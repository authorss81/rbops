# phase-020 — findings

Defects and limits found while building the differential + property harness.
Each is anchored to a file and line so the auditor can turn it into a phase.
Nothing here was fixed unless the report says so.

## 1. `must_touch` departure — the two VMs disagreed about what a program is worth

The phase declares `must_touch: ["tests/"]`. Four changes landed in `src/`
anyway, because no harness confined to `tests/` can state the property the phase
exists to state. Each is small and each is mutation-checked in `REPORT.md`.

1. `src/bytecode/vm.rs:989` — `unwind_frame` discarded the outermost frame's
   value, so a program ending in a bare expression was worth `nothing` on the
   bytecode VM and worth its expression on the tree-walking VM.
2. `src/bytecode/codegen.rs:131` — `statements` treated the last statement of
   *every* block as value-bearing, so `if 1 is 1 then 7 end` left `7` on the
   operand stack for the frame above.
3. `src/bytecode/vm.rs:1610` — `SET_PROPERTY` popped the value but not the
   receiver it had loaded, so a program ending in `set r.a to 1` was worth that
   record. Invisible while (1) discarded the frame, which is why it sat there.
4. `src/vm.rs:170` — a runtime failure was reported at its statement's own
   column; a compiled instruction carries a line and no column
   (`docs/BYTECODE.md`), so the two engines reported one failure at two places.

The alternative was a harness that compares printed lines only. That is a
differential test that routes around a divergence and calls the routing a
property. For S3 it is not cosmetic: two VMs that disagree about a program's
value make "byte-identical" mean two different things.

A fifth change landed in `src/bytecode/codegen.rs:396` — see §11, which is a
reachable panic rather than a wrong answer.

Additive constructors added so a caller could build a reproducible VM at all:
`Vm::with_limits` (`src/vm.rs:391`), `BytecodeVm::with_limits`
(`src/bytecode/vm.rs:575`), `run_isolated_with` (`src/vm.rs:129`). None changes
a default; `new()` still reads `REDBLUE_MAX_*`.

**The manifest should be widened to `["tests/", "src/"]` for this phase.**

## 11. An `object` written inside another `object`'s body panicked the bytecode VM — **fixed here**

Reproduced, and fixed in `src/bytecode/codegen.rs:396`. Recorded here because the
repro is worth keeping:

```
$ cat corpus/objects-0019.rb
object Outer
    has tag default "o"
    object Inner
        has x default 1
    end
    say "after inner"
end
say Outer.tag
```

```
$ cargo test --test differential_test edge_regenerating
thread '…' panicked at src/bytecode/vm.rs:1026:14:
an object declaration being assembled
```

`object Inner` inside `Outer`'s own body is accepted by the analyzer and runs on
the tree-walking VM: `declare_object` (`src/vm.rs`) collects the `has` and
`to can` of the body, registers the type, binds it, and only then runs the rest of
the body in the enclosing scope. The bytecode VM kept one `pending_object`, so an
inner `DEF_OBJECT` overwrote it and the outer frame reached for a declaration
that was gone.

**Why the fix is in the lowering and not in the slot.** A `Vec` of pendings would
stop the panic and leave a worse bug: the inner type would finish *first*, so
`object Child extends Base` written inside `Base`'s body would fail with
`Object 'Child' extends 'Base', which is not declared` on one VM and succeed on the
other — a divergence rather than a crash. An `object` body now compiles as two
halves: the `has` and `to can` go into the block that assembles the type, and
everything else compiles into the enclosing block, after the `STORE` that binds
it. That is the tree-walking VM's order, so by the time a nested `DEF_OBJECT` runs
the enclosing type is registered — the parent is there to extend — and nothing is
overwriting a pending. The single `Option` is then correct rather than lucky.

No prior test in the tree held such a program: the pre-existing differential
corpus in `tests/bytecode_vm_test.rs` has no `object` nested in an `object`, and
this phase's generator did not produce one until the `objects` family grew three.
Three programs now pin it — `corpus/objects-0019.rb` (plain),
`corpus/objects-0020.rb` (read back through `type_of`) and
`corpus/objects-0021.rb` (`extends`-ing the type it is written inside, which is
the case a pending-`Vec` fix would have broken) — and restoring the single-block
compile makes four tests fail.

## 2. `either` is documented and does not work

`docs/GRAMMAR.md` §1.3 lists `either` among the keywords. It is neither an
operator nor a statement:

```
$ say either yes or no
Error: AnalyzerError: Unknown variable 'either'   # src/analyzer.rs
$ say (either yes or no)
Error: ParserError: Expected RightParen but got YesNo(true)   # src/parser.rs
```

The first form lexes `either` as an identifier and the analyzer refuses it; the
second is a parse error. Either is a language defect: `SPEC.md` and the grammar
both promise the form. Found by the typed grammar's `YesNo` arm; the arm now
emits `or` and says why.

## 3. 23 of the 25 registered builtins cannot be called from Redblue source

`src/stdlib.rs:14` registers `abs`, `floor`, `uppercase`, `split`, `push`,
`is_number`, `map`, `filter`, `reduce`, `sqrt`, `pow`, `sin`, `cos`, `tan`,
`log`, `exp`, `ceil`, `round`, `lowercase`, `trim`, `join`, `contains`,
`starts_with`, `ends_with` as globals. `src/vm.rs` resolves a call through
`src/runtime.rs:263`, which handles only `say`, `length`/`len`, `input`/`ask`,
`random`, the `files_*`/`time_*`/`json_*`/`csv_*`/`network_*` module functions,
`expect`/`assert`, `console_*`, `random_number`, `random_choice`,
`random_shuffle` and `type_of`.

So `say abs(-3)` is `RuntimeError: Unknown function 'abs'` while
`src/stdlib.rs:120` implements it. The corpus's `stdlib` family therefore covers
only `length` and `type_of`. `AGENTS.md` §"Standard Library" documents all 23.

## 4. No comparison operator lexes, so there is no `while` in the corpus

`docs/GRAMMAR.md` §1.5 documents `<`, `>`, `<=`, `>=`, `is less than`,
`is less than or equal to`, `is greater than`, `is greater than or equal to` and
`in`. None is in `src/lexer.rs`'s keyword table; `<`, `>`, `<=`, `>=`, `==`, `!=`
and `in` are all `LexerError`s or `ParserError`s in the `malformed` corpus
family. `AGENTS.md`'s own first example (`if count is greater than 10 then`) does
not parse. Every loop in the corpus is therefore a counted one.

## 5. `\u` escapes are dropped rather than refused

A `\uXXXX` escape is dropped from the text it appears in rather than being
decoded or rejected, so a combining mark cannot be written in source and a
mistyped escape is swallowed silently. This is why the `unicode` family has no
combining-mark case.

## 6. `length` counts bytes, not characters

`src/runtime.rs:274` uses `s.len()`. `length("héllo")` is 6, `length("👋")` is 4.
The `unicode` family pins the current behaviour rather than the documented one;
if it is a defect, it is a defect in the spec too.

## 7. Trailing tokens on a line are silently accepted

`say 1 2 3` prints `1` and is worth `3`. The `malformed` family holds it as the
current behaviour.

## 8. `while` is parsed but has no corpus coverage

`while` appears in `src/parser.rs` and in `AGENTS.md`'s block-opener list, but with
no comparison operator (§4) a `while` condition can only be a literal, so the
corpus holds none. Not a defect on its own; recorded so the next auditor does not
re-derive it.

## 9. `rbops/verify.sh` is not present in this checkout

The phase's fourth gate cannot be run: there is no `rbops/` directory here at
all, and the task instructions say the pipeline that dispatched this phase lives
outside the checkout and is not to be inspected. The three gates that do exist
(`cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`) were run and
are green; `AGENTS.md` §2's backwards-compatibility check (`examples/*.rb` and
`modules/*.rb`) was run in its place and all eight files run clean.

## 10. A property harness cannot see a defect both VMs share

Eight of the ten findings above are limitations the two VMs agree on, which is
exactly the class a *differential* harness is blind to. They were found by
reading, and by the grammar's own typedness invariant tripping over `either`
(§2) and over an arm that mixed a number into a text. That is the shape of the
blind spot: a green differential gate says the two VMs agree, not that they are
right. §1 and §11 are the two it *could* see, and §11 only because the `objects`
family grew three programs rather than the harness discovering them on its own —
the generated grammar produces no `object` declarations at all, which is the
sharpest limit of this phase and the obvious next thing to extend.