# SynthPilot Tutorial

SynthPilot 工具集系列教程的配套资料仓库。

## 目录结构

```
├── doc/                ← 各期教程的任务书与设计文档
├── prj/                ← 各期项目工程
│   ├── 01/             ← LED 闪烁（Vivado 基础操作）
│   │   ├── prj/        ← Vivado 工程
│   │   ├── rtl/        ← RTL 源码
│   │   └── xdc/        ← 约束文件
│   ├── 02/             ← I2C 收发器（仿真验证）
│   │   ├── prj/        ← Vivado 工程
│   │   ├── rtl/        ← RTL 源码
│   │   └── sim/        ← 仿真文件
│   └── 03/             ← 多时钟域数据采集与串口输出（进行中）
├── src/                ← 独立示例源码
└── sim/                ← 独立示例仿真
```

## 教程列表

| 期号 | 主题 | 任务书 |
|------|------|--------|
| 01 | Vivado 基础工程创建 | [doc/01_project.md](doc/01_project.md) |
| 02 | I2C 设计与仿真验证 | [doc/04_sim.md](doc/04_sim.md) |
| 03 | 多时钟域数据采集与串口输出 | [doc/05_synth.md](doc/05_synth.md) |
