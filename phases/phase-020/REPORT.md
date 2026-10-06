# Phase 020 — Differential + property test harness

## What changed

| File | Lines | What |
|---|---|---|
| `corpus/*.rb` + `corpus/*.expected` | +638 files | the corpus: **319 programs** across 17 families, each paired with the outcome the tree-walking VM produced — printed lines, the value the program was worth **as a type and a rendering**, and the failure's label, message **and** position (review rounds two and three) |
| `tests/common/generator.rs` | +1317 | the two generators: 17 curated corpus families, and `generate` — a *typed* grammar over a seed, which only ever faults on a fault it injected on purpose, **and fails on that fault and no other** (review round three), with every expression **arm** in a table that can be enumerated and asked what it is worth (review round three) |
| `tests/differential_test.rs` | +1174 −240 | 30 tests: 17 over the corpus and its golden format, 9 over generated programs, 4 over the harness's own failure paths |
| `tests/common/corpus.rs` | +481 | the corpus on disk: the loader, the escaped `.expected` format (with its `#position` directive and its **type-tagged** `#value`), its writer, and `compare` |
| `tests/common/shrink.rs` | +405 | delta debugging: a line pass then a character pass, with `without_line`/`without_char`/`shrinks_to` exposed so the minimality assertion tests the shrinker's own decisions |
| `tests/common/vm.rs` | +860 | `Outcome`, `Failure`, `tree_walk_verbose`, `tree_walk`, `bytecode` — one program, two VMs, one comparison, **one run each**, **typed values**, limits that are not read out of the environment, and the one guarded door to that environment (`EnvLimits`) |
| `tests/common/rng.rs` | +145 | SplitMix64 written out: a fixed-integer generator, so a seed rebuilds the same bytes on any machine and any rustc |
| `tests/common/mod.rs` | +23 | the module list, and why the harness is test-only |
| `src/bytecode/vm.rs` | +65 −13 | the outermost frame's value *is* the program's value; `SET_PROPERTY` consumes its receiver, as `docs/BYTECODE.md:180` says it does; an object body that finishes with nothing to register is a `RuntimeError` rather than a panic; `with_limits` sets all three limits at once (review round two) |
| `src/vm.rs` | +42 −1 | `Vm::with_limits` — the same constructor on the tree-walking side, because the three `with_max_*` constructors each replace one limit and leave the other two to the environment; and `statement_span`, so a runtime failure names the **line** it happened on and both engines answer the same (review round three, §4 of that round below, and `FINDINGS.md` §15) |
| `src/bytecode/codegen.rs` | +117 −21 | only a block whose value is read (`main`, `Function`, `Method`) leaves one behind; an `object` body compiles as two halves — the `has`/`to can` that declare the type, and everything else, in the enclosing block where the type already exists |
| `tests/span_test.rs` | +17 −2 | the one pre-existing assertion that pinned the *old* runtime position, updated rather than deleted: it now states the line-and-column-1 contract and says why |

Line counts are `git diff --numstat` against `d5b42ed`, except the new files.

## Reproduction of the finding

The finding — *"No differential or property testing infrastructure exists; this
is what makes S3 provable"* — **reproduced**. The resume commit `d5b42ed` added a
runner (`tests/differential_test.rs`, 333 lines) and **no corpus at all**, so six
of its seven tests failed:

```
$ cargo test --test differential_test
thread 'corpus_holds_at_least_two_hundred_programs' panicked at tests/differential_test.rs:115:23:
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

**The previous attempt's REPORT.md was not believed and was wrong.** It claimed
`corpus/`, `tests/common/`, a 31-test suite and three `src/` changes. The tree
contained only the 333-line runner, no `corpus/`, no `tests/common/`, and no
`src/` changes at all. Nothing from that report was taken on trust; the work was
redone and every claim below was re-measured.

### What the harness itself turned up, and why it cost three changes in `src/`

The runner compares *what a program is worth*, not only what it printed. Writing
that comparison is what made the divergence visible:

```
$ set t to 5 / say t / t
  tree-walking VM: Ok("5")
  bytecode VM:    Ok("nothing")
```

`src/bytecode/vm.rs` threw the last frame's value away unless the frame was a
*call*, so the top-level frame — which is not a call — always answered `nothing`,
while `src/vm.rs:397` keeps the value of the last statement. Two leaks became
visible the moment that stopped being discarded: `SET_PROPERTY` popped the value
but not the receiver, and `statements` treated the last statement of *every* block
as value-bearing, so `if n is 1 then / 7 / end` left `7` for the frame above.

**This is a deliberate departure from the phase's declared `must_touch: ["tests/"]`.**
No change confined to `tests/` can make `tree_walk == bytecode` hold on a program
ending in an expression while the two VMs disagree about what that program is
worth. The alternative was to compare printed lines only — a differential harness
that routes around a divergence and calls the routing a property. For S3 this is
not cosmetic: two VMs that disagree about a program's value make a byte-identical
fixed point vacuous, because "identical" would have two meanings. Recorded in
`FINDINGS.md` §1.

Red before green, on the test that found it:

```
$ cargo test --test differential_test edge_a_program_ending_in_an_expression_is_worth_it_on_both_vms
assertion `left == right` failed: tree=Outcome { output: ["5"], result: Ok("5") }
bytecode=Outcome { output: ["5"], result: Ok("nothing") }: the two VMs disagree about
what a program is worth, which makes every other comparison on it vacuous
```

## Tests added

62 `#[test]` functions in all — 30 in `tests/differential_test.rs` and 32 inside
`tests/common/` — of which **49 are named `edge_*`**. Quota was ≥ 3 with ≥ 1
`edge_*`; none was deleted, renamed to be skipped, or given an `allow`. Round one
closed six findings, round two closed six more, and round three five; the seven
tests round two added and the five round three added are named below.

| Test | Edge class covered |
|---|---|
| `corpus_holds_at_least_two_hundred_programs` | corpus size, counted over `.rb` files and unconditionally |
| `every_corpus_program_has_an_expected_output_file` | loader — every program has a parseable expectation |
| `every_corpus_program_prints_what_its_expected_file_records` | output, **value** and message all compared, over 319 programs |
| `every_corpus_program_agrees_between_the_two_vms` | differential — 319 programs, both halves of the outcome; a divergence is **shrunk and printed** |
| `the_corpus_holds_programs_that_must_fail` | **asserts a failure is produced** — ≥ 40 recorded failures spanning all four labels |
| `the_corpus_holds_programs_that_are_worth_something` | differential — ≥ 25 valued programs, ≥ 10 distinct values, each run on **both** VMs |
| `regenerating_the_corpus_writes_exactly_what_the_generator_produces` | corpus integrity — writes only behind `RB_WRITE_CORPUS=1`, and **refuses to record a program the two VMs disagree about** |
| `the_checked_in_corpus_is_the_one_the_generator_produces` | corpus integrity — reads `corpus/` and compares the **on-disk name and source** of every program against the generator's, refusing to run when `RB_WRITE_CORPUS` is set |
| `the_two_vms_agree_on_every_generated_program` | differential — 320 generated programs; on a divergence it shrinks and prints the minimal program |
| `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` | type_mismatch — the typed-grammar invariant, asserted: no fault means completion, and an injected fault means **that** failure, at that position (review round three); **it found one generator defect** (table below) |
| `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output` | differential — both VMs asked about every program, ≥ half the completions are worth something, ≥ 5 distinct values |
| `edge_the_generated_corpus_reaches_every_fault_it_declares` | coverage — the declared fault list and what is injected are the same set |
| `edge_the_generator_does_not_produce_nothing_but_failures` | type_mismatch — the grammar must not degenerate into error paths |
| `a_generated_program_runs_the_same_way_every_time` | determinism — same seed twice, same outcome, and both VMs agree |
| `a_generated_program_either_completes_or_reports_a_failure` | **asserts a failure is produced** — a failure names one of the five public labels with a non-empty message; both channels occur |
| `the_generator_is_reproducible_from_its_seed` | determinism — same seed equal, different seed different |
| `edge_almost_every_seed_produces_a_program_of_its_own` | determinism — 320 seeds, **≥ 95% distinct programs**, and any program shared by two seeds is named |
| `edge_a_printed_line_that_looks_like_a_directive_round_trips` | unicode/escapes — a printed `#value`/`#label`/`#message`/`#position`/`#output`/`#end` line survives the round trip as **output** |
| `edge_an_expected_file_carrying_escapes_round_trips` | unicode/escapes — `\`, a newline inside one printed line, and a leading `#` |
| `edge_a_malformed_expected_file_is_rejected` | malformed_input — **asserts a failure is produced** — 16 malformed `.expected` files, each rejected by `catch_unwind`, including the four new `#position` shapes |
| `edge_a_failure_that_moved_is_a_difference_on_both_sides` | differential — a recorded failure at the wrong line is rejected by `compare`, **and** the two VMs are asked separately where the failure happened |
| `edge_every_recorded_failure_records_the_place_it_happened_at` | malformed_input — every one of the corpus's failures records a position, and it is the one the VM reports |
| `edge_both_vms_place_every_failure_at_the_same_line_and_column` | differential — the position half of the outcome, compared over the corpus, with a count so it cannot pass vacuously, **and a count of the columns that are not 1, so that the column half is not arithmetic** (review round three) |
| `edge_a_corpus_program_with_no_expectation_is_a_hard_failure` | **asserts a failure is produced** — an orphan is a hard failure **naming the file**, and no expectation is invented |
| `edge_a_changed_return_value_is_a_runner_failure` | differential + **asserts a failure is produced** — an `.expected` naming the wrong value *and* one naming the wrong message each fail |
| `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` | resource_limit — a `say` before an uncaught fault is recorded *and* compared; the rule that survives is that a **frontend** failure printed nothing, asserted for three programs |
| `edge_every_recorded_failure_points_at_a_line_of_its_own_program` | malformed_input — 77 recorded failures: 74 name a real line and column, 3 are the end-of-file convention and are asserted not to become the norm; each is also asserted to be **the position its `.expected` records** |
| `edge_a_mismatch_names_the_program_it_is_about` | the panic must name the file, so a failure is actionable |
| `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints` | type_mismatch — the golden file's `#value` names a type as well as a rendering, and an untagged `#value 5` is **rejected** for a program worth the number `5` (review round three) |

The other 32 live in `tests/common/`, each next to the code it checks rather than
in a file that would only be able to reach it through the public API:
`edge_the_generator_is_the_sequence_it_documents` (the
PRNG's constants pinned), `edge_a_seed_is_replayed_and_a_different_seed_is_not`,
`edge_the_bounded_helpers_stay_inside_their_bounds`, `edge_the_singleton_and_zero_cases_are_not_ambiguous`,
`edge_a_program_ending_in_an_expression_is_worth_it_on_both_vms`,
`edge_a_statement_leaves_nothing_behind_on_either_vm` (five programs; the
`SET_PROPERTY` and stray-block-value leaks),
`edge_the_two_halves_agree_on_a_failure_and_on_what_was_printed_first`,
`edge_a_frontend_failure_printed_nothing_on_either_vm`,
`edge_one_run_of_a_program_is_all_the_harness_asks_for` (a program that
**appends** to a file, so a second run is visible on disk),
`edge_a_failure_is_read_off_the_run_that_produced_it` (the failure and its
position come from the same run as the output),
`edge_a_nested_object_runs_on_both_vms_and_neither_panics` (six programs; the
nested-`object` panic, and `extends` resolving only when the outer type is
registered first),
`edge_an_object_declaration_is_worth_nothing_even_when_its_body_ends_in_a_value`
(the body's tail compiles into a block whose value *is* read),
`edge_the_shrinker_stops_only_when_nothing_can_be_removed` (minimality asserted
against the shrinker's **own** candidates), `edge_the_shrinker_accepts_a_candidate_only_when_it_is_shorter`,
`edge_a_character_comes_off_a_multibyte_program_at_its_own_boundary` (byte
indexing would panic on `𠮷`), `edge_a_reduction_keeps_the_trailing_newline_a_source_has`,
`edge_the_shrinker_reduces_when_no_line_can_go`, `edge_the_shrinker_never_invents_a_counterexample`,
`edge_a_line_comes_off_and_a_line_that_is_not_there_does_not`,
`edge_drop_lines_builds_the_source_the_line_pass_looks_at`,
`edge_a_reduction_is_reported_with_the_program_it_reduced`,
`edge_the_corpus_generator_is_a_function_of_nothing` (regeneration is a function
of nothing; **no two of the 319 programs are identical**),
`edge_the_generator_emits_every_statement_form_it_lists`,
`edge_generated_programs_end_in_a_value_rather_than_in_a_statement` (the
generator's own programs must end in a bare expression, which is the only
place their value comes from),
`edge_every_declared_fault_is_actually_injected_by_some_seed`,
`edge_every_declared_fault_has_a_tail_that_faults` (review round three: each
declared fault has a tail, each tail faults on both engines, and the six tails
produce six *different* failures),
`edge_every_kind_is_reachable_and_its_arms_produce_it` (review round three: every
**arm** of every kind, built by index, is worth the kind it claims, runs on both
engines, and is reachable).

`tests/common/vm.rs` grew three more in round two:
`edge_a_number_and_the_text_that_spells_it_are_different_outcomes` (the
rendering collides, the values do not — which is what a string-valued
outcome could not see), `edge_a_failure_carries_the_position_it_happened_at`,
and `edge_a_limit_left_in_the_environment_cannot_change_an_outcome`.

`tests/common/vm.rs` grew one more in round three:
`edge_a_runtime_failure_names_a_line_and_a_frontend_failure_names_a_column` —
four runtime failures, two of them **indented**, at the line and column 1 on
both engines; two frontend failures at the offending token's column; and the
rendered caret, which is where a user actually sees the position.

## What the corpus holds

319 programs, no two identical. 242 run to completion; **77 must fail** — 4
`AnalyzerError`, 9 `LexerError`, 26 `ParserError`, 38 `RuntimeError`. 25 record a
`#value` other than `nothing`, across **18** distinct values: eight numbers, two
texts, `yes`, `no`, two lists and two records. **30** of the 77 recorded failures
sit at a column other than 1 — all of them frontend failures, which is the only
kind that carries a column (review round three).

| Family | n | What it pins |
|---|---|---|
| `arithmetic` | 18 | nested `+ - * %`, unary negation, `is`/`is not`, `and`/`or`/`not` |
| `numeric-boundary` | 20 | `1/0`, `0/0`, `9%0`, `1/-0.0` caught; `0.1+0.2`, `1/3`, `-0.0`, `2147483647+1`, `2147483647`, `-2147483648`, `i64` edges, `2^53`, `2^53+1`, signed `/` and `%` |
| `text-ops` | 17 | concatenation, `length`, `is`, empty text, `\"`, `\\`, `\n`, `\t` |
| `unicode` | 17 | CJK, emoji, ZWJ, RTL, astral (`𠮷`), BOM-prefixed source, `length` and equality on each |
| `lists` | 18 | empty, singleton, index `0`, index `len-1`, negative index, trailing comma, nested list, aliasing, `for each` over each |
| `records` | 16 | one field, nested, missing key → `nothing`, repeated key keeps the last, order-independent equality, aliasing |
| `control-flow` | 16 | `if`/`else if`/`else` 1–3 deep, empty `then`, `and`/`or`/`not` in a condition, a 4-deep `if` |
| `functions` | 16 | 0/1/2-arity, a function bound to a variable and called twice, a function passed as an argument, two `give back`s, iteration-as-recursion |
| `objects` | 18 | empty object, `has` with and without a `default`, a method writing through `this`, inheritance one and two deep, `extends` shadowing, a missing field, and an `object` **nested in another object's body**, with and without `extends` on the type it is written inside |
| `loop-forms` | 17 | `repeat 0`/`1`/`n` times, `for each` over `[]`/list/list-of-list, nested loops, a condition inside a loop, and `skip`/`break` — which are accepted and leave the loop alone |
| `nesting` | 16 | lists and records 4–7 deep, a walk down every level, `if` nested 4 deep, triple-nested loops |
| `stdlib` | 21 | `length` and `type_of` on every type, including the empty and singleton cases |
| `runtime-errors` | 22 | each catchable error inside `try … catch` — the catch must fire and the work before it must survive; plus nested `try` and `finally` |
| `faults` | 20 | the same errors uncaught: the failure **and everything printed before it**, plus two **indented** failures — the case that made the two engines disagree about a failure's column (review round three) |
| `malformed` | 31 | unterminated string, stray `end`, `set` with no name / no `to` / no value, missing operand, unclosed paren, unclosed list, unclosed record, `say` with nothing, `for each` with no variable / no iterable, `repeat` with no count, stray `}`, `if` with no condition, `@`, `=`, unclosed `to`, the six non-lexing comparators, `for each … from`, a missing `then`, an unclosed index |
| `value-tails` | 26 | programs whose **last statement is a bare expression**: a bound number, a bound text, arithmetic, concatenation, `yes`, `no`, `nothing`, a whole list, a whole record, a builtin call, a property read, an index, a call, a missing key, a field write, a loop tail, BOM-prefixed programs |
| `labels` | 10 | one program per public failure shape, so the coverage assertion has something to name |

`stdlib` covers only `length` and `type_of` because 23 of the 25 registered
builtins cannot be called from Redblue source → `FINDINGS.md` §7. There is **no
`while` anywhere in the corpus** because no comparison operator lexes →
`FINDINGS.md` §2.

### One generator defect the typed-grammar invariant caught

`edge_a_generated_program_only_faults_on_a_fault_that_was_injected` is only worth
having if it finds things. It found one in its first run:

```
seed 95: no fault was injected, so a typed grammar must not have produced a failure
say nothing
set xs to [7.5]
("a b" + "a"b")

  outcome: Outcome { output: [], result: Err("LexerError: Unterminated string") }
```

`text_literal` spliced a raw word into quotes, so the word `a"b` produced the
source `"a"b"` — a `LexerError` from a program the grammar meant to be well-typed.
Fixed by escaping inside `text_literal` itself rather than by removing the word
from the list, because the word is what found the bug. This is the shape of the
defect in general: the generator's grammar said `Kind::Text` and the grammar was
wrong about escaping.

### Every new assertion is mutation-checked

Each fix was verified by putting the defect back and watching a test fail. Nothing
here was taken on trust:

| Defect restored | Test(s) that failed |
|---|---|
| top-level frame's value discarded again (`src/bytecode/vm.rs:904`) | `edge_a_program_ending_in_an_expression_is_worth_it_on_both_vms`, `every_corpus_program_agrees_between_the_two_vms`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces`, `the_corpus_holds_programs_that_are_worth_something`, `the_two_vms_agree_on_every_generated_program`, `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output`, `a_generated_program_runs_the_same_way_every_time` (**7**) |
| `SET_PROPERTY` leaks its receiver again (`src/bytecode/vm.rs:1516`) | `edge_a_statement_leaves_nothing_behind_on_either_vm`, `every_corpus_program_agrees_between_the_two_vms`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces` (**3**) |
| an `if` branch value-bearing again (`src/bytecode/codegen.rs:147`) | `edge_a_statement_leaves_nothing_behind_on_either_vm` (**1**) |
| the loader skips a program with no `.expected` | `edge_a_corpus_program_with_no_expectation_is_a_hard_failure` |
| `compare` stops checking the value | `edge_a_changed_return_value_is_a_runner_failure` |
| `#` not escaped in the `.expected` format | `edge_a_printed_line_that_looks_like_a_directive_round_trips` |
| `escape` loses the newline case | `edge_an_expected_file_carrying_escapes_round_trips`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces` (**2**) |
| `without_char` indexes bytes, not characters | `edge_a_character_comes_off_a_multibyte_program_at_its_own_boundary` |
| `shrinks_to` accepts an equal-length candidate | `edge_the_shrinker_accepts_a_candidate_only_when_it_is_shorter` |
| an `object` body compiled whole again, so a nested `object` runs inside the block that assembles the outer declaration (`src/bytecode/codegen.rs`) | `edge_a_nested_object_runs_on_both_vms_and_neither_panics`, `every_corpus_program_agrees_between_the_two_vms`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces` (**3**) |
| the body's tail compiled as the enclosing block's last statement, so a trailing `1 + 1` became the function's value | `edge_an_object_declaration_is_worth_nothing_even_when_its_body_ends_in_a_value` (**1**) |
| `tree_walk` recovers the value by running the pipeline a second time | `edge_one_run_of_a_program_is_all_the_harness_asks_for` (**1**; the mutation is visible as `abab` on disk rather than `ab`) |
| a corpus program's source edited, so the checked-in corpus no longer matches the generator | `the_checked_in_corpus_is_the_one_the_generator_produces` (**1**) |
| a corpus program deleted | `the_checked_in_corpus_is_the_one_the_generator_produces`, `corpus_holds_at_least_two_hundred_programs` (**2**) |
| `Outcome.result` back to a rendered string | `edge_a_number_and_the_text_that_spells_it_are_different_outcomes` (**1**) |
| `Failure.position` dropped again | `edge_a_failure_carries_the_position_it_happened_at`, `edge_a_failure_that_moved_is_a_difference_on_both_sides`, `edge_both_vms_place_every_failure_at_the_same_line_and_column`, `edge_every_recorded_failure_records_the_place_it_happened_at` (**4**) |
| `compare` stops checking the position | `edge_a_failure_that_moved_is_a_difference_on_both_sides` (**1**) |
| the generated programs' tail made a statement (`say 1`) instead of an expression | `edge_generated_programs_end_in_a_value_rather_than_in_a_statement` (**1**) |
| the harness builds its VMs with `new()`, so the limits follow the environment | `edge_a_limit_left_in_the_environment_cannot_change_an_outcome` (**1**) |
| `#value` tagged as the bare rendering again (`tests/common/corpus.rs`) | `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints`, `every_corpus_program_prints_what_its_expected_file_records`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces` (**3**) |
| one statement arm of the generator made to fault (`tests/common/generator.rs`) | `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` (**1**) — the reviewer's own scenario: *a prefix defect* |
| two fault tails made to produce one failure | `edge_every_declared_fault_has_a_tail_that_faults` (**1**) |
| `expression`'s arm draw clamped, so the last arm of every kind is dead | `edge_every_kind_is_reachable_and_its_arms_produce_it` (**1**) |
| an arm building the wrong type — the text concatenation arm sums two numbers | `edge_every_kind_is_reachable_and_its_arms_produce_it` (**1**) |
| `statement_span` back to the statement's own column (`src/vm.rs`) | `edge_a_runtime_failure_names_a_line_and_a_frontend_failure_names_a_column`, `edge_both_vms_place_every_failure_at_the_same_line_and_column`, `every_corpus_program_agrees_between_the_two_vms`, `edge_every_recorded_failure_records_the_place_it_happened_at`, `edge_every_recorded_failure_points_at_a_line_of_its_own_program`, `every_corpus_program_prints_what_its_expected_file_records`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces` (**7**), and `tests/span_test.rs`'s updated assertion |
| `EnvLimits` restoring nothing | `edge_a_limit_left_in_the_environment_cannot_change_an_outcome` (**1**) |

Three of these were mutations of review round one, and the first of them is the
one that mattered: it reproduced the nested-`object` **panic** rather than a
wrong answer, and the three tests named against it are the ones that now hold it
in place. Eight more were run for review round two, and seven for review round
three, and all are in the table.

Two mutations were also checked to *compile*: `-D warnings` is in effect in this
tree, so a mutation that left an unused variable would have failed to build and
its "test result: ok" would have been a stale binary. One did exactly that, and
was re-run with a mutation that keeps the variable live.

### Three harness defects the harness's own tests caught

All three were mine, all three were found by the file that was supposed to be
trustworthy:

1. **Two copies of the frontend pipeline.** `tree_walk` reported "printed
   nothing" for every faulting program, because the copy that computed the
   outcome returned an empty output on any failure. That made the runner disagree
   with the bytecode VM about *every* program that printed before it faulted, and
   it made `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away`
   fail on its own premise. Fixed by one `tree_walk_verbose` returning
   `(Vec<String>, Option<Error>)`; `tree_walk` and `tree_walk_failure` are both
   thin wrappers on it.
2. **`shrink` could loop forever.** It accepted any candidate the predicate held,
   and `without_line` on a one-line source returns `"\n"` — which `without_line`
   on `"\n"` returns again. A predicate satisfied by an empty reduction never
   returned. Fixed by the strictly-shorter rule, pinned by
   `edge_the_shrinker_accepts_a_candidate_only_when_it_is_shorter` so the mutation
   *fails* rather than hangs.
3. **The arm-reachability check replicated the draw it was checking.** The first
   version of `edge_every_kind_is_reachable_and_its_arms_produce_it` computed
   each seed's arm index itself, from the arm table's length — which is the same
   bound `expression` uses, until `expression` stops using it. Clamping the index
   inside `expression` to leave the last arm unreachable passed that test. The
   draw now lives in `expression_with_arm`, the test calls *it*, and the same
   mutation fails. A test that recomputes the thing it is checking is a second
   implementation, and a second implementation agrees with a bug.

A fourth defect was mine and is not a defect in the harness: the first version of
the position helper kept only the analyzer's and the VM's errors, so it reported
as a corpus defect a program the corpus had recorded correctly. It is now
`vm::tree_walk_failure`, on the one pipeline.

## Edge-case matrix

| Row | Covered? |
|---|---|
| empty | covered — `lists` holds `[]` and `for each` over it, `text-ops` holds `length("")` and `say ""`, `stdlib` holds `length([])`/`type_of([])`/`type_of({})`, `control-flow` holds an empty `then`, `loop-forms` holds `repeat 0 times`, `records` holds `{}` and `length({})` |
| singleton | covered — one-element list (`length([1])`, `xs[0]`), one-field record, `repeat 1 times`, `length("a")`, `for each` over `[1, 2]`, `to zero()` |
| boundary | covered — index `0`, `len-1`, `[-1]`, `[-3]`, `xs[2-2]` in `lists`; `2147483647`, `2147483647+1`, `-2147483648`, `9223372036854775807`, `-9223372036854775808`, `9007199254740992`, `9007199254740993`, `0.1+0.7` in `numeric-boundary`; loop counters at `repeat 0` and `repeat 10` |
| out_of_bounds | covered — `faults` holds index `len`, index `1` of a 1-list and `xs[9]` of a 2-list; `runtime-errors` holds the same three inside `catch`. Each records the exact message, e.g. `Index 0 is out of bounds: length is 0, the list is empty, so it has no valid index` |
| type_mismatch | covered — `faults` holds number+text, list+text, yes+number, nothing+number, text−number, text×number, index-on-number, index-on-record, index-on-`nothing`, `length({})`, `length(yes)`, `length(nothing)`, an unknown function, property-on-`nothing`; and `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints` covers the **golden side** of the same class, since `Number(5)`/`Text("5")` and `Nothing`/`Text("nothing")` are a type mismatch a `#value 5` could not see |
| numeric_boundary | covered — `numeric-boundary`: `1/0`, `0/0`, `9%0`, `n/0`, `1/-0.0`, `0.1+0.2`, `1/3`, `-0.0`, `-7/2`, `7/-2`, `-7%3`, `7%-3`, `9%9`, and the `i64`/2^53 edges |
| unicode | covered — `unicode`: CJK, emoji, ZWJ (`👩‍💻`), RTL (`مرحبا`), astral (`𠮷`), accented, arrow/∞, BOM-prefixed source, `length` and equality on each; plus `text-ops` for `\\`, `\"`, `\n`, `\t`. **Not covered:** combining marks written in source, because `\u` escapes are dropped (`FINDINGS.md` §12) |
| nesting_recursion | covered — `nesting` (lists and records 4–7 deep, a walk down every level, `if` nested 4 deep, triple-nested loops), `functions` (a function bound to a variable, a function passed as an argument, two `give back`s), `objects` (inheritance two deep). **Terminating recursion is not covered and cannot be** — `give back` inside a conditional does not return (`FINDINGS.md` §5); the family holds iteration-as-recursion instead. A closure declared inside a function is also unreachable (`FINDINGS.md` §6) |
| duplicate_missing_keys | covered — `records` holds a repeated key (`{a: 1, a: 2}` keeps the last), a missing key (`nothing`), a missing key two levels down (`r.a.missing`), a missing key three levels down (`r.b.c.missing`), and aliasing (`set s to r` then writing through `s`); `objects` holds a missing field |
| malformed_input | covered — `malformed` (31 programs) and `labels` (10), plus `edge_a_malformed_expected_file_is_rejected` (9 rejected `.expected` files) and the shrinker's minimality tests, which reduce to malformed programs |
| resource_limit | covered — `runtime-errors` and `faults` hold every catchable runtime error and prove it is catchable rather than fatal; `malformed` holds 31 frontend failures and `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` proves a frontend failure printed nothing; the property tests run 320 generated programs through both VMs and assert no panic anywhere; `edge_every_recorded_failure_points_at_a_line_of_its_own_program` checks every failure's position against a real line and column of its own program; `the_corpus_holds_programs_that_are_worth_something` records and compares the value of every successful program rather than assuming it; `edge_a_limit_left_in_the_environment_cannot_change_an_outcome` and the suite run under `REDBLUE_MAX_STEPS=1` say the limits cannot move under it either |
| value_bearing_tail | covered — the `value-tails` family (26 programs, 25 worth something on **both** VMs: eight numbers, two texts, `yes`, `no`, two lists and two records), plus `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output`, which requires at least half of the completed generated programs to be worth something |
| generator_well_typed | covered — `edge_a_generated_program_only_faults_on_a_fault_that_was_injected`: every generated program carrying no injected fault runs to completion, **and every generated program carrying one fails on that fault and no other**, which makes `FAULTS` the *only* source of failure and the *only* fault. It found one broken arm in its first run; `edge_every_declared_fault_has_a_tail_that_faults` then held the six tails to six different failures, and `edge_every_kind_is_reachable_and_its_arms_produce_it` holds every arm of the typed grammar to the kind it claims |

## Review round 1 — the six findings

A reviewer read the diff and returned six findings: one BLOCKER, two MAJOR, two
MINOR and one STYLE. All six are closed. What each one turned out to be:

### 1. [BLOCKER] a nested `object` panicked the bytecode VM — closed in `src/`

`object Inner` written inside `Outer`'s own body is accepted by the analyzer and
runs on the tree-walking VM: `declare_object` (`src/vm.rs`) collects the `has` and
`to can` of the body, registers the type, binds it, and only then runs the rest of
the body in the enclosing scope. The bytecode VM kept one `pending_object`,
overwritten by the inner `DEF_OBJECT`, so the inner body took it and the outer
body reached for a declaration that was gone:

```
thread 'main' panicked at src/bytecode/vm.rs:941:14:
an object declaration being assembled
  4: <redblue::bytecode::vm::BytecodeVm>::finish_object
  5: <redblue::bytecode::vm::BytecodeVm>::unwind_frame
```

A stack of pendings would have stopped the panic and left a worse bug: with the
stack, the inner type finishes *first*, so `object Child extends Base` written
inside `Base`'s body would fail with `Object 'Child' extends 'Base', which is not
declared` on one VM and succeed on the other — a divergence rather than a crash.

So the fix is in the lowering, not in the slot. An `object` body now compiles as
two halves (`src/bytecode/codegen.rs`, `Declared`): the `has` and `to can` go into
the block that assembles the type, and everything else compiles into the
*enclosing* block, after the `STORE` that binds it. That is the tree-walking VM's
order, so by the time a nested `DEF_OBJECT` runs the enclosing type is registered
— the parent is there to extend — and nothing is overwriting a pending. The
single `Option` is then correct rather than lucky, and `finish_object` reports
`an object body finished with no declaration to register` for a file the compiler
did not write instead of asserting.

The corpus now holds two nested-object programs (`objects-0017`, `objects-0018`),
the second extending the type it is written inside, and
`edge_a_nested_object_runs_on_both_vms_and_neither_panics` holds six more.

### 2. [MAJOR] the harness ran every program twice — closed in `tests/`

`tree_walk_verbose` returned the failure and discarded the value, and `tree_walk`
re-lexed, re-parsed and re-executed the whole program to read the value back —
through `.expect()` panics rather than errors. Every corpus comparison therefore
executed each program twice, and for a program with a side effect the value
compared was the *second* run's. `tree_walk_verbose` now returns
`(Vec<String>, Result<Value, Error>)` from the one run it already made, and both
wrappers are arithmetic on it. `edge_one_run_of_a_program_is_all_the_harness_asks_for`
runs a program that **appends** twice to a file under `target/tmp` and asserts the
file holds `ab`; the mutation puts `abab` there.

### 3. [MAJOR] the `loop-forms` family held a program that was not a loop — closed in `tests/`

`loop_forms`'s last entry was `set xs = []`, a malformed `set` that fails in the
lexer — so the family counted a loop while testing none. `malformed` already
holds `set xs = 0` and `set x = 1`, so moving it there would have added nothing.
It is now a real loop form: `skip` and `break` inside `for each`, which pin that
both are accepted and neither leaves the loop (`total` is 12, not 6) →
`FINDINGS.md` §13.

### 4. [MINOR] `corpus()` hid an unreadable entry — closed in `tests/`

`.filter_map(|entry| entry.ok())` dropped a directory entry it could not read, so a
program the harness cannot see would have shrunk the coverage instead of failing
it. It now panics naming the directory, like the `read_dir` failure beside it.

### 5. [MINOR] the fault list's doc said five — closed in `tests/`

`FAULTS` holds six entries and its doc said five. The comment says six. The
coverage assertion that pins the list reads the array, not the comment, so nothing
was miscounted — which is exactly why the drift could sit there unnoticed.

### 6. [STYLE] a duplicated doc sentence — closed in `src/`

The `is_last` paragraph in `Compiler::statements` appeared twice, word for word.
One copy.

## Review round 2 — six findings about the harness itself

The first review asked whether the *language* was right. This one asked whether
the *harness* could fail, and found six places where it could not. One BLOCKER and
five MAJOR, all closed. What each one was:

### 1. [BLOCKER] `the_checked_in_corpus_is_the_one_the_generator_produces` never read the corpus

The test asserted `generated.len() >= 200` and nothing else. It never opened
`corpus/`, so it could not tell a corpus that had drifted away from its generator
from one that had not: edit a program's source, delete a file, delete every
`.expected` — all 319 files could be wrong and the test passed. Its own doc
comment claimed it compared the checked-in corpus against the generator, and the
test beside it did that; this one claimed the same and did not.

It now reads every program off disk and compares the two sets — `missing from
disk`, `on disk but not generated`, and any name whose **source** differs — and
reports the file names. Verified by mutation, both directions:

```
$ printf 'say 999\n' >> corpus/arithmetic-0001.rb && cargo test --test differential_test \
    the_checked_in_corpus_is_the_one_the_generator_produces
the checked-in corpus is not the one the generator produces:
["lists-0001.rb"] missing from disk, [] on disk but not generated
```

### 2. [MAJOR] a program's value was compared as the *word it prints*

`Outcome.result` was `Result<String, String>` built from `Value::to_string()`,
and `Value`'s `Display` cannot tell `Number(5)` from `Text("5")`, nor `Nothing`
from `Text("nothing")`. Those are not corner cases: they are two of the pairs the
language's own values form. A bytecode VM that returned the *text* `"5"` where
the tree-walking VM returned the *number* `5` would have been reported as
agreement.

`Outcome.result` is now `Result<Value, Failure>` — a typed value, compared by
derivation — and `Outcome` is `PartialEq` rather than `Eq` because a `Value`
holds an `f64`. The `.expected` format is unchanged (`#value` still records what
the program *printed* as, which is the golden file's job);
`edge_a_number_and_the_text_that_spells_it_are_different_outcomes` pins the
distinction by asserting that the two renderings **collide** and the two values
do not.

### 3. [MAJOR] a failure's position was dropped, and never compared

`failure_of` returned `"<label>: <message>"` and nothing else, on the stated
grounds that a `.rbc` carries no source text to *render* a position from. That is
a rendering question; this was a comparison question, and both VMs do have the
position. So a line or a column that moved on either VM — a real regression in
the language — passed every test in the suite.

`Failure` now carries `label`, `message` **and** `position`, the `.expected`
format has a `#position <line>:<column>` directive that is *required* for a
failure and *refused* for a program that ran, and `compare` checks it. The 75
failing corpus programs were re-recorded: each `.expected` gained one line, and
the 242 that succeed are byte-identical to what was checked in. Four new
rejections pin the format (`#position` absent, duplicated, malformed, and on a
`#label none`), and the corpus turns out to agree exactly: **every** one of the
75 failures is at the same line and column on both VMs, which is what the new
`edge_both_vms_place_every_failure_at_the_same_line_and_column` asserts.

### 4. [MAJOR] the expression-tail assertion could not fail

The generator's own test asked whether any line of a generated program was
neither `set`, `say`, `end` nor `for each` — and `if v1 is v1 then`, `repeat 3
times` and `set xs to [1]` all satisfy that. So the check for "the generated
programs end in a value" passed with **zero** bare-expression tails, which is the
coverage it exists to guarantee.

It now reads each program's **last** line, against a list of every keyword that
opens a statement. 227 of 400 generated programs end in a bare expression; the
gate requires 40% of them, so losing the tail entirely fails by a wide margin.
Verified by making the generator emit `say 1` as its tail:

```
only 0 of 400 generated programs end in a bare expression; every program
ending in a statement is worth `nothing`, so the value comparison has nothing
to compare
```

### 5. [MAJOR] the harness's outcomes followed the environment

`Vm::new()` and `BytecodeVm::new()` resolve `REDBLUE_MAX_STEPS`,
`REDBLUE_MAX_ITERATIONS` and `REDBLUE_MAX_CALL_DEPTH` from the environment, and
the harness built both VMs with `new()`. A `REDBLUE_MAX_STEPS=1` left over from
anywhere would have made every corpus program fail differently, and the golden
files would have meant whatever that machine said.

Both VMs are now built with `with_limits(...)` at fixed values
(`tests/common/vm.rs`), which needed one addition to `src/`: the three existing
`with_max_*` constructors each replace one limit and leave the other two to the
environment, so there was no way for a caller to be reproducible. `Vm::with_limits`
and `BytecodeVm::with_limits` set all three; they are additive and change no
default. The tree-walking run is a thread sized from the same depth limit, as
`run_isolated` does it, because 64 frames do not fit in a 2 MiB test thread.
`edge_a_limit_left_in_the_environment_cannot_change_an_outcome` sets all three
variables to `1` and asserts the outcome does not move; with `Vm::new()` put back
it fails, exactly as it should:

```
assertion `left == right` failed: the outcome followed the environment, so it
would not reproduce anywhere else
  left: Outcome { output: ["3"], result: Ok(Number(3.0)) }
 right: Outcome { output: [], result: Err(Failure { label: "RuntimeError",
         message: "Step budget of 1 reached before the program finished", … }) }
```

### 6. [MAJOR] 320 distinct programs out of 320 seeds was a coin toss

The statement grammar has seven arms, the expression grammar six kinds, and the
fault tails are six fixed strings — so two seeds landing on the same program is a
property of the grammar, not a defect, and demanding perfection made a benign
collision fail the gate. That is the worst kind of gate: the pressure it creates
is to widen the grammar or add seeds until the collision stops happening, neither
of which checks anything.

`edge_almost_every_seed_produces_a_program_of_its_own` now requires ≥ 95% distinct
programs, and names any program two seeds share, so "5% is allowed" cannot become
"any number is allowed". A generator that ignored its seed would collapse to one
or two programs and fail by a mile.

## Review round 3 — five findings, and a real divergence behind one of them

The first review asked whether the *language* was right, the second whether the
harness could fail, and this one asked whether the harness could fail *about the
right things*: whether its comparisons compare the thing they name, whether they
run in parallel safely, and whether the generator's own coverage claims are
reachable. One BLOCKER and four MAJOR, all closed. The fourth turned out to be
hiding a divergence between the two VMs that no test could see.

### 1. [BLOCKER] the environment test raced the rest of the binary — closed in `tests/`

`edge_a_limit_left_in_the_environment_cannot_change_an_outcome` set all three
`REDBLUE_MAX_*` variables with `std::env::set_var`, asked the tree-walking VM one
question, and then `remove_var`d them. Three things wrong with that, and only the
first was about the assertion:

- `cargo test` runs a binary's tests in parallel threads over **one** process
  environment, so the write decided other tests' results by scheduling order.
  That is not a flake to wait out; it makes every other test in the binary
  untrustworthy while it is in flight.
- `remove_var` after a `set_var` is not a restore. A developer who ran the suite
  with `REDBLUE_MAX_STEPS` set to something of their own would find it gone.
- only `tree_walk` was asked. `BytecodeVm::new()` resolves the same three
  variables, so a bytecode VM built with `new()` would follow the environment
  too, and the test would have said so about half the harness.

`EnvLimits` now takes a process-wide `Mutex` and restores every variable it
changed — `set` back to what it was, `remove`d if it was not there — on drop,
including the panicking path. Both engines are asked, and the test carries a
**control**: while the variables are pinned to `1`, a VM built the way the
interpreter's own `run` builds one *does* come out differently. Without that
half the assertion would also pass if the harness's limits had stopped being
limits, which is the same class of claim that cannot fail.

Verified three ways — the harness built with `new()` again, the guard restoring
nothing, and the whole suite under `REDBLUE_MAX_STEPS=1` — with the last one
failing until the control was given the one exemption it needs: when the variable
is *already* `1`, pinning it to `1` changes nothing, and that is exactly the state
the pollution run puts the suite in.

```
$ REDBLUE_MAX_STEPS=1 REDBLUE_MAX_ITERATIONS=1 REDBLUE_MAX_CALL_DEPTH=1 \
    cargo test --test differential_test
test result: ok. 62 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

### 2. [MAJOR] the golden file recorded a value as the word it prints as — closed in `tests/`

`record` wrote `#value 5` for a program worth the number `5`, and `compare`
compared `value.to_string()` against it. `Value`'s `Display` renders a `Text`
bare, so `Number(5)` and `Text("5")` are one golden line, and so are `Nothing`
and `Text("nothing")` and `YesNo(true)` and `Text("yes")` — four collisions the
language's own value set makes, not corner cases. A bytecode VM returning the text
`"5"` where the tree-walking VM returned the number `5` was recorded as
*agreement*, which is the shape of divergence that matters most.

`#value` now records a **type and a rendering** (`number:5`, `text:5`,
`yes/no:yes`, `list:[1, 2]`, `record:{a: 1}`), and `compare` compares that. The
19 valued `.expected` files were re-recorded; the other 300 are byte-identical.
`nothing` is deliberately the one untagged spelling, because it is what an
*absent* `#value` means — and `edge_a_recorded_value_names_the_type_and_not_only_
what_it_prints` asserts both halves: that the untagged spelling is **rejected**
for a typed value, and that the absent line and the written one would collide if
`nothing` were tagged too.

### 3. [MAJOR] an injected fault only had to be *a* fault — closed in `tests/`

`edge_a_generated_program_only_faults_on_a_fault_that_was_injected` asserted
`is_err()` for every program carrying an injected fault. *Some* failure is not
*the injected* failure: a statement arm that faulted — a `set` of the wrong type,
an index off the end — would have satisfied it, and the generator's fault
injection would have been untested. `fault_tail` is now a table the property test
can read, and for every seeded program it runs the tail **alone** and requires
the whole program's failure to be that failure: same label, same message, and the
same position shifted down by exactly the height of the generated prefix.

```
$ # one statement arm now faults, which is what a prefix defect looks like
test edge_a_generated_program_only_faults_on_a_fault_that_was_injected ... FAILED
the program failed, but not on the fault that was injected into it (index past the end)
```

Mutation-checking that found a second hole in the same direction, which is now
closed by `edge_every_declared_fault_has_a_tail_that_faults`: pointing
`"text minus a number"` at `say nothing.a` is consistent as far as the property
test is concerned — the program does fault, and it does fault on that tail — so
six names for five failures passed. Each tail now has to fault on **both** engines
and produce a failure no other tail produces. What that cannot check is that each
*name* describes its failure, which is why the names are English and not an enum,
and why the corpus's `faults` family pins each of the six messages by hand.

### 4. [MAJOR] every recorded column was 1, and the two engines disagreed about the rest — closed in `src/` and `tests/`

`line_span` in `src/bytecode/vm.rs` answers `Span::new(line, 1)` for every
instruction, because a bytecode instruction carries a line and no column
(`docs/BYTECODE.md`). The tree-walking VM reported the **statement's** column. So
for any program with an indented statement, the two engines reported the same
failure at two different places — and the corpus held no indented runtime
failure, which is why `edge_both_vms_place_every_failure_at_the_same_line_and_
column` agreed on all 75 recorded failures while the divergence stood one
indented `say` away:

```
set xs to [1]
if 1 is 1 then
    say xs[9]
end

  tree-walking VM: RuntimeError … Span { line: 3, column: 5 }
  bytecode VM:     RuntimeError … Span { line: 3, column: 1 }
```

The fix is in `src/vm.rs`, not in the corpus. `statement_span` reports the
statement's **line** at column 1, which is the position both formats can carry —
and the two remaining ways to do better both change the `.rbc` layout or the
grammar, so they are written down in `FINDINGS.md` §15 rather than done quietly.
This is a `must_touch` departure like the three before it, and for the same
reason: a harness that compared only printed lines, or that kept such a program
out of the corpus, would have called this fixed.

Two new corpus programs (`faults-0019`, `faults-0020`) and one new test pin it —
four runtime failures, two of them indented, at the line and column 1 on both
engines — and the pre-existing `tests/span_test.rs` assertion that pinned the old
`2:5` was **updated, not deleted**, with the reasoning above in its message. The
column claim is now also *measured*: `edge_both_vms_place_every_failure_at_the_same_
line_and_column` counts the recorded failures at a column other than 1 (30 of 77,
all of them frontend failures), because a comparison of two positions that are
both `line:1` passes no matter how many failures there are.

### 5. [MAJOR] the expression grammar's arms were never shown to be reachable — closed in `tests/`

`edge_every_kind_is_reachable_and_its_arms_produce_it` ran 30 seeds per kind and
asserted each run was `Ok`. A **dead arm** — one `expression` can no longer
select — is never built, so nothing in the test asked whether it could have been,
and the typed grammar could have lost arms without a word.

`expression` now selects from a **table** of named arms (`expression_arms`), so an
arm is reachable because it is in the list, and `expression_with_arm` reports which
arm it drew so reachability is observable rather than argued. Per kind, per arm,
the test builds the arm's expression by index and asks the **interpreter** what it
is worth — `type_of`, on both engines — so a `Text` arm that builds a number fails
here — and every arm index must come up over 600 draws through the same function
that does the drawing.

The first version of that last half replicated the draw (`rng.below(arms.len())`)
instead of calling it, and mutation-checking proved the difference: clamping the
index in `expression` to `arms.len() - 2` — leaving the last arm of every kind
unreachable — passed the replication, and fails when the draw is the real one.

## Gates

Run in the order `AGENTS.md` §3.4 gives.

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass — no diff |
| `cargo clippy --all-targets -- -D warnings` | pass — 0 warnings |
| `cargo test --all-targets --no-fail-fast` | **556 passed, 0 failed, 0 ignored** (24 test binaries); `cargo test --doc`: 1 passed |
| `./rbops/verify.sh phase-020` | **not run — `rbops/verify.sh` does not exist in this checkout** (`FINDINGS.md` §9) |

One honest note about that third row, because a green run that is green *usually*
is worth more than one that is green always by accident: **one** of the twelve
full-suite runs in this round reported 555 passed and 1 failed, and the failing
test's name was lost with the pipe. It has not reproduced in eleven runs since —
six of them with the whole log kept — and the differential binary alone was run
fifteen more times under deliberate load. The only timing-sensitive tests in the
tree are `tests/stdlib_modules_test.rs`'s network timeouts, which this phase does
not touch, and neither engine's `with_limits` can be reached by the pollution
this phase introduces (both overwrite all three limits), so nothing here can be
pointed at as the cause. It is recorded rather than rounded off.

556 rather than the 553 of round two, the 546 of round one and the 495 of the
resume commit: 62 tests replaced the 7 the interrupted attempt had, none was
deleted, renamed to be skipped, or given an `allow`. All 495 pre-existing tests
still pass — the one that changed is `tests/span_test.rs`'s runtime position, and
it was **updated to the new contract rather than removed**, with the reason in its
message. The sixteen added by the three review rounds are additions to a passing
suite rather than replacements within it.

On the fourth gate, honestly: there is no `rbops/` directory in this checkout at
all, and the task instructions say the pipeline that dispatched this phase lives
outside the checkout and is not to be inspected. The three gates that do exist
were run and are green. In their place, the backwards-compatibility check
`AGENTS.md` §2 names:

```
$ for f in examples/*.rb modules/*.rb; do ./target/debug/rb run "$f"; done
ok examples/files.rb   ok examples/fizzbuzz.rb   ok examples/formats.rb
ok examples/hello.rb   ok examples/test_arithmetic.rb   ok examples/time.rb
ok modules/MathUtils.rb   ok modules/SuiteKit.rb
```

All eight run clean. Three files under `src/` changed across the three review
rounds, so this was re-checked rather than assumed — it is a check that `src/` did
not change behaviour the examples depend on, and it passed.

The gate is also independent of the environment now, which is finding 5 above
measured directly rather than argued — and finding 1 of round three had to make
that true *under* the pollution rather than around it:

```
$ REDBLUE_MAX_STEPS=1 REDBLUE_MAX_ITERATIONS=1 REDBLUE_MAX_CALL_DEPTH=1 \
    cargo test --test differential_test
test result: ok. 62 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

Determinism was checked by regenerating and comparing checksums:

```
$ before=$(cat corpus/* | sha256sum)
$ RB_WRITE_CORPUS=1 cargo test --test differential_test regenerating
$ after=$(cat corpus/* | sha256sum)
DETERMINISTIC: regeneration is byte-identical
```

## Invariants touched

- **None of the language.** No syntax or grammar changed. The `Value` and `Error`
  variants, the `.rb` extension, `to … end` / `if … end` / `for … end`, `set x to`,
  `say`, and the trailing-comma syntax are all untouched, and all 495
  pre-existing tests still pass.
- **One thing about what a program *is worth* changed on the bytecode VM**, which
  is documented as an invariant and is called out here rather than buried:
  - a program ending in a bare expression now ends with that expression's value on
    the bytecode VM, as it already did on the tree-walking one (`FINDINGS.md` §1);
  - a statement consumes everything it produced, so `set r.a to 2` no longer leaks
    a record onto the operand stack and `if … then 7 … end` no longer leaves `7`
    for the enclosing block. Both were invisible before, because the top-level
    frame discarded whatever it finished with; they are the same bug wearing a
    second hat.
  Neither changes a `.rbc`'s byte format (`Opcode::ALL` is untouched and the
  byte-value assertions in `tests/bytecode_test.rs` still pass), so the bootstrap
  ladder's S1 artifact is unaffected, and neither changes the `.expected` format.
- **One thing about *when* an object body runs changed on the bytecode VM**, added
  in review round one and called out for the same reason: an object's body is two
  halves, and the half that is not `has`/`to can` now compiles into the enclosing
  block and runs after the type is registered and bound — the tree-walking VM's
  order (`declare_object`), and the only order in which `object Child extends
  Base` written inside `Base`'s own body has a `Base` to extend. A body whose only
  statements are `has` and `to can` compiles to the same bytes as before, so the
  object's byte-level assertions are unaffected; what changes is the placement of
  every other statement an object body can hold (`say`, `set`, a nested `object`),
  which used to run inside the declaration's frame before the type existed.
- **The `.expected` format gained one directive** in review round two: a failure
  now records `#position <line>:<column>` (or `#position none`), required for a
  file with a label that is not `none` and refused for one that is. This is the
  golden format, not the language, and the 242 `.expected` files whose programs
  succeed are byte-identical to what was checked in before; the 75 that fail each
  gained exactly one line. `src/vm.rs` and `src/bytecode/vm.rs` each gained one
  additive constructor, `with_limits`, and nothing about a default changed: a
  caller that builds a VM with `new()` still reads `REDBLUE_MAX_*`.
- **The `.expected` format gained a type tag on `#value`** in review round three:
  `number:5`, `text:5`, `yes/no:yes`, `list:[1, 2]`, `record:{a: 1}`, and
  `nothing` alone. Again the golden format rather than the language — a program
  still prints and is still worth what it was worth — and again the 19 valued
  files are the only ones that changed.
- **One thing about *where* a runtime failure happened changed on the tree-walking
  VM**, added in review round three and called out for the same reason: a runtime
  failure now names the **line** of the statement that failed, at column 1, where
  it named that statement's own column. Two engines reporting one failure at two
  places is a divergence in the language, and the bytecode format carries no
  column, so the line is what both can answer (`FINDINGS.md` §15 for what is
  still missing — the caret for an indented runtime failure is now drawn at the
  start of its line). Only `Error::span()` and the rendered caret are affected;
  the label and the message are untouched, and a **frontend** failure still
  carries the offending token's own line and column.
- **One placement decision.** The corpus lives at `corpus/`, not `tests/corpus/`.
  `redblue::testing::find_test_files("tests")` (`src/testing/mod.rs:64`) walks
  `tests/` recursively and `redblue_suite_test.rs:110` requires every `.rb` file
  it finds to declare Redblue `test` blocks with an assertion in them. A corpus
  program declares none, and *"a corpus program is not a test"* is the right thing
  for that test to say — so the corpus goes where the suite's collector does not
  walk, which is also where the phase's definition of done asks for it.

## Known gaps / follow-ups

- **There is no comparison operator that lexes, so there is no `while` and no
  bounded loop written as a condition.** `<`, `>`, `<=`, `>=`, `==`, `!=`,
  `is less than`, `is greater than` and `in` are all documented in
  `docs/GRAMMAR.md:95-98` and none works. `AGENTS.md`'s own first example does
  not parse → `FINDINGS.md` §2.
- **The corpus cannot cover the documented standard library.** 23 of the 25
  registered builtins are unreachable from Redblue source → `FINDINGS.md` §7.
- **The corpus cannot hold a terminating recursion** (`give back` inside a
  conditional does not return) or a closure declared inside a function →
  `FINDINGS.md` §5, §6.
- **A `catch` cannot read the value it caught** — it binds the text `"error"` →
  `FINDINGS.md` §8.
- **Trailing tokens on a line are silently accepted** (`say 1 2 3` prints `1` and
  is worth `3`) → `FINDINGS.md` §4.
- **`\u` escapes are dropped rather than refused**, so a combining mark cannot be
  written in source and a mistyped escape is swallowed → `FINDINGS.md` §12.
- **`length` counts bytes, not characters** → `FINDINGS.md` §11.
- **`skip` and `break` are accepted and do nothing.** `for each x in [1, 2, 3]` /
  `if x is 2 then` / `break` / `end` / `say x` / `end` prints 1, 2, 3 →
  `FINDINGS.md` §13. Both VMs agree, so the corpus pins the current behaviour
  rather than a divergence; `src/vm.rs:680` carries the `TODO`.
- **An `object` declared inside another object's body cannot be named outside
  it.** The type is registered and bound at runtime, but the analyzer declares the
  name in the body's own scope, so `say Inner.b` after the body is an
  `AnalyzerError` → `FINDINGS.md` §14. `corpus/objects-0017.rb` is written the
  only way such a program can be written.
- **A runtime failure's column is always 1**, so `Error::render` draws the caret
  for an indented runtime failure at the start of its line. The two ways to do
  better — reporting the failing *expression*, or putting a column in the 13-byte
  instruction — are written out in `FINDINGS.md` §15, and the second one changes
  the bootstrap ladder's S1 artifact, which is why neither was done here.
- **The generator's grammar is typed**, so it cannot generate a type-mismatched
  program by accident; `FAULTS` injects those on purpose. That is a deliberate
  limit — a generator that produced mostly type errors would assert only that
  errors happen, which `edge_the_generator_does_not_produce_nothing_but_failures`
  fails on.
- **The corpus regenerates only when `RB_WRITE_CORPUS=1` is set.** A CI job that
  set it would rewrite the golden files instead of failing on a regression.
  `the_checked_in_corpus_is_the_one_the_generator_produces` refuses to run at all
  in that case rather than comparing the corpus against itself.
- **A property-harness phase cannot see a defect both VMs share.** Fourteen of
  the fifteen items in `FINDINGS.md` are limitations of the language that the two
  VMs agree on, which is exactly the class a *differential* harness is blind to.
  Only §1 was visible to this phase, and only because the harness compared
  something other than printed output — and, in review round one, only because the
  reviewer's own reading of the object path was asked a question the corpus had
  not been.
- **A harness can be wrong in the same direction as the thing it is checking.**
  All eleven findings of review rounds two and three were of that kind — a
  comparison that could not fail, a value compared as the word it prints, a
  position that was never compared, a coverage assertion satisfied by the wrong
  lines, an outcome that followed the environment, a gate demanding a coin toss,
  a test that raced the binary it ran in, a fault injection that only had to be
  *a* fault, a position column that could never move, and arms of the generator
  that were never reached — and none of them was visible from the language side.
  Two of them were hiding real defects (a value compared as its rendering, and
  the position column), and one of those was hiding a *divergence between the
  two VMs*. A green differential gate says the two VMs agree; it does not, by
  itself, say what they were asked, or whether the question could have a different
  answer next time.
- **`rbops/verify.sh` was not run because it is not present** → `FINDINGS.md` §9.