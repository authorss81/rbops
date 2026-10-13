# phase-051 — closed by hand: its finding no longer reproduces

## What this phase was for

051 was opened for a specific, measured defect, quoted from its own manifest
finding:

> `phases/phase-022/.done` exists in the pipeline root, and the corresponding
> commit on redblue main is `dff04f6`. But `git -C redblue status --short`
> shows SEVEN modified files with 941 insertions and 335 deletions that are NOT
> in any commit… the S3 fixed point that phase-022 exists to prove is not in the
> commit history at all.

Its acceptance criteria were therefore: commit those seven files behind a commit
naming phase-022, prove the four bootstrap tests run from a **fresh clone**, and
leave `git status --short` empty.

## Why the pipeline could not close it

The agent investigated, found nothing to do, and said so — which is correct
behaviour, and the gate correctly refused the empty diff:

> *"The finding is **stale** — I did not change any source, by design. The work
> was adopted via the pipeline's own `resume phase-NNN: adopt preserved work`
> path (`054e0d6`, `dff04f6`, `8910456`, `e26659d`, `10f9750`, `daeb73b`). Only
> the commit **timing** differed from what the finding assumed."*

Gate result, for the record: `must_touch` unsatisfied, test quota 0, no
`edge_*`, no failure assertion — all four symptoms of one fact, a phase with no
work left rather than a phase that failed.

## Verified by hand, at closure

- `git -C redblue status --porcelain` on `origin/main` is **empty**: no uncommitted
  S3 work exists. The tree is clean.
- The four tests 051 named are present in `tests/bootstrap_selfhost_test.rs` on
  `origin/main`, all four found by name: the fixed point
  (`edge_the_self_hosted_compiler_compiles_itself_byte_identically`), the
  determinism triple (`edge_three_consecutive_self_compilations_are_byte_identical`),
  the step budget (`edge_the_self_compilation_still_obeys_the_step_budget`), and the
  jump-patching regression (`edge_a_while_loop_nested_in_another_patches_its_own_jump`).
- redblue `origin/main` carries `054e0d6 rbops: phase-022 (2026-10-09T01:37:10Z)`,
  a real single-parent commit naming the phase — which is what 051 asked for. The
  finding's own evidence (`dff04f6` being the only phase-022 commit) is out of date:
  `054e0d6` landed afterwards.
- The pipeline's own 051 run reproduced this independently: it ran
  `cargo test --all-targets` (**1463 passed, 0 failed**), `cargo fmt --check` pass,
  `cargo clippy --all-targets -- -D warnings` pass, and reported `./rbops/verify.sh`
  as **not run** because `rbops/` is absent from the Redblue checkout. No result is
  claimed for the fourth gate.

Not verified here: a fresh-clone run of the four bootstrap tests from this desk.
The 051 agent did run them (20 passed in 150.73s and 16 passed in 198.46s against
`CARGO_TARGET_DIR` in a `--no-local` clone), and CI re-runs the whole suite on
every push regardless.

## Markers

`.deferred` removed; `.done` set. Selection reads `.done` first, so the phase can
never re-queue. `.attempts` stays at 1 and `.recovered` stays as the trail to the
parked attempt.

## What this cost, and why preflight now covers it

One 21-minute model call and one gate cycle to establish that the finding was
stale. That is the cheap case, not the expensive one: 037 and 048 each burned three
~5-hour runs on defects the gate could not see. Preflight (dispatch.sh, before the
model call) now asks the diff-based half of the gate against whatever a retry
would inherit, so a defect the agent cannot fix stops the run in seconds instead of
after an attempt.