# phase-093 — closed by hand, PARTIAL

Applied manually in `authorss81/redblue`: the `target/` cache landed in `d1380a4`.

**Why by hand.** Same as 092 — `.github/workflows/` is unreachable to the bot.

## Partial, deliberately

**Done:** `actions/cache` on every job, keyed on the Cargo.lock hash. Not
separately measured — caching was folded into the same commit as the sharding, and
the sharding's own effect was 17 seconds, so any caching number taken from that
run would be invented.

**NOT done:** the trigger split. The phase asked for the corpus to run only on
`pull_request` and on push to `main`, not on every branch push. Both triggers still
run everything.

What *is* true is weaker and still valuable: the `fast` job runs build, clippy,
unit tests, README blocks and the corpus-count pin without waiting for the
shards, so a fmt/lint/type error surfaces while the slow tier is still going. That
came out of the matrix, not out of this phase's design.

**Left open rather than half-built,** because it needs a decision and not an
implementation: does a push to a branch that already has an open PR also run the
corpus? It currently does, via the `pull_request` trigger, so a trigger matrix
that keeps both would double the cost on every branch push.

## Standing gaps

- `cargo fmt --check` is **absent from CI** — the tree is not fmt-clean, so adding
  it turns every build permanently red. Worth its own phase.
- The `result` gate has only ever run with every job green; the branch that
  actually fails the workflow has never executed.

See `authorss81/redblue` `phases/phase-093/REPORT.md`.