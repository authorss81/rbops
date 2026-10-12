# phase-048 — READ THIS FIRST. The manifest contradicted your goal; it no longer does.

## What blocked you, and why it was not your fault

Your goal reads: *"either implement `catch error of <Type>` or correct SPEC.md
to the form the code actually supports."* You chose the second branch, did it
well (18 passing tests, honest FINDINGS entry naming the tagged-error follow-up),
and the gate failed you 3/3 on `must_touch: ["src/"]` — because your diff
touches docs + tests only. The goal permits a docs-only resolution; the gate
forbade it. That is a manifest contradiction, not a work defect, and it is now
fixed: `must_touch` reads `["src/", "docs/"]`, and your re-rendered PROMPT.md
says so.

## What to do on this attempt

1. Resume from `rbops-recovery/phase-048` — your docs + tests are parked there.
   Do NOT rewrite them; they were correct.
2. Run the four gates. With `docs/` satisfying must_touch, the gate should pass
   on the resumed tree plus any small additions you make.
3. Then review and land normally. The `of <Type>` follow-up is phase-089 now —
   it is NOT this phase, do not scope-creep it in no matter what the old
   FINDINGS say about it.

## What NOT to do

Do not implement `of <Type>` here to satisfy the old `src/`-only reading.
That decision was already made and recorded: tagged error values touch `Value`,
both VMs, `Error`, the `.rbc` format and every failure site, and it belongs to
089. Implementing it inside this retry would be the rewrite-wearing-a-fix's-clothes
the pipeline blocks on sight.
