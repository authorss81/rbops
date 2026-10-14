# phase-053 — notes for the retry

## What happened on attempt 1

The run was **cut off mid-verification**, not defeated by a wrong answer. The log
ends like this:

```
$ cargo fmt --all && cargo fmt --all -- --check && echo FMT_CLEAN
FMT_CLEAN

$ cargo clippy --all-targets -- -D warnings 2>&1 | tail -30
   Compiling redblue v0.2.0
    Finished `dev` profile [unoptimized] target(s) in 5.20s
```

and then nothing. Clippy compiled and reported nothing; the run ended there.
So the phase was deferred for a budget/runner reason, not because its colour
work was wrong. `cargo test --all-targets` had already been invoked earlier in
the log and its result was never confirmed either.

**This phase is `.deferred`, not `.failed`. No attempt was burned proving
anything.** A retry starts from a fresh context and a fresh budget.

## Do not re-derive what attempt 1 already did

Attempt 1 got quite far. Reconstructing its state is cheaper than redoing it:

- It created `tests/repl_color_test.rs` with named tests including
  `a_loaded_program_keeps_its_text_with_color_on` and
  `colors_off_in_a_live_session_prints_the_plain_transcript`. Both were seen
  failing at `tests/repl_color_test.rs:237` and `:149` before the run ended.
- `src/repl/` already exists and is complete: `commands.rs`, `completer.rs`,
  `editor.rs`, `history.rs`, `mod.rs`. The colour system this phase wants lives
  in `src/repl/mod.rs` and already has a `style.paint(Paint::..., ...)` call
  shape used at four call sites.

**Check whether the work is already committed on `redblue` main before writing
anything.** If attempt 1's diff landed, this phase may be closer to done than
`.deferred` suggests, and the honest move is to verify and close it rather than
reimplement it.

## The one real trap: `cargo fmt --all` reformatted someone else's files

Attempt 1 ran `cargo fmt --all` and it rewrote `src/repl/mod.rs` — files that
**phase-052 created minutes earlier**, not files this phase owns. The diff it
produced was pure reflow:

```rust
-                        self.style
-                            .paint(Paint::Result, &format!("= {}", value))
+                    self.style.paint(Paint::Result, &format!("= {}", value))
```

This is worth being careful about on the retry:

1. **That reformat is not this phase's work.** It belongs in whichever phase
   formatted the tree, not smuggled into a colour-system diff. A reviewer will
   read it as an unrelated change to another phase's output.
2. **`cargo fmt --all -- --check` is the gate command; `cargo fmt --all` is
   not.** Running the bare formatter rewrites the tree. If the tree is not
   fmt-clean, that check will fail for a reason that has nothing to do with this
   phase — and the honest response is to say so in REPORT.md, not to make the
   reformat look like part of the change.
3. **The tree is fmt-clean** — verified with `cargo 1.98.1`, `cargo fmt --all --
   --check` exits 0. (An earlier version of this file said the opposite and
   called it a live trap. That was wrong: the check had never run, because the
   environment had no Rust on its PATH and the shell reported exit 0 on
   `cargo: command not found`, which was misread as "clean".) So the reformat
   attempt 1 produced was reformatting already-correct code — most likely a
   stale or mis-scoped invocation rather than a real fix.

## What attempt 1's reformat therefore means

If `cargo fmt --check` passes on the tree this phase branched from, then the
diff attempt 1 produced against `src/repl/mod.rs` did not fix a formatting
defect. Either:

- the formatter was pointed at the wrong path, or
- it ran against a working tree that already differed from the committed state,
  or
- the reflow came from a `rustfmt` version difference between the runner and
  whatever produced those lines originally.

**Do not land that reflow as part of this phase.** `cargo fmt --check` passes
without it, so it is not required by the gate, and it is not this phase's work.
If the retry genuinely needs it, that is a finding of its own with its own
justification — not a drive-by reformat inside a colour-system diff.
---

# ADDENDUM - why this phase is .blocked

This phase spun for roughly **12 hours and ~120 CI runs**, each about 6 minutes,
every one `rc=42`, producing no work. Every run reported `success`, so nothing
looked wrong from outside.

## Root cause: the preflight path bypassed the deferral counter

`dispatch.sh` had a preflight branch that, when preflight refused the inherited
diff (rc=3), did a bare `touch .deferred` instead of calling `defer_phase`. It
therefore never bumped `.deferred_attempts` - the file was never created at all.

`MAX_DEFERRALS=5` reads that counter. With no counter the bound could not fire,
`.blocked` was unreachable, no model was ever dispatched, and no attempt was
consumed. An infinite loop with no exit.

Introduced by the preflight work in `0f1ea86` the same day. The smoke test for
that feature used a dead-model stub and a clean tree and never exercised the
rc=3 refusal path, so nothing caught that it skipped the counter. That one missing
assertion is why this ran 120 times unnoticed.

## Fixed

The preflight refusal now routes through `defer_phase` like every other deferral
reason, sharing one counter and one bound. Verified: 55 phases done and advancing
after the fix.

## Why it is still blocked, and what a human must decide

Preflight refuses the diff this phase inherits, and that refusal is correct - the
gate cannot read the recovered tree. So the phase cannot proceed until one of:

1. **the gate is taught to read a recovered tree**, or
2. **the manifest/finding is wrong** and this phase should not run, or
3. **the preserved work is abandoned** and the phase restarts from a clean tree.

The preserved work was archived to `rbops-archive/phase-053` and the per-run
artifacts are named `rbops-phase-053`, so nothing is lost by leaving it blocked.

## Follow-ups

- **Any new early-exit path must route through `defer_phase`**, never a bare
  `touch .deferred`. A deferral that costs no attempt still has to be counted.
- **smoke should assert the rc=3 path increments `.deferred_attempts`.**
- **A run that defers forever while reporting success is a silent failure mode.**
  Worth an explicit alarm: N consecutive `rc=42` with no state change should
  raise rather than chain quietly.

---

# UPDATE- why 053 was blocked (supersedes the decision list above)

Blocked manually rather than waiting out the deferral budget, which stood at
3/5 with two ticks remaining and nothing to gain from them.

The deferrals are **not** a code defect. The model log ends identically every
run, right after clippy compiles:

    Finished \dev\ profile [unoptimized] target(s) in 5.20s

...and then nothing, on runs of ~12 minutes rather than the 90-minute attempt
timeout. That signature is the free-tier model chain being unavailable -
\infra_failure\, not a work failure - which is why no attempt was ever
consumed. Nothing in the repository can fix that; it is an upstream
availability problem.

It was left deferred rather than blocked because a blocked phase needs a human,
and blocking would have stalled a legitimate REPL colour-system phase over a
transient upstream outage.

## The real problem: deferred phases have selection priority

\dispatch.sh\ picks \.deferred\ phases first ("retry, cheapest continuity").
While 053 sat deferred, it was re-selected on every tick while phase-083,
phase-084 and phase-085 sat ready and untouched. A deferred phase therefore
**starves ready work** for as long as its deferral budget lasts.

The budget bounds it - five ticks, then blocked - so this is a delay, not a
runaway. But the bound is the only thing stopping it, and when the bound was
bypassed (the bare \	ouch .deferred\ bug fixed earlier today) the result was
~12 hours of nothing.

## What this phase needs, when the model chain is healthy again

1. Unblock it. It is a real phase with real work to do.
2. Run it **without** a preserved recovery, so it starts clean - the previous
   attempt's work was a 0-byte patch and its checkpoint was 0 bytes, so there
   was never anything to inherit.
3. Watch the first run for the same symptom: log ending after clippy with a
   short run time means the model chain is still down, not that the phase is
   wrong.

Worth considering separately: should a deferred phase yield to ready work
after one retry instead of holding selection for five? Priority is right for
continuity, but it lets one transient outage stall a queue that has 15 ready
phases behind it.