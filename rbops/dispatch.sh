#!/usr/bin/env bash
# =============================================================================
# rbops/dispatch.sh — the self-dispatcher.
#
#   dispatch.sh select           pick the next eligible phase, print its id
#   dispatch.sh run <phase>      implement + gate + record state
#   dispatch.sh review <phase>   reviewer pass, then re-gate
#   dispatch.sh tick             select + run + review + retrigger
#   dispatch.sh audit            phase-generating audit loop
#
# Unlike the llops design it borrows its shape from, this NEVER greps the git
# tree for directories. Ordering, dependencies and severity come from
# rbops/phases.json, which is validated, diffable and reviewable.
# =============================================================================
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
# The pipeline repo (this one) holds phases/, the manifest and the log; the
# PROJECT is the thing being changed. They are different checkouts and confusing
# them is the single most expensive bug available here: the agent edits whatever
# directory it happens to be in, and its work is then thrown away.
#
# ORDER MATTERS. RBOPS_ROOT must be assigned before anything that reads it;
# under `set -u` a forward reference aborts the script on line one of use.
# `cd && pwd` normalises away any `..`. It is overridable so the dispatcher can
# be exercised against a fixture pipeline root.
RBOPS_ROOT="${RBOPS_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}"
# BASH_SOURCE[0] here is dispatch.sh ITSELF. Using it as the gate path made the
# "run the gate" call re-run the dispatcher, print its help banner and exit 2,
# which the dispatcher read as GATE FAILED — every phase failed in milliseconds
# for a reason that had nothing to do with the code.
VERIFY="$RBOPS_ROOT/rbops/verify.sh"
PHASES="${RBOPS_PHASES:-$RBOPS_ROOT/rbops/phases.json}"
PHASE_ROOT="$RBOPS_ROOT/phases"
LOG_DIR="${RBOPS_LOG_DIR:-$RBOPS_ROOT/logs}"
PROJECT_DIR="${RBOPS_PROJECT_DIR:-.}"
# Honour $JQ so a native Linux jq can be substituted when testing outside CI.
# A Windows jq.exe under WSL emits CRLF and its nested invocations slurp the
# parent pipe, which silently truncates the phase loop to one iteration.
JQ="${JQ:-jq}"

# Model chains, ranked. Overridable, comma-separated, first entry is primary.
IMPL_MODELS="${RBOPS_IMPL_MODELS:-opencode/big-pickle,openrouter/thinkingmachines/inkling:free,opencode/nemotron-3-ultra-free,openrouter/poolside/laguna-s-2.1:free}"
REVIEW_MODELS="${RBOPS_REVIEW_MODELS:-openrouter/thinkingmachines/inkling:free,opencode/nemotron-3-ultra-free}"
AUDIT_MODELS="${RBOPS_AUDIT_MODELS:-opencode/big-pickle,opencode/muse-spark-1.3-contributor-free}"

MAX_ATTEMPTS="${RBOPS_MAX_ATTEMPTS:-3}"
MAX_DEFERRALS="${RBOPS_MAX_DEFERRALS:-5}"
CHECKPOINT_SECS="${RBOPS_CHECKPOINT_SECS:-300}"

log()  { printf '%s [dispatch] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '%s [dispatch] FATAL %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 2; }

# Advisory lock. CI enforces one-phase-at-a-time with a `concurrency` group;
# `mkdir` is atomic, so this also protects a developer running two ticks from
# one machine. A stale lock (older than 6h, i.e. a runner that was killed) is
# reclaimed rather than blocking the pipeline forever.
LOCK_DIR="${RBOPS_LOCK:-/tmp/rbops-pipeline.lock}"
release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }
# The lock records BOTH the owning pid and when it was taken. Liveness answers
# "is a run still going", age answers "is this pid merely being reused".
lock_take() { echo $$ > "$LOCK_DIR/pid" 2>/dev/null || true
              date +%s > "$LOCK_DIR/born" 2>/dev/null || true
              trap 'release_lock' EXIT INT TERM; }
lock_age()  { local b; b="$(cat "$LOCK_DIR/born" 2>/dev/null || echo 0)"; echo $(( $(date +%s) - b )); }
owner_alive() {
  local p; p="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)"
  [ "$p" -gt 0 ] 2>/dev/null || return 1
  kill -0 "$p" 2>/dev/null
}
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_take
    return 0
  fi

  # Reclaim when the recorded owner is gone. A section killed by `timeout` leaves
  # the lock behind, and without this the NEXT invocation dies with exit 2 and no
  # useful message - which is exactly what the smoke suite caught in CI.
  if ! owner_alive; then
    log "reclaiming lock from a dead owner (age $(lock_age)s)"
    rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR" 2>/dev/null || true
    lock_take
    return 0
  fi

  # Owner is alive, but it may have been killed long ago and its pid reused.
  local age; age="$(lock_age)"
  if [ "$age" -gt 21600 ]; then
    log "reclaiming stale lock (${age}s old)"
    rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR" 2>/dev/null || true
    lock_take
    return 0
  fi

  die "another rbops run holds $LOCK_DIR (pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?'), age ${age}s). Wait, or remove it if no run is active."
}

need_jq() { command -v "$JQ" >/dev/null 2>&1 || die "jq is required (set JQ=/path/to/jq)"; }
# Preflight, shared by every mutating command.
#
# toolchain_ok prints the reason on stdout and returns 3 when the machine cannot
# invoke a model. It NEVER dies: a missing CLI or key is an operator problem,
# not a phase problem, and `die` (exit 2, no marker) made a runner without
# opencode look like a crash instead of a blocked phase.
toolchain_ok() {
  command -v opencode >/dev/null 2>&1 || { printf 'opencode CLI not on PATH'; return 3; }
  [ -n "${OPENCODE_API_KEY:-}" ]        || { printf 'OPENCODE_API_KEY is not set'; return 3; }
  return 0
}

# env_check is the phase-aware wrapper: same verdict, plus a marker and a log
# line naming the phase, so the dispatcher, the workflow and the auditor can
# all see why it stopped.
env_check() {
  local phase="$1" reason
  if ! reason="$(toolchain_ok)"; then
    touch "$(marker "$phase" .blocked)"
    log "$phase BLOCKED — $reason"
    case "$reason" in
      "OPENCODE_API_KEY is not set")
        local hint
        hint="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
        [ -n "$hint" ] || hint="<owner>/rbops"
        log "  fix: gh secret set OPENCODE_API_KEY --repo $hint" ;;
    esac
    return 3
  fi
  # Cheap auth probe. Do not waste a phase on a bad key.
  if ! opencode models >/dev/null 2>&1; then
    touch "$(marker "$phase" .blocked)"
    log "$phase BLOCKED — opencode auth probe failed (bad or exhausted key)"
    return 3
  fi
  return 0
}

# ---------------------------------------------------------------- phase state
# Paths are anchored to the pipeline repo, and git operations are anchored to the
# project, so the script behaves identically no matter where it is invoked from.
marker() { printf '%s/phases/%s/%s' "$RBOPS_ROOT" "$1" "$2"; }
has()    { [ -f "$(marker "$1" "$2")" ]; }
# Run a command inside the project checkout.
in_project() { ( cd "$PROJECT_DIR" && "$@" ); }
bump()   { # bump <phase> <file>
  local f; f="$(marker "$1" "$2")"
  local n=0; [ -f "$f" ] && n="$(tr -cd '0-9' < "$f")"
  mkdir -p "$(dirname "$f")"; printf '%s' "$((n+1))" > "$f"
}
read_n() { local f; f="$(marker "$1" "$2")"; [ -f "$f" ] && tr -cd '0-9' < "$f" || printf '0'; }
# Emit stdin capped at $1 bytes, with an honest marker when truncated.
# run_agent passes the whole prompt as ONE argv string, and one string over
# 128KB (MAX_ARG_STRLEN) fails execve with E2BIG regardless of the total size.
# The review context bundles full diffs, so a large phase blows past that; the
# markers below are what keep a truncation visible instead of silent.
emit_capped() { # emit_capped <bytes> <label>
  local cap="$1" label="$2" tmp total
  tmp="$(mktemp)"
  cat > "$tmp"
  total="$(wc -c < "$tmp")"
  if [ "$total" -le "$cap" ]; then
    cat "$tmp"
  else
    head -c "$cap" "$tmp"
    printf '\n[... truncated: %s of %s bytes shown for %s — full tree available in the clone ...]\n' "$cap" "$total" "$label"
  fi
  rm -f "$tmp"
}
# Normalize formatting before judging. `cargo fmt` is deterministic and
# semantic-neutral: it cannot change what the code does, only how it looks.
# An unformatted tree used to fail the whole gate on `cargo fmt --check` —
# phase-020 burned a 50-minute model run plus a 2.5-hour job on exactly that,
# with a leftover scratch file on top. Formatting here does not weaken the
# gate: verify.sh still runs `fmt --check`, which now verifies a normalized
# tree instead of discovering the agent skipped a step. Logged visibly so the
# REPORT's gate table stays honest about who ran what.
normalize_tree() {
  if in_project cargo fmt --all -- --check >/dev/null 2>&1; then
    log "normalize: tree already formatted — no-op"
  elif in_project cargo fmt --all >/dev/null 2>&1; then
    log "normalize: cargo fmt reformatted the tree (agent left it unformatted)"
  else
    log "normalize: cargo fmt failed — leaving tree as the agent left it"
  fi
}

# ------------------------------------------------------------------- selection
# Priority:  1) .deferred (retry, cheapest continuity)
#            2) lowest-id phase whose deps are all .done and which is not
#               .done/.blocked  — dependency order comes from the manifest,
#               not from numeric luck
#            3) empty  => the queue is drained
cmd_select() {
  need_jq
  if [ -f "$RBOPS_ROOT/phases/.stop" ]; then log "phases/.stop present — pipeline halted"; printf '\n'; return; fi

  # Portability: `tr -d '\r'` guards against a Windows jq.exe under WSL, whose
  # CRLF output would otherwise produce a phase id of "phase-001\r" and create a
  # directory with a carriage return in its name.
  local p
  # 1. resume a deferral
  p="$( "$JQ" -r '.phases[].id' "$PHASES" 2>/dev/null | tr -d '\r' | sort -t- -k2 -n \
       | while read -r id; do has "$id" .deferred && { echo "$id"; break; }; done)"
  if [ -n "$p" ]; then log "resuming deferred: $p"; printf '%s\n' "$p"; return; fi

  # 2. first phase in manifest order whose deps are satisfied
  p="$( "$JQ" -r '.phases[].id' "$PHASES" | tr -d '\r' | sort -t- -k2 -n | while read -r id; do
        has "$id" .done     && continue
        has "$id" .blocked  && continue
        has "$id" .starved  && continue
        local unmet=0 dep
        for dep in $( "$JQ" -r --arg p "$id" '.phases[]|select(.id==$p)|.depends_on[]?' "$PHASES" | tr -d '\r'); do
          has "$dep" .done || unmet=1
        done
        [ "$unmet" -eq 0 ] && { echo "$id"; break; }
      done)"
  if [ -n "$p" ]; then
    # Skipping a blocked phase keeps throughput, but it must never be SILENT.
    # A lower-id phase that is blocked or repeatedly deferred is a hole in the
    # plan; anyone reading "selected: phase-004" must not assume 001 is fine.
    local skipped
    skipped="$("$JQ" -r '.phases[].id' "$PHASES" | tr -d '\r' | sort -t- -k2 -n \
      | while read -r id; do
          if [ "$id" = "$p" ]; then break; fi
          has "$id" .blocked  && { echo "$id:blocked"; continue; }
          d="$(read_n "$id" .deferred_attempts)"
          [ "$d" -gt 0 ] && echo "$id:deferred($d)"
        done)"
    if [ -n "$skipped" ]; then
      log "WARNING: $p selected while earlier phases are not done:"
      printf '%s\n' "$skipped" | sed 's/^/          - /'
      log "  these are stalled. Dispatching stop will halt the pipeline."
    fi
    log "selected: $p"
    printf '%s\n' "$p"
    return
  fi

  # 3. queue drained
  local blocked
  blocked="$(ls -d "$PHASE_ROOT"/*/.blocked 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${blocked:-0}" -gt 0 ]; then
    log "WARNING: $blocked phase(s) blocked and need human intervention:"
    ls -d "$PHASE_ROOT"/*/.blocked 2>/dev/null | sed 's|.*/||;s|/.blocked||' | sed 's/^/          - /'
  fi
  log "queue drained"
  printf '\n'
}

# ------------------------------------------------------------------- execution
# Runs the implementer agent against a chain of models, advancing on
# infrastructure failure only. A real work error is kept, never swallowed.
# RBOPS_PROMPT_FILE: the phase context (AGENTS.md + PROMPT.md) is passed as the
# POSITIONAL message, never on stdin. `opencode run [message..]` does not read
# stdin, so the `< ctx` idiom used by llops-android silently produces
# "You must provide a message or a command" and a zero-byte no-op.
run_agent() {
  local models="$1"; shift
  local logfile="$1"; shift
  local prompt_file="${1:-}"; shift || true
  : > "$logfile"
  local m code pre post growth msg IFS=,
  # The real limit is MAX_ARG_STRLEN: one argv string over 128KB fails execve
  # with E2BIG no matter how small the total is. A comment here once claimed a
  # positional message was safe up to ~2MB (ARG_MAX); that confused the total
  # with the per-string limit, and every review of a large phase died with
  # "/usr/bin/timeout: Argument list too long". Guard far below it so a runaway
  # ctx fails loudly, not obscurely.
  msg=""
  if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
    local bytes; bytes="$(wc -c < "$prompt_file")"
    if [ "$bytes" -gt 100000 ]; then
      log "prompt file is ${bytes} bytes — over the 100KB argv budget, deferring"
      return 75
    fi
    msg="$(cat "$prompt_file")"
  fi
  for m in $models; do
    m="$(printf '%s' "$m" | tr -d ' \r')"
    [ -n "$m" ] || continue
    log "model → $m"
    pre="$(wc -c < "$logfile")"
    if [ -n "$msg" ]; then
      timeout "${RBOPS_MODEL_TIMEOUT:-3000}" opencode run --model "$m" "$@" "$msg" >>"$logfile" 2>&1
    else
      timeout "${RBOPS_MODEL_TIMEOUT:-3000}" opencode run --model "$m" "$@" >>"$logfile" 2>&1
    fi
    code=$?
    post="$(wc -c < "$logfile")"; growth=$((post-pre))
    # A model can exit 0 having produced nothing — an unknown model id, a free
    # tier that has been revoked, or a CLI that gives up quietly. Accepting exit
    # 0 as success is how a phase "passes" with zero work done, so require BOTH
    # a zero exit AND real output before believing it.
    if [ "$code" -eq 0 ] && [ "$growth" -ge "${RBOPS_MIN_OUTPUT:-500}" ]; then
      log "model ok: $m (${growth} bytes)"; return 0
    fi
    if [ "$code" -eq 0 ]; then
      log "model $m exited 0 but produced only ${growth} bytes — advancing chain"
      tail -4 "$logfile" | sed 's/^/    | /'
      continue
    fi
    if infra_failure "$logfile" || [ "$growth" -lt 200 ]; then
      log "model unusable ($m, exit $code) — advancing chain"
      tail -4 "$logfile" | sed 's/^/    | /'
      continue
    fi
    log "model failed with a real work error ($m, exit $code) — keeping result"
    return "$code"
  done
  log "every model in the chain was unusable — infra problem, not a phase problem"
  return 75          # EX_TEMPFAIL: retry later, do NOT count a phase attempt
}

# Strict classifiers. The bare word "retry" must NOT match, or normal agent
# prose about retrying a build would falsely defer a phase.
infra_failure() {
  grep -qiE 'HTTP[ /]?(429|5[0-9][0-9])|too many requests|rate[ _-]?limit|insufficient[ _-]?quota|quota exceeded|model not found|unknown model|invalid model|no such model|overloaded|upstream error|ECONNRESET|ETIMEDOUT|stream.*(closed|failed)' "$1"
}

# Push work-in-progress every CHECKPOINT_SECS so a timeout or cancellation
# never loses a partial phase.
#
# stdout/stderr MUST be redirected away from the caller. A background job that
# inherits the pipe keeps it open for as long as it sleeps, so `$(dispatch.sh
# ...)` and `dispatch.sh ... | tee` block until the 300s sleep expires — the
# phase appears to hang even though the work finished in seconds.
checkpoint_loop() {
  local phase="$1"
  while sleep "$CHECKPOINT_SECS"; do
    # Everything here is git inside the PROJECT, so the checkpoint captures the
    # agent's work rather than the untouched pipeline repo.
    in_project bash -c '
      tree=$(git add -A >/dev/null 2>&1; git write-tree 2>/dev/null) || exit 0
      commit=$(git commit-tree "$tree" -p HEAD -m "rbops: '"$phase"' checkpoint $(date -u +%s)" 2>/dev/null) || exit 0
      git push -f origin "$commit:refs/heads/rbops-wip/'"$phase"'" >/dev/null 2>&1 || true
      git reset --mixed HEAD >/dev/null 2>&1 || true
    ' || true
  done
}

start_checkpoint_loop() {
  local phase="$1"
  checkpoint_loop "$phase" >>"${LOG_DIR}/${phase}.checkpoint.log" 2>&1 &
  CHECK_PID=$!
}

stop_checkpoint_loop() {
  [ -n "${CHECK_PID:-}" ] || return 0
  kill "$CHECK_PID" 2>/dev/null || true
  wait "$CHECK_PID" 2>/dev/null || true
  CHECK_PID=""
}

cmd_run() {
  local phase="${1:?phase required}"
  need_jq
  mkdir -p "$PHASE_ROOT/$phase" "$LOG_DIR"
  local prompt="$PHASE_ROOT/$phase/PROMPT.md"
  [ -f "$prompt" ] || die "no PROMPT.md for $phase — an undeclared prompt is not a phase"

  if has "$phase" .done; then log "$phase already .done"; return 0; fi
  if [ -f "$RBOPS_ROOT/phases/.stop" ]; then log "halted by phases/.stop"; return 0; fi

  # Capture the base BEFORE any resume merge, so the gate judges the phase's
  # END STATE. Work inherited from a previous attempt must count toward the
  # diff and the test quota, or a retry is punished for the tree it was given.
  local base; base="$(in_project git rev-parse HEAD)"

  # Two kinds of preserved work exist, and they are NOT equal:
  #
  #   rbops-recovery/<phase>  a COMPLETE attempt that the gate evaluated and
  #                           rejected. Its tests ran. Its tree is coherent.
  #   rbops-wip/<phase>       whatever a TIMED-OUT attempt had written. Partial
  #                           by definition, and may not even compile.
  #
  # Recovery must therefore win. A stale WIP checkpoint outranking a complete
  # attempt made a retry inherit a broken tree: clippy failing, one test, and a
  # #[ignore] the interrupted run had added. The agent dutifully built on it
  # and the phase got worse than starting clean.
  local resumed=0
  if in_project git rev-parse --verify -q "origin/rbops-recovery/$phase" >/dev/null 2>&1; then
    # --squash, never a real merge. A real `git merge` records BOTH parents, and
    # when the preserved work came from a WIP checkpoint that branch's history is
    # full of `rbops: phase-NNN checkpoint <ts>` commits. Merging it into the
    # project clone's `main` made those checkpoints ancestors of main, and the
    # next successful push shipped them: six of them are in redblue's history
    # today, carrying unreviewed code. A squash stages the same content and
    # commits it with main as the only parent, so the work is adopted and the
    # checkpoint ancestry never reaches main.
    #
    # --squash also covers the fast-forward case, so this is one path, not two.
    if in_project git merge --squash --no-edit "origin/rbops-recovery/$phase" >/dev/null 2>&1; then
      in_project git commit -q -m "resume $phase: adopt preserved work" >/dev/null 2>&1 || true
      log "resumed from previous attempt (rbops-recovery/$phase, squashed onto main)"
      touch "$(marker "$phase" .recovered)"
      resumed=1
    elif in_project git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
         || grep -qE '^(<<<<<<<|=======$|>>>>>>>)' "$PROJECT_DIR"/src/*.rs 2>/dev/null; then
      # Conflicted. Hand the resolution to the agent rather than throwing the
      # work away: phase-019's recovery held a 5629-line bytecode VM, and
      # starting clean would mean re-deriving all of it. The gate still decides
      # whether the resolved tree is any good.
      log "resumed from previous attempt (rbops-recovery/$phase) WITH UNRESOLVED CONFLICTS"
      in_project git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/    conflict: /' | sed -n '1,10p'
      touch "$(marker "$phase" .recovered)"
      touch "$(marker "$phase" .conflict)"
      resumed=1
    else
      in_project git merge --abort 2>/dev/null || true
      in_project git reset -q --hard HEAD 2>/dev/null || true
      log "recovery branch present but not usable — starting clean"
    fi
  fi
  if [ "$resumed" -eq 0 ] \
     && in_project git rev-parse --verify -q "origin/rbops-wip/$phase" >/dev/null 2>&1; then
    log "squashing WIP checkpoint for $phase (partial work from a timeout)"
    # --squash here too, for the same reason: rbops-wip/* is nothing but
    # checkpoint commits, and merging it for real is what put six of them into
    # redblue main.
    if in_project git merge --squash --no-edit -X theirs "origin/rbops-wip/$phase" >/dev/null 2>&1; then
      in_project git commit -q -m "resume $phase: adopt WIP checkpoint" >/dev/null 2>&1 || true
      touch "$(marker "$phase" .checkpoint)"
    else
      in_project git merge --abort 2>/dev/null || true
      in_project git reset -q --hard HEAD 2>/dev/null || true
      log "WIP checkpoint would not apply cleanly — continuing from main"
    fi
  fi
  {
    # The brief comes FIRST and is deliberately blunt. A weak model given a
    # 25KB context with no explicit scope spends its entire budget orienting:
    # run 3 listed directories for five minutes, read AGENTS.md, started
    # auditing the pipeline, and never wrote a line of code. Scope and a time
    # box up front are worth more than a longer brief.
    cat <<TPL
# DO THIS, NOW. No orientation phase.

Your working directory is the project checkout. It is the ONLY place you may
read or write. The RBOPS pipeline that invoked you lives elsewhere; do not
inspect it, do not audit it, and do not spend a single tool call on it.

You have one job, described below. Work in this order and do not deviate:

1. Reproduce the finding. Smallest command that shows it. Then STOP and note it.
2. Write ONE failing test that demonstrates it. Run it. Watch it fail.
3. Make the smallest change that turns that test green.
4. Add the remaining edge-case tests required below.
5. Run the four gates. Fix what they report.
6. Write REPORT.md.

Budget: reproduce in 2 minutes, first test by 5, first edit by 10. If you
still have not written code by then, you have misread the task — re-read this
message. Do not browse. Do not read files you have not been told to read. Do not
write a plan document. There is no human to review a plan.

Files: read and write ONLY inside your working directory. Never write to /tmp,
/home, or anywhere outside the project — the permission system auto-rejects
those calls, and in this pipeline a rejected tool call ends your run. If you
need scratch space, use ./target/tmp/ inside the project.

When you are done, say DONE and stop.

---

## Contract you must obey (AGENTS.md)

TPL
    cat "$RBOPS_ROOT/AGENTS.md"
    printf '\n\n---\n\n# YOUR PHASE: %s\n\nProject root: %s\n\n' "$phase" "$PROJECT_DIR"
    cat "$prompt"
    [ -f "$(marker "$phase" .checkpoint)" ] && cat <<'TPL'

---
## CONTINUATION MODE
A previous attempt was interrupted and its partial work is already in the tree.
DO NOT restart. Inspect what exists, continue from it, finish the phase.
TPL
    # Tell the agent what it inherited and, crucially, why the previous attempt
    # failed — otherwise it repeats the same failure. The prior REPORT.md names
    # the failing checks; the gate output below is quoted from the last run.
    if [ -f "$(marker "$phase" .recovered)" ]; then
      if [ -f "$(marker "$phase" .conflict)" ]; then
        cat <<TPL

---
## RESUMED WORK, WITH UNRESOLVED MERGE CONFLICTS — fix these first
Your tree is the previous attempt's work merged onto newer \`main\`, and the merge
did not resolve cleanly. Files containing conflict markers (\`<<<<<\`, \`=======\`,
\`>>>>>>>\`) are already on disk:

$(in_project git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^  - /')

Before anything else:
1. Open each conflicted file and resolve every marker.
2. Keep BOTH intents. \`main\` has moved since the attempt was parked - usually a
   new phase landed - so its version may contain work the attempt never saw.
   Do not resolve by taking one side wholesale.
3. Then continue and finish the phase as described below.

The gate decides whether the resolved tree is acceptable. A conflict left
unresolved will fail it.
TPL
      fi
      cat <<TPL

---
## RESUMED WORK — read this before touching anything
A previous attempt's work is already merged into your tree. DO NOT start over
and DO NOT rewrite it from scratch. Your job is to finish what is missing:

1. Run the four gates FIRST, before changing anything, to see the current state.
2. Read phases/$phase/REPORT.md from the previous attempt (harvested below if
   present) to see what it claimed and what the gate actually said.
3. Fix exactly what failed. Add what is missing. Do not remove working code.
TPL
      if [ -f "$RBOPS_ROOT/phases/$phase/REPORT.md" ]; then
        printf '\n### Previous REPORT.md (do not trust its gate claims — verify them)\n\n```\n'
        cat "$RBOPS_ROOT/phases/$phase/REPORT.md"
        printf '\n```\n'
      else
        # phase-019 spent three attempts and ~30 minutes re-running an 8-minute
        # model to produce 5629 lines of bytecode VM with 461 green tests, and
        # failed all three times for exactly one reason: it never wrote
        # REPORT.md, so the gate refused a phase with no report. The work was
        # preserved and fine; only the paperwork was missing. Without this line
        # the resumed agent gets "fix exactly what failed" and no report to read,
        # so it cannot know the failure was paperwork rather than code.
        printf '\n### THE PRIOR ATTEMPT HAD NO REPORT.md — that alone failed the phase\n\n'
        printf 'The gate rejects a phase with no REPORT.md, whatever else it achieves.\n'
        printf 'Your code may already be correct and complete. Do NOT rewrite it.\n\n'
        printf 'Your first and cheapest job is to WRITE %s/phases/%s/REPORT.md\n' "$PROJECT_DIR" "$phase"
        printf 'describing the work already in the tree, following AGENTS.md section 4\n'
        printf 'exactly: the "What changed", "Tests added", "Gates" and\n'
        printf '"Known gaps / follow-ups" sections, with real evidence rows.\n'
        printf 'Report the test counts you actually observe. Do not claim a gate you\n'
        printf 'did not run. Only then consider whether the work itself needs changes.\n'
      fi
    fi
  } > "$LOG_DIR/$phase.ctx"
  cat "$LOG_DIR/$phase.ctx" > "$LOG_DIR/$phase.prompt"   # audit record

  # env_check FIRST: it returns 3 with a marker and a reason for both a missing
  # CLI and a missing key. A hard die here (exit 2, no marker) is how a runner
  # without opencode once looked like a crash rather than a blocked phase.
  env_check "$phase" || return 3
  [ -d "$PROJECT_DIR" ] || { log "FATAL: project dir '$PROJECT_DIR' does not exist"; return 2; }
  CHECK_PID=""
  start_checkpoint_loop "$phase"
  local code
  # --dir points the agent at the PROJECT checkout. Without it the agent runs in
  # the rbops repo, spends its whole budget looking for src/testing/harness.rs,
  # edits nothing, and its output is discarded.
  run_agent "$IMPL_MODELS" "$LOG_DIR/$phase.log" "$LOG_DIR/$phase.ctx" \
      --dir "$PROJECT_DIR" --agent build --title "rbops-${phase}"
code=$?
stop_checkpoint_loop

# Harvest what the agent wrote. The agent's working directory is the PROJECT
# checkout, so anything it wrote to a relative path - REPORT.md, FINDINGS.md -
# lands in the project, not in the pipeline repo where the gate looks. Run 5
# produced a correct REPORT.md in redblue/phases/phase-001/ and the gate reported
# "a phase without a report cannot pass".
for artefact in REPORT.md FINDINGS.md; do
  if [ -f "$PROJECT_DIR/phases/$phase/$artefact" ]; then
    mkdir -p "$RBOPS_ROOT/phases/$phase"
    cp "$PROJECT_DIR/phases/$phase/$artefact" "$RBOPS_ROOT/phases/$phase/$artefact"
    log "harvested $artefact from the project"
  fi
done

  # --- classify -------------------------------------------------------------
  # A dead model chain (75) or an infra-shaped log is a RETRYABLE infra fault.
  # It must never be counted as a phase attempt: nothing was attempted, so
  # burning MAX_ATTEMPTS on it would block a phase that never even ran.
  if [ "$code" = "75" ] || infra_failure "$LOG_DIR/$phase.log"; then
    rm -f "$(marker "$phase" .failed)" "$(marker "$phase" .done)"
    bump "$phase" .deferred_attempts
    local d; d="$(read_n "$phase" .deferred_attempts)"
    if [ "$d" -ge "$MAX_DEFERRALS" ]; then
      touch "$(marker "$phase" .blocked)"
      log "$phase BLOCKED after $d deferrals — the model chain is unusable, this needs a human"
      return 3
    fi
    touch "$(marker "$phase" .deferred)"
    log "$phase DEFERRED ($d/$MAX_DEFERRALS) — infra, no attempt consumed, retry next tick"
    tail -6 "$LOG_DIR/$phase.log" | sed 's/^/    | /'
    return 42
  fi

  # --- THE GATE -------------------------------------------------------------
  normalize_tree
  log "running verify gate for $phase"
  RBOPS_PROJECT_DIR="$PROJECT_DIR" RBOPS_PHASES="$PHASES" RBOPS_BASE_REF="$base" "$VERIFY" "$phase"
  code=$?
  if [ "$code" -ne 0 ]; then
    rm -f "$(marker "$phase" .done)" "$(marker "$phase" .checkpoint)"
    touch "$(marker "$phase" .failed)"
    local a; a="$(read_n "$phase" .attempts)"; bump "$phase" .attempts
    a="$(read_n "$phase" .attempts)"
    if [ "$a" -ge "$MAX_ATTEMPTS" ]; then
      touch "$(marker "$phase" .blocked)"
      log "$phase BLOCKED — gate failed $a/$MAX_ATTEMPTS times. A human must look."
      return 3
    fi
    log "$phase GATE FAILED (attempt $a/$MAX_ATTEMPTS)"
    return 1
  fi

  # gate passed — do NOT mark done yet, the reviewer must sign off first
  rm -f "$(marker "$phase" .failed)" "$(marker "$phase" .deferred)" "$(marker "$phase" .deferred_attempts)"
  log "$phase passed the gate — awaiting review"
  return 0
}

# -------------------------------------------------------------------- reviewer
cmd_review() {
  local phase="${1:?phase required}"
  mkdir -p "$LOG_DIR"
  local base; base="$(in_project git rev-parse HEAD)"
  local round=0

  while [ "$round" -lt "${RBOPS_MAX_REVIEW_ROUNDS:-3}" ]; do
    round=$((round+1))
    log "review round $round for $phase"

    # The reviewer agent is read-only AND has no shell, so it cannot run
    # `git diff`. The change set has to be handed to it, and it must be the
    # COMPLETE change set: committed, unstaged and untracked. Reading only
    # `base..HEAD` hides any work the phase left uncommitted, which is exactly
    # the work most worth reviewing.
local rctx="$LOG_DIR/$phase.review.$round.ctx"
    {
      printf '# Review request - round %s of phase %s\n\n' "$round" "$phase"
      printf 'The gate is green. Your job is to find what is still wrong.\n'
      printf 'The contract below is authoritative and is inlined here on purpose:\n'
      printf 'dispatch runs you with --dir pointing at the redblue checkout, which has\n'
      printf 'no opencode.json, so `--agent reviewer` resolves to nothing and silently\n'
      printf 'falls back to the default agent. Referring you to a config file or an\n'
      printf '.opencode/agent/*.md path meant you ran with NO contract for every phase.\n\n'
      printf -- '---\n\n'
      cat "$RBOPS_ROOT/rbops/agents/reviewer.md" 2>/dev/null \
        || printf '!! THE REVIEWER CONTRACT IS MISSING. Treat this review as INVALID.\n'
      printf -- '\n---\n\n'
      printf '## Change set for phase %s\n\n' "$phase"
      printf '### File list (always complete — content below may be capped)\n\n```\n'
      in_project git diff --no-color --numstat "$base"..HEAD 2>/dev/null || printf '(none committed)\n'
      in_project git diff --no-color --numstat 2>/dev/null || printf '(none uncommitted)\n'
      printf '```\n\n## 1. Committed changes (%s..HEAD)\n\n```diff\n' "$base"
      in_project git diff --no-color "$base"..HEAD 2>/dev/null | emit_capped 40000 'committed diff' || printf '(none)\n'
      printf '```\n\n## 2. Uncommitted tracked changes\n\n```diff\n'
      in_project git diff --no-color 2>/dev/null | emit_capped 20000 'uncommitted diff' || printf '(none)\n'
      printf '```\n\n## 3. Untracked files (capped at 8KB each)\n\n'
      # git collapses a wholly-untracked directory to ONE `?? dir/` line. Without
      # expansion the reviewer sees `(unreadable)` for every new file in a new
      # directory — exactly where a phase like bootstrap/ puts its work.
      in_project git status --porcelain 2>/dev/null | grep '^??' | sed 's/^?? //' | while read -r f; do
        if [ -d "$PROJECT_DIR/$f" ]; then
          find "$PROJECT_DIR/$f" -type f | sort | while read -r gf; do
            rel="${gf#$PROJECT_DIR/}"
            printf -- '--- %s\n```\n' "$rel"
            emit_capped 8000 "untracked file $rel" < "$gf"
            printf '```\n'
          done
        elif [ -f "$PROJECT_DIR/$f" ]; then
          printf -- '--- %s\n```\n' "$f"
          emit_capped 8000 "untracked file $f" < "$PROJECT_DIR/$f"
          printf '```\n'
        else
          printf -- '--- %s\n(unreadable)\n' "$f"
        fi
      done
      printf '\n## 4. The phase REPORT.md\n\n'
      cat "$RBOPS_ROOT/phases/$phase/REPORT.md" 2>/dev/null || printf '(missing)\n'
    } > "$rctx"

    run_agent "$REVIEW_MODELS" "$LOG_DIR/$phase.review.$round.log" "$rctx" \
        --dir "$PROJECT_DIR" --agent reviewer --title "rbops-review-${phase}-${round}"

    local rc_round=$?
    if [ "$rc_round" = "75" ]; then
      log "review round $round: model chain unusable — deferring, no attempt consumed"
      bump "$phase" .deferred_attempts
      touch "$(marker "$phase" .deferred)"
      return 42
    fi

    # --- parse the review -------------------------------------------------------
    # The rule is asymmetric ON PURPOSE. The old logic was: "no `[SEVERITY]` tag
    # found, therefore clean". That is not a review, it is an absence of one, and
    # it silently shipped phase-013, whose review contained six real defect
    # classes - a descending `for` range that never executes, an uncharged
    # recursion path that can overflow the Rust stack, env-coupled tests that fail
    # under REDBLUE_MAX_STEPS - all written as prose with no tags, so all of it was
    # discarded and the phase was marked done.
    #
    # A review that cannot be parsed must not be able to approve anything.
    local rlog="$LOG_DIR/$phase.review.$round.log"
    local has_sev has_clean has_verdict blocking
    # NOTE: no `|| echo 0` here. `grep -c` already prints 0 on no match (and
    # exits 1 doing it), so `|| echo 0` would append a SECOND line and leave
    # "0\n0" in the variable, which breaks every `[ ... -gt 0 ]` below.
    has_sev="$(grep -coE '\[(BLOCKER|CRITICAL|MAJOR|MINOR|STYLE)\]|\*\*?(BLOCKER|CRITICAL|MAJOR|MINOR|STYLE)\*\*?|(^|[^A-Za-z])(BLOCKER|CRITICAL|MAJOR):' "$rlog" 2>/dev/null)"; has_sev="${has_sev:-0}"
    has_clean="$(grep -ciE 'FINDINGS: *none|REVIEW VERDICT: *CLEAN' "$rlog" 2>/dev/null)"; has_clean="${has_clean:-0}"
    has_verdict="$(grep -ciE '^[[:space:]]*REVIEW VERDICT: *(CLEAN|FINDINGS)' "$rlog" 2>/dev/null)"; has_verdict="${has_verdict:-0}"
    blocking="$(grep -coE '\[(BLOCKER|CRITICAL)\]|\*\*?(BLOCKER|CRITICAL)\*\*?|(^|[^A-Za-z])(BLOCKER|CRITICAL):' "$rlog" 2>/dev/null)"; blocking="${blocking:-0}"

    if [ "$blocking" -gt 0 ]; then
      log "review round $round: $blocking blocking finding(s) - fixing"
    elif [ "$has_clean" -gt 0 ]; then
      log "review round $round: explicit CLEAN verdict - shipping"
      break
    elif [ "$has_sev" -gt 0 ]; then
      log "review round $round: findings present, none blocking - shipping"
      break
    elif [ "$has_verdict" -gt 0 ]; then
      log "review round $round: verdict line present but no findings and no CLEAN - shipping"
      break
    else
      # No verdict, no severities, no clean marker. Either the model rambled, or
      # it never received the contract. Either way this is not a sign-off.
      log "review round $round INVALID - no verdict line, no severity tags, no clean marker"
      if [ "$round" -ge "${RBOPS_MAX_REVIEW_ROUNDS:-3}" ]; then
        log "$phase BLOCKED - reviewer never produced a parseable verdict in $round rounds"
        touch "$(marker "$phase" .blocked)"
        return 3
      fi
      log "retrying review with an explicit re-request"
      continue
    fi

    # --- did the fix pass actually address the finding? ---------------------
    # A fix pass is another model run, and it can report a fix it did not make.
    # phase-015 burned three review rounds on one defect: the pass wrote
    # "| src/formatter.rs | +40 -10 | **run 3 (this round)** - the `catch`
    # BLOCKER" into its own summary while leaving the `if let Some(var)` arm
    # exactly as it was. The reviewer was right to re-report it every time.
    #
    # So verify mechanically: hash every file the blocking findings cite, run the
    # fix, hash again. If not one cited file changed, the pass did not attempt the
    # finding, and looping again just burns ~11 minutes to learn the same thing.
    # Block immediately with that reason instead.
    local cited; cited="$(mktemp)"
    grep -oE '[A-Za-z0-9_][A-Za-z0-9_./-]*\.(rs|rb|md|json|toml)' "$rlog" 2>/dev/null \
      | grep -vE '^(Cargo\.lock|Cargo\.toml)$' | sort -u > "$cited" || true
    local before after touched=0 f
    before="$(mktemp)"; after="$(mktemp)"
    while read -r f; do
      [ -n "$f" ] || continue
      if [ -f "$PROJECT_DIR/$f" ]; then
        printf '%s %s\n' "$(cksum < "$PROJECT_DIR/$f" | awk '{print $1"-"$2}')" "$f" >> "$before"
      fi
    done < "$cited"
    if [ -s "$before" ]; then log "fix round $round: $(wc -l < "$cited") file(s) cited by the findings"; fi
    # Scope snapshot: how many lines does this fix round add to the phase?
    # A single BLOCKER fix that adds ~1000 lines is not a fix, it is a rewrite
    # wearing a fix's clothes — phase-020 grew +990/+1118 lines per round while
    # test count barely moved (+10 total). Visibility only, never a gate: a big
    # fix can be legitimate, but an ever-growing diff across rounds is how scope
    # creep hides inside a passing gate.
    local added_before
    added_before="$(in_project git diff --numstat "$base" 2>/dev/null | awk '{s+=$1} END{print s+0}')"

    log "applying review fixes"
    local fctx="$LOG_DIR/$phase.fix.$round.ctx"
    {
      printf '# Fix the review findings for phase %s (round %s)\n\n' "$phase" "$round"
      printf 'Read the reviewer output below and fix every BLOCKER and CRITICAL.\n'
      printf 'Do not weaken any gate. Do not add #[ignore], `// skip`, or an'
      printf ' allow(clippy:: suppression. Do not delete a test.\n'
      printf 'Then re-run the four gates yourself.\n\n'
      printf '## Reviewer output\n\n'
      cat "$LOG_DIR/$phase.review.$round.log"
    } > "$fctx"
    run_agent "$IMPL_MODELS" "$LOG_DIR/$phase.fix.$round.log" "$fctx" \
        --dir "$PROJECT_DIR" --agent build --title "rbops-fix-${phase}-${round}"
    if [ "$?" = "75" ]; then
      log "fix round $round: model chain unusable — deferring"
      rm -f "$cited" "$before" "$after"
      return 42
    fi

    while read -r f; do
      [ -n "$f" ] || continue
      if [ -f "$PROJECT_DIR/$f" ]; then
        printf '%s %s\n' "$(cksum < "$PROJECT_DIR/$f" | awk '{print $1"-"$2}')" "$f" >> "$after"
      fi
    done < "$cited"
    if [ -s "$before" ]; then
      touched="$(join -j 2 -o 1.1,2.1 <(sort -k2 "$before") <(sort -k2 "$after") 2>/dev/null \
                | awk '$1 != $2 {print $1}' | wc -l | tr -d ' ')"
      if [ "${touched:-0}" -eq 0 ]; then
        log "fix round $round DID NOT TOUCH any file cited by the findings:"
        sed 's/^/    /' "$cited" | sed -n '1,8p'
        log "the pass reported progress without editing the code under review — not retrying"
        rm -f "$cited" "$before" "$after"
        touch "$(marker "$phase" .blocked)"
        log "$phase BLOCKED - fix pass never addressed the findings"
        return 3
      fi
      log "fix round $round: $touched cited file(s) actually changed"
    fi
    local added_after fix_delta
    added_after="$(in_project git diff --numstat "$base" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    fix_delta=$((added_after - added_before))
    if [ "$fix_delta" -gt 500 ]; then
      log "fix round $round added ${fix_delta} lines to the phase diff — disproportionate for a fix round? scope check only, not failing on this"
    fi
    rm -f "$cited" "$before" "$after"

    # --- re-gate after fixes. Mandatory. -----------------------------------
    normalize_tree
    log "re-running verify gate after review fixes"
    if RBOPS_PROJECT_DIR="$PROJECT_DIR" RBOPS_PHASES="$PHASES" RBOPS_BASE_REF="$base" "$VERIFY" "$phase"; then
      log "gate still green after fixes"
    else
      log "gate red after fixes — review loop continues"
    fi
  done

if grep -qE '\[(BLOCKER|CRITICAL)\]|\*\*?(BLOCKER|CRITICAL)\*\*?|(^|[^A-Za-z])(BLOCKER|CRITICAL):' "$LOG_DIR/$phase.review.$round.log" 2>/dev/null; then
    touch "$(marker "$phase" .blocked)"
    log "$phase BLOCKED - blocking findings survive $round review round(s)"
    return 3
  fi

  # `.done` is the ONLY completion signal cmd_select reads, so the moment it is
  # written the phase must be incapable of looking unfinished. Clearing the
  # failure markers here rather than in cmd_run is deliberate: a phase can reach
  # review with `.failed` still set (the gate clears it, but a resumed attempt
  # that fails again and then passes leaves the sequence easy to get wrong), and
  # phase-015 shipped to redblue twice with `.done` absent and `.failed` present,
  # so it was queued for a third attempt against work already merged.
  rm -f "$(marker "$phase" .failed)" "$(marker "$phase" .deferred)" \
        "$(marker "$phase" .deferred_attempts)" "$(marker "$phase" .checkpoint)"
  touch "$(marker "$phase" .done)"
  [ -f "$(marker "$phase" .done)" ] || { log "$phase FAILED to write .done"; return 3; }
  in_project git push -q origin "HEAD:refs/heads/rbops-wip/DELETE_${phase}" 2>/dev/null || true
  in_project git push -q origin ":refs/heads/rbops-wip/$phase" 2>/dev/null || true
  log "$phase DONE"

  # On the live path: the workflow calls select + run + review, never tick.
  maybe_audit
  return 0
}

# ----------------------------------------------------------------------- audit
# The phase-generating loop. The auditor is the only writer of phases.json.
cmd_audit() {
  local reason
  if ! reason="$(toolchain_ok)"; then
    log "audit SKIPPED — $reason"
    return 3
  fi
  mkdir -p "$LOG_DIR"
  log "audit pass — generating new phases from measured evidence"
  # The auditor runs with --dir at the PIPELINE root, not the project. It is the
  # only component allowed to write rbops/phases.json, and the project checkout
  # lives one level down, so pointing it at redblue/ made its own write
  # impossible - it was told to append to a file outside its working directory,
  # which every other agent is forbidden to touch. From here it can read the
  # project at ./redblue and write exactly one file: rbops/phases.json.
  cat "$RBOPS_ROOT/rbops/agents/auditor.md" > "$LOG_DIR/audit.ctx"
  {
    printf '\n\n---\n\n# AUDIT REQUEST\n\n'
    printf 'The contract above is authoritative and inlined on purpose: dispatch runs\n'
    printf 'you with an explicit working directory, so `--agent auditor` cannot be\n'
    printf 'relied on to carry it.\n\n'
    printf 'Working directory: %s (the pipeline root)\n' "$RBOPS_ROOT"
    printf 'Project under audit: ./redblue  (READ-ONLY - do not modify it)\n'
    printf 'You may write exactly ONE file: rbops/phases.json\n\n'
    printf 'MEASURE the project, DIFF reality against its SPEC/ROADMAP, SAFETY-AUDIT\n'
    printf 'the pipeline, then APPEND evidence-backed phases to rbops/phases.json.\n'
    printf 'Every phase needs a real file:line. Do not invent work.\n'
  } >> "$LOG_DIR/audit.ctx"
  run_agent "$AUDIT_MODELS" "$LOG_DIR/audit.log" "$LOG_DIR/audit.ctx" \
      --dir "$RBOPS_ROOT" --title "rbops-audit"
  local code=$?
  if [ "$code" = "75" ]; then
    log "audit DEFERRED — model chain unusable"
    return 42
  fi
  if "$JQ" empty "$PHASES" 2>/dev/null; then
    log "phases.json still valid JSON after audit"
  else
    log "FATAL: audit corrupted phases.json — reverting"
    # Restore the manifest in the PIPELINE repo, which is where it lives.
    ( cd "$RBOPS_ROOT" && git checkout -- "$PHASES" ) 2>/dev/null || true
    return 1
  fi
  # an audit that invents phases with no evidence is a failed audit
  if [ "$code" -ne 0 ]; then log "audit agent exited $code"; return "$code"; fi
  return 0
}

# --- periodic audit ---------------------------------------------------------
# Extracted from cmd_tick, where it was DEAD CODE: the workflow drives
# `select` + `run` and never calls `tick`, so the every-N-phases trigger had
# never fired once in the project's life. It is called from cmd_review now,
# which is on the live path.
maybe_audit() {
  local every done_n
  every="$("$JQ" -r '.audit.every_n_phases' "$PHASES" 2>/dev/null)"
  [ -n "$every" ] && [ "$every" -gt 0 ] 2>/dev/null || every=8
  done_n="$(ls -d "$PHASE_ROOT"/*/.done 2>/dev/null | wc -l | tr -d ' ')"
  [ "$done_n" -gt 0 ] || return 0
  if [ "$((done_n % every))" -eq 0 ]; then
    log "audit due — $done_n phases done (every $every)"
    cmd_audit || log "audit failed"
  fi
}

# ----------------------------------------------------------------------- tick
cmd_tick() {
  need_jq
  local phase; phase="$(cmd_select | tail -1)"
  if [ -z "$phase" ]; then log "idle"; return 0; fi

  local rc=0
  cmd_run "$phase"    || rc=$?
  case "$rc" in
    0)  cmd_review "$phase" || rc=$? ;;
    42) log "deferred — retrigger will retry" ;;
    3)  log "blocked — retrigger will surface it" ;;
    *)  log "run failed ($rc)" ;;
  esac

  # queue drained and nothing blocked => stop chaining, save minutes
  if [ -z "$(cmd_select | tail -1)" ]; then log "queue drained — no retrigger"; return 0; fi

  if [ "${RBOPS_RETRIGGER:-1}" = "1" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    sleep "${RBOPS_BACKOFF:-10}"
    gh api -X POST -H "Accept: application/vnd.github+json" \
      "/repos/${GITHUB_REPOSITORY}/dispatches" \
      -f "event_type=rbops_tick" \
      -f "client_payload[phase]=${phase}" \
      -f "client_payload[rc]=${rc}" >/dev/null 2>&1 \
      || log "re-dispatch failed — the cron safety net will retry"
  fi
  return "$rc"
}

case "${1:-}" in
  select) cmd_select ;;
  run)    shift; acquire_lock; cmd_run "$@" ;;
  review) shift; acquire_lock; cmd_review "$@" ;;
  audit)  acquire_lock; cmd_audit ;;
  tick)   acquire_lock; cmd_tick ;;
  stop)   mkdir -p "$RBOPS_ROOT/phases"; touch "$RBOPS_ROOT/phases/.stop"; log "HALTED — remove phases/.stop to resume" ;;
  resume) rm -f "$RBOPS_ROOT/phases/.stop"; log "RESUMED" ;;
  status) need_jq
          # Sort numerically: manifest order is a convenience for humans, and the
  # dispatcher must not jump the queue when a phase is appended.
  "$JQ" -r '.phases[].id' "$PHASES" | tr -d '\r' | sort -t- -k2 -n | while read -r id; do
            st="pending"
            for m in .done .failed .deferred .blocked; do has "$id" "$m" && st="${m#.}"; done
            printf '%-12s %-9s %-9s %s\n' "$id" \
              "$( "$JQ" -r --arg p "$id" '.phases[]|select(.id==$p)|.severity' "$PHASES")" "$st" \
              "$( "$JQ" -r --arg p "$id" '.phases[]|select(.id==$p)|.title' "$PHASES")"
          done ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac