# Phase 020 — Differential + property test harness

## Round 2 — review findings

The reviewer returned four findings against the round-1 submission: one BLOCKER,
one MAJOR, two MINORs. All four are fixed. None of the fixes weaken a gate, none
deletes a test, and none adds `#[ignore]`, a `// skip` or an
`allow(clippy::…)` — the two new tests and the four rewritten assertions are
there because the gaps they name were real.

### The BLOCKER: the value comparison was vacuous, and it took `src/` to fix

The finding was that `random_statement` had no arm emitting a bare expression
tail, so every generated `Ok` program ended in `set`/`say`/`if`/`repeat` — each
worth `nothing` — and the cross-VM *value* comparison was never exercised.
Round 1 wrote this off as "not a gap in the format": a program ending in an
expression statement *is* the FINDINGS §4 divergence, so no corpus program could
hold a non-`nothing` value. That was true, and it was also the defect. A phase
that routes around a divergence and calls the routing a property has not tested
anything.

So the divergence is fixed rather than avoided, in `src/`:

| Defect | Fix |
|---|---|
| `unwind_frame` threw away the last frame's value unless the frame was a *call*, so a program ending in a bare expression was `Ok("nothing")` on the bytecode VM and `Ok("5")` on the tree-walking one — FINDINGS §4 | `src/bytecode/vm.rs:893` — the last frame is not a statement, it *is* the program, so its value is what the program is worth. `codegen.rs` already declined to `POP` a trailing expression for exactly this reason; this is where the value it leaves is picked up. |
| `set_property` popped the value but not the receiver, though `docs/BYTECODE.md:180` says `SET_PROPERTY` "pops a value and an object" and "a statement leaves nothing behind" | `src/bytecode/vm.rs:1518` — the receiver operand is consumed. The leak was invisible while the top-level frame discarded whatever it finished with, and showed up as soon as it stopped: a program ending in `set r.a to 2` was worth a record. |
| `statements` treated the last statement of *any* block as value-bearing, so `if n is 1 then / 7 / end` left `7` on the operand stack of the enclosing frame | `src/bytecode/codegen.rs:107,145` — only a block whose value is read (`main`, `Function`, `Method`) may leave one behind. A block statement is worth nothing whatever its body produced, which is what the tree-walking VM gives it. |

This is a departure from the phase's declared `must_touch: ["tests/"]`, and it is
deliberate: the finding asked for `tree_walk == bytecode` asserted on a program
ending in an expression, and no change confined to `tests/` can make that true
while the two VMs disagree. The alternative was to keep the harness green and the
vacuity, which is the thing under review. `FINDINGS.md` §4 is marked resolved;
§1, §2 and §3 are untouched and still stand as recorded.

With the divergence fixed the harness could be widened:

- `random_program` ends three programs in four with `value_tail` — a bound name
  left as a bare expression, drawn from `Number`, `Text` or `YesNo` so the values
  being compared span types. A quarter still end in a statement, so both endings
  are exercised.
- A new `values` corpus family (`tests/common/generator.rs:743`) — 16 programs
  whose last statement is a bare expression: a bound number, a bound text,
  arithmetic, concatenation, a yes/no, a whole list, a whole record, a builtin
  call, a property read, an index, a call that gives a value back, `nothing`
  itself, a key that is not there, a block tail and a loop tail. Twelve of them
  record a `#value` other than `nothing` — a number, a text, `no`, a list, a
  record and `list` — against the 199 programs that all recorded `nothing`.
- `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output`
  asserts both VMs are asked about every generated program worth something, and
  that at least half of the completed ones are worth something: 282 of 320
  complete, 208 valued, 90 distinct values.
- `the_corpus_holds_programs_that_are_worth_something` does the same for the
  corpus: floors the valued count at 10, floors the distinct values at 4, and
  runs *both* VMs over each one.
- `edge_a_changed_return_value_is_a_runner_failure` now asserts
  `tree_walk == bytecode` on `set t to 5 / say t / t`, not only the tree-walking
  outcome against `.expected`. Recording the value only pinned the
  specification; a bytecode VM answering `nothing` would have satisfied every
  other assertion in that test and still been a second, disagreeing language.

The `values` family found the third defect on its first run: `regenerating_the_
corpus_writes_exactly_what_the_generator_produces` refused to record
`0242-values-14` — *"the tree-walking VM said `Ok("nothing")` and the bytecode VM
said `Ok("[7, 8]")`"* — which is the `if`/branch leak above. The family is what
found it; the fix is in the table.

### The MAJOR and the two MINORs

| # | Finding | Fix |
|---|---|---|
| 2 | MAJOR — `typed_expression` for `Kind::Text` returned `(length(left) + length(left))`, a `Number`, against `random_statement`'s contract that `t` holds text, so `set t to <lengths>` faulted at `say length(t)` — accidental type faults instead of the deliberate `random_fault` mix | Every `Kind::Text` arm concatenates (`tests/property_test.rs:144`). Text plus a number is itself a `RuntimeError`, so the length cannot be folded into a text expression at all. The invariant is now asserted, not assumed: `FAULTS` is a named constant and `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` requires every generated program carrying no injected fault to run to completion. |
| 3 | MINOR — `candidate.remove(index)` walked byte indices and panicked on a non-boundary, aborting the test binary instead of failing | `shrink::without_char` (`tests/common/shrink.rs:127`) walks characters, and the minimality assertion calls it rather than rebuilding the candidate by hand. |
| 4 | MINOR — `candidate.join("\n")` dropped the trailing newline, so every line-based candidate also differed at EOF, and the EOF-span cases (`lines + 1`, unterminated blocks) shrank against altered input | `shrink::join_lines` (`tests/common/shrink.rs:89`) puts the terminator back. |

The assertion named in finding 3 could not previously be written at all: it
walked byte indices. `edge_the_shrinker_deletes_a_character_from_a_multibyte_program`
is new, and uses a property that keeps a multi-byte character *in the reduction*
(an unterminated literal alone shrinks to `"`, which is ASCII, so the boundary
would be gone before a byte-indexed pass reached it).

### Three more generator defects the new invariant caught

`edge_a_generated_program_only_faults_on_a_fault_that_was_injected` is only
worth having if it finds things, and it found three in a generator that had been
passing for a round. None of them was visible before, because a broken arm
produces a *failure*, and every property in the file accepts failures:

| Defect | Symptom |
|---|---|
| `random_statement`'s conditional arm wrote `if b is yes` with no `then` | a `ParserError` — *"Expected Then but got Say"* — for a sixth of the generated corpus |
| the `Kind::Text` arm `({left} + " {left}")` spliced expression *source* into a quoted literal | a `LexerError` whenever `left` carried a quote of its own: `(("a b c" + "-") + " ("a b c" + "-")")` |
| `text_literal` did not exist, so what a `Text` expression appended came from the same stream as everything else | `("x" + "é")` and `("é" + "x")` were not both reachable |

### Every new assertion is mutation-checked

Each fix was verified by putting the defect back and watching a test fail:

| Defect restored | Test that failed |
|---|---|
| top-level frame's value discarded again | `edge_a_changed_return_value_is_a_runner_failure`, `every_corpus_program_agrees_between_the_two_vms`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces`, `the_corpus_holds_programs_that_are_worth_something`, `the_two_vms_agree_on_every_generated_program`, `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output` (6 tests) |
| `SET_PROPERTY` leaks its receiver again | `every_corpus_program_agrees_between_the_two_vms`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces`, plus `a_corpus_of_programs_runs_identically_on_both_vms` and `edge_the_two_vms_report_the_same_failure_for_every_corpus_program` in the phase-019 corpus |
| every block leaves a value behind again | `every_corpus_program_agrees_between_the_two_vms`, `regenerating_the_corpus_writes_exactly_what_the_generator_produces` |
| `Kind::Text` arm returns a `Number` again | `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` |
| the conditional arm drops its `then` | `edge_a_generated_program_only_faults_on_a_fault_that_was_injected`, `edge_the_generator_emits_every_statement_form_it_lists` |
| a `Text` arm splices expression source into a literal | `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` |
| the line pass drops the trailing newline | `edge_the_shrinker_stops_only_when_nothing_can_be_removed` |
| the character pass indexes bytes | `edge_the_shrinker_deletes_a_character_from_a_multibyte_program` — *"start byte index 1 is not a char boundary; it is inside 'é'"* |

### Corpus regenerated

`RB_WRITE_CORPUS=1 cargo test --test differential_test`. 228 programs → 244, a
sixteenth family appended so no existing file name moved. Determinism re-checked
by regenerating again and comparing checksums:

```
$ before=$(cat corpus/* | sha256sum)
$ RB_WRITE_CORPUS=1 cargo test --test differential_test
$ after=$(cat corpus/* | sha256sum)
DETERMINISTIC: regeneration is byte-identical
```

### Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass, 0 warnings |
| `cargo test --all-targets` | **525 passed, 0 failed, 0 ignored** (and `cargo test --doc`: 1 passed) |
| `./rbops/verify.sh phase-020` | **not run — `rbops/verify.sh` does not exist in this checkout** (§6 of FINDINGS.md). In its place the `examples/` and `modules/` run `AGENTS.md` §2 names: all 8 clean |

525 rather than 521: three tests were added and none was deleted, renamed to be
skipped, or given an `allow`. `tests/differential_test.rs` holds 17 and
`tests/property_test.rs` holds 14.

## Round 1 — review findings

The reviewer returned eight findings against the first submission: two
BLOCKERs, four MAJORs, two MINORs. All eight are fixed. None of the fixes
weaken a gate, and none of them deletes a test — the two tests the reviewer
called vacuous (`edge_a_missing_expected_output_file_is_a_runner_failure`,
and the 200-program floor in `regenerating_the_corpus_writes_exactly_what_the_generator_produces`)
now assert something that can fail.

| # | Finding | Fix |
|---|---|---|
| 1 | BLOCKER — `edge_a_missing_expected_output_file_is_a_runner_failure` never ran the runner: it wrote `orphan.rb`, listed the directory, and asserted the list was empty | `loaded_corpus` is split into `loaded_corpus_in(&dir)` (`tests/common/corpus.rs:248`); the test now `catch_unwind`s that loader over the scratch directory and asserts the panic **names `orphan.expected`**. Mutation-checked: with the loader skipping a missing file, the test fails. |
| 2 | BLOCKER — `assert!(!writing \|\| count >= 200)` is a tautology in CI, where `RB_WRITE_CORPUS` is unset | The floor is now unconditional and counts `.rb` files rather than directory entries (`tests/differential_test.rs:288`) |
| 3 | MAJOR — the `Ok` payload was discarded by `format_expected` and never compared, so a changed return value passed the golden check | `.expected` records `#value <escaped>`; `parse_expected` requires it for `label none` and forbids it otherwise; `assert_outcome_matches` compares it (`tests/common/corpus.rs:193`). FINDINGS §4's divergence is the case this catches. |
| 4 | MAJOR — the failing branch asserted `output == []` ("a program that fails must print nothing"), false for a `say` before an uncaught fault | Both branches now compare `outcome.output` against `expected.output`. The rule that survives is the true one: a **frontend** failure means nothing ran, so it printed nothing — asserted for every non-`RuntimeError` label, matching `tests/property_test.rs` |
| 5 | MAJOR — `random_statement(rng, 0)` made arms `(_, 4)` and `(_,_)` unreachable, so the property generator emitted no loop at all | The loop arm is now a guard (`_ if depth == 0`) rather than an early arm, and `random_program` seeds it at depth 2. `edge_the_generator_emits_every_statement_form_it_lists` counts each of the seven forms over the statement region, so a shadowed arm cannot recur silently. |
| 6 | MAJOR — `escape` covered `\` and `\n`, so a printed `#message foo` was read back as the failure message | `#` is escaped too (`tests/common/corpus.rs:149`), and `parse_expected` reads directives only while the header is open |
| 7 | MINOR — `failure_of` drops the span, so an error position was invisible to both halves of the runner | `vm::tree_walk_span` (`tests/common/vm.rs:64`) exposes it; `edge_every_recorded_failure_points_at_a_line_of_its_own_program` and `edge_a_generated_failure_points_at_a_line_of_its_own_program` assert the position is a real line and column of the program, or the position just past its last line where the source ends (an unterminated block). `Outcome` still compares label and message only — a `.rbc` has no source text to render a column from — so this is the "assert it separately" branch of the finding. |
| 8 | MINOR — `pick` documents "must not be empty" and then panics on `items[0]` | `assert!(!items.is_empty(), …)` naming the generator rather than the index (`tests/common/rng.rs:57`) |

### Corpus regenerated for the new format

The `.expected` format changed, so the corpus was re-recorded:
`RB_WRITE_CORPUS=1 cargo test --test differential_test`. 199 files gained one
`#value nothing` line; **no `.rb` file changed**. All 199 successful programs
record `nothing`, and that is not a gap in the format — a program ending in an
expression statement is exactly the FINDINGS §4 divergence (`set t to 5 / say t
/ t` is `Ok("5")` on the tree-walking VM and `Ok("nothing")` on the bytecode one),
so no corpus program can hold a non-`nothing` value without recording a known
divergence as the specification. `edge_a_changed_return_value_is_a_runner_failure`
covers the non-`nothing` case on the tree-walking VM directly.

> **Superseded by round 2.** The last sentence of that paragraph was the defect
> the round-2 reviewer named as a BLOCKER, and the reasoning in it was wrong: a
> corpus that cannot hold a non-`nothing` value because the two VMs disagree
> about one is a corpus that cannot check the thing the divergence is about.
> FINDINGS §4 is fixed and the corpus now holds 12 programs worth something.

### Every new assertion is mutation-checked

Each fix was verified by putting the defect back and watching the new test fail:

| Defect restored | Test that failed |
|---|---|
| loader skips a missing `.expected` | `edge_a_missing_expected_output_file_is_a_runner_failure` |
| generator seeded at depth 0 | `edge_the_generator_emits_every_statement_form_it_lists` — `no program containing "a loop"` |
| `Ok` payload not compared | `edge_a_changed_return_value_is_a_runner_failure` |
| failing branch asserts empty output | `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` |
| `#` not escaped | `edge_a_printed_line_that_looks_like_a_directive_round_trips` |
| every span reported as line 9999 | both span tests |

## Reproduction of the finding

The finding as written — *"No differential or property testing infrastructure
exists"* — **does not reproduce on `main`**. Phase 019 added
`a_corpus_of_programs_runs_identically_on_both_vms` (`tests/bytecode_vm_test.rs:1567`)
over ~336 programs hard-coded in Rust. What does not exist is what this phase
was asked for: a corpus on disk with a recorded expectation per program, a
seeded random generator, and a shrinker.

What reproduced was that the interrupted attempt had written the runner and
nothing else — no corpus, so six of its seven tests failed:

```
$ cargo test --test differential_test
---- corpus_holds_at_least_two_hundred_programs stdout ----
thread '...' panicked at tests/differential_test.rs:115:23:
corpus directory /…/tests/corpus should be readable: No such file or directory (os error 2)
test result: FAILED. 1 passed; 6 failed; 0 ignored; 0 measured; 0 filtered out
```

and one of its fixtures recorded a message the interpreter does not produce:

```
---- edge_a_corpus_program_whose_expected_file_names_a_failure_reports_a_mismatch ----
assertion `left == right` failed
  left: "RuntimeError: Index 9 is out of bounds: length is 2, valid indexes are 0 to 1"
 right: "RuntimeError: Index 9 is out of bounds"
```

Stale-phase rule not triggered: there was real work to finish and it was not
finished. That work is finished here, not rewritten — the runner's comparison
logic, its `Outcome` type and its two edge cases are the interrupted attempt's,
with the fixture message corrected and the runner moved to `tests/common/`.

## What changed

| File | Lines | What |
|---|---|---|
| `corpus/NNNN-*.rb` + `.expected` | +472 files | the corpus: 244 programs across 16 families, each paired with the outcome the tree-walking VM produced |
| `tests/common/generator.rs` | +799 | the seeded generator that writes the corpus — 16 families, written-down seed `0x0BADC0DE20200420`, a `{n}` placeholder so a family's extra programs are not copies |
| `tests/common/shrink.rs` | +137 | delta-debugging shrinker: line-halving, then a character pass, both predicate-driven; `without_line`/`without_char` expose the candidates so the minimality assertion tests the shrinker's own deletions; `report` renders a minimal failing program |
| `tests/common/rng.rs` | +65 | SplitMix64 — a fixed-integer generator, so a seed rebuilds the same bytes on any machine and any rustc |
| `tests/common/vm.rs` | +104 | `Outcome`, `tree_walk`, `bytecode` — one program, two VMs, one comparison |
| `tests/common/corpus.rs` | +374 | the corpus on disk: reading it, the `.expected` format (escaped, round-tripped, recording the outcome's label, value, message and output), and the comparison against a recorded outcome |
| `tests/differential_test.rs` | +307 −215 | the 17 corpus tests, including the three that keep the corpus honest |
| `tests/property_test.rs` | +596 | the 14 property and shrinker tests |
| `src/bytecode/vm.rs` | +27 −10 | the round-2 departure from `must_touch`: the last frame's value *is* the program's value, and `SET_PROPERTY` consumes its receiver |
| `src/bytecode/codegen.rs` | +41 −21 | only a block whose value is read (`main`, `Function`, `Method`) leaves one behind |

Line counts are `git diff --numstat` against `6f9e30f`, except the new files.

## Definition of done

| Requirement | Where |
|---|---|
| corpus/ of ≥200 .rb programs, each with an expected-output file | `corpus/` — 244 programs, 244 `.expected`; `corpus_holds_at_least_two_hundred_programs`, `every_corpus_program_has_an_expected_output_file` |
| random program generator with a seed, reproducible | `tests/common/generator.rs` (`CORPUS_SEED`) and `tests/property_test.rs` (`SEEDS`, 8 seeds × 40 programs); `the_generator_is_reproducible_from_its_seed`, `edge_every_seed_produces_a_distinct_corpus_of_programs` |
| shrinker prints a minimal failing program | `tests/common/shrink.rs`; `the_shrinker_reduces_a_counterexample_to_a_minimal_program` prints it, and `the_two_vms_agree_on_every_generated_program` prints the shrunken form in its panic message |
| wired into cargo test | both files are `#[test]`-bearing integration tests; no target registration, no build-script change |

## What the corpus holds

244 programs, no two identical. 215 run to completion; 29 must
fail — 1 `LexerError`, 1 `AnalyzerError`, 16 `ParserError`, 11 `RuntimeError` —
which `the_corpus_holds_programs_that_must_fail` floors at 20 so the corpus
cannot quietly become a corpus of successes. 12 of the 215 record a `#value`
other than `nothing`, which `the_corpus_holds_programs_that_are_worth_something`
floors at 10 — without it every `#value` in the corpus is `nothing` and the
`.expected` comparison never looks at what a program was worth.

| Family | n | What it pins |
|---|---|---|
| `arithmetic` | 20 | nested `+ - *`, unary negation, `type_of`, identity laws |
| `numeric_boundary` | 14 | division and modulo by zero, `2^53±1`, `0.1 + 0.2`, `1/3`, `-0.0`, `i64` edges, division by negative zero — each wrapped in `try` so both the value and the catch are checked |
| `text_ops` | 16 | concatenation, `length`, `is`, empty text, embedded quotes, backslashes, tabs, newlines |
| `unicode` | 16 | emoji, CJK, RTL, combining marks, ZWJ sequences, astral planes, zero-width; `length` and equality on each |
| `lists` | 18 | empty, singleton, index `0`, index `len-1`, negative index, `for each` |
| `records` | 14 | empty, single field, 3-deep nesting, missing key → `nothing`, repeated key keeps the last, order-independent equality |
| `control_flow` | 18 | `if`/`else` nested 1–3 deep, `while` with a counter |
| `functions` | 14 | iteration-as-recursion, a recursive `countdown`, closures, a returned closure called twice |
| `objects` | 12 | `has` with default, `to can`, inheritance, `this`, method writes |
| `loop_forms` | 14 | `repeat` 0 and *n* times, `for each` with a body that skips by condition, `while` to a bound, zero-iteration loops |
| `nesting` | 14 | nested lists and records 3–5 deep, a walk down each level, `if` nested 3 deep |
| `stdlib` | 14 | `length` and `type_of` on every type, singleton/boundary indexes |
| `runtime_errors` | 16 | each error path inside `try … catch` — the catch must fire |
| `faults` | 12 | the same errors uncaught: the failure and everything printed before it, and *both VMs name the same failure* |
| `malformed` | 16 | unterminated literal, missing `end`, stray `end`, missing `to`, missing operand, unclosed list, missing condition, … |
| `values` | 16 | programs whose **last statement is a bare expression**: a bound number, a bound text, arithmetic, concatenation, a yes/no, a whole list, a whole record, a builtin call, a property read, an index, a call that gives a value back, `nothing` itself, a missing key, and two tails (`if`, `for each`) that are worth nothing whatever their body produced |

`stdlib` covers only `length` and `type_of` because nothing else is callable —
FINDINGS.md §2.

## Tests added

| Test | Edge class covered |
|---|---|
| `the_checked_in_corpus_is_the_one_the_generator_produces` | corpus integrity — a hand-edited program, a re-recorded expectation or a deleted program all fail here |
| `the_generator_is_reproducible_from_its_seed` | determinism — the same seed twice is equal; a different seed is not |
| `regenerating_the_corpus_writes_exactly_what_the_generator_produces` | corpus integrity — writes only behind `RB_WRITE_CORPUS=1`, **refuses to record a program the two VMs disagree about**, and floors the corpus at 200 programs *unconditionally* |
| `edge_a_corpus_program_that_stops_failing_is_a_runner_failure` | **asserts a failure is produced** — a recorded failure that no longer happens is reported, caught and asserted, not passed |
| `edge_a_missing_expected_output_file_is_a_runner_failure` | **asserts a failure is produced** — the loader over a scratch directory panics naming the missing `orphan.expected` |
| `edge_a_changed_return_value_is_a_runner_failure` | differential — the same lines printed with a different value is a different outcome; the recorded `#value` catches it, **and both VMs are asserted to agree** on `set t to 5 / say t / t` |
| `the_corpus_holds_programs_that_are_worth_something` | differential — the corpus holds programs worth something, and **both VMs** are run over each one; floors the valued count and the distinct values |
| `edge_a_printed_line_that_looks_like_a_directive_round_trips` | unicode/escapes — a printed `#message`/`#value`/`#label` line survives the round trip as output |
| `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` | resource_limit — a `say` before an uncaught fault is recorded and compared; a *frontend* failure still may not print |
| `edge_every_recorded_failure_points_at_a_line_of_its_own_program` | malformed_input — every recorded failure names a real line and column of its own program |
| `edge_the_generator_emits_every_statement_form_it_lists` | coverage — all seven statement forms occur, **loops included**; an unreachable arm cannot pass |
| `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output` | differential — the generated corpus is worth comparing: both VMs are asked about every program worth something, at least half of the completed ones are, and the values span types |
| `edge_a_generated_program_only_faults_on_a_fault_that_was_injected` | type_mismatch — **the typed-grammar invariant, asserted**: a generated program carrying no injected fault must run to completion |
| `edge_a_generated_failure_points_at_a_line_of_its_own_program` | malformed_input — a generated failure names a real line and column |
| `edge_an_expected_file_carrying_a_multiline_failure_message_round_trips` | unicode/escapes — `\` and newline survive the `.expected` round trip, in both a message and a printed line |
| `edge_the_generator_produces_nothing_the_frontend_swallows_silently` | type_mismatch — the generated grammar must not degenerate into error paths (fails if >half fault) |
| `edge_every_seed_produces_a_distinct_corpus_of_programs` | determinism — 8 seeds, 8 distinct corpora |
| `the_two_vms_agree_on_every_generated_program` | differential — 320 generated programs; on a divergence it **shrinks and prints the minimal failing program** |
| `a_generated_program_runs_the_same_way_every_time` | determinism — the same source twice reaches the same outcome, so a divergence is reproducible |
| `a_generated_program_either_completes_or_reports_a_failure` | **asserts a failure is produced** — a failure names a label this language has and a non-empty message; a non-runtime failure printed nothing; both outcomes must occur |
| `the_shrinker_reduces_a_counterexample_to_a_minimal_program` | malformed_input — 49 lines reduce to `"`, and the reduction is printed |
| `edge_the_shrinker_stops_only_when_nothing_can_be_removed` | malformed_input — minimality asserted against the shrinker's **own** `without_line`/`without_char` candidates: no further line *or* character removal still reproduces, and a line deletion does not move EOF |
| `edge_the_shrinker_deletes_a_character_from_a_multibyte_program` | unicode/escapes — the character pass walks characters, not bytes; a `String::remove` on a non-boundary panics and would abort the binary |
| `edge_the_shrinker_never_invents_a_counterexample` | shrinker soundness — a program that does not reproduce comes back unchanged; a predicate nothing satisfies changes nothing |
| `edge_the_shrinker_reduces_character_by_character_when_no_line_can_go` | malformed_input — the character pass runs, and reduces to the defect rather than past it |

Red before green was watched for the two behaviours this phase introduced:

| Test | Failure before the change |
|---|---|
| `edge_an_expected_file_carrying_a_multiline_failure_message_round_trips` | `left: ["a\\b", "c", "d"]` against `["a\\b", "c\nd"]` — a printed line holding a newline spread over two lines of file, so the expectation described a different program |
| `edge_a_printed_line_that_looks_like_a_directive_round_trips` | a printed `#value 3` line was read back as the value the program ended with, so the file described a different program |
| `edge_a_program_that_prints_before_it_faults_is_recorded_not_asserted_away` | `left: ["before"]` against `[]` — "a program that fails must print nothing" is false |
| `edge_the_generator_emits_every_statement_form_it_lists` | `the generator emitted no program containing "a loop"` — the generator claimed statement coverage and emitted no loop |
| `edge_a_corpus_program_whose_expected_file_names_a_failure_reports_a_mismatch` | (interrupted attempt) `left: "RuntimeError: Index 9 is out of bounds: length is 2, valid indexes are 0 to 1"`, `right: "RuntimeError: Index 9 is out of bounds"` |
| `every_corpus_program_prints_what_its_expected_file_records` | `the corpus directory … should be readable: No such file or directory` — the finding |

## Edge-case matrix

| Row | Covered? |
|---|---|
| empty | covered — `lists`/`records` families hold empty list, empty record, empty text and `nothing`; `loop_forms` holds `repeat 0 times` and a `for each` over `[]` |
| singleton | covered — one-element list (`say one[0]`), one-field record, `repeat 1`, a single nested level |
| boundary | covered — index `0` and `len-1` in `lists`, `i64` and `2^53` boundaries in `numeric_boundary`, loop counters at their bound |
| out_of_bounds | covered — `faults` holds index `len`, index `-len` and index `0` of `[]`; `runtime_errors` holds the same three inside `catch`. Every one records the exact message, e.g. `Index 0 is out of bounds: length is 0, the list is empty, so it has no valid index` |
| type_mismatch | covered — `faults` holds number+text, list+number, yes/no+number, nothing+number, text−number, index-on-number, index-on-record, property-on-`nothing`, walk past a missing key, and a call with the wrong arity |
| numeric_boundary | covered — `numeric_boundary`: `1/0`, `0/0`, `n/0`, `n%0`, `2^53±1`, `0.1+0.2`, `1/3`, `-0.0`, `-2147483648`, `9223372036854775807`, `10^6×n`, `n/−0.0`, signed division |
| unicode | covered — `unicode` family: emoji, CJK, RTL, combining marks, ZWJ, astral (`𠜎`), zero-width, box drawing, `length` and equality on each; plus `text_ops` for `\\`, `\"`, `\n`, `\t` in source |
| nesting_recursion | covered — `nesting` (lists and records 3–5 deep, a walk down every level, `if` nested 3 deep), `functions` (a recursive `countdown`, a closure inside a closure, a returned closure), `objects` (inheritance, `this`) |
| duplicate_missing_keys | covered — `records` holds a repeated key (`{a: 1, a: 2}` keeps the last), a missing key (`nothing`), and a walk past a missing key; `objects` holds a child shadowing a parent's field |
| malformed_input | covered — `malformed` (16 programs: unterminated literal, missing `end`, stray `end`, `set` with no name, `set` with no `to`, missing operand, unclosed paren, `say` with nothing, `for each` with no variable, `repeat` with no count, stray `}`, conditional with no condition, `for each` with no iterable, unclosed list) |
| resource_limit | covered — `runtime_errors` and `faults` hold every catchable runtime error and prove it is catchable rather than fatal; `malformed` holds 16 frontend failures and proves they print nothing; the property tests run 320 generated programs through both VMs and assert no panic anywhere. Every recorded failure is checked against a real line and column of its own program, and the return value of every successful program is recorded rather than assumed. |
| value_bearing_tail | covered — the `values` family: 16 programs whose last statement is a bare expression, 12 of them worth something other than `nothing` on **both** VMs (a number, a text, `no`, a list, a record, a builtin result), and two tails worth `nothing` whatever their body produced. `the_corpus_holds_programs_that_are_worth_something` and `edge_the_generated_corpus_compares_a_program_s_value_not_only_its_output` keep both non-empty: 208 of 282 completed generated programs are worth something, across 90 distinct values. |
| generator_well_typed | covered — `edge_a_generated_program_only_faults_on_a_fault_that_was_injected`: every generated program carrying no injected fault runs to completion, which is what makes the deliberate `random_fault` mix the *only* source of failures. It found three broken arms in one pass. |

## Gates

Re-run after the round-1 fixes, in the same order as before:

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass, 0 warnings |
| `cargo test --all-targets` | **521 passed, 0 failed, 0 ignored** (and `cargo test --doc`: 1 passed) |
| `./rbops/verify.sh phase-020` | **not run — `rbops/verify.sh` does not exist in this checkout** |

521 rather than the 515 of the first submission: six tests were added for the
findings, and none was deleted or ignored. `tests/differential_test.rs` holds 16
and `tests/property_test.rs` holds 12.

On the fourth gate, honestly: there is no `rbops/` directory here at all
(FINDINGS.md §6), and the task instructions say the pipeline that dispatched
this phase lives outside the checkout. The three gates that do exist were run
and are green. In their place, the backwards-compatibility check `AGENTS.md` §2
names:

```
$ for f in examples/*.rb modules/*.rb; do rb run "$f" >/dev/null || echo "FAIL $f"; done
examples/files.rb  examples/fizzbuzz.rb  examples/formats.rb  examples/hello.rb
examples/test_arithmetic.rb  examples/time.rb  modules/MathUtils.rb  modules/SuiteKit.rb
```

All 8 run clean. Nothing under `src/` was touched, so there is nothing in the
corpus that could have broken them.

Determinism was checked by regenerating twice and comparing checksums, since the
`.expected` format changed and a diff against the pre-change files would be
non-empty by construction:

```
$ before=$(cat corpus/* | sha256sum)
$ RB_WRITE_CORPUS=1 cargo test --test differential_test
$ after=$(cat corpus/* | sha256sum)
DETERMINISTIC: regeneration is byte-identical
```

## Invariants touched

- **Two, both in the bytecode VM, both round-2 departures from `must_touch`.**
  No syntax or grammar changed — the `Value` and `Error` variants, the `.rb`
  extension, `to … end` / `if … end` / `for … end`, `set x to`, `say` and the
  trailing-comma/`{interp}` syntax are all untouched, and every pre-existing test
  still passes (525 total, 0 failures) — but two things about what a *program* is
  worth did change:
  - a program ending in a bare expression now ends with that expression's value
    on the bytecode VM, as it already did on the tree-walking one (FINDINGS §4);
  - a statement consumes everything it produced, so `set r.a to 2` no longer
    leaks a record onto the operand stack and `if … then 7 … end` no longer
    leaves `7` for the enclosing block. Both were invisible before because the
    top-level frame discarded whatever it finished with; they are the same bug
    wearing a second hat.
  Neither changes a `.rbc`'s format or the `.expected` format, so the bootstrap
  ladder and the golden files are unaffected. The syntax above is unchanged.
- One placement decision: the corpus lives at `corpus/`, not `tests/corpus/`.
  `redblue::testing::find_test_files("tests")` (`src/testing/mod.rs:64`) walks
  `tests/` recursively and `redblue_suite_test.rs:126` requires every `.rb` file
  it finds to declare Redblue `test` blocks — a corpus program declares none, and
  `a corpus program is not a test` is the correct thing for that test to say. At
  the repository root the corpus is out of the suite's way, which is also where
  the phase's definition of done asks for it (`corpus/`).

## Known gaps / follow-ups

- **The corpus cannot cover the documented stdlib.** `abs`, `uppercase`,
  `split`, `map`, `reduce` and ~30 other registered builtins are unreachable from
  Redblue source; the generators use `length` and `type_of` and nothing else →
  FINDINGS.md §2. Until that is fixed, "the corpus proves the two VMs agree" is
  a claim about the subset of the language that works.
- **Three defects in `src/` are recorded, not fixed**, because this phase declares
  `must_touch: ["tests/"]` and AGENTS.md §1 rule 7 says another phase's work goes
  in FINDINGS.md: a nested `return` that does not return (§1), the unreachable
  stdlib (§2), and `break`/`skip` as no-ops (§3). None of them is a divergence —
  both VMs agree on the wrong answer — so the differential harness cannot catch
  any of them, which is the point of recording rather than fixing them here.
- **§4 was fixed in round 2, outside `must_touch`, and that is a decision the
  auditor should look at.** §4 — trailing tokens silently accepted, and the two
  VMs disagreeing about a program's value — was the one blocking S3: two VMs
  that disagree about a program's value make a byte-identical fixed point
  vacuous. The round-2 review asked for `tree_walk == bytecode` asserted on a
  program ending in an expression, and no change confined to `tests/` can make
  that true. The fix is three small changes in `src/bytecode/`, listed above;
  the alternative was a harness that stays green and keeps asserting nothing
  about values. The round-1 reasoning — "no corpus program can hold a
  non-`nothing` value without recording a known divergence as the
  specification" — was the BLOCKER, not a defence of it.
- The parser still accepts trailing tokens on one line (`say 1 2 3`), which is
  the other half of §4 and is *not* fixed: that is a grammar question
  (`docs/GRAMMAR.md` puts one statement on a line) rather than a divergence, and
  fixing it would change what programs parse.
- The property generator's grammar is typed, so it cannot generate a
  type-mismatched program by accident; `random_fault` injects those on purpose.
  That is a deliberate limit — a generator that produced mostly type errors
  would assert only that errors happen, which
  `edge_the_generator_produces_nothing_the_frontend_swallows_silently` fails on.
- The corpus regenerates only when `RB_WRITE_CORPUS=1` is set. A CI job that set
  it would rewrite the golden files instead of failing on a regression.
- `rbops/verify.sh` was not run because it is not present → FINDINGS.md §6.