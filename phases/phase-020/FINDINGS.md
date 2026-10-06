# phase-020 — FINDINGS

Five defects in `src/`, found by the harness this phase added rather than by
reading the code. Four were out of this phase's declared area
(`must_touch: ["tests/"]`) and are recorded for the auditor to promote. **§4 is
the exception: it was fixed in round 2**, because the round-2 review asked for
`tree_walk == bytecode` asserted on a program ending in an expression and no
change confined to `tests/` can make that true while the two VMs disagree. Two
further entries are not in `src/`: §4b is three broken arms in the property
generator, and §6 is about the phase contract itself.

Each carries the exact command that reproduces it. Every reproduction is a
program the corpus deliberately avoids generating, because a corpus that
records a missing feature as though it were the specification is worse than a
smaller corpus — with one exception now that §4 is fixed: the `values` family
generates programs that end in a bare expression on purpose, because that shape
is the specification, not the defect.

---

## 1. MAJOR — `return` / `give back` inside a nested block does not return

A `return` inside an `if`, `while`, `repeat` or `for each` evaluates its
expression and then throws the value away. The enclosing function carries on and
returns whatever its last statement produced.

```
$ printf 'to f(n)\n    if n is 0 then\n        give back 1\n    end\n    give back 2\nend\nsay f(0)\n' > /tmp/ret.rb
$ cargo run --bin rb -- run /tmp/ret.rb
2                      <- the function returned 2; it must return 1
```

`return` inside a loop, which is the common case:

```
$ printf 'to g()\n    set i to 0\n    while i is not 3\n        set i to i + 1\n        if i is 2 then\n            return i\n        end\n    end\n    return 99\nend\nsay g()\n' > /tmp/ret2.rb
$ cargo run --bin rb -- run /tmp/ret2.rb
99                     <- the function ran to the end and returned 99
```

Mechanism, two lines of it:

- `src/vm.rs:688` — `Statement::Return(expr) | Statement::GiveBack(expr)` is
  *an expression*, not an unwind: it evaluates `expr` and yields the value.
- `src/vm.rs:586` — `Statement::If` runs the chosen branch with
  `for stmt in then_branch { self.execute_statement(stmt)?; }` and then yields
  `Value::Nothing`, discarding what the branch produced. `Statement::ForEach`
  (`src/vm.rs:609`), `Statement::Repeat` (`src/vm.rs:660`), `Statement::While`
  (`src/vm.rs:673`) and `Statement::Object` (`src/vm.rs:776`) do the same.

So an early return can only work as the *last* statement of a function body.
Everything else — a guard clause, a loop that has found its answer — silently
does the wrong thing.

The bytecode VM has the same shape (`src/bytecode/vm.rs:1572`, `call_named`, and
`Opcode::Return` at `src/bytecode/vm.rs:1152`), and `src/bytecode/codegen.rs:292`
emits the return into the branch's own instruction list with no unwind edge, so
both VMs agree on the wrong answer. The differential corpus cannot catch this:
agreement is not correctness. It was caught by writing `fact` in the obvious
way and watching it recurse to the depth limit.

---

## 2. MAJOR — the registered `Value::Builtin` stdlib is not callable

`abs`, `floor`, `ceil`, `round`, `sqrt`, `pow`, `sin`, `cos`, `tan`, `log`,
`exp`, `uppercase`, `lowercase`, `trim`, `split`, `join`, `push`, `pop`,
`shift`, `map`, `filter`, `reduce`, `is_text`, `is_list`, `to_text`, `to_list`
and others are all registered as globals — and none of them can be called from
Redblue source.

```
$ printf 'say abs(-3)\n' > /tmp/abs.rb
$ cargo run --bin rb -- run /tmp/abs.rb
Error: RuntimeError: Unknown function 'abs'

$ printf 'say uppercase("hi")\n' > /tmp/up.rb
$ cargo run --bin rb -- run /tmp/up.rb
Error: RuntimeError: Unknown function 'uppercase'
```

Mechanism:

- `src/stdlib.rs:22` (and every `globals.insert(... Value::Builtin ...)` after
  it) binds the name to `Value::Builtin("name")`.
- `src/vm.rs:870`, `Vm::call`, asks `runtime::builtin` first, and then matches
  `Some(Value::Function(..))` only. A `Value::Builtin` global reaches the `_`
  arm and becomes `Unknown function '<name>'`.
- `src/bytecode/vm.rs:1572`, `call_named`, has the identical shape, so both VMs
  fail the same way — no divergence, just a stdlib nobody can reach.
- `src/stdlib.rs:210`, `builtin_function`, *is* the implementation, and it is
  never called by either VM. Its only callers are
  `tests/numeric_edge_test.rs:390,395,400` — so `sqrt` has a passing unit test
  and no reachable path from the language.

`runtime::builtin` (`src/runtime.rs:263`) implements a disjoint and much smaller
set by name (`say`, `length`, `type_of`, `input`, `random`, `files_*`,
`time_*`, `json_*`, `csv_*`, `network_*`, `expect`, `assert`, `console_*`).
Everything the contract in `AGENTS.md` lists under *Math Functions* and *Text
Functions* is therefore unreachable, which is also why this phase's corpus
generator had to be restricted to `length` and `type_of`.

---

## 3. MAJOR — `break` and `skip` are no-ops

```
$ printf 'set total to 0\nfor each x in [1, 2, 3]\n    if x is 2 then\n        break\n    end\n    set total to total + x\nend\nsay total\n' > /tmp/brk.rb
$ cargo run --bin rb -- run /tmp/brk.rb
6                      <- the loop ran to the end; breaking at 2 gives 1
```

`src/vm.rs:680` and `src/vm.rs:684`:

```rust
Statement::Break => {
    // TODO: Implement proper control flow
    Ok(Value::Nothing)
}
Statement::Skip => {
    // TODO: Implement proper control flow
    Ok(Value::Nothing)
}
```

`skip` has the same fate — a `for each` that prints every element skipped none.

This is **not** a divergence: the bytecode VM deliberately agrees.
`src/bytecode/codegen.rs:282` emits `Opcode::Break`, and
`src/bytecode/vm.rs:1495` `break_loop` is a no-op whose doc comment says why —
"the two VMs disagreeing about what a program means is worse than a language
feature being unfinished". So the gap is a missing language feature, agreed on
by both implementations, and phase-019 recorded it. It is repeated here because
`AGENTS.md` §3.2 asks for the resource/state row to be justified, and because
this phase's `loop_forms` family has to route around it: its loops are bounded
by a counter, not by `break`, and `tests/common/generator.rs` says so at
`loop_forms`.

---

## 4. MAJOR — FIXED IN ROUND 2 — trailing tokens after an expression are silently accepted, and the two VMs then disagree

```
$ printf 'say 1 2 3\n' > /tmp/trailing.rb
$ cargo run --bin rb -- run /tmp/trailing.rb
1                      <- `2 3` is parsed as two more expression statements

$ cargo run --bin rb -- compile /tmp/trailing.rb -o /tmp/trailing.rbc
$ cargo run --bin rb -- vm /tmp/trailing.rbc
1                      <- same output ...
```

but the two disagree on what the program *returned*, which is what
`rb run`/`rb vm` compare in the harness:

```
tree: Outcome { output: ["1"], result: Ok("3") }
byte: Outcome { output: ["1"], result: Ok("nothing") }
```

The tree-walking VM yields the last expression statement's value as the
program's value; the bytecode VM yields `nothing`. Two implementations of the
same source disagreeing about the program's value is precisely the class of
defect that makes an S3 byte-identical fixed point meaningless, and it is the
one thing this phase's differential runner exists to catch.

The tree-walking half is `src/parser.rs`, whose statement loop keeps consuming
tokens after a complete statement rather than refusing a line that holds two.
`docs/GRAMMAR.md` and `SPEC.md` both put one statement on a line.

### Fixed — the VM half only

The reproduction above is a one-line program ending in a bare expression, which
is well formed on its own line; it is the *value* divergence that is fixed, not
the trailing-token grammar. Three changes, all in `src/bytecode/`:

- `src/bytecode/vm.rs:893` — `unwind_frame` threw the last frame's value away
  unless the frame had been entered by a call. The last frame is not a
  statement, it *is* the program, so its value is what the program is worth —
  the rule `src/vm.rs:397` already applies. `codegen.rs:181` already declined to
  `POP` a trailing expression for this reason; this is where the value it leaves
  is picked up.
- `src/bytecode/vm.rs:1518` — `set_property` popped the value but not the
  receiver, though `docs/BYTECODE.md:180` says `SET_PROPERTY` "pops a value and
  an object" and that a statement leaves nothing behind. The leak was invisible
  while the top-level frame discarded whatever it finished with, and appeared as
  soon as it stopped: a program ending in `set r.a to 2` was worth a record.
- `src/bytecode/codegen.rs:107,145` — only a block whose value is read (`main`,
  `Function`, `Method`) may leave a value behind. `set n to 1 / if n is 1 then /
  7 / end` is worth `nothing`, and `if`'s branch was leaving `7` on the enclosing
  frame's operand stack. The `values` corpus family found this one.

The parser still accepts trailing tokens, which is the remaining half of this
finding and is a grammar question rather than a divergence.

---

## 4b. MINOR — the property generator had three arms that produced broken source

Found in round 2 by `edge_a_generated_program_only_faults_on_a_fault_that_was_injected`,
which asserts the invariant the generator's own doc comment claims: the only
failures in the generated corpus are the ones `random_fault` injected. All three
are recorded because each was invisible for the same reason — a broken arm
produces a *failure*, and every property in `tests/property_test.rs` accepts
failures as outcomes.

- `random_statement`'s conditional arm wrote `if b is yes` with no `then`, so a
  sixth of the generated corpus was a `ParserError` — *"Expected Then but got
  Say"*. The parser requires `then` (`src/parser.rs`, and the `control_flow`
  corpus family writes it).
- `typed_expression`'s `Kind::Text` arm `({left} + " {left}")` spliced
  expression *source* into a quoted literal, so any `left` carrying a quote broke
  the literal open: `(("a b c" + "-") + " ("a b c" + "-")")` is a `LexerError`.
- `typed_expression`'s `Kind::Text` arm `(length(left) + length(left))` returned a
  `Number` against `random_statement`'s contract that `t` holds text, so
  `set t to <lengths>` faulted at `say length(t)`. Text plus a number is itself a
  `RuntimeError`, so the length cannot be folded into a text expression at all.

All three are fixed in `tests/property_test.rs` and all three are
mutation-checked — see REPORT.md §Round 2.

---

## 5. MINOR — documented comparison operators and a `for … from … to` loop do not exist

`SPEC.md:273`, `SPEC.md:277`, `SPEC.md:278`, `SPEC.md:288` and
`docs/GRAMMAR.md:97-98`, `:378`, `:380`, `:472` all document `is greater than`,
`is greater than or equal to`, `>` and `>=`. Neither the word forms nor the
symbols reach the lexer:

```
$ printf 'say 1 > 2\n' > /tmp/gt.rb
$ cargo run --bin rb -- run /tmp/gt.rb
Error: LexerError: Unexpected character '>'

$ printf 'if 1 is greater than 0 then\n    say "yes"\nend\n' > /tmp/gt2.rb
$ cargo run --bin rb -- run /tmp/gt2.rb
Error: ParserError: Expected Then but got Identifier("than")
```

`docs/GRAMMAR.md:481` documents `for each i from 1 to 10`, and
`src/parser.rs:141` carries a `Statement::ForRange` variant for it with the
comment `// for each i from 1 to 10 ... end` — but nothing constructs that
variant (`grep -n ForRange src/parser.rs` finds the declaration and nothing
else), so it is dead code and the documented loop cannot be written. The parser
requires `for each x in <expr>` and no other form
(`src/parser.rs:738`, `Expected 'each' after 'for'`, and the
`self.expect(&TokenKind::In)` at `src/parser.rs:715`).

Either the docs or the parser is wrong. This phase's generators use `is` and
`is not`, which do exist (`tests/test_control_flow.rb:106`).

---

## 6. The phase contract's fourth gate does not exist in this checkout

```
$ ./rbops/verify.sh phase-020
bash: ./rbops/verify.sh: No such file or directory
$ ls
AGENTS.md  Cargo.toml  corpus  docs  examples  modules  phases  src  target  tests  tooling
```

There is no `rbops/` directory in the project checkout at all, and the task
instructions say the pipeline that dispatched this phase lives elsewhere. The
three gates that do exist were run and are green; see REPORT.md §Gates. In the
fourth gate's place the examples and modules are run, which is what AGENTS.md §2
names as the backwards-compatibility check. In their
place the examples and modules were run directly, because `AGENTS.md` §2 names
them as the backwards-compatibility check:

```
$ for f in examples/*.rb modules/*.rb; do rb run "$f" >/dev/null || echo "FAIL $f"; done
```

All 8 run clean.