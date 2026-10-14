# phase-079 — closed by hand

**The finding does not reproduce on `main`. No code change was warranted, and the
agent was right to make none.**

This phase was written against a snapshot of `main` in which phase-041's work was
uncommitted. That snapshot is gone. Verified on `main`:

| The finding claimed | `main` actually does |
|---|---|
| `git status --porcelain` shows ` M src/parser.rs`, `A tests/text_split_join_test.rs`, `A phases/phase-041/*` | prints **nothing**, not even untracked |
| the work is unlanded, land it or take back `.done` | `034c5f0 rbops: phase-041` exists on `main`, single-parent on `31622c9` (phase-040) |

The finding's own numbers match that commit exactly: "1800 insertions and 17
deletions, of which `tests/text_split_join_test.rs` is 1235 lines". The phase
described the commit's contents while it was still unlanded; the commit then
landed.

**`.done` never existed**, so "take back the `.done`" was never applicable:

```
$ git log --oneline --all -- phases/phase-041/.done
                                    <- never committed, no history at all
```

## The one criterion that is stale, and who owns it now

The DoD asserted `git log --oneline main | grep -c checkpoint` is "still 4".
It is **1**. That number predates phase-078, and it is a snapshot, not an
invariant.

Phase-078 took this exact question as its subject and answered it properly: six
`rbops: phase-NNN checkpoint` commits *are* ancestors of `main`
(`7fdea15, 074c95e, 563a351, 286fccd, 32d52ad, 97b4043`), each introduced by a
real merge. 078 moved the concern out of a comment and into parsed data —
`tests/checkpoint_ancestry_ack.txt`, enforced by
`tests/checkpoint_ancestry_test.rs` (24 tests, verified passing).

So phase-079 should not assert the stale count, and **phase-078 is what now owns
this concern**. This phase's remaining job was already done by a later one.

## The edge cases it names are already asserted

All three are in the committed file, each to a named value rather than a smoke
test:

- `split` on empty text — `SPLIT_CASES[0]`, plus
  `edge_empty_subject_splits_to_one_empty_part` (`tests/text_split_join_test.rs:783`)
- `split` with an absent separator — `SPLIT_CASES[2]` is `{subject: "abc",
  separator: ",", answer: ["abc"]}`
- `join` on an empty list — `edge_empty_list_joins_to_empty_text` (`:798`)

Eight `edge_*` tests are present in total, covering unicode, nesting, wrong types
on both engines, an empty separator, and a record where a list is wanted.

## Why this was deferred before closing

It deferred 3 times (`.deferred_attempts=3`) because a phase that correctly
changes nothing has **no diff**, and the gate correctly refuses an empty diff.
That is the gate working, not the gate being wrong — and it is the same situation
as phase-051, which was closed by hand for the same reason.

## Verified before closing

- `cargo test --test text_split_join_test` → 20 passed, 0 failed, 0 ignored
- `git status --porcelain` empty, `--untracked-files=all` included
- `git rev-list --parents -n 1 034c5f0` → one parent, `31622c9` (phase-040)

Nothing to implement. Closed by hand on the evidence in `FINDINGS.md`.