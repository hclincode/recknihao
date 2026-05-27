# Iter 206 Q2 — Verifying Predicate Pushdown via pg_stat_activity and Postgres Logs

## Answer

Yes, you can use `pg_stat_activity` to watch what SQL Trino actually sends to Postgres — and it's one of the best ground-truth verification methods. Here's how to use it, the gotchas, and when to use the more durable slow-query log instead.

### 1. Yes — pg_stat_activity shows Trino's actual SQL

While a Trino query is running, query the Postgres replica's active session view:

```sql
-- On the Postgres replica, while a Trino query runs:
SELECT pid, usename, query, query_start, state, wait_event
FROM pg_stat_activity
WHERE usename = 'trino_reader'   -- or whatever Trino's Postgres role is
  AND query NOT LIKE '%pg_stat_activity%';
```

The `query` column is the literal SQL Postgres received from Trino's JDBC connector.

**Pushdown SUCCEEDED** — you see the WHERE clause:
```sql
SELECT id, status, order_date, amount FROM public.orders 
WHERE order_date >= DATE '2026-05-01' AND status = 'active'
```

**Pushdown FAILED** — bare SELECT with no WHERE:
```sql
SELECT id, status, order_date, amount FROM public.orders
```

If pushdown failed, Trino fetched the entire table over JDBC and filtered locally in-memory — this is the disaster case.

---

### 2. Catching queries before they finish — timing techniques

The gotcha you identified is real: queries finish too fast to spot in `pg_stat_activity`.

**Technique A: Open two terminals (most practical)**

- Terminal 1: Run your Trino query (it blocks until it finishes).
- Terminal 2: SSH to the Postgres replica and poll:

```bash
watch -n 0.5 'psql -U postgres -c "SELECT pid, query, query_start FROM pg_stat_activity WHERE usename = '\''trino_reader'\''"'
```

The `watch` command reruns every 0.5 seconds. You can see queries appear and disappear as the Trino scan runs.

**Technique B: Slow query logging** — the durable alternative (see Section 3 below).

---

### 3. Slow-query logging — the production-friendly ground truth

For reliable verification without chasing active sessions, enable Postgres slow-query logging. Queries are captured to the log even if they finish before you check `pg_stat_activity`:

```sql
-- On the Postgres replica, as superuser:
ALTER SYSTEM SET log_min_duration_statement = 0;  -- log ALL queries (ms)
SELECT pg_reload_conf();

-- Now run your Trino query from the coordinator.

-- Check the slow log on the replica:
tail -f /var/log/postgresql/postgresql.log | grep -A 2 'statement:'

-- Disable after testing:
ALTER SYSTEM SET log_min_duration_statement = -1;
SELECT pg_reload_conf();
```

**Why this is better than pg_stat_activity for verification:**
- Queries are captured even if they finish in microseconds.
- The log is durable — review it hours later.
- Shows actual execution time (tells you if Postgres was slow, not just what SQL it received).
- No timing coordination needed.

**Gotcha**: `log_min_duration_statement=0` logs *everything* and is I/O heavy on the replica. Use only during a test window (a few minutes). For ongoing monitoring, set it to `5000` (5 seconds) to catch only slow queries.

The official Trino docs call Postgres slow-query logging **"the definitive proof"** — the Trino EXPLAIN view can occasionally be ambiguous, but the SQL Postgres actually receives is not.

---

### 4. What success vs. failure looks like in the Postgres log

**Pushdown SUCCEEDED** (WHERE clause present, fast execution):
```
2026-05-26 14:23:45 UTC [12345] trino_reader@appdb LOG:
  duration: 1.234 ms
  statement: SELECT id, status, order_date FROM public.orders
             WHERE order_date >= DATE '2026-05-01' AND status = 'active'
```

Predicates in the WHERE clause, execution in 1ms, index was used.

**Pushdown FAILED** (bare SELECT, slow execution):
```
2026-05-26 14:23:46 UTC [12346] trino_reader@appdb LOG:
  duration: 3456.789 ms
  statement: SELECT id, status, order_date FROM public.orders
```

No WHERE clause. Postgres returned all rows. Duration jumped from 1ms to 3.5 seconds — the entire table streamed over JDBC. Trino workers filtered locally.

---

### 5. How this complements EXPLAIN — use both for confidence

**Two-step verification workflow:**

**Step 1: Check the plan shape with EXPLAIN (TYPE DISTRIBUTED)** — fast, no execution cost:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.users
WHERE status = 'active' AND created_at >= DATE '2026-05-01';
```

**Pushdown planned** — `constraint on` block under the TableScan:
```
TableScan[table = app_pg:public.users, ...]
    constraint on [status, created_at]
        status = 'active'
        created_at >= DATE '2026-05-01'
```

**Pushdown NOT planned** — `ScanFilterProject` / `Filter` node ABOVE the TableScan:
```
ScanFilterProject[filterPredicate = (status = 'active') AND (created_at >= DATE '2026-05-01')]
    TableScan[table = app_pg:public.users, ...]
```

**Step 2: Confirm with Postgres slow-query log** — ground truth:

Enable `log_min_duration_statement=0` for a test window, run the Trino query, and grep the log. If the WHERE clause appears in the logged statement, pushdown actually happened. If it doesn't, it failed despite what EXPLAIN said.

**Why both?**
- EXPLAIN tells you what the planner *intended* — fast diagnosis.
- Postgres logs tell you what *actually* happened — the real proof, with timing.
- Rarely, a connector can fail to push a predicate at execution time even when EXPLAIN showed it would (unsupported predicate types, type mismatch). Postgres logs catch that gap.

---

### Practical workflow for Trino 467 on k8s (on-prem Postgres)

```bash
# 1. On the Trino coordinator — check the plan:
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.orders WHERE status = 'active' AND amount > 100;

# 2. On the Postgres replica — enable logging for 2 minutes:
psql -U postgres -c "ALTER SYSTEM SET log_min_duration_statement = 0; SELECT pg_reload_conf();"

# 3. Back on Trino coordinator — run the actual query.

# 4. On Postgres replica — check the log:
tail -20 /var/log/postgresql/postgresql.log | grep "statement:"

# 5. Disable logging:
psql -U postgres -c "ALTER SYSTEM SET log_min_duration_statement = -1; SELECT pg_reload_conf();"
```

If the log shows the WHERE clause → pushdown confirmed. If not → check for unsupported predicate types (string LIKE without `enable_string_pushdown_with_collate`, JSON operators, function-wrapped columns).
