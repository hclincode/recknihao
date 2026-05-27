# Iter275 Q1 — Atomic Cross-Catalog Writes in Trino: Postgres + Iceberg Together

## Answer

**No** — Trino cannot write to both Postgres and Iceberg in one atomic transaction. Each catalog commits independently. If Postgres succeeds but Iceberg fails, you are left with the Postgres write committed and the Iceberg write absent. There is no automatic rollback across catalogs.

### Why Trino Cannot Do Cross-Catalog Transactions

Trino is a federated SQL engine — it connects to many independent data sources, each with its own transactional semantics. Trino does not manage a distributed transaction coordinator (like XA or two-phase commit) that would enforce atomicity across multiple systems.

Each write to each catalog commits to that catalog alone. If you run two separate statements:

```sql
-- Statement 1: Update Postgres
UPDATE app_pg.public.accounts SET status = 'updated' WHERE id = 42;

-- Statement 2: Append to Iceberg (separate statement)
INSERT INTO iceberg.analytics.audit_log (account_id, action, timestamp)
VALUES (42, 'account_update', CURRENT_TIMESTAMP);
```

If Statement 1 succeeds and Statement 2 fails (Iceberg metadata service unreachable, S3 unavailable, etc.), you have:
- **Postgres**: UPDATE committed. Row is permanently changed.
- **Iceberg**: No record. Audit log is missing the event.

No rollback happens to Postgres. Trino made no promise it would.

### What Trino Actually Guarantees

- **Per-statement atomicity within a single target catalog**: An `INSERT INTO iceberg.analytics.events SELECT ...` is atomic within Iceberg — all rows appear or none do.
- **No cross-statement coordination**: Trino does not track Statement 1 to Postgres and Statement 2 to Iceberg as a unit. Each catalog sees only its own statement.
- **No distributed transaction manager**: Trino is a compute layer, not a transaction coordinator.

### The Right Patterns: Three Options

**Pattern 1: Application-level coordination (recommended)**

Keep the application responsible for ordering and recovering from failures:

```python
def update_account_and_log(account_id):
    # Step 1: Update operational Postgres
    pg_conn.execute("UPDATE accounts SET status = 'updated' WHERE id = %s", account_id)
    pg_conn.commit()  # Atomic within Postgres

    # Step 2: Append audit record to Iceberg
    try:
        trino_conn.execute(
            "INSERT INTO iceberg.analytics.audit_log (account_id, action, ts) "
            "VALUES (%s, 'account_update', CURRENT_TIMESTAMP)",
            account_id
        )
        trino_conn.commit()
    except Exception as e:
        # Log the failure — do NOT roll back Postgres (it already committed)
        log_audit_failure(account_id=account_id, error=str(e))
        enqueue_retry(account_id=account_id)
        raise
```

Make the Iceberg write **idempotent**: use a unique key (event ID, timestamp + account_id) so retries don't create duplicate audit entries.

**Pattern 2: Postgres as source of truth + async CDC (best for audit logs)**

Instead of a dual write, stream Postgres changes to Iceberg asynchronously via CDC:

```
Postgres (with logical replication / Debezium)
   → Kafka topic (buffers if Iceberg is temporarily unavailable)
   → Spark Structured Streaming / Flink
   → Iceberg audit_log (MERGE or INSERT)
```

Postgres commits atomically. Iceberg receives the change within seconds, with Kafka buffering retries if needed. The audit log is **eventually consistent** — you never lose an event, and you never block the Postgres write waiting for Iceberg.

**Pattern 3: Postgres-only write, batch sync to Iceberg**

Write everything to Postgres (including the audit row). Run a nightly or hourly MERGE INTO Iceberg from the Postgres audit table:

```sql
-- Hourly sync job: Postgres audit_log → Iceberg analytics.audit_log
MERGE INTO iceberg.analytics.audit_log AS target
USING (
  SELECT account_id, action, timestamp
  FROM app_pg.public.audit_log
  WHERE timestamp > CURRENT_TIMESTAMP - INTERVAL '2' HOUR
) AS source
ON target.account_id = source.account_id
  AND target.timestamp = source.timestamp
WHEN NOT MATCHED THEN
  INSERT (account_id, action, timestamp)
  VALUES (source.account_id, source.action, source.timestamp);
```

Postgres is the system of record. Iceberg is a read-optimized copy that's 1–2 hours behind. Simple and robust.

### What IS and IS NOT Possible in Trino SQL

```sql
-- ALLOWED: single-catalog write (atomic within Iceberg)
INSERT INTO iceberg.analytics.audit_log (account_id, action, ts)
SELECT 42, 'account_update', CURRENT_TIMESTAMP;

-- ALLOWED: single-catalog write to Postgres (atomic within Postgres)
UPDATE app_pg.public.accounts SET status = 'updated' WHERE id = 42;

-- NOT SUPPORTED: DML targeting two catalogs in one atomic statement
-- Trino has no syntax or semantics for this

-- ALLOWED BUT NOT ATOMIC: two separate statements
-- Each commits independently — partial failure leaves inconsistent state
INSERT INTO iceberg.analytics.audit_log ...;
UPDATE app_pg.public.accounts ...;
```

### Key Points

1. **Trino does not support cross-catalog transactions.** No two-phase commit, no XA coordinator. This is by design — Trino is a query engine, not a transaction manager.

2. **Partial failure is the default.** Design your application to handle "Postgres succeeded, Iceberg failed" explicitly. Make the Iceberg write idempotent so retries are safe.

3. **Coordination belongs in your application.** Your app controls the transaction context for each system separately.

4. **For audit logs specifically**, CDC via Debezium + Kafka is the cleanest solution — decouples the write latency and handles Iceberg unavailability gracefully via Kafka buffering.

5. **If you need strict consistency**, keep Postgres as the sole write target and replicate to Iceberg on a schedule — one system of truth eliminates the dual-write coordination problem entirely.
