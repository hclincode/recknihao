# Iter92 Q2 — Judge Score

## Score: 4.56 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.5 |
| Completeness | 4.25 |

## Points covered
- Late events land in the CORRECT historical partition (partitioned by occurred_at, not ingestion time) — covered (explicit and clearly explained)
- What users see during catch-up (incomplete numbers that grow, snapshot isolation means each query is internally consistent) — covered (excellent treatment of snapshot isolation with the phrase "no torn reads")
- Dashboard communication strategy — covered (3 options: proactive comms, schedule off-hours, pause auto-refresh)
- Verify the watermark column is the original event timestamp (not ingestion time) — covered (called out as "Critical assumption" with a runnable verification query)
- (Bonus) Compaction may be needed after catch-up due to many small files — NOT covered

## Technical accuracy gaps
- The answer's claim that "Iceberg partitions by the event's `occurred_at` timestamp, not the ingestion time" is presented as a property of Iceberg, when it is actually a property of the **table's partition spec** (i.e., whichever column the table is partitioned on). The answer does later soften this by labeling it an "assumption" to verify, but the opening framing could mislead a beginner into thinking Iceberg has some built-in awareness of event time. A more precise statement would be: "Iceberg routes each row to a partition based on the value of the partition column for that row — if the table is partitioned by `occurred_at` (event time), late events land in their correct historical partition; if the table is partitioned by ingestion time, they would land in today's." The follow-up section partly recovers this but should be in the opening framing.
- The 30–60 minute catch-up ETA for 6 hours of backlog is a plausible-sounding rule of thumb but not anchored to any production data; it depends on throughput, partition count, write batch size, and number of writer tasks. Minor — phrasing it as an order-of-magnitude estimate would be safer.
- Snapshot isolation guarantee is described correctly per the Iceberg spec (each query reads one atomic snapshot, no torn reads). Verified against iceberg.apache.org/spec/.
- Debezium ts_ms / source.ts_ms field is not explicitly named, but the conceptual explanation of "the time the event happened in your application" is correct (Debezium does record `source.ts_ms` from the WAL commit time, plus `ts_ms` at the connector). Not wrong, just less specific than ideal.

## Completeness gaps
- **Small-files / compaction**: The rapid catch-up will generate many small Iceberg data files (and likely many delete files in MoR CDC tables). The answer should mention running `CALL system.rewrite_data_files()` (Spark) after catch-up completes to consolidate them, otherwise query performance on the historical partitions will be degraded going forward. This is the explicit bonus point in the rubric and was missed.
- No mention of the **on-prem stack specifics** from prod_info.md: the catch-up writes go through Spark Structured Streaming → Iceberg on MinIO/Hive Metastore; the compaction guidance should reference Spark `CALL system.rewrite_data_files` (not Trino, which cannot run it). Mild miss.
- No mention of how Trino dashboards will pick up snapshot updates: Trino's Iceberg connector refreshes per query by default, so each dashboard query will see the latest committed snapshot. Implicit in the snapshot-isolation explanation but a beginner would benefit from being told this explicitly.
- The verification query is good but could go further: comparing `MAX(occurred_at)` per partition to confirm post-catch-up that the May 22 partition really contains the recovered rows, e.g., `SELECT date_trunc('hour', occurred_at), COUNT(*) FROM ... WHERE occurred_at BETWEEN ... GROUP BY 1 ORDER BY 1`.
- No mention of MoR (Merge-on-Read) vs CoW implications — CDC pipelines typically use MoR, and replay creates equality/position delete files that may need an extra compaction pass.

## Verified (WebSearch)
- iceberg.apache.org/spec/ and Conduktor's Iceberg architecture overview confirm snapshot isolation guarantees: each query reads one immutable snapshot, no torn reads, ACID via atomic catalog updates. Answer's snapshot-isolation framing is accurate.
- debezium.io/documentation/reference/stable/connectors/postgresql.html confirms Debezium records WAL position per event and replays from last LSN on restart, with original `source.ts_ms` preserved per event — matches the answer's claim that replayed events carry their original timestamp.
- Iceberg partitioning: confirmed via OLake/Dremio docs that partition routing is based on the partition column value for each row; partition spec is per-table configuration, not implicit on Iceberg's part. Answer's framing is partly imprecise but corrected later.
- CDC small-files problem: confirmed via Dremio, AWS, and Ryft blogs that CDC into Iceberg creates many small files and delete files; compaction every 1–4 hours recommended for streaming, MoR CDC tables should compact at least daily. Answer omits this entirely — confirmed gap.

## Notes for teacher
- Strong answer overall; the framing fix (move "depends on partition spec" up front) and adding a compaction-after-catch-up paragraph would push this to 4.85+.
- Consider explicitly naming `source.ts_ms` from Debezium in `resources/13-postgres-to-iceberg-ingestion.md` to give the responder a precise hook when discussing CDC event time.
