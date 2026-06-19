# Project 3 — 流水线 RV32I CPU + 三类 trap（外部中断 / ecall / 异常）

本项目在 Project 2 的五级流水线 PCPU 上实现了一个最小化、可验收的 **trap（陷入）架构**。它不是只把按钮接到 CPU，而是有完整的 trap 源、pending 锁存、`mepc` 返回地址、`mcause` 类型寄存器、CSR 读写协议，以及统一的 ISR 分发。

按计算机体系结构的经典口径，本设计实现了 **三类 trap**：

| `mcause` | trap 类型 | 触发来源 | 性质 | 板上表现 |
|----------|-----------|----------|------|----------|
| `1` | **外部中断** | `BTNC/BTNU/BTNL/BTNR` 任意按键 | 异步、可被 `mie` 屏蔽 | `E71000ee` |
| `2` | **系统调用 ecall** | `ecall` 指令（复位后自动执行一次） | 同步、随指令产生 | `EC4110ss` |
| `3` | **异常（非法指令）** | 非法指令 `0xFFFFFFFF`（主循环若干拍后自动执行一次） | 同步、随指令产生 | `EACE00xx` |

> **三类 trap 的本质区别**：外部中断是**异步**的，由外部信号 `INT` 在指令边界注入，受全局使能 `mie` 控制；ecall 与异常是**同步**的，由 CPU 在 EX 阶段译码当前指令时产生，不受 `mie` 屏蔽。三者最终都通过同一个入口 `MTVEC=0x80` 进入 ISR，由 ISR 读 `mcause` 分发。

正常态数码管显示 `A0cc__ss`，低位汇总三类 trap 的发生次数；详见[显示编码](#显示编码)。

> 烧板前必须让 ROMD 重新加载新版 `custom_int.coe`，否则硬件改了但程序仍是旧 ISR。

---

## 文件清单

| 文件 | 作用 |
|------|------|
| `PCPU.v` | 五级流水线 CPU，新增 `mie / mepc / mcause / int_pending` 和 CSR 读写、ecall/异常同步 trap |
| `PCPU_TOP.v` | 顶层 SoC，把 4 个按键经同步/消抖/边沿处理后合成外部中断 `INT`，接入 PCPU |
| `custom_int.s` | 自定义程序源码：复位后自动产生 ecall 与非法指令，按键产生外部中断，ISR 读 `mcause` 分发三类 trap |
| `custom_int.coe` | `custom_int.s` 对应的 ROM 初始化文件 |
| `clk_div.v` | CPU 快/慢档时钟，`SW2=0` 快档（≈6.25MHz），`SW2=1` 慢档（≈3Hz） |
| `icf.xdc` | Nexys A7 引脚和 100MHz 时钟约束 |

---

## 整体结构

```text
BTNC/BTNU/BTNL/BTNR ─ 2FF同步 ─ 消抖 ─ 空闲电平学习 ─ 边沿 ─ 事件toggle ─ 跨时钟同步 ─ 展宽 ┐
                                                                                          ├─► INT[2:0] ─► PCPU
                                            （timer 计数器保留但未接入，避免周期事件干扰验收）┘

PCPU 内部（trap 仲裁）：
  ecall 指令      ─► trap_taken, mcause=2 ┐
  非法指令        ─► trap_taken, mcause=3 ├─► mepc <= PC，PC <= MTVEC(0x80)，mie <= 0
  INT 上升沿 + mie ─► int_taken,  mcause=1 ┘

ISR（0x80）：
  lw x28, 12(x12)   # 读 0xD000_000C = mcause
  mcause=1 -> isr_external  外部中断计数
  mcause=2 -> isr_ecall     ecall 计数
  mcause=3 -> isr_exception 异常计数
  sw x0, 8(x12)     # 写 0xD000_0008，触发 MRET 返回 mepc
```

---

## 三类 trap 与验收

### 类型 1：外部中断（`mcause=1`）

来源：`BTNC / BTNU / BTNL / BTNR` 任意一个按键。顶层把这 4 个原始异步按钮经过完整的同步/消抖/边沿链路，最终合成送入 PCPU 的 `INT`。无论按下哪个键，CPU 仲裁后都给出 `mcause=1`（顶层虽按 BTNC/BTNU 与 BTNL/BTNR 分了两类事件位，但都归并为同一类外部中断）。

板上验收：

1. 设置 `SW7..5=000`，`SW2=0`，复位。
2. 按下任意一个用户按键（上、下、左、右、中）。
3. 数码管短暂显示 `E7100001`，再按一次显示 `E7100002`……
4. 正常态 `A0cc__ss` 中 `cc` 变为 `01`，证明 `mcause=1` 被 ISR 读到。

关键代码：

| 功能 | 位置 |
|------|------|
| 4 个原始异步按钮取入 | `PCPU_TOP.v:121` |
| 2-FF 同步到 100MHz 域 | `PCPU_TOP.v:124-134` |
| 每键 5ms 稳态消抖 | `PCPU_TOP.v:137-158` |
| 复位后学习每键空闲电平（兼容 active-high/low） | `PCPU_TOP.v:161-176` |
| 偏离空闲电平→pressed→上升沿 | `PCPU_TOP.v:179-190` |
| 跨时钟到 `Clk_CPU` 域 + 边沿检测 + 展宽 | `PCPU_TOP.v:199-241` |
| 合成 `int_sources` 接入 `PCPU.INT` | `PCPU_TOP.v:262`、`PCPU_TOP.v:277` |
| CPU 仲裁 `INT → mcause=1` | `PCPU.v:531-540` |
| ISR 分发到 `isr_external` | `custom_int.s:39-40` |
| 外部中断计数与显示 | `custom_int.s:47-51`、`custom_int.s:85-88` |

### 类型 2：系统调用 ecall（`mcause=2`）

来源：`ecall` 指令。程序在 `_start` 开中断后立即执行一条 `ecall`，CPU 在 EX 阶段识别 `ecall`，产生同步 trap，`mcause=2`。ecall 不受 `mie` 屏蔽。

板上验收：

1. 设置 `SW7..5=000`，`SW2=0`，复位。
2. 复位后立刻出现 `EC411000`（ecall 计数 = 1）。
3. 正常态 `A0cc__ss` 中 `cc` 变为 `02`，证明 `mcause=2` 被 ISR 读到。

关键代码：

| 功能 | 位置 |
|------|------|
| 程序自动执行一次 `ecall` | `custom_int.s:31` |
| ID 阶段识别 `ecall`（`inst==0x00000073`） | `PCPU.v:191` |
| EX 阶段产生 `ecall` trap，`mcause=2` | `PCPU.v:518`、`PCPU.v:520-522` |
| `mepc <= ecall 的下一条`（跳过 ecall，防止 MRET 后反复 trap） | `PCPU.v:557` |
| ISR 分发到 `isr_ecall` | `custom_int.s:41-42` |
| ecall 计数与显示 | `custom_int.s:53-58`、`custom_int.s:90-94` |

### 类型 3：异常 / 非法指令（`mcause=3`）

来源：非法指令 `0xFFFFFFFF`。主循环跑过若干拍后（由 `x23` 倒计时控制），会执行一条用 `.word 0xffffffff` 埋入的非法指令。CPU 在 ID 阶段做合法性检查，EX 阶段对非法指令产生同步 trap，`mcause=3`。异常同样不受 `mie` 屏蔽。

板上验收：

1. 设置 `SW7..5=000`，`SW2=0`，复位。
2. 等待主循环跑几拍后，出现 `EACE0001`（异常计数 = 1）。
3. 正常态 `A0cc__ss` 中 `cc` 变为 `03`，证明 `mcause=3` 被 ISR 读到。

关键代码：

| 功能 | 位置 |
|------|------|
| ID 阶段指令合法性检查 | `PCPU.v:214-218` |
| 主循环延时后埋入非法指令 | `custom_int.s:123-130` |
| EX 阶段产生异常 trap，`mcause=3` | `PCPU.v:519`、`PCPU.v:520-522` |
| `mepc <= 非法指令的下一条`（跳过它，避免反复 trap） | `PCPU.v:557` |
| ISR 分发到 `isr_exception` | `custom_int.s:43-44` |
| 异常计数与显示 | `custom_int.s:60-64`、`custom_int.s:96-99` |

---

## CPU trap 架构

### CSR 寄存器

| 寄存器 | 含义 | 实现位置 |
|--------|------|----------|
| `mie` | 全局中断使能，1 表示允许进入**外部中断**（不影响 ecall/异常） | `PCPU.v:91` |
| `mepc` | trap 返回地址 | `PCPU.v:92` |
| `mcause` | 当前被服务的 trap 类型（1/2/3） | `PCPU.v:93` |
| `int_pending` | 外部中断 pending 锁存 | `PCPU.v:94` |
| `int_d` | `INT` 边沿采样，避免长按/展宽请求重复入队 | `PCPU.v:95` |

### CSR 地址协议

CSR 访问复用 load/store 指令，地址落在 `0xD000_00xx` 段。该段被 PCPU 在 EX 阶段拦下，不会真正写到 RAM/外设。

| 地址 | 软件操作 | 硬件含义 | 实现位置 |
|------|----------|----------|----------|
| `0xD000_0000` | `sw x0, 0(x12)` | `mie <- 1`，开中断 | `PCPU.v:75`、`PCPU.v:575-578` |
| `0xD000_0004` | `sw x0, 4(x12)` | `mie <- 0`，关中断 | `PCPU.v:76`、`PCPU.v:579-582` |
| `0xD000_0008` | `sw x0, 8(x12)` | MRET，`PC <- mepc`，`mie <- 1` | `PCPU.v:77`、`PCPU.v:126-127`、`PCPU.v:570-573` |
| `0xD000_000C` | `lw x28, 12(x12)` | 读 `mcause` | `PCPU.v:78`、`PCPU.v:509` |
| `0xD000_0010` | `lw` | 读 `int_pending`，调试用 | `PCPU.v:79`、`PCPU.v:510` |
| `0xD000_0014` | `lw` | 读 `mepc`，调试用 | `PCPU.v:80`、`PCPU.v:511` |

### 进入 trap

PC 更新优先级（`PCPU.v:121-136`）：

```
reset > stall > mret > trap(ecall/异常) > 分支flush > 外部中断 > 顺序 PC+4
```

#### 同步 trap（ecall / 异常）

```verilog
ex_ecall_taken     = ID_EX_is_ecall && !stall && !flush && !mret_taken;   // PCPU.v:518
ex_exception_taken = ID_EX_illegal  && !stall && !flush && !mret_taken;   // PCPU.v:519
trap_taken         = ex_ecall_taken || ex_exception_taken;               // PCPU.v:520
trap_cause_next    = ex_ecall_taken ? 2 : 3;                             // PCPU.v:521-522
```

进入时（`PCPU.v:556-561`）：`mepc <= ID_EX_PC + 4`（跳过当前 ecall/非法指令），`mcause <= 2 或 3`，`mie <= 0`。

#### 外部中断

```verilog
int_event       = INT & ~int_d;                              // 上升沿事件，PCPU.v:531
irq_pending_now = int_pending | int_event;                   // PCPU.v:532
int_taken = (irq_pending_now != 0) && mie
            && !stall && !flush && !mret_taken && !trap_taken; // PCPU.v:540
```

进入时（`PCPU.v:563-568`）：`mepc <= IF_ID_valid ? IF_ID_PC : PC`（返回被冲掉的那条指令），`mcause <= 1`，`mie <= 0`，清掉本次服务的 pending 位、保留其余 pending。

> `int_pending` 把单拍的 `INT` 锁存下来，这样即使中断到来时正处于 `stall` 或 `mie=0`，请求也不会丢失，等条件满足后再进入。

### trap 返回

ISR 末尾执行 `sw x0, 8(x12)`，CPU 在 EX 阶段识别地址 `0xD000_0008` 生成 `mret_taken`：

- MRET 检测：`PCPU.v:504`、`PCPU.v:516`
- PC 恢复到 `mepc`：`PCPU.v:126-127`
- MRET 时重新打开中断（`mie<-1`）：`PCPU.v:570-573`

### 精确 trap

本设计是单层、精确 trap：

- IF/ID 在 `flush/mret/trap/int` 时冲刷，丢弃刚取到但还没提交的指令：`PCPU.v:155-159`
- ID/EX 在同样条件下插入气泡，防止 IF/ID 里的跳转流入 EX 覆盖 `MTVEC`：`PCPU.v:301-327`
- 外部中断的 `mepc` 指向被冲掉的指令，MRET 后重新执行，无副作用丢失；ecall/异常的 `mepc` 指向其下一条，避免 MRET 后反复 trap。

---

## CSR Load 如何返回 `mcause`

普通外设没有 `0xD000_000C`，所以 `mcause` 不能从 MIO_BUS 读，必须由 CPU 内部返回。

| 阶段 | 代码 | 位置 |
|------|------|------|
| EX | 判断 `alu_out[31:28]==0xD` 且当前是 load | `PCPU.v:499`、`PCPU.v:501` |
| EX | 按低 8 位地址选择 `mcause/pending/mepc/mie` | `PCPU.v:507-514` |
| EX/MEM | 保存 CSR 读数，屏蔽外部 load/store | `PCPU.v:643-648` |
| Forward | CSR 读数参与前递 | `PCPU.v:661-665` |
| WB | `wb_data` 选择 CSR 读数写回寄存器 | `PCPU.v:719-723` |

软件侧读取：

```asm
lw x28, 12(x12)     # x12 = 0xD0000000，地址 = 0xD000000C，读到 mcause
```

位置：`custom_int.s:36`。

---

## 小程序说明

### 启动后的自动时序

```text
_start(0x00)  初始化基址、计数器、moving LED
   │  sw x0,0(x12)        开中断 mie=1            custom_int.s:29
   │  ecall               → 同步 trap mcause=2    custom_int.s:31
   │                        ISR: isr_ecall，显示 EC411
   │  jal main_loop(0x180)
   ▼
main_loop  循环刷新 LED + 数码管
   │  跑过 x23 倒计时后执行 .word 0xffffffff
   │                      → 同步 trap mcause=3    custom_int.s:129
   │                        ISR: isr_exception，显示 EACE
   ▼
任意时刻按键 → 外部中断 mcause=1 → ISR: isr_external，显示 E7100
```

### 寄存器分工

| 寄存器 | 用途 |
|--------|------|
| `x11` | 数码管基址 `0xE0000000` |
| `x12` | CSR 基址 `0xD0000000` |
| `x15` | LED 基址 `0xF0000000` |
| `x5` | 外部中断次数 |
| `x6` | ecall 次数 |
| `x7` | 异常次数 |
| `x8` | 上一次 `mcause` |
| `x9` | 状态提示倒计时 |
| `x10` | 状态提示类型 1=外部/2=ecall/3=异常 |
| `x13` | 移动光标 LED 位 |
| `x23` | 非法指令演示倒计时 |
| `x28` | ISR 中读到的 `mcause` |

### 显示编码

| 显示 | 含义 | 位置 |
|------|------|------|
| `A0cc__ss` | 正常态：`cc`=上次 `mcause`，低位汇总三类计数 | `custom_int.s:101-109` |
| `E71000ee` | 外部中断次数 | `custom_int.s:85-88` |
| `EC4110ss` | ecall 次数 | `custom_int.s:90-94` |
| `EACE00xx` | 异常次数 | `custom_int.s:96-99` |

LED（`0xF000_0000`，`custom_int.s:70-76`）：`LED[3:0]`=移动光标，`LED[7:4]`=外部中断计数低 4 位，`LED[11:8]`=ecall 计数，`LED[15:12]`=异常计数。

---

## 板上完整验收流程

设置：`SW7..5=000`，`SW2=0`（快档），`SW0` 无关（P3 固定纯 hex 显示）。

| 步骤 | 操作 | 期望现象 | 说明 |
|------|------|----------|------|
| 1 | 复位 | 极短暂出现 `EC411000`，随后进入 `A002...` 正常态 | ecall 自动触发，`mcause=2` |
| 2 | 等待主循环几拍 | 出现 `EACE0001`，正常态 `cc` 变 `03` | 非法指令自动触发，`mcause=3` |
| 3 | 按任意按键 | 出现 `E7100001`，正常态 `cc` 变 `01` | 外部中断，`mcause=1` |
| 4 | `SW2=1`、`SW7..5=111` 看 `PC_out`，再按键 | PC 跳到 `0x80` 执行 ISR 后回到原 PC 附近 | `mepc` 保存/恢复正确 |
| 5 | `SW2=1`、`SW7..5=010` 看指令 | 进入 ISR 第一条机器码是 `00C62E03` | 即 `lw x28, 12(x12)`，ISR 先读 `mcause` |

---

## 核心代码行号速查

### `PCPU.v`

| 内容 | 行号 |
|------|------|
| 中断入口 `MTVEC=0x80` | `PCPU.v:73` |
| CSR 地址定义 | `PCPU.v:74-80` |
| `mie/mepc/mcause/int_pending/int_d` | `PCPU.v:91-95` |
| PC 更新优先级 | `PCPU.v:121-136` |
| IF/ID 冲刷 | `PCPU.v:155-159` |
| ID/EX 气泡 | `PCPU.v:301-327` |
| ecall 识别 | `PCPU.v:191` |
| 非法指令检测 | `PCPU.v:214-218` |
| CSR 读出 `mcause/pending/mepc/mie` | `PCPU.v:507-514` |
| MRET 检测 | `PCPU.v:516` |
| ecall/异常同步 trap | `PCPU.v:518-522` |
| 外部中断 pending + 进入条件 | `PCPU.v:531-540` |
| CSR/trap 状态更新（保存 mepc/mcause） | `PCPU.v:545-587` |
| CSR load 写回 | `PCPU.v:719-723` |

### `PCPU_TOP.v`

| 内容 | 行号 |
|------|------|
| 4 个原始按钮取入 | `PCPU_TOP.v:121` |
| 2-FF 同步 | `PCPU_TOP.v:124-134` |
| 消抖 | `PCPU_TOP.v:137-158` |
| 空闲电平学习 | `PCPU_TOP.v:161-176` |
| pressed + 边沿 | `PCPU_TOP.v:179-190` |
| 事件 toggle | `PCPU_TOP.v:192-196` |
| 跨时钟同步 + 边沿 + 展宽 | `PCPU_TOP.v:199-241` |
| `int_sources` 合成（timer 未接入） | `PCPU_TOP.v:244-262` |
| 接入 `PCPU.INT` | `PCPU_TOP.v:277` |

### `custom_int.s`

| 内容 | 行号 |
|------|------|
| 初始化基址/计数器 | `custom_int.s:15-27` |
| 开中断 | `custom_int.s:29` |
| 自动 `ecall` | `custom_int.s:31` |
| ISR 入口 `0x80`，读 `mcause` | `custom_int.s:34-37` |
| 三类 trap 分发 | `custom_int.s:39-45` |
| `isr_external / isr_ecall / isr_exception` | `custom_int.s:47-64` |
| 主循环入口 `0x180` | `custom_int.s:66-67` |
| 显示分支 | `custom_int.s:85-109` |
| 埋入非法指令 | `custom_int.s:123-130` |

---

## 注意事项

- 修改 `custom_int.s` 后必须重新生成并加载 `custom_int.coe`。
- 当前是单层 trap，不支持嵌套；进入后 `mie=0`，MRET 后恢复为 1。`mie` 只屏蔽**外部中断**，ecall/异常作为同步 trap 不受 `mie` 影响。
- 顶层保留了周期 `timer` 计数器（`PCPU_TOP.v:244-260`）但未接入 `INT`（`int_sources` 中间位固定为 `0`），以免周期事件干扰三类 trap 的验收；如需第四类周期中断，可把 `btn_irq` 那样的脉冲接到中间位。
- `icf.xdc` 已把时钟约束修正为真 100MHz（`-period 10.00`），旧版误写成 `100.00`（实际 10MHz）会在快档下造成按键漂移。
