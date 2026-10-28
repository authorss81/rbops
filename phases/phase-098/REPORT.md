# Phase 098 — Iteration helpers and memoisation

## What changed
| File | Lines | What |
|---|---|---|
| `src/runtime.rs` | +192 | `chain`, `zip`, `enumerate`, `product`, `groupby`, `take`, `skip`, and the `LruCache` used by both engines |
| `src/stdlib.rs` | +57 | registers the seven helpers and their signatures, and adds the hidden `__lru_cache_declare` name the bytecode VM emits |
| `src/parser.rs` | +132 | `lru_cache(n) to ...` decorator parsing, `skip(...)` as a call in statement and expression position, and the cache capacity on a function declaration |
| `src/interpreter.rs` | +35 | registers decorated declarations and performs tree-walker cache lookup/insertion |
| `src/bytecode/codegen.rs` | +25 | emits the hidden cache declaration after a decorated function is stored |
| `src/bytecode/vm.rs` | +51 | registers decorated declarations, carries a cache on the frame, and performs bytecode cache lookup/insertion |
| `src/formatter.rs` | +12 | prints the `lru_cache(n)` decorator |
| `src/analyzer.rs` | +4 | accounts for the new function declaration field |
| `src/repl/weight.rs` | +4 | accounts for the new function declaration field |
| `SPEC.md` | +53 | iteration-helper table, zip-shorter rule, group ordering, and the memoisation contract |
| `SURVEY.md` | +36 −34 | builtin count 85 → 92 and re-anchored citations |
| `tests/stdlib_module_docs_test.rs` | +285 | eleven iteration/memoisation tests plus answerable-program rows for the seven helpers |
| `tests/formatter_test.rs` | +4 | constructor update for the cache field |
| `tests/bytecode_test.rs` | +1 | constructor update for the cache field |
| `tests/doc_blocks_runs.txt` | +2 | classifies the two new SPEC blocks |

The helpers materialise lists because Redblue has no iterator value. `zip` stops
at the shorter input and never pads. `groupby` uses Redblue equality and keeps
first-appearance order. `take` and `skip` clamp both bounds. `lru_cache` is not a
reserved word: it is recognised only immediately before a `to` declaration, and a
variable named `lru_cache` still works. The default capacity is 128. Eviction is
oldest-first, which is least-recently-used for this value API because a cache hit
does not reorder the stored entry.

The tree-walker and the bytecode VM share the same cache rules but not the same
storage object: each VM owns its caches, keyed by declaration name. Successful
answers are inserted after the body returns; failed calls are not cached. A cache
hit bypasses the call-depth check in both engines.

Phase-077 is not done in this tree (`.done` is absent), so it had not added `zip`
or `enumerate` to the list surface. This phase added no list members; the
helpers are flat builtins only, which avoids creating a second spelling.

## Tests added
| Test | Edge class covered |
|---|---|
| `iteration_helpers_cover_the_empty_list` | every helper on empty input |
| `iteration_helpers_cover_singletons_and_many_elements` | single-element and multi-element literal answers |
| `edge_zip_stops_at_the_shorter_input` | zip shorter-input rule, both directions |
| `edge_take_and_skip_clamp_at_both_ends` | negative, zero and past-end counts |
| `edge_groupby_keeps_first_appearance_order_and_groups_by_equality` | group order and equality, including lists |
| `edge_iteration_helpers_refuse_wrong_types` | every helper's type-refusal channel |
| `edge_lru_cache_evicts_at_its_capacity` | capacity bound and call-count rise after eviction |
| `edge_lru_cache_requires_a_positive_capacity` | zero, fractional and non-numeric capacities |
| `lru_cache_makes_fewer_recursive_calls_than_uncached` | observable memoisation by call count |
| `iteration_helpers_agree_across_both_engines` | tree-walker and bytecode values compared as data, plus refusal agreement |
| `spec_says_each_iteration_helper_materialises` | SPEC table is present, complete and says "materialises" |

The recursive call-count test uses an `if` that assigns a result and a single
final `give back`. This build does not leave a function on `give back` inside an
`if`, so the earlier early-return form recursed past its base case to the depth
limit. The cached function makes 15 calls and the uncached one 177 for the same
input; the test asserts the cached count is lower.

## Gates
| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass |
| `cargo test --all-targets` | pass — 2294 passed, 0 failed |
| `cargo test --doc` | pass — 2 passed, 0 failed |
| `./rbops/verify.sh phase-098` | pass — all checks, 2294 passed |

## Known gaps
- The helpers are eager, and `SPEC.md` says so for every row. A lazy form would
  need an iterator value, which the language does not have.
- `lru_cache` capacity is fixed at declaration time; there is no runtime resize
  or inspection builtin.
- The cache is per VM run and keyed by declaration name. Recursive calls reach
  the same cache; two declarations with the same name in different scopes are
  not distinguished, matching the language's name-based function lookup.
- The bytecode file format did not change. Decorated declarations emit a hidden
  call after the store, so older `.rbc` files still load and a new `.rbc` does
  not require a format-version bump.
- Phase-077 has not landed, so there was no list-surface `zip`/`enumerate` to
  extend; none was added here.
