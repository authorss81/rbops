# phase-037 — finished by hand, not by the pipeline

## Why this phase is `.done` without a completed review loop

The work landed as `redblue@ccff5f4` (`rbops: phase-037`, 2026-10-10T19:03:03Z)
and the pipeline's books never closed: origin carries `.attempts=3` with
`.failed`, `.blocked` and `.conflict` set. No `phase-037.review.*.log` was ever
committed and the implement log contains no verdict line, so — as with 038 —
the passing review exists only as the implication of the landing (the redblue
push step runs solely on `PROGRESS=true`, which requires rc=0 from both `run`
and `review`), not as a readable verdict. That gap is recorded here rather than
papered over.

This is the fourth disposition of this phase and the first one that is about
the books rather than the work. The traps, in order: (1) unsatisfiable DoD
lines, corrected in the manifest; (2) stale-REPORT anchoring, fixed by reading
`RETRY-NOTE.md` into the resume context; (3) the gate's failure-assert regex
not knowing the `eval_err` idiom, fixed in `verify.sh` with smoke cover. Each
fix is committed and each was verified. What remains was never a code problem
after attempt 3 — it was the completion bookkeeping.

## What was verified by hand before marking done

- `ccff5f4` is a single-parent commit on `8910456` (`resume phase-037: adopt
  preserved work`), whose own parent `034c5f0` is on main's line — verified by
  `merge-base --is-ancestor`. No checkpoint ancestry leaked into redblue; the
  squash rule held.
- Every added line in `src/`, `tests/`, `SPEC.md` and `phases/` was scanned for
  `#[ignore]`, `// skip`, `.skip(`, `allow(clippy`, `allow(dead_code`, `todo!`,
  `unimplemented!`, `unreachable!` — **zero hits**.
- The implementation is present in the landed tree: SplitMix64 (`splitmix64`),
  `DEFAULT_SEED`, `RANDOM_STATE`, `seed_random` in `src/runtime.rs` — the
  wall-clock source is gone from the `random*` arms.
- The registration is coherent: `random` + `random_seed` added to
  `stdlib::builtins()`, `BUILTIN_NAMES`, and the REPL completer keyword list —
  three places that must agree, all agreeing.
- The final 12-line diff is a seed-contract refinement (negative/`1e300`
  saturation semantics stated as contract, not accident), not new machinery.
- The committed implement log ends with the agent's measured gates (fmt,
  clippy zero warnings, full suite green) and an explicit `DONE`.

What was **not** verified: a full `cargo test` run of the landed tree by hand
(no heavy tests are run by hand; CI owns that), `./rbops/verify.sh phase-037`
by hand, and any review verdict beyond the landing's implication. No result is
claimed for any of the three.

## Markers

`.failed`, `.blocked` and `.conflict` removed; `.done` set. Selection reads
`.done` first so the phase can never re-queue against work already merged.
`.attempts` stays at 3 as the history of what it cost; `.recovered` stays as
the trail to the parked attempts; `RETRY-NOTE.md` stays as the trap diary that
fixed two pipeline bugs (resume-ctx inclusion, `eval_err` recognition) on this
phase's back.
