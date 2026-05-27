# Judge Score — Iter 121 Q2

**Question (topic)**: Late-arriving events (2-5 days late) landing in the wrong Iceberg partition because the table is partitioned by ingestion date rather than event date — causing artificially low historical analytics counts.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter121-q2.md`
**Production stack referenced**: On-prem Trino 467 + Iceberg 1.5.2 + Spark + MinIO + Hive Metastore.

---

## Scores

| Dimension | Score | Reasoning |
|---|---:|---|
| Technical accuracy | 4 | Core architecture (two-timestamp schema; partition by `ingested_at`; query by `occurred_at`; buffer window on `ingested_at`) is correct and industry-attested. Spark `writeTo(...).partitionedBy(...)` API and Trino SQL syntax (`TIMESTAMP '...'`, `INTERVAL '2' HOUR`, `current_timestamp`) are valid for Iceberg 1.5.2 / Trino 467. One material inaccuracy: the answer **understates a real trade-off** — when you partition by `ingested_at` but filter by `occurred_at`, Iceberg's hidden partitioning **cannot prune by `occurred_at`**, so a Tuesday query must scan all ingestion-day partitions containing Tuesday events (or be augmented with an `ingested_at` predicate). The answer says "Iceberg handles this automatically," which is true in correctness but misleading in performance — pruning effectively goes away unless the user adds a defensive `ingested_at BETWEEN occurred_at AND occurred_at + 7 days` predicate. Also, the "partition evolution is metadata-only" line in the repartitioning section glosses over that old data physically stays in its old layout and only new writes use the new spec. |
| Beginner clarity | 5 | Names the problem ("late-arriving events problem"), defines `occurred_at` vs `ingested_at` in plain language with parenthetical glosses ("user device time, business-meaningful" / "server time, monotonic and predictable"), and gives correct/wrong SQL side-by-side. No unexplained jargon. The "what to do right now" checklist at the end is exactly the format a SaaS engineer with no OLAP background can act on. |
| Practical applicability | 5 | End-to-end implementable: full CREATE TABLE DDL, runnable PySpark ingestion snippet capturing both timestamps, before/after analytics SQL, a buffer-window query the engineer can paste into a dashboard, and a monitoring SQL for the on-time percentage. The "do you need to repartition?" section gives a clear no with two options ranked by effort. Maps cleanly onto the production stack (Spark writes, Trino reads, Iceberg 1.5.2 syntax). Could add a one-line note that the bounded backfill window (e.g., "events arrive within 5 days") lets you safely add `ingested_at BETWEEN x AND x + INTERVAL '7' DAY` to recover pruning, but the omission is minor. |
| Completeness | 4 | Covers all six required sub-topics: two-timestamp architecture, partition-by-`ingested_at` recommendation, query-by-`occurred_at`, buffer window for dashboards, monitoring late arrivals, and the explicit repartitioning answer ("no"). What's missing: (1) the partition-pruning trade-off discussed above — the answer should warn that an `occurred_at`-only filter scans all ingestion partitions, and offer the bounded-window defensive predicate; (2) the alternative industry view that partitioning by `event_time` (with buffer-window queries on the *write* side via MERGE/upsert) is also legitimate, especially when read patterns dominate writes; (3) no mention of MERGE INTO or upserts for the case where late events update prior aggregates downstream; (4) no mention of how compaction interacts with late-arriving files written into "today's" ingestion partition but containing 5-day-old `occurred_at` values (small-files risk). |
| **Average** | **4.50** | Above pass threshold (3.5). |

---

## Web verification summary

- **Two-timestamp pattern is standard industry practice.** Confirmed by Databricks Cybersecurity Lakehouse Best Practices (uses `_event_time` + `_ingest_time` at bronze layer for exactly this monitoring + correctness purpose), Confluent's event-time-processing pattern, and dbt's late-arriving-facts guidance.
- **Partition by ingestion, query by event** is one of two accepted patterns. StartDataEngineering explicitly endorses "use the event store time as the date to partition by for the raw data store... define a tolerance range for late arriving events at query time" — exactly the answer's recommendation. The competing view (Starburst, Iceberg masterclass content) prefers partition-by-event-time so hidden partitioning auto-prunes; the answer does not acknowledge this alternative.
- **Iceberg cross-partition scans are automatic but not free.** Iceberg correctly returns all matching rows regardless of which partition they live in (Layer-1/2/3 pruning per the engine), but when the partition column (`ingested_at`) is not in the WHERE clause, **partition pruning is bypassed** and the engine falls back to file-level min/max stats on `occurred_at`. The answer's "Iceberg handles this automatically" is technically correct on correctness but elides the performance cost.
- **Partition evolution is metadata-only for the spec change itself**, but old data files retain their original layout — a nuance the answer mentions only briefly.

Sources consulted:
- StartDataEngineering — 3 Key Points to Help You Partition Late Arriving Events
- Databricks — Cybersecurity Lakehouse Best Practices Part 1 (event timestamp extraction) and Part 2 (handling ingestion delays)
- Starburst — 3 Iceberg partitioning best practices
- Apache Iceberg — Partitioning docs (hidden partitioning)
- e6data / Tinybird / Upsolver / RisingWave — ingestion + partitioning blogs

---

## Topic updates to `rubric.md`

Topics touched:
- **Iceberg partition design for SaaS** — already PASSED at 4.554 over 13 questions; this answer's 4.50 keeps it comfortably above threshold (new running avg ≈ 4.55 over 14).
- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** — already PASSED at 4.55 over 5 questions; time-series query pattern (buffer-window predicate) is exercised here. Updated avg ≈ 4.54 over 6.

Both topics retain PASSED status. No new required topic introduced.

---

## Recommendation to teacher (extended-phase note, no urgency)

If `resources/10-lakehouse-partitioning.md` or a late-arriving-events resource is touched in a future iteration, add:
1. The pruning trade-off explicitly: "partition by `ingested_at` + filter by `occurred_at` alone = no partition pruning; add a defensive `ingested_at BETWEEN x AND x + N days` predicate to recover it, where N is your max late-arrival window."
2. The alternative pattern (partition by `day(occurred_at)` with MERGE INTO for upsert-style ingestion) as a one-paragraph compare/contrast so the engineer knows both options exist.
3. A line on how late-arriving files interact with compaction in the ingestion-time-partitioned layout (mostly fine, but worth a sentence).
