# Iter634 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Per-Question Scores

### Q1 — Top 10% customers' share of total revenue (PERCENT_RANK direction INVERTED)
- Accuracy: **2** — PERCENT_RANK semantics inverted under DESC sort.
- Completeness: **3** — Correct CTE skeleton (SUM/GROUP BY → window → numerator/denominator) but the cutoff is wrong; computes BOTTOM-10% share, not TOP-10%.
- Clarity: **4** — Clean CTE structure, well-narrated; the misstated direction is unambiguously stated (which is what makes it dangerous).
- Actionability: **2** — Copy-paste returns the WRONG number; engineer would ship an inverted KPI.
- **Per-Q avg: 2.75**

**Verification (trino.io/docs/467/functions/window.html):** `percent_rank()` is documented verbatim as `(r - 1) / (n - 1)`. With `ORDER BY total_revenue DESC`, the highest spender has rank r=1 → percent_rank = 0.0; the lowest spender has rank r=n → percent_rank = 1.0. Under DESC ordering, the TOP 10% by spend are `percent_rank <= 0.1`, NOT `>= 0.9`. The responder's prose ("0.0 bottom, 1.0 top") and the `CASE WHEN revenue_percentile >= 0.9` cutoff are both inverted — the query returns the share captured by the BOTTOM 10% of spenders. Fix is either flip the order (`ORDER BY total_revenue ASC` with `>= 0.9`) or flip the cutoff (`ORDER BY total_revenue DESC` with `<= 0.1`). NTILE(10) with `DESC` + `WHERE decile = 1` (filtered in an outer wrapper) would be a count-balanced cleaner alternative — worth signposting.

### Q2 — Duplicate (email, signup_date) detection
- Accuracy: **5** — `GROUP BY email, signup_date HAVING COUNT(*) > 1` is the canonical correct pattern. Self-join-back to the source table to surface the full duplicate rows is valid Trino 467.
- Completeness: **5** — Covers both the dup-key list and the dup-row enumeration; addresses the engineer's likely follow-up.
- Clarity: **5** — Two-step structure (find offending keys, then join back) is easy to read.
- Actionability: **5** — Copy-pasteable.
- **Per-Q avg: 5.00**

**Verification:** Standard SQL; HAVING applies post-aggregation; the existence of duplicate keys is exactly what `COUNT(*) > 1` after a GROUP BY surfaces. No dialect concerns.

### Q3 — Forward-fill / LOCF per device
- Accuracy: **5** — `LAST_VALUE(status) IGNORE NULLS OVER (PARTITION BY device_id ORDER BY event_time ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is correct Trino 467. IGNORE NULLS placement (after closing `)`, before OVER) is right.
- Completeness: **4.5** — All the necessary pieces present; minor: the outer `COALESCE(status, LAST_VALUE(...) IGNORE NULLS ...)` is redundant (LAST_VALUE ... IGNORE NULLS through CURRENT ROW already returns the current row's non-null value when present) — harmless but verbose; a brief note that the wrapper is optional would be cleaner.
- Clarity: **5** — Frame explained in plain language.
- Actionability: **5** — Drop-in.
- **Per-Q avg: 4.875**

**Verification (trino.io/docs/467/functions/window.html):** Trino 467 supports IGNORE NULLS on lead/lag/nth_value/first_value/last_value verbatim ("If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation"). The `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` frame is the correct look-back frame for LOCF. The default frame for LAST_VALUE is `RANGE UNBOUNDED PRECEDING ... last peer of the current row`; for LOCF the explicit ROWS frame is unambiguously safer, so the explicit form is good practice. The COALESCE wrapper is redundant but not wrong.

### Q4 — Top product NAME per category (DISTINCT ON Postgres-leak in secondary)
- Accuracy: **3** — PRIMARY `ROW_NUMBER() ... PARTITION BY category ORDER BY SUM(sales_amount) DESC` + outer `WHERE rn = 1` is fully correct Trino 467. SECONDARY `SELECT DISTINCT ON (category) ...` is **invalid Trino dialect** — DISTINCT ON is a PostgreSQL extension; Trino 467 supports only standard `SELECT DISTINCT`, not `DISTINCT ON (cols)`. Verified against trino.io/docs/current/sql/select.html (DISTINCT/ALL section mentions only set-quantifier DISTINCT, no DISTINCT ON) and trinodb/trino discussion #17261 ("Trino does not natively support PostgreSQL's DISTINCT ON syntax"). The secondary snippet would raise a parse error. Calling it the "tighter query" misdirects the engineer.
- Completeness: **4** — Engineer's actual question (return the product name, not the max number) is fully addressed by the PRIMARY snippet. The PRIMARY is the canonical Trino route. The bigger miss is omitting the Trino-native one-liner `max_by(product_name, total_sales) GROUP BY category` which is even cleaner than ROW_NUMBER and is the docs-recommended idiom for "value of x associated with the max of y."
- Clarity: **4** — PRIMARY is clearly explained; SECONDARY confidently labels Postgres syntax as a "tighter Trino query," which is actively misleading.
- Actionability: **3** — PRIMARY copy-pastes and runs; SECONDARY copy-pastes and FAILS at parse time. Engineer following the "tighter" recommendation would hit an error.
- **Per-Q avg: 3.50**

**Verification:** `SELECT DISTINCT ON (cols)` does not exist in Trino 467. trino.io/docs/current/sql/select.html DISTINCT/ALL section: "If the argument DISTINCT is specified, only unique rows are included in the result set" — no DISTINCT ON. GitHub discussion #17261 confirms it is a frequently requested PostgreSQL extension that Trino does not implement; users are told to use ROW_NUMBER, GROUP BY+aggregation, or subqueries.

---

## Overall

**Per-Q average:** (2.75 + 5.00 + 4.875 + 3.50) / 4 = **16.125 / 4 = 4.03125**
**Dim-avg cross-check:** Acc (2+5+5+3)/4=3.75, Comp (3+5+4.5+4)/4=4.125, Clar (4+5+5+4)/4=4.50, Act (2+5+5+3)/4=3.75 → (3.75+4.125+4.50+3.75)/4 = **4.03125** — agree.

**VERDICT: PASS** (overall 4.03125 >= 3.5; overall-avg governs label per directive — no per-Q gate).

Q1 per-Q avg 2.75 is below 3.5 and is flagged as a **quality concern** (not a label override). It is the highest-impact thin-spot of the iter, since the inversion produces a confidently-wrong number an engineer would ship without realizing.

---

## iter635 Directive

### FIX-A (PRIMARY — pick this one): PERCENT_RANK direction-under-DESC guardrail

Q1 inverted PERCENT_RANK under `ORDER BY ... DESC` is the higher-impact defect (per-Q 2.75, "top N% of spenders" is a high-frequency analyst phrasing, and an inverted answer is silently wrong rather than parse-failing).

**Action (reconcile-in-place, do NOT append/duplicate):**

1. Locate the existing PERCENT_RANK canonical (per state.json notes this is at **r07:1841** as part of Pattern C3 — the PERCENT_RANK()>=0.9 exact-cutoff alternative). Add a direction-under-DESC guardrail block IMMEDIATELY at that landing point. Keyword-anchor it for findability: "top 10% by spend", "top 5% customers", "highest-revenue decile", "percent_rank descending", "percent_rank top vs bottom".

2. Content of the guardrail (verbatim-grade, docs-cited):
   - Restate the docs formula: `percent_rank() = (r - 1) / (n - 1)` (cite trino.io/docs/467/functions/window.html).
   - Explicit direction table:
     - `ORDER BY x ASC` → smallest x has rank 1, percent_rank 0.0; largest x has percent_rank 1.0. **Top 10% by x ⇒ `percent_rank >= 0.9`**.
     - `ORDER BY x DESC` → largest x has rank 1, percent_rank 0.0; smallest x has percent_rank 1.0. **Top 10% by x ⇒ `percent_rank <= 0.1`**.
   - One-line trap callout: "If you wrote `ORDER BY total_revenue DESC` AND `percent_rank >= 0.9`, you are selecting the BOTTOM 10% (smallest spenders), not the top — a classic silent-wrong bug."
   - Equivalent NTILE form: `NTILE(10) OVER (ORDER BY x DESC)` → decile 1 is top, filter via outer wrapper `WHERE decile = 1` (cross-reference the existing NTILE-in-WHERE outer-wrap warning at r07 Pattern C3).
   - Note PERCENT_RANK is a fraction-of-rank cutoff (~10% of distinct rank positions), slightly different from NTILE's count-balanced deciles; both are valid "top 10%" idioms.

3. Cross-reference from the r23 share-of-grand-total canonical at r07:1068-1080 so the "top-10%-share-of-revenue" compose lands cleanly: top-N% filter (outer wrapper) → `SUM(x) / SUM(SUM(x)) OVER ()` or join to the grand-total.

4. Do NOT rewrite the existing PERCENT_RANK / NTILE / share-of-grand-total canonicals — additive guardrail block only, reconcile-in-place.

### FIX-B (SECONDARY — optional, lower impact): DISTINCT ON Postgres-leak inoculation

Q4 secondary snippet was Postgres `SELECT DISTINCT ON (cols)`, which does not exist in Trino 467 (parse error). This is a clean inoculation target if there is bandwidth after FIX-A.

**Action (reconcile-in-place, additive at r23 dialect-not-supported neighborhood):**

1. Add a "Trino does NOT support `SELECT DISTINCT ON (cols)` (Postgres extension)" inoculation row at the existing r23 anti-pattern/dialect-not-supported list (where QUALIFY, RLIKE, PERCENTILE_CONT, MEDIAN, initcap, dayname, PIVOT inoculations already live).
2. Verbatim trap: `-- INVALID Trino 467: SELECT DISTINCT ON (category) category, product_name FROM ...` → `-- VALID Trino 467: ROW_NUMBER() ... WHERE rn = 1` OR `max_by(product_name, total_sales) GROUP BY category`.
3. Cite trino.io/docs/current/sql/select.html DISTINCT/ALL section + trinodb/trino discussion #17261.
4. Keyword-anchor for findability: "DISTINCT ON", "tighter query", "top per group one-liner", "Postgres DISTINCT ON".
5. Cross-reference r23 max_by canonical at r23:597-668 — this is the Trino-native one-liner the responder should have led with on Q4 (and is the cleanest top-1-per-group idiom).

### Pick One

**Per directive, pick the higher-impact: FIX-A (PERCENT_RANK direction-under-DESC).** Q1 per-Q 2.75 vs Q4 per-Q 3.50 → Q1 is the deeper thin-spot, and the inverted-percentile bug is the more dangerous slip (silent-wrong vs parse-error). If teacher has cycles, FIX-B as a clean low-effort inoculation alongside, but FIX-A is the iter635 PRIMARY.

### DO NOT

- Re-edit the LAST_VALUE IGNORE NULLS LOCF canonical (Q3 clean first-probe; r07:769 + r07:873 + r23:905-951 all routed).
- Re-edit the GROUP BY + HAVING COUNT(*)>1 dup-detection canonical (Q2 clean first-probe; r28:215/238/260 + r27:2467 + r22:2467 + r13:5162 all routed).
- Re-edit the ROW_NUMBER top-1-per-group canonical at r23 §3.1G or the existing PERCENT_RANK / NTILE / max_by canonicals — additive guardrail/inoculation only, reconcile-in-place.
- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter634).
- Add `::`-casts (iter571 PIN); use EXTRACT(EPOCH FROM ...) (iter562 ban); QUALIFY; PERCENTILE_CONT/MEDIAN (iter611 ban); fabricate dayname()/initcap.
- Touch iter534-633 locks.
- Bump training/state.json (already 634).
- git commit / git push (no-op per state.json directive for iter634, but the FIX-A edit in iter635 should follow the normal commit/push flow).

---

## Meta-notes

- **Q1 PERCENT_RANK inversion** is the iter634 headline defect. The existing r07:1841 PERCENT_RANK alternative is mentioned in state.json as part of Pattern C3 but evidently does not carry an explicit direction-under-DESC guardrail — the responder routed to PERCENT_RANK and chose the wrong inequality. FIX-A is exactly the kind of additive in-place guardrail that has historically resolved similar direction/placement traps (cf. iter600 NTILE-in-WHERE outer-wrap, iter598 starts_with/ends_with inoculation).
- **Q4 DISTINCT ON leak** is a new Postgres-dialect-leak class — the responder confidently produced invalid Trino syntax labeled as a "tighter query." Worth a dedicated inoculation row alongside the existing QUALIFY/RLIKE/PERCENTILE_CONT inoculations. Lower urgency than FIX-A because parse errors are loud (engineer notices immediately) vs silent-wrong inverted-percentile (engineer ships a bad KPI).
- **Q2 + Q3** both clean first-probe, no changes needed.
- No fabricated functions in any of the four answers; the slips were direction/dialect, not function-existence.
- Federation row 4.49944/310 unchanged (NOT PROBED iter634).
