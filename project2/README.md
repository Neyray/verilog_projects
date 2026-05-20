# Project 2 — 五级流水线 RV32I CPU（PCPU）

> 把 [Project 1](../project1/README.md) 的单周期组合逻辑切成 5 段，加入 4 组流水线寄存器，配合 **前递 + 气泡 + 冲刷** 解决三类冒险，对外接口与单周期版完全相同。
>
> 外设/总线/地址映射/开关用法等三个项目共通内容请看 [根目录 README](../README.md)。本文聚焦流水线 CPU 自身。

---

## 目录

- [文件清单](#文件清单)
- [总体结构](#总体结构)
- [PCPU.v — 流水线核心](#pcpuv--流水线核心)
  - [五个流水段](#五个流水段)
  - [三种冒险的处理方案](#三种冒险的处理方案)
  - [NOP 与流水段清空](#nop-与流水段清空)
- [PCPU_TOP.v — 流水线 SoC 顶层](#pcpu_topv--流水线-soc-顶层)
- [配套 COE 文件](#配套-coe-文件)
- [验收操作](#验收操作)
  - [配置 A：功能正确性（testac）](#配置-atestac-验流水线功能正确性)
  - [配置 B：贪吃蛇 I/O 演示](#配置-bi_pipemem37--d_snakedemo--贪吃蛇-io-演示)
- [与 Project 1 / Project 3 的差异速查](#与-project-1--project-3-的差异速查)

---

## 文件清单

| 文件 | 作用 |
|------|------|
| `PCPU.v` | **五级流水线 CPU 核心**（与 SCPU.v 等价但加了 IF/ID/EX/MEM/WB 寄存器和冒险逻辑） |
| `PCPU_TOP.v` | 流水线 SoC 顶层 |
| `dm_controller.v` | 字节/半字访存控制器 |
| `MIO_BUS.v` / `MIO_BUS.edf` | 内存映射 I/O 总线（黑盒 IP） |
| `Multi_8CH32.v` / `Multi_8CH32.edf` | 8 路 32bit 多路选择，送数码管 |
| `SPIO.v` / `SPIO.edf` | LED/SW GPIO 外设 |
| `SSeg.v` / `SSeg7.edf` | 七段数码管驱动 |
| `Counter_x.v` | 计数器外设 |
| `Enter.v` | 按键 / 拨码开关同步 |
| `clk_div.v` | 时钟分频 |
| `testac.coe` | 验收程序（同 Project 1） |
| `I_pipemem37.coe` | 贪吃蛇 I/O 演示程序 |
| `D_snakeDEMO.coe` | 数据 RAM 初始化（含蛇身模式数据） |
| `rv32-instr.disasm` | `testac` 的反汇编源码 |
| `icf.xdc` | 引脚约束（16 LED / 8 数码管 / 16 拨码 / 5 按键） |

> ⚠️ 切换 ROM/RAM 的 COE 文件需要在 Vivado 中重新生成 IP 核。

---

## 总体结构

外设部分与 [Project 1 顶层](../project1/SCPU_TOP.v) 完全一致；CPU 核换成 `PCPU` 即可：

```
btn_i, sw_i ─► Enter ─► BTN_out, SW_out
                            │
clk ─► clk_div ─► Clk_CPU + clkdiv[31:0]
                            │
PC_out ─► ROMD ─► spo（指令字）
                            │
            PCPU ◄── Data_read ◄── dm_controller ◄── MIO_BUS
              │                          │
              ├─ Addr_out, Data_out, mem_w, dm_ctrl
              ▼
          MIO_BUS（地址译码）
              ├──► RAM_B（0x0000_0000 段，受 data_ram_we 门控）
              ├──► SPIO（0xF000_0000）
              ├──► Multi_8CH32（0xE000_0000）
              └──► Counter_x

Multi_8CH32 ──► Disp_num ──► SSeg7 ──► 数码管
SPIO ──────────────────────────────► led_o, counter_set
```

CPU 内部数据通路（流水线）：

```
PC ─► IF/ID ─► ID/EX ─► EX/MEM ─► MEM/WB ─► RegFile
              ▲ ▲          │ │           │
              │ └─前递─────┘ │           │
              └─前递─────────┘           │
              └─WB→ID 同拍旁路─────────────┘
```

---

## PCPU.v — 流水线核心

### 五个流水段

| 阶段 | 工作内容 | 关键流水寄存器 |
|------|----------|----------------|
| **IF**（取指） | 用 `PC` 取指令 | `PC` |
| **ID**（译码） | 拆字段、生成 5 种立即数、读寄存器堆、生成 9 个 `is_xxx` 控制信号 | `IF_ID_inst`、`IF_ID_PC` |
| **EX**（执行） | 前递选源、ALU 运算、分支判断、跳转目标计算 | `ID_EX_*`（大量信号） |
| **MEM**（访存） | 输出地址/写数据/控制信号给总线，接收 `Data_in` | `EX_MEM_*` |
| **WB**（写回） | 从 LOAD 数据、ALU 结果、`PC+4` 中选一个写回寄存器堆 | `MEM_WB_*` |

理论上每拍可让 5 条指令同时在各阶段执行，IPC 接近 1。

### 三种冒险的处理方案

#### （一）数据冒险 — 前递（Forwarding）

EX 阶段计算 ALU 时，源寄存器的值可能正被后续阶段的指令更新，不能等写回后再读，需直接"旁路"转发：

```
fwd_ex_mem_rs1 = (EX/MEM 中的指令写 rs1) && (rd ≠ x0)
fwd_mem_wb_rs1 = (MEM/WB 中的指令写 rs1) && (rd ≠ x0)

ex_rs1_data = fwd_ex_mem_rs1 ? ex_mem_wb_data   // EX/MEM 优先（更新）
            : fwd_mem_wb_rs1 ? wb_data           // 次选 MEM/WB
            :                  ID_EX_rs1_data    // 无冒险
```

其中 `ex_mem_wb_data` 本身是三选一：LOAD 取 `Data_in`，JAL/JALR 取 `PC+4`，否则取 ALU 结果。

另外，**WB→ID 同拍旁路**：ID 阶段用组合逻辑读寄存器堆，但同一拍 WB 正在写入（非阻塞赋值会让 ID 读到旧值）。解决方法：若 `MEM/WB` 写的 `rd` 等于 ID 阶段读的 `rs1/rs2`，直接用 `wb_data` 旁路，跳过寄存器堆。

#### （二）Load-Use 冒险 — 插入气泡（Stall）

```asm
lw  x10, 0(x11)     ; LOAD，数据要到 MEM 段才出来
add x12, x10, x13   ; 紧接着用 x10 → 无法纯前递
```

必须停顿一拍：

```
stall = (EX 段是 LOAD) && (LOAD 的 rd == ID 段的 rs1 或 rs2)
```

`stall = 1` 时：
- `PC` 保持不动
- `IF/ID` 寄存器保持不动
- `ID/EX` 注入 NOP

一拍后 LOAD 进入 MEM/WB，后续指令重新进入 EX，通过 MEM/WB→EX 前递拿到数据。

#### （三）控制冒险 — 冲刷（Flush）

分支/跳转目标在 **EX 阶段**才能算出，此时 IF 和 ID 阶段已经各取了一条顺序（错误的）指令：

```
flush = is_jal | is_jalr | (is_branch & branch_taken)
```

`flush = 1` 时：
- `PC ← branch_target`
- `IF/ID` 注入 NOP
- `ID/EX` 注入 NOP

代价：**每次分支/跳转浪费 2 拍**（分支在 EX 方案）。如果将分支判断提前到 ID 段可降为 1 拍，但要更多前递逻辑。

### NOP 与流水段清空

```verilog
localparam NOP = 32'h00000013;  // addi x0, x0, 0
```

写入 `x0`（被硬件屏蔽）且不触发外设访问，是完全无副作用的"占位指令"。Stall 和 Flush 都靠注入 NOP 来"清空"对应流水段。

---

## PCPU_TOP.v — 流水线 SoC 顶层

与 `SCPU_TOP.v` 基本一致，主要差异：

1. **CPU 实例替换**：`SCPU U1(...)` → `PCPU U1(...)`。对外接口完全相同，外设无需改动。

2. **RAM 写保护门控**：

   ```verilog
   ram_wea = data_ram_we ? wea_mem : 4'b0000;
   ```

   仅当 MIO_BUS 地址译码确认当前地址属于数据 RAM 区域时才允许写 RAM，防止 `sw` 到外设地址（`0xE000_0000` / `0xF000_0000`）时误写 RAM。

3. **计数器显示通道**：`data3` 接入 `counter_out`（单周期版接 `none`），数码管可显示计数器当前值。

4. **`INT` 输入仍接 `1'b0`**：流水线 CPU 本身预留了 `INT` 端口，但本工程未启用——中断完整流程在 [Project 3](../project3/README.md) 中实现。

数码管显示通道（由 `SW[7:5]` 选择）与单周期版完全一致，唯一差别是 `data3`：

| SW7 SW6 SW5 | 显示内容 |
|-------------|----------|
| 0 1 1 | `counter_out`（**Project 2 新增**） |

---

## 配套 COE 文件

| 用途 | 指令 ROM | 数据 RAM |
|------|----------|----------|
| 流水线全功能自检 | `testac.coe` | `D_snakeDEMO.coe` |
| 贪吃蛇 I/O 演示 | `I_pipemem37.coe` | `D_snakeDEMO.coe` |

> 数据 RAM 默认使用 `D_snakeDEMO.coe`：贪吃蛇演示需要它的图案数据，`testac` 不读这块区域所以也能正常跑通。

---

## 验收操作

开关功能定义统一见 [根 README 的"板上开关用法"](../README.md#板上开关用法三个项目都一样)，三个项目通用。

### 配置 A：`testac` 验流水线功能正确性

| 步骤 | SW 设定 | 期望现象 | 验什么 |
|------|---------|----------|--------|
| 1 | `SW0=1`，`SW7..5=000`，`SW2=0`（快档） | 数码管显示 **AC123456** | PCPU 五段流水线 + 前递 + load-use stall + 分支冲刷全部正确 |
| 2 | `SW0=0`，`SW2=1`，`SW7..5=001` | PC 字地址逐条递增 | 慢档下 PCPU 比 SCPU 明显更快（IPC≈1，分支/load-use 损失拍数少） |
| 3 | `SW0=0`，`SW2=1`，`SW7..5=011` | `counter_out` 数值在变化 | Project 2 多接的计数器通道在工作 |

**失败诊断**：若 SCPU 跑同样的 `testac` 正常而 PCPU 出 `0xF000xxxx`，几乎一定是流水线冒险处理遗漏——最常见场景：
- 分支前 1 条 ALU 指令依赖前 2 条 ALU 指令（需走 EX/MEM 前递）
- `jalr` 的目标地址来自 `lw` 读出的结果（load-use 检测覆盖到 jalr）
- 写回与 ID 读寄存器同拍（WB→ID 旁路）

### 配置 B：`I_pipemem37` + `D_snakeDEMO` — 贪吃蛇 I/O 演示

把 ROMD 的 COE 换成 `I_pipemem37.coe`，RAM_B 保持 `D_snakeDEMO.coe`。

| 步骤 | SW 设定 | 期望现象 |
|------|---------|----------|
| 1 | `SW0=0`，`SW2=0`（快档），`SW7..5=000` | 数码管按帧刷新——程序循环把 `D_snakeDEMO` 的模式数据写到 `0xE000_0000`，8 位数码管点亮模式形成蛇身延伸/缩短的视觉动画 |
| 2 | — | LED 同步按帧切换（程序同时写 `0xF000_0000`） |
| 3 | `SW7..5=110` | `data6 = Cpu_data4bus`，看每次 `lw` 读出的快照，验证读到的是 `D_snakeDEMO` 里的模式数据 |
| 4 | `SW7..5=001` | PC 字地址快速循环，证明在 I/O 主循环里反复 `jal` |

> `icf.xdc` 已约束好全部 I/O 引脚，烧入板子图案直接显示，无需额外配置。

---

## 与 Project 1 / Project 3 的差异速查

| 维度 | Project 1（SCPU） | Project 2（PCPU） | Project 3（PCPU + INT） |
|------|-------------------|-------------------|--------------------------|
| CPU 微架构 | 单周期 | 五级流水线 | 五级流水线 |
| 冒险处理 | 无 | 前递 + 气泡 + 冲刷 | 同 Project 2 |
| 中断处理 | ❌ | ❌（`INT` 接 0） | ✅（CSR + 中断进入/返回） |
| 默认指令 ROM | `testac.coe` | `testac.coe` | 自定义小程序 |
| `data3` 通道 | 浮空 | `counter_out` | `counter_out` |
| 顶层 INT 来源 | 未连 | 接 `1'b0` | 来自按键 / 计数器 |

> **核心一句话：** PCPU 把单周期切成 5 段、加上 4 组流水寄存器和冒险处理逻辑，对外接口、外设、验收方法都与 SCPU 兼容。验收主要看 `SW0=1` 是否出 **AC123456**——出 AC 即流水线全功能通过。
