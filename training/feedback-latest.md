# Judge Feedback — iter932 (EXTENDED PHASE, NO-OP durability sweep)

**Overall: 4.40625 / 5 → PASS** (margin +0.90625; OVERALL AVERAGE governs, no per-Q veto)
Per-Q: Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 2.625 = 17.625 / 4 = **4.40625**

FEDERATION NOT PROBED this sweep — the 4.49944/310 FAIL row is UNCHANGED.

All dialect verified against **trino.io/docs/467** (language/types.html, functions/datetime.html, sql/select.html, functions/aggregate.html) + **Trino git-tag 467 source** (`SqlBase.g4` grammar) via WebFetch/WebSearch 2026-06-10 — NOT against resources/. iter882 verify-BOTH-directions applied.

---

## ★ Q4 INTERVAL-QUALIFIER VERDICT — `INTERVAL '1' QUARTER` IS A CONFIRMED DIALECT DEFECT (the query will NOT run)

**VERIFIED FROM TWO INDEPENDENT 467 SOURCES:**

1. **trino.io/docs/467 language/types.html (INTERVAL section):** the only valid interval literal qualifiers are the **year-to-month** units (`YEAR`, `MONTH`) and the **day-to-second** units (`DAY`, `HOUR`, `MINUTE`, `SECOND`). QUARTER and WEEK are NOT listed.
2. **Trino 467 git-tag grammar `core/trino-grammar/.../SqlBase.g4`:** the production rule is literally
   ```
   intervalField : YEAR | MONTH | DAY | HOUR | MINUTE | SECOND ;
   ```
   QUARTER and WEEK are absent from the rule. Therefore `INTERVAL '1' QUARTER` raises a parse error (`mismatched input 'QUARTER'`) at analysis — **it never executes.**

**THE TRAP (and why it is genuinely confusing):** `quarter` and `week` ARE valid *unit STRINGS* for the function family — `date_trunc('quarter', x)`, `date_add('quarter', n, x)`, `date_diff('quarter', a, b)`, `EXTRACT(QUARTER FROM x)`, `quarter(x)` are all valid 467 (resources teach these extensively in r07). But the *INTERVAL literal qualifier* grammar is a strictly smaller set (6 units, no QUARTER/WEEK). The responder over-generalized from the many valid `'quarter'` unit-string usages to the invalid `INTERVAL '1' QUARTER` qualifier.

**FIX:** the correct one-quarter end-bound is `INTERVAL '3' MONTH` or `date_add('quarter', 1, date_trunc('quarter', current_date))`:
```sql
WHERE discontinued_at >= date_trunc('quarter', current_date)
  AND discontinued_at <  date_trunc('quarter', current_date) + INTERVAL '3' MONTH
```

**SCORED Q4 DOWN FOR THE SINGLE BROKEN TOKEN, NOT TO ZERO** — everything else in A4 is correct and well-explained:
- start bound `date_trunc('quarter', current_date)` — VALID (quarter is a valid date_trunc unit string).
- half-open `>= start AND < end` range — correct (avoids boundary double-count).
- bare column for partition pruning — correct.
- dynamic (current_date) not hard-coded — correct.
- the responder's OTHER period examples `INTERVAL '1' YEAR`, `INTERVAL '1' MONTH`, `INTERVAL '30' DAY` — **all VALID** (YEAR/MONTH/DAY are real interval qualifiers; cf. iter921 Q2 which correctly used `INTERVAL '1' YEAR` for a half-open year range).

Q4 scoring: **Acc 2.0** (won't run — single token), **Comp 3.0**, **Clar 3.0**, **Act 2.5** = 10.5/4 = **2.625**. Folded into the overall average, not vetoed.

---

## ★ SCOPE-CHECK Q4 — FINDABLE GAP (not a pure responder slip): name a LIGHT iter933 FIX-A

Grep of resources/ shows:
- No card lists the **valid INTERVAL literal qualifiers** (YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only).
- No card **warns that `quarter`/`week`, though valid as date_trunc/date_add/date_diff/EXTRACT unit STRINGS, are NOT valid INTERVAL literal qualifiers.**
- Resources DO use the valid `INTERVAL '3' MONTH` (r07 L3639, r27 L763) and `date_add('quarter', ...)` (r07 L3325) — but never as the explicit "quarter end-bound" template, and never disambiguated from the INTERVAL form.
- r07 L3479 teaches the analogous *function-alias* trap (`quarter` has no `quarter_of_year` alias) — same family of confusion, different surface. The INTERVAL-qualifier variant is unguarded.

This is **NOT** a pure synthesis slip (resources never disambiguate the two `quarter` surfaces), and it is the FIRST time this specific token has been probed. It is a genuine **findable gap with a precise, low-risk anchor.**

**iter933 LIGHT FIX-A (recommended):** add ONE small card to r07 in the existing "this quarter / date-range filter" keyword-anchor neighborhood (near L41 / L3469 WHICH-QUARTER card). Content:
- "**Valid INTERVAL literal qualifiers in Trino 467 are ONLY `YEAR`, `MONTH`, `DAY`, `HOUR`, `MINUTE`, `SECOND`.**"
- Inline-WRONG-mark (un-copyable form) `INTERVAL '1' QUARTER` / `INTERVAL '1' WEEK` → "parse error: `mismatched input 'QUARTER'`; QUARTER/WEEK are valid date_trunc/date_add/date_diff UNIT STRINGS but NOT interval literal qualifiers."
- Copy-attractive canonical for the current-quarter half-open window:
  ```sql
  WHERE discontinued_at >= date_trunc('quarter', current_date)
    AND discontinued_at <  date_trunc('quarter', current_date) + INTERVAL '3' MONTH
  -- or: date_add('quarter', 1, date_trunc('quarter', current_date))
  ```
Keep it tight. Follow Markdown-pipe-escape and defang-DO-NOT-WRITE memory lessons: put the WRONG token inline-marked and un-copyable, make the `INTERVAL '3' MONTH` block the copy-attractive canonical. Re-probe a "this quarter / this week" range Q next sweep to confirm the responder reaches for `INTERVAL '3' MONTH` (or date_add).

---

## Q1 — total weight per shipment — 5.00
`SELECT shipment_id, SUM(weight_grams) FROM shipment_items GROUP BY shipment_id`. VERIFIED select.html GROUP BY + aggregate.html `sum()` — correct shape. SUM ignores NULL weight rows (a shipment with all-NULL weights returns NULL, not 0) — the responder's NULL-skip note is accurate. Acc/Comp/Clar/Act 5.0.

## Q2 — count users with no profile photo — 5.00
`SELECT COUNT(*) FILTER (WHERE profile_photo_url IS NULL) FROM users` + `COUNT(CASE WHEN profile_photo_url IS NULL THEN 1 END)` alt. VERIFIED aggregate.html: FILTER clause "supported for all aggregate functions"; both forms count NULL-photo users (the CASE form returns 1 for NULL rows, NULL otherwise, and COUNT skips NULL). `IS NULL` is the correct NULL test (not `= NULL`). Acc/Comp/Clar/Act 5.0.

## Q3 — avg basket value per coupon, coupon-used only — 5.00
`SELECT coupon_code, AVG(basket_value) FROM orders WHERE coupon_code IS NOT NULL GROUP BY coupon_code`. VERIFIED: this is a **row-level** filter (drop orders with no coupon) so it belongs in **WHERE (pre-aggregation)**, not HAVING (post-aggregation). The responder's WHERE-vs-HAVING explanation is correct: WHERE filters rows before grouping; HAVING filters groups after aggregation. Using WHERE here also avoids a spurious NULL-coupon group. Acc/Comp/Clar/Act 5.0.

---

## iter933 DIRECTIVE

**iter933 = LIGHT FIX-A (single small card), NOT a pure NO-OP.** The Q4 `INTERVAL '1' QUARTER` defect is a **findable gap** (no card lists valid INTERVAL qualifiers / warns QUARTER+WEEK aren't interval units) — add the one card described above to r07's this-quarter/date-range neighborhood. Then re-probe a "this quarter / this week" range Q to confirm the fix.

- Do NOT mark Q1 (SUM GROUP BY + NULL-skip), Q2 (COUNT(*) FILTER / COUNT(CASE) for NULL photos), or Q3 (AVG GROUP BY + WHERE-not-HAVING) wrong — all correct.
- Do NOT touch federation resources (4.49944/310 only un-passed row; bulletproofed angles only).
- Preserve the full iter534–931 pin inventory.
- PIN NEW: **Trino 467 valid INTERVAL literal qualifiers = YEAR, MONTH, DAY, HOUR, MINUTE, SECOND ONLY. `INTERVAL '1' QUARTER` / `INTERVAL '1' WEEK` are PARSE ERRORS (`mismatched input`). `quarter`/`week` are valid UNIT STRINGS for date_trunc/date_add/date_diff/EXTRACT but NOT interval qualifiers. Quarter end-bound = `INTERVAL '3' MONTH` or `date_add('quarter', 1, ...)`.** (Verified types.html + git-tag 467 SqlBase.g4 `intervalField` rule.)
- PIN 467.
- DO NOT bump training/state.json (already 932; passed=true preserved; overall 4.40625 PASS holds).
