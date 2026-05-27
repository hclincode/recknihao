# Trino CBO, ANALYZE, Puffin Statistics, NDV, and Join Ordering

A guide for SaaS engineers who have never heard of a "cost-based optimizer" and want to know why their multi-table join in Trino is slow, what `ANALYZE` actually does for an Iceberg table, and how three different layers of statistics work together.

> **Trino syntax warning — read this once and remember it:** Trino's command is `ANALYZE schema.table` — there is **NO** `TABLE` keyword. `ANALYZE TABLE schema.table` is **Spark/Hive syntax** and will fail in Trino with a parser error. If you've used Spark or Hive recently, this is the single most common copy-paste bug.

> **Production stack assumed**: Trino 467 + Iceberg connector + Hive Metastore + MinIO (S3) on-prem k8s, with ingestion via Spark 3 + Iceberg 1.5.2. JWT auth, OPA authz.

---

## TL;DR (read these 6 sentences first)

1. Iceberg **auto-collects per-file min/max statistics** on every write — these power **file skipping** at scan time. No `ANALYZE` needed for that.
2. Iceberg does **NOT** auto-collect **NDV** (number of distinct values) or histograms. Those are what Trino's **cost-based optimizer (CBO)** needs to pick a good join order. Without them the optimizer guesses.
3. To populate NDV stats, run `ANALYZE iceberg.analytics.events` from Trino. The result is written as a **Puffin file** (a small `.stats` blob) next to the table's metadata in MinIO.
4. Stats do **not auto-update** when new data arrives. Re-run `ANALYZE` on a recurring schedule (weekly, or after large ingests), otherwise the CBO starts working from stale numbers.
5. **If you switch from full-table ANALYZE to a column subset on the SAME table, you MUST first run `ALTER TABLE <t> EXECUTE drop_extended_stats`** — otherwise the previously-collected per-column Puffin entries linger and the column-targeted ANALYZE may not update stats as expected. See section 4.5.
6. There are **three independent layers** of optimization: (a) Iceberg partition pruning, (b) Iceberg file/data skipping via min/max, (c) Trino CBO join ordering via NDV. They are NOT the same thing and they fix different problems.

> **Two pasteable rules that prevent the most common ANALYZE bugs on Iceberg:**
>
> - **Never use `WITH (partitions = ARRAY[...])` on the Iceberg connector** — it is a **Hive-only** property and will fail at runtime with `Catalog 'iceberg' analyze property 'partitions' does not exist`. The only Iceberg ANALYZE property is `columns`. (See section 4.)
> - **Before switching from a full-table ANALYZE to a column-subset ANALYZE** (or whenever `SHOW STATS` shows stale or suspicious NDV after a column-targeted run), run `ALTER TABLE iceberg.<schema>.<table> EXECUTE drop_extended_stats` first, then the column-subset ANALYZE. (See section 4.5.)

---

## 1. What is a "cost-based optimizer" and why should a SaaS engineer care?

When you write a query that joins three tables:

```sql
SELECT u.email, t.name, COUNT(*) AS event_count
FROM iceberg.analytics.events e
JOIN iceberg.app.users     u ON e.user_id   = u.id
JOIN iceberg.app.tenants   t ON u.tenant_id = t.id
WHERE e.occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND t.plan = 'enterprise'
GROUP BY u.email, t.name;
```

Trino has to decide:

- **In what order** to perform the two joins. (Join `events` to `users` first, then to `tenants`? Or join `users` to `tenants` first, then to `events`?)
- **Which side of each join is the "build" (small, hashed in memory) and which is the "probe" (large, streamed past the hash table).**
- **Whether to broadcast** the build side to every worker (broadcast join) or **redistribute by hash** (partitioned join).
- **How much memory** to reserve for each operator.

Picking right vs picking wrong can be the difference between **a query that runs in 5 seconds and one that runs for 45 minutes**, on the exact same data. The component that makes these decisions is called the **cost-based optimizer**, or **CBO** for short.

To make sound choices the CBO needs to **estimate how many rows each operator will produce**. To estimate that, it needs to know:

- How many rows are in each table (Iceberg knows this from metadata — it's free).
- How many **distinct values** each join key has (this is the **NDV** — number of distinct values — and Iceberg does **not** auto-collect it).
- Roughly how values are distributed (histograms, also not auto-collected).

Without NDV, the CBO falls back to defaults and heuristics. The defaults are reasonable for small symmetric joins; they go badly wrong for **skewed data**, **highly selective filters**, and **large-vs-tiny dimension joins** — which are exactly the patterns most SaaS analytical queries hit.

---

## 2. What Iceberg auto-collects (no ANALYZE required)

Every time Spark or Trino writes a Parquet file into an Iceberg table, the writer records a small block of statistics **for each column in each file** into the Iceberg **manifest file** that tracks that data file. Specifically:

| Statistic | Auto-collected? | What it's used for |
|---|---|---|
| Min value per column per file | YES | File skipping (data-skipping) |
| Max value per column per file | YES | File skipping |
| Null count per column per file | YES | Predicate evaluation, NULL-aware pruning |
| Total row count per file | YES | Row-count estimates, planning |
| **NDV (distinct value count)** | **NO** | Join ordering, cardinality estimates |
| **Column histograms** | **NO** | Range cardinality, skew detection |

### How file skipping (a.k.a. data skipping) works

Suppose a Parquet file has `occurred_at` values ranging from `2026-04-01` to `2026-04-15` (the manifest stores `min=2026-04-01` and `max=2026-04-15` for that file). You run:

```sql
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00';
```

Trino reads the manifest, sees that the file's `[2026-04-01, 2026-04-15]` range cannot possibly contain rows where `occurred_at >= 2026-05-01`, and **skips the file entirely** — no Parquet I/O at all. That's **file pruning** and it is **always on**. You do not need ANALYZE to get this.

The catch: file skipping only helps if **data is sorted or clustered** within the table by the predicate column. If you write events in random order, every file's `[min, max]` covers nearly the full date range, and no file gets skipped. (See `resources/17-iceberg-table-maintenance.md` for `rewrite_data_files` with `sort_order`, and section 6 below for the `sorted_by` table property.)

---

## 3. What Iceberg does NOT auto-collect — and why it matters

Iceberg does **not** automatically know:

- How many **distinct user IDs** appear in `events`. Is it 10? Is it 50 million? Big difference for join planning.
- How many **distinct tenant IDs** appear in `users`. Tells the CBO how selective `tenant_id = X` is.
- The **shape of the distribution** — does one tenant generate 90% of events, or are they uniform?

Without those numbers, the CBO defaults to assuming things like "the join produces 10% of the larger side's rows," which is often very wrong. When the CBO guesses wrong about join cardinality, three concrete bad things happen:

1. **Join order is wrong.** The optimizer might build a hash table on a 500M-row side because it thinks the other side is bigger, exhausting worker memory and spilling to disk.
2. **Broadcast vs partitioned decision is wrong.** If the CBO underestimates the build side, it tries to broadcast it to every worker and OOMs the cluster. Overestimate, and it picks an unnecessarily expensive partitioned (shuffle) join.
3. **Memory reservation is wrong.** Operators ask for too much or too little, which interacts badly with concurrent queries on the same cluster.

The fix is to populate NDV statistics by running `ANALYZE`.

---

## 4. `ANALYZE` in Trino — the command itself

Trino's Iceberg connector exposes an `ANALYZE` statement that walks the table, computes column statistics (including NDV), and writes them to a **Puffin file** alongside the table's existing metadata in MinIO.

### 4.1 Basic syntax

```sql
-- Analyze every column of the table:
ANALYZE iceberg.analytics.events;

-- Analyze just specific columns (cheaper for wide tables):
ANALYZE iceberg.analytics.events WITH (columns = ARRAY['user_id', 'tenant_id', 'event_type']);
```

> **CRITICAL — `partitions` property is Hive-only, NOT Iceberg.** The Trino **Iceberg connector's `ANALYZE` only supports ONE property: `columns`**. The `partitions = ARRAY[...]` property is a **Hive connector feature only**. If you paste an Iceberg ANALYZE with `WITH (partitions = ARRAY[...])`, Trino will fail with:
>
> ```
> Catalog 'iceberg' analyze property 'partitions' does not exist
> ```
>
> For Iceberg tables, to limit ANALYZE work:
> - Use `WITH (columns = ARRAY[...])` to scope to specific columns (much faster than full-table on wide tables — this is the main lever you have).
> - To refresh stats incrementally for recent data, run `ANALYZE` after each ingest job — Iceberg's stats infrastructure processes the new snapshot's data files, not the whole table from scratch, so an `ANALYZE` after a small append is much cheaper than a cold full-table ANALYZE.
> - If you truly need partition-scoped analysis behavior, that is only available on the **Hive connector**, e.g. `ANALYZE hive.analytics.events WITH (partitions = ARRAY[ARRAY['2026-05']])`. Do **not** assume the same syntax works on Iceberg.

This is a normal Trino DML statement. It runs as a query in the Trino UI, can be killed mid-flight, and obeys the same OPA permissions as any other write. It can take from seconds (small tables) to many minutes (hundreds of millions of rows) — it is doing a real scan to count distinct values.

### 4.2 What `ANALYZE` produces — Puffin files

The output of `ANALYZE` is a **Puffin file**: a small binary file (typically a few hundred KB to a few MB) that lives in the same metadata directory as the table's `.metadata.json` files inside MinIO. Filenames look like:

```
s3://lakehouse/warehouse/analytics/events/metadata/
    00012-a1b2c3d4-...-snap-1234567890123456789.stats
```

The `.stats` extension is the Puffin file. It stores **NDV sketches** (typically the Theta sketch or HLL family — a compact, ~4–8 KB-per-column data structure that lets the CBO answer "approximately how many distinct values are in this column?" in O(1) time without re-scanning data).

You do not need to manage Puffin files directly. Iceberg's snapshot model knows about them: every snapshot points at the Puffin file that was current at the time. When you expire old snapshots (via `expire_snapshots`), orphaned Puffin files are cleaned up by `remove_orphan_files` like any other unreferenced file.

### 4.3 Verifying that stats are populated

After running `ANALYZE`, check what Trino now knows by querying the metadata:

```sql
-- Show per-column statistics the CBO will use:
SHOW STATS FOR iceberg.analytics.events;
```

The output looks like:

```
 column_name | data_size | distinct_values_count | nulls_fraction | row_count | low_value | high_value
-------------+-----------+-----------------------+----------------+-----------+-----------+-----------
 user_id     |   8.0E6   |       1.45E5          |     0.0        |   5.0E8   |     1     |  500000
 tenant_id   |   8.0E6   |       2.5E2           |     0.0        |   5.0E8   |     1     |    250
 ...
 NULL        |   NULL    |        NULL           |     NULL       |   5.0E8   |   NULL    |   NULL
```

If `distinct_values_count` is **NULL** for the columns you join on, ANALYZE has not been run (or has been run for other columns only). Re-run `ANALYZE` with the right column list.

### 4.4 Reducing ANALYZE cost on large Iceberg tables

For a large Iceberg table, you do **not** have a "ANALYZE one partition only" knob — the `partitions` property is **Hive-only** (see callout above). The Iceberg-friendly ways to keep ANALYZE cheap are:

1. **Column-targeted ANALYZE.** Use `WITH (columns = ARRAY[...])` to scope to the join keys and high-selectivity filter columns only. On a wide table (50+ columns), targeting just the 4-5 join keys can reduce ANALYZE wall time by an order of magnitude versus a full-column scan.

   ```sql
   -- Far cheaper than `ANALYZE iceberg.analytics.events` on a 50-column table:
   ANALYZE iceberg.analytics.events
     WITH (columns = ARRAY['user_id', 'tenant_id', 'event_type']);
   ```

2. **Run ANALYZE shortly after each ingest.** Iceberg's stats are snapshot-aware. Running `ANALYZE` after a smaller append job costs much less than running it on a long-cold table, because the underlying scan touches the most recent data alongside cached stats infrastructure.

3. **Stagger ANALYZE across tables instead of running them all at once.** Schedule each table's ANALYZE in a separate cron slot so they don't contend for the same worker resources.

If your real goal is "I want partition-scoped ANALYZE behavior because my table is too big to scan", the right architectural answer on Iceberg is usually: keep the column list small AND make sure your ingest cadence triggers ANALYZE on a snapshot that already has good file layout (run compaction before ANALYZE, see section 6).

### 4.5 Re-analyzing specific columns on a previously-analyzed table — `drop_extended_stats` (read this carefully)

This is the **single most important footgun** when running ANALYZE on Iceberg in production. If you previously ran a **full-table** ANALYZE:

```sql
ANALYZE iceberg.analytics.events;   -- collects stats for ALL columns
```

…and now you want a **faster column-targeted** run (e.g., refreshing only the join keys after a backfill), you must **first drop the existing extended stats**. Otherwise Trino keeps the old per-column Puffin entries around and the column-targeted ANALYZE may not update statistics the way you expect — `SHOW STATS` may keep showing the old NDV values long after you "refreshed" them.

**The required two-step recipe** (memorize this — it comes up every time someone tries to make ANALYZE cheaper):

```sql
-- Step 1: drop the existing extended stats
ALTER TABLE iceberg.analytics.events EXECUTE drop_extended_stats;

-- Step 2: now run the column-targeted ANALYZE
ANALYZE iceberg.analytics.events
  WITH (columns = ARRAY['user_id', 'tenant_id', 'event_type']);
```

`drop_extended_stats` is a `ALTER TABLE ... EXECUTE` table procedure (same family as `optimize` and `expire_snapshots`). It removes the Puffin file(s) so the next ANALYZE writes a fresh one. It does NOT touch the per-file min/max stats in manifests (those are auto-collected on write and don't go through Puffin).

Rule of thumb table — when you DO and when you DON'T need `drop_extended_stats`:

| Previous ANALYZE state | Next ANALYZE you want | Need `drop_extended_stats` first? |
|---|---|---|
| No prior ANALYZE (cold table) | Any ANALYZE | NO — nothing to drop. |
| Previously full-table ANALYZE | Full-table ANALYZE again (refresh) | NO — overwrites the Puffin. |
| Previously column-subset ANALYZE | Same columns again | NO — overwrites the Puffin for those columns. |
| Previously column-subset ANALYZE | Different / smaller column subset | NO usually, but YES if you observe the old NDVs persisting in SHOW STATS. |
| **Previously full-table ANALYZE** | **Column-subset ANALYZE** | **YES — required.** |
| Previously column-subset ANALYZE | Full-table ANALYZE | NO — overwrites everything. |

How to diagnose that you forgot it: `SHOW STATS FOR iceberg.analytics.events` after a column-targeted ANALYZE shows `distinct_values_count` values that look stale (an order of magnitude off from what you'd expect after the refresh). The fix is always the same: drop, then ANALYZE again.

> **Why this happens** (conceptually): Iceberg's Puffin file is keyed by the snapshot it was generated against. Running ANALYZE with a smaller column set on top of a Puffin from a wider column set produces a NEW Puffin for the new snapshot, but Trino's lookup logic in some cases still resolves stats from the older Puffin for columns not in the new run. `drop_extended_stats` removes the older Puffin so there is no fallback path.

---

## 5. CBO behavior with vs without stats

This is the core "why ANALYZE matters" comparison.

### 5.1 Enabling the CBO (one-time cluster setting or per-session)

```properties
# In coordinator's etc/config.properties (cluster-wide default):
optimizer.join-reordering-strategy=AUTOMATIC
```

Or per session:

```sql
SET SESSION join_reordering_strategy = 'AUTOMATIC';
```

Options are:
- `NONE` — keep the join order exactly as the SQL is written. No reordering.
- `ELIMINATE_CROSS_JOINS` — reorder only to avoid cross joins (the safe minimum).
- `AUTOMATIC` — full CBO-driven reordering based on cost estimates. **This is what you want for analytical queries on production.**

`AUTOMATIC` only does useful work if the CBO has stats to estimate cost from.

### 5.2 What happens WITHOUT ANALYZE (no NDV stats)

The CBO falls back to heuristics:

- It uses **row counts** (always available from manifests) but has no idea **how selective** a predicate is. `WHERE plan = 'enterprise'` could return 1% of rows or 99% — without NDV it guesses with a wide default (often ~10% or ~50%, version-dependent).
- It estimates join cardinality with default selectivity factors. This often picks the wrong build/probe side for highly skewed joins.
- For two large tables, it may broadcast the wrong side and OOM the cluster. Or it might pick a partitioned (shuffle) join even when broadcast would be cheaper.

Symptoms in practice:
- A 3-way join that "should be fast" runs for 20+ minutes.
- `EXPLAIN ANALYZE` shows a tiny side being **probed against** a huge hash table — the build/probe side picks are inverted.
- Queries OOM with "Query exceeded per-node memory limit" because the wrong side was chosen for the build.
- Different join orders for the same logical query produce wildly different wall times.

### 5.3 What happens WITH ANALYZE (NDV stats present)

The CBO can:

- Estimate **post-filter cardinality** accurately for each table. If `plan = 'enterprise'` filters 8M users down to 50K, and the NDV stats on `plan` show 4 distinct values with reasonable distribution, the CBO knows to expect ~50K (not 800K, not 8K).
- Pick the **smaller side as the build side** consistently, even for complex multi-table joins.
- Pick **broadcast vs partitioned join** correctly based on the estimated build-side cardinality (broadcast is cheaper for small builds; partitioned is necessary for large builds that won't fit in worker memory).
- **Choose join order** in 3-way+ joins: e.g., join the two most-selective tables first to produce a small intermediate, then join the big table last with a small probe side.

### 5.4 How to see what the CBO is doing

```sql
EXPLAIN (TYPE LOGICAL)
SELECT u.email, t.name, COUNT(*)
FROM iceberg.analytics.events e
JOIN iceberg.app.users     u ON e.user_id   = u.id
JOIN iceberg.app.tenants   t ON u.tenant_id = t.id
WHERE e.occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND t.plan = 'enterprise'
GROUP BY u.email, t.name;
```

In the output, every operator node prints `Estimates: {rows: N, cpu: ..., memory: ..., network: ...}`. If you see `rows: ?` (a literal question mark) or extremely round defaults, the CBO is guessing — stats are missing for that column.

After `ANALYZE`, re-run the EXPLAIN — the `rows:` estimates will become concrete numbers and the join order in the printed plan may change.

---

## 6. Trino-native compaction and sorting (no Spark needed)

ANALYZE is one of two Trino-native maintenance operations relevant to keeping the CBO useful. The other is **compaction**, which keeps the *underlying file layout* good so file skipping (Layer 2 in the optimization stack) keeps working.

### 6.1 `ALTER TABLE ... EXECUTE optimize` — Trino-native file compaction

Trino 467 supports running file compaction directly, without falling back to Spark for this purpose:

```sql
-- Compact small files in the table to ~256MB targets:
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '256MB');

-- Only compact a specific partition:
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '256MB')
WHERE month = '2026-05';
```

What it does:
- Reads every file in the table (or matching partition) that is **smaller than** `file_size_threshold`.
- Rewrites them into larger files (~the target size).
- Commits a new snapshot.
- Does **NOT** delete the old files immediately — that happens on the next `expire_snapshots` + `remove_orphan_files` cycle (see resource 17).

**Limitation vs Spark's `rewrite_data_files`**: `ALTER TABLE EXECUTE optimize` does NOT sort or cluster data — it only rewrites for size. If you want to **sort** the data within each file (to make file skipping more effective), you must use Spark with the `strategy = 'sort'` form:

```python
# Spark:
spark.sql("""
  CALL iceberg.system.rewrite_data_files(
    table => 'analytics.events',
    strategy => 'sort',
    sort_order => 'occurred_at ASC NULLS LAST'
  )
""")
```

In summary: use `ALTER TABLE EXECUTE optimize` from Trino for **routine size-based compaction** (cheap and easy); use Spark `rewrite_data_files` for **sort-based reclustering** when file skipping has decayed.

### 6.2 `sorted_by` table property — sort newly written data automatically

For *new* Iceberg tables created from Trino, you can declare a sort order at table-creation time, and Trino will write new data pre-sorted by those columns:

```sql
CREATE TABLE iceberg.analytics.events (
    event_id    BIGINT,
    occurred_at TIMESTAMP(6),
    user_id     BIGINT,
    tenant_id   BIGINT,
    event_type  VARCHAR,
    payload     VARCHAR
)
WITH (
    partitioning = ARRAY['month(occurred_at)'],
    sorted_by    = ARRAY['occurred_at ASC', 'tenant_id ASC']
);
```

What it does:
- Every time Trino writes to this table (via `INSERT`, `MERGE`, or `CTAS`), the rows are sorted by `occurred_at` and then `tenant_id` *within each output file*.
- This makes Iceberg manifest min/max statistics **tight** (each file covers a narrow time/tenant range), which makes file skipping highly effective at scan time.
- Existing data is **not** retroactively sorted — `sorted_by` only affects future writes. For existing tables, use the Spark sort-based rewrite above.

The combination of partition spec + `sorted_by` + periodic ANALYZE is the maintenance trifecta that keeps Trino queries fast on Iceberg.

---

## 7. The three-layer optimization stack — keep these straight

This is the most important conceptual table in this document. It is the difference between giving correct advice and giving confusing advice when an engineer asks "why is my Trino query slow?"

| Layer | Mechanism | What it eliminates | Requires ANALYZE? | Always on? |
|---|---|---|---|---|
| **1. Partition pruning** | Iceberg partition spec (`partitioning = ARRAY['day(occurred_at)']`) — at query planning, Trino evaluates the WHERE clause against partition values and discards entire partitions. | **Whole partitions** (= many files at once). | NO | YES (always, free) |
| **2. File pruning / data skipping** | Iceberg manifest per-file min/max stats — at scan time, files whose [min, max] don't overlap the WHERE predicate are skipped without opening the Parquet file. | **Individual files** within a (kept) partition. | NO (min/max are auto-collected) — but effectiveness depends on data layout (sorted/clustered). | YES (always collected); effectiveness varies |
| **3. CBO join ordering** | Trino cost-based optimizer using NDV statistics from Puffin files — at query planning, the optimizer chooses join order, build/probe side, broadcast vs partitioned join, and memory plan. | **CPU and memory for joins** — not data; it picks a cheaper way to execute the same logical plan. | **YES** (`ANALYZE` to populate NDV). | YES (CBO is on); effective only with stats |

Common misconceptions to avoid:

- "Running `ANALYZE` will make my scan faster." Usually NO. `ANALYZE` populates **CBO** stats (Layer 3). It does not change which files are read — that is Layer 2 (min/max). If your problem is "Trino is reading too much data," the fix is partitioning + sort-based compaction, not `ANALYZE`.
- "If I run `ANALYZE`, file skipping will improve." NO. File skipping has been working from the moment data was written (Layer 2 is automatic). `ANALYZE` improves only join ordering.
- "I don't need `ANALYZE` because Iceberg auto-collects stats." Half right. Iceberg auto-collects **min/max/null/row count** (Layer 2). It does NOT auto-collect **NDV** (Layer 3). If you do multi-table joins, you need `ANALYZE` for the CBO.

---

## 8. When does `ANALYZE` matter most?

You do **not** need to run `ANALYZE` on every table. The benefit comes from a specific pattern. Run `ANALYZE` when:

### 8.1 Complex multi-table joins (3 or more tables)

The more tables in a join, the more ways the optimizer can order them — and the more important it is to pick the cheapest order. A 2-table join has 2 possible orders; a 4-table join has 24. The CBO only narrows the search space well with stats.

If your dashboards or dbt models join `events` × `users` × `tenants` × `subscriptions`, `ANALYZE` all four tables.

### 8.2 Highly skewed data distributions

Examples: one tenant generates 80% of all events; one country accounts for 90% of all users. Without NDV + (ideally) histograms, the CBO assumes roughly uniform distribution and picks the wrong build side for tenant-keyed joins.

### 8.3 Large fact joined to small dimension

This is the classic "broadcast the dimension to every worker" case. With stats, the CBO sees that `tenants` has only 250 distinct rows and broadcasts it correctly. Without stats, it may guess the dimension is large and pick a partitioned join (slow shuffle) instead.

### 8.4 After major data ingests or schema/partition changes

Stats become stale when:
- Large batch loads add millions of rows (NDV changes).
- A new tenant onboards that 10x's the user count.
- The partition spec is changed (e.g., from `month(occurred_at)` to `day(occurred_at)` — old stats no longer reflect new layout).

A reasonable cadence is: re-`ANALYZE` weekly, plus after any one-off bulk backfill.

> **A note on stale stats**: Very stale NDV statistics can mislead the CBO in some cases — the optimizer trusts the number it has and will commit to a join plan based on it, even if that number is now an order of magnitude off. Run `ANALYZE` after major data shape changes. That said, in most steady-state workloads slightly-stale stats are still better than no stats; do not panic if you've gone a few extra days without a refresh.

### 8.5 When you do NOT need ANALYZE

Skip `ANALYZE` (or deprioritize it) for:
- **Tables that are only scanned, never joined.** Pure `SELECT ... FROM big_table WHERE date >= ...` style queries are bounded by partition pruning and file skipping, not by CBO decisions.
- **Tables under ~1M rows.** The CBO's heuristics are usually fine at small scale.
- **Tables that are rebuilt full-refresh nightly.** Run `ANALYZE` as the last step of the rebuild pipeline so the next morning's queries see fresh stats.

### 8.6 What about non-Iceberg connector tables (PostgreSQL, MySQL, etc.)?

> **Important — do NOT generalize "Trino has no stats for X connector" from this guide's focus on Iceberg.** This entire guide so far has been about **Iceberg tables** because that is where Trino's own `ANALYZE` command applies. For **JDBC connector tables** (PostgreSQL, MySQL, SQL Server, Oracle), the statistics story is **different but still works** — Trino's CBO can and does use statistics from those source databases.

The high-level rule, per connector family:

| Connector family | How to populate CBO stats | How Trino sees them |
|---|---|---|
| **Iceberg, Hive, Delta Lake** (connectors that own the data files) | Run Trino's `ANALYZE schema.table` — writes a Puffin file (Iceberg) or updates the metastore (Hive/Delta). See sections 4–6 above. | Trino reads NDV from its own statistics layer. |
| **PostgreSQL, MySQL, SQL Server, Oracle** (JDBC connectors) | Run the source database's **native ANALYZE** (e.g., `ANALYZE billing.invoices;` in psql; `ANALYZE TABLE billing.invoices;` in MySQL). Trino's `ANALYZE` does NOT work on these connectors. | The JDBC connector retrieves statistics on demand from the source database's catalog (`pg_stats` for PostgreSQL; `INFORMATION_SCHEMA.STATISTICS` for MySQL). The CBO gets NDV and null fraction from there. See resource 22, Section 4.1A for the PostgreSQL details. |

The misconception to actively reject: **"Trino's CBO has no statistics for federated tables, so federation joins always run with guess-based planning."** This is **false**. For PostgreSQL connector tables, statistics flow into Trino's CBO as long as native ANALYZE has been run on the Postgres side. `SHOW STATS FOR app_pg.public.users` will show populated `distinct_values_count` and `nulls_fraction` columns exactly the same way it does for Iceberg, just sourced from `pg_stats` instead of Puffin. Run native ANALYZE on the Postgres replica on a similar cadence to Iceberg ANALYZE (weekly or after major data ingest), or rely on Postgres `autovacuum_analyze` to keep statistics fresh automatically.

The corollary: when troubleshooting a slow federation join, **check `SHOW STATS FOR <pg_catalog>.<schema>.<table>` first** — if `distinct_values_count` is NULL for the join keys, the fix is not "Trino has no stats so use a hint"; the fix is "run `ANALYZE <schema>.<table>;` natively on the Postgres replica, then flush Trino's metadata cache if `metadata.cache-ttl > 0`."

---

## 9. A copy-paste maintenance recipe

Put this in your dbt project's post-hook, or schedule it via Airflow / k8s CronJob, on top of the maintenance schedule in resource 17.

```sql
-- ONE-TIME (only if these tables had a prior full-table ANALYZE):
-- Drop the old Puffin so column-targeted ANALYZE writes clean stats.
ALTER TABLE iceberg.analytics.events    EXECUTE drop_extended_stats;
ALTER TABLE iceberg.app.users           EXECUTE drop_extended_stats;
ALTER TABLE iceberg.app.tenants         EXECUTE drop_extended_stats;
ALTER TABLE iceberg.app.subscriptions   EXECUTE drop_extended_stats;

-- Weekly job: refresh CBO stats for the high-fanout join tables
ANALYZE iceberg.analytics.events    WITH (columns = ARRAY['user_id', 'tenant_id', 'event_type']);
ANALYZE iceberg.app.users           WITH (columns = ARRAY['id', 'tenant_id', 'plan', 'status']);
ANALYZE iceberg.app.tenants         WITH (columns = ARRAY['id', 'plan', 'region']);
ANALYZE iceberg.app.subscriptions   WITH (columns = ARRAY['tenant_id', 'plan', 'status']);
```

A few notes:
- **Column-targeted ANALYZE is cheaper** than full-table ANALYZE on wide tables. Specify the columns that show up as join keys or as filter predicates.
- **The `drop_extended_stats` step is one-time, NOT weekly.** Once your tables have only ever been analyzed with the column-subset list above, you do NOT need to drop on every weekly run — Trino overwrites the per-column Puffin entries. The drop is only required when you're switching from "full-table ANALYZE was run at some point" to "column-subset ANALYZE going forward." See section 4.5 for the rule-of-thumb table.
- Run `ANALYZE` **after** `rewrite_data_files` (compaction) — sorting/compacting first then computing stats gives the most accurate Puffin file.
- Run `ANALYZE` **before** `expire_snapshots` — so the new Puffin is referenced by a kept snapshot.
- **Concurrency control via resource groups (optional).** If weekly ANALYZE jobs collide with interactive queries, put them in a dedicated resource group with a low concurrency limit. Trino **resource groups** control **how many concurrent queries** can run in a group and **how much memory** the group can use in aggregate — they do **NOT** control per-query thread counts or per-query parallelism. So the lever you have is: "only let 1 ANALYZE run at a time, and cap its memory at 20% of cluster," not "make ANALYZE use fewer worker threads."

---

## 10. Verification & troubleshooting checklist

When a join is mysteriously slow on Iceberg:

1. **Are CBO stats populated?** `SHOW STATS FOR <table>` for each joined table. If `distinct_values_count` is NULL for the join key, run `ANALYZE`.
2. **Are the stats actually fresh, or are you looking at a stale Puffin?** If you recently ran a column-targeted ANALYZE but `SHOW STATS` shows what look like the old full-table NDV values, run `ALTER TABLE <table> EXECUTE drop_extended_stats` then re-run the column-targeted ANALYZE. See section 4.5.
3. **Is `join_reordering_strategy` set to AUTOMATIC?** `SHOW SESSION LIKE 'join_reordering_strategy'`. If `NONE`, set it to `AUTOMATIC` and re-run.
4. **Did the join order actually change?** Compare `EXPLAIN (TYPE LOGICAL)` before and after `ANALYZE`. Look at the order of the Join nodes from inside-out.
5. **Did broadcast vs partitioned decision change?** Look for `Join[BROADCAST]` vs `Join[PARTITIONED]` annotations in the EXPLAIN output. The right call depends on build-side cardinality estimates, which only become accurate with stats.
6. **Are the row estimates concrete numbers?** Each operator's `Estimates: {rows: N, ...}` line should show real numbers, not `?`. A `?` means the CBO has no estimate and is falling back to defaults.

If after all that the join is still slow, the problem is probably Layer 1 or Layer 2, not Layer 3 — go check partition pruning and file skipping (resources 17 and 18). `ANALYZE` is not a cure for missing partitions or bad file layout.

---

## 11. Key terms

- **CBO (cost-based optimizer)**: the part of Trino that chooses among logically equivalent query plans based on estimated CPU, memory, and network cost. Needs statistics to estimate cost well.
- **NDV (number of distinct values)**: for a column, the count of unique values. Critical input to join cardinality estimation. NOT auto-collected by Iceberg.
- **Puffin file**: an Iceberg-native binary file format used to store table-level statistics that don't fit in the manifest (notably NDV sketches). Lives alongside `.metadata.json` files in the table's metadata directory in MinIO. Extension is typically `.stats`.
- **Sketch (Theta / HLL)**: a compact data structure (typically a few KB) that gives an approximate count of distinct values. Far cheaper than a true `COUNT(DISTINCT)`. What Puffin files store for NDV.
- **Build side / probe side**: in a hash join, the side that is loaded into a hash table in memory is the **build** side; the side that streams past it looking for matches is the **probe** side. Build side should be the smaller side.
- **Broadcast join**: the build side is sent to every worker, so each worker has the whole hash table. Cheap if the build is small; OOMs if the build is large.
- **Partitioned (hash / shuffle) join**: both sides are re-partitioned across the cluster by the join key, then each worker joins its slice locally. Necessary for large builds but adds a shuffle.
- **`join_reordering_strategy`**: Trino session/cluster property controlling whether the CBO is allowed to reorder joins. Should be `AUTOMATIC` for analytical workloads.
- **File skipping / data skipping**: scan-time optimization where files whose [min, max] for a column don't overlap the WHERE predicate are not opened. Driven by Iceberg manifest stats, always on.
- **Partition pruning**: planning-time optimization where entire partitions are eliminated based on WHERE clauses against partition columns. Always on.

---

## 12. Quick reference — what to run when

| Symptom | Likely layer | Fix |
|---|---|---|
| "Scan reads every file in the partition." | Layer 2 (file skipping ineffective) | Sort-based `rewrite_data_files` + `sorted_by` table property. |
| "Scan reads every partition." | Layer 1 (partition pruning missed) | Add a WHERE on the partition column with literals matching the partition transform. |
| "Join order looks wrong; small dimension being probed instead of built." | Layer 3 (CBO missing stats) | `ANALYZE schema.table`. |
| "Query OOMs with 'exceeded per-node memory'." | Layer 3 (wrong build side) | `ANALYZE schema.table` + check `join_distribution_type`. |
| "Lots of small files, every query slow." | Layer 2 (small-file penalty) | `ALTER TABLE EXECUTE optimize`. |
| "Query plan estimates show `rows: ?`." | Layer 3 (no stats) | `ANALYZE schema.table`. |
| "SHOW STATS shows old NDV values after I ran column-targeted ANALYZE." | Layer 3 (Puffin not refreshed) | `ALTER TABLE schema.table EXECUTE drop_extended_stats`, then re-run the ANALYZE. |
| "I ran `ANALYZE ... WITH (partitions = ARRAY[...])` on an Iceberg table and got `analyze property 'partitions' does not exist`." | Wrong connector syntax | `partitions` is Hive-only. Use `WITH (columns = ARRAY[...])` on Iceberg. |
| "Dashboards were fast last month, slow this month." | Layer 2 or 3 (stale stats / decayed layout) | Re-run weekly compaction + `ANALYZE`. |
