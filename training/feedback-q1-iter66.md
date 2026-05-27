# Feedback — Iter 66 Q1

**Topic**: Postgres-to-Iceberg ingestion (CDC DELETE handling: Debezium tombstone → Iceberg)
**Question**: How to apply Debezium delete events into Iceberg so deleted rows actually disappear from the lakehouse.

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Completeness | 4.5 | Covers 4.5 of 5 expected points; missing explicit CoW alternative and position/equality delete distinction |
| Accuracy | 5 | All technical claims verified against Debezium and Iceberg docs |
| Clarity | 5 | Clear two-path framing, comparison tables, plain-language explanations |
| No hallucination | 5 | Faithful to resource and to upstream docs; no invented properties |
| **Average** | **4.875** | PASSED |

## What the answer did well

1. **Debezium event structure correctly explained**: All four op values (c/u/d/r) listed; `before` field contains pre-delete row data; `after` is null; tombstone is a separate follow-up message with null value used by Kafka log compaction. This matches the official Debezium PostgreSQL connector documentation precisely.

2. **Two clear paths offered**: Path A (Structured Streaming with foreachBatch DELETE) for real-time, Path B (soft-delete + nightly batch) for simpler/relaxed-latency use cases. The decision table at the end (delete lag, complexity, GDPR fit, best-for) gives the engineer a real decision-making tool.

3. **Iceberg MoR delete-file behavior explained at the right level**: "Iceberg does not erase the row from the Parquet files. Instead, it creates a small delete file that records 'skip row 123 from this file.'" — this is exactly the mental model a Postgres-trained engineer needs.

4. **Complete compaction sequence with correct CALL signatures**: rewrite_data_files (with strategy => 'binpack'), expire_snapshots (older_than, retain_last), remove_orphan_files (older_than). The "critical ordering" callout that storage temporarily *increases* after step 1 and only drops after step 2 is a great practical detail.

5. **Production-fit guidance**: Correctly uses spark-submit for compaction (NOT Trino), respects on-prem MinIO via S3 protocol, names the concurrent-ingestion conflict risk and recommends off-peak scheduling.

6. **GDPR framing**: Calls out that DELETE FROM alone is insufficient for GDPR — the expire_snapshots step is what physically removes bytes from MinIO. Aligns with iter65 Q2 (the multi-tenant GDPR purge answer).

## What was missing / could be stronger

1. **No explicit CoW vs MoR contrast** (the one real coverage gap). The answer describes MoR behavior accurately but doesn't mention that Iceberg supports a table-level `write.delete.mode` property that can be set to `copy-on-write` (rewrite the whole data file immediately, slower writes, no delete-file accumulation, faster reads) as an alternative for low-volume delete workloads. A SaaS engineer choosing a table mode for a small reference table might pick CoW; one with a high-mutation `messages` table should stay on MoR. The expected coverage point explicitly called for this contrast.

2. **No mention of position-delete vs equality-delete file types**. MoR has two flavors and the choice has real performance implications. Position deletes are efficient to read but require knowing which file/row a delete targets (so they're written at compact-time or for known-position deletes); equality deletes are written by streaming jobs that don't know the position, so they're fast to write but force predicate evaluation against every base file at read time. A Debezium-driven streaming DELETE typically produces equality deletes — worth mentioning because it amplifies the need for compaction.

3. **Spark code pattern uses `.collect()` + per-row SQL**, which works but is inefficient at scale. For a batch of N deletes you'll issue N separate DELETE statements (each one a separate Iceberg commit, so N snapshots). A `MERGE INTO ... WHEN MATCHED THEN DELETE` joining the delete batch against the target table would be one commit per micro-batch and far cheaper. This is not technically wrong but a senior reviewer would flag it. Consider adding a note like "for high delete volume, switch to MERGE INTO ... WHEN MATCHED THEN DELETE to coalesce into one commit per micro-batch."

4. **Tombstone handling guidance is light**: The answer says "your Spark job must handle both" the op=d and the tombstone, but doesn't tell the engineer what to actually do with the tombstone (typically: filter it out — `filter(value IS NOT NULL)` on the parsed stream — because the op=d message already carries the delete intent; the tombstone only matters for Kafka topic compaction). A one-line "just drop null-value records" would close this loop.

## Suggested resource enhancement

Add a "CDC DELETE handling" subsection to `resources/13-postgres-to-iceberg-ingestion.md` under Pattern C that covers:
- Debezium DELETE envelope vs tombstone (distinct, both arrive on the topic)
- A `MERGE INTO ... WHEN MATCHED THEN DELETE` pattern (one commit per micro-batch) as the preferred Spark code shape
- The CoW vs MoR table-level `write.delete.mode` knob and when to choose each
- Position-delete vs equality-delete file types and which one streaming DELETEs produce
- "Filter out tombstones early" guidance (`.filter(F.col("value").isNotNull())`)

This would close the only real coverage gap in this answer and give the next question on the topic a stronger resource to ground on.

## Verdict

PASS. 4.875 average, well above the 3.5 threshold. The answer is technically correct, production-fit for the on-prem MinIO + Spark + Iceberg + Trino stack, and gives an engineer enough to ship the change. The CoW omission is the only meaningful gap.
