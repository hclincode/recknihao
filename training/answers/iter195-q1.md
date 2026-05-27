# Iter 195 Q1 — Cross-Catalog Iceberg + Postgres Join in Trino

## Answer

## Can Trino query Postgres directly and join against Iceberg in the same query?

Yes, Trino can absolutely do this. It's called **federation**, and it's one of Trino's most powerful features. You can write a single SQL statement that JOINs your live Postgres data against your Iceberg event data — exactly as you describe.

Here's what a real query looks like:

```sql
SELECT 
  e.event_id,
  e.event_time,
  e.user_id,
  a.account_id,
  a.account_name,
  a.plan_tier
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

In this query:
- `iceberg.analytics.events` is your event table in Iceberg on MinIO (queried via Trino's Iceberg connector)
- `app_pg.public.accounts` is your accounts table in Postgres (queried via Trino's PostgreSQL connector)
- Both are catalogs registered in Trino — you set them up once in the coordinator config, and then you can join them like this

---

## What actually happens under the hood

**Trino does NOT pull all rows from both sides into memory and join them there.** Instead:

1. **Predicate pushdown on the Postgres side**: Trino pushes down the WHERE clause and join conditions into Postgres. Postgres executes the portion of the query it can understand natively and returns only the filtered result set — not the entire accounts table.

2. **Iceberg partition pruning**: The Iceberg side uses partition pruning to skip files that don't match the WHERE clause.

3. **The actual join happens on Trino workers**: Once both sides have been filtered down, the join execution happens in Trino's distributed query engine across your workers. For a 200K accounts table and a 300M event table, this is typically a small join — the accounts table is **broadcast** to every worker (since it's small), and each worker streams its local slice of the events through the join.

**In your case (200K accounts, hundreds of millions of events):** The query is practically optimal because the accounts table is tiny. Trino broadcasts it once and each worker joins its local partition of the events against the full accounts table in memory. Total network traffic: minimal.

---

## What happens to performance

**Best case (typical):** The Postgres predicate pushdown works, Postgres quickly returns the matching rows, and the Trino-side join completes in seconds. For 200K rows, even a full table pull is only a few MB — fast.

**The real risk:** It's not on the accounts side — it's if your event-side WHERE clause fails to push down to Iceberg properly, or if partition pruning breaks. Then Trino scans hundreds of millions of rows from Iceberg on every query. Adding Postgres to the join doesn't make that worse.

---

## When to keep doing the nightly ingest instead

| Scenario | Keep nightly ingest | Use live federation |
|---|---|---|
| Customers want account changes within a few hours | Federation makes sense | Yes |
| Very high query volume (100+ QPS hitting accounts) | Federation = JDBC connections per query, connection exhaustion risk | Nightly ingest is safer |
| Low query volume but need real-time account state | Federation is fine | Yes |
| Hundreds of UPDATE/DELETE per minute, need all visible | Nightly ingest lags; federation sees live state | Federation |
| Storage cost is a constraint | Federation saves storage | Yes |

**Hidden gotchas with federation:**

1. **OSS Trino 467 has NO connection pooling on the PostgreSQL connector.** Every concurrent query touching Postgres opens a fresh JDBC connection. 50 concurrent dashboards = 50 connections. **Mitigations**: run Postgres role-level `CONNECTION LIMIT`; put PgBouncer in front; use Trino resource groups to cap concurrent federation queries; set `statement_timeout` aggressively on the replica.

2. **Replica lag is your freshness ceiling.** If your read replica is 5 minutes behind the primary, your "live" accounts data is 5 minutes stale. For in-app dashboards where customers just upgraded their plan, 5 minutes is often unacceptable.

3. **Network hops add latency.** Every query pays the Trino→Postgres round-trip cost. At high query volume (hundreds of QPS), those milliseconds add up. Pre-joining in Iceberg eliminates this per-query cost.

---

## The practical recommendation

**If customers want real-time account changes:**
1. **Keep the nightly ingest of accounts into Iceberg** as your baseline. Simple, predictable, zero operational overhead.
2. **For dashboards that need fresher account state**, use federation queries for those specific dashboards only — not every query.
3. **Do NOT try to replace the nightly ingest entirely** with live federation across all queries. The connection-pooling issue will bite you at scale.

**If you do go the federation route:**
- Enable `catalog.management=dynamic` so you can rotate Postgres credentials without restarting Trino
- Add PgBouncer in transaction-pooling mode in front of the Postgres replica
- Monitor Postgres connection usage — alert on `pg_stat_activity` count
- Test at your expected peak concurrency before going to production
- Keep the nightly ingest as a fallback

**The true answer to "when to ditch nightly ingest":** Only when your query volume is low enough that Postgres connection saturation isn't a risk, AND your replica lag is acceptable for your SLA, AND you've verified that Trino's predicate pushdown works correctly for your specific queries.
