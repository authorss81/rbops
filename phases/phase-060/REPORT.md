# Phase 060 — Export sessions and complete file paths: `.export` plus TAB for `:load`/`:save`

## What changed

`.export`, TAB path completion, `.reload`, `.format` and format-on-enter were
already in the tree (commit `a61cdef`), complete against the phase's definition of
done, and are not touched by this run beyond one `#[test]` that pins a property of
the complier this run reasoned about.

The gate was red on arrival in exactly one test,
`unreviewed_work_in_head_history_is_acknowledged`, and the run found one real
defect in the phase's own code. `must_touch: [src/]` is satisfied by
`src/repl/mod.rs` and `src/repl/completer.rs`. This run's diff is **+197 −2**
across 4 files (`git diff --numstat -- src/ tests/`).

| File | Lines | What |
|---|---|---|
| src/repl/mod.rs | +18 −1 | `write_source_atomically` carries the target's permissions onto the temporary before the rename, so `.format` stops resetting a file's mode to `0644` |
| src/repl/completer.rs | +42 −0 | `edge_a_name_typed_whole_is_offered_past_the_cap`: the cap cannot take the one name the user typed whole |
| tests/repl_test.rs | +136 −0 | 2 new tests: the mode `.format` gives back, and a `.format` whose temporary name is already taken |
| tests/unreviewed_work_ack_test.rs | +1 −1 | The `a61cdef` acknowledgement this resume needs, replacing the `5b73229` row that commit does not descend from (see *The red gate this run inherited*) |

## The red gate this run inherited

`cargo test` failed on arrival, in one test:
`unreviewed_work_in_head_history_is_acknowledged`.

```
unreviewed-work commits selected: 31 | acknowledged: 31 | unacknowledged: 1 | stale entries: 1
| UNACKNOWLEDGED: a61cdef…  resume phase-060: adopt preserved work
| STALE: 5b73229…
```

Two failures in one assertion pair, one cause: the acknowledgement list named
`5b73229`, the phase-060 commit this clone of the tree actually descends from is
`a61cdef`, and `5b73229` is not an ancestor of `HEAD`. `scan` therefore reported
the real `HEAD` commit as unreviewed and the row for the abandoned attempt as
stale. One row replaced with one row, carrying what `a61cdef` contains (+3879/−18,
10 files, +2188/−17 under `src/`) and why the abandoned attempt is not listed,
following the pattern phases 056 and 059 already established. The test's
`MEASURED` list was checked against `git log HEAD` first: every SHA in it is in
this history, so nothing else needed changing.

## The defect this run found: `.format` reset every file's permissions

Reproduced on the tree as it stood, before any change:

```
$ printf 'if 1 is greater than 0 then\nsay "a"\nend\n' > q.rb && chmod 755 q.rb
$ printf 'if 1 is greater than 0 then\nsay "a"\nend\n' > n.rb && chmod 600 n.rb
$ printf '.format q.rb\n.format n.rb\n:quit\n' | ./target/debug/rb
>>> Formatted 'q.rb'.
>>> Formatted 'n.rb'.
$ ls -l q.rb n.rb
-rw-r--r-- 1 runner runner 30 q.rb      # was -rwxr-xr-x
-rw-r--r-- 1 runner runner 30 n.rb      # was -rw-------
```

`write_source_atomically` writes a temporary beside the target and renames it
over the top. A rename brings the **incoming** file's mode with it, and the
incoming file is one the function had just created — `0644`, whatever the umask
and whatever the file it was replacing was. So `.format` of an executable script
returned a file that could no longer be run, and `.format` of a `0600` file
returned one readable by everyone: the session widened a file's permissions
while formatting it and reported only "Formatted". The message is the whole of
what the user was told, so the loss was silent.

The fix reads the target's permissions before the write and puts them on the
temporary, so the file that arrives over the top has the mode of the file it
replaces — narrowed and widened alike. The atomicity is unchanged: a failure to
write the temporary or to set its mode removes it and returns the error, and the
caller's "It is unchanged" is still true.

**What was deliberately not changed:** a `0444` file in a writable directory is
still formatted rather than refused. `tests/repl_test.rs` documents that as a
decision — "a `0444` file on its own is not in the way, because a rename asks the
directory and not the file, which is the same answer every editor that saves
atomically gives" — and reversing it is a design call, not a bug fix. What was
broken is the *mode*, which the same comment says nothing about. With the fix, a
`0444` file is formatted and comes back `0444`; the decision stands and its
worst consequence is gone.

## Tests added

3 new `#[test]` functions, all three named `edge_*`: 2 in `tests/repl_test.rs`
and 1 in `src/repl/completer.rs`. No test was weakened, skipped, ignored or
suppressed; this diff adds no `#[ignore]`, no `// skip` and no
`allow(clippy::`. The one pre-existing test file touched is the acknowledgement
list, which gained a data row.

| Test | Edge class covered |
|---|---|
| edge_format_keeps_the_permissions_the_file_had | **resource/state** — the finding: `0755` stays `0755` and `0600` stays `0600` across `.format`, and the content is still what `formatter::format` writes |
| edge_format_of_a_file_whose_temporary_name_is_taken_leaves_it_alone | **failure / resource_limit** — a directory already named `prog.rb.tmp` stops the write; the path is named, "It is unchanged" is printed, the source is byte-for-byte, and the occupying directory is left alone |
| edge_a_name_typed_whole_is_offered_past_the_cap | **boundary** — the exact name is offered in a directory larger than `MAX_PATH_CANDIDATES`, and a listing is still capped |

**Every new test was watched.** `edge_format_keeps_the_permissions_the_file_had`
was red on its mode assertion with `left: 420` (0o644) against `right: 493`
(0o755) before `write_source_atomically` changed. Its first run was red for a
different reason — I had written out the formatter's expected output by hand and
got `is greater than 0` where the formatter writes `>` (F7); the expectation is
now asked of `redblue::formatter::format` instead of copied, so it fails for the
permissions and not for a formatter change. The other two tests were green on
first run and are boundary pins rather than fixes; that is stated here rather
than dressed up as a red-to-green story.

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | **pass** — no output |
| `cargo clippy --all-targets -- -D warnings` | **pass** — `Finished dev profile`, no warning or error |
| `cargo test --all-targets` | **pass** — 1872 passed, 0 failed, 0 ignored, across 67 binaries |
| `./rbops/verify.sh phase-060` | **NOT RUN — `rbops/` does not exist in this checkout** |

```
$ ls rbops
ls: cannot access 'rbops': No such file or directory
$ find . -maxdepth 3 -name "verify*.sh" -not -path "./target/*"
(no output)
```

The fourth gate could not be executed: there is no `rbops/verify.sh` in the tree
this phase was given, and `find` finds no verify script anywhere. This report
does not claim it passed. `.github/workflows/ci.yml` runs
`cargo fmt --all -- --check`, `cargo clippy -- -D warnings` and the test suite —
the first three gates above — and those are green. See F1 in `FINDINGS.md`,
recorded identically by phases 057, 058 and 059.

`cargo test --doc` was run as well (2 passed), and backwards compatibility was
checked by hand: every file in `examples/` and in `modules/` run through
`rb run` (9 of 9, all exit 0).

## Invariants touched

- **`.format` no longer changes a file's permissions.** It did: every formatted
  file came back `0644`. The mode the file had is now the mode it keeps, in both
  directions. No `Value` variant, no `Error` variant, no grammar change, no
  change to `to … end` / `set x to` / `say`, no change to the `.rb` extension.
- **Whether a read-only file is formatted at all** is unchanged — a `0444` file
  in a writable directory is still formatted, as
  `edge_format_of_a_file_that_cannot_be_written_names_the_path_and_leaves_it_alone`
  documents and asserts. It now comes back read-only rather than writable.
- No test was re-scoped. All 14 other `.format` tests pass untouched, which is
  the evidence that the change is narrow.

## Edge-case matrix (AGENTS.md §3.2)

| Row | Status | Where |
|---|---|---|
| empty | covered | `edge_format_of_an_empty_file_says_it_changed_nothing`; TAB in an empty directory (`edge_nothing_to_offer_is_no_candidates_rather_than_a_failure`) |
| singleton | covered | one line in, one block out (`an_exchange_keeps_its_input_apart_from_its_output`); one file in a directory (`edge_a_name_typed_whole_is_offered_past_the_cap`) |
| boundary | covered | `edge_a_name_typed_whole_is_offered_past_the_cap` — a fragment at the edge of `MAX_PATH_CANDIDATES`; `edge_output_fencing_a_line_that_closes_the_fence_holds` |
| out_of_bounds | covered | a cursor inside a character (`edge_a_cursor_inside_a_character_is_refused_rather_than_sliced`); `pos` past the line end returns `None`, not a panic |
| type_mismatch | covered | `edge_output_that_prints_an_input_fence_is_not_read_back_as_one` and `edge_a_redblue_fence_inside_a_block_in_another_language_is_not_input` — a fence carrying `text` where a `redblue` one is expected is read as output, not as a line the session ran |
| numeric_boundary | N/A | nothing in this phase does arithmetic; `.export` and TAB completion move strings and paths, and the one numeric boundary in scope (`MAX_PATH_CANDIDATES`) is an exact count, asserted as one |
| unicode | covered | `edge_a_session_of_unicode_exports_and_reads_back_unchanged` (emoji, combining mark, RTL, CJK), the `é` boundary in the cursor test, and `edge_tab_offers_a_spaced_filename_quoted_and_never_split` |
| nesting_recursion | N/A | a document is a flat list of fences; there is no nesting to recurse through and no recursion in the reader |
| duplicate_missing_keys | N/A | a session has no keys — it has exchanges in order, and `read_markdown` returns them in that order |
| malformed_input | covered | `edge_a_redblue_fence_inside_a_block_in_another_language_is_not_input`, `edge_an_unclosed_fence_at_the_end_of_a_document_reads_as_nothing`, `a_document_written_by_hand_is_read_the_same_way`, `edge_backticks_joined_by_an_escape_are_measured_after_the_escape_is_off` |
| resource_limit | covered | `edge_a_long_session_keeps_the_newest_exchanges_and_no_more` (`LIMIT`), `edge_a_long_listing_is_capped_and_the_order_does_not_depend_on_the_disk` (`MAX_PATH_CANDIDATES`), `edge_format_of_a_file_whose_temporary_name_is_taken_leaves_it_alone` (the temporary the write needs is already in use) |

## Known gaps / follow-ups

- `rbops/verify.sh` cannot run here (F1) — the fourth gate is unverified, not
  passed.
- `.format` still replaces a **symlink** with a regular file: the rename goes
  over the link itself, not its target. Pre-existing, not this run's, and now
  recorded as F11.
- A read-only file is still formatted rather than refused — a deliberate
  decision, argued in the test it is pinned by, recorded as F12.
- The TAB completion is read from the process's working directory
  (`completer::current_dir`), so a session cannot complete against another
  directory; F2 covers the related blind-typing case and is still open.
- `.export` fences output only when it could be misread. A document containing
  an output line of `` ``` `` with no language still relies on the reader
  treating a bare run as opening nothing, which is Markdown's reading and is
  pinned by `edge_a_line_that_prints_a_fence_is_written_inside_a_longer_one`.
- Nothing reads an exported document back (F10): `Transcript::read_markdown` has
  no caller under `src/`, so the round trip is asserted rather than observed.