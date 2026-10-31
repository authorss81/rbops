# Phase 100 — Path values and directory listing

## What changed

The finding reproduced on the phase base before any edit: `path` was not a
module, so `say path.join("a", "b")` failed with `AnalyzerError: Unknown
variable 'path'`. Every program that built a filesystem path had to concatenate
`/` itself, which is wrong on Windows and has no answer for a parent, a filename,
an extension or the contents of a directory.

A path is now a `path` object with one field, `text`. It is deliberately not a
new `Value` variant: it prints as its text, compares equal to that text, and
`type_of` answers `path`. `path.join`, `path.parent` and `path.resolve` answer
path values; `path.filename`, `path.stem` and `path.extension` answer text or
`nothing`; `path.is_absolute` answers yes/no; and `path.list` answers the sorted
names directly inside a directory. The separators come from
`std::path::MAIN_SEPARATOR`, not a hardcoded slash.

`files.read`, `write`, `append`, `exists`, `lines`, `delete`, `copy` and
`rename` accept either a text path or a path value. The old text spelling keeps
working, and the old argument-error phrases remain visible in the refusal text.
Both engines reach the same implementation through `runtime::builtin`.

The in-memory wasm filesystem now answers `read_dir` as well, so `path.list` is
not a native-only surface. A directory listing is sorted by name and an empty
directory is the empty list.

| File | Lines | What |
|---|---|---|
| `src/path.rs` | +304 −0 | path value, `text_of`, `join`, `join_with_separator`, `parent`, `filename`, `stem`, `extension`, `is_absolute`, lexical `resolve`, `list`, the eight `path.*` builtin arms, and two unit tests |
| `src/runtime.rs` | +46 −25 | `path_*` dispatch, path-object property access and hashing, and `files.*` accepting text or path values without changing the existing refusal phrases |
| `src/vfs.rs` | +51 −3 | native and in-memory `read_dir`, with sorted names and an empty directory answered as an empty list |
| `src/value.rs` | +17 −0 | path values display as their text, answer `path` from `type_name`, and compare equal to that text |
| `src/stdlib.rs` | +60 −0 | registers the `path` module, its eight members, builtin names, signatures and the effectful `path_list` entry |
| `src/lib.rs` | +1 −0 | exports `pub mod path` |
| `tests/stdlib_modules_test.rs` | +233 −2 | 10 path integration tests running both engines and comparing their answers, kept beside the existing files tests |
| `tests/stdlib_module_docs_test.rs` | +52 −0 | one answerable row per new builtin |
| `tests/stdlib_module_names_test.rs` | +5 −0 | the `path` module row |
| `tests/doc_blocks_runs.txt` | +9 −9 | re-anchors the SPEC blocks after the expanded files/path block |
| `tests/doc_blocks_fragments.txt` | +1 −1 | re-anchors the later network fragment |
| `tests/doc_blocks_known_fail.txt` | +1 −1 | re-anchors the later parser-failure block |
| `SPEC.md` | +30 −2 | documents the `path` surface, path values, separators, absolute joins, roots, trailing separators, lexical resolution and sorted listings |
| `README.md` | +15 −1 | the user-facing files and path section |
| `SURVEY.md` | +7 −6 | builtin count 105 → 113, modules 13 → 14, members 76 → 84, the `path` row, and re-anchored citations |

A path value is `Value::Object("path", {text: ...})`. `path::text_of` is the one
conversion every path argument and every `files.*` call goes through, so the text
form and the value form cannot drift apart. `path.join` follows the host rule
that an absolute later part discards everything before it; it also removes a
trailing separator and folds `/` to `\` when the test asks for the Windows
separator. `path.resolve` is lexical: it makes the path absolute against the
working directory and folds `.` and `..` without consulting the filesystem or
resolving symlinks.

## Tests added

| Test | Edge class covered |
|---|---|
| `path_join_uses_the_platform_separator` | platform separator: the language's join takes its separator from `MAIN_SEPARATOR` |
| `edge_the_separator_is_the_platforms_not_a_hardcoded_slash` | platform separator: POSIX and Windows joins are distinct, and the language agrees with the host |
| `path_components_are_literal_for_relative_and_absolute_inputs` | relative and absolute parents, filenames, stems, extensions and `is_absolute` |
| `edge_parent_of_a_root_is_nothing_and_a_trailing_separator_is_ignored` | empty/boundary: a root has no parent; a trailing separator does not make a filename empty |
| `edge_join_of_an_absolute_part_discards_what_came_before` | boundary: an absolute component replaces the relative prefix |
| `edge_trailing_double_dot_and_spaced_paths_are_handled` | malformed_input/unicode: double separators, trailing separators, dot segments, spaces and non-ASCII names |
| `files_accept_a_path_value_as_well_as_text` | type_mismatch: `files.*` accept both the text spelling and the path-value spelling |
| `edge_listing_is_sorted_and_an_empty_directory_is_an_empty_list` | empty and ordering: sorted names, an empty directory answers `[]` |
| `edge_bad_path_arguments_are_clean_runtime_failures` | type_mismatch and malformed_input: non-path arguments are catchable runtime errors; a missing directory is a catchable I/O error |
| `edge_empty_text_has_no_components` | empty: an empty path has no parent, filename, stem or extension |
| `path::tests::edge_join_with_each_separator_is_distinct` | unit: `/` and `\` produce different joins |
| `path::tests::edge_resolve_removes_dot_segments` | unit: resolution removes `.` and `..` segments |

Mandatory matrix:

- empty — `edge_empty_text_has_no_components`, the empty directory in
  `edge_listing_is_sorted_and_an_empty_directory_is_an_empty_list`, and the
  root parent case.
- singleton — a single component is joined and listed unchanged; the one-file
  listing case is covered by the sorted-listing test.
- boundary — the root parent, a trailing separator, an absolute later part,
  double separators and dot segments are all pinned.
- out_of_bounds — N/A: `path` exposes no numeric index or argument order.
- type_mismatch — every `path.*` argument and every `files.*` path is checked;
  `edge_bad_path_arguments_are_clean_runtime_failures` pins the refusals.
- numeric_boundary — N/A: no numeric path operation is exposed.
- unicode — the spaced and non-ASCII filename and stem cases in
  `edge_trailing_double_dot_and_spaced_paths_are_handled`.
- nesting_recursion — N/A: a path is flat text; no recursive user callback is
  invoked.
- duplicate_missing_keys — N/A: paths are not collections and do not have keys.
- malformed_input — missing directory, non-text arguments and empty components
  are covered by the refusal and empty-path tests.
- resource_limit — N/A: no new numeric limit is introduced; a listing is
  bounded by the host directory.

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass |
| `cargo test --all-targets` | 2398 passed, 0 failed, 0 ignored |
| `../rbops/verify.sh phase-100` | pass |

## Invariants touched

- None. `Value` has no new variant, `Error` has no new variant, and the grammar,
  `.rb` files, `to … end`, `set … to`, `say`, trailing commas, interpolation,
  examples and modules are unchanged.
- `path` is a module name; the new names are builtins reached by both engines
  through the existing shared dispatcher.
- A path value is an ordinary object with a `text` field, not a hidden value
  kind; it remains inspectable as a record.

## Known gaps / follow-ups

- `path.resolve` is lexical. It does not resolve symlinks or require the path to
  exist, which is the useful answer for a path that is about to be created; a
  canonicalising spelling would be a separate operation.
- `path.list` answers names only, not file type, size or modification time. A
  structured directory-entry value would be a follow-up.
- A path value is a record-shaped object, so `json.stringify` does not have a
  special path spelling. If paths need a JSON form, that is a separate decision.
