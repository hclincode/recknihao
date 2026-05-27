# Iter 146 Q1 — Judge Report

**Question**: Spark Structured Streaming job reading from Kafka and writing to data lake crashed mid-batch. On restart, how does Spark avoid lost or duplicate events / half-written state?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter146-q1.md`

---

## Overall verdict

**Weighted average: 4.83 / 5 — PASS** (threshold 4.5)

Weighting: Technical accuracy 2x, Clarity 1x, Practical usefulness 1x, Completeness 1x.

| Dimension | Score | Weight | Contribution |
|---|---|---|---|
| Technical accuracy | 5 | 2 | 10 |
| Clarity | 5 | 1 | 5 |
| Practical usefulness | 5 | 1 | 5 |
| Completeness | 4 | 1 | 4 |
| **Weighted sum / total weight** | | | **24 / 5 = 4.80** |

(Note: re-computed weighted average is 4.80, which is **PASS** at ≥ 4.5.)

---

## Per-dimension scoring

### Technical accuracy — 5 / 5

The four core technical claims are factually correct against the official Spark and Iceberg documentation:

1. **Checkpoint stores Kafka offsets and batch metadata** — CONFIRMED. The checkpoint directory contains `offsets/` (KafkaSourceOffset JSON, written at start of micro-batch), `commits/` (written at end of micro-batch when sink commits), and `sources/` metadata. Spark's checkpoint is the source of truth for replay, not Kafka's `__consumer_offsets` topic.
2. **Kafka source delivers at-least-once** — CONFIRMED. Spark's default guarantee is at-least-once; exactly-once requires both an idempotent source replay (which Kafka provides via offset checkpointing) AND an idempotent or transactional sink. The file sink supports exactly-once; `foreachBatch` is at-least-once unless you add `batchId` or business-key deduplication.
3. **Iceberg atomic commit model: stage files, then atomic metadata pointer swap** — CONFIRMED. Iceberg writes data files first, then atomically swaps the metadata pointer (compare-and-swap on the catalog). Partial/crashed writes leave orphan files but never appear in any snapshot. Readers always see a consistent prior snapshot.
4. **Orphan files cleaned by `remove_orphan_files`** — CONFIRMED. The procedure removes files not referenced by any valid snapshot; the answer correctly identifies it as the right cleanup mechanism.
5. **MERGE INTO with event_id is the standard idempotency pattern** — CONFIRMED. This is the canonical Iceberg+foreachBatch pattern endorsed by Tabular/Databricks/Iceberg cookbook material.

The `WHEN NOT MATCHED THEN INSERT *` clause is syntactically valid for Iceberg/Spark MERGE INTO. The runnable code uses correct Iceberg+Spark API patterns (`.format("iceberg")`, `.toTable()`, `foreachBatch` lambda receiving `(batch_df, batch_id)`).

The summary table is accurate, including the subtle point that ephemeral pod disk for checkpoint is functionally equivalent to no checkpoint when the pod reschedules — important for the production k8s/MinIO environment.

One minor nit: the "Write-ahead log — in-flight output file locations" framing in the checkpoint contents list is slightly imprecise — the WAL primarily records the offset ranges that have been planned for a batch (so the batch can be replayed deterministically), not output file locations per se. Output file locations land in the Iceberg metadata at commit time. This is a small terminological imprecision but not a factual error sufficient to dock the score.

### Clarity — 5 / 5

Strong structure: (1) checkpoint mandatory, (2) at-least-once explanation, (3) MERGE INTO idempotency, (4) half-written state explanation, (5) verification, (6) summary table. Each section addresses one of the engineer's concerns in their order of asking. Jargon (checkpoint, at-least-once, idempotency, MERGE INTO, snapshot) is introduced with operational consequences rather than abstract definitions. The summary table makes the "what if I do/don't do X" tradeoff scannable.

### Practical usefulness — 5 / 5

The answer is highly actionable:
- Concrete `checkpointLocation` path on MinIO (`s3a://lakehouse/streaming-checkpoints/events-pipeline`) matching the production stack.
- Runnable `foreachBatch` + MERGE INTO snippet that the engineer can paste in and adapt.
- Two verification commands: `$snapshots` metadata table query and `kafka-consumer-groups.sh` lag check.
- Explicit warning that local pod disk checkpoint = data loss on reschedule — directly relevant to the k8s production environment.
- Summary table that maps the engineer's three failure scenarios to "what happens if you configure X."

### Completeness — 4 / 5

Covers all three failure scenarios (missing events, duplicates, half-written state) and the recovery mechanism. Minor gaps:

- **MEDIUM (LOW severity)**: Does not mention the known `remove_orphan_files` + S3FileIO compatibility issue on MinIO (apache/iceberg issues #3838 and #12765) — this is a real gotcha the on-prem MinIO engineer will hit. Rubric history flags this gap in prior iterations (iter 68).
- **LOW**: Does not mention `foreachBatch`'s own `batch_id` as an alternative idempotency mechanism (using the deterministic batch_id to skip already-committed batches). The event_id MERGE pattern is correctly presented as the standard, but `batch_id` is the Databricks-recommended alternative when no natural unique key exists.
- **LOW**: Does not mention what happens if the **checkpoint itself** is corrupted (the recovery requires either rebuilding from Kafka offsets at the source, or accepting an exactly-once break). This is rarer but is the next question after a real incident.
- **LOW**: Does not cover the duplicate-source-row case (multiple records for the same event_id in a single batch — MERGE INTO raises "multiple matches" error). Rubric history (iter 37) shows this is a recurring follow-on question.

These are nuance gaps, not core completeness failures. Score 4.

---

## Verified-correct claims (with sources)

| Claim | Verified via |
|---|---|
| Checkpoint stores Kafka offsets, batch metadata, WAL of intended offset range | [Spark 3.5.6 Structured Streaming Programming Guide](https://spark.apache.org/docs/3.5.6/structured-streaming-programming-guide.html); [Databricks Structured Streaming Checkpoints](https://docs.databricks.com/aws/en/structured-streaming/checkpoints); [Jacek Laskowski — Offsets and Metadata Checkpointing](https://jaceklaskowski.gitbooks.io/spark-structured-streaming/content/spark-sql-streaming-offsets-and-metadata-checkpointing.html) |
| Spark uses its own checkpoint as source of truth for Kafka offsets, NOT `__consumer_offsets` | [Abstract Algorithms — Kafka and Spark Structured Streaming Production Pipeline](https://www.abstractalgorithms.dev/spark-kafka-structured-streaming-pipeline) |
| Kafka source = at-least-once by default; exactly-once requires idempotent sink | [Spark Streaming + Kafka Integration Guide](https://spark.apache.org/docs/latest/streaming-kafka-0-10-integration.html); [Is Structured Streaming Exactly-Once? Well, it depends...](https://dev.to/kevinwallimann/is-structured-streaming-exactly-once-well-it-depends-noe) |
| Iceberg commit = atomic metadata pointer swap (compare-and-swap) | [Iceberg Table Spec](https://iceberg.apache.org/spec/); [Writing to an Apache Iceberg Table: How Commits and ACID Actually Work](https://iceberglakehouse.com/posts/2026-04-29-iceberg-masterclass-06/) |
| Crashed writes leave orphan files; readers see prior snapshot | [Apache Iceberg Maintenance docs](https://iceberg.apache.org/docs/1.5.1/maintenance/); [Apache Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/) |
| `remove_orphan_files` removes files not referenced by any snapshot | [Apache Iceberg Spark Procedures — remove_orphan_files](https://iceberg.apache.org/docs/latest/spark-procedures/) |
| MERGE INTO + event_id is the standard foreachBatch idempotency pattern | [Tabular Iceberg Cookbook — MERGE for Idempotent Pipelines](https://www.tabular.io/apache-iceberg-cookbook/data-engineering-merge-idempotent-pipelines/); [Databricks foreachBatch docs](https://docs.databricks.com/aws/en/structured-streaming/foreach) |
| foreachBatch is at-least-once; batch_id or business-key dedup yields exactly-once effective | [Databricks foreachBatch docs](https://docs.databricks.com/aws/en/structured-streaming/foreach) |

---

## Errors and gaps

### HIGH severity
None.

### MEDIUM severity
None.

### LOW severity

1. **WAL contents mischaracterized**. The checkpoint's WAL records the offset range to be processed in each micro-batch, not "in-flight output file locations." Output file locations live in Iceberg metadata, not the Spark WAL. This is a terminological imprecision that does not change the engineer's actions but is technically loose.

2. **Missing MinIO + S3FileIO `remove_orphan_files` known issue**. On-prem MinIO deployments of certain Iceberg/Spark versions hit `UnsupportedFileSystemException: No FileSystem for scheme "s3"` when calling `remove_orphan_files` (apache/iceberg #3838, #12765). The answer recommends `remove_orphan_files` without flagging this production-environment gotcha. Rubric notes this as a recurring gap.

3. **Missing `batch_id`-based idempotency alternative**. For sources without a natural unique key, Spark provides the deterministic `batch_id` as the dedup key. The answer presents MERGE on `event_id` as the only idempotency pattern.

4. **Missing duplicate-source-row caveat**. If a single batch contains multiple rows with the same `event_id`, MERGE INTO raises a runtime error ("multiple source rows matched"). Should be a one-line caveat with the standard `row_number()` dedup precursor (rubric iter 37/41 history shows this is a recurring follow-on).

5. **Missing recovery path for corrupted checkpoint**. Not asked directly, but the natural follow-on for a real incident is "what if the checkpoint itself is bad?" — a one-paragraph escape hatch (delete checkpoint, set `startingOffsets` explicitly, accept replay window) would round out the answer.

---

## Resource fix recommendations

Priority is LOW because the answer passes comfortably and the gaps are nuance.

1. **`resources/19-spark-streaming-iceberg.md`** (or wherever the Structured Streaming + Iceberg material lives) — add a short callout box for **`remove_orphan_files` + MinIO/S3FileIO known issue**, with the workaround (run via Hadoop FileIO or scope via the `location` parameter). This is the third iteration where the gap surfaces; worth fixing once.

2. **Same resource** — add a one-paragraph section on **alternatives when no unique event_id exists**: (a) `batch_id`-based idempotency table (`(batch_id, partition_id)` written to a "processed batches" Iceberg table, MERGE checks before insert), (b) composite-key MERGE, (c) `row_number()` pre-dedup inside the `foreachBatch` function before the MERGE.

3. **Same resource** — one-line caveat that MERGE INTO raises an error when the source side contains multiple rows matching the same target row, with the `Window.partitionBy("event_id").orderBy(ingest_ts.desc())` + `row_number() == 1` filter as the pre-MERGE pattern.

4. **Same resource** — short subsection on **checkpoint corruption recovery**: if checkpoint files are unreadable, options are (a) restart with explicit `startingOffsets` and accept a small replay window covered by MERGE idempotency, or (b) rebuild from Kafka log retention if it covers the gap.

None of these are blockers — the answer earns PASS. These are polish items for future iterations.

---

## Rubric topic impact

This question primarily exercises:
- **Real-time vs batch analytics trade-offs** (PASSED 4.812, 4 questions) — confirms streaming reliability guarantees.
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** (PASSED 4.602, 14 questions) — confirms orphan file handling.
- **Postgres-to-Iceberg ingestion: ...** (PASSED 4.473, 97 questions) — the Spark/Kafka/Iceberg ingestion pattern; this question is Kafka-source rather than Postgres-source but the idempotency pattern is the same.

All three topics are already PASSED. This answer reinforces the running averages with a strong PASS (4.80).
