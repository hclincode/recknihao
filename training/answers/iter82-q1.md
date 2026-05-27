# Iter82 Q1 — Answer

**Question**: Retention cohort analysis — "how many users who signed up in week N are still logging in 4 weeks later?" on a shared Iceberg table partitioned by event date, across hundreds of tenants. Will it be efficient? How to write the SQL?

---

## Answer

**Yes, this query pattern works efficiently on a shared Iceberg table — if you structure it right.** The key is understanding how Iceberg's **partition pruning** protects you from scanning the entire table, even with a multi-week join.

---

### The core pattern: two-step cohort join

Your intuition is correct: you're joining sign-up events from week N against activity events from week N+4. Here's the practical SQL:

```sql
WITH signups_week_0 AS (
  SELECT user_id, tenant_id, MIN(event_ts) AS signed_up_at
  FROM iceberg.analytics.events
  WHERE event_name = 'signup'
    AND event_ts >= TIMESTAMP '2026-05-01 00:00:00'
    AND event_ts <  TIMESTAMP '2026-05-08 00:00:00'  -- week 0
  GROUP BY user_id, tenant_id
),
week_4_activity AS (
  SELECT DISTINCT user_id, tenant_id
  FROM iceberg.analytics.events
  WHERE event_ts >= TIMESTAMP '2026-05-29 00:00:00'
    AND event_ts <  TIMESTAMP '2026-06-05 00:00:00'  -- week 4 (4 weeks later)
)
SELECT
  s.tenant_id,
  COUNT(*) AS signed_up_week_0,
  COUNT(a.user_id) AS still_active_week_4,
  ROUND(100.0 * COUNT(a.user_id) / COUNT(*), 1) AS retention_pct
FROM signups_week_0 s
LEFT JOIN week_4_activity a
  ON s.user_id = a.user_id
  AND s.tenant_id = a.tenant_id
GROUP BY s.tenant_id
ORDER BY retention_pct DESC;
```

This does not blow up because of **partition pruning**. Here's why:

---

### How partition pruning makes this efficient

If your table is partitioned by `(day(event_ts), tenant_id)` — the recommended layout for multi-tenant SaaS — Iceberg's partition pruning works independently on each `WHERE` filter. When you write:

```sql
WHERE event_ts >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_ts <  TIMESTAMP '2026-05-08 00:00:00'
  AND tenant_id = 'customer_x'
```

Iceberg translates the `event_ts` predicate into "read only the day partitions from May 1–7" and the `tenant_id` predicate into "within those days, read only customer_x's files." The result: **you read roughly 7 days × 1 tenant = a tiny slice of the table.**

The join itself is then fast because:
1. The `signups_week_0` CTE scans only week 0 (7 days) for the target tenant — very small.
2. The `week_4_activity` CTE scans only week 4 for that same tenant — also small.
3. The JOIN is a user-by-user match on the same tenant, which is a cheap memory-resident lookup.

**The multi-week gap between week 0 and week 4 does not force you to scan the weeks in between.** Partition pruning skips them entirely.

---

### Why this works at scale: multi-tenant benefits

With hundreds of customers in one table, you're actually *safer* than a single-tenant setup:

- **Partition pruning by tenant_id is very selective.** Each query touches only one or a few tenants' files, not all tenants' files.
- **The join window is small.** You're not joining "all events from Jan" against "all events from Feb" — you're joining a specific week for a specific tenant.
- **Partition metadata is lean.** Iceberg stores partition statistics (min/max event_ts per file), so even before opening a file, the coordinator knows which partitions can match your date range.

If you had 100 tenants × 52 weeks of data = 5,200 potential day partitions in a year, a single-tenant retention query still reads only ~2 partitions (week 0 and week 4 for that tenant). The other 5,198 partitions are skipped at the metadata level — Trino never opens their files.

---

### Watch out for two gotchas

1. **Don't filter on tenant_id only in the application layer.** If your SQL builder concatenates `WHERE tenant_id = ?` at the application level and a junior engineer forgets it once, all customers' data leaks into the result. Instead, use Trino **views** with the tenant filter baked in, or ensure your OPA policy enforces row-level access control. The partition pruning is an optimization, not a security boundary.

2. **If your query joins event_name columns, add those filters too.** Writing:
   ```sql
   WHERE event_ts >= ... AND tenant_id = 'acme'
   ```
   is fast because partitions prune. Writing:
   ```sql
   WHERE tenant_id = 'acme'
   ```
   without an event_ts range will scan all of acme's files for all time — fine for small tenants, slow for big ones. Always include time filters on fact tables.

---

### Real-world example: 80 tenants, 6 months of data

- Table size: ~5 TB (across all tenants).
- Partition spec: `(day(event_ts), tenant_id)`.
- One retention query for tenant_x (week 0 and week 4): scans roughly 2 days × that tenant's proportion of data = ~20 GB.
- Query time: 5–15 seconds (dominated by the LEFT JOIN, not the table scan).
- Cluster cost: minimal, because Trino only powers a handful of worker nodes for such a small scan.

Run the same query for 10 tenants in parallel (separate queries, not one big UNION) and you touch 20 different day partitions across 10 tenant slices — still manageable.

---

### Summary

This pattern is exactly what Iceberg + Trino's partition pruning is designed for. You can confidently write retention queries against shared multi-tenant event tables without fear of full-table scans, provided you:

1. Partition by `(day(event_ts), tenant_id)` (or a similar time + tenant split).
2. Always filter on both event_ts (with a specific date range) and tenant_id in your WHERE clause.
3. Enforce tenant isolation at the query engine (Trino views + OPA) to prevent accidental cross-tenant leaks.

The multi-week join is not a performance issue — partition pruning handles it transparently.
