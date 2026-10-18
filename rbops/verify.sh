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
# Every failure passes through here, so this is the one place a remedy can be
# attached to a check that does not know how to fix itself.
#
# Phase-092, 088 and 113 all failed the same two checks and burned three
# attempts each. The message said the rule and not the remedy, and a rule an
# agent cannot act on is not a gate - it is a wall. The retry note is supposed to
# close that gap, but a note is written by a human who has to notice, and three
# of these ran before anyone did.
#
# remedy_for prints the first line of advice for a message, keyed on a substring
# of it. It is a lookup rather than a per-check argument so that adding a check
# means adding a remedy rather than remembering to thread one through, and so
# the text lives in exactly one place and cannot drift from what it explains.
#
# When nothing matches, nothing is printed: a wrong remedy would send an agent
# chasing a problem it does not have, which is worse than the bare verdict it
# replaces.
remedy_for() {
  case "$1" in
    *"failure is produced"*)
      printf '          A suite of entirely passing tests does NOT satisfy this.\n'
      printf '          The check wants a test whose SUBJECT is a failure - a bad input\n'
      printf '          producing a clean error rather than a panic or a wrong value.\n'
      printf '          Rust:    let r = run_source(bad); assert!(r.is_err());\n'
      printf '          or:      #[should_panic] fn edge_...() { /* ... */ }\n'
      printf '          Redblue: try ... catch error ... end, asserting it was caught.\n'
      ;;
    *"REPORT.md missing"*)
      printf '          Writing REPORT.md is the whole fix; the code may already be right.\n'
      printf '          It needs sections: What changed / Tests added / Gates /\n'
      printf '          Known gaps, with real evidence rows. Report counts you observed.\n'
      ;;
    *"edge"*"test"*|*"no test named"*)
      printf '          At least one test must be named edge_* (fn edge_foo, or test "edge_foo").\n'
      printf '          The happy path alone is not a test.\n'
      ;;
    *"quota"*)
      printf '          AGENTS.md 3.3: at least 3 new #[test] (or 2 Redblue test blocks).\n'
      printf '          The count floor catches "no verification at all"; see it there.\n'
      ;;
    *"must_touch"*|*"no implementation change"*)
      printf '          must_touch names the areas the change must land in. At least one\n'
      printf '          changed file must fall under one of them, or this check fails on\n'
      printf '          exactly that. Editing only tests, or only docs, does not satisfy it.\n'
      ;;
    *"documentation block"*|*"bucket"*)
      printf '          A ```redblue block moved or was added, so tests/doc_blocks_runs.txt\n'
      printf '          still points at the old line. Update the registry entry to the new\n'
      printf '          line of the opening fence, or classify the block in\n'
      printf '          doc_blocks_fragments.txt / doc_blocks_known_fail.txt.\n'
      ;;
    *"README"*)
      printf '          README names a corpus count that has drifted. Count corpus/*.rb and\n'
      printf '          update the number in the same commit that adds or removes a program.\n'
      ;;
    *"clippy"*|*"fmt"*)
      printf '          Fix the reported diagnostic and re-run; do not widen the lint bound\n'
      printf '          and do not reformat files outside this phase.\n'
      ;;
  esac
}

bad()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1))
  remedy_for "$*"
}

# =============================================================================
# RBOPS_PREFLIGHT=1 — the cheap half of the gate.
#
# Everything here is a question about a DIFF or a DOCUMENT. Nothing here needs a
# build, a test run, or an example to execute. So it can be asked BEFORE the
# agent is dispatched, against whatever the phase inherits (its recovery branch,
# its WIP checkpoint, or nothing yet).
#
# Why this exists, in numbers: phases 037 and 048 each burned three ~5-hour runs
# and 24 agent-hours total, and both were correct work refused by a DETECTOR —
# first `eval_err`, then `label()`, neither of which the failure-assert regex
# recognised. The agent cannot fix that; only the gate can. Asking the same
# questions seconds earlier, before the model call, turns a 5-hour failure into
# a 5-second one.
#
# This mode deliberately does NOT reimplement any check. It runs the same
# functions below, so preflight and the real gate cannot drift into disagreeing
# about what a diff means. It only skips the expensive sections (3 and 4), and
# says so in its own verdict line, so a skipped section is never a silent pass.
# =============================================================================
PREFLIGHT="${RBOPS_PREFLIGHT:-0}"
preflight_skip() {
  [ "$PREFLIGHT" = "1" ] || return 1
  printf '\n\033[1m== %s\033[0m\n' "$*"
  printf '  \033[33mSKIP\033[0m %s — needs a build; preflight does not build\n' "$*"
  return 0
}

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
  # Under preflight a missing report is EXPECTED, not a defect: preflight runs
  # BEFORE the agent, so it is judging a tree nobody has written a report into
  # yet. Failing it there would refuse every retry of every phase, which is the
  # opposite of what an early warning is for. The report is still required by the
  # full gate, which runs after the agent. A report that EXISTS is checked in
  # full even under preflight — only its absence is tolerated.
  if [ "$PREFLIGHT" = "1" ]; then
    warn "no REPORT.md yet — expected under preflight (the agent has not run); the full gate requires one"
  else
    bad "$REPORT missing — a phase without a report cannot pass"
  fi
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
  # An empty diff means two different things. Under the full gate it means the
  # phase changed nothing, which is a failure — and correctly so. Under
  # PREFLIGHT it usually means the phase is on its FIRST attempt and has not
  # written anything yet: there is nothing to judge, not something to reject.
  # Failing it there would defer every new phase before the agent ever ran.
  if [ "$PREFLIGHT" = "1" ]; then
    printf '\n\033[33m╔══════════════════════════════════════╗\033[0m\n'
    printf '\033[33m║ PREFLIGHT NOTHING TO JUDGE — %s ║\033[0m\n' "$PHASE"
    printf '\033[33m╚══════════════════════════════════════╝\033[0m\n'
    exit 4
  fi
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
  | sed -n '1,20p'; then
  # NOTE: `| head -20` here would be a verdict-inverting bug, not a display
  # choice. head exits after 20 lines; with 21+ matches grep dies on SIGPIPE
  # (141), pipefail propagates it, and the `else` below reports a phase with
  # twenty-one violations as clean. sed consumes the whole stream instead.
  bad "gate-weakening construct added (#[ignore], // skip, allow(clippy::...)) — see AGENTS.md rule 2"
else
  ok "no gate-weakening constructs added"
fi

# 2b2. scratch and probe files must not land in the diff. phase-020 left
# tests/zz_probe.rs — a debugging scratch file — in the tree, and the gate only
# caught it incidentally via formatting. A formatted scratch file would have
# shipped.
#
# The comment here used to claim the patterns were "prefixes and junk
# extensions, not substrings", and the code said otherwise: `[^/]*probe[^/]*`
# was a substring match, so ANY filename containing "probe" was refused.
# Preflight caught it on its first real use — a legitimate
# `tests/preflight_probe.rs` was rejected as scratch, which is exactly the
# failure this rule exists to prevent, inverted. It is now anchored to the
# conventions that mean "scratch" and nothing else: the `zz_` prefix phase-020
# actually used, a `_scratch` suffix, and junk extensions. `probe_stub.rs`,
# `resumed_probe.rs` and `preflight_probe.rs` are real test files and pass;
# `zz_probe.rs`, `foo_scratch.rs` and `x.tmp` do not.
_scratch="$(printf '%s\n' "$CHANGED" | grep -iE '(^|/)zz_[^/]*$|(^|/)[^/]*_scratch\.[^/]*$|\.(tmp|bak|orig|swp)$|~$' || true)"
if [ -n "$_scratch" ]; then
  bad "scratch/probe files in the diff — remove them, they are not phase work: $(printf '%s' "$_scratch" | tr '\n' ' ' | head -c 300)"
else
  ok "no scratch files"
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
if preflight_skip "cargo fmt"; then
  :
else
step "cargo fmt"
if cargo fmt --all -- --check >/tmp/fmt.log 2>&1; then ok "cargo fmt --check"
else bad "cargo fmt --check"; tail -20 /tmp/fmt.log; fi

step "cargo clippy"
if cargo clippy --all-targets -- -D warnings >/tmp/clippy.log 2>&1; then
  ok "cargo clippy -D warnings"
else
  bad "cargo clippy"; grep -E '^(error|warning)' /tmp/clippy.log | sed -n '1,20p'
fi

step "cargo test"
if cargo test --all-targets >/tmp/test.log 2>&1; then
  PASSED="$(grep -oE '[0-9]+ passed' /tmp/test.log | awk '{s+=$1} END{print s+0}')"
  FAILED="$(grep -oE '[0-9]+ failed' /tmp/test.log | awk '{s+=$1} END{print s+0}')"
  if [ "${PASSED:-0}" -gt 0 ]; then ok "cargo test: ${PASSED} passed, ${FAILED:-0} failed"
  else bad "cargo test reported 0 passing tests — a suite that cannot fail is not a suite"; fi
else
  bad "cargo test"; grep -E 'FAILED|panicked|failures:' /tmp/test.log | sed -n '1,20p'
fi

step "doc tests"
cargo test --doc >/tmp/doctest.log 2>&1 || { bad "cargo test --doc"; tail -15 /tmp/doctest.log; }
fi

# --- 4. examples still run (the language's spec-by-example) ------------------
if preflight_skip "examples"; then
  :
else
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
# Some subsystems have no failure channel to assert on. A linter reports
# problems as a diagnostics collection; a formatter and an LSP produce documents,
# not errors. Requiring `is_err`/`should_panic` of them is a category error, and
# it is not hypothetical: phase-015 (formatter) and phase-016 (linter) were both
# blocked after burning every attempt on it, while phase-016's tests were
# asserting failure correctly as `assert_eq!(warnings.len(), 1, ...)`.
#
# Such a phase declares `failure_assert: "not_applicable"` and the check is
# SKIPPED, visibly — never silently passed, and never a global relaxation. The
# reviewer still judges whether the tests can actually fail, and every
# error-producing phase keeps the rule at full strength.
FAILASSERT_MODE="$("$JQ" -r --arg p "$PHASE" '.phases[] | select(.id==$p) | .failure_assert // "required"' "$PHASES" 2>/dev/null)" || FAILASSERT_MODE="required"
[ -n "$FAILASSERT_MODE" ] || FAILASSERT_MODE="required"

# Failure assertions per language. Rust has is_err/expect_err/should_panic;
# Redblue has no exceptions and instead has `try ... catch error`, which was
# missing here entirely — the one construct Redblue offers for asserting a fault.
# Anchored to the line start so a test whose *data* mentions `catch error` cannot
# buy a pass.
#
# Rust also has the `eval_err` idiom: a helper that evaluates a program
# expecting an error, followed by `assert!(matches!(e, Error::...))`. Phase-037
# blocked a 1200-green phase on this rule with 12 such assertions in the diff
# and zero recognized strings — `let e = eval_err("random_choice([])");
# assert!(matches!(e, Error::Runtime(_, _)))` asserts a failure is produced as
# surely as `is_err()` does. Same class as the #[test]-attribute fix (007) and
# the bilingual rules: the detector was narrower than the language's real
# failure-asserting idioms. The reviewer remains the ceiling — a bare
# `let _ = eval_err(x);` with no assertion is gaming, and it reads as gaming.
if [ "$FAILASSERT_MODE" = "not_applicable" ]; then
  # Skipped, and said out loud. A silent pass here would be indistinguishable
  # from the rule being satisfied.
  warn "failure-assertion rule NOT APPLICABLE to this phase (failure_assert: not_applicable) — the reviewer still judges whether the tests can fail"
else
  # Redblue's Error carries a label rather than a Result, so a test that proves
  # a failure was produced reads `assert_eq!(label(&e), "RuntimeError")` through
  # a local helper rather than calling is_err() on a Result. Phase-048 blocked on
  # this with ~10 such assertions (every one documented as "failure asserted" in
  # its REPORT) and zero recognized strings. Detecting the assertion is what
  # matters, not which method spells it, so the pattern also accepts a helper
  # call beside a spelled-out error label: a test cannot buy this by naming a
  # label in prose, because the label must be quoted inside the matched line.
  FAILASSERT="$(git diff -U0 "$BASE_REF" -- '*.rs' '*.rb' 2>/dev/null \
    | grep -cE '^\+.*(is_err|expect_err|should_panic|eval_err|assert_throws|expect_refusal|assert_stdout_contains|label\(.*\)\s*[,)]|label\(.*==)|Error::(Lexer|Parser|Analyzer|Runtime|Io)|expect .* to fail|^\+[[:space:]]*catch[[:space:]]+error')"
  if [ "$FAILASSERT" -ge 1 ]; then
    ok "failure-asserting test present: $FAILASSERT"
  else
    bad "no test asserts a failure is produced — mandatory (Rust: is_err()/should_panic; Redblue: try ... catch error)"
  fi
fi

TEST_POLICY_MODE="$("$JQ" -r --arg p "$PHASE" '.phases[] | select(.id==$p) | .test_policy // "required"' "$PHASES" 2>/dev/null)" || TEST_POLICY_MODE="required"
[ -n "$TEST_POLICY_MODE" ] || TEST_POLICY_MODE="required"
if [ "$TEST_POLICY_MODE" = "not_applicable" ]; then
  warn "test quota and edge_* rule NOT APPLICABLE to this phase (test_policy: not_applicable) — the reviewer still judges documentation and substance"
else
  if [ "$NEW_TESTS" -ge "$MIN_RS" ] || [ "$NEW_RB" -ge "$MIN_RB" ]; then
    ok "test quota met: ${NEW_TESTS} rust / ${NEW_RB} redblue (need ${MIN_RS} or ${MIN_RB})"
  else
    bad "test quota not met: ${NEW_TESTS} rust (need ${MIN_RS}) and ${NEW_RB} redblue (need ${MIN_RB}) — see AGENTS.md 3.3"
  fi
  [ "$EDGE" -ge 1 ] && ok "edge case test present: $EDGE" \
    || bad "no test named edge_* — mandatory (Rust: fn edge_foo(); Redblue: test \"edge_foo\")"
fi

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
if [ "$PREFLIGHT" = "1" ]; then
  # A preflight PASS is NOT a gate pass, and the exit code says so: 0 means "no
  # defect found in the cheap half", never "this phase may be marked .done". The
  # caller (dispatch.sh cmd_run) still runs the full gate after the agent. A
  # distinct exit code makes it impossible for a preflight to be mistaken for
  # the real thing by a caller that does not read this banner.
  if [ "$FAIL" -eq 0 ]; then
    printf '\033[33m╔══════════════════════════════════════╗\033[0m\n'
    printf '\033[33m║ PREFLIGHT CLEAN — %-19s ║\033[0m\n' "$PHASE"
    printf '\033[33m║ diff-based checks only; no build run ║\033[0m\n'
    printf '\033[33m╚══════════════════════════════════════╝\033[0m\n'
    exit 0
  fi
  printf '\033[31m╔══════════════════════════════════════╗\033[0m\n'
  printf '\033[31m║ PREFLIGHT FAIL   — %-19s ║\033[0m\n' "$PHASE"
  printf '\033[31m║ %d diff-based check(s) failed         ║\033[0m\n' "$FAIL"
  printf '\033[31m╚══════════════════════════════════════╝\033[0m\n'
  exit 3
fi
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