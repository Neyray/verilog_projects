---
description: Guided workflow for fixing a described CPU/peripheral bug in this repo
---

Fix the following issue in this RV32I CPU repo: $ARGUMENTS

Follow this sequence — don't skip steps just because the fix looks obvious:

1. **Locate every affected copy.** Search all of `project1/`, `project2/`, `project3/`, and `lab/` for
   the module(s) involved — peripherals and bus glue are copy-pasted per project directory, not
   shared (see root `CLAUDE.md`). Decide explicitly whether this bug exists in one copy or all of
   them.
2. **Reproduce before fixing.** Write a small throwaway `iverilog` testbench that demonstrates the bug
   in isolation (pattern: `test/tb.v` or `code/sccomp_tb.v`). For a full CPU/top-level module that
   can't be elaborated standalone (needs Vivado IP for ROM/RAM), stub a behavioral RAM/ROM instead —
   see `.claude/rules/testing.md`.
3. **Apply the minimal fix.** Don't refactor surrounding code while fixing a bug.
4. **Re-run the testbench** and confirm the failure mode from step 2 is gone.
5. **Propagate.** If the bug exists in sibling project directories per step 1, apply the same fix
   there too, and check whether the `.edf` netlist (project2/project3) also needs regenerating —
   Vivado synthesizes the `.edf` over the `.v` if both are present.
6. **Update docs if behavior changed.** If the fix changes what appears on the 7-segment display, LEDs,
   or the address map, update the relevant table in root `README.md` or the affected `projectN/README.md`
   in the same change.
7. **Run the security/correctness checklist** (`.claude/skills/security-review/checklist.md`) if the
   fix touches `PCPU.v`, `SCPU.v`, `MIO_BUS.v`, `dm_controller.v`, or a `*_TOP.v`.

Report back concisely: what the bug was, what changed, which files/projects it touched, and how it was
verified.
