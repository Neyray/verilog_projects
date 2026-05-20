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

> **v2 改动**：之前简单的 `btn1_d <= BTN_out[1]` 直接在 `Clk_CPU` 域采样异步 `BTN_out[1]`，会因为机械按键 5–20 ms 的抖动出现**漏触发或多触发**（GPT 一眼看出来的硬伤）。v2 改成 *消抖 + 100MHz 同源边沿 + 拉宽 + 跨时钟 2-FF 同步 + Clk_CPU 域边沿* 的标准链路。

```verilog
// [A] 100MHz 域消抖 (~21ms 必须稳定才接受新电平)
reg [20:0] dbnc_cnt;
reg        btn1_dbnc;
always @(posedge clk or posedge rst_i)
    if (rst_i)                              {dbnc_cnt, btn1_dbnc} <= 0;
    else if (BTN_out[1] == btn1_dbnc)       dbnc_cnt <= 0;
    else if (&dbnc_cnt)                     btn1_dbnc <= BTN_out[1];
    else                                    dbnc_cnt <= dbnc_cnt + 1;

// [B] 100MHz 域上升沿 (同源时钟内做边沿一定不丢)
reg btn1_dbnc_d;
always @(posedge clk) btn1_dbnc_d <= btn1_dbnc;
wire btn1_rising = btn1_dbnc & ~btn1_dbnc_d;

// [C] 拉宽到 ~500ms (慢档 Clk_CPU 周期 333ms, 保证至少 1 次 posedge 命中)
reg [25:0] req_cnt; reg int_req;
always @(posedge clk)
    if (btn1_rising)                        {int_req, req_cnt} <= {1'b1, 26'd0};
    else if (int_req && req_cnt == 50_000_000) int_req <= 0;
    else if (int_req)                       req_cnt <= req_cnt + 1;

// [D] 跨时钟 2-FF 同步器
reg int_req_s0, int_req_s1;
always @(posedge Clk_CPU) {int_req_s1, int_req_s0} <= {int_req_s0, int_req};

// [E] Clk_CPU 域上升沿 → 单拍 INT 给 CPU
reg int_req_d;
always @(posedge Clk_CPU) int_req_d <= int_req_s1;
wire int_pulse = int_req_s1 & ~int_req_d;

PCPU U1( ... .INT(int_pulse) );
```

为什么需要这么复杂？

| 问题 | 旧实现 | v2 修复 |
|------|--------|---------|
| 按键抖动 5–20ms → 多次伪边沿 | 没消抖 | [A] 21ms 稳定才接受 |
| 异步信号在目标域直接采样 → 元稳态 | 单 FF 采样 | [B][C][D] 同源采样 → 拉宽 → 双 FF 同步 |
| 慢档 Clk_CPU 周期 333ms > 按键持续时间 → 漏触发 | 直接采按键电平 | [C] 把 1 拍宽脉冲拉宽到 500ms 再过桥 |
| 按住按键不放 → 持续触发 | 边沿检测可控 | 同样靠边沿，但是在干净的 `int_req` 上做边沿 |

外设、总线、时钟分频、`PCPU` 接口全部沿用 Project 2，**只改 INT 这一根线**。

### XDC 时钟约束（v2 关键修复）

旧的 [icf.xdc](icf.xdc) 第 3 行写的是 `create_clock ... -period 100.00`，**100ns 周期 = 10MHz**，但板子是 100MHz。Vivado 按 10MHz 做时序分析允许极长组合路径，实际跑 100MHz 时某些路径压在 setup/hold 边界 → 快档下出现"按 BTNU 偶尔无反应 / PC 显示偶尔跳错"。改成 `-period 10.00 -waveform {0 5}` 后 Vivado 才会真按 100MHz 约束布线。

> ROMD IP 核需要在 Vivado 中重新生成，加载本目录的 `custom_int.coe` 作为初始化文件。RAM_B 可以沿用 `D_snakeDEMO.coe`（程序不读这块）。

---

## 自定义小程序 custom_int.coe

> **v2 改版**：旧版主循环纯跑 `counter++`，在快档下 7-seg 直接糊成 "88888888"、按 BTN1 只点亮 LED0 一个位、肉眼几乎看不出来。新版用 **软件延时 + 跑马灯 + 醒目 ISR 标记** 让中断现象一目了然。

### 板上现象

| 阶段 | 7-seg 数码管 | 16 LED 灯条 |
|------|--------------|-------------|
| 主循环（默认） | 缓慢递增的小数字 (x13, 约 1.6 次/秒, 用 0xF0000 次内循环延时) | 一只灯由 LED0 → LED15 跑马灯滚动 (约 1.6 次/秒) |
| **按下 BTNU 瞬间** | **跳成 `CAFE00xx`（xx = 累计中断次数）** | **全部 16 灯齐亮 (`FFFF`)** |
| ISR 退出后 | 立刻恢复主循环递增 | 立刻恢复跑马灯 |

中断状态停留约 **2 秒**（ISR 内部 0x300000 次软件延时），不论按多快都来得及看清。

### 程序结构

```
═══ 初始化 ═══
0x00:  lui   x11, 0xE0000          ; 数码管基址
0x04:  lui   x12, 0xD0000          ; CSR 基址
0x08:  lui   x15, 0xF0000          ; LED 基址
0x0C:  addi  x10, x0, 1            ; LED 跑马灯位 = 0x0001
0x10:  addi  x13, x0, 0            ; 主计数 = 0
0x14:  addi  x14, x0, 0            ; ISR 计数 = 0
0x18:  sw    x0,  0(x12)           ; ★ mie ← 1 (开中断)

═══ 主循环 (PC = 0x1C) ═══
0x1C:  sw    x13, 0(x11)           ; 7-seg ← 主计数 x13
0x20:  sw    x10, 0(x15)           ; LED   ← 跑马灯 x10

;       软件延时 ~400ms (655K iter × 4 cyc/iter ≈ 2.6M cyc, 6.25MHz)
0x24:  addi  x16, x0, 0
0x28:  lui   x17, 0xA0              ; delay 上限 = 0xA0000
0x2C:  addi  x16, x16, 1
0x30:  bne   x16, x17, -4           ; 内循环

;       跑马灯左移；越过 LED15 后回卷到 LED0
0x34:  slli  x10, x10, 1
0x38:  lui   x21, 0x10               ; x21 = 0x10000 (越界标记)
0x3C:  bne   x10, x21, +8            ; if x10 ≠ 0x10000 跳过 reset
0x40:  addi  x10, x0, 1
0x44:  addi  x13, x13, 1             ; 主计数 ++
0x48:  jal   x0,  -44                ; 回到 0x1C

═══ ISR @ MTVEC = 0x80 ═══
0x80:  addi  x14, x14, 1             ; ISR 计数 ++
0x84:  lui   x18, 0xCAFE0             ; x18 = 0xCAFE_0000
0x88:  add   x18, x18, x14            ; x18 = 0xCAFE_0000 + x14
0x8C:  sw    x18, 0(x11)              ; ★ 7-seg ← "CAFE00xx"
0x90:  addi  x18, x0, -1              ; x18 = 0xFFFF_FFFF
0x94:  sw    x18, 0(x15)              ; ★ LED ← 0xFFFF (全亮)

;       ISR 延时 ~500ms 让醒目特征停留可见
0x98:  addi  x19, x0, 0
0x9C:  lui   x20, 0xC0                ; delay 上限 = 0xC0000
0xA0:  addi  x19, x19, 1
0xA4:  bne   x19, x20, -4

0xA8:  sw    x0,  8(x12)              ; ★ MRET (PC ← mepc, mie ← 1)
```

### 寄存器分工（关键 — 主/ISR 不冲突，免去保存现场）

| 用途 | 主循环 | ISR |
|------|--------|-----|
| 外设基址（只读） | x11, x12, x15 | x11, x12, x15 |
| 自身计数 | **x10**（跑马灯位）、**x13**（主计数） | **x14**（ISR 次数） |
| Scratch | **x16, x17, x21** | **x18, x19, x20** |

主循环和 ISR 使用的 scratch 寄存器**完全不重叠**，所以 ISR 不需要任何 `sw`/`lw` 来保存恢复——硬件的 `mepc` 已经管好返回 PC，剩下的只要不踩对方的寄存器就行。

### 机器码逐行解析（30 条有效指令，其余 994 字填 NOP）

| PC | 机器码 | 助记符 | 备注 |
|----|--------|--------|------|
| 0x00 | `E00005B7` | `lui x11, 0xE0000` | 7-seg base |
| 0x04 | `D0000637` | `lui x12, 0xD0000` | CSR base |
| 0x08 | `F00007B7` | `lui x15, 0xF0000` | LED base |
| 0x0C | `00100513` | `addi x10, x0, 1` | 跑马灯位 = 1 |
| 0x10 | `00000693` | `addi x13, x0, 0` | 主计数 = 0 |
| 0x14 | `00000713` | `addi x14, x0, 0` | ISR 计数 = 0 |
| 0x18 | `00062023` | `sw x0, 0(x12)` | **enable INT** |
| 0x1C | `00D5A023` | `sw x13, 0(x11)` | 7-seg ← x13 |
| 0x20 | `00A7A023` | `sw x10, 0(x15)` | LED ← x10 |
| 0x24 | `00000813` | `addi x16, x0, 0` | delay 重置 |
| 0x28 | `000F08B7` | `lui x17, 0xF0` | 主循环 delay 上限 (~630ms) |
| 0x2C | `00180813` | `addi x16, x16, 1` | delay ++ |
| 0x30 | `FF181EE3` | `bne x16, x17, -4` | delay loop |
| 0x34 | `00151513` | `slli x10, x10, 1` | 跑马灯左移 |
| 0x38 | `00010AB7` | `lui x21, 0x10` | 0x10000 |
| 0x3C | `01551463` | `bne x10, x21, +8` | 未越界则跳过 |
| 0x40 | `00100513` | `addi x10, x0, 1` | 越界回卷 |
| 0x44 | `00168693` | `addi x13, x13, 1` | 主计数 ++ |
| 0x48 | `FD5FF06F` | `jal x0, -44` | 回 0x1C |
| 0x80 | `00170713` | `addi x14, x14, 1` | ISR 计数 ++ |
| 0x84 | `CAFE0937` | `lui x18, 0xCAFE0` | 醒目前缀 |
| 0x88 | `00E90933` | `add x18, x18, x14` | + x14 |
| 0x8C | `0125A023` | `sw x18, 0(x11)` | **★ 7-seg ← CAFExxxx** |
| 0x90 | `FFF00913` | `addi x18, x0, -1` | 0xFFFFFFFF |
| 0x94 | `0127A023` | `sw x18, 0(x15)` | **★ LED ← FFFF** |
| 0x98 | `00000993` | `addi x19, x0, 0` | ISR delay 重置 |
| 0x9C | `00300A37` | `lui x20, 0x300` | ISR delay 上限 (~2.0s, 让 CAFE 停留久一些) |
| 0xA0 | `00198993` | `addi x19, x19, 1` | ISR delay ++ |
| 0xA4 | `FF499EE3` | `bne x19, x20, -4` | ISR delay loop |
| 0xA8 | `00062423` | `sw x0, 8(x12)` | **★ MRET** |

完整逐行注释见同目录的 [`custom_int.s`](custom_int.s)。其余地址全部填 `0x00000013` (`addi x0, x0, 0` = NOP)，对硬件无副作用。

### 仿真验证

`iverilog` 仿真（stub ROM + PCPU.v）已确认：

| 检查项 | 结果 |
|--------|------|
| 复位后 `PC=0x14` 的 sw 把 `mie` 拉成 1 | ✅ 仿真中 `mie=1` |
| INT 脉冲触发 → `PC ← 0x80`，`mepc` 保存当时的主循环 PC | ✅ `ISR ENTRY: mepc=0x34` |
| ISR 内 `sw x18, 0(x11)` → 总线观察到 `Addr=0xE0000000, Data=0xCAFE0001` | ✅ |
| ISR 内 `sw x18, 0(x15)` → 总线观察到 `Addr=0xF0000000, Data=0xFFFFFFFF` | ✅ |
| `sw x0, X(x12)` 全部被 PCPU 内部消化、**不会**出现在外部 `mem_w` 总线 | ✅ `csr_writes=0` |

---

## 验收操作

> 默认 ROMD ← `custom_int.coe`，RAM_B ← `D_snakeDEMO.coe`（不读到，不影响）。

开关功能与 Project 2 一致。**`BTN_out[1]` 在本项目专用于触发中断**，请避免把它当作其他用途。

| 步骤 | SW 设定 | 操作 | 期望现象 | 验什么 |
|------|---------|------|----------|--------|
| 1 | `SW0=0`，`SW7..5=000`，`SW2=0`（快档） | 按 `rstn` 复位 | 7-seg 缓慢递增小数字 `00000001 → 00000002 → …`（约 2~3 次/秒）；LED 一只灯由 LED0 → LED15 跑马灯滚动 | 主循环正常，软件延时让现象肉眼可见 |
| 2 | 同上 | **按一下 BTNU** | 7-seg 立刻跳到 **`CAFE0001`**，**16 个 LED 全部点亮**，停约 0.5 s，然后恢复 | 中断进入 ISR，写出醒目特征 + ISR 延时让效果可见，MRET 后主循环无丢拍 |
| 3 | 同上 | 连续按 BTNU 几下 | 每按一次 → `CAFE0001 → CAFE0002 → CAFE0003 → …` | 每次按键产生 1 拍 INT 脉冲 → `int_pending` 锁存 → 进入 ISR + `x14` 累加 |
| 4 | `SW2=1`（慢档），`SW7..5=001` | 按 BTNU | PC 字地址从主循环区（6~12）瞬间跳到 `0x20`（=byte 0x80=MTVEC），走 ISR 几条指令后回到主循环 | 慢档下能逐字看见跳转 |
| 5 | `SW2=1`，`SW7..5=010` | 按 BTNU，慢慢看 | ISR 几条机器码依次出现：`00170713 → CAFE0937 → 00E90933 → 0125A023 → FFF00913 → 0127A023 → … → 00062423` | 与 [`custom_int.s`](custom_int.s) 反汇编对应 |
| 6 | `SW7..5=100` | — | `Adder_out` 显示 `sw` 目标地址：主循环时 `0xE000_0000`/`0xF000_0000` 交替；按 BTNU 时短暂看到 `0xD000_0008`（MRET 地址，但 mem_w 已被内部抑制） | 总线流量正确；CSR 写不溢出 |

**故障诊断（v2 后大多数旧问题已修复，下表只列残留可能性）：**

- **按 BTNU 完全没反应（7-seg 不 flash, LED 不全亮）**：
  1. 确认 `custom_int.coe` 已写进 ROMD IP（在 Vivado IP Sources 里 Re-customize 选这个 coe + Generate）。
  2. 确认顶层 `PCPU.INT` 接的是 `int_pulse` 而不是 `1'b0`。
  3. 确认 `MTVEC = 0x80` 与 ROM 偏移一致（30 条有效指令对的上 0x00..0xA8）。
  4. 确认 BTNU 物理引脚 = M18（[icf.xdc](icf.xdc) 第 73 行），按上面那颗"上"键，不是左/右/中/下。
- **按 BTNU 后 CPU 死锁（不再跑主循环）**：ISR 缺 MRET。确认 `0xA8` 是 `00062423`（sw x0, 8(x12)）。
- **数码管出现非 `CAFE` 的怪值**：可能是 CSR 写漏到外部总线，触发了 MIO_BUS 误译码。检查 [PCPU.v](PCPU.v) 第 525 行 `EX_MEM_mem_w <= ID_EX_mem_w && !ex_is_csr_write` 与第 528 行 `EX_MEM_is_store` 同款保护是否存在。
- **快档下按 BTNU 偶尔不响应 / PC 跳错（v1 老问题，v2 已修）**：v1 在 `Clk_CPU` 域直接采异步按键 + xdc 时钟周期写错（100ns 应是 10ns），导致：
  - 机械按键 5–20ms 抖动被边沿检测误拆成多个伪脉冲（或刚好夹缝中漏掉一次）；
  - Vivado 按 10MHz 约束布线，某些路径实际跑 100MHz 时压在边界 → 偶发抽搐。
  - 修复：[PCPU_TOP.v](PCPU_TOP.v) v2 加了 21ms 消抖 + 100MHz 同源边沿 + 500ms 拉宽 + 2-FF 跨时钟同步；[icf.xdc](icf.xdc) `create_clock` 周期由 100.00 改成 10.00。
- **CAFE 闪一下就过去了（v1 老问题，v2 已修）**：v1 ISR 延时 0xC0000 ≈ 500ms。v2 改成 0x300000 ≈ 2.0 秒，且寄存器分工严格隔离，不会因为按多次连按搞乱 x16/x17 主循环 delay loop。
- **慢档按 BTNU 偶尔不响应（部分缓解）**：慢档 `Clk_CPU ≈ 3 Hz`，每拍 333 ms。v2 把 INT 请求拉宽到 500ms，**保证至少 1 个 `Clk_CPU` posedge 命中**；但如果你 0.5 秒内连按两次，第二次会被第一次"吃掉"（int_req 一直高，没有新的上升沿）。慢档下间隔 ≥ 0.6 秒按即可。

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
| 默认指令 ROM | `testac.coe` | `testac.coe` | **`custom_int.coe`（自带 main + ISR + 软件延时）** |
| 数码管 `data0` | 进度码 | 进度码 | 主循环计数器 x13（被 ISR 临时覆盖为 `CAFE00xx`） |
| LED 16 位 | testac 进度低 16 位 | testac 进度低 16 位 | **主循环跑马灯位 x10 / ISR 时全亮 `FFFF`** |
| 验证方式 | 看 "AC123456" | 看 "AC123456" | **按 BTNU → 7-seg 闪 `CAFE00xx` + LED 全亮** |
| 顶层新增逻辑 | — | RAM 写保护门控 | + **完整中断 IO 链路**：消抖 (clk 域 ~21ms) + 100MHz 同源边沿 + 500ms 拉宽 + 2-FF 跨时钟同步器 + Clk_CPU 域边沿 |
| 时钟约束 (xdc) | `-period 100.00` (10MHz, **错的**) | 同 P1 | **`-period 10.00`** (100MHz, 修正) |
| 流水线损失 | — | 分支 2 拍、load-use 1 拍 | + 进入中断 1 拍、MRET 2 拍 |

> **核心一句话**：Project 3 在 PCPU 内部追加 ~60 行硬件（CSR + 中断状态机）、在 TOP 加 ~50 行（消抖 + 拉宽 + 双 FF 同步 + 双边沿检测）、并修了 xdc 的 100MHz 时钟约束，把 Project 2 升级成具备**精确单层中断 + 可靠按键中断源**的最小可用 RISC-V CPU；自定义小程序通过 memory-mapped CSR 控制中断，演示"主循环跑马灯 / ISR `CAFE` 全亮"的强对比效果。
