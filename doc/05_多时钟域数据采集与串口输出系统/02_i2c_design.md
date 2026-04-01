# I2C Master/Slave 收发器设计文档

## 1. 模块功能概述

本设计实现了一套完整的 I2C（Inter-Integrated Circuit）主机与从机收发器模块，遵循 NXP UM10204 规范的 Standard Mode（100 kbps）子集：

- **i2c_master**：I2C 主机控制器，负责生成 SCL 时钟、发起 START/STOP 条件、发送/接收数据字节、检测从机应答
- **i2c_slave**：I2C 从机控制器，负责检测总线条件、地址匹配、接收/发送数据字节、支持时钟拉伸

支持的事务类型：单字节读/写、多字节连续读/写、复合读写（Repeated START）、地址不匹配检测。

## 2. 顶层架构框图

```
                    ┌─────────────────┐
                    │   User Logic    │
                    │  (Testbench)    │
                    └──┬──────────┬───┘
                       │          │
              cmd/tx/rx│          │rx/tx
                       ▼          ▼
              ┌────────────┐  ┌────────────┐
              │ i2c_master │  │ i2c_slave  │
              │            │  │            │
              │  scl_o/oen │  │  scl_o/oen │
              │  sda_o/oen │  │  sda_o/oen │
              │  scl_i     │  │  scl_i     │
              │  sda_i     │  │  sda_i     │
              └──┬─────┬───┘  └──┬─────┬───┘
                 │     │         │     │
                 ▼     ▼         ▼     ▼
              ┌──────────────────────────────┐
              │    Wired-AND Open-Drain Bus   │
              │   SCL_bus = m_scl & s_scl    │
              │   SDA_bus = m_sda & s_sda    │
              └──────────────────────────────┘
```

I2C 物理层采用三态拆分接口（`_o`/`_oen`/`_i`），在 Testbench 中通过线与（Wired-AND）模型模拟开漏总线行为。

## 3. 接口信号说明

### 3.1 i2c_master 接口

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| clk | input | 1 | 系统时钟（100 MHz） |
| rst_n | input | 1 | 异步复位，低有效 |
| cmd_valid | input | 1 | 命令有效 |
| cmd_ready | output | 1 | 命令握手就绪 |
| cmd_rw | input | 1 | 0=写，1=读 |
| cmd_addr | input | 7 | 目标从机地址 |
| cmd_len | input | 8 | 传输字节数（1~256，0 表示 256） |
| tx_data | input | 8 | 发送数据 |
| tx_valid | input | 1 | 发送数据有效 |
| tx_ready | output | 1 | 发送数据握手就绪 |
| rx_data | output | 8 | 接收数据 |
| rx_valid | output | 1 | 接收数据有效 |
| rx_ready | input | 1 | 接收数据握手就绪 |
| busy | output | 1 | 总线忙指示 |
| nack_error | output | 1 | 从机无应答错误（脉冲） |
| scl_o/scl_oen/scl_i | - | 1 | SCL 三态接口 |
| sda_o/sda_oen/sda_i | - | 1 | SDA 三态接口 |

### 3.2 i2c_slave 接口

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| clk | input | 1 | 系统时钟 |
| rst_n | input | 1 | 异步复位，低有效 |
| rx_data | output | 8 | 从主机接收的数据 |
| rx_valid | output | 1 | 接收数据有效 |
| rx_ready | input | 1 | 接收数据握手就绪 |
| tx_data | input | 8 | 待发送给主机的数据 |
| tx_valid | input | 1 | 发送数据有效 |
| tx_ready | output | 1 | 发送数据握手就绪 |
| start_det | output | 1 | 检测到 START/Repeated START（脉冲） |
| stop_det | output | 1 | 检测到 STOP（脉冲） |
| addr_match | output | 1 | 地址匹配指示 |
| rw_bit | output | 1 | 当前事务方向（0=写，1=读） |
| scl_o/scl_oen/scl_i | - | 1 | SCL 三态接口 |
| sda_o/sda_oen/sda_i | - | 1 | SDA 三态接口 |

## 4. 核心状态机描述

### 4.1 i2c_master 状态机（10 状态）

```
IDLE ──cmd_valid──► START ──────► ADDR ──8bits──► ADDR_ACK
                                                     │
                                          ┌──ACK─────┤
                                          │      NACK─┼──► STOP ──► IDLE
                                          ▼           │
                                  ┌── rw=0 ──┐   rw=1 ──┐
                                  ▼          │          ▼
                              TX_DATA        │      RX_DATA
                              8bits          │      8bits
                                  │          │          │
                                  ▼          │          ▼
                              TX_ACK         │      RX_ACK
                                  │          │          │
                        ┌─────ACK─┤          │    ACK───┤
                        │    NACK──► STOP    │    NACK──┤
                        │         │          │          │
                   last byte?     │     last byte?      │
                   ┌─yes──┘       │     ┌─yes──┘        │
                   │              │     │               │
              next_cmd? ──yes──► RSTART ◄──yes── next_cmd?
                   │                                    │
                   no──────────► STOP ◄────────────no───┘
```

**4 相 SCL 时钟生成**（每相 250 系统时钟 tick @ 100MHz/100kHz）：
- Phase 0：SCL 低，SDA 可变更（数据建立）
- Phase 1：SCL 释放/高，检测时钟拉伸
- Phase 2：SCL 高，采样 SDA
- Phase 3：SCL 拉低，准备下一位

### 4.2 i2c_slave 状态机（8 状态）

```
IDLE ──start_cond──► ADDR ──8bits──► ADDR_ACK
                                        │
                               match ───┤
                               ┌─ rw=0 ─┤─ rw=1 ─┐
                               ▼         │        ▼
                           RX_DATA       │    TX_DATA ◄── STRETCH
                           8bits         │    8bits          ▲
                               │         │        │          │
                               ▼         │        ▼          │
                           RX_ACK        │    TX_ACK ────────┘
                               │         │        │     (no tx_valid)
                               └─────────┘   NACK ──► IDLE
                                              ACK ──► TX_DATA

         任意状态检测 start_cond → 跳转 ADDR（Repeated START）
         任意状态检测 stop_cond  → 跳转 IDLE
```

**关键特性：**
- 3 级同步器采样 SCL/SDA，检测上升/下降沿
- 时钟拉伸：在 S_STRETCH 状态拉低 SCL，等待 tx_valid 后释放

## 5. 关键时序说明

### 5.1 START 条件生成
SCL 保持高电平时，SDA 从高拉低。主机在 S_START 状态先拉低 SDA，保持一个 QUARTER 周期后拉低 SCL。

### 5.2 STOP 条件生成
SCL 低电平时先拉低 SDA，然后释放 SCL 使其变高，最后释放 SDA 使其变高。SDA 在 SCL 高电平期间的上升沿构成 STOP 条件。

### 5.3 SCL 时钟分频
系统时钟 100 MHz 分频到 100 kHz SCL：
- 总周期 = 1000 ticks = 10 us
- 每相 = 250 ticks = 2.5 us
- 占空比约 50%（Phase 0+3 低，Phase 1+2 高）

### 5.4 数据采样时机
- **主机发送**：Phase 0 建立 SDA，Phase 1-2 SCL 高保持，Phase 3 拉低 SCL
- **主机接收**：Phase 2（SCL 高中点）采样 SDA
- **从机**：SCL 上升沿采样 SDA（通过同步器后）

### 5.5 时钟拉伸
主机在 Phase 1 释放 SCL 后检测 scl_i：若 SCL 被从机拉低（scl_i == 0），主机暂停计数器，等待 SCL 释放后继续。

### 5.6 Repeated START
最后一个字节传输完成后，若 next_cmd_valid 有效，主机进入 S_RSTART 状态：先释放 SDA，再释放 SCL，然后拉低 SDA（形成 Repeated START），最后拉低 SCL 开始新的地址阶段。

## 6. 仿真结果

### 6.1 测试用例结果

```
--- TC-01: Single byte write ---
[PASS] TC-01: Single byte write

--- TC-02: Single byte read ---
[PASS] TC-02: Single byte read

--- TC-03: Multi-byte write (4 bytes) ---
[PASS] TC-03: Multi-byte write (4 bytes)

--- TC-04: Multi-byte read (4 bytes) ---
[PASS] TC-04: Multi-byte read (4 bytes)

--- TC-05: Compound read/write (Repeated START) ---
[PASS] TC-05: Compound read/write (Repeated START)

--- TC-06: Address mismatch ---
[PASS] TC-06: Address mismatch

--- TC-07: Back-to-back 3 writes ---
[PASS] TC-07: Back-to-back 3 writes

--- TC-08: Bus idle detection ---
[PASS] TC-08: Bus idle detection

=== 8/8 PASSED ===
```

全部 8 个测试用例通过，验证了 I2C 主机与从机模块在以下场景下的正确性：
1. 单字节写/读基本功能
2. 多字节连续写/读（含末字节 NACK）
3. Repeated START 复合读写事务
4. 地址不匹配时的 NACK 错误检测
5. 背靠背连续事务无总线挂死
6. STOP 后总线正确回到空闲态

### 6.2 工程信息

| 项目 | 值 |
|------|-----|
| 工具 | Vivado 2024.2 + XSim |
| 器件 | xc7z010clg400-1 |
| 仿真时长 | ~2.6 ms |
| 编译警告 | 0 |
