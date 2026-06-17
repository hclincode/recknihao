# iter977 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.41 STRONG PASS** (Q1 4.50 / Q2 3.50 / Q3 4.81 / Q4 4.81 = 17.625/4 = 4.4063; margin +0.91; OVERALL AVERAGE governs, no per-Q veto).

All 4 Qs verified BOTH directions vs trino.io/docs/467 (connector/iceberg.html partitioning + optimize, functions/aggregate.html max_by/array_agg) + trinodb/trino PR#14011 (UnwrapDateTruncInComparison) + Trino blog 2023-04-11 date-predicates + WebSearch QUALIFY-absence 2026-06-17 — NOT against resources/. Q4 max_by latest-per-group TRACED. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + dbt) — answers fit.

---

## Q1 — tickets-per-agent today-vs-yesterday: **4.50**
Two half-open-range queries (`closed_at >= TIMESTAMP '2026-06-11 00:00:00' AND closed_at < '2026-06-12...'`; prior day for yesterday) + GROUP BY agent_id — CORRECT. Auto-updating form `closed_at >= date_trunc('day', current_date) AND closed_at < date_trunc('day', current_date) + INTERVAL '1' DAY` — VERIFIED: date_trunc('day', current_date) returns a timestamp (date→timestamp midnight) and `+ INTERVAL '1' DAY` is valid; half-open prevents boundary double-count. Bare-range-most-portable + don't-wrap-partition-col advice correct.

★ **KEY CONFIRMATION — SimplifyDateTrunc fabrication did NOT recur.** Responder explicitly attributed pruning of wrapped `date_trunc('day', closed_at) = DATE '...'` forms to the `UnwrapDateTruncInComparison` optimizer rule — VERIFIED this is the REAL 467 rule name (trinodb/trino PR#14011 "Simplify predicates involving date_trunc", PR#14161 hour-unit follow-up). This is the CORRECT name; the iter960/976 "SimplifyDateTrunc (or similar)" hallucination did NOT repeat. Responder also correctly credits these wrapped forms as DOES-prune (not the iter976 under-crediting pessimism).

Minor completeness ding: Q said "today VERSUS yesterday" (side-by-side); responder gave two SEPARATE queries rather than one conditional-aggregation row (`COUNT(*) FILTER (WHERE closed_at >= today_start) AS closed_today, COUNT(*) FILTER (WHERE ... yesterday) AS closed_yesterday ... GROUP BY agent_id`). Not wrong — both correct — but the side-by-side single-pass form is the more elegant fit for the asked comparison. Acc 4.75 / Clar 4.5 / App 4.5 / Comp 4.25.

## Q2 — partition-pruning on non-partition col account_tier: **3.50** — THE KEY CHECK
Pruning DIAGNOSIS is CORRECT and well-explained: two-layer pruning (partition-level event_date prunes by day + file-level min/max footers for non-partition cols; account_tier min/max only helps if data is SORTED, else min/max spans the whole range → no skip). SHOW CREATE TABLE to inspect `partitioning = ARRAY[...]` correct. The "genuine scan-killer" note (opaque expressions on partition cols like `LOWER(event_date)=...` / `event_date + INTERVAL '1' DAY=...` defeat pruning; verify with EXPLAIN) is correct and a good value-add.

★ **DEFECT — FOREIGN-DDL SLIP: `PARTITIONED BY (day(event_date), account_tier)`.** VERIFIED against trino.io/docs/467 connector/iceberg.html: Trino 467 Iceberg does NOT use `PARTITIONED BY (...)` — that is Spark/Hive/Postgres-ish DDL. The correct forms are:
- CREATE: `CREATE TABLE ... WITH (partitioning = ARRAY['day(event_date)', 'account_tier'])`
- existing table: `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(event_date)', 'account_tier']`

The responder's `PARTITIONED BY` recommendation would not parse on Trino-Iceberg. RESOURCE-vs-SLIP: r09 L127 teaches the CORRECT `WITH (partitioning = ARRAY['day(occurred_at)','tenant_id'])` string-transform form FINDABLY → this is a **RESPONDER DIALECT SLIP (foreign Spark/Hive DDL), NOT a resource defect**. This is the PARTITIONED-BY-foreign-DDL slip family; **prior instance iter945 Q2 — NON-CONSECUTIVE** (intervening partition-spec Qs used WITH(partitioning=ARRAY[...]) correctly).

The advice to add account_tier as a second partition dimension (only if low-cardinality) is conceptually sound; only the DDL syntax is wrong.

★ `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` — VERIFIED VALID 467 syntax (optimize table procedure; merges files below threshold, default 100MB). "respects sorted_by" correct.

Acc 3.0 (foreign-DDL would-not-parse on the lead actionable recommendation, but diagnosis + optimize() correct) / Clar 3.75 / App 3.5 / Comp 3.75.

## Q3 — customers buying from >=3 DISTINCT categories: **4.81** CLEAN
`SELECT customer_id FROM orders GROUP BY customer_id HAVING COUNT(DISTINCT product_category) >= 3` — CORRECT, clean single-pass GROUP BY, NO subquery-per-customer (directly answers the "clean query or subquery-per-customer?" framing — correctly recommends the clean aggregation over the correlated form). `array_agg(DISTINCT product_category ORDER BY product_category)` variant VERIFIED valid (aggregate.html supports ORDER BY within array_agg; DISTINCT also supported). HAVING-runs-after-aggregation (trims OUTPUT; add WHERE before GROUP BY to reduce INPUT) matches r07 L37 reconcile — the HAVING-trims-memory folklore did NOT recur. "Don't use ROW_NUMBER for counting distinct" correct steer. Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q4 — most-recent price per SKU from append-log: **4.81** CLEAN
`SELECT sku_id, max_by(price, changed_at) AS current_price, MAX(changed_at) AS last_changed FROM price_history GROUP BY sku_id` — VERIFIED CORRECT: max_by(x, y) returns the value of x associated with the MAXIMUM value of y (aggregate.html) → price at the latest changed_at. This is the CORRECT as-of/argmax pattern, NOT the MAX(varchar)-as-latest trap (responder did NOT use MAX(price)). `max_by` for other columns correct. `ROW_NUMBER() OVER (PARTITION BY sku_id ORDER BY changed_at DESC) = 1` subquery for ALL columns correct (matches r23 §3.1G L1734 leading canonical).

★ Proactive + CORRECT: "Trino does NOT support QUALIFY ... Never write QUALIFY ROW_NUMBER()=1 — it will parse-fail." VERIFIED — QUALIFY is absent from Trino (Teradata/Snowflake/Redshift only; matches r23 L1755). Legitimate volunteered guard, NOT the false-mechanism tic. `INSERT INTO current_prices` export example fits the prod stack (ad-hoc INSERT...AS SELECT + MinIO download). Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## SCOPE NOTES
- **Q1 SimplifyDateTrunc-did-NOT-recur CONFIRMED**: responder used the CORRECT rule name `UnwrapDateTruncInComparison` (VERIFIED PR#14011) and correctly credited wrapped forms as DOES-prune. The iter960/976 "SimplifyDateTrunc" fabrication did not repeat → fabrication-family INTERMITTENT, candidate LIGHT defang near r23 L2451 NOT warranted.
- **Q2 PARTITIONED-BY foreign-DDL VERDICT**: confirmed FOREIGN-DDL slip (Trino-Iceberg = `WITH (partitioning = ARRAY[...])` CREATE / `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` existing). **RESPONDER DIALECT SLIP, NOT a resource defect** (r09 L127 teaches correct form findably). PARTITIONED-BY-foreign-DDL family; **prior instance iter945 Q2 — NON-CONSECUTIVE.** Re-probe-don't-churn; LIGHT FIX-A (defang near r09 L127) ONLY if recurs next sweep (would be 2-in-2).
- **Q2 optimize() syntax VERIFIED valid**; diagnosis correct.
- Q3/Q4 CLEAN.

## TICS
CLEAN except the Q2 PARTITIONED-BY slip. NO recurrence of: SimplifyDateTrunc fabrication (Q1 correct name), false-mechanism semi-join mislabel, MAX(varchar)-as-latest (Q4 used max_by correctly), percent_rank inversion, PERCENTILE_CONT fabrication, QUALIFY-as-valid (Q4 correctly says absent), broken-secondary/false-justification/unsupported-perf-claim, mid-churn, missing-column-in-CTE-projection, JOIN fan-out, ts-minus-ts.

## RECOMMENDATION = DEFAULT NO-OP
Margin +0.91; Q2 defect is a responder dialect slip (no resource defect / no findability gap — r09 L127 correct + findable). Re-probe (a) another add-a-partition-dimension / SET PROPERTIES Q (watch PARTITIONED-BY recurrence → 2-in-2 LIGHT defang near r09 L127; does responder reach WITH(partitioning=ARRAY[...]) / ALTER SET PROPERTIES), (b) another today-vs-yesterday or period-vs-period comparison Q (does responder reach single-pass conditional aggregation `COUNT(*) FILTER (WHERE today)` vs `FILTER (WHERE yesterday)`). Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 977; passed=true preserved; final_iterations_remaining 0).
