# Iter95 Q2 — Answer

**Question**: We're designing a new Iceberg table for usage events and trying to decide how to partition by `tenant_id`. I've seen two different patterns in examples: some just use `tenant_id` directly in the partition spec so each tenant gets their own group of files, and others use something called `bucket(tenant_id, 64)` which seems to hash tenants into a fixed number of buckets instead. We have about 200 tenants but the distribution is very uneven — our 5 largest customers generate roughly 80% of all events while the other 195 are relatively small and quiet. Does that size imbalance between tenants affect which approach I should use, and what does each one actually mean in terms of how files end up on disk and how queries behave when I'm filtering by a specific tenant?

---

## Answer

## The two approaches

Both patterns are real and work differently on disk.

### Approach 1: Direct `tenant_id` partitioning

```sql
-- Trino
CREATE TABLE iceberg.analytics.usage_events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  occurred_at TIMESTAMP(6),
  ...
)
WITH (
  partitioning = ARRAY['day(occurred_at)', 'tenant_id'],
  format = 'PARQUET'
);
```

Files on MinIO live at paths like `day=2026-05-25/tenant_id=acme/part-000.parquet`, `day=2026-05-25/tenant_id=globex/part-001.parquet`. Each tenant gets its own directory per day. When you query `WHERE tenant_id = 'acme'`, Iceberg reads the partition metadata and opens only the `tenant_id=acme/` files — it skips every other tenant's files without even opening them. This is called **partition pruning**.

### Approach 2: `bucket(tenant_id, 64)` partitioning

```sql
-- Trino
WITH (
  partitioning = ARRAY['day(occurred_at)', 'bucket(tenant_id, 64)'],
  format = 'PARQUET'
);
```

Instead of one partition per tenant, this hashes each tenant ID into one of 64 fixed buckets. Files live at `day=2026-05-25/bucket=0/part-000.parquet`, `day=2026-05-25/bucket=12/part-000.parquet`, etc. Multiple tenants share each bucket. When you filter by `WHERE tenant_id = 'acme'`, Iceberg runs the same hash function on 'acme', sees it maps to (say) bucket 12, and opens only that bucket's files. The bucket assignment is deterministic — 'acme' always goes to bucket 12.

## Why the skewed distribution matters

This is the core issue. With direct partitioning and your 5-tenant/80% skew:

**The large-tenant problem:** Your five biggest tenants each get their own partition, and each generates ~160 MB–1 GB of Parquet per day. That's healthy — Spark writes 1-3 files per day per large tenant, compaction stays easy.

**The small-tenant problem:** Your 195 quiet tenants each generate maybe 1–50 MB per day. That's 1 tiny file per day per tenant, possibly less. After 30 days you have 195 × 30 = 5,850 tiny files just from the small tenants. Iceberg must read metadata for all those files on every table scan. Queries slow down not from reading data but from opening thousands of manifest entries. This is the **small-file problem** at its worst.

**How bucketing solves it:** With 64 buckets, your 195 small tenants spread across all 64 buckets. Each bucket collects events from ~3 small tenants per bucket. Spark writes one file per bucket per day → 64 files per day for the entire table. After compaction you get 1-3 files per bucket per day = 1,920 files over 30 days instead of 5,850+. The metadata Iceberg scans is much smaller, and file sizes are consistently healthy.

## How queries behave

| Query pattern | Direct partitioning | Bucketing |
|---|---|---|
| `WHERE tenant_id = 'acme'` | Opens only `tenant_id=acme/` files | Hashes 'acme' → opens only bucket N files |
| `WHERE tenant_id IN (5 tenants)` | Opens 5 partitions | Opens up to 5 buckets |
| `WHERE day = '2026-05-25'` (all tenants) | Opens all 200 tenant partitions | Opens all 64 buckets |
| Billing: `GROUP BY tenant_id` | Metadata-only (no Parquet reads) | Metadata-only (still works via manifests) |

Single-tenant queries are fast with either approach — both prune to exactly the right set of files. The difference shows up in table-scan overhead (fewer files = faster manifest reads) and write-time file sizes.

## Recommendation for your 200-tenant skewed setup

**Use `bucket(tenant_id, 64)` combined with `day(occurred_at)`.**

Why:

1. **Compaction stays predictable.** With 64 buckets, a nightly `rewrite_data_files` job produces 1-3 compacted files per bucket per day. No matter how many tenants are added, the file count stays bounded.

2. **Small tenants don't generate metadata bloat.** Your 195 quiet tenants contribute a handful of rows per bucket per day — they never create their own tiny partition files.

3. **Large tenants don't dominate file sizes.** Your five big tenants' events get mixed with small tenants' events across buckets. Each bucket ends up with a balanced mix. No single partition blows up to multi-GB files.

4. **Single-tenant queries stay fast.** `WHERE tenant_id = 'acme'` prunes to exactly one bucket — same read efficiency as direct partitioning.

5. **Metadata stays manageable.** Direct partitioning with 200 tenants × 365 days = 73,000 partitions. Bucketing with 64 buckets × 365 days = 23,360 partitions. Trino reads manifests faster with fewer partitions.

## Spark DDL (note the argument order difference)

```python
# Spark syntax: bucket(N, column) — count FIRST
spark.sql("""
  CREATE TABLE iceberg.analytics.usage_events (
    event_id    STRING,
    tenant_id   STRING,
    occurred_at TIMESTAMP,
    ...
  )
  USING iceberg
  PARTITIONED BY (day(occurred_at), bucket(64, tenant_id))
""")
```

Note: Trino uses `bucket(tenant_id, 64)` (column first), Spark uses `bucket(64, tenant_id)` (count first). The on-disk result is identical — use Trino for DDL if you prefer consistency.

## One caveat: when to consider direct partitioning

If your five large tenants are so dominant that they have their own SLA-backed dashboards, and you're worried bucket-sharing slows their queries (because bucket files contain other tenants' rows that must be skipped row-by-row), you can consider a hybrid: partition your main table with bucketing for all 200 tenants, and create separate per-tenant tables for the five whales that can use direct day+tenant partitioning with tight compaction. This is operationally complex — start with bucketing for everyone and only split if you measure a concrete latency problem.

## The billing query bonus

Because `tenant_id` appears in the partition spec (even via bucketing), per-tenant row counts can be answered entirely from Iceberg's manifest metadata without opening Parquet files:

```sql
-- This runs in seconds on a huge table — reads only manifest metadata
SELECT tenant_id, COUNT(*)
FROM iceberg.analytics.usage_events
WHERE day >= '2026-05-01'
GROUP BY tenant_id;
```

Iceberg tracks row counts per file, and files are grouped by bucket (which maps to a deterministic set of tenants). The engine aggregates the manifests without touching data files. This is the canonical SaaS billing query and it stays fast regardless of scale.
