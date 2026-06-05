# Iter 482 Judge Feedback — END-OF-ITERATION (EXTENDED PHASE)

## Verdict: 4.7656 STRONG PASS (81st consecutive PASS in extended phase)

| Question | Avg | Status |
|---|---|---|
| Q1 windowed LISTAGG RE-PROBE (capability-grant-fix confirm) | 4.875 | STRONG PASS |
| Q2 Trino JSON extraction + GROUP BY | 4.875 | STRONG PASS |
| Q3 Iceberg snapshot retention + GDPR + time travel | 4.75 | STRONG PASS |
| Q4 sort-order/clustering for tenant_id file pruning | 4.5625 | STRONG PASS |
| **Overall** | **4.7656** | **STRONG PASS** |

## Per-question scores

### Q1 — windowed LISTAGG re-probe (Acc 5.0 / Comp 5.0 / Clar 4.75 / Act 4.75 = 4.875)
- Responder explicitly stated `listagg` is AGGREGATE-ONLY, quoted Trino doc verbatim ("The current implementation of listagg function does not support window frames"), did NOT claim listagg OVER works, did NOT misdiagnose as NULLS/quoting.
- Case A (collapsed: one row per group) given correctly: `listagg(product_name, ', ') WITHIN GROUP (ORDER BY product_name) ... GROUP BY order_id`.
- Case B (repeated-on-every-row) given correctly: pre-sort CTE then `array_join(array_agg(product_name) OVER (PARTITION BY order_id), ', ')`, with the correct caveat that `array_agg(x ORDER BY y) OVER (...)` is not supported in Trino so ordering is weaker without a pre-sort.
- **capability-grant-fix STATUS: CONFIRMED LANDED.** iter481 r27 §7A.2A canonical card + r23 line-844 reconciliation were effective. ZERO fabs.

### Q2 — Trino JSON extraction + GROUP BY (Acc 5.0 / Comp 4.75 / Clar 4.75 / Act 5.0 = 4.875)
- `json_extract_scalar(properties, '$.plan')` returns VARCHAR — VERIFIED at trino.io/docs/current/functions/json.html.
- `CAST(json_extract_scalar(properties,'$.seats') AS INTEGER)` correct for numeric grouping.
- `JSON_VALUE(... RETURNING varchar NULL ON EMPTY NULL ON ERROR)` syntax VERIFIED — actual signature: `JSON_VALUE(json_input, json_path [PASSING ...] [RETURNING type] [{ERROR|NULL|DEFAULT expr} ON EMPTY] [{ERROR|NULL|DEFAULT expr} ON ERROR])`. Defaults are NULL ON EMPTY / NULL ON ERROR, so responder's explicit form is valid (slightly verbose but correct).
- Re-parsing cost framing correct; ingestion-time flattening via Spark `get_json_object` correctly attributed to Spark (NOT Trino). ZERO fabs.

### Q3 — Iceberg snapshot retention + GDPR + time travel (Acc 4.75 / Comp 4.75 / Clar 4.5 / Act 5.0 = 4.75)
- 7-day floor via `iceberg.expire-snapshots.min-retention` default `7d` — VERIFIED at trino.io/docs/current/connector/iceberg.html.
- Spark `CALL <catalog>.system.expire_snapshots(table => '...', older_than => current_timestamp - interval '1' hour, retain_last => 1)` — VERIFIED at iceberg.apache.org/docs/latest/spark-procedures (parameters: `table` StringType required, `older_than` TimestampType optional, `retain_last` IntegerType optional).
- 3-step purge architecturally CORRECT: (1) DELETE creates positional/equality deletes, (2) EXECUTE optimize / Spark rewrite_data_files rewrites clean files without deleted rows, (3) EXECUTE expire_snapshots GCs old snapshots + issues S3 DELETEs.
- Time-travel-persistence-until-expiry CORRECT. ZERO load-bearing fabs.

### Q4 — sort-order/clustering for tenant_id file pruning (Acc 4.75 / Comp 4.5 / Clar 4.5 / Act 4.5 = 4.5625)
- `ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY['tenant_id ASC NULLS LAST']` — VERIFIED (Trino doc shows exactly that array-of-strings form: `sorted_by = ARRAY['order_date DESC NULLS FIRST', 'order_id ASC NULLS LAST']`).
- `EXECUTE optimize(file_size_threshold => '512MB')` rewrites existing files in the new sorted order — VERIFIED (default 100MB, override to 512MB valid).
- `$files` `lower_bounds` / `upper_bounds` columns VERIFIED as `map(INTEGER, BIGINT)` (mapping by Iceberg column ID, not column name — minor non-load-bearing nit if the answer did not flag the column-id indirection for engineers reading the map).
- Min/max-based file pruning rationale CORRECT. ZERO fabs.

## Fabrications

**NONE.** ZERO load-bearing fabrications across Q1–Q4. Citation-hygiene streak FULLY RESTORED after iter481's break.

## Capability-grant-fix status

**CONFIRMED LANDED.** Q1 re-probe demonstrates the iter481 r27 §7A.2A canonical card + r23 line-844 reconciliation took. Responder:
- Did NOT claim listagg supports OVER.
- Did NOT misdiagnose as NULLS/quoting.
- Gave both Case A (aggregate, one row per group) and Case B (windowed repeated-per-row via `array_join(array_agg() OVER ())`) rewrites.
- Cited the verbatim doc text.

Defer next windowed-listagg re-probe to iter484 or later from a different keyword angle (e.g., Oracle source + Trino error verbatim, or "value repeated on every row of a partition" without mentioning Oracle).

## Teacher actions for iter483

### PRIMARY — breadth design, NO dedicated federation probe
Federation row stays at 4.49944/310 per the iter472-482 directive. Continue letting the count grow naturally through non-federation breadth probes; do not engineer a federation question this iter.

### SECONDARY — target low-count topics (under-sampled at 2-3 datapoints)
Pick 1-2 of these for the iter483 saas-engineer question set:
- **dbt sources / source freshness** (3 questions, 4.219 avg) — probe with a realistic SaaS angle, e.g., "we want dbt to fail downstream models if the Postgres → Iceberg snapshot is older than 2 hours, how do we configure source freshness blocking?".
- **dbt model contracts** (3 questions, 4.1146 avg) — probe with constraint-enforcement angle, e.g., "we set `config.contract.enforced=true` and added `not_null` + `primary_key` to a column — which actually enforce at runtime on dbt-trino + Iceberg?".
- **Storage tiering on Trino+Iceberg+MinIO** (2 questions, 4.25 avg) — probe with a per-partition-tier angle (no built-in DDL, must use compression_codec + recent/archive table UNION ALL via dbt view + MinIO `mc ilm tier add`).
- **dbt snapshots SCD2** (2 questions, 4.5625 avg) — probe with a different angle than the previous two (timestamp vs check strategy, dbt_is_deleted in 1.9+, validity-window point-in-time pattern).

### TERTIARY — fab-class watch (preventive, no edits required)
- **fabricated-capability-GRANT** (iter481 class, now fixed) — watch for any RE-EMERGENCE on different functions/clauses (e.g., claiming `array_agg(x ORDER BY y) OVER (...)` works, claiming `string_agg` exists in Trino, claiming Trino MERGE supports `UPDATE SET *` shorthand, claiming `LATERAL VIEW EXPLODE` works in Trino-Iceberg).
- **fabricated-session-property-names** (iter474/iter478/iter479 class, fixed in iter479-480) — no re-probe needed this iter but stay alert if a memory/spill question surfaces by chance.
- **cross-dialect-spillover** (iter476 class, fixed in iter477) — watch for any Oracle/Spark/Snowflake idiom presented as Trino.

### Do NOT
- Do NOT immediately re-probe windowed-listagg this iter (just confirmed). Defer to iter484-485 from a different angle.
- Do NOT add new resources/ files. Only reconcile in-place if a NEW fab class surfaces.
- Do NOT touch federation guardrails (r22 §13.x) — unchanged per directive.

## Streak status
- 81st consecutive PASS in extended phase.
- 4.7656 STRONG margin (~1.27 above 3.5 floor; matches/exceeds iter477's 4.75).
- Citation-hygiene streak: 1 iter clean (iter482) after iter481 break.
- All required topics PASSED. Federation at 4.49944/310 (0.0006 below 4.5 raised threshold, held per directive).
