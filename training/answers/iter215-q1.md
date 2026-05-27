# Iter 215 Q1 — OPA Decision-Log Volume Sizing for Federated Queries

## Answer

## OPA Decision Logging for Trino Federation Queries: How Many Entries Per Query

### Core mechanics: OPA fires at query analysis time only, not per worker or split

OPA makes authorization decisions **once per query, at query analysis time** — before any worker threads are launched or splits are created. When Trino's analyzer runs, it consults OPA for each table access, gets the allow/deny + row filter (if configured), then either fails the query or rewrites it. No decision-log entries after that point. Workers never call OPA; they just execute the rewritten SQL.

This means your storage estimate is **not** multiplied by the number of workers or splits. One query = one small set of decision log entries, regardless of parallelism.

### Decision log entries per query: the **2 + N** formula

For a typical two-table cross-catalog join (Iceberg fact table + Postgres dimension), expect exactly **2 + N** decision log entries, where N depends on your row-filter and column-masking configuration.

**Baseline: 2 entries**
- One `SelectFromColumns` entry per table accessed. A two-table join produces 2 entries minimum (one per table).

**Row-filter entries: add 1 per table**
- If you have `opa.policy.row-filters-uri` configured, each table gets one additional entry of operation type `RowFilters` (or `GetRowFilters` — depends on your Trino version). This entry contains the WHERE expression OPA returns, e.g., `result: ["tenant_id = 'acme'"]`.
- Two tables with row filters = 2 additional entries.

**Column-masking entries: add more, but less common**
- Column masking is less frequently configured than row filters. When it is, you get additional entries per table, but this is not the typical pattern.

**The practical arithmetic for your 2–3 table case:**
- 2-table join, no row filters: **2 entries** (1 `SelectFromColumns` per table)
- 2-table join, row filters on both tables: **4 entries** (2 `SelectFromColumns` + 2 `RowFilters`)
- 3-table join, row filters on all three: **6 entries** (3 `SelectFromColumns` + 3 `RowFilters`)

You will also get one `ExecuteQuery` entry per query (useful for join keys against the event listener), so add 1 to all the above if you're counting every entry that carries your `queryId`.

### Batched filter-list operations differ: one entry per batch, not per candidate

If you run `SHOW TABLES` to list 50 visible tables:
- **With `opa.policy.batched-uri` configured**: 1 decision log entry whose `input.action.filterResources` array contains all 50 candidates. The `result` field is the sparse array of indices of permitted tables.
- **Without batched-uri**: 50 separate entries (one call to `opa.policy.uri` per candidate).

For your federated query scenario, this doesn't apply directly — batching is for `SHOW` operations and schema/table/column filtering, not for data queries. In a SELECT statement across two tables, you get single-resource `SelectFromColumns` calls, not filter-list operations.

### Practical sizing estimate for 30-day retention

Each decision log entry is a single JSON line to stdout. A minimal entry (two-table query, no row filters) is roughly **1–2 KB** per entry after OPA serializes the full `input` document (catalog, schema, table, column names, user, groups, etc.) plus metadata (decision_id, metrics, timestamps).

With row filters, entries grow because they include the WHERE expression. A row filter like `tenant_id = 'acme'` adds perhaps 50–100 bytes to the entry.

**For a 2-table join with row filters on both tables (4 entries per query):**
- Conservative: 4 entries × 2 KB = 8 KB per query
- If you run 100,000 queries per day: 100,000 × 8 KB = 800 MB/day
- 30-day retention: 800 MB × 30 = **24 GB**

**For a 3-table join with row filters (6 entries per query):**
- 6 entries × 2 KB = 12 KB per query
- 100,000 queries/day: 100,000 × 12 KB = 1.2 GB/day
- 30-day retention: 1.2 GB × 30 = **36 GB**

This estimate assumes moderate compression (gzip brings it to ~30% of original) and a typical JSON serialization overhead. If you have custom Rego rules that add large metadata to results, entries may be larger. Test with a sample of your policy.

### How to enable OPA decision logs

1. **In the OPA configuration** (usually `config.yaml` or your Helm chart values), set:
   ```yaml
   decision_logs:
     console: true
   ```
   This writes one JSON line per decision to OPA's stdout.

2. **Critical: you MUST ship stdout to an external store.** OPA's stdout is not durable on its own. If the OPA pod restarts, the buffer is lost; if k8s log rotation happens, history is gone. Without shipping, you have no 30-day retention.
   - **Standard pattern**: Fluentd / Fluent Bit sidecar + OpenSearch (query via Kibana) or Loki (query via Grafana).
   - **Alternative**: configure `decision_logs.service` to push entries to a remote HTTP endpoint.

3. **On the Trino side**, these settings are **optional** for forensics but **not required** for OPA to log:
   - `opa.log-requests=true` and `opa.log-responses=true` in `etc/access-control.properties` — these log the raw HTTP request/response on Trino's side. They produce gigabytes per day on a busy cluster and are meant only for debugging Trino ↔ OPA communication issues, not routine auditing.

4. **Confirm the log is on**: after enabling, run a test query and grep the OPA pod logs for a JSON line containing `decision_id`. If you see it, you're live. If not, restart the OPA pod and confirm the config was picked up.
