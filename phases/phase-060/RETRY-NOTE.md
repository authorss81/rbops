# RETRY-NOTE — phase-060 — Close the file loop: `.reload`, `.format`, `.format`-on-enter

The previous attempt deferred 3 times. The reason is unknown from the preserved
work: `.recovered` exists, the checkpoint log is 0 bytes, and the preserved patch
is 0 bytes. So either nothing was written or nothing survived. The retry-note
below is the only guidance this retry has; there is no REPORT.md claim to
distrust.

## The two shapes of failure this phase will hit, and how to fix both in one run

The gate has two checks that can fail independently:

**A. `tests/` not touched** (`must_touch: [tests/]`). The easiest and also the
mandatory floor. Write at least one `test` block before anything else.
A single `test "edge_reload_keeps_variables" ... end` satisfies the quota if
it asserts a failure is produced; a `test "edge_empty_file_is_handled" ... end`
covers an empty-file case, and that covers the edge_* requirement too.

**B. No `tests/` that asserts a failure is produced.** Every passing suite can
still fail this. The only way to satisfy it is to call something that CAN
fail and assert it does: `try ... catch error ... end` in Redblue, or
`assert!(r.is_err())` in Rust. It takes 10 minutes at most.

The previous attempt's REPORT.md (if it exists) claims `tests/` touched, but
there is no test file in the preserved work; the claim was either empty or about
different tests. Verify your own counts, not the previous numbers.

The work itself — `.reload`, `.format` and format-on-enter — is all about
reading, formatting and writing the file loop. A `.format` that never writes
anything is invisible to any gate; only `.format` that rewrites the source tree
is observable. `fmt` is already clean at `main`, so the formatter has no real
work unless it writes; if it writes nothing, the phase's code changes are the
REPL command wiring, not a file change. That means the gate's diff is small
but must still touch `tests/`.

## Budget this time

If you have 180 minutes now, spend them like this:

| Time | Do this |
|---|---|
| 0 - 15 | Reproduce the finding: run `.reload`, `.format`, and show that the output does not match what `SPEC.md` claims about format behaviour. Record the exact wrong output in the log. |
| 15 - 30 | Write ONE `tests/repl_reload_format_edge_... .rb` block that asserts a failure - either a file that does not exist (`ERROR`), or a format that produces a wrong value. Watch it fail. |
| 30 - 90 | Implement. The REPL command table is in `commands.rs`; the editor sources are in `editor.rs`; format calls `formatter.rs`. Read the interfaces rather than re-deriving the whole file. |
| 90 - 120 | Verify: fmt clean; clippy clean; the new edge test passes; the gate output is captured and included; `tests/repl_...` touches `tests/`. Write `REPORT.md`. Commit. |
| Do NOT spend 60 minutes re-measuring claims that are already measured. Read `tests/repl_color_test.rs` for the 17-test example of assertions that cover both a failure and an edge case, and follow that shape rather than deriving it from scratch. |