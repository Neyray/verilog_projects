# Project 1 — 单周期 RV32I CPU（SCPU）

> 一条指令一个 `Clk_CPU` 周期内完成 `IF → ID → EX → MEM → WB` 全部 5 个阶段，**无流水线寄存器，纯组合逻辑串联**。

---

## 目录

- [文件清单](#文件清单)
- [总体结构](#总体结构)
- [SCPU.v — 单周期核心](#scpuv--单周期核心)
- [SCPU_TOP.v — 单周期 SoC 顶层](#scpu_topv--单周期-soc-顶层)
- [配套 COE 与外设细节](#配套-coe-与外设细节)
- [验收操作](#验收操作)
  - [开关功能](#开关功能)
  - [总体验收](#总体验收)
  - [细分演示](#细分演示)
- [与 Project 2 的差异速查](#与-project-2-的差异速查)

---

## 文件清单

| 文件 | 作用 |
|------|------|
| `SCPU.v` | 单周期 CPU 核心 |
| `SCPU_TOP.v` | SoC 顶层，连接 CPU、ROM、RAM、总线、外设 |
| `dm_controller.v` | 字节/半字访存控制器（`lb/lh/lbu/lhu/sb/sh`） |
| `MIO_BUS.v` | 内存映射 I/O 总线（地址译码 + 数据选择） |
| `Multi_8CH32.v` | 8 路 32bit 信号多路选择，送至数码管显示 |
| `SPIO.v` | LED/SW GPIO 外设 |
| `SSeg.v` | 七段数码管驱动 |
| `Counter_x.v` | 计数器外设（3 通道） |
| `Enter.v` | 按键 + 拨码开关消抖/同步 |
| `clk_div.v` | 时钟分频，输出 `Clk_CPU` 和 `clkdiv[31:0]` |
| `testac.coe` | 验收程序（六个测试函数 + 渲染） |
| `D_mem.coe` | 数据 RAM 初始化 |
| `rv32-instr.disasm` | `testac` 的反汇编源码（对照 PC 用） |

> ⚠️ **指令 ROM（ROMD）和数据 RAM（RAM_B）是 Vivado Block Memory IP 核**，在工程中由 `.coe` 文件初始化，不在本目录的 `.v` 源码里。

---

## 总体结构

```
btn_i, sw_i ─► Enter ─► BTN_out, SW_out
                            │
clk ─► clk_div ─► Clk_CPU（CPU 慢时钟）+ clkdiv[31:0]（分频/数码管刷新）
                            │
PC_out ─► ROMD（指令 ROM）─► spo（32bit 指令字）
                            │
            SCPU ◄── Data_read ◄── dm_controller ◄── MIO_BUS
              │                          │
              ├─ Addr_out, Data_out, mem_w, dm_ctrl
              ▼
          MIO_BUS（地址译码）
              ├──► RAM_B（数据存储器，0x0000_0000 段）
              ├──► SPIO（LED/SW GPIO，0xF000_0000）
              ├──► Multi_8CH32（数码管，0xE000_0000）
              └──► Counter_x（计数器外设）

Multi_8CH32 ──► Disp_num ──► SSeg7 ──► 七段数码管扫描输出
SPIO ──────────────────────────────► led_o, counter_set
```

---

## SCPU.v — 单周期核心

单周期 CPU 的核心思想：**一条指令在一个 `Clk_CPU` 上升沿内完成 IF→ID→EX→MEM→WB 的全部工作**。`PC` 是整个 CPU 中唯一的状态寄存器（除寄存器堆外），各阶段全靠组合逻辑串联。

### 支持的指令类型（RV32I 子集）

`LUI` · `AUIPC` · `JAL` · `JALR` · `BRANCH`(6) · `LOAD`(5) · `STORE`(3) · `ALUI`(8) · `ALUR`(8)

### 各功能块说明

| 功能块 | 作用 | 实现方式 |
|--------|------|----------|
| **PC 寄存器** | 保存当前取指地址 | `always @(posedge clk)`，复位清零，正常 `PC ← PC_next` |
| **指令字段拆分** | 提取 `opcode/rd/funct3/rs1/rs2/funct7` | `assign` 直接切片 |
| **立即数生成** | 生成 I/S/B/U/J 五种格式立即数 | 按 RV32I 编码规则拼接 + 符号扩展 |
| **类型判断** | 输出 `is_lui/is_auipc/…/is_alur` 等 9 个布尔信号 | `opcode` 比较 |
| **寄存器堆** | 32×32bit，`x0` 恒为 0 | 读为组合，写为时序（上升沿） |
| **ALU 输入选择** | `alu_A` 选 `PC/0/rs1`；`alu_B` 选 `rs2/imm_U/imm_S/imm_I` | 三目运算符链 |
| **ALU 运算** | 按 `opcode` 区分类型，再按 `funct3+funct7` 选具体运算 | `case` 语句；`funct7[5]` 区分 `add/sub`、`srl/sra` |
| **分支判断** | `beq/bne/blt/bge/bltu/bgeu` | 独立 `case`，输出 `branch_taken` |
| **PC_next 选择** | `JAL: PC+immJ`，`JALR: (rs1+immI)&~1`，分支成立: `PC+immB`，其他: `PC+4` | 三目运算符链 |
| **写回选择** | LUI/AUIPC/ALUI/ALUR→ALU；JAL/JALR→`PC+4`；LOAD→`Data_in` | 三目运算符链 |
| **写回时序** | `wb_en && rd≠0 && MIO_ready` 时写 `rf[rd]` | 时序（上升沿） |

### 单周期访存特性

一条 `lw` 在同一个 `Clk_CPU` 周期内即可完成"算地址 → RAM 读 → 写回"：

- `Addr_out = alu_out`（组合）
- `Data_out = rs2_data`（组合）
- `mem_w = is_store`（写使能）
- `dm_ctrl = funct3`（访存类型）
- RAM 的 `douta` 经 `dm_controller` 处理后由 `Data_in` 组合送回写回多路选择器

> **`INT` 输入端口存在但被忽略**（`SCPU_TOP.v` 中接 `1'b0`）。单周期 CPU 不处理中断，留待 Project 3 在流水线 CPU 上实现。

---

## SCPU_TOP.v — 单周期 SoC 顶层

顶层将 CPU 核、外设 IP 核和总线连接成完整 SoC。相比早期版本，本顶层修正了三个关键问题：

### 三个关键修正

1. **`MIO_ready` 必须为常 `1'b1`**
   原始版本将 `MIO_ready` 自环接 `CPU_MIO`，导致非 LOAD/STORE 指令时 `CPU_MIO=0 → MIO_ready=0 → PC 永远不更新`，程序死锁。修正后总线视作始终就绪。

2. **`dm_controller` 接线重写**
   原始 Block RAM 不支持 `lb/lh/sb/sh`，必须在 CPU 与 RAM 之间插入 `dm_controller`：
   - `Data_write` ← CPU 的 `Data_out`（rs2 原始数据）
   - `Data_read_from_dm` ← `Cpu_data4bus`（MIO_BUS 选出的读数据）
   - `Data_read` → CPU 的 `Data_in`（经字节提取 + 符号扩展）
   - `Data_write_to_dm` → RAM 的 `dina`（字节对齐后的写数据）
   - `wea_mem[3:0]` → RAM 的 4 个字节写使能

3. **RAM 时钟相位反相**
   RAM 使用 `~clk` 作为 `clka`。CPU 在 `Clk_CPU` 上升沿输出地址，半个系统周期后 RAM 采到地址，再过半个周期 `douta` 稳定，CPU 在下一个 `Clk_CPU` 上升沿完成写回。

### 数码管显示通道（由 `SW[7:5]` 选择）

`Multi_8CH32` 根据拨码开关选择显示内容：

| SW7 SW6 SW5 | 显示内容 | 用来看什么 |
|-------------|----------|------------|
| 0 0 0 | `Peripheral_in`（最近一次写 `0xE000_0000`） | 测试进度码 |
| 0 0 1 | `{2'b00, PC[31:2]}` | PC 字地址 |
| 0 1 0 | `spo` | 当前指令机器码 |
| 0 1 1 | 浮空（Project 1 未接） | — |
| 1 0 0 | `Adder_out` | ALU 结果 / 访存地址 |
| 1 0 1 | `Data_out` | `sw` 写出的数据（rs2） |
| 1 1 0 | `Cpu_data4bus` | 总线读回的 32bit 字 |
| 1 1 1 | `PC_out` | PC 原值（字节地址） |

---

## 配套 COE 与外设细节

| ROM/RAM | COE 文件 |
|---------|----------|
| 指令 ROM（ROMD） | `testac.coe` |
| 数据 RAM（RAM_B） | `D_mem.coe` |

`testac.coe` 由 `rv32-instr.disasm` 编译得到。程序结构：

```
PC=0x00  addi x2, x2, -16       ; main 入口，sp -= 16
PC=0x04  sw   x1, 12(x2)        ; 保存 ra
PC=0x10  addi x2, x0, 1024      ; 重新设置栈底
PC=0x14  jal  x1, 0x248         ; 调用 test1
PC=0x18  jal  x1, 0x2d8         ; 调用 test2
PC=0x1c  jal  x1, 0x420         ; 调用 test3
PC=0x20  jal  x1, 0x494         ; 调用 test4
PC=0x24  jal  x1, 0x658         ; 调用 test5
PC=0x28  jal  x1, 0xa24         ; 调用 test6
PC=0x2c  jal  x1, 0x8c          ; 调用 finalize（渲染结果）
```

每个 `testN` 函数都会：
1. 把测试编号写到 `0xE000_0000`（数码管），实时显示"跑到第几关"；
2. 把累积通过码写到 `mem[4]`（左移 4 位 OR 当前编号）；
3. 全部通过后 `mem[4] = 0x00123456`。

失败入口 `0x204`：把 `0xF000_0000 | mem[4]` 写到数码管并死循环，前两位 `0xF` 即失败标志。

**"AC" 字样的来源**：`SSeg7` 的 `SW0` 输入为 1 时进入验收模式，前两位强制画 "A C"，后 6 位画 `mem[4]`。所以 `SW0=1` 且测试全通 → 数码管显示 **AC123456**。

---

## 验收操作

### 开关功能

| 开关 | 接到哪 | 作用 |
|------|--------|------|
| `SW0` | `SSeg7.SW0` | `0`=纯 hex；`1`=验收模式（前两位显示 AC） |
| `SW2` | `clk_div.SW2` | `0`=快档（≈6 MHz）；`1`=慢档（≈3 Hz，肉眼看 PC 跑动） |
| `SW7,SW6,SW5` | `Multi_8CH32.Switch[2:0]` | 选择 8 路 32bit 信号中送显示的那一路 |
| `rstn` (按键) | 全局复位 | 低有效（按下复位） |

### 总体验收

使用 `testac.coe` + `D_mem.coe`：

| 步骤 | SW 设定 | 期望现象 | 验什么 |
|------|---------|----------|--------|
| 1 | `SW0=1`，`SW7..5=000`，`SW2=0`（快档），按 rstn 复位 | 数码管显示 **AC123456** | CPU 全功能通过，6 个测试函数全部 OK |
| 2 | 同上但 `SW2=1`（慢档） | 进度码依次：`0x111100 → 0x222200 → … → 0x666600`，切 `SW0=1` 后出 **AC123456** | 肉眼看到每关依次通过 |
| ❌ 失败 | — | 出现 `0xF000xxxx`，`xxxx` 表示卡在第几个测试之前 |

### 细分演示

`SW2=1`（慢档） + `SW0=0`（纯 hex），切换 `SW7~SW5` 对照 `rv32-instr.disasm` 逐项核查：

| SW7 SW6 SW5 | 看到的内容 | 验什么 |
|-------------|------------|--------|
| 0 0 0 | 进度码 | 各 test 通过的时序 |
| 0 0 1 | PC 字地址 | 下一条指令编号 |
| 0 1 0 | 当前指令机器码 | ROMD 取指正确（如 `ff010113` = 第一条 `addi sp,sp,-16`） |
| 1 0 0 | ALU 结果 | ADD/SUB/SLT/XOR 等运算 |
| 1 0 1 | rs2 写出数据 | `sw` 时写出的值 |
| 1 1 0 | 总线读回数据 | `lw`/`lh`/`lb` 读回正确（含字节/半字提取） |
| 1 1 1 | PC 字节地址 | 跳转处看到 `jal/jalr/branch` 跳到正确目标 |

---

## 与 Project 2 的差异速查

| 维度 | Project 1（SCPU） | Project 2（PCPU） |
|------|-------------------|--------------------|
| CPU 微架构 | 单周期，组合逻辑串联 | 五级流水线，4 组流水寄存器 |
| 每条指令周期 | 1 个 `Clk_CPU` | 平均 ≈1 拍（有冒险时多 1~2 拍） |
| 冒险处理 | 无（不需要） | 前递 + 气泡 + 冲刷 |
| 配套 COE（默认） | `testac` + `D_mem` | `testac` + `D_snakeDEMO` |
| 顶层数码管 `data3` 通道 | 浮空 | `counter_out`（计数器值） |
| `INT` 输入 | 接 `1'b0`，未处理 | 接 `1'b0`，未处理（Project 3 才启用） |
| RAM 写保护 | 无门控 | `data_ram_we` 门控 `wea_mem`，避免外设地址误写 RAM |

> **核心一句话：** 单周期 CPU 是 RV32I 子集的最直白实现，目标是把 `IF→ID→EX→MEM→WB` 五段全部塞进一个时钟周期，理解 CPU 数据通路的入门版本。如要追求性能，请看 [Project 2](../project2/README.md)；如要增加中断/异常和自定义程序，请看 [Project 3](../project3/README.md)。
