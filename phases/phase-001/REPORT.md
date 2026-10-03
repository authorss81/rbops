# Phase 001 — Make the test harness capable of failing

## Reproduction (before any change)

```
$ printf 'set result to 2 + 3\nexpect result to be 5\n' > /tmp/opencode/repro.rb
$ ./target/debug/rb run /tmp/opencode/repro.rb
Error: ParserError: Unexpected token Expect
EXIT=1
```

The finding re-verified on `main` for its central claim: `Expr::Expect` is declared
at `src/parser.rs:56` and there was **no construction site anywhere in `parser.rs`**.
`grep -rn "Expr::Expect" src/` on the pre-change tree matched only the enum
declaration, the `analyzer.rs:266` no-op arm, and the `vm.rs:410` evaluation arm.

**One part of the finding was stale and is recorded below rather than "fixed":**
`rb test` does *not* report 0 tests. It reports `Tests run: 22, Passed: 21,
Failed: 0`. See FINDINGS.md.

## What changed

| File | Lines | What |
|---|---|---|
| `src/parser.rs` | +27 | `TokenKind::Expect => self.parse_expect()?` in `parse_statement`; new `parse_expect()` builds `Expr::Expect` for `expect A to be B` (and `expect A to B`) |
| `src/vm.rs` | +23 −12 | `Expr::Expect` arm now delegates to `testing::assertions::assert_values_equal` and records the structured failure in a new private `expectation_failure` field; new `pub fn take_expectation_failure()` |
| `src/testing/assertions.rs` | +1 | `#[derive(Clone)]` on `TestAssertionError` so the VM can clone it before rendering the message |
| `src/testing/mod.rs` | +18 | new `TestFailure` enum distinguishing `Assertion` from `Error` |
| `src/testing/harness.rs` | +40 −12 | `execute_test_code` returns `Result<(), TestFailure>` and takes the structured `TestAssertionError` off the VM; `run_single_test` records `message`/`expected`/`actual` for assertion failures |
| `src/lib.rs` | +8 −2 | `run_test(Some(path))` now calls `PrettyReporter::report`, which prints Expected/Actual and exits 1 |
| `tests/expect_test.rs` | +379 | 21 new tests (new file) |

No existing test was modified, weakened, deleted, ignored, or skipped.
No `allow(clippy::` suppression was added.

## Proof the harness can now fail (both directions, end to end)

```
$ printf '// test "deliberately wrong"\nexpect 1 to be 2\n// end\n\n// test "deliberately right"\nexpect 1 to be 1\n// end\n' > wrong_suite.rb
$ ./target/debug/rb test wrong_suite.rb
F.
Test Results: 2 total, 1 passed, 1 failed, 0 skipped (50.0% success)
Failures:
============================================================
1. "deliberately wrong": FAILED
  Location: inline:2
  Error: Values not equal: Number(2.0) vs Number(1.0)
  Expected: Number(2.0)
  Actual: Number(1.0)
EXIT=1
```

```
$ ./target/debug/rb run wrong.rb   # expect 1 to be 2
Error: RuntimeError: Values not equal: Number(2.0) vs Number(1.0)   # exit 1
$ ./target/debug/rb run right.rb   # expect 1 to be 1
                                                               # exit 0
```

## Tests added

21 new `#[test]` functions in `tests/expect_test.rs`. Quota: ≥6 required, 21 delivered.
18 are named `edge_*`; 0 skipped/ignored.

| Test | Edge class covered |
|---|---|
| `expect_mismatch_fails_the_test` | asserts a **failure**: `failed == 1`, message names both values, `expected == Some("Number(2.0)")`, `actual == Some("Number(1.0)")` |
| `expect_match_passes_the_test` | happy path, other direction |
| `expect_matches_a_computed_expression` | actual side is computed, not a literal |
| `expect_tolerates_omitting_be` | `expect A to B` accepted as well as `expect A to be B` |
| `edge_empty_values_compare_equal_to_themselves` | empty: `nothing`, `""`, `[]`, `{}`, `0` |
| `edge_empty_text_is_not_the_same_as_nothing` | empty + type: `""` != `nothing`, `[]` != `nothing` |
| `edge_singleton_list_compares_elementwise` | singleton; also length-only differences `[1]` vs `[]`, `[1]` vs `[1,1]` |
| `edge_index_boundaries_feed_the_actual_value` | boundary: index `0`, index `len-1`, index `-1` |
| `edge_type_mismatch_fails` | type mismatch: number↔text, yes/no↔number, list↔number, record↔number, `nothing`↔number — each must fail *and* record both values |
| `edge_numeric_boundaries_compare_exactly` | numeric boundary: `-0.0 == 0`, and `0.1 + 0.2` vs `0.3` genuinely **fails** (no silent float tolerance) |
| `edge_division_by_zero_is_a_runtime_error_not_an_assertion` | resource/numeric: `1 / 0` yields a clean `Division by zero` runtime error with `expected`/`actual` left `None`, proving a runtime fault is not reported as a value mismatch |
| `edge_unicode_compares_by_whole_string` | unicode: `héllo`, `日本語`, emoji, RTL `שלום`, precomposed accent; mismatches fail |
| `edge_escapes_are_compared_literally` | unicode/escapes: `\n`, escaped quotes; and the fact that Redblue has no `\u{...}` escape (it is a literal) |
| `edge_normalisation_is_not_applied_to_text_comparison` | unicode: U+00E9 (NFC) != U+0065 U+0301 (NFD) |
| `edge_nested_containers_compare_structurally` | nesting: 3-deep nested lists, list-of-record, `[[1]]` vs `[1]` |
| `expect_inside_a_control_flow_block` | nesting: `expect` inside a taken `if` branch fails and names both values; a skipped branch does not evaluate it |
| `edge_a_loop_evaluates_every_expect` | resource/looping: first mismatching iteration of `for each` fails |
| `edge_missing_record_key_differs_from_present_key` | duplicate/missing keys: `{a:1}` != `{a:1,b:2}` both directions |
| `edge_malformed_expect_is_a_parse_error` | malformed input: `expect`, `expect 1 to`, `expect 1 to be`, `expect to be 1` all rejected as `ParserError` with `expected == None` |
| `edge_an_empty_test_body_still_passes` | documents the known vacuous-pass gap (see FINDINGS.md), does not hide it |
| `edge_expect_results_are_deterministic_across_runs` | determinism: 5 runs produce byte-identical failure messages |

Two of my initial assumptions were **wrong** and the tests caught them, which is
why they are worth keeping: I asserted two visually identical emoji would differ
(the file literally contained the same bytes twice) and that a raw combining mark
inside a string would be a lexer error (it is accepted). Both assertions were
rewritten to the behaviour actually verified against `rb run`.

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass, 0 warnings |
| `cargo test --all-targets` | pass — 31 passed, 0 failed, 0 ignored (5 lib + 21 expect_test + 5 redblue_test) |
| `./rbops/verify.sh phase-001` | **NOT RUN — `rbops/` does not exist in this checkout** (see below) |

### Gate 4 could not be executed

```
$ ls -la rbops
ls: cannot access 'rbops': No such file or directory
```

The RBOPS pipeline lives outside this checkout and I was instructed not to inspect
it, so `./rbops/verify.sh phase-001` is unrunnable here. In its place I ran the
project-specific gate described in AGENTS.md §2 (backwards compatibility with
`examples/*.rb` and `modules/*.rb`), which I could verify by hand:

```
$ for f in examples/*.rb modules/*.rb; do ./target/debug/rb run "$f"; done
FAIL modules/MathUtils.rb
FAILS=1 of 7
```

**`modules/MathUtils.rb` fails identically on unmodified `main`** — verified by
`git stash`ing my changes, rebuilding, and re-running: `Error: ParserError:
Expected function name`. It is a pre-existing defect, not a regression from this
phase, and it is recorded in FINDINGS.md per AGENTS.md §1 rule 7. The other 6
files pass both before and after. No example imports `MathUtils`, so nothing
else depends on it.

## Invariants touched

- **None.** No change to: `.rb` extension, `to … end` / `if … end` / `for … end`
  bracketing, `set x to <expr>`, `say`, the `Value` variant list
  (`value.rs:5`), or the `Error` variant list (`error.rs:4`).
- `Expr::Expect` was already a declared variant with a VM evaluation arm; this
  phase only supplies the missing parser construction site. The variant was
  unreachable before and is reachable now.
- The lexer was **not** modified. `be` is not a reserved keyword: `parse_expect`
  consumes a bare `Identifier("be")` only in expect position, so `set be to 1`
  still works. No existing program changes meaning.
- `assertions.rs` was already public (`pub use assertions::*` at
  `testing/mod.rs:6`) and its comparison functions were dead code. They are now
  the single source of truth for the equality `expect` uses.

## Known gaps / follow-ups

Recorded in `FINDINGS.md` rather than fixed here, per AGENTS.md §1 rule 7:

1. A discovered test with **no assertion still passes** (`edge_an_empty_test_body_still_passes`).
2. The harness's `// test` scanner **stops at the first line trimming to `end`**,
   so `expect` inside a block cannot be reached through that scanner — only via
   `run_source`.
3. `rb test` (all-files mode) prints counts but not the failure messages.
4. `modules/MathUtils.rb` does not parse on `main`.
5. Out-of-bounds list indexing returns `nothing` rather than raising a clean error.
6. The lexer accepts an unterminated string at end of line without an error.
7. `TestAssertionError` has no `Display` for `expected`/`actual` beyond the
   existing single-line `message`; the multi-value detail only survives through
   the `TestError` fields and the reporter.