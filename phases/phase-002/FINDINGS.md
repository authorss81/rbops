# phase-002 — FINDINGS

Out-of-scope defects noticed while fixing test discovery. Not fixed here; each
is anchored to a file:line so the auditor can promote it to a real phase.

## 1. Redblue `test "name" … end` blocks are invisible to the harness

`TestHarness::run_source` (src/testing/harness.rs:31) only starts a test on a
line beginning with `// test `, `# test `, `// bench `, `# bench ` or `// skip `.
A `.rb` file written in the language's own syntax:

```redblue
test "adds correctly"
    set result to 2 + 3
    expect result to be 5
end
```

is scanned, never matched, and contributes **zero** tests. `AGENTS.md` section
"Built-in Test Syntax" documents exactly that form as the built-in test syntax,
and the lexer/parser both accept it (tests/suite.rb uses it). The harness and the
documented syntax have diverged; a `.rb` suite of only `test … end` blocks
reports `Tests run: 0`, `Passed: 0`, `Failed: 0` and exits 0 — a green suite
that ran nothing.

Reproduced while writing `edge_malformed_rb_reports_a_failure_and_does_not_panic`:
the first version of that fixture used `test "unterminated"`, and
`run_test_file` returned `failed == 0` with no errors.

Suggested phase: teach `run_source` to recognise `test "<name>" … end` blocks
in addition to the marker comments, with a test that a `.rb` file of only
`test … end` blocks yields `total > 0`.

## 2. Lexer accepts an unterminated string at EOF

`say "oops` (no closing quote, newline, EOF) prints `oops` instead of raising a
lexer error. Observed through `run_test_file` on a fixture containing
`say "oops`: the harness recorded 0 failures.

This is the `malformed_input` row of the testing matrix: an unterminated string
is accepted where an error is expected. Expected location: the string-lexing
loop in src/lexer.rs. Not fixed here — a lexer change in a test-discovery phase
is the "refactor smuggled into a bug-fix phase" blocker.

## 3. `rb test <path>` still exits 0 on failure

`run_test(Some(path))` (src/lib.rs:50-55) prints the PrettyReporter and returns
`Ok(())`; only the no-argument path calls `process::exit(1)` (src/lib.rs:61-63).
So:

```bash
./target/debug/rb test tests/broken.rb; echo $?   # prints "1 failed", exits 0
```

CI cannot detect a failing single-file run. The comment at src/lib.rs:52-53
claims the non-zero exit exists, but it is only wired for the all-files path.

## 4. `run_all_tests()` hardcodes the relative directory `tests/`

`run_all_tests` (src/testing/mod.rs:44) resolves `"tests/"` against the process
cwd. Running `rb test` from any other directory silently collects nothing and
reports `Tests run: 0 / Passed: 0 / Failed: 0` with exit 0 — a green run that
executed nothing. There is no warning when discovery finds zero files.