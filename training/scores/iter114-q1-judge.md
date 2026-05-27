# Iter 114 Q1 — Judge Report

**Topic**: Postgres-to-Iceberg ingestion: schema evolution mid-stream with Debezium CDC
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter114-q1.md`
**Resource**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| 1. Technical accuracy | 3.5 | Mostly correct, with one significant error (over-broad claim that both knobs are required) and one omission (no mention that PG WAL needs DML after DDL for Debezium to surface the column). |
| 2. Clarity | 4.5 | Well-structured, plain language, good "why NULL" framing for a SaaS engineer; summary table is crisp. |
| 3. Practical completeness | 4.0 | Concrete ALTER TABLE statements, two backfill recipes (post-release vs pre-release), explicit "don't restart Debezium" guidance. Production-stack-aware (Trino + Spark + Iceberg). |
| 4. Completeness of coverage | 3.5 | Covers core path well, but misses: (a) the mode-1 (debezium-server-iceberg) vs mode-2 (Spark consumer) distinction, (b) the DML-triggers-relation-message detail explaining WHY the columns were already silently flowing, (c) the `MERGE INTO` ignores `mergeSchema` caveat (which is precisely relevant to a CDC consumer that likely uses MERGE). |

**Average**: (3.5 + 4.5 + 4.0 + 3.5) / 4 = **3.875** — **PASS** (>= 3.5 threshold).

---

## Verdict

PASS, but with a meaningful technical concern that should be corrected in the next teacher iteration. The answer gives the SaaS engineer a working recipe and is correct enough to ship, but the framing of "both knobs are required" is too universal and contradicts the resource's own (correct) statement that `mergeSchema` is irrelevant to `MERGE INTO` — the exact write shape a CDC consumer almost always uses.

---

## What was verified correct (via WebSearch against official docs)

1. **Iceberg schema evolution is metadata-only for `ADD COLUMN`** — confirmed against `iceberg.apache.org/docs/latest/spark-writes/` and Trino docs. The answer's claim that the three `ALTER TABLE ADD COLUMN` statements complete in milliseconds and don't rewrite Parquet is correct.

2. **`TIMESTAMP(6)` is the correct precision for Iceberg via Trino** — confirmed against trinodb/trino issue #19708. The answer uses `TIMESTAMP(6)` rather than bare `TIMESTAMP`, which is correct for Iceberg (Trino's default `TIMESTAMP(3)` is rejected on Iceberg ADD COLUMN). Good catch.

3. **Two-knob pattern `write.spark.accept-any-schema=true` + `.option("mergeSchema","true")`** — confirmed against `iceberg.apache.org/docs/1.5.0/spark-writes/` and apache/iceberg issue #8005. Both required when using `writeTo(...).append()` for schema auto-evolution.

4. **Old rows return NULL automatically (no Parquet rewrite)** — confirmed. This is Iceberg's column-ID-based schema-evolution guarantee.

5. **Debezium does NOT need to restart** — confirmed against debezium.io stable docs. The connector tracks the schema via WAL relation messages and continues from its last committed LSN.

6. **Iceberg columns are always nullable** — correct per Iceberg spec.

---

## Errors and gaps

### ERROR 1 (technical accuracy, moderate severity)
The answer asserts in Step 2 that **both** `write.spark.accept-any-schema=true` and `.option("mergeSchema","true")` are "required" for the Debezium → Spark → Iceberg pipeline to populate the new columns. This is **only true if the consumer uses `writeTo(...).append()`**. Most production CDC consumers use **`MERGE INTO`** (because CDC events include updates and deletes, not just inserts), and per apache/iceberg issue #5556, **`MERGE INTO` ignores `mergeSchema` entirely**. Resource 13 lines 2753 and 2983 already document this correctly. The answer omits the caveat, which means an engineer following Step 2 verbatim against a `MERGE INTO`-based CDC consumer will:
- Set the table property and the writer option.
- Believe their pipeline is now auto-evolving.
- Continue silently dropping new columns on every MERGE.

This is precisely the failure mode the question is describing, and the answer accidentally prescribes the same broken fix.

### ERROR 2 (technical accuracy, moderate severity)
The answer says "Debezium detected the schema change automatically (via the `schema_history` topic it maintains)." This is misleading for the Postgres connector specifically. **PostgreSQL does NOT have a schema-history topic** — that mechanism is for MySQL, MariaDB, and SQL Server. The Postgres connector tracks schema via **WAL relation messages**, and (per debezium.io and the Debezium PG docs) **the relation message for a newly-added column is only emitted after the next DML against the table**. Resource 13 line 1789 already documents this correctly. If the SaaS engineer's `user_profiles` table is read-heavy and write-light, the new columns may not appear in the Debezium events at all until the next INSERT/UPDATE on the table — which would explain "users who signed up after the migration" having NULLs in a different way than the answer suggests.

### GAP 1 (completeness of coverage, moderate severity)
The answer treats the production setup as exclusively Pattern C with a Spark Structured Streaming consumer. Resource 13 (correctly) documents two distinct CDC deployment modes:
- **Mode 1: debezium-server-iceberg** — `debezium.sink.iceberg.allow-field-addition=true` is the default; auto-ALTERs the Iceberg table; no manual intervention.
- **Mode 2: Spark Structured Streaming** — manual `ALTER TABLE ADD COLUMN` required; the `allow-field-addition` property does NOT apply.

The answer should at least acknowledge "if you're running debezium-server-iceberg, the sink may already be handling this — check that property first." Without this branch, an engineer on Mode 1 will run the manual ALTER unnecessarily and may be confused why their sink wasn't already doing it (or worse, why it's failing now).

### GAP 2 (completeness of coverage, minor)
The answer's backfill recipe filters by `created_at >= '2026-05-18'`. This date is fabricated from context and the answer does not flag that the engineer needs to substitute the actual migration timestamp. A one-line "replace this with the date your team ran the Postgres ADD COLUMN migration" note would prevent confusion.

### GAP 3 (technical accuracy, minor)
The summary table claims "`mergeSchema=true` + `accept-any-schema` — Yes — both required." Combined with ERROR 1, this reinforces the over-broad claim. The correct framing would be "both required for `writeTo().append()`; not applicable to `MERGE INTO` — for `MERGE INTO` consumers, ALTER TABLE first is mandatory."

---

## Resource fix recommendations

### HIGH priority

**File**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
**Where**: Add a new dedicated subsection under the "Schema evolution: handling new columns added to Postgres" section (around line 2633), titled **"Mid-stream schema changes in a running CDC pipeline (the most common SaaS scenario)"**.

The subsection should answer the exact question shape the SaaS engineer asked, in this order:

1. **Symptom recognition** — "New columns appear NULL in Iceberg for new rows; Debezium logs no errors; no crash." Pattern-match the user to this section.

2. **Root cause checklist (in order to verify)**:
   a. Has any INSERT/UPDATE happened on the Postgres table since the ADD COLUMN? If not, Debezium has not yet emitted a relation message for the new schema, and the column is not yet in the Kafka events. (Cite WAL relation message behavior. Reference resource line 1789.)
   b. Does the Iceberg table have the new columns? If not, the consumer is silently dropping them. (Cite default Iceberg `append()` behavior — fails on schema mismatch — vs `MERGE INTO` behavior — silently drops extra fields.)
   c. Which CDC deployment mode are you running — debezium-server-iceberg sink (mode 1) or Spark Structured Streaming consumer (mode 2)? The fix differs.

3. **Mode-specific fix matrix**:

   | Mode | Fix | Auto-evolution? |
   |---|---|---|
   | debezium-server-iceberg, `allow-field-addition=true` (default) | Nothing — sink auto-ALTERs after first DML | Yes |
   | debezium-server-iceberg, `allow-field-addition=false` | Manual `ALTER TABLE ... ADD COLUMN` in Iceberg, then resume | No |
   | Spark Structured Streaming using `writeTo().append()` | Either (a) manual `ALTER TABLE ADD COLUMN` first, or (b) set both `write.spark.accept-any-schema=true` AND `.option("mergeSchema","true")` | Optional |
   | Spark Structured Streaming using `MERGE INTO` (most CDC consumers) | **Manual `ALTER TABLE ADD COLUMN` is MANDATORY** — `mergeSchema` is ignored by `MERGE INTO` ([apache/iceberg#5556](https://github.com/apache/iceberg/issues/5556)) | No |

4. **Backfill recipe** for post-DDL rows already silently truncated:
   - MERGE INTO from Postgres primary, scoped to `created_at >= <DDL_timestamp>`.
   - Explicitly omit `WHEN NOT MATCHED THEN INSERT` to avoid creating duplicates ahead of the streaming pipeline.
   - Call out that the engineer must substitute the actual DDL timestamp.

5. **Explicit "do NOT restart the Debezium connector"** with a one-line explanation: the connector reads from its committed LSN; restart causes re-read from last offset, not a full re-snapshot, and is unnecessary for schema changes.

6. **Pre-release rows are correctly NULL** — historical rows that pre-date the Postgres column should remain NULL; backfilling them with a business-default (e.g., `onboarding_step = 0`) is a business decision, not a data-correctness fix.

### MEDIUM priority

**File**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
**Where**: The existing two-knob callout around line 2698. Add a one-line note at the very top: **"This pattern applies to `writeTo(...).append()` only. If your consumer uses `MERGE INTO` (the recommended shape for CDC), `mergeSchema` is ignored — see [apache/iceberg#5556] — and the only correct fix is `ALTER TABLE ... ADD COLUMN` first."** Resource already says this at line 2753, but it is buried in the middle of a long subsection. Promoting it to the top of the callout reduces the chance an answerer (orchestrator-synthesized or otherwise) prescribes it for the wrong write shape — which is exactly what happened in this answer.

**File**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
**Where**: Near the schema-history-topic mentions in the CDC section. Add a brief callout that for PostgreSQL specifically, there is no schema-history topic — schema is tracked via WAL relation messages, and **a relation message is only emitted after the next DML on the changed table**. This nuance is the most common source of "I added a column and Debezium ignored it" confusion. (Resource currently mentions this in passing at line 1789 in a different context.)

### LOW priority

**File**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
**Where**: The backfill examples throughout. Standardize a comment template like `-- TODO: replace with the actual timestamp of your Postgres DDL (find via psql \d+ or your migration tool's log)` so that orchestrator-synthesized answers carry the prompt forward to the engineer.

---

## Does resource 13 need a dedicated "schema evolution mid-stream" section?

**YES.** The current resource has excellent coverage of schema evolution in the batch / append patterns (sections starting at line 2633) and good coverage of the two-mode CDC distinction (lines 2960-3007), but they are in separate parts of the document, neither is keyed by the symptom "my CDC pipeline silently dropped the new column," and the MERGE-INTO-ignores-mergeSchema caveat is buried where an orchestrator synthesizing an answer is unlikely to pull it forward.

A 200-300 line subsection titled exactly **"My Debezium CDC pipeline silently dropped a new column — diagnosis and fix"**, structured as outlined in HIGH priority above, would prevent the two technical errors this answer made and would more directly serve the SaaS engineer's scenario in the question.

---

## Production-environment fit

The answer respects the production stack: Trino 467 + Iceberg 1.5.2 + Spark + Postgres on-prem + Debezium 2.x. No public-cloud references, no LDAP, no file-based ACL invocations. The `TIMESTAMP(6)` choice is specifically correct for Iceberg-via-Trino on this stack. Good environmental awareness.

---

## Sources verified

- [Apache Iceberg Spark Writes 1.5.0](https://iceberg.apache.org/docs/1.5.0/spark-writes/)
- [Apache Iceberg issue #5556 — mergeSchema not supported in MERGE INTO](https://github.com/apache/iceberg/issues/5556)
- [Apache Iceberg issue #8005 — Document MergeSchema, AcceptAnySchema](https://github.com/apache/iceberg/issues/8005)
- [Debezium PostgreSQL connector stable docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Trino issue #19708 — Iceberg ADD COLUMN timestamp precision](https://github.com/trinodb/trino/issues/19708)
- [Trino ALTER TABLE docs](https://trino.io/docs/current/sql/alter-table.html)
- [Debezium FAQ](https://debezium.io/documentation/faq/)
