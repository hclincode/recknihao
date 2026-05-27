# Iter113 Q2 — Answer

**Question**: We have about 80 tenants on our platform, and our Iceberg `events` table is partitioned by `tenant_id` and `event_date`. Most tenants are small — maybe 10,000 to 50,000 rows each — but we just onboarded two enterprise customers who each have around 200 million rows and they generate new events constantly. I have noticed that when those two big tenants run complex dashboard queries, the smaller tenants' dashboards start timing out or returning results really slowly, even though the queries are completely separate. Is this a partitioning problem, or is there something else going on? What can I actually do to stop the large tenants from degrading performance for everyone else — do I need to give them separate tables, or is there a way to handle this within the same table setup?

---

## Answer

You're seeing the **noisy-neighbor effect** — two independent problems layered together, each with a different fix. Partitioning is part of the problem but not the whole story. Here's what's happening and exactly what to do.

### Why Small Tenants Are Slowing Down (Three Mechanisms)

**Mechanism 1: Manifest metadata bloat slows query planning**

Iceberg organizes metadata as a tree: snapshot → manifest list → manifests → data files. When your planner evaluates a query, it walks the manifest list to find which manifests match the partition filter, even for queries that ultimately prune to just one tenant's files. With 200M+ rows from your two enterprise tenants, their files accumulate many manifests — and the planner must traverse all of them on every query's planning phase, even small-tenant queries. The symptom: small-tenant queries still read the right files, but planning time grows from 10ms to 100ms+.

**Mechanism 2: Shared maintenance jobs now work at enterprise-tenant scale**

Compaction (`EXECUTE optimize`), snapshot expiry, and orphan-file cleanup all walk the table's full metadata. A job that used to complete overnight now takes 30+ minutes because it's iterating over 200M enterprise-tenant rows. When these jobs run during business hours, they consume worker CPU and I/O that should serve customer queries.

**Mechanism 3: No per-tenant CPU limits — enterprise queries starve small tenants**

All 80 tenants share the same Trino cluster. An enterprise customer's 12-month aggregation pins every available worker core at 100%. Small-tenant dashboard queries land in the queue (`QUEUED` state) and wait. They're not slow — they're blocked.

### The Two-Part Fix (Both Are Needed)

Storage isolation (separate tables) fixes Mechanisms 1 and 2. Compute isolation (resource groups) fixes Mechanism 3. Neither alone is sufficient.

---

### Part A: Migrate the Two Enterprise Tenants to Dedicated Tables

**5-step safe cutover sequence** (order matters — safe to abort at any step before Step 5):

```sql
-- Step 1: Create dedicated table for enterprise tenant 'acme'
CREATE TABLE iceberg.analytics.acme_events (
  LIKE iceberg.analytics.events INCLUDING PROPERTIES
)
WITH (partitioning = ARRAY['day(event_ts)']);  -- no tenant_id; only Acme lives here

-- Step 2: Copy the data (shared table untouched; readers still see the existing view)
INSERT INTO iceberg.analytics.acme_events
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';

-- Step 3: VERIFY row counts match BEFORE proceeding
SELECT
  (SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme') AS shared_count,
  (SELECT COUNT(*) FROM iceberg.analytics.acme_events) AS dedicated_count;
-- If counts differ by even one row, ABORT and investigate.

-- Step 4: Swap the tenant view (atomic and instant — readers now see dedicated table)
CREATE OR REPLACE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.acme_events;

-- Step 5: Delete from shared table LAST (shared table is backup until this step)
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

Repeat the same 5 steps for the second enterprise tenant.

**Step 6: Post-cutover verification**

```sql
-- As the tenant principal: confirm the view returns only their own data
SELECT DISTINCT tenant_id FROM tenant_acme.events;
-- Expected: exactly one row ('acme')

-- As admin: confirm shared table no longer holds the migrated tenant
SELECT partition.tenant_id, record_count
FROM iceberg.analytics."events$partitions"
WHERE partition.tenant_id = 'acme';
-- Expected: zero rows
```

**Why the cutover order matters:** The view swap (Step 4) happens before the DELETE (Step 5). If Step 5 fails for any reason, the dedicated table is a complete copy and the view already points to it — customers never notice. If Step 4 fails, the shared table is untouched and customers continue reading from it.

**Result after both tenants are migrated:**
- Shared `events` table holds only 78 small tenants. Manifest traversal is fast again.
- Compaction jobs on the shared table complete in minutes, not hours.
- Enterprise tenants' dashboards run against their dedicated tables with no other tenants' data in the way.

---

### Part B: Add Resource Groups to Cap Enterprise CPU/Memory

Create two files on the Trino coordinator:

**`etc/resource-groups.properties`:**
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**`etc/resource-groups.json`:**
```json
{
  "cpuQuotaPeriod": "1h",
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "subGroups": [
      {
        "name": "enterprise_tenants",
        "softMemoryLimit": "40%",
        "hardConcurrencyLimit": 8,
        "maxQueued": 100,
        "softCpuLimit": "2h",
        "hardCpuLimit": "3h"
      },
      {
        "name": "small_tenants",
        "softMemoryLimit": "40%",
        "hardConcurrencyLimit": 50,
        "maxQueued": 500
      }
    ]
  }],
  "selectors": [
    {"user": "acme-service-account",   "group": "global.enterprise_tenants"},
    {"user": "beta-service-account",   "group": "global.enterprise_tenants"},
    {"user": ".*",                     "group": "global.small_tenants"}
  ]
}
```

**Note:** The `user` selector matches the JWT principal (e.g., `acme-service-account`) — not a Trino role name. Confirm each enterprise tenant's service account name matches exactly what appears in the JWT `sub` claim; a mismatch silently routes them to the catch-all `small_tenants` group.

**Deploy:**
```bash
kubectl rollout restart deployment/trino-coordinator -n trino
kubectl rollout status deployment/trino-coordinator -n trino
```

**What this does:** Enterprise tenants can run at most 8 concurrent queries and use at most 40% of cluster memory. Even a 12-month full-scan aggregation can't pin all the workers. Small tenants get 50 independent concurrency slots with their own 40% memory cap.

**Verify:**
```sql
SELECT query_id, user, resource_group_id, state
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
-- Confirm: acme-service-account → global.enterprise_tenants
-- Confirm: small-tenant principals → global.small_tenants
```

---

### Checklist

1. Identify the two enterprise tenants' row counts via `$partitions` metadata (no full table scan needed):
   ```sql
   SELECT partition.tenant_id, record_count, file_count,
          ROUND(total_size / 1e9, 2) AS total_gb
   FROM iceberg.analytics."events$partitions"
   ORDER BY total_size DESC LIMIT 10;
   ```
2. Run the 5-step cutover for both enterprise tenants (one at a time)
3. Run Step 6 verification after each migration
4. Deploy resource-groups.json + properties file and restart the coordinator
5. Add a weekly alert: if any single tenant exceeds 30% of the shared table's total_size, promote them to a dedicated table before customers notice
