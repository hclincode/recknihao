# Iter112 Q1 — Answer

**Question**: We have about 200 customers using our analytics dashboard. Most are small — maybe a few thousand rows of data each — but we recently signed two enterprise customers who have tens of millions of rows each. Now I'm noticing that when I run any kind of cross-tenant aggregation (like "what's the total usage across all customers this month" for our own internal reporting), the query is dominated by those two big tenants. That part I understand. The problem I can't figure out is the reverse: queries scoped to a *small* tenant are now slower too, even though their data hasn't changed. We're using Trino on Iceberg, and all tenant data is in the same table with a `tenant_id` column. What could be going on, and how do I fix it without splitting every tenant into their own table?

---

## Answer

This is the **noisy-neighbor problem** — your partition pruning is still working correctly for small tenants, but three other mechanisms are hurting them. The fix does not require splitting every tenant.

### Why small tenant queries got slower

**1. Larger Iceberg manifest.** Iceberg's table metadata (manifest files listing which data files exist, with partition info and column statistics) is now much larger. Even though a small-tenant query prunes to just that tenant's files, the Trino coordinator still reads through the full manifest at query planning time to find which files to skip. More entries = slower planning.

**2. Shared maintenance jobs run longer.** Nightly compaction (`rewrite_data_files`), snapshot expiry, and orphan file cleanup now iterate over the enterprise tenants' files too. If these jobs are still running during business hours, they consume worker CPU and I/O that should serve customer queries.

**3. No per-tenant cluster quotas.** An enterprise tenant's 12-month aggregation query can saturate cluster CPU and memory, queueing every small tenant's dashboard request behind it.

### Fix 1: Correct partition spec (if not already set)

If the table is only partitioned by `tenant_id` without time, switch to `(day(event_ts), tenant_id)`:

```sql
-- Trino: change partition spec for new writes
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['day(event_ts)', 'tenant_id'];
```

```python
# Spark: rewrite historical data under the new spec
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table => 'analytics.events',
        options => map('target-file-size-bytes', '268435456', 'min-input-files', '1')
    )
""")
```

This organizes the manifest by (day, tenant) tuples. Small-tenant queries now skip irrelevant days entirely — planning is faster.

### Fix 2: Migrate only the two large tenants to dedicated tables

You don't need to split every tenant — just isolate the two outliers. This is the safe 5-step cutover sequence:

**Step 1: Create a dedicated table**
```sql
CREATE TABLE iceberg.analytics.acme_events (
  LIKE iceberg.analytics.events INCLUDING ALL
)
WITH (partitioning = ARRAY['day(event_ts)']);  -- no tenant_id; only Acme lives here
```

**Step 2: Copy the tenant's data**
```sql
INSERT INTO iceberg.analytics.acme_events
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

**Step 3: Verify row counts match BEFORE proceeding**
```sql
SELECT
  (SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme') AS shared_count,
  (SELECT COUNT(*) FROM iceberg.analytics.acme_events) AS dedicated_count;
```
If the numbers differ by even one row, abort and investigate.

**Step 4: Swap the Trino view to the dedicated table**
```sql
CREATE OR REPLACE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.acme_events;
```

**Step 5: Delete from shared table LAST**
```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

**Why this order matters:** the view swap happens before the DELETE, so the dedicated table is a complete backup if anything fails. You can always swap the view back.

**Result:** the shared table now holds only 198 small tenants. Manifest reads are much faster, maintenance jobs complete in a fraction of the time, and small-tenant queries no longer compete with enterprise-data compaction.

### Fix 3: Resource groups for CPU/memory isolation

Even with dedicated tables, the enterprise tenants share the same Trino cluster. Cap their concurrency and memory in `etc/resource-groups.json`:

```json
{
  "cpuQuotaPeriod": "1h",
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "subGroups": [
      {"name": "enterprise_acme",   "softMemoryLimit": "40%", "hardConcurrencyLimit": 10, "hardCpuLimit": "3h"},
      {"name": "enterprise_globex", "softMemoryLimit": "40%", "hardConcurrencyLimit": 10, "hardCpuLimit": "3h"},
      {"name": "small_tenants",     "softMemoryLimit": "40%", "hardConcurrencyLimit": 50}
    ]
  }],
  "selectors": [
    {"user": "acme-service-account",   "group": "global.enterprise_acme"},
    {"user": "globex-service-account", "group": "global.enterprise_globex"},
    {"user": ".*", "group": "global.small_tenants"}
  ]
}
```

And `etc/resource-groups.properties`:
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

Both files go on the coordinator pod. Restart the coordinator:
```bash
kubectl rollout restart deployment/trino-coordinator -n trino
```

Enterprise tenants can still run long aggregations (generous `hardCpuLimit: 3h`) but cannot monopolize the cluster. Small tenants in `global.small_tenants` retain 40% of memory and 50 concurrency slots.

Note: tenant migration and resource groups are **complementary, not alternative** levers. Migration provides storage isolation (compaction and file scans are isolated). Resource groups provide compute isolation (CPU/memory quota enforcement at query time). Both are needed.

### Checklist

1. Verify partition spec includes `day(event_ts)` before `tenant_id` — `SHOW CREATE TABLE analytics.events`
2. Migrate the two large tenants using the 5-step sequence (do them one at a time)
3. Set up resource groups to cap enterprise tenants' concurrency and memory
4. Schedule nightly compaction on the shared table during off-peak hours
