# Phase 1：Block Design — XDMA + FIFO

> 所属项目：XDMA + FFT 音乐频谱分析仪
> 前置依赖：无
> 后续阶段：Phase 2（FFT IP 配置与仿真）
> **状态：✅ 已完成（2026-03-31）**

## 一、目标

创建 Vivado 工程，搭建包含 XDMA IP 和跨时钟域 AXI4-Stream FIFO 的 Block Design，生成输出产物与 HDL Wrapper，为后续顶层 RTL 集成提供子系统模块。

## 二、工程创建

| 配置项 | 值 |
|--------|-----|
| 工程名 | fft_spectrum |
| 工程路径 | `F:\synthpilot_tutorial\prj\04\prj\fft_spectrum` |
| 目标器件 | xcku3p-ffvb676-2-e |
| 工程类型 | RTL Project |

同时创建项目目录结构：

```
prj/04/
├── prj/          ← Vivado 工程
├── rtl/          ← 自定义 RTL
├── sim/          ← 仿真文件
└── host/         ← Python 上位机（后续阶段）
```

## 三、时钟域架构

本 BD 涉及两个时钟域，通过 AXI4-Stream FIFO 完成跨时钟域传递：

| 时钟域 | 时钟源 | 频率 | 使用范围 |
|--------|--------|------|----------|
| axi_aclk | XDMA IP 输出 | ~250 MHz（由 PCIe 衍生） | 仅 XDMA 自身的 AXI 总线，不引出 BD |
| clk_100m | Clock Wizard 输出（BD 外部传入） | 100 MHz | BD 外部所有用户逻辑（FFT、magnitude_calc 等） |

```
  axi_aclk 域（BD 内部）          clk_100m 域（BD 外部）
 ┌──────────────────┐           ┌─────────────────────────┐
 │  XDMA H2C 输出   │──►CDC FIFO──►│  FFT → mag_calc        │
 │  XDMA C2H 输入   │◄──CDC FIFO◄──│  mag_calc 输出          │
 └──────────────────┘           └─────────────────────────┘
```

> **axi_aclk 不引出**：XDMA 的 AXI 时钟封闭在 BD 内部，外部无需感知其频率。BD 引出的 AXI-Stream 接口（m_axis_h2c、s_axis_c2h）均工作在 clk_100m 域。

## 四、Block Design 搭建

BD 名称：`xdma_subsystem`

### 4.1 XDMA IP 配置

| 配置项 | 值 | 说明 |
|--------|-----|------|
| PCIe Block Location | 在 Vivado 中确认可选值后指定 | KU3P ffvb676 封装可用位置有限，需在 IP 配置界面确认 |
| Lane Width | x4 | 4 Lane |
| Maximum Link Speed | 8.0 GT/s (Gen3) | PCIe Gen3 |
| AXI Interface | AXI4-Stream | 非 AXI4-MM |
| DMA H2C Channels | 1 | Host-to-Card |
| DMA C2H Channels | 1 | Card-to-Host |
| AXI Data Width | 128-bit | Gen3 x4 下 XDMA AXI-S 位宽由 lane width 决定，x4 对应 128-bit |

> **关于 AXI 数据位宽**：XDMA 在 AXI4-Stream 模式下，数据位宽由 PCIe lane width 决定（x1=64b, x2=64b, x4=128b, x8=256b）。Gen3 x4 对应 128-bit，即每个 AXI-Stream beat 传输 16 bytes。

### 4.2 Input FIFO（H2C 方向，CDC）

使用 AXI4-Stream Data FIFO IP，**Independent Clock 模式**，完成 axi_aclk → clk_100m 跨时钟域传递。

| 配置项 | 值 | 说明 |
|--------|-----|------|
| Clock Mode | **Independent Clocks** | 跨时钟域 |
| FIFO Depth | 256 | 128-bit words；256 × 16B = 4KB |
| TDATA Width | 128-bit | 与 XDMA H2C 输出一致 |
| 有无 TLAST | 有 | 帧边界传递 |
| 有无 TKEEP | 有 | 16-byte，tkeep[15:0] |

时钟与复位连接：

| 端口 | 连接 | 说明 |
|------|------|------|
| s_axis_aclk | axi_aclk（XDMA 输出） | 写侧时钟 |
| s_axis_aresetn | axi_aresetn（XDMA 输出） | 写侧复位 |
| m_axis_aclk | clk_100m（外部传入） | 读侧时钟 |
| m_axis_aresetn | clk_100m_locked（外部传入） | 读侧复位，locked 直接接 aresetn |

### 4.3 Output FIFO（C2H 方向，CDC）

使用 AXI4-Stream Data FIFO IP，**Independent Clock 模式**，完成 clk_100m → axi_aclk 跨时钟域传递。

| 配置项 | 值 | 说明 |
|--------|-----|------|
| Clock Mode | **Independent Clocks** | 跨时钟域 |
| FIFO Depth | 256 | 128-bit words |
| TDATA Width | 128-bit | 与 XDMA C2H 输入一致 |
| 有无 TLAST | 有 | 帧边界传递 |
| 有无 TKEEP | 有 | |

时钟与复位连接：

| 端口 | 连接 | 说明 |
|------|------|------|
| s_axis_aclk | clk_100m（外部传入） | 写侧时钟 |
| s_axis_aresetn | clk_100m_locked（外部传入） | 写侧复位 |
| m_axis_aclk | axi_aclk（XDMA 输出） | 读侧时钟 |
| m_axis_aresetn | axi_aresetn（XDMA 输出） | 读侧复位 |

### 4.4 usr_irq_req 处理

XDMA IP 的 `usr_irq_req` 输入端口未使用，在 BD 中使用 Constant IP 将其连接为 0。

## 五、BD 端口引出

### 5.1 端口总表

| 端口名 | 方向 | 时钟域 | 说明 |
|--------|------|--------|------|
| pcie_mgt_rxp[3:0] | input | — | PCIe GT 接收正端 |
| pcie_mgt_rxn[3:0] | input | — | PCIe GT 接收负端 |
| pcie_mgt_txp[3:0] | output | — | PCIe GT 发送正端 |
| pcie_mgt_txn[3:0] | output | — | PCIe GT 发送负端 |
| pcie_refclk_clk_p | input | — | PCIe 参考时钟正端 |
| pcie_refclk_clk_n | input | — | PCIe 参考时钟负端 |
| pcie_perstn | input | — | PCIe 复位，低有效 |
| clk_100m | input | clk_100m | 用户时钟 100 MHz，从 Clock Wizard 输出接入 |
| clk_100m_locked | input | — | Clock Wizard locked 信号，直接接 FIFO 的 aresetn（locked=1 正常，locked=0 复位） |
| user_lnk_up | output | — | XDMA PCIe link up 指示，供顶层驱动 LED |

### 5.2 AXI4-Stream 端口（均在 clk_100m 域）

**m_axis_h2c（BD 输出，H2C 方向）**：

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| m_axis_h2c_tdata | [127:0] | output | 数据 |
| m_axis_h2c_tkeep | [15:0] | output | 字节有效标记 |
| m_axis_h2c_tlast | 1 | output | 帧尾标记 |
| m_axis_h2c_tvalid | 1 | output | 数据有效 |
| m_axis_h2c_tready | 1 | input | 下游就绪 |

**s_axis_c2h（BD 输入，C2H 方向）**：

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| s_axis_c2h_tdata | [127:0] | input | 数据 |
| s_axis_c2h_tkeep | [15:0] | input | 字节有效标记 |
| s_axis_c2h_tlast | 1 | input | 帧尾标记 |
| s_axis_c2h_tvalid | 1 | input | 数据有效 |
| s_axis_c2h_tready | 1 | output | BD 就绪 |

> **所有 AXI-Stream 端口均工作在 clk_100m 时钟域**，位宽适配（128→32 和 16→128）在顶层 RTL 中完成。

## 六、BD 内部连接关系

```
                      xdma_subsystem (Block Design)
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  clk_100m ─────────────────────┐              ┌──────────────────── │
│  clk_100m_locked ──────────────┤              │                     │
│                                │              │                     │
│                          ┌─────▼──────┐       │                     │
│  pcie_mgt ◄──►┌────────┐│ Input FIFO ├───────┼──► m_axis_h2c      │
│  pcie_refclk─►│  XDMA  ││ (CDC)      │       │    (clk_100m域)     │
│  pcie_perstn─►│        │└────────────┘       │                     │
│               │        │  axi_aclk ──────┐   │                     │
│               │        │  axi_aresetn ───┤   │                     │
│               │        │              ┌──▼───▼──┐                  │
│               │  C2H   │◄─────────────│Out FIFO │◄── s_axis_c2h   │
│               │  入口   │              │ (CDC)   │    (clk_100m域)  │
│               └────────┘              └─────────┘                  │
│                                                                     │
│  [Constant=0] ──► usr_irq_req                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## 七、生成输出产物

1. **验证 BD 设计**：运行 Validate Design，确保无 Error
2. **生成输出产物**：Generate Output Products（Global 模式）
3. **生成 HDL Wrapper**：Create HDL Wrapper（Let Vivado manage wrapper）

生成后的 Wrapper 文件将作为顶层 RTL 中的一个子模块被例化。

## 八、验证标准

| 编号 | 验证项 | 通过条件 | 结果 |
|------|--------|----------|------|
| P1-01 | BD 验证 | Validate Design 无 Error | ✅ |
| P1-02 | 输出产物生成 | Generate Output Products 成功 | ✅ |
| P1-03 | Wrapper 生成 | HDL Wrapper 文件存在且语法正确 | ✅ |
| P1-04 | XDMA 配置 | Gen3 x4，AXI4-Stream，1H2C + 1C2H，128-bit，MSI-X，cfg_mgmt 禁用 | ✅ |
| P1-05 | FIFO 配置 | Independent Clock 模式，深度 256，TLAST/TKEEP 使能 | ✅ |
| P1-06 | 时钟连接 | FIFO 写/读侧时钟与复位连接正确（axi_aclk ↔ clk_100m） | ✅ |
| P1-07 | 端口引出 | m_axis_h2c、s_axis_c2h 接口方式引出，clk_100m 域，pcie_refclk 差分接口 | ✅ |
| P1-08 | usr_irq_req | 悬空（MSI-X 中断，无需常量驱动） | ✅ |
