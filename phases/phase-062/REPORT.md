# Phase 062 — Open a debug sub-REPL: `.debug` with `.watch`, `.stack` and `.locals`

## Reproduce (before the change)

The phase's finding claimed "no `.debug` command exists in commands.rs". That
was **stale in one detail and right in every one that mattered**. On HEAD
(`60d7fcf`, "state after phase-061"):

- `.debug` *did* parse — as a no-argument placeholder that ignored whatever was
  typed after it and printed a breakpoint summary. There was no sub-REPL, no
  tracing, no way to evaluate anything inside a debug session.
- `watch`, `stack` and `locals` did not parse at all, as either `.`-commands or
  anything else.

```
$ printf '.watch x\n.stack\n.locals\n.debug 1 + 1\n:quit\n' | ./target/debug/rb
>>> Unknown command 'watch'. Type :help for available commands.
>>> Unknown command 'stack'. Type :help for available commands.
>>> Unknown command 'locals'. Type :help for available commands.
>>> Debugger: 0 breakpoint(s) set. `:break <line>` sets one, `:next` steps
over a call, `:step` steps into it, `:continue` runs on.
Goodbye!
```

The last line is the stale half: `.debug 1 + 1` did not run `1 + 1`, and
"Debugger:" promised breakpoint machinery phase-062's scope explicitly excludes.
The remedy the finding asks for — an in-session, observe-only debug sub-REPL —
is what this phase implements; the placeholder's message is deleted with it
(the `:break`/`:next`/`:step`/`:continue` commands it advertised remain where
they were, on the separate breakpoint session `repl.debug`, untouched).

## What changed

`must_touch: ["src/"]` is satisfied: five files under `src/`, **+1245 −22** in
total — `git diff --numstat HEAD`, re-derived rather than trusted.

| File | Lines | What |
|---|---|---|
| `src/repl/commands.rs` | +116 −7 | `ReplCommand` gains `Debug(String)`, `Watch(String)`, `Stack`, `Locals`, `Back`; the parse table gains the five specs (`debug` optional-argument, `watch` required-argument); `argument_text` carries the arguments; the alias-table test gains the five rows. |
| `src/repl/debug_repl.rs` (new) | +816 | The whole sub-REPL. `DebugRepl` (a forked `Vm`, an `Arc<Mutex<State>>`, its own line buffer, its own `_`); `Watch`/`Trace`/`State`; the debug-hook closure; `evaluate_watches` (the one place a watch is evaluated — statement stops and end-of-run pass both); the `impl Repl` glue (`debug_session`, `enter_debug`, `debug_line`, `run_debug_argument`, `run_in_debug`); 8 tests. |
| `src/repl/mod.rs` | +158 −15 | The `debug_repl: Option<DebugRepl>` field; the session-loop branch that hands every line to `debug_line` *before* the history push while a session is open; the EOF branch reporting the sub-REPL's unclosed block as its own; `prompt_for_next_line` returning `debug> `/`..  N ` inside a session; `handle_command` wiring `Debug`/`Watch`/`Stack`/`Locals`/`Back`; the old `debug_mode` placeholder removed; `session_names` extends with the sub-REPL's names while open (completer snapshot only); 1 test (parent byte-identity). |
| `src/debugger.rs` | +77 | `DebugEvent` gains `call_stack` (outermost-first frame names), `scope_base` (where this frame's scopes start) and `frame_writes` (which globals this frame overwrote), plus `DebugEvent::frame_locals()` — the `.locals` answer, scopes from `scope_base` on, innermost-wins, frame-writes branch, sorted by name. |
| `src/interpreter.rs` | +78 | `Vm` fields `call_stack`, `frame_scope_base`, `frame_writes` (initialised in `new_in`); `call_user_function` — the one choke point for every way a Redblue function is called — saves the caller's `scope_base`, records the callee's frame name, and restores/pops on both exits; `set_var`'s globals fall-through records into `frame_writes.last_mut()`; `debug_before` emits the new fields; `Vm::observe_bindings` (overwrite a VM's bindings without running anything) and `Vm::current_bindings` (borrow the bindings after a run). |

The semantics, in the places they live:

- **Observe-only.** The hook returns `DebugAction::Run` always; a watch that
  fails is a line of report, never an error in the run. The scratch VM that
  evaluates watches is created with `ask_questions(true)`, so an effectful
  builtin — `files.write`, `network.post` — is refused at the call rather than
  performed on behalf of an expression that was only being watched.
- **`.watch` reports changes, not steps.** Registration is parse-only (an
  expression that does not parse is refused then, not at some future step).
  The first value a watch ever sees is its baseline and is *not* reported — a
  watch set on a name with a value has not seen a change. Every later difference
  from the last held value is one line, `watch <source> = <value>`, including
  the value a program's *last* statement produced: after each run the watches
  are evaluated once more against the bindings the run finished with, because
  no statement stop exists after a program's final statement to observe it at.
  A watch that fails reports one line per evaluation (`watch <source>: <first
  line of the error>`) and keeps its previous value.
- **`.stack` / `.locals` answer about the last step.** "No live frames." before
  anything has run — including right after a bare `.debug`. `.locals` shows the
  stepped frame's parameters and locals (`scope_base` slicing is what keeps the
  caller's frame out) plus the globals *this frame* overwrote (`frame_writes`,
  recorded only on `set_var`'s globals fall-through — see Known gaps).
- **`.back` is the way out**, and while a session is open every typed line —
  command or code, buffered or whole — belongs to the sub-REPL: it is
  dispatched by `debug_line` and reaches neither the parent's history, nor its
  transcript, nor its bindings. The `.debug` line itself was typed at the
  parent prompt and is the parent's; the `.back` line was typed at `debug>` and
  is not. The name: `exit` is taken (`:quit`), `leave` would have been a second
  word for the same thing, and `back` says what the user wants — the session
  they left.
- **`.debug <arg>` while open runs `arg` in the current session** (re-entry
  semantics); a bare `.debug` while open says so once. An argument ending in
  `.rb` is read as a file — the suffix is the detection, because a REPL
  argument is already ambiguous between a path and an expression, and the
  suffix is the convention `:load` and `rb run` use. A file that cannot be read
  is one error line; the session still opens (the banner comes first).
- **A block typed in the sub-REPL is the sub-REPL's block.** Its own buffer,
  its own `..  N ` continuation numbering, its own unclosed-block report on
  EOF, its own too-large report — against the parent's limits, because they are
  one session's limits, not two sessions'.

## Tests added

Ten new `#[test]` functions, all through the sub-REPL driver or the real read
loop over a scripted source — none needs a TTY.

| Test | Edge class covered |
|---|---|
| `repl::commands::tests::the_debug_sub_repl_commands_parse` | malformed input — the five spellings parse to the right variants with the right argument, and `.debug` with no argument parses to `Debug("")` rather than a missing-argument error |
| `repl::debug_repl::tests::debug_stack_names_a_three_deep_call_chain` | nesting — `.debug outer()` over a three-deep chain, `.stack` names `outer`, `middle`, `inner` in call order |
| `repl::debug_repl::tests::debug_watch_reports_only_the_steps_where_the_value_changed` | happy path + counting — four statements run, three changes, exactly three report lines and no others; **this is the test that was red first** (the first implementation reported the baseline as a change: `["watch x = 0", "watch x = 1", "watch x = 2"]`) |
| `repl::debug_repl::tests::debug_locals_shows_the_stepped_frame_and_not_the_callers` | frame isolation — the callee's parameter and local listed, the caller's local and the global the caller overwrote both absent, while the callee could see that global through Redblue's own scoping |
| `repl::tests::a_debug_sub_repl_leaves_the_parent_session_untouched` | byte-identity — driven through `session_loop` with a scripted source: history is exactly the two parent-prompt lines, the transcript is a strict prefix plus the post-`.back` line, the sub-REPL's binding absent from the parent's VM, the resumed line's binding present, the parent's `_` never written, the block buffer empty, a `debug>` prompt asked |
| `repl::debug_repl::tests::edge_a_bare_debug_opens_a_session_and_runs_nothing` | empty — `.debug` with no argument opens with the banner, runs nothing, `.back` returns; the next line answers outside any session |
| `repl::debug_repl::tests::edge_a_watch_that_cannot_parse_fails_and_the_session_goes_on` | malformed input + **failure produced** — `.watch 1 +` is a reported failure (`Error:` line quoting the source), `parse_only("1 +").is_err()` asserts the property underneath, `.stack` still answers `No live frames.` (also the no-live-frames edge), the session never closed |
| `repl::debug_repl::tests::edge_a_watch_on_an_unbound_name_reports_per_step_and_the_run_still_finishes` | missing name + **failure produced** — `.watch nosuchname` over a loop reports `Unknown variable 'nosuchname'` once per evaluation (four for the loop run, two for the one-statement run typed after), and the run still answers `= 2` |
| `repl::debug_repl::tests::edge_a_debug_of_a_file_that_cannot_be_read_says_so_and_still_opens` | missing resource — `.debug definitely_missing_phase062.rb` answers `Error: cannot read '…'`, the sub-REPL opens anyway, `.stack` answers inside it |
| `repl::debug_repl::tests::edge_sub_repl_commands_outside_a_session_say_how_to_open_one` | boundary — `.stack`, `.locals`, `.watch x`, `.back` with no session open all answer the one sentence naming `.debug` |

### Edge-case matrix (AGENTS.md §3.2)

- **empty** — covered: bare `.debug` (`edge_a_bare_debug_opens_a_session_and_runs_nothing`); `.stack` before any step (`No live frames.`).
- **singleton** — covered: the one-statement `.debug 1 + 1` run inside the unbound-watch edge (one stop, one end-of-run pass, two reports).
- **boundary** — covered: sub-REPL commands with no sub-REPL open (`edge_sub_repl_commands_outside_a_session_say_how_to_open_one`).
- **out_of_bounds** — N/A: this change indexes no user-supplied position; `scope_base` slicing is internal and cannot go past the scope stack (it is taken from the VM at a live frame).
- **type_mismatch** — covered in its failure shape: a watch on a name that does not exist takes the same per-step error path as any other failing evaluation (`edge_a_watch_on_an_unbound_name…`); arithmetic type failures on watched values take that identical `Err` path — no separate branch exists to test.
- **numeric_boundary** — N/A: no numeric surface is introduced; watch values are compared with `Value` equality, and `Value::number` already refuses non-finite numbers, so a NaN comparator is not a branch this change has.
- **unicode** — N/A: no encoding surface is introduced; a watch's name is interpolated into a report line with `Display`, which is exercised for every value across the watch tests.
- **nesting_recursion** — covered: three-deep call chain for `.stack`; frame isolation for `.locals`.
- **duplicate_missing_keys** — covered (missing half): watching a name nobody bound reports per step without aborting; re-registering the same watch twice is two independent watches (each compares against its own last value — no shared state exists to corrupt).
- **malformed_input** — covered: `.watch 1 +` refused at registration; every sub-REPL command's parse is pinned by the alias-table rows.
- **resource_limit** — N/A with reason: the sub-REPL reuses the parent's block limits (`MAX_BLOCK_LINES`/`MAX_BLOCK_BYTES`) through the parent's own `exceeds_block_limits`; the enforcement is tested at the parent, and the forwarding path here is the three lines of `report_block_too_large`. A runaway *run* is bounded by the same step budget the parent never resets.

## Gates

Run in this checkout, on the tree as it now stands, in this order:

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass |
| `cargo test --all-targets` | **1878 passed, 0 failed** across 67 test binaries (log: `target/tmp/test_final.log`; the long poles are the pre-existing bootstrap self-hosting suites at ~280 s and ~373 s) |
| `cargo test --doc` | 2 passed, 0 failed |
| `../rbops/verify.sh "phase-062"` | run after this file existed (the gate requires it up front); result recorded below |

What `verify.sh` does, for the record: it validates that the phase is declared
in `rbops/phases.json` with its dependencies `.done`; that this report exists
with its four required sections and at least one evidence row naming a file;
that the working-tree diff against HEAD touches no forbidden path
(`.github/workflows/`, `rbops/`, `.opencode/agent/`), adds no gate-weakening
construct (`#[ignore]`, `// skip`, `allow(clippy::…)` at line start), contains
no scratch files, and clears the manifest's minimum line count; that at least
one changed file falls under the phase's `must_touch`; that the four cargo
gates pass and every `examples/*.rb` and `modules/*.rb` still runs under the
built binary (baselined pre-existing failures excepted, and the exemption
revoked for any file this phase touched); that the diff carries at least three
new `#[test]` functions, at least one `edge_*` test and at least one assertion
that a *failure* is produced, with no newly skipped or ignored tests; and that
the test count this report claims is within tolerance of the count its own run
measured — over-claiming fails the phase, under-claiming only warns.

**`verify.sh "phase-062"`: PASS.** (Run immediately after this report was
written; every check green on the first attempt — manifest, report, diff
hygiene, `must_touch`, the four cargo gates, the examples sweep, test policy
and the honesty check.)

## Invariants touched

`phases/INVARIANTS.md`'s language surface is unchanged: `.debug`, `.watch`,
`.stack`, `.locals` and `.back` are REPL commands behind the same `.`-sigil
parser as every other session command — no keyword, no statement form, no
change to what a `.rb` file may contain. The breakpoint session behind
`:break`/`:next`/`:step`/`:continue`/`:frame` is untouched; only the dead
`debug_mode` printer that advertised it from `.debug` was removed, and it had
no tests.

## Known gaps / follow-ups

- **File detection is the `.rb` suffix only.** `.debug notes.txt` runs the
  string as code and fails to parse it, rather than reading the file. The
  suffix is what `:load` and `rb run` use; a `file:` prefix or an explicit
  `:load`-style command inside the sub-REPL would be the follow-up if it
  chafes.
- **`frame_writes` records only globals overwritten by `set`.** A `to`
  function, an `import` or a `constant` declared inside a frame does not
  appear in that frame's `.locals` listing. The frame's own scopes (parameters
  and locals) are complete; this is only the globals-branch, and the
  alternative — tracking every binding site — was more machinery than the
  DoD's "parameters and locals and nothing from the caller's frame" asked for.
- **Sub-REPL completion is the union snapshot** of parent and sub names (via
  `session_names`), refreshed at each prompt; it has no command-name
  completion of its own. Commands are five and their names are in the banner.
- **The entry `.debug` line is in the parent's history** — it was typed at the
  parent prompt — while every line typed at `debug>` is not. A `:history` on
  the far side of `.back` therefore shows the door and not the room, which is
  the contract stated in `src/repl/mod.rs`; it is a deliberate asymmetry, and
  it is testable (`a_debug_sub_repl_leaves_the_parent_session_untouched`
  pins both halves).
- **No step budget is added or reset.** Sub-REPL runs share the VM's
  `MAX_STEPS` default, exactly as parent runs do; a watch multiplies work per
  step by the number of registered watches, which is the user's arithmetic to
  be careful with, not a second budget to police.
- **Stepping and breakpoints stay out of scope**, as the goal says: if this
  sub-REPL proves its worth, `:break`-style primitives wired to the sub-REPL's
  hook are their own phase.
