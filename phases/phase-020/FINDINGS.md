# FINDINGS — phase-020

Findings this phase did **not** fix. Each one is anchored to a file:line that was
read, not inferred. The auditor should turn these into phases; a phase that fixes
one of them should say which numbered finding it is closing.

---

## §1 — The bytecode VM threw away what a program was worth (FIXED here, but it is a `must_touch` departure)

Three defects in `src/bytecode/`, all of them invisible while the top-level frame
discarded its own value:

| Where | Defect |
|---|---|
| `src/bytecode/vm.rs:904` | The outermost frame's leftover value was dropped unless the frame was a *call*, so `run` answered `nothing` for every program ending in an expression, while `src/vm.rs:397` keeps the value of the last statement. |
| `src/bytecode/vm.rs:1516` | `SET_PROPERTY` popped the value but not the receiver. `docs/BYTECODE.md:180` says it "pops a value and an object". |
| `src/bytecode/codegen.rs:147` | `statements` treated the last statement of *every* block as value-bearing, so `if n is 1 then / 7 / end` left `7` for the enclosing frame. |

### §1a — a nested `object` panicked the bytecode VM (FIXED in review round one, same departure)

A fourth `src/bytecode/` defect, found by the reviewer rather than by the harness,
and of the same kind: a program the tree-walking VM runs and the analyzer accepts
was a **panic** on the bytecode VM.

```
object Outer
has a default 1

object Inner
has b default 2
end
end

say Outer.a
```

```
thread 'main' panicked at src/bytecode/vm.rs:941:14:
an object declaration being assembled
```

`src/vm.rs:1042` runs a nested `object` in the enclosing scope *after* the
enclosing type is registered, and the bytecode VM kept a single
`pending_object: Option`, so the inner body took it and the outer body asserted
on a declaration that was gone. Fixed in the lowering rather than in the slot: an
object body is two halves, and only the `has`/`to can` half compiles into the
block that assembles the type (`src/bytecode/codegen.rs`, `Declared`). The other
half compiles into the enclosing block, after the `STORE`, which is the
tree-walking VM's order — so a nested `object Child extends Outer` finds the
`Outer` it extends, and no declaration is overwritten while it is being built.
`corpus/objects-0017.rb` and `corpus/objects-0018.rb` hold both shapes.

**Recorded as a finding because of the placement, not the content.** This phase
declares `must_touch: ["tests/"]` and I changed `src/`. No change confined to
`tests/` can make `tree_walk == bytecode` hold on a program ending in an
expression while the two VMs disagree about what that program is worth. The
alternative was to compare printed lines only — a differential harness that
routes around a divergence and calls the routing a property. For S3 that is not
cosmetic: two VMs that disagree about a program's value make a byte-identical
fixed point vacuous, because "identical" would have two meanings.

None of the three changes a `.rbc` byte: `Opcode::ALL` is untouched and the
byte-value assertions in `tests/bytecode_test.rs` still pass.

### §1b — a fourth `src/` change, in review round two (FIXED here, same departure)

`Vm::new()` and `BytecodeVm::new()` resolve `REDBLUE_MAX_CALL_DEPTH`,
`REDBLUE_MAX_STEPS` and `REDBLUE_MAX_ITERATIONS` from the environment, and the
three `with_max_*` constructors next to them each replace **one** limit and leave
the other two to the environment — so a caller that has to be reproducible had no
way to be. The differential harness was such a caller: it built both VMs with
`new()`, so a `REDBLUE_MAX_STEPS=1` left over in the environment would have made
every corpus program fail differently and the golden files would have meant
whatever that machine said.

`Vm::with_limits` and `BytecodeVm::with_limits` set all three at once. Both are
additive, neither changes a default, and a caller that builds a VM with `new()`
still reads `REDBLUE_MAX_*` exactly as before — `call_depth_test.rs` and
`loop_bounds_test.rs` pin that and still pass.

## §2 — There is no comparison operator that lexes

`docs/GRAMMAR.md:95-98` documents `is less than`, `is greater than`,
`is less than or equal to`, `is greater than or equal to` and the `docs/GRAMMAR.md:375-381`
section adds `is equal to`, `==`, `!=`, `in`. None of them is implemented:

- `say 1 < 2`, `say 2 > 1`, `say 1 <= 1`, `say 2 >= 3`, `say 1 == 1` all fail in
  the **lexer**: `Unexpected character '<'` / `'<'` / `'>'` / `'<'` / `'='`.
- `while n is less than 3 do` fails in the **analyzer**: `Unknown variable
  'less'` — `is less than` lexes as the identifier `less` and then the
  identifier `than`.
- `say 1 in [1, 2]` fails in the **parser**: `Unexpected token In`.

Only `is`, `is not`, `and`, `or`, `not` survive. The consequences are large:

- **`while` is unusable.** It has no condition that can express a bound, so the
  only programs it could head are unbounded. The corpus therefore cannot contain
  a single bounded `while`, and `generator::statement` cannot emit one either —
  `edge_the_generator_emits_every_statement_form_it_lists` asserts that no `while`
  is generated, precisely so a future fix has to remove that assertion.
- `AGENTS.md`'s own example, `if count is greater than 10 then say "Hello"`,
  does not parse. So does `SPEC.md`'s and `docs/GRAMMAR.md:472`'s
  (`if age is greater than 18`).
- `docs/GRAMMAR.md:481`'s `for each i from 1 to 10` is refused by the parser:
  `Expected In but got From`. `for each` takes a list and nothing else.

## §3 — Six comparator word-forms the grammar documents but the parser has not got

Distinct from §2 in that these are single tokens rather than multi-word phrases:
the grammar lists `is equal to`, `==`, `!=` and `in` alongside the four
relational word-forms. The corpus pins the *current* behaviour, which is a clean
rejection, in `corpus/malformed-0020.rb` … `corpus/malformed-0022.rb` and
`corpus/labels-0002.rb`, `corpus/labels-0007.rb`, `corpus/labels-0008.rb`.

## §4 — Trailing tokens on a line are silently accepted

`say 1 2 3` prints `1` and is worth `3`. `set x to 1 2 3` is worth `3` and binds
nothing visible. `src/parser.rs` takes the expression and drops whatever follows
on the line rather than refusing it. A program with a typo on the end of a line
is a program that does something other than what it says.

Pinned at `corpus/malformed-0027.rb` and `corpus/labels-0004.rb`.

## §5 — `give back` inside a conditional does not return

`to f(n) / if n is 1 then / give back 1 / end / give back 2 / end / say f(1)`
prints `1` and carries on. So a genuinely recursive function cannot be written
at all: the only shape available is iteration spelled as recursion, which the
`functions` family uses instead. This is why the corpus's nesting/recursion row
is not covered by a real recursion case.

## §6 — A closure declared inside a function is not reachable outside it

`to outer(n) / to inner(m) / give back n + m / end / end / set i to inner(n) /
say i(1) / end / say outer(4)` gives `RuntimeError: Unknown function 'i'`. A
function value bound inside a body does not survive as a value the way
`set g to inc` does at the top level (`corpus/functions-0004.rb`,
`corpus/functions-0005.rb` pin the version that works).

## §7 — 23 of the 25 registered builtins cannot be called from Redblue source

`src/stdlib.rs` registers `uppercase` at line 36 and `length` at line 61, but
`say upper("abc")` and `say uppercase("abc")` both give
`RuntimeError: Unknown function`. Only `length` and `type_of` are reachable.
The corpus's `stdlib` family therefore covers two functions and the finding rows
for the rest of the standard library cannot be written down.

## §8 — `catch` binds the word `error`, not the caught value

`try / say 1 / 0 / catch e / say e / end` prints `error`. `try / say xs[9] /
catch err / say err / end` also prints `error`. The caught value is not bound
anywhere the program can read, so a `catch` can say *that* something failed and
nothing about *what*. `src/bytecode/vm.rs`'s `TRY` handler does push "the failed
value" (see `docs/BYTECODE.md:265-270`) but binds the text `error` in its place.

## §9 — `rbops/verify.sh` is not present in this checkout

There is no `rbops/` directory at all. The fourth gate could not be run. What was
run in its place is the backwards-compatibility check `AGENTS.md` §2 names, over
`examples/*.rb` and `modules/*.rb` — all eight pass, which matters here because
three files in `src/bytecode/` changed. See `REPORT.md`'s Gates table.

## §10 — A parser reports EOF at line N+1 for an N-line file

`corpus/control-flow-0003.rb`, `corpus/control-flow-0010.rb` and
`corpus/malformed-0002.rb` are all reported at one line past their own end with
`Expected End but got Eof`. This is a defensible convention rather than a defect,
so `edge_every_recorded_failure_points_at_a_line_of_its_own_program` grants the
exemption to that one case and nothing else, and asserts that at most 5 of the
corpus's failures use it (in fact 3 of 73 do).

## §11 — `length` counts bytes, not characters

`length("日本語")` is 9 and `length("👩‍💻")` is 11. Recorded, not changed: a
cor program's natural reading is that a string's length is its characters. See
`corpus/unicode-0002.rb` and `corpus/unicode-0005.rb`.

## §12 — `\u` escapes are not supported and a backslash before them is dropped

`say "a\u0000b"` prints `au0000b`; `say "e\u0301"` prints `eu0301`. `\\`, `\"`,
`\n` and `\t` all work. So a combining mark cannot be written in source at all,
and a typo in an escape is silently swallowed rather than refused.
## §13 — `skip` and `break` are accepted and do nothing

`docs/GRAMMAR.md:254-255` gives both, and `src/vm.rs:680` and `:684` are two
`TODO: Implement proper control flow` that answer `Value::Nothing`:

```
set total to 0
for each x in [1, 2, 3]
if x is 2 then
break
end
set total to total + x
end
say total
```

prints `12`, not `6`. The same program with `skip` also prints `12`, so neither
statement leaves the loop it is written in — and `skip <expression>`, which the
grammar allows, discards the expression as well. `corpus/loop-forms-0017.rb` pins
the current behaviour; both VMs agree on it, which is why it is a finding here
and not a divergence.

## §14 — An `object` declared inside another object's body cannot be named

The nested declaration of §1a is registered and bound at runtime, and a program
cannot read it back:

```
object Outer
has a default 1

object Inner
has b default 2
end
end

say Inner.b
```

gives `AnalyzerError: Unknown variable 'Inner'`. `src/analyzer.rs:276` declares
the name and then pushes the body's scope, so the binding dies with the scope even
though `declare_object` bound it for real. The nested type is therefore writable
but not readable — which is also why `corpus/objects-0017.rb` says `say Outer.a`
and nothing more: it is the most a program can say about it. Either the analyzer
should hoist the name the way the VM binds it, or the parser should refuse a
nested `object` outright rather than accept a declaration nothing can name.

## §15 — A runtime failure names a line, not a column

`Error::render` draws a caret under `span.column`, and for a **runtime** failure
that column is now always 1 on both engines — see §1c of `REPORT.md` for why
that had to be settled. So the caret for

```
for each i in [1, 2, 3]
    say i / 0
end
```

sits under the first character of the line rather than under the `say`, and the
position in a `#position` directive carries no more about a runtime failure than
the line it is on.

Two ways to do better, both refused here rather than left unmentioned:

1. **Report the failing *expression* rather than the statement.** The tree-walking
   VM has the spans: `evaluate` would have to push `expr.span` the way
   `execute_statement` pushes `stmt.span`, so `say xs[9]` would fail at the
   index rather than at the `say`. That is a better answer and it costs nothing
   on this side — but `src/bytecode/vm.rs` could not match it, because one
   bytecode instruction carries one line and no column (`docs/BYTECODE.md`), and
   the same fix on both sides needs the format to change.
2. **Put a column in the format.** `Instruction` is 13 bytes on the wire
   (`src/bytecode/format.rs`), so a column is a seventeenth byte on every
   instruction of every `.rbc`. That changes the bootstrap ladder's S1 artifact,
   which is the one thing this phase's format claims it has not done.

Until then the honest statement is the one the harness now asserts: a runtime
failure names its line on both engines, and a frontend failure names its token's
line *and* column.
