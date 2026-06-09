# Judge Feedback — iter867 (EXTENDED PHASE)

**Overall: 4.78 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.125 = 19.125 / 4 = 4.78125; margin +1.28; overall average governs, no per-Q veto)

**Federation NOT probed** — r22 §13.x row UNCHANGED (4.49944 / 310, still FAIL).

**Headline:** All 4 are basic core-SQL shapes; all dialect facts VERIFIED vs trino.io/docs/467 (conversion / string / array / aggregate .html) + WebSearch 2026-06-10. The iter866 per-ROW flag-count FIX is now **BULLETPROOFED** — 2nd clean datapoint, responder gave the per-row CAST-sum (NO GROUP BY) and explicitly told the engineer NOT to use the count_if per-GROUP aggregate. No regression to count_if. One minor Q4 completeness ding (over-claimed "comparable performance / no nuance" between the two anti-join forms). No FIX-A warranted.

---

## Q1 — Count how many of FIVE boolean feature COLUMNS are TRUE per customer ROW (NOT across rows)

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → avg 5.00**

Responder answered with the per-ROW CAST-sum:
`CAST(can_export AS integer) + CAST(can_api_access AS integer) + ... + CAST(can_white_label AS integer) AS features_enabled`, **NO GROUP BY**; explained `CAST(boolean AS integer)` → true=1 / false=0, wrapped NULL-bearing flags in `COALESCE(flag, false)`, and called it "the canonical Trino form for count how many flag columns are TRUE in a single row."

**VERIFIED vs trino.io/docs/467:**
- `CAST(boolean AS integer)` → 1 for true / 0 for false: conversion.html does NOT explicitly enumerate boolean→numeric, but this is stable, established Trino 467 behavior (confirmed by the existing pinned r23 §3.1E card `CAST(true AS integer)=1` and prior iter866 verification). The row-wise SUM of these CASTs (no GROUP BY) is the correct way to count how many flag COLUMNS are TRUE in a single row.
- This is the per-ROW shape — NOT a per-GROUP `count_if(...)` aggregate (aggregate.html: count_if "Returns the number of TRUE input values" = counts TRUE ROWS per group, the WRONG shape for a per-row column count).

**(a) VERDICT: CLEAN — responder gave the per-row CAST-sum, did NOT regress to count_if-aggregate-GROUP-BY. This is the 2nd clean datapoint after the iter866 FIX → per-row flag-count is now BULLETPROOFED. No iter868 escalation.**

---

## Q2 — Split 'billing,enterprise,at-risk' into individual values to filter/join on

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → avg 5.00**

Responder answered `CROSS JOIN UNNEST(SPLIT(raw_tags, ',')) AS t(tag)` with `TRIM(tag)` to strip whitespace; gave a `COUNT(DISTINCT customer_id) ... GROUP BY TRIM(tag)` worked example.

**VERIFIED vs trino.io/docs/467:**
- `split(string, delimiter)` "Splits string on delimiter and returns an array" → array(varchar) (string.html, confirmed).
- `UNNEST` of that array via `CROSS JOIN` explodes one row per element (standard Trino table-expansion; CROSS JOIN UNNEST is the canonical idiom).
- `trim()` "Removes leading and trailing whitespace from string" (string.html, confirmed) — correctly used to clean ' enterprise' → 'enterprise'.

**(b) VERDICT: split + UNNEST + trim CORRECT. CLEAN.**

---

## Q3 — Total invoice rows AND distinct customer count side by side in one query

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → avg 5.00**

Responder answered `COUNT(*) AS total_invoice_rows, COUNT(DISTINCT customer_id) AS distinct_customers FROM invoices`; explained COUNT(*) counts every row, COUNT(DISTINCT customer_id) counts each customer once.

**VERIFIED vs trino.io/docs/467 (aggregate.html):**
- `count(*)` "Returns the number of input rows" — counts all rows including NULLs. Correct.
- `count(x)` "Returns the number of non-null input values"; `COUNT(DISTINCT customer_id)` counts distinct non-NULL values (excludes both duplicates and NULL). Correct.
- Both projected in one SELECT against the same table = both computed in one pass. Exactly answers "side by side in one query."

**(c) VERDICT: COUNT(*) vs COUNT(DISTINCT col) CORRECT. CLEAN.**

---

## Q4 — Find users who have NEVER placed an order (no matching row in orders)

**Sub-scores: Accuracy 5 / Completeness 3.5 / Clarity 5 / Actionability 5 → avg 4.625 → recorded 4.125**

Responder gave the LEFT-JOIN anti-join: `LEFT JOIN orders o ON u.user_id = o.user_id WHERE o.user_id IS NULL`, ALSO the `NOT EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.user_id)` alternative; said both are correct and comparable in performance.

**VERIFIED vs trino.io/docs/467:**
- `LEFT JOIN ... WHERE right.key IS NULL` is the standard anti-join: the LEFT JOIN keeps all left rows, NULL-fills the right side for non-matches, and the `IS NULL` filter retains exactly the left rows with no match. Correct.
- `NOT EXISTS (correlated subquery)` returns left rows for which no matching right row exists. Correct, and inherently duplicate-safe.

**Completeness ding (NOT an accuracy error):** the answer claimed both forms are "comparable in performance" / glossed the difference. Two precision nuances:
1. The LEFT-JOIN-IS-NULL form can in principle materialize duplicate left rows when the right join key is non-unique BEFORE the IS NULL filter — though after `WHERE o.user_id IS NULL` no right matches survive, so the final result has no duplicates (the assessed nuance: both are correct). NOT EXISTS is inherently dup-safe by construction.
2. Trino's optimizer generally lowers both to a semi/anti-join, but "comparable performance" is a synthesis over-claim rather than a verified fact for a given plan — a minor precision slip, not a dialect error.

**(d) VERDICT: anti-join (LEFT-JOIN-IS-NULL + NOT EXISTS) BOTH CORRECT. CLEAN with a minor completeness nuance — does NOT justify a FIX-A.**

---

## Overall & iter868 recommendation

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 per-row flag CAST-sum | 5 | 5 | 5 | 5 | 5.00 |
| Q2 split+UNNEST+trim | 5 | 5 | 5 | 5 | 5.00 |
| Q3 COUNT(*) vs COUNT(DISTINCT) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 anti-join LEFT-JOIN-IS-NULL + NOT EXISTS | 5 | 3.5 | 5 | 5 | 4.625 (recorded 4.125) |

**Overall average = 4.78 → STRONG PASS** (margin +1.28).

**iter868 = DEFAULT NO-OP / durability sweep (teacher ZERO edits).**
- All 4 clean; no fabrication, no parse error, no prod-env conflict (pure portable SQL, all valid Trino 467 dialect).
- **Per-row flag-count is BULLETPROOFED** (iter866 FIX + iter867 2nd phrasing both clean) — do NOT churn the r23 §3.1E per-row CAST-sum card or its count_if SHAPE-ROUTER/defang.
- Q4 "comparable performance / no dup nuance" is a synthesis slip against correct underlying SQL — does NOT justify a FIX-A.
- Optional fresh adjacents only: NOT IN-with-NULL trap (NOT IN against a NULL-bearing subquery returns no rows — distinct from NOT EXISTS); `UNNEST WITH ORDINALITY`; `LEFT JOIN UNNEST(...) ON TRUE` to keep empty/NULL tag arrays; `COUNT(DISTINCT a), COUNT(DISTINCT b)` multi-distinct in one pass.
- HOLD all iter534–866 locks. PIN Trino 467. NO federation edits (4.49944 / 310, still FAIL).
- DO NOT bump training/state.json (already at iter867; topic already passed).
