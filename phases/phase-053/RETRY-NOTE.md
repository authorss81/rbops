# RETRY-NOTE — phase-053

**This outranks anything in your generated PROMPT.md.** Two previous attempts
produced **zero bytes** of work. This note exists so a third does the same.

## What went wrong, precisely

Attempt 1 had a 90-minute budget. It spent all of it **reading**:

```
grep -rn ... src/            exploring
ls src/repl/                 exploring
read fn debug_answer, fn complete, fn restore_history, impl Repl ...
cargo fmt --all -- --check   FMT_CLEAN
cargo clippy                 compiles, then the 90-minute timeout kills it
```

It never created a test file and never wrote a line of implementation. The
preserved patch was **0 bytes**. The checkpoint log was **0 bytes**.

`src/repl/` is large because phase-052 created it minutes earlier, so there was a
lot to read. The budget went into reading and the run was killed before step 3
of the method.

Attempts after that never even started — the model chain was unavailable, and
those deferrals were upstream, not yours.

## Budget yourself, or you die the same way

**You have roughly 90 minutes. Spend them like this:**

| Minutes | Do this |
|---|---|
| **0–10** | `ls src/repl/`, read **only** `mod.rs` signatures. Do not read whole files. |
| **10–25** | Write `tests/repl_color_test.rs` with 3–4 `edge_*` tests. Watch them fail. |
| **25–65** | Implement. This is the part that must not get squeezed. |
| **65–85** | `cargo fmt --all && cargo clippy --all-targets -- -D warnings` |
| **85–90** | Write `REPORT.md`. Commit. |

**If you are at minute 40 and have written no test file, stop exploring and
write it.** Reading is the failure mode that killed the last two attempts.

## What this phase actually wants

`phase-053`: **REPL colour system — TTY detection, forced modes, one theme.**

Phase-052 already built the REPL surface (`commands.rs`, `completer.rs`,
`editor.rs`, `history.rs`, `mod.rs`). You are adding colour to it. Look for the
existing `Paint` enum and a `style.paint(...)` call shape — `src/repl/mod.rs`
already has calls in that form.

The smallest honest version:

- detect whether stdout is a TTY (and respect an env override for forcing
  colour on/off, so tests can pin it)
- define a small theme: a few `Paint` variants (Result, Error, Heading at minimum)
- paint the existing output sites through it
- when colour is off, output is **byte-identical** to today — that is the test
  that matters most, because it is the one that can actually fail

## Traps, both verified

1. **Do NOT run `cargo fmt --all`.** The tree is already fmt-clean
   (`cargo fmt --all -- --check` exits 0). A previous attempt ran the bare
   formatter and produced a reformat of phase-052's files for **zero net
   change** — which is part of why its diff was empty. Use `-- --check`.

2. **Do not reformat `src/repl/mod.rs`.** It is phase-052's output. If `fmt`
   reports a diff there, report it in `REPORT.md` and move on. Do not sweep it
   into a colour diff.

Both engines must agree — a program that colours on the tree-walker and not on
the bytecode VM is a real bug, so cover it differentially.