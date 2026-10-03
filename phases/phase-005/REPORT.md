# Phase 005 — Source spans on every error

## Finding re-verified (reproduction)

`src/error.rs` carried only `String` on every variant, exactly as the phase
evidence claimed. Reproduced before any edit:

```
$ printf 'set x to 1\nsay x +\n' > /tmp/opencode/bad.rb
$ cargo build && ./target/debug/rb run /tmp/opencode/bad.rb
Error: ParserError: Unexpected token Newline
exit=1
```

The offending token is on line 2, column 8, and the output names neither.

Red test written first (`tests/span_test.rs::test_parser_error_reports_line_and_column`),
watched fail with
`parser error must report line:column 2:9, got: ParserError: Unexpected token Newline`,
then made green.

## What changed

| File | Lines | What |
|---|---|---|
| src/error.rs | +125 −10 | new `Span { line, column }`; `Lexer/Parser/Analyzer/Runtime` now carry `(String, Span)`; `Error::span()`, `Error::render(source, file)` draws the source line and a caret; `Display` gained a `  --> line:col` line |
| src/parser.rs | +117 −39 | `Stmt { span, statement }` wrapper; every body is `Vec<Stmt>`; `Parser::span()`; all 18 `Error::Parser` sites pass a span (token position for `expect`/`parse_primary`, current position elsewhere) |
| src/vm.rs | +186 −73 | `current_span` restored around `execute_statement`; `Vm::span()` feeds all 54 `Error::Runtime` sites; `Span` threaded through the free `parse_json*` helpers; `load_module` reads `stmt.statement` |
| src/analyzer.rs | +40 −33 | `errors: Vec<(String, Span)>`; `add_error(msg, span)`; `analyze_expr`/`analyze_statement` carry the owning statement's span; `Error::Analyzer` reports the first error's span |
| src/lexer.rs | +10 −5 | `Token::span()`; the lexer error carries `Span` instead of embedding "at line N, column M" in the message |
| src/lib.rs | +21 −7 | `pub use error::Span`; `run_file_with_diagnostic` + `report` so `rb run <file>` prints the caret diagnostic |
| src/formatter.rs | +3 −3 | statements are read through `Stmt::statement` |
| src/linter.rs | +3 −3 | same |
| tests/span_test.rs | +295 | 15 new tests (file added) |

Post-change output for the reproduction:

```
$ ./target/debug/rb run /tmp/opencode/a.rb
Error: ParserError: Unexpected token Newline
  --> /tmp/opencode/a.rb:2:8
2 | say x +
  |        ^
```

### Why an AST wrapper instead of a `span` field on each variant

`Statement` has 24 variants. Putting a span in each would have touched every
pattern in the formatter, the linter, the analyzer and the VM. `Stmt { span,
statement }` keeps all 24 variants untouched: the parser wraps the single
`Option<Statement>` that `parse_statement` builds, and readers take
`&stmt.statement`. Formatter output is byte-identical (verified by diffing
`rb format` for every `examples/*.rb` against a binary built from `HEAD`).

Spans are statement-granular. An error inside `say 4 / 0` points at `say` on
that line, not at the `/`. Expression-level spans are a follow-up
(FINDINGS.md), not a lie: the line is always the line the statement is on.

### Error arity is compiler-enforced

`Error::Parser(msg)` no longer compiles — `Parser(msg, span)` does. "No error
path constructs a variant without a span" is therefore a type-level property,
not a convention: `rg 'Error::(Parser|Analyzer|Runtime|Lexer)\('` returns 74
constructions, every one of which passes a span.

## Tests added

| Test | Edge class covered |
|---|---|
| `test_parser_error_reports_line_and_column` | failure: location is 2:8, not just a kind |
| `edge_error_on_first_line_points_at_line_one` | boundary (line 1) |
| `edge_error_on_last_line_points_at_the_last_line` | boundary (last line) |
| `edge_empty_source_is_a_valid_empty_program` | empty / zero; smallest malformed input (`end`) |
| `edge_multibyte_column_offsets_are_character_based` | unicode: emoji before the error; column counts characters (10), not bytes (offset 12) |
| `test_lexer_error_carries_position` | failure + boundary: lexer error, 2:10 |
| `edge_runtime_error_reports_the_statement_position` | runtime span on line 3 after a blank line |
| `edge_runtime_error_inside_a_loop_reports_the_inner_statement` | nesting: loop body span, not the `for` line |
| `test_analyzer_error_carries_position` | failure: analyzer span + names the missing variable |
| `test_render_draws_source_line_and_caret` | the four diagnostic lines, asserted exactly |
| `edge_render_without_a_file_omits_the_file_name` | boundary: `file = None` |
| `edge_render_of_a_span_past_the_last_line_still_reports_the_location` | malformed input: unclosed `if` → span 4:1 with no line 4; location kept, caret omitted |
| `test_io_error_has_no_span` | failure: `Io` has no position by design |
| `edge_unknown_span_renders_message_only` | empty/`nothing` case: `Span::unknown()` degrades to message only |
| `test_every_failed_program_reports_a_position` | 7 malformed inputs, each must carry a span |

15 tests, 9 named `edge_*`, all asserting a value or a failure kind.
Zero `#[ignore]`, zero `// skip`, zero `allow(clippy::`.

### Mandatory edge-case matrix

| Row | Status |
|---|---|
| empty | covered — `edge_empty_source_is_a_valid_empty_program`, `edge_unknown_span_renders_message_only` |
| singleton | covered — the smallest malformed input (`end`) is a one-token program |
| boundary | covered — first line, last line, past-the-last-line (EOF) span, no-file-name render |
| out_of_bounds | N/A — no indexing was added; the only index touched is `source.lines().nth(span.line - 1)`, which is guarded by `Option` and tested by the EOF-span test |
| type_mismatch | N/A — error *types* are unchanged; `Io` keeps its old shape and is asserted to have no span |
| numeric_boundary | N/A — spans are `usize` line/column counters produced by the existing lexer; `line - 1` is guarded by `is_known()` (`line > 0`) |
| unicode | covered — `edge_multibyte_column_offsets_are_character_based` (4-byte emoji; char column vs byte offset) |
| nesting_recursion | covered — `edge_runtime_error_inside_a_loop_reports_the_inner_statement` |
| duplicate_missing_keys | N/A — no record key handling touched |
| malformed_input | covered — `edge_empty_source_is_a_valid_empty_program`, `edge_render_of_a_span_past_the_last_line…`, `test_every_failed_program_reports_a_position` |
| resource_limit | N/A — no new allocation, recursion or output; `render` allocates one copy of the failing line |

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass |
| `cargo test` | 46 passed, 0 failed (15 of them new) |
| `./rbops/verify.sh phase-005` | **not run — `rbops/verify.sh` does not exist in this checkout** (no `rbops/` and no `phases/` directory; the pipeline that dispatched this phase lives outside the repository). Substitute evidence run by hand instead: `rb run` over every `examples/*.rb` → 0 failures; `rb lint` over `examples/*.rb` and `tests/*.rb` → 0 failures; `rb test tests/test_arithmetic.rb` → 4/4 pass; `rb format` output byte-identical to a `HEAD` build. |

Pre-existing failures that this phase did **not** introduce and did not touch:
`modules/MathUtils.rb` fails to parse (`constant` is not a keyword at `HEAD`
either — `git show HEAD:src/lexer.rs | rg -i constant` is empty), and
`rb format --check examples/hello.rb` reports "File would be reformatted" at
`HEAD` too. Both are in FINDINGS.md.

## Invariants touched

- `Error` keeps the variants `Lexer/Parser/Analyzer/Runtime/Io`. Their *arity*
  changed: the four positioned variants now carry a `Span`, and `Span` is
  exported as `redblue::Span`. This is the change the phase asked for; there is
  no way to attach a position without changing the variants.
- `Statement` is unchanged. Statement lists are now `Vec<Stmt>`; `Stmt` is a
  new public type in `redblue::parser` that pairs a statement with its span.
- Unchanged and re-checked: `.rb` extension, `end` terminators, `set x to …`,
  `say`, the `Value` variants, trailing-comma and `{interp}` strings, all
  pre-existing tests, formatter output, linter behaviour, every example.
- New user-visible behaviour: `Error`'s `Display` now has a second
  `  --> line:col` line, and `rb run <file>` prints the source line plus a
  caret. Any consumer that compared the full `Display` string byte-for-byte
  sees the extra line; `contains`-style checks are unaffected.

## Known gaps / follow-ups

All of these are in `phases/phase-005/FINDINGS.md`.

- Expression-level spans: a runtime error points at the statement, not the
  offending sub-expression.
- The caret counts characters, so it is visually short of the target when the
  line contains wide characters (CJK, emoji). No wcwidth table.
- Tabs are echoed verbatim, so the caret drifts on tab-indented lines.
- `rb test` still reports a failing file with the bare message; only `rb run`
  renders the caret.
- The lexer accepts an unterminated string (`say "abc` runs and prints `abc`).
- `modules/MathUtils.rb` does not parse (`constant` unsupported) — pre-existing.
- `rb format --check examples/hello.rb` fails — pre-existing formatter
  idempotency bug.
- `rbops/verify.sh` is absent from the repository, so the fourth gate could not
  be executed here.