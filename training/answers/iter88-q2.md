# Iter88 Q2 — Answer

**Question**: Setting up Debezium CDC from Postgres to Kafka → Iceberg. Hitting confusing errors. What are WAL level, replication slots, and publications? What needs to be configured in Postgres before Debezium can work? In what order?

---

## Answer

Before you start Debezium, your Postgres primary needs five specific pieces of configuration. Here's what each one is, why Debezium needs it, and the exact SQL/command to run.

**The big picture first:** Debezium works by reading Postgres's write-ahead log (WAL) — think of it as Postgres's internal journal of every change it commits. But Postgres doesn't write enough detail to that journal by default. These five prerequisites tell Postgres: "I need you to write more detail and keep the journal around long enough for me to read it."

---

### 1. Set `wal_level = logical` in postgresql.conf

**What it is:** A configuration parameter that controls how much detail Postgres writes to its write-ahead log.

**Why Debezium needs it:** By default, `wal_level = replica` writes enough WAL for streaming replication (a read replica catching up). But Debezium needs `logical` mode, which writes complete before-and-after column values for every change — not just enough for replica sync.

**Critical gotcha:** This requires a **Postgres restart**. Schedule maintenance downtime before this step.

```bash
# Edit postgresql.conf (location varies by install):
wal_level = logical

# Then restart Postgres:
sudo systemctl restart postgresql

# Verify:
SHOW wal_level;   -- must return 'logical'
```

---

### 2. Create a publication

**What it is:** A Postgres declaration of "these are the tables I want to send change events for."

**Why Debezium needs it:** Debezium doesn't listen to every table by default — you explicitly declare which tables to stream. This is a safety feature: you only get change events for the tables you're intentionally watching.

```sql
CREATE PUBLICATION debezium_pub FOR TABLE events, users, orders;
```

To add tables later (no restart needed):
```sql
ALTER PUBLICATION debezium_pub ADD TABLE products;
```

---

### 3. Set `REPLICA IDENTITY FULL` on each table

**What it is:** A table-level setting that controls how much information Postgres stores about old column values in the WAL.

**Why Debezium needs it:** By default (`REPLICA IDENTITY DEFAULT`), when a row is updated or deleted, the WAL only records the **primary key** in the before-image. If your Spark MERGE INTO needs to check non-key columns (like `WHEN MATCHED AND s.tenant_id = 'acme' THEN DELETE`), those columns won't exist in the before-image and the filter fails silently or errors.

Setting `FULL` tells Postgres to store all column values before an UPDATE or DELETE. This doubles WAL volume for UPDATE-heavy tables — acceptable for most SaaS workloads.

```sql
ALTER TABLE events REPLICA IDENTITY FULL;
ALTER TABLE users REPLICA IDENTITY FULL;
-- Repeat for every table in your publication that you UPDATE or DELETE
-- (append-only tables like audit_log can stay at DEFAULT)
```

---

### 4. Create a logical replication slot

**What it is:** A bookmark Postgres maintains for "where has this consumer read in the WAL so far?"

**Why Debezium needs it:** Without a slot, Postgres will delete old WAL segments before Debezium gets a chance to read them. You'll hit "requested WAL segment has already been removed" errors. A slot tells Postgres: "Don't delete WAL segments until slot `debezium_slot` has read them."

```sql
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
-- 'pgoutput' is the built-in Postgres logical replication plugin (use this, not wal2json)
```

The slot name must match the `slot.name` property in your Debezium connector config. The slot persists across Postgres restarts — you create it once.

---

### 5. Grant permissions to the Debezium user

**Why Debezium needs it:** Debezium runs under a database user. That user needs permission to read your tables and access the replication slot.

```sql
GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;
GRANT REPLICATION ON DATABASE app TO debezium_user;
GRANT USAGE ON SCHEMA public TO debezium_user;
```

Replace `debezium_user` and `app` with your actual Debezium user account and database name.

---

### Verification — run this before starting Debezium

```sql
SHOW wal_level;                                                    -- must say 'logical'
SELECT * FROM pg_publication WHERE pubname = 'debezium_pub';      -- must return one row
SELECT * FROM pg_replication_slots WHERE slot_name = 'debezium_slot'; -- must return one row
```

If any of these return empty or wrong values, Debezium will fail with a cryptic error. Fix the prerequisite first.

---

### Order of operations

1. Edit `postgresql.conf` → set `wal_level = logical` → restart Postgres (only downtime-requiring step)
2. Verify: `SHOW wal_level;` returns `logical`
3. Create the publication
4. Set `REPLICA IDENTITY FULL` on each table
5. Create the logical replication slot
6. Grant permissions to the Debezium user
7. Run the three verification queries above — all must pass

Once all five prerequisites are in place and verified, Debezium will start and begin streaming changes from your Postgres WAL into Kafka within seconds of connecting.
