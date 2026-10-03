# Phase 001 — FINDINGS

Out-of-scope defects found while making the harness capable of failing. Each has
file:line evidence and is a candidate for the auditor to promote to a phase. None
was fixed in phase-001 (AGENTS.md §1 rule 7: one phase, one concern).

---

## 1. Stale claim in the phase evidence — `rb test` does NOT report 0 tests

The phase evidence said:

> `rb test` reports 0 tests because every .rb file in tests/ is 100% commented out
> and discovery only matches lines starting `// test `.

This does **not** reproduce:

```
$ ./target/debug/rb test
.....................SKIP: // skip "Awaiting full test harness implementation"
Tests run: 22
Passed: 21
Failed: 0
```

22 tests are discovered. The second half of the claim is the real defect and it is
much worse than "0 tests": the marker convention means **every discovered test body
is empty**, so all 21 "passes" are vacuous.

`src/testing/harness.rs:65` `run_single_test` collects body lines between
`// test "..."` and `// end`, then passes them to `Lexer::tokenize`. In
`tests/integration_test.rb`, `tests/suite.rb` and `tests/test_arithmetic.rb` those
body lines are themselves `//`-prefixed, so the lexer reads the whole body as a
comment and the "test" runs an empty program. `tests/integration_test.rb:26` even
carries `// skip "Awaiting full test harness implementation"`, which is an
admission that the layer was never finished.

**Evidence that the layer is now capable of failing but the suite is not using it:**
the same files run unchanged after this phase and still report 21 vacuous passes,
while a `.rb` file with real body lines fails correctly.

**Suggested phase:** give `tests/*.rb` real `// test` bodies (un-prefixed code
lines) that use `expect`, and make a discovered test with zero assertions a
failure rather than a pass. The second half is a semantics change to the harness
and was deliberately not smuggled into this phase.

---

## 2. A discovered test with no assertions passes

`src/testing/harness.rs:80` — `run_single_test` calls `execute_test_code` and any
non-error is `add_pass()`. An empty or assertion-free body trivially succeeds.

Documented rather than hidden by `edge_an_empty_test_body_still_passes` in
`tests/expect_test.rs`.

---

## 3. The `// test` scanner cannot reach `expect` inside a block

`src/testing/harness.rs:71`

```rust
if line.trim().starts_with("// end") || line.trim() == "end" {
    break;
}
```

A body line that trims to `end` — the terminator of every `if`/`for`/`while`/
`to` block — terminates test discovery. So an `expect` inside a block is
unreachable through the scanner. It is reachable through `redblue::run_source`,
which is how `expect_inside_a_control_flow_block` and
`edge_a_loop_evaluates_every_expect` test it.

**Suggested phase:** discover tests by parsing the file (the grammar already has
`Statement::Test` at `parser.rs:190`) instead of scanning lines, which also
removes finding 1's comment-prefix coupling.

---

## 4. `rb test` (all-files mode) never prints failure messages

`src/lib.rs` `run_test`, the `None` arm prints only `total`/`passed`/`failed`
and exits 1. It never calls a `Reporter`, so an `expect` failure's
`expected`/`actual` are invisible. `src/testing/reporter.rs:62`
`PrettyReporter::report` already prints both and exits 1 — it was simply not
called. phase-001 wired the `Some(path)` arm only, to keep the diff on-topic.

---

## 5. `modules/MathUtils.rb` does not parse on `main` (pre-existing)

```
$ git stash && cargo build && ./target/debug/rb run modules/MathUtils.rb
Error: ParserError: Expected function name
```

The file opens with `constant PI to 3.14159` (`modules/MathUtils.rb:3`). There is
no `constant` keyword in `src/lexer.rs` `keyword()` (`lexer.rs:217`), so `constant`
lexes as an identifier and the statement is misparsed. No example imports
`MathUtils`, so the other 6 example/module files still pass.

This is a **backwards-compatibility break against AGENTS.md §2** — `modules/*.rb`
is specified as the language's specification-by-example — so it needs its own
phase, not a drive-by fix here.

---

## 6. Out-of-bounds list index returns `nothing` instead of raising

`src/vm.rs:384`

```rust
Ok(items.get(i as usize).cloned().unwrap_or(Value::Nothing))
```

`[1][5]` and `[1][-9]` yield `nothing` silently. AGENTS.md §3.2 requires
out-of-bounds to be "a clean runtime error, never a panic, never UB"; it is not a
panic, but it is also not an error. `src/vm.rs:367` does the same for a missing
record field.

Left as-is deliberately: changing it to an error would flip the behaviour that
`expect x[99] to be nothing` currently asserts, which is outside this phase's
concern.

---

## 7. The lexer accepts an unterminated string

```
$ printf 'set x to "abc\n' > q.rb && ./target/debug/rb run q.rb
   (no output, exit 0)
```

An unterminated string literal is silently accepted to end of line instead of
raising `LexerError`, so a typo'd expectation can pass vacuously. This is why
phase-001 asserts `ParserError` for malformed `expect` forms and does **not**
assert anything about unterminated strings.

---

## 8. `expect` compares floats exactly, with no tolerance

`src/testing/assertions.rs:117` `assert_values_equal` uses `PartialEq` on
`Value::Number(f64)`, so `expect 0.1 + 0.2 to be 0.3` fails. Asserted as current
behaviour by `edge_numeric_boundaries_compare_exactly`.

Deliberately not changed: whether to add a tolerance, and what the default should
be, is a language-design decision requiring its own phase. Until then the strict
behaviour is safer (it cannot mask a real regression).