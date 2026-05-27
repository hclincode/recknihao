# Iter288 Q2 — Federate vs Ingest: 5M-Row Slowly-Updating Postgres Table

## Answer

At 5M rows joined dozens of times per day, you're above the comfortable live-federation threshold. The right move is to ingest into Iceberg and keep it in sync incrementally.

## Why federation stops scaling here

Three structural costs hit you simultaneously at this scale and frequency:

1. **Single-threaded JDBC scan**: The PostgreSQL connector in OSS Trino 467 reads via a single JDBC connection (no parallel splits). Every join pulls 5M rows over one thread — no matter how many Trino workers you have.

2. **Replica load**: Dozens of full-table reads per day is significant sustained I/O on your read replica. If analytical queries and app OLTP traffic spike together, the replica falls behind.

3. **No pre-computation**: Every join re-reads 5M rows from scratch. There's no caching or pre-joined state. Dynamic filtering helps prune Iceberg files, but it doesn't reduce the Postgres read.

**5M rows is in the federate/ingest gray zone** (comfortable federation is roughly under 1-2M rows at low frequency; ingest is clearly right above 10-20M or when query frequency is high). At your combination of size *and* frequency (dozens per day), ingest is the right call.

## Initial load into Iceberg

```python
# Spark job — one-time initial load
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("accounts-initial-load").getOrCreate()

PG_URL = "jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb"
PG_PROPS = {"user": "trino_reader", "password": "<secret>", "driver": "org.postgresql.Driver"}

df = spark.read.jdbc(url=PG_URL, table="public.accounts", properties=PG_PROPS)
df.writeTo("iceberg.analytics.accounts").using("iceberg").createOrReplace()

spark.stop()
```

## Keeping it in sync: incremental MERGE INTO

Since the table updates every few hours, use a watermark on `updated_at` to sync only changed rows — no full rewrites:

```python
from datetime import date, timedelta
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("accounts-incremental-sync").getOrCreate()

PG_URL = "jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb"
PG_PROPS = {"user": "trino_reader", "password": "<secret>", "driver": "org.postgresql.Driver"}

# Look back 2 days as a lag buffer (catches late-arriving updates and replica lag)
lookback = (date.today() - timedelta(days=2)).isoformat()

changed = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM public.accounts WHERE updated_at > '{lookback}') t",
    properties=PG_PROPS,
)

changed.createOrReplaceTempView("accounts_delta")

spark.sql("""
    MERGE INTO iceberg.analytics.accounts tgt
    USING accounts_delta src ON tgt.account_id = src.account_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

spark.stop()
```

**Why the 2-day lookback (not just "since yesterday")**: the lag buffer absorbs Postgres replica lag, delayed background job writes, and Spark job timing drift. Re-processing the same rows is safe because MERGE INTO is idempotent — updating an unchanged row is a no-op.

## Prerequisites on the Postgres side

Your `accounts` table needs an `updated_at` column that apps maintain:

```sql
-- Add updated_at if missing
ALTER TABLE accounts ADD COLUMN updated_at TIMESTAMPTZ DEFAULT now();
UPDATE accounts SET updated_at = now();  -- seed existing rows

-- Trigger to maintain it automatically
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;

CREATE TRIGGER accounts_updated_at
BEFORE INSERT OR UPDATE ON accounts
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

## Maintenance after ingesting

Schedule alongside your sync job:

```sql
-- Nightly compaction (after sync completes)
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.accounts',
  options => map('target-file-size-bytes', '268435456')
);

-- Weekly snapshot expiry
CALL iceberg.system.expire_snapshots(
  table => 'analytics.accounts',
  older_than => current_timestamp - INTERVAL '7' DAY,
  retain_last => 5
);
```

## Update your join queries

```sql
-- Before (federates from Postgres every time)
SELECT e.*, a.plan_tier
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id;

-- After (both sides in Iceberg — fast, parallel, no Postgres touch)
SELECT e.*, a.plan_tier
FROM iceberg.analytics.events e
JOIN iceberg.analytics.accounts a ON e.account_id = a.id;
```

## Decision summary

| Factor | Your situation | Verdict |
|---|---|---|
| Table size | 5M rows | Gray zone — leans toward ingest |
| Query frequency | Dozens/day | Well above federation comfort zone |
| Update cadence | Every few hours | Compatible with hourly or nightly sync |
| Staleness tolerance | Hours acceptable | Incremental sync with lag buffer covers this |
| Postgres replica load | Currently high | Ingest eliminates it entirely |

At 5M rows + dozens of daily joins, ingest with incremental sync is the right call. Start with a full nightly refresh (simplest), then switch to the MERGE pattern once stable.
