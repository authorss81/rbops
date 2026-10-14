# FINDINGS — phase-078

Work that is real, evidenced, and **not** this phase's job (AGENTS.md §1.7). Each
item is anchored to a line I read.

---

## 1. `src/repl/history.rs` leaks a directory mode and fails six unrelated tests

**Severity:** major, pre-existing, reproduces on any `cargo test --lib` run that
executes the permission test first.

`src/repl/history.rs:348` (`edge_a_history_file_that_stops_being_readable_is_not_a_successful_load`)
`chmod`s the shared scratch directory to simulate an unreadable file and never
restores the mode. The directory is `scratch_dir()` at `src/repl/history.rs:134`,
i.e. `target/tmp/repl-history` — shared by every test in the module.

Observed:

```
$ ls -lad target/tmp/repl-history
drw------- 2 runner runner 4096 target/tmp/repl-history

$ cargo test --lib
---- repl::history::tests::save_to_file_and_load_from_file_round_trip stdout ----
panicked at src/repl/history.rs:251:14:
history should be writable to the scratch path: Os { code: 13, kind: PermissionDenied, message: "Permission denied" }
...
test result: FAILED. 154 passed; 6 failed
```

Six tests fail, all of them innocent: the five that merely *write* a history file
plus `edge_a_file_whose_own_name_is_not_utf8_can_be_saved_and_loaded`. `chmod 755`
on the directory makes all six pass again (verified: `160 passed; 0 failed`).

**Why it is not this phase:** it is in `src/`, phase-078 declares `must_touch:
["tests/"]`, and it has nothing to do with checkpoint ancestry. Fixing it here would
put an unrelated `src/` change in a test-only phase, which is the diff-smuggling the
reviewer is told to reject.

**Suggested fix:** give each test its own directory (`scratch_dir().join(name)`)
rather than sharing one, so a `chmod` in one test cannot affect another. A restore
guard is the weaker version and still leaves a window where a concurrently-running
test sees the wrong mode.

**Not caused by phase-078.** Confirmed by construction: the phase adds two new
files under `tests/` and changes no tracked file that `cargo test --lib` compiles.

---

## 2. CI checks out shallow, so a history audit cannot pass there

**Severity:** blocker for any future git-history gate, including this phase's.
**Status:** the `.github/` half is still open and needs a human; the target itself
is now green on a depth-1 checkout.

`.github/workflows/ci.yml:19`, `:95` and `:153` are bare `uses: actions/checkout@v4`
with no `with: fetch-depth:`. The default is `1`, so every CI job holds a depth-1
clone whose `git log main` is one commit long.

This pipeline's own checkout reproduced it exactly: on arrival,
`git rev-parse --is-shallow-repository` was `true` with 50 commits, and
`git log --oneline main | grep checkpoint` printed **zero** lines while
`git cat-file -t 7fdea15` happily reported `commit`. The objects were reachable only
from the `origin/rbops-recovery/*` and `origin/rbops-wip/*` refs. Any audit that
trusts a short log reports a false pass.

**Why the phase did not make this edit:** it was made, and `rbops/verify.sh:176`
rejected it — `.github/workflows/*` is a forbidden path, and AGENTS.md §1.1 forbids
touching it at all:

```
== diff hygiene
  FAIL forbidden path touched: .github/workflows/ci.yml
```

**What the phase did instead:** `tests/checkpoint_ancestry_test.rs` completes a
shallow clone (`ensure_full_history` → `git fetch --unshallow`) before it measures
anything, then reads the depth **again** and refuses if the history is still short.
That is not the tolerance the finding warned against: a repair that fails is a
loud refusal, never a pass. Verified against three real clones — a depth-1 push
clone, a depth-1 pull-request merge-ref clone with no local `main`, and a depth-1
clone with no remote. The first two are green (24 tests each); the third is red
with `history is shallow and it could not be completed`.

**Suggested fix (unchanged, and still the better one):** `with: { fetch-depth: 0 }`
on the three checkout steps. It is cheaper than a fetch per test run and keeps the
network out of the test suite. Note that this must not be "solved" in the audit
instead — a test that *tolerates* a shallow history is the exact defect this phase
was created to detect, and the audit deliberately does not do that.

**Also worth fixing while you are in there:** a pull-request checkout is a
detached merge ref with **no local `main`**, so `git log main` there is
`fatal: ambiguous argument`. `resolve_main` in the audit reads `origin/main` when
there is no local `main`; the workflow could avoid the situation entirely with
`ref: ${{ github.event.repository.default_branch }}` or a local-branch fetch.

---

## 3. `rbops/dispatch.sh:442-447` says six; the history says six; the phase brief said four

Not a code defect. Recorded because two phases in a row have now measured this from
a log truncated at different depths and got different answers, and the truncated
one was lower.

`git log --oneline main | grep checkpoint` prints **6** lines on a full clone:
`7fdea15`, `074c95e` (phase-019), `563a351` (phase-018), `286fccd` (phase-016),
`32d52ad`, `97b4043` (phase-004). The last two are below the depth the finding's own
`git log` could reach, which is why it counted four. The wip-merge count is likewise
6, not 4.

The lesson generalises to the auditor: **measure the count on a full clone and
record the clone depth next to the number**, or the next phase inherits the same
undercount. `tests/checkpoint_ancestry_test.rs` now refuses shallow history rather
than reporting a number off a truncated log.
