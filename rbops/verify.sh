#!/usr/bin/env bash
# =============================================================================
# rbops/verify.sh — the ONLY authority on whether phase work is real.
#
# Exit 0  = phase may be marked .done
# Exit 1  = gate failed, phase must be retried
#
# Design rule: this script must be UNTRUSTWORTHY-PROOF against the agent.
# The implementer agent cannot edit this file (see AGENTS.md hard rule 1) and
# the token it runs under has no `workflows` scope, so a push that modifies
# .github/ is rejected by GitHub itself. Two independent locks.
# =============================================================================
set -uo pipefail

PHASE="${1:?usage: verify.sh <phase-id>}"

# Resolve every path BEFORE changing directory, and normalise away any `..`.
# The gate runs against the project checkout (redblue/) while the manifest,
# baseline and report live in the pipeline repo. A relative path resolved after
# `cd` silently points at a file that does not exist there, and the gate then
# fails on its very first check having verified nothing.
abspath() {
  local p="$1"
  if [ -e "$p" ]; then (cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd)" "$(basename "$p")")
  else printf '%s\n' "$p"; fi
}

# `cd && pwd` normalises away any `..`. RBOPS_ROOT is overridable so the gate can
# be exercised against a fixture pipeline root, not only this checkout.
RBOPS_ROOT="${RBOPS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PHASES="$(abspath "${RBOPS_PHASES:-$RBOPS_ROOT/rbops/phases.json}")"
BASELINE="$(abspath "${RBOPS_BASELINE:-$RBOPS_ROOT/rbops/baseline.json}")"
PROJECT_DIR="$(abspath "${RBOPS_PROJECT_DIR:-.}")"
REPORT="$RBOPS_ROOT/phases/$PHASE/REPORT.md"

# Preconditions, checked before we touch the project.
[ -f "$PHASES" ]                                    || { echo "FATAL: no manifest at $PHASES" >&2; exit 1; }
[ -f "$BASELINE" ]                                  || { echo "FATAL: no baseline at $BASELINE" >&2; exit 1; }
[ -d "$RBOPS_ROOT/phases/$PHASE" ]                  || { echo "FATAL: $RBOPS_ROOT/phases/$PHASE does not exist" >&2; exit 1; }
cd "$PROJECT_DIR" || { echo "FATAL: cannot enter project dir $PROJECT_DIR" >&2; exit 1; }
[ -f Cargo.toml ] || { echo "FATAL: no Cargo.toml in $PROJECT_DIR — is RBOPS_PROJECT_DIR correct?" >&2; exit 1; }

# Honour $JQ so a native Linux jq can be substituted when testing outside CI.
# A Windows jq.exe under WSL emits CRLF and breaks every id and count.
JQ="${JQ:-jq}"
BASE_REF="${RBOPS_BASE_REF:-HEAD}"

FAIL=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

# --- 0. integrity: is the phase even declared? ------------------------------
step "manifest"
if command -v "$JQ" >/dev/null 2>&1; then
  if "$JQ" -e --arg p "$PHASE" '.phases[] | select(.id==$p)' "$PHASES" >/dev/null 2>&1; then
    ok "phase $PHASE is declared in $PHASES"
  else
    bad "phase $PHASE is NOT declared in $PHASES — an undeclared phase cannot pass"
  fi
  # dependencies must be .done. Anchored to the pipeline root: this script cd's
  # into the project, so a relative phases/ path would resolve inside redblue/
  # and every satisfied dependency would read as missing — which is exactly how
  # a good phase-002 attempt once failed its own gate.
  while read -r dep; do
    [ -n "$dep" ] || continue
    if [ -f "$RBOPS_ROOT/phases/${dep}/.done" ]; then ok "dep ${dep} done"
    else bad "dep ${dep} not done"; fi
  done < <("$JQ" -r --arg p "$PHASE" '.phases[] | select(.id==$p) | .depends_on[]?' "$PHASES" 2>/dev/null)
else
  bad "jq not available — cannot validate manifest"
fi

# --- 1. report exists and is not a stub -------------------------------------
step "report"
if [ -f "$REPORT" ]; then
  ok "$REPORT exists"
  # every required section must be present AND non-trivially filled
  for sec in "What changed" "Tests added" "Gates" "Known gaps"; do
    if grep -qF "$sec" "$REPORT"; then ok "section: $sec"
    else bad "report missing section: $sec"; fi
  done
  # The evidence table must contain at least one real data row: a markdown row
  # that names a path. A header-only or placeholder table is a stub.
  if awk '
    /^##[[:space:]]+What changed/ { insec=1; next }
    /^##[[:space:]]/           { insec=0 }
    insec && /^\|/ && /\// && !/^\|[[:space:]]*-+/ && !/^\|[[:space:]]*File[[:space:]]*\|/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$REPORT"; then ok "report has at least one real evidence row"
  else bad "report evidence table is a stub — needs a row naming an actual file"; fi
  # a report claiming a green gate it cannot have run
  if grep -qiE 'cargo test *\| *(pass|green)' "$REPORT" && ! grep -qE '[1-9][0-9]* passed' "$REPORT"; then
    bad "report claims cargo test passed but records no passing count"
  fi
else
  bad "$REPORT missing — a phase without a report cannot pass"
fi

# --- 2. diff hygiene ---------------------------------------------------------
step "diff hygiene"

# STAGE NEW FILES, then diff. `git diff <base>` compares the base tree to the
# working tree for TRACKED paths only — a brand-new file the agent wrote is
# untracked, and untracked files are invisible to it. Writing a new test file is
# the single most natural thing a phase does, and the gate was scoring those
# phases as if no test existed: phase-007 wrote 355 lines and 16 #[test]
# functions in tests/numeric_edge_test.rs and the gate reported "0 rust".
#
# `git add -N` (intent-to-add), deliberately NOT `git add -A`: it records the
# path in the index with no content, so the file becomes visible to the diff,
# while modifications to already-tracked files stay unstaged. That matters
# because `git checkout -- <path>` restores from the INDEX, so staging
# tracked edits would silently break every restore-from-HEAD in the pipeline.
git add -N . >/dev/null 2>&1 || true

CHANGED="$(git diff --name-only "$BASE_REF" 2>/dev/null)"
if [ -z "$CHANGED" ]; then
  bad "no changed files detected against $BASE_REF"
fi

# 2a. forbidden paths (the lock that makes this gate trustworthy)
while read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    .github/workflows/*|rbops/*|.opencode/agent/*)
      bad "forbidden path touched: $f" ;;
  esac
done <<< "$CHANGED"
ok "forbidden-path scan done"

# 2b. forbidden diff patterns = gate weakening.
#
# The attribute must be at the START of an added line, which is how Rust
# attributes actually appear. Matching `#[ignore]` anywhere in the line
# produced a false positive: a test that asserts the linter rejects
# `#[ignore]` contains that token inside a string literal, and the gate
# blocked a phase for containing the word it was testing against.
if git diff -U0 "$BASE_REF" -- '*.rs' 2>/dev/null \
   | grep -nE '^\+[[:space:]]*(#\[ignore|#\[allow\((clippy|dead_code)|//[[:space:]]*skip\b)' \
   | head -20; then
  bad "gate-weakening construct added (#[ignore], // skip, allow(clippy::...)) — see AGENTS.md rule 2"
else
  ok "no gate-weakening constructs added"
fi

# 2c. minimum substance
# NOTE ON QUOTING: these read `"$JQ"`, never `'"$JQ"'`. The latter is a
# single-quoted string CONTAINING the literal characters "$JQ" — bash does not
# expand it, so the command ran as a program named `"$JQ"`, failed, and the
# `|| echo N` fallback silently supplied the default. Every one of these reads
# had been dead since the gate was written: min_changed_lines and BOTH test
# quota floors came from the fallback, not the manifest. They matched by luck.
# A wrong fallback also hid the failure completely, so each now warns.
MIN_LINES="$("$JQ" -r '.gate.min_changed_lines' "$PHASES" 2>/dev/null)" || MIN_LINES=""
if [ -z "$MIN_LINES" ]; then warn "could not read .gate.min_changed_lines from the manifest; using 5"; MIN_LINES=5; fi
ADDED="$(git diff --numstat "$BASE_REF" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
DELETED="$(git diff --numstat "$BASE_REF" 2>/dev/null | awk '{s+=$2} END{print s+0}')"
if [ "$ADDED" -ge "$MIN_LINES" ]; then ok "diff substance: +${ADDED} -${DELETED} (min +${MIN_LINES})"
else bad "diff too small: +${ADDED} (min +${MIN_LINES})"; fi

# 2d. must_touch: the phase must IMPLEMENT, not only test.
#
# Every other rule here measures verification. None of them measures ambition, so
# the cheapest way to pass was to write tests for behaviour that already existed
# and touch no implementation at all. Phase-004 did exactly that: its goal was
# preserving insertion order in src/value.rs and it landed 19 lines of src/ and
# 532 of tests. A gate that cannot tell the difference will happily keep buying
# that.
#
# This is a FLOOR, not a judgement of substance — one line under src/ satisfies
# it. Judging whether the change is big enough, correct, or complete is the
# reviewer's job (AGENTS.md 5). What it removes is the tests-only escape hatch.
#
# It is per-phase and opt-in: a phase whose real work IS tests (phase-020, the
# differential harness) declares tests/, and a phase with no must_touch is not
# constrained at all. Several acceptable areas may be listed; touching ANY one
# satisfies the phase, because which of them is correct depends on the finding.
MUST_TOUCH="$("$JQ" -r --arg p "$PHASE" '[.phases[] | select(.id==$p) | (.must_touch // [])[]] | join(" ")' "$PHASES" 2>/dev/null)" || MUST_TOUCH=""
if [ -n "${MUST_TOUCH// /}" ]; then
  _hit=""
  for _pat in $MUST_TOUCH; do
    if printf '%s\n' "$CHANGED" | grep -q "^$_pat"; then _hit="$_pat"; break; fi
  done
  if [ -n "$_hit" ]; then
    ok "implementation touched ${_hit} (must_touch: ${MUST_TOUCH})"
  else
    bad "no implementation change — must_touch requires a change under one of: ${MUST_TOUCH} — see AGENTS.md 3.5"
  fi
else
  ok "no must_touch declared (nothing to enforce)"
fi

# --- 3. the four gates -------------------------------------------------------
step "cargo fmt"
if cargo fmt --all -- --check >/tmp/fmt.log 2>&1; then ok "cargo fmt --check"
else bad "cargo fmt --check"; tail -20 /tmp/fmt.log; fi

step "cargo clippy"
if cargo clippy --all-targets -- -D warnings >/tmp/clippy.log 2>&1; then
  ok "cargo clippy -D warnings"
else
  bad "cargo clippy"; grep -E '^(error|warning)' /tmp/clippy.log | head -20
fi

step "cargo test"
if cargo test --all-targets >/tmp/test.log 2>&1; then
  PASSED="$(grep -oE '[0-9]+ passed' /tmp/test.log | awk '{s+=$1} END{print s+0}')"
  FAILED="$(grep -oE '[0-9]+ failed' /tmp/test.log | awk '{s+=$1} END{print s+0}')"
  if [ "${PASSED:-0}" -gt 0 ]; then ok "cargo test: ${PASSED} passed, ${FAILED:-0} failed"
  else bad "cargo test reported 0 passing tests — a suite that cannot fail is not a suite"; fi
else
  bad "cargo test"; grep -E 'FAILED|panicked|failures:' /tmp/test.log | head -20
fi

step "doc tests"
cargo test --doc >/tmp/doctest.log 2>&1 || { bad "cargo test --doc"; tail -15 /tmp/doctest.log; }

# --- 4. examples still run (the language's spec-by-example) ------------------
step "examples"
# Do not hide why the build failed: an unbuilt binary used to surface as the
# useless "rb binary not built".
if ! cargo build >/tmp/build.log 2>&1; then
  bad "cargo build"; tail -20 /tmp/build.log
fi
RB="./target/debug/rb"
if [ -x "$RB" ]; then
  for ex in examples/*.rb modules/*.rb; do
    [ -f "$ex" ] || continue
    if timeout 60 "$RB" run "$ex" >/dev/null 2>&1; then
      ok "runs: $ex"
      continue
    fi
    detail="$(timeout 60 "$RB" run "$ex" 2>&1 | tail -1)"
    # Was this failure already known at bootstrap time?
    known="$("$JQ" -r --arg p "$ex" \
              '.unparseable[]? | select(.path == $p) | .path' "$BASELINE" 2>/dev/null | head -1)"
    if [ -n "$known" ]; then
      # Rule 1: touching a baselined file revokes the exemption. A phase cannot
      # edit a broken file and keep calling it "pre-existing".
      if printf '%s\n' "$CHANGED" | grep -qxF -- "$ex"; then
        bad "example still fails AND this phase touched it (baseline revoked): $ex — $detail"
      else
        warn "pre-existing failure, baselined, not touched by this phase: $ex — $detail"
      fi
    else
      bad "example fails: $ex — $detail"
    fi
  done
  ok "example sweep done"
else
  bad "rb binary missing at $RB after a successful build — check [[bin]] name in Cargo.toml"
fi

# --- 5. test policy: edge cases and failure assertions are mandatory ---------
step "test policy"
# The quota is disjunctive, matching AGENTS.md 3.3: a phase qualifies with
# >=3 Rust tests OR >=2 Redblue tests. This is deliberately a low floor, not a
# target — it catches "no verification at all", and sufficiency beyond it is
# the reviewer's call. A high count once failed a good 5-test phase.
MIN_RS="$("$JQ" -r '.test_policy.min_rust_tests' "$PHASES" 2>/dev/null)" || MIN_RS=""
if [ -z "$MIN_RS" ]; then warn "could not read .test_policy.min_rust_tests; using 3"; MIN_RS=3; fi
MIN_RB="$("$JQ" -r '.test_policy.min_redblue_tests' "$PHASES" 2>/dev/null)" || MIN_RB=""
if [ -z "$MIN_RB" ]; then warn "could not read .test_policy.min_redblue_tests; using 2"; MIN_RB=2; fi
# Count the `#[test]` ATTRIBUTE, not a name prefix. Requiring `fn test_`/`fn
# edge_` meant a test named `modulo_by_zero_is_a_runtime_error` — perfectly
# clear, perfectly real — did not count toward the quota. phase-007 wrote 16
# #[test] functions and the quota read 0 because only the 6 edge_-prefixed ones
# matched. The prefix belongs to the edge_-naming rule below, which enforces it
# deliberately; the quota should be counting tests.
NEW_TESTS="$(git diff -U0 "$BASE_REF" -- '*.rs' 2>/dev/null | grep -cE '^\+\s*#\[test\]' )"
NEW_RB="$(git diff -U0 "$BASE_REF" -- '*.rb' 2>/dev/null | grep -cE '^\+\s*test ' )"
# Both idioms must be recognised, in BOTH target languages. The quota above is
# disjunctive (Rust OR Redblue), so these two rules have to be too — otherwise a
# Redblue-only phase can satisfy the quota and still be told it proved nothing.
#   Rust:    fn edge_empty_list()          Redblue:  test "edge_empty list"
# The optional quote is the whole bug: a Redblue test name is a string literal,
# so `test edge_x` never occurs, and the unquoted-only regex rejected 61 real
# tests in phase-003 including correctly-named ones.
EDGE="$(git diff -U0 "$BASE_REF" -- '*.rs' '*.rb' 2>/dev/null | grep -cE '^\+.*(fn |test +"?)edge_')"
# Failure assertions per language. Rust has is_err/should_panic; Redblue has no
# exceptions and instead has `try ... catch error`, which was missing here
# entirely — the one construct Redblue offers for asserting a fault. Anchored to
# the line start so a test whose *data* mentions `catch error` cannot buy a pass.
FAILASSERT="$(git diff -U0 "$BASE_REF" -- '*.rs' '*.rb' 2>/dev/null \
  | grep -cE '^\+.*(is_err|expect_err|should_panic|expect .* to fail|assert_throws)|^\+[[:space:]]*catch[[:space:]]+error')"

if [ "$NEW_TESTS" -ge "$MIN_RS" ] || [ "$NEW_RB" -ge "$MIN_RB" ]; then
  ok "test quota met: ${NEW_TESTS} rust / ${NEW_RB} redblue (need ${MIN_RS} or ${MIN_RB})"
else
  bad "test quota not met: ${NEW_TESTS} rust (need ${MIN_RS}) and ${NEW_RB} redblue (need ${MIN_RB}) — see AGENTS.md 3.3"
fi
[ "$EDGE" -ge 1 ] && ok "edge case test present: $EDGE" \
  || bad "no test named edge_* — mandatory (Rust: fn edge_foo(); Redblue: test \"edge_foo\")"
[ "$FAILASSERT" -ge 1 ] && ok "failure-asserting test present: $FAILASSERT" \
  || bad "no test asserts a failure is produced — mandatory (Rust: is_err()/should_panic; Redblue: try ... catch error)"

# Same precision rule as the construct scan above: the token must begin the
# line. A test fixture that embeds `#[ignore]` as data is not a skipped test.
SKIPDELTA="$(git diff -U0 "$BASE_REF" -- '*.rs' '*.rb' 2>/dev/null \
  | grep -cE '^\+[[:space:]]*(#\[ignore|//[[:space:]]*skip\b)')"
[ "$SKIPDELTA" -eq 0 ] && ok "no newly skipped tests" || bad "$SKIPDELTA newly skipped/ignored tests"

# --- 6. self-consistency: does the report match reality? --------------------
step "report honesty"
if [ -f "$REPORT" ] && [ -f /tmp/test.log ]; then
  REAL="$(grep -oE '[0-9]+ passed' /tmp/test.log | awk '{s+=$1} END{print s+0}')"
  CLAIM="$(grep -oE '[0-9]+ passed' "$REPORT" | head -1 | awk '{print $1}')"
  if [ -n "${CLAIM:-}" ]; then
    # Asymmetric by design. The threat model is FABRICATION: claiming green
    # that was never earned. A claim ABOVE reality (+2 tolerance for reruns)
    # fails the phase. A claim BELOW reality is sloppiness in prose, not a lie
    # that ships bad code — the gate itself measured the real number, so warn
    # and move on. This distinction once blocked a phase with 59 green tests
    # over a "0 passing" typo.
    if [ "$CLAIM" -gt $((REAL + 2)) ]; then
      bad "report claims $CLAIM passing, actual run has $REAL — over-claiming is fabrication"
    elif [ "$CLAIM" -lt $((REAL - 2)) ]; then
      warn "report claims $CLAIM passing, actual run has $REAL — under-claimed, fix the number"
      ok "reported test count ($CLAIM) does not exceed actual ($REAL)"
    else
      ok "reported test count ($CLAIM) matches actual ($REAL)"
    fi
  fi
fi

# --- verdict -----------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m╔══════════════════════════════════════╗\033[0m\n'
  printf '\033[32m║ VERIFY PASS — %-24s ║\033[0m\n' "$PHASE"
  printf '\033[32m╚══════════════════════════════════════╝\033[0m\n'
  exit 0
fi
printf '\033[31m╔══════════════════════════════════════╗\033[0m\n'
printf '\033[31m║ VERIFY FAIL — %-24s ║\033[0m\n' "$PHASE"
printf '\033[31m║ %d check(s) failed                    ║\033[0m\n' "$FAIL"
printf '\033[31m╚══════════════════════════════════════╝\033[0m\n'
exit 1