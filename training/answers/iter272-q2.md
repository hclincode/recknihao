# Iter272 Q2 — Dynamic Filtering: Why Your Iceberg+Postgres Join Scans Too Much

## Answer

Your intuition is correct — Trino is likely reading the entire Postgres table unless dynamic filtering is actively working. This is one of the most important patterns in federated queries, and the fix is usually simple once you know what to look for.

### What Is Dynamic Filtering?

Dynamic filtering (DF) is the mechanism where Trino collects join-key values from the **smaller table** (build side) and pushes a runtime predicate to the **larger table** (probe side) before scanning it.

In your case:
1. Trino scans the Postgres lookup table (5,000 rows) → collects all `user_id` values
2. Trino derives a runtime IN-list: `user_id IN (id1, id2, ..., id5000)`
3. Trino pushes this IN-list to the Iceberg scan — Iceberg uses per-file min/max stats to skip files that can't contain any of those 5,000 values
4. Result: Iceberg scans a fraction of the 200M rows instead of all rows that match the date/tenant filter

Without DF, Iceberg scans all 50,000 matching rows, then the join filter runs in memory. With DF, many Iceberg files are skipped entirely before scanning.

### Critical: Which Join Types Enable Dynamic Filtering?

| Join type | DF enabled? |
|---|---|
| `INNER JOIN` | **YES** |
| `RIGHT OUTER JOIN` | **YES** |
| `LEFT OUTER JOIN` | **NO** |
| `FULL OUTER JOIN` | **NO** |

**If your query uses LEFT OUTER JOIN, DF is disabled.** This is the most common cause of the pattern you're describing.

```sql
-- DF works — INNER JOIN
SELECT e.event_id, a.account_name
FROM iceberg.analytics.events e
INNER JOIN app_pg.public.accounts a ON e.user_id = a.account_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND a.tenant_id = 'acme';

-- DF DOES NOT work — LEFT OUTER disables it
SELECT e.event_id, a.account_name
FROM iceberg.analytics.events e
LEFT OUTER JOIN app_pg.public.accounts a ON e.user_id = a.account_id  -- no DF
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

If you truly need all events including those without account matches, consider restructuring: run the INNER JOIN for the matched case and UNION ALL with a NOT EXISTS query for the unmatched case, or accept the full scan for that specific query.

### The Wait-Timeout Problem

Trino has a deadline for how long the Iceberg scan will wait for the Postgres build side to finish before giving up on DF and scanning everything. The **Iceberg catalog default is 1 second** (`iceberg.dynamic-filtering.wait-timeout`).

**If your Postgres scan takes longer than 1 second**, Iceberg gives up waiting and scans the full table without the IN-list. The join still produces correct results — just slowly.

Fix: increase the timeout for your session or catalog:

```sql
-- Session-level (no restart required)
SET SESSION iceberg.dynamic_filtering_wait_timeout = '10s';

-- Then run your join query — Iceberg will now wait up to 10 seconds for the DF predicate
```

This is the **most-overlooked production fix** for "DF enabled but join still slow."

### Verify DF Is Actually Working: EXPLAIN ANALYZE

```sql
EXPLAIN ANALYZE VERBOSE
SELECT e.event_id, a.account_name
FROM iceberg.analytics.events e
INNER JOIN app_pg.public.accounts a ON e.user_id = a.account_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND a.tenant_id = 'acme';
```

Look for `DynamicFilter` in the Iceberg scan section:

```
Fragment [SOURCE]
  ScanFilterProject[table=iceberg:analytics.events$data]
    DynamicFilter[column=user_id, IN list with 5000 values from build side]
      Input: X rows, Physical Input: Y GB
```

**DynamicFilter present** → DF is active, Iceberg is using the IN-list.
**DynamicFilter absent** → DF is disabled or blocked; check join type, column types, and session settings.

Also check:
```sql
-- Check if DF is disabled at session level
SHOW SESSION LIKE '%dynamic%';

-- Re-enable if someone turned it off
SET SESSION enable_dynamic_filtering = true;
```

### Full Working Example

```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '10s';

SELECT
  e.event_id,
  e.event_time,
  a.account_name,
  a.account_tier
FROM iceberg.analytics.events e
INNER JOIN app_pg.public.accounts a
  ON e.account_id = a.account_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '90' DAY
  AND a.tenant_id = 'acme'
ORDER BY e.event_time DESC;
```

What happens with DF active:
1. Postgres scans `accounts` filtered to `tenant_id = 'acme'` → 5,000 rows
2. Trino collects all `account_id` values from those 5,000 rows
3. Trino pushes `account_id IN (val1, ..., val5000)` to the Iceberg scan
4. Iceberg skips files where min/max range doesn't overlap the 5,000 values
5. Iceberg scans only a fraction of the 200M rows → result in seconds

### Three-Step Diagnostic

1. **Check join type** — use `INNER JOIN` or `RIGHT OUTER JOIN`, not `LEFT` or `FULL`
2. **Increase the wait-timeout** — `SET SESSION iceberg.dynamic_filtering_wait_timeout = '10s'` (default 1s is often too short)
3. **Run `EXPLAIN ANALYZE VERBOSE`** — confirm `DynamicFilter` appears in the Iceberg scan; if absent, DF is blocked

Make sure the Postgres side (`a.tenant_id = 'acme'`) also has a proper index — if the build side is slow to return its 5,000 rows, even a 10s timeout may not be enough.
