# Phase 4：顶层集成

> 所属项目：XDMA + FFT 音乐频谱分析仪
> 前置依赖：Phase 1（BD Wrapper）、Phase 2（FFT IP）、Phase 3（magnitude_calc）
> 后续阶段：Phase 5（约束、综合与实现）

## 一、目标

创建 Clock Wizard IP，编写顶层 RTL 模块 `top.v`，例化 BD Wrapper、Clock Wizard、FFT IP 和 magnitude_calc，完成所有信号连接，并通过系统级仿真验证完整数据通路。

## 二、Clock Wizard IP 创建

实例名：`clk_wiz_0`

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 输入时钟 | 100 MHz 差分 (LVDS) | 板上晶振 |
| 输出时钟 clk_out1 | 100 MHz | 全局系统时钟 |
| 输入类型 | Differential clock capable pin | 差分输入 |
| Reset Type | Active Low | rst_n |

生成输出产物。

## 三、顶层模块设计

### 3.1 接口定义

```verilog
module top (
    // 系统时钟
    input  wire        sys_clk_p,       // 100 MHz 差分正端
    input  wire        sys_clk_n,       // 100 MHz 差分负端
    input  wire        sys_rst_n,       // 全局复位，低有效

    // PCIe 接口
    input  wire        pcie_refclk_p,   // PCIe 参考时钟正端
    input  wire        pcie_refclk_n,   // PCIe 参考时钟负端
    input  wire        pcie_perstn,     // PCIe 复位
    input  wire [3:0]  pcie_rxp,        // PCIe 接收
    input  wire [3:0]  pcie_rxn,
    output wire [3:0]  pcie_txp,        // PCIe 发送
    output wire [3:0]  pcie_txn,

    // 状态指示
    output wire        led_link_up      // PCIe link up 指示（可选）
);
```

### 3.2 内部连接架构

```
        top.v                            全部 clk_100m 域
┌────────────────────────────────────────────────────────────┐
│                                                            │
│  sys_clk_p/n ──► [clk_wiz_0] ──┬► clk_100m ─────────┐    │
│                                 └► locked             │    │
│                                      │                │    │
│  pcie_* ◄──────► [xdma_subsystem_wrapper]             │    │
│                  │ clk_100m ◄────────┘                │    │
│                  │ locked ◄──────────                 │    │
│                  │                                    │    │
│                  │ m_axis_h2c ──►[位宽适配 128→32]    │    │
│                  │                      │             │    │
│                  │                ┌─────▼──────┐      │    │
│                  │                │  xfft_0    │      │    │
│                  │                │ (FFT IP)   │      │    │
│                  │                └─────┬──────┘      │    │
│                  │                      │             │    │
│                  │                ┌─────▼──────────┐  │    │
│                  │                │ magnitude_calc │  │    │
│                  │                └─────┬──────────┘  │    │
│                  │                      │             │    │
│                  │ s_axis_c2h ◄──[位宽适配 16→128]    │    │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### 3.3 时钟域说明

| 时钟 | 来源 | 频率 | 驱动模块 |
|------|------|------|----------|
| clk_100m | Clock Wizard 输出 | 100 MHz | FFT、magnitude_calc、位宽适配逻辑、BD FIFO 的用户侧 |
| axi_aclk | XDMA IP 内部 | ~250 MHz | 仅 XDMA 自身 AXI 总线，封闭在 BD 内部，不引出 |

> **单时钟域设计**：BD Wrapper 引出的 AXI-Stream 接口已经过 CDC FIFO 转到 clk_100m 域。因此顶层 RTL 中所有用户逻辑（FFT、magnitude_calc、位宽适配）均工作在 **clk_100m (100 MHz)** 下，无任何跨时钟域问题。100 MHz 对 FFT Pipelined Streaming 和 magnitude_calc 组合路径来说时序非常宽裕。

### 3.4 数据位宽适配

XDMA AXI4-Stream 数据宽度为 **128-bit**（Gen3 x4），而 FFT 输入为 32-bit（16-bit Re + 16-bit Im），magnitude_calc 输出为 16-bit。需要在顶层 RTL 中进行位宽适配。

**H2C 方向（128-bit → 32-bit）**：

PC 端每个 128-bit beat 中只放一个 16-bit 采样点在最低位，其余补零。顶层 RTL 提取低 16 位作为 FFT 实部输入，虚部补零：

```verilog
// H2C 位宽适配（在 top.v 中用 assign 实现）
assign fft_s_axis_tdata  = {16'b0, h2c_m_axis_tdata[15:0]};  // {Im=0, Re=PCM}
assign fft_s_axis_tvalid = h2c_m_axis_tvalid;
assign fft_s_axis_tlast  = h2c_m_axis_tlast;
assign h2c_m_axis_tready = fft_s_axis_tready;
// h2c_m_axis_tkeep 不需要处理（数据已由 PC 端正确对齐）
```

> 每个 128-bit beat 只携带一个 16-bit 有效样本，利用率低（12.5%），但音频带宽需求仅约 345 KB/s，PCIe Gen3 x4 带宽约 4 GB/s，完全可接受。

**C2H 方向（16-bit → 128-bit）**：

将 magnitude_calc 的 16-bit 输出扩展到 128-bit，放入最低位：

```verilog
// C2H 位宽适配（在 top.v 中用 assign 实现）
assign c2h_s_axis_tdata  = {112'b0, mag_m_axis_tdata[15:0]};
assign c2h_s_axis_tvalid = mag_m_axis_tvalid;
assign c2h_s_axis_tlast  = mag_m_axis_tlast;
assign c2h_s_axis_tkeep  = 16'hFFFF;  // 全部字节标记有效
assign mag_m_axis_tready = c2h_s_axis_tready;
```

> **关于 tkeep**：设置为全 1（`16'hFFFF`）表示 128-bit 中所有 16 个字节有效。虽然实际只有低 2 字节携带有效数据，但 XDMA 驱动读回完整的 128-bit word，PC 端提取低 16 位即可。

### 3.5 FFT Config 通道驱动

FFT IP 的 `s_axis_config` 通道需要**每帧**发送一个配置字（即使配置不变）。设计一个 config 驱动逻辑：

- 配置字内容固定：`FWD_INV=1, SCALE_SCH=20'b10_10_10_10_10_10_10_10_10_10`（详见 Phase 2 §2.4）
- **每帧发送一次 config**：监测 H2C 数据流的 tlast 信号，每当上一帧结束（tlast 断言），在下一帧第一个数据到达前发送 config
- 上电后首帧的 config 由复位逻辑触发
- 使用状态机：SEND_CONFIG → WAIT_FRAME_END → SEND_CONFIG（循环）

Config 通道 RTL 框架：

```verilog
// FFT config 通道驱动（在 top.v 中）
// 注意：config tdata 位宽以 IP 实际生成的端口为准，此处假设为 24-bit
localparam CFG_FWD_INV  = 1'b1;
localparam CFG_SCALE    = 20'b10_10_10_10_10_10_10_10_10_10;
localparam CFG_WORD     = {3'b000, CFG_SCALE, CFG_FWD_INV};  // 24-bit

reg cfg_sent;  // 当前帧 config 是否已发送

always @(posedge clk_100m or negedge rst_n) begin
    if (!rst_n)
        cfg_sent <= 1'b0;
    else if (fft_cfg_tvalid && fft_cfg_tready)
        cfg_sent <= 1'b1;                     // config 已发送
    else if (h2c_tlast_pulse)
        cfg_sent <= 1'b0;                     // 帧结束，准备下一帧 config
end

assign fft_cfg_tdata  = CFG_WORD;
assign fft_cfg_tvalid = ~cfg_sent;            // 未发送时持续请求
```

> **关于 config tdata 位宽**：上述代码假设 24-bit，实际位宽以 FFT IP 生成后的端口声明为准。创建 IP 后检查 `s_axis_config_tdata` 的位宽，必要时调整 `CFG_WORD` 的拼接方式。

> **为什么每帧都发**：Pipelined Streaming 架构的 FFT IP 要求每帧都有对应的 config word。只在上电时发一次可能导致后续帧处理异常（取决于 IP 版本的内部行为）。每帧发送 config 是最安全的做法。

### 3.6 文件路径

| 文件 | 路径 |
|------|------|
| top.v | `prj/04/rtl/top.v` |

## 四、仿真验证

### 4.1 仿真策略

XDMA IP 的 PCIe 行为无法在简单 testbench 中模拟，因此仿真**不例化 top.v**，而是搭建一个独立的数据通路 testbench，直接例化 FFT IP + magnitude_calc + 位宽适配 + config 驱动逻辑：

- **注入端**：testbench 生成 128-bit AXI-Stream 测试数据（模拟 BD 的 m_axis_h2c 输出），送入位宽适配 → FFT
- **捕获端**：magnitude_calc → 位宽适配输出 128-bit AXI-Stream，testbench 接收并验证
- **时钟**：testbench 提供 100 MHz 时钟，与实际 clk_100m 一致

> 本 testbench 验证的是 BD Wrapper 以外的全部用户逻辑（位宽适配 + FFT + config 驱动 + magnitude_calc），不包含 BD Wrapper 和 XDMA。文件命名为 `tb_datapath.v` 以准确反映仿真范围。

### 4.1.1 帧同步机制说明

端到端帧同步依赖以下链条：
1. PC 端一次 DMA write 写入恰好 1024 × 16 bytes = 16384 bytes
2. XDMA H2C 在该次传输最后一个 beat 自动生成 `tlast`
3. `tlast` 经 Input FIFO 透传到 FFT，FFT 以此识别帧边界
4. FFT 处理完整 1024 点后输出完整一帧，`tlast` 标记帧尾
5. magnitude_calc 透传 `tlast`，经 Output FIFO 传递到 XDMA C2H
6. PC 端一次 DMA read 读取 16384 bytes，`tlast` 标记传输完成

**需要在 Phase 6 硬件验证中确认**：XDMA AXI-Stream H2C 在单次 DMA 传输结束时确实生成 `tlast`。

**Plan B — tlast 计数器生成**：如果 XDMA H2C 不自动生成 tlast，在顶层 RTL 的 H2C 位宽适配与 FFT 之间插入一个 tlast 生成模块：对 `tvalid & tready` 握手计数，每 1024 个有效 beat 后置 `tlast=1`，并忽略上游 tlast。逻辑仅需一个 10-bit 计数器，资源开销可忽略。

```verilog
// Plan B: tlast 计数器（在 top.v 中，位宽适配与 FFT 之间）
reg [9:0] beat_cnt;
always @(posedge clk_100m or negedge rst_n) begin
    if (!rst_n)
        beat_cnt <= 0;
    else if (fft_s_axis_tvalid && fft_s_axis_tready)
        beat_cnt <= (beat_cnt == 1023) ? 0 : beat_cnt + 1;
end
assign fft_s_axis_tlast = (beat_cnt == 1023) && fft_s_axis_tvalid;
```

> Phase 6 硬件验证时先测试不加计数器（依赖 XDMA 原生 tlast），如果帧同步失败，启用 Plan B。

**首帧延迟注意**：FFT Pipelined Streaming 有内部流水线延迟，第一帧输入完成后可能需要额外若干周期才能输出全部结果。C2H read 的超时设置应考虑这一延迟。

### 4.2 测试用例

#### TC-01：端到端单频正弦波

**输入**：通过 AXI-S 接口发送 1024 点单频正弦波（bin 64），格式为 `{112'b0, pcm_sample[15:0]}`（128-bit 对齐）。

**验证**：
- 从 C2H 端口捕获 1024 个 128-bit word，提取低 16 位为幅度值
- bin 64 处幅度最大
- 输出 tlast 正确

#### TC-02：连续多帧处理

**输入**：连续发送 4 帧不同频率的正弦波数据。

**验证**：
- 每帧独立输出正确频谱
- 帧间无数据丢失或串扰
- 共接收 4 × 1024 = 4096 个输出数据

#### TC-03：复位恢复

**输入**：正常运行 1 帧后，断言复位，释放后再发送 1 帧。

**验证**：
- 复位后系统正确初始化
- 第二帧数据处理结果正确

#### TC-04：反压测试

**输入**：发送数据的同时，在 C2H 端口（输出侧）随机拉低 `tready`。

**验证**：
- 上游数据不丢失，整条通路正确反压
- 最终输出数据完整且正确

### 4.3 仿真文件

| 文件 | 路径 | 说明 |
|------|------|------|
| tb_datapath.v | `prj/04/sim/tb_datapath.v` | 数据通路 testbench（位宽适配 + FFT + config 驱动 + magnitude_calc） |

## 五、验证标准

| 编号 | 验证项 | 通过条件 |
|------|--------|----------|
| P4-01 | Clock Wizard | IP 创建成功，输出产物生成 |
| P4-02 | 语法检查 | top.v 编译无 Error |
| P4-03 | 端到端正弦波 | 单频正弦波频谱正确 |
| P4-04 | 连续多帧 | 4 帧连续处理均正确 |
| P4-05 | 复位恢复 | 复位后系统正常恢复工作 |
| P4-06 | 反压 | 输出侧反压时无数据丢失 |
