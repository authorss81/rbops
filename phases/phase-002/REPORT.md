# Phase 002 — Fix test discovery: stop feeding Rust source to the Redblue harness

## Reproduction (before the change)

```
$ strace -f -e trace=openat ./target/debug/rb test 2>&1 | grep "tests/"
openat(AT_FDCWD, "tests/", O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_DIRECTORY) = 3
openat(AT_FDCWD, "tests/suite.rb", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "tests/redblue_test.rs", O_RDONLY|O_CLOEXEC) = 3      <-- Rust source
openat(AT_FDCWD, "tests/expect_test.rs", O_RDONLY|O_CLOEXEC) = 3      <-- Rust source
openat(AT_FDCWD, "tests/test_arithmetic.rb", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "tests/integration_test.rb", O_RDONLY|O_CLOEXEC) = 3
```

The Redblue harness opened and read `tests/redblue_test.rs` and
`tests/expect_test.rs` — Rust source — on every `rb test` run.

**Partial staleness, stated plainly.** The phase prompt's stronger claim,
"parsed as Redblue code and reported as a failure", does **not** reproduce on
`main` (commit `c4ebad3`, phase-001). Phase-001 made the harness require a
line starting with `// test ` before lexing anything, and neither `.rs` file
contains such a line, so `rb test` reports `Failed: 0` today. What *does*
reproduce, and what the phase's own definition of done targets ("no `.rs` path
is ever read by the Redblue harness"), is the `openat` evidence above: the `.rs`
files are still discovered and read. The fix removes that. Any `.rs` file
added to `tests/` carrying a `// test ` comment would previously have been
executed as a Redblue program; `edge_discovery_rejects_rust_source` now makes
that impossible and asserts it.

Red test evidence (before the fix, `cargo test --lib testing::`):

```
failures:
    testing::tests::discovery_collects_only_rb_files
    testing::tests::discovery_skips_rust_sources_in_repository_test_directory
    testing::tests::edge_discovery_descends_into_subdirectories
    testing::tests::edge_discovery_rejects_rust_source
test result: FAILED. 4 passed; 4 failed; 0 ignored
```

After the fix:

```
$ strace -f -e trace=openat ./target/debug/rb test 2>&1 | grep "tests/"
openat(AT_FDCWD, "tests/", O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_DIRECTORY) = 3
openat(AT_FDCWD, "tests/suite.rb", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "tests/test_arithmetic.rb", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "tests/integration_test.rb", O_RDONLY|O_CLOEXEC) = 3
```

No `.rs` path is opened. `rb test` → `Tests run: 22 / Passed: 21 / Failed: 0`.

## What changed

| File | Lines | What |
|---|---|---|
| src/testing/mod.rs | +55 −4 | `find_test_files()` now collects only `ext == "rb"`, so `.rs` is never returned |
| src/testing/mod.rs | +8 −6 | `run_all_tests()` drops the now-redundant `ends_with("_test.rs") \|\| ends_with(".rb")` guard |
| src/testing/mod.rs | +141 | `#[cfg(test)] mod tests` — 8 new discovery tests |
| phases/phase-002/REPORT.md | new | this report |
| phases/phase-002/FINDINGS.md | new | out-of-scope observations |

No production code outside discovery was touched. `run_test_file`,
`TestHarness::run_source`, and every `.rb` suite file are unchanged.

## Tests added

All in `src/testing/mod.rs` (`#[cfg(test)] mod tests`). Scratch fixtures live
under `std::env::temp_dir()`, one directory per test, no network, no wall clock.

| Test | Edge class covered |
|---|---|
| `edge_discovery_rejects_rust_source` | the reported defect — a `_test.rs` file containing Redblue-looking `// test` markers is not collected |
| `discovery_collects_only_rb_files` | boundary — `.rs`, `.txt`, extensionless `README`, and `script.rb.bak` all rejected; only the two `.rb` collected |
| `edge_discovery_ignores_dot_rb_named_file` | boundary — a file named exactly `.rb` has no `Path::extension()` and must be skipped, not read |
| `edge_discovery_yields_no_files_for_missing_directory` | resource / malformed — a directory that does not exist yields `Ok(vec![])`, not an error |
| `edge_discovery_descends_into_subdirectories` | nesting — recursion into `unit/deep/`, `.rb` found, `.rs` not, at every depth |
| `edge_non_utf8_rb_file_reports_read_error` | malformed input, **asserts a failure**: non-UTF8 `.rb` bytes produce `Error::Io` naming the file, never a panic or a silent pass |
| `discovery_skips_rust_sources_in_repository_test_directory` | the defect against the real `tests/` tree — asserts zero `.rs` entries and that `suite.rb` is still found |
| `run_all_tests_reports_no_errors_for_rust_suite` | end-to-end — asserts `total > 0`, `errors.is_empty()`, `failed == 0` for `run_all_tests()` |

Test quota: 8 new `#[test]` functions (≥6 required); 5 named `edge_*` (≥1);
`edge_non_utf8_rb_file_reports_read_error` asserts an error is produced (≥1);
zero `#[ignore]`, zero new skips, zero new `allow(clippy::`.

### Edge-case matrix

| Row | Status |
|---|---|
| empty | covered — `edge_discovery_yields_no_files_for_missing_directory` (a scan of nothing finds nothing, cleanly) |
| singleton | covered — `edge_discovery_descends_into_subdirectories` collects exactly one nested `.rb`; `edge_discovery_ignores_dot_rb_named_file` collects exactly one file |
| boundary | covered — `.rb.bak` vs `.rb`, extensionless `README`, file named `.rb`, path under a nested subdirectory |
| out_of_bounds | N/A — discovery indexes nothing; `Path::extension()` and `read_dir` entries are the only lookups, and both are total functions returning `Option`/`None` |
| type_mismatch | N/A — the only type crossing this boundary is a filesystem path; a non-UTF8 path is handled by `to_string_lossy()` (preexisting) and is covered by `edge_non_utf8_rb_file_reports_read_error` for file *contents* |
| numeric_boundary | N/A — no arithmetic on this path; file counts are `usize` counts of `read_dir` entries |
| unicode | N/A — a path is compared byte-wise against the ASCII literal `"rb"`; `tests/*.rb` filenames are ASCII. Non-ASCII *content* is unrelated to discovery |
| nesting_recursion | covered — `edge_discovery_descends_into_subdirectories` walks two levels deep |
| duplicate_missing_keys | N/A — no map or keyed collection is built; the result is a `Vec` and duplicates cannot arise (a path appears once per `read_dir` entry) |
| malformed_input | covered — `edge_non_utf8_rb_file_reports_read_error` (invalid UTF-8 source) and `edge_discovery_yields_no_files_for_missing_directory` (absent directory) |
| resource_limit | covered — `edge_discovery_yields_no_files_for_missing_directory` (absent path must not error or hang); recursion depth is bounded by the real directory depth, and no unbounded allocation is introduced |

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass — no diff |
| `cargo clippy --all-targets -- -D warnings` | pass — zero warnings |
| `cargo test --all-targets` | pass — 39 passed, 0 failed (13 lib + 21 `tests/expect_test.rs` + 5 `tests/redblue_test.rs`), 0 ignored |
| `./rbops/verify.sh phase-002` | **not run — `rbops/` does not exist in this checkout** |

On the fourth gate: `ls rbops` returns `No such file or directory` in the
working tree this phase was dispatched into, so there is no `verify.sh` to
execute. I did not fabricate a result. As substitutes I ran the checks
`verify.sh` is documented to perform that are reachable here:

- `rb test` → `Tests run: 22 / Passed: 21 / Failed: 0` (the 22nd is the
  pre-existing `// skip` in `tests/integration_test.rb:26`).
- `for f in examples/*.rb; do rb run "$f"; done` → all 6 exit `0`.
- `modules/MathUtils.rb` → `Error: ParserError: Expected function name`,
  exit 1. **This is pre-existing and not a regression**: I confirmed it by
  `git stash`ing my change and re-running the same command on the unmodified
  tree, which produces the identical error. A module is not a runnable
  script; nothing in this phase touches that path. Recorded in `FINDINGS.md`.

## Invariants touched

- None. No `.rb` grammar, no `Value` variant, no `Error` variant, no file
  extension, and no `examples/*.rb` / `modules/*.rb` behaviour changed. The
  only behavioural delta is that `run_all_tests()` no longer reads `.rs`.

## Known gaps / follow-ups

- `rbops/verify.sh` was not executed — see the Gates table. → `FINDINGS.md`
- `find_test_files` returns entries in raw `read_dir` order, so the order in
  which `.rb` suites run is nondeterministic. Harmless today (each suite is
  independent, results are counted, not ordered) but it makes output
  unreproducible. Left alone to keep this diff a bug fix rather than a
  refactor. → `FINDINGS.md`
- Discovery still scans everything under `tests/`; a large non-test directory
  placed there would be walked. Not reachable in this repo. → `FINDINGS.md`