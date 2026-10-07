# Phase 020 — Differential + property test harness

## What changed

| File | Lines | What |
|---|---|---|
| `corpus/<family>-NNNN.rb` + `.expected` | +340 programs, +340 golden files | the corpus: **340 programs** across 16 families, each paired with the outcome the tree-walking VM produced — printed lines, the value the program was worth **as a type and a rendering**, and a failure's label, message **and** position |
| `tests/common/generator.rs` | +1493 | the two generators: 16 curated corpus families, and `generate` — a *typed* grammar over a seed, depth-bounded so a program's size is bounded, which **only ever faults on a fault it injected on purpose and fails on that fault and no other**, with every expression **arm** in a table that can be enumerated and asked what it is worth |
| `tests/differential_test.rs` | +1128 −232 | 32 tests: 17 over the corpus and its golden format, 9 over generated programs, 6 over the harness's own failure paths |
| `tests/common/corpus.rs` | +653 | the corpus on disk: the loader, the escaped `.expected` format (with its `#position` directive and its **type-tagged** `#value`), its writer, and `compare` |
| `tests/common/shrink.rs` | +290 | delta debugging: a line pass then a character pass, with `without_line`/`without_char`/`shrinks_to` exposed so the minimality assertion tests the shrinker's own decisions |
| `tests/common/vm.rs` | +396 | `Outcome`, `Failure`, `tree_walk_verbose`, `tree_walk`, `bytecode` — one program, two VMs, one comparison, **one run each**, **typed values**, limits that are not read out of the environment, and the one guarded door to that environment (`EnvLimits`) |
| `tests/common/rng.rs` | +137 | SplitMix64 written out: a fixed-integer generator, so a seed rebuilds the same bytes on any machine and any rustc |
| `tests/common/mod.rs` | +21 | the module list, and why the harness is test-only |
| `src/bytecode/codegen.rs` | +83 −13 | only a block whose value is *read* (`main`, `Function`, `Method`) leaves one behind; an `if` branch, a loop body, a `try` body and a module body are statements and consume what they produced; and an `object` body compiles as two halves, so a nested `object` no longer panics the bytecode VM |
| `src/bytecode/vm.rs` | +35 −5 | the outermost frame's value *is* the program's value; `SET_PROPERTY` consumes its receiver, as `docs/BYTECODE.md:180` says it does; and `with_limits` sets all three limits at once |
| `src/vm.rs` | +46 −2 | `Vm::with_limits` and `run_isolated_with` — the same constructor on the tree-walking side, because the three `with_max_*` constructors each replace one limit and leave the other two to the environment; and `statement_span`, so a runtime failure names the **line** it happened on and both engines answer the same |
| `src/lib.rs` | +3 −2 | the two new names re-exported |
| `tests/span_test.rs` | +11 −2 | the one pre-existing assertion that pinned the *old* runtime position, updated rather than deleted: it now states the line-at-column-1 contract and says why |

Line counts are `git diff --numstat` against the resume commit `5d5ea00`, except
the new files.

## Reproduction of the finding

The finding — *"No differential or property testing infrastructure exists; this
is what makes S3 provable"* — **reproduced**. The resume commit `5d5ea00` added
a runner (`tests/differential_test.rs`, 333 lines) and **no corpus at all**, so
six of its seven tests failed:

```
$ cargo test --test differential_test
thread 'every_corpus_program_has_an_expected_output_file' panicked at
  tests/differential_test.rs:115:23:
corpus directory …/tests/corpus should be readable: No such file or directory (os error 2)
test result: FAILED. 1 passed; 6 failed; 0 ignored; 0 measured; 0 filtered out
```

**The previous attempt's REPORT.md was not believed and was wrong.** It claimed
`corpus/`, `tests/common/`, a 73-test suite and three `src/` changes. The tree
contained only the 333-line runner, no `corpus/`, no `tests/common/`, and no
`src/` changes at all. Nothing from that report was taken on trust; the work was
redone and every claim below was re-measured.

### What the harness itself turned up, and why it cost four changes in `src/`

The runner compares *what a program is worth*, not only what it printed. Writing
that comparison is what made the divergence visible:

```
$ set t to 5 / say t / t
  tree-walking VM: Ok(Number(5.0))
  bytecode VM:    Ok(Nothing)
```

`src/bytecode/vm.rs:989` threw the last frame's value away unless the frame was a
*call*, so the top-level frame — which is not a call — always answered `nothing`,
while `src/vm.rs` keeps the value of the last statement. Three more leaks became
visible the moment that stopped being discarded, and a fourth was a disagreement
about *where* a failure happened. `FINDINGS.md` §1 carries all four with
file:line, and says why `must_touch: ["tests/"]` had to be widened.

The corpus also found a fifth thing, and it is a reachable panic rather than a
wrong answer. Three programs were added to the `objects` family that no prior test
in the tree held:

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

$ cargo test --test differential_test edge_regenerating
thread 'edge_regenerating…' panicked at src/bytecode/vm.rs:1026:14:
an object declaration being assembled
```

`object Inner` inside `Outer`'s own body is accepted by the analyzer and runs on
the tree-walking VM; the bytecode VM kept one `pending_object`, so the inner
`DEF_OBJECT` overwrote the outer one's and the outer frame then reached for a
declaration that was gone. The fix is in the lowering, not the slot — an object
body compiles as two halves — so an inner declaration runs *after* the enclosing
type is registered and bound. A stack of pendings would have stopped the panic and
left a worse bug: with one, the inner type finishes first, so `object Child
extends Base` written inside `Base`'s body would fail on one VM and succeed on the
other. `corpus/objects-0021.rb` is that program, and it is in the corpus.

Red before green, on the test that found the first:

```
$ cargo test --test differential_test every_corpus_program_agrees_between_the_two_vms
assertion `left == right` failed: arithmetic-0015.rb: the tree-walking VM and the
bytecode VM disagree
  left:  Outcome { output: ["2"], result: Ok(Number(2.0)) }
  right: Outcome { output: ["2"], result: Ok(Nothing) }
```

## Tests added

**74 `#[test]` functions** — 32 in `tests/differential_test.rs` and 42 inside
`tests/common/`, each next to the code it checks rather than in a file that could
only reach it through the public API. **63 are named `edge_*`**. The quota was
≥ 3 with ≥ 1 `edge_*`; none was deleted, renamed to be skipped, or given an
`allow`.

| Test | Edge class covered |
|---|---|
| `corpus_holds_at_least_two_hundred_programs` | corpus size, counted over `.rb` files |
| `every_corpus_program_has_an_expected_output_file` | loader — every program has a parseable expectation |
| `every_corpus_program_prints_what_its_expected_file_records` | output, **value** and message all compared, over 340 programs, with a count so it cannot pass vacuously |
| `every_corpus_program_agrees_between_the_two_vms` | differential — 340 programs, both halves of the outcome; a divergence is **shrunk and printed** |
| `the_corpus_holds_programs_that_must_fail` | **asserts a failure is produced** — ≥ 40 recorded failures, and one of each of the four labels |
| `the_corpus_holds_programs_that_are_worth_something` | differential — ≥ 20 valued programs, ≥ 10 distinct values, each run on **both** VMs |
| `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte` | corpus integrity — regeneration runs into a scratch directory and is compared **byte for byte** against `corpus/`, so the claim needs no environment variable |
| `the_checked_in_corpus_is_the_one_the_generator_produces` | corpus integrity — reads `corpus/` and compares the **on-disk name and source** of every program against the generator's, in all three directions |
| `the_two_vms_agree_on_every_generated_program` | differential — 200 generated programs; on a divergence it shrinks and prints the minimal program |
| `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` | type_mismatch — the typed-grammar invariant, asserted: no fault means completion, and an injected fault means **that** failure, at that position; **it found three generator defects** (table below) |
| `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output` | differential — both VMs asked about every program, ≥ half the completions worth something, ≥ 5 distinct values |
| `edge_a_generated_program_can_be_seen` | the failure path — a property test names a seed, and a seed is only actionable if the program behind it can be seen |
| `edge_the_generator_does_not_produce_nothing_but_failures` | type_mismatch — the grammar must not degenerate into error paths |
| `a_generated_program_runs_the_same_way_every_time` | determinism — same seed twice, same outcome, and both VMs agree |
| `a_generated_program_either_completes_or_reports_a_failure` | **asserts a failure is produced** — a failure names one of the five public labels with a non-empty message and a non-empty position; both channels occur, on both engines |
| `the_generator_is_reproducible_from_its_seed` | determinism — same seed equal, different seed different, and the program carries its seed |
| `edge_every_recorded_failure_records_the_place_it_happened_at` | malformed_input — every one of the corpus's failures records a position and it is the one the VM reports, **and** a count of the columns that are not 1, so the column half is not arithmetic |
| `edge_every_recorded_failure_points_at_a_line_of_its_own_program` | malformed_input — 78 recorded failures: each is checked against a real line and column of its own program, the end-of-input convention is counted rather than forbidden, and the convention is held to under a quarter of them |
| `edge_both_vms_place_every_failure_at_the_same_line_and_column` | differential — the position half of the outcome, compared over the corpus, with a count so it cannot pass vacuously |
| `edge_a_runtime_failure_names_a_line_and_a_frontend_failure_names_a_column` | the `src/` position fix — four runtime failures, two of them **indented**, at the line and column 1 on both engines; three frontend failures at the offending token's own column |
| `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` | resource_limit — 16 corpus programs print before they fail and each is recorded *and* compared; the rule that survives is that a **frontend** failure printed nothing, asserted for three programs |
| `edge_a_corpus_program_with_no_expectation_is_a_hard_failure` | **asserts a failure is produced** — an orphan is a hard failure naming the file *and* saying the expectation is missing, and no expectation is invented |
| `edge_a_changed_return_value_is_a_runner_failure` | differential + **asserts a failure is produced** — an `.expected` naming the wrong value *and* one naming the wrong message each fail |
| `edge_a_failure_that_moved_is_a_difference_on_both_sides` | differential — a recorded failure at the wrong line is rejected by `compare`, **and** the two VMs are asked separately where the failure happened |
| `edge_a_mismatch_names_the_program_it_is_about` | the panic must name the file, so a failure is actionable |
| `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints` | type_mismatch — the golden file's `#value` names a type as well as a rendering, and an untagged `#value 5` is **rejected** for a program worth the number `5` |
| `edge_the_golden_format_is_what_the_corpus_uses` | corpus integrity — re-recording an outcome reproduces the file byte for byte |
| `edge_the_corpus_is_a_function_of_the_generator_and_nothing_else` | corpus integrity — regeneration is a function of nothing, and no two of the 340 programs are identical |
| `edge_the_corpus_declares_a_fault_for_every_label_it_records` | coverage — the recorded failures and the declared faults are both non-empty |
| `edge_a_shrunk_program_still_diverges` | the shrinker must not reduce a program that does not fail |

The other 41 live in `tests/common/`:

| Module | Tests |
|---|---|
| `rng.rs` | `edge_the_generator_is_the_sequence_splitmix64_publishes` (the PRNG's constants pinned against the published output), `edge_a_seed_is_replayed_and_a_different_seed_is_not`, `edge_the_bounded_helpers_stay_inside_their_bounds`, `edge_a_flag_draws_both_answers`, `edge_the_default_seed_is_not_zero` |
| `vm.rs` | `edge_the_harness_reads_its_limits_from_itself`, `edge_a_number_and_the_text_that_spells_it_are_different_outcomes` (the rendering collides, the values do not — which a string-valued outcome could not see), `edge_a_failure_carries_the_position_it_happened_at`, `edge_a_frontend_failure_printed_nothing_on_either_vm`, `edge_the_two_halves_agree_on_a_failure_and_on_what_was_printed_first`, `edge_one_run_of_a_program_is_all_the_harness_asks_for` (a program that **appends** to a file, so a second run is visible on disk), `edge_a_limit_left_in_the_environment_cannot_change_an_outcome`, `edge_a_vm_built_the_way_the_interpreter_builds_one_follows_the_environment` (the **control** for the previous test) |
| `corpus.rs` | `edge_a_printed_line_that_looks_like_a_directive_round_trips`, `edge_an_expected_file_carrying_escapes_round_trips`, `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints` (the four `Display` collisions), `edge_an_untagged_value_is_rejected_for_a_typed_one`, `edge_a_malformed_expected_file_is_rejected` (**asserts a failure is produced** — 16 malformed `.expected` files, each rejected), `edge_a_well_formed_expected_file_is_accepted`, `edge_the_escape_is_a_two_way_function_over_every_case`, `edge_a_rendered_value_is_readable_back_for_what_the_corpus_records` |
| `shrink.rs` | `edge_the_shrinker_stops_only_when_nothing_can_be_removed` (minimality asserted against the shrinker's **own** candidates), `edge_the_shrinker_accepts_a_candidate_only_when_it_is_shorter`, `edge_a_character_comes_off_a_multibyte_program_at_its_own_boundary` (byte indexing would panic on `𠮷`), `edge_a_reduction_keeps_the_trailing_newline_a_source_has`, `edge_the_shrinker_reduces_when_no_line_can_go`, `edge_the_shrinker_never_invents_a_counterexample`, `edge_a_line_comes_off_and_a_line_that_is_not_there_does_not`, `edge_drop_lines_builds_the_source_the_line_pass_looks_at`, `edge_a_reduction_is_reported_with_the_program_it_reduced`, `edge_the_failing_predicate_is_the_interpreter_s_own_verdict` |
| `generator.rs` | `edge_every_kind_is_reachable_and_its_arms_produce_it`, `edge_every_arm_is_worth_the_kind_it_claims`, `edge_every_declared_fault_has_a_tail_that_faults`, `edge_every_declared_fault_is_actually_injected_by_some_seed`, `edge_generated_programs_end_in_a_value_rather_than_in_a_statement`, `edge_almost_every_seed_produces_a_program_of_its_own`, `edge_the_generator_is_a_function_of_nothing`, `edge_the_generator_emits_every_statement_form_it_lists`, `edge_a_text_literal_escapes_what_a_source_cannot_hold_raw`, `edge_the_binders_and_readers_agree` |

## What the corpus holds

340 programs, no two identical. 262 run to completion; **78 must fail** — 3
`AnalyzerError`, 2 `LexerError`, 32 `ParserError`, 41 `RuntimeError`. 24 record a
`#value` other than `nothing`, across **18** distinct values: eleven numbers, two
texts, `yesno:yes`, `yesno:no`, two lists and two records. **28** of the 78
recorded failures sit at a column other than 1 — all of them frontend failures,
the only kind that carries a column.

| Family | n | What it pins |
|---|---|---|
| `arithmetic` | 20 | nested `+ - * mod`, unary negation, `is`/`is not`, `and`/`or`, `2147483647 + 1` |
| `numeric-boundary` | 25 | `1/0`, `0/0`, `9 mod 0`, `1/-0.0` caught; `0.1+0.2`, `1/3`, `-0.0`, the 32-bit and `i64` edges, `2^53`, `2^53+1`, signed `/` and `mod` |
| `text-ops` | 21 | concatenation, `length`, `is`, empty text, `\"`, `\\`, `\n`, `\t`, `5 + "abc"` |
| `unicode` | 16 | CJK, emoji, ZWJ, RTL, astral (`𠮷`), accented, arrow/∞, BOM-prefixed source, `length` and equality on each |
| `lists` | 19 | empty, singleton, index `0`, index `len-1`, negative index, trailing comma, nested list, aliasing, `for each` over each |
| `records` | 16 | one field, nested, missing key → `nothing`, missing key two and three levels down, repeated key keeps the last, order-independent equality, aliasing |
| `control-flow` | 16 | `if`/`else if`/`else` 1–3 deep, empty `then`, `and`/`or`/`not` in a condition, a 4-deep `if`, `unless` |
| `functions` | 17 | 0/1/2-arity, a function bound to a variable and called twice, a function passed as an argument, two `give back`s, an unknown function, a wrong arity, iteration-as-recursion |
| `objects` | 21 | empty object, `has` with and without a `default`, a method reading `this`, inheritance one and two deep, `extends` shadowing, a missing field, a field written through the name, and **three nested-`object` programs** — one plain, one read back through `type_of`, and one `extends`-ing the type it is written inside |
| `loop-forms` | 17 | `repeat 0`/`1`/`n` times, `for each` over `[]`/list/list-of-list, nested loops, a condition inside a loop, and `skip`/`break` — which are accepted and leave the loop alone |
| `nesting` | 18 | lists and records 4–7 deep, a walk down every level, `if` nested 4 deep, triple-nested loops, a three-deep method chain |
| `stdlib` | 18 | `length` and `type_of` on every type, including the empty and singleton cases |
| `runtime-errors` | 18 | each catchable error inside `try … catch` — the catch must fire and the work before it must survive; plus nested `try` and `finally` |
| `faults` | 18 | the same errors uncaught: the failure **and everything printed before it**, plus two **indented** failures — the case that made the two engines disagree about a failure's column |
| `malformed` | 38 | unterminated string, stray `end`, `set` with no name / no `to` / no value, missing operand, unclosed paren, unclosed list, unclosed record, `say` with nothing, `for each` with no variable, `repeat` with no count, stray `}`, `if` with no condition, `@`, `=`, unclosed `to`, the six non-lexing comparators, `for each … from`, a missing `then`, an unclosed index, three analyzer failures, trailing tokens |
| `value-tails` | 42 | programs whose **last statement is a bare expression**, and programs ending in a **block whose value is read**: a bound number, a bound text, arithmetic, concatenation, `yes`, `no`, `nothing`, a whole list, a whole record, a builtin call, a property read, an index, a call, a missing key, a field write, a loop tail, BOM-prefixed programs, an `if` tail, an `unless` tail, a `for each` tail, a `try` tail, a nested-`if` tail, a method call inside an `if` tail |

`stdlib` covers only `length` and `type_of` because 23 of the 25 registered
builtins cannot be called from Redblue source → `FINDINGS.md` §3. There is **no
`while` anywhere in the corpus** because no comparison operator lexes →
`FINDINGS.md` §4.

### Three generator defects the typed-grammar invariant caught

`edge_a_generated_program_only_faults_on_a_fault_that_was_injected` is only worth
having if it finds things. It found three in its first runs:

1. **A text arm that summed a number into a text.** `length` is a *number*, and
   the `Text` grammar's `length` arm produced `text + length(text)`. The first
   run reported seed 1 failing with `Cannot add non-numbers` on a program that
   was told to run. The arm is now a triple of texts.
2. **A `mod` arm that could divide by zero.** `(x mod y)` with a literal `0` in
   the number table made a generated program fail with `Modulo by zero` and no
   fault injected — which would have made a fault-injection test indistinguishable
   from a grammar bug. The divisor is now `((y) * (y)) + 1`, with each operand
   parenthesised on its own, because relying on the outer pair alone let a drawn
   divisor that already ended in `* …` regroup.
3. **A `YesNo` arm that emitted the documented-but-unimplemented `either`** →
   `FINDINGS.md` §2. It is now `or`.

This is the shape of the defect in general: the generator's grammar said
`Kind::Text` and the grammar was wrong.

### Every new assertion is mutation-checked

Each fix was verified by putting the defect back and watching a test fail.
Nothing here was taken on trust:

| Defect restored | Test(s) that failed |
|---|---|
| top-level frame's value discarded again (`src/bytecode/vm.rs:989`) | `every_corpus_program_agrees_between_the_two_vms`, `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte`, `the_corpus_holds_programs_that_are_worth_something`, `the_two_vms_agree_on_every_generated_program`, `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output`, `a_generated_program_runs_the_same_way_every_time`, `edge_a_shrunk_program_still_diverges`, `common::generator::tests::edge_every_kind_is_reachable_and_its_arms_produce_it`, `common::vm::tests::edge_a_limit_left_in_the_environment_cannot_change_an_outcome` (**9**) |
| an `if` branch value-bearing again (`src/bytecode/codegen.rs`) | `every_corpus_program_agrees_between_the_two_vms`, `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte`, `the_corpus_holds_programs_that_are_worth_something` (**3**) |
| every inner block value-bearing again (`src/bytecode/codegen.rs`) | the same three (**3**) |
| `SET_PROPERTY` leaks its receiver again (`src/bytecode/vm.rs:1610`) | `every_corpus_program_agrees_between_the_two_vms`, `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte`, `the_corpus_holds_programs_that_are_worth_something` (**3**) |
| `statement_span` back to the statement's own column (`src/vm.rs:170`) | `every_corpus_program_agrees_between_the_two_vms`, `every_corpus_program_prints_what_its_expected_file_records`, `the_corpus_holds_programs_that_are_worth_something`, `edge_a_runtime_failure_names_a_line_and_a_frontend_failure_names_a_column`, `edge_both_vms_place_every_failure_at_the_same_line_and_column`, `edge_every_recorded_failure_records_the_place_it_happened_at`, `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte`, and `tests/span_test.rs`'s updated assertion (**8**) |
| the harness builds its bytecode VM with `new()`, so its limits follow the environment | the same seven as the first row, minus two (**7**) |
| an orphan program stops being a hard failure (`expectation_of` reads an empty string) | `every_corpus_program_has_an_expected_output_file`, `every_corpus_program_prints_what_its_expected_file_records`, `edge_a_corpus_program_with_no_expectation_is_a_hard_failure`, `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away`, `edge_every_recorded_failure_points_at_a_line_of_its_own_program`, `edge_every_recorded_failure_records_the_place_it_happened_at`, `edge_the_corpus_declares_a_fault_for_every_label_it_records`, `edge_the_golden_format_is_what_the_corpus_uses` (**8**) |
| `number:` dropped from `#value` | `every_corpus_program_prints_what_its_expected_file_records`, `edge_a_changed_return_value_is_a_runner_failure`, `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints`, `edge_an_expected_file_carrying_escapes_round_trips`, `edge_a_shrunk_program_still_diverges`, `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte` (**6**) |
| `text:` dropped from `#value` | `every_corpus_program_prints_what_its_expected_file_records`, `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints`, `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte` (**3**) |
| an `object` body compiled whole again, so a nested `object` runs inside the block that assembles the outer declaration (`src/bytecode/codegen.rs`) | `every_corpus_program_agrees_between_the_two_vms`, `edge_both_vms_place_every_failure_at_the_same_line_and_column`, `edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte`, `the_corpus_holds_programs_that_are_worth_something` (**4**; the mutation reproduces the `src/bytecode/vm.rs:1026` panic four times over) |
| a multi-line failure message written raw into `#message` (`tests/common/corpus.rs`) | the whole differential binary: every golden file failed to load — found by the corpus when a nested `object Child extends Base` recorded `"Unknown variable 'Child'"` twice |
| `shrinks_to` accepts an equal-length candidate | `common::shrink::tests::edge_the_shrinker_accepts_a_candidate_only_when_it_is_shorter` (**1**; the mutation fails rather than hanging, which is what it is for) |
| `without_line`'s range check off by one | `common::shrink::tests::edge_a_line_comes_off_and_a_line_that_is_not_there_does_not` (**1**) |

Three mutations had to be re-run because the *first* one did not fail, and each of
those three found a real hole rather than a bad assertion:

1. The `if`-branch mutation passed on the first corpus, because no program in it
   ended in a block whose value is read. Fourteen `value-tails` programs were added
   for exactly that reason and the same mutation now fails three tests.
2. The nested-`object` mutation aborted the test *binary* rather than failing a
   test, so the first two attempts at it produced no output at all and were
   re-run with a mutation that keeps the build green under `-D warnings`.
3. The `#value` and orphan-check mutations were each applied to a copy rather than
   to the file, and "passed" — twice. Both were re-run against the real file and
   both fail.

One of these mutations was run twice. The `if`-branch mutation **passed** on the
first corpus, because no program in it ended in a block whose value is read.
Fourteen `value-tails` programs were added for exactly that reason — an `if` tail,
an `unless` tail, a `for each` tail, a `try` tail, a nested-`if` tail and the
rest — and the same mutation now fails three tests. That is the one result in
this table that was not the first one it claimed to be.

### Four defects the harness's own tests caught

All four were mine, and all four were found by the file that was supposed to be
trustworthy:

1. **Two copies of the frontend pipeline.** `tree_walk` would have recovered the
   value by running the pipeline a second time. `edge_one_run_of_a_program_is_all_
   the_harness_asks_for` runs a program that **appends** twice to a file and
   asserts the file holds `ab`; the mutation puts `abab` there.
2. **The generator's grammar was not a generator.** An `add` arm draws two more
   numbers, each of which may be an `add`, so a seed could produce a source with
   no size bound at all — and the first run overflowed the interpreter thread's
   stack, which is what proved it. `MAX_DEPTH` bounds it and `descends` names
   the arms that stop.
3. **`regenerating` wrote files with no `.rb` extension.** `corpus_sources()`
   returned `arithmetic-0001` and the writer wrote that name, so the whole corpus
   was written as extensionless files and every `.rb` count read zero. Found by
   `corpus_holds_at_least_two_hundred_programs`, not by the writer.
4. **The regeneration test could not run in an ordinary `cargo test`.** It
   asserted `RB_WRITE_CORPUS=1`, so it failed in every normal run — a test that
   fails by design is a red gate. It now regenerates into `target/tmp` and
   compares byte for byte, and `RB_WRITE_CORPUS=1` refreshes `corpus/` in place
   for when the generator has deliberately changed.

A fifth was mine and is not a defect in the harness: the first version of the
position assertion required every recorded failure to name a line *inside* its
program, and reported 55 of 75 as violations because a parser failure at the end
of a program is legitimately reported one line past the last. That is now counted
as the end-of-input convention it is, and held to under a quarter.

## Edge-case matrix

| Row | Covered? |
|---|---|
| empty | covered — `lists` holds `[]` and `for each` over it, `text-ops` holds `length("")` and `say ""`, `stdlib` holds `length([])`/`type_of([])`/`type_of({})`, `control-flow` holds an empty `then`, `loop-forms` holds `repeat 0 times`, `records` holds `{}` and `length({})`, `value-tails` holds `nothing` and `[]` and `{}` |
| singleton | covered — one-element list (`length([1])`, `xs[0]`), one-field record, `repeat 1 times`, `length("a")`, `for each` over `[1, 2]`, `to zero()`, `say "👋"`, `say length("a")` |
| boundary | covered — index `0`, `len-1`, `[-1]`, `[-3]` in `lists`; `2147483647`, `2147483647+1`, `-2147483648`, `9223372036854775807`, `-9223372036854775808`, `9007199254740992`, `9007199254740993`, `0.1+0.7` in `numeric-boundary`; loop counters at `repeat 0` and `repeat 10` |
| out_of_bounds | covered — `faults` holds index `len`, index `1` of a 1-list and `xs[9]` of a 2-list, `xs[0]` of `[]`; `runtime-errors` holds the same three inside `catch`. Each records the exact message, e.g. `Index 9 is out of bounds: length is 2, valid indexes are 0 to 1` |
| type_mismatch | covered — `faults` holds number+text, list+text, yes+number, nothing+number, text−number, index-on-number, index-on-`nothing`, length-of-record, length-of-yes, length-of-`nothing`, index-of-text, an unknown function, a property of `nothing`; and `edge_a_recorded_value_names_the_type_and_not_only_what_it_prints` covers the **golden** side of the same class, since `Number(5)`/`Text("5")` and `Nothing`/`Text("nothing")` are a type mismatch a `#value 5` could not see |
| numeric_boundary | covered — `numeric-boundary`: `1/0`, `0/0`, `9 mod 0`, `1/-0.0`, `0.1+0.2`, `1/3`, `-0.0`, `-7/2`, `7/-2`, `-7 mod 3`, `7 mod -3`, `9 mod 9`, and the `i64`/`2^53` edges |
| unicode | covered — `unicode`: CJK, emoji, ZWJ (`👩‍💻`), RTL (`مرحبا`), astral (`𠮷`), accented, arrow/∞, Greek, BOM-prefixed source, `length` and equality on each; plus `text-ops` for `\\`, `\"`, `\n`, `\t`. **Not covered:** combining marks written in source, because `\u` escapes are dropped (`FINDINGS.md` §5) |
| nesting_recursion | covered — `nesting` (lists and records 4–7 deep, a walk down every level, `if` nested 4 deep, triple-nested loops), `functions` (a function bound to a variable, a function passed as an argument, two `give back`s), `objects` (inheritance two deep). **Terminating recursion is held as three explicit programs** (`count_down(3)`, `fact(5)`, nested calls) — the earlier assumption that `give back` inside a conditional does not return was wrong; these three run. A closure declared inside a function is still not reachable → `FINDINGS.md` |
| duplicate_missing_keys | covered — `records` holds a repeated key (`{a: 1, a: 2}` keeps the last), a missing key (`nothing`), a missing key two levels down (`r.a.missing`) and three levels down, and aliasing (`set s to r` then reading through `s`); `objects` holds a missing field; `malformed` holds a property read on a number |
| malformed_input | covered — `malformed` (38 programs) and `edge_a_malformed_expected_file_is_rejected` (16 rejected `.expected` files), plus the shrinker's minimality tests, which reduce real programs to malformed ones |
| resource_limit | covered — `runtime-errors` and `faults` hold every catchable runtime error and prove it is catchable rather than fatal; `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` proves a frontend failure printed nothing; the property tests run 200 generated programs through both VMs and assert no panic; `edge_every_recorded_failure_points_at_a_line_of_its_own_program` checks every failure's position against a real line and column; `edge_a_limit_left_in_the_environment_cannot_change_an_outcome` plus the whole suite under `REDBLUE_MAX_STEPS=1` say the limits cannot move under it either |
| value_bearing_tail | covered — the `value-tails` family (42 programs, 24 worth something on **both** VMs across 18 distinct values), plus `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output`, which requires at least half the completed generated programs to be worth something |
| generator_well_typed | covered — `edge_a_generated_program_only_faults_on_a_fault_that_was_injected`: every generated program carrying no injected fault runs to completion, **and every generated program carrying one fails on that fault and no other**, which makes `FAULTS` the *only* source of failure and the *only* fault. It found three generator defects; `edge_every_declared_fault_has_a_tail_that_faults` then held the six tails to six different failures, and `edge_every_kind_is_reachable_and_its_arms_produce_it` holds every arm of the typed grammar to the kind it claims |
| generator_bounded | covered — `edge_a_generated_program_can_be_seen` prints whole programs, `MAX_DEPTH` bounds the nesting, and the first run of the suite overflowed the interpreter thread's stack before the bound existed — the bound is pinned by the fact that 200 programs now run without one |

## Gates

Run in the order `AGENTS.md` §3.4 gives.

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass — no diff |
| `cargo clippy --all-targets -- -D warnings` | pass — 0 warnings |
| `cargo test --all-targets --no-fail-fast` | **727 passed, 0 failed, 0 ignored** (30 test binaries); `cargo test --doc`: 1 passed |
| `./rbops/verify.sh phase-020` | **not run — `rbops/verify.sh` does not exist in this checkout** (`FINDINGS.md` §9) |

727 rather than the 495 of the resume commit: the 333-line runner's 7 tests
replaced 74, none was deleted, renamed to be skipped, or given an `allow`, and the
other 495 all still pass. The one pre-existing test that changed is
`tests/span_test.rs`'s runtime position, and it was **updated to the new contract
rather than removed**, with the reason in its message.

On the fourth gate, honestly: there is no `rbops/` directory in this checkout at
all, and the task instructions say the pipeline that dispatched this phase lives
outside the checkout and is not to be inspected. The three gates that do exist
were run and are green. In their place, the backwards-compatibility check
`AGENTS.md` §2 names — and four files under `src/` changed, so this was
re-checked rather than assumed:

```
$ for f in examples/*.rb modules/*.rb; do ./target/debug/rb run "$f"; done
ok examples/files.rb   ok examples/fizzbuzz.rb   ok examples/formats.rb
ok examples/hello.rb   ok examples/test_arithmetic.rb   ok examples/time.rb
ok modules/MathUtils.rb   ok modules/SuiteKit.rb
```

All eight run clean.

The gate is also independent of the environment now, which is measured rather
than argued:

```
$ REDBLUE_MAX_STEPS=1 REDBLUE_MAX_ITERATIONS=1 REDBLUE_MAX_CALL_DEPTH=1 \
    cargo test --test differential_test
test result: ok. 73 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

Determinism was checked by regenerating and comparing bytes, which is what
`edge_regenerating_the_corpus_reproduces_the_checked_in_one_byte_for_byte` does
on every run:

```
$ RB_WRITE_CORPUS=1 cargo test --test differential_test edge_regenerating
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

## Invariants touched

- **None of the language.** No syntax or grammar changed. The `Value` and `Error`
  variants, the `.rb` extension, `to … end` / `if … end` / `for … end`, `set x to`,
  `say`, and the trailing-comma syntax are all untouched, and all 495
  pre-existing tests still pass. `Opcode::ALL` is untouched, so the S1 artifact's
  byte format is unaffected.
- **One thing about what a program *is worth* changed on the bytecode VM**, which
  the language documents as an invariant and is called out here rather than
  buried:
  - a program ending in a bare expression now ends with that expression's value on
    the bytecode VM, as it already did on the tree-walking one;
  - a statement consumes everything it produced, so `set r.a to 1` no longer leaks
    a record onto the operand stack and `if … then 7 … end` no longer leaves `7`
    for the enclosing block. Both were invisible before, because the top-level
    frame discarded whatever it finished with; they are the same bug wearing a
    second hat.
- **One thing about *when* an object body runs changed on the bytecode VM.** An
  `object` body now compiles as two halves: the `has` and `to can` go into the
  block that assembles the type, and everything else compiles into the
  **enclosing** block, after the `STORE` that binds the type. That is the
  tree-walking VM's order (`declare_object`), and it is what makes an `object`
  written inside another object's body work at all — the bytecode VM keeps one
  pending declaration, so an inner `DEF_OBJECT` overwrote the outer one's and the
  outer frame then reached for a declaration that was gone:
  `thread 'main' panicked at src/bytecode/vm.rs:1026: an object declaration being
  assembled`. **This is a reachable `panic!` that the harness found and that is
  fixed here**; `FINDINGS.md` §11 has the repro. A body whose only statements are
  `has` and `to can` compiles to the same bytes as before, so an object's byte-level
  assertions are unaffected; what changes is the placement of every other
  statement an object body can hold (`say`, `set`, a nested `object`), which used
  to run inside the declaration's own frame.
- **One thing about *where* a runtime failure happened changed on the tree-walking
  VM**: a runtime failure now names the **line** of the statement that failed, at
  column 1, where it named that statement's own column. Two engines reporting one
  failure at two places is a divergence in the language, and the bytecode format
  carries no column, so the line is what both can answer. Only `Error::span()` and
  the rendered caret are affected; the label and the message are untouched, and a
  **frontend** failure still carries the offending token's own line and column —
  asserted directly in `edge_a_runtime_failure_names_a_line_and_a_frontend_
  failure_names_a_column`.
- **The `.expected` format is new** and carries two directives the language does
  not: `#position <line>:<column>` (or `#position none`), required for a failing
  program and refused for one that ran; and `#value`, which records the type as
  well as the rendering (`number:5`, `text:5`, `yesno:yes`, `list:[1, 2]`,
  `record:{a: 1}`, and `nothing` alone). This is the golden format, not the
  language, and it is a new format rather than a changed one.
- **Four additive constructors**, `Vm::with_limits`, `BytecodeVm::with_limits`,
  `run_isolated_with` and the existing `run_isolated` now delegating to it. Nothing
  about a default changed: a caller that builds a VM with `new()` still reads
  `REDBLUE_MAX_*`.
- **One placement decision.** The corpus lives at `corpus/`, not `tests/corpus/`.
  `redblue::testing::find_test_files("tests")` (`src/testing/mod.rs:64`) walks
  `tests/` recursively and `tests/redblue_suite_test.rs:132` requires every `.rb`
  file it finds to declare Redblue `test` blocks with an assertion in them. A
  corpus program declares none, and *"a corpus program is not a test"* is the right
  thing for that gate to say — so the corpus goes where the suite's collector does
  not walk, which is also where the phase's definition of done asks for it.

## Known gaps / follow-ups

- **23 of the 25 registered builtins cannot be called from Redblue source**
  → `FINDINGS.md` §3. The corpus's `stdlib` family is 18 programs instead of the
  ~60 it should be.
- **No comparison operator lexes, so there is no `while` in the corpus** →
  `FINDINGS.md` §4. `AGENTS.md`'s own first example does not parse.
- **`either` is documented and unimplemented** → `FINDINGS.md` §2.
- **`\u` escapes are dropped rather than refused**, so a combining mark cannot be
  written in source and a mistyped escape is swallowed → `FINDINGS.md` §5.
- **`length` counts bytes, not characters** → `FINDINGS.md` §6.
- **Trailing tokens on a line are silently accepted** (`say 1 2 3` prints `1` and
  is worth `3`) → `FINDINGS.md` §7.
- **`skip` and `break` are accepted and do nothing.** `for each x in [1, 2, 3]` /
  `if x is 2 then` / `break` / `end` / `say x` / `end` prints 1, 2, 3. Both VMs
  agree, so the corpus pins the current behaviour rather than a divergence.
- **A property harness cannot see a defect both VMs share.** Nine of the ten items
  in `FINDINGS.md` are limitations the two VMs agree on, which is exactly the
  class a *differential* harness is blind to. Only §1 was visible to this phase,
  and only because the harness compared something other than printed output.
- **The corpus regenerates only when `RB_WRITE_CORPUS=1` is set**, so a CI job that
  set it would rewrite the golden files rather than fail on a regression. The
  regeneration test still runs in that case: it refreshes `corpus/` and then
  regenerates into a scratch directory and compares, so a rewrite is visible as a
  diff rather than hidden.
- **`rbops/verify.sh` was not run because it is not present** → `FINDINGS.md` §9.