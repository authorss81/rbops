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