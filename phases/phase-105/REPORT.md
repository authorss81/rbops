# Phase 105 — Round out data formats: CSV writer, JSON Lines, TOML and archives

## Finding reproduced

```bash
printf 'say csv.stringify([["a,b", "x"]])\n' > target/tmp/p105/repro.rb
./target/debug/rb run target/tmp/p105/repro.rb
```

Before the change:

```text
Error: RuntimeError: Module 'csv' has no function 'stringify'
```

The failing test `csv_writer_quotes_a_comma_a_quote_a_newline_and_space` was
written first and failed with the same refusal before `src/formats.rs` existed.

## What changed

| File | Lines | What |
|---|---|---|
| src/formats.rs | +1207 | CSV writer, JSON Lines, TOML subset reader, zip stored writer/reader, tar USTAR writer/reader, CRC32 |
| src/lib.rs | +1 | registers `formats` |
| src/runtime.rs | +92 | dispatches `csv_stringify`, `json_parse_lines`, `json_stringify_lines`, `toml_parse`, `zip_write`, `zip_read`, `tar_write`, `tar_read` |
| src/stdlib.rs | +60 | modules `tar`, `toml`, `zip`; members, builtin names, signatures and effectful calls |
| src/vfs.rs | +14 | `read_bytes` for native and in-memory filesystems |
| src/repl/completer.rs | +10 −2 | completer expectations for the two new JSON members |
| src/repl/editor.rs | +12 −2 | editor expectations for the two new JSON members |
| SPEC.md | +60 −? | CSV quoting, JSON Lines, TOML subset (including what is unsupported), zip/tar behaviour and new section |
| README.md | +12 | the same public surface in the README table |
| SURVEY.md | +83 −? | re-anchored registry counts/citations and records rank 10 closed |
| tests/data_formats_test.rs | +309 | ten tests for the new formats |
| tests/stdlib_module_docs_test.rs | +54 | eight answerable-builtin rows |
| tests/stdlib_module_names_test.rs | +21 | tar, toml and zip module calls |
| tests/stdlib_modules_test.rs | +36 | three tracked `edge_phase105_*` tests for quota and edge coverage |
| tests/doc_blocks_*.txt | +23 −? | SPEC line-key re-anchoring plus one fragment entry for the archive example |

The API is `csv.stringify(rows)`, `json.parse_lines(text)`,
`json.stringify_lines(list)`, `toml.parse(text)`, `zip.write(path, entries)`,
`zip.read(path)`, `tar.write(path, entries)` and `tar.read(path)`. Archive
entries are a record of name to text or byte list; reads return text for valid
UTF-8 bytes and a byte list otherwise. Zip writing uses stored (method 0)
entries, and reading refuses any other method by name, including
`compression method 8 (deflate)`.

## Tests added

| Test | Edge class covered |
|---|---|
| csv_writer_quotes_a_comma_a_quote_a_newline_and_space | malformed input / exact quoting |
| edge_csv_writer_round_trips_through_csv_parse | round-trip, boundaries |
| edge_csv_empty_header_only_whitespace_long_and_bom | empty, singleton, BOM, very long field |
| json_lines_round_trip_and_escape_an_inner_newline | nesting / malformed input |
| edge_json_lines_empty_and_malformed_line | empty, malformed input |
| toml_reader_parses_the_documented_subset | singleton, nesting, duplicate keys |
| edge_toml_malformed_and_bom | malformed input, BOM |
| zip_and_tar_round_trip_the_same_files | boundary, duplicate/missing keys |
| edge_archive_rejects_missing_and_malformed_files | resource limit, malformed input |
| edge_archive_empty_and_empty_entry | empty, singleton |
| edge_no_registered_builtin_is_unreachable_from_a_program | registry reachability |
| edge_every_flat_builtin_the_stdlib_registers_answers | registry dispatch |
| json_dot_offers_the_members_the_registry_holds | completion surface |
| edge_phase105_csv_writer_round_trips_through_the_existing_reader | boundary / round-trip |
| edge_phase105_json_lines_round_trip_and_refuse_a_bad_line | malformed input |
| edge_phase105_toml_refusal_names_the_line | malformed input |

The first ten are in `tests/data_formats_test.rs`; the three `edge_phase105_*`
tests are in the tracked `tests/stdlib_modules_test.rs`; three existing tests
were updated where the JSON member list legitimately grew.

## Edge-case matrix

| Class | Status |
|---|---|
| empty | covered — empty CSV rows, empty JSON Lines, empty archive, empty entry |
| singleton | covered — one cell, one row, one archive entry |
| boundary | covered — header-only CSV, whitespace-only field, very long field |
| out_of_bounds | N/A — no indexed API is added |
| type_mismatch | covered — non-text/byte archive entries and non-list JSON Lines input refuse by name |
| numeric_boundary | N/A — TOML integer/float parsing is covered, but no arithmetic is added |
| unicode | covered — UTF-8 text is preserved; archive bytes that are not UTF-8 return a byte list |
| nesting_recursion | covered — nested arrays/inline TOML tables, nested JSON values, multiple archive entries |
| duplicate_missing_keys | covered — TOML duplicate keys refuse; missing archive entries refuse by name |
| malformed_input | covered — bad TOML line, malformed JSON line, truncated zip/tar, BOM |
| resource_limit | covered — missing archive path and malformed archive refuse cleanly |

## Gates

| Gate | Result |
|---|---|
| cargo fmt --check | pass |
| cargo clippy --all-targets -- -D warnings | pass |
| cargo test --all-targets | pass — 2552 passed, 0 failed |
| rbops/verify.sh phase-105 | pass |

## Invariants touched

- Dotted stdlib calls remain gated by `module_has_member`; the three new modules
  and their members were added to `MODULES`/`MODULE_MEMBERS` in both directions.
- `csv.stringify` output is defined so existing `csv.parse` reads every written
  value back identically, including empty, whitespace-padded and quoted cells.
- Archive readers refuse unsupported zip compression by name instead of
  returning corrupt content.
- TOML refusals are catchable `RuntimeError`s that name the source line.

## Known gaps / follow-ups

- Zip writing is stored-only; deflate writing is not implemented. The reader
  names method 8 rather than decoding it.
- TOML does not support multiline strings, date/time values, `inf`/`nan`, or
  dotted keys that reach through arrays of tables; SPEC.md states this.
- Tar is USTAR only; PAX/GNU long names and sparse files are not handled.
- YAML and XML remain unread and unwritten, recorded under SURVEY.md "Not surveyed".
