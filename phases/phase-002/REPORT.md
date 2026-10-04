# Phase 002 — Fix test discovery: stop feeding Rust source to the Redblue harness

## Reproduction (before the change)

`src/testing/mod.rs:66` collected `ext == "rs" || ext == "rb"`, and
`run_all_tests()` passed every collected path to `TestHarness::run_file`. Probe:

```
$ printf 'fn main() {}\n// test "rust source leaked into harness"\nsay "not redblue"\n// end\n' \
    > tests/zz_probe_test.rs
$ ./target/debug/rb test
.....................this is not redblue
..................SKIP: ...
Tests run: 23
Passed: 22
Failed: 0
```

The Rust file was read by the Redblue harness, its body was lexed and executed
(`this is not redblue` printed), and it was counted as a **passing** test — worse
than the reported "reported as a failure", which is the same code path when the
Rust body happens not to lex. Probe file removed afterwards; `tests/` is back to
its six tracked files.

## What changed

| File | Lines | What |
|---|---|---|
| `src/testing/mod.rs` | +14 −9 | `find_test_files` collects `.rb` only; `run_all_tests` drops the `_test.rs` branch; discovery results sorted for a stable report. `find_test_files` made `pub` so the discovery contract is testable from `tests/`. |
| `tests/harness_discovery_test.rs` | +319 | new — 15 tests pinning the discovery contract |
| `phases/phase-002/FINDINGS.md` | new | 5 out-of-scope defects recorded |

Nothing else touched. No language surface, no `tests/*.rb` body, no existing test.

## Tests added

`tests/harness_discovery_test.rs`, 15 `#[test]` functions.

| Test | Edge class covered |
|---|---|
| `discovers_only_rb_files_and_never_rust_sources` | the defect itself; `.rs`/`.txt`/`.rbc` beside a `.rb` |
| `repository_tests_directory_yields_only_rb_paths` | defect asserted against the real `tests/` tree, not a fixture |
| `edge_run_all_tests_reports_no_failure_from_rust_sources` | `run_all_tests()` reports 0 failures, none blaming a `.rs` |
| `edge_rust_source_between_rb_files_leaves_both_neighbours` | boundary — `.rb` at index 0 and index len−1 survive the dropped `.rs` |
| `discovers_a_single_rb_file` | singleton |
| `empty_directory_yields_no_files` | empty |
| `discovers_nested_rb_files_and_drops_nested_rust_sources` | nesting/recursion, 3 levels, `.rs` dropped at depth |
| `duplicate_basenames_in_different_directories_are_both_collected` | duplicate keys analogue — same basename in two dirs, both kept |
| `edge_rb_file_beside_identically_named_rs_file_is_still_collected` | duplicate/missing — `.rb` vs same-named `.rs` |
| `discovery_order_is_sorted` | determinism (read_dir order is filesystem-dependent) |
| `discovers_paths_with_spaces_and_unicode` | unicode — Cyrillic + emoji file names in a directory with a space |
| `edge_uppercase_extension_is_not_collected` | boundary — `.RB` is not `.rb` |
| `edge_missing_directory_yields_no_files_and_does_not_panic` | resource/state — absent directory, no panic |
| `edge_non_utf8_rb_file_is_reported_as_an_io_failure` | **asserts a failure of a named kind** (`Error::Io`), no panic, no silent pass |
| `edge_malformed_rb_test_body_is_reported_as_a_failure` | **asserts a failure of a named kind** — incomplete statement inside a `// test` body yields 1 failure, 0 passes, message naming the parser error |

Quotas: 15 ≥ 6 new `#[test]`s; 7 `edge_*` tests; 2 tests assert a *failure kind*
(`Error::Io`, parser error) rather than only success; 0 new `#[ignore]`, 0
`.skip`, 0 clippy suppressions.

### Red before green

The first run of `cargo test --test harness_discovery_test`, before the fix:

```
failures:
    discovers_nested_rb_files_and_drops_nested_rust_sources
    discovers_only_rb_files_and_never_rust_sources
    discovery_order_is_sorted
    edge_rb_file_beside_identically_named_rs_file_is_still_collected
    edge_rust_source_between_rb_files_leaves_both_neighbours
    repository_tests_directory_yields_only_rb_paths
    ...
test result: FAILED. 8 passed; 7 failed
```

e.g. `the Redblue harness must not be given ["tests/redblue_test.rs",
"tests/span_test.rs", "tests/expect_test.rs", "tests/harness_discovery_test.rs"]`.
Disclosure, per AGENTS.md §8: to make the contract testable I first changed
`fn find_test_files` to `pub fn find_test_files` — a visibility change only, no
behaviour change — and the red run above was made against that. The behaviour
change landed afterwards.

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass (clean) |
| `cargo clippy --all-targets -- -D warnings` | pass (`Finished dev profile`, no warnings) |
| `cargo test --all-targets` | pass — 61 passed, 0 failed, 0 ignored (lib 5, expect_test 21, harness_discovery_test 15, redblue_test 5, span_test 15, bin 0) |
| `./rbops/verify.sh phase-002` | **not run — `rbops/` does not exist in this checkout** (see below) |

Additional check, not a gate: `rb run` over all of `examples/*.rb` and
`modules/*.rb` — all pass except `modules/MathUtils.rb`, which fails identically
with my diff stashed (`git stash -u`, rebuild, same `ParserError: Expected
function name` at `modules/MathUtils.rb:4`). Pre-existing → FINDINGS.md F4.

## Invariants touched

- None. No change to `Value`, `Error`, the grammar, `.rb` as the source
  extension, `say`, `set … to`, or `… end` blocks.
- Behavioural change outside the language: the Redblue test harness no longer
  reads `.rs` files (was: `rb test` executed Rust sources as Redblue), and
  `run_all_tests()` no longer re-filters by filename (`find_test_files` already
  filtered). Public API grew by one item: `redblue::testing::find_test_files`.

## Test-requirement matrix (phase prompt §"Test requirements")

- **empty** — covered: `empty_directory_yields_no_files`; a directory with nothing
  to run yields an empty list, not an error.
- **singleton** — covered: `discovers_a_single_rb_file`.
- **boundary** — covered: `edge_rust_source_between_rb_files_leaves_both_neighbours`
  keeps the `.rb` at index 0 and index len−1; `edge_uppercase_extension_is_not_collected`
  covers the `.rb`/`.RB` extension boundary.
- **out_of_bounds** — covered: `edge_missing_directory_yields_no_files_and_does_not_panic`
  (a path that was never created returns empty rather than panicking). No
  index-based access exists in the code under change.
- **type_mismatch** — covered: `.rs`, `.txt` and `.rbc` candidates in a scanned
  directory are all rejected while the `.rb` is kept
  (`discovers_only_rb_files_and_never_rust_sources`).
- **numeric_boundary** — N/A + why: this change adds no arithmetic and reads no
  numbers; the only counts involved are `Vec::len` in assertions, and the
  boundary there is covered by the index-0/len−1 test above.
- **unicode** — covered: `discovers_paths_with_spaces_and_unicode` uses a
  directory named `a folder 🎉` containing `тест файл.rb` and `emoji 🎉.rb`.
- **nesting_recursion** — covered: `discovers_nested_rb_files_and_drops_nested_rust_sources`
  descends three levels with `.rs` decoys at each depth. Recursion is
  per-directory, one frame per level; no user-controlled depth is reachable
  through `rb test`, which is hardcoded to `tests/`.
- **duplicate_missing_keys** — covered (file analogue): duplicate basenames in
  different directories are both collected, and a `.rb` sharing a basename with
  a `.rs` is still collected. There are no records/keys in this code path.
- **malformed_input** — covered: `edge_malformed_rb_test_body_is_reported_as_a_failure`
  (incomplete statement inside a discovered body) and
  `edge_non_utf8_rb_file_is_reported_as_an_io_failure` (invalid UTF-8 bytes →
  `Error::Io`, no panic, no silent pass). Unterminated-string-at-EOF is **not**
  covered: the lexer accepts it silently today, so the test would have asserted
  current wrong behaviour → FINDINGS.md F3.
- **resource_limit** — covered: absent directory, three-level recursion, and a
  `.rb` that cannot be decoded all terminate cleanly with a recorded outcome.
  No unbounded loop is introduced; the only unbounded construct is directory
  recursion, which is bounded by the filesystem depth of `tests/`.

## Known gaps / follow-ups

- `rbops/verify.sh` could not be executed: this checkout has no `rbops/` and no
  `phases/` directory (`ls: cannot access 'rbops': No such file or directory`),
  and the gate script lives outside the project. I created
  `phases/phase-002/` to hold this report and FINDINGS.md. The three cargo gates
  were run locally and are green.
- The 21 tests `rb test` still reports are all vacuous (empty bodies) →
  FINDINGS.md F1. Discovery is now correct; the suite's contents are not.
- The documented `test "name" … end` block syntax is still unsupported by the
  harness → FINDINGS.md F2.
- `modules/MathUtils.rb` does not parse → FINDINGS.md F4.
