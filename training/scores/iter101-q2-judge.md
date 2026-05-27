# Iter 101 Q2 — Judge Score

**Topic**: Postgres-to-Iceberg ingestion (mid-stream schema change: Postgres ADD COLUMN → Debezium WAL relation message → Iceberg ADD COLUMN propagation)

**Question**: We added a new nullable varchar column to a Postgres source table last week. Debezium has been doing CDC on it for months. The Iceberg table doesn't show the new column. What actually happens on the Debezium/Iceberg side when a column is added mid-stream, and what do we need to do to propagate it?

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | One factual error — `debezium.sink.iceberg.allow-field-addition` defaults to `true`, NOT `false` as the answer claims. The rest is verified correct. |
| Beginner clarity | 5.0 | Clear layered explanation (Postgres → Debezium → Kafka → Iceberg), no unexplained jargon, mental-model section, gotchas list. |
| Practical applicability | 4.5 | Three-step fix is exactly right and directly runnable on the production stack. Slight deduction because the wrong default for `allow-field-addition` could mislead the engineer's prevention planning ("enable it" — but it's already on). |
| Completeness | 5.0 | Covers WAL relation-message timing, Spark vs debezium-server-iceberg sink paths, ALTER TABLE metadata-only behavior, NULL backfill semantics, REPLICA IDENTITY FULL, gotchas, prevention, and mental model. |
| **Average** | **4.625** | |

**Verdict**: PASS (above 3.5 threshold), but flag the `allow-field-addition` default bug for the teacher.

---

## Verified via WebSearch

1. **Debezium detects schema changes via WAL relation messages, not by intercepting DDL** — CONFIRMED at debezium.io and github.com/debezium/debezium. Postgres logical decoding "does not support DDL changes" — Debezium learns of schema changes via the relation (R) message that precedes the first change event after the schema change.
2. **New column appears in Kafka only after the next DML hits the table** — CONFIRMED. "When you add a column with a default value in PostgreSQL, the database does not generate change events for existing rows in the WAL. Without any such event for pre-existing rows, the schema change doesn't get propagated to the sink connector." Only INSERT/UPDATE/DELETE triggers the relation refresh.
3. **Iceberg `ALTER TABLE ADD COLUMN` is metadata-only** — CONFIRMED at iceberg.apache.org/docs/latest/evolution/. "ADD COLUMN is a metadata-only operation"; "no data files need to be rewritten"; "takes milliseconds, regardless of table size." Iceberg uses unique column IDs.
4. **Old rows automatically return NULL for new columns without backfill** — CONFIRMED at iceberg.apache.org. "The values of newly added columns on existing rows are NULL." Iceberg auto-fills NULL when reading old Parquet files that don't physically contain the column.
5. **REPLICA IDENTITY FULL required for `before` to contain all columns on DELETE/UPDATE** — CONFIRMED at debezium.io. With REPLICA IDENTITY FULL, "change events will include the before and after values for a row's columns." With DEFAULT, unchanged TOAST columns are excluded from `before`.
6. **Spark Iceberg write rejects extra columns by default** — CONFIRMED at iceberg.apache.org/docs/latest/spark-writes/. Default behavior rejects unknown columns. mergeSchema option exists but requires `write.spark.accept-any-schema=true` on the table AND `mergeSchema=true` on the writer. The answer correctly characterizes the default-rejection behavior.

---

## Errors found

### BUG (Technical Accuracy): `debezium.sink.iceberg.allow-field-addition` default

The answer states (line 33):

> "The sink has `debezium.sink.iceberg.allow-field-addition`, which **defaults to `false`**. With `false`, the sink rejects writes containing new fields. With `true`, it auto-runs `ALTER TABLE ADD COLUMN` when it sees a new field in the Kafka message."

**This is incorrect.** Per the official memiiso/debezium-server-iceberg docs (https://github.com/memiiso/debezium-server-iceberg/blob/master/docs/iceberg.md), the property defaults to **`true`**. The doc table reads exactly:

> `debezium.sink.iceberg.allow-field-addition` | `true` | Allow field addition to target tables. Enables automatic schema evolution, expansion.

**Impact**: If the engineer is using debezium-server-iceberg with default config, the new column would in fact propagate automatically — the answer's narrative that the sink "rejected" the column is wrong for the default-configured sink path. This narrows the root cause to: (a) the engineer is using the Spark consumer (not debezium-server-iceberg), or (b) the sink has been explicitly set to `false`, or (c) no DML has happened on the Postgres table since the ALTER. The answer's three-step manual ALTER TABLE fix is still correct and safe to run, but the explanation for WHY Iceberg "doesn't have the column" is partially mis-attributed in the debezium-server-iceberg case.

The answer's "Prevention for next time" bullet ("enable `allow-field-addition=true` for automatic column propagation") also reads as if this is opt-in, when it's actually opt-out.

### Minor (not score-affecting)

- The "Trino metadata cache, wait 60 seconds" gotcha is a generic claim. Trino's Iceberg connector caches table metadata per-coordinator with TTL governed by `iceberg.metadata-cache.ttl` (default 0 i.e. disabled in many recent releases; varies). A safer phrasing would be "Trino may have cached the table metadata — refresh by re-resolving the table or restarting the coordinator." This is a minor nit, not a bug.

---

## Strengths

1. **Correctly explains the WAL relation-message mechanism** — opens with "Debezium does not directly detect DDL statements" and walks through the three-step sequence (ALTER → next DML → relation message). This is the single most-misunderstood piece and the answer nails it.

2. **Calls out the "timing trap"** — "If nobody writes to the table after the ALTER, Debezium keeps publishing events with the old schema." This is exactly the silent-failure mode SaaS engineers hit. Gotcha #1 reinforces with a concrete workaround (`UPDATE your_table SET metadata_note = NULL WHERE id = 1` to force a relation refresh).

3. **Distinguishes the two consumer paths** — Spark Structured Streaming vs debezium-server-iceberg sink. The engineer reading this knows immediately which set of advice applies.

4. **Correct Iceberg semantics** — `ALTER TABLE ADD COLUMN` is metadata-only, completes in milliseconds, no data rewrite. Old rows return NULL automatically because Iceberg tracks columns by unique ID and fills NULL when the column ID is missing from a Parquet file. Verified against iceberg.apache.org/docs/latest/evolution/.

5. **Correct REPLICA IDENTITY FULL framing** — "nothing special needed for the new column; if already FULL, the new column is automatically included in before-images." Correctly identifies FULL as needed for complete `before` on UPDATE/DELETE, not for ADD COLUMN propagation per se.

6. **Concrete three-step fix** — manual ALTER TABLE in Trino/Spark, resume pipeline, verify with SELECT. Each step is directly runnable on the production stack.

7. **Mental model paragraph at the end** — single-paragraph synthesis: "Debezium detects schema changes via WAL and publishes them to Kafka. Iceberg does not consume those schema changes automatically." Crisp.

8. **Production stack fit** — Trino + Spark + MinIO + Hive Metastore + Debezium 2.x all named or implied; no public-cloud-only tools referenced; `ALTER TABLE iceberg.analytics.your_table ADD COLUMN metadata_note VARCHAR` is the correct Trino 467 syntax.

---

## Gaps

1. **The `allow-field-addition` default bug** (see Errors). This is the only material gap.

2. **Spark `mergeSchema` option not mentioned**. The answer says Spark "enforces strict schema matching by default" (correct) and that writes are "rejected" (correct), but does not mention that Iceberg's Spark writer DOES support `mergeSchema=true` + `write.spark.accept-any-schema=true` on the table as an opt-in path to auto-evolution. This is a missing-but-useful alternative for engineers running the Spark consumer path, parallel to `allow-field-addition` for the sink path. Not score-deducting (the question is "what do I do RIGHT NOW", and manual ALTER is the right answer), but resource-worthy.

3. **"Spark consumer rejected the column silently"** — the answer says the rows "are never written, the column data is lost." Worth being more precise: the Spark write FAILS LOUDLY with a schema-mismatch exception (the streaming job goes to FAILED state), it does not silently drop rows. The phrase "Iceberg is dropping it" in the mental-model paragraph could mislead an engineer into thinking writes succeeded with the new column silently truncated. They didn't — the write failed and offsets did not advance.

---

## Resource fix recommendations

**HIGH (technical correctness)**:
- In `resources/13-postgres-to-iceberg-ingestion.md` (or wherever debezium-server-iceberg sink config is documented), correct the default for `debezium.sink.iceberg.allow-field-addition` to **`true`**. Verify the entire properties table against https://github.com/memiiso/debezium-server-iceberg/blob/master/docs/iceberg.md.

**MEDIUM (precision)**:
- Add a one-paragraph note that on the Spark consumer path, Iceberg's `mergeSchema=true` writer option PLUS `write.spark.accept-any-schema=true` table property is the equivalent of `allow-field-addition` for Spark. This is the parallel auto-evolution mechanism for engineers not running debezium-server-iceberg.
- Clarify failure mode wording: when Spark writes a DataFrame with an unknown column to an Iceberg table without mergeSchema, the WRITE FAILS LOUDLY (schema-mismatch exception, streaming job goes to FAILED state) — it does not silently drop the column data. Engineers can detect this via Spark job failure, not via missing data.

**LOW (precision)**:
- Note that Trino metadata caching for Iceberg is governed by `iceberg.metadata-cache.ttl` and varies by version (Trino 467 default behavior should be cited specifically).

---

## Topic state update

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior: 4.477 across 85 questions
- New score: 4.625
- New running average: (4.477 × 85 + 4.625) / 86 = (380.545 + 4.625) / 86 = 385.170 / 86 ≈ **4.479 across 86 questions**
- Status: PASSED (well above 3.5 threshold)

---

## Production fit

Fully compatible with the on-prem stack: Trino 467 + Iceberg 1.5.2 + Spark + MinIO + Hive Metastore + Debezium 2.x. The three-step fix runs directly on the stack as written. The `ALTER TABLE iceberg.analytics.your_table ADD COLUMN metadata_note VARCHAR` Trino syntax is correct for Trino 467. The `REPLICA IDENTITY FULL` advice is correct for Postgres. The single non-fit issue is the wrong default on the debezium-server-iceberg config property — this doesn't break the fix but does mis-direct the engineer's understanding of what was configured wrong.

---

## Sources verified

- [Debezium PostgreSQL Connector documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [memiiso/debezium-server-iceberg Iceberg sink config](https://github.com/memiiso/debezium-server-iceberg/blob/master/docs/iceberg.md)
- [Apache Iceberg Schema Evolution](https://iceberg.apache.org/docs/latest/evolution/)
- [Apache Iceberg Spark Writes (mergeSchema)](https://iceberg.apache.org/docs/latest/spark-writes/)
- [Debezium blog — Adding a new table with Debezium (schema refresh mechanics)](https://debezium.io/blog/2025/10/06/add-new-table-to-capture-list/)
- [OneUptime — How to Handle Debezium Schema Changes (DML required to refresh)](https://oneuptime.com/blog/post/2026-01-28-debezium-schema-changes/view)
