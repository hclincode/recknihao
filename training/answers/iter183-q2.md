# Iter 183 Q2 — Distinguishing OPA vs Trino vs Postgres Errors in Federation Queries

## Answer

When a federation query "didn't work," the three possible failure layers each produce **distinct error strings and error codes**. One glance at `system.runtime.queries` tells you which layer to investigate.

---

### The three layers and their signatures

#### Layer 1: OPA Authorization Rejection (before Trino parses SQL)

When OPA blocks a query, the user gets an **HTTP 403 Forbidden** before Trino's SQL parser runs.

| Where | What you see |
|---|---|
| **Trino CLI** | `Query failed: Access Denied` — appears instantly, no planning time |
| **`system.runtime.queries`** | `state = 'FAILED'`, `error_type = 'USER_ERROR'`, `error_code = 'PERMISSION_DENIED'` |
| **OPA decision log** | Structured JSON: `decision = deny`, `input.resource.catalog = 'app_pg'`, the Rego rule that fired |

**Triage check**: `error_code = 'PERMISSION_DENIED'`? → OPA rejected it. Look at the OPA decision log (shipped to OpenSearch/Loki) for the user + catalog combination. The rule that fired is explicitly named in the `result` field. You do NOT need stack traces for OPA failures.

---

#### Layer 2: Trino Rejection (plan-time: syntax, type mismatch, invalid query)

When Trino rejects a query at planning time (bad SQL, column not found, unsupported construct), the error appears **after the HTTP 200 OK** but **before Trino touches Postgres**.

| Error code | Example message | Meaning |
|---|---|---|
| `SYNTAX_ERROR` | `line X, position Y: Unexpected token` | Malformed SQL |
| `INVALID_QUERY` | `Column "foo" cannot be resolved` | Wrong column/table name |
| `QUERY_TOO_LARGE` | `Query exceeded maximum size limit` | Query text exceeds `query.max-length-bytes` |
| `GENERIC_USER_ERROR` | Type mismatch, unsupported operation | Catch-all for plan-time user errors |

All have `error_type = 'USER_ERROR'`. They are **deterministic and reproducible** — the same query fails the same way every time. If an engineer says "it sometimes works, sometimes fails," this layer is NOT the culprit.

**Triage check**: `error_type = 'USER_ERROR'` with `error_code` like `SYNTAX_ERROR`? → Trino plan-time error. Ask the engineer to run `EXPLAIN <query>` to see where planning fails. OPA is not involved.

---

#### Layer 3: Postgres Rejection (runtime: timeout, connection loss, too many connections)

When Postgres kills or rejects a connection, Trino catches a `PSQLException` at runtime and surfaces a **verbatim Postgres error string**. These have `error_type = 'EXTERNAL'` in `system.runtime.queries`.

Memorize these verbatim strings — they identify exactly what happened:

| Verbatim error string | Meaning | Root cause |
|---|---|---|
| `ERROR: canceling statement due to statement timeout` | Postgres `statement_timeout` fired on the replica | Query was too expensive; predicate pushdown may have failed; Postgres had to scan the full table |
| `java.net.SocketTimeoutException: Read timed out` | JDBC driver gave up waiting for bytes from Postgres | Postgres backend hung (replication stall, CPU spike), or `socketTimeout` set too low |
| `FATAL: too many connections for role "trino_reader"` | Postgres rejected the connection — role `CONNECTION LIMIT` exceeded | PgBouncer pool exhausted; too many concurrent federation queries; pool size too small |
| `Connection refused` | Postgres or PgBouncer is down | Operational — network routing, pod crash |

Layer 3 errors are **flaky and temporal** — they depend on system load, replica lag, or connection state. If an engineer says "worked yesterday, fails today, works now," this layer is the prime suspect.

**Triage check**: `error_type = 'EXTERNAL'` or error message contains a verbatim Postgres string? → Postgres/JDBC failure. Check Postgres replica logs and connection metrics (PgBouncer pool, `pg_stat_activity`).

---

### Three-question triage runbook

Ask these **in order** when a support ticket arrives:

```
Step 1: Get the query_id (Trino CLI shows it as "Query <id>" in the error)

Step 2: Check system.runtime.queries
  SELECT error_type, error_code, state
  FROM system.runtime.queries
  WHERE query_id = '<id>';

Step 3: Route based on result:

  error_code = 'PERMISSION_DENIED'
  → OPA rejected the query. Check OPA decision log (OpenSearch/Loki) for
    catalog + user. Find the Rego rule that fired. Fix: grant access or
    update policy. No SQL debugging needed.

  error_type = 'USER_ERROR' AND error_code IN ('SYNTAX_ERROR', 'INVALID_QUERY', ...)
  → Trino plan-time error. Ask user to run: EXPLAIN <query>
    Fix: SQL correction (typo, wrong column name, unsupported construct).
    OPA was NOT involved.

  error_type = 'EXTERNAL' OR error message contains Postgres/JDBC strings
  → Postgres/JDBC failure. Determine which:
      "statement timeout" → pushdown failed or query too expensive
        Fix: verify pushdown with EXPLAIN, add Postgres index, or replicate to Iceberg
      "SocketTimeoutException" → JDBC connection hung
        Fix: check Postgres replica health, consider raising socketTimeout in JDBC URL
      "too many connections" → pool exhausted
        Fix: raise PgBouncer default_pool_size or lower hardConcurrencyLimit in resource groups
```

---

### What each tool is best for

| Tool | Best for | How to use |
|---|---|---|
| **`system.runtime.queries`** | First triage — categorize by `error_type` + `error_code` | `WHERE query_id = '<id>'` |
| **OPA decision log** (OpenSearch/Loki) | Layer 1: access-denial details, Rego rule audit | Filter `decision=deny AND input.resource.catalog='billing_pg'` |
| **Postgres slow log** | Layer 3: statement_timeout, what SQL Postgres received | `grep "statement timeout"` or check replica pg_log |
| **`pg_stat_activity`** | Layer 3: live connection count and state | `WHERE usename = 'trino_reader'` |
| **PgBouncer `SHOW POOLS`** | Layer 3: pool saturation | `waiting_clients > 0` = pool full |
| **Trino HTTP event listener** (OpenSearch) | Durable history of all three layers' outcomes | Query `errorCode` + `errorMessage` fields |

---

### Making this surfaced clearly in your tools

The quickest win: build a Grafana panel that groups recent federation query failures by layer:

```sql
-- In system.runtime.queries (for live triage, ~15 min window):
SELECT 
  CASE 
    WHEN error_code = 'PERMISSION_DENIED' THEN 'OPA rejection'
    WHEN error_type = 'USER_ERROR' THEN 'Trino plan error'
    WHEN error_type = 'EXTERNAL' THEN 'Postgres/JDBC error'
    ELSE error_type
  END AS failure_layer,
  COUNT(*) AS count
FROM system.runtime.queries
WHERE state = 'FAILED'
  AND (query LIKE '%billing_pg%' OR query LIKE '%app_pg%')
  AND created >= NOW() - INTERVAL '1' HOUR
GROUP BY 1
ORDER BY count DESC;
```

For the longer-term durable view, ship events via the Trino HTTP event listener to OpenSearch and run the same categorization over weeks of history.

---

### Most common misdiagnosis

- **"Trino is slow"** when Postgres logs show `statement timeout` → it's Layer 3, not Trino. Postgres killed the query because predicate pushdown didn't happen and it had to scan 50M rows.
- **"Permission issue"** when `system.runtime.queries` shows `SYNTAX_ERROR` → it's Layer 2, a SQL typo. OPA was never involved.

One `error_type` lookup avoids weeks of debugging the wrong layer.
