# Iter262 Q2 — Multi-Tenant Postgres Schemas in Trino: Can One Catalog See All of Them?

## Answer

**Short answer: Yes, absolutely.** A single Trino catalog can see and query all schemas in a Postgres database in the same SQL statement. You do not need 60 separate catalog entries.

### How the Postgres Connector Exposes Schemas

When you configure the Trino PostgreSQL connector, it points to a Postgres server (not just one schema). Every schema in that Postgres database shows up as a Trino schema inside the catalog, and every Postgres table shows up as a Trino table.

So if you have one Postgres instance with 60 tenant schemas (`tenant_abc`, `tenant_xyz`, etc.), a **single catalog** in Trino automatically exposes all of them. After you configure `etc/catalog/app_pg.properties` pointing to your Postgres server, you can immediately do:

```sql
SHOW SCHEMAS FROM app_pg;  -- lists all 60 tenant schemas
SHOW TABLES FROM app_pg.tenant_abc;  -- tables in the 'tenant_abc' schema
SELECT * FROM app_pg.tenant_abc.orders;  -- read from one tenant's orders
SELECT * FROM app_pg.tenant_xyz.orders;  -- read from another tenant's orders
```

### Writing a Cross-Tenant Aggregation Query

You can query across multiple schemas in a single SQL statement. For example, to sum orders across multiple tenants:

```sql
SELECT 
  tenant,
  SUM(order_amount) AS total_orders
FROM (
  SELECT 'tenant_abc' AS tenant, amount AS order_amount FROM app_pg.tenant_abc.orders
  UNION ALL
  SELECT 'tenant_xyz' AS tenant, amount AS order_amount FROM app_pg.tenant_xyz.orders
  -- ... repeat for each tenant
) t
GROUP BY tenant;
```

However, this still requires explicitly listing each schema in the UNION ALL. **There is no built-in "query all schemas matching a pattern" syntax in Trino.** Trino cannot automatically loop over all schemas whose names match `tenant_%`. If you need dynamic aggregation across all 60 tenants without hardcoding each schema name, you would need to either:

1. **Generate the UNION ALL query programmatically** in your application — build the full SQL string (by querying `SHOW SCHEMAS FROM app_pg` to list all tenant schemas first), then send it to Trino.
2. **Ingest the tenant data into Iceberg** as a single table partitioned by `tenant_id` — the recommended approach for multi-tenant analytics at your scale.

### The Recommended Pattern for Your Scale

For 60 tenants, the multi-tenant analytics pattern recommended for SaaS companies is: instead of keeping separate Postgres schemas and writing UNION ALL across them, ingest all tenant data into a **single shared Iceberg table partitioned by `tenant_id`**. This gives you:

- **Simple cross-tenant queries** — `SELECT tenant_id, SUM(amount) FROM iceberg.analytics.orders GROUP BY tenant_id` with no UNION ALL
- **Partition pruning** — when filtering by tenant, Trino skips files for other tenants automatically
- **One schema to maintain** — no schema-drift or migration complexity across 60 copies
- **Easier access control** — create Trino views that hard-code `WHERE tenant_id = <caller's tenant>` so customers never see other tenants' data through your API

### Bottom Line

- **A single Trino Postgres catalog CAN see all 60 schemas** — you don't need 60 catalog entries. One catalog = one Postgres server = all schemas visible.
- **But querying them together requires explicit UNION ALL** — there's no "auto-loop over matching schemas" syntax in SQL or Trino.
- **For cross-tenant analytics at 60 tenants**, the better architecture is to ingest into a single Iceberg table partitioned by `tenant_id` and query it directly from Trino — this eliminates the UNION ALL entirely and makes queries much faster.
