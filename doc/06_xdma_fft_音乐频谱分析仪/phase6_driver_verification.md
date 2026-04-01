# Phase 6：驱动安装与硬件验证

> 所属项目：XDMA + FFT 音乐频谱分析仪
> 前置依赖：Phase 5（比特流已生成）
> 后续阶段：Phase 7（上位机与 Web 频谱可视化）

## 一、目标

在 Linux 服务器上完成比特流下载、XDMA 驱动安装，并通过 DMA 读写测试验证 FPGA 数据通路正确性。

## 二、远程操作环境

所有远程 Linux 操作通过 Claude Code 的 MCP 工具完成，无需手动 SSH 登录。

| 工具 | 用途 |
|------|------|
| `ssh-client` (exec / sudo_exec / SFTP) | 远程命令执行、文件上传下载 |
| Vivado Hardware Manager | 比特流烧写（本地 Vivado 连接远程 hw_server 或本地 JTAG） |

**远程服务器信息**：
- IP: 192.168.2.101，用户: work
- OS: Ubuntu 18.04，Kernel: 4.15.0-156
- Python: 3.6.9，GCC: 7.5
- 远程工作目录: `~/workplace/fft`

## 三、比特流下载与系统重启

### 3.1 下载比特流

通过本地 Vivado Hardware Manager 将比特流下载到 FPGA（SynthPilot MCP 工具）：

```
# SynthPilot MCP 操作流程
connect_hardware_server → open_hardware_target → program_device
```

比特流路径：`.../impl_1/top.bit`

### 3.2 重启远程服务器

FPGA 烧录后需要重启服务器，让 Linux 内核在启动阶段完成 PCIe 枚举和 link training：

```bash
# 通过 ssh-client sudo exec 执行
sudo reboot
```

等待 **60 秒** 后，通过 ssh-client exec 验证连通性：

```bash
echo "SSH OK" && hostname
```

> **注意**：热扫描 (`echo 1 > /sys/bus/pci/rescan`) 对 XDMA 这种需要 link training 的设备不够可靠，reboot 是最稳妥的方式。

### 3.3 确认设备枚举

通过 ssh-client exec 执行：

```bash
lspci | grep -i xilinx
# 期望输出类似：
# 01:00.0 Memory controller: Xilinx Corporation Device 903f
```

```bash
lspci -vvv -s <BDF> | grep -E "LnkSta:|LnkCap:"
# 确认 Link Speed = 8GT/s (Gen3), Link Width = x4
```

## 四、远程工作目录初始化

通过 ssh-client exec 创建工作目录：

```bash
mkdir -p ~/workplace/fft
```

后续所有 Python 脚本通过 ssh-client SFTP 上传到此目录。

## 五、XDMA 驱动安装

驱动已在远程机预编译：`~/workplace/xdma_rework/driver/xdma.ko`

所有步骤通过 ssh-client exec / sudo 执行。

### 5.1 安装到内核模块目录

```bash
# sudo
sudo mkdir -p /lib/modules/$(uname -r)/extra
sudo cp ~/workplace/xdma_rework/driver/xdma.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a
```

### 5.2 配置开机自动加载

```bash
# sudo
echo "xdma" | sudo tee /etc/modules-load.d/xdma.conf
```

重启后系统自动执行 `modprobe xdma`，无需手动 insmod。

### 5.3 验证驱动加载

```bash
lsmod | grep xdma
# 期望看到 xdma 模块

ls /dev/xdma0_*
# 期望看到：
# /dev/xdma0_h2c_0    ← Host to Card (DMA 写通道)
# /dev/xdma0_c2h_0    ← Card to Host (DMA 读通道)
# /dev/xdma0_control  ← 控制寄存器（AXI-Lite，如有）
# /dev/xdma0_user     ← 用户寄存器（如有）
```

> **注意**：如果重新编译了驱动，需要重新执行 5.1 步骤更新 `/lib/modules/.../extra/xdma.ko` 并 `depmod -a`。

## 六、基础 DMA 测试

### 6.1 使用驱动自带工具

通过 ssh-client exec 执行：

```bash
cd ~/workplace/fft/dma_ip_drivers/XDMA/linux-kernel/tools
make

# 生成测试数据
dd if=/dev/urandom of=test_data.bin bs=4096 count=1

# H2C 写入
./dma_to_device -d /dev/xdma0_h2c_0 -f test_data.bin -s 4096

# C2H 读回
./dma_from_device -d /dev/xdma0_c2h_0 -f output.bin -s 4096
```

> **注意**：由于数据经过 FFT + magnitude 处理，读回的数据不会与写入数据相同。此处仅验证 DMA 通道畅通，不校验数据内容。

### 6.2 Python 基础 DMA 测试

文件：`prj/04/host/test_dma.py`（本地编写，SFTP 上传到 `~/workplace/fft/`）

```python
"""基础 DMA 读写测试脚本"""

# 功能需求：
# 1. 打开 /dev/xdma0_h2c_0 和 /dev/xdma0_c2h_0
# 2. 生成已知数据（如全零或简单模式）
# 3. H2C 写入 → 等待处理 → C2H 读回
# 4. 打印读回数据，人工确认
```

通过 ssh-client exec 运行：

```bash
cd ~/workplace/fft && python3 test_dma.py
```

## 七、FFT 通路端到端验证

### 7.1 正弦波测试

文件：`prj/04/host/test_fft.py`（本地编写，SFTP 上传到 `~/workplace/fft/`）

**测试流程**：

1. **生成测试数据**：
   - 生成 1024 点正弦波（频率 = bin 64 对应频率）
   - 16-bit signed 格式，放入 128-bit (16 bytes) 对齐的 buffer（低 16 位有效，高 112 位补零）
   - 总数据量 = 1024 × 16 bytes = 16384 bytes

2. **DMA 写入**：
   - 将数据写入 `/dev/xdma0_h2c_0`
   - **确认 XDMA 在传输结束时生成了 tlast**（关键帧同步点）

3. **DMA 读回**：
   - 从 `/dev/xdma0_c2h_0` 读取 1024 × 16 bytes = 16384 bytes
   - 每 16 bytes 提取低 16 位（unsigned）作为幅度值

4. **验证**：
   - 找到幅度最大值所在的 bin index
   - 确认 bin index = 64（或与输入频率对应的 bin）
   - 打印完整频谱数据供人工审查

通过 ssh-client exec 运行：

```bash
cd ~/workplace/fft && python3 test_fft.py
```

### 7.2 多频测试

在正弦波测试通过后，叠加两个频率的正弦波，验证两个频率 bin 均出现尖峰。

### 7.3 静音测试

输入全零数据，验证输出全部为零或接近零（噪底）。

## 八、操作流程总结

```
本地 Vivado                 ssh-client
    │                              │
    ├─ program_device (top.bit)    │
    │                              │
    │                      sudo reboot
    │                      wait 60s
    │                      lspci (确认枚举)
    │                              │
    │                      git clone dma_ip_drivers
    │                      make && sudo modprobe xdma
    │                      ls /dev/xdma0_*
    │                              │
    │      SFTP upload ──→ test_dma.py / test_fft.py
    │                      python3 test_dma.py
    │                      python3 test_fft.py
```

## 九、故障排查指南

| 现象 | 可能原因 | 排查方法 |
|------|----------|----------|
| reboot 后 SSH 连不上 | 机器未恢复 | 等待更久（90-120 秒），检查网络 |
| lspci 无设备 | PCIe link 未建立 | 检查比特流是否烧录、PERST# 信号、GT 引脚约束 |
| 驱动加载失败 | 内核版本不兼容 | SSH 执行 `dmesg | tail -50`，确认内核 headers |
| /dev/xdma0_* 不存在 | 驱动未识别设备 | SSH 执行 `dmesg | grep xdma`，确认 Device ID |
| DMA 写超时 | H2C 通道阻塞 | 检查 FPGA 内部 FIFO 是否满，tready 是否拉高 |
| 读回数据全零 | C2H 通道未连接或 FFT 未启动 | 检查 FFT config 是否已发送，数据通路连接 |
| 频谱不正确 | 位宽对齐或字节序问题 | 打印原始 DMA 数据，对比仿真结果 |

## 十、验证标准

| 编号 | 验证项 | 通过条件 |
|------|--------|----------|
| P6-01 | PCIe 枚举 | SSH `lspci` 显示 Xilinx 设备，Gen3 x4 |
| P6-02 | 驱动加载 | SSH `lsmod` 显示 xdma，/dev/xdma0_* 存在 |
| P6-03 | DMA 通道 | H2C 写入和 C2H 读回无超时 |
| P6-04 | 正弦波频谱 | 输入 bin 64 正弦波，输出在 bin 64 出现最大幅度 |
| P6-05 | 多频频谱 | 两个频率分量均正确分离 |
| P6-06 | 静音测试 | 全零输入，输出幅度接近零 |
