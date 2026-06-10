# Judge Feedback — iter899 (EXTENDED PHASE, NO-OP durability sweep)

## Verdict: 5.00 STRONG PASS — DEFAULT NO-OP (teacher ZERO edits)

Overall average **5.00** (per-Q 5.00/5.00/5.00/5.00 = 20.00/4), margin **+1.50** over the 3.5 threshold. Overall average governs (no per-Q veto). All four answers are dialect-clean, textbook Trino 467 analytical SQL. **Federation NOT probed this iter** — the 4.49944/310 row is UNCHANGED and remains the only un-passed row.

All facts VERIFIED vs trino.io/docs/467 (window / aggregate / string .html) + window-eval-order confirmation via WebFetch/WebSearch 2026-06-10. iter882 verify-first applied — the one structurally-suspicious claim (Q3 `SUM(COUNT(*)) OVER ()`) was VERIFIED LEGAL before judgment and is NOT flagged.

---

## Per-question scoring

**Q1 — 5.00. Per-customer % of orders returned (single orders table, status col).**
`ROUND(100.0 * SUM(CASE WHEN status='returned' THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id) / COUNT(*) OVER (PARTITION BY customer_id), 2) AS pct_returned` (per-row window form).
CORRECT — VERIFIED window.html: all aggregates usable as window functions via OVER; `SUM(CASE...)` and `COUNT(*)` over `PARTITION BY customer_id` return the per-customer totals broadcast onto every row of that customer (rate repeated per row is the intended/correct shape for a per-row window form). `100.0 *` is a DECIMAL literal forcing non-integer division (avoids the integer-truncate-to-0 trap); ROUND(...,2) standard. No GROUP BY needed since it is the keep-all-rows window form.

**Q2 — 5.00. Keep only customers with >= 5 orders.**
`SELECT customer_id, COUNT(*) AS total_orders FROM orders GROUP BY customer_id HAVING COUNT(*) >= 5;` + `WHERE customer_id IN (<same GROUP BY/HAVING subquery>)` to pull detail rows.
CORRECT — textbook Trino 467. HAVING filters post-aggregation on the group count = exactly the >=5-order customers. The IN-subquery variant is the idiomatic way to bring back full detail rows for the qualifying customers; `customer_id IN (subquery)` is standard and valid. Both the summary form and the detail-pull form are correct and the two-shape framing is helpful.

**Q3 — 5.00 (VERIFIED CAREFULLY — nested aggregate-in-window). Each department's % of total company headcount.**
`SELECT department, COUNT(*) AS headcount, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total FROM employees GROUP BY department ORDER BY pct_of_total DESC`.
CORRECT — the key claim `SUM(COUNT(*)) OVER ()` (a window function whose argument is an aggregate) IS LEGAL in Trino 467 when there is a GROUP BY. VERIFIED vs trino.io/docs/467 window.html: window functions "run after the HAVING clause but before the ORDER BY clause" — i.e. AFTER GROUP BY/aggregation. Therefore an aggregate (`COUNT(*)`) may appear inside a window-function argument; it is evaluated per-department-group first, then `SUM(...) OVER ()` sums those group counts to the grand total and broadcasts it onto every department row. This is the canonical percent-of-total idiom (also confirmed via WebSearch as the standard Trino pattern). **Distinct from the iter573 PIN** that the GROUP BY *clause itself* cannot CONTAIN an aggregate — that is a different clause; here the construct is in the SELECT list, which is allowed. `100.0 *` decimal division, ROUND, and `ORDER BY pct_of_total DESC` (output-alias in ORDER BY, legal) all correct. **Q3 = 5.0 as anticipated.**

**Q4 — 5.00. Extract the domain part of an email (after the @).**
`split_part(email, '@', 2) AS domain` ('jane@example.com' -> 'example.com') + count-by-domain `GROUP BY split_part(email,'@',2)` variant.
CORRECT — VERIFIED string.html: `split_part(string, delimiter, index) -> varchar`, "Field indexes start with 1." So index 2 returns the second field = everything after the first '@' = the domain; `split_part('jane@example.com','@',2)` = 'example.com'. The GROUP-BY-the-expression count-by-domain variant is valid (groups on the expression, not a SELECT alias).
DOC NUANCE (not a defect, not findable here): the docs state split_part "returns **null** if the index is larger than the number of fields" — i.e. for an input with no '@', `split_part(...,'@',2)` returns NULL (NOT '' empty string). The run-prompt premise floated "empty string"; the actual 467 behavior is NULL. The responder used a valid '@' email with index 2 and did NOT assert the wrong out-of-range value, so there is no accuracy defect — this is at most an unstated completeness nuance.

---

## Defect scan: NONE

No dialect defect, no findable-but-missing gap. All four are clean, copy-pasteable Trino 467. The Q3 `SUM(COUNT(*)) OVER ()` structure — the only one worth verifying — is confirmed legal and is NOT flagged (iter882 verify-first honored).

## Directive for iter900: DEFAULT NO-OP

- Teacher: **ZERO edits.** No defect / no FIX-A / no escalation.
- Do NOT add any "wrong" card for Q1-Q4. Do NOT mark the Q3 `SUM(COUNT(*)) OVER ()` percent-of-total form wrong — Trino 467 allows it (window fns evaluate after GROUP BY).
- Do NOT churn the percent-of-total / windowed-CASE-rate / HAVING-COUNT / split_part cards (all confirmed correct in practice across many sweeps).
- OPTIONAL micro-anchor only if it touches NO pin: a one-line "split_part out-of-range index returns NULL (not '')" note near an existing split_part card. SKIP if it would churn or duplicate a split_part pin.
- Re-probe fresh adjacents next sweep. **Federation (4.49944/310) is the only un-passed row** — probe only bulletproofed federation angles.
- Do NOT touch any iter534-898 pin. PIN Trino 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed; overall 5.00 PASS holds).
