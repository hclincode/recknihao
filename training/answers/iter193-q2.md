# Iter 193 Q2 — system.query() Deep Dive: When, Why, Security, and Performance

## Answer

## `system.query()` in the PostgreSQL Connector

You've found a powerful escape hatch, and your security concerns are well-founded. Let me walk through what `system.query()` does, when to use it, and the security and performance implications.

### What problem does `system.query()` solve?

Trino's PostgreSQL connector translates Trino SQL into equivalent Postgres SQL on the fly. But some things can't be expressed in standard SQL or require Postgres-specific syntax:

- **Postgres-specific functions and operators** — JSON/JSONB operators like `->`, `?`, `@>` (full containment check) don't have Trino equivalents
- **Custom Postgres functions** — if your app has a homegrown stored function or extension function, Trino can't call it
- **System introspection** — queries against `pg_stat_user_tables`, `pg_stat_user_indexes`, or `pg_catalog` tables
- **Vendor extensions** — things like PostGIS or full-text search operators that Postgres provides but aren't standard SQL

When you hit one of these, you can't write normal Trino SQL and expect it to work. That's where `system.query()` comes in.

### Syntax and basic usage

```sql
SELECT * FROM TABLE(
  <catalog>.system.query(
    query => 'raw Postgres SQL here'
  )
);
```

For example, to find unused indexes on your replica:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT schemaname, relname, indexrelname, idx_scan FROM pg_stat_user_indexes WHERE idx_scan = 0'
  )
);
```

The raw SQL string is sent **verbatim** to Postgres via JDBC. Trino doesn't parse it, rewrite it, or try to optimize it — it just passes it through.

### Security: Does it bypass your access controls?

**Short answer: No, but with a major caveat about Postgres-level permissions.**

Here's how the layering works:

1. **Trino's OPA policy still applies** — the user running the query still needs permission to execute table functions on the catalog. If your OPA policy denies the user access, the query is blocked at the Trino layer before it even reaches Postgres.

2. **But once past Trino's gate, the query executes as the Postgres user configured in the catalog** — not as the original Trino user. The credentials (`trino_reader` role) are stored in a Kubernetes secret and mounted into the Trino catalog. **Every query through that catalog, including `system.query()`, runs as `trino_reader` on Postgres.** There's no per-user credential impersonation.

This means:
- If `trino_reader` can see a Postgres table, **any Trino user who can access the catalog can see that table too** via `system.query()`, regardless of whether your Trino OPA policy would normally deny them direct table access
- `system.query()` **does NOT respect Trino row filters or column masks** — those are Trino-level controls that apply to tables Trino understands, not to raw Postgres SQL being passed through
- **The Postgres GRANT model is your second layer of defense**. If you want to prevent a class of Trino users from querying sensitive data via `system.query()`, ensure the `trino_reader` role on Postgres doesn't have `SELECT` on sensitive tables

In your production setup with OPA:
1. Trino user → OPA evaluates → (if deny) request blocked, query never reaches Postgres
2. (if allow) → query executes as `trino_reader` on Postgres → Postgres ACLs determine what the query can actually see

OPA gates *access to the catalog*, but once a user gets past that gate, they see everything `trino_reader` can see on Postgres.

### Performance: Trino doesn't try to push anything down

This is where `system.query()` differs sharply from normal table queries:

- **The entire query string is sent to Postgres as-is** — Trino doesn't push predicates, joins, or aggregations. It treats the result as an opaque source.
- **If you write `SELECT * FROM TABLE(...) WHERE id = 42`, Trino pulls the entire result set from Postgres first, then filters locally.** If `huge_table` has 5 million rows, you're transferring 5 million rows over the network even though you only wanted one.
- **No join pushdown** — joins against a `system.query()` result happen on Trino workers
- **No column pruning or statistics** — Trino can't estimate row counts, so it fetches everything and figures it out at runtime

**The fix: always push filtering into the SQL string:**

```sql
-- Bad: fetches all rows, filters on Trino side
SELECT * FROM TABLE(app_pg.system.query(query => 'SELECT * FROM users'))
WHERE created_at > now() - interval 30 day;

-- Good: Postgres does the filtering
SELECT * FROM TABLE(app_pg.system.query(
  query => 'SELECT * FROM users WHERE created_at > now() - interval ''30 days'''
));
```

### When NOT to use it

- **Don't use it as your normal data-read path for tables Trino can already query.** Regular Trino SQL gets predicate pushdown, column pruning, dynamic filtering, and join optimization. `system.query()` sacrifices all of that.
- **Don't use it for exploratory queries that might accidentally expose large datasets.** No predicate pushdown means a casual `SELECT * FROM TABLE(system.query(query => 'SELECT * FROM big_table'))` is a performance and network disaster.
- **Don't use it to work around OPA policy.** OPA blocks you at the Trino layer. Even if that somehow failed, Postgres ACLs still apply.

### Anti-patterns and risks

1. **Assuming it bypasses Trino controls** — it doesn't. OPA still gates access.
2. **Assuming it lets you query data the `trino_reader` role shouldn't see** — Postgres GRANT model is the actual boundary.
3. **Using it without filtering** — always push predicates into the SQL string.
4. **Not monitoring it** — `system.query()` calls should be logged and monitored like any Trino query. Unexpected patterns are worth investigating.

### Summary

`system.query()` is an escape hatch for things Trino SQL can't express (Postgres-specific functions, operators, system catalog queries). It's safe from an *OPA bypass* perspective (OPA still gates it), but the effective permission boundary is "what does the `trino_reader` Postgres role have access to" — not per-Trino-user access controls. Ensure `trino_reader` has only minimal grants. And always filter inside the SQL string — otherwise you pay the full network cost of unoptimized Postgres queries.
