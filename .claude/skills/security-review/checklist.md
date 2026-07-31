# RTL review checklist

## Combinational / synthesis hazards

- [ ] Every `always @(*)` block assigns its output on every branch — an unassigned branch infers a
      latch instead of the intended combinational logic.
- [ ] Blocking (`=`) is used only in combinational `always @(*)` blocks; non-blocking (`<=`) is used
      only in clocked `always @(posedge ...)` blocks. Mixing them in the same always block, or using
      blocking assignment in a clocked block that later gets read by another clocked block, is a
      classic race.
- [ ] No combinational loop introduced between newly connected signals (e.g. a forwarding mux whose
      select depends on a signal it also feeds).

## Reset and clock domains

- [ ] New registers are reset (or explicitly justified as don't-care-on-reset) under the same
      active-low `rstn` convention as their neighbors — see [[api-design]].
- [ ] Any signal crossing from `clk` domain to `Clk_CPU` domain (or from a button/switch input) goes
      through the same debounce + 2-FF synchronizer pattern already used in `Enter.v` /
      `PCPU_TOP.v`'s button-interrupt path (see `project3/README.md` "事件 toggle" / "2-FF 跨时钟同步").
      A raw async signal read directly by CPU-clocked logic is a metastability bug.

## CSR / interrupt privilege boundary (project3)

- [ ] CSR addresses (`0xD000_0000/4/8/C/10/14`) are still only interpreted inside `PCPU.v`'s EX stage,
      never routed through `MIO_BUS` — routing them through the normal bus would let an ordinary
      peripheral alias into CSR space.
- [ ] `int_taken` still requires `mie && !stall && !flush && !mret_taken` — removing any one of these
      guards can double-enter an ISR or corrupt `mepc` mid-stall.
- [ ] IF/ID is still flushed on `int_taken` but ID/EX is not — this is what keeps the interrupt
      precise (the instruction already in EX is allowed to retire so `mepc` points at a
      side-effect-free re-entry point). Flushing ID/EX on `int_taken` would silently break precision
      without breaking any visible test.
- [ ] Interrupt priority order (`INT[0]` button > `INT[1]` timer > `INT[2]` aux) is preserved unless
      the change intentionally re-prioritizes — check the arbitration `case`/`if-else` chain order,
      not just presence of all three.

## Address decode

- [ ] New/changed address regions in `MIO_BUS.v` don't overlap an existing region (see the map in
      root `README.md`).
- [ ] Any new store-target region is excluded from `wea_mem` the same way `data_ram_we` excludes
      `0xE000_0000`/`0xF000_0000` today (project2/project3 only — flag if project1 needs the same fix
      backported, since it currently has none).

## Duplication drift

- [ ] If the changed file exists in more than one of `project1/`, `project2/`, `project3/`, `lab/`,
      confirm whether the fix needs to be applied to the sibling copies too, or whether the divergence
      is intentional (e.g. project3's `PCPU.v` intentionally differs from project2's).
