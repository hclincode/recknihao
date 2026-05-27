# Iter 185 Q1 — Multi-Schema Federation Within One Postgres Catalog

## Answer

### Part 1: Can you join two schemas under the same Postgres catalog in one query?

**Yes, absolutely.** You can write:

```sql
SELECT *
FROM billing_pg.public.invoices i
JOIN billing_pg.accounting.adjustments a ON i.invoice_id = a.invoice_id
WHERE i.created_at > TIMESTAMP '2026-05-01 00:00:00'
```

This will work. Since both tables live in the **same catalog** (`billing_pg`), the PostgreSQL connector can push the entire join down into Postgres itself. Trino will rewrite this as a single SQL statement sent to Postgres: `SELECT ... FROM public.invoices JOIN accounting.adjustments ON ...`, and Postgres executes the join server-side using its own indexes and join algorithms.

**Key detail:** Join pushdown is **intra-catalog only**. The schema (`public` vs `accounting`) does not matter — what matters is that both tables are in the same catalog. The PostgreSQL connector sees them as part of the same Postgres instance and can push the join down. If you were joining `billing_pg.public.invoices` against a different catalog (e.g., `iceberg.analytics.events`), then the join would run on Trino workers instead, and the entire join-pushdown mechanism would be unavailable.

You can control join-pushdown behavior via session properties if needed:

```sql
-- Force join pushdown for this query (Postgres executes it server-side)
SET SESSION billing_pg.join_pushdown_strategy = 'EAGER';

-- Or disable join pushdown (join runs on Trino workers instead) for debugging
SET SESSION billing_pg.join_pushdown_enabled = false;
```

To verify join pushdown succeeded, use EXPLAIN:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT i.invoice_id, i.amount, a.adjustment_amount
FROM billing_pg.public.invoices i
JOIN billing_pg.accounting.adjustments a ON i.invoice_id = a.invoice_id;
```

If join pushdown succeeded, you'll see a single `TableScan` node that encapsulates the join (Postgres ran it). If you see separate `TableScan` nodes with a `HashJoin` above them, the join ran on Trino workers.

---

### Part 2: OPA and schema-level authorization

**OPA sees the full three-part identifier** — catalog, schema, and table — when it evaluates each access check. Specifically, Trino sends OPA the full resource path for each table being accessed:

- `billing_pg.public.invoices` — one OPA check
- `billing_pg.accounting.adjustments` — a separate OPA check

OPA policy rules are typically written per catalog-schema-table triplet. **A single OPA rule can cover both schemas** — you do not need separate OPA rules for `billing_pg.public` vs `billing_pg.accounting`. In Rego, you can write a rule that says "principals in group X are allowed to SELECT on any table in `billing_pg` regardless of schema" using pattern matching:

```rego
allow {
  input.action.operation == "SelectFromColumns"
  input.action.resource.table.catalogName == "billing_pg"
  # schema can be "public", "accounting", or any other schema in billing_pg
}
```

Or if you want schema-level granularity (e.g., `accounting` schema requires a different role):

```rego
allow {
  input.action.operation == "SelectFromColumns"
  input.action.resource.table.catalogName == "billing_pg"
  input.action.resource.table.schemaName == "public"
  # allow general users to access public schema
}

allow {
  input.action.operation == "SelectFromColumns"
  input.action.resource.table.catalogName == "billing_pg"
  input.action.resource.table.schemaName == "accounting"
  input.context.identity.user == data.finance_team[_]
  # restrict accounting schema to finance team only
}
```

**The schema name IS visible to OPA** as `input.action.resource.table.schemaName`. This is the correct field to use for schema-level access control. Your Rego rules can be as coarse (whole catalog) or as fine (per-schema, per-table, per-column) as your governance requirements dictate.

---

### Practical next steps

1. **For the join itself:** write the query confidently. Same catalog = join pushdown is available. Both `public` and `accounting` schemas are queryable from Trino as long as the connector's Postgres credentials have SELECT on both.

2. **For OPA authorization:** confirm with your security team what `schemaName` values appear in your OPA decision logs when hitting `billing_pg.accounting.*` tables. If no rules currently match `accounting`, requests will be denied by OPA's default-deny. You may need to explicitly add `accounting` to your existing `billing_pg` rules.

3. **Postgres permissions:** Trino's JDBC connection to Postgres must have `SELECT` privileges on both schemas (`public` and `accounting`). This is independent of OPA — Postgres-level role permissions and Trino/OPA-level permissions both need to allow access.
