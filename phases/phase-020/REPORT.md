# Phase 020 — Differential + property test harness

## What changed

| File | Lines | What |
|---|---|---|
| `corpus/NNNN-*.rb` + `.expected` | +528 files | the corpus: 264 programs across 16 families, each paired with the outcome the tree-walking VM produced |
| `tests/common/generator.rs` | +816 | the two generators: the 16 curated corpus families, and `random_program` — a *typed* grammar that only fails on faults it injected on purpose |
| `tests/differential_test.rs` | +1056 −241 | 31 tests: 15 over the corpus, 10 over generated programs, 6 over the shrinker |
| `tests/common/corpus.rs` | +370 | the corpus on disk: the loader, the escaped `.expected` format, and the comparison |
| `tests/common/shrink.rs` | +204 | delta debugging: a line pass then a character pass, both predicate-driven, with `without_line`/`without_char` exposed so the minimality assertion tests the shrinker's own deletions |
| `tests/common/vm.rs` | +181 | `Outcome`, `tree_walk`, `bytecode`, `tree_walk_span` — one program, two VMs, one comparison |
| `tests/common/rng.rs` | +101 | SplitMix64, written out: a fixed-integer generator, so a seed rebuilds the same bytes on any machine and any rustc |
| `tests/common/mod.rs` | +24 | the module list, and why the harness is test-only |
| `src/bytecode/vm.rs` | +20 −2 | the last frame's value *is* the program's value; `SET_PROPERTY` consumes its receiver |
| `src/bytecode/codegen.rs` | +35 −19 | only a block whose value is read (`main`, `Function`, `Method`) leaves one behind |

Line counts are `git diff --numstat` against `617f824`, except the new files.

## Reproduction of the finding

The finding as written — *"No differential or property testing infrastructure
exists; this is what makes S3 provable"* — **partly reproduces and partly does
not.**

What did not reproduce: phase 019 already added
`a_corpus_of_programs_runs_identically_on_both_vms`
(`tests/bytecode_vm_test.rs`) over ~336 programs hard-coded in Rust. Two VMs
being compared is not new.

What did reproduce: the interrupted attempt had written a runner
(`tests/differential_test.rs`, 333 lines) and **no corpus at all**, so six of its
seven tests failed:

```
$ cargo test --test differential_test
---- corpus_holds_at_least_two_hundred_programs stdout ----
thread '...' panicked at tests/differential_test.rs:115:23:
corpus directory …/tests/corpus should be readable: No such file or directory (os error 2)
test result: FAILED. 1 passed; 6 failed; 0 ignored; 0 measured; 0 filtered out
```

and one of its fixtures recorded a message the interpreter does not produce:

```
---- edge_a_corpus_program_whose_expected_file_names_a_failure_reports_a_mismatch ----
assertion `left == right` failed
  left: "RuntimeError: Index 9 is out of bounds: length is 2, valid indexes are 0 to 1"
 right: "RuntimeError: Index 9 is out of bounds"
```

A corpus with an expectation per program, a *seeded* generator, and a shrinker:
none of those existed.

The stale-phase rule was therefore **not** triggered — there was real work to
finish. It is finished here, not rewritten: `Outcome`, `failure_of`, `tree_walk`,
`bytecode`, `parse_expected` and `assert_outcome_matches` are the interrupted
attempt's, moved to `tests/common/` and corrected; and five of its seven test
names survive verbatim (`corpus_holds_at_least_two_hundred_programs`,
`every_corpus_program_has_an_expected_output_file`,
`every_corpus_program_prints_what_its_expected_file_records`,
`every_corpus_program_agrees_between_the_two_vms`,
`the_corpus_holds_programs_that_must_fail`). Its two edge tests were absorbed into
tests that actually run the thing they claim to check — see
`edge_a_changed_return_value_is_a_runner_failure` and
`every_corpus_program_has_an_expected_output_file`.

### The finding the harness itself turned up, and why it cost three changes in `src/`

The runner compares *what a program is worth*, not only what it printed. Writing
that comparison is what made the divergence visible:

```
$ set t to 5 / say t / t
  tree-walking VM: Ok("5")
  bytecode VM:    Ok("nothing")
```

`src/bytecode/vm.rs:916` threw the last frame's value away unless the frame was a
*call*, so the top-level frame — which is not a call — always answered `nothing`,
while `src/vm.rs:397` keeps the value of the last statement. Two leaks became
visible the moment that stopped being discarded: `SET_PROPERTY` popped the value
but not the receiver (`docs/BYTECODE.md:180` says it pops both), and `statements`
treated the last statement of *every* block as value-bearing, so
`if n is 1 then / 7 / end` left `7` for the frame above.

**This is a deliberate departure from the phase's declared `must_touch: ["tests/"]`.**
No change confined to `tests/` can make `tree_walk == bytecode` hold on a program
ending in an expression while the two VMs disagree about what that program is
worth. The alternative was to compare printed lines only — a differential harness
that routes around a divergence and calls the routing a property. For S3 this is
not cosmetic: two VMs that disagree about a program's value make a byte-identical
fixed point vacuous, because "identical" would have two meanings. Recorded in
`FINDINGS.md` §1 so the auditor can look at the decision.

Red before green, on the test that found it:

```
$ cargo test --test differential_test edge_a_changed_return_value_is_a_runner_failure
assertion `left == right` failed: the bytecode VM gave Ok("nothing") for a program
the tree-walking VM says is worth Ok("5"); a divergence here makes the whole corpus
check vacuous
  left: Outcome { output: ["5"], result: Ok("5") }
 right: Outcome { output: ["5"], result: Ok("nothing") }
```

### Red before green, on the harness itself

| Test | Failure before the change |
|---|---|
| `edge_a_changed_return_value_is_a_runner_failure` | the divergence above — `.expected` records the value and both VMs are asked |
| `regenerating_the_corpus_writes_exactly_what_the_generator_produces` | `corpus directory … should be readable: No such file or directory` — the finding |
| `edge_a_printed_line_that_looks_like_a_directive_round_trips` | a printed `#value 3` line read back as the program's value, so the file described a different program |
| `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` | `left: []` against `["before", "2"]` — "a program that fails must print nothing" is false |
| `edge_nearly_every_recorded_failure_says_where_it_happened` | the failure position was dropped by `failure_of`, so it was invisible to both halves |
| `edge_the_shrinker_stops_only_when_nothing_can_be_removed` | `without_line` split on `'\n'`, so deleting the phantom empty line after the final newline returned the source unchanged and the shrinker sat on a fixed point for ever |
| `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` | three generator defects, in the table below |
| `edge_the_generator_emits_every_statement_form_it_lists` | `no generated program containing an expression tail` |

## Tests added

31 `#[test]` functions, 18 of them named `edge_*`. Quota was ≥ 3 with ≥ 1
`edge_*`; none was deleted, renamed to be skipped, or given an `allow`.

| Test | Edge class covered |
|---|---|
| `the_checked_in_corpus_is_the_one_the_generator_produces` | corpus integrity — a hand-edited program, a re-recorded expectation or a reordered family all fail here |
| `regenerating_the_corpus_writes_exactly_what_the_generator_produces` | corpus integrity — writes only behind `RB_WRITE_CORPUS=1`, **refuses to record a program the two VMs disagree about**, refuses to record a program that did not fail when its family says it must or did fail when it must not, and floors the corpus at 200 programs |
| `corpus_holds_at_least_two_hundred_programs` | corpus size, counted over `.rb` files and unconditionally (not only when writing) |
| `every_corpus_program_has_an_expected_output_file` | **asserts a failure is produced** — the loader `catch_unwind`s over a scratch directory and the panic must name `orphan.expected`; a loader that skipped the orphan would leave the count assertion green and the corpus one notch smaller |
| `every_corpus_program_prints_what_its_expected_file_records` | output, value and message all compared |
| `every_corpus_program_agrees_between_the_two_vms` | differential — 264 programs, both halves of the outcome |
| `the_corpus_holds_programs_that_must_fail` | floored at 20 failures spanning **four** labels: `LexerError`, `ParserError`, `AnalyzerError`, `RuntimeError` |
| `the_corpus_holds_programs_that_are_worth_something` | differential — floors the valued programs at 10 and the distinct values at 4, and runs **both** VMs over each one |
| `edge_a_changed_return_value_is_a_runner_failure` | differential + **asserts a failure is produced** — both VMs on `set t to 5 / say t / t`, then `catch_unwind` on an `.expected` naming 6 for a program worth 5 and one naming the wrong message |
| `edge_a_printed_line_that_looks_like_a_directive_round_trips` | unicode/escapes — a printed `#value`/`#label`/`#output`/`#end`/`#message` line survives the round trip as output |
| `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` | resource_limit — a `say` before an uncaught fault is recorded *and* compared; the rule that survives is that a **frontend** failure printed nothing, asserted for three programs |
| `edge_every_recorded_failure_points_at_a_line_of_its_own_program` | malformed_input — every recorded failure names a real line and column of its own program |
| `edge_nearly_every_recorded_failure_says_where_it_happened` | malformed_input — the unknown-position count is bounded, *and* one named fixture per stage (`Lexer`, `Parser`, `Analyzer`, `Runtime`) carries a position, so the ratio cannot be satisfied by a corpus in which nothing does |
| `edge_an_expected_file_carrying_a_multiline_failure_message_round_trips` | unicode/escapes — `\` and newline survive in both a message and a printed line |
| `edge_a_malformed_expected_file_is_rejected` | malformed_input — 8 `.expected` files that are not valid ones are each rejected by `catch_unwind` |
| `the_two_vms_agree_on_every_generated_program` | differential — 320 generated programs; on a divergence it **shrinks and prints the minimal failing program** |
| `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` | type_mismatch — the typed-grammar invariant, asserted, and it found three generator defects in one pass |
| `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output` | differential — both VMs asked about every program worth something, at least half of the completed ones are worth something, and the values span four or more distinct values |
| `edge_the_generator_emits_every_statement_form_it_lists` | coverage — all seven statement forms occur; an unreachable arm cannot pass |
| `edge_the_generator_does_not_produce_nothing_but_failures` | type_mismatch — the generated grammar must not degenerate into error paths |
| `a_generated_program_runs_the_same_way_every_time` | determinism — the same source twice reaches the same outcome, and both VMs agree, so a divergence is reproducible |
| `a_generated_program_either_completes_or_reports_a_failure` | **asserts a failure is produced** — a failure names one of the five public labels with a non-empty message; a non-runtime failure printed nothing; both outcomes occur |
| `edge_a_generated_failure_points_at_a_line_of_its_own_program` | malformed_input — a generated failure names a real line and column |
| `the_generator_is_reproducible_from_its_seed` | determinism — the same seed twice is equal, a different seed is not, the corpus generator is a function of nothing, and **no two corpus programs are identical** |
| `edge_every_seed_produces_a_distinct_corpus_of_programs` | determinism — 8 seeds, 8 distinct corpora |
| `the_shrinker_reduces_a_counterexample_to_a_minimal_program` | malformed_input — 41 lines reduce below 40 characters, and the reduction is printed |
| `edge_the_shrinker_stops_only_when_nothing_can_be_removed` | malformed_input — minimality asserted against the shrinker's **own** `without_line`/`without_char` candidates: no further line *or* character removal still reproduces the same failure |
| `edge_the_shrinker_deletes_a_character_from_a_multibyte_program` | unicode/escapes — the character pass walks characters, not bytes; a `String::remove` on a non-boundary panics and would abort the binary |
| `edge_a_reduction_keeps_the_trailing_newline_a_source_has` | malformed_input — the terminator is put back, `lines()` not `split('\n')` so no phantom line can be "deleted" into a fixed point, and out-of-range lines return `None` |
| `edge_the_shrinker_reduces_character_by_character_when_no_line_can_go` | malformed_input — the character pass runs, and the predicate names the *failure* rather than "it failed", so a division by zero does not reduce to a bare `/` |
| `edge_the_shrinker_never_invents_a_counterexample` | shrinker soundness — a program that does not reproduce comes back unchanged; a predicate nothing satisfies changes nothing |

## What the corpus holds

264 programs, no two identical. 231 run to completion; **33 must fail** — 1
`AnalyzerError`, 3 `LexerError`, 14 `ParserError`, 15 `RuntimeError`. 15 of the
231 record a `#value` other than `nothing`, across **14** distinct values: eight
different numbers, two texts, `yes`, `no`, a list and a record.

| Family | n | What it pins |
|---|---|---|
| `arithmetic` | 16 | nested `+ - *`, unary negation, identity, `is`/`is not`, `and`/`or`/`not` |
| `numeric_boundary` | 19 | `1/0`, `0/0`, `n/7`, `9%n` all caught; `2^53`, `2^53+1`, `0.1+0.2`, `1/3`, `-0.0`, `2147483647`, `-2147483648`, `i64` edges, `1/-0.0`, signed `/` and `%` |
| `text_ops` | 16 | concatenation, `length`, `is`, empty text, embedded quote, backslash, tab, newline |
| `unicode` | 17 | CJK, emoji, ZWJ, RTL, combining mark, astral (`𠮷`), BOM-prefixed source, `length` and equality on each |
| `lists` | 16 | empty, singleton, index `0`, index `len-1`, negative index, trailing comma, `for each` over each |
| `records` | 15 | one field, nested, missing key → `nothing`, repeated key keeps the last, order-independent equality, aliasing |
| `control_flow` | 16 | `if`/`else` 1–3 deep, empty `then`, `while`, `and`/`not` in a condition |
| `functions` | 16 | 0/1/2-arity, a conditional `give back`, a closure returned from a closure, two closures from the same outer, iteration-as-recursion |
| `objects` | 12 | empty object, field write, two `has`, inheritance one and two deep, `extends` shadowing, a missing field |
| `loop_forms` | 16 | `repeat 0`/`1`/`n` times, `for each` over `[]`/list/list-of-list, `while` to a bound, nested loops |
| `nesting` | 16 | lists and records 3–5 deep, a walk down every level, `if` nested 4 deep, nested loops over a nested list |
| `stdlib` | 16 | `length` and `type_of` on every type, including the empty and singleton cases |
| `runtime_errors` | 18 | each catchable error inside `try … catch` — the catch must fire, and the work before it must survive |
| `faults` | 16 | the same errors uncaught: the failure **and everything printed before it** |
| `malformed` | 17 | unterminated literal, escaped-quote run, missing `end`, stray `end`, `set` with no name, `set` with no `to`, `set` with no value, missing operand, unclosed paren, `say` with nothing, `for each` with no variable, `repeat` with no count, stray `}`, `if` with no condition, `for each` with no iterable, unclosed list, `@` |
| `values` | 22 | programs whose **last statement is a bare expression**: a bound number, a bound text, arithmetic, concatenation, `yes`, `no`, `nothing`, a whole list, a whole record, a builtin call, a property read, an index, a call that gives a value back, a missing key, a field write, a conditional tail, a loop tail, two BOM-prefixed programs |

`stdlib` covers only `length` and `type_of` because nothing else is callable —
`FINDINGS.md` §7.

## Every new assertion is mutation-checked

Each fix was verified by putting the defect back and watching a test fail. Nothing
here was taken on trust:

| Defect restored | Test(s) that failed |
|---|---|
| top-level frame's value discarded again (`src/bytecode/vm.rs:916`) | `edge_a_changed_return_value_is_a_runner_failure`, `every_corpus_program_agrees_between_the_two_vms`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces`, `the_corpus_holds_programs_that_are_worth_something`, `the_two_vms_agree_on_every_generated_program`, `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output`, `a_generated_program_runs_the_same_way_every_time` (**7**) |
| `SET_PROPERTY` leaks its receiver again (`src/bytecode/vm.rs:1526`) | the same five corpus/differential tests (**5**) |
| every block leaves a value behind again (`src/bytecode/codegen.rs:104`) | the same five (**5**) |
| the loader skips a program with no `.expected` | `every_corpus_program_has_an_expected_output_file` |
| `without_line` splits on `'\n'` (phantom empty line ⇒ fixed point) | `edge_a_reduction_keeps_the_trailing_newline_a_source_has`, `edge_the_shrinker_stops_only_when_nothing_can_be_removed`, `edge_the_shrinker_deletes_a_character_from_a_multibyte_program`, `the_shrinker_reduces_a_counterexample_to_a_minimal_program` (**4**) |
| `#` is not escaped in the `.expected` format | `edge_a_printed_line_that_looks_like_a_directive_round_trips` |
| `type_of` back in the generator's `Number` arm | `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` |
| the conditional arm drops its `then` | `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` |

The three `src/` mutations were also checked to *compile*: `-D warnings` is in
effect in this tree, so a mutation that left an unused variable would have failed
to build and its "test result: ok" would have been a stale binary. That happened
once and was re-run.

### Three generator defects the typed-grammar invariant caught

`edge_a_generated_program_only_faults_on_a_fault_that_was_injected` is only worth
having if it finds things. It found three:

| Defect | Symptom |
|---|---|
| `type_of` used to build a `Number` — it answers *text* | `set v1 to (type_of({a: 7, b: 1}) * (m + 2))` → `RuntimeError: Cannot multiply non-numbers` |
| `Kind::Text` folded in a `length`, which is a number | text plus a number is a `RuntimeError`, so the length cannot be folded into a text expression at all |
| a `Text` literal built by splicing expression *source* | a `LexerError` whenever the expression held a quote of its own |

The first is the shape of the defect in general: the generator's grammar said
`Kind::Number` and the grammar was wrong about what a builtin returns. That is why
`text_literal` and `number_literal` are separate functions from
`random_expression`, and why `FAULTS` is a named list rather than a boolean.

## Edge-case matrix

| Row | Covered? |
|---|---|
| empty | covered — `lists` holds `[]` and `for each` over it, `text_ops` holds `length("")`, `stdlib` holds `length([])` and `type_of([])`/`type_of({})`, `control_flow` holds an empty `then`, `loop_forms` holds `repeat 0 times` |
| singleton | covered — one-element list (`say xs[0]`), one-field record, `repeat 1 times`, `length([1])`, one `has` object |
| boundary | covered — index `0` and `len-1` and `[-2]` in `lists`, `2147483647`/`-2147483648`/`9223372036854775807`/`-9223372036854775808`/`9007199254740992`/`9007199254740993` in `numeric_boundary`, loop counters at their bound |
| out_of_bounds | covered — `faults` holds index `len`, index `-len-1` and index `0` of `[]`; `runtime_errors` holds the same three inside `catch`. Each records the exact message, e.g. `Index 0 is out of bounds: length is 0, the list is empty, so it has no valid index` |
| type_mismatch | covered — `faults` holds number×text, list×text, yes/no×number, nothing+number, text−number, index-on-number, index-on-record, index-on-`nothing`, `length({})`, an unknown function, an unknown variable, and `set r.a` on a `nothing` |
| numeric_boundary | covered — `numeric_boundary`: `1/0`, `0/0`, `n/7`, `9%n`, `1/-0.0`, `0.1+0.2`, `1/3`, `-0.0`, `-7/2`, `-7%3`, `7%-3`, `10^6×n`, and the `i64`/2^53 edges |
| unicode | covered — `unicode`: CJK, emoji, ZWJ (`👩‍💻`), RTL, combining mark, astral (`𠮷`), zero-width, box drawing, `length` and equality on each; plus `text_ops` for `\\`, `\"`, `\n`, `\t` in source, and a BOM-prefixed program in both `unicode` and `values` |
| nesting_recursion | covered — `nesting` (lists and records 3–5 deep, a walk down every level, `if` nested 4 deep, nested loops over a nested list), `functions` (a closure inside a closure, a returned closure called from two different outers), `objects` (inheritance two deep). **Terminating recursion is not covered and cannot be** — `give back` inside a conditional does not return, so `FINDINGS.md` §5; the family holds iteration-as-recursion instead |
| duplicate_missing_keys | covered — `records` holds a repeated key (`{a: 1, a: 2}` keeps the last), a missing key (`nothing`), a missing key three levels down, and aliasing (`set s to r` then writing through `s`); `objects` holds a missing field on an empty object |
| malformed_input | covered — `malformed` (17 programs, listed above) plus `edge_a_malformed_expected_file_is_rejected` (8 rejected `.expected` files) and the shrinker's minimality tests, which reduce to malformed programs |
| resource_limit | covered — `runtime_errors` and `faults` hold every catchable runtime error and prove it is catchable rather than fatal; `malformed` holds 17 frontend failures and `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` proves a frontend failure printed nothing; the property tests run 320 generated programs through both VMs and assert no panic anywhere; `edge_every_recorded_failure_points_at_a_line_of_its_own_program` and its generated counterpart check every failure's position against a real line and column of its own program; `the_corpus_holds_programs_that_are_worth_something` records and compares the value of every successful program rather than assuming it |
| value_bearing_tail | covered — the `values` family (22 programs, 15 worth something on **both** VMs: eight numbers, two texts, `yes`, `no`, a list and a record), plus `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output`, which requires at least half of the completed generated programs to be worth something |
| generator_well_typed | covered — `edge_a_generated_program_only_faults_on_a_fault_that_was_injected`: every generated program carrying no injected fault runs to completion, which is what makes `random_fault` the *only* source of failure. It found three broken arms in one pass |

## Gates

Run in the order `AGENTS.md` §3.4 gives.

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass — no diff |
| `cargo clippy --all-targets -- -D warnings` | pass — 0 warnings |
| `cargo test --all-targets` | **525 passed, 0 failed, 0 ignored** (24 test binaries), and `cargo test --doc`: 1 passed |
| `./rbops/verify.sh phase-020` | **not run — `rbops/verify.sh` does not exist in this checkout** (`FINDINGS.md` §9) |

525 rather than the 501 of the interrupted attempt: 31 tests replaced the 7 the
interrupted attempt had, none was
deleted, renamed to be skipped, or given an `allow`. `tests/differential_test.rs`
holds all 31; `tests/common/` holds the five modules they share.

On the fourth gate, honestly: there is no `rbops/` directory in this checkout at
all, and the task instructions say the pipeline that dispatched this phase lives
outside the checkout and is not to be inspected. The three gates that do exist
were run and are green. In their place, the backwards-compatibility check
`AGENTS.md` §2 names:

```
$ for f in examples/*.rb modules/*.rb; do rb run "$f" >/dev/null || echo "FAIL $f"; done
```

All eight run clean. Three small changes in `src/bytecode/` were made, so this was
re-checked rather than assumed — it is a check that `src/` did not change behaviour
the examples depend on, and it passed.

Determinism was checked by regenerating twice and comparing checksums:

```
$ before=$(cat corpus/* | sha256sum)
$ RB_WRITE_CORPUS=1 cargo test --test differential_test
$ after=$(cat corpus/* | sha256sum)
DETERMINISTIC: regeneration is byte-identical
```

## Invariants touched

- **None of the language.** No syntax or grammar changed. The `Value` and `Error`
  variants, the `.rb` extension, `to … end` / `if … end` / `for … end`, `set x to`,
  `say`, and the trailing-comma syntax are all untouched, and every pre-existing
  test still passes (525 total, 0 failures).
- **One thing about what a program *is worth* changed on the bytecode VM**, which
  is documented as an invariant and is called out here rather than buried:
  - a program ending in a bare expression now ends with that expression's value on
    the bytecode VM, as it already did on the tree-walking one (`FINDINGS.md` §1);
  - a statement consumes everything it produced, so `set r.a to 2` no longer leaks
    a record onto the operand stack and `if … then 7 … end` no longer leaves `7`
    for the enclosing block. Both were invisible before, because the top-level
    frame discarded whatever it finished with; they are the same bug wearing a
    second hat.
  Neither changes a `.rbc`'s byte format (`Opcode::ALL` is untouched and
  `tests/bytecode_test.rs`'s byte-value assertions still pass), so the bootstrap
  ladder's S1 artifact is unaffected, and neither changes the `.expected` format.
- **One placement decision.** The corpus lives at `corpus/`, not `tests/corpus/`.
  `redblue::testing::find_test_files("tests")` (`src/testing/mod.rs:64`) walks
  `tests/` recursively and `redblue_suite_test.rs:12` collects everything it finds
  and requires every `.rb` file to declare Redblue `test` blocks. A corpus program
  declares none, and *"a corpus program is not a test"* is the right thing for that
  test to say — so the corpus goes where the suite's collector does not walk, which
  is also where the phase's definition of done asks for it.

## Known gaps / follow-ups

- **The corpus cannot cover the documented standard library.** `abs`,
  `uppercase`, `split`, `map`, `reduce` and ~30 other registered builtins are
  unreachable from Redblue source, so `stdlib` holds `length` and `type_of` and
  nothing else → `FINDINGS.md` §7. "The corpus proves the two VMs agree" is a claim
  about the subset of the language that works.
- **The corpus cannot hold a terminating recursion.** `give back` inside a
  conditional does not return, so `to down(n) / if n is 0 then / give back 0 …`
  runs to the call-depth limit → `FINDINGS.md` §5. The `functions` family holds
  iteration-as-recursion instead.
- **`{interp}` is dead in the parser while `AGENTS.md` §2 lists it as an
  invariant** → `FINDINGS.md` §2. This is spec drift in the *other* direction: the
  corpus records what the interpreter does, not what the spec promises, and a
  phase that "fixed" interpolation would change 264 recorded expectations.
- **Six comparison and logical operators the grammar documents do not lex** →
  `FINDINGS.md` §3.
- **Trailing tokens on a line are silently accepted** (`say 1 2 3` prints `1` and
  is worth `3`) → `FINDINGS.md` §4.
- **`break` and `skip` are no-ops** → `FINDINGS.md` §8.
- **The generator's grammar is typed**, so it cannot generate a type-mismatched
  program by accident; `random_fault` injects those on purpose. That is a
  deliberate limit — a generator that produced mostly type errors would assert only
  that errors happen, which `edge_the_generator_does_not_produce_nothing_but_failures`
  fails on.
- **The corpus regenerates only when `RB_WRITE_CORPUS=1` is set.** A CI job that set
  it would rewrite the golden files instead of failing on a regression.
  `the_checked_in_corpus_is_the_one_the_generator_produces` refuses to run at all
  in that case rather than comparing the corpus against itself.
- **A property-harness phase cannot see a defect both VMs share.** Six of the nine
  items in `FINDINGS.md` are limitations of the language that the two VMs agree
  on, which is exactly the class a *differential* harness is blind to. Only §1 was
  visible to this phase, and only because the harness compared something other than
  printed output.
- **`rbops/verify.sh` was not run because it is not present** → `FINDINGS.md` §9.
