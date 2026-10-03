# RBOPS — Redblue Autonomous Ops

A self-dispatching, self-auditing development pipeline for the
[Redblue](https://github.com/authorss81/redblue) programming language.

It runs on GitHub Actions with no human in the loop. It picks the next phase,
implements it, **proves** it with a gate that can fail, has an adversarial
reviewer sign off, and periodically audits itself to write new phases. The
endgame is Redblue compiling Redblue.

---

## Why this exists and what it fixes

This borrows its *shape* from
[llops-android](https://github.com/authorss81/llops-android) (agent per phase,
marker-file state, self-retrigger chain) and fixes its seven load-bearing
weaknesses:

| # | llops-android | RBOPS |
|---|---|---|
| 1 | Phases discovered by `grep -E '^workspace/phase-[0-9]+/'` over the git tree; no deps, no DAG | `rbops/phases.json` — validated, diffable, ordered, dependency-aware |
| 2 | "Definition of done" is a line of prompt text the agent self-reports | `rbops/verify.sh` runs the gates; its exit code decides `.done` |
| 3 | Evidence gate only proves *some* file changed | Gate requires a populated report, a minimum diff, and **zero** gate-weakening constructs |
| 4 | Bot pushes straight to `main`, no PRs, 20-model free-tier chain | Per-phase commits, push-rebase-retry, recovery branch + patch artifact, 4-model ranked chain |
| 5 | Cron removed at HEAD; `llops-tick.yml` has `contents: read` but POSTs `repository_dispatch` → 403 | Cron present, `contents: write`, and a real in-flight check |
| 6 | Tests are whatever the phase felt like writing | Mandatory edge-case matrix + hard test quota, machine-enforced |
| 7 | No self-improvement loop; audits are a human writing prompt files by hand | Auditor agent measures, diffs against SPEC/ROADMAP, and appends new phases |

---

## Layout

```
rbops/
├── AGENTS.md                 the contract injected into every phase
├── opencode.json             models + reviewer / auditor / verifier agents
├── rbops/
│   ├── phases.json           ← single source of truth. deps, severity, gate,
│   │                           test policy, models, budgets, all 23 phases
│   ├── dispatch.sh           the self-dispatcher state machine
│   ├── verify.sh             the gate. the only authority on real work
│   └── gen-prompts.sh        materialises PROMPT.md from phases.json
├── phases/phase-NNN/
│   ├── PROMPT.md             generated from the manifest
│   └── REPORT.md             written by the implementer, checked by the gate
├── .github/workflows/
│   ├── rbops.yml             select → work → retrigger
│   └── rbops-tick.yml        cron safety net
└── docs/audits/              audit reports, one per pass
```

## State

State is **git**, in marker files committed under `phases/phase-NNN/`:

| Marker | Meaning |
|---|---|
| `.done` | gate green **and** reviewer signed off |
| `.failed` | gate red; attempts counted in `.attempts` |
| `.deferred` | infra failure (rate limit, model outage); retry next tick |
| `.blocked` | max attempts, or a blocking review finding survived N rounds |
| `.checkpoint` | partial work resumed — do not restart |
| `phases/.stop` | global halt. `dispatch.sh stop` / `resume` |

## Running it locally

```bash
./rbops/dispatch.sh status      # table of every phase and its state
./rbops/dispatch.sh select      # which phase would run next
./rbops/dispatch.sh run phase-001
./rbops/dispatch.sh review phase-001
./rbops/dispatch.sh audit
./rbops/verify.sh phase-001     # just the gate
./rbops/gen-prompts.sh          # regenerate PROMPT.md from phases.json
./rbops/gen-prompts.sh --check  # CI: fail if any PROMPT.md is stale
```

## Enabling

```bash
# 1. the API key for the models. This is the only secret the pipeline needs
#    to THINK.
gh secret set OPENCODE_API_KEY --repo authorss81/rbops

# 2. push access to redblue, so finished work can SHIP. GITHUB_TOKEN cannot do
#    this: it is scoped to rbops no matter what `permissions:` says. Instead a
#    WRITE SSH deploy key is registered on redblue and its private half is
#    stored as REDBLUE_DEPLOY_KEY on rbops. Fully scripted, no UI, least
#    privilege (that key opens exactly one repo):
#
#      powershell -File rbops/setup-deploy-key.ps1
#
#    Re-running rotates the key. Without either credential the pipeline still
#    runs, but work lands as a work-<phase>.patch artifact instead of a commit.

# 3. check the pipeline can prove itself before spending model tokens
gh workflow run validate.yml
gh workflow run smoke.yml

# 3. see what would run next, without running it
./rbops/dispatch.sh status
./rbops/dispatch.sh select

# 4. go
gh workflow run rbops.yml -f action=tick
```

Halt and resume:

```bash
./rbops/dispatch.sh stop     # touch phases/.stop; every tick becomes a no-op
./rbops/dispatch.sh resume
```

### If the key is missing or wrong

`dispatch.sh` preflights before invoking the agent. A missing CLI, an empty
`OPENCODE_API_KEY`, or a failed `opencode` auth probe marks the phase
`.blocked` and exits 3 immediately. It does **not** consume a phase attempt, so
setting the key and running `resume` picks up exactly where it stopped. It never
reports a key problem as a phase failure or a model outage.

The bot token is deliberately **not** granted the `workflows` scope, so a push
that touches `.github/` is rejected by GitHub itself. That is the outer lock;
`verify.sh` is the inner one. Two independent locks, because a gate that the
implementer can edit is not a gate.

## Cost control

| Knob | Env var | Default |
|---|---|---|
| Attempts per phase | `RBOPS_MAX_ATTEMPTS` | 3 |
| Infra deferrals before blocking | `RBOPS_MAX_DEFERRALS` | 5 |
| Review rounds before blocking | `RBOPS_MAX_REVIEW_ROUNDS` | 3 |
| Per-model wall clock | `RBOPS_MODEL_TIMEOUT` | 3000 s |
| Minimum agent output to trust a model | `RBOPS_MIN_OUTPUT` | 500 bytes |
| Chain to next tick | `RBOPS_RETRIGGER` | 1 |
| Audit every N completed phases | `.audit.every_n_phases` | 8 |

`./rbops/dispatch.sh stop` is the kill switch. It is a committed file, so the
halt survives a runner being replaced.

### Models

Order is deliberate: `opencode/space-bunny-free` leads, then
`muse-spark-1.3-contributor-free`. The strongest coder on the free tier goes
first because a dead model advances the chain **without consuming a phase
attempt**, so an unavailable or revoked entry costs about two seconds rather
than a retry from `MAX_ATTEMPTS`. That makes a long chain cheap insurance
rather than a liability.

To see what your key can actually reach:

```bash
OPENCODE_API_KEY=... opencode models
```

If `space-bunny-free` is not listed for your key it will simply be skipped and
the chain moves to muse-spark. To change the order, edit `RBOPS_IMPL_MODELS`
(and the reviewer/audit chains) in `.github/workflows/rbops.yml`, plus
`.models` in `rbops/phases.json` and the agent models in `opencode.json`.

To add `openrouter/*` models (a different provider, different benchmarks):

```bash
gh secret set OPENROUTER_API_KEY --repo authorss81/rbops
```

Free-tier models disappear without warning. When a phase starts deferring
repeatedly with `every model in the chain was unusable`, that is the signal to
re-list and re-order.

### Pushing while a run is in flight

**Don't, unless you mean to.** The `work` job ends by rebasing onto `origin/main`
before pushing its state, so a commit arriving mid-run can collide with that
rebase. It retries five times and then falls back to a recovery branch, which
loses the marker state.

The phase's *code* lands in redblue and is not at risk from an rbops push. To
iterate on the pipeline itself while a phase is running:

```bash
./rbops/dispatch.sh stop      # committed halt; select becomes a no-op
# ... push freely, the queue will not move ...
./rbops/dispatch.sh resume
```

`phases/.stop` survives a runner being replaced, which is why it is a committed
file rather than a runner-local flag.

## The gate

`rbops/verify.sh` fails a phase for any of:

- the phase is not declared in `phases.json`, or a dependency is not `.done`
- `REPORT.md` is missing, stubbed, or its claimed test count is more than ±2 off
  the actual run
- a forbidden path was touched (`.github/workflows/`, `rbops/`, `.opencode/agent/`)
- a gate-weakening construct was **added**: `#[ignore]`, `// skip`, `allow(clippy::…)`
- the diff adds fewer than 5 lines
- `cargo fmt --check` fails
- `cargo clippy -- -D warnings` emits any warning
- `cargo test` fails **or reports zero passing tests**
- any file in `examples/` or `modules/` stops running
- fewer than 6 new Rust tests / 4 new Redblue tests / 1 `edge_*` / 1 failure-asserting test
- any newly skipped or ignored test

## The bootstrap ladder

| Stage | Artifact | Done when |
|---|---|---|
| S0 | Rust `rb` | gates green, all examples run |
| S1 | bytecode compiler + `rb vm` | differential test: tree-walk ≡ bytecode on a ≥200-program corpus |
| S2 | the compiler rewritten **in Redblue** | byte-identical `.rbc` output vs. S1, no Rust fast path |
| S3 | self-compilation | `stage1.rbc == stage2.rbc`, three runs identical |
| S4 | self-hosted release | the shipped `rb` is built by `rb` and passes the full gate |

S1–S4 are phases 018–023 and are gated by the fixed-point test, not by "it
compiled".

## Licence

MIT. See [LICENSE](LICENSE).