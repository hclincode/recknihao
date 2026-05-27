# Iter 186 Q1 — Postgres-to-Iceberg Write via Trino (INSERT INTO ... SELECT + JSONB Mapping)

## Answer

Yes, this is absolutely possible through Trino — you can write a single SQL statement that reads directly from your Postgres billing table and inserts the results into an Iceberg table in one shot. No file export/re-import needed.

### The mechanics: cross-catalog INSERT INTO ... SELECT

Trino's federation allows you to write:

```sql
INSERT INTO iceberg.your_catalog.historical_invoices
SELECT * FROM billing_pg.public.invoices
WHERE created_at < now() - interval '2 years';
```

When you execute this:
1. Trino reads from the Postgres table via the PostgreSQL connector (JDBC).
2. Trino writes the result set directly to Iceberg in your object store.
3. The operation is atomic from Iceberg's perspective — either all rows commit or none do.

This is a Trino-executed operation, not a Postgres operation. Trino pulls the rows from Postgres, applies any transformations, then writes to Iceberg.

### Reading from Postgres safely — use a read replica

**Never point Trino at your OLTP primary.** A multi-hour historical export can:
- Hold open transactions, blocking VACUUM and causing table bloat
- Saturate connection slots on the primary (OSS Trino 467's PostgreSQL connector has no native connection pooling)
- Cause replica lag or CPU contention on the primary

Configure a Postgres catalog in Trino pointing at a **dedicated read replica**:

```properties
# In etc/catalog/billing_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://billing-replica.internal:5432/billing_db?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=trino_reader
connection-password=<from-secret>
```

Store credentials in Kubernetes secrets — mount as environment variables and reference with `${ENV:...}` syntax rather than hardcoding in ConfigMaps.

### The JSONB metadata column — type mapping

Postgres JSONB maps to Trino's `JSON` type, which Parquet stores as a VARCHAR string with the JSON logical type annotation. **Trino and Iceberg can handle it, but with an important limitation**: Parquet stores JSON as an opaque string — no per-key columnar storage, no column-level statistics. When Trino queries the Iceberg table, it reads the entire JSON blob as a string and must re-parse it on every query. This is slow for large result sets and gives you no partition pruning inside the JSON.

**You have two practical options:**

#### Option 1: Store as-is (simplest, but slow for repeated analytics)

Keep the `metadata` column as a VARCHAR string in Iceberg:

```sql
INSERT INTO iceberg.your_catalog.historical_invoices
SELECT 
  invoice_id, 
  customer_id, 
  amount, 
  CAST(metadata AS VARCHAR) AS metadata,  -- cast JSONB to VARCHAR
  created_at
FROM billing_pg.public.invoices
WHERE created_at < now() - interval '2 years';
```

Query with Trino's JSON functions:

```sql
SELECT json_extract_scalar(metadata, '$.transaction_id') AS txn_id, COUNT(*)
FROM iceberg.your_catalog.historical_invoices
GROUP BY 1;
```

**Pro:** lossless, no schema decisions upfront. **Con:** re-parsing JSON on every query is slow compared to typed columns.

#### Option 2: Flatten hot keys (recommended for analytics)

Extract the most-queried JSONB keys into typed columns, keep the raw blob as fallback:

```sql
INSERT INTO iceberg.your_catalog.historical_invoices
SELECT 
  invoice_id, 
  customer_id, 
  amount, 
  CAST(json_extract_scalar(metadata, '$.transaction_id') AS VARCHAR) AS txn_id,
  CAST(json_extract_scalar(metadata, '$.payment_method') AS VARCHAR) AS payment_method,
  CAST(metadata AS VARCHAR) AS metadata_raw,
  created_at
FROM billing_pg.public.invoices
WHERE created_at < now() - interval '2 years';
```

**Rule of thumb:** flatten anything you `WHERE`, `JOIN ON`, or `GROUP BY`. Leave the rest in `metadata_raw`. Flattened columns get full columnar compression, partition pruning, and dictionary filtering — often 10–50× faster than raw JSON extraction for filtered queries.

### Practical implementation checklist

1. **Create the target Iceberg table** first:
   ```sql
   CREATE TABLE iceberg.your_catalog.historical_invoices (
     invoice_id BIGINT,
     customer_id BIGINT,
     amount DECIMAL(18,2),
     txn_id VARCHAR,
     payment_method VARCHAR,
     metadata_raw VARCHAR,
     created_at TIMESTAMP(6)
   )
   WITH (partitioning = ARRAY['day(created_at)']);
   ```

2. **Verify Postgres connectivity** before the big run:
   ```sql
   SELECT COUNT(*) FROM billing_pg.public.invoices
   WHERE created_at >= TIMESTAMP '2024-01-01' AND created_at < TIMESTAMP '2024-02-01';
   ```

3. **Run INSERT in a small batch first** — start with one month to verify schema and type mappings:
   ```sql
   INSERT INTO iceberg.your_catalog.historical_invoices
   SELECT invoice_id, customer_id, amount, 
          CAST(json_extract_scalar(metadata, '$.transaction_id') AS VARCHAR) AS txn_id,
          CAST(metadata AS VARCHAR) AS metadata_raw, created_at
   FROM billing_pg.public.invoices
   WHERE created_at >= TIMESTAMP '2024-01-01' AND created_at < TIMESTAMP '2024-02-01';
   ```

4. **Spot-check the result**, then scale up to the full two-year range.

### Type mapping reference

| Postgres type | Trino type | Parquet storage |
|---|---|---|
| `JSONB` | `JSON` | VARCHAR string (JSON logical type) |
| `BIGINT` | `BIGINT` | int64 |
| `NUMERIC(18,2)` | `DECIMAL(18,2)` | Decimal logical type |
| `TIMESTAMP` | `TIMESTAMP(6)` | timestamp(6) |
| `TEXT`/`VARCHAR` | `VARCHAR` | BYTE_ARRAY |

### Production guardrails

1. **Connection pooling**: OSS Trino 467 has no native JDBC connection pooling. Place PgBouncer between Trino and Postgres in transaction-pooling mode. Set a `CONNECTION LIMIT` on the `trino_reader` role at the Postgres level.

2. **Replica statement timeout**: Set `statement_timeout` on the read replica (e.g., 2–4 hours matching your expected job runtime) so runaway queries don't hold connections indefinitely.

3. **Hive Metastore availability**: The INSERT commit requires HMS to be available to update the Iceberg metadata pointer. If HMS goes down during the write, the query fails at commit time (the SELECT finishes but the INSERT doesn't commit). Ensure HMS is highly available before running multi-hour loads.

### Summary

Yes, it works. A single Trino query reads two years of Postgres invoices and writes directly to Iceberg. The JSONB `metadata` column comes through intact as a VARCHAR string in Iceberg. For analytics performance, flatten the most-queried keys into typed columns. Start with a small date range to verify schema mapping, then scale to the full historical load.
