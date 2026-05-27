# Judge Score — Iter 87 Q2

## Score: 4.75 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |

## Points covered

**Postgres-to-Iceberg ingestion topic — points addressed:**
1. Skipping full-load for a brand-new, nearly-empty table is supported — no baseline snapshot required by Iceberg.
2. What an incremental pipeline actually needs: a starting watermark or LSN, not a pre-populated table.
3. Empty Iceberg table creation (`CREATE TABLE ... USING iceberg`) is metadata-only and instant.
4. Watermark-based incremental example with concrete JDBC `SELECT ... WHERE updated_at > ?` pattern.
5. Debezium CDC starting from a given LSN is the normal operating mode — no special baseline required.
6. The one real risk: pre-pipeline rows are missed if you start from "now."
7. Option 1 (recommended): bootstrap small existing row count then set watermark to `max(updated_at)` — explicit code.
8. Option 2 (accept the gap): only when no historical data and no audit requirement — preconditions listed.
9. Mental model: full-load exists for large historical tables (e.g., 500M-row 3-year backfill), not as a technical prerequisite.
10. Iceberg has no concept of a "baseline snapshot required before incremental writes" — explicitly stated.
11. Debezium's relationship to Iceberg: Debezium doesn't care about target table state, it only reads WAL.
12. Practical 5-step checklist: create table → decide bootstrap vs gap → set watermark → start pipeline → verify with COUNT(*).

## Accuracy notes

Verified against iceberg.apache.org and debezium.io:

- **Iceberg baseline requirement**: Correctly stated as "none." Iceberg's append/MERGE writes do not require any prior data; documented in iceberg.apache.org/docs/latest/spark-writes.
- **Debezium `snapshot.mode=never`**: Correctly stated as a supported mode for starting without a snapshot. However, the answer's "start from a given LSN" framing is **slightly oversimplified** — without a stored offset, the connector streams from the **replication slot's creation point**, not the absolute "now." This is a real-world gotcha that engineers will encounter; the answer's framing implies more precision than Debezium gives out of the box.
- **`createOrReplace()` bootstrap pattern**: Reasonable for small initial loads on Hive Metastore + MinIO. Note apache/iceberg#14625 shows `createOrReplace()` has known issues on some object stores (GCS, ADLS Gen2, OneLake) — MinIO via S3 typically works, but `createIfNotExists()` is safer for true new-table bootstrapping because `createOrReplace()` will wipe data on accidental re-run.
- **"Watermark from now" approach**: Not formally documented as an Iceberg/Debezium feature — it is a pipeline-level design pattern. The answer correctly presents it as a design choice with explicit preconditions.

## Issues / gaps

1. **Debezium `snapshot.mode=never` semantics oversimplified.** Without a stored offset, the connector starts from the replication slot's creation position, not "now." For true from-now CDC, the slot must be created at the desired starting point before the connector first starts. Not mentioned; could lead to surprise replays.
2. **MERGE INTO vs append semantics not addressed for CDC-fed pipelines.** If the first CDC events include UPDATEs/DELETEs for rows that pre-date the start LSN, MERGE INTO will treat them as inserts or no-ops, creating temporary skew until the table catches up.
3. **`createOrReplace()` is shown for bootstrap but is risky on re-run.** A retry of the bootstrap job after the pipeline has already appended new rows would wipe them. `createIfNotExists()` (or `CREATE TABLE IF NOT EXISTS` + `append()`) is the safer idempotent pattern.
4. **Production stack not named.** The advice fits the on-prem Spark + Iceberg 1.5.2 + MinIO + HMS stack, but a one-line anchor would have grounded it.
5. **Replication slot lifecycle not covered.** The actual Debezium prerequisites (CREATE PUBLICATION, CREATE REPLICATION SLOT, replica identity FULL for UPDATE/DELETE before-images) are the real first hurdle for an engineer new to Debezium — not the snapshot mode.
6. **Sanity check missing.** Option 2 ("start from now, accept the gap") becomes dangerous if the engineer's "nearly empty" assumption is wrong. A one-line `SELECT COUNT(*) FROM source_table` check before choosing Option 2 would harden the recommendation.

## Resource fix needed?

**Low priority.** Topic is at 4.462 average across 80 questions — well above the 3.5 pass threshold. Suggested polish to `resources/13-postgres-to-iceberg-ingestion.md`:

- Add a "bootstrapping a brand-new Postgres table" subsection covering: (a) when full-load is genuinely unnecessary, (b) the Debezium replication-slot-creation-time gotcha for `snapshot.mode=never`, (c) why `createIfNotExists()` + `append()` is safer than `createOrReplace()` for idempotent bootstrap re-runs, (d) the replication slot + publication + replica identity prerequisites.
- Mention the row-count sanity check before committing to Option 2.

**Sources verified:**
- [Debezium connector for PostgreSQL](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Apache Iceberg Spark Writes](https://iceberg.apache.org/docs/latest/spark-writes/)
- [apache/iceberg#14625 — createOrReplace fails on some object stores](https://github.com/apache/iceberg/issues/14625)
