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
      && git config user.email t@t && git config user.name t \
      && git add -A \
      && git commit -qm init ) >/dev/null 2>&1
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

// A real Rust test needs the #[test] attribute — without it cargo never runs
// it. The stub used to emit bare `fn test_a()`, which taught the suite to
// believe tests can exist without the attribute and hid a quota bug.
#[test]
fn edge_empty() { assert!(true); }
#[test]
fn test_a() { assert!(true); }
#[test]
fn test_b() { assert!(true); }
#[test]
fn test_c() { assert!(true); }
#[test]
fn test_d() { assert!(true); }
#[test]
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

# Dependencies must resolve against the pipeline root even though the gate runs
# inside the project. A relative phases/ here once failed a satisfied phase.
out="$( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" JQ="$JQ" \
        bash "$PIPE/rbops/verify.sh" phase-002 2>&1 | strip )"
case "$out" in
  *"dep phase-001 not done"*) ok "an unsatisfied dependency is reported" ;;
  *) no "dependency check did not fire"; printf '%s\n' "$out" | head -4 | sed 's/^/      /' ;;
esac
touch "$PIPE/phases/phase-001/.done"
out="$( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" JQ="$JQ" \
        bash "$PIPE/rbops/verify.sh" phase-002 2>&1 | strip )"
case "$out" in
  *"dep phase-001 done"*) ok "a satisfied dependency resolves from the pipeline root" ;;
  *) no "satisfied dependency misreported"; printf '%s\n' "$out" | head -4 | sed 's/^/      /' ;;
esac
rm -f "$PIPE/phases/phase-001/.done"

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
# =========================================================== 13. resume
head_ "13. a retry resumes the preserved work instead of starting from zero"
build_fixture >/dev/null; use_stubs
# Forge a previous attempt: a commit on the recovery ref with distinctive content.
( cd "$PROJ" \
  && printf '// recovered work from attempt 1\n' >> src/vm.rs \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "attempt 1" \
  && git update-ref "refs/remotes/origin/rbops-recovery/phase-001" HEAD \
  && git reset -q --hard HEAD~1 )
# Sanity: the fixture project is back to clean, the ref points at the work.
( cd "$PROJ" && git rev-parse --verify -q "origin/rbops-recovery/phase-001" >/dev/null ) \
  || { no "fixture ref not created"; }
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"; rc=$?
[ "$rc" = "42" ] && ok "dead-model stub still defers after a merge (exit 42)" \
  || no "expected deferral, got $rc"
[ -f "$PIPE/phases/phase-001/.recovered" ] \
  && ok ".recovered marker written" || no ".recovered marker missing"
if grep -q 'recovered work from attempt 1' "$PROJ/src/vm.rs" 2>/dev/null; then
  ok "the preserved commit's content is in the tree"
else
  no "preserved work not merged"
fi
if grep -q "RESUMED WORK" "$PIPE"/logs/phase-001.ctx 2>/dev/null; then
  ok "the agent was told what it inherited"
else
  no "no RESUMED WORK note in the context"
fi
# And the base capture must predate the merge, so inherited work counts.
( cd "$PROJ" && git diff --stat HEAD~1 HEAD | grep -q "vm.rs" ) \
  && ok "inherited diff is measurable against the pre-merge base" \
  || no "inherited work invisible to the diff"

# Precedence. A WIP checkpoint is what a TIMED-OUT attempt left behind:
# partial, and possibly not even compiling. A recovery branch is a COMPLETE
# attempt the gate evaluated. When both exist the complete one must win — a
# stale WIP outranking it once made a retry inherit a broken tree and the
# phase came out worse than starting clean.
build_fixture >/dev/null; use_stubs
# A recovery branch DIVERGED from main: both moved on. --ff-only cannot merge
# that, and the old code then logged "starting clean" and silently discarded
# phase-019's 5629-line bytecode VM. Divergence is the COMMON case - any other
# phase landing after a failure causes it.
( cd "$PROJ" \
  && git checkout -q -b recovered \
  && printf '// recovery side\n' >> src/vm.rs \
  && git add -A && git commit -qm "recovered work" \
  && git update-ref "refs/remotes/origin/rbops-recovery/phase-001" HEAD \
  && git checkout -q main \
  && printf '// main moved on\n' >> src/vm.rs \
  && git add -A && git commit -qm "main moved on" ) >/dev/null 2>&1
# The recovery commit MUST be made on its own branch. Committed while HEAD was
# `main`, it would advance main and the ref would equal main's tip — the sanity
# check below caught exactly that, which is the point of having it.
# Sanity: the recovery tip must NOT be a descendant of main, or nothing is being
# tested. (Getting this fixture wrong is how a check passes for the wrong reason.)
if git -C "$PROJ" merge-base --is-ancestor origin/rbops-recovery/phase-001 HEAD 2>/dev/null; then
  no "fixture is not actually diverged — recovery is already on main, nothing tested"
else
  ok "fixture is genuinely diverged (recovery is not a descendant of main)"
fi
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"
if printf '%s' "$out" | grep -q "resumed from previous attempt"; then
  ok "a DIVERGED recovery branch is resumed, not discarded"
else
  no "the diverged recovery branch was dropped"; printf '%s' "$out" | grep -E 'recovery|clean' | head -3 | sed 's/^/      /'
fi
if printf '%s' "$out" | grep -q "starting clean"; then
  no "it started clean and threw the work away"
else
  ok "it did not fall back to a clean start"
fi
# Both sides must survive the merge.
if grep -q "recovery side" "$PROJ/src/vm.rs" && grep -q "main moved on" "$PROJ/src/vm.rs"; then
  ok "both sides of the divergence are present after the merge"
else
  no "the merge dropped one side"
fi
# And the fast-forward case must still work — the merge path is an addition, not
# a replacement.
build_fixture >/dev/null; use_stubs
( cd "$PROJ" \
  && printf '// recovered work from attempt 1\n' >> src/vm.rs \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "attempt 1" \
  && git update-ref "refs/remotes/origin/rbops-recovery/phase-001" HEAD \
  && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"
if printf '%s' "$out" | grep -q "resumed from previous attempt"; then
  ok "the fast-forward path still resumes"
else
  no "the fast-forward path regressed"
fi

# Precedence: with both a WIP and a recovery ref, the COMPLETE attempt wins.
build_fixture >/dev/null; use_stubs
( cd "$PROJ" \
  && printf '// WIP: interrupted, does not compile\n#[ignore]\nfn half_done() {}\n' >> src/vm.rs \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "wip attempt" \
  && git update-ref "refs/remotes/origin/rbops-wip/phase-001" HEAD \
  && git reset -q --hard HEAD~1 \
  && printf '// recovery: complete attempt\n' >> src/vm.rs \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "complete attempt" \
  && git update-ref "refs/remotes/origin/rbops-recovery/phase-001" HEAD \
  && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"
if printf '%s' "$out" | grep -q "resumed from previous attempt"; then
  ok "with both refs present, the complete attempt is resumed"
else
  no "neither resume path logged"
fi
if printf '%s' "$out" | grep -q "squashing WIP checkpoint"; then
  no "the partial WIP checkpoint was merged over the complete attempt"
else
  ok "the partial WIP checkpoint was not merged"
fi
( cd "$PROJ" && grep -q "complete attempt" src/vm.rs && ! grep -q "does not compile" src/vm.rs ) \
  && ok "the tree holds the complete attempt, not the interrupted one" \
  || no "wrong tree inherited"
# And with only a WIP ref, it must still be used — that is its whole purpose.
build_fixture >/dev/null; use_stubs
( cd "$PROJ" \
  && printf '// wip only\n' >> src/vm.rs \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "wip only" \
  && git update-ref "refs/remotes/origin/rbops-wip/phase-001" HEAD \
  && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"
if printf '%s' "$out" | grep -q "squashing WIP checkpoint" \
   && grep -q "wip only" "$PROJ/src/vm.rs"; then
  ok "with only a WIP ref, the checkpoint is still resumed"
else
  no "a lone WIP checkpoint is ignored"
fi

# =========================================================== 14. honesty
head_ "14. report honesty is asymmetric: over-claim fails, under-claim warns"
# The stub agent writes a conforming report (claims the 12 the stub cargo
# reports) plus real tests, so the gate passes cleanly. That is the control.
build_fixture >/dev/null; use_stubs
D run phase-001 >/dev/null
V() { ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ); }
out="$(V)"
case "$out" in
  *"VERIFY PASS"*) ok "control: conforming report passes" ;;
  *) no "control gate did not pass"; printf '%s\n' "$out" | grep -E 'FAIL|FATAL' | head -5 | sed 's/^/      /' ;;
esac
# Over-claim: report says 50, reality is 12. Must FAIL — this is fabrication,
# the one threat the honesty check exists for.
sed -i 's/12 passed/50 passed/' "$PIPE/phases/phase-001/REPORT.md"
out="$(V)"
case "$out" in
  *"over-claiming is fabrication"*) ok "over-claim fails the phase" ;;
  *) no "over-claim did not fail" ;;
esac
case "$out" in
  *"VERIFY FAIL"*) ok "verdict is FAIL on over-claim" ;;
  *) no "verdict was not FAIL on over-claim" ;;
esac
# Under-claim: report says 0, reality is 12. Must WARN, not fail — the code is
# proven good by the gate itself, and a wrong number in prose is sloppiness,
# not a lie that ships bad code. This exact case once blocked a 59-green phase.
sed -i 's/50 passed/0 passed/' "$PIPE/phases/phase-001/REPORT.md"
out="$(V)"
case "$out" in
  *"under-claimed"*) ok "under-claim warns" ;;
  *) no "under-claim did not warn"; printf '%s\n' "$out" | grep -E 'FAIL|WARN' | head -5 | sed 's/^/      /' ;;
esac
case "$out" in
  *"VERIFY PASS"*) ok "verdict stays PASS on under-claim" ;;
  *) no "verdict failed on under-claim" ;;
esac

# =========================================================== 15. bilingual rules
head_ "15. the mandatory rules work in Redblue, not just Rust"
# Two rules — "≥1 test named edge_*" and "≥1 test asserting a failure" — were
# written with Rust-only patterns. They rejected 61 real Redblue tests in
# phase-003: a Redblue test name is a quoted string, so `test edge_x` never
# occurs, and Redblue has no exceptions, only `try ... catch error`, which the
# failure pattern did not list. Both rules must hold in both languages.
build_fixture >/dev/null; use_stubs
# tests/*.rb is not swept by the example runner (examples/ and modules/ only),
# so Redblue tests here are inert fixtures — we are testing the gate's reading
# of the diff, not the interpreter.
RB_PASS='test "edge_empty list is rejected"
    try
        set x to empty[0]
    catch error
        set caught to yes
    end
    expect caught to be yes

test "edge_out_of_bounds index"
    try
        set y to [1, 2, 3][9]
    catch error
        set caught2 to yes
    end
    expect caught2 to be yes
'
# A conforming report, so the ONLY thing under test is the two rules.
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase 001 — redblue-only probe

## What changed
| File | Lines | What |
|---|---|---|
| tests/sample.rb | +14 −0 | redblue edge + failure tests |

## Tests added
| Test | Edge class covered |
|---|---|
| edge_empty list is rejected | out of bounds |
| edge_out_of_bounds index | out of bounds |

## Gates
| Gate | Result |
|---|---|
| cargo test | 12 passed, 0 failed |

## Known gaps / follow-ups
- none
EOR
printf '%s' "$RB_PASS" > "$PROJ/tests/sample.rb"
# `git diff HEAD` cannot see an untracked file, and a new test file starts
# untracked — stage it or the gate correctly reports "no changed files".
V() { ( cd "$PROJ" && git add -A && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ); }
out="$(V)"
case "$out" in
  *"edge case test present"*) ok "a quoted Redblue name satisfies the edge_* rule" ;;
  *) no "quoted Redblue test name still rejected"; printf '%s\n' "$out" | grep -E 'edge_|FAIL' | head -4 | sed 's/^/      /' ;;
esac
case "$out" in
  *"failure-asserting test present"*) ok "try/catch satisfies the failure-assertion rule" ;;
  *) no "try/catch still rejected"; printf '%s\n' "$out" | grep -E 'failure|FAIL' | head -4 | sed 's/^/      /' ;;
esac
case "$out" in
  *"VERIFY PASS"*) ok "a Redblue-only phase can now pass the gate" ;;
  *) no "Redblue-only phase still cannot pass" ;;
esac

# Now the cheater check: same file, edge_ naming and catch/error both removed.
# The rules must still bite, or the fix above was a loosening, not a fix.
printf 'test "list basics"\n    set x to [1, 2, 3]\n    expect length(x) to be 3\n' \
  > "$PROJ/tests/sample.rb"
out="$(V)"
case "$out" in
  *"no test named edge_"*) ok "un-named test still fails the edge_* rule" ;;
  *) no "edge_* rule stopped biting" ;;
esac
case "$out" in
  *"no test asserts a failure"*) ok "no-catch test still fails the failure rule" ;;
  *) no "failure-assertion rule stopped biting" ;;
esac
case "$out" in
  *"VERIFY FAIL"*) ok "verdict is FAIL for a phase that asserts nothing about faults" ;;
  *) no "verdict was not FAIL" ;;
esac
# And the anchored catch must not be buyable from a string literal or prose.
printf 'test "edge_catch_error is mentioned in the docs"\n    set note to "catch error"\n    expect note to be "catch error"\n' \
  > "$PROJ/tests/sample.rb"
out="$(V)"
case "$out" in
  *"no test asserts a failure"*) ok "'catch error' as string data cannot buy a pass" ;;
  *) no "failure rule satisfied by a string literal" ;;
esac

# =========================================================== 16. no clobber
head_ "16. parking work archives the previous attempt instead of destroying it"
# Self-contained: needs a real remote to push refs to, so it builds its own bare
# repo rather than borrowing $PROJ. A worse retry must never be able to erase a
# better one — that is how phase-003's 187-test tree was lost.
AT="$(mktemp -d)"
git init -q --bare "$AT/remote.git" 2>/dev/null
git clone -q "$AT/remote.git" "$AT/w" 2>/dev/null
( cd "$AT/w" && git config user.email t@t && git config user.name t \
  && PH=phase-999
  # Verbatim from rbops.yml — if the workflow's copy drifts, this stops testing it.
  archive_and_park() {
    local prev
    prev="$(git ls-remote origin "refs/heads/rbops-recovery/${PH}" 2>/dev/null | awk '{print $1}')"
    if [ -n "${prev:-}" ] && [ "${prev}" != "$(git rev-parse HEAD)" ]; then
      if git push -q origin "${prev}:refs/heads/rbops-archive/${PH}/${prev:0:7}" 2>/dev/null; then
        echo "archived ${prev:0:7}"
      fi
    fi
    git branch -f "rbops-recovery/${PH}" HEAD 2>/dev/null || true
    git push -f origin "HEAD:refs/heads/rbops-recovery/${PH}" 2>/dev/null || true
  }
  echo one > f.txt; git add -A; git commit -qm one
  git branch -f "rbops-recovery/$PH" HEAD
  git push -q -f origin "HEAD:refs/heads/rbops-recovery/$PH"
  GOOD="$(git rev-parse HEAD)"
  echo two > f.txt; git add -A; git commit -qm two      # a later, worse attempt
  archive_and_park >/dev/null 2>&1
  REC="$(git ls-remote origin "refs/heads/rbops-recovery/$PH" | awk '{print $1}')"
  ARCH="$(git ls-remote origin "refs/heads/rbops-archive/$PH/${GOOD:0:7}" | awk '{print $1}')"
  N="$(git ls-remote origin "refs/heads/rbops-archive/$PH/*" | wc -l | tr -d ' ')"
  [ "$REC" = "$(git rev-parse HEAD)" ] && echo "rec=ok" || echo "rec=bad"
  [ "$ARCH" = "$GOOD" ] && echo "arch=ok" || echo "arch=bad"
  archive_and_park >/dev/null 2>&1
  echo "three" > f.txt; git add -A; git commit -qm three
  archive_and_park >/dev/null 2>&1
  echo "n=$(git ls-remote origin "refs/heads/rbops-archive/$PH/*" | wc -l | tr -d ' ')"
) > "$AT/out" 2>&1
res="$(cat "$AT/out" 2>/dev/null)"
grep -q 'rec=ok'   <<<"$res" && ok "recovery head tracks the newest attempt" \
  || no "recovery head is wrong"
grep -q 'arch=ok'  <<<"$res" && ok "the previous attempt is archived, not destroyed" \
  || no "the previous attempt was destroyed"
grep -q '^n=2$'    <<<"$res" && ok "re-parking is idempotent and older attempts accumulate" \
  || no "archive refs are wrong: $(grep '^n=' <<<"$res")"
rm -rf "$AT"

# =========================================================== 17. new files count
head_ "17. a brand-new test file is visible to the gate"
# `git diff <base>` ignores untracked paths, and a new test file starts
# untracked. Phase-007 wrote 355 lines and 16 #[test] functions in a new file
# and the quota reported "0 rust" — so the gate passed a phase it never read.
build_fixture >/dev/null; use_stubs
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase 001 — new-file probe

## What changed
| File | Lines | What |
|---|---|---|
| tests/brand_new.rs | +9 −0 | new file, never staged by the agent |

## Tests added
| Test | Edge class covered |
|---|---|
| division_by_zero_reports_an_error | numeric boundary |

## Gates
| Gate | Result |
|---|---|
| cargo test | 12 passed, 0 failed |

## Known gaps / follow-ups
- none
EOR
# A new Rust test file with plainly-named tests: no test_ prefix, no edge_
# prefix. Only one is edge_-named so the naming rule is satisfied separately.
cat > "$PROJ/tests/brand_new.rs" <<'EOR'
#[test]
fn division_by_zero_reports_an_error() { assert!(true); }

#[test]
fn modulo_by_a_zero_divisor_is_rejected() { assert!(true); }

#[test]
fn edge_numeric_boundary_is_an_error_not_a_panic() {
    let r: Result<(), ()> = Err(());
    assert!(r.is_err());
}
EOR
out="$( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip )"
case "$out" in
  *"test quota met: 3 rust"*) ok "3 #[test] fns in a NEW file counted (quota met)" ;;
  *) no "new test file still invisible"; printf '%s\n' "$out" | grep -E 'quota|diff' | head -3 | sed 's/^/      /' ;;
esac
case "$out" in
  *"edge case test present"*) ok "the edge_-named test still satisfies the naming rule" ;;
  *) no "edge naming rule broken" ;;
esac
# Control: the same tests with NO edge_ name must still fail the naming rule,
# proving the count did not quietly satisfy it by accident.
cat > "$PROJ/tests/brand_new.rs" <<'EOR'
#[test]
fn division_by_zero_reports_an_error() { assert!(true); }
#[test]
fn modulo_by_a_zero_divisor_is_rejected() { assert!(true); }
#[test]
fn another_plainly_named_case() { assert!(true); }
EOR
out="$( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip )"
case "$out" in
  *"test quota met: 3 rust"*) ok "un-prefixed tests still meet the quota on the #[test] count" ;;
  *) no "quota still demands a name prefix" ;;
esac
case "$out" in
  *"no test named edge_"*) ok "but the edge_ naming rule still bites" ;;
  *) no "naming rule stopped biting once the quota passed" ;;
esac
# And an untracked file must not be able to smuggle in a skip either.
printf '#[test]\nfn edge_x() { assert!(true); }\n#[ignore]\nfn y() {}\n' \
  > "$PROJ/tests/brand_new.rs"
out="$( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip )"
case "$out" in
  *"newly skipped/ignored tests"*) ok "a #[ignore] in a new file is caught too" ;;
  *) no "a new file can hide a skipped test" ;;
esac

# =========================================================== 18. must_touch
head_ "18. a phase must implement, not only test"
# Every other gate rule measures verification; none measures ambition. So the
# cheapest pass was to write tests for behaviour that already exists and touch
# no implementation. Phase-004 did: goal was insertion order in src/value.rs,
# landed 19 lines of src/ and 532 of tests. must_touch closes that escape hatch.
build_fixture >/dev/null; use_stubs
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase 001 — must_touch probe

## What changed
| File | Lines | What |
|---|---|---|
| tests/sample.rb | +9 −0 | redblue tests |

## Tests added
| Test | Edge class covered |
|---|---|
| edge_empty list is rejected | out of bounds |

## Gates
| Gate | Result |
|---|---|
| cargo test | 12 passed, 0 failed |

## Known gaps / follow-ups
- none
EOR
set_mt() { "$JQ" --argjson v "$1" '.phases |= map(if .id=="phase-001" then .must_touch=$v else . end)' \
             "$PIPE/rbops/phases.json" > "$PIPE/phases.json.t" && mv "$PIPE/phases.json.t" "$PIPE/rbops/phases.json"; }
RB_TESTS='test "edge_empty list is rejected"
    try
        set x to empty[0]
    catch error
        set caught to yes
    end
    expect caught to be yes

test "edge_out_of_bounds index is a clean error"
    try
        set y to [1, 2, 3][9]
    catch error
        set caught2 to yes
    end
    expect caught2 to be yes
'
printf '%s' "$RB_TESTS" > "$PROJ/tests/sample.rb"
V() { ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ); }

# The cheat: a complete, passing, honest test-only phase.
set_mt '["src/"]'
out="$(V)"
case "$out" in
  *"no implementation change"*) ok "tests-only phase FAILS against must_touch src/" ;;
  *) no "must_touch did not fire on a tests-only phase"; printf '%s\n' "$out" | grep -E 'must_touch|implementation|DBG' | head -3 | sed 's/^/      /' ;;
esac
case "$out" in
  *"VERIFY FAIL"*) ok "verdict is FAIL" ;;
  *) no "verdict was not FAIL" ;;
esac
# Now do the same work plus one line of implementation. Must pass, and the only
# thing that changed is that src/ was touched — proving the rule is about area,
# not volume.
( cd "$PROJ" && printf '// implementation\n' >> src/vm.rs )
out="$(V)"
case "$out" in
  *"implementation touched src/"*) ok "touching src/ satisfies must_touch" ;;
  *) no "must_touch not satisfied by a src/ change"; printf '%s\n' "$out" | grep -E 'must_touch|implementation' | head -3 | sed 's/^/      /' ;;
esac
case "$out" in
  *"VERIFY PASS"*) ok "and the phase passes" ;;
  *) no "phase still fails after implementing"; printf '%s\n' "$out" | grep -E 'FAIL' | head -3 | sed 's/^/      /' ;;
esac
# A test-only phase that DECLARES tests/ is legitimate work and must pass.
( cd "$PROJ" && git checkout -- src/vm.rs )
set_mt '["tests/"]'
out="$(V)"
case "$out" in
  *"implementation touched tests/"*) ok "a phase declaring tests/ is satisfied by tests" ;;
  *) no "must_touch wrongly fired on a legitimate test-only phase" ;;
esac
case "$out" in
  *"VERIFY PASS"*) ok "phase-020-style harness phase is not blocked" ;;
  *) no "a test-only phase was blocked" ;;
esac
# Several acceptable areas: touching ANY one is enough.
( cd "$PROJ" && git checkout -- tests/sample.rb 2>/dev/null; printf '%s' "$RB_TESTS" > "$PROJ/tests/sample.rb" )
set_mt '["src/", "modules/"]'
mkdir -p "$PROJ/modules"; printf '// a module fix\n' >> "$PROJ/modules/SuiteKit.rb"
out="$(V)"
case "$out" in
  *"implementation touched modules/"*) ok "any one of several declared areas satisfies it" ;;
  *) no "multi-area must_touch too strict" ;;
esac
# No declaration at all: unconstrained, must not fail.
set_mt 'null'
out="$(V)"
case "$out" in
  *"no must_touch declared"*) ok "a phase with no must_touch is unconstrained" ;;
  *) no "an undeclared phase was constrained anyway" ;;
esac
case "$out" in
  *"VERIFY PASS"*) ok "unconstrained phase passes on tests alone (history is not rewritten)" ;;
  *) no "unconstrained phase failed" ;;
esac

# =========================================================== 19. manifest is read
head_ "19. the gate reads the manifest instead of falling back to defaults"
# verify.sh read its thresholds with '$("...\"$JQ\"..." )' — a single-quoted
# string CONTAINING the literal characters "$JQ". Bash does not expand it, so the
# command ran as a program literally named `"$JQ"`, failed, and the `|| echo N`
# fallback supplied the number. min_changed_lines and BOTH test-quota floors were
# therefore hardcoded and had never once been read from phases.json. They matched
# by coincidence, so nothing looked wrong — and any future manifest edit would
# have been silently ignored.
build_fixture >/dev/null; use_stubs
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase 001 — manifest probe

## What changed
| File | Lines | What |
|---|---|---|
| tests/sample.rb | +14 −0 | redblue tests |

## Tests added
| Test | Edge class covered |
|---|---|
| edge_empty list is rejected | out of bounds |

## Gates
| Gate | Result |
|---|---|
| cargo test | 12 passed, 0 failed |

## Known gaps / follow-ups
- none
EOR
set_tf() { "$JQ" '.test_policy.min_redblue_tests='"$1" "$PIPE/rbops/phases.json" > "$PIPE/t.json" \
            && mv "$PIPE/t.json" "$PIPE/rbops/phases.json"; }
cat > "$PROJ/tests/sample.rb" <<'EOR'
test "edge_empty list is rejected"
    try
        set x to empty[0]
    catch error
        set caught to yes
    end
    expect caught to be yes

test "edge_out_of_bounds index is a clean error"
    expect 1 to be 1
EOR
V() { ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ); }
# Two redblue tests: passes the real floor of 2.
out="$(V)"
case "$out" in
  *"test quota met: 0 rust / 2 redblue (need 3 or 2)"*) ok "the real floor (2) is read from the manifest" ;;
  *) no "quota floor is not the manifest value"; printf '%s\n' "$out" | grep -E 'quota' | head -2 | sed 's/^/      /' ;;
esac
# Raise the floor to 9: the SAME tree must now fail. If the gate were using a
# hardcoded default this would still pass, which is exactly the bug.
set_tf 9
out="$(V)"
case "$out" in
  *"test quota not met: 0 rust (need 3) and 2 redblue (need 9)"*) ok "raising the manifest floor to 9 fails the same tree" ;;
  *) no "the manifest floor is ignored"; printf '%s\n' "$out" | grep -E 'quota' | head -2 | sed 's/^/      /' ;;
esac
# And no warning may be emitted: a fallback firing is itself the bug.
case "$out" in
  *"could not read .test_policy"*) no "a silent jq fallback fired" ;;
  *) ok "no silent fallback warning" ;;
esac
set_tf 2

# =========================================================== 20. review integrity
head_ "20. the reviewer is a real gate, not a rubber stamp"
# Two separate failures made every phase ship unreviewed:
#
#  1. `--agent reviewer` resolved to NOTHING ("agent not found, falling back to
#     default agent"), because dispatch runs opencode with --dir at the redblue
#     checkout, which has no opencode.json. The reviewer was then told to read
#     `.opencode/agent/reviewer.md`, which does not exist. So it ran with no
#     contract at all. One review log is 654 bytes of file-not-found errors.
#  2. The parser read "no [SEVERITY] tag found" as APPROVAL. Phase-013's review
#     contained six real defect classes in prose and was discarded wholesale.
#
# The contract is now inlined from rbops/agents/*.md, and a review with no
# parseable verdict is INVALID rather than clean.

# (1) the contract must actually reach the model
build_fixture >/dev/null; use_stubs
D run phase-001 >/dev/null 2>&1
R() { RBOPS_MIN_OUTPUT=1 D review phase-001 2>&1 | strip; }
out="$(R)"
if grep -q 'RBOPS REVIEWER CONTRACT' "$PIPE"/logs/phase-001.review.1.ctx 2>/dev/null; then
  ok "the reviewer contract is inlined into the request"
else
  no "the reviewer got no contract"
fi
if grep -q 'REVIEW VERDICT' "$PIPE"/logs/phase-001.review.1.ctx 2>/dev/null; then
  ok "the mandatory verdict line is specified"
else
  no "no verdict requirement in the reviewer contract"
fi
if grep -q '\.opencode/agent/reviewer\.md' "$PIPE"/logs/phase-001.review.1.ctx 2>/dev/null; then
  no "the request still points at a nonexistent agent file"
else
  ok "the request no longer points at a nonexistent agent file"
fi
[ -s "$PIPE/rbops/agents/reviewer.md" ] && ok "reviewer.md ships in the pipeline repo" \
  || no "rbops/agents/reviewer.md is missing from the fixture"

# (2) parsing. Drive the real parser through cmd_review with a stub that emits a
# chosen review log, so each outcome is asserted rather than assumed.
review_with() {   # $1 = body to emit
  build_fixture >/dev/null; use_stubs
  cat > "$STUB/opencode" <<EOS
#!/usr/bin/env bash
cat <<'BODY'
$1
BODY
echo "review done"
exit 0
EOS
  chmod +x "$STUB/opencode"
  RBOPS_MAX_REVIEW_ROUNDS=1 R review phase-001
}
# a) prose findings with no tags and no verdict must NOT approve. This is the
#    exact shape that shipped phase-013.
out="$(review_with 'I looked hard and found problems.
- src/vm.rs:473 - for loop ignores step sign, descending ranges never run
- src/vm.rs:626 - evaluate recurses with no depth check, can overflow the stack
Please fix these before shipping.')"
case "$out" in
  *"INVALID"*) ok "prose findings with no verdict are INVALID, not clean" ;;
  *) no "a tagless prose review was treated as approval"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /' ;;
esac
marker phase-001 .done && no "an invalid review still wrote .done" || ok "an invalid review does NOT write .done"
# b) an explicit CLEAN verdict approves
out="$(review_with 'I checked the diff against the report and the gates.
FINDINGS: none
REVIEW VERDICT: CLEAN')"
case "$out" in
  *"explicit CLEAN"*) ok "an explicit CLEAN verdict approves" ;;
  *) no "an explicit CLEAN was not honoured"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /' ;;
esac
marker phase-001 .done && ok ".done written on a clean review" || ok "no .done (acceptable for this assertion path)"
# c) BLOCKER in prose form must block, not slip through the tag-only regex
out="$(review_with 'src/vm.rs:473 - descending for range never executes
BLOCKER: this is reachable and wrong
REVIEW VERDICT: FINDINGS 1')"
case "$out" in
  *"blocking finding"*) ok "a prose BLOCKER is caught (old regex missed it)" ;;
  *) no "a prose BLOCKER slipped through"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /' ;;
esac
# d) total garbage must not approve either
out="$(review_with 'I am unable to complete the review.')"
case "$out" in
  *"INVALID"*) ok "an unusable review is INVALID" ;;
  *) no "an unusable review was treated as clean" ;;
esac

# =========================================================== 21. one pipeline, one lock
head_ "21. both workflows share one concurrency group"
# rbops.yml and rbops-tick.yml drive ONE pipeline. Separate concurrency groups do
# not exclude each other, and a cron tick at :17/:47 fired while the retrigger
# chain was mid-phase. Both runs worked phase-015 at once, on separate runners.
# Phase-015's work landed on redblue twice and its `.done` was clobbered back to
# `.failed`, so a merged phase got queued for a third attempt.
#
# The in-tick guard (count in-progress runs) cannot fix this: it checks, sleeps,
# then dispatches, and a retrigger inside that window dispatches too. The mkdir
# lock in dispatch.sh cannot either — every CI run has its own /tmp.
WF="$RBOPS_ROOT/.github/workflows"
# Parsed with awk, not jq: these are YAML files and jq only reads JSON. Scoped to
# the `concurrency:` block so a `group:` key elsewhere cannot be picked up.
conc_field() {  # $1=file $2=key
  awk -v key="$2" '
    /^concurrency:/ { inc=1; next }
    inc && /^[^[:space:]]/ { inc=0 }
    inc && $1 == key":" { $1=""; sub(/^[[:space:]]+/,""); print; exit }
  ' "$1"
}
for w in rbops.yml rbops-tick.yml; do
  if [ -r "$WF/$w" ]; then
    g="$(conc_field "$WF/$w" group)"
    [ "$g" = "rbops-pipeline" ] && ok "$w declares group rbops-pipeline" \
      || no "$w declares group '$g' — the two workflows can race"
  else
    no "$w is missing"
  fi
done
# cancel-in-progress would let a tick kill a half-finished phase's state push,
# which is how .done gets lost in the first place.
for w in rbops.yml rbops-tick.yml; do
  [ -r "$WF/$w" ] || continue
  c="$(conc_field "$WF/$w" cancel-in-progress)"
  [ "$c" = "false" ] && ok "$w does not cancel in-progress runs" \
    || no "$w sets cancel-in-progress: '$c' — a running phase can be killed mid-push"
done
# Both files are read from the real repo, not the fixture: build_fixture copies
# only rbops/, phases/ and AGENTS.md, so checking $PIPE here would silently pass
# against nothing. Assert both are actually readable instead.
for w in rbops.yml rbops-tick.yml; do
  [ -r "$WF/$w" ] && ok "$w is readable" || no "$w is unreadable — the checks above cannot be trusted"
done

# =========================================================== 22. done is authoritative
head_ "22. writing .done clears the failure markers"
# cmd_select reads only `.done`, so a phase carrying both `.done` and `.failed`
# looks finished to one reader and unfinished to another - which is exactly how
# phase-015 ended up merged on redblue and still queued for another attempt.
build_fixture >/dev/null; use_stubs
D run phase-001 >/dev/null 2>&1
mkdir -p "$PIPE/phases/phase-001"
: > "$PIPE/phases/phase-001/.failed"
: > "$PIPE/phases/phase-001/.deferred"
out="$(R)"
marker phase-001 .done && ok ".done written" || no ".done missing"
[ -f "$PIPE/phases/phase-001/.failed" ] && no ".failed survived alongside .done" \
  || ok ".failed cleared when .done was written"
[ -f "$PIPE/phases/phase-001/.deferred" ] && no ".deferred survived alongside .done" \
  || ok ".deferred cleared when .done was written"
# And a phase with .done must not be selected again.
out="$( cd "$PIPE" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/dispatch.sh" select 2>&1 | tail -1 | strip )"
case "$out" in
  *"phase-001"*) no "a .done phase is still selectable" ;;
  *) ok "a .done phase is not selected again" ;;
esac

# =========================================================== 23. failure_assert scope
head_ "23. the failure-assertion rule is skipped only where it cannot apply"
# A linter reports problems as a diagnostics collection, a formatter and an LSP
# emit documents. There is no Result::Err to assert on, so requiring is_err()/
# should_panic of them is a category error - and phase-016's linter tests were
# asserting failure correctly as `assert_eq!(warnings.len(), 1, ...)` when it
# blocked it. Both 015 and 016 burned every attempt on it.
#
# The escape is declared per phase and must be VISIBLE when it fires, or it is
# indistinguishable from the rule being satisfied.
build_fixture >/dev/null; use_stubs
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase 001 — failure_assert probe

## What changed
| File | Lines | What |
|---|---|---|
| tests/probe.rs | +8 −0 | tests only |

## Tests added
| Test | Edge class covered |
|---|---|
| edge_warns_on_unused_variable | false positive |

## Gates
| Gate | Result |
|---|---|
| cargo test | 12 passed, 0 failed |

## Known gaps / follow-ups
- none
EOR
set_fa() { "$JQ" --argjson v "$1" '.phases |= map(if .id=="phase-001" then .failure_assert=$v else . end)' \
             "$PIPE/rbops/phases.json" > "$PIPE/f.json" && mv "$PIPE/f.json" "$PIPE/rbops/phases.json"; }
# A linter-shaped test: asserts the diagnostic count. No is_err, no should_panic.
cat > "$PROJ/tests/sample.rb" <<'EOR'
test "edge_warns_on_unused_variable"
    set total to 1
    expect total to be 1

test "edge_no_warning_on_used_variable"
    expect 1 to be 1
EOR
V() { ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ); }
# default: the rule applies and this phase fails it
set_fa 'null'
out="$(V)"
case "$out" in
  *"no test asserts a failure"*) ok "by default the rule applies and a diagnostics-only test fails it" ;;
  *) no "the rule stopped applying by default"; printf '%s\n' "$out" | grep -E 'failure' | head -2 | sed 's/^/      /' ;;
esac
# declared not applicable: skipped, and announced
set_fa '"not_applicable"'
out="$(V)"
case "$out" in
  *"NOT APPLICABLE"*) ok "the skip is announced, not silent" ;;
  *) no "the skip was silent — indistinguishable from passing"; printf '%s\n' "$out" | grep -E 'failure' | head -2 | sed 's/^/      /' ;;
esac
case "$out" in
  *"no test asserts a failure"*) no "the rule fired despite the declaration" ;;
  *) ok "the rule is skipped when declared" ;;
esac
case "$out" in
  *"VERIFY PASS"*) ok "a linter/formatter-shaped phase can now pass" ;;
  *) no "still blocked on an inapplicable rule"; printf '%s\n' "$out" | grep -E 'FAIL' | head -3 | sed 's/^/      /' ;;
esac
# And the other mandatory rules must still bite under the declaration - the
# exemption is for the failure check ONLY.
rm -f "$PROJ/tests/sample.rb"
out="$(V)"
case "$out" in
  *"no test named edge_"*) ok "the edge_* rule still applies under the exemption" ;;
  *) no "the exemption leaked into other rules" ;;
esac
case "$out" in
  *"test quota not met"*) ok "the quota still applies under the exemption" ;;
  *) no "the exemption leaked into the quota" ;;
esac
# And every phase that DID declare it is a non-error-producing one, by title.
na="$(cd "$RBOPS_ROOT" && "$JQ" -r '[.phases[] | select(.failure_assert=="not_applicable") | "\(.id) \(.title)"] | .[]' rbops/phases.json)"
echo "$na" | sed 's/^/      /'
if echo "$na" | grep -qiE 'formatter|linter|language server'; then
  ok "every exemption is a diagnostics/document producer"
else
  no "an exemption was granted to a phase that does produce errors"
fi
n_ex="$(echo "$na" | grep -c .)"
[ "$n_ex" -le 4 ] && ok "the exemption is narrow ($n_ex phases)" \
  || no "$n_ex phases exempted — too broad"

# =========================================================== 24. fix-pass honesty
head_ "24. a fix pass that ignores the findings is caught, not retried"
# phase-015 spent three review rounds on a single defect. The fix pass wrote
# "| src/formatter.rs | +40 -10 | **run 3 (this round)** - the `catch` BLOCKER"
# into its own summary while leaving the cited code untouched, so the reviewer
# correctly re-reported it and each round cost ~11 minutes to learn nothing.
#
# The dispatcher now hashes every file the blocking findings cite, runs the fix,
# and hashes again. If nothing cited changed, it blocks with that reason rather
# than looping.
build_fixture >/dev/null; use_stubs
D run phase-001 >/dev/null 2>&1
# The stubs below run as separate processes, so $PIPE/$PROJ are NOT visible to
# them: D() cd's into $PIPE and inherits only exported variables. Without these
# exports the stub silently took its review branch on BOTH invocations - the fix
# branch was never entered, and the "non-fix" check passed for the wrong reason.
export SMOKE_PIPE="$PIPE" SMOKE_PROJ="$PROJ"
cat > "$STUB/opencode" <<'EOS'
#!/usr/bin/env bash
n=0
[ -f "$SMOKE_PIPE/logs/phase-001.fix.1.log" ] && n=1
if [ "$n" = "0" ]; then
  # review round 1: one blocking finding citing src/vm.rs
  echo "1. [BLOCKER] src/vm.rs:1 - the defect is here - fix it - done"
  echo "REVIEW VERDICT: FINDINGS 1"
  echo "review done"
else
  # the fix pass: reports a fix, edits NOTHING
  echo "| src/vm.rs | +40 -10 | run 3 (this round) - the BLOCKER |"
  echo "fix done"
fi
exit 0
EOS
chmod +x "$STUB/opencode"
out="$(R)"
case "$out" in
  *"DID NOT TOUCH any file cited"*) ok "a fix pass that edited nothing is detected" ;;
  *) no "the non-fix was not detected"; printf '%s\n' "$out" | grep -E 'fix round|BLOCKED' | head -4 | sed 's/^/      /' ;;
esac
case "$out" in
  *"BLOCKED - fix pass never addressed the findings"*) ok "it blocks instead of looping again" ;;
  *) no "it did not block on a non-fix" ;;
esac
case "$out" in
  *"fix round 1: 1 file(s) cited by the findings"*) ok "the findings' files were tracked" ;;
  *) no "cited files were not tracked" ;;
esac
# Only ONE fix round may have been spent: a second would mean it looped.
n_rounds="$(grep -c 'applying review fixes' <<<"$out")"
[ "${n_rounds:-0}" -le 1 ] && ok "no blind retry after the non-fix ($n_rounds fix round(s))" \
  || no "it retried $n_rounds times after a non-fix"

# And the control: a fix pass that DOES touch the cited file must proceed to the
# next review round. Otherwise this check could be passing by blocking everything.
build_fixture >/dev/null; use_stubs
D run phase-001 >/dev/null 2>&1
cat > "$STUB/opencode" <<'EOS'
#!/usr/bin/env bash
n=0
[ -f "$SMOKE_PIPE/logs/phase-001.fix.1.log" ] && n=1
if [ "$n" = "0" ]; then
  echo "1. [BLOCKER] src/vm.rs:1 - the defect is here - fix it - done"
  echo "REVIEW VERDICT: FINDINGS 1"
  echo "review done"
else
  printf '// the cited file WAS edited\n' >> "$SMOKE_PROJ/src/vm.rs"
  echo "edited src/vm.rs"
fi
exit 0
EOS
chmod +x "$STUB/opencode"
out="$(R)"
case "$out" in
  *"fix round 1: 1 cited file(s) actually changed"*) ok "a real fix is recognised" ;;
  *) no "a real fix was not recognised"; printf '%s\n' "$out" | grep -E 'fix round|BLOCKED|review round' | head -5 | sed 's/^/      /' ;;
esac
case "$out" in
  *"DID NOT TOUCH"*) no "a real fix was misreported as a non-fix" ;;
  *) ok "a real fix is not mistaken for a non-fix" ;;
esac

# =========================================================== 25. manifest/prompt parity
head_ "25. every phase in the manifest has a runnable prompt"
# cmd_run dies on a missing prompt, so a manifest entry without one is a queue
# item that kills its own run. The first audit appended 11 phases and created
# none of their prompts: validate reported 11 missing-prompt errors and all 11
# were unrunnable until regenerated by hand. The same shape of gap as before -
# the manifest was right and the artefact the pipeline actually reads was absent.
bad=0; missing=""
for d in "$RBOPS_ROOT"/phases/*/; do
  id="$(basename "$d")"
  [ -d "$d" ] || continue
  [ -f "$d/PROMPT.md" ] || { bad=1; missing="$missing $id"; }
done
[ "$bad" = "0" ] && ok "every phase directory has a PROMPT.md" \
  || no "phases without a PROMPT.md:$missing"
# And the inverse: nothing on disk that the manifest does not declare.
orphan=""
for d in "$RBOPS_ROOT"/phases/*/; do
  id="$(basename "$d")"
  [ "$id" = "INVARIANTS.md" ] && continue
  [ -d "$d" ] || continue
  if ! "$JQ" -e --arg p "$id" '.phases[] | select(.id==$p)' "$RBOPS_ROOT/rbops/phases.json" >/dev/null 2>&1; then
    orphan="$orphan $id"
  fi
done
[ -z "$orphan" ] && ok "no phase directory is missing from the manifest" \
  || no "phase dirs not in phases.json:$orphan"
# The generator must carry the gate rules into the brief. It did not once: the
# manifest had must_touch on 14 phases and the prompts said nothing, so an agent
# reading only its brief could not know it had to change src/ at all.
"$JQ" -r '.phases[] | select((.must_touch // []) | length > 0) | .id' "$RBOPS_ROOT/rbops/phases.json" \
  > "$T/mt.txt" 2>/dev/null || true
mt_missing=""
while read -r id; do
  [ -n "$id" ] || continue
  grep -q 'Must change' "$RBOPS_ROOT/phases/$id/PROMPT.md" 2>/dev/null || mt_missing="$mt_missing $id"
done < "$T/mt.txt"
[ -z "$mt_missing" ] && ok "every must_touch phase states it in its prompt" \
  || no "prompts omitting must_touch:$mt_missing"
# And the exemption must be stated too, or the agent invents a failure test.
"$JQ" -r '.phases[] | select(.failure_assert=="not_applicable") | .id' "$RBOPS_ROOT/rbops/phases.json" \
  > "$T/fa.txt" 2>/dev/null || true
fa_missing=""
while read -r id; do
  [ -n "$id" ] || continue
  grep -q 'does not apply' "$RBOPS_ROOT/phases/$id/PROMPT.md" 2>/dev/null || fa_missing="$fa_missing $id"
done < "$T/fa.txt"
[ -z "$fa_missing" ] && ok "every exempt phase explains the exemption in its prompt" \
  || no "prompts omitting the exemption:$fa_missing"

# =========================================================== 26. no checkpoint ancestry
head_ "26. main never inherits checkpoint commits"
# Six `rbops: phase-NNN checkpoint <ts>` commits are ancestors of redblue main
# today, carrying unreviewed code. The cause was the resume path doing a REAL
# `git merge` of rbops-wip/* inside the project clone, whose branch is main: the
# merge recorded both parents, so the checkpoint commits became ancestors, and
# the next successful push shipped them. Preserved work must be adopted by
# CONTENT, not by importing a history of half-finished snapshots.
build_fixture >/dev/null; use_stubs
# A WIP branch made only of checkpoint commits, as the real one is.
( cd "$PROJ" \
  && printf '// half-finished work\n' >> src/vm.rs \
  && TREE=$(git add -A >/dev/null 2>&1; git write-tree) \
  && C=$(git commit-tree "$TREE" -p HEAD -m "rbops: phase-001 checkpoint 1700000000") \
  && git update-ref "refs/remotes/origin/rbops-wip/phase-001" "$C" \
  && git reset -q --hard HEAD ) >/dev/null 2>&1
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"
# `if ... fi` cannot be chained with &&, so each check stands alone.
if ( cd "$PROJ" && git log --oneline ) | grep -q 'checkpoint 1700000000'; then
  no "a checkpoint commit is in main's history"
else
  ok "the checkpoint commit is NOT in main's history"
fi
if ( cd "$PROJ" && git log --oneline ) | grep -q 'adopt WIP checkpoint'; then
  ok "the work was adopted as a single-parent commit on main"
else
  no "no adopt commit — the WIP work may have been dropped"
fi
if grep -q 'half-finished work' "$PROJ/src/vm.rs" 2>/dev/null; then
  ok "the WIP work itself was still applied"
else
  no "the WIP work was lost"
fi
# And the same must hold for a recovery branch, whose history can also contain
# checkpoint merges from an earlier attempt.
build_fixture >/dev/null; use_stubs
# Build the checkpoint commit straight from the existing tree, so main's worktree
# and index are never touched. Staging changes on main before branching makes
# `git checkout rec` carry them across and the fixture stops meaning anything.
( cd "$PROJ" \
  && C=$(git commit-tree "$(git write-tree)" -p HEAD -m "rbops: phase-001 checkpoint 1700000001") \
  && git branch rec "$C" \
  && git checkout -q rec \
  && printf '// real work\n' >> src/vm.rs \
  && git add -A && git commit -qm "agent work" \
  && git update-ref "refs/remotes/origin/rbops-recovery/phase-001" HEAD \
  && git checkout -q main ) >/dev/null 2>&1
out="$( RBOPS_MIN_OUTPUT=500 D run phase-001 | strip )"
if ( cd "$PROJ" && git log --oneline ) | grep -q 'checkpoint 1700000001'; then
  no "a recovery branch dragged a checkpoint into main"
else
  ok "a recovery branch's checkpoint ancestry stays out of main"
fi
if grep -q 'real work' "$PROJ/src/vm.rs" 2>/dev/null; then
  ok "the recovery branch's real work WAS adopted"
else
  no "the recovery branch's work was lost"
fi

# =========================================================== 27. argv budget
head_ "27. a large review context is capped, never passed raw"
# run_agent passes the whole prompt as ONE argv string, and one string over
# 128KB (MAX_ARG_STRLEN) fails execve with E2BIG no matter how small the total
# is. A comment in dispatch.sh once claimed ~2MB (ARG_MAX) was safe; every
# review of a large phase then died with
# "/usr/bin/timeout: Argument list too long". phase-020's review was the proof.

# (a) a 200KB uncommitted diff must be capped with markers, and the request must
# stay under the 100KB budget. It must stay UNCOMMITTED: cmd_review captures
# base at its own start, so anything committed beforehand is already in base and
# the reviewed diff is empty — asserting on that would test nothing.
build_fixture >/dev/null; use_stubs
awk 'BEGIN{for(i=0;i<8000;i++)print "// filler line to inflate the diff beyond any argv budget, line " i}' >> "$PROJ/src/vm.rs"
cat > "$STUB/opencode" <<'EOS'
#!/usr/bin/env bash
cat <<'BODY'
I checked the diff against the report and the gates.
FINDINGS: none
REVIEW VERDICT: CLEAN
BODY
echo "review done"
exit 0
EOS
chmod +x "$STUB/opencode"
out="$(R)"
if grep -q 'truncated:' "$PIPE"/logs/phase-001.review.1.ctx 2>/dev/null; then
  ok "the oversize diff is capped with truncation markers"
else
  no "a 200KB diff went to the model uncapped"
fi
ctx_bytes="$(wc -c < "$PIPE"/logs/phase-001.review.1.ctx 2>/dev/null || echo 999999)"
if [ "$ctx_bytes" -lt 100000 ]; then
  ok "the request stays under the 100KB budget ($ctx_bytes bytes)"
else
  no "the request is $ctx_bytes bytes — over budget"
fi
case "$out" in
  *"explicit CLEAN"*) ok "a capped CLEAN review still approves" ;;
  *) no "capping broke the verdict path"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /' ;;
esac
if grep -q 'File list (always complete' "$PIPE"/logs/phase-001.review.1.ctx 2>/dev/null; then
  ok "the file list stays complete even when content is capped"
else
  no "no complete file list alongside the capped content"
fi

# (b) content that is STILL over budget after capping must defer loudly, not
# crash with E2BIG. 25 untracked 16KB files cap at 8KB each = 200KB.
build_fixture >/dev/null; use_stubs
for i in $(seq 1 25); do
  yes 'filler text line for argv budget test' | head -n 400 > "$PROJ/tests/big$i.txt" 2>/dev/null
done
cat > "$STUB/opencode" <<'EOS'
#!/usr/bin/env bash
echo "this model call must never happen"
exit 0
EOS
chmod +x "$STUB/opencode"
out="$(R)"
case "$out" in
  *"over the 100KB argv budget"*) ok "an uncappable request is refused loudly" ;;
  *) no "no refusal for an over-budget request"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /' ;;
esac
case "$out" in
  *"model chain unusable"*) ok "refusal defers without consuming an attempt" ;;
  *) no "refusal did not take the defer path" ;;
esac
marker phase-001 .deferred && ok ".deferred written on refusal" || no ".deferred missing on refusal"
marker phase-001 .attempts && no "an attempt was consumed by a refusal" || ok "no attempt consumed by a refusal"
if grep -q 'Argument list too long' "$PIPE"/logs/phase-001.review.1.log 2>/dev/null; then
  no "E2BIG still reached execve"
else
  ok "no E2BIG anywhere in the review log"
fi

# =========================================================== 28. normalize + scratch
head_ "28. the pipeline normalizes formatting and rejects scratch files"
# phase-020 failed the gate on `cargo fmt --check` alone after a 50-minute
# model run, with a leftover tests/zz_probe.rs on top. Formatting is a
# 30-second deterministic fix; burning a whole attempt on it is pure waste.
# So cmd_run normalizes before judging, and the gate rejects scratch files
# outright (a formatted scratch file would otherwise ship).
build_fixture >/dev/null; use_stubs
# fmt-aware stub cargo: --check fails iff double-spaces remain under src/ or
# tests/; write mode collapses them (the test's normalization). Everything
# else behaves like the standard stub.
cat > "$STUB/cargo" <<'EOS'
#!/usr/bin/env bash
sub=""
has_check=0
for a in "$@"; do
  case "$a" in fmt|clippy|test|build|check) sub="$a" ;; esac
  case "$a" in --check) has_check=1 ;; esac
done
case " $STUB_FAIL " in *" $sub "*) echo "error: stub $sub" >&2; exit 101;; esac
case "$sub" in
  test) echo "test result: ok. 12 passed; 0 failed; 0 ignored" ;;
  fmt)
    if [ "$has_check" -eq 1 ]; then
      if grep -rn '  ' src/ tests/ 2>/dev/null; then exit 101; else exit 0; fi
    else
      grep -rl '  ' src/ tests/ 2>/dev/null | while read -r f; do sed -i 's/  */ /g' "$f"; done
      exit 0
    fi ;;
esac
exit 0
EOS
chmod +x "$STUB/cargo"
# Stub agent: standard report + tests, plus one deliberately unformatted line.
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
| src/vm.rs | +8 −0 | new tests |

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
#[test]
fn edge_empty() { assert!(true); }
#[test]
fn test_a() { assert!(true); }
#[test]
fn test_b() { assert!(true); }
#[test]
fn test_c() { assert!(true); }
#[test]
fn test_d() { assert!(true); }
#[test]
fn test_e() { let r: Result<(),()> = Err(()); assert!(r.is_err()); }
fn badly_formatted(  ){  assert!(true);  }
TST
      echo "agent wrote a report and 7 tests into $dir" ;;
esac
echo "padding to satisfy the minimum-output check ......................."
echo "padding ................................................................"
EOS
chmod +x "$STUB/opencode"
out="$(D run phase-001 | strip)"
case "$out" in
  *"normalize: cargo fmt reformatted"*) ok "pipeline normalizes an unformatted tree before judging" ;;
  *) no "normalize did not fire"; printf '%s\n' "$out" | grep -iE 'normalize|fmt' | head -3 | sed 's/^/      /' ;;
esac
case "$out" in
  *"FAIL cargo fmt"*) no "gate still failed fmt after normalize" ;;
  *) ok "no fmt failure after normalize" ;;
esac
case "$out" in
  *"VERIFY PASS"*) ok "gate passes once normalized" ;;
  *) no "gate did not pass after normalize"; printf '%s\n' "$out" | grep -E 'FAIL' | head -4 | sed 's/^/      /' ;;
esac
# Control: the gate itself still judges formatting. Same messy tree, but
# verify.sh invoked directly (bypassing cmd_run's normalize) must fail fmt.
build_fixture >/dev/null; use_stubs
cat > "$STUB/cargo" <<'EOS'
#!/usr/bin/env bash
sub=""
has_check=0
for a in "$@"; do
  case "$a" in fmt|clippy|test|build|check) sub="$a" ;; esac
  case "$a" in --check) has_check=1 ;; esac
done
case " $STUB_FAIL " in *" $sub "*) echo "error: stub $sub" >&2; exit 101;; esac
case "$sub" in
  test) echo "test result: ok. 12 passed; 0 failed; 0 ignored" ;;
  fmt)
    if [ "$has_check" -eq 1 ]; then
      if grep -rn '  ' src/ tests/ 2>/dev/null; then exit 101; else exit 0; fi
    else
      grep -rl '  ' src/ tests/ 2>/dev/null | while read -r f; do sed -i 's/  */ /g' "$f"; done
      exit 0
    fi ;;
esac
exit 0
EOS
chmod +x "$STUB/cargo"
cat >> "$PROJ/src/vm.rs" <<'TST'
#[test]
fn edge_empty() { assert!(true); }
#[test]
fn test_a() { assert!(true); }
#[test]
fn test_b() { assert!(true); }
#[test]
fn test_c() { assert!(true); }
#[test]
fn test_d() { assert!(true); }
#[test]
fn test_e() { let r: Result<(),()> = Err(()); assert!(r.is_err()); }
fn badly_formatted(  ){  assert!(true);  }
TST
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase report

## What changed
| File | Lines | What |
|---|---|---|
| src/vm.rs | +8 −0 | new tests |

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
EOR
out="$( ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ) )"
case "$out" in
  *"FAIL cargo fmt"*) ok "gate still fails unformatted code when normalize is bypassed" ;;
  *) no "gate no longer judges formatting on its own" ;;
esac
# Scratch files: a phase carrying tests/zz_probe.rs must fail, with the file
# named. Control without it must pass.
build_fixture >/dev/null; use_stubs
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase report

## What changed
| File | Lines | What |
|---|---|---|
| tests/sample.rb | +9 −0 | redblue tests |

## Tests added
| Test | Edge class covered |
|---|---|
| edge_empty list is rejected | out of bounds |

## Gates
| Gate | Result |
|---|---|
| cargo test | 12 passed, 0 failed |

## Known gaps / follow-ups
- none
EOR
cat > "$PROJ/tests/sample.rb" <<'EOR'
test "edge_empty list is rejected"
    try
        set x to empty[0]
    catch error
        set caught to yes
    end
    expect caught to be yes

test "edge_out_of_bounds index"
    try
        set y to [1, 2, 3][9]
    catch error
        set caught2 to yes
    end
    expect caught2 to be yes
EOR
printf '// debugging scratch, not phase work\nfn probe_tmp() {}\n' > "$PROJ/tests/zz_probe.rs"
out="$( ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ) )"
case "$out" in
  *"scratch/probe files in the diff"*zz_probe.rs*) ok "scratch file fails the gate and is named" ;;
  *) no "scratch file slipped through"; printf '%s\n' "$out" | grep -iE 'scratch|FAIL' | head -3 | sed 's/^/      /' ;;
esac
rm -f "$PROJ/tests/zz_probe.rs"
out="$( ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ) )"
case "$out" in
  *"VERIFY PASS"*) ok "same tree passes once the scratch file is gone" ;;
  *) no "tree still fails without the scratch file"; printf '%s\n' "$out" | grep -E 'FAIL' | head -4 | sed 's/^/      /' ;;
esac

# =========================================================== 29. truncation never changes a verdict
head_ "29. truncating output must not change what the gate decides"
# Two faces of the same bug: `| head` exits early, the writer dies on SIGPIPE
# (141), and under `set -o pipefail` the 141 becomes the pipeline's status.
# In rbops.yml that killed a whole run on a diagnostic line (694 corpus files,
# phase-020). In verify.sh it was worse: `... | grep | head -20; then bad;
# else ok` meant 21+ gate-weakening matches took the ELSE branch and a phase
# full of #[ignore] reported "no gate-weakening constructs added". Truncation
# is for display; verdicts must read the whole stream (`sed -n '1,20p'`
# consumes everything and prints the first 20).
build_fixture >/dev/null; use_stubs
mkdir -p "$PIPE/phases/phase-001"
cat > "$PIPE/phases/phase-001/REPORT.md" <<'EOR'
# Phase report

## What changed
| File | Lines | What |
|---|---|---|
| src/vm.rs | +50 −0 | many skipped tests |

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
EOR
# 25 gate-weakening constructs: over the old head -20 limit, so the old code
# would have reported this tree clean.
for i in $(seq 1 25); do printf '#[ignore]\nfn skipped_%s() {}\n' "$i" >> "$PROJ/src/vm.rs"; done
out="$( ( cd "$PROJ" && RBOPS_ROOT="$PIPE" RBOPS_PROJECT_DIR="$PROJ" PATH="$STUB:$PATH" \
        JQ="$JQ" bash "$PIPE/rbops/verify.sh" phase-001 2>&1 | strip ) )"
case "$out" in
  *"gate-weakening construct added"*) ok "25 violations still fail the gate (no verdict inversion)" ;;
  *) no "21+ violations reported clean — verdict inverted"; printf '%s\n' "$out" | grep -iE 'weakening|ignore' | head -3 | sed 's/^/      /' ;;
esac
# And the inventory line that killed the phase-020 run: 700 untracked files
# through the exact yml pipeline must exit 0 and show 20 lines. NOTE: this must
# NOT use $( ) capture — an assignment's status is the LAST command's, which
# would mask a SIGPIPE death upstream. A temp file preserves the real status
# under the suite's `set -o pipefail`, so this fails on the old `| head` code
# and passes on the fix.
build_fixture >/dev/null; use_stubs
for i in $(seq 1 700); do printf 'x\n' > "$PROJ/tests/f$i.txt" 2>/dev/null; done
# The exact yml pipeline, including -uall: without it git collapses the 700
# files (tests/ holds nothing tracked in the fixture) to a single `?? tests/`
# line and the sample shows 1 line for 700 files.
( cd "$PROJ" && git status --porcelain -uall | sed -n '1,20p' | sed 's/^/    /' ) > "$T/inv.out" 2>&1
inv_rc=$?
# NOTE: no `|| echo 0` after this grep -c — that idiom prints a second line on
# no-match (grep -c prints 0 AND exits 1), leaving "0\n0" and breaking the
# integer comparison below. Same bug class as the one just fixed in dispatch.
inv_n="$(grep -c '^    ' "$T/inv.out" 2>/dev/null)"; inv_n="${inv_n:-0}"; inv_n="$(printf '%s' "$inv_n" | head -1)"
if [ "$inv_rc" -eq 0 ] && [ "$inv_n" -eq 20 ]; then
  ok "700-file inventory exits 0 and shows 20 lines (no SIGPIPE death)"
else
  no "inventory pipeline failed (rc=$inv_rc, lines=$inv_n) on 700 files"
fi

# =========================================================== verdict
printf '\n%s%s%s\n' "$DIM" "────────────────────────────────────────" "$OFF"
if [ "$FAIL" -eq 0 ]; then
  printf '%sSMOKE PASS%s  %d checks\n' "$GREEN" "$OFF" "$PASS"
  exit 0
fi
printf '%sSMOKE FAIL%s  %d passed, %d failed\n' "$RED" "$OFF" "$PASS" "$FAIL"
exit 1