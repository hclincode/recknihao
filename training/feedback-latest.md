# iter983 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.2656 PASS** (Q1 2.875 / Q2 4.75 / Q3 4.75 / Q4 4.6875 = 17.0625/4 = 4.2656; margin +0.766). OVERALL AVERAGE governs — NO per-Q veto (Q1 does NOT sink the iteration).

Final tally:
- Q1 = (2.5 Acc + 3.5 Clar + 2.75 App + 2.75 Comp)/4 = 11.5/4 = **2.875**
- Q2 = (4.75 + 4.75 + 4.75 + 4.75)/4 = **4.75**
- Q3 = (4.75 + 4.75 + 4.75 + 4.75)/4 = **4.75**
- Q4 = (4.75 + 4.75 + 4.625 + 4.625)/4 = **4.6875**
- **OVERALL = 17.0625/4 = 4.2656 PASS**

All claims verified BOTH directions vs trino.io/docs/467 (sql/select.html GROUP BY; functions/json.html; functions/aggregate.html max_by) + WebSearch 2026-06-17 for the aggregate-in-GROUP-BY error message — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all answers fit the stack.

---

## ★ Q1 — Monthly revenue bucketing + "can I GROUP BY the computed alias?" — 2.875 (THE KEY CHECK — TWO DEFECTS)

### DEFECT 1 (DOMINANT): ILLEGAL QUERY — aggregate inside GROUP BY. The query does NOT run.
The responder emitted:
```
GROUP BY customer_id, CASE WHEN SUM(amount)>1000 THEN 'high' WHEN SUM(amount)>=200 THEN 'medium' ELSE 'low' END
```
This puts `CASE WHEN SUM(amount) ... END` — an expression **containing the aggregate `SUM(amount)`** — inside the GROUP BY clause. **VERIFIED ILLEGAL in Trino 467**: an aggregate in GROUP BY throws `GROUP BY clause cannot contain aggregations, window functions or grouping operations` (confirmed via WebSearch against the Trino analyzer error + trinodb/trino #25984; select.html states GROUP BY may contain "any expression composed of input columns or an ordinal number" — an aggregate is NOT an input column). The query as written **DOES NOT COMPILE**.

### DEFECT 2: the engineer's premise was a MISCONCEPTION, and the responder VALIDATED it instead of correcting it.
The engineer asked "can I GROUP BY the bucket, or must I repeat the CASE?" The correct answer is **neither** — you do NOT group by the bucket at all. The bucket is a *post-aggregation label* derived from `SUM(amount)`; it is not a grouping key. The CORRECT pattern:
```
SELECT customer_id,
       date_trunc('month', order_date) AS month,
       SUM(amount) AS total_revenue,
       CASE WHEN SUM(amount) > 1000 THEN 'high'
            WHEN SUM(amount) >= 200 THEN 'medium'
            ELSE 'low' END AS revenue_bucket
FROM orders
WHERE order_date >= DATE '2026-01-01'
GROUP BY customer_id, date_trunc('month', order_date)   -- group by the RAW keys only
ORDER BY revenue_bucket
```
Aggregates and aggregate-derived CASE labels are allowed in SELECT; you group ONLY by the raw dimensions (customer_id + month). (If the engineer instead wants a COUNT of customers per bucket, that is a two-level query: inner = SUM per customer/month, outer = GROUP BY the bucket.) The responder never surfaced this — it took the misconception at face value and mechanically repeated the aggregate-bearing CASE into GROUP BY, producing the non-running query.

### DEFECT 3 (completeness): "MONTHLY" was dropped. The query has no month bucket in SELECT or GROUP BY (no `date_trunc('month', order_date)`); `WHERE order_date >= DATE '2026-01-01'` sums the entire period since Jan 1, not per month. The engineer explicitly asked for **monthly** revenue per customer.

### The GROUP-BY-ALIAS sub-claim is CORRECT (verified) — but it is the SECONDARY issue.
The responder's claim "Trino does NOT support a SELECT output alias in GROUP BY — use the input column, an ordinal (GROUP BY 1), or repeat the full expression; aliases ARE usable in ORDER BY but not GROUP BY (unlike Postgres/MySQL)" is **VERIFIED CORRECT** against select.html: "A simple GROUP BY clause may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position." Output aliases are not referenceable. So the responder got the *alias* question right. BUT this is moot for THIS query: even if aliases were allowed, grouping by this bucket alias still fails because it resolves to an aggregate. Defect 1 dominates.

### RESPONDER-SLIP vs RESOURCE-DEFECT classification:
This reads as a **RESPONDER synthesis slip** (mis-assembled an illegal query while correctly answering the narrower alias sub-question), NOT a confirmed resource defect — the responder clearly knows GROUP-BY-alias semantics (got that right) and uses correct CASE/aggregate forms elsewhere, but failed to recognize that an aggregate-bearing expression cannot be a grouping key and failed to correct the embedded premise. **ORCHESTRATOR ACTION REQUIRED:** the responder cited r07 ~L2770-2822 for Q1. I (judge) score against trino.io/docs/467, not resources/, so I CANNOT confirm whether r07 itself teaches the illegal pattern. The orchestrator MUST verify-first against git-tag 467 source AND read r07 L2770-2822 directly to classify: (a) if r07's canonical correctly shows GROUP BY raw-keys-only with the CASE-on-aggregate in SELECT and the responder mis-assembled it → RESPONDER SLIP, re-probe-don't-churn; (b) if r07 actually shows aggregate-in-GROUP-BY or repeats a CASE-on-SUM into GROUP BY → RESOURCE DEFECT, reconcile-in-place (the "repeat the full expression" advice is correct ONLY for non-aggregate computed columns; it MUST NOT be applied to aggregate-derived buckets). Premise-correction was **MISSED**.

Scores: Acc 2.5 (illegal query that does not run + uncorrected misconception; partially offset by the correct alias sub-claim) / Clar 3.5 (well-written, jargon explained, but confidently teaches a non-running query) / App 2.75 (engineer who pastes this gets a compile error) / Comp 2.75 (monthly dimension dropped; premise uncorrected).

---

## Q2 — Filter plan='pro' + pull referrer from a VARCHAR JSON column — 4.75 CLEAN
`json_extract_scalar(properties, '$.plan')` / `'$.referrer'`, `WHERE json_extract_scalar(properties,'$.plan')='pro'`. **VERIFIED 467 functions/json.html**: `json_extract_scalar(json, json_path)` accepts a VARCHAR JSON string (docs example `json_extract_scalar(json, '$.store.book[0].author')`), returns the scalar leaf as an unencoded string (VARCHAR) — the value "must be a scalar (boolean, number or string)" — and is usable in WHERE. The NULL-on-missing/non-scalar note, the CAST-to-type advice (redundant-but-harmless since the return is already VARCHAR), and `json_extract()` for nested object/array are all correct. "No pre-processing needed" is right. (json_value/json_query are SQL-standard alternatives — not required, no ding.) Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## Q3 — Deduplicate leads, keep most-recent row per email — 4.75 CLEAN
```
WITH ranked AS (
  SELECT email, lead_id, created_at, name,
         ROW_NUMBER() OVER (PARTITION BY email ORDER BY created_at DESC) AS rn
  FROM leads)
SELECT * FROM ranked WHERE rn = 1
```
**VERIFIED CORRECT**: ROW_NUMBER() PARTITION BY email ORDER BY created_at DESC = 1 keeps exactly the most-recent row per email (window.html row_number starts at 1 in the ordering). The `max_by(status, created_at) GROUP BY email` single-column variant is correct (aggregate.html: max_by(x,y) = value of x at the MAX of y — VERIFIED argmax, NOT a MAX(varchar)-as-latest trap). The CREATE TABLE AS persistence tip fits the prod stack. The DISTINCT-* warning ("won't dedup because rows differ by created_at") and the "PARTITION BY * is a parse error" note are both correct. **No QUALIFY misuse** (responder correctly used the subquery-wrap, did not invoke the non-existent-in-467 QUALIFY). Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## Q4 — WHERE status != 'pending' drops NULL rows — 4.6875 CLEAN
Three-valued-logic explanation **VERIFIED CORRECT**: `NULL != 'pending'` evaluates to UNKNOWN (any comparison with NULL = UNKNOWN), and WHERE keeps only rows evaluating to TRUE, so UNKNOWN rows are filtered out. All three fixes are valid Trino 467:
- (A) `WHERE status != 'pending' OR status IS NULL` — keeps NULL rows
- (B) `WHERE status != 'pending' AND status IS NOT NULL` — explicitly excludes NULL (semantically same as the original behavior, but explicit)
- (C) `WHERE COALESCE(status,'unset') != 'pending'` — folds NULL into a non-'pending' sentinel so it survives
The TRUE/FALSE/UNKNOWN framing and "standard across Trino/Postgres/MySQL" are accurate. **Minor completeness add (NOT a defect):** a 4th idiomatic option is `WHERE status IS DISTINCT FROM 'pending'`, which treats NULL as distinct from 'pending' and includes NULL rows in one clause — cleaner than (A). Worth surfacing but its absence is not a defect. Acc 4.75 / Clar 4.75 / App 4.625 / Comp 4.625.

---

## SCOPE NOTES

- **Q1 aggregate-in-GROUP-BY = ILLEGAL QUERY, VERIFIED (dominant defect):** `CASE WHEN SUM(amount)... END` inside GROUP BY throws "GROUP BY clause cannot contain aggregations, window functions or grouping operations" in Trino 467 — the query does NOT run. CORRECT pattern groups by raw keys only (customer_id + month) with the CASE-on-aggregate in SELECT.
- **Q1 GROUP-BY-ALIAS sub-claim = VERIFIED CORRECT:** Trino 467 does NOT support SELECT output aliases in GROUP BY (use input column, ordinal, or repeat the expression). Responder got this right; it is secondary to the illegal-query defect.
- **Q1 premise-correction = MISSED:** the engineer's "must I GROUP BY the bucket" embeds the misconception that the bucket is a grouping key; it is a post-aggregation label. Responder validated the misconception.
- **Q1 RESPONDER-SLIP vs RESOURCE-DEFECT = UNRESOLVED at judge level — orchestrator MUST verify r07 L2770-2822 + git-tag 467 source.** Leaning RESPONDER synthesis slip (alias sub-claim correct, knows CASE/aggregate forms), but cannot rule out a resource defect where "repeat the full expression" is over-generalized to aggregate-derived buckets. This is a NEW defect class (aggregate-in-GROUP-BY), not previously in the tic list — flag as the iter983 watch item.
- **Q2/Q3/Q4 all CLEAN.** No QUALIFY misuse (Q3 correctly used subquery-wrap), no false-mechanism semi-join mislabel, no MAX(varchar)-as-latest (Q3 max_by correct argmax), no percent_rank inversion, no fabricated functions/rule-names, no PARTITIONED-BY foreign DDL, no broken secondary / false justification, no mid-churn, no missing-CTE-col (Q3 projects+references all cols), no JOIN fan-out, no ts-minus-ts.

## RECOMMENDATION
**iter983 RECOMMENDATION = DEFAULT NO-OP for now, pending orchestrator verification of r07 L2770-2822.** Overall margin is +0.766 (PASS), but Q1 is the lowest single-Q score in the recent sweep (2.875) and is a NEW defect class (aggregate-in-GROUP-BY illegal query + uncorrected premise). Re-probe next sweep: (a) another "compute a bucket/category from an aggregate then group/filter" Q — watch whether the responder again puts an aggregate-bearing expression in GROUP BY (2-in-2 → orchestrator should reconcile r07's GROUP-BY-on-computed-column guidance to explicitly carve out aggregate-derived labels: "you do NOT group by a bucket derived from SUM/COUNT/etc; group by raw keys, put the CASE-on-aggregate in SELECT"); (b) another GROUP-BY-alias Q (confirm the correct alias claim persists). Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). NO resource edits this iteration (judge does not edit resources/). DO NOT bump training/state.json (already 983; passed=true preserved; final_iterations_remaining 0).

Sources:
- https://trino.io/docs/467/sql/select.html
- https://trino.io/docs/467/functions/json.html
- https://trino.io/docs/467/functions/aggregate.html
- https://github.com/trinodb/trino/issues/25984
