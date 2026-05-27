# Iter 201 Q1 — Multi-Schema Postgres Federation in Trino

## Answer

**Short answer: Yes, you can join across all four schemas in a single Trino query. You need only ONE PostgreSQL connector, not four. And you must use fully-qualified three-part names — `search_path` does not carry over into Trino.**

---

## One connector, all schemas visible

When you configure a single Trino PostgreSQL connector named `app_pg` pointing at your appdb database, Trino automatically exposes every schema in that Postgres instance as a separate Trino schema within that catalog. So your four Postgres schemas (`public`, `billing`, `audit`, `tenant_data`) all become visible to Trino as:
- `app_pg.public`
- `app_pg.billing`
- `app_pg.audit`
- `app_pg.tenant_data`

You don't need a separate connector file for each schema. One connector configuration in `etc/catalog/app_pg.properties` pointing at the Postgres database gives you access to all schemas simultaneously.

---

## Cross-schema joins work — use three-part naming

You can absolutely join across schemas in a single query:

```sql
SELECT t.subscription_id, i.amount, i.invoice_date
FROM app_pg.tenant_data.subscriptions t
JOIN app_pg.billing.invoices i
  ON t.subscription_id = i.subscription_id
WHERE i.invoice_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

This is one of Trino's key strengths as a **federated query engine** — it can join tables from different schemas (and even different data sources) in a single statement. The join itself executes on the Trino workers; predicate pushdown means filters on each side get pushed back to Postgres, so the replica does the filtering before sending rows to Trino.

---

## Three-part naming is mandatory; search_path doesn't exist in Trino

Postgres's `search_path` setting — which lets you write unqualified names like `SELECT * FROM subscriptions` and have Postgres search through schemas to find the table — **does not carry over into Trino.** Trino requires you to always use the **three-part name**: `<catalog>.<schema>.<table>`.

This is actually good news operationally. It forces clarity. In Postgres, when you see `SELECT * FROM invoices`, you have to check the current `search_path` session variable to know which invoices table you're reading — there's ambiguity. In Trino, `app_pg.billing.invoices` is unambiguous.

If your engineers are used to Postgres's `search_path` convenience, they'll need to adjust: every query must spell out the full three-part name. You can create **Trino views** to hide the repetition if the pattern is common:

```sql
-- In your analytics catalog, create a view
CREATE VIEW analytics.tenant_subscriptions AS
SELECT * FROM app_pg.tenant_data.subscriptions;

-- Now analysts can write shorter queries:
SELECT * FROM analytics.tenant_subscriptions
WHERE status = 'active';
```

---

## Practical setup checklist

1. Create one `etc/catalog/app_pg.properties` file pointing at your read replica:
   ```properties
   connector.name=postgresql
   connection-url=jdbc:postgresql://app-postgres-replica:5432/appdb
   connection-user=${ENV:TRINO_PG_USER}
   connection-password=${ENV:TRINO_PG_PASSWORD}
   ```

2. Verify Trino sees all four schemas:
   ```sql
   SHOW SCHEMAS FROM app_pg;
   -- Output includes: public, billing, audit, tenant_data
   ```

3. Write your cross-schema joins using three-part names (`app_pg.schema.table`).

4. Consider creating lightweight Trino views in your analytics catalog to provide familiar table names to downstream tools — this shields them from the Trino naming requirements while keeping federation explicit in the view definitions.
