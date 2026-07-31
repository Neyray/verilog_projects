---
name: security-review
description: RTL correctness/security review for this RV32I CPU repo — checks a Verilog diff for hardware-specific bug classes (X-propagation, latch inference, CDC, privilege/CSR boundary violations, address decode overlaps) before it's considered safe to simulate or synthesize. Use whenever changes touch PCPU.v, SCPU.v, MIO_BUS.v, dm_controller.v, or any *_TOP.v.
---

# RTL security/correctness review

This repo doesn't have software-style security bugs (no network input, no injection surface). The
closest analogue is: (a) the memory-mapped CSR/interrupt boundary in `project3` — the one place where
"privileged" state (`mie`/`mepc`/`mcause`) is exposed to ordinary `sw`/`lw` instructions, and (b) plain
RTL correctness bugs that silently produce wrong hardware (which for coursework grading is the
equivalent of a security bug: it fails acceptance silently instead of loudly).

## When to run this

Before treating any edit to `PCPU.v`, `SCPU.v`, `MIO_BUS.v`, `dm_controller.v`, or a `*_TOP.v` as done.

## How to run it

1. Read the full diff for the affected module(s), not just the changed hunk — hazards and CSR logic
   are easy to break at a distance (e.g. editing `int_taken` without re-checking every place it gates
   a flush).
2. Walk `checklist.md` in this skill directory item by item against the diff.
3. For every item that's uncertain rather than clearly fine, either write a small `iverilog` testbench
   that exercises it (see [[testing]]) or state explicitly that it's unverified — don't silently pass
   over it.
4. Cross-reference `project3/README.md`'s "核心代码行号速查" table for the CSR/interrupt logic — if a
   line-number reference no longer matches the code after your edit, the table is stale and should be
   updated in the same change.
5. Report findings the same way `/code-review` does: most-severe first, with a concrete failure
   scenario (what input/state makes it misbehave), not a vague "consider adding a check."
