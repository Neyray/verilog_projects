# Project 3 — 流水线 RV32I CPU + 中断 + 自定义小程序

> 在 [Project 2](../project2/README.md) 的五级流水线 PCPU 上**新增最小化精确中断（单层、不嵌套）**，并烧入自定义的"序列锁"反应小游戏：主循环负责显示与移动光标，按 `BTN1/BTNU` 既是确认键也是中断源；ISR 只判定一次按键并更新游戏状态、立即 MRET 回到主循环。

---

## 目录

- [文件清单](#文件清单)
- [整体结构](#整体结构)
- [✦ 中断如何"返回原状态"（验收重点 ①）](#-中断如何返回原状态验收重点-)
  - [硬件侧：mepc 保存与恢复的代码位置](#硬件侧mepc-保存与恢复的代码位置)
  - [软件侧：ISR 如何主动触发 MRET](#软件侧isr-如何主动触发-mret)
  - [一拍一拍走一次中断进入 + 返回](#一拍一拍走一次中断进入--返回)
  - [ISR 返回延迟到底有多短](#isr-返回延迟到底有多短)
- [中断硬件机制（参考）](#中断硬件机制参考)
  - [新增的 CSR / 状态寄存器](#新增的-csr--状态寄存器)
  - [中断的 4 个关键时刻](#中断的-4-个关键时刻)
  - [流水线一致性（精确异常）](#流水线一致性精确异常)
  - [CSR 访问协议](#csr-访问协议)
- [PCPU.v / PCPU_TOP.v 改动一览](#pcpuv--pcpu_topv-改动一览)
- [✦ 自定义小程序 custom_int.coe（验收重点 ②）](#-自定义小程序-custom_intcoe验收重点-)
  - [板上现象](#板上现象)
  - [程序结构与寄存器分工](#程序结构与寄存器分工)
  - [机器码入口速查](#机器码入口速查)
- [验收操作（含故障诊断）](#验收操作含故障诊断)
- [与 Project 1 / Project 2 的差异速查](#与-project-1--project-2-的差异速查)

---

## 文件清单

| 文件 | 来源 | 说明 |
|------|------|------|
| `PCPU.v` | Project 2 + **本项目修改** | 流水线 CPU 核，**新增 CSR 寄存器和中断流水机制** |
| `PCPU_TOP.v` | Project 2 + **本项目修改** | 顶层 SoC，**新增 BTN1 消抖 + 跨时钟 + 边沿检测 → INT 脉冲** |
| `custom_int.coe` | **本项目新建** | 自定义演示程序的 ROM 初始化文件（1024 word） |
| `custom_int.s` | **本项目新建** | 演示程序的汇编源（可读注释版） |
| `dm_controller.v` / `MIO_BUS.v` / `Multi_8CH32.v` / `SPIO.v` / `SSeg.v` / `Counter_x.v` / `Enter.v` / `clk_div.v` | Project 2 | 外设无改动，直接复用 |
| `D_snakeDEMO.coe` | Project 2 | 数据 RAM 初始化（沿用，演示程序未读这块） |
| `testac.coe` / `I_pipemem37.coe` | Project 2 | 备用 ROM（可切换回去做对照） |
| `icf.xdc` | Project 2 (**关键修正**) | 引脚约束 + 时钟周期从 100ns 改为 **10ns（真 100MHz）** |

> ⚠️ **关键硬约束：** `PCPU.v` 内把中断入口硬编码为 `MTVEC = 0x0000_0080`。`custom_int.coe` 的 ISR 必须放在偏移 0x80（字索引 32）。

---

## 整体结构

```
btn_i, sw_i ─► Enter ─► BTN_out, SW_out
                            │
                ┌──── BTN_out[1]：[消抖] [边沿] [拉宽] [2-FF 同步] [Clk_CPU 域边沿]
                │              ──────────────► int_pulse (Clk_CPU 域 1 拍宽)
                │                                          │
clk ─► clk_div ─► Clk_CPU + clkdiv[31:0]                  │
                            │                              │
PC_out ─► ROMD（custom_int.coe）─► spo                     │
                            │                              ▼
            PCPU (with INT) ◄── Data_read ◄── …      INT ──┘
              │  内部新增：mie / mepc / int_pending
              │           CSR 写检测 (EX 阶段)
              │           int_taken / mret_taken
              ▼
          MIO_BUS（地址译码）
              ├──► RAM_B（0x0000_0000）
              ├──► SPIO（0xF000_0000，LED：高 8 位=目标，低 8 位=光标）
              ├──► Multi_8CH32（0xE000_0000，数码管：状态码）
              ├──► Counter_x
              └──► 0xD000_0xxx → 未路由（CPU 内部当作 CSR）
```

---

## ✦ 中断如何"返回原状态"（验收重点 ①）

> 这一节用来回答验收的核心问题：**"中断处理完之后，CPU 是怎么知道要回到原来那条指令的？体现在哪个文件、哪一行？"**

### 硬件侧：mepc 保存与恢复的代码位置

**保存被打断的 PC（进入中断时）** — [`PCPU.v:463-490`](PCPU.v)

```verilog
// PCPU.v 第 463~490 行（CSR / 中断状态更新）
always @(posedge clk or posedge reset) begin
    if (reset) begin
        mie         <= 1'b0;
        mepc        <= 32'h0;
        int_pending <= 1'b0;
    end else begin
        if (INT) int_pending <= 1'b1;          // 1) INT 输入锁存

        if (int_taken) begin                   // 2) 进入中断 ★
            mepc        <= PC;                 //   ← ★ 保存当前 PC 到 mepc
            mie         <= 1'b0;               //   关中断，禁止嵌套
            int_pending <= 1'b0;               //   pending 清掉
        end
        else if (mret_taken) mie <= 1'b1;      // 3) MRET 时重新开中断
        else if (ex_is_csr_enable)  mie <= 1'b1;
        else if (ex_is_csr_disable) mie <= 1'b0;
    end
end
```

这里 `mepc <= PC` 抓住的就是"被打断的 IF 阶段那条指令的地址"。同一拍 IF/ID 被冲刷为 NOP（[`PCPU.v:139-142`](PCPU.v)），所以这条指令**完全没产生任何副作用**——可以放心重做。

**恢复 PC（MRET 触发时）** — [`PCPU.v:108-123`](PCPU.v)

```verilog
// PCPU.v 第 108~123 行（PC 更新优先级链）
always @(posedge clk or posedge reset) begin
    if (reset)            PC <= 32'h0;
    else if (stall)       PC <= PC;
    else if (mret_taken)  PC <= mepc;          // ★ 中断返回：PC 回到 mepc
    else if (flush)       PC <= branch_target;
    else if (int_taken)   PC <= MTVEC;         // 进入 ISR
    else                  PC <= PC + 32'd4;
end
```

`mret_taken` 由 EX 阶段检测 `sw ?, 8(x12)` 产生（[`PCPU.v:445-450`](PCPU.v)）：

```verilog
wire ex_is_csr_write = ID_EX_mem_w && (alu_out[31:28] == CSR_SEG);
wire ex_is_csr_mret  = ex_is_csr_write && (alu_out[7:0] == CSR_MRET);
assign mret_taken    = ex_is_csr_mret;
```

并且 MRET 同时冲刷 IF/ID 与 ID/EX（[`PCPU.v:139, 251`](PCPU.v)），把 ISR 后顺序取到的两条无效指令清掉。

### 软件侧：ISR 如何主动触发 MRET

ISR 退出**不是靠某条特殊的硬件指令**，而是靠**一条普通的 store 指令** —— `sw x0, 8(x12)`（其中 `x12 = 0xD000_0000`，目标地址 `0xD000_0008`）。CPU 内部把这个地址当作"MRET CSR"捕获，并把 mem_w 屏蔽掉（不送外部总线，见 [`PCPU.v:528, 531`](PCPU.v)）。

[`custom_int.s`](custom_int.s) 中 ISR 的三个返回点：

```asm
isr_correct:                       # 命中目标，stage++
    ...
    sw    x0, 8(x12)               # custom_int.s:61  → MRET (WIN 路径)
isr_step_ok:
    ...
    sw    x0, 8(x12)               # custom_int.s:66  → MRET (OK 路径)
isr_wrong:
    ...
    sw    x0, 8(x12)               # custom_int.s:73  → MRET (BAD 路径)
```

**ISR 中并没有显式保存/恢复寄存器！** 因为：
- 主循环只用 `x10/x13/x14/x16/x18/x23/x24/x25/x26/x27/x30/x31/x8/x9`，ISR 只用 `x28/x29` 作 scratch，**两边不重叠**；
- 主循环本就和 ISR 共享 `x13`(stage) / `x14`(penalty) / `x16`(win) / `x23`(flash count) / `x24`(flash kind) —— 这些就是"被 ISR 写、被主循环读"的状态字，**故意共享**。

省去了 push/pop 寄存器堆的开销，所以返回非常快。

### 一拍一拍走一次中断进入 + 返回

把 `mepc=0xP0`、ISR=0x80~0xCC、主循环 PC=P0 这次中断展开看：

```
拍号 │  IF      │  ID         │  EX         │  MEM      │  WB       │  事件
─────┼──────────┼─────────────┼─────────────┼───────────┼───────────┼────────────────────
 N   │ P0       │ <prev>      │ ...         │ ...       │ ...       │ int_pending=1, mie=1
 N+1 │ 0x80(MT) │ NOP(flush)  │ <prev>      │ ...       │ ...       │ ★ mepc<=P0, PC<=0x80
 N+2 │ 0x84     │ 0x80        │ NOP         │ <prev>    │ ...       │
 ... │ (ISR 体)                                                       │
 M   │ 0xD0+    │ 0xCC sw     │ 0xC8        │ ...       │ ...       │
 M+1 │ 0xD4     │ 0xD0        │ 0xCC sw★    │ 0xC8      │ ...       │ ★ mret_taken
 M+2 │ P0       │ NOP(flush)  │ NOP(flush)  │ 0xCC sw   │ 0xC8      │ ★ PC<=mepc=P0
 M+3 │ P0+4     │ P0          │ NOP         │ NOP       │ 0xCC sw   │ 主循环正常推进
```

- **进入中断只丢 IF 阶段那 1 条指令** —— ID/EX 等已发射的指令照常完成（精确异常）。
- **MRET 丢 IF/ID + ID/EX 两条** —— 因为 MRET 之后 2 条顺序取到的代码是 ISR 内的无关指令。
- MRET 这条 sw 自己继续走完 MEM/WB，但 [`PCPU.v:528`](PCPU.v) 已经把 `EX_MEM_mem_w` 与 `!ex_is_csr_write` 与门，所以**不会真往总线写**。

### ISR 返回延迟到底有多短

- 进入中断：1 拍气泡。
- ISR 体指令数（含分支）：最坏 stage 3 路径约 11~13 条 + WIN/OK/BAD 末尾 3~5 条 ≈ **15 条左右**。
- 流水化执行，IPC≈1，含一两次分支 flush。
- MRET：2 拍气泡。

**合计 ≈ 18~22 个 Clk_CPU 拍。**
- 快档 `Clk_CPU ≈ 6 MHz` → 约 **3 µs**，肉眼完全无法察觉。
- 慢档 `Clk_CPU ≈ 3 Hz` → 约 **7 秒**（每拍 0.33s），慢档本来就是给单步看的。

> 对比旧版 v1：ISR 里有软件延时循环（数十万拍），返回前 LED/数码管会被"占住"几秒钟。**v3 已经彻底去掉 ISR 内的延时**，状态提示（OK/BAD/WIN 字样）改由主循环在返回后自然刷新（`x23/x24` 是倒计时和提示类型），所以中断响应快、主循环画面立刻接续，体现"中断没有改变原来程序的执行轨迹"。

---

## 中断硬件机制（参考）

### 新增的 CSR / 状态寄存器

```verilog
reg        mie;          // 全局中断使能 (machine interrupt enable)
reg [31:0] mepc;         // 中断返回地址（被中断时的 PC）
reg        int_pending;  // INT 输入锁存，避免 stall 期间漏脉冲
```

- **`mie`**：复位为 0（屏蔽中断）。程序必须显式写 `0xD000_0000` 来开启。
- **`mepc`**：见上节"硬件侧"。
- **`int_pending`**：`INT` 拉高一拍就锁住；中断进入时由硬件清零，stall 期间到来的中断脉冲不会丢失。

### 中断的 4 个关键时刻

| 时刻 | 触发条件 | 硬件动作 | 代码位置 |
|------|----------|----------|----------|
| **使能中断** | EX 检测到 `sw ?, 0(x12)` (x12=0xD0000000) | 下一拍 `mie ← 1` | [`PCPU.v:483-485`](PCPU.v) |
| **关闭中断** | EX 检测到 `sw ?, 4(x12)` | 下一拍 `mie ← 0` | [`PCPU.v:486-488`](PCPU.v) |
| **进入中断** | `int_pending && mie && !stall && !flush && !mret_taken` | `mepc←PC`、`PC←MTVEC=0x80`、`mie←0`、`int_pending←0`、**冲 IF/ID** | [`PCPU.v:473-477`](PCPU.v) + [`PCPU.v:119-120`](PCPU.v) |
| **中断返回 (MRET)** | EX 检测到 `sw ?, 8(x12)` | `PC←mepc`、`mie←1`、**冲 IF/ID + ID/EX** | [`PCPU.v:115-116`](PCPU.v) + [`PCPU.v:479-481`](PCPU.v) |

PC 更新优先级链（[`PCPU.v:110-123`](PCPU.v)）：

```
reset > stall > mret_taken > 分支 flush > int_taken > 顺序 PC+4
```

### 流水线一致性（精确异常）

进入中断只在 **IF 边界** 发生，所以：

- IF 阶段刚取到的指令尚未提交，**丢弃**（IF/ID ← NOP）。被丢弃的指令地址写入 `mepc`，MRET 时重新取指。
- ID 阶段及更后面的指令是"被中断点之前"已经派发的，**让它们正常完成**。`int_taken` 不会冲 ID/EX（[`PCPU.v:251`](PCPU.v) 注释强调这一点）。
- 因此 **所有 `mepc` 之前的指令完成、`mepc` 及之后的指令都没有副作用** —— 精确单层中断。

MRET 略不同：MRET 指令本身在 EX 检测，此时 ID/EX 与 IF/ID 都已装了 MRET 之后的顺序指令（无意义的 ISR 尾部），它们不应执行，所以 MRET 同时冲 IF/ID + ID/EX（2 拍气泡）。

> **嵌套中断**：不支持。`mie ← 0` 后再来的 INT 只锁 `int_pending`，要 MRET 把 `mie` 还原为 1 才会被处理。

### CSR 访问协议

| 地址 | sw 行为 | 备注 |
|------|---------|------|
| `0xD000_0000` | `mie ← 1`（开中断） | 写入数据值被忽略，只看地址 |
| `0xD000_0004` | `mie ← 0`（关中断） | 同上 |
| `0xD000_0008` | MRET：`PC ← mepc`, `mie ← 1`，冲刷 IF/ID + ID/EX | 同上 |

CPU 内部在 EX 阶段判 `mem_w && Addr[31:28]==0xD`，然后：

1. **不把 mem_w 透给 MEM 阶段**（[`PCPU.v:528`](PCPU.v)：`EX_MEM_mem_w <= ID_EX_mem_w && !ex_is_csr_write`），避免污染外部总线。
2. 根据低 8 位地址做内部状态更新。

---

## PCPU.v / PCPU_TOP.v 改动一览

**PCPU.v：**

| 区段 | 改动 | 行数 |
|------|------|------|
| 常量声明 | 新增 `MTVEC = 0x80`、`CSR_SEG = 0xD`、`CSR_ENABLE/DISABLE/MRET` | [`PCPU.v:68-72`](PCPU.v) |
| 寄存器声明 | 新增 `mie`、`mepc`、`int_pending` | [`PCPU.v:83-85`](PCPU.v) |
| **PC 更新** | 优先级链插入 `mret → flush → int_taken → PC+4` | [`PCPU.v:110-123`](PCPU.v) |
| **IF/ID 寄存器** | flush 条件扩展为 `flush ‖ mret_taken ‖ int_taken` | [`PCPU.v:139-142`](PCPU.v) |
| **ID/EX 寄存器** | flush 条件扩展为 `flush ‖ stall ‖ mret_taken`（**int_taken 不冲 ID/EX**） | [`PCPU.v:251`](PCPU.v) |
| EX 阶段 | 检测 `ex_is_csr_write / enable / disable / mret`；产生 `mret_taken` | [`PCPU.v:445-450`](PCPU.v) |
| EX/MEM 寄存器 | `EX_MEM_mem_w / EX_MEM_is_store` 与 `!ex_is_csr_write` 与门 | [`PCPU.v:528, 531`](PCPU.v) |
| 新增 always 块 | 维护 `mie / mepc / int_pending` 状态机 | [`PCPU.v:463-490`](PCPU.v) |

代码总量增量约 **60 行**，对前递、Stall、Flush 等已有冒险逻辑没有任何修改。

**PCPU_TOP.v：** 只改 INT 这一根线。从 BTN_out[1] 到 PCPU.INT 的五段链路：

```verilog
// PCPU_TOP.v 第 112~170 行
// [A] 100MHz 域消抖 (~21ms 必须稳定才接受新电平)
reg [20:0] dbnc_cnt;  reg btn1_dbnc;
always @(posedge clk or posedge rst_i)
    if (rst_i)                              {dbnc_cnt, btn1_dbnc} <= 0;
    else if (BTN_out[1] == btn1_dbnc)       dbnc_cnt <= 0;
    else if (&dbnc_cnt)                     btn1_dbnc <= BTN_out[1];
    else                                    dbnc_cnt <= dbnc_cnt + 1;

// [B] 100MHz 域上升沿（同源时钟内做边沿一定不丢）
reg btn1_dbnc_d;
always @(posedge clk) btn1_dbnc_d <= btn1_dbnc;
wire btn1_rising = btn1_dbnc & ~btn1_dbnc_d;

// [C] 拉宽到 ~500ms（慢档 Clk_CPU 周期 333ms，保证至少 1 次 posedge 命中）
reg [25:0] req_cnt;  reg int_req;
always @(posedge clk)
    if (btn1_rising)                            {int_req, req_cnt} <= {1'b1, 26'd0};
    else if (int_req && req_cnt == 50_000_000)  int_req <= 0;
    else if (int_req)                           req_cnt <= req_cnt + 1;

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

| 问题 | 旧实现（v1） | v2 修复 |
|------|--------------|---------|
| 按键抖动 5~20ms → 多次伪边沿 | 没消抖 | [A] 21ms 稳定才接受 |
| 异步信号在目标域直接采样 → 元稳态 | 单 FF 采样 | [B][C][D] 同源采样 → 拉宽 → 双 FF 同步 |
| 慢档 Clk_CPU 周期 333ms > 按键持续时间 → 漏触发 | 直接采按键电平 | [C] 拉宽到 500ms 再过桥 |
| 按住按键不放 → 持续触发 | 边沿可控但毛刺漏 | 在干净的 `int_req` 上做边沿 |

**XDC 时钟约束的关键修复：** 旧版 [`icf.xdc`](icf.xdc) 写 `-period 100.00`（=10MHz，不对！板子是 100MHz）。Vivado 按 10MHz 跑时序分析允许极长组合路径，实际 100MHz 时某些路径压在 setup/hold 边界 → 快档下偶尔无反应。改成 `-period 10.00 -waveform {0 5}` 后才真正按 100MHz 约束布线。

> ROMD IP 核需在 Vivado 重新生成，加载 `custom_int.coe`。RAM_B 可继续沿用 `D_snakeDEMO.coe`（程序不读这块）。

---

## ✦ 自定义小程序 custom_int.coe（验收重点 ②）

> **v3 改版**：旧版只是跑马灯 + ISR 长延时，交互性弱、中断返回慢。新版改成 **BTNU 序列锁小游戏**：主循环负责动态显示，ISR 只判定一次按键并更新状态，立即 MRET。

### 板上现象

| 状态 | 7-seg 数码管 (`SW7..5=000`) | 16 LED 灯条 |
|------|------------------------------|-------------|
| 正常游戏 | `A000ppss`：`pp`=罚分次数，`ss`=当前进度 0..3 | `LED[7:0]` 是移动光标，`LED[15:8]` 是当前目标位 |
| 按对一次 | 短暂显示 `C0DE000s`，进度 `s` 增加 | 继续显示下一关目标和移动光标 |
| 按错一次 | 短暂显示 `BAD000pp`，罚分 `pp` 增加 | 进度清零，目标回到第一关 |
| 完成 4 步 | 短暂显示 `600D00ww`，胜利次数 `ww` 增加 | 进度清零，重新开始下一轮 |

目标顺序固定为：`0x02 → 0x08 → 0x01 → 0x10`。玩家需要在低 8 位光标等于当前高 8 位目标时按 `BTNU`。没按到目标会触发惩罚：罚分 +1，进度回 0。

### 程序结构与寄存器分工

```
0x00: 初始化外设基址、游戏状态，写 0xD000_0000 开中断
0x28: jal main_loop，跳过中断向量区

0x80: ISR（必须放这里——MTVEC 硬编码）
      根据稳定的 stage 重新计算目标值
      if cursor == target:
          stage++；满 4 步则 win++ 且 stage=0
      else:
          penalty++；stage=0
      设置短暂状态提示标记 (x23/x24)
      sw x0, 8(x12)   ; ★ MRET

0x100: main_loop
       计算当前目标，LED[15:8]=目标 / LED[7:0]=光标，sw 到 0xF000_0000
       数码管显示 A000ppss / C0DE000s / BAD000pp / 600D00ww
       软件延时后左移光标（5 位循环 1→2→4→8→16→1），jal 回 main_loop
```

| 寄存器 | 用途 | 谁写 | 谁读 |
|--------|------|------|------|
| `x10` | 光标 mask，循环 `1,2,4,8,16` | 主循环 | 主循环 + ISR（比较） |
| `x11` | 7-seg 基址 `0xE000_0000` | 初始化 | 主循环 |
| `x12` | CSR 基址 `0xD000_0000` | 初始化 | 主循环 + ISR |
| `x15` | LED 基址 `0xF000_0000` | 初始化 | 主循环 |
| `x13` | **序列进度 stage**（共享状态） | 初始化 + ISR | 主循环 + ISR |
| `x14` | **罚分 penalty**（共享状态） | 初始化 + ISR | 主循环 |
| `x16` | **胜利计数 win**（共享状态） | 初始化 + ISR | 主循环 |
| `x23` | **flash 倒计时**（共享状态） | 初始化 + ISR | 主循环 |
| `x24` | **flash 类型** 1=OK 2=BAD 3=WIN（共享） | 初始化 + ISR | 主循环 |
| `x18, x25-x27, x30, x31, x8, x9` | 主循环 scratch | 主循环 | 主循环 |
| `x28, x29` | ISR scratch（与主循环不重叠） | ISR | ISR |

**关键设计：** ISR 只 push 不 pop 寄存器（连 push 都不做！）—— 因为 ISR scratch (`x28/x29`) 和主循环 scratch 完全不重叠；ISR 写的"共享状态字"本来就是要被主循环看到的；所以**省去了上下文保存的全部开销**，ISR 真正只做"决策 + 更新状态字 + MRET"。

### 机器码入口速查

| PC | 机器码 | 助记符 | 备注 |
|----|--------|--------|------|
| `0x00` | `E00005B7` | `lui x11, 0xE0000` | 数码管基址 |
| `0x04` | `D0000637` | `lui x12, 0xD0000` | CSR 基址 |
| `0x08` | `F00007B7` | `lui x15, 0xF0000` | LED 基址 |
| `0x24` | `00062023` | `sw x0, 0(x12)` | 开中断（mie ← 1） |
| `0x28` | `0D80006F` | `jal x0, 0x100` | 跳到主循环 |
| `0x80` | `00200E13` | `addi x28, x0, 2` | ISR 入口（MTVEC），默认第一关目标 |
| `0xAC` | `03C51863` | `bne x10, x28, isr_wrong` | 判断按键是否命中目标 |
| `0xCC / 0xD8 / 0xEC` | `00062423` | `sw x0, 8(x12)` | 三条路径都快速 MRET |
| `0x100` | `00200913` | `addi x18, x0, 2` | 主循环入口 |

完整可汇编源见 [`custom_int.s`](custom_int.s)。`custom_int.coe` 共 1024 word，未使用的位置填 `0x00000013`（`addi x0, x0, 0`，即 NOP）。

---

## 验收操作（含故障诊断）

> 默认 ROMD ← `custom_int.coe`，RAM_B ← `D_snakeDEMO.coe`（本程序不读数据 RAM）。
> 开关功能与 Project 2 一致。`BTN_out[1]` / `BTNU` 在本项目中**既是游戏确认键也是中断源**。

### 验收 checklist（建议按顺序）

| 步骤 | SW 设定 | 操作 | 期望现象 | 验什么（对应代码） |
|------|---------|------|----------|---------------------|
| 1 | `SW0=0`，`SW7..5=000`，`SW2=0`（快档） | 复位 | 数码管显示 `A0000000`；LED 高 8 位 `0x0200`，低 8 位光标在 `01/02/04/08/10` 循环移动 | 主循环 + 小程序状态机 + LED/数码管 IO 正常 ([`custom_int.s:76`](custom_int.s)+) |
| 2 | 同上 | 光标到 `0x02` 时按 `BTNU` | 数码管短暂显示 `C0DE0001`，几帧后变 `A0000001` | **进中断 → ISR 比较命中 → MRET 返回**；x13 stage 被 ISR 推到 1 ([`custom_int.s:50-66`](custom_int.s)) |
| 3 | 同上 | 依次在 `0x08`、`0x01`、`0x10` 命中按键 | 第 4 次命中后显示 `600D0001`，然后回到 `A0000000` | 完整序列通过，win 计数 +1（ISR WIN 路径 [`custom_int.s:53-61`](custom_int.s)） |
| 4 | 同上 | 故意在非目标位置按 `BTNU` | 显示 `BAD00001`，几帧后变 `A0000100` | 错误输入触发惩罚，penalty +1 且 stage 清零（ISR BAD 路径 [`custom_int.s:68-73`](custom_int.s)） |
| 5 | `SW2=1`（慢档），`SW7..5=111`（看 PC 字节地址） | 按 `BTNU` | PC 从主循环段（≥ 0x100）跳到 `0x80`，走十几条后**回到原 PC 附近 +4** | **中断进入与返回路径正确**——验证"返回原状态"：PC 没有跳到一个随机位置 ([`PCPU.v:116, 474`](PCPU.v)) |
| 6 | `SW2=1`，`SW7..5=010`（看当前指令机器码） | 慢速观察一次中断 | ISR 第一条是 `00200E13`，最后三条 MRET 都是 `00062423` | ROM 内容与 [`custom_int.s`](custom_int.s) 对应 |
| 7 | `SW2=1`，`SW7..5=001`（看 PC>>2） | 持续按 BTNU 多次 | 主循环画面不会"卡住"或长时间停在 ISR 区 | **ISR 没有软件延时，中断返回延迟非常短**（约 18~22 拍） |

> 步骤 5 是验收的"杀手锏"问法——肉眼看到 PC 跳进 ISR 又干净地跳回原位置，就是中断"返回原状态"的最直观证据。配合 README 中标 ★ 的两行 Verilog 解释。

### 故障诊断

| 现象 | 排查 |
|------|------|
| 按 BTNU 完全没反应 | ① ROMD IP 是否重新加载了 `custom_int.coe`；② `PCPU.INT` 是否接 `int_pulse`；③ `icf.xdc` 周期是否已改为 10ns |
| 按键后长时间停在 ISR 显示 | 检查 ROM 中 `0xCC/0xD8/0xEC` 是否都为 `00062423`；新版 ISR 没有软件延时，提示由主循环刷新 |
| 经常按错 | 这是游戏逻辑在工作。低 8 位光标必须与高 8 位目标同列时按下；错误会罚分并重置进度 |
| 慢档下连续快按少记一次 | 顶层把一次按键请求拉宽约 500ms 以保证慢 CPU 时钟能采到；慢档连续按键建议间隔 > 0.6s |
| 中断返回到错误的 PC | 检查 [`PCPU.v:474`](PCPU.v) `mepc <= PC` 是否用 `PC` 而不是 `PC+4`、[`PCPU.v:116`](PCPU.v) `PC <= mepc` 是否在 `mret_taken` 分支 |

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
| 默认指令 ROM | `testac.coe` | `testac.coe` | **`custom_int.coe`（序列锁 main + 快速 ISR）** |
| 数码管 `data0` | 进度码 | 进度码 | `A000ppss` 正常态 / `C0DE`、`BAD`、`600D` 状态提示 |
| LED 16 位 | testac 进度 | testac 进度 | **高 8 位目标 + 低 8 位移动光标** |
| 验收方式 | 看 "AC123456" | 看 "AC123456" | **按 BTNU 完成 `0x02→0x08→0x01→0x10`，错按罚分** |
| 顶层新增逻辑 | — | RAM 写保护门控 | + **完整中断 IO 链路**：消抖 (~21ms) + 100MHz 同源边沿 + 500ms 拉宽 + 2-FF 跨时钟同步 + Clk_CPU 域边沿 |
| 时钟约束 (xdc) | `-period 100.00` (10MHz, **错的**) | 同 P1 | **`-period 10.00`** (100MHz, 修正) |
| 流水线损失 | — | 分支 2 拍、load-use 1 拍 | + 进入中断 1 拍、MRET 2 拍 |

> **核心一句话：** Project 3 在 PCPU 内部追加 CSR + 中断状态机（保存/恢复 PC 的代码集中在 [`PCPU.v:110-123, 463-490`](PCPU.v)），在 TOP 搭建可靠按键中断链路，并把自定义程序升级为"目标顺序 + 按钮确认 + 错误惩罚 + 快速 MRET"的序列锁小游戏。
