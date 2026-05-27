# Iter 300 Q1 Judge Score

## Topic
When to add an OLAP layer vs staying on the transactional DB

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 5.00 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification

Verified via WebSearch:

1. **Postgres replication lag from long analytical queries on replicas** — CONFIRMED. PostgreSQL's MVCC execution model means long-running queries on a streaming replica will indeed block WAL replay (or cancel the query) due to query/replication conflicts. The answer's claim that "a long analytical scan on a read replica can cause replication lag" is accurate. The common mitigation pattern (separate OLAP replica, `hot_standby_feedback`, `max_standby_streaming_delay`) is consistent with the answer's broader framing.

2. **Row-oriented vs columnar I/O reduction** — CONFIRMED. Postgres is row-oriented by design and reads full tuples even when only a few columns are needed. Columnar engines reading only required columns yield substantial I/O reduction for aggregation/scan workloads — the answer's "10–50x reduction in I/O" claim is in a reasonable, widely-cited range.

3. **Read replica solves "analytics breaking the app"** — Reasonable rule-of-thumb. The "~60%" number is an opinionated estimate rather than a measured stat, but the principle (separating analytics workload from primary) is broadly accurate and matches industry practice.

4. **Postgres tuning checklist items** (partial indexes, materialized views, `pg_partman`, PgBouncer, `EXPLAIN ANALYZE`) — all standard, correct Postgres optimization steps.

5. **Migration path mapped to user's actual stack** (Spark → MinIO → Iceberg → Hive Metastore → Trino) — matches `prod_info.md` exactly: on-prem k8s, Spark+Iceberg 1.5.2 for ingestion, Trino 467 for query, Hive Metastore.

6. **Threshold table** (50M rows, 2s p95, >3 ad-hoc queryers, >1 source system, >20% CPU) — reasonable, opinionated heuristics; not "facts" per se but defensible decision-aids and consistent with the resource.

7. **`pg_total_relation_size` SQL** — syntactically correct.

## What worked

- **Direct engagement with both teammates' positions** — explicitly named that one is "technically correct but incomplete" and the other is also right, then frames the actual question as "which optimization hits the wall first?" This is exactly the framing an engineer needs to take this back to a team debate.
- **Concrete, actionable Postgres tuning checklist** with one-line rationale per item. Not abstract.
- **Quantitative thresholds in a clean table** plus the "two or more" decision rule — gives the engineer a defensible number to bring to a planning meeting.
- **Honest application to their specific situation**: "For your situation right now (15,000 customers, 5–10M rows per customer, mostly 90-day queries), you almost certainly haven't hit the 50M row threshold." This personalizes the answer to the question rather than dumping generic advice.
- **Decision tree** mirrors the resource cleanly and makes the branching logic visually obvious.
- **Cost of moving too early vs too late** — directly addresses the "are we jumping too fast?" anxiety in the question.
- **"What to do next" with 5 specific actions** including a runnable SQL query for table sizing.
- **Stack-aware migration steps** correctly mapping to MinIO + Iceberg + Trino + Spark + Hive Metastore.
- **Jargon explained inline** — "row-oriented," "columnar," "replication lag" all get a one-sentence definition in context.

## What was wrong or missing

Essentially nothing of substance. Very minor:
- The "~60%" estimate for read replica problem-solving is opinionated; could be flagged as a heuristic rather than a measurement, but does not mislead.
- Could have briefly mentioned the cross-customer "platform health" report scenario the user explicitly raised — the answer addresses it implicitly via the columnar/row-store explanation, but a one-line callout ("your platform-health reports are the canonical case where Postgres aggregations across all customers struggle most") would have explicitly closed the loop on that specific framing.

Neither rises to the level of a real defect.

## Suggested topic score update
Old: 4.415 / 8 questions
New avg if this scores 5.00: (4.415 * 8 + 5.00) / 9 = **4.480 / 9 questions**
