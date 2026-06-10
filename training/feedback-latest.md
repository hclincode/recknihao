# Judge Feedback — Iter 913 (EXTENDED PHASE, NO-OP durability sweep)

## Verdict: 4.75 PASS — NO-OP CONFIRMED (teacher ZERO edits)

Per-Q: 4.5 / 5.0 / 5.0 / 4.5 = 19.0 / 4 = **4.75** (margin +1.25 over 3.5; overall average governs, no per-Q veto).

All 4 answers dialect-clean. No genuine findable-but-missing gap and no Trino-467 dialect defect surfaced → **DEFAULT NO-OP, no FIX-A for iter914.** Federation (4.49944/310 row) NOT probed this sweep — UNCHANGED.

---

## Per-question scoring

### Q1 — count orders with exactly one line item — 4.5
SQL: `SELECT COUNT(*) FROM (SELECT order_id FROM line_items GROUP BY order_id HAVING COUNT(*)=1)` — **CORRECT and endorsed as "best."**
- VERIFIED: `GROUP BY order_id HAVING COUNT(*)=1` filters to orders with exactly one line-item row; wrapping in `SELECT COUNT(*) FROM (...)` collapses the qualifying-order list to a single total. Standard ANSI form, valid in Trino 467 (select.html GROUP BY/HAVING; no QUALIFY needed).
- NUANCE (minor clarity, NOT a hard defect): the responder also shows a muddled middle form `SELECT COUNT(DISTINCT order_id) ... GROUP BY order_id HAVING COUNT(*)=1`, which returns **one row per qualifying order** (each value =1), not a single total. It is shown as an alternative and NOT endorsed; the correct wrapped form is delivered AND explicitly labeled "best." Weighed as a clarity nuance per iter913 directive.
- Acc 4.5 / Comp 5.0 / Clar 4.0 / Act 4.5.

### Q2 — shortest SKU per brand; does MIN find shortest? — 5.0  ★ KEY DURABILITY CHECK PASSED
**The responder CORRECTLY AVOIDED the MIN-string trap.** It said NO — `MIN(sku)` returns the **lexicographically smallest** (alphabetically first) string, NOT the shortest — and for the actual shortest-by-length it used `MIN_BY(sku, LENGTH(sku)) ... GROUP BY brand`.
- VERIFIED vs trino.io/docs/467 aggregate.html + WebSearch 2026-06-10:
  - `min(x)` on varchar = lexicographically smallest (standard varchar comparison; "10" before "2"), NOT length-based — **responder correct.**
  - `min_by(x, y)` = "Returns the value of `x` associated with the minimum value of `y`" → `min_by(sku, length(sku))` returns the sku with the smallest length = the SHORTEST sku (ties arbitrary) — **responder used the right form.**
- This is a strong durability signal: the MIN-on-text length misconception was correctly rejected and the idiomatic min_by length form was delivered.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0.

### Q3 — duplicate product names — 5.0
SQL: `SELECT product_name, COUNT(*) ... GROUP BY product_name HAVING COUNT(*) > 1` (list of dup names + their counts) + wrapped `SELECT COUNT(*) FROM (...)` for the count-of-duplicate-names. **Both valid.**
- VERIFIED: HAVING COUNT(*) > 1 keeps only names appearing 2+ times; wrapping in COUNT(*) yields how many distinct names are duplicated. Standard Trino 467 form.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0.

### Q4 — % users who upgraded within 30 days of signup — 4.5
SQL: `LEFT JOIN signups s` to `upgrades u`, `ROUND(100.0 * COUNT(DISTINCT CASE WHEN date_diff('day', s.signup_date, u.upgrade_date) BETWEEN 1 AND 30 THEN s.user_id END) / COUNT(DISTINCT s.user_id), 2)`. **CORRECT.**
- VERIFIED vs datetime.html (date_diff('day') = day count, bigint) + select.html:
  - LEFT JOIN keeps non-upgraders; NULL upgrade_date → `date_diff` NULL → fails BETWEEN → correctly excluded from numerator but still counted in denominator.
  - `COUNT(DISTINCT CASE...)` counts each qualifying user once (handles multiple upgrade rows).
  - `100.0 *` forces decimal division (avoids integer-truncation to 0).
  - The `first_upgrade` CTE variant (`MIN(upgrade_date)` per user) for "first upgrade within 30d" is valid.
- NUANCE (debatable-interpretation completeness, NOT a hard defect): `BETWEEN 1 AND 30` **excludes a same-day (day 0) upgrade**. "Within 30 days" arguably should be `BETWEEN 0 AND 30`. This is a reasonable interpretation either way (some funnels treat signup-day conversions separately) — weighed proportionally as a minor completeness nuance.
- PRESENTATION (minor): responder showed a `GROUP BY 1` then self-corrected by removing it; final query is correct. Minor messiness, no scoring veto.
- Acc 5.0 / Comp 4.0 / Clar 4.5 / Act 4.5.

---

## iter882 verify-first applied (BOTH directions)
- Q2 `MIN(varchar)` lexicographic + `min_by(sku, length(sku))` shortest — VERIFIED CORRECT (aggregate.html + WebSearch), NOT falsely flagged; explicitly blessed as the right answer.
- Q1/Q3 wrapped-subquery `COUNT(*)` over `GROUP BY ... HAVING` — VERIFIED valid, NOT flagged.
- Q4 `date_diff('day')` = bigint day count, `COUNT(DISTINCT CASE...)`, `100.0*` decimal division — VERIFIED valid (datetime.html/select.html), NOT flagged.
- No doc-CORRECT claim flagged as defect; no doc-WRONG claim blessed.

## Directive for iter914
- **DEFAULT NO-OP.** No "wrong" card, no findability anchor, no churn.
  - Do NOT add a "MIN doesn't find shortest" warning card as a *defect fix* — the responder already answered this correctly; adding a negative-example card risks defang-backfire and duplicates the min_by/min-lexicographic content already present and working.
  - Do NOT mark Q1 wrapped-subquery, Q2 MIN-lexicographic+min_by-length, Q3 HAVING COUNT(*)>1+wrapped-COUNT, or Q4 LEFT-JOIN+COUNT(DISTINCT CASE)+date_diff('day') wrong — all correct.
  - The Q1 muddled-middle COUNT(DISTINCT) form and the Q4 BETWEEN-1-AND-30 day-0 edge are responder-side presentation/interpretation nuances, NOT resource gaps — re-probe-don't-churn.
- OPTIONAL micro re-probe (only if it touches NO pin): "within N days" inclusive-of-day-0 (`BETWEEN 0 AND N`) vs `BETWEEN 1 AND N` boundary intent — fresh adjacent next sweep; SKIP if it duplicates any date-window/funnel pin.
- Federation (4.49944/310) is the only un-passed row — bulletproofed angles only.
- Do NOT touch any iter534-912 pin. PIN Trino 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed; overall 4.75 PASS holds).
