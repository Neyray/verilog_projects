# Project 3 — 流水线 RV32I CPU + 三类中断架构 + 自定义小程序

本项目在 Project 2 的五级流水线 PCPU 上实现了一个最小化、可验收的中断架构。它不是只把按钮接到 CPU，而是有完整的中断源、pending 锁存、优先级仲裁、`mepc` 返回地址、`mcause` 中断类型寄存器、CSR 读写协议，以及统一 ISR 分发。

当前支持 3 类中断：

| `mcause` | 中断类型 | 来源 | 板上表现 | 作用 |
|----------|----------|------|----------|------|
| `1` | BTN1 游戏确认中断 | `BTNC/BTNU / btn_i[0]/btn_i[1]` | `C0DE000s`、`BAD000pp`、`600D00ww` | 小程序确认按键 |
| `2` | timer 周期中断 | `PCPU_TOP.v` 内部计时器 | `710E00tt` | 证明系统能主动周期中断 |
| `3` | BTNL 辅助中断 | `BTNL/BTNR / btn_i[2]/btn_i[3]` | `A11000aa` | 证明可扩展第三类外部中断 |

正常态数码管显示 `A0ccppss`：

- `cc`：上一次中断类型，即 `mcause`
- `pp`：错误次数 penalty
- `ss`：当前游戏进度 stage

> 烧板前必须让 ROMD 重新加载新版 `custom_int.coe`，否则硬件改了但程序仍是旧 ISR。

---

## 文件清单

| 文件 | 作用 |
|------|------|
| `PCPU.v` | 五级流水线 CPU，新增 `mie / mepc / mcause / int_pending[2:0]` 和 CSR 读写 |
| `PCPU_TOP.v` | 顶层 SoC，产生三路 `INT[2:0]`：BTN1/BTNC/BTNU、timer、BTNL/BTNR |
| `custom_int.s` | 自定义程序源码，ISR 读取 `mcause` 后分发三类中断 |
| `custom_int.coe` | `custom_int.s` 对应的 ROM 初始化文件 |
| `clk_div.v` | CPU 快/慢档时钟，`SW2=0` 快档，`SW2=1` 慢档 |
| `icf.xdc` | Nexys A7 引脚和 100MHz 时钟约束 |

---

## 整体结构

```text
BTN1/BTNC/BTNU ── 消抖 ─ 边沿 ─ 事件 toggle ─ 2FF 同步 ┐
timer     ── 计数到期产生 1 拍脉冲                ├─► INT[2:0] ─► PCPU
BTNL/BTNR ── 消抖 ─ 边沿 ─ 事件 toggle ─ 2FF 同步 ┘

PCPU 内部：
  INT[2:0] ─► int_pending[2:0] ─► 优先级仲裁 ─► mcause
                                      │
                                      ├─► mepc <= PC
                                      ├─► PC <= MTVEC = 0x80
                                      └─► mie <= 0

ISR：
  lw x21, 12(x12)    # 读 0xD000_000C，也就是 mcause
  mcause=1 -> 游戏确认
  mcause=2 -> timer 计数
  mcause=3 -> BTNL/BTNR 辅助计数
  sw x0, 8(x12)      # 写 0xD000_0008，触发 MRET
```

---

## 中断类型与验收

### 类型 1：BTN1 / BTNC/BTNU 游戏确认中断

来源：`BTNC` 或 `BTNU`，顶层端口 `btn_i[0]` 或 `btn_i[1]`。

板上验收：

1. 设置 `SW7..5=000`，`SW2=0`。
2. 复位后数码管显示 `A0000000`。
3. LED 低 8 位光标循环移动，LED15 亮时按 `BTNC` 或 `BTNU`。
4. 按对显示 `C0DE0001`，按错显示 `BAD000pp`，完成四步显示 `600D00ww`。
5. 正常态的 `A0ccppss` 中 `cc` 会变成 `01`，证明 `mcause=1` 被读到并显示出来。

关键代码：

| 功能 | 位置 |
|------|------|
| BTN1 原始输入映射为中断按钮 bit0 | `PCPU_TOP.v:113` |
| BTN1/BTNC/BTNU 和 BTNL/BTNR 消抖 | `PCPU_TOP.v:110-135` |
| 按键上升沿检测 | `PCPU_TOP.v:137-143` |
| 事件 toggle 跨时钟 | `PCPU_TOP.v:145-170` |
| `INT[0]` 接入 CPU | `PCPU_TOP.v:189`、`PCPU_TOP.v:204` |
| ISR 读取 `mcause` | `custom_int.s:40-44` |
| ISR 分发到 `isr_button` | `custom_int.s:45-46` |
| 游戏确认逻辑 | `custom_int.s:53-103` |

### 类型 2：timer 周期中断

来源：`PCPU_TOP.v` 内部 `timer_cnt`。在快档 `Clk_CPU≈6.25MHz` 下，`TIMER_RELOAD=6_250_000`，约 1 秒触发一次。

板上验收：

1. 设置 `SW7..5=000`，`SW2=0`。
2. 复位后等待约 1 秒。
3. 数码管短暂显示 `710E0001`，之后 timer 次数继续增加为 `710E0002`、`710E0003`。
4. 正常态 `A0ccppss` 中 `cc` 会变成 `02`，证明 `mcause=2` 被读到并显示出来。

关键代码：

| 功能 | 位置 |
|------|------|
| timer reload 常量 | `PCPU_TOP.v:172-173` |
| timer 计数并产生 1 拍中断 | `PCPU_TOP.v:174-187` |
| `INT[1]` 接入 CPU | `PCPU_TOP.v:189`、`PCPU_TOP.v:204` |
| CPU 仲裁 `INT[1] -> mcause=2` | `PCPU.v:475-483` |
| ISR 分发到 `isr_timer` | `custom_int.s:47-48` |
| timer 次数加一并设置显示类型 | `custom_int.s:105-109` |
| 数码管显示 `710E00tt` | `custom_int.s:157-160` |

### 类型 3：BTNL/BTNR 辅助中断

来源：`BTNL` 或 `BTNR`，顶层端口 `btn_i[2]` 或 `btn_i[3]`。它不影响游戏状态，只证明系统还能扩展第三类外部中断。

板上验收：

1. 设置 `SW7..5=000`，`SW2=0`。
2. 按 `BTNL` 或 `BTNR`。
3. 数码管短暂显示 `A1100001`，再次按显示 `A1100002`。
4. 正常态 `A0ccppss` 中 `cc` 会变成 `03`，证明 `mcause=3` 被读到并显示出来。

关键代码：

| 功能 | 位置 |
|------|------|
| BTNL/BTNR 原始输入映射为中断按钮 bit1 | `PCPU_TOP.v:113` |
| BTNL/BTNR 消抖/边沿/toggle | `PCPU_TOP.v:117-170` |
| `INT[2]` 接入 CPU | `PCPU_TOP.v:189`、`PCPU_TOP.v:204` |
| CPU 仲裁 `INT[2] -> mcause=3` | `PCPU.v:475-483` |
| ISR 分发到 `isr_aux` | `custom_int.s:49-50` |
| BTNL/BTNR 次数加一并设置显示类型 | `custom_int.s:111-115` |
| 数码管显示 `A11000aa` | `custom_int.s:161-164` |

---

## CPU 中断架构

### CSR 寄存器

| 寄存器 | 含义 | 实现位置 |
|--------|------|----------|
| `mie` | 全局中断使能，1 表示允许进入中断 | `PCPU.v:87` |
| `mepc` | 中断返回地址 | `PCPU.v:88` |
| `mcause` | 当前被服务的中断类型 | `PCPU.v:89` |
| `int_pending[2:0]` | 三路中断 pending 锁存 | `PCPU.v:90` |

### CSR 地址协议

| 地址 | 软件操作 | 硬件含义 | 实现位置 |
|------|----------|----------|----------|
| `0xD000_0000` | `sw x0, 0(x12)` | `mie <- 1`，开中断 | `PCPU.v:71`、`PCPU.v:510-512` |
| `0xD000_0004` | `sw x0, 4(x12)` | `mie <- 0`，关中断 | `PCPU.v:72`、`PCPU.v:514-516` |
| `0xD000_0008` | `sw x0, 8(x12)` | MRET，`PC <- mepc` | `PCPU.v:73`、`PCPU.v:120-121` |
| `0xD000_000C` | `lw x21, 12(x12)` | 读 `mcause` | `PCPU.v:74`、`PCPU.v:457-464` |
| `0xD000_0010` | `lw` | 读 `int_pending[2:0]`，调试用 | `PCPU.v:75`、`PCPU.v:461` |
| `0xD000_0014` | `lw` | 读 `mepc`，调试用 | `PCPU.v:76`、`PCPU.v:462` |

### 进入中断

进入中断的条件：

```verilog
int_taken = (irq_pending_now != 3'b000) && mie && !stall && !flush && !mret_taken;
```

实现位置：`PCPU.v:475-485`。

进入中断时硬件做四件事：

1. `mepc <= PC` 保存返回地址：`PCPU.v:499`
2. `mcause <= irq_cause_next` 保存中断类型：`PCPU.v:500`
3. `mie <= 0` 关闭中断，防止嵌套：`PCPU.v:501`
4. 清掉本次服务的 pending，保留其他 pending：`PCPU.v:502`

中断优先级：

| 优先级 | pending bit | `mcause` |
|--------|-------------|----------|
| 最高 | `INT[0]` | `1` BTN1 |
| 中 | `INT[1]` | `2` timer |
| 低 | `INT[2]` | `3` BTNL/BTNR |

仲裁实现位置：`PCPU.v:475-483`。

### 中断返回

ISR 最后执行：

```asm
sw x0, 8(x12)
```

CPU 在 EX 阶段识别地址 `0xD000_0008`，生成 `mret_taken`：

- CSR MRET 地址定义：`PCPU.v:73`
- MRET 检测：`PCPU.v:455-467`
- PC 恢复到 `mepc`：`PCPU.v:120-121`
- MRET 时重新打开中断：`PCPU.v:504-507`

### 精确中断

这个设计是单层、精确中断：

- IF/ID 在 `int_taken` 时冲刷，丢弃刚取到但还没提交的指令：`PCPU.v:144-147`
- ID/EX 在 `int_taken` 时不冲刷，让已经在中断点之前发射的指令完成：`PCPU.v:256-258`
- 因此 `mepc` 处的指令没有副作用，MRET 后可以重新执行。

---

## CSR Load 如何返回 `mcause`

普通外设没有 `0xD000_000C`，所以 `mcause` 不能从 MIO_BUS 读，必须由 CPU 内部返回。

实现路径：

| 阶段 | 代码 | 位置 |
|------|------|------|
| EX | 判断 `Addr[31:28] == 0xD` 且当前是 load | `PCPU.v:450-452` |
| EX | 根据低 8 位地址选择 `mcause/pending/mepc/mie` | `PCPU.v:457-464` |
| EX/MEM | 保存 CSR 读数，屏蔽外部 load | `PCPU.v:536-569` |
| Forward | CSR 读数参与前递 | `PCPU.v:582-586` |
| MEM/WB | CSR 读数进入写回阶段 | `PCPU.v:602-630` |
| WB | `wb_data` 选择 CSR 读数写回寄存器 | `PCPU.v:640-644` |

软件侧用这一句读取：

```asm
lw x21, 12(x12)     # x12 = 0xD0000000，所以地址是 0xD000000C
```

位置：`custom_int.s:43`。

---

## 小程序说明

程序入口：

| 地址 | 作用 |
|------|------|
| `0x00` | 初始化外设基址、游戏状态、计数器 |
| `0x30` | `sw x0, 0(x12)` 开中断 |
| `0x34` | 跳到 `main_loop` |
| `0x80` | ISR 入口，必须和 `MTVEC=0x80` 对齐 |
| `0x180` | 主循环入口 |

寄存器分工：

| 寄存器 | 用途 |
|--------|------|
| `x10` | 光标，循环 `1,2,4,8,16` |
| `x11` | 数码管基址 `0xE0000000` |
| `x12` | CSR 基址 `0xD0000000` |
| `x13` | 游戏进度 stage |
| `x14` | 错误次数 penalty |
| `x16` | 完成次数 win |
| `x17` | 上一次中断类型 last cause |
| `x19` | timer 中断次数 |
| `x20` | BTNL/BTNR 辅助中断次数 |
| `x21` | ISR 里读取的 `mcause` |
| `x23` | 状态提示倒计时 |
| `x24` | 状态提示类型 |

主循环显示：

| 显示 | 含义 |
|------|------|
| `A0ccppss` | 正常态，`cc` 是上次 `mcause` |
| `C0DE000s` | BTN1 按对 |
| `BAD000pp` | BTN1 按错 |
| `600D00ww` | 四步完成 |
| `710E00tt` | timer 中断次数 |
| `A11000aa` | BTNL/BTNR 辅助中断次数 |

---

## 板上完整验收流程

### 1. 基本小程序

设置：`SW7..5=000`，`SW2=0`。

现象：

- 复位后显示 `A0000000`
- LED9 是第一关目标
- 低位光标循环移动
- 光标到目标时 LED15 亮

### 2. BTN1 中断

操作：LED15 亮时按 `BTNC` 或 `BTNU`。

期望：

- 短暂显示 `C0DE0001`
- 正常态 `A0ccppss` 中 `cc=01`
- 说明 `mcause=1` 生效

### 3. timer 中断

操作：等待约 1 秒。

期望：

- 短暂显示 `710E0001`
- 再等会显示 `710E0002`
- 正常态 `cc=02`
- 说明 `mcause=2` 生效

### 4. BTNL/BTNR 第三类中断

操作：按 `BTNL` 或 `BTNR`。

期望：

- 短暂显示 `A1100001`
- 再按显示 `A1100002`
- 正常态 `cc=03`
- 说明 `mcause=3` 生效

### 5. 中断返回原状态

设置：`SW2=1` 慢档，`SW7..5=111` 看 `PC_out`。

操作：按 `BTNC/BTNU` 或 `BTNL/BTNR`。

期望：

- PC 从主循环段跳到 `0x80`
- 执行 ISR 后回到原 PC 附近继续跑
- 说明 `mepc` 保存/恢复正确

### 6. 看当前指令验证 ROM

设置：`SW2=1`，`SW7..5=010`。

期望：

- 进入 ISR 时第一条机器码是 `00C62A83`
- 这条就是 `lw x21, 12(x12)`，说明 ISR 第一件事是读取 `mcause`

---

## 核心代码行号速查

### `PCPU.v`

| 问题 | 文件行号 |
|------|----------|
| 中断入口 `MTVEC=0x80` | `PCPU.v:69` |
| CSR 地址定义 | `PCPU.v:70-76` |
| `mie/mepc/mcause/int_pending` 寄存器 | `PCPU.v:87-90` |
| MRET 返回 `PC <= mepc` | `PCPU.v:120-121` |
| 进入中断 `PC <= MTVEC` | `PCPU.v:124-125` |
| IF/ID 冲刷 | `PCPU.v:144-147` |
| ID/EX 对 MRET 冲刷，但 int_taken 不冲 ID/EX | `PCPU.v:256-258` |
| CSR read/write 检测 | `PCPU.v:450-455` |
| CSR 读出 `mcause/pending/mepc` | `PCPU.v:457-464` |
| 三路中断 pending + 优先级仲裁 | `PCPU.v:475-485` |
| 保存 `mepc` 和 `mcause` | `PCPU.v:498-502` |
| MRET 重新开中断 | `PCPU.v:504-507` |
| CSR load/store 屏蔽外部总线 | `PCPU.v:561-569` |
| CSR load 写回 | `PCPU.v:640-644` |

### `PCPU_TOP.v`

| 问题 | 文件行号 |
|------|----------|
| BTN1/BTNC/BTNU 和 BTNL/BTNR 原始输入映射 | `PCPU_TOP.v:113` |
| 双按键消抖 | `PCPU_TOP.v:117-135` |
| 按键上升沿检测 | `PCPU_TOP.v:137-143` |
| 事件 toggle | `PCPU_TOP.v:145-150` |
| 2-FF 跨时钟同步 | `PCPU_TOP.v:152-162` |
| 生成按钮中断脉冲 | `PCPU_TOP.v:164-170` |
| timer 中断 | `PCPU_TOP.v:172-187` |
| 三路 `int_sources` 合成 | `PCPU_TOP.v:189` |
| 接入 `PCPU.INT` | `PCPU_TOP.v:204` |
| 数码管 `data7=PC_out` | `PCPU_TOP.v:278` |
| 固定纯 hex 显示 | `PCPU_TOP.v:289` |

### `custom_int.s`

| 问题 | 文件行号 |
|------|----------|
| 初始化 CSR 基址 `0xD0000000` | `custom_int.s:26` |
| 开中断 `sw x0, 0(x12)` | `custom_int.s:37` |
| ISR 放在 `0x80` | `custom_int.s:40` |
| 读取 `mcause` | `custom_int.s:43` |
| 按 `mcause` 分发三类中断 | `custom_int.s:45-50` |
| BTN1 游戏中断处理 | `custom_int.s:53-103` |
| timer 中断处理 | `custom_int.s:105-109` |
| BTNL/BTNR 辅助中断处理 | `custom_int.s:111-115` |
| 主循环入口 `0x180` | `custom_int.s:117-118` |
| LED15 READY 灯 | `custom_int.s:137-139` |
| `710E00tt` 显示 | `custom_int.s:157-160` |
| `A11000aa` 显示 | `custom_int.s:161-164` |
| `A0ccppss` 正常态显示 | `custom_int.s:173-179` |

### `clk_div.v`

| 问题 | 文件行号 |
|------|----------|
| 快档约 6.25MHz | `clk_div.v:12` |
| 慢档约 3Hz | `clk_div.v:13` |
| `SW2` 选择快/慢档 | `clk_div.v:18` |

---

## 注意事项

- 修改 `custom_int.s` 后必须重新生成并加载 `custom_int.coe`。
- 当前设计是单层中断，不支持嵌套；进入中断后 `mie=0`，MRET 后恢复为 1。
- 如果 timer 过于频繁干扰小程序验收，可以临时增大 `PCPU_TOP.v:173` 的 `TIMER_RELOAD`。
- 如果看 PC 或指令，确保 `SW0` 不影响显示；Project 3 已在 `PCPU_TOP.v:289` 固定为纯 hex。
