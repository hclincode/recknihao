# Iter101 Q1 — Answer

**Question**: We're adding tenant 201 to our platform today. We've been running this Iceberg setup for about six months with 200 existing tenants, and all their data is already partitioned by tenant_id and date. When tenant 201 starts sending events, do their rows just start flowing into the table and automatically get their own partition, or is there some kind of registration or setup step we need to do first? I'm nervous about whether the first queries against tenant 201's data will be slow or broken if we haven't "initialized" something for them.

---

## Answer

### The short answer

**Good news:** There is no "initialization" step for the Iceberg table itself. When your ingestion pipeline writes tenant 201's first event, Iceberg automatically creates the partition directory and writes files there — no pre-registration needed. Your first queries against tenant 201's data will not be slow or broken due to partition setup.

**What you DO need to set up:** Trino authorization (roles, views, grants) and optionally resource groups. Those are one-time setup tasks, separate from the table itself.

---

## Part (a): Does Iceberg auto-create partitions for new tenant_id values?

**Yes, completely automatic.** Iceberg's hidden partitioning means that when your Spark ingestion job writes the first row with `tenant_id = '201'`, Iceberg:

1. Recognizes `tenant_id = '201'` as a new partition value.
2. Creates the partition directory on MinIO (e.g., `s3a://lakehouse/warehouse/analytics/events/data/occurred_at_day=2026-05-25/tenant_id=201/`).
3. Writes the Parquet file(s) into that directory.
4. Updates the table's manifest metadata to include the new partition.

There is no `CREATE PARTITION` statement. There is no configuration change. The partition exists the moment the first byte lands.

---

## Part (b): Are there setup steps needed?

Yes, but they are **Trino authorization setup**, not Iceberg setup. These should happen before tenant 201 starts querying.

### Required steps:

**1. Create a Trino role for tenant 201**

```sql
CREATE ROLE tenant_201_role;
```

Note: Trino does NOT support `CREATE ROLE IF NOT EXISTS` — wrap in error handling at the application layer treating "already exists" as success.

**2. Assign the role to tenant 201's service account**

```sql
GRANT ROLE tenant_201_role TO USER "tenant-201-service-account";
```

**3. Create a tenant-scoped view**

```sql
CREATE VIEW tenant_201.events AS
  SELECT event_id, user_id, event_name, occurred_at, payload
  FROM analytics.events
  WHERE tenant_id = '201';
```

This is the security boundary. Tenant 201 only gets access to this view, never the base table.

**4. Grant SELECT on the view**

```sql
GRANT SELECT ON tenant_201.events TO ROLE tenant_201_role;
```

**5. Revoke base-table access**

```sql
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "tenant-201-service-account";
```

This closes the back door — the service account can reach events data only through the filtered view.

### Optional but recommended:

**6. Add tenant 201 to Trino resource groups**

Edit `etc/resource-groups.json` on the coordinator and add a selector for the new tenant. After editing, restart the Trino coordinator (file-based resource groups do not hot-reload).

**Critical:** resource group JSON is inert unless `etc/resource-groups.properties` exists separately on the coordinator with:

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

These lines go in `etc/resource-groups.properties` — NOT in `etc/config.properties`. Trino will start cleanly either way, but if placed in `config.properties` the resource group config is silently ignored.

---

## Part (c): Will first queries be slow or broken?

**No.** Once data lands in Iceberg and Trino auth is set up, queries run at normal speed:

1. **Partition pruning works from the first query:** Trino translates the view's `WHERE tenant_id = '201'` into a partition pruning directive — it skips all other tenants' files and reads only tenant 201's. Same benefit as your 200 existing tenants.

2. **No cold-start penalty:** The manifest files list the new partition immediately after write. No warmup needed.

**The only potential slowness:** if your shared table already has a general small-files problem (missing nightly compaction), all tenants — including tenant 201 — may be slow. That's a pre-existing maintenance issue, not a tenant-201 issue. Fix it by scheduling nightly `rewrite_data_files` if not already running.

---

## Part (d): Full onboarding checklist

**Before tenant 201's first event (optional):**
- [ ] Add tenant 201 to resource groups JSON and restart coordinator

**When data starts flowing (automatic):**
- [ ] Iceberg creates `tenant_id=201` partition — no action needed

**Immediately after data arrives (before tenant queries):**
- [ ] Run the 5 SQL steps: CREATE ROLE, GRANT ROLE, CREATE VIEW, GRANT SELECT on view, REVOKE base-table access

**Day 1 verification:**
```sql
-- As tenant 201's service account:
SELECT COUNT(*) FROM tenant_201.events;   -- must succeed
SELECT COUNT(*) FROM analytics.events;    -- must fail with Access Denied
```
If both succeed, OPA is not denying base-table access — check your OPA policy. If both fail, check view grants.

**Ongoing:**
- [ ] Nightly `rewrite_data_files` compaction already covers the shared table — tenant 201 benefits automatically.

---

## Summary

- **Partition auto-creation:** Yes, completely automatic. Write the first event, the partition exists.
- **First queries slow?** No, unless the shared table already has a compaction backlog.
- **Setup required?** Only Trino-side auth (role, view, grants) — one-time 5-minute setup. Do it before tenant 201 runs queries.
- **Resource groups?** Optional, good for fairness. Requires coordinator restart. Must be in `etc/resource-groups.properties`, not `etc/config.properties`.
- **Bottom line:** Tenant 201's data flows in and queries work without any Iceberg initialization. Handle Trino auth and they're live.
