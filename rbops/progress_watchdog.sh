#!/usr/bin/env bash
# =============================================================================
# progress_watchdog.sh — end an attempt that has demonstrably produced nothing.
#
# Phase-053 spent a full 90-minute attempt reading src/repl/ and was killed at
# clippy with a 0-byte patch. Nothing about that failure was visible until the
# attempt had already spent everything it had. The counter fix bounded the
# consequences; this removes the waste.
#
# It is deliberately CONSERVATIVE and evidence-based, never time-guessing:
#
#   * It does not shorten any budget. A phase that writes early keeps its full
#     time; only an attempt with nothing to show is ended.
#   * It never fails a phase. The worst it can do is end an attempt, and it says
#     so out loud when it cannot tell. A watchdog that kills good work is worse
#     than none.
#   * It fires LATE — at WATCHDOG_FRACTION of the attempt budget, not on a timer
#     racing the agent — because the agent owns the workspace until it exits.
#
# Two shapes of wasted attempt are caught, because both cost full budgets here:
#
#   1. Nothing written at all. Phase-053.
#   2. Implementation written, no tests. Phase-082 shipped correct code with
#      1555 green tests and wrote NONE of its own, failing the gate's mandatory
#      quota three times over ~4.5 hours.
#
# Usage: progress_watchdog.sh <phase> <base_ref> <elapsed_seconds> <budget_seconds>
# Prints a verdict line. Exit 0 = leave it alone. Exit 10 = nothing to show,
# end the attempt.
# =============================================================================

set -uo pipefail

phase="${1:?phase required}"
base="${2:?base ref required}"
elapsed="${3:?elapsed seconds required}"
budget="${4:?budget seconds required}"

# --- configuration ----------------------------------------------------------
# Fire at 70% of the budget: late enough that a phase doing genuine work has
# written something, early enough that a dead attempt still returns minutes
# rather than the whole hour.
FRACTION="${RBOPS_WATCHDOG_FRACTION:-70}"
# Never fire before this, whatever the fraction says — a 90-second budget with a
# 70% fraction would fire at 63s, which is inside setup.
MIN_SECONDS="${RBOPS_WATCHDOG_MIN_SECONDS:-1200}"

[ "$budget" -le 0 ] 2>/dev/null && { echo "WATCHDOG: no budget set, staying out of it"; exit 0; }

threshold=$(( budget * FRACTION / 100 ))
[ "$threshold" -lt "$MIN_SECONDS" ] && threshold="$MIN_SECONDS"
[ "$elapsed" -lt "$threshold" ] && exit 0

# --- what has the attempt actually produced? -------------------------------
# Diffed against the attempt's OWN base, not against the worktree. A resumed
# attempt squashes its inherited work into a commit, so a clean worktree says
# "adopted", not "idle" — reading the tree that way defers every retry forever.
cd "${RBOPS_PROJECT_DIR:-$PWD}" 2>/dev/null || {
  echo "WATCHDOG: cannot read the project dir, staying out of it"; exit 0; }

touched="$(git diff --name-only "$base" 2>/dev/null | head -200)"
count=0
[ -n "$touched" ] && count=$(printf '%s\n' "$touched" | grep -c . || true)

# Nothing at all.
if [ "${count:-0}" -eq 0 ]; then
  echo "::error::$phase has written NOTHING after ${elapsed}s of ${budget}s (${FRACTION}% threshold) — ending this attempt rather than spending the rest of it"
  exit 10
fi

# --- shape 2: implementation with no tests ---------------------------------
# The gate's mandatory floor from AGENTS.md 3.3: >=3 new #[test] (or >=2
# Redblue test blocks), >=1 edge_*, and >=1 failure-asserting test. A phase can
# satisfy "implementation touched" with a single line and still write no
# verification at all, which is what 082 did.
added_tests="$(git diff --name-only "$base" -- 'tests/**' '*_test.rs' '*.rb' 2>/dev/null | head -50)"
n_tests=0
[ -n "$added_tests" ] && n_tests=$(printf '%s\n' "$added_tests" | grep -c . || true)

if [ "${n_tests:-0}" -eq 0 ]; then
  # Confirm there is real implementation to protect before ending anything: a
  # docs-only or config-only phase legitimately touches no test file.
  impl="$(git diff --name-only "$base" -- 'src/**' 2>/dev/null | head -20)"
  n_impl=0
  [ -n "$impl" ] && n_impl=$(printf '%s\n' "$impl" | grep -c . || true)
  if [ "${n_impl:-0}" -gt 0 ]; then
    echo "::error::$phase has changed src/ but written NO tests after ${elapsed}s of ${budget}s — the gate's mandatory quota will fail it, so ending this attempt rather than spending the rest of it"
    exit 10
  fi
  # No src and no tests: this is a documentation phase, which is legitimate.
  echo "WATCHDOG: $phase has touched ${count} file(s), none under src/ or tests/ — likely a docs phase, leaving it alone"
  exit 0
fi

echo "WATCHDOG: $phase has ${count} changed file(s) including ${n_tests} test file(s) — leaving it alone"
exit 0