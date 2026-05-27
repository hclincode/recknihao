# Score: Iter 335 Q2 — Postgres-to-Iceberg Ingestion Strategy

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Three-pattern taxonomy (Full Refresh / Incremental / CDC) is correct and matches resources/13. `overwritePartitions()` idempotency, `append()` non-idempotency, `updated_at` vs `created_at` choice, the late-arriving rows trap, and the `hot_standby_feedback` on read replicas are all technically accurate per Iceberg docs and Postgres docs. Minor nit: the answer says CDC adds "~3x more infrastructure" — that's a hand-wavy multiplier and not a fact (real-world it's more like new infra entirely: Kafka/Connect/Debezium/streaming consumer/schema registry). Also says use `overwritePartitions()` with "fixed batch window (e.g., yesterday's date)" for the heavy-write tables — this is correct only if the table is partitioned by something compatible with that window, which isn't stated. The MERGE INTO guidance for late-arriving rows in gotcha #2 is solid and correct. |
| Beginner clarity | 4.5 | Three patterns presented clearly with When/Pros/Cons. Concrete examples (the trigger SQL, the index check SQL). Acronyms (CDC, WAL) get short expansions. Good use of "What NOT to do" framing. The "Start here" section at the end gives a clear flowchart. Could note what "watermark" and "Debezium" mean a bit more for a true beginner, but the surrounding context makes it inferable. |
| Practical applicability | 4.5 | Engineer knows exactly what to do: (1) for heavy-write tables → Pattern B with updated_at + overwritePartitions per day, (2) for large slow-change tables → Pattern B or Pattern A with view swap, (3) defer CDC unless sub-minute freshness required. The decision rule (10M-row threshold), the index preflight SQL, the trigger snippet, and the hot_standby_feedback tip are all concrete and immediately actionable. Fits the production stack (Spark + Iceberg + MinIO on-prem) without recommending anything off-stack. |
| Completeness | 4.0 | Covers the three patterns, decision criteria per table type, the watermark column choice, the late-arrivals trap (with MERGE INTO fix), index preflight, and read replica strategy. Missing: (a) explicit mention of hard DELETEs being invisible to incremental loads (soft-delete pattern via `deleted_at`) — this is in resources/13 and relevant to "tables get heavy writes all day"; (b) the lag-buffer recommendation (15-30 min P99 calibration) which is a key resources/13 callout; (c) no mention of compaction / snapshot expiration as a maintenance follow-up; (d) doesn't acknowledge the user's "we can't slow down the live database" concern with concrete throttling guidance (JDBC `fetchsize`, partitioned reads, off-peak scheduling). |
| **Average** | **4.375** | **PASS** |

## What Worked
- Three-pattern taxonomy mapped cleanly to user's two-table scenario at the end ("Start here").
- Pushed back on CDC as the default and gave a concrete bar for when to escalate ("analyst tells you they need analytics fresher than once per hour").
- Late-arriving rows trap with MERGE INTO fix is the single most important gotcha in this domain and was called out by name.
- `hot_standby_feedback = on` mention is a sophisticated and accurate detail for production replica reads.
- updated_at vs created_at trap is exactly the most common new-pipeline failure mode and was correctly described.
- Index preflight SQL is immediately runnable; trigger SQL is correct.
- Fits the on-prem Spark + Iceberg + MinIO production stack — no off-stack tools recommended.

## What Missed
- **Hard DELETEs invisible to incremental loads** — the user said "a few tables get heavy writes all day," which often includes deletes. The soft-delete (`deleted_at` column) pattern from resources/13 should have been mentioned.
- **Lag buffer / replica freshness calibration** — resources/13 has a detailed 15-min default with P99 calibration; the answer omits this.
- **Throttling against the live database** — the user's stated concern was "we can't afford to slow it down." The answer mentions read replicas for bootstrap, but doesn't mention JDBC `fetchsize`, partitioned parallel reads, or scheduling against off-peak windows for ongoing pulls.
- **Maintenance follow-up** — Iceberg compaction and snapshot expiration are necessary after any of these patterns and aren't mentioned.
- **CDC complexity multiplier ("~3x")** — this is imprecise; CDC adds Kafka, Connect, Debezium, a streaming consumer, schema registry, plus replication slot management. The honest framing is "an entirely new infrastructure footprint," not a multiplier.

## Technical Accuracy Verification

| Claim | Verified? | Source |
|---|---|---|
| `append()` is non-idempotent; restart causes duplicates | Correct | Iceberg Spark docs and resources/13 confirm; restart re-inserts the watermark window |
| `overwritePartitions()` is atomic and idempotent for partition-scoped writes | Correct | Iceberg Spark writes documentation confirms snapshot-isolated overwrite semantics |
| MERGE INTO preferred over INSERT OVERWRITE for evolving schemas / safety | Correct | Iceberg docs + Expedia Group blog explicitly recommend MERGE INTO over INSERT OVERWRITE |
| `updated_at` watermark + `overwritePartitions()` on a different partition column causes silent data loss for late-arriving rows | Correct | Documented in resources/13 with concrete timeline; matches Iceberg overwrite semantics |
| Fix: use MERGE INTO when late-arrivals are possible | Correct | Standard data-engineering pattern; matches resources/13 |
| `hot_standby_feedback = on` on read replicas prevents "canceling statement due to conflict with recovery" during long reads | Correct | PostgreSQL docs (postgresql.org/docs/current/hot-standby.html) and AWS re:Post confirm. Trade-off (replica feedback can cause primary-side bloat from delayed vacuum) was NOT mentioned in the answer — a minor completeness gap |
| `created_at` on tables with UPDATEs causes silent drift | Correct | Standard data-engineering knowledge; matches resources/13 |
| Index `updated_at` to avoid full-table scans on incremental runs | Correct | Postgres query planner will use the index for the range filter; without it, sequential scan |
| Trigger snippet (`touch_updated_at`) is correct Postgres syntax | Correct | Standard PL/pgSQL pattern |
| CDC threshold: sub-minute freshness or hard-DELETE capture | Correct | Industry standard guidance; matches resources/13 and Estuary/RisingWave write-ups |
| 10M-row Pattern A→B threshold | Reasonable rule of thumb | Matches resources/13; in practice the actual threshold depends on JDBC throughput and Postgres I/O headroom, but 10M is a defensible default |
| Staging table + view swap pattern eliminates rebuild-window downtime | Correct | Matches resources/13; standard pattern for atomic full-refresh swaps |

Sources consulted:
- [Apache Iceberg Spark Writes documentation](https://iceberg.apache.org/docs/latest/spark-writes/)
- [Why You Should Prefer MERGE INTO Over INSERT OVERWRITE in Apache Iceberg (Expedia)](https://medium.com/expedia-group-tech/why-you-should-prefer-merge-into-over-insert-overwrite-in-apache-iceberg-b6b130cc27d2)
- [PostgreSQL Hot Standby documentation](https://www.postgresql.org/docs/current/hot-standby.html)
- [Debezium Pain Points (Estuary)](https://estuary.dev/blog/debezium-cdc-pain-points/)
- [Debezium Alternatives 2026 (RisingWave)](https://risingwave.com/blog/debezium-alternatives-2026-cdc-tools/)
- [hot_standby_feedback Bloat Trap (Michal Drozd blog)](https://www.michal-drozd.com/en/blog/postgresql-hot-standby-feedback-bloat/)
