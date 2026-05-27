# Iter281 Q2 — Multi-Tenant Cross-Schema Postgres Federation in Trino

## Answer

Trino cannot use dynamic schema names — schemas must be known at query-planning time. Here are the three patterns for your per-tenant schema setup, in order of increasing scale.

### Why Dynamic Schema Names Don't Work

Trino's query planner runs before execution. It needs to know which schemas to access when it parses your SQL. `SELECT * FROM app_pg.<DYNAMIC_SCHEMA>.orders` doesn't work — you cannot substitute the schema name at runtime. This is a fundamental constraint of Trino's federated query model.

### Pattern 1 — UNION ALL Generator (Recommended for < 30 Tenants)

Generate a SQL query with one branch per tenant schema using a script:

```python
# Python example — generates the UNION ALL and creates the view
tenants = ["tenant_1", "tenant_2", "tenant_3"]  # or discover from Postgres

branches = []
for tenant in tenants:
    branches.append(f"""
    SELECT id, order_date, amount, '{tenant}' AS tenant_id
    FROM app_pg.{tenant}.orders
    """)

union_sql = "\nUNION ALL\n".join(branches)
view_sql = f"CREATE OR REPLACE VIEW analytics.all_orders AS\n{union_sql}"
trino_conn.execute(view_sql)
```

Your ops team queries `analytics.all_orders` and gets cross-tenant data. When you add a new tenant, re-run the generator script and execute `CREATE OR REPLACE VIEW` — the new tenant's data flows into aggregates immediately.

### Pattern 2 — Dynamic Discovery with system.query()

To avoid hardcoding tenant lists in your generator script, use the PostgreSQL connector's `system.query()` to discover schemas from Postgres's system catalog:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT schema_name FROM information_schema.schemata
              WHERE schema_name LIKE ''tenant_%'' ORDER BY schema_name'
  )
)
```

Note: single quotes inside the `query =>` string must be doubled (`''`). This returns all matching schema names live — no hardcoded list to maintain. Pipe this into your UNION ALL generator script.

### Pattern 3 — Iceberg with bucket(tenant_id, N) Partitioning (Best for 50+ Tenants)

Once your tenant count grows, the UNION ALL pattern becomes a maintenance burden (every new tenant = regenerate and redeploy the view). The scalable solution: **ingest all tenant data into one Iceberg table partitioned by `tenant_id`**.

```sql
CREATE TABLE iceberg.analytics.orders (
  id BIGINT,
  tenant_id VARCHAR,
  order_date DATE,
  amount DECIMAL(10, 2)
)
WITH (
  partitioning = ARRAY['bucket(tenant_id, 64)', 'day(order_date)']
);
```

Why `bucket(tenant_id, 64)` instead of raw `tenant_id`:
- `tenant_id` as an identity partition creates one partition per tenant per day — metadata explodes with thousands of tenants
- `bucket(N, tenant_id)` groups all tenants into N buckets — metadata stays bounded even with thousands of tenants, while still enabling Trino to prune reads to the relevant bucket(s) for single-tenant queries

Your ingestion pipeline (Spark, Flink, or a nightly Trino MERGE INTO job) reads from all `tenant_N.orders` schemas and writes into this table. Adding a new tenant requires only adding them to the pipeline — no view change, no SQL rewrite.

### Tradeoffs

| Approach | Setup | Scalability | Maintenance on new tenant | Freshness |
|---|---|---|---|---|
| UNION ALL generator | Low (one script + view) | Up to ~30 tenants | Re-run generator, redeploy view | Live (federated from Postgres) |
| system.query() discovery | Low (discovery step only) | Supplements UNION ALL | Automatic (script reads live schemas) | Live |
| Iceberg + bucket(tenant_id, 64) | Medium (ingestion pipeline) | Thousands of tenants | Zero code changes | Minutes to hours |

**Recommendation:** Start with UNION ALL + system.query() discovery today — it works immediately with no ingestion pipeline. Plan to migrate to Iceberg once you exceed ~30-50 tenants or when your freshness SLO allows the ingestion lag.
