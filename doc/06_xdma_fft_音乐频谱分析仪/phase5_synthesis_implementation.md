# Phase 5：约束、综合与实现

> 所属项目：XDMA + FFT 音乐频谱分析仪
> 前置依赖：Phase 4（顶层集成与系统仿真通过）
> 后续阶段：Phase 6（驱动安装与硬件验证）

## 一、目标

创建约束文件，完成综合与布局布线，确保时序收敛，生成比特流。

## 二、约束文件

约束文件路径：`prj/04/prj/fft_spectrum/constrs/top.xdc`

### 2.1 引脚分配

目标板卡：xcku3p-ffvb676-2-e

#### 系统时钟（100 MHz 差分，Clock Wizard 输入）

| 信号 | LOC | IOSTANDARD |
|------|-----|------------|
| `sys_clk_p` | E18 | LVDS |
| `sys_clk_n` | D18 | LVDS |

#### PCIe 接口

GT 及其时钟只约束 P 端，Vivado 自动推断 N 端。

| 信号 | LOC | 说明 |
|------|-----|------|
| `pcie_refclk_p` | T7 | PCIe GT 参考时钟 |
| `pcie_txp[0]` | R5 | PCIe GT TX Lane 0 |
| `pcie_txp[1]` | U5 | PCIe GT TX Lane 1 |
| `pcie_txp[2]` | W5 | PCIe GT TX Lane 2 |
| `pcie_txp[3]` | AA5 | PCIe GT TX Lane 3 |

#### 通用 IO

| 信号 | LOC | IOSTANDARD |
|------|-----|------------|
| `pcie_perstn` | A9 | LVCMOS18 |
| `led_link_up` | B12 | LVCMOS18 |

> LED 为低有效（高电平熄灭），顶层输出取反：link up 时输出低电平点亮。

> **注意**：XDMA IP 在综合时会自动生成 PCIe 参考时钟约束。系统差分时钟需手动创建 `create_clock` 约束。

### 2.2 时钟约束

系统差分时钟 100 MHz，周期 10 ns。PCIe 参考时钟由 XDMA IP 自动约束。

## 三、综合

### 3.1 综合策略

使用默认综合策略（Vivado Synthesis Defaults）。

### 3.2 综合后分析

综合完成后，执行以下分析：

| 分析项 | 工具 | 关注点 |
|--------|------|--------|
| 资源利用率 | report_utilization | LUT、FF、BRAM、DSP、GT 使用量 |
| 层次化资源 | report_utilization -hierarchical | 各模块资源占比 |
| 时序摘要 | report_timing_summary | WNS、TNS、WHS、THS |
| 关键路径 | report_worst_timing_paths | 最差路径位于哪个模块 |
| 时钟网络 | report_clock_networks | 时钟域列表与关系 |
| CDC | report_cdc | 跨时钟域路径安全性 |
| DRC | report_drc | 设计规则检查 |
| 方法学 | report_methodology | 设计方法学检查 |

## 四、实现（布局布线）

### 4.1 实现策略

使用默认策略（Vivado Implementation Defaults）。如果时序不满足，可切换到 Performance_Explore。

### 4.2 实现后分析

| 分析项 | 工具 | 关注点 |
|--------|------|--------|
| 资源利用率 | report_utilization | 与综合后对比，关注 opt_design 优化效果 |
| 时序摘要 | report_timing_summary | 实现后 WNS/WHS，与综合后对比 |
| 关键路径 | report_timing_detail | 逻辑延迟 vs 布线延迟比例 |
| 布线状态 | report_route_status | 确认所有网络 fully routed |
| 拥塞 | report_congestion | 拥塞热点 |
| 功耗 | report_power | 总功耗、动态/静态分解 |
| CDC | report_cdc | 实现后 CDC 复查 |
| DRC | report_drc | 实现后 DRC |

### 4.3 综合 vs 实现对比

重点关注：
- WNS 变化（布线延迟真实化后时序裕量通常下降）
- 关键路径逻辑延迟 vs 布线延迟比例变化
- 资源优化（opt_design 的 LUT 削减）

## 五、比特流生成

时序签收通过后，生成比特流文件。

## 六、验证标准

| 编号 | 验证项 | 通过条件 |
|------|--------|----------|
| P5-01 | 综合通过 | 综合无 Error，Critical Warning 可控 |
| P5-02 | 时序（综合后） | 所有时钟域 WNS > 0 |
| P5-03 | 实现通过 | 布局布线完成，所有网络 fully routed |
| P5-04 | 时序（实现后） | 所有时钟域 WNS > 0，WHS > 0 |
| P5-05 | CDC 安全 | 无 Unsafe 跨时钟域路径 |
| P5-06 | DRC | 无阻断性 Error |
| P5-07 | 比特流 | .bit 文件成功生成 |
