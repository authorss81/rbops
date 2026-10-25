# Phase 071 — Map the whole environment: `.env`, `.types`, `.dir`, `.typehints`

## What changed

| File | Lines | What |
|---|---|---|
| src/interpreter.rs | +139 −0 | Read-only accessors for imported modules, module members, declared object fields/methods, and shape-based object recognition |
| src/repl/commands.rs | +44 −0 | `env`/`environment`, `types`, `dir <expression>`, `typehints` command table entries |
| src/repl/mod.rs | +823 −1 | Live session listings and `.dir` answer, plus the environment-map tests |

## Reproduction

Before the change, each command was rejected as an unknown word:

```
$ printf '.env\n.types\n.typehints\n.dir 1\n.quit\n' | target/debug/rb
>>> Unknown command 'env'. Type :help for available commands.
>>> Unknown command 'types'. Type :help for available commands.
>>> Unknown command 'typehints'. Type :help for available commands.
>>> Unknown command 'dir'. Type :help for available commands.
```

## Tests added

| Test | Edge class covered |
|---|---|
| environment_has_session_import_and_builtin_sections | live session binding + imported module member + builtin, asserted per section |
| edge_environment_on_a_fresh_session_names_empty_sections | empty / zero / nothing |
| edge_importing_does_not_duplicate_session_rows | duplicate rows; state before and after an import |
| types_names_the_record_shape_and_dir_lists_its_fields | singleton shape; field kinds and values |
| edge_dir_on_a_non_record_omits_the_fields_section | type mismatch (non-record has no fields section) |
| edge_dir_refuses_a_statement_rather_than_describing_it | malformed input / asserts a failure is produced |
| typehints_track_a_rebinding_to_another_type | state change: rebinding updates the row |
| edge_types_with_no_records_bound_is_named_empty | empty / zero / nothing |
| edge_types_renders_a_hundred_field_record_completely | boundary: 100 fields, no silent truncation |
| edge_dir_on_an_object_shows_its_type_fields_and_methods | object fields and methods |
| edge_dir_recognises_an_object_instance_bound_to_another_name | object instance held by a differently named binding |
| edge_dir_recognises_an_object_returned_by_an_expression | object instance reached through a call rather than a bare name |
| edge_types_shows_a_rebound_object_name_by_its_actual_shape | state change: an object type name rebound to a different record |
| edge_typehints_omits_imported_module_placeholders | imported module's internal `Nothing` placeholder is not a user binding |
| the_environment_commands_parse | command spelling and missing argument |

## Edge-case matrix

| Row | Status |
|---|---|
| empty | Covered: fresh `.env` names empty session/imports sections; `.types` names an empty listing. |
| singleton | Covered: one record with two fields is listed with both field kinds. |
| boundary | Covered: a 100-field record renders every field with no truncation notice. |
| out_of_bounds | N/A: the listings index no collection; `.dir` takes an expression and evaluates it through the normal pipeline. |
| type_mismatch | Covered: `.dir` on a number omits the fields section and still shows kind/methods. |
| numeric_boundary | N/A: no arithmetic is added; values are only rendered through the existing `Value` display. |
| unicode | N/A: field names and values are rendered through the existing `Display`; no new text slicing or byte indexing was added. |
| nesting_recursion | Covered: `.types` walks lists and nested records, and object declarations are read from the type table. |
| duplicate_missing_keys | Covered: `.types` deduplicates equal shapes; `.env` counts session rows before and after an import. |
| malformed_input | Covered: `.dir` refuses a statement with an error naming the command and keyword. |
| resource_limit | N/A: all four listings are bounded by the session's existing binding/import/type tables; `.types` does not recurse through cyclic structures because Redblue values are acyclic. |

## Gates

| Gate | Result |
|---|---|
| cargo fmt --all -- --check | pass |
| cargo clippy --all-targets -- -D warnings | pass |
| cargo test --all-targets | pass (2193 passed, 0 failed) |
| rbops/verify.sh phase-071 | pass (2193 tests, 0 failed; all doc examples ran) |

## Invariants touched

- None. Existing commands, values, grammar and file extension are unchanged; the four new commands are additive.

## Known gaps / follow-ups

- `.dir` recognises an object instance by the field shape it carries, because an object declaration binds a record rather than a tagged instance. Two object declarations with exactly the same fields are ambiguous; `.dir` then uses the expression as a hint and otherwise describes the value as a record rather than guessing.
