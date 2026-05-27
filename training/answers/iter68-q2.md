# Iter68 Q2 — Answer

**Question**: We store all our tenants' event data in a single Iceberg table, partitioned by tenant_id. We have maybe 200 tenants today but we're growing fast and expect to be at 2,000+ within a year. Someone on my team mentioned we shouldn't use tenant_id directly as a partition key at that scale and instead should use something called a "bucket" transform — but I have no idea what that means or why it would be better. If I partition directly by tenant_id, what actually breaks or degrades when we have thousands of tenants? And what does this bucket approach do differently? How would I even pick how many buckets to use?

---

## Answer

Your teammate is right — direct tenant_id partitioning runs into real problems at thousands of tenants, and the bucket transform is the standard solution. Here's what breaks, how buckets fix it, and how to choose N.

### What breaks with direct tenant_id partitioning at 2,000+ tenants

**Problem 1: Metadata explosion**

Iceberg tracks every partition in manifest files in the table metadata. With `PARTITIONED BY (tenant_id, day(event_ts))`, you get one partition entry per (tenant, day) combination. At 200 tenants × 365 days = 73,000 partitions per year — manageable. At 2,000 tenants × 365 = 730,000 partitions per year, manifest files grow large, query planning slows (Trino has to read more partition metadata before executing), and Hive Metastore lookups get sluggish.

**Problem 2: Small-file explosion from small tenants**

In any SaaS product, tenants are not uniform — 80% of events come from 20% of customers. Your 2,000 tenants will include:
- A few large tenants writing 100,000+ events per day → these create reasonably-sized Parquet files.
- Hundreds of tiny tenants writing 50 events per day → these create tiny Parquet files (kilobytes, not megabytes).

Tiny files are expensive. When a Trino query scans across many tenants, it opens each file — and file-open overhead (10–50 ms per file for metadata reads) dominates. 1,000 tiny tenant files costs more to open than 10 large ones, even if the total byte count is smaller. At 2,000 tenants with heterogeneous sizes, many queries become dominated by file-open overhead.

**Problem 3: No clean upgrade path when you want time partitioning**

If you start with `PARTITIONED BY (tenant_id)` and later want to add time partitioning (almost universal in analytics), changing the partition spec requires rewriting all historical data. Planning ahead with a scalable scheme from the start avoids this.

### What `bucket(N, tenant_id)` does

The bucket transform hashes each tenant_id value into one of N fixed buckets using a deterministic hash function. Instead of one partition per tenant, multiple tenants share each bucket.

With `bucket(128, tenant_id)`:
- `hash('acme') mod 128` → bucket 42
- `hash('beta') mod 128` → bucket 17
- `hash('gamma') mod 128` → bucket 42 (same bucket as acme)

All events from tenants that hash to bucket 42 live in the same partition files. Queries for `WHERE tenant_id = 'acme'` still return only Acme's events — the row-level filter applies inside the bucket — but Iceberg prunes to just bucket 42 without scanning the other 127 buckets.

**What this fixes**:
- Partition count stays constant at 128 (or however many buckets you choose) regardless of how many tenants you have. Add 10,000 tenants and the partition count doesn't change.
- Small tenants' events are co-located with other small tenants in the same bucket, so each bucket file is a reasonable size even if individual tenants write very little.
- Manifest metadata stays lean: 128 buckets × 365 days = 47,280 partitions per year, forever.

### The trade-off: you lose strict per-tenant file isolation

With direct partitioning, a query for tenant Acme reads only Acme's files — perfect isolation. With bucket partitioning, Acme's data shares bucket 42 with several other tenants. A query for `WHERE tenant_id = 'acme'` reads all files in bucket 42 and filters to Acme's rows. You're reading more data than necessary.

For typical analytics workloads (dashboard aggregations, time-series queries, funnels), this overhead is acceptable — you're scanning large time ranges anyway. For very precise per-tenant point lookups, this can matter.

### How to choose N (number of buckets)

Target Parquet file sizes of 128 MB–1 GB per bucket-day partition. Here's the math:

1. Estimate total events per day across all tenants.
2. Estimate compressed Parquet bytes per event (typically 200–500 bytes for SaaS event tables after columnar compression).
3. Choose N so each bucket-day partition lands in the target size range.

Example: 5 billion events/day × 300 bytes/event = 1.5 TB/day total. Divided by 128 buckets = ~12 GB per bucket per day. With `rewrite_data_files` targeting 256 MB files, that's ~47 Parquet files per bucket-day — very manageable.

**Practical rules of thumb**:
- **32–64 buckets**: small-to-medium SaaS (< 500M events/day)
- **128 buckets**: default for most B2B SaaS (500M–5B events/day)
- **256 buckets**: high-volume products (5B+ events/day)

Don't go below 16 (each bucket is huge, slow scans) or above 512 (metadata overhead returns). Start with 128 for most teams — it handles 10–100× growth without redesign.

### The recommended pattern: bucket + time

Combine bucket partitioning with day-level time partitioning:

```sql
CREATE TABLE iceberg.analytics.events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP,
  user_id     VARCHAR,
  payload     VARCHAR
)
WITH (
  partitioning = ARRAY['bucket(128, tenant_id)', 'day(event_ts)']
);
```

This gives you:
- **128 × 365 = 47,280 partitions/year** regardless of tenant count.
- **Fast per-tenant queries**: `WHERE tenant_id = 'acme'` prunes to 1 bucket.
- **Fast time-range queries**: `WHERE event_ts >= '2026-05-01'` prunes on the day dimension across all buckets.
- **Compound pruning**: `WHERE tenant_id = 'acme' AND event_ts >= '2026-05-01'` prunes to 1 bucket + only May onward.

This is the pattern that scales from 200 to 20,000 tenants without redesign.

### Migration if your table already exists

If you already have the table partitioned by `(tenant_id, day(event_ts))` and want to switch:

```sql
-- Step 1: Change the partition spec (metadata only, no data rewrite yet)
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['bucket(128, tenant_id)', 'day(event_ts)'];

-- Step 2: Rewrite historical data into the new partition layout (run via spark-submit)
CALL iceberg.system.rewrite_data_files(
  table    => 'analytics.events',
  strategy => 'sort',
  options  => map('target-file-size-bytes', '268435456')
);
```

The rewrite takes time (30–90 minutes per TB on a typical on-prem Spark cluster). New ingestion after the ALTER TABLE will write to the bucket layout automatically. Historical data written before the ALTER stays in the old layout until rewrite_data_files migrates it.

Run the rewrite during a maintenance window — it's a heavy Spark job that competes with ingestion for cluster resources.

### Summary

| Direct tenant_id partitioning | bucket(128, tenant_id) + day(event_ts) |
|---|---|
| 1 partition per tenant | 128 fixed buckets, multiple tenants per bucket |
| 730K+ partitions/year at 2K tenants | 47K partitions/year regardless of tenant count |
| Tiny files from small tenants | Small tenants co-located in shared buckets |
| Queries read only one tenant's files | Queries read 1/128 of the table, then filter |
| Breaks at 2K+ tenants | Scales to 20K+ tenants without redesign |

At 200 tenants today you're not in acute pain yet, but planning the migration before you hit 500–1,000 tenants is the right call — at that scale you can rewrite historical data in a few hours rather than days.
