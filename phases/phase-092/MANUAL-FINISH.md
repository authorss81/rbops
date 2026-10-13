# phase-092 — closed by hand

Applied manually in `authorss81/redblue`: commits `d1380a4` (the sharding),
`589d8ca` (a fix to that commit), `4672f75` (the report).

**Why by hand.** This phase changes `.github/workflows/`, and the rbops bot token
deliberately has no `workflows` permission (`.github/workflows/rbops.yml:10`) so
that an agent cannot edit its own gate. An agent cannot land this phase, so it
is declared `manual: true` in the manifest rather than left to fail three times
and land in `.blocked`.

**Done.** 8 jobs instead of one serial job: `fast`, a 5-way `shard` matrix, a
dedicated `corpus` job, and a `result` gate. The partition was verified against
the real `tests/` tree before pushing — 53 targets, each in exactly one shard,
no duplicates, full coverage, and a hash rather than a round-robin so adding a
test changes only its own shard.

**Measured: 8m25s → 8m8s.** Seventeen seconds. This is *not* a speed win and the
phase's report says so. The suite was already bounded by the corpus differential
harness; sharding the other 50 targets recovered no slack. What was bought is
resilience — a slow or failing target no longer blocks the other 52, and a
failure names its shard. That removes a ceiling on suite size, which was this
phase's stated purpose.

CI run `38362122114`: 8/8 jobs green.

See `authorss81/redblue` `phases/phase-092/REPORT.md` for the full record.