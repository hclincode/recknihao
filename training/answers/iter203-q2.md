# Iter 203 Q2 — OPA Policy Evaluation Latency in Trino Federated Queries

## Answer

Yes, OPA is adding latency to query startup — but it's **not a fixed cost; it scales with table and column count in a very specific way**. Here's what's happening and what you can do about it.

### 1. When OPA is called during the query lifecycle

OPA decisions happen during the **query analysis phase**, which runs on the Trino coordinator before query planning. The timeline for a federation query hitting Postgres and Iceberg looks like this:

1. Query arrives at coordinator
2. **Query analysis begins** — this is where OPA gets invoked
3. **OPA column-masking checks** (if configured) — evaluated per table and column
4. Query planning proceeds (HMS lookup for Iceberg, Postgres catalog calls)
5. Workers execute

The critical insight: OPA decisions **block the analysis phase from completing**. A slow OPA evaluation directly delays the moment your query appears in `system.runtime.queries` as `RUNNING`.

### 2. Cost structure — scaling with tables and columns

The overhead is **NOT fixed per query**. It scales in the worst way:

**Single-column endpoint (the default):**
- For a query touching a 40-column table, OPA makes **40 sequential HTTP calls** before analysis can finish
- Each call is a round-trip to the OPA pod: serialize the request → network → Rego evaluation → serialize response → network → deserialize
- On a wide table, this becomes a measurable per-query latency tax on a busy cluster

**Example latency breakdown:**
- Single OPA HTTP call to evaluate one column: ~5–15 ms (network + Rego evaluation)
- 40-column table: 40 × 5–15 ms = 200–600 ms **added to query startup** before planning even starts
- A query touching **two wide tables** (40 + 30 columns) = 70 sequential round-trips

This is why your dashboards that hit several tables feel "pausy" — the coordinator is stuck in OPA's sequential column evaluation loop.

### 3. The batch endpoints — what they are and why they help

Trino has two column-masking endpoints, and you must configure both:

```properties
# Per-column endpoint (still needed, slower for wide tables):
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask

# Batch endpoint (preferred when available):
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

**How the batch endpoint changes the math:**
- Instead of one HTTP call per column, Trino sends **one request with all columns from a table**, and OPA returns the masking decision for **all of them at once**
- Same 40-column table: 1 HTTP round-trip instead of 40
- This reduces per-query startup latency from ~200–600 ms to ~5–15 ms for that table

**Critical gotcha — the response shape differs:**

| Endpoint | Response format |
|---|---|
| Single-column | `{"expression": "to_hex(sha256(...))"}` |
| Batch | `[{"index": 0, "viewExpression": {"expression": "..."}}, ...]` |

Note the key is `viewExpression`, not `expression`. Using the single-column shape in a batch Rego rule causes a policy-eval error or silently returns no mask.

### 4. Caching and policy optimization approaches

**Trino has no built-in per-query OPA decision cache.** Every query re-evaluates the policy. This is by design — Rego rules can depend on dynamic data (LDAP group memberships, OPA data bundles), so caching stale decisions across queries risks granting access to someone who was just revoked.

However, you can optimize at the OPA side:

**A. Optimize your Rego rules themselves:**
- Avoid expensive string operations in hot paths (e.g., repeated regex matching against a large list of usernames)
- Pre-compute commonly-used groupings in OPA's data bundle instead of doing list comprehensions at evaluation time
- For tenant-to-user mappings, load them as a lookup table in the bundle (`data.tenant_map[username]`) rather than iterating through a list

**B. Reduce rule complexity:**
- Each Rego rule that fires adds to `metrics.timer_rego_query_eval_ns` evaluation time. Profile your rules to find which fire most often and refactor the hot ones

**C. Monitor latency:**
Track the actual OPA evaluation time in the decision log. The field is `metrics.timer_rego_query_eval_ns`. Set a threshold alert: if p95 policy evaluation time exceeds 100 ms on a busy cluster, query planning slows noticeably. Example:

```json
{
  "metrics": {
    "timer_rego_query_eval_ns": 45000000
  }
}
```

(That's 45 ms of OPA evaluation time for a single query's policy decision.)

### 5. Practical configuration recommendations

**Immediate wins (do these now):**

1. **Enable the batch endpoint** if you haven't:
   ```properties
   opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
   ```
   Trino will automatically prefer batch when available and fall back to per-column for older OPA bundles.

2. **Audit which tables are triggering the slowest masking decisions:**
   - Run a query that touches multiple tables
   - Measure `analysis_time_ms` in `system.runtime.queries`
   - Identify the widest tables (highest column count) and ensure masking is only applied where truly needed

3. **Consider reducing masking scope:**
   - If only 5 columns in a 40-column table need masking, set your OPA rule to return `null` (no mask) for the other 35. Trino skips the expression substitution for `null` results
   - Don't mask columns that don't contain PII (e.g., `event_timestamp`, `country_code`)

4. **Use row filters instead of column masking where possible:**
   - Row filters (`opa.policy.row-filters-uri`) are evaluated once per query, not per-table-per-column
   - If your access control is "tenants see only their rows," a row filter (`tenant_id = 'acme'`) is cheaper than masking 20 columns

5. **Monitor the OPA pod's own latency:**
   - Enable OPA decision logging: `decision_logs.console: true`
   - Ship logs to your observability stack
   - Build a dashboard on `metrics.timer_rego_query_eval_ns` (p50, p95, p99)
   - If OPA evaluation time is creeping up, it may indicate: a regressing Rego rule, OPA pod memory/GC pressure, or a data bundle that's grown too large

6. **Batch-load your OPA data bundles:**
   - If tenant-to-user mappings come from a database, pre-fetch them into OPA's data layer once per pod restart, not inline with each Rego evaluation

**What NOT to do:**

- **Don't configure only the batch endpoint and forget the single-column endpoint.** If your OPA bundle doesn't implement the batch handler, Trino falls back to per-column with no warning.
- **Don't try to implement OPA caching at the Trino level.** The coordinator has no built-in decision cache.

### Summary

Your multi-table dashboard query pauses for ~200–600 ms per wide table in analysis due to sequential OPA column-masking HTTP round-trips. **Enabling the batch endpoint reduces this to ~5–15 ms per table.** For a multi-table dashboard, this is the single biggest lever — implement that first. Then monitor OPA's own evaluation time via decision logs and optimize Rego rules if needed.
