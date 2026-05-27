# Iter136 Q1 — Answer

**Question**: "We have about 80 enterprise customers on our platform, and we're rolling out a new 'advanced segmentation' feature that only customers on our enterprise-plus tier are licensed to use. That means I need to add new columns to some of our shared Iceberg analytics tables — columns that should exist in the data physically, but that only certain tenants should ever be able to query. My question is: how do you actually manage a schema change like this in a multi-tenant setup where everyone's data is in the same table? Do I just add the columns to the shared Iceberg table and rely on something in Trino to block which tenants can see them? Or is there a different approach that doesn't require me to maintain a completely separate Iceberg table per customer tier? I'm also worried about what happens mid-migration — like, if I'm adding a column and half the tenant rows already have it populated and half don't, does that cause problems for queries in the meantime?"

---

## Short Answer: One Shared Table, OPA Column Masking, and Safe NULLs

**Adding columns to the shared Iceberg table is safe and cheap — it's a metadata-only operation.** The tricky part is controlling which tenants see the new columns at query time. You have two main options: (1) **OPA column masking** — one physical table, Trino/OPA hides columns from non-enterprise tenants at runtime, or (2) **view-per-tier** — one physical table, separate views expose different column sets to different tenant groups. The NULL-handling during migration is straightforward: Iceberg returns NULL for old rows on new columns automatically. You don't need to backfill historical data unless your dashboards immediately depend on non-NULL values.

---

## Step 1: Add the Column — Metadata-Only, Free, Safe

```sql
-- Trino 467 syntax. This is a metadata-only operation — no data files are rewritten.
ALTER TABLE iceberg.analytics.user_events
ADD COLUMN segmentation_advanced VARCHAR,
ADD COLUMN advanced_filters MAP<VARCHAR, VARCHAR>;
```

What Iceberg actually does:
- Assigns new column IDs to the new columns.
- Updates the table's metadata file (`metadata/v*.metadata.json`) on MinIO.
- Leaves all existing Parquet files **completely untouched**.
- When Trino reads an old file predating this change, it returns `NULL` for the new columns on every row.
- New data written after the `ALTER TABLE` includes the new columns with actual values.

**Cost:** nearly zero. No Spark job, no MinIO bandwidth, no downtime.

---

## What Happens Mid-Migration: NULL Is Expected, Not a Bug

After `ALTER TABLE ... ADD COLUMN`:
- **New rows** (written after the change): `segmentation_advanced` has values ('yes', 'no', etc.)
- **Old rows** (written before): `segmentation_advanced` returns `NULL` forever — unless you backfill

This coexistence is fine and expected:

```sql
-- Counts only new rows (old rows are NULL, excluded by WHERE)
SELECT COUNT(*) FROM user_events WHERE segmentation_advanced = 'yes';

-- Counts all old rows + any new rows explicitly set to NULL
SELECT COUNT(*) FROM user_events WHERE segmentation_advanced IS NULL;

-- Shows three groups: 'yes', 'no', and NULL (old rows)
SELECT segmentation_advanced, COUNT(*) FROM user_events GROUP BY 1;
```

No problems occur. **The only gotcha:** if a dashboard immediately starts filtering on `WHERE segmentation_advanced = 'yes'`, historical data will be excluded — it looks like no enterprise events ever happened. Backfill if that matters:

```sql
-- Spark SQL — backfill the new column for historical rows
MERGE INTO iceberg.analytics.user_events AS target
USING (
  SELECT event_id,
         CASE WHEN plan_type = 'enterprise' THEN 'yes' ELSE 'no' END AS segmentation_advanced
  FROM iceberg.analytics.user_events
  WHERE segmentation_advanced IS NULL
) AS source
ON target.event_id = source.event_id
WHEN MATCHED THEN UPDATE SET segmentation_advanced = source.segmentation_advanced;
```

---

## Controlling Column Visibility: Two Approaches

### Approach A: OPA Column Masking (Recommended)

When you configure OPA as Trino's authorization backend, OPA can return not just allow/deny but also **column-masking expressions** that Trino substitutes at query analysis time. Non-enterprise tenants get `NULL` (or another masked value) instead of the real column data.

**Flow for a non-enterprise tenant query:**
1. Tenant submits `SELECT event_id, segmentation_advanced FROM user_events`
2. Trino calls OPA: "can this principal read `segmentation_advanced`?"
3. OPA checks the tenant mapping (from the Trino username — e.g., `acme--svc` encodes tenant `acme`) and determines tenant tier
4. OPA returns: mask `segmentation_advanced` → `NULL`
5. Trino rewrites to: `SELECT event_id, NULL AS segmentation_advanced FROM user_events`
6. Tenant sees NULLs — not the real data, not an error

**Trino coordinator configuration:**
```properties
# etc/access-control.properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
```

> **Important:** Trino's OPA integration does NOT pass JWT claims to OPA. The `input.context.identity` object only contains `user` (the Trino username) and `groups`. To convey tenant ID to OPA, encode it in the username (e.g., `acme--svc` → parse `acme` from the prefix using `split(user, "--")[0]`) or use an OPA data bundle mapping (username → tenant_id lookup). The actual Rego rules live in your governance bundle per `prod_info.md`.

**Pros of OPA masking:**
- Single table, zero schema overhead — no views to maintain
- Dynamic — change the OPA policy bundle, effects take immediately on next query, no Trino restart
- Scales: adding a 3rd tier means one policy update, not another view per table

**Cons:**
- Policy bugs silently expose columns — requires CI assertions that non-enterprise tenants see NULLs
- OPA is an additional system to operate and monitor

### Approach B: View-Per-Tier (Simpler, Explicit)

Create separate views that expose different column sets:

```sql
-- Standard-tier view — no advanced columns
CREATE VIEW analytics.user_events_standard AS
SELECT event_id, user_id, event_name, occurred_at, plan_type, tenant_id
FROM iceberg.analytics.user_events;

-- Enterprise-plus view — includes advanced columns
CREATE VIEW analytics.user_events_enterprise AS
SELECT event_id, user_id, event_name, occurred_at, plan_type,
       segmentation_advanced, advanced_filters, tenant_id
FROM iceberg.analytics.user_events;
```

OPA policy (or SQL GRANT/REVOKE) then controls which principals can SELECT from which view, and denies all principals direct base-table access.

**Pros:** Self-documenting schema; simpler testing (just verify grants, not Rego rules); no OPA masking setup needed.

**Cons:** Every new tier means new views per table. Every base-table schema change (`ADD COLUMN`) requires updating the enterprise view. Scales poorly past 5–6 tiers and 20+ tables.

### Which to pick

| Situation | Recommendation |
|---|---|
| ≤3 tiers, stable schema, team unfamiliar with OPA | View-per-tier (simpler) |
| 80+ customers, frequent tier changes, 10+ tables | OPA column masking (scales) |
| Your stack: Trino 467 + OPA already in use | OPA column masking (consistent with existing auth model) |

**For your 80-customer, 2-tier setup with OPA already deployed:** use OPA column masking.

---

## Why NOT Tiered Tables (Separate Iceberg Table Per Tier)

You asked about "maintaining a completely separate Iceberg table per customer tier" — don't do this unless you have regulatory requirements (HIPAA-level isolation). The costs:

- **Ingestion complexity:** your Spark job must route each write to the right tier table. Mid-flight tier upgrades require careful handling.
- **Schema changes multiply:** `ADD COLUMN` on the base feature means updating 2+ tables.
- **Cross-tenant aggregations become `UNION ALL`** — slow and fragile.
- **Maintenance multiplies:** one `rewrite_data_files` job becomes N jobs, one `expire_snapshots` becomes N jobs.

The shared table + OPA masking approach gives you isolation without these operational costs.

---

## The SECURITY DEFINER Risk When Using Views

If you choose view-per-tier, Trino views default to **SECURITY DEFINER** mode: they execute with the view owner's privileges, not the caller's. This creates a single point of failure.

**If the view owner loses SELECT on the base table, every tenant view breaks simultaneously.**

Mitigate this:
1. Use a stable, dedicated service account as the view owner (e.g., `trino-view-owner@internal`) — never a rotation-prone individual account.
2. Add a synthetic monitoring query (`SELECT 1 FROM analytics.user_events_standard LIMIT 1`) that pages on-call if it fails with "Access Denied."
3. Protect the view owner's base-table grant in OPA policy with a separate, protected rule.

---

## Summary

1. **`ALTER TABLE ... ADD COLUMN` is safe and free** — metadata-only in Iceberg 1.5.2. Do it anytime.
2. **Old rows return NULL for new columns** — expected behavior. Backfill only if dashboards depend on non-NULL historical values.
3. **Control visibility via OPA column masking** (recommended for your setup) or view-per-tier (simpler for small tier counts).
4. **Keep one shared table** — tiered tables multiply operational burden without proportional isolation benefit at 80-customer scale.
5. **Test the access-control layer with CI assertions** — verify non-enterprise tenants see NULLs (masking) or "Access Denied" (view-tier approach) for the sensitive columns.
