#!/usr/bin/env bash
# =============================================================================
# rbops/smoke.sh — exercise the ENTIRE pipeline shape in about three minutes
# with no model calls and no real cargo build.
#
# WHY THIS EXISTS
# Five wiring bugs cost a full day, and every one of them was only observable
# inside a 20-minute agent loop on a GitHub runner: a prompt piped on stdin that
# `opencode run` never reads, an agent pointed at the wrong checkout, a "gate"
# variable that re-ran the dispatcher, a use-before-assignment under `set -u`,
# and a clone with no push credentials. Each was found by reading CI logs twenty
# minutes apart.
#
# The gate itself was never wrong. The orchestration was. So the orchestration
# gets tested the way the gate is: directly, cheaply, and on every push.
#
# This substitutes a stub `opencode` (writes a real report, touches a real file),
# a stub `cargo` and a stub `rb`, then drives dispatch.sh through run, review,
# select, status, tick, stop and resume, asserting the marker state after each.
# A wiring regression fails here in three minutes instead of in twenty.
# =============================================================================
set -uo pipefail

JQ="${JQ:-jq}"
PASS=0; FAIL=0
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'

ok()  { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GREEN" "$OFF" "$*"; }
no()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$*"; }
head_() { printf '\n%s== %s%s\n' "$DIM" "$*" "$OFF"; }
check() { if [ "$1" = "$2" ]; then ok "$3 (= $2)"; else no "$3: expected '$2', got '$1'"; fi; }

RBOPS_ROOT="${RBOPS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PIPE="$T/pipeline"      # stands in for the rbops repo
PROJ="$T/project"       # stands in for the redblue checkout
STUB="$T/stub"

# ---------------------------------------------------------------- fixture repo
build_fixture() {
  rm -rf "$PIPE" "$PROJ" "$STUB"
  mkdir -p "$PIPE" "$PROJ" "$STUB"
  cp -R "$RBOPS_ROOT/rbops" "$PIPE/rbops"
  cp -R "$RBOPS_ROOT/phases" "$PIPE/phases"
  cp "$RBOPS_ROOT/AGENTS.md" "$PIPE/AGENTS.md"
  chmod +x "$PIPE"/rbops/*.sh
  # The real phases/ directory carries committed state markers. A smoke test must
  # start from a clean queue or it silently inherits a satisfied phase-001.
  find "$PIPE/phases" -name '.*' -type f -delete 2>/dev/null || true
  rm -f "$PIPE/phases/.stop" 2>/dev/null || true

  mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/examples" "$PROJ/modules" "$PROJ/target/debug"
  printf '[package]\nname="redblue"\nversion="0.1.0"\nedition="2021"\n' > "$PROJ/Cargo.toml"
  : > "$PROJ/src/lib.rs"
  : > "$PROJ/examples/hello.rb"
  : > "$PROJ/modules/MathUtils.rb"
  printf 'fn placeholder() {}\n' > "$PROJ/src/vm.rs"

  for d in "$PIPE" "$PROJ"; do
    ( cd "$d" && git init -q -b main . \
      && git -c user.email=t@t -c user.name=t add -A \
      && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
  done
}

# ---------------------------------------------------------------- stub toolchain
_stubs_raw() {
  # opencode: writes a conforming REPORT.md plus real tests into its own cwd,
  # exactly as a successful agent would. --dir is honoured so we can assert the
  # agent was pointed at the project.
  cat > "$STUB/opencode" <<'EOS'
#!/usr/bin/env bash
dir="."; msg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --model|--agent|--title) shift 2 ;;
    *) msg="$1"; shift ;;
  esac
done
printf '%s' "$msg" > "$(dirname "$0")/../last-prompt.txt"
case "$msg" in
  *"Review phase"*|*"Review request"*)
      echo "FINDINGS: none" ;;
  *)
      mkdir -p "$dir/phases/$PHASE_UNDER_TEST"
      cat > "$dir/phases/$PHASE_UNDER_TEST/REPORT.md" <<'RPT'
# Phase report

## What changed
| File | Lines | What |
|---|---|---|
| src/testing/harness.rs | +40 -12 | evaluate Expect |

## Tests added
| Test | Edge class covered |
|---|---|
| edge_expect_mismatch | failure |

## Gates
| Gate | Result |
|---|---|
| cargo test | 12 passed, 0 failed |

## Known gaps / follow-ups
- none
RPT
      cat >> "$dir/src/vm.rs" <<'TST'

fn edge_empty() { assert!(true); }
fn test_a() { assert!(true); }
fn test_b() { assert!(true); }
fn test_c() { assert!(true); }
fn test_d() { assert!(true); }
fn test_e() { let r: Result<(),()> = Err(()); assert!(r.is_err()); }
TST
      echo "agent wrote a report and 6 tests into $dir" ;;
esac
echo "padding to satisfy the minimum-output check ......................."
echo "padding ................................................................"
EOS
  chmod +x "$STUB/opencode"

  cat > "$STUB/cargo" <<'EOS'
#!/usr/bin/env bash
sub=""
for a in "$@"; do case "$a" in fmt|clippy|test|build|check) sub="$a"; break;; esac; done
case " $STUB_FAIL " in *" $sub "*) echo "error: stub $sub" >&2; exit 101;; esac
case "$sub" in
  test) echo "test result: ok. 12 passed; 0 failed; 0 ignored" ;;
esac
exit 0
EOS
  chmod +x "$STUB/cargo"

  cat > "$STUB/rb" <<'EOS'
#!/usr/bin/env bash
for f in $FAILING_FILES; do
  case "$1$2" in *"$f"*) echo "Error: ParserError: Expected function name"; exit 1;; esac
done
exit 0
EOS
  chmod +x "$STUB/rb"
  cp "$STUB/rb" "$PROJ/target/debug/rb"; chmod +x "$PROJ/target/debug/rb"
}

# Rebuild the stubs AND prove the suite is hermetic: every tool the pipeline can
# invoke must resolve to $STUB, not to whatever happens to exist on the host.
# Without this, a host opencode masks a missing stub locally and the suite passes
# here while failing on a runner that has no opencode installed — which is
# exactly how a CI-only failure once survived review.
use_stubs() {
  _stubs_raw
  local t got bad=0
  for t in opencode cargo rb; do
    got="$(PATH="$STUB:$PATH" command -v "$t")"
    if [ "$got" != "$STUB/$t" ]; then
      no "HERMETICITY BREAK: $t resolves to $got, not $STUB/$t"
      bad=1
    fi
  done
  return "$bad"
}

# run <args...>  — invoke dispatch.sh against the fixture.
# RBOPS_MIN_OUTPUT is the threshold below which a model's output is treated as a
# silent no-op. It is lowered here so the terse stub agent counts as success,
# and RAISED for the dead-model test so a stub that emits a short error is
# correctly classified as unusable. Getting this wrong makes the dead-chain test
# pass for the wrong reason.
D() { ( cd "$PIPE" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" \
         PATH="$STUB:$PATH" OPENCODE_API_KEY=stub JQ="$JQ" \
         RBOPS_LOCK="$T/lock" \
         PHASE_UNDER_TEST="${2:-phase-001}" \
         RBOPS_MIN_OUTPUT="${RBOPS_MIN_OUTPUT:-10}" RBOPS_MAX_REVIEW_ROUNDS=1 \
         timeout 120 bash "$PIPE/rbops/dispatch.sh" "$@" 2>&1 ); }
marker() { [ -f "$PIPE/phases/$1/$2" ]; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# Build the fixture once up front. Forgetting this is exactly how the first
# version of this script reported eighteen failures that were all "no such
# directory".
build_fixture >/dev/null; use_stubs

# =========================================================== 1. cold start
head_ "1. cold start under set -u (the use-before-assignment class)"
out="$(D status)"; rc=$?
check "$rc" 0 "dispatch.sh status exits 0"
case "$out" in *"unbound variable"*) no "no unbound variable: $out" ;; *) ok "no unbound variable" ;; esac
out="$(D select)"; rc=$?
[ "$rc" -eq 0 ] && ok "dispatch.sh select exits 0" || no "select exited $rc"

# =========================================================== 2. paths
head_ "2. gate resolves the manifest from the pipeline, cargo from the project"
out="$( cd / && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" JQ="$JQ" \
        bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip )"
case "$out" in
  *"no manifest at rbops/phases.json"*) no "manifest resolved relatively" ;;
  *"is declared in $PIPE/rbops/phases.json"*) ok "manifest resolved to the pipeline root" ;;
  *) no "unexpected manifest resolution"; printf '%s\n' "$out" | head -4 | sed 's/^/      /' ;;
esac
case "$out" in
  *"rb binary missing at"*|*"cannot enter project dir"*) no "project dir wrong" ;;
  *) ok "project dir accepted" ;;
esac

# =========================================================== 3. run + gate
head_ "3. run: agent is pointed at the project, report is harvested, gate passes"
rm -f "$PIPE/phases/phase-001"/.[a-z]* 2>/dev/null
out="$(D run phase-001 | strip)"
case "$out" in
  *"model ok"*) ok "a model produced usable output" ;;
  *) no "no model succeeded"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /' ;;
esac
case "$out" in
  *"harvested REPORT.md"*) ok "REPORT.md harvested out of the project" ;;
  *) no "REPORT.md was not harvested" ;;
esac
# The agent's edits must be in the PROJECT, not the pipeline.
if grep -q 'edge_empty' "$PROJ/src/vm.rs" 2>/dev/null; then
  ok "the agent's edits landed in the project checkout"
else
  no "agent edits are not in the project"
fi
if grep -rq 'evaluate Expect' "$PROJ/phases/phase-001/REPORT.md" 2>/dev/null; then
  ok "the agent's report is in the project, and was harvested from there"
else
  no "no agent report in the project"
fi
# A green gate must NOT be enough: .done waits for the reviewer.
marker phase-001 .done && no ".done written before review" || ok ".done NOT written before review"

# Assert the prompt actually reached the agent, and that --dir pointed it at the
# project. This is the check that would have caught bug 2 (agent in the wrong
# checkout) in three minutes instead of twenty.
if [ -s "$STUB/../last-prompt.txt" ]; then
  if grep -q 'DO THIS, NOW' "$STUB/../last-prompt.txt"; then
    ok "the phase brief was delivered to the agent"
  else
    no "the agent never received the brief"
  fi
else
  no "the agent was never invoked"
fi

# =========================================================== 4. gate discrimination
head_ "4. the gate still rejects real gate-weakening"
( cd "$PROJ" && printf '\n#[ignore]\nfn skipped_by_the_agent() {}\n' >> src/vm.rs )
out="$( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 )"
case "$out" in
  *"gate-weakening construct added"*) ok "a real #[ignore] is rejected" ;;
  *) no "a real #[ignore] slipped through" ;;
esac
case "$out" in
  *"newly skipped/ignored tests"*) ok "skip counter fired" ;;
  *) no "skip counter did not fire" ;;
esac
( cd "$PROJ" && git checkout -- src/vm.rs )

head_ "5. the gate does NOT flag a string literal that mentions #[ignore]"
( cd "$PROJ" && printf '\nfn mentions_token() { let s = "#[ignore]"; let _ = s; }\n' >> src/vm.rs )
out="$( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 )"
case "$out" in
  *"gate-weakening construct added"*) no "false positive: string literal flagged" ;;
  *) ok "string literal not flagged" ;;
esac
( cd "$PROJ" && git checkout -- src/vm.rs )

# =========================================================== 6. baseline
head_ "6. baseline distinguishes pre-existing breakage from a regression"
out="$( cd "$PROJ" && FAILING_FILES="modules/MathUtils.rb" RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" \
        PATH="$STUB:$PATH" JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 )"
case "$out" in
  *"pre-existing failure, baselined"*) ok "baselined breakage is a warning" ;;
  *) no "baselined breakage not reported as a warning" ;;
esac
out="$( cd "$PROJ" && FAILING_FILES="examples/hello.rb" RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" \
        PATH="$STUB:$PATH" JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 )"
case "$out" in
  *"example fails: examples/hello.rb"*) ok "a NEW break is a failure" ;;
  *) no "a new break was not caught" ;;
esac
out="$( cd "$PROJ" && FAILING_FILES="modules/MathUtils.rb" RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" \
        PATH="$STUB:$PATH" JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 )"
case "$out" in
  *"no newly skipped/ignored tests"*) : ;;
esac

# =========================================================== 7. dead model chain
head_ "7. a dead model chain defers WITHOUT consuming an attempt"
build_fixture >/dev/null; use_stubs
cat > "$STUB/opencode" <<'EOS'
#!/usr/bin/env bash
echo "Error: OpenCode 1.18.0 or newer is required to use the free tier"
exit 0
EOS
chmod +x "$STUB/opencode"
# RBOPS_MIN_OUTPUT must be back at a realistic value, or the 90-byte error is
# accepted as a successful run and the gate fails instead of deferring.
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"; rc=$?
check "$rc" 42 "exit code is 42 (deferred)"
marker phase-001 .deferred && ok ".deferred written" || no ".deferred missing"
marker phase-001 .attempts && no "an attempt was consumed" || ok "no attempt consumed"
marker phase-001 .blocked  && no "blocked on first infra failure" || ok "not blocked"

# deferral cap
for _ in 1 2 3 4 5; do RBOPS_MIN_OUTPUT=500 D run phase-001 >/dev/null; done
marker phase-001 .blocked && ok "blocks after MAX_DEFERRALS" || no "never blocked"
marker phase-001 .attempts && no "attempts consumed while deferring" || ok "still zero attempts"
use_stubs
# =========================================================== 8. missing key
head_ "8. a missing API key blocks instead of burning the queue"
# build_fixture removes $STUB, so the toolchain must be rebuilt or this section
# depends on whatever opencode happens to exist on the host. That is how the
# first CI run failed with 'FATAL opencode CLI not on PATH' while passing
# locally: the runner has no opencode, my machine does.
build_fixture >/dev/null; use_stubs
out="$( cd "$PIPE" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" RBOPS_LOCK="$T/lock" \
        env -u OPENCODE_API_KEY timeout 60 bash "$PIPE/rbops/dispatch.sh" run phase-001 2>&1 | strip )"
rc=${PIPESTATUS[0]}
if [ "$rc" = "3" ]; then ok "exit code is 3 (blocked)"
else no "exit code is 3 (blocked): got '$rc'"; printf '%s\n' "$out" | tail -6 | sed 's/^/      /'; fi
marker phase-001 .blocked && ok ".blocked written" || no ".blocked missing"
case "$out" in *"OPENCODE_API_KEY is not set"*) ok "the reason is stated" ;; *) no "no reason given" ;; esac

# =========================================================== 9. review + done
head_ "9. review signs off and only then is .done written"
build_fixture >/dev/null; use_stubs
D run phase-001 >/dev/null
rm -f "$PIPE/phases/phase-001"/.failed 2>/dev/null
D review phase-001 >/dev/null
marker phase-001 .done && ok ".done written after review" || no ".done missing after review"

# =========================================================== 10. selection
head_ "10. selection: dependency order, deferral priority, halt switch"
build_fixture >/dev/null
sel="$(D select | tail -1)"
check "$sel" "phase-001" "first pending phase selected"
touch "$PIPE/phases/phase-001/.done" "$PIPE/phases/phase-002/.done" "$PIPE/phases/phase-003/.done"
sel="$(D select | tail -1)"
check "$sel" "phase-004" "moves past completed dependencies"
touch "$PIPE/phases/phase-012/.deferred"
sel="$(D select | tail -1)"
check "$sel" "phase-012" "a deferred phase is resumed first"
rm -f "$PIPE/phases/phase-012/.deferred"
D stop >/dev/null 2>&1
out="$(D select)"
case "$out" in *"pipeline halted"*) ok ".stop halts selection" ;; *) no ".stop did not halt" ;; esac
D resume >/dev/null 2>&1
sel="$(D select | tail -1)"
[ -n "$sel" ] && ok "resume restores selection" || no "resume did not restore selection"

# =========================================================== 11. push safety
head_ "11. an agent-committed phase is not mistaken for 'nothing to push'"
( cd "$PROJ" && printf 'fn committed_by_agent() {}\n' > src/new.rs \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "agent commit" )
st="$( cd "$PROJ" && git status --porcelain | wc -l | tr -d ' ' )"
commits="$( cd "$PROJ" && git log --oneline HEAD~1..HEAD | wc -l | tr -d ' ' )"
check "$st" "0" "git status is clean after the agent committed"
if [ "$commits" -ge 1 ]; then ok "local commit detected -> the push step will ship it"
else no "local commit missed -> phase would be discarded"; fi

# =========================================================== 12. the lock
head_ "12. the advisory lock reclaims a dead owner instead of wedging"
# Use a dead-model stub so `run` returns quickly: this is a lock test, not an
# agent test. `select` and `status` are deliberately lock-free, so they cannot
# exercise this path.
cat > "$STUB/opencode" <<'EOS'
#!/usr/bin/env bash
echo "Error: OpenCode 1.18.0 or newer is required to use the free tier"
exit 0
EOS
chmod +x "$STUB/opencode"

LOCK="$T/lock-probe"
rm -rf "$LOCK" "$PIPE/phases/phase-001"/.[a-z]* 2>/dev/null || true
mkdir -p "$LOCK"
echo 999999 > "$LOCK/pid"                 # a pid that cannot be running
echo $(( $(date +%s) - 5 )) > "$LOCK/born"
out="$( cd "$PIPE" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" RBOPS_LOCK="$LOCK" OPENCODE_API_KEY=stub RBOPS_MIN_OUTPUT=500 \
        timeout 60 bash "$PIPE/rbops/dispatch.sh" run phase-001 2>&1 | strip )"; rc=$?
case "$out" in
  *"reclaiming lock from a dead owner"*) ok "a lock left by a dead pid is reclaimed" ;;
  *"another rbops run holds"*) no "a dead owner's lock wedged the dispatcher"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /' ;;
  *) no "no reclaim message (exit $rc)"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /' ;;
esac
[ "$rc" = "42" ] && ok "and the run then proceeded normally (deferred)" \
                || no "expected 42 after reclaiming, got $rc"
rm -rf "$LOCK"

# A LIVE owner must still be respected, or the lock protects nothing.
mkdir -p "$LOCK"
sleep 300 & LIVE=$!
echo "$LIVE" > "$LOCK/pid"; date +%s > "$LOCK/born"
out="$( cd "$PIPE" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" RBOPS_LOCK="$LOCK" OPENCODE_API_KEY=stub RBOPS_MIN_OUTPUT=500 \
        timeout 60 bash "$PIPE/rbops/dispatch.sh" run phase-001 2>&1 | strip )"; rc=$?
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; rm -rf "$LOCK"
case "$out" in
  *"another rbops run holds"*) ok "a live owner's lock is respected (exit $rc)" ;;
  *) no "the lock did not stop a concurrent run" ;;
esac
use_stubs
# =========================================================== verdict
printf '\n%s%s%s\n' "$DIM" "────────────────────────────────────────" "$OFF"
if [ "$FAIL" -eq 0 ]; then
  printf '%sSMOKE PASS%s  %d checks\n' "$GREEN" "$OFF" "$PASS"
  exit 0
fi
printf '%sSMOKE FAIL%s  %d passed, %d failed\n' "$RED" "$OFF" "$PASS" "$FAIL"
exit 1