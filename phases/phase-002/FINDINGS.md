# phase-002 — FINDINGS

Out-of-scope observations. Not fixed here; recorded for the auditor to promote
into real phases if it agrees.

## 1. `rbops/verify.sh` does not exist in this checkout

`ls rbops` → `No such file or directory`. Also `ls phases` → no such directory
(only `phases/phase-002/`, created by this phase, exists). The phase prompt
lists `./rbops/verify.sh phase-002` as gate 4 and says to run the four gates
"before claiming anything". That command cannot be run here, so its result in
`REPORT.md` is reported as *not run* rather than invented.

What I ran instead, and its real output:
- `cargo fmt --all -- --check` → pass
- `cargo clippy --all-targets -- -D warnings` → pass, zero warnings
- `cargo test --all-targets` → 39 passed, 0 failed
- `./target/debug/rb test` → `Tests run: 22 / Passed: 21 / Failed: 0`
- `for f in examples/*.rb; do ./target/debug/rb run "$f"; done` → all 6 exit 0

## 2. `rb run modules/MathUtils.rb` fails — pre-existing

```
$ ./target/debug/rb run modules/MathUtils.rb
Error: ParserError: Expected function name     (exit 1)
```

Confirmed pre-existing: `git stash` → rerun on the clean tree → identical error
and exit code. `rb run` treats the file as a top-level program, so a module
(only `define` statements) does not parse. Whether the gate expects modules to
be runnable directly, or expects `import` from a driver script, is a language/
CLI decision this phase must not make. `src/lib.rs:57` (`run_all_tests`) and the
`test` subcommand in `src/main.rs` are the places that would need to change.

## 3. Test discovery order is nondeterministic

`find_test_files` (`src/testing/mod.rs:58`) pushes whatever order `std::fs::read_dir`
yields. `rb test` therefore runs `.rb` suites in a filesystem-dependent order
and prints progress dots in that order. Results are counted, not ordered, so
nothing is wrong today, but output is not reproducible across machines — which
§3.1.4 of `AGENTS.md` calls out as a determinism requirement. A one-line
`files.sort()` would fix it; left out to keep this diff a bug fix. Cheap phase.

## 4. `run_all_tests()` hardcodes the directory `"tests/"`

`src/testing/mod.rs:44`. There is no way to point the Redblue harness at another
suite directory, so the temp-fixture tests in this phase had to reach
`find_test_files` and `TestHarness::run_file` directly (both are reachable only
because the new tests live inside the module). A `run_tests_in(dir)` entry point
would make the harness testable without `#[cfg(test)]`-internal access.

## 5. `run_test_file` and `run_all_tests` duplicate their logic

`src/testing/mod.rs:31` reads a file and runs it; `run_all_tests` does the same
through `TestHarness::run_file`. `run_test_file` appears to have no callers.
Dead public API is a clippy/`dead_code` candidate that `pub` visibility hides.