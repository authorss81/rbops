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

PHASES="${RBOPS_PHASES:-rbops/phases.json}"
PHASE_ROOT="phases"
LOG_DIR="${RBOPS_LOG_DIR:-logs}"
VERIFY="./rbops/verify.sh"
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

need_jq() { command -v "$JQ" >/dev/null 2>&1 || die "jq is required (set JQ=/path/to/jq)"; }
need_rbx(){ command -v opencode >/dev/null 2>&1 || die "opencode CLI not on PATH"; }

# ---------------------------------------------------------------- phase state
marker() { printf 'phases/%s/%s' "$1" "$2"; }
has()    { [ -f "$(marker "$1" "$2")" ]; }
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
  if [ -f phases/.stop ]; then log "phases/.stop present — pipeline halted"; printf '\n'; return; fi

  # Portability: `tr -d '\r'` guards against a Windows jq.exe under WSL, whose
  # CRLF output would otherwise produce a phase id of "phase-001\r" and create a
  # directory with a carriage return in its name.
  local p
  # 1. resume a deferral
  p="$( "$JQ" -r '.phases[].id' "$PHASES" 2>/dev/null | tr -d '\r' \
       | while read -r id; do has "$id" .deferred && { echo "$id"; break; }; done)"
  if [ -n "$p" ]; then log "resuming deferred: $p"; printf '%s\n' "$p"; return; fi

  # 2. first phase in manifest order whose deps are satisfied
  p="$( "$JQ" -r '.phases[].id' "$PHASES" | tr -d '\r' | while read -r id; do
        has "$id" .done     && continue
        has "$id" .blocked  && continue
        has "$id" .starved  && continue
        local unmet=0 dep
        for dep in $( "$JQ" -r --arg p "$id" '.phases[]|select(.id==$p)|.depends_on[]?' "$PHASES" | tr -d '\r'); do
          has "$dep" .done || unmet=1
        done
        [ "$unmet" -eq 0 ] && { echo "$id"; break; }
      done)"
  if [ -n "$p" ]; then log "selected: $p"; printf '%s\n' "$p"; return; fi

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
run_agent() {
  local models="$1"; shift
  local logfile="$1"; shift
  : > "$logfile"
  local m code pre post growth IFS=,
  for m in $models; do
    m="$(printf '%s' "$m" | tr -d ' ')"
    [ -n "$m" ] || continue
    log "model → $m"
    pre="$(wc -c < "$logfile")"
    timeout "${RBOPS_MODEL_TIMEOUT:-3000}" opencode run --model "$m" "$@" >>"$logfile" 2>&1
    code=$?
    post="$(wc -c < "$logfile")"; growth=$((post-pre))
    [ "$code" -eq 0 ] && { log "model ok: $m"; return 0; }
    if infra_failure "$logfile" || [ "$growth" -lt 200 ]; then
      log "model unusable ($m, exit $code) — advancing chain"; continue
    fi
    log "model failed with a real work error ($m, exit $code) — keeping result"
    return "$code"
  done
  log "entire model chain unusable"; return 1
}

# Strict classifiers. The bare word "retry" must NOT match, or normal agent
# prose about retrying a build would falsely defer a phase.
infra_failure() {
  grep -qiE 'HTTP[ /]?(429|5[0-9][0-9])|too many requests|rate[ _-]?limit|insufficient[ _-]?quota|quota exceeded|model not found|unknown model|invalid model|no such model|overloaded|upstream error|ECONNRESET|ETIMEDOUT|stream.*(closed|failed)' "$1"
}

# Push work-in-progress every CHECKPOINT_SECS so a timeout or cancellation
# never loses a partial phase.
checkpoint_loop() {
  local phase="$1"
  while sleep "$CHECKPOINT_SECS"; do
    local tree commit
    tree="$(git add -A >/dev/null 2>&1; git write-tree 2>/dev/null)" || continue
    commit="$(git commit-tree "$tree" -p HEAD -m "rbops: ${phase} checkpoint $(date -u +%s)" 2>/dev/null)" || continue
    git push -f "origin" "$commit:refs/heads/rbops-wip/${phase}" >/dev/null 2>&1 || true
    git reset --mixed HEAD >/dev/null 2>&1 || true
  done
}

cmd_run() {
  local phase="${1:?phase required}"
  need_jq
  mkdir -p "$PHASE_ROOT/$phase" "$LOG_DIR"
  local prompt="$PHASE_ROOT/$phase/PROMPT.md"
  [ -f "$prompt" ] || die "no PROMPT.md for $phase — an undeclared prompt is not a phase"

  if has "$phase" .done; then log "$phase already .done"; return 0; fi
  if [ -f phases/.stop ]; then log "halted by phases/.stop"; return 0; fi

  # resume any WIP checkpoint from a previous timeout
  if git rev-parse --verify -q "origin/rbops-wip/$phase" >/dev/null 2>&1; then
    log "merging WIP checkpoint for $phase"
    git merge --no-edit -X theirs "origin/rbops-wip/$phase" >/dev/null 2>&1 || true
    touch "$(marker "$phase" .checkpoint)"
  fi

  local base; base="$(git rev-parse HEAD)"
  {
    cat AGENTS.md
    printf '\n\n---\n\n# YOUR PHASE: %s\n\n' "$phase"
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
  checkpoint_loop "$phase" & local cp=$!
  local code
  run_agent "$IMPL_MODELS" "$LOG_DIR/$phase.log" \
      --agent build --title "rbops-${phase}" < "$LOG_DIR/$phase.ctx"
  code=$?
  kill "$cp" 2>/dev/null; wait "$cp" 2>/dev/null

  # --- classify -------------------------------------------------------------
  if infra_failure "$LOG_DIR/$phase.log"; then
    bump "$phase" .deferred_attempts
    local d; d="$(read_n "$phase" .deferred_attempts)"
    if [ "$d" -ge "$MAX_DEFERRALS" ]; then
      touch "$(marker "$phase" .blocked)"; log "$phase BLOCKED after $d deferrals (infra)"
      return 3
    fi
    touch "$(marker "$phase" .deferred)"; log "$phase DEFERRED ($d/$MAX_DEFERRALS) — infra, retry next tick"
    return 42
  fi

  # --- THE GATE -------------------------------------------------------------
  log "running verify gate for $phase"
  RBOPS_BASE_REF="$base" "$VERIFY" "$phase"
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
  local base; base="$(git rev-parse HEAD)"
  local round=0

  while [ "$round" -lt "${RBOPS_MAX_REVIEW_ROUNDS:-3}" ]; do
    round=$((round+1))
    log "review round $round for $phase"

    run_agent "$REVIEW_MODELS" "$LOG_DIR/$phase.review.$round.log" \
        --agent reviewer "Review phase ${phase} (round ${round}). Diff base: ${base}. Emit numbered FINDINGS with severity. Blockers: fake completion, panics, unbounded resources, nondeterminism, weakened gates, spec drift, missing edge-case tests."

    if ! grep -qiE 'FINDINGS:[[:space:]]*(none|0)|FINDINGS:[[:space:]]*$' "$LOG_DIR/$phase.review.$round.log" \
       || grep -qE 'FINDINGS:' "$LOG_DIR/$phase.review.$round.log"; then
      if ! grep -qE '\[(BLOCKER|CRITICAL)\]' "$LOG_DIR/$phase.review.$round.log"; then
        log "no blocking findings — review clean"
        break
      fi
    else
      log "no blocking findings — review clean"
      break
    fi

    log "applying review fixes"
    run_agent "$IMPL_MODELS" "$LOG_DIR/$phase.fix.$round.log" \
        --agent build --continue \
        "Apply the review FINDINGS for phase ${phase} from the preceding review output. Fix every BLOCKER and CRITICAL. Do not weaken any gate, do not skip or ignore a test. Then re-run the four gates yourself."

    # --- re-gate after fixes. Mandatory. -----------------------------------
    log "re-running verify gate after review fixes"
    RBOPS_BASE_REF="$base" "$VERIFY" "$phase" || { log "gate red after fixes — review loop continues"; continue; }
  done

  if grep -qE '\[(BLOCKER|CRITICAL)\]' "$LOG_DIR/$phase.review.$round.log" 2>/dev/null; then
    touch "$(marker "$phase" .blocked)"
    log "$phase BLOCKED — blocking findings survive $round review round(s)"
    return 3
  fi

  touch "$(marker "$phase" .done)"
  git push -q origin "HEAD:refs/heads/rbops-wip/DELETE_${phase}" 2>/dev/null || true
  git push -q origin ":refs/heads/rbops-wip/$phase" 2>/dev/null || true
  log "$phase DONE"
  return 0
}

# ----------------------------------------------------------------------- audit
# The phase-generating loop. The auditor is the only writer of phases.json.
cmd_audit() {
  need_rbx
  mkdir -p "$LOG_DIR"
  log "audit pass — generating new phases from measured evidence"
  run_agent "$AUDIT_MODELS" "$LOG_DIR/audit.log" \
      --agent auditor \
      "Audit the redblue repository per .opencode/agent/auditor.md and AGENTS.md section 6. Measure, diff against SPEC.md and ROADMAP.md, and APPEND new phases to rbops/phases.json. Every phase needs file:line evidence. Do not invent work."
  local code=$?
  if "$JQ" empty "$PHASES" 2>/dev/null; then
    log "phases.json still valid JSON after audit"
  else
    log "FATAL: audit corrupted phases.json — reverting"
    git checkout -- "$PHASES"; return 1
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
  run)    shift; cmd_run "$@" ;;
  review) shift; cmd_review "$@" ;;
  audit)  cmd_audit ;;
  tick)   cmd_tick ;;
  stop)   mkdir -p phases; touch phases/.stop; log "HALTED — remove phases/.stop to resume" ;;
  resume) rm -f phases/.stop; log "RESUMED" ;;
  status) need_jq
          "$JQ" -r '.phases[].id' "$PHASES" | tr -d '\r' | while read -r id; do
            st="pending"
            for m in .done .failed .deferred .blocked; do has "$id" "$m" && st="${m#.}"; done
            printf '%-12s %-9s %-9s %s\n' "$id" \
              "$( "$JQ" -r --arg p "$id" '.phases[]|select(.id==$p)|.severity' "$PHASES")" "$st" \
              "$( "$JQ" -r --arg p "$id" '.phases[]|select(.id==$p)|.title' "$PHASES")"
          done ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac