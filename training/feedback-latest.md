# Judge Feedback — Iter 397

## Summary

**Iter 397 overall: 4.34375 — PASS** (Q1 4.3125 + Q2 4.375)

Both answers in this iteration demonstrate calibrated, production-stack-fit responses with correct underlying mechanisms. No critical errors. Trajectory continues the iter390+ band of consistent ~4.3-4.4 PASS results with the teacher's resources now reliably supporting the responder on schema evolution and query performance diagnosis.

---

## Q1 — Iceberg column rename user_name → display_name

**Score: 4.3125 — PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.5 |
| Completeness | 4.0 |

### What was correct
- **RENAME COLUMN is metadata-only** — verified against Iceberg schema evolution spec; the commit writes a new schema version to the metadata.json without rewriting any Parquet data files. Millisecond-scale operation regardless of table size.
- **Field ID matching, not column names** — this is the precise underlying mechanism. Iceberg's Parquet writer embeds a numeric `field_id` in each column's Parquet schema metadata, and the reader resolves columns by ID, not by name. Renaming the column updates the schema's name<->id mapping without touching data.
- **Backward compatibility for old Parquet files** — true and follows directly from field ID matching. The old files have the same field IDs they always had; only the schema's display name for that field ID changed.
- **ADD + backfill + DROP is the wrong path** — correctly flagged as anti-pattern. That path would (a) rewrite ~all data, (b) break time-travel to pre-rename snapshots that referenced the old column, (c) risk equality-delete inconsistency if CDC is active.

### Minor gaps
1. Didn't quote the exact Trino syntax `ALTER TABLE catalog.schema.t RENAME COLUMN user_name TO display_name` — engineer might guess wrong on case sensitivity or quoting.
2. Didn't flag the **downstream consumer impact**: while the rename is engine-side instant, dashboards/dbt models/saved queries still referencing `user_name` will break. The metadata-only nature of the rename does NOT mean the change is consumer-transparent.
3. The "field ID" concept itself wasn't unpacked for a beginner — could add one sentence: "field IDs are integers Iceberg assigns to each column when it's first added; they're stored inside the Parquet file footer so readers can match columns to schema regardless of name."

---

## Q2 — GROUP BY 5B rows with CPU 6m / Scheduled 7m

**Score: 4.375 — PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 3.75 |
| Practical applicability | 4.5 |
| Completeness | 4.5 |

### What was correct
- **CPU is similar to Scheduled (17% gap) means compute-bound** — this is the sharp, defensible Trino-specific diagnostic. The 17% gap is well within "essentially equal" territory; if scheduled were 2-5x CPU, that would indicate I/O wait or driver scheduling contention. Identifying this as compute-bound (not I/O-bound) correctly redirects the engineer away from "more memory" or "faster storage" fixes that wouldn't help.
- **Whale skew detection + salt + two-level GROUP BY** — this is the canonical distributed-SQL fix for high-cardinality skew. The pattern: `GROUP BY CONCAT(key, '_', cast(mod(some_hash, N) as varchar))` first, then re-aggregate the partial sums by the original key. Industry-standard, Trino-documented pattern.
- **Pre-aggregation rollup** — the right precomputation play for billion-row GROUP BYs. Materialized daily/hourly aggregates compress 5B rows down to millions.
- **EXPLAIN ANALYZE VERBOSE per-driver inputRows** — the exact Trino diagnostic for skew confirmation. Per Trino 467 EXPLAIN docs, VERBOSE mode exposes per-driver statistics including inputRows distribution. If one driver shows 10x the rows of others, skew is confirmed.

### Minor gaps
1. **"Whale skew" jargon** — not unpacked. A beginner could read this and not know what it means. One-line explanation: "one or a few group keys (e.g., one customer with 50% of all events) end up on a single driver, which becomes the bottleneck while other drivers idle."
2. **No SQL example for salt + two-level pattern** — this is the highest-value gap. A 3-line example would multiply the practical applicability. Recommend the teacher add to resources:
   ```sql
   -- Level 1: salted partial aggregate
   SELECT key, mod(rand_int, 16) AS salt, COUNT(*) AS partial
   FROM events
   GROUP BY key, salt;
   -- Level 2: combine partials
   SELECT key, SUM(partial) AS total
   FROM (<level 1>) GROUP BY key;
   ```

---

## Pattern across iter397

Both answers exhibit the teacher's resources successfully producing **correct underlying mechanisms** (not just surface-level rule statements):
- Q1: not just "RENAME COLUMN works" but "because Iceberg matches by field ID"
- Q2: not just "fix the GROUP BY" but "CPU is similar to Scheduled indicates compute-bound, fix the right layer"

This is the calibrated technical depth we want. Both answers also remain SaaS-engineer-actionable.

The clarity dimension is the consistent weakest spot — jargon like "field ID" (Q1) and "whale skew" (Q2) is used correctly but not unpacked for a true zero-OLAP-background reader. This is a recurring pattern from iter390+ and worth a low-priority teacher action.

---

## Teacher actions next (iter 398)

1. **LOW** — Add to Iceberg schema evolution resource: explicit Trino `ALTER TABLE ... RENAME COLUMN` syntax + downstream consumer impact callout (dashboards/dbt models still reference old name).
2. **LOW** — Add to Iceberg schema evolution resource: one-line beginner explanation of "field ID" mechanism (integer assigned at column creation, stored in Parquet footer, used for column matching regardless of name).
3. **MEDIUM** — Add to Trino query performance diagnosis resource: 3-line SQL example for the salt + two-level GROUP BY pattern. This is high-value because the textual description without code is hard for a beginner to translate into working SQL.
4. **LOW** — Add to Trino query performance diagnosis resource: one-line "whale skew" definition (one or a few group keys dominate one driver) + how to detect from EXPLAIN ANALYZE VERBOSE per-driver inputRows distribution.

## Judge probe targets next (iter 398)

Carry-forward backlog:
- Hive to Iceberg migration 3rd angle (explicit Trino-from-migrate per iter395 verification)
- Equality-delete 2nd angle: MERGE INTO slowness after 6mo CDC
- HMS to Nessie no-downtime migration
- SPILL_FAILED 60GB query at 200GB cap
- MERGE INTO rollback
- OPA-override timeout pattern
- Schema registry compatibility
- EXPLAIN TYPE IO + VALIDATE
- Result caching options on Trino 467
- Iceberg branches fast_forward
- Bucket partition sizing
- JWT+OPA concurrency at 1000 QPS
- Partition spec migration
- Iceberg tagging 3rd angle
- fs.cache 3rd angle (JMX exposure)

## Trajectory

iter370 to iter397:
4.625, 4.375, 4.47, 3.98 FAIL, 4.5625, 4.75, 4.1875, 4.4375, 4.40625, 4.5625, 3.25 FAIL, 4.71875, 4.8125, 4.78125, 4.375, 4.094, 4.4375, 4.4375, 4.4375, 4.25, 3.125 FAIL, 4.75 PASS, 4.125 PASS, 3.9375 FAIL, 4.625 PASS, 4.75 PASS, 3.125 FAIL, 4.3125 PASS, 4.375 PASS, **4.34375 PASS**.

Recent 5-iter window (iter393-397): 4.75, 3.125 FAIL, 4.3125, 4.375, 4.34375 — average 4.18 (one critical failure at iter394 weighs on window). Strip the failure: 4.44 average over passing iters, well above the 3.5 pass threshold.
