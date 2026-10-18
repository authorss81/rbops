# MANUAL-FINISH - phase-082

Done by hand, not by an agent attempt. The phase was blocked with a real
finding; this note records what was actually changed so the next reader does not
assume a bot got there.

Product commit: `21460a3` (redblue).

## What was wrong

HANDOUT.md demonstrated two functions that do not exist:

- `formats.parse_json` / `formats.to_json` - no such module. JSON and CSV are
  their own modules (`json.parse`, `json.stringify`, `csv.parse`). `formats` was
  removed deliberately in phase-050.
- `list.filter` - never implemented. `list` has `map` and `length`.

Both were sitting in `tests/doc_blocks_known_fail.txt`, so the suite had been
green while two tutorial examples were broken. That is the trap worth naming:
the failure was recorded correctly and still never got fixed, because a correct
known-fail looks exactly like a passing test in the summary line.

## What changed

- The `formats` section became a `json` section using `json.parse` /
  `json.stringify`.
- The list example dropped `list.filter`.
- Redblue has no single-quoted strings, so the JSON literal uses escaped inner
  quotes: `json.parse("{\"name\": \"Alice\"}")`, matching AGENTS.md.
- New `tests/handout_claims_test.rs` pins the handout's claims against
  `stdlib::MODULES`, runs the corrected block through the real `rb` binary, and
  asserts the two wrong names are REFUSED rather than silently no-op'ing.
- Doc-block registry line numbers re-derived from the real fences:
  42, 126, 133, 140, 149, 156, 162, 250.

## Left failing on purpose

`HANDOUT.md:162` uses `ask`, which has no equivalent: `console` has `log`,
`error` and `clear`, and there is no input builtin. It stays a known-fail.
Adding console input is a feature, not a docs correction.

## Evidence

- `cargo test --test doc_blocks_test` 7 passed
- `cargo test --test handout_claims_test` 6 passed
- Direct run of the corrected block prints `Alice` and `[2, 4, 6]`