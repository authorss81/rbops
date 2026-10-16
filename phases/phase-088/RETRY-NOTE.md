# RETRY-NOTE — phase-088

**This outranks the previous REPORT below.** Four attempts have now failed this
phase for exactly one reason, and it is not the code.

## What the gate says, verbatim

```
PASS test quota met: 8 rust / 0 redblue (need 3 or 2)
PASS edge case test present: 8
FAIL no test asserts a failure is produced - mandatory
     (Rust: is_err()/should_panic; Redblue: try ... catch error)
```

**That is the whole failure.** One check. Everything else is green: 1774 tests
passing, 0 failing, fmt clean, clippy clean.

## Why your previous attempts did not fix it

Your REPORT says "cargo test --all-targets 1774/0/0" and that is **true**. The
mistake is reading that as "the gate passes".

It does not, and it is worth being precise about why. The failing check is not
asking whether your tests are **correct**. It is asking whether any test asserts
that something **fails**. Those are different properties:

- 1774 passing tests prove your code does the right thing when things go right.
- The mandatory check wants proof that your code does the **right thing when
  something goes wrong** — that a bad input produces a clean, catchable error
  rather than a panic, a silent wrong value, or a crash.

A suite can be entirely green and still satisfy nothing here. That is why
attempt after attempt passed 1774 tests and still failed.

## The fix — one test, a few lines

Add ONE test whose subject is a failure. Any of these satisfies it:

```rust
#[test]
fn edge_a_bad_input_is_refused_rather_than_panicking() {
    let r = run_source("set x to list.map(5, to_text)");
    assert!(r.is_err(), "a non-list receiver must be a clean error");
}
```

```rust
#[test]
fn edge_the_vm_and_the_tree_walker_agree_on_a_failure() {
    assert!(run_on_treewalker(BAD_PROGRAM).is_err());
    assert!(run_on_bytecode(BAD_PROGRAM).is_err());
}
```

Or, if a case genuinely must panic rather than return an error:

```rust
#[test]
#[should_panic]
fn edge_out_of_range_index_is_caught() { /* ... */ }
```

Pick the input that this phase's change makes reachable and that the language
promises is an error. **It must be a case you have actually verified produces an
error** — do not write `assert!(true)` and do not assert on a case you have not
run.

## The rule, stated once

> Every test asserts something that can fail. A test that only ever succeeds is
> a smoke test. The gate counts tests that assert a **failure was produced**.

`AGENTS.md` §3.1 calls this out separately from the quota and from the
`edge_*` requirement, precisely because it is the easiest of the four to satisfy
by accident.

## Do not redo the rest

The re-measurement in your REPORT is correct and worth keeping. Quota is met,
`edge_*` is met, the code is green. **Add the one test, re-run, report.**

Budget ten minutes, not ninety. You do not need to re-derive anything.