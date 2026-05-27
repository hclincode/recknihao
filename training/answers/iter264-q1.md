# Iter264 Q1 — Iceberg Time Travel in Federated Queries: Can I Join Historical Iceberg Against Live Postgres?

## Answer

**Yes, you can absolutely do this in a single Trino query.** Iceberg time travel works seamlessly in a federated join with live PostgreSQL. Trino will pin the Iceberg events table to a specific historical snapshot while joining it against current Postgres user/account records — all in one statement.

### The Syntax

```sql
-- Query events from 30 days ago, joined to current Postgres user records
SELECT 
  e.user_id,
  e.event_type,
  e.event_count,
  u.plan_tier,
  u.account_name
FROM iceberg.analytics.events FOR VERSION AS OF snapshot_id_here AS e
JOIN app_pg.public.accounts AS u ON e.user_id = u.user_id
WHERE e.tenant_id = 'your-customer';
```

To find the snapshot ID from 30 days ago, query Iceberg's metadata:

```sql
SELECT snapshot_id, committed_at
FROM iceberg.analytics."events$snapshots"
WHERE committed_at <= TIMESTAMP '2026-04-27 23:59:59 UTC'  -- 30 days ago
ORDER BY committed_at DESC
LIMIT 1;
```

You can also use the timestamp-based syntax directly (Trino resolves the nearest snapshot):

```sql
FROM iceberg.analytics.events 
FOR TIMESTAMP AS OF TIMESTAMP '2026-04-27 00:00:00 UTC' AS e
```

### Why This Works

**On the Iceberg side**: the snapshot ID is resolved at planning time, and Trino reads the historical manifest files and data files from object storage — exactly the same as a current query, just pointing at a different snapshot.

**On the Postgres side**: the connector opens a fresh `READ COMMITTED` cursor at execution time, giving you the current state of accounts. Only Iceberg is pinned to history; Postgres always runs live.

**Optimizations still fire**: partition pruning, file skipping, and dynamic filtering (runtime join pruning) all work perfectly with time travel. If your WHERE clause filters on partition columns or join keys, those still prune aggressively.

### The Real-World Trap: Snapshot Expiration

The #1 failure mode in production is **snapshot expiration**:

- If your maintenance job runs `expire_snapshots` with a retention threshold below 30 days (many default to 7 days), the snapshot you're trying to query may no longer exist.
- The query will fail with an error like: `No version history table ... at or before <timestamp>`
- **There is no fallback** — once a snapshot is expired, you cannot query it.

**Check your retention policy first:**

```sql
-- What's the current expire_snapshots retention setting?
-- Check your dbt/Spark job that runs this
ALTER TABLE iceberg.analytics.events 
EXECUTE expire_snapshots(retention_threshold => '30d');
-- If currently set to '7d', you need to change it before you can do 30-day time travel
```

### Protecting Audit Snapshots with Tags

For any snapshot you need to query repeatedly (billing audits, compliance, customer comparisons), **pin a named tag** at that snapshot BEFORE `expire_snapshots` runs:

```sql
-- Create at month-end (Spark — Trino 467 cannot create tags directly)
ALTER TABLE iceberg.analytics.events
  CREATE TAG '2026-05-billing-snapshot' 
  AS OF VERSION snapshot_id_here;

-- Query anytime in the future with the tag
SELECT ...
FROM iceberg.analytics.events 
FOR VERSION AS OF '2026-05-billing-snapshot' AS e
JOIN app_pg.public.accounts AS u ON ...
```

Tags survive `expire_snapshots` indefinitely — the tagged snapshot is protected from cleanup.

### Performance Considerations

**Good news**: time-travel queries are **no slower than regular queries**. Predicate pushdown still works; dynamic filtering still works. Your WHERE predicates still prune partitions and files.

**One async issue**: if you're running a Postgres-build × Iceberg-probe join (small Postgres result used to filter large Iceberg table via dynamic filtering), the Iceberg-side dynamic filter has a default wait timeout of 1 second. Since Postgres scans typically take several seconds, the Iceberg scan may start without the dynamic filter. Fix:

```properties
# etc/catalog/iceberg.properties
iceberg.dynamic-filtering.wait-timeout=20s
```

This gives Postgres time to deliver the filter before Iceberg starts scanning.

### Summary

| Question | Answer |
|---|---|
| Can you do it in one query? | Yes |
| Is Iceberg pinned to history? | Yes — snapshot resolved at plan time |
| Is Postgres pinned to history? | No — always live |
| Is it slow? | No — all optimizations still fire |
| What breaks it? | Snapshot expiration |

**Action items before using 30-day time travel:**
1. Check your `expire_snapshots` retention policy (must be >= 30 days for this use case)
2. For audit windows you need to query repeatedly, use tags to pin snapshots before expiry
3. Set `iceberg.dynamic-filtering.wait-timeout=20s` in your Iceberg catalog if join performance is inconsistent
