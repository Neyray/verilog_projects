# Project 3 — 流水线 RV32I CPU + 中断 + 自定义小程序

> 在 [Project 2](../project2/README.md) 的五级流水线 PCPU 上**增加最小化的中断机制**（精确异常，单层），并烧入自定义的演示小程序：主循环数码管递增，按下 `BTN1` 触发中断让 LED 上的 ISR 计数器 +1，自动 MRET 返回。

---

## 目录

- [文件清单](#文件清单)
- [整体设计](#整体设计)
- [中断硬件机制](#中断硬件机制)
  - [新增的 CSR / 状态寄存器](#新增的-csr--状态寄存器)
  - [中断的 4 个关键时刻](#中断的-4-个关键时刻)
  - [流水线一致性 (精确异常)](#流水线一致性-精确异常)
  - [CSR 访问协议](#csr-访问协议)
- [PCPU.v 改动一览](#pcpuv-改动一览)
- [PCPU_TOP.v 改动一览](#pcpu_topv-改动一览)
- [自定义小程序 custom_int.coe](#自定义小程序-custom_intcoe)
  - [程序结构](#程序结构)
  - [机器码逐行解析](#机器码逐行解析)
- [验收操作](#验收操作)
- [与 Project 1 / Project 2 的差异速查](#与-project-1--project-2-的差异速查)

---

## 文件清单

| 文件 | 来源 | 说明 |
|------|------|------|
| `PCPU.v` | Project 2 + **本项目修改** | 流水线 CPU 核，**新增 CSR 寄存器和中断流水机制** |
| `PCPU_TOP.v` | Project 2 + **本项目修改** | 顶层 SoC，**新增 BTN1 上升沿检测产生 INT 脉冲** |
| `custom_int.coe` | **本项目新建** | 自定义演示程序的 ROM 初始化文件（1024 word） |
| `custom_int.s` | **本项目新建** | 演示程序的反汇编注释源（人读用） |
| `dm_controller.v` / `MIO_BUS.v` / … | Project 2 | 外设无改动，直接复用 |
| `D_snakeDEMO.coe` | Project 2 | 数据 RAM 初始化（沿用，演示程序未读这块区域） |
| `testac.coe` / `I_pipemem37.coe` | Project 2 | 备用 ROM（可切换回去做对照） |
| `icf.xdc` | Project 2 | 引脚约束 |

> ⚠️ **关键约束：** `PCPU.v` 内把中断入口硬编码为 `MTVEC = 0x0000_0080`。`custom_int.coe` 的 ISR 必须放在偏移 0x80（即字索引 32）。

---

## 整体结构

```
btn_i, sw_i ─► Enter ─► BTN_out, SW_out
                            │
                ┌──── BTN_out[1] 上升沿检测（Clk_CPU 域）
                │           │
                │           ▼
                │    ┌──► int_pulse (1 拍宽)
                │    │
                ▼    ▼
clk ─► clk_div ─► Clk_CPU + clkdiv[31:0]
                            │
PC_out ─► ROMD（custom_int.coe）─► spo
                            │
            PCPU (with INT) ◄── Data_read ◄── dm_controller ◄── MIO_BUS
              │
              │  内部新增: mie / mepc / int_pending
              │           CSR 写检测 (在 EX 阶段)
              │           int_taken / mret_taken
              │
              ├─ Addr_out, Data_out, mem_w, dm_ctrl
              ▼
          MIO_BUS（地址译码）
              ├──► RAM_B（0x0000_0000 段）
              ├──► SPIO（0xF000_0000，被 ISR 用作 LED 显示）
              ├──► Multi_8CH32（0xE000_0000，被 main loop 用作数码管显示）
              ├──► Counter_x
              └──► 0xD000_0xxx → 未路由（被 PCPU 内部捕获为 CSR 操作）
```

---

## 中断硬件机制

### 新增的 CSR / 状态寄存器

```verilog
reg        mie;          // 全局中断使能 (machine interrupt enable)
reg [31:0] mepc;         // 中断返回地址（被中断时的 PC）
reg        int_pending;  // INT 输入锁存，避免 stall 期间漏脉冲
```

- **`mie`**：复位为 0（屏蔽中断）。程序必须显式写 `0xD000_0000` 来开启。
- **`mepc`**：中断进入时由硬件锁存为"当前 PC"，即正要进入 IF 但被打断的那条指令地址；MRET 时 `PC ← mepc`，那条指令会被重新执行。
- **`int_pending`**：`INT` 输入只要拉高一拍，本位就锁住；中断进入时由硬件清零。这样 stall 周期里到来的中断脉冲不会丢失。

### 中断的 4 个关键时刻

| 时刻 | 触发条件 | 硬件动作 |
|------|----------|----------|
| **使能中断** | EX 阶段检测到 `sw ?, 0(x12)`（x12=0xD0000000） | 下一拍 `mie ← 1` |
| **关闭中断** | EX 阶段检测到 `sw ?, 4(x12)` | 下一拍 `mie ← 0` |
| **进入中断** | `int_pending && mie && !stall && !flush && !mret_taken` | 下一拍 `mepc ← PC`，`PC ← MTVEC = 0x80`，`mie ← 0`，`int_pending ← 0`，**冲刷 IF/ID** |
| **中断返回 (MRET)** | EX 阶段检测到 `sw ?, 8(x12)` | 下一拍 `PC ← mepc`，`mie ← 1`，**冲刷 IF/ID 和 ID/EX** |

PC 更新优先级链：

```
reset > stall > mret_taken > 分支 flush > int_taken > 顺序 PC+4
```

### 流水线一致性（精确异常）

进入中断只在 **IF 边界** 发生，所以：

- IF 阶段刚取到的指令（PC 上的那条）尚未提交，**丢弃**它（IF/ID ← NOP）。被丢弃的指令地址写入 `mepc`，MRET 时重新取指执行。
- ID 阶段及更后面的指令是"被中断点之前"已经派发出去的，**让它们正常完成**。所以 **ID/EX 不冲刷**。
- 这保证了：所有 `mepc` 之前的指令完成、`mepc` 及之后的指令都没有任何副作用——**精确单层中断**。

MRET 略不同：MRET 指令本身在 EX 阶段被检测，此时 ID/EX 和 IF/ID 都已装入了 MRET 之后的顺序指令（PC+4、PC+8），它们不应执行，所以 MRET 既冲 IF/ID 又冲 ID/EX。代价是 2 拍气泡。MRET 自身作为一条 sw 继续走完 MEM/WB，但写出的地址 `0xD000_0008` 未被 MIO_BUS 路由到任何外设，对外不可见。

CSR enable/disable（写 `0xD000_0000` / `0xD000_0004`）只更新内部 `mie`，**不冲刷流水线**——它们的语义就是"在这条 sw 之后的下一拍生效"，自然地随流水推进。

> **嵌套中断**：不支持。一旦进入 ISR，`mie ← 0`，再来的 INT 只是 `int_pending` 置位但不被取走，直到 ISR 用 MRET 还原 `mie = 1` 才会被处理。

### CSR 访问协议

| 地址 | sw 行为 | 备注 |
|------|---------|------|
| `0xD000_0000` | `mie ← 1`（开中断） | 写入数据值被忽略，只关心地址 |
| `0xD000_0004` | `mie ← 0`（关中断） | 同上 |
| `0xD000_0008` | MRET：`PC ← mepc`, `mie ← 1`，冲刷 IF/ID + ID/EX | 同上 |

`mepc` **当前没有暴露 lw 读口**——演示程序不需要查 mepc，只需"自动返回"。如需扩展，可加 `lw` 路径或额外内部接线，但这超出 Project 3 目标。

CPU 内部在 EX 阶段判断 `mem_w && Addr[31:28]==0xD`，然后：

1. **不把 mem_w 透给 MEM 阶段**（避免污染外部总线，见 PCPU.v 中的 `EX_MEM_mem_w <= ID_EX_mem_w && !ex_is_csr_write`）。
2. 根据低 8 位地址做内部状态更新。

---

## PCPU.v 改动一览

| 区段 | 改动 |
|------|------|
| 注释 / 常量 | 新增 `MTVEC = 0x80`、`CSR_SEG = 0xD`、`CSR_ENABLE/DISABLE/MRET` |
| 寄存器声明 | 新增 `mie`、`mepc`、`int_pending` |
| 前向声明 | 新增 `mret_taken`、`int_taken` |
| **PC 更新** | 优先级链插入 `mret → flush → int_taken → PC+4` |
| **IF/ID 寄存器** | flush 条件扩展为 `flush ‖ mret_taken ‖ int_taken` |
| **ID/EX 寄存器** | flush 条件扩展为 `flush ‖ stall ‖ mret_taken`（注意：**int_taken 不冲 ID/EX**） |
| EX 阶段 | 计算 `ex_is_csr_write / enable / disable / mret`；产生 `mret_taken` |
| EX/MEM 寄存器 | `EX_MEM_mem_w` 和 `EX_MEM_is_store` 与 `!ex_is_csr_write` 与门，避免外溢 |
| 新增 always 块 | 维护 `mie / mepc / int_pending` 状态机 |

代码总量增量约 **60 行**，对前递、Stall、Flush 等已有冒险逻辑没有任何修改。

---

## PCPU_TOP.v 改动一览

```verilog
// 中断源：BTN_out[1] 上升沿检测（Clk_CPU 域）
reg btn1_d;
always @(posedge Clk_CPU or posedge rst_i) begin
    if (rst_i) btn1_d <= 1'b0;
    else       btn1_d <= BTN_out[1];
end
wire int_pulse = BTN_out[1] & ~btn1_d;

// PCPU 实例化：将 INT 由 1'b0 改为 int_pulse
PCPU U1(
    ...
    .INT(int_pulse)
);
```

外设、显示、时钟分频、总线全部沿用 Project 2，**一行不改**。

> ROMD IP 核需要在 Vivado 中重新生成，加载本目录的 `custom_int.coe` 作为初始化文件。RAM_B 可以沿用 `D_snakeDEMO.coe`（程序不读这块）。

---

## 自定义小程序 custom_int.coe

### 程序结构

```
0x00:  lui   x11, 0xE0000        ; x11 = 0xE000_0000  数码管基址
0x04:  lui   x12, 0xD0000        ; x12 = 0xD000_0000  CSR  基址
0x08:  lui   x15, 0xF0000        ; x15 = 0xF000_0000  LED  基址
0x0C:  addi  x10, x0, 0          ; main 计数器  = 0
0x10:  addi  x14, x0, 0          ; ISR  计数器  = 0
0x14:  sw    x0,  0(x12)         ; ★ 开中断 (mie ← 1)

; ===== 主循环 =====
0x18:  addi  x10, x10, 1         ; counter++
0x1C:  sw    x10, 0(x11)         ; 数码管显示 counter
0x20:  jal   x0,  -8             ; → 0x18

; 0x24..0x7C: NOP 填充

; ===== ISR (硬件硬编码入口 0x80) =====
0x80:  addi  x14, x14, 1         ; ISR 计数器++
0x84:  sw    x14, 0(x15)         ; LED 显示 ISR cnt
0x88:  sw    x0,  8(x12)         ; ★ MRET：PC ← mepc, mie ← 1
```

寄存器约定：

- **主循环**：使用 `x10, x11, x12`
- **ISR**：使用 `x14, x15`
- 两组寄存器不重叠 → ISR 不需要保存/恢复任何寄存器；硬件 `mepc` 自动管理返回地址

### 机器码逐行解析

| PC | 机器码 | 助记符 | 说明 |
|----|--------|--------|------|
| 0x00 | `E00005B7` | `lui x11, 0xE0000` | 数码管基址 |
| 0x04 | `D0000637` | `lui x12, 0xD0000` | CSR 基址 |
| 0x08 | `F00007B7` | `lui x15, 0xF0000` | LED 基址 |
| 0x0C | `00000513` | `addi x10, x0, 0` | main cnt = 0 |
| 0x10 | `00000713` | `addi x14, x0, 0` | ISR cnt = 0 |
| 0x14 | `00062023` | `sw x0, 0(x12)` | **enable INT** |
| 0x18 | `00150513` | `addi x10, x10, 1` | counter++ |
| 0x1C | `00A5A023` | `sw x10, 0(x11)` | 数码管显示 |
| 0x20 | `FF9FF06F` | `jal x0, -8` | 跳回 0x18 |
| 0x80 | `00170713` | `addi x14, x14, 1` | ISR cnt++ |
| 0x84 | `00E7A023` | `sw x14, 0(x15)` | LED 显示 ISR cnt |
| 0x88 | `00062423` | `sw x0, 8(x12)` | **MRET** |

其余地址全部填 `0x00000013` (`addi x0, x0, 0` = NOP)，对硬件无副作用。

---

## 验收操作

> 默认 ROMD ← `custom_int.coe`，RAM_B ← `D_snakeDEMO.coe`（不读到，不影响）。

开关功能与 Project 2 一致。**`BTN_out[1]` 在本项目专用于触发中断**，请避免把它当作其他用途。

| 步骤 | SW 设定 | 操作 | 期望现象 | 验什么 |
|------|---------|------|----------|--------|
| 1 | `SW0=0`，`SW7..5=000`，`SW2=0`（快档） | 按 `rstn` 复位 | 数码管 `00000000 → 00000001 → 00000002 → …` 飞快递增；LED 全 0 | 主循环正常 + 中断默认关 → BTN1 未按时 LED 不动 |
| 2 | 同上 | **按一下 BTN1** | LED 低 16 位由 `0000 → 0001`；数码管递增不中断 | 中断进入 ISR 一次，自加 x14 写 LED，再 MRET 回主循环；mepc 机制让主循环计数无丢拍 |
| 3 | 同上 | 连续按 BTN1 几下 | LED `0001 → 0002 → 0003 → …` | 每次按键产生 1 拍 INT 脉冲 → `int_pending` 锁存 → 一拍内进入 ISR |
| 4 | `SW2=1`（慢档），`SW7..5=001` | 按 BTN1 | PC 字地址跳到 `0x80/4 = 0x20`，然后回到主循环 | 流水线确实跳到了 MTVEC，ISR 执行完后 PC 回到 `mepc/4` |
| 5 | `SW2=1`，`SW7..5=010` | 按 BTN1，慢慢看 | ISR 入口几个指令机器码：`00170713 → 00E7A023 → 00062423` | 反汇编对应 |
| 6 | `SW7..5=100` | — | `Adder_out` 显示 `sw` 的目标地址，按 BTN1 时能看到 `0xF000_0000`（LED 写）和 `0xD000_0008`（MRET） | 总线流量正确 |

**故障诊断：**

- **LED 永远不动**：检查 `int_pulse` 是否到了 PCPU——可能是 `mie` 没被开（PC=0x14 的 sw 没执行）。常见原因：`custom_int.coe` 没写进 ROMD IP；或 `MTVEC` 与 ROM 内 ISR 偏移不匹配。
- **按 BTN1 后 CPU 死锁**：检查 ISR 是否以 MRET (sw 到 0xD000_0008) 结束；否则 PC 会一直在 NOP 区域往后跑直到地址越界。
- **数码管乱跳**：检查 `EX_MEM_mem_w <= ID_EX_mem_w && !ex_is_csr_write` 是否生效——若 CSR 写漏到外部总线，可能误触 MIO_BUS 译码。

---

## 与 Project 1 / Project 2 的差异速查

| 维度 | Project 1（SCPU） | Project 2（PCPU） | **Project 3（PCPU + INT）** |
|------|-------------------|-------------------|-----------------------------|
| CPU 微架构 | 单周期 | 五级流水线 | 五级流水线 |
| 数据/控制冒险 | — | 前递 + Stall + Flush | 同 Project 2 |
| **CSR / 中断** | 无 | 无（`INT` 接 0） | **mie + mepc + int_pending + MTVEC** |
| **中断入口** | — | — | **0x0000_0080（硬编码）** |
| **中断协议** | — | — | **memory-mapped CSR（0xD000_00xx）** |
| **INT 源** | — | — | **BTN_out[1] 上升沿，1 拍脉冲** |
| 默认指令 ROM | `testac.coe` | `testac.coe` | **`custom_int.coe`（自带 main + ISR）** |
| 数码管 `data0` | 进度码 | 进度码 | 主循环计数器 (x10) |
| LED 16 位 | testac 进度低 16 位 | testac 进度低 16 位 | **ISR 计数器 (x14)** |
| 验证方式 | 看 "AC123456" | 看 "AC123456" | **按 BTN1 → LED++** |
| 顶层新增逻辑 | — | RAM 写保护门控 | + BTN1 上升沿检测 (`btn1_d`, `int_pulse`) |
| 流水线损失 | — | 分支 2 拍、load-use 1 拍 | + 进入中断 1 拍、MRET 2 拍 |

> **核心一句话**：Project 3 只在 PCPU 内部追加 ~60 行硬件（CSR + 状态机）、在 TOP 加 6 行（BTN 上升沿），把 Project 2 升级成具备精确单层中断的最小可用 RISC-V CPU；自定义小程序通过 memory-mapped CSR 控制中断，并演示了"主循环 + ISR 互不干扰"的经典使用模式。
