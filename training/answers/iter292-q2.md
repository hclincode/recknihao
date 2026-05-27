# Iter292 Q2 — Is HAVING Slower Than WHERE in Trino?

## Short answer

Yes — HAVING runs after aggregation, WHERE runs before. But your specific query (`HAVING COUNT(*) > 1000`) is **already the right pattern**. You cannot push a filter on an aggregate into WHERE. HAVING is mandatory here, not a mistake.

## The rule

| Filter type | Use | Why |
|---|---|---|
| Condition on a raw column | `WHERE` | Filters rows before aggregation — cheap |
| Condition on an aggregate (COUNT, SUM, AVG...) | `HAVING` | Must run after aggregation — no alternative |

## The trap (the slow HAVING pattern)

The warning you heard applies to filtering on non-aggregate columns in HAVING:

```sql
-- BAD: aggregates ALL events, then discards groups by tenant_id
SELECT tenant_id, COUNT(*) AS c
FROM events
GROUP BY tenant_id
HAVING tenant_id IN ('acme', 'globex');

-- GOOD: filters to matching tenants before aggregation
SELECT tenant_id, COUNT(*) AS c
FROM events
WHERE tenant_id IN ('acme', 'globex')
  AND event_date >= DATE '2026-05-20'  -- partition column
GROUP BY tenant_id;
```

In the bad version, Trino aggregates every tenant in the entire table, then discards all but 2. In the good version, Trino reads only the matching tenant's events before grouping.

## Your query is correct

```sql
SELECT tenant_id, COUNT(*) AS event_count
FROM events
WHERE event_date >= DATE '2026-05-20'   -- partition filter: prunes to 1 week
GROUP BY tenant_id
HAVING COUNT(*) > 1000;                 -- aggregate filter: mandatory here
```

This is the right form:
1. `WHERE event_date >= DATE '2026-05-20'` filters to one week before aggregation (partition pruning + row filtering)
2. `HAVING COUNT(*) > 1000` filters on the count after aggregation — the only valid location for this

There is no faster alternative. `COUNT(*) > 1000` has no rows to filter until after grouping is complete.

## If the query still feels slow

The issue isn't HAVING vs WHERE. Run:

```sql
EXPLAIN ANALYZE
SELECT tenant_id, COUNT(*) AS event_count
FROM events
WHERE event_date >= DATE '2026-05-20'
GROUP BY tenant_id
HAVING COUNT(*) > 1000;
```

Check `Physical Input: X GB`. If it's much larger than one week of data, your partition filter isn't working — check that `event_date` is the partition column and the predicate is in the right form (see the partition pruning guide).

## Summary

- HAVING on a non-aggregate = slow (move the filter to WHERE)
- HAVING on COUNT/SUM/AVG = correct, no alternative
- Your query is right — if it's slow, look at Physical Input and partition pruning, not HAVING
