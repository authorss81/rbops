# MANUAL-FINISH - phase-062

Done by hand, not by an agent attempt. The implementation had already landed
(redblue `0647108` + `af3312b`, +1,367 lines) and the gate had gone green; the
reviewer's round-3 findings were the only thing between it and `.done`, and the
fix pass that should have addressed them spent its whole window reading the
14,258-line diff and never edited a line.

The pipeline read that as an attempt that never happened and blocked the phase.

## What was fixed

Two MAJOR findings, both in the scratch VM a watch is evaluated on:

- `observe_bindings` replaced the locals stack but did not restart
  `frame_scope_base`, so the base pointed into a stack that no longer existed.
- The scratch VM was rooted at `.` rather than at the program's own root. The
  roots are the same today, so this is a latent inconsistency rather than a live
  bug; the fix makes the scratch share the program's root by construction.

Also tightened `frame_locals`'s fallback and dropped three unused imports that
were failing `cargo clippy --all-targets -- -D warnings` on the branch.

Product commit: `1dbfd1c`.

## The BLOCKER finding was not a defect

The reviewer said the VM discards the `DebugAction` the hook returns, so
`:break`, `:step`, `:next` and `:continue` cannot stop the program.

They can. The stop is the hook blocking on stdin inside `debug_stop`, which
prints the stop report and reads the user's answer, and the action it returns
is consumed by `DebugSession::record_action`, which arms the next stop. The VM
never needed it. `tests/debugger_test.rs` has sixteen tests - one of them
asserts a breakpoint in a loop fires on every iteration and the program still
prints every value - and they passed before this fix and after it.

## Evidence

- `cargo fmt --all -- --check` clean
- `cargo clippy --all-targets -- -D warnings` clean
- `cargo test --lib` - the same six failures as the branch before this change
  (five are Windows path escapes in test fixtures, one is the known clock
  test); the three new tests pass
- `cargo test --test debugger_test` 16 passed
- `cargo test --test debug_watch_test` 2 passed
- `cargo test --test repl_test` 64 passed, the same two failures as the branch
  before this change
- `cargo test --test unreviewed_work_ack_test` 13 passed

## Still open

`phase-062` is a 1,231-line phase on the recovery branch, and the 21 REPL
phases added together in one commit (052-072) include several of that size.
A phase that size is a wall for a reviewer and for a fix pass alike. Splitting
one into `.stack`, `.locals` and `.watch` would make the work reviewable;
`phases.json` is the auditor's to write, so that is the auditor's to do.