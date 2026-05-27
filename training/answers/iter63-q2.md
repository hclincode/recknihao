# Iter63 Q2 — Answer

**Question**: I'm building a leaderboard for our customers — basically a "top tenants by event count over the last 30 days" table on our admin dashboard. I have the event data in Iceberg and I'm querying it through Trino. The query works but I'm getting weird results when two tenants have the same event count — they both end up showing as rank 3, and then the next one jumps straight to rank 5 instead of rank 4, which breaks our UI that expects sequential positions. Is this just how ranking works and I need to change my SQL, or is something else going on? What's the right function to use here?

---

## Answer

You're using `RANK()`, which is designed to produce gaps at ties. What you want for a sequential leaderboard is `DENSE_RANK()`. The fix is one word in your SQL.

### Why RANK() gives you gaps

`RANK()` assigns the same rank to all tied rows, then skips ahead by the number of ties. Two rows tied at position 3 means the next row gets position 5 — both rank 3 positions are "consumed."

```sql
-- What RANK() produces:
-- tenant_a: event_count=9500, rank=1
-- tenant_b: event_count=8200, rank=2
-- tenant_c: event_count=7100, rank=3  ← tied
-- tenant_d: event_count=7100, rank=3  ← tied
-- tenant_e: event_count=6800, rank=5  ← jumps! (positions 3 and 4 were consumed)
```

This is mathematically correct for sports-style ranking (Olympic medals: two silver medals means no bronze). But it breaks any UI that treats rank as a display position.

### What DENSE_RANK() does instead

`DENSE_RANK()` assigns the same rank to tied rows, but the next rank is sequential — no gaps.

```sql
-- What DENSE_RANK() produces:
-- tenant_a: event_count=9500, position=1
-- tenant_b: event_count=8200, position=2
-- tenant_c: event_count=7100, position=3  ← tied
-- tenant_d: event_count=7100, position=3  ← tied
-- tenant_e: event_count=6800, position=4  ← sequential, no gap
```

This is what a leaderboard with "sequential position" needs.

### The corrected query

```sql
SELECT
    tenant_id,
    event_count,
    DENSE_RANK() OVER (ORDER BY event_count DESC) AS position
FROM (
    SELECT
        tenant_id,
        COUNT(*) AS event_count
    FROM iceberg.analytics.events
    WHERE occurred_at >= NOW() - INTERVAL '30' DAY
    GROUP BY tenant_id
) t
ORDER BY position, tenant_id;
```

The `tenant_id` in the final `ORDER BY` breaks ties deterministically — two tenants at position 3 appear in alphabetical order every time the query runs, so the leaderboard doesn't shuffle between page loads.

### All three ranking functions compared

| Function | Behavior on ties | Result on [A=100, B=100, C=90] |
|---|---|---|
| `RANK()` | Same rank for ties; skips next ranks | 1, 1, 3 (no rank 2) |
| `DENSE_RANK()` | Same rank for ties; next rank is sequential | 1, 1, 2 |
| `ROW_NUMBER()` | Unique numbers; ties broken arbitrarily | 1, 2, 3 (or 2, 1, 3 — not stable) |

**Use RANK()** when ties have real competitive meaning and gaps are expected (e.g., "two silver medals means no bronze").

**Use DENSE_RANK()** when you need sequential display positions and want ties to share a slot without causing gaps downstream.

**Use ROW_NUMBER()** when you need exactly one row per position and don't care how ties are broken — useful for deduplication or taking the "first" record per group.

### Partitioned leaderboard (per event type)

If your dashboard needs a leaderboard within each event type, use `PARTITION BY`:

```sql
SELECT
    tenant_id,
    event_type,
    event_count,
    DENSE_RANK() OVER (
        PARTITION BY event_type
        ORDER BY event_count DESC
    ) AS position_within_type
FROM (
    SELECT
        tenant_id,
        event_type,
        COUNT(*) AS event_count
    FROM iceberg.analytics.events
    WHERE occurred_at >= NOW() - INTERVAL '30' DAY
    GROUP BY tenant_id, event_type
) t
ORDER BY event_type, position_within_type, tenant_id;
```

`PARTITION BY event_type` restarts the rank counter for each event type — so each type has its own position 1, 2, 3... independently.
