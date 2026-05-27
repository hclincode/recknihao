# Iter273 Q1 — Querying Across All Tenant Schemas in Trino: UNION ALL, system.query(), or Migrate to Iceberg

## Answer

You're hitting a fundamental design mismatch between Postgres and Trino. **Trino cannot use schema names as variables because SQL is planned statically before execution** — the schema name must be known at parse time, not at runtime. Here are your three options with concrete SQL.

### The Core Problem: Static Schema Binding

In Postgres, you can discover and query schemas dynamically with PL/pgSQL loops. This cannot work in Trino. When Trino parses your SQL at the coordinator, it validates every table exists before the query runs. Schema names must be hardcoded or parameterized at the client level — not built inside the query string at execution time.

### Option 1: Explicit UNION ALL (Simple, Recommended)

Hardcode a UNION ALL across all 200 tenant schemas. The key insight: **generate the UNION ALL statement with a script**, not by hand.

```sql
-- Platform-level report: total events per tenant this week
SELECT 'tenant_abc' AS tenant_id, COUNT(*) AS event_count
FROM app_pg.tenant_abc.events
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
UNION ALL
SELECT 'tenant_xyz' AS tenant_id, COUNT(*) AS event_count
FROM app_pg.tenant_xyz.events
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
UNION ALL
SELECT 'tenant_acme' AS tenant_id, COUNT(*) AS event_count
FROM app_pg.tenant_acme.events
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
-- ... repeat for all 200 tenants ...
ORDER BY event_count DESC;
```

**Generate it with Python:**

```python
import psycopg2

conn = psycopg2.connect("dbname=appdb user=app_user host=postgres-replica")
cursor = conn.cursor()

cursor.execute("""
  SELECT schema_name FROM information_schema.schemata
  WHERE schema_name LIKE 'tenant_%'
  ORDER BY schema_name
""")
schemas = [row[0] for row in cursor.fetchall()]

sql_parts = []
for schema in schemas:
    sql_parts.append(f"""
    SELECT '{schema}' AS tenant_id, COUNT(*) AS event_count
    FROM app_pg.{schema}.events
    WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
    """)

full_query = "\nUNION ALL\n".join(sql_parts) + "\nORDER BY event_count DESC;"
print(full_query)
```

Wrap the generated SQL in a `CREATE OR REPLACE VIEW` and save to version control. Regenerate when tenants are added.

**Pros**: Predicates push down cleanly to each Postgres schema independently. Easy to debug with EXPLAIN. Works with any BI tool.

**Cons**: Must regenerate when schema list changes. 200 branches looks long but is valid SQL.

### Option 2: system.query() — Let Postgres Do the Work

`system.query()` sends SQL verbatim to Postgres, letting Postgres do the dynamic discovery:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => '
      WITH schemas AS (
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name LIKE ''tenant_%''
      )
      SELECT schema_name AS tenant_id,
             (SELECT COUNT(*) FROM events
              WHERE created_at >= CURRENT_DATE - INTERVAL ''7'' DAY) AS event_count
      FROM schemas
    '
  )
);
```

**Critical limitation**: Trino treats the result as an opaque blob — **no predicate pushdown, no join pushdown**. If you add a WHERE clause outside the `TABLE(...)`, Trino fetches all rows first and filters locally. Use this for ad-hoc reports, not repeated analytics queries.

**Pros**: No regeneration script — add a tenant schema to Postgres and it's automatically included.

**Cons**: No predicate pushdown from Trino. No parallel execution (Postgres loops serially). Postgres-specific syntax locks you in.

### Option 3: Migrate to Iceberg with tenant_id Column (Long-Term)

The real fix is to stop using per-tenant schemas and use a **single shared Iceberg table partitioned by `tenant_id`**:

```sql
CREATE TABLE iceberg.analytics.events (
  event_id BIGINT,
  tenant_id VARCHAR,
  user_id BIGINT,
  event_type VARCHAR,
  created_at TIMESTAMP
) WITH (
  partitioning = ARRAY['tenant_id', 'day(created_at)'],
  format = 'PARQUET'
);
```

Your platform-level query becomes trivial — one scan, no UNION:

```sql
SELECT tenant_id, COUNT(*) AS event_count
FROM iceberg.analytics.events
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY tenant_id
ORDER BY event_count DESC;
```

Migration: use Spark to iterate all 200 Postgres schemas and union into Iceberg with a `tenant_id` column added per schema. Run once for initial load, then incremental updates.

**Pros**: Scales to 1,000+ tenants with no query changes. Iceberg partition pruning skips files for other tenants in per-tenant queries. Adding a tenant is just inserting rows — no schema provisioning. GDPR delete is `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'`.

**Cons**: Requires a migration project (2–4 weeks). One-time cost, but zero operational friction afterward.

### Decision Guide

| Approach | Time | Ongoing effort | Best for | Scalability |
|---|---|---|---|---|
| **UNION ALL** (generate script) | Hours | Low — regenerate on new tenant | < 500 tenants | Medium |
| **system.query()** | Minutes | None | Ad-hoc one-off reports | Low (no pushdown) |
| **Iceberg + tenant_id** | Weeks (migration) | None | 100+ tenants, long-term | High |

**Recommendation**: Use UNION ALL now (write the generator script today). Plan the Iceberg migration for next quarter — once done, you never think about this problem again.
