# Testing rules

There is no CI and no top-level test runner in this repo. Verification is a manual, per-module
discipline — follow these rules whenever you change a `.v` file.

## 1. Never claim a fix works without simulating it

`iverilog`/`vvp`/`gtkwave` are installed on this machine (see `test/Makefile` for the reference
invocation). Before saying a Verilog change is correct:

- If the changed module is small and self-contained (`alu.v`, `ctrl.v`, `EXT.v`, `dm_controller.v`,
  a single peripheral), write a throwaway testbench (`tb_<module>.v`) modeled on `test/tb.v` or
  `code/sccomp_tb.v`, compile with `iverilog -o /tmp/... module.v tb_module.v`, run with `vvp`, and
  read the `$display` output or dump a `.vcd` and inspect key signals/timestamps textually
  (`gtkwave` needs a display — don't assume one is available; prefer `$monitor`/`$display` assertions
  in headless runs).
- If the changed module is a full CPU core (`SCPU.v`, `PCPU.v`) or a top level (`*_TOP.v`), it cannot
  be elaborated standalone with `iverilog` because `ROMD`/`RAM_B` are Vivado Block Memory Generator IP
  cores, not `.v` sources in this repo. In that case:
  - Stub the missing IP with a behavioral RAM/ROM model (`reg [31:0] mem [0:N]` + `$readmemh`) purely
    for the testbench — do not commit the stub into the project source tree.
  - Or reason explicitly through the datapath/timing by hand, and say so plainly rather than implying
    it was simulated.
- Board-level behavior (7-segment codes like `AC123456`, LED patterns, button/interrupt timing) can
  only be confirmed on real hardware or in Vivado's simulator — do not fabricate a "verified on board"
  claim.

## 2. Preserve the acceptance criteria in the READMEs

Each `projectN/README.md` has a "验收操作" section describing exact switch settings and expected
7-segment output. Any datapath/control change must not silently break that contract. If a change
does change the expected output, update the README's table in the same edit.

## 3. Regression-check shared peripherals

`Multi_8CH32` / `SPIO` / `SSeg` / `Counter_x` / `Enter` / `clk_div` / `MIO_BUS` / `dm_controller` are
duplicated per-project rather than shared. A testbench that only covers the copy in `project2/` says
nothing about `project1/` or `project3/`'s copy — see [[api-design]] for how to propagate a fix.
