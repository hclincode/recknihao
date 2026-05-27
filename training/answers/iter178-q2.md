# Iter 178 Q2 — Cross-Catalog Transactions in Trino: Postgres + Iceberg

## Answer

**Trino cannot atomically transact across different catalogs.** This is a hard architectural constraint, not a configuration limitation. Here's exactly what happens and what you should do instead.

---

### The Fundamental Limitation

Trino is a **federated query engine**, not a distributed transaction coordinator. When you write to `app_pg.feature_flags` and `events_iceberg.audit_log` in the same Trino session, you are executing **two independent single-catalog transactions** — one in Postgres, one in Iceberg. Trino has no mechanism to coordinate a two-phase commit across them.

Each connector maintains its own transaction isolation:
- **PostgreSQL connector**: JDBC autoCommit per statement — each INSERT commits immediately to Postgres when it completes.
- **Iceberg connector**: atomic metadata-pointer swap in the Hive Metastore — the Iceberg INSERT commits when HMS atomically replaces the metadata JSON pointer.

There is no shared transaction log and no rollback mechanism that spans both.

---

### What Actually Happens When You Try

If you run two INSERTs in sequence through Trino:

```sql
-- Statement 1
INSERT INTO app_pg.feature_flags (feature_id, enabled) VALUES (123, true);

-- Statement 2
INSERT INTO events_iceberg.audit_log (event_type, feature_id, ts) VALUES ('flag_enabled', 123, now());
```

Execution:
1. Statement 1: Trino opens a JDBC connection to Postgres, executes the INSERT, Postgres **commits immediately**. Done.
2. Statement 2: Trino writes Parquet files to MinIO for the audit log, then commits the Iceberg metadata pointer in HMS.
3. If Statement 2 fails (HMS timeout, MinIO full, network failure): **Statement 1 is already committed and cannot be rolled back.** Your tables are now inconsistent.

---

### Failure Modes in Production

**Mode 1: Postgres succeeds, Iceberg fails (most common)**
- Feature flag is active in Postgres.
- Audit log event is missing from Iceberg.
- Users see the feature change; security audit shows nothing.
- Debugging requires cross-system time correlation.

**Mode 2: Iceberg succeeds, Postgres fails (rare but nasty)**
- Audit log says the flag changed.
- The flag didn't actually change in Postgres.
- Analytics reports "100 flag changes this hour" but the feature is still off.

**Mode 3: Both succeed but at different visible times**
- Postgres write is immediately visible to all readers.
- Iceberg write is visible only after the metadata pointer swap completes (seconds later).
- A concurrent query reads the flag as enabled before the audit event is queryable.
- The events appear to have happened at different times even in the same SQL session.

---

### Why Cross-Catalog Transactions Are Impossible

Even a theoretical cross-catalog transaction would require:

1. **A shared transaction coordinator** both Postgres and Iceberg acknowledge. They have no common transaction log or two-phase commit protocol. Postgres is a JDBC database with its own MVCC engine. Iceberg is a table format on MinIO with metadata in a separate HMS — they have no way to communicate with each other.

2. **Matching rollback semantics**. Once a Postgres transaction commits, every other Postgres client immediately sees that row. You cannot "pretend it didn't happen." Iceberg's atomicity is at the table-metadata level (replacing the metadata JSON pointer), not row-level — the granularities don't even match.

3. **A Trino coordinator that acts as a 2PC coordinator**. Trino does not implement this. The Hive Metastore is not a transaction coordinator — it only stores metadata pointers.

---

### The Correct Pattern: Application-Level Coordination

**You must handle this in your application code, not in Trino.**

**Pattern 1: Postgres as source of truth, async replication to Iceberg**

This is the recommended approach for your use case:

```python
# Application code (pseudo-code)
try:
    # Write to Postgres in a single transaction (the authoritative write)
    with pg_connection.transaction():
        pg_connection.execute(
            "INSERT INTO feature_flags (feature_id, enabled) VALUES (%s, %s)",
            (123, True)
        )
        pg_connection.execute(
            "INSERT INTO audit_log_pg (event_type, feature_id, ts) VALUES (%s, %s, now())",
            ('flag_enabled', 123)
        )
    # Both committed atomically in Postgres.

    # Async: replicate audit events to Iceberg separately (Debezium, Spark, or a queue)
    # If this fails, you retry — the Postgres data is your source of truth

except Exception as e:
    # Postgres transaction rolls back atomically. No inconsistency.
    raise
```

Keep both writes in Postgres for atomicity. Then use Debezium CDC or a nightly Spark job to replicate the Postgres audit log into `events_iceberg.audit_log` for analytics. The Iceberg copy may lag by seconds to minutes — that's acceptable for an audit trail.

**Pattern 2: Write-ahead in Postgres, retry Iceberg asynchronously**

If you need both systems current:

1. Write to Postgres first (the critical system, rolls back if it fails).
2. Enqueue the Iceberg write to a durable message queue (Kafka, SQS, Redis).
3. A consumer writes to Iceberg asynchronously with retry.
4. If the Iceberg write fails repeatedly, alert for manual intervention.

The Iceberg audit log is eventually consistent — it will catch up, but may lag briefly.

**Pattern 3: Treat the audit log as eventually consistent**

Accept that the two systems are not synchronized in real time. Write to Postgres first (critical), then write to Iceberg separately. If Iceberg fails, retry with exponential backoff. If the Iceberg write never succeeds, reconcile periodically by comparing Postgres audit log to Iceberg audit log.

---

### What NOT to Do

**Do not rely on Trino for transactional consistency across catalogs.**

Even wrapping two Trino INSERTs in a `BEGIN`/`COMMIT` block doesn't help — Trino's transaction boundaries only coordinate commits within a single catalog. A `BEGIN`/`COMMIT` wrapping both INSERTs still leaves you with two independent single-catalog transactions under the hood.

---

### Long-Term Recommendation

**Consolidate your source of truth.** For the `feature_flags` + `audit_log` use case:

- Keep both tables in Postgres for the operational path (atomicity guaranteed by Postgres transactions).
- Replicate the Postgres `audit_log` table to Iceberg nightly or via CDC for analytics queries.
- This gives you: atomic consistency in production + historical analytical queries on Iceberg.

The Iceberg copy may be 1-24 hours stale for analytics, but your operational consistency is never at risk. For security audit use cases, a 24-hour lag in the analytics copy is usually acceptable — the authoritative record is always in Postgres.
