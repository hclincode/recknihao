# Iter 181 Q2 — Why Trino Switches from IN-list to BETWEEN (domain-compaction-threshold)

## Answer

What you're observing is called **domain compaction** — a deliberate behavior in Trino's JDBC connector that converts large IN-lists to BETWEEN ranges before sending SQL to Postgres.

---

### Why it happens: `domain-compaction-threshold`

Trino has a connector-level setting called `domain-compaction-threshold` (default: **256**). When a dynamic filter arrives at the PostgreSQL connector with more distinct values than this threshold, Trino automatically compacts the IN-list into a `BETWEEN` range before embedding it in the SQL sent to Postgres.

For example:
- **256 or fewer values**: Trino sends `WHERE tenant_id IN (101, 102, 103, ...)` — the exact set needed.
- **257+ values**: Trino sends `WHERE tenant_id BETWEEN 101 AND 950` — the min and max, but everything in between, whether or not you actually need those rows.

This is intentional, not a bug. Large IN-lists create overhead on the Postgres side: query plan generation slows, index selection can get confused, and SQL parsing cost climbs with thousands of values. Trino's compaction is a safety valve to keep SQL size and Postgres planning overhead bounded.

The cost, as you've noticed, is significant: `BETWEEN` returns many more rows than `IN`, destroying the selectivity you were counting on from dynamic filtering.

---

### How dynamic filtering and compaction interact

Here's the full flow:

1. **Trino builds a dynamic filter** from the join's build side (e.g., the 500 tenant IDs returned by filtering one table).
2. **PostgreSQL connector's compaction step** sees 500 values > 256 threshold and silently converts to `BETWEEN min(500 values) AND max(500 values)` before sending SQL to Postgres.
3. **Postgres receives the weaker filter** and returns far more rows than needed.
4. **Trino then applies the real filter** in-memory on the worker, after pulling excess rows over the wire.

The Postgres slow-query log shows `BETWEEN` — that's why you spotted it. It's the exact SQL Postgres received after compaction.

---

### How to tune it — without restarting the coordinator

You have two options:

#### Option 1: SET SESSION per-query (immediate, no restart needed)

```sql
-- Raise the threshold for this session only
SET SESSION app_pg.domain_compaction_threshold = 1024;

-- Now run your federated query — Trino preserves IN-lists up to 1024 values
SELECT *
FROM app_pg.public.orders o
JOIN iceberg.analytics.tenants t ON o.tenant_id = t.id
WHERE t.plan_type = 'enterprise';
```

**Critical syntax note**: The session property requires the **catalog prefix** (`app_pg.`). The bare form `SET SESSION domain_compaction_threshold = 1024` fails with "Session property does not exist" because this is a connector-scoped property, not a system-level one.

#### Option 2: Catalog properties file (persistent, requires coordinator restart)

Edit `etc/catalog/app_pg.properties`:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://pgbouncer-app.svc:6432/appdb?prepareThreshold=0
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
domain-compaction-threshold=1024
```

This persists the setting cluster-wide but requires rolling the coordinator pod to take effect.

For per-query tuning during investigation, use Option 1 (SET SESSION). For a permanent production setting, use Option 2.

---

### What value to pick

**Start with 1024** (4× the default). This handles most real-world federation patterns:
- Up to ~1024 distinct join-key values → Trino preserves the IN-list
- Beyond 1024 → still compacts to BETWEEN, but this indicates you're federating a very large join that may be better served by ingesting to Iceberg

Values above 2048 are rarely useful — if your join produces 10,000+ distinct keys, the IN-list SQL overhead becomes significant and the join itself is probably too large for JDBC federation anyway.

---

### How to verify it worked

1. **Enable Postgres slow-query logging temporarily** (on the replica only):
   ```sql
   ALTER SYSTEM SET log_min_duration_statement = 0;
   SELECT pg_reload_conf();
   ```

2. **Run your federated query from Trino** with the new threshold:
   ```sql
   SET SESSION app_pg.domain_compaction_threshold = 1024;
   SELECT * FROM app_pg.public.orders o
   JOIN iceberg.analytics.events e ON o.tenant_id = e.tenant_id
   WHERE e.event_type = 'purchase';
   ```

3. **Check the Postgres replica log** for what Trino actually sent:
   ```bash
   tail -f /var/log/postgresql/postgresql.log | grep "WHERE.*tenant_id"
   ```

   Before (compacted to BETWEEN):
   ```sql
   SELECT ... FROM orders WHERE tenant_id BETWEEN 101 AND 950
   ```

   After (precise IN-list preserved):
   ```sql
   SELECT ... FROM orders WHERE tenant_id IN (101, 102, 103, ... <up to 1024 values>)
   ```

4. **Compare row counts in EXPLAIN ANALYZE**:
   ```sql
   EXPLAIN ANALYZE SELECT ...;
   ```
   Look at `Input: N rows` on the Postgres TableScan. With a more selective IN-list, you should see fewer rows returned from Postgres and lower wall-clock time overall.

5. **Re-disable slow logging** when done:
   ```sql
   ALTER SYSTEM SET log_min_duration_statement = -1;
   SELECT pg_reload_conf();
   ```

---

### Trade-offs of raising the threshold

| Aspect | Default (256) | Raised (1024) |
|---|---|---|
| **Pushdown precision** | Weak — compacts to BETWEEN after 256 values | Strong — preserves exact IN-list up to 1024 |
| **Postgres SQL parsing cost** | Low | Slightly higher but negligible for 1024 values |
| **Network overhead** | Low | Minor increase (longer SQL text — kilobytes, not megabytes) |
| **Postgres index use** | BETWEEN may use range scan; can miss exact values | IN-list often uses bitmap index scan for selective columns |
| **When to raise** | Your join build side regularly exceeds 256 distinct values | Exactly your scenario — multi-tenant joins with 300–1000 active tenants per query |
| **When NOT to raise** | (rarely a downside at 1024) | If the build side has 10K+ values → consider replication to Iceberg instead |

---

### Summary

| Setting | Value | Scope | Requires restart? |
|---|---|---|---|
| `domain-compaction-threshold` (default) | 256 | PostgreSQL connector | — |
| `SET SESSION app_pg.domain_compaction_threshold = 1024` | 1024 | Current session only | No |
| `domain-compaction-threshold=1024` in catalog `.properties` | 1024 | All queries to this catalog | Yes (coordinator restart) |

Start with `SET SESSION app_pg.domain_compaction_threshold = 1024` to test immediately, then verify against the Postgres slow log. Once confirmed effective, promote it to the catalog properties file for all queries.
