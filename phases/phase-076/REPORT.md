# Phase 076 — Scaffold projects: `rb new`, root discovery, and a project-aware `rb test`

## Finding reproduced

```
$ mkdir -p target/tmp/repro && cd target/tmp/repro
$ ../../../target/debug/rb new hello
Redblue v0.1.0 - A programming language as readable as plain English
...
  rb help        Show this help
exit=1
$ ls -A
(nothing)
```

`rb new hello` printed the generic help text and exited 1 without creating
anything. Bare `rb test` had no notion of a project either: `run_test(None)`
called `testing::run_all_tests()`, which always walks the literal `tests/`
directory of the working directory (`src/testing/mod.rs`). Nothing walked up to
a manifest, so a command run from `src/` could not find the project's tests.

## What changed

| File | Lines | What |
|---|---|---|
| `src/project.rs` | +173 (new) | `find_project_root` walks up to the nearest `redblue.manifest`; `create_project` writes `src/`, `tests/`, `src/main.rb`, `tests/main_test.rb` and a manifest in phase-044's schema; `check_manifest` parses it with `Manifest::parse`; `tests_dir` names the project's suite |
| `src/lib.rs` | +47 −5 | `rb new <name>` command (bare `rb new` is a usage error); bare `rb test` discovers the project root, validates its manifest and runs the root's `tests/`; `rb test <path>` is unchanged; help text lists `rb new` |
| `src/testing/mod.rs` | +10 −1 | `run_tests_in(dir)` is the directory-scoped runner; `run_all_tests()` now calls it with `tests/`, so the existing suite is byte-identical |
| `tests/discovery_test.rs` | +285 | 8 end-to-end project tests driving the `rb` binary in `target/tmp/`, beside the existing discovery tests |
| `redblue.manifest` | +2 (new) | the checkout is now a project, so bare `rb test` from the repository root runs the shipped `tests/` suite instead of failing with "No Redblue project found here" |
| `src/project.rs` | review | round-1 fixes: canonicalise/clean the discovery start path and correct its doc comment; reuse `manifest::is_module_name` instead of a second validator |
| `src/testing/mod.rs` | review | round-1 fixes: `collect_test_files` propagates a real `read_dir` error instead of silently skipping the directory, and `run_tests_in` refuses an empty collection rather than reporting zero tests as success |
| `tests/discovery_test.rs` | review | round-1 tests: a file where the project should go, an existing empty directory, a project with a missing or empty `tests/`, and canonicalised `..` discovery |

The manifest `rb new` writes is exactly phase-044's schema and nothing more:

```text
name hello
version 0.1.0
```

No dependency, lockfile or second schema is invented. `rb new` writes the
manifest last, so a half-written layout is not discoverable as a project.

## Tests added

| Test | Edge class covered |
|---|---|
| `rb_new_scaffolds_a_project_that_tests_green` | happy path + end-to-end: layout exists, manifest parses through 044's `parse_manifest`, bare `rb test` reports `Passed: 1` |
| `edge_rb_new_refuses_an_existing_non_empty_directory` | duplicate/occupied ground: refuses, names the directory, keeps the existing file, writes no manifest |
| `edge_rb_new_without_a_name_is_a_usage_error` | empty/missing name: non-zero exit, names the missing project name, creates nothing |
| `edge_rb_new_with_a_path_separator_is_refused_in_place` | boundary/traversal: `nested/hello` is refused, no directory outside the working directory, no leaf in it |
| `edge_rb_test_outside_a_project_names_rb_new` | empty project context: clean non-zero error naming `rb new`, never a silent success |
| `edge_rb_test_walks_up_from_a_nested_directory` | nesting/recursion: from `src/a/b` discovery finds the root and runs its `tests/` |
| `edge_rb_test_with_a_malformed_manifest_names_the_file_and_line` | malformed input: names `redblue.manifest` and `line 2` before running anything |
| `edge_rb_test_with_a_path_runs_only_that_file` | explicit path compatibility: a failing project suite is not run when a passing file is named |
| `edge_rb_new_refuses_a_file_named_after_the_project` | boundary/occupied ground: a file in the project's place is refused as "not a directory" and survives |
| `edge_rb_new_accepts_an_existing_empty_directory` | boundary/empty: an existing empty directory is accepted and tests green |
| `edge_rb_test_in_a_project_with_no_test_files_fails` | empty/missing: both a missing and an empty `tests/` fail with "No Redblue test files" rather than exiting 0 |
| `edge_project_root_canonicalises_parent_components` | boundary/path: a start path containing `..` answers the canonical project root |

### Mandatory edge-case matrix

| Row | Covered? |
|---|---|
| empty | covered: `edge_rb_new_without_a_name_is_a_usage_error` (no name) and `edge_rb_test_outside_a_project_names_rb_new` (empty directory outside any project) |
| singleton | covered: the scaffold writes exactly one test and bare `rb test` reports `Passed: 1` |
| boundary | covered: `edge_rb_new_with_a_path_separator_is_refused_in_place` (name boundary), `edge_rb_new_refuses_a_file_named_after_the_project` and `edge_rb_new_accepts_an_existing_empty_directory` (path-shape boundary), `edge_rb_test_with_a_path_runs_only_that_file` (explicit path boundary), and `edge_project_root_canonicalises_parent_components` |
| out_of_bounds | N/A: no index or collection is addressed; the closest path concern is traversal, covered by the path-separator refusal |
| type_mismatch | N/A: command arguments are text, and the only typed value is the project name, which the identifier validator refuses (`edge_rb_new_with_a_path_separator_is_refused_in_place`) |
| numeric_boundary | N/A: no arithmetic or numeric values are evaluated; the version is the fixed literal `0.1.0` parsed by phase-044's `Version` |
| unicode | N/A: project names follow phase-044's ASCII identifier schema; a non-ASCII name is refused by the same validator that refuses a path separator, and no path is written |
| nesting_recursion | covered: `edge_rb_test_walks_up_from_a_nested_directory` walks up three directories (`src/a/b`) |
| duplicate_missing_keys | covered: `edge_rb_new_refuses_an_existing_non_empty_directory` (occupied directory), `edge_rb_new_refuses_a_file_named_after_the_project`, `edge_rb_test_in_a_project_with_no_test_files_fails` (missing/empty tests), and `edge_rb_test_with_a_malformed_manifest_names_the_file_and_line` (unknown manifest field) |
| malformed_input | covered: malformed manifest names the file and line; invalid names and occupied directories are refused cleanly |
| resource_limit | N/A: discovery walks a finite ancestor chain once and reads one directory; there is no loop, recursion or unbounded output introduced here |

The suite has 12 new `#[test]` functions (8 from the first pass, 4 from the
round-1 review), 11 named `edge_*`, and 12 assertions of a failure outcome.
Zero new `#[ignore]`, `// skip` or `allow(clippy::` suppressions.

## Gates

| Gate | Result |
|---|---|
| cargo fmt --all -- --check | pass |
| cargo clippy --all-targets -- -D warnings | pass |
| cargo test --all-targets | 2931 passed, 0 failed, 0 ignored (86 test binaries) |
| ../rbops/verify.sh "phase-076" | pass |

`cargo test --all-targets` was re-run after the round-1 review: exit status 0,
and the summed `test result:` lines are 2931 passed, 0 failed, 0 ignored. The
four review tests are the file-in-the-way refusal, the empty-directory
acceptance, the missing/empty `tests/` refusal, and the canonicalised `..`
discovery path.

## Invariants touched

- None to the language surface: no lexer, parser, grammar, `Value` or `Error`
  variant changed. `.rb` is still the extension.
- Behaviour change, deliberate: bare `rb test` now means "the current
  project's tests", not "the working directory's `tests/`". Outside any project
  it is a non-zero error naming `rb new`.
- Behaviour change, deliberate: `rb new <name>` exists; bare `rb new` is a usage
  error.
- `rb test <path>` is unchanged: it still runs exactly the named file through
  the same `TestHarness`/`PrettyReporter` path, so the existing test-runner
  tests pass unmodified.
- Additive public API: `redblue::project::{create_project, find_project_root,
  check_manifest, tests_dir}` and `redblue::testing::run_tests_in`.

## Known gaps / follow-ups

- Root discovery is exposed as `project::find_project_root` and used by bare
  `rb test`. The explicit-path commands (`rb run`, `rb lint`, `rb format`,
  `rb compile`) keep their phase-044 semantics: a program resolves imports
  against its own directory, and `rb test <path>` must stay byte-identical.
  Teaching those commands to fall back to a discovered root is a separate
  behaviour change, not smuggled into this phase.
- An existing *empty* directory is accepted by `rb new`; only occupied ground
  is refused. This is intentional: an empty directory is not a merge and has
  nothing to overwrite. Both branches are pinned by the round-1 tests.
- The checkout now ships `redblue.manifest` so bare `rb test` at the repository
  root runs `tests/`; a project with a discovered manifest but no test files is
  a non-zero error, not a zero-test success.
