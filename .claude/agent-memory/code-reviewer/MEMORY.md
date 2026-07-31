# code-reviewer agent memory

Seed knowledge for the `code-reviewer` subagent, so it doesn't re-discover (or re-flag as new) issues
that are already known and intentionally fixed in this repo.

## Already-fixed bugs — verify they haven't regressed, don't re-report as new findings

- **`MIO_ready` self-loop deadlock.** An earlier version tied `MIO_ready` to `CPU_MIO`, so any
  non-load/store instruction saw `MIO_ready=0` and `PC` never advanced. Fixed by tying `MIO_ready` to
  constant `1'b1` in all three `*_TOP.v`. If a diff touches `MIO_ready`, check it's still a constant
  tie-off, not routed through bus-ready logic.
- **`icf.xdc` clock period bug (project3).** `create_clock -period 100.00` actually specifies 10MHz,
  not 100MHz. project3's `icf.xdc` correctly uses `-period 10.00 -waveform {0 5}`. If someone copies an
  older `icf.xdc` into project3, this regresses and causes button-read/PC glitches at fast clock
  divider settings — flag any `icf.xdc` diff that touches `create_clock`.
- **RAM write-gating.** `project2`/`project3` gate `wea_mem` with `data_ram_we` (derived from MIO_BUS
  address decode) so a `sw` to `0xE000_0000`/`0xF000_0000` can't also write `RAM_B`. `project1` has no
  such gate by design (it predates the fix) — don't flag project1's absence of gating as a bug unless
  asked to backport it.

## Structural fact to keep re-deriving correctly

Peripheral modules (`Multi_8CH32`, `SPIO`, `SSeg`, `Counter_x`, `Enter`, `clk_div`, `MIO_BUS`,
`dm_controller`) are duplicated verbatim across `project1/`, `project2/`, `project3/` rather than
shared via a common source — there is no include mechanism in this repo. A one-sided fix (applied to
only one project's copy) is a legitimate finding to raise, not an assumption to make silently.
