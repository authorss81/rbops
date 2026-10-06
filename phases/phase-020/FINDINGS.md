# phase-020 — FINDINGS

Work that belongs to another phase. Nothing here was done, because AGENTS.md §1
rule 7 says another phase's work is recorded rather than smuggled into this one,
and rule 8 says not to widen scope. Each item is anchored to a file:line that was
actually read.

## 1. The two VMs disagreed about what a program is worth — **fixed here**

This is the one item that *was* fixed, and fixing it is a deliberate departure
from the phase's declared `must_touch: ["tests/"]`. It is called out here because
the decision belongs to the auditor.

```
$ cargo run --bin rb -- run /dev/stdin   # conceptually:
set t to 5
say t
t
  tree-walking VM: Ok("5")
  bytecode VM:    Ok("nothing")
```

`src/bytecode/vm.rs:916` threw the last frame's value away unless the frame was a
*call*, so the top-level frame — which is not a call — always answered `nothing`.
`src/vm.rs:397` (`Vm::run`) keeps the value of its last statement, so the two
disagreed on every program ending in a bare expression.

Two further leaks became visible the moment the value stopped being discarded:

- `src/bytecode/vm.rs:1526` — `SET_PROPERTY` popped the value but not the
  receiver, though `docs/BYTECODE.md:180` says it "pops a value and an object"
  and that "a statement leaves nothing behind". A program ending in
  `set r.a to 2` was worth a record.
- `src/bytecode/codegen.rs:104` — `statements` treated the last statement of
  *every* block as value-bearing, so `if n is 1 then / 7 / end` left `7` on the
  enclosing frame's operand stack. A block statement is worth nothing whatever
  its body produced.

All three are fixed, in 22 lines and 54 lines respectively, and each fix is
mutation-checked (see `REPORT.md`). The reason it is in this phase: the
definition of done is a *differential* harness, and a harness that cannot
compare what a program is worth on both VMs is not a differential harness. The
alternative was to route around the divergence — compare printed lines only — and
a corpus that routes around a divergence has not tested it.

This matters for S3 specifically: two VMs that disagree about a program's value
make a byte-identical fixed point vacuous, because "identical" would then have
two meanings.

## 2. `Expr::InterpolatedText` is unreachable from Redblue source

`src/parser.rs:56` declares the variant; `src/vm.rs:830`, `src/analyzer.rs:388`,
`src/linter.rs:373`, `src/formatter.rs:542` and `src/bytecode/codegen.rs:525` all
handle it. **No parser path constructs it.** `say "n is {n}"` prints `n is {n}`
with the braces intact, and `examples/hello.rb:12` does exactly that:

```
$ printf 'set n to 2\nsay "n is {n}"\n' > /tmp/i.rb && cargo run -q --bin rb -- run /tmp/i.rb
n is {n}
```

`AGENTS.md` §2 lists "trailing-comma and `{interp}` string syntax" as an
invariant, so this is a **spec drift**: `SPEC.md` and `examples/hello.rb` promise
interpolation and the parser does not do it. It belongs to a grammar phase, not to
a test-harness phase, and the corpus deliberately records the *actual* behaviour
rather than the promised one — a corpus is a record of what the interpreter does,
and a phase that "fixed" it would change 264 recorded expectations.

Note that `tests/bytecode_test.rs:1373` already records the variant as
unreachable, so this is known, not new. What is new is that it is a documented
invariant that does not hold.

## 3. `<`, `>`, `<=`, `>=` and `!`/`&&` are lexed as errors

`src/lexer.rs:142` declares `TokenKind::Less` and `Greater`, and
`src/parser.rs:1250`+ consumes them — but the lexer never produces them:

```
$ printf 'say 1 < 2\n' > /tmp/l.rb && cargo run -q --bin rb -- run /tmp/l.rb
Error: LexerError: Unexpected character '<'
$ printf 'say 1 is less than 2\n' > /tmp/l2.rb && cargo run -q --bin rb -- run /tmp/l2.rb
Error: AnalyzerError: Unknown variable 'less' (Unknown variable 'than')
```

`docs/GRAMMAR.md` §1.5 lists all of them (`<`, `<=`, `>`, `>=`, `&&`, `!`, and
`is less than` as spelled words). So is any of the six comparison or logical
operators the spec promises. The corpus uses `is`, `is not`, `and`, `or` and
`not`, which is what the interpreter actually accepts.

A grammar phase, not a test phase. Recorded with the line numbers so it does not
have to be re-found.

## 4. Trailing tokens on a line are silently accepted

```
$ printf 'say 1 2 3\n' > /tmp/t.rb && cargo run -q --bin rb -- run /tmp/t.rb
1
```

`say 1 2 3` prints `1` and the *program* is worth `3`. `docs/GRAMMAR.md` puts one
statement on a line, so `2` and `3` should be refused. This is a grammar question
rather than a divergence — both VMs agree on the wrong answer — and fixing it
would change what programs parse, so it needs a phase that says so.

## 5. `give back` inside a conditional does not return, so recursion cannot terminate

```
to down(n)
    if n is 0 then
        give back 0
    end
    give back down(n - 1) + 1
end
say down(3)
  → RuntimeError: Maximum call depth of 1000 reached while calling 'down'
```

`src/bytecode/vm.rs:1560` documents the bytecode half of it ("`return` is an
ordinary statement in Redblue, not an escape") and both VMs agree, so no
differential harness can catch it: it is a limitation of the language, not a
divergence. The consequence for this phase is that the `functions` corpus family
cannot contain a *terminating* recursion — only iteration-as-recursion (a function
called from a loop) and a closure returned from a closure, which is what it holds.
Both VMs do have a call-depth limit and both stop at the same one.

A `give back` phase. Pre-existing on the tree-walking VM.

## 6. A module's functions are unreachable from Redblue source

`modules/MathUtils.rb` declares `to circle_area(radius)`, and
`examples/` never calls it. `MathUtils.circle_area(5)` does not resolve. Carried
from `phases/phase-019/FINDINGS.md` §5, unchanged here: it is a module-phase
concern and it is not a divergence.

## 7. The documented standard library is unreachable, so the corpus is narrower than the language

`src/stdlib.rs` registers ~30 builtins (`abs`, `uppercase`, `split`, `map`,
`reduce`, …). Only `length` and `type_of` are callable from Redblue source in the
language as it stands, which is why the `stdlib` family holds those two and
nothing else. "The corpus proves the two VMs agree" is therefore a claim about the
subset of the language that works. Carried from `phases/phase-019/FINDINGS.md`.

## 8. `break` and `skip` are no-ops

```
set i to 0
repeat 3 times
    set i to i + 1
    break
end
say i        → 3, not 1
```

`src/bytecode/vm.rs:1505` and `:1511` both say so outright. Both VMs agree, so the
differential harness cannot catch it either.

## 9. `rbops/verify.sh` is not present in this checkout

There is no `rbops/` directory at all — only `.github/workflows/ci.yml`, which is
off limits to this phase. The task instructions also say the pipeline that
dispatched the phase lives outside the checkout and is not to be inspected, so it
could not be recovered from there. The fourth gate therefore **was not run**, and
`REPORT.md` says so rather than claiming it passed. In its place the
backwards-compatibility check `AGENTS.md` §2 names was run: all eight
`examples/*.rb` and `modules/*.rb` run clean, and the whole pre-existing suite
still passes.

The auditor should decide whether `verify.sh` is expected to be vendored into the
checkout. If it is, its absence is an infrastructure defect that will silently
skip a gate on every phase in this pipeline.
