# AGENTS.md — RBOPS (Redblue Autonomous Ops)

This file is the contract for every agent that RBOPS dispatches. It is injected
verbatim into every phase context by `rbops/dispatch.sh`. It is law, not advice.

You are running inside an automated pipeline. There is no human in your loop.
The only thing that makes your work count is that it passes a machine gate.
Nothing you *say* about your work is evidence. Only what `rbops/verify.sh`
proves is evidence.

---

## 0. What RBOPS is

RBOPS is a self-dispatching, self-auditing development pipeline for the
**Redblue** programming language.

- **Dispatcher** (`rbops/dispatch.sh`) — picks the next eligible phase from
  `rbops/phases.json`, runs it, records state, gates it, triggers the next tick.
- **Manifest** (`rbops/phases.json`) — the single source of truth. Machine-readable.
  If a phase is not in the manifest, it does not exist.
- **Gate** (`rbops/verify.sh`) — the only authority on whether work is real.
- **Auditor** (`.opencode/agent/auditor.md`) — periodically reads the codebase,
  finds new defects and missing capabilities, and **writes new phases**.
- **Bootstrap** — the endgame: Redblue compiles Redblue.

### The state machine

```
  IDLE ──dispatch──▶ RUNNING ──verify ok──▶ REVIEW ──ok──▶ .done ──▶ next phase
                      │
                      ├─ verify fail ──▶ RETRY (attempt+1)
                      ├─ model error ──▶ .deferred (retry later tick)
                      ├─ max attempts ──▶ .blocked (needs human)
                      └─ budget spent ──▶ .starved (needs new phases)
```

State is **git**, not a database. Each phase directory in `phases/` carries
marker files that are committed. Stateless runners therefore work.

---

## 1. HARD RULES — violating any of these fails the phase

1. **Do not touch RBOPS itself.** Never edit `.github/workflows/`, `rbops/`,
   `rbops/phases.json`, or any `.opencode/agent/*.md`. The bot token has no
   `workflows` scope and a push touching `.github/` is refused. Do not waste a
   phase discovering this.
2. **Never weaken a gate.** You may not modify `verify.sh`, delete a failing
   test, add `#[ignore]`, add `.skip`, loosen an assertion, lower a threshold,
   raise a timeout to dodge a hang, or comment out a test body. **Any of these
   is an automatic phase failure and a review-blocking finding.** There is no
   exception for "it was flaky". Flaky tests get fixed, not muted.
3. **No claiming success you did not achieve.** If `verify.sh` is red, the phase
   is not done. Report the failure honestly in `REPORT.md` and exit.
4. **Do not run long builds locally.** CI is the only place `cargo build` runs.
   Locally use `cargo check --all-targets` at most, and only if essential.
5. **Never commit secrets, API keys, tokens.** Check `.gitignore` covers
   `.env`, `*.key`, `target/`.
6. **No destructive git.** No `push --force` to `main`, no `reset --hard` on
   shared history, no rewriting other phases' commits.
7. **One phase, one concern.** If you discover work that does not belong to your
   phase, do not do it. Record it in `phases/phase-NNN/FINDINGS.md` so the
   auditor can promote it to a real phase.
8. **No unbounded speculation.** Do not rewrite the architecture, rename public
   types, change the `.rb` file extension, or redesign the grammar without an
   explicit phase that says so.

---

## 2. Redblue — what must never silently change

Redblue is a tree-walking interpreter: `Lexer → Parser → Analyzer → VM`.
Its contract is *readable English-like source*.

**Language invariants.** A phase may not change these without explicitly
re-opening the language design in its own PROMPT:

| Invariant | Why |
|---|---|
| `.rb` is the source extension | Tooling, `rb run`, LSP |
| `to … end`, `if … end`, `for … end` use `end`, never braces | Core philosophy |
| `set x to <expr>` is assignment | Grammar |
| `say` prints | 100% of examples depend on it |
| `Value` variants are `Nothing/Number/Text/YesNo/List/Record/Object/Function/Builtin` | Public API, `redblue::Value` is exported |
| Errors are `Error::{Lexer,Parser,Analyzer,Runtime,Io}` | Public API |
| Trailing-comma and `{interp}` string syntax | Parser tests |
| Existing tests in `tests/` keep passing | — |

**Backwards compatibility.** `examples/*.rb` and `modules/*.rb` are the language's
specification-by-example. Every phase must keep them working. The gate runs them.

---

## 3. Testing mandate — this is where most phases fail

> Every test must assert something that can fail.

Redblue's current test layer is broken in exactly this way, which is why Phase 1
exists. From the moment you touch behaviour, your code is held to the standard
the rest of the project has not yet reached.

### 3.1 Every test must have

1. **A real assertion.** A Redblue test must use `expect <expr> to be <value>`,
   `expect <expr> to contain <value>`, or `assert.equal`. If your test only
   "runs without crashing", it is a smoke test: label it `// smoke` and it will
   not count toward the phase's test quota.
2. **At least one edge case.** The happy path alone is not a test.
3. **A named failure message.** `expect x to be 5` must be able to fail with a
   useful message.
4. **Determinism.** No wall-clock, no filesystem outside a temp dir, no network,
   no reliance on `HashMap` iteration order.

### 3.2 Mandatory edge-case matrix

For **every** behaviour you implement or change, test at minimum:

- **Empty / zero / "nothing"** — empty list, empty text, `nothing`, `0`, `""`
- **Singleton and boundary** — exactly one element; index `0` and index `len-1`
- **Out of bounds** — index `-1`, index `len`, index `999` (must be a clean
  runtime error, never a panic, never UB)
- **Type mismatch** — number where text expected, record where list expected
- **Type coercion boundaries** — `0/0`, `1/0`, `-0.0`, `NaN`, `±Infinity`,
  `2^53±1` (precision), `-2^31`, integer overflow past `i64`
- **Unicode and escapes** — empty text, `"`, `\`, newline in string,
  emoji/CJK/RTL, combining marks, very long strings
- **Nesting and recursion** — nested lists, nested records, 3+ closure/object
  scopes, mutual recursion
- **Duplicate and missing keys** — record with repeated keys, missing field access
- **Malformed input** — unterminated string, unclosed `end`, stray token,
  empty file, BOM, CRLF line endings, non-UTF8 bytes
- **Resource and state** — file that does not exist, permission denied, path with
  spaces, deeply nested call stack, infinite loop guard

Pick the rows that apply. A phase that changes the VM must justify in
`REPORT.md` which rows are N/A and why.

### 3.3 Test quota (hard floor, not a target)

The gate enforces a floor: **≥ 3 new `#[test]` functions or ≥ 2 new Redblue
`test` blocks**, plus **≥ 1 test named `edge_*`**, **≥ 1 test that asserts a
failure is produced**, and **zero** newly-skipped or newly-ignored tests.

Deliberately, the count floor is low. It exists to catch "no verification at
all", not to judge sufficiency — a hard 6 once failed a genuinely good phase
with 5 edge tests, which is the gate being smarter than the reviewer. Judging
whether the tests COVER the change is the reviewer's job (AGENTS.md section 5:
an untested branch is a MAJOR finding, fixed and re-gated). The gate is the
floor — cheap, mechanical, never wrong in the pass direction. The reviewer is
the ceiling.

### 3.4 The four gates, in order

```
cargo fmt --check          # formatting        (fails on any diff)
cargo clippy -- -D warnings# lints, zero warnings tolerated
cargo test                 # full suite, 0 failures
./rbops/verify.sh          # project-specific gates
```

---

## 4. REPORT.md contract — required, machine-checked

`phases/phase-NNN/REPORT.md` must exist. `verify.sh` rejects the phase without it.

```markdown
# Phase NNN — <title>

## What changed
| File | Lines | What |
|---|---|---|
| src/vm.rs | +40 −12 | call depth counter in call_builtin |

## Tests added
| Test | Edge class covered |
|---|---|
| edge_call_stack_overflow | out of bounds / resource |
| test_zero_division | type/numeric boundary |

## Gates
| Gate | Result |
|---|---|
| cargo fmt --check | pass |
| cargo clippy -- -D warnings | pass |
| cargo test | 42 passed, 0 failed |
| rbops/verify.sh | pass |

## Invariants touched
- None  /  - `expect` now returns a catchable Runtime error (was: process abort)

## Known gaps / follow-ups
- No stack-depth limit for mutually recursive objects yet → FINDINGS.md
```

A REPORT.md with empty tables, or with a `Gates` table that does not match what
`verify.sh` printed, is a **fake completion** and will be caught by the auditor.

---

## 5. Reviewer contract

The reviewer (`.opencode/agent/reviewer.md`) is **read-only**: no edit, no bash.
It reviews the phase diff after the gate is green and emits `FINDINGS:`.
Findings are then fixed by a fresh implementer run, and **the full gate is run
again**. A phase with open BLOCKER/MAJOR findings is not `.done`.

The reviewer must specifically hunt for:

- **Fake completion** — REPORT.md claims a gate passed that it did not; tests
  that cannot fail; assertions weakened; thresholds lowered.
- **Panic paths** — any reachable `panic!`/`unwrap`/indexing/`unreachable!`.
- **Unbounded resource use** — no recursion limit, no loop guard, no output cap.
- **Nondeterminism** — `HashMap` iteration reaching output, floats in equality.
- **Error-message regressions** — a previously-rejected program now accepted, or
  a crash where an error was expected.
- **Spec drift** — behaviour that now contradicts `SPEC.md` or `docs/GRAMMAR.md`.

---

## 6. Auditor contract — the phase-generating loop

Every N phases, the **auditor** runs. It must:

1. Measure the codebase: test count, coverage of `src/*.rs`, gate health,
   `todo`/`unimplemented`/`FIXME` counts, largest functions, clippy debt.
2. Diff the language's actual behaviour against `SPEC.md` and `ROADMAP.md`
   and list every gap as a concrete, file:line-anchored finding.
3. Turn each finding into a **new phase**: id, title, severity, dependencies,
   estimated risk, and an acceptance gate — written into `rbops/phases.json`.
4. Refuse to invent work. A phase with no file:line evidence is not created.

The auditor is the only component permitted to append to `phases.json`.

---

## 7. Bootstrap contract — the endgame

**Goal:** Redblue compiles Redblue.

This is a ladder, not a leap. Each rung must be green before the next:

| Stage | Artifact | Definition of done |
|---|---|---|
| **S0** | Rust `rb` (exists today) | `cargo test` green, `rb` runs all `examples/*.rb` |
| **S1** | `rb compile` — Redblue **bytecode compiler** written in Rust | emits `.rbc`; `rb vm file.rbc` runs it |
| **S2** | The S1 compiler **rewritten in Redblue** | `rb run bootstrap/compiler.rb` produces byte-identical `.rbc` to S1 for a corpus |
| **S3** | S2-compiled compiler compiles itself | fixed point: `stage1.rbc == stage2.rbc` byte-for-byte |
| **S4** | S3 binary is the shipped `rb` | `rb` built by `rb` passes the full gate |

Non-negotiable rules for any phase in the S2–S4 range:

- **No shimming.** You may not add a Rust-only fast path that the Redblue path
  silently falls back to. If it is not implemented in Redblue, it does not exist.
- **Fixed-point is the only proof.** "It compiles" is not done. Byte-identical
  output over a ≥200-program corpus is done.
- **Self-hosting forbids changing the language to make it easier.** Any grammar
  change needed for S2+ must be justified by general language merit in its own phase.
- **The gate for every bootstrap phase is the S3 fixed-point test**, plus the
  normal four gates. No exceptions, no "next phase will finish it".

---

## 8. Communication rules

- Report facts, not narrative. "`rbops/verify.sh` reports `edge_foo: FAILED`" beats "there may be an issue with foo".
- When blocked, say exactly what you tried and what the exact error was.
- Never fabricate a file:line. If you did not read the line, do not cite it.
- Prefer the smallest correct change. A 400-line refactor in a bug-fix phase
  is a review BLOCKER.