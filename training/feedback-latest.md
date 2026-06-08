# Judge Feedback — iter734

**Phase**: extended | **Governing label**: PASS | **Overall avg**: 4.84 (>= 3.5 floor; OVERALL AVERAGE governs, no per-Q override)

All four function forms VERIFIED against trino.io/docs/467 (conversion.html, math.html, string.html) on 2026-06-08 — not scored against resources/.

## Per-Q scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — typeof (CRITICAL FIX-A re-probe) — 5 / 5 / 5 / 5 = 5.00
Responder used `typeof(order_total)`, explained it returns the type as a varchar string (`'varchar(20)'`, `'bigint'`, `'decimal(18,2)'`), correctly diagnosed that `varchar(...)` means the column is text (explaining the mixed number/text behavior + why `SUM()` fails), then gave the `CAST(... AS DECIMAL(18,2))` fix with `TRY_CAST` for bad values.
- DOCS-VERIFIED: conversion.html — `typeof(expr)` "Returns the name of the type of the provided expression" (returns varchar). `cast`/`try_cast` entries confirmed.
- Used `typeof` DIRECTLY — NOT "check the schema", NOT just "use CAST". This is precisely the FIX-A target.
- **typeof FIX-A VERDICT: CLOSED.** (1st passing re-probe datapoint at iter734; iter733 baseline scored 2.75 FINDABLE-BUT-MISSING. One more angle recommended to bulletproof.)

### Q2 — round down to nearest multiple of N — 4 / 4.5 / 4 / 5 = 4.375
SQL is CORRECT: `FLOOR(customer_age / 10) * 10` floors to the nearest lower multiple of 10 for non-negative ages; user said "round down to the nearest multiple," so FLOOR (not round) is the right choice. Generalization to 5/100 is right.
- **Prose nit (genuine, light):** the explanation says "integer division (floor division) truncates toward zero — so 27/10 = 2." This muddles two distinct concepts:
  - Trino INTEGER division (`/` on two integers) truncates **toward zero** — so for an INTEGER `customer_age`, `customer_age/10` is already truncated and the wrapping `FLOOR` is a redundant no-op.
  - `FLOOR` rounds toward **negative infinity** — these DIFFER for negatives: `-27/10` (int division) = -2, but `FLOOR(-27/10.0)` = -3.
  - "integer division (floor division)" is itself self-contradictory: in Trino, integer division is TRUNCATION, not floor division.
- For the non-negative age use case the result is correct, so this is a small accuracy/clarity ding, NOT a defect. -1 accuracy / -1 clarity, light. Do not over-penalize — result is right.
- iter735 LIGHT-TOUCH flag below.

### Q3 — sign — 5 / 5 / 5 / 5 = 5.00
`sign(revenue_delta)` + `CASE sign(...) WHEN 1 ... WHEN -1 ... WHEN 0 ...` mapping to growth/loss/flat.
- DOCS-VERIFIED: math.html — "0 if the argument is 0, 1 if greater than 0, −1 if less than 0"; return type same as input. Mapping is exact and clean.

### Q4 — split delimited string to array — 5 / 5 / 5 / 5 = 5.00
`split(tags, ';')` → array(varchar), `CROSS JOIN UNNEST(...) AS t(tag)` explode, `TRIM(tag)` note for spaces, `split_to_map()` pointer for KV pairs.
- DOCS-VERIFIED: string.html — `split(string, delimiter)` "Splits string on delimiter and returns an array"; 3-arg `split(string, delimiter, limit)` form also exists (responder didn't need it; no error).
- Clause order valid: `CROSS JOIN UNNEST` in FROM, `WHERE event_date = DATE '...'` after, `GROUP BY` after — all sound.

## Overall

**Overall average = (5.00 + 4.375 + 5.00 + 5.00) / 4 = 4.84 — PASS** (threshold 3.5).

## iter735 flags

1. **typeof FIX-A — CLOSED but probe once more.** Re-probe from a 3rd phrasing to bulletproof: e.g. "an expression keeps coming out the wrong type — how do I see what Trino thinks it is mid-query?" Confirm the responder leads with `typeof()` and routes to CAST/TRY_CAST, not schema-inspection.
2. **Q2 floor-vs-truncate prose — LIGHT TOUCH-UP (no defect).** At the `FLOOR(x/N)*N` round-down-to-multiple canonical (r07 §1.9.1), add a one-line clarification distinguishing:
   - integer division `/` (two integers) = truncates **toward zero**;
   - `FLOOR(x/N.0)` = rounds toward **negative infinity** (differs for negatives: `-27/10`=-2 vs `FLOOR(-27/10.0)`=-3);
   - note that for an INTEGER column, `FLOOR(intcol/N)` is redundant (already truncated) — use `FLOOR` after real division (`/N.0` or DECIMAL) when you want true floor semantics.
   Avoid the contradictory phrase "integer division (floor division)". Keep `FLOOR(x/N)*N` as the round-DOWN-to-multiple lead and `round(x/N)*N` as the round-to-NEAREST alt. Additive only; preserve existing canonical verbatim.

No new genuine gaps. Q3/Q4 fully clean and docs-verified.
