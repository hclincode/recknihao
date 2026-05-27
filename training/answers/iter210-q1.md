# Iter 210 Q1 — Broadcast Join Threshold: join_max_broadcast_table_size and EXPLAIN Verification

## Answer

### The exact session property name and default value

**Session property name:** `join_max_broadcast_table_size`

**Default value:** `100MB`

This is the **operative tuning knob** that controls when Trino's cost-based optimizer (CBO) switches from broadcasting a smaller table to every worker versus hash-shuffling both sides of the join.

**Do not confuse this with `query.max-memory-per-node`.** That property is a per-node memory cap for any single query (cluster-wide governance). Raising it does not change the join distribution decision — it just lets queries use more memory before being killed.

---

### How to raise the threshold per-query

Use `SET SESSION` before your query:

```sql
SET SESSION join_max_broadcast_table_size = '200MB';
-- Now run your cross-catalog join
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t ON e.tenant_id = t.id;
```

For your 60MB `tenants` table, the default 100MB threshold should already favor broadcast. However, as the table grows to ~150MB, you would raise it to `200MB` or higher to keep broadcasting in effect.

**Cluster-wide (in `etc/config.properties`):**

```
join-max-broadcast-table-size=200MB
```

---

### Relationship to `join_distribution_type`

- **`SET SESSION join_distribution_type = 'AUTOMATIC'`** (default): The CBO uses `join_max_broadcast_table_size` as the cutoff. If the **estimated** build-side size is below the threshold, broadcast is chosen; above it, partitioned.
- **`SET SESSION join_distribution_type = 'BROADCAST'`**: Forces broadcast regardless of the threshold.
- **`SET SESSION join_distribution_type = 'PARTITIONED'`**: Forces a hash-shuffle join regardless of build size.

---

### What AUTOMATIC does when statistics are missing

**When `AUTOMATIC` has no table statistics**, the CBO cannot estimate the build-side size. In that case, Trino defaults to **hash-distributed (PARTITIONED) joins** — not arbitrary heuristics. This is the most common reason a join you expected to be broadcast turns out partitioned. Check whether stats are populated before raising the threshold.

---

### How to verify in EXPLAIN output

Run `EXPLAIN (TYPE DISTRIBUTED)` on your query. Look for the **Exchange operator above the join** — not a label on the Join node itself. (`Join[BROADCAST]` / `Join[PARTITIONED]` notation in blog posts does not exist in real Trino output.)

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t ON e.tenant_id = t.id;
```

In the output:

- **`Exchange[Type=REPLICATE]`** or **`Distribution: REPLICATED`** → broadcast join — the build side (tenants) was sent to every worker. ✓
- **`Exchange[Type=REPARTITION]`** or **`Distribution: PARTITIONED`** → hash-partitioned join — both sides are being shuffled on the join key.

If you see `REPARTITION` when you expected `REPLICATE`, the CBO either estimated the build side exceeding `join_max_broadcast_table_size`, or statistics are missing.

---

### Verifying with SHOW STATS

Statistics directly influence the CBO's size estimate. Before raising the threshold, ensure the CBO has accurate stats:

**For Postgres side** (stats come from Postgres's `pg_stats`, populated by `ANALYZE` on the Postgres server):

```sql
SHOW STATS FOR app_pg.public.tenants;
```

Expected: `row_count`, `distinct_values_count`, and `nulls_fraction` are populated (not NULL). If they're NULL, run `ANALYZE public.tenants;` on the Postgres read replica.

**For Iceberg side** (stats come from Iceberg Puffin metadata files):

```sql
SHOW STATS FOR iceberg.analytics.events;
```

If missing, run:

```sql
ANALYZE TABLE iceberg.analytics.events WITH (columns = ARRAY['tenant_id', 'occurred_at']);
```

---

### Practical runbook entry

```
## Cross-Catalog Join Threshold — Runbook

Current tenants table size: ~60MB (300K rows)
Default threshold: join_max_broadcast_table_size = 100MB  → broadcast expected

If join performance drops as tenants grows:
1. Run EXPLAIN (TYPE DISTRIBUTED) and look for Exchange[Type=REPARTITION] on the tenants side
2. Check statistics: SHOW STATS FOR app_pg.public.tenants
3. If stats missing: ANALYZE public.tenants; (on the Postgres server)
4. If stats present but still REPARTITION: raise threshold:
   SET SESSION join_max_broadcast_table_size = '200MB';
5. Cluster-wide fix: add join-max-broadcast-table-size=200MB to etc/config.properties
```
