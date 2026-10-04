# FINDINGS — phase-002

Out-of-scope defects observed while fixing test discovery. Each is anchored to a
line I read. Not actioned in this phase (hard rule 7: one phase, one concern).

## F1 — All `.rb` tests in `tests/` have empty bodies; `rb test` reports vacuous passes

`rb test` reports `Tests run: 22 / Passed: 21 / Failed: 0`. Every one of those 21
bodies is a comment. Examples:

- `tests/suite.rb:8` — `// test "Lexer: Numbers"` is followed only by `//` lines.
- `tests/test_arithmetic.rb:3` — `// test "Basic addition"` body is all `//`.
- `tests/integration_test.rb:3` — same.

The scanner at `src/testing/harness.rs:31` collects the lines between
`// test "name"` and `// end`; every such span is empty, so
`src/testing/harness.rs:147` lexes an empty program and records a pass. This is
the largest remaining source of tests that cannot fail. → needs a phase that
writes real bodies using `expect … to be …`.

## F2 — Harness does not implement the documented `test "name" … end` syntax

`AGENTS.md` ("Built-in Test Syntax") and the test-harness docs specify

```redblue
test "my test"
    set result to 2 + 3
    expect result to be 5
end
```

but `src/testing/harness.rs:31` only recognises `// test `, `# test `, `// bench `
and `// skip`. `src/lexer.rs:263` does tokenize the word `test`
(`TokenKind::Test`), so the lexer already has the keyword. The `.rb` suite
therefore cannot be written in the documented style. → needs a phase to add
block-marker discovery to `TestHarness::run_source`.

## F3 — Lexer accepts an unterminated string literal at EOF

```
$ printf 'say "open\n' > target/tmp/p2.rb && ./target/debug/rb target/tmp/p2.rb
open
```

Exit 0. `src/lexer.rs` string scanning does not report an unterminated literal
when the input ends; per `AGENTS.md` §3.2 "malformed input" this should be a
lexer error with a span. I dropped this case from
`tests/harness_discovery_test.rs` for that reason and used a parse error
(`set x to`) instead.

## F4 — `modules/MathUtils.rb` does not parse

```
$ ./target/debug/rb run modules/MathUtils.rb
Error: ParserError: Expected function name
  --> modules/MathUtils.rb:4:16
4 | constant PI to 3.14159
```

Verified pre-existing: reproduced with my diff stashed
(`git stash -u` → rebuild → same error). `AGENTS.md` §2 says `modules/*.rb` is
specification-by-example and the gate runs it. The parser has no `constant`
declaration form. → needs its own phase.

## F5 — `find_test_files` returns `Result` but cannot fail

`src/testing/mod.rs:57` returns `Result<Vec<String>>` while every failure path is
swallowed (`if let Ok(entries) = std::fs::read_dir(dir)`), so the `?` on the
recursive call at `src/testing/mod.rs:64` can never trigger. Harmless today;
noted so a future change does not read it as "errors are propagated".
