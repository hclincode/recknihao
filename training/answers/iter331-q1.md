# Answer to Q1: Setting history.expire.* Properties — Spark Required, Not Trino (Iter 331)

You're right that you got an error from Trino. Those two properties — `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` — are **Iceberg table-level properties**, not Trino connector properties, so you need **Spark SQL**, not Trino.

## Why Trino Errors Out

Trino 467's `ALTER TABLE ... SET PROPERTIES` only accepts **connector-level Iceberg properties** like `partitioning`, `format`, `sorted_by`, and `format_version`. It does not pass through the underlying Iceberg table-level properties — which is where `history.expire.*` lives. Trino rejects these because it doesn't recognize them as connector properties.

## How to Set Them (Spark SQL)

Use **Spark SQL** with `SET TBLPROPERTIES`:

```sql
-- Run from spark-sql CLI or spark.sql(...) in a Spark job
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep' = '5',
    'history.expire.max-snapshot-age-ms'   = '2592000000'  -- 30 days in milliseconds
);
```

After setting from Spark, verify from Trino:

```sql
-- Verify from Trino (read-only check)
SELECT * FROM iceberg.analytics."events$properties"
WHERE key IN ('history.expire.min-snapshots-to-keep', 'history.expire.max-snapshot-age-ms');
```

## What These Properties Do

They act as a **safety floor** that `expire_snapshots` cannot violate regardless of arguments passed:

- `history.expire.min-snapshots-to-keep` — always keeps at least N of the most recent snapshots, even if they're old
- `history.expire.max-snapshot-age-ms` — protects snapshots younger than this age from being expired, even if someone passes a shorter retention window

This is a defense-in-depth pattern: table-level properties are **sticky and durable**, whereas per-call arguments are one-off overrides. Once set, they enforce a minimum retention floor automatically every time snapshot expiry runs — regardless of which engine runs it.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
