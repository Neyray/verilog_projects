# RV32I CPU 实验项目

> 计算机组成原理实验 · 三阶段递进：单周期 → 五级流水线 → 流水线 + 中断 + 自定义小程序

---

## 目录

- [项目概览](#项目概览)
- [递进路线](#递进路线)
- [仓库结构](#仓库结构)
- [共享的 SoC 框架](#共享的-soc-框架)
- [外设地址映射](#外设地址映射)
- [板上开关用法（三个项目都一样）](#板上开关用法三个项目都一样)
- [Vivado 操作要点](#vivado-操作要点)
- [如何选择项目阅读](#如何选择项目阅读)

---

## 项目概览

本仓库实现了三版 RISC-V（RV32I 子集）处理器，集成到**同一套 SoC 外设框架**上，CPU 对外接口三版完全一致，外设无需任何改动。

每个子项目都有**自己独立的 README**，详细文档请进入相应目录查阅：

| 项目 | 链接 | 主题 |
|------|------|------|
| Project 1 | **[`project1/README.md`](project1/README.md)** | 单周期 CPU（SCPU），纯组合逻辑串联，理解数据通路的入门 |
| Project 2 | **[`project2/README.md`](project2/README.md)** | 五级流水线 CPU（PCPU），前递 + 气泡 + 冲刷解决三类冒险 |
| Project 3 | **[`project3/README.md`](project3/README.md)** | 流水线 CPU + **精确中断 + 自定义序列锁小程序** |

> 本根 README 只描述**三个项目共通的内容**（外设框架、地址映射、开关用法、Vivado 流程）。CPU 内部架构、冒险处理、中断机制等请到子 README 看。

---

## 递进路线

```
Project 1 (SCPU)              Project 2 (PCPU)            Project 3 (PCPU + INT)
──────────────────            ────────────────────        ────────────────────────────
一条指令 = 1 个 Clk_CPU         一条指令 ≈ 1 拍              + CSR + mepc + int_pending
纯组合逻辑链                    4 组流水寄存器               + memory-mapped CSR 协议
                              前递 / Stall / Flush         + BTN 上升沿做 INT 脉冲
                                                          + 自定义反应小游戏
testac.coe → AC123456         testac.coe → AC123456        custom_int.coe → 按 BTNU 玩游戏
```

每一步都保留前一步的全部功能；外设、总线、时钟分频、`testac.coe` 都不变。CPU 之外的改动只发生在顶层（如 Project 3 新增 INT 链路）。

---

## 仓库结构

```
verilog_projects/
├── README.md                    ← 本文件
├── project1/                    ← 单周期 CPU
│   ├── README.md                  独立文档
│   ├── SCPU.v / SCPU_TOP.v
│   ├── testac.coe / D_mem.coe
│   └── 外设 .v 文件 + dm_controller / MIO_BUS / …
├── project2/                    ← 五级流水线 CPU
│   ├── README.md                  独立文档
│   ├── PCPU.v / PCPU_TOP.v
│   ├── testac.coe / I_pipemem37.coe / D_snakeDEMO.coe
│   └── 外设 .v / .edf 文件 + icf.xdc
├── project3/                    ← 流水线 + 中断 + 自定义程序
│   ├── README.md                  独立文档（验收重点：中断与小程序）
│   ├── PCPU.v / PCPU_TOP.v        ← 与 P2 同名但已加中断
│   ├── custom_int.coe / custom_int.s
│   ├── 其它 .coe（备用）
│   └── 外设 / icf.xdc（已修正时钟周期）
├── code/                        ← 早期草稿/参考代码
├── lab/                         ← 课程小实验
└── test/                        ← 杂项测试
```

---

## 共享的 SoC 框架

三个项目的顶层都遵循同一套数据流：

```
btn_i, sw_i ─► Enter ─► BTN_out, SW_out
                            │
clk ─► clk_div ─► Clk_CPU + clkdiv[31:0]
                            │
PC_out ─► ROMD ─► spo (指令字)
                            │
            CPU ◄── Data_read ◄── dm_controller ◄── MIO_BUS
              │                          │
              ├─ Addr_out, Data_out, mem_w, dm_ctrl
              ▼
          MIO_BUS（地址译码）
              ├──► RAM_B
              ├──► SPIO（LED）
              ├──► Multi_8CH32（数码管数据选择）
              └──► Counter_x

Multi_8CH32 ─► Disp_num ─► SSeg7 ─► 七段数码管
SPIO ────────────────────────────► led_o
```

**所有外设模块（`Multi_8CH32` / `SPIO` / `SSeg` / `Counter_x` / `Enter` / `clk_div` / `MIO_BUS` / `dm_controller`）三个项目使用同一份代码**，只是 P2/P3 多了 `.edf` 网表版本。

---

## 外设地址映射

| 段 | 用途 | 谁解码 |
|----|------|--------|
| `0x0000_0000` ~ `0x0000_0FFF` | 数据 RAM (RAM_B) | `MIO_BUS` |
| `0xE000_0000` | Multi_8CH32 写口（数码管数据） | `MIO_BUS`（`GPIOe0000000_we`） |
| `0xF000_0000` | SPIO（LED + counter_set） | `MIO_BUS`（`GPIOf0000000_we`） |
| `0xC000_0000` 段 | Counter_x（计数器值） | `MIO_BUS`（`counter_we`） |
| `0xD000_00xx` | **CSR（仅 Project 3 启用）** | **PCPU 内部捕获**，不进 MIO_BUS |

> Project 3 的 `0xD000_00xx` 段不被 MIO_BUS 路由到外设，而是被 PCPU 内部在 EX 阶段拦下，用于控制 `mie/mepc`。详见 [`project3/README.md`](project3/README.md#csr-访问协议)。

---

## 板上开关用法（三个项目都一样）

| 开关 | 接到哪 | 作用 |
|------|--------|------|
| `SW0` | `SSeg7.SW0` | `0`=纯 hex 显示；`1`=验收模式（前两位画 "AC"，后六位画 `mem[4]`） |
| `SW2` | `clk_div.SW2` | `0`=快档 `clkdiv[3]`（≈6 MHz）；`1`=慢档 `clkdiv[24]`（≈3 Hz，肉眼看 PC 跑动） |
| `SW7,SW6,SW5` | `Multi_8CH32.Switch[2:0]` | 选择 8 路 32bit 信号中送数码管显示的那一路 |
| `rstn` | 顶层 | 低有效复位（按下复位） |
| `BTNU = btn_i[1]` | P1/P2：未用；**P3：游戏确认键 + 中断源** | — |

`Multi_8CH32` 的 8 个数据通道：

| SW7 SW6 SW5 | 通道 | 显示内容 | 备注 |
|-------------|------|----------|------|
| 0 0 0 | `data0 = Peripheral_in` | 最近一次写入 `0xE000_0000` 的数据 | P1/P2 看进度码，P3 看状态码 |
| 0 0 1 | `data1 = {2'b00, PC[31:2]}` | PC 的字地址 | 跟踪指令编号 |
| 0 1 0 | `data2 = spo` | 当前 ROMD 输出的指令机器码 | 当前正在执行的 32bit 指令 |
| 0 1 1 | `data3` | P1：浮空；P2/P3：`counter_out` | 计数器值 |
| 1 0 0 | `data4 = Adder_out` | ALU 结果 / 访存地址 | `lw/sw` 目标地址 |
| 1 0 1 | `data5 = Data_out` | CPU 输出的写数据（`rs2`） | `sw` 写出去的内容 |
| 1 1 0 | `data6 = Cpu_data4bus` | 总线读回的 32bit 字 | `lw` 读到了什么 |
| 1 1 1 | `data7 = PC_out` | PC 原值（字节地址） | 真实 PC，对照反汇编 |

LED 显示的是程序写到 `0xF000_0000` 的低 16 位。P1/P2 同步进度码；P3 高 8 位 = 当前目标位、低 8 位 = 移动光标。

---

## Vivado 操作要点

- 指令 ROM（ROMD）和数据 RAM（RAM_B）是 **Block Memory Generator IP 核**，在工程里用 COE 文件初始化，不在 `.v` 源码里。
- 切换不同验收程序（如 P1 的 `testac.coe` ↔ P3 的 `custom_int.coe`）需要在 Vivado 里**重新生成 IP 核**或改 IP 的 COE 路径。
- `icf.xdc`（Project 2/3 提供）已经约束好了 16 LED、8 位数码管、16 拨码开关、5 个按键的全部引脚。
- **⚠️ Project 3 的 `icf.xdc` 修正了一个隐藏 bug**：旧版的 `create_clock -period 100.00` 实际意思是 10MHz；改为 `-period 10.00 -waveform {0 5}` 才是真 100MHz。如果你拷贝旧 xdc 到 P3 工程，会在快档下出现按键漂移、PC 偶发跳错。详见 [`project3/README.md`](project3/README.md#pcpuv--pcpu_topv-改动一览)。

---

## 如何选择项目阅读

- 想理解 **"一条指令在硬件里跑一遍"** → 读 [Project 1](project1/README.md)。
- 想理解 **流水线、前递、Stall、Flush** → 读 [Project 2](project2/README.md)。
- 想理解 **精确中断、CSR 状态机、ISR 怎么"原地返回"、跨时钟域 IO** → 读 [Project 3](project3/README.md)（验收重点）。
- 想直接验收：每个子 README 的"验收操作"章节都给了"开关怎么拨、看什么、出什么算过"的清单。

> **核心一句话：** 这是一个三步走的 RV32I 实验栈，每一步都在前一步上增量，外设和验收方法保持一致；想看具体细节请进对应 `projectN/README.md`。
