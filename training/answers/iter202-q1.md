# Iter 202 Q1 — OPA Column Masking with Trino's PostgreSQL Connector

## Answer

**OPA Column Masking with Trino's PostgreSQL Connector: How It Works**

When you mask a column with OPA in Trino, the masking happens **at query analysis time inside the Trino coordinator**, not at the source database. Here's the exact flow:

---

### Where the masking applies

OPA column masking is applied during Trino's `StatementAnalyzer` phase (query planning, before execution). OPA returns a SQL expression that Trino substitutes for the column reference. When an analyst runs `SELECT email FROM users`, Trino rewrites it internally to something like `SELECT '****' AS email FROM users` or `SELECT to_hex(sha256(to_utf8(email))) AS email FROM users`, depending on what OPA's policy specifies.

---

### What actually gets sent to Postgres

This is the critical point: **Trino still pulls the full data from Postgres, including the raw unmasked PII, before applying the mask.** The masking does NOT push down to the PostgreSQL connector level. Here's what happens:

1. Analyst's query arrives with a masked column (e.g., `email`).
2. OPA returns the masking expression (e.g., `to_hex(sha256(to_utf8(email)))`).
3. Trino rewrites the query plan to compute that expression.
4. The query is sent to the PostgreSQL connector, which executes against Postgres — **but Postgres still returns all rows with all columns, because Trino needs the raw bytes to compute the masking function**.
5. Trino workers receive the raw Postgres data into memory, evaluate the masking expression, and return **only the masked result** to the analyst.

---

### Security implications

- **What the analyst sees**: Only the masked value. A query like `SELECT email FROM users` shows `to_hex(sha256(to_utf8(email)))` or `****`, never the raw email.
- **What Postgres sends**: The complete raw email address. Postgres has no awareness of the masking policy; it returns all rows and columns as requested.
- **What Trino workers see**: The raw unmasked bytes momentarily in worker process memory before the masking expression evaluates. **Masking does NOT prevent the raw data from entering the query engine.** For the common case where worker pods are trusted and the goal is "analysts cannot see raw PII in their result set," masking is exactly right. If your threat model requires that raw PII never enter Trino worker pods, column masking is insufficient — you need encryption or physically separate tables.

---

### Configuration

Wire up masking on the Trino coordinator in `etc/access-control.properties`:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
# For wide tables, use the batch endpoint:
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

OPA returns masking expressions like:

```json
{"expression": "'****'"}
{"expression": "to_hex(sha256(to_utf8(email)))"}
```

---

### Critical gotcha: constant masking breaks GROUP BY and JOIN

Masking to a constant value like `'****'` makes every row identical in that column. If analysts then `GROUP BY email` or `JOIN` on the masked column, all rows collapse into one group, or you get a full cartesian product. Use deterministic hashing (`to_hex(sha256(...))`) instead — it preserves equality so grouping and joining work correctly, while the raw PII never reaches the client.

---

### Bottom line for your use case

Your data analysts will see `to_hex(sha256(...))` or similar masked values for `email` and `phone_number`. Trino still fetches the full raw Postgres rows, applies the masking transformation inside Trino workers (in trusted process memory), and returns only the masked result. The masking is a presentation layer — it doesn't reduce what leaves Postgres or change what pushes down (normal predicate pushdown still applies to non-masked columns and row filters).
