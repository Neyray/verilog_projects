# Workflow: add a new memory-mapped peripheral

Reference workflow for the step sequence described in `.claude/rules/api-design.md`. Follow in order;
each step depends on the previous one.

1. **Pick an address region.** Cross-check against root `README.md`'s "外设地址映射" table:
   `0x0000_0000` RAM, `0xE000_0000` Multi_8CH32, `0xF000_0000` SPIO, `0xC000_0000`-ish Counter_x,
   `0xD000_00xx` CSR (project3 only, CPU-internal). Pick something that doesn't collide.
2. **Write the peripheral module** following the port-naming conventions in
   `.claude/rules/api-design.md` (`clk`/`Clk_CPU`, active-low `rstn`, bus signal names matching
   `MIO_BUS`'s existing `<region>_we` pattern).
3. **Wire the decode into `MIO_BUS.v`** for each `projectN/` that should carry the peripheral. Do this
   once per project directory — there is no shared source, this repo is copy-per-project.
4. **Gate RAM writes** so a store to the new region can't also strike `RAM_B` — mirror
   `data_ram_we` in `project2/PCPU_TOP.v` / `project3/PCPU_TOP.v`.
5. **Instantiate in each `*_TOP.v`** and connect to the CPU's `Addr_out`/`Data_out`/`mem_w`/`Data_in`
   bus, same as the existing peripherals.
6. **Regenerate/update the `.edf` netlist** for `project2`/`project3` if those directories ship one for
   the files you touched — Vivado prefers the `.edf` over the `.v` when both exist, so a `.v`-only
   change can silently be ignored at synthesis time.
7. **Add a display channel** in `Multi_8CH32` if the peripheral's state is worth observing on the
   7-segment display, and document the new `SW7:5` mapping in the project's README.
8. **Validate.** Write an `iverilog` testbench per `.claude/rules/testing.md` covering: address decode
   fires only on the intended region, doesn't fire on neighboring regions, and (if writable) doesn't
   leak into `RAM_B`.
9. **Update docs.** Root `README.md` address-map table, and the per-project README if board-visible
   behavior changed.
