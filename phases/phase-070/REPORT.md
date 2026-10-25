# Phase 070 — Weigh the session: `.mem` and `.profile`

## Reproduction

Before the change, neither word was in the command table, so the session treated
each as a mistyped command:

```
$ printf '.mem\n.profile\n:quit\n' | rb
>>> Unknown command 'mem'. Type :help for available commands.
>>> Unknown command 'profile'. Type :help for available commands.
```

After the change the same lines answer from the session:

```
$ printf 'set payload to "abcdefghij"\n.mem\nset x to 0\nfor each i from 1 to 5000\n    set x to x + i\nend\n.profile\n:quit\n' | rb
>>> Memory:
  bindings: 1 (10 B (10 B))
  history: 2 entries (31 B (31 B))
  heap: 10 B (10 B)
  largest bindings:
    payload               10 B (10 B)
>>> >>> ..  2 ..  3 >>> Profile: last block, 3 line(s), wall time
  total: 17.441 ms
  line 1: 11.655 ms  for each i from 1 to 5000
  line 2: 5.786 ms  set x to x + i
  line 3: 0.000 ms  end
```

## What changed

| File | Lines | What |
|---|---|---|
| `src/repl/commands.rs` | +59 −0 | `ReplCommand::Mem`, `ReplCommand::Profile`, their `COMMAND_TABLE` rows (`:mem`/`:memory`, `:profile`, so `:help`, completion and parsing share one source), and the parse test |
| `src/repl/mod.rs` | +408 −0 | dispatch for both commands, `memory_answer`/`binding_sizes`, `profile_answer`/`print_profile`, `last_profile` session state filled by `execute_line` for a multiline block, and the eight session tests |
| `src/repl/weight.rs` | new, 848 | the read-only arithmetic: logical `value_bytes` (cycle-safe, shared storage walked once, function bodies measured as statements or compiled chunks), `human_bytes` (B through EiB with raw bytes), `memory_lines`, `BlockProfile`/`profile_lines` (integer division), and fourteen unit tests |
| `src/interpreter.rs` | +137 −0 | an optional per-statement `LineTimer`; `start_line_profile`/`take_line_profile`, self-time accounting that subtracts nested statement time, call-depth filtering so a called function's body time stays on the call-site line, and the test that pins it |

`.mem` reports the binding count and their logical bytes, the history entry count
and bytes, a heap estimate (the sum of binding bytes), and the ten largest
bindings heaviest first. Every size is rendered as a human unit with the raw byte
count in parentheses, including `0 B (0 B)`, so a fresh session never prints a
blank figure.

`.profile` reports every source line of the last multiline block, slowest first,
with the total being the sum of the line figures. The timer records a statement's
own time (elapsed minus nested statements), so parts add up instead of
double-counting a loop body inside its loop. Statements inside a user-function
call are not attributed to the function's declaration line; their time remains on
the call-site line the block actually showed. The same rule covers a `catch` or
`finally` body running in that call, while a top-level `finally` is timed
normally.

Both commands only observe: bindings are borrowed for sizing, never cloned, and
neither history nor `_` is written.

## Tests added

| Test | Edge class covered |
|---|---|
| `mem_reports_the_largest_binding_and_its_size` (repl/mod.rs) | boundary — a 10 KiB binding is listed first and reports `10.0 KiB (10240 B)` |
| `edge_mem_on_a_fresh_session_names_every_zero` (repl/mod.rs) | empty — zero bindings, zero history, `0 B (0 B)` and `(none)`, never blank |
| `edge_mem_twice_leaves_bindings_and_last_result_alone` (repl/mod.rs) | state — two `.mem` runs leave the binding count and `_` unchanged |
| `edge_mem_reports_a_five_megabyte_text_without_copying_it` (repl/mod.rs) | resource limit — a 5 MiB binding is sized by length and survives the report |
| `edge_profile_with_no_previous_block_names_the_history` (repl/mod.rs) | empty / failure — a fresh session returns an error naming `:history` |
| `profile_times_each_line_slowest_first_and_sums_to_the_total` (repl/mod.rs) | boundary — three-line block has three rows, ordered slowest first, parts within 20% of total |
| `profile_reports_only_the_last_block_not_the_earlier_one` (repl/mod.rs) | state — a second block replaces the first block's source and timings |
| `profile_quotes_the_line_the_lexer_numbered` (repl/mod.rs) | boundary — a newline inside a text literal keeps the following statement on its own source line |
| `mem_and_profile_are_commands` (commands.rs) | malformed input — both sigils and `:memory` parse as commands that take no argument |
| `edge_human_bytes_names_zero_and_keeps_the_raw_count` (weight.rs) | empty / boundary — 0 B, byte boundary, KiB, MiB, GiB and TiB |
| `val_bytes_covers_text_lists_records_and_sharing` (weight.rs) | nesting — text, shared list storage counted once, record keys plus values |
| `val_bytes_covers_scalars_builtins_objects_and_functions` (weight.rs) | type coverage — number, yes/no, builtin, object and function sizes |
| `val_bytes_covers_a_statements_function_body` (weight.rs) | coverage — a non-empty statements body's nodes and text are measured, not ignored |
| `val_bytes_covers_a_compiled_block_function_body` (weight.rs) | coverage — a compiled block's chunk bytes and path are measured |
| `edge_profile_stays_exact_past_the_float_mantissa` (weight.rs) | numeric_boundary — a timing past `f64`'s exact-integer range keeps its integer quotient in both the total and the row |
| `profile_keeps_a_user_function_body_at_its_call_site` (interpreter.rs) | nesting / recursion — a called function's body is not timed as its own lines |
| `edge_memory_lines_report_every_zero_on_an_empty_session` (weight.rs) | empty — every figure named at zero |
| `memory_lines_order_the_largest_first_and_stop_at_the_listing_limit` (weight.rs) | boundary — heaviest first and the top-ten cap holds |
| `edge_profile_on_an_empty_block_still_names_a_zero_total` (weight.rs) | empty — no block still prints a zero total, not a blank page |
| `profile_lines_are_slowest_first_and_sum_to_the_total` (weight.rs) | boundary — ordering and total arithmetic on fixed timings |
| `edge_profile_lines_keep_a_timing_past_the_source` (weight.rs) | out_of_bounds — a timing past the quoted source keeps its row and its share of the total |
| `edge_human_bytes_stays_exact_past_the_float_mantissa` (weight.rs) | numeric_boundary — a count past `f64`'s exact-integer range keeps an exact whole unit and raw count |
| `edge_value_bytes_measures_a_deep_value_without_recursing` (weight.rs) | nesting_recursion / resource_limit — 100,000 nested lists are measured with an explicit stack and the bottom text is still counted |
| `edge_source_lines_match_the_lexers_line_numbers` (weight.rs) | boundary — the source map splits where the lexer increments its line, including inside a text literal |

### Mandatory edge-case matrix

- **empty** — covered: fresh `.mem` zeros, empty history, empty profile block, and `.profile` with no previous block.
- **singleton** — covered: one 10 KiB binding is the one largest entry; one history entry has the singular spelling.
- **boundary** — covered: the 1024-byte unit boundary, the top-ten listing cap, and a three-line profile whose parts sum to the total.
- **out_of_bounds** — covered: a timing whose line is past the quoted source keeps its own row and is still part of the total, and the source lookup uses a checked subtraction.
- **type_mismatch** — N/A: both commands accept no argument and every `Value` variant has a defined logical size (untyped values are not an error here).
- **numeric_boundary** — covered: sizes are byte counts and timings elapsed nanoseconds; integer arithmetic keeps both a count and a profile timing past `f64`'s 53-bit mantissa exact, and the 5 MiB case pins the large end.
- **unicode** — covered indirectly by `value_bytes`, which counts UTF-8 bytes; no new text transformation was added, and history/profile source text is already UTF-8.
- **nesting_recursion** — covered: `value_bytes` walks nested lists/records/functions with an explicit stack and an `Arc`-address visited set, so shared storage is counted once, a cycle cannot loop forever, and deep acyclic data cannot overflow the process stack.
- **duplicate_missing_keys** — N/A: no new keyed collection; record keys are summed in `value_bytes` and a missing field is not reachable from a value.
- **malformed_input** — covered: `.mem`/`.profile` take no argument, so no malformed argument path exists; the parse test pins that both are commands rather than unknown words.
- **resource_limit** — covered: the 5 MiB text is measured from its length without cloning it into the report.

## Gates

| Gate | Result |
|---|---|
| cargo fmt --all -- --check | pass |
| cargo clippy --all-targets -- -D warnings | pass |
| cargo test --all-targets | 2175 passed, 0 failed, 0 ignored |
| ../rbops/verify.sh phase-070 | pass — `VERIFY PASS — phase-070` |

## Invariants touched

- None in the language: no grammar, keyword, `Value`/`Error` variant or `.rb` extension changed.
- REPL-only: two new command-table rows and two read-only reports. `:reset` does not clear the profile (it is an observation about a block that ran, not session state), matching history's treatment.

## Known gaps / follow-ups

- `.mem` is a logical-size estimate, not an allocator figure: shared list/record storage is counted once inside one binding but two bindings holding the same `Arc` are each counted. That is stated in the module and pinned by tests; no allocator hook is added.
- The profile timer is the tree-walker's, which is the engine a REPL session runs. A future bytecode-profile command would need its own instrumentation rather than sharing this one silently.
