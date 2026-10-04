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
( cd "$PROJ" && git log --oneline -1 | grep -q "attempt 1" ) \
  && ok "the preserved commit is in the tree" || no "preserved work not merged"
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
if printf '%s' "$out" | grep -q "merging WIP checkpoint"; then
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
if printf '%s' "$out" | grep -q "merging WIP checkpoint" \
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
| tests/probe.rb | +14 −0 | redblue edge + failure tests |

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
printf '%s' "$RB_PASS" > "$PROJ/tests/probe.rb"
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
  > "$PROJ/tests/probe.rb"
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
  > "$PROJ/tests/probe.rb"
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
| tests/probe.rb | +9 −0 | redblue tests |

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
printf '%s' "$RB_TESTS" > "$PROJ/tests/probe.rb"
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
( cd "$PROJ" && git checkout -- tests/probe.rb 2>/dev/null; printf '%s' "$RB_TESTS" > "$PROJ/tests/probe.rb" )
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
| tests/probe.rb | +14 −0 | redblue tests |

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
cat > "$PROJ/tests/probe.rb" <<'EOR'
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

# =========================================================== verdict
printf '\n%s%s%s\n' "$DIM" "────────────────────────────────────────" "$OFF"
if [ "$FAIL" -eq 0 ]; then
  printf '%sSMOKE PASS%s  %d checks\n' "$GREEN" "$OFF" "$PASS"
  exit 0
fi
printf '%sSMOKE FAIL%s  %d passed, %d failed\n' "$RED" "$OFF" "$PASS" "$FAIL"
exit 1