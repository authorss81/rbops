# Deferred phases — Tier 2 and Tier 3

**Status: deliberately NOT in `rbops/phases.json`. Do not add them without the
user's say-so.**

These were designed during the "where does Redblue go next" discussion and
deliberately held back. Tier 0 (090–094) and Tier 1 (095–109) were added; these
were not, because each one either depends on Tier 1 landing first, or needs a
decision or money that has not been given.

**Why they are not in the manifest.** A manifest entry is auto-selected by
`dispatch.sh`. Adding these would queue work we explicitly agreed to defer, and
the gate would hold up the pipeline on phases whose prerequisites do not exist
yet. This file is the record instead.

**When to promote one:** raise it with the user, state which prerequisite is now
met, and only then add a manifest entry with `depends_on` naming that
prerequisite. Do not promote a whole tier at once.

---

## Tier 2 — Ecosystem and measurement

### 1. Speed phases, each gated on the benchmark harness
**Blocked by:** phase-073 (benchmark harness, already in the manifest, not yet done)
**Also blocked by:** phase-109 (native backend survey) for anything ambitious.

A "make it faster" phase with no baseline is unfalsifiable — improvement is a
claim with no measurement, so a reviewer cannot check it. The harness must land
first; after that, each speed phase reports before/after on a fixed workload.

Honest expectations: Redblue is a tree-walking interpreter, slower than Python.
Redblue already ships a bytecode VM, and tree-walker vs bytecode is the one
genuinely controlled comparison available internally. Cross-language numbers are
only meaningful via a shared published benchmark suite.

### 2. Package publishing — registry, sign, verify
**Blocked by:** needs a hosting decision AND money. This is the **only** item in
the whole backlog that genuinely costs money; it is infrastructure rent plus
publishing identity, not judgment.

Premature regardless: a registry for a language with no third-party packages is a
cost with no users. Revisit when there is an actual package to publish.

### 3. Usability ladder — real programs, small to large
**Blocked by:** soft. Should start as soon as the stdlib is usable, and in
practice it is what *derives* the next stdlib phase rather than following it.

Scope rule that makes this valuable: a handful of programs too large for a single
phase, written the way a person would, all gate-run. Not a flood of trivial
programs — 1,000 fizzbuzzes prove nothing. Precedent: `bootstrap/compiler.rb`
is 2,854 lines of Redblue that compiles Redblue, and the S3 fixed point works.
This is the endgame that proves the language.

### 4. UI components — TUI and web
**Blocked by:** needs Tier 1. A UI module with no regex and no path handling is
a demo, not a toolkit.

Scope: widgets, layout, events. TUI (portable, achievable) or web components
(uses the existing `network` module and WASM playground) — **not** a native
desktop GUI, which is genuinely hard from a sandboxed Rust interpreter and would
consume the pipeline for years while adding zero language capability.

---

## Tier 3 — Ambitious

### 5. OS simulator in Redblue, running on Linux
**Blocked by:** phase-109 (native backend survey) informs scope; realistically
also wants Tier 1 done first.

**This is the achievable one.** Write a CPU emulator, a kernel and a bootloader
*in Redblue*, and run the simulated machine on Linux. Pure Redblue, every line
gate-verified, no native code, no privilege needed. It sits squarely in
Redblue's existing competence — it already ships a compiler and a bytecode VM.

### 6. A real Redblue OS that boots on hardware
**Blocked by:** a native backend that does not exist. Needs Redblue → machine
code, plus privileged hardware access. **Explicitly gated behind phase-109 and
behind any decision to build a backend.** Do not start.

---

## Also parked, for a different reason

- **`cargo fmt --check` unproven in CI** — added to redblue CI, but it has never
  caught anything because nothing has ever been unformatted. Fine; needs no phase.
- **Redblue history: six `rbops: phase-NNN checkpoint` ancestors on main** —
  rewriting shared history. An explicit user decision, never an agent's.
- **Pre-existing test failure** `runtime::tests::edge_a_clock_before_the_epoch_is_a_runtime_error`
  at `src/runtime.rs:1882` on rustc 1.98.1. Untouched, unrelated to any phase here.

---

## Provenance

Designed in discussion on 2026-10-13, in answer to six questions about Redblue's
direction (package manager and large libraries; auditing other languages; UI;
tutorials-as-tests; per-package version control; writing programs to prove
usability). The conclusions from that discussion were recorded as phases 090–109;
these are the parts that were held back.

The governing insight behind the split: **the standard library is the ceiling,
not the REPL.** Tier 0 derives the work, Tier 1 is the substance, and these
tiers rest on things that do not exist yet.