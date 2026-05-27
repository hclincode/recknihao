# Iter87 Q1 — Answer

**Question**: 80 tenants, shared Iceberg table partitioned by tenant_id. 5-6 enterprise tenants at 10x data volume causing slow queries. Shared table model breaking down? Dedicated tables for large tenants? How to manage operational overhead?

---

## Answer

**Short answer:** Your shared Iceberg table is not fundamentally broken — it works fine for your ~75 small tenants. But for your 5-6 enterprise tenants at 10x volume, the shared model hits a real wall: **partition skew** tanks performance, and you end up in a constant operational firefight. A **tiered model** (small tenants on shared, large tenants on dedicated schemas) solves this cleanly and is operationally manageable at 6 enterprise tables.

---

### What "10x Data Volume" Actually Does

In your shared table with `partitioning = ARRAY['tenant_id', 'day(event_ts)']`, each day's data for each tenant goes into separate Parquet files grouped by tenant. So on a given day:
- Small tenant: 1 Parquet file, ~100M rows
- Enterprise tenant (Acme): 10 Parquet files, ~100M rows each (because Iceberg keeps individual files near 128–256 MB)

When Acme queries their own events, Trino correctly prunes to only Acme's files (skipping all 74 other tenants). That's working as designed. The problem is that Acme's own data spans 10 files per day. Multiplied over months of history, Acme's queries now open many more files than small-tenant queries, and each file open costs 10–50ms of overhead. The queries feel slow even though the partitioning is technically correct.

The operational trap: to keep Acme's queries fast, you need frequent compaction (rewrite_data_files) on the shared table. But when you compact the entire shared table, you're also rewriting all 75 small tenants' files — wasting compute on tenants who don't need it. Either you compact too often (CPU waste) or too seldom (Acme stays slow). There's no good setting.

---

### The Tiered Model: Small Tenants Shared, Large Tenants Dedicated

The industry-standard pattern for this scale mismatch:

- **Shared table** (`analytics.events`): holds all 74 small tenants. Zero-ops tenant onboarding — new small tenants just start writing to it.
- **Dedicated tables** (`analytics.acme_events`, etc.): one per enterprise tenant, partitioned only by `day(event_ts)` (no tenant_id partition column needed — there's only one tenant per table).

Benefits:
- Acme's queries hit a table where all Parquet files belong to Acme. After compaction, each day is one compact file. No per-file overhead stacking up.
- Maintenance runs on independent schedules: compact the shared table weekly; compact Acme's table nightly if their write volume warrants it.
- No more "compacting small tenants to fix Acme" waste.

---

### Keeping Operational Overhead Manageable: Templated Maintenance

**The key insight:** all 6 enterprise tables have the same schema and the same maintenance needs. You write one parameterized job that loops over 6 table names — not 6 separate jobs.

```bash
# Kubernetes CronJob (runs nightly)
for TENANT in acme beta charlie delta echo foxtrot; do
  spark-submit maintenance.sql --args "iceberg.analytics.${TENANT}_events"
done
```

Where `maintenance.sql` is:

```sql
CALL iceberg.system.rewrite_data_files(table => '${TENANT_TABLE}');
CALL iceberg.system.expire_snapshots(
  table       => '${TENANT_TABLE}',
  older_than  => current_timestamp() - INTERVAL '7' DAY,
  retain_last => 10
);
CALL iceberg.system.remove_orphan_files(
  table       => '${TENANT_TABLE}',
  older_than  => current_timestamp() - INTERVAL '1' DAY
);
```

When you add a 7th enterprise tenant, you add one name to the loop. That's the entire onboarding operation.

**Schema changes** across 6 tables: generate the DDL with a Python one-liner:

```python
for tenant in ['acme', 'beta', 'charlie', 'delta', 'echo', 'foxtrot']:
    print(f"ALTER TABLE iceberg.analytics.{tenant}_events ADD COLUMN new_col VARCHAR;")
```

Paste output into Trino, run. Done in under a minute. At 6 tenants this is trivial; at 60 it would be painful — but that's a future problem.

---

### Middle Ground: When NOT to Split

Avoid giving every tenant a dedicated table. The break-even is roughly 8–10 large tenants — beyond that, management overhead outweighs gains. The right model is **tiered by contract/volume tier**, not per-tenant:

| Tier | Example | Model |
|---|---|---|
| Free (60 tenants, ~10M events/day) | Most customers | Shared table |
| Standard (15 tenants, ~100M events/day) | Mid-market | Shared table (fits fine) |
| Enterprise (5 tenants, ~500M–1B events/day) | Acme, Beta... | Dedicated tables |

As Standard-tier tenants grow into Enterprise, migrate them: copy their partition to a dedicated table, update the Trino view to point at it, remove them from the shared table. The OPA row-filter or per-tenant view setup from your existing multi-tenant isolation carries over unchanged — just update the view's FROM clause.

---

### Concrete Next Steps For Your 80-Tenant Setup

1. **Identify your 5-6 enterprise tenants** (you probably already know — check query logs or contract tier).
2. **Create dedicated tables** for them in the same schema (`analytics.acme_events`, etc.).
3. **Migrate their data**: run `INSERT INTO analytics.acme_events SELECT * FROM analytics.events WHERE tenant_id = 'acme'` then delete from the shared table.
4. **Update Trino views/OPA**: point enterprise tenant views at their dedicated tables.
5. **Deploy templated maintenance** as a single Kubernetes CronJob with a loop.

Result: fast enterprise queries, zero-ops small-tenant onboarding, manageable maintenance via one parameterized job.
