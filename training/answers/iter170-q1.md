# Iter 170 Q1 — Dynamic Catalog Management in Trino

## Answer

Yes, there's a solution — you can add new Postgres catalogs to Trino without restarting any pods, but it requires a one-time coordinator configuration change first.

## Step 1: Enable dynamic catalog management (one-time setup, one restart)

Edit `etc/config.properties` on your Trino coordinator:

```properties
catalog.management=dynamic
```

This requires one coordinator restart to enable. After that, you never restart for catalog changes again. The default (`catalog.management=static`) requires properties files and pod restarts each time.

## Step 2: Create a new Postgres catalog at runtime via SQL

Once dynamic mode is enabled, add a new catalog on the fly:

```sql
CREATE CATALOG new_customer_pg USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://customer-postgres-replica.on-prem:5432/customerdb?ssl=true&sslmode=require&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10',
  "connection-user" = 'trino_reader',
  "connection-password" = 'customer_password',
  "metadata.cache-ttl" = '60s'
);
```

The catalog appears cluster-wide immediately. Run `SHOW CATALOGS;` to verify. Users can query `new_customer_pg.public.orders` right away — no pod restarts, no downtime.

## Key points for compliance requirements

1. **Always point at a read replica** — never the operational primary. A runaway Trino query can hold transactions and exhaust connections.

2. **The JDBC URL parameters matter**:
   - `ssl=true&sslmode=require` — encrypts the connection (your security team will require this)
   - `defaultRowFetchSize=1000` — biggest single lever for federation throughput, reduces JDBC round-trips
   - `socketTimeout=60` and `connectTimeout=10` — prevent queries hanging on network issues

3. **Password rotation without downtime** (since `ALTER CATALOG` doesn't exist yet in Trino 467):

```sql
-- Create with new credentials under a temporary name
CREATE CATALOG new_customer_pg_v2 USING postgresql
WITH ("connection-password" = 'rotated_password', ...);

-- Drop old catalog (in-flight queries survive; new queries temporarily fail)
DROP CATALOG new_customer_pg;

-- Recreate with the original name
CREATE CATALOG new_customer_pg USING postgresql
WITH ("connection-password" = 'rotated_password', ...);

DROP CATALOG new_customer_pg_v2;
```

`DROP CATALOG` does not interrupt queries already in flight on that catalog.

## Removing a catalog

```sql
DROP CATALOG new_customer_pg;
```

When a customer churns or revokes access, this immediately removes their catalog without any restart.
