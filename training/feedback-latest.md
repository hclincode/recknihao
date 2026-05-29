# Judge Feedback — Iter 390

**Date**: 2026-05-30
**Phase**: extended
**Overall score**: (3.5 + 4.75) / 2 = **4.125 — PASS (>= 4.0)**

---

## Q1 — Iceberg incremental reads since last snapshot

**Score: 3.5 — BORDERLINE PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 3.5 |
| Beginner clarity | 4.0 |
| Practical applicability | 3.5 |
| Completeness | 3.0 |

### What was right
- Honest "not enough info in resources" — responsible refusal-to-hallucinate; preserves TA over fabrication.
- Correctly identified time-travel (`FOR VERSION AS OF`) and `$snapshots` metadata table.
- Correctly concluded that current resources cannot answer the row-level change-data query.
- Recommended official Iceberg docs as fallback.

### What was missing — RESOURCE GAP (HIGH PRIORITY)
The canonical incremental-read answer DOES exist publicly in Trino docs and Iceberg docs:

1. **Trino**: `system.table_changes(schema_name, table_name, since_snapshot_id, end_snapshot_id)` table function returns row-level changes with output columns:
   - `_change_type` — insert / delete / update_before / update_after
   - `_change_version_id` — snapshot id where the row changed
   - `_change_timestamp` — when the snapshot committed
   - Verified at trino.io/docs/current/connector/iceberg.html
2. **Spark**: `spark.read.format("iceberg").option("start-snapshot-id", id1).option("end-snapshot-id", id2).load("db.table")` for batch incremental ETL.

This is the SECOND iteration in three where the responder honestly-punted on a publicly-documented Trino feature (iter388 Q2 was the first: `fs.cache.enabled`; teacher patched in iter389). The honest-punt is correct behavior given the resource state, but the resource state must improve.

### Teacher action (HIGH PRIORITY for iter391)
Add a resource page covering:
- `system.table_changes` Trino table function with full output schema and CDC use case (weekly export downstream, build SCD2, materialized-view-like incremental refresh)
- Spark `start-snapshot-id` / `end-snapshot-id` read options with production-stack-fit (Spark ingestion + Trino query split)
- Workflow: query `$snapshots` to find boundary `snapshot_id`, store last-seen id in state table, pass to `system.table_changes` on next run.
- Caveats: requires Iceberg format-version >= 2; copy-on-write vs merge-on-read interaction with `_change_type`.

---

## Q2 — Trino PostgreSQL connector accessing all schemas

**Score: 4.75 — STRONG PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.5 |

### What was right
- Matches trino.io/docs/current/connector/postgresql.html exactly: "The PostgreSQL connector can only access a single database within a PostgreSQL server."
- Within ONE database, ALL schemas auto-exposed as `catalog.schema.table` — no per-schema config.
- `connection-url=jdbc:postgresql://host:5432/dbname` is scoped at database level — correctly framed.
- Separate `.properties` files only needed for separate databases or PG servers.
- Engineer knows exactly what to do: one catalog file, then enumerate via `SHOW SCHEMAS FROM catalog`.

### Minor gaps (low priority)
- Could mention `case-insensitive-name-matching=true` for PG schemas with MixedCase (common gotcha — PG quoted identifiers vs Trino lowercasing).
- Could mention `schema-pattern` to whitelist a subset of schemas when the DB has 100+ schemas.
- Could mention `case-insensitive-name-matching-cache-ttl` for DDL-heavy environments.

These are completeness polish items, not correctness issues.

---

## Patterns and Teacher Priorities

### Two-iteration PASS streak with recurring resource-gap pattern
- iter389: 4.75 PASS (teacher patched two iter388 gaps: Iceberg tagging + fs.cache.enabled)
- iter390: 4.125 PASS (Q1 honest-punt revealed THIRD documented-Trino-feature resource gap)

### Honest-punt floor + canonical-answer ceiling
Q1 3.5 (honest-punt) + Q2 4.75 (canonical answer) is the iter390 shape. The honest-punt floor reliably clears the 3.5 per-question bar and keeps overall above 4.0. But each honest-punt is a resource-gap signal — teacher must patch.

### Topic score updates
- Iceberg table maintenance: 4.5098/51 -> 4.4904/52 (mild drop from Q1 borderline, still PASS)
- Trino federation: 4.4910/263 -> 4.4920/264 (mild rise from Q2 strong pass, NEEDS WORK toward 4.5 override threshold)

### Beginner clarity ceiling
Q1 BC 4.0 (honest-punt clarity), Q2 BC 4.5 (clear mechanic explanation). Inline-gloss strategy ("jdbc:postgresql URL = the JDBC connection string Trino uses to talk to Postgres", "catalog = a named connection in Trino, `.schema.table` resolves under it") could push both Qs to 4.75+.

---

## Next Iteration Judge Probe Targets

1. **Iceberg incremental reads 2nd angle**: "Weekly CDC export to downstream warehouse — what rows changed in the last 7 days?" — tests `system.table_changes` + Spark `start-snapshot-id`/`end-snapshot-id` after teacher patches gap.
2. **Trino Postgres connector 2nd angle**: "I have a PG schema named `MixedCase.Customer_Records` and Trino says it doesn't exist" — tests `case-insensitive-name-matching=true`.
3. **Carry-forward iter387-389 targets**: HMS -> Nessie no-downtime catalog migration, SPILL_FAILED at 60GB despite 200GB cap (aggregate vs per-query), Z-order 2nd angle, audit log 2nd angle, MERGE INTO rollback, Trino timeout OPA-override interaction, schema registry forward/backward compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches concurrent fast_forward, bucket sizing 32/128/256, JWT+OPA concurrency, partition spec migration without downtime, Iceberg tagging 3rd angle "drop expired tag + $refs", fs.cache 3rd angle "JMX cache-hit-rate metric + tuning max-sizes when working set > cache".

---

## Trajectory iter370-390

4.625 -> 4.375 -> 4.47 -> 3.98 FAIL -> 4.5625 -> 4.75 -> 4.1875 -> 4.4375 -> 4.40625 -> 4.5625 -> 3.25 FAIL -> 4.71875 -> 4.8125 -> 4.78125 -> 4.375 -> 4.094 -> 4.4375 -> 4.4375 -> 4.4375 -> 4.25 -> 3.125 FAIL -> 4.75 PASS -> **4.125 PASS**
