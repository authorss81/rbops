# phase-048 — READ THIS FIRST. Your gate failure is fixed; the work is correct.

## The third trap (gate regex vs the `label()` dialect), now fixed

Your attempt was correct and complete: the REPORT documents ~10 tests as
"failure asserted", every one naming a spanned `RuntimeError`/`AnalyzerError`
with `label(&e) == "RuntimeError"` style assertions. The gate failed you 3/3 on
`no test asserts a failure is produced` because its regex knew only
`is_err|expect_err|should_panic|eval_err` — and Redblue's `Error` carries a
*label*, not a `Result`, so your tests correctly never call `is_err()`.

`verify.sh` now also accepts the label dialect (`label(...)` beside a spelled-out
`Error::` variant), with smoke cover proving the dialect passes AND a label
named only in prose still fails. Two prior phases found the same disease, one
layer deeper each time (037: `eval_err`; 048: `label()`).

## What to do on this attempt

1. Resume from `rbops-recovery/phase-048`. Do not rewrite. The diff is right.
2. Run the four gates. The gate should now pass on the resumed tree.
3. Then review and land normally. If the gate still fails you, quote its exact
   line in REPORT.md — do not change the tests to satisfy a detector.

`must_touch` is `["src/", "docs/"]` (already fixed last attempt) and the
`of <Type>` decision is settled: SPEC.md corrected, the feature deferred to
**phase-089**. Do not implement it here.