# Iter141 Q2 — Judge Evaluation

**Question**: Postgres ADD COLUMN to a Debezium-streamed table → Iceberg has mixed populated/null rows. What does Debezium do automatically, what manual steps are needed for consistency?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter141-q2.md`

---

## Verification (WebSearch against debezium.io, iceberg.apache.org, trino.io)

### CORRECT claims

1. **Debezium pgoutput detects ADD COLUMN via RELATION messages, no restart needed** — CONFIRMED.
   - PostgreSQL `pgoutput` emits an updated RELATION message on the first DML after a DDL change. Debezium's `PgOutputMessageDecoder` consumes RELATION messages and updates its in-memory schema cache.
   - Source: debezium.io PostgreSQL connector docs; Debezium GitHub `PgOutputMessageDecoder.java`.

2. **`schema.refresh.mode=columns_diff` is the default** — CONFIRMED.
   - Debezium PostgreSQL docs state this is the default and "the safest mode that ensures the in-memory schema stays in-sync with the database table schema."
   - The answer doesn't name this property explicitly but the underlying behavior described matches.

3. **Pre-DDL rows return NULL for the new column** — CONFIRMED.
   - Postgres does not retroactively rewrite WAL entries for existing rows. UPDATE statements only emit changed-column metadata in the WAL after the DDL. Iceberg's metadata-only ADD COLUMN means old Parquet files return NULL for the new column on read.
   - Source: iceberg.apache.org evolution docs.

4. **Trino 467 `ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR`** — CONFIRMED.
   - Trino's ALTER TABLE syntax is documented as `ALTER TABLE name ADD COLUMN column_name data_type ...`. The fully-qualified catalog.schema.table form is valid.

5. **Spark MERGE INTO throws AnalysisException on schema mismatch when source has columns the target doesn't** — CONFIRMED in spirit.
   - Spark's MERGE INTO with explicit column references (or `INSERT *`) requires schema alignment. While the docs cite Delta-specific examples, the underlying behavior also applies to Iceberg's MERGE INTO procedure when source schema diverges from target.

6. **Iceberg ALTER TABLE ADD COLUMN is metadata-only, instant** — CONFIRMED.
   - Iceberg docs: "ADD COLUMN is a metadata-only operation. The values of newly added columns on existing rows are NULL."

7. **`snapshot.mode=never` prevents re-snapshot on restart** — CONFIRMED.
   - Documented Debezium PostgreSQL behavior.

### INCORRECT / MISLEADING claim (significant)

**The claim that "with `snapshot.mode=initial` (the default): restart triggers a full table re-snapshot, flooding Kafka with 3 months of events and causing millions of duplicates in Iceberg" is WRONG.**

Per Debezium PostgreSQL docs and multiple secondary sources (Conduktor's snapshot modes explainer, RisingWave best-practices article):

> "The connector performs a full snapshot the first time it starts (no offsets exist). After the snapshot completes, the connector streams subsequent changes from the transaction log. On later restarts, if offsets exist, the snapshot is skipped and streaming resumes from the saved position."

A simple restart of a healthy Debezium connector with `snapshot.mode=initial` will NOT trigger a re-snapshot, because the connector's Kafka offsets persist across restarts. A re-snapshot only happens if (a) offsets are deleted, (b) the connector name changes, or (c) `snapshot.mode=always` is set.

This is a recurring issue in this resource (iter94 Q2 raised the same concern about oversimplifying snapshot.mode semantics — see rubric line 4490 confirming "snapshot.mode=initial...trigger is 'no offsets recorded for the logical server name' — i.e., Debezium checks its own Kafka offset store"). The teacher should fix the "What NOT to Do" section to clarify that the risk is offset loss, not a plain restart.

The intent of the warning (don't restart needlessly) is fine, but the stated *reason* is technically wrong and could confuse engineers who later need to restart the connector for legitimate operational reasons (config change, version upgrade).

### Minor observations

- The MERGE backfill SQL uses self-referential `WHERE new_col IS NULL` reading from the same table it's writing — this works but is unusual. A more typical backfill would join against a source-of-truth table or use UPDATE directly (which the answer also offers as alternative). Acceptable.
- "Column silently dropped" with `mergeSchema=false` — strictly speaking, Iceberg + Spark Structured Streaming would raise an error rather than silently drop. The framing is slightly loose but not actively misleading.
- The hardcoded `after_schema` example (StructType) is a realistic Spark pattern; good practical detail.
- No mention of `op='r'` snapshot events or tombstones, but those aren't relevant to this question.
- The "pause consumer / ALTER Iceberg / update Spark schema / resume" sequence is correct and matches resources/13's CDC schema-evolution pattern.
- Good summary table at the end.
- Appropriately scoped to the production stack (Trino 467, on-prem k8s, Spark consumer, MinIO).

---

## Scoring

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 4 | Core Debezium pgoutput/RELATION mechanics, Iceberg metadata-only ALTER, Trino syntax all correct. One significant error: `snapshot.mode=initial` restart does NOT trigger re-snapshot when offsets exist — answer's framing is incorrect. Minor looseness on `mergeSchema=false` "silently dropped." |
| **Beginner clarity** | 5 | Excellent structure: separates Debezium auto-behavior from manual steps, table-summary at the end, concrete code blocks, explains why mixed-null rows are expected. No unexplained jargon. Step-by-step procedure with kubectl/SQL examples. |
| **Practical applicability** | 5 | Engineer can execute the 4 steps directly: pause consumer, ALTER Iceberg, update Spark StructType, resume. Realistic backfill SQL. Correct on production stack (Trino 467, k8s, Spark). |
| **Completeness** | 5 | Addresses both halves of the question (what does Debezium do, what manual steps). Covers Postgres → Debezium → Kafka → Spark → Iceberg layers. Includes backfill discussion as optional. Summary table ties it all together. |
| **Average** | **4.75** | PASS |

---

## Verdict

**PASS** (4.75 / 5)

The answer is operationally excellent and would correctly guide the SaaS engineer through the schema-change sequence. The one significant technical error — claiming a Debezium restart with `snapshot.mode=initial` triggers a re-snapshot — needs correction in the resource, but it does not change the recommended action (don't restart unnecessarily). The answer's instructional value for the asked scenario remains high.

## Topics touched

- **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling** — already PASSED (4.473, 97 questions). Update with this iteration's score.

## Action for teacher (queued, non-blocking)

Update `resources/13-postgres-to-iceberg-ingestion.md` Debezium snapshot.mode section:
- Clarify that `snapshot.mode=initial` re-snapshots **only when no offsets exist** (first start, deleted offsets, or renamed connector) — NOT on every restart.
- The genuine risk of a needless restart is operational (transient downtime, replication slot disconnect timing) and the (real) risk of re-snapshot **if** offsets get lost, not that a routine restart causes a re-snapshot.
- Cross-reference iter94 Q2 feedback for the same gap (snapshot.mode trigger semantics).
