# RV32I CPU 实验项目文档

> 计算机组成原理实验 · 单周期 CPU（Project 1）与五级流水线 CPU（Project 2）

---

## 目录

- [项目概览](#项目概览)
- [Project 1：单周期 CPU（SCPU）](#project-1单周期-cpuscpu)
  - [SCPU.v — 单周期核心](#scpuv--单周期核心)
  - [SCPU_TOP.v — 单周期 SoC 顶层](#scpu_topv--单周期-soc-顶层)
- [Project 2：五级流水线 CPU（PCPU）](#project-2五级流水线-cpupcpu)
  - [PCPU.v — 流水线核心](#pcpuv--流水线核心)
  - [PCPU_TOP.v — 流水线 SoC 顶层](#pcpu_topv--流水线-soc-顶层)
- [testac.coe — 验收测试程序](#testacoe--验收测试程序)
  - [程序整体流程](#程序整体流程)
  - [六个测试函数](#六个测试函数)
  - [通过/失败显示机制](#通过失败显示机制)
  - ["AC" 字样的来源](#ac-字样的来源)

---

## 项目概览

本项目实现了两版 RISC-V（RV32I 子集）处理器，并将其集成进同一套 SoC 外设框架：

| 项目 | CPU 文件 | 顶层文件 | 特点 |
|------|----------|----------|------|
| Project 1 | `SCPU.v` | `SCPU_TOP.v` | 单周期，一条指令一个 CPU 时钟周期完成全部 5 个阶段 |
| Project 2 | `PCPU.v` | `PCPU_TOP.v` | 五级流水线，前递 + 冒泡 + 冲刷解决三类冒险 |

两个顶层共享同一套外设（数码管、LED、计数器、总线译码、时钟分频），CPU 对外接口完全相同，流水化对外透明。

---

## Project 1：单周期 CPU（SCPU）

### SCPU.v — 单周期核心

单周期 CPU 的核心思想是：**一条指令在一个 `Clk_CPU` 上升沿内，完成 IF → ID → EX → MEM → WB 的全部工作**。实现上没有流水线寄存器，全靠纯组合逻辑串联各阶段。

#### 支持的指令类型

`LUI` / `AUIPC` / `JAL` / `JALR` / `BRANCH`（6 种）/ `LOAD`（5 种）/ `STORE`（3 种）/ `ALUI`（8 种）/ `ALUR`（8 种）

#### 各功能块说明

| 功能块 | 作用 | 实现方式 |
|--------|------|----------|
| **PC 寄存器** | 保存当前取指地址 | `always @(posedge clk)`，复位清零；正常时 `PC ← PC_next` |
| **指令字段拆分** | 提取 `opcode/rd/funct3/rs1/rs2/funct7` | `assign` 直接切片 |
| **立即数生成** | 生成 I/S/B/U/J 五种格式立即数 | 按 RV32I 编码规则拼接 + 符号扩展 |
| **类型判断** | 生成 `is_lui/is_auipc/…/is_alur` 等 9 个布尔信号 | `opcode` 比较 |
| **寄存器堆** | 32×32bit，`x0` 恒为 0 | 读为组合逻辑，写为时序（上升沿） |
| **ALU 输入选择** | `alu_A` 选 `PC/0/rs1`；`alu_B` 选 `rs2/imm_U/imm_S/imm_I` | 三目运算符链 |
| **ALU 运算** | 按 `opcode` 区分类型，再按 `funct3+funct7` 选具体运算 | `case` 语句；`funct7[5]` 区分 `add/sub`、`srl/sra` |
| **分支判断** | `beq/bne/blt/bge/bltu/bgeu` | 独立 `case`，输出 `branch_taken` |
| **PC_next 选择** | JAL: `PC+immJ`；JALR: `(rs1+immI)&~1`；分支成立: `PC+immB`；其他: `PC+4` | 三目运算符链 |
| **写回选择** | LUI/AUIPC/ALUI/ALUR → ALU 结果；JAL/JALR → `PC+4`；LOAD → `Data_in` | 三目运算符链 |
| **写回** | `wb_en && rd≠0 && MIO_ready` 时写 `rf[rd]` | 时序（上升沿） |

#### 单周期访存特性

一条 `lw` 指令在同一个 `Clk_CPU` 周期内即可完成"算地址 → RAM 读 → 写回"：

- `Addr_out = alu_out`（组合输出）
- `Data_out = rs2_data`（组合输出）
- `mem_w = is_store`（写使能）
- `dm_ctrl = funct3`（访存类型）
- RAM 的 `douta` 通过 `Data_in` 再组合地送回写回多路选择器

---

### SCPU_TOP.v — 单周期 SoC 顶层

顶层将 CPU 核、外设 IP 核和总线连接成完整 SoC，结构如下：

```
btn_i, sw_i ──► Enter ──► BTN_out, SW_out
                                │
clk ──► clk_div ──► Clk_CPU（慢时钟）+ clkdiv[31:0]（分频/数码管刷新）
                                │
PC_out ──► ROMD（指令 ROM）──► spo（32bit 指令字）
                                │
                 SCPU ◄── Data_read ◄── dm_controller ◄── MIO_BUS
                   │                         │
                   ├─ Addr_out, Data_out, mem_w, dm_ctrl
                   ▼
               MIO_BUS（地址译码）
                   ├──► RAM_B（数据存储器，0x0000_0000 起）
                   ├──► SPIO（LED/SW GPIO，0xF000_0000 起）
                   ├──► Multi_8CH32（数码管数据选择，0xE000_0000 起）
                   └──► Counter_x（计数器外设）

Multi_8CH32 ──► Disp_num ──► SSeg7 ──► 七段数码管扫描输出
SPIO ──────────────────────────────► led_o, counter_set
```

#### 重要实现细节

**`MIO_ready` 必须为常 `1'b1`**
若接成 `CPU_MIO` 条件信号，非 LOAD/STORE 指令时 PC 永远不更新，程序死锁。

**`dm_controller` 的作用**
原始 Block RAM 不支持 `lb/lh/sb/sh`，必须在 CPU 和 RAM 之间插入 `dm_controller`：
- `Data_write`：将 CPU 写数据对齐到正确字节位置
- `Data_read`：从 32bit 字中提取字节/半字并做符号扩展
- `wea_mem[3:0]`：直接驱动 RAM 的 4 个字节写使能

**RAM 时钟相位**
RAM 使用 `~clk`（反相系统时钟）作为 `clka`。CPU 在 `Clk_CPU` 上升沿输出地址，半个系统周期后 RAM 采到地址，再过半个周期 `douta` 稳定，CPU 在下一个 `Clk_CPU` 上升沿完成写回。

**数码管内容选择（`SW[7:5]`）**
`Multi_8CH32` 根据拨码开关选择显示内容，例如外设输入、当前 PC、当前指令字、ALU 地址、写数据、读数据等。

---

## Project 2：五级流水线 CPU（PCPU）

### PCPU.v — 流水线核心

五级流水线将单周期的组合逻辑切成 5 段，各段之间用流水线寄存器隔离，理论上可让 5 条指令同时在各阶段执行。

#### 五个流水段

| 阶段 | 工作内容 | 关键流水寄存器 |
|------|----------|----------------|
| **IF**（取指） | 用 `PC` 取指令，结果进入 `IF/ID` | `PC` |
| **ID**（译码） | 拆字段、生成 5 种立即数、读寄存器堆、生成 `is_xxx` 控制信号 | `IF_ID_inst`、`IF_ID_PC` |
| **EX**（执行） | 前递选源、ALU 运算、分支判断、跳转目标计算 | `ID_EX_*`（大量信号） |
| **MEM**（访存） | 输出地址/写数据/控制信号给外部总线，接收 `Data_in` | `EX_MEM_*` |
| **WB**（写回） | 从 LOAD 数据、ALU 结果、`PC+4` 中选一个写回寄存器堆 | `MEM_WB_*` |

#### 三种冒险的处理方案

**（一）数据冒险 — 前递（Forwarding）**

EX 阶段计算 ALU 时，源寄存器的值可能正被后续阶段的指令更新，不能等写回后再读，需直接"旁路"转发：

```
fwd_ex_mem_rs1 = (EX/MEM 中的指令写 rs1) && (rd ≠ x0)
fwd_mem_wb_rs1 = (MEM/WB 中的指令写 rs1) && (rd ≠ x0)

ex_rs1_data = fwd_ex_mem_rs1 ? ex_mem_wb_data    // EX/MEM 优先（更新）
            : fwd_mem_wb_rs1 ? wb_data            // 次选 MEM/WB
            : ID_EX_rs1_data                      // 无冒险，用寄存器堆值
```

其中 `ex_mem_wb_data` 本身也是三选一：LOAD 取 `Data_in`，JAL/JALR 取 `PC+4`，否则取 ALU 结果。

另外，**WB→ID 同拍旁路**：ID 阶段用组合逻辑读寄存器堆，但同一拍 WB 正在写入（非阻塞赋值导致读到旧值）。解决方法：若 `MEM/WB` 写的 `rd` 等于 ID 阶段读的 `rs1/rs2`，直接用 `wb_data` 旁路，跳过寄存器堆。

**（二）Load-Use 冒险 — 插入气泡（Stall）**

```
lw  x10, 0(x11)     ; LOAD，数据要到 MEM 段才出来
add x12, x10, x13   ; 紧接着用 x10 → 无法纯前递
```

必须停顿一拍：

```
stall = (EX 段是 LOAD) && (LOAD 的 rd == ID 段的 rs1 或 rs2)
```

`stall = 1` 时：
- PC 保持不动
- IF/ID 寄存器保持不动
- ID/EX 注入 NOP（`addi x0, x0, 0`）

一拍后 LOAD 进入 MEM/WB，后续指令重新进入 EX，通过 MEM/WB→EX 前递拿到数据。

**（三）控制冒险 — 冲刷（Flush）**

分支/跳转目标在 **EX 阶段**才能算出，此时 IF 和 ID 阶段已经各取了一条顺序（错误的）指令：

```
flush = is_jal | is_jalr | (is_branch & branch_taken)
```

`flush = 1` 时：
- `PC ← branch_target`（跳转目标）
- IF/ID 注入 NOP
- ID/EX 注入 NOP

代价：**每次分支/跳转浪费 2 拍**（分支在 EX 方案）。若将分支提前到 ID 段判断可将代价降为 1 拍，但需要更多前递逻辑。

#### NOP 的定义

```verilog
localparam NOP = 32'h00000013;  // addi x0, x0, 0
```

写入 `x0`（被硬件屏蔽）且不触发外设访问，是完全无副作用的"占位指令"。Stall 和 Flush 均靠注入 NOP 来"清空"流水段。

---

### PCPU_TOP.v — 流水线 SoC 顶层

外设结构与 `SCPU_TOP.v` 基本一致，主要区别如下：

**CPU 实例替换**
`SCPU U1(...)` → `PCPU U1(...)`，对外接口完全相同，外设无需改动。

**RAM 写保护门控**

```verilog
ram_wea = data_ram_we ? wea_mem : 4'b0000;
```

仅当 MIO_BUS 地址译码确认当前地址属于数据 RAM 区域时，才真正允许写 RAM，防止写外设地址时误写 RAM。

**计数器显示**
`data3` 接入 `counter_out`（单周期版接 `none`），数码管可显示计数器当前值。

**配套 COE 文件**

| ROM/RAM | 对应 COE 文件 |
|---------|---------------|
| 指令 ROM（ROMD） | `I_pipemem37.coe` |
| 数据 RAM（RAM_B） | `D_snakeDEMO.coe` |

> ⚠️ 切换到流水线版本时，需重新生成 IP 核并替换 COE 文件。

---

## testac.coe — 验收测试程序

`testac.coe` 是由 `rv32-instr.disasm` 汇编源文件编译得到的二进制机器码，按字节地址顺序排列后写成十六进制数列，用于初始化指令 ROM。

### 程序整体流程

```
PC=0x00  addi x2, x2, -16    ; main 入口，sp -= 16
PC=0x04  sw   x1, 12(x2)     ; 保存返回地址 ra
PC=0x10  addi x2, x0, 1024   ; 重新设置栈底
PC=0x14  jal  x1, 0x248      ; 调用 test1
PC=0x18  jal  x1, 0x2d8      ; 调用 test2
PC=0x1c  jal  x1, 0x420      ; 调用 test3
PC=0x20  jal  x1, 0x474      ; 调用 test4（注：文档显示 0x494 为函数体）
PC=0x24  jal  x1, 0x658      ; 调用 test5
PC=0x28  jal  x1, 0xa24      ; 调用 test6
PC=0x2c  jal  x1, 0x8c       ; 调用 finalize（渲染结果）
PC=0x44  jalr x0, 0(x1)      ; 返回（ra=0 → 跳回 0，反复运行）
```

### 六个测试函数

每个 test 函数入口都执行相同的**进度码写入**流程：

```asm
lui  x14, 0xe0000        ; x14 = 0xe0000000（数码管外设地址）
lui  x15, 0xNNN          ; 测试编号标记
sw   x15, 0(x14)         ; 写到数码管 → 实时显示"跑到第几关"

lw   x15, 4(x0)          ; 读 mem[4]（已通过测试的累积码）
slli x15, x15, 4         ; 左移 4 位
ori  x15, x15, N         ; 拼入当前测试号 N
sw   x15, 4(x0)          ; 写回 mem[4]
```

`mem[4]` 作为**累积通过标志**，每过一关左移 4 位再 OR 上当前编号：

| 通过情况 | `mem[4]` 值 |
|----------|-------------|
| 通过 test1 | `0x00000001` |
| 通过 test1~2 | `0x00000012` |
| 通过 test1~3 | `0x00000123` |
| 通过 test1~6 | `0x00123456` |

各测试函数具体内容：

| 编号 | 入口地址 | 测试内容 |
|------|----------|----------|
| test1 | `0x248` | 算术运算 + 旋转哈希（`add_8` 子例程，输入 `0x66ccff`，期望输出 `0x712f731`） |
| test2 | `0x2d8` | 字节/半字访存 + 符号扩展（`lb/lh/lbu/lhu/lw/sb/sh/sw`，验证 `mem[8..11]` 读写结果 `0x62a89633`） |
| test3 | `0x420` | 模运算（验证 `5 mod N = 42` 类型运算） |
| test4 | `0x494` | 综合算法循环（大量 `add/blt/bgeu`，验证分支判断正确性） |
| test5 | `0x658` | 异或交换变量（`a^=b; b^=a; a^=b`，验证 a/b 互换） |
| test6 | `0xa24` | SHA-1 风格哈希（`hash(0x12345678)` 期望结果 `0x7c222fb2`） |

### 通过/失败显示机制

**失败处理**（入口 `0x204`）：

```asm
0x204: lui  x14, 0xf0000
0x208: lw   x15, 4(x0)        ; 读取当前累积进度
0x20c: or   x15, x15, x14     ; 高位打上 0xF0000000 失败标记
0x210: lui  x14, 0xe0000
0x214: sw   x15, 0(x14)       ; 写数码管 → 显示 "F000_进度码"
0x218: jal  x0, 0x218         ; 死循环，停在失败现场
```

| 显示内容 | 含义 |
|----------|------|
| `0xF000_xxxx` | 某个测试失败，`xxxx` 为失败前最后的累积通过进度 |
| `0x0012_3456` | 六关全部通过（`mem[4]` 最终值） |

### "AC" 字样的来源

`SSeg7` 模块有一个 `SW0` 输入引脚，其行为如下：

```verilog
SSeg7 U6(
    .clk(clk),
    .rst(rst_i),
    .SW0(SW_out[0]),   // 拨码开关第 0 位
    .flash(clkdiv[12]),
    .Hexs(Disp_num),   // 来自 Multi_8CH32 的 32bit 显示数据
    ...
);
```

| `SW0` | 显示模式 |
|-------|----------|
| `0` | 普通模式：将 `Hexs[31:0]` 作为 8 个十六进制字符直接显示 |
| `1` | 验收模式：前两位显示 **"A C"**（七段码），后 6 位显示 `mem[4]` 的累积进度 `0x123456` |

> **结论：** "AC" 并非由 `testac` 程序直接"打印"，而是 `SSeg7` IP 核在 `SW0=1` 且检测到测试全部通过的条件下，以特定七段码图案显示出来的。`testac` 程序的使命是确保 `SSeg7` 收到的输入处于"六关全通"状态（`mem[4] = 0x00123456`），由此触发 "AC" 显示。

---