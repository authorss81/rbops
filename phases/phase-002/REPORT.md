# phase-002 — Fix test discovery: stop feeding Rust source to the Redblue harness

## Reproduction (before the fix)

`tests/redblue_test.rs` (and any other `tests/*_test.rs`) is scanned by
`run_all_tests()`. If such a file contains a line starting with `// test ` or
`// skip `, its body is lexed as Redblue.

Command (temporary fixture, deleted afterwards):

```bash
printf '// test fake rust test\nfn helper() -> i32 { 1 }\nlet x = 5;\n// end\n' > tests/zz_repro_test.rs
./target/debug/rb test; echo "exit=$?"
```

Wrong output before the fix:

```
............F.........SKIP: // skip "Awaiting full test harness implementation" - // Reason: Need to complete test integration
Tests run: 23
Passed: 21
Failed: 1
exit=1
```

`rb test tests/zz_repro_test.rs` names the fault directly:

```
1. fake rust test: FAILED
  Location: inline:3
  Error: LexerError: Unexpected character '>' at line 1, column 14
```

Note: with no `*_test.rs` fixture the suite happens to look green today — no
existing Rust file carries a `// test ` marker. The defect is live, not stale:
the moment one does, `rb test` reports a failure that never existed and exits 1.

## What changed

| File | Lines | What |
|---|---|---|
| src/testing/mod.rs | +8 −3 | `find_test_files` collects only `.rb`; `run_all_tests` filter is `.rb` only; results sorted for deterministic reporting; helper made `pub` so its filter is observable from a test |
| tests/discovery_test.rs | +250 (new) | 11 tests covering discovery, filtering, and failure reporting |

- `find_test_files` no longer accepts `ext == "rs"` (src/testing/mod.rs:69).
- `run_all_tests` no longer accepts `*_test.rs` (src/testing/mod.rs:47).
- `files.sort()` (src/testing/mod.rs:76) removes `read_dir` order from the
  report, so failure ordering is deterministic.
- `find_test_files` was `fn`; it is now `pub` with a doc comment. Visibility
  only — no behaviour change. It was made observable so the failing test could
  be written against the real filter instead of a proxy.

## Tests added

All in `tests/discovery_test.rs` (11 new `#[test]` functions).

| Test | Edge class covered |
|---|---|
| `edge_rust_source_is_never_collected` | type/format mismatch — `.rs` never collected; exactly one `.rb` is |
| `only_rb_files_are_collected_from_repo_tests_dir` | duplicate/missing — real `tests/` tree leaks nothing but `.rb` |
| `repo_suite_reports_zero_failures` | end-to-end: `run_all_tests()` over the repo has 0 failures and >0 tests |
| `edge_lexer_rejects_rust_source_sent_to_harness` | asserts a **failure**: Rust source fed to the harness yields exactly 1 lexer failure |
| `edge_missing_directory_yields_no_files` | empty / out_of_bounds — absent directory is empty, not an error |
| `recurses_into_nested_directories` | nesting — `.rb` at depth 3 found, nested `.rs` ignored, count exact |
| `edge_paths_with_spaces_and_unicode_are_collected` | unicode — `with space.rb`, `тест-файл.rb` both collected |
| `rb_file_without_markers_contributes_nothing` | empty — a marker-free `.rb` adds 0 tests and 0 failures |
| `files_without_a_recognised_extension_are_ignored` | boundary — `.txt`, `.rbs`, no-extension ignored; only `.rb` collected |
| `edge_malformed_rb_reports_a_failure_and_does_not_panic` | malformed input — unclosed `if` → exactly 1 failure with a non-empty message |
| `missing_test_file_is_reported_as_an_io_error` | asserts a **failure** and its kind — `Error::Io` for a file that does not exist |

Red-then-green evidence: before the fix,
`edge_rust_source_is_never_collected`, `only_rb_files_are_collected_from_repo_tests_dir`
and `recurses_into_nested_directories` failed with
`discovery leaked Rust source into the Redblue harness: ["tests/suite.rb", "tests/redblue_test.rs", "tests/expect_test.rs", ...]`.

## Edge-case matrix

- empty — covered: `edge_missing_directory_yields_no_files`, `rb_file_without_markers_contributes_nothing`
- singleton — covered: `edge_rust_source_is_never_collected` (exactly one `.rb` survives), `recurses_into_nested_directories`
- boundary — covered: `files_without_a_recognised_extension_are_ignored` (`.rb` vs `.rbs`/`.txt`/no-extension), `recurses_into_nested_directories` (exact count 2)
- out_of_bounds — covered: `edge_missing_directory_yields_no_files` (absent path), `missing_test_file_is_reported_as_an_io_error`
- type_mismatch — covered: `edge_rust_source_is_never_collected` (Rust source vs Redblue source)
- numeric_boundary — N/A: this change touches file extension matching only; no arithmetic is involved
- unicode — covered: `edge_paths_with_spaces_and_unicode_are_collected`
- nesting_recursion — covered: `recurses_into_nested_directories` (3 levels)
- duplicate_missing_keys — N/A: no records or maps are keyed here; the discovery filter is an extension predicate, and `edge_missing_directory_yields_no_files` covers the "missing" half
- malformed_input — covered: `edge_malformed_rb_reports_a_failure_and_does_not_panic`
- resource_limit — N/A: `find_test_files` recursion is bounded by directory depth on disk and the change adds no new loop; a depth cap for pathological directory trees is filed in FINDINGS.md rather than smuggled into this phase

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass (0 diff) |
| `cargo clippy --all-targets -- -D warnings` | pass (0 warnings) |
| `cargo test` / `cargo test --all-targets` | pass — 5 + 0 + 11 + 21 + 5 = 42 passed, 0 failed |
| `./rbops/verify.sh phase-002` | **not run** — `rbops/` and `phases/` do not exist in this checkout; `./rbops/verify.sh` returns `No such file or directory`. The pipeline that invoked this phase lives outside the working directory and was not inspected. Reported honestly rather than claimed. |

Manual end-to-end confirmation after the fix, same fixture as the reproduction:

```
Tests run: 22
Passed: 21
Failed: 0
exit=0
```

## Invariants touched

- None. No change to the language surface: `Value` variants, `Error` variants,
  `set x to <expr>`, `to … end`, `say`, string interpolation, trailing commas, and
  `.rb` as the source extension are all untouched.
- `find_test_files` became `pub` (additive). `testing` was already `pub mod`, so
  no module visibility changed.

## Known gaps / follow-ups

- The harness still discovers only `// test ` / `# test ` / `// skip ` marker
  lines; a Redblue `test "name" … end` block written in `.rb` is silently
  ignored (contributes 0 tests). → FINDINGS.md
- The lexer accepts an unterminated string at EOF (`say "oops` prints `oops`)
  instead of raising a lexer error. → FINDINGS.md
- `rb test <path>` (`src/lib.rs:50-55`) still does not exit non-zero on failure
  the way `rb test` (all) does. → FINDINGS.md