# Iter282 Q1 — Trino Federation to a Postgres Read Replica

## Answer

Yes — pointing Trino at the read replica is mostly just changing the connection URL. But the replication lag story is entirely on you to manage.

### 1. The Config Change Is Straightforward

In `etc/catalog/app_pg.properties`, update the JDBC URL to point at the replica host:

```properties
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb
connection-user=trino_reader
connection-password=...
```

Everything else stays the same — credentials, JDBC parameters, type mappings. Trino treats the replica as an ordinary Postgres instance. There is no "read replica mode" or flag to set.

### 2. Trino Has Zero Replication Lag Awareness

**Trino does not know the replica exists, does not know about the primary, and has no mechanism to detect or warn you about replication lag.** If the replica is 30 seconds or 5 minutes behind, Trino silently returns stale rows. No warning, no error, no flag in query results. The data appears identical to fresh data from the primary.

This is the most important thing to understand: replication lag is your operational responsibility, not Trino's.

### 3. How to Monitor Lag Externally

You must track replication lag independently and make decisions based on it:

**On the primary**, check all replicas:
```sql
SELECT client_addr, state, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

**On the replica itself**, check how far behind it is:
```sql
SELECT pg_last_wal_receive_lsn() AS last_received,
       pg_last_wal_replay_lsn() AS last_replayed;
```

If `replay_lag` is consistently under your freshness threshold (e.g., 5-10 seconds for analytics aggregations), federation from the replica is safe. If it spikes to minutes, Trino queries return stale data for the entire lag window.

### 4. When Read Replica Federation Is Appropriate (and When It Isn't)

**Use the replica for:**
- Analytical aggregations where minutes-level freshness is acceptable
- Joins of a small Postgres dimension table to a large Iceberg fact table
- Any query where a few seconds of staleness doesn't affect the business decision

**Stick with the primary when:**
- You need strict real-time data (sub-second freshness)
- Users expect T+0 data in dashboards
- Your query logic depends on perfectly synchronized reads

**The general rule:** Federation against a read replica is correct for analytics and reporting workloads. It's explicitly recommended — Trino's JDBC connection creates read load on Postgres, and that load belongs on a replica, not the primary.

### 5. Schema Caching and Replica Interaction

With the default `metadata.cache-ttl=0s` (caching disabled), Trino fetches schema metadata fresh from the replica on every query. If a new column appears on the primary and replicates within seconds, Trino sees it on the next query.

If you configure a higher TTL (e.g., `60s`) to reduce planner overhead, Trino holds a cached schema for up to 60 seconds. In theory, if the replica lags behind by more than the cache TTL, Trino could serve a schema from a version that's older than what it would see fresh. This is a rare edge case for schema changes but worth knowing if you tune the cache TTL.

### Summary

| Concern | Answer |
|---|---|
| Config change | Update `connection-url` to replica host — nothing else changes |
| Replication lag detection | Trino has none — monitor `pg_stat_replication` on the primary yourself |
| When to use replica | Analytics, aggregations, freshness tolerance in minutes |
| When to use primary | Freshness-critical queries, strict consistency |
| Schema caching | Default TTL=0s, so replica schema is fetched fresh — no extra risk |
