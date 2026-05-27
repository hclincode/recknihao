# Iter 181 Q1 — Diagnosing a Completed Slow Cross-Catalog Query After It's Gone from the Web UI

## Answer

When a query disappears from the Trino Web UI, you have lost the in-memory record on the coordinator. Here's the complete pathway to recovery and diagnosis, organized by what you need to know and how durable your answer needs to be.

---

### In-memory query retention (ephemeral)

**`system.runtime.queries` table** — This is the first place to look while the query is still "fresh" (coordinator hasn't restarted, and the query hasn't been evicted from memory).

- **What it contains**: Every running, completed, and failed query that the coordinator has seen, with columns for query ID, state (RUNNING/FINISHED/FAILED), SQL text, user, timestamps (created, started, end), and phase timings (queued_time_ms, analysis_time_ms, planning_time_ms). Notably, there is **no `catalog` column** — you must search the SQL text itself.
- **Retention window**: Bounded by two settings:
  - `query.max-history` (default: 100 queries) — once exceeded, oldest queries get evicted.
  - `query.min-expire-age` (default: 15 minutes) — queries are eligible for eviction once they exceed this age AND the history limit is breached.
  - This means if your cluster ran 150 queries in the last 15 minutes, only the most recent 100 remain.
- **Lifespan**: Queries live ONLY in the running coordinator's memory. **A coordinator restart wipes the entire history clean.** If your Trino cluster restarted between when the query ran last night and when you checked this morning, `system.runtime.queries` will be empty.

**To query it for your federation query:**

```sql
-- Find all queries that touched the billing_pg catalog
SELECT 
  query_id, 
  "user",                    -- MUST be double-quoted; unquoted 'user' returns current_user instead
  source,
  query,
  state,
  created, 
  started, 
  "end",
  (CAST("end" AS BIGINT) - CAST(created AS BIGINT)) / 1000.0 AS wall_time_sec
FROM system.runtime.queries
WHERE query LIKE '%billing_pg%'
  AND state IN ('FINISHED', 'FAILED')
ORDER BY "end" DESC
LIMIT 20;
```

**Key quirk**: `"user"` and `"end"` must be double-quoted — both are reserved words. The unquoted `user` silently evaluates to `current_user` (a builtin function) instead of the table column, so every row would show your name.

To see cost metrics (bytes scanned, CPU time), join with `system.runtime.tasks`:

```sql
SELECT 
  q.query_id,
  q."user",
  q.query,
  q.state,
  q.created,
  q."end",
  SUM(t.physical_input_bytes) / 1e9 AS total_gb_scanned,
  SUM(t.split_cpu_time_ms) / 1000.0 AS total_cpu_sec
FROM system.runtime.queries q
LEFT JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.query LIKE '%billing_pg%'
  AND q.state IN ('FINISHED', 'FAILED')
GROUP BY q.query_id, q."user", q.query, q.state, q.created, q."end"
ORDER BY total_gb_scanned DESC
LIMIT 20;
```

---

### The Trino Web UI query history

**Location**: `http://trino-coordinator:8080/ui/queries`

The Web UI shows the same in-memory list as `system.runtime.queries`. Once a query falls off that table (coordinator restart, or eviction), **the Web UI no longer shows it either.** It is useful for real-time triage ("what's running right now?") but useless for post-mortem analysis of queries that finished hours ago.

There is one exception: the coordinator keeps the raw query JSON at `/ui/query.html?<query_id>` for in-memory queries — this includes per-operator stats, input/output row counts, and dynamic filter details that don't appear in `system.runtime.queries`. Bookmark the URL the moment you see a slow query so you can inspect it even after it falls off the list.

---

### Coordinator logs (limited, but available immediately)

**Location**: `/var/log/trino/server.log` on the Trino coordinator pod.

**What to grep for**:
```bash
# Find all queries mentioning your catalog
grep -i "billing_pg\|app_pg" /var/log/trino/server.log

# Look for slow completions
grep "FINISHED.*[3-9][0-9][0-9][0-9]ms\|FINISHED.*[0-9]m[0-9]" /var/log/trino/server.log
```

**Limitations**:
- SQL text in logs is **truncated** — long queries appear as `SELECT ... [<remaining_chars_truncated>]`.
- Logs contain wall-clock time but **not** bytes scanned or CPU time.
- Logs are ephemeral (rotate based on your log retention policy — usually 7–30 days).

Use logs for: quick "did this query ever run?" checks within the last few days.

---

### The Trino event listener (durable, persistent record)

**This is the essential piece for production.** When you need to understand queries that ran hours or days ago, the event listener is the only source of truth.

**What it captures**:
- Full query text (not truncated)
- Query ID, user, source, state (FINISHED/FAILED/CANCELED)
- Wall-clock time, physical input bytes, CPU time, peak memory
- Error code and error message for failed queries

**Setup (HTTP listener — recommended for on-prem k8s)**:

Create `etc/http-event-listener.properties` on the coordinator:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://vector-collector:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Register it in `etc/config.properties`:

```properties
event-listener.config-files=etc/http-event-listener.properties
```

Restart the coordinator. From that point forward, every completed query is POSTed as JSON to your collector. Land events in OpenSearch/Loki, or build a queryable Iceberg table:

```sql
-- Query your event listener history (days or weeks later)
SELECT 
  query_id,
  user,
  query,
  state,
  wall_time_ms / 1000.0 AS wall_time_sec,
  physical_input_bytes / 1e9 AS gb_scanned
FROM iceberg.observability.trino_queries
WHERE created >= CURRENT_DATE - INTERVAL '7' DAY
  AND query LIKE '%billing_pg%'
ORDER BY wall_time_ms DESC;
```

---

### PostgreSQL-side diagnostics (for federation-specific issues)

Since your slow query was cross-catalog (billing_pg + Iceberg), the Postgres replica also has a view of what it received. Enable slow-query logging temporarily:

```sql
-- On the Postgres replica only:
ALTER SYSTEM SET log_min_duration_statement = 0;
SELECT pg_reload_conf();
```

Then re-run the query. The actual SQL Postgres received shows what Trino pushed down:
- **Pushdown succeeded**: `SELECT ... WHERE status = 'active' AND region = 'us-east'` — Postgres filtered.
- **Pushdown failed**: `SELECT * FROM billing_pg.accounts` — all rows returned, Trino filtered in-memory.

Disable it when done:
```sql
ALTER SYSTEM SET log_min_duration_statement = -1;
SELECT pg_reload_conf();
```

---

### Concrete diagnosis sequence for your 8-minute query

1. **Check in-memory (while fresh)**:
   ```sql
   SELECT query_id, "user", query, "end", state
   FROM system.runtime.queries
   WHERE query LIKE '%billing_pg%' AND state = 'FINISHED'
   ORDER BY "end" DESC LIMIT 5;
   ```

2. **If empty (evicted or coordinator restarted)** — check coordinator logs:
   ```bash
   grep "billing_pg" /var/log/trino/server.log | tail -20
   ```

3. **For historical analysis** — query your event listener store:
   ```sql
   SELECT query_id, query, wall_time_ms, physical_input_bytes
   FROM iceberg.observability.trino_queries
   WHERE created >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR
     AND query LIKE '%billing_pg%'
   ORDER BY wall_time_ms DESC;
   ```

4. **For federation-specific slowness** — re-run with Postgres slow logging enabled and check what SQL Postgres actually received.

---

### Summary: retention windows

| View | Retention | Durable? | Best for |
|---|---|---|---|
| **Trino Web UI** | ~15 min + coordinator memory | No | Real-time triage |
| **`system.runtime.queries`** | ~15 min + ~100 queries | No | Immediate post-query diagnosis |
| **Coordinator logs** | 7–30 days (depends on rotation) | Semi | "Did this ever run?" |
| **Trino event listener → Iceberg** | Indefinite | Yes | Long-term forensics, SLA compliance |
| **Postgres slow logs** | Days (configure rotation) | Semi | Debugging pushdown success/failure |

**Immediate action**: Enable the Trino HTTP event listener now if not already done. Also check `query.max-history` in `config.properties` — raising it (e.g., to 500) extends your in-memory window on active clusters.
