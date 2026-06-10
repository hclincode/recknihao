# Iter941 Feedback — DEFAULT NO-OP durability sweep (teacher made ZERO resource edits)

**Date**: 2026-06-10
**Phase**: EXTENDED (passed=true preserved)
**Overall verdict**: **4.4375 PASS** (per-Q Q1 4.75 / Q2 4.875 / Q3 3.125 / Q4 5.00 = 17.75/4 = 4.4375; margin +0.9375; OVERALL AVERAGE governs, no per-Q veto)
**Federation NOT probed** (4.49944/310 row UNCHANGED)

---

## Per-question scoring

### Q1 — Slow GROUP BY payment_method (Trino vs Postgres)
**Score: 4.75** (Acc 4.5 / Comp 5.0 / Clar 5.0 / Act 4.5)

VERIFIED dialect facts (trino.io/docs/467):
- "Trino has no secondary indexes" — CORRECT (Iceberg connector relies on partition pruning + file skipping only).
- "Cost = bytes scanned" — accurate framing for object-store-backed Iceberg.
- Half-open date range `WHERE created_at >= DATE '...' AND created_at < DATE '...'` — CORRECT (DATE-literal, unwrappable for pruning, no overlap at boundary).
- EXPLAIN to verify constraint pushdown — CORRECT canonical workflow.

**MINOR Acc ding** (-0.5) for the secondary aside: "HAVING COUNT(*) > N to trim high-cardinality group-by memory." HAVING runs AFTER aggregation (pinned: HAVING filters groups after groups and aggregates are computed; standard SQL semantics) — it can only trim OUTPUT rows, not the aggregation's working set. The actual memory footprint of the GROUP BY is determined by the number of distinct group keys, which is already fixed by the time HAVING evaluates. To shrink the aggregation memory you need to push selectivity into WHERE (pre-aggregation filter), not HAVING (post-aggregation filter). Loose perf claim, not a dialect defect, not the main answer. Small Act ding mirrors.

### Q2 — Latest event per user
**Score: 4.875** (Acc 5.0 / Comp 5.0 / Clar 4.5 / Act 5.0)

VERIFIED dialect facts:
- `max_by(event_time, event_time)` — VALID 467 (aggregate.html: "Returns the value of x associated with the maximum value of y"). Technically REDUNDANT but correct: `max_by(a, b)` returns `a` at max(`b`); when `a` = `b`, this equals `max(a)`. Plain `max(event_time) GROUP BY user_id` is the simpler canonical form for "latest timestamp only." `max_by` shines when you want some OTHER column at the max timestamp (e.g., `max_by(event_type, event_time)`).
- ROW_NUMBER() + subquery WHERE rn=1 — VALID 467; "no QUALIFY / no DISTINCT ON in 467" — CONFIRMED (select.html does not document either; window-fn illegal in WHERE).
- "Default is NULLS LAST for descending" — accurate but UNDER-stated. Per pinned fact (verified select.html "The default null ordering is NULLS LAST, regardless of the ordering direction"), Trino 467's default is NULLS LAST regardless of ASC/DESC. The responder phrasing "default is NULLS LAST for descending order" implies the rule is direction-dependent — it's not. Result is the same for the DESC case being asked, but the rule statement is slightly imprecise.

**Small Clar ding** (-0.5) for that under-stated null-ordering rule. Otherwise clean — both forms answer the question (max_by for the timestamp, ROW_NUMBER for "all columns of the latest row").

### Q3 — Bucket products into price ranges, COUNT per bucket — **WRONG-SHAPE LEAD**
**Score: 3.125** (Acc 2.5 / Comp 3.5 / Clar 3.0 / Act 3.5)

**★ KEY CHECK — WRONG-SHAPE VERDICT: CONFIRMED MUDDLED LEAD ★**

The user asked to **count how many products fall in each bucket** — expected output: roughly 4 rows (one per price band), each with a per-bucket product count.

The responder's LEAD CASE WHEN form:
```sql
SELECT product_id, price,
       CASE WHEN price < 25 THEN '$0-$25' ... END AS price_bucket,
       COUNT(*) AS product_count
FROM products
GROUP BY product_id, price, CASE WHEN ... END
ORDER BY price_bucket
```

This **PARSES and RUNS** as valid Trino 467 SQL (GROUP BY can repeat the CASE expression — no alias-in-GROUP-BY trap because the expression is literal). But the SHAPE is **WRONG**: `product_id` is unique per product, so every group is **exactly one product** → `COUNT(*)` is **always 1** → the result is ONE ROW PER PRODUCT (each labelled with its bucket), NOT a per-bucket tally. The `product_count` column will be `1` for every row. That does not answer "how many products fall in each bucket."

**CORRECT shape** (GROUP BY the bucket expression ONLY, no product_id/price in GROUP BY):
```sql
SELECT CASE WHEN price < 25 THEN '$0-$25'
            WHEN price < 50 THEN '$25-$50'
            WHEN price < 100 THEN '$50-$100'
            ELSE '$100+' END AS price_bucket,
       COUNT(*) AS product_count
FROM products
GROUP BY 1
ORDER BY 1;
```

**Does the SECOND (dynamic-buckets) form rescue it?** YES — partially. The dynamic-buckets INNER JOIN form:
```sql
SELECT b.bucket_name, COUNT(*) AS product_count
FROM products p
INNER JOIN price_buckets b ON p.price >= b.min_price AND p.price < b.max_price
GROUP BY b.bucket_name
ORDER BY b.min_price
```
**DOES** produce the per-bucket count correctly (GROUP BY bucket_name only; each product contributes 1 to its bucket; one row per bucket). So the responder DID deliver a correct shape — just not as the lead. The reader is most likely to copy the FIRST canonical, so the muddled lead is the load-bearing defect.

**MISSED OPPORTUNITY (completeness, not required)**: Trino 467 has native `width_bucket(x, bound1, bound2, n)` for equal-width bins AND `width_bucket(x, ARRAY[25, 50, 100])` for custom bins (math.html verified). For this exact "$0-25 / $25-50 / $50-100 / $100+" use case, `width_bucket(price, ARRAY[25, 50, 100])` would return 0/1/2/3 (cleaner than CASE WHEN for changing bucket sizes — directly answers the user's "better than CASE WHEN if bucket sizes change?" sub-question). Not mentioned. Comp ding.

**Scope verdict: RESPONDER WRONG-SHAPE SLIP, NOT FINDABLE GAP**:
- The GROUP BY output-shape rule (including a unique key collapses COUNT(*) to 1 per row; GROUP BY the bucket expression only for per-bucket count) is taught at the L488 / L1238 / iter909 / iter915 / iter936 GROUP-BY-muddle family locks. Resources already cover this correctly with copy-attractive canonicals.
- This is the iter909/915/936 GROUP-BY-muddle family recurring — responder synthesis slip on already-taught content.
- The dynamic-buckets form being correct shows the responder understands per-bucket aggregation; it just regressed on the simpler CASE WHEN lead form.
- **RE-PROBE-DON'T-CHURN, NO iter942 FIX-A**: Churning the dense GROUP-BY-shape pins risks New-Card/defang regression for zero correctness benefit at 4th-instance recurrence; the canonical is already correct in resources.
- ESCALATE to dedicated "per-bucket count CANONICAL = GROUP BY bucket only, NOT product_id+bucket" router card ONLY if this slip recurs in 2+ further sweeps with no intervening clean answer.

OPTIONAL secondary: width_bucket(x, array) is not taught as the lead for "custom bin counts." Adding a small width_bucket card pointing at this exact use case (bin-count of custom ranges) would be a completeness improvement, NOT a defect fix. Defer unless a future probe specifically tests width_bucket.

### Q4 — Cross-border ship vs billing, NULL inequality
**Score: 5.00** (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0)

VERIFIED dialect facts (trino.io/docs/467 functions/comparison.html):
- `IS DISTINCT FROM` is the **NULL-safe inequality** — CONFIRMED. Truth table from docs:
  | a | b | a = b | a <> b | a DISTINCT b |
  |---|---|-------|--------|--------------|
  | 1 | 1 | TRUE | FALSE | FALSE |
  | 1 | 2 | FALSE | TRUE | **TRUE** |
  | 1 | NULL | NULL | NULL | **TRUE** |
  | NULL | NULL | NULL | NULL | **FALSE** |
  Docs verbatim: "treat NULL as a known value and both operators guarantee either a true or false outcome even in the presence of NULL input."
- `!=` (or `<>`) → NULL → filtered out in WHERE — CORRECT (WHERE filters non-TRUE → both UNKNOWN and FALSE drop). Silent-drop behavior accurately explained.
- OR-form with explicit IS NULL checks (`a != b OR (a IS NULL AND b IS NOT NULL) OR (a IS NOT NULL AND b IS NULL)`) — CORRECT NULL-safe equivalent. More verbose than `IS DISTINCT FROM`, but useful for engineers unfamiliar with the operator.
- Truth-table presentation in the answer — CORRECT and matches the docs.

Clean 5.00. This is the textbook correct answer to the cross-border-NULL trap. No defects.

---

## Overall verdict and scope

**OVERALL = 4.4375 PASS** (margin +0.9375). The single Q3 wrong-shape slip drags the average from a strong-5 sweep to a tight pass — but pass it does.

**SCOPE**:
- NO RESOURCE DEFECT (Q3 GROUP-BY-output-shape rule is taught at L488/L1238/iter909/iter915/iter936 locks; canonicals correct).
- RESPONDER SLIP on Q3 lead form (iter909/915/936 GROUP-BY-muddle family recurrence at 4th sweep with intervening clean answers — re-probe-don't-churn discipline applies; resources are right, responder synthesis regressed on the CASE WHEN lead while delivering the correct dynamic-buckets alternative).
- Q1 HAVING-trims-memory aside is a loose perf colloquialism, not a dialect defect.
- Q2 NULLS-LAST direction-dependence phrasing is mildly imprecise, not wrong-result.
- NO FINDABLE GAP.

**iter942 = DEFAULT NO-OP**:
- Teacher ZERO resource edits.
- RE-PROBE the Q3 slip next sweep via a fresh per-bucket-count question (e.g., "histogram of orders by total amount band" or "count customers by tenure band") — verify responder leads with GROUP BY bucket-expr ONLY, no product_id/customer_id in GROUP BY.
- Escalate to dedicated FIX-A router card ONLY if Q3 GROUP-BY muddle recurs across 2+ further sweeps (currently 4th-cumulative-recurrence with intervening clean iter934/938/939/940 — still re-probe territory).
- DO NOT touch dense L488 / L1238 / iter909/915/936 GROUP-BY-output-shape pins (defang-backfire risk per markdown-pipe-trap lesson).
- OPTIONAL low-priority completeness improvement: a small width_bucket(x, array) card for custom-bin counting (NOT required; defer unless probed).
- Federation (4.49944/310) only un-passed row — bulletproofed angles only.
- PRESERVE full iter534-940 pin inventory. NO federation edits. PIN 467.
- DO NOT bump training/state.json (already 941; passed=true preserved; overall 4.4375 PASS holds).

## Pinned dialect facts carried forward (Q1-Q4 touched)
- Trino has NO secondary indexes (Iceberg: partition pruning + file skipping only).
- EXPLAIN reveals constraint pushdown.
- Half-open DATE-literal range `>= DATE '...' AND < DATE '...'` correct for pruning.
- HAVING runs AFTER aggregation; trims output only, does NOT reduce aggregation memory footprint.
- `max_by(x, y)` returns x at max(y); `max_by(a, a)` = `max(a)` (valid but redundant).
- Plain `max(event_time) GROUP BY user_id` is the simplest "latest timestamp" canonical.
- ROW_NUMBER() OVER (PARTITION/ORDER) + subquery WHERE rn=1 = "all columns of latest row per group."
- NO QUALIFY clause in 467. NO DISTINCT ON in 467.
- Default ORDER BY null ordering = NULLS LAST regardless of direction (verified select.html).
- GROUP BY output shape: including a unique key collapses COUNT(*) to 1 per row; GROUP BY the bucket expression ONLY for per-bucket count.
- `width_bucket(x, bound1, bound2, n)` for equi-width bins; `width_bucket(x, ARRAY[...])` for custom bins (math.html verified).
- CASE WHEN bucketing valid; GROUP BY repeats the CASE expression (no alias-in-GROUP-BY).
- IS DISTINCT FROM is the NULL-safe inequality (TRUE when differ incl NULL-vs-nonNULL, FALSE when equal or both NULL).
- `!=` / `<>` with NULL → UNKNOWN → silently filtered in WHERE.
