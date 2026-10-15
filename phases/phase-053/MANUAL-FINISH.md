# phase-053 — closed by hand

**Implemented and landed in `authorss81/redblue` as `25630a8`.** Verified on
pushed `main`, not on a local tree: `cargo test --test repl_color_test` →
**15 passed, 0 failed**, and `repl_test` → **34 passed, 0 failed** unmodified.

## Why this was done by hand

Phase-053 gated **nineteen phases** — 054 through 072, the entire REPL chain,
about a third of the remaining backlog. It was the single point of failure for
that track and had been stuck for roughly fourteen hours.

Three attempts produced nothing:

1. Attempt 1 spent its whole 90-minute budget **reading** `src/repl/` and was
   killed at clippy. `work-phase-053.patch` was **0 bytes** and its checkpoint
   log was **0 bytes** — the work was never preserved because it was never
   written. It ran `cargo fmt --all` against a tree that is already fmt-clean,
   so it produced a net-zero reformat of phase-052's files.
2. Attempts 2 and 3 hit a dead model chain and deferred without dispatching.

There was no work to recover, so the only options were wait or write it. Waiting
meant nineteen phases stayed blocked behind an upstream availability problem that
no repository change can fix.

## What landed

- `src/repl/style.rs` — `Paint` roles, TTY detection, `REDBLUE_COLOR` override,
  `NO_COLOR`, one theme
- `src/repl/banner.rs` — a **static** wordmark, red half and blue half
- `src/repl/mod.rs` — wired in, seven output sites painted
- `tests/repl_color_test.rs` — 15 tests, five of them `edge_*`
- `README.md` — the PATH note

The governing guarantee: **with colour off, output is byte-identical** to what it
was before. Not visually the same — the same bytes, because `paint()` returns its
input verbatim rather than a decorated copy.

The wordmark is static on purpose. An animated banner redraws over time, and
byte-identical plain output, balanced escapes, and "nothing written between
prompts" all become untestable the moment frames appear.

## Three defects the tests caught during the work

1. **`BrandBlue` was byte-identical to `Prompt`** (both `1;34`). Fixed the
   palette to `1;36` rather than relaxing the assertion — a brand colour matching
   the prompt makes the wordmark look like something to type.
2. **Detection was cached in a `OnceLock`**, which made it untestable: the first
   call anywhere in the process fixed the answer forever, so `REDBLUE_COLOR` set
   by a later test had no effect. Removed; it bought nothing, since
   `is_terminal()` is far cheaper than the `println!` it feeds.
3. **The banner emitted a bare reset sequence** for its empty red half. Now
   guarded by an `is_empty` check so a missing half paints nothing.

## Gate status at close

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --all-targets -- -D warnings` | pass |
| targeted tests (repl_color, repl, discovery) | 15 + 34 + 13, 0 failed |
| full `cargo test` | not run by hand; CI is the authority |

The known pre-existing failure
`runtime::tests::edge_a_clock_before_the_epoch_is_a_runtime_error` fails
identically on clean `main` and is unrelated — confirmed by stashing this work
and re-running against unmodified `main`.

## What this unblocks

`phase-054` through `phase-072` — the REPL chain. They should now become
selectable in manifest order.