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
3. **The tree is currently not fmt-clean** (verified while closing phase-092).
   So this is a live trap, not a hypothetical one. See the open question at the
   bottom of `phases/phase-093/REPORT.md` in redblue.

## Open question this phase may need to answer

Redblue's `cargo fmt --check` gate fails today because the tree is not
fmt-clean. Nobody owns fixing that. If attempt 1's reformat was the *only*
thing standing between the tree and a clean `cargo fmt --check`, that is worth
recording in REPORT.md — and possibly worth a FINDINGS entry for a dedicated
formatting phase, rather than having the formatting land invisibly inside an
unrelated colour-system change.