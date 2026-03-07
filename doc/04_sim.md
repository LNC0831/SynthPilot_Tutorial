# 任务书：通用IIC收发器设计与仿真验证

## 一、任务概述

使用 Verilog 语言设计一套完整的 IIC（I2C）主机与从机收发器模块，并通过闭环仿真验证全部事务类型的正确性。设计完成后输出设计文档。

## 二、参考手册

本设计遵循以下 I2C 总线规范，实现其 Standard Mode（100 kbps）、7-bit 地址、单主机子集：

> [1] NXP Semiconductors, *"I2C-bus specification and user manual"*, UM10204 Rev.7.0, October 2021.
>
> [2] Philips Semiconductors, *"The I2C-bus and how to use it (including specifications)"*, April 1995.

**手册本地路径：**

| 文献编号 | 本地路径                                                |
| -------- | ------------------------------------------------------- |
| [1]      | `F:\synthpilot_tutorial\doc\UM10204.pdf`                |
| [2]      | `F:\synthpilot_tutorial\doc\i2c_bus_specification_1995.pdf` |

## 三、协议规格

| 参数         | 规格                      |
| ------------ | ------------------------- |
| 速率模式     | Standard Mode（100 kbps） |
| 系统时钟     | 100 MHz                   |
| 数据位宽     | 8 bit（固定）             |
| 地址位宽     | 7 bit                     |
| 总线拓扑     | 单主机                    |
| 时钟拉伸     | 从机侧支持（clock stretching），主机侧需正确检测并等待 |
| 多主机仲裁   | 不支持                    |

> **关于时钟拉伸的说明：** 时钟拉伸（Clock Stretching）是 I2C 协议的标准特性——当从机来不及处理数据时，可以主动拉低 SCL 使主机暂停，直到从机准备就绪后释放 SCL。从机模块应在需要准备数据时拉低 SCL；主机模块应在释放 SCL 后检测 SCL 实际电平，若被拉低则等待，不继续驱动时钟。此功能可保证不同处理速度的从机都能可靠通信。

## 四、模块架构

设计为两个独立模块：`i2c_master` 和 `i2c_slave`。

### 4.1 i2c_master — 主机模块

**参数：**

| 参数名       | 默认值   | 说明                             |
| ------------ | -------- | -------------------------------- |
| CLK_FREQ     | 100_000_000 | 系统时钟频率（Hz）            |
| SCL_FREQ     | 100_000  | SCL 时钟频率（Hz）               |

**用户侧接口（AXI-Stream 风格握手）：**

| 信号名     | 方向   | 位宽 | 说明                                         |
| ---------- | ------ | ---- | -------------------------------------------- |
| clk        | input  | 1    | 系统时钟                                     |
| rst_n      | input  | 1    | 异步复位，低有效                             |
| cmd_valid  | input  | 1    | 命令有效                                     |
| cmd_ready  | output | 1    | 命令握手就绪                                 |
| cmd_rw     | input  | 1    | 0=写，1=读                                   |
| cmd_addr   | input  | 7    | 目标从机地址                                 |
| cmd_len    | input  | 8    | 传输字节数（1~256，0表示256）                |
| tx_data    | input  | 8    | 发送数据                                     |
| tx_valid   | input  | 1    | 发送数据有效                                 |
| tx_ready   | output | 1    | 发送数据握手就绪                             |
| rx_data    | output | 8    | 接收数据                                     |
| rx_valid   | output | 1    | 接收数据有效                                 |
| rx_ready   | input  | 1    | 接收数据握手就绪                             |
| busy       | output | 1    | 总线忙指示                                   |
| nack_error | output | 1    | 从机无应答错误指示（脉冲）                   |

**I2C 物理侧接口（三态拆分）：**

| 信号名   | 方向   | 位宽 | 说明                        |
| -------- | ------ | ---- | --------------------------- |
| scl_o    | output | 1    | SCL 输出（低有效驱动）      |
| scl_oen  | output | 1    | SCL 输出使能（0=驱动，1=释放） |
| scl_i    | input  | 1    | SCL 输入采样                |
| sda_o    | output | 1    | SDA 输出（低有效驱动）      |
| sda_oen  | output | 1    | SDA 输出使能（0=驱动，1=释放） |
| sda_i    | input  | 1    | SDA 输入采样                |

### 4.2 i2c_slave — 从机模块

**参数：**

| 参数名       | 默认值   | 说明               |
| ------------ | -------- | ------------------ |
| SLAVE_ADDR   | 7'h50    | 本机从机地址       |

**用户侧接口（AXI-Stream 风格握手）：**

| 信号名     | 方向   | 位宽 | 说明                                     |
| ---------- | ------ | ---- | ---------------------------------------- |
| clk        | input  | 1    | 系统时钟                                 |
| rst_n      | input  | 1    | 异步复位，低有效                         |
| rx_data    | output | 8    | 从主机接收的数据                         |
| rx_valid   | output | 1    | 接收数据有效                             |
| rx_ready   | input  | 1    | 接收数据握手就绪                         |
| tx_data    | input  | 8    | 待发送给主机的数据                       |
| tx_valid   | input  | 1    | 发送数据有效                             |
| tx_ready   | output | 1    | 发送数据握手就绪                         |
| start_det  | output | 1    | 检测到 START/Repeated START（脉冲）      |
| stop_det   | output | 1    | 检测到 STOP（脉冲）                      |
| addr_match | output | 1    | 地址匹配指示                             |
| rw_bit     | output | 1    | 当前事务方向（0=写，1=读）               |

**I2C 物理侧接口：** 与主机相同的三态拆分方式（scl_o/scl_oen/scl_i, sda_o/sda_oen/sda_i）。

### 4.3 Testbench 中的总线建模

在 testbench 中使用线与（wired-AND）模型连接主从模块：

```verilog
// 开漏总线模型
wire scl_bus = (m_scl_oen ? 1'b1 : m_scl_o) & (s_scl_oen ? 1'b1 : s_scl_o);
wire sda_bus = (m_sda_oen ? 1'b1 : m_sda_o) & (s_sda_oen ? 1'b1 : s_sda_o);

// 回连至各模块的输入端
assign m_scl_i = scl_bus;
assign s_scl_i = scl_bus;
assign m_sda_i = sda_bus;
assign s_sda_i = sda_bus;
```

## 五、支持的事务类型

| 编号 | 事务类型            | 时序描述                                             |
| ---- | ------------------- | ---------------------------------------------------- |
| T1   | 单字节写            | START → ADDR+W → ACK → DATA(1B) → ACK → STOP       |
| T2   | 单字节读            | START → ADDR+R → ACK → DATA(1B) → NACK → STOP      |
| T3   | 多字节连续写        | START → ADDR+W → ACK → DATA(nB,每字节ACK) → STOP   |
| T4   | 多字节连续读        | START → ADDR+R → ACK → DATA(nB,末字节NACK) → STOP  |
| T5   | 复合读写（Repeated START） | START → ADDR+W → ACK → REG_ADDR → ACK → **Sr** → ADDR+R → ACK → DATA → NACK → STOP |
| T6   | 地址不匹配（NACK）  | START → ADDR(错误)+W → **NACK** → STOP              |

## 六、仿真验证 Checklist

Testbench 需例化一个 `i2c_master`（地址由命令指定）和一个 `i2c_slave`（SLAVE_ADDR=7'h50），对以下场景逐项验证并自动判定 PASS/FAIL：

| 编号   | 测试场景                       | 通过条件                                                   |
| ------ | ------------------------------ | ---------------------------------------------------------- |
| TC-01  | 单字节写                       | 从机 rx_data 接收值与主机发送值一致                        |
| TC-02  | 单字节读                       | 主机 rx_data 接收值与从机预装数据一致                      |
| TC-03  | 多字节连续写（4 字节）         | 从机连续接收的 4 字节均正确                                |
| TC-04  | 多字节连续读（4 字节）         | 主机连续接收的 4 字节均正确，且末字节后从机收到 NACK       |
| TC-05  | 复合读写（先写寄存器地址再读） | 从机先接收寄存器地址，再正确返回对应数据                   |
| TC-06  | 地址不匹配                     | 主机检测到 nack_error，事务正确终止                        |
| TC-07  | 背靠背连续事务                 | 连续发起 3 笔写事务，每笔均正确完成，无总线挂死           |
| TC-08  | 总线空闲检测                   | STOP 之后 busy 信号正确拉低，总线回到空闲态               |

**Testbench 输出要求：**
- 每个测试用例打印 `[PASS] TC-xx: 描述` 或 `[FAIL] TC-xx: 描述 — 期望值=xx, 实际值=xx`
- 全部完成后打印汇总：`=== x/8 PASSED ===`
- 使用 `$dumpfile` / `$dumpvars` 生成波形文件，以便 Vivado 查看

## 七、设计文档要求

设计完成后，在 `F:\synthpilot_tutorial\doc` 目录下生成设计文档，内容应包含：

1. 模块功能概述
2. 顶层架构框图（主/从模块关系、总线连接）
3. 接口信号说明表（与本任务书一致）
4. 主机/从机核心状态机描述（状态转移图或表格）
5. 关键时序说明（START/STOP 条件生成、SCL 时钟分频、数据采样时机）
6. 仿真结果（Testbench 的 PASS/FAIL 日志 + 关键波形截图）

## 八、项目管理

### 8.1 目录结构

在 `F:\synthpilot_tutorial\prj\02` 下创建：

```
02/
├── prj/          ← Vivado 工程
├── rtl/          ← RTL 源码
│   ├── i2c_master.v
│   └── i2c_slave.v
└── sim/          ← 仿真文件
    └── tb_i2c_top.v
```

### 8.2 Vivado 工程

- 工程路径：`F:\synthpilot_tutorial\prj\02\prj`
- 工程名称：demo02
- 芯片型号：XC7Z010-1CLG400I

### 8.3 设计约束

本任务为纯仿真验证，不做综合与实现，无需约束文件。
