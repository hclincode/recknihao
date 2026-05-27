# Iter 212 Q2 — OPA Decision Log Timing and Cross-Catalog Forensics

## Answer

### When OPA decision log entries are written

OPA decision log entries are written **at query analysis time, before workers start reading any data**. The authorization decision — allow or deny — is already captured in the OPA decision log by the time the Trino coordinator begins handing tasks to workers.

When your SaaS app submits a SQL query, Trino immediately sends authorization checks to OPA ("can this user read these tables?"). OPA evaluates the policy and writes a decision log entry. Only if OPA says "yes" does the coordinator move to the next phase — sending tasks to workers to actually fetch data. The log entry exists even if the coordinator subsequently crashes mid-execution, because it was written when OPA returned its response.

---

### Decision log entries for a cross-catalog join (Iceberg + Postgres)

For a query joining `iceberg.analytics.events` and `app_pg.public.tenants`, you get **multiple OPA calls and multiple decision log entries**:

1. **One call per table access** (`SelectFromColumns` operation): Trino issues a `SelectFromColumns` call to OPA for each base table the query touches — one for the Iceberg table and one for the Postgres table. That's at least two separate decision log entries per query.

2. **Additional calls for row-filtering or column masking**: If you've configured `opa.policy.row-filters-uri`, each table gets an additional call asking "what WHERE predicate should I inject for this user on this table?" — another decision log entry per filtered table.

3. **Batch vs. non-batch for filter-list operations**: If the query also enumerates tables/schemas (e.g., triggered by `SHOW TABLES`) and you have `opa.policy.batched-uri` configured, Trino collapses N per-candidate calls into one. The batched decision log entry contains the full `action.filterResources` array and the returned indices. Without `batched-uri`, the same operation produces one entry per candidate.

**For your Iceberg + Postgres join without column masking, with row-filtering enabled**: expect at minimum 2 authorization log entries (one per table for `SelectFromColumns`), plus 2 row-filter entries (one per table), all written before the first worker task starts.

---

### Using the OPA decision log for forensics

The three-way cross-reference workflow tells you definitively whether missing data was filtered by OPA at authorization time or lost during execution:

**Step 1 — Trino event listener (`queryCompleted` event)**

Pull the `queryCompleted` event for that query by `queryId` or by user + time. This gives you:
- The full query text
- The `queryId` to use as a join key into OPA logs
- `errorCode.name = "PERMISSION_DENIED"` if OPA denied the whole query at analysis

**Step 2 — OPA decision log (authorization time)**

Filter the OPA decision log by `input.context.queryId = "<that queryId>"`. You now see:
- Which tables OPA was asked about
- Which returned `allow: true` vs. which were denied
- If row-filtering: which WHERE expressions were injected (e.g., `tenant_id = 'acme'`)

**Interpretation**:
- OPA shows `deny` for a table → data was filtered at authorization time. The customer never could have seen it — it was blocked before any worker ran.
- OPA shows `allow` with a row-filter expression → data was restricted by a policy-injected WHERE clause. Check whether the predicate was correct.
- OPA shows `allow` with no filter → authorization passed. If data is still missing, the cause is downstream.

**Step 3 — Postgres execution (`pg_stat_activity` or slow-query log)**

For federated queries, check the SQL that actually reached Postgres. This tells you:
- Did the row-filter predicate get pushed down to Postgres (it will appear in the JDBC WHERE clause)?
- Did Trino fetch the full table and filter locally (no WHERE clause in the Postgres log)?

**The definitive conclusion**:

| OPA log shows | Postgres log shows | Conclusion |
|---|---|---|
| `deny` | N/A (query blocked) | Authorization filtered the data |
| `allow` + row-filter injected | WHERE clause with filter | Policy worked, predicate pushed to Postgres |
| `allow` + row-filter injected | No WHERE clause | Policy worked but predicate not pushed — Trino filtered locally |
| `allow` + no filter | N/A | Authorization passed; data loss is elsewhere (query logic, Iceberg snapshot timing) |

---

### Detecting authorization vs. execution filtering: quick summary

- **OPA log with `deny`** or `result = []` (empty indices for a filter-list op) → hidden by policy, authorization time.
- **OPA log with row-filter expression** → data restricted by injected predicate, not missing entirely.
- **OPA log all `allow`, Postgres log has no WHERE clause** → data not filtered by OPA or predicate pushdown; investigate query logic or Iceberg snapshot timing.
- **Use `input.context.queryId`** as the join key across all three systems (Trino event log, OPA decision log, Postgres `pg_stat_activity`).
