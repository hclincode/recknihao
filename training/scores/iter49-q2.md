# Iteration 49, Q2 — Score

**Question**: Watermark ingestion misses hard deletes (GDPR) and produces duplicates on Spark retry. How does Debezium CDC differ from the watermark approach? Would it fix both problems?

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Technical verification (via WebSearch against debezium.io and iceberg.apache.org)

1. **Does Debezium capture DELETE operations from the Postgres WAL?**
   YES — Debezium uses Postgres logical decoding via a replication slot to read the WAL, and emits change events for every INSERT/UPDATE/DELETE operation captured by the slot.

2. **Is the DELETE event format `op: "d"` with `before` populated and `after` null, plus a tombstone?**
   PARTIALLY VERIFIED — confirmed by Debezium docs: "A database DELETE operation causes Debezium to generate two Kafka records: A record that contains `op: 'd'`, the before row data... A tombstone record that has the same key as the deleted row and a value of null." The responder's framing "DELETE → `{op: 'd', before: {id: 88, ...}, after: null}` (tombstone event)" conflates the change-event-with-op:'d' with the separate tombstone record — they are TWO records, not one. Practically this is a minor pedagogical simplification (the engineer only needs to consume the op='d' event to learn about the delete), but the precise statement is: the DELETE produces an op='d' event AND a separate tombstone (null-value) record for Kafka log compaction.

3. **Does Postgres require `wal_level = logical` for Debezium CDC?**
   YES — confirmed by Debezium docs: "To configure a replication slot, you need to specify `wal_level=logical` in the postgresql.conf file." The responder's claim is correct.

4. **Is MERGE INTO with primary key the correct pattern for idempotent CDC writes to Iceberg?**
   YES — confirmed by Iceberg docs: "Iceberg supports UPSERT based on the primary key when writing data into v2 table format." MERGE INTO with WHEN MATCHED / WHEN NOT MATCHED clauses on the PK is the canonical idempotent CDC sink pattern. The responder's snippet (`MERGE INTO ... USING ... ON t.id = s.id WHEN MATCHED THEN DELETE`) is correct shape.

5. **Production stack fit**: Responder correctly identifies the prod stack constraint (Spark + Iceberg 1.5.2 on MinIO via Hive Metastore, k8s, on-prem) and gives an "alternative without CDC" path using soft-deletes + `overwritePartitions()` that is directly compatible with the existing stack. This is the right defensive framing for an on-prem team being pitched a Kafka adoption — they should know they have a non-CDC path. Also correctly names MinIO, Trino, and Iceberg in concrete remediation steps.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every load-bearing claim is verified: WAL-based CDC, op codes for c/u/d, tombstone-event nature of DELETEs, `wal_level=logical` requirement, MERGE INTO as the idempotent sink, LSN-based ordering, exactly-once semantics requirement on the streaming job side, append-vs-MERGE distinction for retry safety. The only nit is the "DELETE → {op:'d', before:..., after:null} (tombstone event)" line, which compresses two distinct Kafka records (the op='d' change event AND the separate null-value tombstone) into a single JSON sketch. Not wrong enough to mislead — the engineer's actual consumer code reads the op='d' event and gets the right PK — but a precise version would say "Debezium produces a DELETE change event with op='d' and before populated; it also emits a separate tombstone (null-value) record on the same key for Kafka log compaction." Minor refinement, not a correction. |
| **Beginner clarity** | 4 | Strong framing — leads with "your watermark approach asks X, CDC asks Y" which is the right mental-model reset. The c/u/d JSON sketch is the right teaching device. The "Yes, completely" / "Mostly yes, but..." section headers give a beginner a clean answer-shape before any technicals. Clarity gaps: WAL (defined once inline, good), but LSN, replication slot, Spark Structured Streaming, Kafka offsets, schema registry, exactly-once semantics, micro-batch all appear without inline plain-English glosses. A beginner SaaS engineer reading the "operational cost" bullet list would not learn what most of those terms mean from this answer. The before/after stack-specific remediations are clear and runnable. Inline gloss for `overwritePartitions` vs `append` is present in spirit but not in words. |
| **Practical applicability** | 5 | Engineer leaves with: (a) yes/no answers to both sub-questions, (b) a runnable MERGE INTO snippet for the CDC consumer, (c) two concrete fixes deployable TODAY without adopting Debezium (soft-delete + view filter; `overwritePartitions()` with deterministic batch window), (d) a clear three-bullet decision rule for when CDC is worth the operational cost, (e) explicit named operational burdens (wal_level config, replication slot, Kafka, streaming job, exactly-once config, schema evolution under CDC). The "what to do right now" section is exactly the answer a busy engineer needs — it lets them stop the bleeding without a quarter-long Debezium project. The soft-delete pattern is correctly paired with the Iceberg physical-purge sequence (DELETE → rewrite_data_files → expire_snapshots) which is consistent with the GDPR resource fixes. |
| **Completeness** | 5 | Covers all three sub-questions the user asked: (1) how does CDC differ from watermark? — explicit WAL-vs-poll contrast with op codes. (2) Does CDC fix Problem 1 (hard deletes)? — yes, with mechanism and runnable SQL. (3) Does CDC fix Problem 2 (duplicates)? — mostly, with the exactly-once caveat that distinguishes "Kafka holds the change history" from "the sink writes are actually idempotent." Goes beyond the expected outline by surfacing the non-CDC alternative path (soft-delete + view; `overwritePartitions()`) AND the "when to actually adopt CDC" decision rule. The operational-cost section enumerates the real burdens (wal_level, replication slot, Kafka ops, streaming job, exactly-once, schema evolution) rather than the typical hand-wave. The only nuance not surfaced: replication slot disk-bloat risk if the consumer falls behind (a real on-prem operational gotcha — Postgres WAL grows unbounded until the slot is consumed), but this is a level-2 concern, not a missing core point. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
- Prior: avg 4.257 across 50 questions (end of iter 48)
- New running avg: (4.257 × 50 + 4.75) / 51 = **4.267** across 51 questions
- Status: **PASSED** (avg 4.267 >= 3.5 threshold, deep coverage)

---

## Notes for teacher

No critical resource gaps identified. The answer is among the strongest in the topic's history and demonstrates that `resources/13-postgres-to-iceberg-ingestion.md` now contains good CDC coverage (correct WAL mechanism, correct op codes, correct MERGE INTO idempotency framing, correct exactly-once caveat, correct soft-delete fallback path).

Minor refinement opportunities (none blocking):

1. **DELETE event precision** — if the resource file currently sketches a DELETE event as a single JSON record, add one sentence clarifying that Debezium actually emits TWO records for a DELETE: (a) the change event with `op: "d"` and `before` populated, and (b) a separate tombstone record with null value on the same key for Kafka log compaction. The responder's consolidated sketch is pedagogically reasonable but the distinction matters when the engineer writes a Kafka consumer that needs to filter out the null-value record.

2. **Replication slot disk-bloat gotcha** — add to the "operational cost of CDC" subsection: "If your Spark Structured Streaming consumer falls behind or stops, Postgres retains all WAL the replication slot needs, which can fill the Postgres disk. Monitor `pg_replication_slots.wal_status` and `restart_lsn` lag." This is one of the most common on-prem CDC outages and the answer touches Postgres health only implicitly.

3. **Beginner clarity** — inline glosses for LSN (Log Sequence Number — Postgres's monotonically increasing byte position in the WAL, used as a deterministic event ordering key), exactly-once semantics (the streaming job tracks Kafka offsets in a way that guarantees each event is reflected in the sink exactly once even across crashes), and replication slot (a Postgres mechanism that pins WAL retention for a specific consumer so the consumer can resume from a known position after downtime) — all recurring clarity gaps for this topic.

The "when to adopt CDC" decision rule at the bottom of the answer is exactly the framing on-prem teams need to push back on Debezium-as-default proposals. Keep that pattern in the resource.
