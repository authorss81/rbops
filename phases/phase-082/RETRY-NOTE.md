# RETRY-NOTE — phase-082

**This outranks your generated PROMPT.md.** The previous attempt produced good,
thorough work and **failed the gate for one reason: it wrote no tests.**

## What the gate actually said

```
PASS cargo test: 1555 passed, 0 failed
FAIL no test asserts a failure is produced - mandatory
FAIL test quota not met: 0 rust (need 3) and 0 redblue (need 2) - see AGENTS.md 3.3
FAIL no test named edge_* - mandatory
```

Read that again. **Everything else passed.** 1,555 tests green, fmt clean, clippy
clean, diff substantial. The implementation is sound. The gate did not reject
your change — it rejected the *absence of verification*, which is mandatory
(`AGENTS.md` §3.3) and is a floor, not a target.

## Your work is preserved and it is good

`REPORT.md` from the last attempt is thorough and correct. It re-measured all
five claims against `main` first and found **three had already been fixed by an
earlier phase** and **two were still true** (`HANDOUT.md:150` `formats.parse_json`
with single quotes, `HANDOUT.md:157` `list.filter`, `README.md:274` listing a
nonexistent `src/vm.rs`, `README.md:316` self-hosting still "in progress").

**Keep that analysis. Reuse it. Do not redo it.**

## What to do this time

Your change corrects documentation and tests that state falsehoods. So the
tests you need are the ones that **pin each corrected claim**, and they are the
natural thing to have written anyway:

| Claim corrected | Test that pins it |
|---|---|
| `README.md` lists `src/vm.rs` (nonexistent) | read the file's own source-tree block, assert every path it names exists on disk — and name the missing one in the failure |
| `HANDOUT.md` shows `formats.parse_json` | assert that exact snippet is **not** presented as runnable, or that it is fixed to real syntax |
| `README.md` marks self-hosting "in progress" | assert the claim matches reality — `bootstrap/compiler.rb` exists and `tests/bootstrap_selfhost_test.rs` has the byte-identical self-compilation test |
| `known_gaps()` in `stdlib_module_docs_test.rs` | a test asserting the two remaining gaps (`filter`, `reduce`) are still genuinely unimplemented, so the list cannot silently rot |

### The three mandatory checks, concretely

```rust
// 1. quota: at least 3 new #[test] functions
#[test] fn every_path_named_in_the_readme_exists() { /* ... */ }

// 2. at least one edge_* name
#[test] fn edge_readme_names_a_file_that_was_deleted() { /* ... */ }

// 3. at least one test that ASSERTS A FAILURE IS PRODUCED
#[test] fn a_claim_that_was_wrong_now_reports_the_error() {
    let r = run("set x to formats.parse_json('{...}')");
    assert!(r.is_err());   // this is what satisfies the failure channel
}
```

The failure-asserting test is the one most often missed. It must call something
that **can** fail and assert it does — `assert!(r.is_err())`, or
`#[should_panic]`. A test that only ever succeeds does not satisfy it.

## Budget

The last attempt spent its time re-measuring every claim — which was the right
instinct, and is already done in `REPORT.md`. **Do not redo that.** Go straight
to writing the tests, then the gate.

Roughly: 10 minutes reading `REPORT.md`, 40 writing and running tests, 20
verifying, 10 on `REPORT.md`. You should not need the full budget.

## One more trap

`cargo fmt --all` is **not** the gate command; `cargo fmt --all -- --check` is.
The tree is already fmt-clean, so the bare formatter will produce a reformat of
other phases' files for no reason. Use `--check` only.