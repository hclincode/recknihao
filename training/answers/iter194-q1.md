# Iter 194 Q1 — Multi-Schema Postgres Federation in Trino

## Answer

Based on your Trino 467 setup on k8s pointing to a Postgres read replica, here's exactly how the catalog/schema mapping works:

### How catalog and schema map

When you configure a single Postgres connector (e.g., `app_pg.properties`), **Trino exposes all schemas in that database**. From the resource documentation:

> "Once configured, every database/schema in that Postgres instance shows up as a Trino schema inside the catalog, and every Postgres table shows up as a Trino table."

So if your Postgres instance has both `public` and `billing` schemas, they both appear as Trino schemas under the same `app_pg` catalog. You don't need separate connectors for each schema — one connector gives you access to all of them.

### Naming in Trino

Your intuition is correct. They show up as:
- `app_pg.public.users` for the users table in the public schema
- `app_pg.billing.invoices` for the invoices table in the billing schema

(Replace `app_pg` with whatever you named your catalog in the properties file.)

You can verify what's there with standard Trino commands:

```sql
SHOW SCHEMAS FROM app_pg;        -- lists both 'public' and 'billing'
SHOW TABLES FROM app_pg.public;  -- tables in public schema
SHOW TABLES FROM app_pg.billing; -- tables in billing schema
```

### Cross-schema JOINs work perfectly

Yes, you can absolutely JOIN across schemas in the same query. This works fine:

```sql
SELECT 
  u.user_id, 
  u.email,
  i.invoice_id,
  i.total_amount
FROM app_pg.public.users u
JOIN app_pg.billing.invoices i 
  ON u.user_id = i.customer_id
WHERE i.created_at > CURRENT_DATE - INTERVAL '30' DAY;
```

Trino treats both tables as living in the same catalog (`app_pg`), so they're queried as a single JDBC connection to your Postgres replica. There's no per-schema connection limitation — it's one connector, one connection pool scenario (though note: OSS Trino 467 doesn't have built-in JDBC connection pooling, so see the resource file for PgBouncer mitigation if you hit connection limits).

### What you should configure

In your `etc/catalog/app_pg.properties`, point once at your Postgres replica:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://postgres-replica-host:5432/your_database_name
connection-user=${ENV:TRINO_POSTGRES_USER}
connection-password=${ENV:TRINO_POSTGRES_PASSWORD}
```

That one configuration exposes both `public` and `billing` schemas (and any others) as queryable Trino schemas. No per-schema connectors needed.

**Key production consideration for your setup**: Make sure you're pointing at the **read replica**, never the OLTP primary. Even a seemingly lightweight JOIN can hold long transactions on Postgres and block autovacuum, which will degrade your production system. The resource doc emphasizes this is "the single most important operational rule."
