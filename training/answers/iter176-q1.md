# Iter 176 Q1 — Auditing Queries on a Postgres Catalog via system.runtime.queries and Event Listener

## Answer

### Understanding `system.runtime.queries` — the in-memory option

**What it is:** An in-memory system table on the Trino coordinator that holds recently-completed and running queries. It's ephemeral — entries vanish on coordinator restart or after 15 minutes of age (default `query.min-expire-age`), and a maximum of ~100 recent queries are retained before older ones get evicted.

**When to use it:** Ad-hoc investigations, incident response, and live triage — "which queries touched `billing_pg` in the last 5 minutes?"

#### The columns you actually have

**Important caveat:** This table has **NO `catalog` column**, despite the Trino UI exposing catalog per query. Writing `WHERE catalog = 'billing_pg'` fails with `Column 'catalog' cannot be resolved`. This is the single most common trap engineers hit.

The actual columns in Trino 467 are:

| Column | What it contains |
|--------|---|
| `query_id` | Unique query identifier (string like `20260526_143012_00042_abcde`) |
| `state` | `RUNNING`, `FINISHED`, `FAILED`, or `CANCELED` |
| `"user"` | **Must be double-quoted** (unquoted `user` silently resolves to the `current_user` builtin instead of the column value) |
| `source` | Client source name, set via JDBC `?source=<name>` or `X-Trino-Source` HTTP header — useful for "which BI tool ran this?" |
| `query` | **The full SQL text** — this is your only path to identify which catalog was queried |
| `created`, `started`, `"end"` | Timestamps (note: `"end"` must be double-quoted; it's a reserved word) |
| `queued_time_ms`, `analysis_time_ms`, `planning_time_ms` | Phase timings |
| `resource_group_id` | Which resource group ran the query |
| `error_type`, `error_code` | Populated only for `FAILED` queries |

**What's NOT here:** No `catalog`, `schema`, `peak_memory_bytes`, or byte-count columns. There's no way to filter directly on catalog — you must search the SQL text.

#### SQL example — find recent queries hitting `billing_pg`

```sql
SELECT
  query_id,
  "user",
  source,
  query,
  state,
  created,
  "end"
FROM system.runtime.queries
WHERE query LIKE '%billing_pg%'
  AND state = 'FINISHED'
ORDER BY created DESC
LIMIT 50;
```

**Critical gotchas:**

1. **`"user"` must be double-quoted** everywhere — in SELECT, WHERE, GROUP BY, etc. Unquoted `user` silently returns your own session username on every row, not the actual query user.
2. **LIKE matching produces false positives.** If a query contains `billing_pg` in a string literal, comment, or column value, it matches even though the query never touched that catalog. For production security audits with low false-positive rates, you need the event listener.
3. **No historical data.** If the coordinator restarted yesterday, you have zero visibility into queries from before that restart.

---

### Event listeners — the durable, production-grade option

**What they are:** Trino can be configured to POST a JSON event to your infrastructure for every completed query. These events carry the full SQL text, runtime statistics, catalog name, and more — and they land in your own persistent store (Loki, OpenSearch, Kafka, MySQL, or a custom collector).

**When to use it:** Any security audit longer than "last few hours," cost tracking, compliance, and forensics like "who queried the billing catalog last week?"

#### The key difference from `system.runtime.queries`

| Aspect | `system.runtime.queries` | Event Listener |
|--------|---|---|
| **Catalog field** | No `catalog` column — must text-match the SQL | `metadata.catalog` field — direct, no false positives |
| **Duration** | Ephemeral, ~100 recent queries, 15 min max age | Durable — you control retention (30 days, 1 year, forever) |
| **Cost metrics** | No bytes-scanned field | Full stats: `physicalInputBytes`, `cpuTime`, `wallTime` |
| **Latency** | Live, in-memory | Async, events POST after query completes |
| **Use case** | "What's running NOW?" | "Who touched this catalog last month?" |

#### Setting up the HTTP event listener

Create `etc/http-event-listener.properties` on your Trino coordinator:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://audit-collector:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Register it in `etc/config.properties`:

```properties
event-listener.config-files=etc/http-event-listener.properties
```

**Restart the Trino coordinator** — event listeners are not hot-reloaded.

#### What each completed query sends

For every query that completes, Trino POSTs JSON. The key fields for auditing:

```json
{
  "context": {
    "user": "alice@mycompany.com"
  },
  "metadata": {
    "queryId": "20260526_143012_00042_abcde",
    "query": "SELECT * FROM billing_pg.accounts WHERE customer_id = 42",
    "catalog": "billing_pg",
    "queryState": "FINISHED"
  },
  "statistics": {
    "wallTime": "PT2.345S",
    "cpuTime": "PT1.8S",
    "physicalInputBytes": 5242880
  },
  "ioMetadata": {
    "inputs": [
      {
        "catalogName": "billing_pg",
        "schemaName": "public",
        "tableName": "accounts"
      }
    ]
  }
}
```

**Critical parsing notes:**
- Nested paths, not flat keys: `context.user`, `metadata.catalog`, `statistics.physicalInputBytes`
- Time fields are ISO-8601 Duration strings (`"PT2.345S"`), not milliseconds — parse with a library
- Bytes are plain integers

Once persisted to an Iceberg audit table, a security audit query becomes:

```sql
SELECT query_id, trino_user, query_text, create_time
FROM iceberg.analytics.query_audit_log
WHERE catalog_name = 'billing_pg'
  AND create_time >= CURRENT_DATE - INTERVAL '7' DAY
ORDER BY create_time DESC;
```

---

### Which tool for your security audit?

| Question | Use this |
|----------|----------|
| "Is anyone querying `billing_pg` RIGHT NOW?" | `system.runtime.queries` with `WHERE query LIKE '%billing_pg%'` |
| "Who accessed `billing_pg` last week?" | Event listener → Iceberg/OpenSearch/Loki |
| "Show me exact SQL, user, bytes scanned" | Event listener only (no bytes-scanned in system table) |
| "Low false-positive rate audit" | Event listener (`metadata.catalog` field, not text match) |

---

### Security warnings

1. **Never expose `system.runtime.queries` to tenant users or analysts** — it contains every user's full SQL text on the cluster. Restrict to admin service accounts only.
2. **Event listener events are not retried** if your HTTP receiver is down — events are lost. Run receiver as a local sidecar or configure retry logic.
3. **Text-matching against the `query` column produces false positives** — use event listener's `metadata.catalog` for reliable audits.
