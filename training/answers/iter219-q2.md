# Iter 219 Q2 — When to Stop Federating and Ingest into Iceberg: Concrete Signals and Decision Framework

## Answer

You're right to be skeptical about adding ingestion complexity without evidence. There are specific, measurable signals that tell you federation is the problem — not guessing. Here's what to look for.

### The Five Key Signals (in order of clarity)

**Signal 1: Postgres read-replica CPU sustained >70% during business hours**

Check `pg_stat_activity` and filter for queries running as the Trino-connector user. If Trino's JDBC connections are driving your replica's CPU consistently above 70% during peak hours, federation has become a load problem. Migrating to Iceberg removes this load entirely because Iceberg reads MinIO (object storage), not Postgres. This is the strongest signal — it means your Postgres replica is doing OLAP work, which is the wrong tool for that job.

**Signal 2: Query latency consistently exceeds your dashboard SLO**

If federated queries come back in >2 seconds but your dashboard SLO expects <500ms, the user experience is broken. Iceberg with the right partition and sort order routinely serves the same query in <500ms because of columnar scans and partition pruning (min/max stats on Parquet files). This is a direct UX problem that federation cannot solve without fundamental changes.

**Signal 3: Physical input bytes in EXPLAIN ANALYZE show full table scans despite WHERE clauses**

Run `EXPLAIN ANALYZE` on your federated query. Look at the Postgres TableScan node's `Input:` field — it shows how many rows Trino actually pulled from Postgres over JDBC. Compare that to the rows your WHERE clause should have filtered.

If you see `Input: 5200000 rows (450MB)` but your query only returns 1,000 rows and has a WHERE clause, **predicate pushdown failed**. Trino is fetching the entire table and filtering locally on workers. Look for the `Filtered:` percentage — if it's 0% or very low despite an active WHERE clause, the predicate is not pushing down. Iceberg avoids this by applying predicates at read time within columnar files, so this failure mode disappears after migration.

**Signal 4: Federation queries represent >20% of all query volume against that Postgres table**

Check `pg_stat_statements` or your Trino event listener audit log. If federation traffic is now 20%+ of total queries against the users table, it's no longer an edge case — it's become the primary access pattern. At that scale, an OLTP database is doing analytical work, which is the wrong architecture.

**Signal 5: Freshness requirement has loosened to >15 minutes**

If the business used to require real-time data but can now tolerate T-15min staleness, federation is no longer necessary. A 15-minute Spark/dbt micro-batch into Iceberg is strictly better: faster queries, no Postgres load, snapshot-isolated reads, and time travel. Federation is only justified when sub-minute freshness is a hard requirement.

### How to Rule Out Other Bottlenecks First

Before assuming federation is the problem, verify these alternatives:

**Check predicate pushdown first**: Run `EXPLAIN (TYPE DISTRIBUTED)` (free, no execution) on your federated query. Look specifically at the Postgres TableScan node for `constraint on [columns]` — if it's present, pushdown succeeded. If you see a `ScanFilterProject` or `Filter` node ABOVE the TableScan with your WHERE clause in it, pushdown failed. Fix the predicate shape (use supported types, avoid function calls on columns) before deciding to ingest.

**Check for connection exhaustion**: OSS Trino 467 has **no native JDBC connection pooling**. If you see "Too many connections" errors in Trino logs, the issue is connection pressure, not query speed. The fix is PgBouncer in front of Postgres (transaction-pooling mode, `prepareThreshold=0`). Connection pooling is a separate fix from ingestion — don't confuse the two.

**Check where time is actually spent**: Use the Trino Web UI query stats. Look at CPU time vs Blocked/Input time for the Postgres scan fragment. If `Blocked: Input` is high (operator waiting on data), the bottleneck is network or storage I/O from Postgres. If CPU time is high, the bottleneck is join complexity on Trino workers, not Postgres.

**Query your event listener for this table**:
```sql
SELECT
  query_id,
  execution_time_ms,
  physical_input_bytes,
  physical_input_rows
FROM iceberg.analytics.query_audit_log
WHERE created_at > NOW() - INTERVAL '24' HOUR
  AND query_text LIKE '%app_pg%'
ORDER BY execution_time_ms DESC
LIMIT 20;
```

High `execution_time_ms` paired with `physical_input_bytes` close to your full table size is the smoking gun that federation is fetching too much data.

### The Decision Framework

| You need... | Keep Federating | Ingest to Iceberg |
|---|---|---|
| Sub-minute freshness (real-time) | YES | No |
| 15-minute to 1-hour freshness (typical dashboard) | No | YES |
| One-off ad-hoc investigation | YES | Overkill |
| Continuous analytical queries on a large table | No | YES |
| Postgres replica showing OLAP load | No | YES |

**The freshness decision is the hinge.** Your options for ingestion cadence:
- **CDC streaming** (Debezium → Kafka → Iceberg): seconds to a few minutes latency, highest operational cost
- **Micro-batch Spark** (15-min refresh): minutes latency, medium cost, fits most SaaS dashboards
- **Nightly/hourly batch**: hours of latency, minimal operational cost

At 50 federated queries per day, if sub-minute freshness is NOT a hard requirement, a 15-minute Spark micro-batch into Iceberg is usually the right call. Iceberg will be faster, Postgres gets zero load, and you get time travel + partition pruning as bonuses.

### Migration Checklist (Once You Decide)

1. **Capture 1 week of event listener data** for the federated table: `execution_time_ms`, `physical_input_bytes`, query count.
2. **Decide ingestion cadence** based on freshness SLO (usually 15-minute micro-batch for SaaS dashboards).
3. **Partition the Iceberg table** to match your dominant query predicate. If queries mostly filter by `WHERE tenant_id = ? AND created_at > ?`, use `(day(created_at), bucket(tenant_id, N))`.
4. **Run federated and Iceberg side-by-side for one refresh cycle** to confirm row counts match.
5. **Cut over** by replacing the federated reference with the Iceberg table. Keep the federated path as a rollback for 1–2 weeks.

### Key Trade-off to Remember

**Federation wins on freshness** (true real-time, no ingestion lag). **Iceberg wins on speed and eliminates Postgres load**. The hybrid pattern — Iceberg for history + federated Postgres for the last hour — splits the difference but adds operational complexity. Only use it if your ingestion pipeline genuinely can't keep pace with your freshness SLO.

For 50 queries per day against a users lookup table with no hard real-time requirement: ingest it. The investment is worth it.
