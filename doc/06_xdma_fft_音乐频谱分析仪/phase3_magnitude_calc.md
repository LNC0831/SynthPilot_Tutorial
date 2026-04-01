# Phase 3：幅度计算模块

> 所属项目：XDMA + FFT 音乐频谱分析仪
> 前置依赖：Phase 2（FFT IP 配置与仿真完成）
> 后续阶段：Phase 4（顶层集成）

## 一、目标

编写幅度计算 RTL 模块 `magnitude_calc`，对 FFT 输出的复数结果取近似幅度，AXI4-Stream 接口适配，并通过仿真全面验证。

## 二、模块设计

### 2.1 功能描述

FFT IP 输出的每个频率 bin 为复数 `X[k] = Re + j·Im`，本模块计算其近似幅度：

```
|X[k]| ≈ |Re| + |Im|
```

这是最简单的 L1 范数近似，硬件开销仅为两个绝对值和一个加法器。最大误差约 41%（当 |Re| = |Im| 时），但对于频谱可视化场景完全足够。

### 2.2 接口定义

```verilog
module magnitude_calc #(
    parameter DATA_WIDTH = 32,   // FFT 输出 tdata 位宽（Re + Im 拼接）
    parameter OUT_WIDTH  = 16    // 输出幅度位宽
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // AXI4-Stream slave（来自 FFT 输出）
    input  wire [DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire                    s_axis_tvalid,
    input  wire                    s_axis_tlast,
    output wire                    s_axis_tready,

    // AXI4-Stream master（输出到 Output FIFO）
    output wire [OUT_WIDTH-1:0]    m_axis_tdata,
    output wire                    m_axis_tvalid,
    output wire                    m_axis_tlast,
    input  wire                    m_axis_tready
);
```

### 2.3 内部逻辑

```
s_axis_tdata = {Im[15:0], Re[15:0]}   （FFT 输出格式）

步骤：
1. 提取 Re = tdata[15:0]  （16-bit signed）
2. 提取 Im = tdata[31:16]  （16-bit signed）
3. 将 Re、Im 符号扩展为 17-bit signed，再取绝对值：
   wire signed [16:0] re_ext = {Re[15], Re};     // 17-bit signed
   wire signed [16:0] im_ext = {Im[15], Im};
   abs_re = (re_ext < 0) ? -re_ext : re_ext;     // 17-bit unsigned, 范围 [0, 32768]
   abs_im = (im_ext < 0) ? -im_ext : im_ext;
4. magnitude = abs_re + abs_im                    // 18-bit, 最大值 32768+32768=65536
5. 输出 OUT_WIDTH=16 (unsigned): 截取低 16 位，若 magnitude > 65535 则饱和为 65535
```

> **-32768 边界处理**：16-bit signed 的 -32768 (16'h8000) 取反在 16-bit 内会溢出（+32768 超出范围）。通过先符号扩展到 17-bit，-32768 变为 17'sh10000，取反得到 +32768 = 17'h08000，正确无溢出。

> **输出位宽**：OUT_WIDTH=16 为 **unsigned**，范围 [0, 65535]。|Re|+|Im| 最大值为 65536（当 Re=-32768, Im=-32768），此极端情况饱和为 65535。一般情况下 max=65534（32767+32767），无需饱和。

### 2.4 AXI4-Stream 协议要求

- **直通式设计**：`s_axis_tready` 直接连接 `m_axis_tready`（组合逻辑），不引入额外缓冲
- **tvalid 传递**：输入 `s_axis_tvalid` 经过 1 拍寄存后输出为 `m_axis_tvalid`（如果采用寄存器输出）；或组合直通（零延迟方案）
- **tlast 传递**：与 tvalid 同步传递，标记帧尾
- **反压支持**：当 `m_axis_tready = 0` 时，停止接收上游数据

> **设计选择**：推荐 **组合直通** 方案（零周期延迟），将绝对值和加法作为纯组合逻辑实现。该模块工作在 clk_100m (100 MHz, 10 ns 周期)，17-bit 求补 + 18-bit 加法的组合路径时序非常宽裕。

### 2.5 文件路径

| 文件 | 路径 |
|------|------|
| magnitude_calc.v | `prj/04/rtl/magnitude_calc.v` |

## 三、仿真验证

### 3.1 仿真参数

| 参数 | 值 |
|------|-----|
| 仿真时钟 | 100 MHz（与实际工作时钟 clk_100m 一致） |
| 数据位宽 | 32-bit 输入，16-bit unsigned 输出 |

### 3.2 测试用例

#### TC-01：已知复数幅度验证

**输入**：一组预设的复数值，覆盖典型和边界情况：

| Re | Im | 期望 |Re| + |Im| |
|----|----|-----------------------|
| 100 | 0 | 100 |
| 0 | 100 | 100 |
| 100 | 100 | 200 |
| -100 | 50 | 150 |
| -32768 | 0 | 32768（通过 17-bit 扩展正确处理） |
| 0 | -32768 | 32768 |
| 0 | 0 | 0 |
| 32767 | 32767 | 65534（16-bit unsigned 可表示，无需饱和） |
| -32768 | -32768 | 65535（65536 饱和为 65535） |

**验证**：输出值与期望一致，-32768 边界和饱和情况正确处理。

#### TC-02：AXI4-Stream 反压

**输入**：连续发送 1024 个复数数据，期间 `m_axis_tready` 随机拉低。

**验证**：
- `tready = 0` 时模块暂停接收（`s_axis_tready` 也拉低）
- `tready` 恢复后数据继续传输，无丢失
- 最终输出数据数量 = 输入数据数量

#### TC-03：tlast 传递

**输入**：发送两帧数据（每帧 1024 点），每帧最后一个数据 `tlast = 1`。

**验证**：
- 输出 `m_axis_tlast` 在每帧最后一个数据时为 1
- tlast 与 tdata/tvalid 严格对齐

#### TC-04：快速反压交替

**输入**：连续发送 1024 个数据，`m_axis_tready` 每 1~2 拍快速翻转。

**验证**：
- 无毛刺或数据损坏
- 输出数据完整正确

#### TC-05：背靠背帧

**输入**：两帧数据背靠背发送，第一帧 `tlast` 紧接第二帧第一个 `tvalid`，无间隔。

**验证**：
- 两帧均正确处理，帧边界无混淆
- 输出 tlast 正确对齐

#### TC-06：与 FFT IP 级联仿真

**输入**：将 Phase 2 的 FFT testbench 扩展，在 FFT 输出后级联 magnitude_calc 模块。输入单频正弦波（如 bin 64）。

**验证**：
- magnitude_calc 输出在 bin 64 处为最大值
- 输出为正整数（无符号），帧长度 = 1024
- 数据流无阻塞，吞吐率与 FFT 输出匹配

### 3.3 仿真文件

| 文件 | 路径 | 说明 |
|------|------|------|
| tb_magnitude_calc.v | `prj/04/sim/tb_magnitude_calc.v` | 模块级 testbench |
| tb_fft_magnitude.v | `prj/04/sim/tb_fft_magnitude.v` | FFT + magnitude 级联 testbench |

## 四、验证标准

| 编号 | 验证项 | 通过条件 |
|------|--------|----------|
| P3-01 | 幅度正确性 | 所有预设复数输入的输出值与期望一致 |
| P3-02 | 溢出处理 | 极端值输入时正确饱和，无回绕 |
| P3-03 | 反压合规 | tready 随机拉低时无数据丢失 |
| P3-04 | tlast 传递 | 每帧 tlast 正确对齐传递 |
| P3-05 | 快速反压 | tready 每 1~2 拍翻转时无数据损坏 |
| P3-06 | 背靠背帧 | 帧间无间隔时两帧均正确处理 |
| P3-07 | 级联正确性 | FFT → magnitude_calc 端到端频谱输出正确 |
| P3-08 | 吞吐率 | 零反压时每时钟处理一个数据 |
