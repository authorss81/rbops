# phase-091 — done by hand, in redblue `2948f23`

**MEMORY.md and `tests/memory_model_test.rs` are on `main`.**

This phase was blocked with a `REPORT.md` claiming completed work that had
never shipped — no `MEMORY.md`, no change anywhere. Written here instead of
retrying, because every fact in it was already established.

## What it documents

| Claim | Evidence |
|---|---|
| No garbage collector | `src/value.rs:276` — `pub type Shared<T> = std::sync::Arc<T>`, freed on last reference |
| Reading a variable **copies**, it does not alias | `src/value.rs:88-90` |
| **A reference cycle leaks** | No `Weak` anywhere under `src/` — verified, zero matches |
| Numbers are `f64`, exact only to `2^53` | `src/value.rs:250`, `src/value.rs:109` |
| Deep recursion raises a **catchable** error | `MAX_CALL_DEPTH = 1000` in `build.rs:19`, plus `MAX_ITERATIONS` / `MAX_STEPS` |

Each limit's environment override is listed in a table.

## Why the tests exist

A document nobody checks becomes wrong quietly, and the cycle claim is exactly
the statement a future change to reference handling would falsify. Six tests
pin it — the cycle that no handle can break, the demonstration that a `Weak`
handle is the standard remedy and is absent here, and the `2^53` boundary from
both sides.

## Two mistakes in the first draft, both mine and both caught

- A global `AtomicUsize` drop counter. Cargo runs tests on parallel threads, so
  two tests sharing a global fail unpredictably — the same trap as the `COLUMNS`
  leak fixed earlier the same day. It now uses `Arc::strong_count`, which is
  per-value and thread-safe.
- It reached for `redblue::value::Shared`, which is not re-exported. The tests
  use the public API only, so they cannot pass by depending on internals that are
  free to change.

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass |
| `cargo test --test memory_model_test` | 6 passed, 0 failed |

## Note

The prior `REPORT.md` for this phase was preserved by a sibling cleanup as
`UNSHIPPED-REPORT.md`: it described this same work as done when none of it
existed. It is kept as the record of that failure, not as evidence of anything.