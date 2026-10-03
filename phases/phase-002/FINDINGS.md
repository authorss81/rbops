# phase-002 — FINDINGS

## Pre-existing failure observed while running the examples

`rb run modules/MathUtils.rb` fails on `main` and still fails after this
phase's diff:

```
$ ./target/debug/rb run modules/MathUtils.rb
Error: ParserError: Expected function name
exit=1
```

Verified pre-existing by stashing the phase diff, rebuilding, and re-running:
identical output and exit code before and after.

All other `examples/*.rb` and `modules/*.rb` run clean.

This is outside the scope of phase-002 (test discovery) and was not touched.
A parser phase should own it. Evidence: `modules/MathUtils.rb` first line.

## Out of scope

`src/testing/harness.rs:48` prints a skip line for `// skip` regardless of
where it appears, and the harness's `test_name` keeps the surrounding quotes
(`"this must fail"` rather than `this must fail`). Both are pre-existing
presentation quirks; `tests/discovery_test.rs` documents the quoted form
rather than changing it.