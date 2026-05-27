# Iter 192 Q2 — Read Replica Lag vs Trino Caching: Distinguishing and Routing

## Answer

## Your problem is almost certainly **Postgres replication lag**, not Trino caching

Here's how to tell the difference, and what tools you have to fix it.

### Understand what Trino actually caches (and doesn't)

**Trino caches METADATA ONLY, and only if you turned it on:**
- Check your PostgreSQL catalog properties file (`etc/catalog/app_pg.properties`): look for `metadata.cache-ttl`.
  - If it's `0s` or missing (the default), Trino is NOT caching schema metadata.
  - If it's `60s`, `300s`, or higher, Trino IS caching schema metadata (column names, column types, table definitions) for that duration.
- **This caching is ONLY about schema structure.** It does NOT cache table row data or query results. Trino has no query result cache for the PostgreSQL connector — every query executes a fresh SELECT against the replica, pulls matching rows, and returns them.

### How to distinguish replication lag from metadata cache lag

| Symptom | Trino metadata cache | Postgres replication lag |
|---|---|---|
| **Timing** | 5–10 seconds after a write? | YES — replication lag matches |
| **What you see** | Stale schema (column names don't update) | Stale DATA (new record missing) |
| **How to test** | `DESCRIBE app_pg.public.accounts;` before/after Postgres schema change | Query PRIMARY directly — if primary shows new record immediately but replica doesn't, it's lag |
| **TTL window** | Up to `metadata.cache-ttl` duration | 5–10 seconds matches typical streaming replication lag |
| **Fix** | `CALL app_pg.system.flush_metadata_cache();` or wait for TTL | Reduce replica load; tune replication settings |

**Your symptoms point to replication lag.** The 5–10 second window, data visibility (new record) not schema issues (column names), and immediate user action all match replica lag.

### How to measure Postgres replication lag

On your **primary** Postgres database, run:

```sql
SELECT 
  client_addr,
  state,
  write_lag,
  flush_lag,
  replay_lag
FROM pg_stat_replication;
```

If `replay_lag` shows 5–10 seconds, that is your culprit. The replica is lagging by that much on applying writes.

Three lag points:
- **`write_lag`**: time since primary wrote the WAL record (usually <50ms)
- **`flush_lag`**: time since replica received and flushed to disk (usually 10–100ms)
- **`replay_lag`**: time since replica **applied it to the database** — this is the one that matters for analytics reads

### Why replication lag happens and what to do about it

**Common causes:**
1. The replica is underpowered relative to the primary
2. Heavy Trino analytical queries holding long transactions on the replica block WAL application
3. Multiple tools (BI tools, dbt, scripts) all querying the replica simultaneously

**Mitigation options:**

**Option 1: Reduce read load on the replica (lowest effort, highest impact)**
```sql
-- Set statement_timeout on the replica to kill runaway queries:
ALTER SYSTEM SET statement_timeout = '5min';
SELECT pg_reload_conf();
```
Also check PgBouncer connection limits and Trino resource groups (see connection pooling docs).

**Option 2: Use `hot_standby_feedback` to prevent primary from blocking replication**
```ini
# In replica's postgresql.conf (Postgres 12+):
hot_standby_feedback = on
```
This tells the replica to signal back so the primary doesn't vacuum rows still needed by long transactions. Tradeoff: primary vacuums less aggressively.

### Routing time-sensitive queries to the primary

**Approach 1: Separate catalog for the primary (recommended)**

Create a second PostgreSQL catalog pointing at the **primary**:

```properties
# etc/catalog/app_pg_primary.properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-primary.app.svc.cluster.local:5432/appdb
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

Roll the coordinator and workers. Now you have:
- `app_pg` — replica catalog (most queries, reduced primary load)
- `app_pg_primary` — primary catalog (read-after-write consistency for fresh queries)

Your application routes accordingly:
- Read-after-write queries → `app_pg_primary.public.accounts`
- Historical/analytical queries → `app_pg.public.accounts`

**Pros:** Simple, explicit, no magic. **Cons:** Two catalog configurations, two credential sets, application code must know which to use, puts read load on primary.

**Approach 2: The pragmatic middle ground**

Accept the 5–10 second lag for analytics dashboards and add a UI note: *"Data refreshes every 5–10 seconds due to replication latency. For immediate transaction confirmation, check your account page."* Most SaaS teams use this approach.

### Checklist: diagnose your issue step by step

**Step 1: Check if you're using metadata caching:**
```bash
grep metadata.cache-ttl /etc/trino/catalog/app_pg.properties
```
If `0s` or missing → caching is off; your issue is NOT Trino metadata cache. If `60s` or higher → caching is on for schema only, still not data freshness.

**Step 2: Measure your replica lag:**
```sql
-- Run on the PRIMARY:
SELECT replay_lag FROM pg_stat_replication;
```
If 5+ seconds → replication lag confirmed.

**Step 3: Test direct primary access:**
Run your dashboard query against both `app_pg_primary` (if you create it) and `app_pg` side-by-side and time the freshness difference.

**Step 4: Reduce replica load:**
- Check what other tools query the replica (`SELECT * FROM pg_stat_activity WHERE state = 'active';`)
- Set aggressive `statement_timeout` on the replica
- Monitor concurrent Trino queries using Trino Web UI

**Step 5: If you decide to add a primary catalog:**
Create `etc/catalog/app_pg_primary.properties`, roll coordinator + workers, update dashboard code to route fresh-read queries to primary.

### Final note: you probably don't need the primary catalog

Unless your SaaS product explicitly markets sub-second analytics freshness, the 5–10 second lag is acceptable and expected. Most SaaS dashboards refresh every 30–60 seconds anyway. Measure the lag, reduce load on the replica, and educate customers about refresh timing before adding infrastructure complexity.
