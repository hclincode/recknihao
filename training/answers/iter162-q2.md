# Iter 162 Q2 — Federation vs Ingest: Decision Framework for Cross-Source Joins

## Answer

## Federate or Ingest? A Decision Framework

Your instinct is right to question whether cross-source joins in Trino are fast enough. The answer depends on a few specific factors, and there's a clear decision matrix.

### When cross-catalog joins in Trino actually work

Trino's PostgreSQL connector can query both sources in one statement, but there's a critical gotcha: **the join itself always runs on Trino workers** — it cannot be pushed down to Postgres. What you can optimize is how much data flows across the network before the join happens.

**The key optimization is dynamic filtering.** When Trino builds a hash table from your smaller side (the Postgres account settings), it derives a filter based on the actual values it saw, and pushes that filter to the Iceberg scan to reduce rows. For example: if you have 5,000 unique account IDs in your filtered Postgres results, Trino creates an IN-list filter (`user_id IN (id1, id2, ..., id5000)`) and sends it to Iceberg. Iceberg can then skip files that don't contain those IDs.

This works great **only if one side of the join is small and selective.** If your Postgres query filtering (e.g., `WHERE account_tier = 'enterprise'`) returns thousands or tens of thousands of rows, and your Iceberg events table is hundreds of millions of rows, Trino can prune the Iceberg side. But if the Postgres side returns millions of rows, you're pulling millions of rows over JDBC and building a huge hash table — at that point the federation approach will be slow.

**Verify this with `EXPLAIN (TYPE DISTRIBUTED)`** on one of your actual queries. Look for `dynamicFilters = {column = ...}` on the Iceberg side's `ScanFilterProject` node. If it's there, dynamic filtering kicked in and the join is probably acceptable. If it's missing, the probe-side scan is reading nearly all rows — time to ingest.

### When to ingest to Iceberg instead

Ingesting the Postgres table into Iceberg wins when:

1. **These joins run repeatedly** (dashboards, daily reports). You pay the ingestion cost once, then get fast columnar reads forever. For a table you join on "pretty often," this usually pays back in days or weeks.

2. **Query freshness requirements are compatible.** If your account settings table changes infrequently (plans, tier definitions, etc.), ingesting hourly or daily is fine. Real-time Postgres querying is only necessary if the account tier changes several times per minute and your dashboards need second-level freshness.

3. **The Postgres table is large or needed for multi-table joins.** Large dimensions benefit enormously from becoming Iceberg because both the scan and the join can stay columnar. If you'll later join that table with other Iceberg tables in future queries, having it in Iceberg unlocks optimization opportunities that cross-catalog joins cannot achieve.

### The hidden cost of ingestion

Don't just think about query speed. Ingestion means:
- **Writing a Spark job** to read from Postgres and write to Iceberg (via JDBC).
- **Deciding on a watermark column** — typically `updated_at` if account settings get updated, or a full refresh if the table is small and stable.
- **Maintaining the job** — monitoring for failures, handling late-arriving data, running compaction.

For a small dimension table (under 100K rows), a nightly **full refresh** is the simplest approach: just read the whole Postgres table and overwrite the Iceberg copy. For larger tables that change frequently, you'd use **incremental append** with a watermark, which adds complexity around deduplication.

### Decision flowchart

```
Is this a "run once, investigate" query?  → Just federate, no setup cost.
                ↓ NO
Does your Postgres table change daily/hourly, 
and these joins run many times per day?  → Ingest (lower total cost over time).
                ↓ NO
Is the account settings table small (<1M rows)?  → Federate + verify dynamic filtering with EXPLAIN.
                ↓ NO
Both large and frequently joined?        → Ingest.
```

### Concrete recommendation

**Ingest the account settings table.** Reasons:
- Account settings tables are typically small and stable (easier ingestion than a fact table).
- If you're running these joins "pretty often," a full refresh or hourly incremental refresh costs less than the cumulative slow-query overhead.
- Once in Iceberg, the join becomes intra-catalog and can leverage broadcast join optimization — likely 10–100x faster than the federated path.

**But first, verify the federated path is actually slow** by running `EXPLAIN (TYPE DISTRIBUTED)`. If dynamic filtering is firing, keep federating — the query is probably fast enough. If it's missing, that's your sign: time to ingest.
