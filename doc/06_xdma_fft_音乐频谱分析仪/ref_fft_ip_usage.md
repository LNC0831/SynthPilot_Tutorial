# Xilinx Fast Fourier Transform IP (xfft v9.1) 使用参考手册

> 参考文档：Xilinx PG109 - Fast Fourier Transform v9.1 LogiCORE IP Product Guide
> 适用配置：1024 点 / Pipelined Streaming I/O / Fixed Point / Scaled / 16-bit
> 本文档基于项目实际生成的 IP 实例 `xfft_0` 编写

---

## 1. IP 概述

Xilinx Fast Fourier Transform (FFT) IP 核实现了 Cooley-Tukey FFT 算法，支持正变换 (FFT) 和逆变换 (IFFT)。IP 采用 AXI4-Stream 接口，包括配置通道（config）、数据输入通道（data in）、数据输出通道（data out）和可选的状态通道（status）。

本项目使用的核心配置：

| 参数 | 值 | 说明 |
|------|-----|------|
| IP 版本 | xfft v9.1 (Revision 13) | Vivado 2024.2 |
| Transform Length | 1024 | N = 1024，NFFT_MAX = 10 |
| Architecture | Pipelined Streaming I/O | 最高吞吐架构，DIF (Decimation-in-Frequency) |
| Data Format | Fixed Point | 定点运算 |
| Input Data Width | 16 bit | 有符号补码，Re 和 Im 各 16 bit |
| Phase Factor Width | 16 bit | 旋转因子精度 |
| Scaling Options | Scaled | 每级可配置缩放，输出位宽 = 输入位宽 |
| Rounding Mode | Convergent Rounding | 银行家舍入，减少截断偏差 |
| Output Ordering | Natural Order | 自然序输出（需要额外 reorder 缓存） |
| Throttle Scheme | Non Real Time | 支持反压，tready/tvalid 完全握手 |
| Run-time Configurable Length | No | 固定 1024 点 |
| Target Device | xcku3p-ffvb676-2-e | Kintex UltraScale+ |

---

## 2. 配置参数详解

### 2.1 Architecture: Pipelined Streaming I/O

Pipelined Streaming I/O 是 FFT IP 中吞吐量最高的架构。其特点：

- 采用 **Decimation-in-Frequency (DIF)** 分解
- 内部由多级 Radix-2 蝶形单元组成，以 **Radix-2 对（pairs）** 为单位进行处理
- 1024 点 FFT：log2(1024) = 10 级 Radix-2，组成 **5 对 Radix-2 级**（等效于 5 级 Radix-4）
- 可同时进行：当前帧的计算、下一帧的数据加载、上一帧的结果输出
- 数据持续流过流水线，无间断（首帧需要初始填充延迟）

### 2.2 Scaled 模式

Scaled 模式下：
- 每个 Radix-2 对（缩放级）可配置 0~3 bit 的右移缩放
- 输出位宽 **等于** 输入位宽（bxk = bxn = 16 bit）
- 总缩放因子 = 各级缩放因子之积
- 合理配置缩放调度可防止中间结果溢出

对比 Unscaled 模式：输出位宽 = bxn + NFFT_MAX + 1 = 16 + 10 + 1 = 27 bit。

### 2.3 Non Real Time Throttle Scheme

- 完全支持 AXI4-Stream 反压机制
- 当 s_axis_data_tvalid 为低时，核心暂停等待
- 当 m_axis_data_tready 为低时，核心暂停输出
- 适合与 FIFO、DMA 等模块配合使用

---

## 3. 接口信号与数据格式

### 3.1 端口列表

根据项目实际生成的 IP（`xfft_0.veo`），端口定义如下：

```verilog
xfft_0 your_instance_name (
  .aclk                        (aclk),                        // input  wire         时钟
  // Config 通道
  .s_axis_config_tdata         (s_axis_config_tdata),         // input  wire [15:0]  配置数据
  .s_axis_config_tvalid        (s_axis_config_tvalid),        // input  wire         配置有效
  .s_axis_config_tready        (s_axis_config_tready),        // output wire         配置就绪
  // 数据输入通道
  .s_axis_data_tdata           (s_axis_data_tdata),           // input  wire [31:0]  输入数据
  .s_axis_data_tvalid          (s_axis_data_tvalid),          // input  wire         输入有效
  .s_axis_data_tready          (s_axis_data_tready),          // output wire         输入就绪
  .s_axis_data_tlast           (s_axis_data_tlast),           // input  wire         帧结束标志
  // 数据输出通道
  .m_axis_data_tdata           (m_axis_data_tdata),           // output wire [31:0]  输出数据
  .m_axis_data_tvalid          (m_axis_data_tvalid),          // output wire         输出有效
  .m_axis_data_tready          (m_axis_data_tready),          // input  wire         输出就绪
  .m_axis_data_tlast           (m_axis_data_tlast),           // output wire         帧结束标志
  // 事件信号
  .event_frame_started         (event_frame_started),         // output wire         帧开始
  .event_tlast_unexpected      (event_tlast_unexpected),      // output wire         意外的 tlast
  .event_tlast_missing         (event_tlast_missing),         // output wire         缺失的 tlast
  .event_status_channel_halt   (event_status_channel_halt),   // output wire         状态通道阻塞
  .event_data_in_channel_halt  (event_data_in_channel_halt),  // output wire         输入通道阻塞
  .event_data_out_channel_halt (event_data_out_channel_halt)  // output wire         输出通道阻塞
);
```

### 3.2 输入数据格式 (s_axis_data_tdata)

`s_axis_data_tdata` 为 32 bit，小端序打包：

```
s_axis_data_tdata[31:0]
├── [15:0]  = XN_RE  （实部，16-bit 有符号补码）
└── [31:16] = XN_IM  （虚部，16-bit 有符号补码）
```

**纯实数输入（本项目 PCM 音频场景）**：

```verilog
s_axis_data_tdata = {16'h0000, pcm_sample[15:0]};
//                   ^^^^^^^^  ^^^^^^^^^^^^^^^^
//                   虚部=0     实部=PCM采样值
```

注意：实部在低 16 位，虚部在高 16 位。

### 3.3 输出数据格式 (m_axis_data_tdata)

`m_axis_data_tdata` 为 32 bit，格式与输入相同：

```
m_axis_data_tdata[31:0]
├── [15:0]  = XK_RE  （频域实部，16-bit 有符号补码）
└── [31:16] = XK_IM  （频域虚部，16-bit 有符号补码）
```

Scaled 模式下，输出位宽等于输入位宽（16 bit），因此 32-bit tdata 中的 Re/Im 各占完整的 16 bit，无需额外的位扩展或截断处理。

**频谱幅度计算**：

```
|X[k]| = sqrt(XK_RE^2 + XK_IM^2)
```

---

## 4. Config 通道配置字格式

### 4.1 s_axis_config_tdata 位域定义

本项目 IP 实例的 `s_axis_config_tdata` 总线宽度为 **16 bit**（由 XCI 参数 `C_S_AXIS_CONFIG_TDATA_WIDTH = 16` 确定）。

> **关键纠正**：phase2_fft_ip.md 中曾假设 config tdata 为 24 bit / SCALE_SCH 为 20 bit（10 级 x 2 bit）。
> 实际上，Pipelined Streaming 架构内部以 Radix-2 对为单位处理，1024 点 = **5 个缩放级**，
> SCALE_SCH 仅需 **10 bit**，加上 1 bit FWD_INV，共 11 bit 有效位，对齐到 16 bit (2 字节)。

位域定义如下：

| 位域 | 宽度 | 字段 | 说明 |
|------|------|------|------|
| bit[0] | 1 bit | FWD_INV | 1 = 正变换 (FFT)，0 = 逆变换 (IFFT) |
| bit[10:1] | 10 bit | SCALE_SCH | 缩放调度，5 级 x 每级 2 bit |
| bit[15:11] | 5 bit | （未使用） | 填零，综合时会被优化掉 |

### 4.2 配置字的打包方式

```
s_axis_config_tdata[15:0]
┌─────────────────┬──────────┬──────────┬──────────┬──────────┬──────────┬─────────┐
│  bit[15:11]     │ bit[10:9]│ bit[8:7] │ bit[6:5] │ bit[4:3] │ bit[2:1] │ bit[0]  │
│  未使用 (填零)  │  Stage 4 │  Stage 3 │  Stage 2 │  Stage 1 │  Stage 0 │ FWD_INV │
│  5'b00000       │  2'bXX   │  2'bXX   │  2'bXX   │  2'bXX   │  2'bXX   │  1'bX   │
└─────────────────┴──────────┴──────────┴──────────┴──────────┴──────────┴─────────┘
```

- **LSB 两位 [2:1]** 对应第一个 Radix-2 对（Stage 0，最前端的蝶形运算）
- **MSB 两位 [10:9]** 对应最后一个 Radix-2 对（Stage 4，最末端的蝶形运算）

### 4.3 本项目的配置字值

正变换 (FFT) 的配置字：

```verilog
// FWD_INV = 1 (正变换)
// SCALE_SCH = 10'b10_10_10_10_11
//   Stage 0: 2'b11 = 缩放 3 (右移 3 bit)  — 最前端级缩放最多
//   Stage 1: 2'b10 = 缩放 2 (右移 2 bit)
//   Stage 2: 2'b10 = 缩放 2 (右移 2 bit)
//   Stage 3: 2'b10 = 缩放 2 (右移 2 bit)
//   Stage 4: 2'b10 = 缩放 2 (右移 2 bit)
// 总缩放: 2^(3+2+2+2+2) = 2^11 = 2048 > 1024

localparam [15:0] FFT_CONFIG = {5'b00000, 10'b10_10_10_10_11, 1'b1};
// = 16'h0557
```

> 上述是 Xilinx 官方 demo testbench 中的默认推荐值。总缩放 2^11 = 2048，略大于 N=1024，
> 保证绝对不溢出，但会损失约 1 bit 的输出精度。

**备选保守方案（每级缩放 2，总缩放 = 2^10 = 1024 = N）**：

```verilog
localparam [15:0] FFT_CONFIG_ALT = {5'b00000, 10'b10_10_10_10_10, 1'b1};
// = 16'h0555
// 总缩放 = 2^(2+2+2+2+2) = 2^10 = 1024 = N
// 精度最优，但对满幅值信号有极小溢出风险
```

---

## 5. Scaling Schedule 详解

### 5.1 缩放级与 Radix-2 对的关系

Pipelined Streaming I/O 架构内部使用 Radix-2 蝶形单元，但以 **每两级 Radix-2** 为一组进行缩放控制（等效一级 Radix-4）：

| 缩放级 | 对应的 Radix-2 级 | SCALE_SCH 位域 | 最大位增长（无缩放时） |
|--------|-------------------|----------------|----------------------|
| Stage 0 | Radix-2 级 0, 1 | bit[2:1] | +2 bit |
| Stage 1 | Radix-2 级 2, 3 | bit[4:3] | +2 bit |
| Stage 2 | Radix-2 级 4, 5 | bit[6:5] | +2 bit |
| Stage 3 | Radix-2 级 6, 7 | bit[8:7] | +2 bit |
| Stage 4 | Radix-2 级 8, 9 | bit[10:9] | +2 bit |

### 5.2 每级 2-bit 编码含义

每个 2-bit 缩放值指定该级的右移位数：

| 编码 | 含义 | 缩放因子 | 说明 |
|------|------|----------|------|
| 2'b00 | 不缩放 | 1 | 保留全精度，但可能溢出 |
| 2'b01 | 右移 1 bit | 1/2 | 缩放因子 2 |
| 2'b10 | 右移 2 bit | 1/4 | 缩放因子 4，匹配 Radix-4 级的最大位增长 |
| 2'b11 | 右移 3 bit | 1/8 | 最大缩放，最安全但损失精度 |

### 5.3 推荐缩放调度策略

**策略 A：Xilinx 官方 demo 推荐（首级最大缩放）**

```
Stage 0 = 2'b11 (缩放 8)   — 首级信号幅值最大，缩放最多
Stage 1 = 2'b10 (缩放 4)
Stage 2 = 2'b10 (缩放 4)
Stage 3 = 2'b10 (缩放 4)
Stage 4 = 2'b10 (缩放 4)
总缩放 = 8 x 4 x 4 x 4 x 4 = 2048 = 2^11
SCALE_SCH = 10'b10_10_10_10_11
```

优点：绝对不溢出；缺点：比 1/N 多缩放一倍，损失约 1 bit 动态范围。

**策略 B：均匀缩放（总缩放 = N）**

```
Stage 0~4 均 = 2'b10 (缩放 4)
总缩放 = 4^5 = 1024 = N
SCALE_SCH = 10'b10_10_10_10_10
```

优点：精度最优（1/N 缩放，与 DFT 定义一致）；缺点：对接近满幅值的信号有极小溢出风险。

**策略 C：末级不缩放（保留末级精度）**

```
Stage 0 = 2'b11, Stage 1~3 = 2'b10, Stage 4 = 2'b01
总缩放 = 8 x 4 x 4 x 4 x 2 = 1024 = N
SCALE_SCH = 10'b01_10_10_10_11
```

优点：总缩放 = N 且首级有足够裕量。

**本项目建议**：使用策略 A（`SCALE_SCH = 10'b10_10_10_10_11`），优先保证不溢出。音频频谱分析对绝对精度要求不高，1 bit 精度损失可接受。

---

## 6. AXI-Stream 时序要求

### 6.1 基本握手规则

AXI4-Stream 握手遵循标准协议：

- **数据传输条件**：`tvalid = 1` 且 `tready = 1` 的时钟上升沿，完成一次传输
- **tvalid 规则**：主端口断言 tvalid 后，在 tready 回应之前 **不可撤回** tvalid，且 tdata 不可改变
- **tready 规则**：从端口可在任意时刻改变 tready（无需等待 tvalid）

### 6.2 Config 通道与 Data 通道的时序关系

**关键规则：Config 必须在对应帧的数据之前或同时到达。**

具体行为：

1. FFT IP 内部维护一个 config FIFO（深度有限）
2. 每帧处理开始时，IP 从 config FIFO 弹出一个配置字
3. 如果 config FIFO 为空，IP 将**阻塞**，不接受新的数据输入（`s_axis_data_tready` 保持低）
4. 因此，config 传输必须发生在数据传输之前（或在帧处理开始之前完成）

**推荐做法**：

```
时间线:  config_tvalid ──┐
                         ↓
         config 握手完成 (tvalid & tready)
                         ↓
         data_tvalid ────┐ 开始发送 1024 个数据点
                         ↓
         ...（1024 个握手周期）...
                         ↓
         data_tlast ─────┘ 最后一个数据点
```

**连续多帧处理**：

```
Frame 0:  [Config 0] [Data 0: 1024 samples] [Config 1] [Data 1: 1024 samples] ...
```

- 可以提前发送多个 config（IP 内部会缓存）
- 也可以在上一帧数据发送过程中发送下一帧的 config
- demo testbench 演示了 `AFTER_START` 模式：在 `event_frame_started` 信号之后发送下一帧的 config

### 6.3 Pipelined Streaming 下 tready 的行为

Non Real Time Throttle Scheme 下：

- **s_axis_data_tready**：
  - 当 IP 就绪接收数据时为高
  - 当 config FIFO 为空（等待配置）时为低
  - 当输出端被反压（m_axis_data_tready = 0 导致内部缓存满）时可能为低
  - Pipelined Streaming 架构下，正常工作时 tready 通常保持高电平

- **s_axis_config_tready**：
  - 当内部 config FIFO 未满时为高
  - 通常在发送 config 后很快握手成功

- **m_axis_data_tvalid**：
  - 当有有效输出数据时为高
  - 首帧输出有初始延迟（pipeline latency）

### 6.4 tlast 信号

**输入 tlast (s_axis_data_tlast)**：
- 必须在每帧最后一个数据（第 1024 个样本）的传输周期断言为高
- IP 通过 tlast 检测帧边界
- 如果 tlast 在非第 1024 个样本时断言 -> `event_tlast_unexpected` 事件
- 如果第 1024 个样本时 tlast 未断言 -> `event_tlast_missing` 事件
- **重要**：tlast 不直接控制帧边界。IP 内部通过计数来确定帧边界。tlast 仅用于一致性检查和事件生成

**输出 tlast (m_axis_data_tlast)**：
- IP 在输出帧的最后一个数据时自动断言 tlast
- 可用于下游模块检测帧结束

### 6.5 事件信号

| 信号 | 触发条件 | 建议处理 |
|------|----------|----------|
| event_frame_started | 每帧处理开始时脉冲 | 可用于计数帧数 |
| event_tlast_unexpected | 输入 tlast 在非帧末尾断言 | 检查数据源帧计数 |
| event_tlast_missing | 帧末尾未收到输入 tlast | 检查数据源帧计数 |
| event_status_channel_halt | 状态通道被阻塞 | 本设计无 status 通道，可忽略 |
| event_data_in_channel_halt | 输入数据通道阻塞导致处理暂停 | 检查上游数据源 |
| event_data_out_channel_halt | 输出数据通道阻塞导致处理暂停 | 检查下游是否反压 |

---

## 7. 仿真要点与常见问题

### 7.1 Pipeline Latency

Pipelined Streaming I/O 架构的延迟取决于多个因素：

- FFT 点数 (N)
- 是否启用 Natural Order 输出（需要额外的 reorder 缓存延迟）
- 数据传输速率（是否有反压暂停）

对于 1024 点、Natural Order 输出的 Pipelined Streaming 架构：
- **典型延迟**：约为 N 到 2N 个时钟周期（即约 1024~2048 个时钟周期），从第一个输入样本被接受到第一个输出样本出现
- Natural Order 输出会增加约 N 个时钟周期的延迟（reorder 缓存）
- 实际延迟值建议通过仿真实测确定

> 注意：PG109 文档未给出精确的延迟公式，而是建议通过仿真或使用 C 语言 bit-accurate 模型来确定具体延迟。

### 7.2 Xilinx FFT IP 行为模型的已知特性

1. **仿真模型类型**：Vivado 生成的仿真模型为 VHDL 行为模型，与综合后的 RTL 在功能上 bit-accurate
2. **仿真速度**：行为模型仿真较慢，尤其是大点数 FFT。建议限制仿真帧数
3. **初始状态**：无 aresetn 信号时，IP 在第一个时钟沿后即进入就绪状态
4. **X 值传播**：如果输入包含 X 或 Z 值，将传播到输出。确保所有输入信号在仿真开始时已初始化
5. **首帧延迟**：第一帧输出需要等待整个 pipeline 填满，后续帧可以连续输出

### 7.3 常见问题与排查

**Q1：输出全零或不变化**

- 检查 config 是否在数据之前成功发送（config_tvalid & config_tready 握手成功）
- 检查 m_axis_data_tready 是否保持高电平
- 检查 s_axis_data_tvalid 是否正确断言

**Q2：输出数据看起来不正确**

- 检查输入数据的 Re/Im 是否放在正确的位域（Re 在低 16 位，Im 在高 16 位）
- 检查 SCALE_SCH 配置是否合理（全零缩放会导致溢出回绕）
- 检查 FWD_INV 方向是否正确（1 = FFT，0 = IFFT）

**Q3：event_tlast_unexpected 或 event_tlast_missing**

- 确保 tlast 恰好在第 1024 个数据传输时（而非第 1023 个或第 1025 个）断言
- 注意 tlast 的断言时刻是在有效传输周期（tvalid & tready 都为高）

**Q4：s_axis_data_tready 持续为低**

- 检查是否已发送 config（IP 等待 config 才接受数据）
- 检查 m_axis_data_tready 是否为低导致输出阻塞反压到输入
- 检查时钟信号是否正常

**Q5：Scaled 模式下输出溢出（值突变/回绕）**

- 增大 SCALE_SCH 的缩放值（使用策略 A：首级 2'b11）
- 使用 `event_fft_overflow`（若启用 ovflo 选项）检测溢出

**Q6：第一帧 FFT 输出错误（奇谐波/幅度偏差），第二帧正常**

- 原因：Pipelined Streaming 架构的 FFT IP 上电后 config FIFO 存在一个 **phantom config slot**（默认/未初始化的配置）
- 表现：用户发送的第一个 config 被 phantom slot 挤到第二帧使用，第一帧数据使用了未知的默认配置（通常为无缩放），导致输出严重失真
- 验证方法：修改 SCALE_SCH 值后观察是否只有第二帧输出发生变化
- 解决方案：在正式数据帧之前，发送一个 **warm-up config + 零数据帧** 来消耗 phantom slot：
  ```verilog
  // Warm-up：消耗 phantom config slot
  send_config(FFT_FWD_CONFIG);
  send_frame(zero_data);  // 全零输入
  // 等待输出完成
  // 从此之后 config 和 data 帧 1:1 对齐
  ```
- 注意：Xilinx 官方 demo TB 的第一帧也未显式发送 config，而是依赖默认配置

**Q7：xsim 仿真中 FFT 行为模型与随机 tvalid gap 导致仿真引擎死循环**

- 现象：使用 `$urandom_range()` 控制 tvalid 间歇发送时，xsim 报 "Simulation engine not responding"
- 原因：随机 tvalid 翻转与 VHDL 行为模型的 delta cycle 机制交互异常
- 解决方案：改用确定性 gap 模式（如每 4 样本插入 2 个空闲周期），避免在 FFT 行为模型仿真中使用 `$urandom_range` 控制 tvalid

---

## 8. Testbench 编写指南

### 8.1 Verilog Testbench 基本框架

```verilog
`timescale 1ns / 1ps

module tb_fft_ip;

    // ============================================================
    // 参数定义
    // ============================================================
    localparam CLK_PERIOD   = 10;           // 100 MHz
    localparam FFT_N        = 1024;         // FFT 点数
    localparam DATA_WIDTH   = 16;           // 数据位宽

    // Config 字：FFT 正变换，首级缩放 3，其余缩放 2
    localparam [15:0] FFT_FWD_CONFIG = {5'b00000, 10'b10_10_10_10_11, 1'b1};

    // ============================================================
    // 信号声明
    // ============================================================
    reg         aclk = 0;

    // Config 通道
    reg  [15:0] s_axis_config_tdata  = 0;
    reg         s_axis_config_tvalid = 0;
    wire        s_axis_config_tready;

    // 数据输入通道
    reg  [31:0] s_axis_data_tdata  = 0;
    reg         s_axis_data_tvalid = 0;
    wire        s_axis_data_tready;
    reg         s_axis_data_tlast  = 0;

    // 数据输出通道
    wire [31:0] m_axis_data_tdata;
    wire        m_axis_data_tvalid;
    reg         m_axis_data_tready = 1;
    wire        m_axis_data_tlast;

    // 事件信号
    wire        event_frame_started;
    wire        event_tlast_unexpected;
    wire        event_tlast_missing;
    wire        event_status_channel_halt;
    wire        event_data_in_channel_halt;
    wire        event_data_out_channel_halt;

    // ============================================================
    // 时钟生成
    // ============================================================
    always #(CLK_PERIOD/2) aclk = ~aclk;

    // ============================================================
    // DUT 实例化
    // ============================================================
    xfft_0 u_fft (
        .aclk                        (aclk),
        .s_axis_config_tdata         (s_axis_config_tdata),
        .s_axis_config_tvalid        (s_axis_config_tvalid),
        .s_axis_config_tready        (s_axis_config_tready),
        .s_axis_data_tdata           (s_axis_data_tdata),
        .s_axis_data_tvalid          (s_axis_data_tvalid),
        .s_axis_data_tready          (s_axis_data_tready),
        .s_axis_data_tlast           (s_axis_data_tlast),
        .m_axis_data_tdata           (m_axis_data_tdata),
        .m_axis_data_tvalid          (m_axis_data_tvalid),
        .m_axis_data_tready          (m_axis_data_tready),
        .m_axis_data_tlast           (m_axis_data_tlast),
        .event_frame_started         (event_frame_started),
        .event_tlast_unexpected      (event_tlast_unexpected),
        .event_tlast_missing         (event_tlast_missing),
        .event_status_channel_halt   (event_status_channel_halt),
        .event_data_in_channel_halt  (event_data_in_channel_halt),
        .event_data_out_channel_halt (event_data_out_channel_halt)
    );

    // ============================================================
    // Task：发送 Config
    // ============================================================
    task send_config;
        input [15:0] config_word;
        begin
            @(posedge aclk);
            s_axis_config_tdata  <= config_word;
            s_axis_config_tvalid <= 1'b1;
            @(posedge aclk);
            while (!s_axis_config_tready) @(posedge aclk);
            // 握手成功（tvalid & tready 在时钟上升沿同时为高）
            s_axis_config_tvalid <= 1'b0;
            s_axis_config_tdata  <= 16'h0000;
        end
    endtask

    // ============================================================
    // Task：发送一帧数据（1024 点）
    // ============================================================
    task send_frame;
        input [DATA_WIDTH-1:0] data_re [0:FFT_N-1];  // 实部数组
        integer i;
        begin
            for (i = 0; i < FFT_N; i = i + 1) begin
                @(posedge aclk);
                s_axis_data_tdata  <= {16'h0000, data_re[i]};  // Im=0, Re=data
                s_axis_data_tvalid <= 1'b1;
                s_axis_data_tlast  <= (i == FFT_N - 1) ? 1'b1 : 1'b0;
                @(posedge aclk);
                while (!s_axis_data_tready) @(posedge aclk);
                // 握手成功
            end
            s_axis_data_tvalid <= 1'b0;
            s_axis_data_tlast  <= 1'b0;
        end
    endtask

    // ============================================================
    // Task：接收一帧输出数据
    // ============================================================
    integer out_count;
    reg signed [15:0] out_re [0:FFT_N-1];
    reg signed [15:0] out_im [0:FFT_N-1];

    task receive_frame;
        begin
            out_count = 0;
            while (out_count < FFT_N) begin
                @(posedge aclk);
                if (m_axis_data_tvalid && m_axis_data_tready) begin
                    out_re[out_count] = m_axis_data_tdata[15:0];
                    out_im[out_count] = m_axis_data_tdata[31:16];
                    out_count = out_count + 1;
                end
            end
        end
    endtask

    // ============================================================
    // 主测试流程
    // ============================================================
    reg signed [15:0] test_data [0:FFT_N-1];
    integer k;

    initial begin
        // 生成测试数据：单频正弦波，频率落在 bin 64
        for (k = 0; k < FFT_N; k = k + 1) begin
            // sin(2*pi*64*k/1024) 量化为 16-bit
            // 使用 $sin() 系统函数（部分仿真器支持）或预计算数据
            test_data[k] = $rtoi($sin(2.0 * 3.14159265 * 64.0 * $itor(k) / 1024.0) * 16383.0);
        end

        // 等待初始化
        #(CLK_PERIOD * 10);

        // Step 1: 发送配置
        send_config(FFT_FWD_CONFIG);

        // Step 2: 发送数据帧
        fork
            send_frame(test_data);
            receive_frame();
        join

        // Step 3: 分析结果
        $display("=== FFT Output (first 128 bins) ===");
        for (k = 0; k < 128; k = k + 1) begin
            $display("Bin[%4d]: Re=%6d, Im=%6d", k, out_re[k], out_im[k]);
        end

        #(CLK_PERIOD * 100);
        $display("Simulation PASSED");
        $finish;
    end

endmodule
```

### 8.2 AXI-Stream 握手的正确写法

**错误写法**（可能丢失数据）：

```verilog
// 错误：没有等待 tready
@(posedge aclk);
s_axis_data_tdata <= data;
s_axis_data_tvalid <= 1'b1;
@(posedge aclk);
s_axis_data_tvalid <= 1'b0;  // 如果 tready 为低，数据丢失！
```

**正确写法**：

```verilog
// 正确：等待握手完成
@(posedge aclk);
s_axis_data_tdata  <= data;
s_axis_data_tvalid <= 1'b1;
s_axis_data_tlast  <= last;
// 等待 tready（握手发生在 tvalid & tready 同时为高的时钟上升沿）
do begin
    @(posedge aclk);
end while (!s_axis_data_tready);
// 此时握手已完成，可以更新或撤回 tvalid
s_axis_data_tvalid <= 1'b0;
```

### 8.3 Config 先于 Data 的时序保证

```verilog
initial begin
    // 先发送 config
    send_config(FFT_FWD_CONFIG);
    // 等待 1~2 个周期（可选，确保 config 已被 IP 锁存）
    @(posedge aclk);
    // 再发送 data
    send_frame(test_data);
end
```

### 8.4 连续多帧处理

```verilog
initial begin
    // 可以提前发送多个 config（IP 内部 FIFO 缓存）
    send_config(FFT_FWD_CONFIG);  // Frame 0 的配置
    send_config(FFT_FWD_CONFIG);  // Frame 1 的配置

    // 连续发送多帧数据，帧间无间隔
    send_frame(test_data_0);      // Frame 0
    send_frame(test_data_1);      // Frame 1
end
```

### 8.5 带反压测试的输出接收

```verilog
// 模拟下游模块偶尔不就绪
always @(posedge aclk) begin
    if ($urandom_range(0, 3) == 0)
        m_axis_data_tready <= 1'b0;  // 25% 概率反压
    else
        m_axis_data_tready <= 1'b1;
end
```

### 8.6 使用 $readmemh 加载测试数据

```verilog
reg signed [15:0] test_data [0:1023];

initial begin
    $readmemh("test_sine_1024.hex", test_data);
end
```

对应的 hex 文件每行一个 16-bit 十六进制值（有符号补码表示）。

---

## 附录 A：Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────┐
│                    FFT IP Quick Reference                       │
├─────────────────────────────────────────────────────────────────┤
│ Config tdata (16 bit):                                          │
│   [0]     = FWD_INV  (1=FFT, 0=IFFT)                          │
│   [10:1]  = SCALE_SCH (5 stages x 2 bit)                      │
│   [15:11] = unused (tie to 0)                                   │
│                                                                 │
│ 推荐 config (FFT, 防溢出):  16'h0557                           │
│   = {5'b0, 2'b10, 2'b10, 2'b10, 2'b10, 2'b11, 1'b1}          │
│                                                                 │
│ Data tdata (32 bit):                                            │
│   [15:0]  = Re (实部, signed 16-bit)                           │
│   [31:16] = Im (虚部, signed 16-bit)                           │
│                                                                 │
│ 纯实数输入:  tdata = {16'h0000, pcm_sample}                    │
│                                                                 │
│ 帧长度: 1024 samples                                           │
│ tlast:  在第 1024 个有效传输时置高                               │
│ Config: 必须在帧数据之前发送                                     │
└─────────────────────────────────────────────────────────────────┘
```

## 附录 B：与 phase2_fft_ip.md 的差异说明

phase2_fft_ip.md 中关于 config tdata 的描述存在以下需要修正的内容：

| 项目 | phase2_fft_ip.md 原始描述 | 实际值（本文档） | 依据 |
|------|--------------------------|-----------------|------|
| config tdata 位宽 | 24 bit | **16 bit** | XCI: C_S_AXIS_CONFIG_TDATA_WIDTH=16, VEO: [15:0] |
| SCALE_SCH 位宽 | 20 bit (10 级 x 2 bit) | **10 bit** (5 级 x 2 bit) | Demo TB: scale_sch(9 downto 0), Pipelined Streaming 以 Radix-2 对为缩放单位 |
| SCALE_SCH 位域 | bit[20:1] | **bit[10:1]** | Demo TB: s_axis_config_tdata(10 downto 1) |
| 缩放级数 | 10 级 | **5 级** | 1024 点 Pipelined Streaming = 5 对 Radix-2 |
| 推荐 SCALE_SCH | 20'b10_10_10_10_10_10_10_10_10_10 | **10'b10_10_10_10_11** | Xilinx 官方 demo TB 默认值 |

---

## 参考资料

- [PG109 - Fast Fourier Transform v9.1 LogiCORE IP Product Guide (PDF)](https://www.xilinx.com/support/documents/ip_documentation/xfft/v9_1/pg109-xfft.pdf)
- [PG109 - Fast Fourier Transform (AMD Docs Portal)](https://docs.amd.com/r/en-US/pg109-xfft)
- [Performance and Resource Utilization for Fast Fourier Transform v9.1](https://www.xilinx.com/html_docs/ip_docs/pru_files/xfft.html)
- [FFT IP Pipeline Latency Discussion (Xilinx Support)](https://support.xilinx.com/s/question/0D52E00006iHqS2SAK/fft-ip-pipeline-latency)
- [The Use of Xilinx FFT IP Core (Medium)](https://medium.com/@pqshedy33/the-use-of-xilinx-fft-ip-core-a5ad88e01a4b)
- [FFT v8.0 AXI with Scaled Output (Blog)](http://myfpgablog.blogspot.com/2011/03/fft-v80-axi-with-scaled-output.html)
- Xilinx 官方 Demo Testbench: `tb_xfft_0.vhd`（随 IP 生成，位于 `demo_tb/` 目录）
