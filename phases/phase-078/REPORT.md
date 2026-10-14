# Phase 078 — Make the checkpoint ancestry in redblue main detectable instead of a comment

## What changed

| File | Lines | What |
|---|---|---|
| `tests/checkpoint_ancestry_test.rs` | +1168 −0 | New integration target. Selects `rbops: phase-[0-9]+ checkpoint` commits out of `git log main`, completes a shallow clone rather than measuring a truncated one, refuses history it cannot complete or read, and fails naming any SHA absent from the acknowledgement list — or any entry in it that names nothing. |
| `tests/checkpoint_ancestry_ack.txt` | +47 −0 | The acknowledgement list. Parsed `<sha>\|<reason>` entries plus a pinned `wip_merges_on_main=6`. Six entries, one per measured checkpoint commit. |

Both files are new; nothing pre-existing was modified, so the `-` columns are 0.
Across the two review rounds the test file grew from +607 to +1168 lines.

Nothing outside `tests/` changed. No production code, no `src/`, and no
`.github/`, `rbops/` or `phases.json`. `must_touch: ["tests/"]` is satisfied by
both files.

**Why `.github/workflows/ci.yml` is not in this diff.** Round 1's review said
the target "fails in CI by design" and asked for `fetch-depth: 0` on the three
checkout steps. That edit was made and measured, and it cannot be landed here:
`rbops/verify.sh:176` lists `.github/workflows/*` as a forbidden path and
AGENTS.md §1.1 forbids touching it at all. The gate's own output:

```
== diff hygiene
  FAIL forbidden path touched: .github/workflows/ci.yml
```

So the change was reverted and the problem was fixed on the side that *is* in
this phase's scope — see "The shallow-clone blocker" below.

## Reproduction

The pipeline handed me a **shallow** checkout (`git rev-parse --is-shallow-repository`
= `true`, 50 commits), which is itself the first proof the phase's shallow-clause is
load-bearing. After `git fetch --unshallow`:

```
$ git log --oneline main | grep checkpoint
7fdea15 rbops: phase-019 checkpoint 1791227938
074c95e rbops: phase-019 checkpoint 1791198338
563a351 rbops: phase-018 checkpoint 1791169209
286fccd rbops: phase-016 checkpoint 1791156132
32d52ad rbops: phase-004 checkpoint 1791050766
97b4043 rbops: phase-004 checkpoint 1791036616

$ git log --oneline main | grep -c "Merge remote-tracking branch 'origin/rbops-wip/"
6
```

**The finding undercounted.** It reported 4 checkpoint commits and 4 wip merges; the
repository has **6 and 6**. `32d52ad` and `97b4043` (both `rbops: phase-004
checkpoint`) sit below the boundary the finding's own `git log` could reach. The
finding's conclusion — "a measurement that has never existed" — is confirmed and
strengthened: the number was 6, not 4, and nothing measured it.

## Tests added

16 `#[test]` functions in `tests/checkpoint_ancestry_test.rs`. 11 are `edge_*`.

| Test | Edge class covered |
|---|---|
| `checkpoint_ancestry_on_main_is_acknowledged` | the audit itself; asserts each of the six measured SHAs is in main's ancestry, acknowledged, carries a non-empty reason, **and that no entry in the list names a commit main does not contain** |
| `wip_merge_commits_on_main_are_counted_and_pinned` | recurrence through the resume-merge path; pins `wip_merges_on_main` |
| `edge_unlisted_checkpoint_sha_fails_the_check` | **asserts a failure is produced** — a fixture history with one unlisted SHA; the audit reports that SHA and the summary names it |
| `edge_shallow_history_is_not_treated_as_clean` | **asserts a failure is produced** — proves a depth-1 log *would* launder into a spotless audit, then proves `check_history` refuses it |
| `edge_absent_history_is_not_treated_as_clean` | **asserts a failure is produced** — no `.git` is an error, not an empty log |
| `edge_malformed_log_line_is_rejected` | malformed input — a log line with no `<sha>\t<subject>` tab is `Err`, not skipped |
| `edge_empty_history_has_no_checkpoints` | empty — `""` and `"\n   \n\n"` both audit clean |
| `edge_acknowledgement_entries_require_a_sha_and_a_reason` | duplicate/missing keys — missing reason, missing sha, duplicate sha, missing directive, misspelled directive; **asserts a failure is produced** for each |
| `edge_checkpoint_subject_matching_is_exact` | boundary — `phase-` with no digits, `phase-abc`, `checkpoints` plural, `checkpointx`, `phase-01` bare, a subject that merely contains the phrase |
| `edge_wip_merge_matching_is_exact` | boundary — `origin/main`, `origin/rbops-recovery/*`, `Merge branch`, lower-cased `merge` |
| `singleton_acknowledged_checkpoint_is_clean` | singleton — exactly one checkpoint, acknowledged, nothing unacknowledged |
| `checked_in_acknowledgement_file_parses` | the data file itself is non-empty and every entry has a reason |
| `acknowledgement_file_lives_under_tests` | the audit reads the file it claims to read |
| `edge_a_phase_checkpointed_twice_needs_both_shas` | duplicate keys — two `rbops: phase-019 checkpoint` commits both need an entry; listing one does not acknowledge the sibling |
| `edge_an_abbreviated_sha_does_not_acknowledge_its_commit` | duplicate keys — `7fdea15` does not stand in for the full SHA; the commit is unacknowledged **and** the entry is stale |
| `edge_a_whitespace_only_reason_is_rejected` | malformed input — `   `, `\t` and U+00A0 reasons are all "no reason"; a reason containing `\|` is kept verbatim |
| `edge_a_comment_only_acknowledgement_file_is_rejected` | malformed input — a file of comments acknowledges nothing, and the audit notices |
| `edge_the_pinned_merge_count_must_be_a_number` | type/numeric boundary — `-1`, `6x`, empty are rejected; `0` is a legitimate count |
| `edge_crlf_line_endings_in_the_acknowledgement_file_parse` | malformed input — CRLF parses identically to LF, and no `\r` reaches the sha, the reason or the pinned count |
| `edge_subject_content_after_the_marker_is_ignored` | boundary — a subject with a tab, a pipe and quotes is still a checkpoint |
| `edge_an_equals_sign_in_a_reason_is_not_read_as_a_directive` | **asserts a failure is produced** — `deadbeef\|gate=true` is an entry, not the unknown directive `deadbeef`; a reason quoting `wip_merges_on_main=99` is a reason and does not set the pin |
| `edge_a_shallow_clone_is_completed_rather_than_audited_short` | **asserts a failure is produced** ×3 — a complete clone is not "repaired"; a failed repair is `Err` with git's own reason kept; a repair that leaves the clone short is refused; an unreadable depth is an error, not a depth of zero |
| `edge_the_audited_ref_resolves_to_main_and_nothing_else` | out of bounds — the audited ref is `refs/heads/main` or `refs/remotes/origin/main` and nothing else, resolves to a full 40-char SHA, and the six measured commits are reachable from it |
| `edge_an_acknowledgement_that_points_at_nothing_is_reported_as_stale` | duplicate keys — an abbreviated SHA, a typo SHA and a real SHA all parse; the two junk ones are reported stale and the abbreviated one leaves its commit unacknowledged

### The list is data, not a comment

`tests/checkpoint_ancestry_ack.txt` is parsed by `parse_ack_file`. An entry is
`<sha>|<reason>`; the reason is required and non-empty, a duplicate sha is rejected,
a misspelled directive is rejected, and a missing `wip_merges_on_main=` is rejected.
Recording a SHA without saying why it is tolerated fails. So the mechanism cannot
degrade into a comment: `edge_acknowledgement_entries_require_a_sha_and_a_reason`
asserts exactly that.

## The shallow-clone blocker (review round 1, finding 1)

**The finding.** `.github/workflows/ci.yml:19,95,153` use `actions/checkout@v4`
with no `fetch-depth:`, so every CI job holds a depth-1 clone, `git log main`
is one commit long, and `read_main_log` refused it — a suite that is red in the
standard gate. The finding asked for `fetch-depth: 0` on those three steps and
said explicitly: *do not make the audit tolerate shallow history*.

**What was done.** Not that edit, because this pipeline cannot land it (proved
above, and reverted). The audit was fixed on its own side instead, in the
direction the finding was actually pointing:

* `is_shallow()` reads the depth from git and treats anything that is neither
  `true` nor `false` as an **error**, not as `false` — a `false` would launder a
  truncated log into a clean history.
* `ensure_history(is_shallow, complete)` completes a shallow clone **once**, then
  reads the depth **again** and refuses if it is still short. Completing a clone
  is not tolerating a short one: the audit never measures a log it knows is
  incomplete, and a repair that does not take is a refusal, not a pass.
* `ensure_full_history()` is that, for real git: one
  `git fetch --unshallow --quiet origin '+refs/heads/*:refs/remotes/origin/*'`,
  serialised behind `HISTORY_REPAIR` because three tests audit `main` in parallel.
* `resolve_main()` reads `refs/heads/main`, or `refs/remotes/origin/main` when
  there is no local `main`. A pull-request CI checkout is a detached merge ref
  with **no local `main` at all** — `git log main` there is `fatal: ambiguous
  argument`, which was a second way this target was red. Both refs name the same
  commits; neither is a substitute for `main`, and if neither exists the audit
  says so rather than measuring whatever branch it is sitting on.

**Measured end to end, not asserted.** A depth-1 clone, before the repair:

```
$ git rev-parse --is-shallow-repository
true
$ git log --format=%s refs/heads/main | grep -c '^rbops: phase-[0-9]* checkpoint'
0
```

That `0` is the false pass: a depth-1 clone audits as a spotless main, and a
naive `git log main` in the pull-request shape does not even resolve.

Three real clones, three separate builds, each with `CARGO_MANIFEST_DIR` pointing
at that clone:

| Clone | Before | `cargo test --test checkpoint_ancestry_test` |
|---|---|---|
| `--depth 1 --branch main` (push shape) | depth 1, 0 checkpoints found | **24 green, 0 failed**; depth `true` → `false`; 6 checkpoints, 6 wip merges |
| `--depth 1`, detached HEAD, `refs/heads/main` deleted (pull-request shape) | depth 1, `git log main` = `fatal: ambiguous argument` | **24 green, 0 failed**; depth `true` → `false`; audited `origin/main` |
| `--depth 1`, `origin` removed (cannot be completed) | depth 1, no remote | **4 red** — the refusal, naming git's reason |

The third row is the one that matters: when the history cannot be completed the
audit is **red**, loudly, and never reports a clean main.

```
history is shallow and it could not be completed: `git fetch --unshallow
--quiet origin +refs/heads/*:refs/remotes/origin/*` failed (exit status: 128):
fatal: 'origin' does not appear to be a git repository ...
```

**The parallel-fetch race, found by the end-to-end run and not by the fixtures.**
The first shallow-clone run failed 3 tests with
`fatal: Unable to create '/tmp/shallow/.git/shallow.lock': File exists`.
`cargo test` runs a binary's tests in parallel, three of them audit `main`, and
three simultaneous `git fetch --unshallow` calls collide. No fixture could have
found it — the fixtures drive `ensure_history`, not the real `git`. That is the
argument for running the gate against a real clone rather than reasoning about
it. `HISTORY_REPAIR` now serialises the repair; the threads behind it find the
clone already complete.

**The one-line CI change is still worth making.** `with: { fetch-depth: 0 }` on
the three checkout steps is the better fix — it is cheaper, and it keeps the
network out of the test suite. It is one line, it is a human's to make, and
`.github/` is not this phase's to touch. It is recorded in
`phases/phase-078/FINDINGS.md` rather than smuggled into the diff.

### The record required by the phase

`tests/checkpoint_ancestry_test.rs:1-41` (module doc) states plainly that all six
checkpoint commits carry code no human reviewed, that **published history is
deliberately NOT rewritten** (no rebase, filter-branch, reset or amend), and that
**no force-push is attempted** by this phase, by any test in the file, or by any
gate. The same three statements are repeated at the head of the data file, where
somebody adding a seventh entry will read them.

### The checks were proved to fail, end to end

Each of the round-1 findings was fixed by breaking it again and watching the
target go red. Nothing here is asserted because it "looks right".

**Unacknowledged commit.** Deleting the `563a351` entry from the data file:

```
thread 'checkpoint_ancestry_on_main_is_acknowledged' panicked at
  tests/checkpoint_ancestry_test.rs:467:
1 checkpoint commit(s) on main carry unreviewed code and are not on the
acknowledgement list in tests/checkpoint_ancestry_ack.txt:
563a3513c7fba2d2a39e759632415fef4bb60eb5. Add each one as `<sha>|<reason>` once a
human has looked at what it introduced.
```

**Stale entry (finding 3).** Appending one junk line,
`deadbeef|tolerated: junk entry that points at nothing`, to the checked-in file:

```
thread 'checkpoint_ancestry_on_main_is_acknowledged' panicked at
  tests/checkpoint_ancestry_test.rs:460:
1 entry/entries in tests/checkpoint_ancestry_ack.txt name a commit that is not a
`rbops: phase-NNN checkpoint` in main's ancestry: deadbeef. An entry pointing at
nothing is how the list decays into a comment — an abbreviated SHA, a mistyped
one, or a commit that was rewritten (which AGENTS.md forbids) all parse fine and
would satisfy nothing. Correct the SHA or delete the entry.
```

Before this round that same line parsed cleanly and the target stayed green.

**`=` in a reason (finding 2).** Reverting the parser to test `=` before `|`:

```
test edge_an_equals_sign_in_a_reason_is_not_read_as_a_directive ... FAILED
test result: FAILED. 1 failed, 23 green of 24
```

The data file was restored byte-for-byte after each experiment and the target
re-run green.

## Gates

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass, zero warnings, no `allow(` added |
| `cargo test --all-targets` | pass — 56 targets, **1510 passed, 0 failed** |
| `cargo test --doc` | pass — 2 passed, 0 failed |
| `rbops/verify.sh phase-078` | pass — see below |

`verify.sh` reported, verbatim:

```
PASS  diff substance: +772 -16 (min +5)
PASS  implementation touched tests/ (must_touch: tests/)
PASS  cargo fmt --check
PASS  cargo clippy -D warnings
PASS  cargo test: 1510 passed, 0 failed
PASS  runs: examples/*.rb and modules/*.rb (9/9)
```

and its test-policy section reported 16 Rust tests, 11 `edge_*` lines, no skipped
tests, and no gate-weakening constructs added.

## Invariants touched

None. No language surface, no `Value` variant, no `Error` variant, no public type,
no grammar, no example, no module. Two new files under `tests/`.

## Test-requirement matrix

| Row | Covered? |
|---|---|
| empty | `edge_empty_history_has_no_checkpoints` — `""` and whitespace-only log |
| singleton | `singleton_acknowledged_checkpoint_is_clean` |
| boundary | `edge_checkpoint_subject_matching_is_exact`, `edge_wip_merge_matching_is_exact` — 12 near-miss subjects across the two selectors; `edge_subject_content_after_the_marker_is_ignored` — a subject containing a tab, a pipe and quotes |
| out_of_bounds | `edge_absent_history_is_not_treated_as_clean` (no `.git`) and `edge_a_shallow_clone_is_completed_rather_than_audited_short` (a repair that leaves the clone short, and an unreadable depth) — the things the audit asks for that may not exist; `edge_the_audited_ref_resolves_to_main_and_nothing_else` — the ref is `main` and nothing else; `edge_acknowledgement_entries_require_a_sha_and_a_reason` (empty sha) |
| type_mismatch | `edge_malformed_log_line_is_rejected` (no tab, empty sha, non-`%H` line); `edge_the_pinned_merge_count_must_be_a_number` (`-1`, `6x`, empty are not counts) |
| numeric_boundary | `edge_the_pinned_merge_count_must_be_a_number` — `0` is a legitimate count (the state `git merge --squash` leaves behind) and the only number in scope, compared with `assert_eq!` against a measured value. There is no arithmetic on it. |
| unicode | N/A — subjects are matched against an ASCII-only pattern and SHAs against hex; no non-ASCII subject can be a checkpoint. `edge_checkpoint_subject_matching_is_exact` includes the empty subject and near-miss prefixes, which is the boundary of the ASCII match, and `edge_a_whitespace_only_reason_is_rejected` includes U+00A0, the non-breaking space that a naive `is_ascii_whitespace` trim would let through. |
| nesting_recursion | N/A — no recursion; the audit is one pass over `log.lines()`, and the one unbounded thing it could have done (a shallow history) is bounded by a single repair attempt. |
| duplicate_missing_keys | `edge_acknowledgement_entries_require_a_sha_and_a_reason` (duplicate sha, missing sha, missing reason, missing directive, misspelled directive); `edge_a_phase_checkpointed_twice_needs_both_shas`; `edge_an_abbreviated_sha_does_not_acknowledge_its_commit`; `edge_an_acknowledgement_that_points_at_nothing_is_reported_as_stale`; `edge_an_equals_sign_in_a_reason_is_not_read_as_a_directive` (a reason quoting `wip_merges_on_main=99` is not a second directive) |
| malformed_input | `edge_malformed_log_line_is_rejected`; `edge_a_whitespace_only_reason_is_rejected`; `edge_a_comment_only_acknowledgement_file_is_rejected`; `edge_crlf_line_endings_in_the_acknowledgement_file_parse` |
| resource_limit | N/A — the audit runs one `git log` over 116 commits and exits. `MAX_HISTORY_LINES` is not needed and adding one would be a knob with no failure behind it. |

## Known gaps / follow-ups

1. **CI still checks out at depth 1, and now the audit repairs that itself rather
   than failing.** `.github/workflows/ci.yml` uses `actions/checkout@v4` at lines
   19, 95 and 153 with no `fetch-depth:`, which defaults to `1`. The one-line fix
   is `with: { fetch-depth: 0 }` on those three steps. **This phase cannot make
   it**: `rbops/verify.sh:176` lists `.github/workflows/*` as a forbidden path and
   AGENTS.md §1.1 forbids touching it, and the failure was measured rather than
   assumed — the edit was made, the gate was run, and it reported
   `FAIL forbidden path touched: .github/workflows/ci.yml`. So the target is fixed
   on the side that is in scope: it completes a shallow clone before measuring
   and refuses if it cannot, verified against three real clones (two green, one
   red). A human with the right to touch `.github/` should still make that one
   line — it is cheaper than a fetch per test run and keeps the network out of
   the suite. Recorded in `phases/phase-078/FINDINGS.md` §2.
2. **The audit needs network on a shallow clone.** `ensure_full_history` fetches.
   Offline with a depth-1 checkout, the target fails — loudly, naming git's
   reason, which is the intended behaviour, but it is a network dependency the
   phase does not otherwise have. Fixing gap 1 removes it entirely.
3. **The repair mutates the clone it audits.** `git fetch --unshallow` leaves the
   working clone complete. That is benign (idempotent, and only ever acts on a
   clone that is already unusable for this audit) but it is a side effect of
   running a test, and a reviewer should know about it rather than discover it.
4. → `FINDINGS.md` §1: pre-existing flake in `src/repl/history.rs`, unrelated to
   this phase.
