# phase-005 — findings

Discovered while attaching spans to errors. Not this phase's concern; recorded
so the auditor can promote them.

## 1. `rbops/verify.sh` is not in the repository

`ls` at the project root shows no `rbops/` directory and no `phases/`
directory. `./rbops/verify.sh phase-005` → `No such file or directory`. The
pipeline that dispatches phases must mount its own scripts. Either the
dispatcher should confirm the script is present before running a phase, or
`verify.sh` should be vendored into the checkout. Until then the fourth gate
cannot be executed from inside the project.

## 2. The lexer accepts an unterminated string

`printf 'say "unterminated\n' > t.rb && rb run t.rb` prints `unterminated` and
exits 0. `src/lexer.rs` `read_text` has no terminating-quote check. Severity:
major (silently accepts malformed source). Suggested phase: reject an
unterminated string literal at the position where the quote opened.

## 3. `modules/MathUtils.rb` does not parse

`rb run modules/MathUtils.rb` → `ParserError: Expected function name
--> modules/MathUtils.rb:4:16`, on `constant PI to 3.14159`. `constant` is not
a keyword in `src/lexer.rs` at `HEAD` either (verified with
`git show HEAD:src/lexer.rs | rg -i constant`, no matches), so this is a long
standing gap, not a regression. `AGENTS.md` calls `modules/*.rb` a
specification-by-example; either `constant` should be implemented or the module
rewritten.

## 4. `rb format --check examples/hello.rb` fails at `HEAD`

`cargo build` from a clean `HEAD` and running `rb format --check
examples/hello.rb` prints `File would be reformatted` and exits 1. The
formatter is not idempotent on its own output. Severity: minor for the
language, major for the gate if the gate ever formats examples.

## 5. Caret alignment with wide characters and tabs

`Error::render` (`src/error.rs`) advances the caret by one space per *character*.
On a line containing a wide character (CJK, emoji) the caret therefore prints
one or two terminal columns left of the target. Tabs are echoed verbatim, so a
tab-indented line also drifts. Fixing this needs a wcwidth table and a tab-stop
rule, plus the choice of whether the echoed line is expanded. Out of scope here
because the *position* is correct; only the glyph placement is approximate.

## 6. `rb test` does not render diagnostics

`src/testing/harness.rs::execute_test_code` maps lexer/parser/analyzer/runtime
failures into `TestFailure::Error(e)` and the reporter prints only
`error.message`. A Redblue test file that fails to parse reports the kind and
message but no line, column or caret, while `rb run` now renders all three.
Wiring `Error::render(code, None)` into `TestFailure` would close the gap.

## 7. Expression-level spans

Runtime and analyzer errors are reported at the granularity of the enclosing
statement (`Stmt::span`), because `Expr` carries no position. `say 4 / 0`
reports the `say` token. Giving `Expr` the same `Spanned` treatment as
`Statement` would pinpoint the sub-expression, but it touches the formatter's
`format_expression`, the linter and every `Expr` construction in the parser.

## 8. Runtime errors have no stack of call sites

`Value::Function(name, params)` stores only the name and the parameter names
(`src/vm.rs`, `Statement::Function` arm: "Store function body (simplified —
just store params)"), so a failure inside a function body is reported at the
body's statement and there is no call stack to show. Function bodies are not
even executed. Pre-existing limitation, listed because error diagnostics are
where it becomes visible.