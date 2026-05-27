# Iter 346 Q2 Score — Postgres-to-Iceberg: INT→BIGINT Column Type Change via Debezium CDC

## Score Table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All major technical claims verified: (1) Postgres ALTER TYPE INT→BIGINT is metadata-only on Postgres side — correct; (2) Debezium uses WAL RELATION message (pgoutput) for schema refresh on next DML, not on DDL itself — correct (matches Debezium pgoutput decoder behavior and `schema.refresh.mode=columns_diff` default); (3) Iceberg supports INT→BIGINT as widening promotion, metadata-only — verified against iceberg.apache.org schema evolution docs; (4) Trino syntax `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE BIGINT` — verified correct against Trino 481/480 ALTER TABLE docs and Iceberg connector docs (widening-only is supported); (5) Spark SQL syntax `CHANGE COLUMN some_id some_id BIGINT` — correct Iceberg Spark DDL form; (6) Spark AnalysisException on schema mismatch — correct default behavior; (7) Narrowing (BIGINT→INT) and cross-type (INT→STRING) unsupported in Iceberg 1.5.2 — verified against resources/13 line 1494-1499 and Iceberg spec. |
| Beginner clarity | 5.0 | Clear progression: Postgres side → Debezium side → Iceberg side → fix → damage check. Defines RELATION message inline ("a schema announcement inline with the row change"). Defines widening promotion ("the safest possible type change"). Uses concrete commands with comments. Frames danger upfront ("different and more dangerous situation"). No unexplained jargon. |
| Practical applicability | 5.0 | Provides three concrete diagnostic steps (Spark logs, DESCRIBE TABLE check, Kafka message inspect), exact Trino and Spark SQL fix commands, restart/recovery procedure, gap-detection runbook (Kafka consumer lag check, row-count before/after). Engineer knows exactly what to run next on the on-prem Spark+Iceberg+Trino+MinIO stack. |
| Completeness | 5.0 | Covers all five angles the question implies: (1) Did Debezium handle it? (yes, via RELATION); (2) Did Iceberg/Spark handle automatically? (no, manual ALTER required); (3) Is this same as ADD COLUMN? (no, riskier in principle); (4) The fix; (5) Damage check / data gap recovery. Bonus coverage: explicit narrowing/cross-type unsupported list, why-this-is-more-dangerous comparison block. No nuance missed. |
| **Average** | **5.00** | **STRONG PASS (PERFECT)** |

## What Worked

- Direct upfront framing ("different and more dangerous situation") matches the engineer's exact phrasing in the question.
- Correctly separated three layers (Postgres → Debezium → Iceberg) and explained behavior at each.
- Trino syntax `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE BIGINT` is the exact correct form for the production Trino 467 + Iceberg connector stack.
- Spark alternative `CHANGE COLUMN some_id some_id BIGINT` is also correct (Iceberg-on-Spark DDL form).
- Explicit "metadata-only — no Parquet files are rewritten" line correctly explains why widening is safe at the file layer.
- Damage-check runbook (logs → consumer lag → row counts) is exactly the operational sequence an on-call engineer would follow.
- Explicit callout that Kafka has the buffered events safely (7-day default retention) reduces panic appropriately.
- Final comparison table (Added column vs Type change vs Narrowing/cross-type) directly answers the user's "same way as added column?" framing.

## What Missed

Nothing material. Minor possible additions (not deductions):
- Could mention that the Iceberg field ID stays the same across the type widening (unlike a rename) — but this is implicit in "metadata-only."
- Could mention `schema.refresh.mode=columns_diff` config name explicitly (used in iter345 Q1) — not required since the topic is type change, not schema-refresh tuning.
- Could caveat that Debezium serializes BIGINT as Kafka Connect `int64` schema, which downstream Spark Avro/JSON deserialization handles automatically — but again not required at this depth.

## Technical Accuracy Verification

Verified via WebSearch against official docs:

1. **Iceberg INT→LONG widening, metadata-only**: Confirmed on iceberg.apache.org evolution docs and multiple secondary sources. Widening is read-time promotion; data files are never rewritten. Float→double and decimal precision-increase are also supported. ✓

2. **Trino `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE`**: Confirmed in Trino 481/480 SQL docs and Iceberg connector docs. Iceberg connector supports this only for widening, which matches the answer's framing. ✓

3. **Debezium pgoutput RELATION message on schema change**: Confirmed Debezium receives RELATION message before first change event for a table, whenever a schema change occurs, or when replication resumes. Default `schema.refresh.mode=columns_diff` keeps in-memory schema in sync. Important nuance: Postgres does not emit a DDL event for ALTER TYPE; Debezium detects the change only on the next DML when the RELATION message arrives. The answer correctly captures this ("The next INSERT, UPDATE, or DELETE on that table produced a WAL RELATION message"). ✓

4. **Spark AnalysisException on schema mismatch (source BIGINT vs target INT)**: Spark default behavior is strict — incompatible writes fail with AnalysisException ("Cannot write incompatible data to table"). Confirmed in Spark/Iceberg issue reports. ✓

5. **Narrowing (BIGINT→INT) and cross-type (INT→STRING) unsupported in Iceberg 1.5.2**: Confirmed in resources/13 line 1494-1499 and Iceberg spec — only int→long, float→double, decimal(P,S)→decimal(P',S) with P'>P are supported. ✓

All technical claims hold against official Debezium, Iceberg, Trino, and Spark documentation.

## Resource Fix Applied

None needed. resources/13-postgres-to-iceberg-ingestion.md already contains the necessary content:
- Line 1370 covers "Column type widening (varchar(100) → varchar(200), int → bigint)" with RELATION-message detection
- Lines 1494-1499 enumerate the widening promotions supported in Iceberg 1.5.2 and explicitly mark narrowing / cross-type as unsupported with the rewrite-and-swap workaround

The responder synthesized these resource sections with the prior Q1 (iter345/iter346 Q1) WAL RELATION explanation correctly. No resource gap exposed by this question.

## Rubric Update

**Postgres-to-Iceberg ingestion** topic:
- Prior: 4.505 avg across 126 questions
- New question score: 5.00
- New running avg: (4.505 × 126 + 5.00) / 127 = (567.63 + 5.00) / 127 = 572.63 / 127 = **4.5089/127 questions**
- Status: **PASSED** (consecutive strong/perfect scores on Postgres-to-Iceberg this iteration; column type change widening correctly explained from Postgres → Debezium → Iceberg/Spark → fix → damage-check)
