# Iter93 Q2 — Answer

**Question**: Our Debezium slot is falling behind even when low-traffic tables have no changes. What are heartbeat events and how do we configure them?

---

## Answer

## The problem: replication slot lag on quiet tables

When you set up Debezium, it uses a **replication slot** — Postgres's way of bookmarking "how far has Debezium read into the transaction log?" The slot advances each time Debezium reads and confirms a change event.

On low-traffic tables (permissions, plans, feature flags, roles), nothing changes for hours. Without any data flowing, the slot's position never advances. Postgres keeps every WAL file from where the slot is stuck forward. Your `bytes_behind` metric ticks upward and alerts fire — even though your pipeline is perfectly healthy.

Worse: if the lag grows large enough, Postgres may **auto-invalidate the slot** (`wal_status = 'lost'`), and Debezium loses track of where it was. You'd need to rebuild from scratch.

## The solution: heartbeat events

Debezium can write a synthetic "heartbeat" — a single INSERT row into a special table you create — every 30 seconds. That INSERT is a real Postgres transaction that flows through the WAL. When Debezium reads and confirms it, the slot advances, Postgres releases old WAL segments, and your slot-lag metric stays near zero.

The heartbeat carries no business data. Your Spark consumer filters it out before it reaches the MERGE INTO logic.

## Configuration

Add two properties to your Debezium connector config:

```json
{
  "heartbeat.interval.ms": "30000",
  "heartbeat.action.query": "INSERT INTO public.debezium_heartbeat (heartbeat_at) VALUES (now()) ON CONFLICT DO NOTHING"
}
```

- **`heartbeat.interval.ms: 30000`** — write a heartbeat every 30 seconds. Default is `0` (disabled). 30 seconds keeps alerts happy with negligible overhead.
- **`heartbeat.action.query`** — the SQL Debezium runs at each heartbeat tick. `ON CONFLICT DO NOTHING` prevents the heartbeat table from growing indefinitely.

## Setup required in Postgres

**Create the heartbeat table first:**

```sql
CREATE TABLE IF NOT EXISTS public.debezium_heartbeat (
  id SERIAL PRIMARY KEY,
  heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Grant the Debezium user write access:
GRANT SELECT, INSERT, UPDATE ON public.debezium_heartbeat TO debezium_user;
GRANT USAGE, SELECT ON SEQUENCE public.debezium_heartbeat_id_seq TO debezium_user;
```

**Add the heartbeat table to your publication:**

```sql
ALTER PUBLICATION debezium_pub ADD TABLE public.debezium_heartbeat;
```

This step is critical. If you skip it, the heartbeat INSERT writes to Postgres but Postgres's logical decoder won't see it — so the slot won't advance and you're back where you started.

## Filter heartbeats in your Spark consumer

Heartbeats are infrastructure events, not business data. Filter them before MERGE INTO:

```python
# Drop heartbeat events before they hit your Iceberg MERGE INTO
df = df.filter(~col("topic").like("%.debezium_heartbeat"))
```

The Kafka topic follows the pattern `<topic.prefix>.<schema>.<table>`. If your `topic.prefix` is `app-db`, the heartbeat topic is `app-db.public.debezium_heartbeat`. If you subscribe to specific topics by name, just don't include the heartbeat topic.

## When to enable

Enable heartbeats for almost every production CDC pipeline. The rule: if any table in your publication goes more than an hour without changes, turn them on.

For a SaaS app, that covers:
- Permissions and roles (rarely change)
- Plans and pricing tiers (updated weekly)
- Feature flags (touched once a month)
- Tenants and subscriptions in low-churn B2B setups

Even busy publications go quiet during nights and weekends. The cost is one tiny INSERT every 30 seconds — negligible. The benefit is no false slot-lag alerts and no accidental slot invalidation.
