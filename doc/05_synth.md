# 任务书：多时钟域数据采集与串口输出系统

## 一、任务概述

使用 Verilog 语言设计一套多时钟域数据采集与串口输出系统。系统包含快时钟（200 MHz）数据采集前端、异步 FIFO 跨时钟域桥接、以及慢时钟（50 MHz）UART 串口发送后端。

## 二、系统架构

```
                    ┌──────────────────────────────────────────────────┐
                    │            sampler_uart_top                      │
                    │                                                  │
 clk_fast(200MHz)──►│  ┌──────────────┐    ┌────────────┐             │
                    │  │ data_sampler  │───►│ async_fifo  │            │
 rst_n ────────────►│  │  (200MHz域)   │    │ (跨时钟域)  │            │
                    │  └──────────────┘    └─────┬──────┘            │
                    │                            │                    │
  clk_sys(50MHz)───►│                      ┌─────▼──────┐            │
                    │                      │  uart_tx    │───► tx_out │
                    │                      │  (50MHz域)  │            │
                    │                      └────────────┘            │
                    └──────────────────────────────────────────────────┘
```

数据流：`data_sampler` 在 200 MHz 时钟域产生采样数据，写入异步 FIFO；`uart_tx` 在 50 MHz 时钟域从 FIFO 读取数据，按 UART 协议串行发送。

## 三、模块设计

### 3.1 sampler_uart_top — 顶层模块

将三个子模块连接，并对外暴露时钟、复位与 UART 输出。

**参数：**

| 参数名       | 默认值      | 说明                     |
| ------------ | ----------- | ------------------------ |
| DATA_WIDTH   | 8           | 数据位宽                 |
| BAUD_RATE    | 115200      | UART 波特率              |
| CLK_SYS_FREQ | 50_000_000 | 系统时钟频率（Hz）       |

**端口：**

| 信号名   | 方向   | 位宽 | 说明                           |
| -------- | ------ | ---- | ------------------------------ |
| clk_fast | input  | 1    | 快时钟，200 MHz                |
| clk_sys  | input  | 1    | 系统时钟，50 MHz               |
| rst_n    | input  | 1    | 全局异步复位，低有效           |
| tx_out   | output | 1    | UART 串行数据输出              |
| fifo_full| output | 1    | FIFO 满指示（调试用）          |
| fifo_empty| output| 1    | FIFO 空指示（调试用）          |

### 3.2 data_sampler — 数据采集模块

工作在 200 MHz 时钟域。内部维护一个递增计数器作为模拟采样数据源。当 FIFO 未满时，以可控速率将数据写入 FIFO。

**参数：**

| 参数名      | 默认值 | 说明                               |
| ----------- | ------ | ---------------------------------- |
| DATA_WIDTH  | 8      | 输出数据位宽                       |
| SAMPLE_DIV  | 20000  | 采样分频系数（每 N 个时钟产生一笔） |

**端口：**

| 信号名     | 方向   | 位宽       | 说明                         |
| ---------- | ------ | ---------- | ---------------------------- |
| clk        | input  | 1          | 200 MHz 时钟                 |
| rst_n      | input  | 1          | 异步复位，低有效             |
| data_out   | output | DATA_WIDTH | 采样数据输出                 |
| data_valid | output | 1          | 数据有效指示                 |
| fifo_full  | input  | 1          | FIFO 满信号（反压）          |

**功能描述：**
- 内部分频计数器每 `SAMPLE_DIV` 个时钟周期产生一次数据
- 数据为 8-bit 递增计数器值（0x00 ~ 0xFF 循环），串口输出形如 `00 01 02 ... FE FF 00 01 ...`，接收端通过观察数值是否连续递增即可判断数据完整性
- 当 `fifo_full` 为高时暂停产生数据（反压机制）
- `data_valid` 仅在产生有效数据且 FIFO 未满时拉高一个时钟周期

**`SAMPLE_DIV` 取值说明：**

UART 115200 baud、8N1 格式下，每字节需 10 bit，理论吞吐量为 115200 / 10 = 11520 字节/秒，即每字节约 86.8 μs。在 200 MHz 时钟下对应约 17361 个时钟周期。`SAMPLE_DIV` 取 20000（对应每笔间隔 100 μs，即 10000 字节/秒）略低于 UART 吞吐上限，确保 FIFO 不会被填满，串口输出连续无断裂。

### 3.3 异步 FIFO — Xilinx FIFO Generator IP

跨时钟域 FIFO，写端工作在 `clk_fast`（200 MHz），读端工作在 `clk_sys`（50 MHz）。不手写 RTL，使用 SynthPilot MCP 工具配置一个 Xilinx FIFO Generator IP，配置要求如下：

| 配置项       | 值           | 说明                           |
| ------------ | ------------ | ------------------------------ |
| IP 实例名    | async_fifo   |                                |
| 数据位宽     | 8            | 与 data_sampler 输出一致       |
| 深度         | 16           | 教程演示用，无需太大           |
| 异步模式     | 是           | 写时钟 200 MHz，读时钟 50 MHz  |
| 读模式       | First Word Fall Through | 便于与下游握手逻辑对接 |
| 存储类型     | Block RAM    | 默认即可                       |

IP 生成后，其典型端口为 `wr_clk`、`rd_clk`、`din`、`wr_en`、`full`、`dout`、`rd_en`、`empty` 等，顶层例化时按实际生成的端口连接。

### 3.4 uart_tx — UART 发送模块

工作在 50 MHz 时钟域。从 FIFO 读取数据，按标准 UART 协议（8N1）串行发送。

**参数：**

| 参数名    | 默认值      | 说明               |
| --------- | ----------- | ------------------ |
| CLK_FREQ  | 50_000_000  | 系统时钟频率（Hz） |
| BAUD_RATE | 115200      | 波特率             |

**端口：**

| 信号名     | 方向   | 位宽 | 说明                           |
| ---------- | ------ | ---- | ------------------------------ |
| clk        | input  | 1    | 50 MHz 时钟                    |
| rst_n      | input  | 1    | 异步复位，低有效               |
| tx_data    | input  | 8    | 待发送数据                     |
| tx_valid   | input  | 1    | 数据有效（握手信号）           |
| tx_ready   | output | 1    | 发送器就绪（握手信号）         |
| tx_out     | output | 1    | UART 串行输出（空闲态为高）    |

**功能描述：**
- 空闲时 `tx_out` 保持高电平，`tx_ready` 为高
- 当 `tx_valid` 与 `tx_ready` 同时为高时，锁存数据并开始发送
- 发送帧格式：1 起始位（低）+ 8 数据位（LSB first）+ 1 停止位（高）
- 内部波特率分频计数器从系统时钟分频产生 bit 时钟
- 发送过程中 `tx_ready` 拉低，发送完成后恢复

## 四、顶层连接逻辑

顶层模块 `sampler_uart_top` 的内部连接关系：

```
data_sampler.data_out   ──► async_fifo.din
data_sampler.data_valid ──► async_fifo.wr_en
async_fifo.full         ──► data_sampler.fifo_full

async_fifo.dout         ──► uart_tx.tx_data
async_fifo.empty        ──►（取反后）──► uart_tx.tx_valid
uart_tx.tx_ready        ──► async_fifo.rd_en
```

读端握手逻辑：FIFO 非空时将数据送入 UART 发送器，需正确处理 FIFO 读使能与 UART 握手的配合，避免对空 FIFO 发起读操作。

## 五、项目管理

### 5.1 目录结构

在 `F:\synthpilot_tutorial\prj\03` 下创建：

```
03/
├── prj/          ← Vivado 工程
├── rtl/          ← RTL 源码
│   ├── sampler_uart_top.v
│   ├── data_sampler.v
│   （async_fifo 由 Xilinx FIFO Generator IP 提供，无需手写 RTL）
│   └── uart_tx.v
└── sim/          ← 仿真文件
    └── tb_sampler_uart_top.v
```

### 5.2 Vivado 工程

- 工程路径：`F:\synthpilot_tutorial\prj\03\prj`
- 工程名称：demo03
- 芯片型号：XC7Z010-1CLG400I

### 5.3 设计文档

设计完成后，在 `F:\synthpilot_tutorial\doc` 目录下生成设计文档，内容应包含：

1. 模块功能概述
2. 顶层架构框图
3. 接口信号说明表（与本任务书一致）
4. 异步 FIFO IP 配置说明与例化方式
5. UART 发送状态机描述
