# phase-001 FINDINGS

Phase-001's own work is green. These are things it found that do not belong to
it. Each one is anchored to a line I read.

## 1. BLOCKER (pipeline, not language): `rbops/verify.sh` cannot find its own inputs

`rbops/verify.sh`:

```
17:  PHASES="${RBOPS_PHASES:-rbops/phases.json}"
24:  BASELINE="${RBOPS_BASELINE:-rbops/baseline.json}"
27:  cd "$REPO" || exit 1
```

Both defaults are relative and are read *after* the `cd`. `.github/workflows/rbops.yml:160`
sets `RBOPS_REPO=$PWD/redblue`, and no step ever copies `rbops/` into the
cloned `redblue/`, so both resolve to paths that do not exist.

Observed, running the gate exactly as CI does:

```
$ RBOPS_REPO=$PWD/redblue ./rbops/verify.sh phase-001
  FAIL phase phase-001 is NOT declared in rbops/phases.json — an undeclared phase cannot pass
  FAIL example fails: modules/MathUtils.rb — Error: ParserError: Expected function name
  VERIFY FAIL — 2 check(s) failed
```

Every phase will fail this way, including one that changes nothing. The second
failure is collateral: the baseline lookup misses, so a baselined pre-existing
failure is promoted to `example fails` (contrast `rbops/verify.sh:145-160`,
which is written to WARN in exactly that case).

Confirmed by pointing the two vars `verify.sh` already supports at the real
files — then it passes:

```
$ RBOPS_REPO=$PWD/redblue RBOPS_PHASES=$PWD/rbops/phases.json \
  RBOPS_BASELINE=$PWD/rbops/baseline.json ./rbops/verify.sh phase-001
  ...
  WARN pre-existing failure, baselined, not touched by this phase: modules/MathUtils.rb
  VERIFY PASS — phase-001
```

Suggested fix, one line each: make the defaults absolute
(`"$(dirname "${BASH_SOURCE[0]}")/phases.json"`), or resolve them before the
`cd`, or export `RBOPS_PHASES`/`RBOPS_BASELINE` in the workflow's Clone step
next to `RBOPS_REPO`. A phase agent cannot apply any of these (hard rule 1), and
creating `redblue/rbops/phases.json` to satisfy the relative path trips
`forbidden path touched: rbops/*` at `rbops/verify.sh:96`. This needs a human or
a workflow change.

## 2. `modules/MathUtils.rb` does not parse

Already baselined (`rbops/baseline.json`, `phase-024`):
`ParserError: Expected function name`. The file uses `constant PI to 3.14159`
and `constant` is not in the keyword table in `src/lexer.rs:225-266`. Not
touched by phase-001. Same finding, restated so the baselining is visible.

## 3. Out-of-range list index returns a value instead of raising

`src/vm.rs` `Expr::Index` handling: index `999` on `[1, 2, 3]` yields
`Value::Nothing`, and index `-1` yields `Number(3.0)` — it wraps to the last
element. Both are silent wrong answers; `AGENTS.md` §3.2 and
`phases/INVARIANTS.md:61-64` require a clean error, never a silent success.
phase-001 only asserts the current, non-panicking behaviour
(`edge_out_of_bounds_index_fails_the_test_cleanly`, index 999) and deliberately
does **not** lock in the `-1` wrap. A VM phase should make both raise.

## 4. Numbers are `f64`, so integers past 2^53 silently compare equal

`expect 9007199254740992 to be 9007199254740993` passes: both literals round to
the same `f64` and `Value` derives `PartialEq` (`src/value.rs:4`). No test locks
this in — phase-001's `edge_numeric_boundaries` stops at 10^15. Either the
specification has to state that Redblue numbers are IEEE doubles with 53-bit
mantissas, or integers need their own representation.

## 5. `src/testing/assertions.rs` still has traps in its unused half

Now that the module is live, the remaining unreferenced functions are worth
auditing before phase-003 builds a suite on them:

- `src/testing/assertions.rs:101-114` `AssertThat::contains` is **inverted** —
  it returns `Err` when the value *is* equal to the item and `Ok` otherwise.
- `src/testing/assertions.rs:82-99` `is_none` and `is_some` always return
  `Err`, on any input.
- `assert_value_is_number` / `_text` / `_list` / `_yes_no` / `_record`,
  `assert_list_length`, `assert_text_matches`, `assert_number_in_range`,
  `assert_throws`: no callers.
- `src/testing/runner.rs:132-315` is a second, unrelated assertion library
  (`assert_eq`, `assert_contains`, `assert_panics`, …) also with no callers, and
  its own `TestAssertionError` distinct from the one in `assertions.rs`. Two
  `TestAssertionError` types with the same name in one module tree is a trap for
  the next phase. Consolidating them is a decision for whoever writes the suite.

`assert_throws` and `assert_panics` both use `catch_unwind`, which is the wrong
tool here: nothing in `Lexer → Parser → Analyzer → VM` panics by design, so they
can only ever pass vacuously.

## 6. `run_all_tests` feeds Rust source to the Redblue parser

`src/testing/mod.rs:29` accepts both `_test.rs` and `.rb`, and
`src/testing/mod.rs:48` collects both extensions, so `tests/redblue_test.rs` is
lexed as Redblue. That is phase-002's finding. One consequence is new in
phase-001: now that `run_source` parses the file in order to find `test … end`
blocks, `rb test` reports a parse error for `tests/redblue_test.rs` where it
previously reported nothing. No gate runs `rb test`, so nothing regressed in the
build, but phase-002 should expect this extra error line.

## 7. `expect` nested in an expression is not an assertion

`expect` inside another expression (`set x to expect 1 to be 2`) is evaluated by
`src/vm.rs`, not by the harness, so it surfaces as a `RuntimeError` rather than
an assertion failure with expected/actual. Only statement-level `expect` — the
form in `phases/INVARIANTS.md:24` — goes through `testing::assertions`. Worth
deciding whether nested `expect` should be a parse error.