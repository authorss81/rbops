# Redblue language invariants

Changes to anything on this list require a phase that **explicitly** re-opens
language design, in its own PROMPT, with its own SPEC.md amendment. A bug-fix
phase that touches one of these is a review BLOCKER.

## Source surface

| Invariant | Value | Why |
|---|---|---|
| Source extension | `.rb` | `rb run`, tooling, LSP grammar |
| Comment | `//` to end of line | every example uses it |
| Assignment | `set <name> to <expr>` | grammar |
| Block terminator | `end` — never `}` | PHILOSOPHY.md: no cryptic symbols |
| Blocks | `to…end`, `if…end`, `for…end`, `object…end`, `test…end` | — |
| Printing | `say <expr>` | 100% of examples, the REPL, all docs |
| String interpolation | `"Hello, {name}!"` | lexer + parser tests |
| Comparison phrasings | `is greater than`, `is less than`, `is equal to`, `at` (index) | plain-English core |
| Booleans | `yes` / `no` (not true/false) | `Value::YesNo` |
| Absence | `nothing` (not nil/null) | `Value::Nothing` |
| Lists | `[a, b, c]`, trailing comma allowed | parser |
| Records | `{key: value}` | parser |
| Module import | `import X` / `import X, Y as Z` | stdlib |
| Test block | `test "name" … expect x to be y … end` | testing |

## Rust public API (`redblue::`)

Changing any of these is a breaking change requiring a major version bump.

```rust
Value::Nothing | Number(f64) | Text(String) | YesNo(bool)
       | List(Vec<Value>) | Record(..) | Object(..) | Function(..) | Builtin(..)

Error::Lexer | Parser | Analyzer | Runtime | Io

pub fn run_file(path: &str) -> Result<(), Error>
pub fn run_source(source: &str) -> Result<(), Error>
pub fn run_test(path: Option<&str>) -> Result<(), Error>
pub struct Vm;  // Vm::new(), Vm::run(&Program)
```

## Pipeline

```
source → Lexer → Parser → Analyzer → VM
```

Module responsibilities must not leak: the lexer must not parse, the parser
must not resolve names beyond syntax, the analyzer must not execute, and the
VM must not parse. A phase that collapses two stages together is a BLOCKER
unless the phase is explicitly a compiler-architecture phase.

## Behavioural guarantees

These must hold after every phase. `rbops/verify.sh` checks the first three
directly; the rest are covered by the Redblue suite once phase-003 lands.

1. `examples/*.rb` and `modules/*.rb` all run successfully.
2. `cargo test` is green with a non-zero passing count.
3. `cargo clippy -- -D warnings` is silent.
4. A malformed program produces a **spanned diagnostic**, never a panic,
   never a process abort, never a silent success.
5. No user-reachable path allocates without bound; recursion, loop iterations
   and output are all capped.
6. Output is deterministic: no `HashMap` iteration order, no wall clock, no
   unseeded randomness in anything observable.
7. Record and object key order is insertion order, stable across processes.
8. Division by zero, `NaN` and `±Infinity` have documented, tested outcomes.
9. Errors are catchable by the test harness; they do not abort the process.
10. `examples/` is the specification by example and is treated as such.

## Re-opening an invariant

If a phase genuinely must change one, its PROMPT must contain a section
`## Language change` that states:

- which invariant, and the old and new form
- the SPEC.md amendment, written out in full
- the migration path for existing `.rb` programs
- why the change is a general language improvement, not a bootstrap convenience

Without that section the gate's reviewer pass will block the phase. This rule
exists specifically to stop "we'll just change the language to make
self-hosting easier" from happening quietly.