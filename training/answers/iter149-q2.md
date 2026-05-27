# Iter 149 Q2 — Trino JDBC Connection Pooling and Prepared Statements

## Answer

The "too many open connections" problem and the repeated re-planning issue are both real, and they have different solutions. Here is what the resources cover on these topics.

### Limiting concurrent connections per tenant with resource groups

The most direct tool in the Trino stack for controlling connection-level overload is **resource groups**. Resource groups cap how many queries from a given user or group can run or queue simultaneously. If 50–80 concurrent users are each creating a connection and immediately submitting queries, resource groups prevent the cluster from being overwhelmed:

```json
{
  "name": "api_users",
  "softMemoryLimit": "50%",
  "hardConcurrencyLimit": 40,
  "maxQueued": 100
}
```

With `hardConcurrencyLimit: 40`, at most 40 queries from the `api_users` group run simultaneously. The next 100 queue. Beyond that, submissions are rejected with a "queue full" response — which is more graceful than a connection-refused error at the TCP level.

This does not directly reduce the number of open JDBC connections, but it does prevent the cluster from being overwhelmed by concurrent query submissions and gives your API a predictable backpressure mechanism.

See the full resource group configuration in `resources/05-multi-tenant-analytics.md`.

### Query re-planning on every request

The resources do not contain documentation on Trino prepared statements or JDBC connection pooling configuration. These are client-side patterns that sit outside the current resource coverage.

What the resources do cover for repeated-query performance:
- **Partition pruning**: If the parameterized query filters on a partition column (e.g., `event_date`), Trino skips unrelated partitions entirely. The planning cost is low when partition pruning is effective.
- **Resource group scheduling**: `weighted_fair` scheduling ensures repeated queries from the same tenant group are not penalized.

### What is missing from these resources

The following topics are not covered and would need to be added to the resources to fully answer this question:
1. **JDBC connection pooling for Trino** — whether standard connection pool libraries (HikariCP, c3p0) work with the Trino JDBC driver, and how to configure pool size.
2. **Trino prepared statements** — whether `PREPARE` / `EXECUTE` SQL exists in Trino 467, and whether it reduces per-query planning cost.
3. **Trino JDBC driver connection lifecycle** — whether connections are stateful or stateless, and what overhead each new connection incurs.

The resources are strong on server-side query optimization and cluster configuration but do not currently cover client-side connection management patterns for SaaS APIs.

### What you can do now

Based on what the resources cover:

1. **Configure resource groups** to cap concurrent queries per user group — this prevents the cluster from being overwhelmed regardless of how many connections are open.
2. **Ensure partition pruning is active** — confirm your `event_date` and `tenant_id` filters match the table's partition spec, so repeated parameterized queries scan minimal data.
3. **Check system.runtime.queries** for planning time vs execution time — if planning is a small fraction of total query time, re-planning is not the bottleneck.

For the JDBC connection pooling and prepared statements question specifically, consult the Trino 467 JDBC driver documentation directly.
