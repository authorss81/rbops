# phase-002 — FINDINGS

Work that does **not** belong to this phase. Recorded here so the auditor can
promote it to a real phase. Nothing below was changed by phase-002.

## 1. `collect_test_files` mangles non-UTF-8 paths

- **Where:** `src/testing/mod.rs` → `collect_test_files`, the
  `files.push(path.to_string_lossy().to_string())` line.
- **Problem:** a `.rb` file (or a directory in its path) whose name is not valid
  UTF-8 becomes a lossy string containing U+FFFD. `TestHarness::run_file` then
  fails to open it and the harness reports a *test failure* for a file it can
  never reach. Pre-existing: the same `to_string_lossy()` was there before this
  phase.
- **Suggested fix:** use `Path::to_str()` and skip (or report once, as a warning)
  a path that is not representable, rather than collecting a path that cannot be
  read.
- **Why not now:** a file the harness cannot name is a discoverability policy
  question, not a discovery-extension question. phase-002 changed only the
  extension match.

## 2. `find_test_files` has no recursion-depth cap

- **Where:** `src/testing/mod.rs` → `collect_test_files`.
- **Problem:** `path.is_dir()` follows symlinks. A symlink loop inside `tests/`
  recurses until the process stack overflows. The Redblue VM has its own call
  guard; filesystem discovery has none.
- **Suggested fix:** a depth counter, or `std::fs::symlink_metadata` to not
  follow directory symlinks, plus a documented maximum depth.

## 3. `run_test_file` bypasses the `.rb` guard

- **Where:** `src/testing/mod.rs:31`, `pub fn run_test_file(path: &str)`.
- **Problem:** it calls `harness.run_source(&source)` after its own
  `read_to_string`, so it never passes through `TestHarness::run_file` and never
  receives the new extension guard added by this phase. It has no callers in
  `src/` or `tests/` — grep confirms — so it is currently dead public API.
- **Suggested fix:** either delete it, or route it through `harness.run_file`.
  Leaving two entry points with different validation is a trap for the next
  phase.

## 4. `// test "name"` quotes are not stripped from `test_name`

- **Where:** `src/testing/harness.rs:31-35`. The marker is trimmed of the
  `// test ` prefix but the `"` characters are kept, so `TestError::test_name`
  is `"\"my test\""` rather than `my test`.
- **Problem:** reporter output shows the quotes; any consumer matching on
  test names has to know about them.
- **Suggested fix:** strip a surrounding pair of `"` in `run_source`.
  phase-002's assertions deliberately use `contains` rather than `==` so this
  phase does not lock the behaviour in either direction.

## 5. `TestHarness` carries two unused `HashMap` fields

- **Where:** `src/testing/harness.rs:11-12`, `_globals` and `_test_context`.
  `_test_context` is always empty; `_globals` is seeded from `stdlib::builtins()`
  and never read. Each `TestHarness::new()` rebuilds the whole builtin table.
- **Problem:** dead weight, and an ordering/nondeterminism hazard the moment
  anything iterates them (AGENTS.md §5 forbids `HashMap` order reaching output).
- **Suggested fix:** delete both fields, or wire them up as the shared
  cross-test scope the harness clearly intended.

## 6. `rb test` (no path) and `rb test <path>` report differently

- **Where:** `src/lib.rs:62-84`. The no-path branch prints bare
  `Tests run/Passed/Failed`; the with-path branch prints the `PrettyReporter`
  table including duration and skipped count.
- **Problem:** a CI step that greps the output has two different shapes to
  handle, and the no-path branch omits `skipped` entirely.
- **Suggested fix:** use `PrettyReporter` in both branches.

## 7. `verify.sh` was not runnable from this checkout

- **Problem:** `rbops/` and `phases/` were absent from the working directory;
  only `.github/workflows/ci.yml` was present. Gate 4 of the contract
  (`./rbops/verify.sh phase-002`) could not be executed and is reported as
  NOT RUN in REPORT.md rather than claimed as a pass.
- **Suggested fix:** either vendor `rbops/` into the repo so an agent can run
  gate 4 locally, or drop it from the agent-facing gate list.
