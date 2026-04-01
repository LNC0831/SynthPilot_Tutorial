# Phase 2：FFT IP 配置与仿真

> 所属项目：XDMA + FFT 音乐频谱分析仪
> 前置依赖：Phase 1（Block Design 搭建完成，工程已创建）
> 后续阶段：Phase 3（幅度计算模块）

## 一、目标

创建并配置 Xilinx FFT IP（独立 IP，不在 BD 内），生成输出产物，并通过仿真验证 FFT 功能正确性。

## 二、FFT IP 配置

使用 Xilinx Fast Fourier Transform IP (xfft)。

实例名：`xfft_0`

### 2.1 核心参数

| 配置项 | 值 | 说明 |
|--------|-----|------|
| Transform Length | 1024 | N = 1024 点 |
| Architecture | Pipelined Streaming I/O | 高吞吐，持续流式处理 |
| Data Format | Fixed Point | 定点 |
| Input Data Width | 16 bit | 匹配 PCM 采样精度 |
| Phase Factor Width | 16 bit | 旋转因子精度 |
| Scaling Options | Scaled | 每级蝶形运算缩放，防溢出 |
| Rounding Mode | Convergent Rounding | 精度更优 |
| Output Ordering | Natural Order | 自然序输出，便于后续处理 |
| Throttle Scheme | Non Real Time | 支持反压 |

### 2.2 AXI4-Stream 接口

FFT IP 的 AXI4-Stream 接口说明：

| 接口 | 方向 | 说明 |
|------|------|------|
| s_axis_data | slave | 输入时域数据，`tdata` 格式为 `{Im[15:0], Re[15:0]}`（本设计 Im 补零） |
| m_axis_data | master | 输出频域数据，`tdata` 格式为 `{Im[15:0], Re[15:0]}` |
| s_axis_config | slave | FFT 配置通道（FWD/INV、缩放因子） |
| m_axis_status | master | 状态输出（可选） |

> **输入数据格式**：PCM 音频为实数信号，输入时 Re = PCM 采样值，Im = 0。`s_axis_data.tdata` 的高 16 位（虚部）填零，低 16 位（实部）为 PCM 数据。

> **Config 通道**：每帧开始前需通过 `s_axis_config` 发送一个配置字，指定 FWD_INV = 1（正变换）和 SCALE_SCH（缩放调度）。详见 2.4 节。

### 2.3 缩放调度（Scaling Schedule）

1024 点 FFT，Pipelined Streaming 架构，Radix-2 分解 = **10 级**蝶形运算。每级用 2 bit 编码缩放因子，共需 **20 bit**。

推荐缩放调度：每级缩放 2（右移 1 位），总缩放 2^10 = 1024。

`SCALE_SCH = 20'b10_10_10_10_10_10_10_10_10_10`

- 每两位对应一级，值 `2'b10` 表示该级缩放因子为 2
- **LSB 两位对应第一级（Stage 0），MSB 两位对应最后一级（Stage 9）**
- Scaled 模式下，总缩放因子 = N = 1024，输出位宽等于输入位宽（16-bit Re + 16-bit Im = 32-bit tdata）

### 2.4 Config 通道配置字格式

FFT IP 的 `s_axis_config.tdata` 位域定义（参考 PG109）：

| 位域 | 宽度 | 说明 |
|------|------|------|
| bit[0] | 1 | FWD_INV：1 = 正变换 (FFT)，0 = 逆变换 (IFFT) |
| bit[20:1] | 20 | SCALE_SCH：缩放调度（LSB 对应第一级） |
| bit[23:21] | 3 | 保留，填零 |

`s_axis_config.tdata` 总线宽度为 24-bit（参考 PG109 对 1024 点 Pipelined Streaming + Scaled 的默认值）。

> **重要**：config tdata 的实际位宽以 IP 创建后生成的端口声明为准。创建 FFT IP 后，务必检查 `xfft_0` 的 `s_axis_config_tdata` 端口位宽，若与 24-bit 不符则需调整 Phase 4 中 config 驱动的拼接逻辑。

**本设计的配置字**：`FWD_INV=1, SCALE_SCH=20'b10_10_10_10_10_10_10_10_10_10`

拼接为：`{3'b000, 20'b10_10_10_10_10_10_10_10_10_10, 1'b1}`

> **每帧配置**：Pipelined Streaming 架构下，建议每帧都发送一个 config word（即使配置不变），确保 FFT IP 正确识别帧边界。Config 必须在该帧第一个数据到达之前或同时发送。

## 三、生成 IP 输出产物

配置完成后，生成 IP 输出产物（Generate Output Products），确保综合和仿真模型可用。

## 四、仿真验证

### 4.1 仿真参数

| 参数 | 值 |
|------|-----|
| 仿真时钟 | 100 MHz（10 ns 周期） |
| FFT 点数 | 1024 |
| 输入数据位宽 | 16-bit signed |

> **仿真时钟 = 实际工作时钟**：FFT 工作在 clk_100m (100 MHz) 下，与仿真时钟一致，无需额外频率验证。

### 4.2 测试用例

#### TC-01：单频正弦波

**输入**：生成 1024 点正弦波，频率设定使其恰好落在某个 FFT bin 上。

例如：bin index = 64，则频率 = 64 × (Fs / N)，其中 Fs = 采样率，N = 1024。

**验证**：
- FFT 输出在 bin 64 处幅度最大
- 其余 bin 幅度显著低于峰值（至少低 40 dB）
- 输出 `tlast` 在第 1024 个数据点时断言

#### TC-02：多频叠加信号

**输入**：叠加两个不同频率的正弦波（如 bin 64 和 bin 256）。

**验证**：
- FFT 输出在 bin 64 和 bin 256 处均出现幅度尖峰
- 两个峰值幅度与输入振幅比例一致

#### TC-03：AXI4-Stream 握手时序

**输入**：在数据传输过程中随机暂停 `tvalid`（模拟上游间歇发送）。

**验证**：
- FFT 正确处理不连续输入，输出数据不受影响
- `tready` 信号行为正确

#### TC-04：连续多帧

**输入**：连续发送 4 帧不同数据（每帧 1024 点），帧间无间隔。

**验证**：
- 每帧输出独立正确，帧间无数据串扰
- `tlast` 在每帧最后一个数据点正确断言
- 共输出 4 × 1024 = 4096 个数据点

#### TC-05：Config 通道验证

**输入**：发送正变换配置（FWD_INV = 1），验证 FFT 执行正变换。每帧都发送 config word。

**验证**：
- Config `tready` 握手正常
- FFT 按正变换模式处理数据
- 连续多帧每帧前都发送 config，处理均正确

#### TC-06：全零输入

**输入**：1024 个全零采样点。

**验证**：
- 所有 bin 输出幅度为零或接近零（排除 DC offset 问题）

#### TC-07：DC 信号（常数输入）

**输入**：1024 个相同值（如 1000）。

**验证**：
- 能量集中在 bin 0（DC 分量），其余 bin 接近零

#### TC-08：最大幅值输入

**输入**：所有采样点为 +32767 或交替 +32767/-32768。

**验证**：
- Scaled 模式下输出无溢出回绕
- 交替输入（Nyquist 频率）能量集中在 bin 512

### 4.3 仿真文件

| 文件 | 路径 | 说明 |
|------|------|------|
| tb_fft_ip.v | `prj/04/sim/tb_fft_ip.v` | FFT IP 仿真 testbench |

Testbench 需要：
- 使用 `$readmemh` 或内部 generate 生成正弦波测试数据
- 捕获 FFT 输出，计算各 bin 幅度
- 自动判定 PASS/FAIL 并打印结果

## 五、验证标准

| 编号 | 验证项 | 通过条件 |
|------|--------|----------|
| P2-01 | IP 创建 | FFT IP 配置正确，输出产物生成成功 |
| P2-02 | 单频正弦波 | 目标 bin 幅度为最大值，旁瓣抑制 > 40 dB |
| P2-03 | 多频叠加 | 两个频率分量均正确分离 |
| P2-04 | AXI-S 握手 | tvalid 间歇发送时数据处理正确 |
| P2-05 | 连续多帧 | 4 帧连续处理，每帧结果独立正确 |
| P2-06 | Config 通道 | 配置字握手正常，每帧 config 正变换执行正确 |
| P2-07 | 全零输入 | 输出全零或接近零 |
| P2-08 | DC / Nyquist | DC 信号能量在 bin 0，Nyquist 信号能量在 bin 512 |

## 六、完成记录（2026-03-31）

### 状态：✅ 全部通过

Testbench 文件：`prj/04/sim/tb_fft_ip.sv`（SystemVerilog）

| 编号 | 测试项 | 结果 | 备注 |
|------|--------|------|------|
| P2-01 | IP 创建 | ✅ PASS | `xfft_0`，config tdata=16-bit，SCALE_SCH=10-bit (5级) |
| P2-02 | 单频正弦波 (TC-01) | ✅ PASS | Bin[64]: Im=-4096, ratio=100.0 dB |
| P2-03 | 多频叠加 (TC-02) | ✅ PASS | Bin64=4.194e+06, Bin256=4.194e+06, other=0 |
| P2-04 | AXI-S 握手 (TC-03) | ✅ PASS | 确定性 gap (每4样本插2空闲周期), ratio=100.0 dB |
| P2-05 | 连续多帧 (TC-04) | ✅ PASS | 4帧/4096样本/4 tlast，最后一帧数据正确 |
| P2-06 | Config 通道 (TC-05) | ✅ PASS | tready 握手正常，FFT 正变换正确 |
| P2-07 | 全零输入 (TC-06) | ✅ PASS | max mag²=0 |
| P2-08a | DC 信号 (TC-07) | ✅ PASS | DC=2.5e+05, AC=0, Re[0]=500 |
| P2-08b | 最大幅值 (TC-08a) | ✅ PASS | Bin0 Re=16384, 无溢出 |
| P2-08c | Nyquist (TC-08b) | ✅ PASS | Bin512=2.684e+08, other=0 |

### 与原始任务书的差异

| 项目 | 任务书原始值 | 实际值 | 依据 |
|------|-------------|--------|------|
| Testbench 语言 | Verilog (`tb_fft_ip.v`) | **SystemVerilog** (`tb_fft_ip.sv`) | 需要 `$itor`、`function`、`logic` 等特性 |
| config tdata 位宽 | 24 bit | **16 bit** | IP .veo: `[15:0]` |
| SCALE_SCH 位宽 | 20 bit (10 级) | **10 bit (5 级)** | IP VHDL: `field_width = 10` |
| 推荐 config 值 | `24'h...` | **`16'h0557`** | Xilinx demo TB 默认 |

### 调试中发现的关键问题

1. **Config 偏移（phantom config slot）**
   - 现象：第一帧 FFT 输出完全错误（奇谐波、幅度偏差 4×），第二帧正确
   - 原因：FFT IP (Pipelined Streaming) 上电后 config FIFO 有一个默认 slot，第一个显式发送的 config 被挤到第二帧使用
   - 验证：改变 SCALE_SCH 后只有第二帧输出变化，第一帧不变
   - 修正：在所有测试前发送一个 warm-up 零帧 + config 来消耗 phantom slot

2. **xsim 行为模型与 `$urandom_range` 不兼容**
   - 现象：使用 `$urandom_range(0,3)` 随机 gap 时 xsim 仿真引擎死循环
   - 修正：改用确定性 gap（每 4 样本插 2 空闲周期）

3. **NBA 双传输 bug**（已修正）
   - sender 用 blocking (`=`)，receiver 用 NBA (`<=`)

4. **SV `real'()` bit-cast**（已修正）
   - `real'(logic)` 是 IEEE754 bit-cast，改用 `$itor()`

5. **`out_cnt` reset 竞争**（已修正）
   - 改为累计计数器，永不 reset
