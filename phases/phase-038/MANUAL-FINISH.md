# phase-038 — finished by hand, not by the pipeline

## Why this phase is `.done` without a completed review loop

`might fail` is implemented, landed, and green — but the pipeline's books never
closed. The sequence, reconstructed from the two repos:

1. A run implemented the phase, and `redblue@963d660` (`rbops: phase-038`,
   2026-10-09T22:24:52Z) landed on redblue main. The redblue push step runs
   only on `PROGRESS=true`, which requires rc=0 from *both* `run` and
   `review`, so a review passed for this tree.
2. The rbops state push carrying `.done` was lost (the likely shape: push
   rejected, rebase loop exhausted, or the run was superseded before the state
   step). What survived instead was `.failed` + `.conflict` at attempt 2.
3. The next run re-selected 038 (no `.done` on record), resumed from
   `rbops-recovery/phase-038` onto moved main, hit the diverged-resume
   conflict, and failed — attempt 3, `.blocked`.

No `phase-038.review.*.log` was ever committed, so the passing review exists
only as the implication of the landing, not as a readable verdict. That gap is
recorded here rather than papered over.

## What was verified by hand before marking done

- `963d660` is a single-parent commit on top of `b6d633b` (the squash-adopted
  resume). No checkpoint ancestry leaked into redblue.
- Every added line in `src/`, `tests/`, `SPEC.md`, `docs/GRAMMAR.md` and
  `docs/BYTECODE.md` was scanned for `#[ignore]`, `// skip`, `.skip(`,
  `allow(clippy`, `allow(dead_code`, `todo!`, `unimplemented!`,
  `unreachable!` — **zero hits**.
- The landed `tests/might_fail_test.rs` holds 43 `#[test]` functions, 23 of
  them `edge_*` — more than the REPORT's 36, not fewer. `Error::is_resource_limit`
  is present in `src/error.rs`.
- The committed log shows the agent *extending* `tests/function_literal_test.rs`'s
  `message()` helper to accept the new `Error::Limit` variant rather than
  weakening the assertion — honest fixing under review pressure.
- `FORMAT_VERSION` moved 5 → 6 with the version table, the disassembler, the
  opcode table-end assertions, and `bootstrap/compiler.rb`'s version word all
  following. The fixed point is not asserted here (that is phase-022's standing
  claim), but nothing in this diff contradicts it.

What was **not** verified: a full `cargo test` run of the landed tree (no heavy
tests are run by hand; CI owns that), and `./rbops/verify.sh phase-038`, which
cannot run outside the pipeline checkout. No result is claimed for either.

## Markers

`.failed`, `.conflict` and `.blocked` removed; `.done` set. Selection reads
`.done` first, so the phase can never be re-queued against work already merged.
The recovery branch `rbops-recovery/phase-038` is left in place as the audit
trail of the attempt that failed on the conflict rather than on the code.
