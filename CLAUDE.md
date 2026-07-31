# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@.claude/rules/testing.md
@.claude/rules/api-design.md

## Repository purpose

Chinese-language coursework repo ("计算机组成原理" / Computer Organization) implementing three progressively
more advanced RV32I RISC-V CPUs on the same SoC peripheral framework, targeted at a Nexys A7 Xilinx FPGA
board via Vivado. `project1`/`project2`/`project3` are the graded deliverables; `code/` and `lab/` are earlier
drafts/course exercises kept for reference; `test/` is a scratch iverilog sandbox unrelated to the CPU projects.

Read `README.md` at the repo root first — it documents the shared SoC framework, peripheral address map, and
board switch usage common to all three projects. Each `projectN/README.md` documents that project's CPU
internals in detail (pipeline hazards, interrupt architecture, etc.) with file:line references into the
Verilog sources — consult those before making changes, they are extensive and authoritative.

## Progression across project1 → project3

- **project1** — `SCPU.v`: single-cycle CPU, one instruction completes per `Clk_CPU` edge, pure combinational
  datapath, no pipeline registers. `INT` port exists but is tied to `1'b0` (unhandled).
- **project2** — `PCPU.v`: same ISA support, restructured into a 5-stage pipeline (IF/ID/EX/MEM/WB) with
  4 sets of pipeline registers. Adds forwarding (EX/MEM and MEM/WB → EX, plus a same-cycle WB→ID register-file
  bypass), a load-use stall, and branch/jump flush (branches resolve in EX, costing 2 bubble cycles).
  `INT` still tied to `1'b0`.
- **project3** — `PCPU.v`/`PCPU_TOP.v` (same filenames as project2 but not the same content): adds a minimal
  precise-interrupt architecture — CSRs (`mie`/`mepc`/`mcause`/`int_pending[2:0]`) memory-mapped at
  `0xD000_00xx` and captured inside the CPU (not routed through `MIO_BUS`), three prioritized interrupt
  sources (button, timer, second button pair), and a custom assembly demo program (`custom_int.s` /
  `custom_int.coe`) whose ISR lives at `MTVEC=0x80`.

All three projects share the exact same peripheral modules (`Multi_8CH32`, `SPIO`, `SSeg`, `Counter_x`,
`Enter`, `clk_div`, `MIO_BUS`, `dm_controller`) — copy-pasted per directory, not shared via includes. When
fixing a peripheral bug, check whether it needs to be fixed in more than one of `project1/`, `project2/`,
`project3/` (and possibly `lab/`).

## Common SoC datapath (all three projects)

```
btn_i, sw_i ─► Enter ─► BTN_out, SW_out
clk ─► clk_div ─► Clk_CPU + clkdiv[31:0]
PC_out ─► ROMD ─► spo (instruction word)
        CPU ◄── Data_read ◄── dm_controller ◄── MIO_BUS
          ├─ Addr_out, Data_out, mem_w, dm_ctrl ─► MIO_BUS (address decode)
          │     ├──► RAM_B      (0x0000_0000, data RAM)
          │     ├──► SPIO       (0xF000_0000, LED/GPIO)
          │     ├──► Multi_8CH32(0xE000_0000, 7-seg display mux)
          │     └──► Counter_x
          └── Multi_8CH32 ─► Disp_num ─► SSeg7 ─► 7-segment display
```

Instruction ROM (`ROMD`) and data RAM (`RAM_B`) are Vivado Block Memory Generator IP cores initialized from
`.coe` files — they are **not** present as `.v` sources in this repo. Swapping which program runs requires
regenerating/repointing the IP core's `.coe` in Vivado, not editing Verilog.

## Building / testing

There is no top-level build system (no Makefile, no automated CI). Two different workflows apply depending on
what you're touching:

1. **FPGA projects (`project1`/`project2`/`project3`, `lab`, `code`)**: these are meant to be opened in Xilinx
   Vivado, synthesized, and verified either by Vivado simulation or on real board hardware using the switch/
   button/display behavior documented in each project's README (search each README for "验收操作" / 验收流程
   for the exact switch settings and expected 7-segment output, e.g. `AC123456` = all self-tests passed).
   There is no way to fully validate a CPU core change from the CLI alone — check README acceptance criteria
   and, where possible, reason through the datapath/timing by hand or with `iverilog`-based unit testing of
   the affected module in isolation.
2. **`test/` sandbox**: a standalone iverilog example (`alu.v` + `tb.v`, unrelated to the CPU cores) with a
   working Makefile:
   ```
   cd test
   make            # compile (iverilog) + run (vvp) + open waveform (gtkwave)
   make compile    # iverilog -o test.out alu.v tb.v
   make run        # vvp test.out
   make wave       # gtkwave test.vcd
   make clean
   ```
   `iverilog`/`vvp`/`gtkwave` are available on this machine. This pattern (a small `tb.v` testbench driving a
   single module, dumped to `.vcd`) is the fastest way to sanity-check a single Verilog module (e.g. `alu.v`,
   `ctrl.v`) in isolation without touching Vivado — create similar throwaway testbenches under `test/` or the
   scratchpad when validating combinational/sequential logic changes, since the full CPU top-levels depend on
   Vivado IP cores (`ROMD`/`RAM_B`) that plain `iverilog` cannot elaborate.

`code/sccomp_tb.v` shows the intended in-repo testbench pattern for a full CPU (`sccomp.v`): it loads a `.dat`
program via `$readmemh` into the instruction memory and lets it run for a fixed number of cycles — reuse this
style if adding testbenches for `code/`.

## Key architectural details worth knowing before editing a CPU core

- **Interrupts (project3 only)**: CSR addresses are hardcoded (`0xD000_0000` mie-set, `0xD000_0004` mie-clear,
  `0xD000_0008` MRET trigger, `0xD000_000C` read mcause, `0xD000_0010` read pending, `0xD000_0014` read mepc).
  Interrupt entry flushes IF/ID but deliberately does **not** flush ID/EX, so an instruction already past
  decode is allowed to complete — this is what makes the design a *precise* interrupt (the instruction at
  `mepc` has no side effects, so MRET can safely re-execute it). Priority: `INT[0]` (button) > `INT[1]`
  (timer) > `INT[2]` (aux buttons). See `project3/README.md` for exact `PCPU.v` line references — they will
  drift as the file is edited, so treat them as approximate pointers, not ground truth.
- **RAM write-gating (project2/project3)**: `PCPU_TOP.v` gates `wea_mem` with `data_ram_we` (derived from
  MIO_BUS address decode) so that a `sw` targeting a peripheral address (`0xE000_0000`/`0xF000_0000`) doesn't
  also accidentally write the data RAM at the same address bits. project1's `SCPU_TOP.v` has no such gating.
  If you add a new memory-mapped peripheral region, make sure this gate still excludes it.
- **`MIO_ready` must stay tied to `1'b1`** in single-cycle/pipeline top levels — an earlier bug wired it
  through `CPU_MIO` so non-load/store instructions never bumped `PC`. If you see PC stall on non-memory
  instructions, check this first.
- **`icf.xdc` clock period**: project3's `icf.xdc` fixed a real bug where `-period 100.00` on `create_clock`
  actually specified 10MHz, not the intended 100MHz — always use `-period 10.00 -waveform {0 5}` for a true
  100MHz constraint. Don't copy an older `icf.xdc` into project3 without checking this.
- **NOP encoding**: pipeline bubbles/flushes inject `32'h00000013` (`addi x0, x0, 0`) — writes to `x0` are
  hardware-masked and it triggers no peripheral access, making it a true no-op for stalling/flushing.
