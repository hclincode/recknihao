# Judge Feedback — iter798 (DEFAULT NO-OP / durability-breadth sweep; teacher ZERO resource edits)

**Verdict: overall avg 4.31 — PASS** (threshold 3.5; overall average governs, no single-Q veto).
All dialect claims verified against trino.io/docs/467 (window / select / json / datetime .html) via WebFetch on 2026-06-09.

---

## Per-question scores

### Q1 — 2nd-highest DISTINCT salary (tied top = one tier) — avg **5.00 PASS**
- Accuracy **5** · Completeness **5** · Clarity **5** · Actionability **5**
- Answer: `SELECT DISTINCT salary FROM (SELECT salary, DENSE_RANK() OVER (ORDER BY salary DESC) AS salary_rank FROM employees) WHERE salary_rank = 2`.
- VERIFIED vs functions/window.html: DENSE_RANK "tie values do not produce gaps in the sequence" → assigns 1,1,2,… so `salary_rank=2` is the 2nd distinct tier; tied top correctly collapses to one tier. Responder correctly chose DENSE_RANK over RANK (RANK would skip after a tie) and noted the empty-result-if-no-2nd-tier edge. Matches the RANK/DENSE_RANK pin. Clean. Cites r23.

### Q2 — flag each sale above its OWN region's average — avg **5.00 PASS**
- Accuracy **5** · Completeness **5** · Clarity **5** · Actionability **5**
- Answer: subquery computes `AVG(sale_amount) OVER (PARTITION BY region) AS region_avg`, outer query `CASE WHEN sale_amount > region_avg THEN true ELSE false END`.
- VERIFIED vs functions/window.html + select.html: window AVG partitioned per region is per-region mean (not global); wrapping in a subquery is REQUIRED because a window result cannot be referenced by its alias in the same SELECT's CASE (and the WHERE/SELECT alias scoping rule). Comparison `sale_amount > region_avg` is the correct above-group-avg flag. Matches the above-group-avg / standing-deviation pattern. Clean. Cites r07.

### Q3 — explode a JSON-ARRAY-STRING (varchar `'["vip","beta","trial"]'`) to one row per tag — avg **2.25** (PRIMARY DEFECT)
- Accuracy **2** · Completeness **2** · Clarity **3** · Actionability **2**
- Answer used `CROSS JOIN UNNEST(tags) AS t(tag)` directly and reframed the column as a NATIVE array ("tags = ARRAY['vip','beta','trial']"). LEFT JOIN UNNEST … ON TRUE for empty/null noted.
- **DEFECT — bare `UNNEST(tags)` on a varchar column is a TYPE ERROR.** VERIFIED vs sql/select.html: "UNNEST can be used to expand an ARRAY or MAP into a relation" — UNNEST requires an ARRAY (or MAP) argument. A varchar holding JSON text is NOT an array; `UNNEST(varchar)` fails to type-check ("cannot UNNEST varchar"). The responder skipped the mandatory parse step and mischaracterized the stated JSON-string column as a native array, so the answer does NOT solve the question as asked.
- **CORRECT CANONICAL (state explicitly to teacher):**
  ```sql
  SELECT o.order_id, t.tag
  FROM iceberg.analytics.orders o
  CROSS JOIN UNNEST(CAST(json_parse(o.tags) AS ARRAY(VARCHAR))) AS t(tag);
  ```
  VERIFIED vs functions/json.html: `json_parse(varchar) -> json` deserializes the JSON text; casting a JSON array value to `ARRAY(VARCHAR)` is supported. Pipeline: varchar → `json_parse` → JSON → `CAST(... AS ARRAY(VARCHAR))` → ARRAY → `UNNEST`. (Use `LEFT JOIN UNNEST(...) ON TRUE` to keep rows whose array is empty/null, as the responder noted for the native case.)
- **FINDABILITY MISS, not a content gap.** The parse half EXISTS in resources but is unreachable from explode/UNNEST keywords:
  - `resources/09-lakehouse-schema-design.md:876` — `SELECT CAST(json_parse(tags_raw) AS ARRAY(VARCHAR)) AS tags` (the exact parse-to-array step) — BUT this section (r09 §"CAST(json_col AS … ARRAY(T))" LEADING CANONICAL, lines 849–900) is keyword-anchored to "parse JSON into ROW / JSON to struct / deserialize JSON to typed columns" and does NOT combine the result with UNNEST or anchor on "explode JSON array / one row per tag / flatten JSON array string".
  - `resources/07-analytical-query-patterns.md:41` (§1a) — the explode/UNNEST landing the responder DID reach — covers ONLY a NATIVE `tags ARRAY(VARCHAR)` column (`UNNEST(u.tags)`, line 54); it has NO branch for a JSON-array-STRING (varchar) column and never mentions json_parse/CAST.
  - GREP confirms NO occurrence of the combined `UNNEST(CAST(json_parse(...) AS ARRAY(...)))` form anywhere in resources/.
  - Net: each half is present (explode in r07 §1a; json_parse→array in r09:876) but they are NEVER connected, and the explode landing assumes a native array. **Resource/findability gap, NOT a pure responder slip** — a Haiku responder keying on "explode JSON array column" lands at r07 §1a (native array) and has no signal to insert the parse step.

### Q4 — dynamic first-day-of-current-month MTD boundary — avg **5.00 PASS**
- Accuracy **5** · Completeness **5** · Clarity **5** · Actionability **5**
- Answer: `WHERE event_date >= date_trunc('month', current_date)`; auto-rolls each month; `CAST(date_trunc('month', current_date) AS DATE)` for a DATE-typed boundary.
- VERIFIED vs functions/datetime.html: `date_trunc('month', current_date)` returns the first day of the current month; `current_date` is the start-of-query date (no parens). `event_date >= that` is month-to-date and auto-rolls on the 1st. CAST AS DATE valid. Matches the standing date_trunc pin. Clean. Cites r07.

---

## Overall

`(5.00 + 5.00 + 2.25 + 5.00) / 4 = 4.31 → PASS`

Three of four probes (nth-highest-distinct via DENSE_RANK, above-group-avg via window AVG, MTD via date_trunc) are bulletproof and reconfirm standing pins. The lone defect is Q3.

## Teacher feedback / iter799 designation

**iter799 = FIX-A (additive findability).** Findability/content-connection gap, not a pure responder slip — surface a JSON-array-STRING → rows canonical reachable from explode/UNNEST keywords:

1. Add a branch in **r07 §1a** (the explode/UNNEST landing, ~lines 41–66) that DISAMBIGUATES native-array vs JSON-array-string columns. For a varchar column holding `'["vip","beta","trial"]'`, the canonical is:
   ```sql
   CROSS JOIN UNNEST(CAST(json_parse(tags) AS ARRAY(VARCHAR))) AS t(tag)
   ```
   Lead with: "If `tags` is a native `ARRAY(VARCHAR)` column, `UNNEST(tags)` directly. If `tags` is a VARCHAR holding a JSON array string, you MUST first `CAST(json_parse(tags) AS ARRAY(VARCHAR))` — `UNNEST` requires an ARRAY/MAP and **`UNNEST(<varchar>)` is a type error** (verified sql/select.html)."
2. Keyword-anchor it: "explode JSON array string, UNNEST JSON array column, one row per tag from JSON string, flatten JSON array varchar, json_parse then UNNEST, tags stored as JSON string to rows, CAST json_parse AS ARRAY then UNNEST."
3. DEFANG the trap inline (un-copyable WRONG mark): `UNNEST(tags)` when `tags` is a varchar JSON string → **WRONG, type error "cannot UNNEST varchar"**; and do NOT reinterpret a JSON-string column as a native `ARRAY[...]` literal.
4. Cross-ref to r09:876 (`CAST(json_parse(tags_raw) AS ARRAY(VARCHAR))`). Apply Reconcile-Don't-Append: keep r07 §1a's native-array form as-is, add the JSON-string branch so the responder picks the right one.

PRESERVE (verified clean this iter, churn risk): r23 DENSE_RANK nth-distinct card, r07 window-AVG above-group-avg card, r07 date_trunc MTD-boundary card.
