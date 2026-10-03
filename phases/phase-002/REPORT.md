# Phase 002 — Fix test discovery: stop feeding Rust source to the Redblue harness

## What changed

| File | Lines | What |
|---|---|---|
| src/testing/mod.rs | +62 −16 | `is_test_file()` accepts only `.rb`; `require_test_file()` guard runs before any file is opened; `find_test_files()` made `pub`, collects `.rb` only, recurses via `collect_test_files()` with a 16-level depth cap, and sorts+dedups for deterministic order; `run_all_tests()` no longer keeps a `*_test.rs` branch |
| src/testing/harness.rs | +2 −0 | `TestHarness::run_file()` calls `require_test_file()` first, so no `.rs` path can be read through the harness entry point |
| tests/discovery_test.rs | +383 −0 | new file, 14 tests over discovery |

`run_test_file()` and `TestHarness::run_file()` are the only two places that
open a path for the Redblue harness. Both now reject a non-`.rb` path before
`read_to_string`, so no `.rs` path is ever read.

## Reproduction

Before:

```
$ ./target/debug/rb test tests/redblue_test.rs
Test Results: 0 total, 0 passed, 0 failed, 0 skipped (0.0% success)
exit=0
```

The Redblue harness accepted a Rust source file as a Redblue suite and exited 0.
`run_all_tests()` reached the same files through `find_test_files("tests/")`,
which collected every `.rs` under `tests/` and passed the two cargo suites
(`redblue_test.rs`, `expect_test.rs`) to `harness.run_file()`.

After:

```
$ ./target/debug/rb test tests/redblue_test.rs
Error: IoError: Not a Redblue test file: tests/redblue_test.rs (expected a .rb file)
exit=1
```

`rb test` (whole suite) is unchanged at `Tests run: 22 / Passed: 21 / Failed: 0`,
because all 22 tests already came from the `.rb` files.

Note on the phase evidence: the claim "reported as a failure" did not reproduce
on `main`. `TestHarness::run_source` only scans lines for `// test ` markers and
never lexes the whole file, and no Rust file in `tests/` carries such a marker,
so the `.rs` files were read and scanned silently. The observable defect is that
they were read at all and were accepted without complaint. The fix makes the
acceptance an error rather than a silent read.

## Tests added

All in `tests/discovery_test.rs`. Each builds its own scratch directory under
`std::env::temp_dir()` and removes it on drop, so no test depends on the
repository's `tests/` contents, the network, or the wall clock.

| Test | Edge class covered |
|---|---|
| `edge_rs_path_is_rejected_by_redblue_harness` | out_of_bounds / type_mismatch — asserts a **failure**: `run_test_file` on a `.rs` path returns `Err` naming `.rb`, instead of the `Ok(0 tests)` it returned before |
| `redblue_files_are_accepted_by_discovery` | singleton — `.rb` paths of each shape are accepted by `is_test_file` |
| `discovery_collects_rb_files_only` | type_mismatch — mixed directory: `.rb` collected, `_test.rs`, `Cargo.toml`, `notes.md` not |
| `edge_discover_nothing_in_empty_directory` | empty |
| `edge_discover_single_rb_file` | singleton — exactly one element |
| `edge_discover_extension_lookalikes_are_rejected` | boundary — `trailing_dot.rb.`, `double.rb.bak`, `backup.rb.rs`, `upper.RB`, `no_extension`, `.rb`, `redblue_test.rs` |
| `edge_directory_named_like_a_test_file_is_not_collected` | type_mismatch — a *directory* named `looks_like_a_suite.rb` is descended into, not collected |
| `edge_discover_nested_directories` | nesting_recursion — three levels; nested `.rb` found, nested `.rs` not |
| `discovery_is_deterministic_across_runs` | resource_limit / determinism — 9 repeated runs return identical order (was `read_dir` order); 5 files reported exactly once |
| `edge_discover_unicode_and_spaced_paths` | unicode — `héllo wörld.rb`, CJK `漢字.rb`, `dir 🚀 with spaces/中文.rb`; the `.rs` twin is excluded |
| `edge_missing_directory_yields_no_files` | resource_limit — absent directory is `Ok([])`, not an error, so `rb test` works in a checkout with no tests |
| `edge_symlink_cycle_is_bounded_not_a_hang` | resource_limit — a symlink back to the parent is cut off by the depth cap instead of recursing forever |
| `edge_malformed_non_utf8_rb_file_is_a_clean_io_error` | malformed_input — asserts a **failure**: invalid UTF-8 bytes give `Error::Io`, never a panic |
| `edge_failing_expect_in_rb_file_is_reported_as_a_failure` | asserts a **failure**: a wrong `expect` yields `passed=0`, `failed=1`, and an error naming the values |

Also added: `tests/discovery_test.rs` is itself a `.rs` file under `tests/`; it
is ignored by `rb test` and runs under `cargo test`.

## Edge-case matrix

- empty — covered, `edge_discover_nothing_in_empty_directory`
- singleton — covered, `edge_discover_single_rb_file` + `redblue_files_are_accepted_by_discovery`
- boundary — covered, `edge_discover_extension_lookalikes_are_rejected` (dotfiles, double extensions, case, trailing dot)
- out_of_bounds — covered, `edge_rs_path_is_rejected_by_redblue_harness`: the wrong file kind must produce a clean error, not a parse. There is no index arithmetic in discovery, so index `-1`/`len`/`999` are N/A.
- type_mismatch — covered, `discovery_collects_rb_files_only` and `edge_directory_named_like_a_test_file_is_not_collected`
- numeric_boundary — N/A: discovery compares an extension string against `"rb"`. No numeric value is parsed, divided, or converted anywhere in the changed code.
- unicode — covered, `edge_discover_unicode_and_spaced_paths`
- nesting_recursion — covered, `edge_discover_nested_directories`; the recursion itself is bounded by `edge_symlink_cycle_is_bounded_not_a_hang`
- duplicate_missing_keys — N/A: discovery returns a `Vec<String>` of paths. There is no record, no key, and no field access, so a duplicate or missing key has no representation to test.
- malformed_input — covered, `edge_malformed_non_utf8_rb_file_is_a_clean_io_error` (invalid UTF-8 bytes) and `edge_missing_directory_yields_no_files`. A `.rb` file with malformed *Redblue* is covered by `edge_failing_expect_in_rb_file_is_reported_as_a_failure`; lexing malformed Redblue belongs to the lexer phase.
- resource_limit — covered, `edge_symlink_cycle_is_bounded_not_a_hang` (depth cap), `edge_missing_directory_yields_no_files`, `discovery_is_deterministic_across_runs`

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass, 0 warnings |
| `cargo test --all-targets` | 45 passed, 0 failed (5 + 14 + 21 + 5), 0 ignored |
| `cargo test` | 45 passed, 0 failed, doc-tests 0 |
| `./rbops/verify.sh phase-002` | **not run — `rbops/verify.sh` does not exist in this checkout** |

There is no `rbops/` directory in this working tree (`ls` shows only `.github`,
`src`, `tests`, `examples`, `modules`, `docs`, `tooling`, and top-level docs),
and no `phases/` directory either, so the fourth gate could not be executed here.
The first three gates were run directly and are green. Every `examples/*.rb`
and `modules/*.rb` was executed; `modules/MathUtils.rb` fails identically
before and after this diff and is recorded in `FINDINGS.md`.

## Invariants touched

- None. No language surface changed: no grammar change, no `Value` variant, no
  `Error` variant, no change to `.rb`, `to … end`, `set x to`, `say`, or string
  interpolation. `Error::Io` is used, not added.
- `run_test_file` and `TestHarness::run_file` now reject a non-`.rb` path with
  `Error::Io` instead of reading it (was: read silently, produce 0 tests).
- `find_test_files` changed from private to `pub`. Public API addition only.

## Known gaps / follow-ups

- `TestHarness::run_source` still scans whole files for `// test ` markers, so a
  `.rb` file whose body happens to sit between two markers is extracted
  verbatim. Not in scope; → `FINDINGS.md`
- The harness keeps the surrounding quotes in `test_name`. Pre-existing;
  `discovery_test.rs` documents the current form rather than changing it.
- `modules/MathUtils.rb` does not parse on `main`. → `FINDINGS.md`