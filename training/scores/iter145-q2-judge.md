# Iter145 Q2 — Judge Score

**Question topic**: Debezium behavior on Postgres DROP COLUMN, RENAME COLUMN, and type changes; impact on the Iceberg pipeline.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter145-q2.md`

---

## Score Breakdown

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.5 | All major claims verified correct. One minor syntax imprecision (Spark `CHANGE COLUMN` vs. Iceberg-documented `ALTER COLUMN ... TYPE`). |
| Clarity for SaaS engineer | 5 | Zero assumed OLAP background. Walks through DDL → WAL → Debezium → Kafka → Iceberg chain step by step. Side-by-side JSON example for the DROP case is excellent. |
| Practical usefulness | 5 | Concrete kubectl + SQL sequences for every scenario. Pre-change checklist, diagnostic checklist, and the "no-op UPDATE to force a RELATION message" trick are highly actionable. Production-stack-aware (Trino 467, Spark, k8s, MinIO). |
| Completeness | 5 | Covers detection mechanism, DROP, RENAME, widen-type, narrow-type, the multi-step migration pattern for incompatible types, summary matrix, pre-change checklist, and silent-NULL diagnosis. Specifically warns against restarting the connector (re-snapshot risk). |

**Average = (4.5 + 5 + 5 + 5) / 4 = 4.875**

**Verdict: PASS** (threshold ≥ 4.5)

---

## What Was Verified Correct (via WebSearch)

1. **RELATION message timing** — Confirmed. Postgres pgoutput emits a RELATION (`R`) message with the new schema before the first DML row event after a schema change, not at DDL commit time. Sources: debezium.io PostgreSQL connector docs, PostgreSQL logical replication message format docs, and multiple logical decoding deep-dives.

2. **RENAME COLUMN = DROP + ADD from Debezium's perspective** — Substantively correct. Postgres logical decoding does not emit an explicit "rename" event; it only emits a new RELATION message with the new column name. Downstream consumers cannot tell that the new column is the same as the old one, so the practical effect is identical to DROP + ADD: old column disappears from the schema, new column appears as if brand-new, historical Iceberg rows show NULL for the new column. The phrasing in the answer is correct in operational terms.

3. **Iceberg allowed type promotions** — Confirmed against the Iceberg spec: int→long, float→double, decimal(P,S)→decimal(P',S) where P' > P. Scale cannot change. Narrowing is forbidden. All three rows in the answer's table are accurate.

4. **Trino 467 ALTER TABLE ... ALTER COLUMN SET DATA TYPE syntax** — Confirmed. The Trino docs show `ALTER TABLE [IF EXISTS] name ALTER COLUMN column_name SET DATA TYPE new_type`. The answer's example `ALTER TABLE iceberg.analytics.events ALTER COLUMN score SET DATA TYPE BIGINT` is syntactically correct for Trino 467.

5. **Iceberg DROP COLUMN is metadata-only** — Confirmed. Iceberg drops the column from the schema; the underlying Parquet files retain the bytes until compaction. Field IDs (not names) make this safe.

6. **Iceberg field ID semantics enable safe RENAME** — Confirmed. Iceberg tracks columns by integer field ID stored in both table metadata and Parquet metadata, so renaming in Iceberg is metadata-only and historical data remains correctly mapped.

7. **`columns_diff` default schema refresh, Debezium does not replay old Kafka events** — Implicitly correct; aligned with Debezium documentation.

---

## Minor Issues / Gaps

### MINOR: Spark SQL syntax for type change
The answer gives:
```sql
ALTER TABLE iceberg.analytics.events CHANGE COLUMN score score BIGINT;
```
The Iceberg-official Spark DDL docs (https://iceberg.apache.org/docs/latest/spark-ddl/) document the syntax as:
```sql
ALTER TABLE iceberg.analytics.events ALTER COLUMN score TYPE BIGINT;
```
Spark SQL does accept Hive-style `CHANGE COLUMN col col type` in some catalogs, but the canonical Iceberg-Spark syntax is `ALTER COLUMN ... TYPE`. This is a minor accuracy issue and should be corrected to align with the official Iceberg Spark DDL.

### MINOR: "RENAME as DROP + ADD" framing
The framing is operationally correct but technically the WAL/pgoutput protocol does not emit an explicit DROP and ADD event — it just emits a new RELATION message with the new column name. The downstream consumer cannot distinguish a rename from a drop-plus-add, which is why the practical effect is identical. The answer could be slightly more precise by saying "indistinguishable from DROP + ADD" rather than implying explicit drop/add events are emitted. Not a scoring deduction since the operational guidance is correct.

### MINOR: Step ordering for type change has a subtle risk
The answer says: pause consumer → ALTER Postgres → ALTER Iceberg → resume. This works for widening (int → bigint), but if the Iceberg ALTER happens before any DML in Postgres, the Iceberg table now expects bigint while in-flight Debezium events (already in Kafka before the pause) may still carry the old type. The answer could mention draining the Kafka topic before the Iceberg ALTER, or running the Iceberg ALTER first (Iceberg accepts wider type, then narrower-typed historical events still fit). Minor — not enough to fail.

---

## Resource Fix Recommendations

1. **Update resources/13 (or wherever the schema-change DDL examples live)**: change the Spark SQL example from `CHANGE COLUMN score score BIGINT` to `ALTER COLUMN score TYPE BIGINT` to match the canonical Iceberg-Spark DDL documented at iceberg.apache.org/docs/latest/spark-ddl/. Keep the Trino syntax as-is since `ALTER COLUMN ... SET DATA TYPE` is verified correct.

2. **Optional**: Add a one-line clarification on the RENAME framing — "Postgres emits a new RELATION message with the new column name; there is no explicit rename event, so downstream consumers see this as indistinguishable from DROP + ADD."

3. **Optional**: For type-change ordering, mention draining the Kafka topic or doing Iceberg ALTER before Postgres ALTER for widening cases (since Iceberg's wider type accepts narrower-typed historical events).

---

## Verdict

**PASS** — average 4.875/5, well above 4.5 threshold. The answer is comprehensive, accurate on all major technical claims, production-stack-aware, and gives the engineer an immediately usable runbook. The one syntax imprecision (Spark `CHANGE COLUMN` vs. `ALTER COLUMN ... TYPE`) is minor and easily fixed in the resource.
