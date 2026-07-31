# Module interface / bus protocol rules

Verilog has no "API" in the REST-endpoint sense — the closest equivalent is the module port list and
the MIO_BUS memory-mapped protocol shared across all three projects. Treat both as a contract.

## Port naming conventions already established in this repo

Stick to these when adding or modifying a module so it reads consistently with its neighbors:

- Clocks: `clk` is the raw board clock; `Clk_CPU` is the divided CPU clock produced by `clk_div`.
  Never introduce a third clock name for the same signal.
- Reset: active-low, named `rstn`, synchronized/registered at the top level (see `Enter.v`). Don't add
  an active-high reset into a module that will be instantiated alongside active-low ones.
- Bus signals: `Addr_out`, `Data_out`, `Data_in`, `mem_w`, `dm_ctrl` are the CPU-core → bus naming used
  by `SCPU.v`/`PCPU.v`. `MIO_ready` must always be tied to `1'b1` at the top level — see the historical
  bug in the root README where a self-looped `MIO_ready` deadlocked the PC.

## Adding a new memory-mapped peripheral

1. Pick an address region that doesn't collide with the existing map (see root `README.md` → "外设地址
   映射"): `0x0000_0000` data RAM, `0xE000_0000` Multi_8CH32, `0xF000_0000` SPIO, `0xC000_0000`-ish
   Counter_x, and — project3 only — `0xD000_00xx` CSR (captured inside `PCPU.v`, never routed through
   `MIO_BUS`).
2. Add the decode in `MIO_BUS.v`. Follow the existing `<region>_we` naming pattern
   (`GPIOe0000000_we`, `GPIOf0000000_we`, `counter_we`).
3. Gate any RAM write enable with the new region's decode, mirroring `data_ram_we` in
   `project2/PCPU_TOP.v` / `project3/PCPU_TOP.v`, so a store to the new peripheral can't also strike
   `RAM_B` (project1's `SCPU_TOP.v` intentionally has no such gate — don't copy that omission forward).
4. Since peripherals are duplicated per project directory rather than shared, apply the same change to
   every `projectN/MIO_BUS.v` that should support it, and check whether `project2`/`project3` also need
   their `.edf` netlist regenerated (they ship both `.v` and `.edf` — the `.edf` is what Vivado actually
   synthesizes if present, so a `.v`-only edit can silently be ignored).
5. Update the address-map table in root `README.md` and, if it changes what a `Multi_8CH32` SW7:5
   channel displays, update the per-project README's channel table too.

See [[testing]] for how to validate the new decode before calling it done, and [[add-peripheral]] for
the full step-by-step workflow.
