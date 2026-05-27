# Iter 175 Q2 — Audit Trail for Federation Queries and OPA Decisions

## Answer

Your security team is asking the right questions. Here's the complete picture for your Trino + OPA + Postgres stack.

### (1) Trino's `system.runtime.queries` Table (Short-Term Window)

For same-day audit, Trino's in-memory query metadata is immediately available:

```sql
SELECT
  query_id,
  "user",        -- CRITICAL: must be double-quoted — "user" is a Trino reserved word
  catalog,
  schema,
  query,
  state,
  created,
  "end"
FROM system.runtime.queries
WHERE catalog = 'postgres_billing'
ORDER BY created DESC;
```

**Critical**: the `"user"` column name is a Trino reserved word. Always quote it as `"user"` in SELECT, WHERE, GROUP BY, and JOIN references. Writing unquoted `user` causes a syntax error because Trino parses it as the `user()` function.

**Retention**: `system.runtime.queries` is ephemeral — lives only in coordinator memory. Default: ~100 queries, 15-minute minimum age. When the coordinator restarts, the table evaporates. This gives you only a real-time view, not historical audit.

### (2) Trino Event Listener for Persistent Query Audit

For durable, queryable history, configure a **Trino event listener plugin** on the coordinator:

```properties
# /etc/trino/http-event-listener.properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://log-collector.internal:8080/v1/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Register it in `config.properties`:
```properties
event-listener.config-files=etc/http-event-listener.properties
```

**Syntax note**: the property prefix uses a **hyphen**, not a dot — `http-event-listener.*` not `http.event-listener.*`. A dot causes Trino to reject the config at startup.

Each `QueryCompletedEvent` includes: query ID, SQL text, user/principal, catalog/schema/tables touched, execution timestamps, state (FINISHED/FAILED), bytes scanned, and error messages if failed.

Once persisted to an Iceberg observability table, you can run historical audit queries:
```sql
SELECT query_id, "user", catalog, query, end_time
FROM iceberg.observability.trino_queries
WHERE catalog = 'postgres_billing'
  AND end_time >= CURRENT_TIMESTAMP - INTERVAL '30' DAY
ORDER BY end_time DESC;
```

**Key limitation**: the event listener only records queries that completed. Queries denied by OPA before execution don't appear here. For denied access attempts, you need the OPA decision log.

### (3) OPA Decision Logs — The Authorization Audit Trail

OPA evaluates every Trino query before execution and logs each decision. Each log entry contains:

- **Timestamp** of the evaluation
- **Input document**: the action (e.g., `SelectFromColumns`), resource (catalog/schema/table/columns), and identity (Trino username + groups)
- **Which Rego policy rules fired** and their intermediate results
- **The allow or deny outcome**
- **Latency** of the policy evaluation

**OPA decision logs are NOT durable by default.** Setting `console: true` in OPA's config writes to OPA's stdout only — ephemeral pod output. For durability:

```yaml
# OPA config
decision_logs:
  console: true  # writes to stdout — pipe to Fluentd/Loki for persistence
```

To make them durable: pipe OPA stdout to a logging backend (Fluentd, Fluent Bit, Loki, ELK) or configure an OPA remote service sink. Without this step, denied access attempts vanish when the pod restarts.

### (4) How the Two Log Streams are Complementary

| Question | Answer from |
|---|---|
| Who ran the query? | Both (OPA decision + Trino event log) |
| What SQL did they run? | Trino event log only |
| Did OPA allow or deny it? | OPA decision log only |
| How much data did it scan? | Trino event log only |
| Which queries were blocked before running? | OPA decision log only — denied queries never appear in Trino's event log |

**The key gap**: Trino event listener only records queries that **made it past OPA** (allowed). Denied queries appear in OPA decision logs but NOT in Trino query history. If your security team asks "was someone blocked from accessing the billing catalog?", only the OPA decision log can answer that.

Together: OPA answers **who tried to access what and whether it was allowed**. Trino event listener answers **what SQL ran, how long it took, and how much data was scanned**.

### (5) Recommended Dashboard — Deny Events on Billing Catalog

The highest-signal security alert: any OPA deny event targeting your `postgres_billing` catalog.

Configure your logging pipeline (Loki, ELK) to alert when:
- `decision == "deny"` AND `resource.catalog == "postgres_billing"`

Any deny is worth investigating immediately — it means an analyst (or attacker) attempted access to sensitive financial data without the right permissions. Either it's misconfiguration (grant missing, role assignment wrong) or a security incident. Both need triage.

For your complete audit coverage:
1. **Trino event listener** → Iceberg observability table → SQL queries for "who queried the billing catalog in the last 30 days"
2. **OPA decision logs** → Loki/ELK → real-time alert on deny events targeting the billing catalog

Neither alone is sufficient: event listener misses denied attempts; OPA decision logs miss SQL-level details of successful queries.
