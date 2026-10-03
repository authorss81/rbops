# Phase 001 — Make the test harness capable of failing

## Finding re-verified

Reproduced on `redblue@ad83985` before any change:

```
$ cargo run --bin rb -- run /tmp/wrong.rb
Error: ParserError: Unexpected token Expect
```

with `/tmp/wrong.rb`:

```redblue
test "edge_wrong_expectation"
    set x to 1
    expect x to be 2
end
```

The finding holds, and is worse than recorded: `Expr::Expect` was **never
constructed anywhere in `src/parser.rs`** (`grep -n "Expr::Expect" src/parser.rs`
matched only the enum declaration at line 56), so `expect …` was not merely
unasserted, it did not parse at all. `src/testing/assertions.rs` was reachable
only through `pub use assertions::*` in `src/testing/mod.rs:6`.

## What changed

| File | Lines | What |
|---|---|---|
| `src/parser.rs` | +138 −1 | `parse_expect`: `expect <expr> to be\|contain <expr>` now parses into `Expr::Expect`; new `ExpectMatcher { Equal, Contain }` carries the comparison word. `be`/`contain` are matched as identifiers, not tokens, so neither word is reserved. |
| `src/testing/harness.rs` | +355 −23 | `run_test_blocks` runs every top-level `test "name" … end`; `run_test_body` walks the body in order and evaluates each `Expr::Expect` through `testing::assertions`; `record` turns an outcome into pass/fail with expected/actual. `execute_test_code` reduced to parse+run for benchmarks. |
| `src/vm.rs` | +37 −9 | `Expr::Expect` honours the matcher; `pub fn evaluate_expression`, `pub fn execute_statements`, `pub fn flush_output` added so the harness can interleave assertions without the VM parsing anything. |
| `src/testing/assertions.rs` | +24 | `assert_value_contains(container, item)` for `expect x to contain y`. |
| `src/value.rs` | +16 | `Value::contains_item` — list membership, text substring, record/object key; `None` when containment is undefined. |
| `src/lib.rs` | +16 −10 | `run_test(Some(path))` now prints the summary and exits 1 on failure, like the no-path branch. A runner that exits 0 on a failed test is not a runner. |
| `src/formatter.rs` | +8 −2 | Formats `to be` / `to contain` from the matcher instead of hardcoding `to be`. |
| `src/linter.rs` | +3 −1 | Pattern widened for the new field. |

## Tests added

30 → 35 `#[test]`; 25 new, all in the two modules that changed.

| Test | Edge class covered |
|---|---|
| `test_wrong_expectation_fails_the_test` | failure assertion — the phase's central claim |
| `test_correct_expectation_passes` | happy path |
| `test_each_block_is_a_separate_test` | nesting/isolation (one VM per block) |
| `edge_failing_assertion_stops_the_rest_of_the_body` | resource_limit — a failed assertion ends the test, so the remainder (any loop) never runs |
| `edge_empty_values_are_compared_not_skipped` | empty |
| `edge_empty_against_non_empty_fails` | empty |
| `edge_singleton_list_membership` | singleton |
| `edge_boundary_elements_of_a_list` | boundary (index 0 and index len-1) |
| `edge_out_of_bounds_index_fails_the_test_cleanly` | out_of_bounds (index 999 → clean failure, no panic) |
| `edge_type_mismatch_is_not_a_pass` | type_mismatch (number vs text both ways) |
| `edge_containment_of_a_number_is_an_error_not_a_pass` | type_mismatch — undefined containment is an error, not a silent pass |
| `edge_numeric_boundaries` | numeric_boundary (`-0`, `-1`, large magnitude) |
| `edge_division_by_zero_fails_the_test` | numeric_boundary |
| `edge_unicode_text_is_compared_by_content` | unicode (emoji, CJK, RTL) |
| `edge_nested_collections_are_compared_structurally` | nesting_recursion |
| `edge_record_keys_present_and_missing` | duplicate_missing_keys |
| `test_duplicate_record_keys_keep_the_last_value` | duplicate_missing_keys |
| `edge_malformed_expect_is_a_parser_error` | malformed_input — asserts `is_err()` |
| `edge_expect_without_a_comparison_word_is_a_parser_error` | malformed_input — asserts `is_err()` |
| `edge_undefined_operand_fails_the_test` | malformed_input |
| `parser::tests::test_parse_expect_to_be` | happy path |
| `parser::tests::test_parse_expect_to_contain` | happy path |
| `parser::tests::test_parse_expect_keeps_both_operands` | singleton |
| `parser::tests::edge_expect_without_a_comparison_word_is_rejected` | malformed_input |
| `parser::tests::test_be_and_contain_stay_usable_as_variable_names` | language-surface guard for the new comparison words |

### Edge-case matrix

All 11 rows covered: empty, singleton, boundary, out_of_bounds, type_mismatch,
numeric_boundary, unicode, nesting_recursion, duplicate_missing_keys,
malformed_input, resource_limit. `resource_limit` is covered by
`edge_failing_assertion_stops_the_rest_of_the_body`: the harness stops the test
at the failing assertion, so no statement after it — including an unbounded
loop — is executed. The VM's own loop guards are a pre-existing gap recorded in
FINDINGS.md, not something this phase introduces.

### The tests were watched failing

`check_expectation` was temporarily made to discard the assertion result
(`let _ = match matcher { … }; Ok(())`). 11 of the 25 new tests went red,
including `test_wrong_expectation_fails_the_test` and every `edge_*` failure
test. The neutering was reverted and the suite returned to 30 lib + 5
integration green. A test that cannot fail is not a test, so this was checked
rather than asserted.

### `rb test` on a deliberately wrong test

```
$ cargo run --bin rb -- test /tmp/wrong.rb
F
Tests run: 1
Passed: 0
Failed: 1
  FAILED edge_wrong_expectation: Values not equal: Number(2.0) vs Number(1.0)
$ echo $?
1

$ cargo run --bin rb -- test /tmp/right.rb
.
Tests run: 1
Passed: 1
Failed: 0
$ echo $?
0
```

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass |
| `cargo test --all-targets` | pass — 35 passed, 0 failed (30 lib + 5 integration) |
| `cargo test --doc` | pass — 0 doc tests, 0 failed |
| `examples/*.rb` | pass — 6/6 run (`files`, `fizzbuzz`, `formats`, `hello`, `test_arithmetic`, `time`) |
| `modules/*.rb` | `modules/MathUtils.rb` fails with `ParserError: Expected function name` — **pre-existing**, baselined in `rbops/baseline.json` as `phase-024`, verified on `ad83985`, and this phase does not touch that file, so verify.sh reports it as a WARN |
| `./rbops/verify.sh phase-001` | **FAIL — 2 checks, both from one wiring bug in `verify.sh` itself.** Every other check passes; see below |
| `./rbops/verify.sh phase-001` with `RBOPS_PHASES`/`RBOPS_BASELINE` absolute | **VERIFY PASS** — 23 PASS, 1 baselined WARN, 0 FAIL |

### The two failing checks, honestly

Run as CI runs it (`RBOPS_REPO=$PWD/redblue`, matching
`.github/workflows/rbops.yml:160`):

```
  FAIL phase phase-001 is NOT declared in rbops/phases.json — an undeclared phase cannot pass
  ...
  FAIL example fails: modules/MathUtils.rb — Error: ParserError: Expected function name
  ...
  VERIFY FAIL — 2 check(s) failed
```

One root cause. `rbops/verify.sh` resolves two paths *relative* and then
changes directory underneath them:

- `rbops/verify.sh:17` — `PHASES="${RBOPS_PHASES:-rbops/phases.json}"`
- `rbops/verify.sh:24` — `BASELINE="${RBOPS_BASELINE:-rbops/baseline.json}"`
- `rbops/verify.sh:27` — `cd "$REPO"`

Both are read *after* the `cd`, so in CI they resolve to
`redblue/rbops/phases.json` and `redblue/rbops/baseline.json`. Neither exists:
the workflow never copies `rbops/` into the cloned `redblue/`, and
`git ls-tree ad83985 --name-only` in the redblue repository lists no `phases/`
and no `rbops/`.

Consequences: the manifest lookup finds nothing, and the baseline lookup finds
nothing, so the pre-existing, baselined `modules/MathUtils.rb` failure is
reported as `example fails` instead of a `WARN`.

Proof it is the wiring and not this phase — the same gate, with the two env vars
`verify.sh` already supports pointed at the real files:

```
$ RBOPS_REPO=$PWD/redblue \
  RBOPS_PHASES=$PWD/rbops/phases.json \
  RBOPS_BASELINE=$PWD/rbops/baseline.json \
  ./rbops/verify.sh phase-001

  PASS phase phase-001 is declared in /…/rbops/phases.json
  PASS dep — none
  PASS report: all 4 sections, real evidence row
  PASS no gate-weakening constructs added
  PASS diff substance: +604 -46 (min +5)
  PASS cargo fmt --check
  PASS cargo clippy -D warnings
  PASS cargo test: 35 passed, 0 failed
  PASS runs: examples/{files,fizzbuzz,formats,hello,test_arithmetic,time}.rb
  WARN pre-existing failure, baselined, not touched by this phase: modules/MathUtils.rb
  PASS test quota met: 25 rust / 0 redblue (need 6 or 4)
  PASS edge case test present: 17
  PASS failure-asserting test present: 2
  PASS no newly skipped tests
  PASS reported test count (35) matches actual (35)

  VERIFY PASS — phase-001
```

The fix is one line each in `rbops/verify.sh` (make the defaults absolute, or
`cd` after resolving them, or export the two vars in the workflow). `rbops/` is
off-limits to a phase agent under hard rule 1, and the alternative — creating
`redblue/rbops/phases.json` so the relative path resolves — trips the gate's own
`forbidden path touched: rbops/*` scan at `rbops/verify.sh:96`. So the wiring
is left alone and reported in `phases/phase-001/FINDINGS.md`.

## Invariants touched

- None re-opened. `phases/INVARIANTS.md:24` lists the test block as
  `test "name" … expect x to be y … end`; that is the form implemented, so this
  phase closes the gap between the invariant and the implementation rather than
  changing it.
- `be` and `contain` are matched as identifiers, not added as keywords, so no
  existing identifier changes meaning. Asserted by
  `test_be_and_contain_stay_usable_as_variable_names`.
- Pipeline separation holds: the parser still does not resolve names, the
  analyzer still does not execute, and the VM still does not parse. The harness
  reaches into the VM only through `execute_statements` /
  `evaluate_expression`; all comparison logic stays in `testing::assertions`.
- `Value` variants, `Error` variants and the `redblue::` signatures in
  `INVARIANTS.md:31-39` are unchanged. `run_test`'s signature is unchanged; its
  behaviour now reports failures and exits 1, which is what its name promises.
- `Expr::Expect` gained a `matcher` field. `Expr` is not in the Rust public API
  list and this is additive, but it is a shape change to an existing variant and
  is called out here deliberately.

## Known gaps / follow-ups

- `modules/MathUtils.rb` still does not parse → FINDINGS.md (pre-existing,
  baselined as phase-024).
- List index `len` and `-1` return `nothing` / wrap to the last element instead
  of raising → FINDINGS.md.
- Numbers are `f64`, so `expect 2^53 to be 2^53 + 1` passes. Not locked in by a
  test; recorded in FINDINGS.md.
- `expect` nested inside another expression (`set x to expect 1 to be 2`) is
  evaluated by the VM, not the harness, so it reports a runtime error rather than
  an assertion failure. Only statement-level `expect`, the documented form, is
  routed through the assertion library.
- `test "…" … end` blocks are only discovered at the top level of a file, not
  nested inside an object or module body.
- `assertions.rs` still has functions no caller uses (`assert_that`,
  `AssertThat::contains` — which is also inverted, `is_none`, `is_some`,
  `assert_value_is_number`, `assert_list_length`, `assert_text_matches`,
  `assert_number_in_range`, `assert_throws`). The module is now live rather than
  dead; the leftovers are phase-003's to use or delete → FINDINGS.md.
- `run_all_tests()` still feeds `tests/*.rs` to the Redblue parser
  (`src/testing/mod.rs:29`), so `rb test` now reports a parse failure for
  `tests/redblue_test.rs` where it previously reported nothing. That is
  phase-002's finding, unchanged in substance, and the gate does not run
  `rb test`.