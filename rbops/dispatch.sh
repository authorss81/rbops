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
need_rbx(){ command -v opencode >/dev/null 2>&1 || die "opencode CLI not on PATH"; }

# Preflight. A missing binary or a bad key is an OPERATOR problem, not a phase
# problem: mark the phase .blocked immediately and exit 3 rather than burning
# MAX_ATTEMPTS on a failure that will never succeed.
env_check() {
  local phase="$1"
  command -v opencode >/dev/null 2>&1 || {
    touch "$(marker "$phase" .blocked)"
    log "$phase BLOCKED — opencode CLI not installed"
    return 3
  }
  if [ -z "${OPENCODE_API_KEY:-}" ]; then
    touch "$(marker "$phase" .blocked)"
    local repo_hint
    repo_hint="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$repo_hint" ] || repo_hint="<owner>/rbops"
    log "$phase BLOCKED — OPENCODE_API_KEY is not set"
    log "  fix: gh secret set OPENCODE_API_KEY --repo $repo_hint"
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
  # ARG_MAX on Linux is ~2MB; AGENTS.md + PROMPT.md is ~25KB, so a positional
  # message is safe. Guard anyway so a runaway ctx fails loudly, not obscurely.
  msg=""
  if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
    local bytes; bytes="$(wc -c < "$prompt_file")"
    if [ "$bytes" -gt 500000 ]; then
      log "prompt file is ${bytes} bytes — refusing to pass it as argv"
      return 2
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

  # resume any WIP checkpoint from a previous timeout
  if in_project git rev-parse --verify -q "origin/rbops-wip/$phase" >/dev/null 2>&1; then
    log "merging WIP checkpoint for $phase"
    in_project git merge --no-edit -X theirs "origin/rbops-wip/$phase" >/dev/null 2>&1 || true
    touch "$(marker "$phase" .checkpoint)"
  fi

  local base; base="$(in_project git rev-parse HEAD)"
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
  } > "$LOG_DIR/$phase.ctx"
  cat "$LOG_DIR/$phase.ctx" > "$LOG_DIR/$phase.prompt"   # audit record

  need_rbx
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
      printf '# Review request — round %s of phase %s\n\n' "$round" "$phase"
      printf 'Rules: .opencode/agent/reviewer.md and AGENTS.md section 5.\n'
      printf 'The gate is green. Your job is to find what is still wrong.\n\n'
      printf '## 1. Committed changes (%s..HEAD)\n\n```diff\n' "$base"
      in_project git diff --no-color "$base"..HEAD 2>/dev/null || printf '(none)\n'
      printf '```\n\n## 2. Uncommitted tracked changes\n\n```diff\n'
      in_project git diff --no-color 2>/dev/null || printf '(none)\n'
      printf '```\n\n## 3. Untracked files (full contents)\n\n'
      in_project git status --porcelain 2>/dev/null | grep '^??' | sed 's/^?? //' | while read -r f; do
        printf -- '--- %s\n```\n' "$f"
        cat "$PROJECT_DIR/$f" 2>/dev/null || printf '(unreadable)\n'
        printf '```\n'
      done
      printf '\n## 4. The phase REPORT.md\n\n'
      cat "$RBOPS_ROOT/phases/$phase/REPORT.md" 2>/dev/null || printf '(missing)\n'
    } > "$rctx"

    run_agent "$REVIEW_MODELS" "$LOG_DIR/$phase.review.$round.log" "$rctx" \
        --dir "$PROJECT_DIR" --agent reviewer --title "rbops-review-${phase}-${round}"

    local rc_round=$?
    if [ "$rc_round" = "75" ]; then
      log "review round $round: model chain unusable — deferring, no attempt consumed"
      return 42
    fi

    # Blocking findings present? The second clause is redundant-looking on
    # purpose: it catches a reviewer that emitted FINDINGS but no severity tags.
    if grep -qE '\[(BLOCKER|CRITICAL)\]' "$LOG_DIR/$phase.review.$round.log"; then
      log "review round $round found blocking findings — fixing"
    elif ! grep -qE '^\s*[0-9]+\.?\s*\[' "$LOG_DIR/$phase.review.$round.log"; then
      log "review round $round produced no structured findings — treating as clean"
      break
    else
      log "review round $round found non-blocking findings only"
      break
    fi

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
      return 42
    fi

    # --- re-gate after fixes. Mandatory. -----------------------------------
    log "re-running verify gate after review fixes"
    if RBOPS_PROJECT_DIR="$PROJECT_DIR" RBOPS_PHASES="$PHASES" RBOPS_BASE_REF="$base" "$VERIFY" "$phase"; then
      log "gate still green after fixes"
    else
      log "gate red after fixes — review loop continues"
    fi
  done

  if grep -qE '\[(BLOCKER|CRITICAL)\]' "$LOG_DIR/$phase.review.$round.log" 2>/dev/null; then
    touch "$(marker "$phase" .blocked)"
    log "$phase BLOCKED — blocking findings survive $round review round(s)"
    return 3
  fi

  touch "$(marker "$phase" .done)"
  in_project git push -q origin "HEAD:refs/heads/rbops-wip/DELETE_${phase}" 2>/dev/null || true
  in_project git push -q origin ":refs/heads/rbops-wip/$phase" 2>/dev/null || true
  log "$phase DONE"
  return 0
}

# ----------------------------------------------------------------------- audit
# The phase-generating loop. The auditor is the only writer of phases.json.
cmd_audit() {
  need_rbx
  mkdir -p "$LOG_DIR"
  if [ -z "${OPENCODE_API_KEY:-}" ]; then
    log "audit SKIPPED — OPENCODE_API_KEY is not set"; return 3
  fi
  log "audit pass — generating new phases from measured evidence"
  # The auditor needs to read the tree, so point it at the repo root rather than
  # rbops/, and hand it the contract rather than assuming it remembers.
  cat "$RBOPS_ROOT/AGENTS.md" > "$LOG_DIR/audit.ctx"
  {
    printf '\n\n---\n\n# AUDIT REQUEST\n\n'
    printf 'Follow .opencode/agent/auditor.md and AGENTS.md section 6.\n'
    printf 'The project under audit is the redblue checkout in this working directory.\n'
    printf 'MEASURE it, DIFF reality against SPEC.md / ROADMAP.md / README.md,\n'
    printf 'SAFETY-AUDIT this pipeline, then APPEND new phases to rbops/phases.json.\n'
    printf 'Every phase needs a real file:line. Do not invent work.\n'
  } >> "$LOG_DIR/audit.ctx"
  run_agent "$AUDIT_MODELS" "$LOG_DIR/audit.log" "$LOG_DIR/audit.ctx" \
      --dir "$PROJECT_DIR" --agent auditor --title "rbops-audit"
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

# ----------------------------------------------------------------------- tick
cmd_tick() {
  need_jq
  local phase; phase="$(cmd_select | tail -1)"
  [ -n "$phase" ] || { log "idle"; return 0; }

  local rc=0
  cmd_run "$phase"    || rc=$?
  case "$rc" in
    0)  cmd_review "$phase" || rc=$? ;;
    42) log "deferred — retrigger will retry" ;;
    3)  log "blocked — retrigger will surface it" ;;
    *)  log "run failed ($rc)" ;;
  esac

  # periodic audit
  local every; every="$( "$JQ" -r '.audit.every_n_phases' "$PHASES" 2>/dev/null || echo 8)"
  local done_n; done_n="$(ls -d "$PHASE_ROOT"/*/.done 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$((done_n % every))" -eq 0 ] && [ "$done_n" -gt 0 ]; then
    cmd_audit || log "audit failed"
  fi

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