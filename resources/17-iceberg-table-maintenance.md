# Iceberg Table Maintenance: Compaction, Snapshot Expiry, Orphan Files

> You just inherited a Trino + Iceberg + MinIO setup. Queries are getting slower week over week and MinIO storage keeps climbing even though no one is writing new data. Nobody ever set up maintenance jobs. This guide tells you what's wrong, what to schedule, and in what order — without breaking anything.
>
> **Production stack:** Apache Spark + Iceberg 1.5.2 + MinIO + Hive Metastore + Trino 467, all on Kubernetes on-prem.

---

## TL;DR (read these 5 sentences first)

1. Iceberg never modifies files in place — every write creates new files, every delete creates marker files, every operation creates a new snapshot.
2. Without maintenance, your table accumulates thousands of tiny files plus old snapshots holding onto data files forever — query speed drops 5–10x and storage grows ~30% per year.
3. Run **four** procedures: `rewrite_data_files` (nightly), `expire_snapshots` (weekly), `remove_orphan_files` (weekly), `rewrite_manifests` (weekly).
4. **Run them in this order:** compaction → expire snapshots → remove orphan files. The risk if you reverse the order isn't deleting referenced files (Iceberg's definition of "orphan" already protects those) — it's a race with in-flight writes when `older_than` is set aggressively.
5. If a bad ingestion job ever runs, `CALL iceberg.system.rollback_to_snapshot` instantly reverts the table without touching data files — the safest cleanup tool you have.

---

## Why maintenance is needed (the immutable-file model)

Iceberg is built on **immutable Parquet files**. Once a file is written, it is never modified. This is the foundation of Iceberg's ACID guarantees (Atomicity, Consistency, Isolation, Durability — meaning concurrent reads and writes see a consistent, complete picture of the table even mid-update). But it has a cost: every operation creates more files.

Here's what happens during normal use:

| Operation | What Iceberg writes |
|---|---|
| `INSERT` (10K rows) | One new Parquet data file + one new manifest file + one new snapshot |
| `INSERT` from a 5-minute streaming job | One new Parquet file per micro-batch — **288 new files per day per partition** (streaming pipeline example: 12 micro-batches/hour × 24 hours = 288. For a daily batch ETL, expect ~1–5 files per partition per day instead — the file-count problem only gets dramatic with frequent micro-batches or many concurrent writers.) |
| `UPDATE` / `DELETE` (format-version 2, **MoR explicitly enabled**) | A **delete file** marking which rows in existing files to ignore + new snapshot |
| `UPDATE` / `DELETE` (format-version 2, **CoW = Iceberg 1.5.2 default**) | Full Parquet data files rewritten without the affected rows; no delete files produced; new snapshot |
| `MERGE INTO` (dimension upsert, **CoW = Iceberg 1.5.2 default**) | Full Parquet data files rewritten with merged content; no delete files; new snapshot |
| `MERGE INTO` (dimension upsert, **MoR explicitly enabled**) | New data files for the changed rows + delete files for the old rows + new snapshot |

> **Quick fact on Iceberg 1.5.2 defaults (do not get this backwards).** The library defaults are `write.delete.mode = copy-on-write`, `write.update.mode = copy-on-write`, and `write.merge.mode = copy-on-write` — verified from `TableProperties.java` in the Iceberg 1.5.2 source. **Merge-on-Read is NOT the default**; it must be explicitly set in TBLPROPERTIES. If your table has position delete files (`content = 1` in the `$files` metadata table) it is because someone explicitly set `write.delete.mode = 'merge-on-read'` (or `write.update.mode` / `write.merge.mode`). See the MoR vs CoW section in resource 13 for the full property reference, the three-properties-are-separate gotcha, and CDC-pipeline guidance.

> **ENGINE CALLOUT — `write.delete.mode`, `write.update.mode`, `write.merge.mode` must be set from Spark SQL, NOT Trino.** These three write-mode properties are NOT exposed through Trino 467's `ALTER TABLE ... SET PROPERTIES` syntax. Trino's `SET PROPERTIES` only handles Iceberg connector-specific properties like `partitioning`, `format`, `sorted_by`, `format_version`, etc. — it does not pass through the underlying Iceberg write-mode table properties. To configure CoW vs MoR, use **Spark SQL**:
>
> ```sql
> -- Spark SQL (CORRECT — this is the only engine that can set these properties).
> ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES (
>   'write.delete.mode' = 'copy-on-write',
>   'write.update.mode' = 'copy-on-write',
>   'write.merge.mode'  = 'copy-on-write'
> );
> ```
>
> ```sql
> -- Trino 467 (WRONG for these properties — Trino's SET PROPERTIES does not accept them).
> -- These will either error or be silently ignored depending on Trino version.
> ALTER TABLE iceberg.analytics.events SET PROPERTIES (
>   'write.delete.mode' = 'copy-on-write'   -- not a recognized Trino connector property
> );
> ```
>
> If you need to flip CoW/MoR on this stack, run the `ALTER TABLE ... SET TBLPROPERTIES` from a Spark SQL session (`spark-sql` CLI or `spark.sql(...)` in a job). Verify the property took effect from either engine with `SHOW TBLPROPERTIES iceberg.analytics.events` (Spark) or `SELECT * FROM iceberg.analytics."events$properties"` (Trino metadata table).

**A manifest file** is an Iceberg metadata file listing which Parquet data files belong to a snapshot and their per-column min/max statistics. **A snapshot** is a point-in-time version of the table — a pointer to the set of manifest files that constitute the table at a particular moment.

After two months of running an unmaintained streaming pipeline, a single SaaS event table can have:
- 200,000+ tiny Parquet files (most < 1 MB each).
- 1,000+ snapshots, each holding onto files it referenced even after they've been "deleted."
- Manifest files large enough that Trino spends 10+ seconds **planning** the query before it even reads data.
- 3x the storage you actually need, because every "deleted" file is still on MinIO.

This is what maintenance fixes.

---

## Engine context: Spark vs Trino syntax

> **Important before you copy any SQL below.** Both engines support the same Iceberg maintenance operations — the SQL surface differs. In Trino 467, every routine maintenance procedure in this document has a first-class `ALTER TABLE ... EXECUTE` form, AND the `CALL iceberg.system.rollback_to_snapshot(...)` procedure is also available natively in Trino. You do NOT need Spark for routine compaction, snapshot expiry, OR rollback. Spark is required only when you need to expire below Trino's 7-day minimum-retention floor (e.g., GDPR same-day purge), or when you want Spark's richer compaction tuning knobs.
>
> Most teams submit scheduled maintenance via Spark anyway because it integrates naturally with Airflow / Kubernetes CronJobs and exposes more tuning knobs (`min-input-files`, `partial-progress.enabled`, sort/zorder strategy). But for ad-hoc cleanup from a Trino session — "this dashboard table feels slow, let me compact it right now" or "I need to roll back a bad write right now" — the Trino-native form is one statement and done, no Spark cluster spin-up.

### Trino-native maintenance cheat sheet (copy-pasteable for Trino 467)

> **CRITICAL TRINO 467 FLOOR — read this before copying any `expire_snapshots` or `remove_orphan_files` example below.** Trino 467 enforces a minimum retention of 7 days for both `expire_snapshots` and `remove_orphan_files`. Passing a shorter duration (e.g., `retention_threshold => '1d'`, `'3d'`, `'6d'`, or anything below `'7d'`) produces a procedure error and the call fails immediately. The minimum can be changed by setting `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` in the Trino coordinator config (a coordinator restart is required for the change to take effect). For routine maintenance, leave the floor at `7d` and use `'7d'` as your minimum value from Trino. For sub-7-day urgency (GDPR right-to-erasure), run from Spark instead — Spark does not enforce this floor.
>
> **NO `dry_run` IN TRINO.** Trino's `ALTER TABLE ... EXECUTE remove_orphan_files(...)` does **not** support a `dry_run` parameter — only Spark's `CALL iceberg.system.remove_orphan_files(table => '...', dry_run => true)` form does. Because orphan-file deletion is irreversible, **always preview from Spark with `dry_run => true` before running the production deletion**, even when the actual deletion will be issued from Trino. Skipping the dry-run preview is the #1 cause of "we deleted in-flight Parquet files and now the table has dangling references" incidents on this stack.

```sql
-- Compaction (Trino-native; no Spark required)
ALTER TABLE iceberg.analytics.events EXECUTE optimize;
-- Or with a custom small-file threshold:
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');

-- Snapshot expiry (Trino-native)
-- NOTE: retention_threshold must be >= iceberg.expire-snapshots.min-retention
-- (default 7d). Trino REJECTS values below the floor with a clear error.
-- NOTE: Trino 467 supports ONLY `retention_threshold`. The `retain_last` and
-- `clean_expired_metadata` arguments were added in Trino 479 (Dec 2025) and
-- DO NOT exist on Trino 467. For retain_last behavior on this stack, use the
-- Spark form: CALL iceberg.system.expire_snapshots(table => '...',
-- older_than => ..., retain_last => N).
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');

-- Orphan-file cleanup (Trino-native)
-- NOTE: retention_threshold must be >= iceberg.remove-orphan-files.min-retention
-- (default 7d). Same floor enforcement as expire_snapshots.
-- NOTE: Trino does NOT support `dry_run` here. To preview which files would
-- be removed, run from Spark first:
--   CALL iceberg.system.remove_orphan_files(
--     table   => 'analytics.events',
--     dry_run => true
--   );
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');

-- Manifest rewrite — NOT available on Trino 467.
-- `optimize_manifests` was added in Trino 470 (Feb 2025). On Trino 467 (the
-- current production version), the EXECUTE form below does NOT exist and
-- fails with a procedure / syntax error. Use Spark instead:
--   CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
-- Once the cluster is upgraded to Trino 470+, you can use:
--   ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests;

-- Rollback to a prior snapshot (Trino-native; preferred in an incident).
-- Trino 467 form — CALL with POSITIONAL args (schema, table, snapshot_id):
CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321);

-- NOTE: the `ALTER TABLE iceberg.analytics.events EXECUTE rollback_to_snapshot(snapshot_id => ...)`
-- syntax requires Trino 469+ (released Jan 2025). On Trino 467 (the current
-- production version), that form does NOT exist and fails with a procedure /
-- syntax error — use the CALL form above.
-- Do NOT use the Spark named-arg form (table => ..., snapshot_id => ...) from Trino either.

-- Per-tenant ad-hoc compaction (Trino-native; WHERE on partition columns only)
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '128MB')
WHERE tenant_id = 'acme';
```

**When to choose Spark CALL over Trino ALTER TABLE EXECUTE:**

| Need | Use Spark CALL |
|---|---|
| Expire snapshots younger than 7 days (e.g., GDPR right-to-erasure same-day purge) | YES — Spark has no min-retention floor; Trino does (default 7d) |
| Roll back to a prior snapshot (`rollback_to_snapshot`) | NO — both engines expose this. Trino is faster in an active incident because you likely already have a Trino session open. Spark's only advantage is named-argument syntax. |
| Fine-grained tuning (`min-input-files`, `partial-progress.enabled`, sort strategy) | YES — Spark's options map exposes these; Trino's `OPTIMIZE` only exposes `file_size_threshold` |
| Compaction immediately after partition evolution (newly-added partition column or changed spec) | YES — required. Trino bugs [#26109](https://github.com/trinodb/trino/issues/26109), [#26503](https://github.com/trinodb/trino/issues/26503), [#25279](https://github.com/trinodb/trino/issues/25279) — Trino's `EXECUTE optimize` may produce incorrect partition values or fail to reorganize files. Use Spark with `rewrite-all=true`. |
| Routine nightly maintenance in Airflow / k8s CronJob | Either works; Spark is the common choice for batch-job ergonomics |
| Ad-hoc "fix this table from my Trino session right now" | Use Trino — no need to start Spark |

> **ANTI-PATTERN WARNING — `CALL iceberg.system.expire_snapshots(...)` is Spark syntax, not Trino.** In Trino 467, snapshot expiry is `ALTER TABLE iceberg.<schema>.<table> EXECUTE expire_snapshots(retention_threshold => '30d')`. Writing `CALL iceberg.system.expire_snapshots(table => ...)` in a Trino session fails silently or errors. The pattern applies to ALL four routine procedures: `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files`, and `rewrite_manifests` — their `CALL` form is Spark-only. The only `CALL iceberg.system.*` procedures that work in Trino 467 are `rollback_to_snapshot` and `register_table`.

> **Important before you copy any SQL below.** For the four routine maintenance procedures (`rewrite_data_files`, `expire_snapshots`, `remove_orphan_files`, `rewrite_manifests`), `CALL iceberg.system.*` is **Spark SQL syntax** and the Trino 467 equivalent uses `ALTER TABLE ... EXECUTE` (see the cheat sheet above and the per-section translations in the comments). **Exceptions:** `rollback_to_snapshot` and `register_table` use `CALL iceberg.system.*` syntax in **both** Trino and Spark, with different argument styles (positional in Trino, named in Spark) — see the table below and the rollback / register sections later in this document.

### Side-by-side syntax reference (every procedure, both engines)

> **Use this table as the canonical reference.** Both engines run the same underlying Iceberg operation; only the SQL surface differs. Pick the column for the client you're already in. The four routine procedures (`rewrite_data_files`, `expire_snapshots`, `remove_orphan_files`, `rewrite_manifests`) have **distinct keywords** between engines (`CALL` in Spark, `ALTER TABLE ... EXECUTE` in Trino). The two recovery procedures (`rollback_to_snapshot`, `register_table`) use **`CALL iceberg.system.*` in BOTH engines** — only the argument style differs (positional in Trino, named in Spark).

| Operation | Spark SQL (named args via `=>`) | Trino 467 (positional / `ALTER TABLE ... EXECUTE`) |
|---|---|---|
| Compact data files | `CALL iceberg.system.rewrite_data_files(table => 'analytics.events', options => map('target-file-size-bytes', '268435456'))` | `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB')` |
| Expire snapshots | `CALL iceberg.system.expire_snapshots(table => 'analytics.events', older_than => current_timestamp - interval '30' day, retain_last => 10)` | `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d')` — **Trino 467 supports ONLY `retention_threshold`.** `retain_last` and `clean_expired_metadata` were added in Trino 479 (Dec 2025) and do NOT exist on Trino 467. For retain_last on this stack, use the Spark form. |
| Remove orphan files | `CALL iceberg.system.remove_orphan_files(table => 'analytics.events', older_than => current_timestamp - interval '3' day, dry_run => true)` (run with `dry_run => true` first to preview; re-run without it to delete) | `ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d')` — **NO `dry_run` parameter in Trino**; preview from Spark. Trino enforces a 7-day minimum-retention floor; values shorter than `'7d'` are rejected. |
| Rewrite manifests | `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` | Not available on Trino 467 — use Spark `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')`. Available as `ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests` on Trino 470+ (Feb 2025). |
| Rollback to snapshot | `CALL iceberg.system.rollback_to_snapshot(table => 'analytics.events', snapshot_id => 4823511203987654321)` (named args) | `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321)` (positional args — the only Trino 467 form). The `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` syntax requires Trino 469+ and does NOT work on Trino 467. |
| Re-register a dropped table | `CALL iceberg.system.register_table(table => 'analytics.events', metadata_file => 's3a://lakehouse/.../v18.metadata.json')` (named args) | `CALL iceberg.system.register_table(schema_name => 'analytics', table_name => 'events', metadata_file => 's3a://lakehouse/.../v18.metadata.json')` (named args, schema/table split) |

> **Trino rollback on Trino 467 — use `CALL iceberg.system.rollback_to_snapshot('schema', 'table', <id>)`.** On Trino 467 (the current production version), the only supported rollback syntax is `CALL iceberg.system.rollback_to_snapshot('schema', 'table', <snapshot_id>)` with **positional** VARCHAR, VARCHAR, BIGINT arguments. The `ALTER TABLE iceberg.<schema>.<table> EXECUTE rollback_to_snapshot(snapshot_id => <id>)` syntax was added in **Trino 469** (released Jan 2025) and does **not** exist on Trino 467 — attempting it fails with a syntax / procedure error. **Do NOT use the Spark `CALL iceberg.system.rollback_to_snapshot(table => '...', snapshot_id => ...)` named-argument form from Trino either** — Trino's `CALL` requires positional arguments.

### Valid `iceberg.system.*` procedures (Trino 467) — and common fabrications to avoid

> **Use this as the canonical "does this procedure exist in Trino?" reference.** Confusing Spark-only procedures for Trino-supported ones is the most common cause of "procedure not found" errors on this stack. The Iceberg library exposes many procedures; **Trino implements only a subset**. Everything else is Spark-only.

**Valid in Trino 467 via `ALTER TABLE ... EXECUTE`:**
- `expire_snapshots` — snapshot metadata expiry (subject to 7-day min-retention floor). **Trino 467 accepts ONLY `retention_threshold` as an argument.** The `retain_last` and `clean_expired_metadata` arguments were added in **Trino 479** (Dec 2025) and are NOT available on Trino 467. For retain_last behavior, use the Spark form.
- `remove_orphan_files` — sweep unreferenced files from object storage (subject to 7-day min-retention floor).
- `optimize` — file compaction (Trino's equivalent of Spark's `rewrite_data_files`; exposes only `file_size_threshold`).
- `optimize_manifests` — **NOT available on Trino 467**. This EXECUTE form was added in **Trino 470** (Feb 2025). On Trino 467 you must use Spark's `CALL iceberg.system.rewrite_manifests(table => '...')` for manifest rewrites.

**Valid in Trino 467 via `CALL iceberg.system.*`:**
- `rollback_to_snapshot` — positional args `('schema','table',snapshot_id)`. This is the **only** rollback syntax available on Trino 467. The `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` form was added in Trino 469 (Jan 2025) and does NOT exist on Trino 467.
- `register_table` — re-attach a dropped table from a surviving `v*.metadata.json` file. No `EXECUTE` equivalent; this is the only way to re-register.

**NOT supported in Trino 467 (Spark-only — do NOT attempt these from Trino):**
- `rewrite_data_files` — use Spark `CALL iceberg.system.rewrite_data_files(...)`. Trino's equivalent is `ALTER TABLE ... EXECUTE optimize`.
- `rewrite_manifests` — Spark only on Trino 467. There is **no Trino 467 equivalent** for manifest rewrite — the `ALTER TABLE ... EXECUTE optimize_manifests` form was added in **Trino 470** (Feb 2025) and does not exist on Trino 467. Until the cluster is upgraded, run `CALL iceberg.system.rewrite_manifests(table => '...')` from Spark.
- `create_tag` — Spark only, via DDL: `ALTER TABLE ... CREATE TAG \`tag_name\` AS OF VERSION <snapshot_id>`.
- `create_branch` — Spark only, via DDL: `ALTER TABLE ... CREATE BRANCH \`branch_name\` AS OF VERSION <snapshot_id>`.
- `drop_tag` — Spark only, via DDL: `ALTER TABLE ... DROP TAG \`tag_name\``.
- `drop_branch` — Spark only, via DDL: `ALTER TABLE ... DROP BRANCH \`branch_name\``.
- `fast_forward` — Spark only (branch fast-forward operation).
- `publish_changes`, `cherrypick_snapshot`, `set_current_snapshot` (procedure form), `rewrite_position_delete_files`, `migrate`, `snapshot` (the table-snapshot form for migration) — all Spark-only.

**Why this matters in practice:** if a Trino client returns `Procedure not registered: iceberg.system.<name>` or `function 'iceberg.system.<name>' not found`, the procedure is one of the Spark-only ones above. Switch to Spark (`spark-sql` or `spark-submit`) — do not try to "fix" the call by adjusting argument syntax. The procedure simply does not exist in Trino's catalog.

---

## The four maintenance operations

Run them in **this order of importance**. If you only have time to set up one, start with `rewrite_data_files`.

> **Engine matters — read this before copying any command:**
> - **The procedures themselves are NOT Spark-only.** `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files`, and `rewrite_manifests` are Iceberg-level operations supported by both engines. Only the SQL surface differs.
> - **`CALL iceberg.system.*` syntax for the four routine maintenance procedures is Spark-only** — submit via `spark-submit`, `spark-sql`, or `spark.sql("CALL ...")`. The Trino equivalent for those four is `ALTER TABLE ... EXECUTE`. **However**, Trino DOES accept `CALL iceberg.system.rollback_to_snapshot(...)` and `CALL iceberg.system.register_table(...)` natively — those two procedures are exposed via the same `CALL` keyword in Trino, just with positional arguments instead of named ones.
> - **`ALTER TABLE ... EXECUTE` is Trino 467 syntax** — submit from any Trino client (`trino` CLI, DBeaver, JDBC, REST). This syntax does not work in Spark.
> - **Trino enforces a 7-day minimum-retention floor on `expire_snapshots` and `remove_orphan_files`** (catalog properties `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention`). Spark does not enforce this floor. For GDPR right-to-erasure with zero-day urgency, run those steps from Spark (or temporarily lower the Trino catalog property and restart the coordinator).
> - **`rollback_to_snapshot` is available in BOTH Trino AND Spark.** Trino 467 exposes it via `CALL iceberg.system.rollback_to_snapshot('schema', 'table', snapshot_id)` (positional args), and Spark exposes the same procedure via `CALL iceberg.system.rollback_to_snapshot(table => '...', snapshot_id => ...)` (named args). In an active incident, prefer the Trino form — you almost certainly already have a Trino session open and don't want the latency of starting a Spark job.
> - **Don't mix engines within a single scheduled job.** Pick one engine per job for easier incident debugging. But the choice of engine is operational, not a hard capability limit.

### 1. `rewrite_data_files` (compaction) — most important, run nightly

**What it does:** reads all the small Parquet files in each partition, merges them into bigger files (~256 MB each), and applies any pending delete files. After it runs, the partition has fewer, bigger, cleaner data files.

**Why it matters most:** every Parquet file has fixed overhead in Trino — roughly 10–50 ms to open the file, read its footer, and check column statistics. A query that touches 10,000 small files spends minutes just opening files, before reading any data. The same query on 100 compacted files reads the same data in seconds.

> **CoW vs MoR and the GDPR / right-to-erasure 4-step sequence — what changes between the two modes.** The standard 4-step physical-deletion runbook on this stack is: (1) `DELETE FROM iceberg.analytics.events WHERE user_id = 'gdpr-subject-42'`, (2) `rewrite_data_files(..., where => 'partition_predicate')` to compact the affected partition, (3) `expire_snapshots(...)` to drop the snapshots that still pointed at the pre-DELETE files, (4) `remove_orphan_files(...)` to sweep any stragglers. **This 4-step sequence is correct for BOTH CoW and MoR — but what Step 1 actually does to the data files is different in each mode**, and that affects what Step 2 has to do:
>
> - **Copy-on-Write (CoW) — the Iceberg 1.5.2 default for DELETE, UPDATE, and MERGE.** Step 1 already **rewrites the affected data files immediately**: every Parquet file that contained at least one matching row is read, the matching rows are dropped, and a brand-new Parquet file is written containing only the surviving rows. The original Parquet files are unreferenced by the new (current) snapshot — but they ARE still referenced by the prior snapshot (the one Step 1 superseded). No delete marker files are produced. Step 2 (`rewrite_data_files`) then has very little to do for the rows you just deleted (they're already gone from current-snapshot files); its real job in this sequence is residual small-file cleanup on the partition you touched. Steps 3 and 4 then remove the prior snapshots and physically delete the now-unreferenced original Parquet files from MinIO.
> - **Merge-on-Read (MoR) — requires explicit TBLPROPERTIES (`write.delete.mode = 'merge-on-read'`, plus `write.update.mode` and `write.merge.mode` separately if you also need those).** Step 1 writes a small **delete file** (Iceberg metadata listing which rows in which existing data files to ignore) and leaves the original Parquet data files completely intact. The matching rows are still physically present on MinIO — readers just filter them out at query time by consulting the delete file. Step 2 (`rewrite_data_files`) is now doing the actual rewriting: it reads the data files plus delete files, applies the deletes, writes new data files without the deleted rows, and clears the delete files. Steps 3 and 4 then expire prior snapshots and remove the now-unreferenced originals — same as CoW.
>
> **Bottom line for a right-to-erasure operator:** on the Iceberg 1.5.2 default stack (CoW), the rows are out of the current-snapshot files immediately after Step 1, so a query against `current` snapshot already misses the subject — but the bytes are still on MinIO until Steps 3 and 4 finish. On MoR, the rows are still in the current-snapshot data files until Step 2 completes the compaction. **Both modes require the full 4-step sequence to physically remove bytes from MinIO** — never skip Steps 3 and 4. If you are not sure which mode your table uses, run `SHOW TBLPROPERTIES iceberg.analytics.events` and look for `write.delete.mode`; absence of the property means CoW (the Iceberg 1.5.2 default).

```sql
-- ============================================================================
-- ENGINE LABEL: the `CALL iceberg.system.*` SYNTAX shown here is Spark SQL.
-- The underlying Iceberg PROCEDURES are also available in Trino 467 via a
-- different syntax (`ALTER TABLE ... EXECUTE`) — they are NOT Spark-only
-- operations. The two engines call the same Iceberg library code; only the
-- SQL surface differs. Trino-equivalent forms for everything below:
--   ALTER TABLE iceberg.analytics.events EXECUTE optimize
--       (equivalent to rewrite_data_files; binpack strategy by default)
--   ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(
--     retention_threshold => '30d'
--   )
--   ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(
--     retention_threshold => '7d'
--   )
--   For rewrite_manifests: NO Trino 467 equivalent exists. The
--       `ALTER TABLE ... EXECUTE optimize_manifests` form requires Trino 470+
--       (Feb 2025). On Trino 467, run from Spark:
--           CALL iceberg.system.rewrite_manifests(table => 'analytics.events')
--
-- IMPORTANT TRINO CAVEAT: Trino enforces a minimum retention floor on
-- expire_snapshots (default 7d via iceberg.expire-snapshots.min-retention)
-- and remove_orphan_files (default 7d via iceberg.remove-orphan-files.min-retention).
-- Trino will REJECT retention_threshold values below the configured floor.
-- Spark does not enforce this floor — that's why GDPR-urgent zero-retention
-- purges are typically run from Spark, not Trino. Routine maintenance is
-- fine from either engine.
--
-- Below this line, every CALL iceberg.system.* statement is Spark SQL syntax.
-- Translate to ALTER TABLE EXECUTE (see the Spark-vs-Trino table above)
-- if you want to run from Trino.
-- ============================================================================

-- Spark SQL syntax (run via spark-submit or spark-sql).
-- Trino 467 equivalent: ALTER TABLE iceberg.analytics.events EXECUTE optimize
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB target
    'min-input-files',        '5'           -- only compact partitions with 5+ small files
  )
);
```

What the options mean:
- `target-file-size-bytes` — the size each rewritten Parquet file aims for. 256 MB is the standard sweet spot: big enough that file-open overhead is negligible, small enough that one Trino worker per file gives good parallelism.
- `min-input-files` — a partition is only compacted if it has at least this many candidate small files. Prevents wasted work on partitions that don't need it.

**Schedule:** nightly, after the ingestion window closes. For a SaaS that runs nightly ETL at 2 AM, schedule compaction at 4 AM.

> **COMMON MISCONCEPTION — `rewrite_data_files` does NOT reduce MinIO storage by itself.**
>
> After `rewrite_data_files` runs, MinIO usage typically goes **UP**, not down. Here's why and what to do about it:
>
> - Compaction writes **new** Parquet files (the merged big ones) and creates a new snapshot pointing at them.
> - The **old** small Parquet files are **still on MinIO** because the **prior snapshots still reference them** (Iceberg never deletes files that any live snapshot still points to).
> - Only after `expire_snapshots` removes those prior snapshots do the old small files become unreferenced. They are then eligible for cleanup by `remove_orphan_files` (or by Iceberg's automatic file cleanup that runs during `expire_snapshots` itself for files that fall out of all live snapshots).
>
> **Storage only drops visibly on MinIO after BOTH `rewrite_data_files` AND `expire_snapshots` have run.** If you ran compaction last night and the storage graph still shows growth, that is expected — schedule `expire_snapshots` to follow and the drop will appear after that runs.
>
> The complete storage-reclamation sequence is:
> 1. `rewrite_data_files` — writes new big files (storage temporarily grows by ~old + new size).
> 2. `expire_snapshots` — removes prior snapshots that still referenced the old small files; the old files now become eligible for deletion. For files no longer referenced by ANY live snapshot, `expire_snapshots` issues the S3 DELETE calls itself.
> 3. (Optional belt-and-suspenders) `remove_orphan_files` — sweeps any stragglers that escaped step 2 (e.g., files from failed writes that were never in any snapshot).
>
> After all three, storage drops. After only step 1, it grows.

#### Trino-native compaction: `ALTER TABLE ... EXECUTE optimize`

`rewrite_data_files` is the Spark form. If you are **already in a Trino session** (DBeaver, `trino` CLI, JDBC, the Trino UI's SQL editor) and just want to compact one table without bouncing over to `spark-submit`, Trino 467 has a first-class equivalent:

```sql
-- Trino 467 native compaction. Same underlying Iceberg operation as Spark's
-- rewrite_data_files — only the SQL surface differs.
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '128MB');
```

The `file_size_threshold` parameter tells Trino: any data file **smaller** than this threshold is a compaction candidate; files at or above it are left alone. The default is `100MB`. Setting it to `128MB` (or higher) is a common tweak when you want to be more aggressive about pulling small files into bigger ones.

**When to reach for Trino `OPTIMIZE` vs Spark `rewrite_data_files`:**

| Situation | Use |
|---|---|
| Ad-hoc compaction from a Trino session — "this dashboard table feels slow, let me clean it up right now" | **Trino `OPTIMIZE`**. No need to leave the SQL client; one statement and done. |
| Scheduled nightly/weekly maintenance jobs | **Spark `rewrite_data_files`**. Fits the batch-job model, integrates naturally with Airflow / Kubernetes CronJobs, and exposes more tuning knobs (see next row). |
| You need fine-grained options — `min-input-files`, `target-file-size-bytes`, `partial-progress.enabled`, `max-concurrent-file-group-rewrites`, sort/zorder strategy | **Spark `rewrite_data_files`**. Trino's `OPTIMIZE` exposes only `file_size_threshold`; Spark's procedure has the full option set. |
| You only need to scope compaction to one tenant / one partition (no extra tuning) — both engines support this via a partition-column `WHERE` filter | **Either works.** Trino: `ALTER TABLE ... EXECUTE optimize(...) WHERE tenant_id = 'acme'`. Spark: `CALL ... rewrite_data_files(table => ..., where => 'tenant_id = ''acme''', options => ...)`. See the "Per-tenant compaction" subsection below for details. |
| Compaction immediately after **partition evolution** (e.g., you just ran `ALTER TABLE ... SET PARTITIONING` to add `tenant_id` to the partition spec, and now you want existing data reorganized by the new column) | **Spark `rewrite_data_files`** — see the limitation below. |

**Key limitation — Trino `OPTIMIZE` cannot use newly-added partition columns as predicates** ([trinodb/trino#25279](https://github.com/trinodb/trino/issues/25279)). If you just changed the partition spec via `ALTER TABLE iceberg.analytics.events SET PROPERTIES partitioning = ARRAY['tenant_id', 'day(event_ts)']` to introduce `tenant_id` as a new partition column, Trino's `OPTIMIZE` will rewrite files but will **not** correctly organize them by the new `tenant_id` partition — the resulting layout won't give you the partition pruning you expected. For post-partition-evolution compaction, run **Spark `rewrite_data_files`** (which handles the new partition spec correctly). Once the table is fully re-laid-out under the new spec, Trino `OPTIMIZE` is fine again for routine compaction.

> **Post-partition-evolution exception — do NOT use `ALTER TABLE ... EXECUTE optimize` after a partition spec change.** If you recently changed the table's partition spec with `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]`, do NOT use `ALTER TABLE ... EXECUTE optimize` for the initial migration of old-spec files. Confirmed Trino bugs ([trinodb/trino #26109](https://github.com/trinodb/trino/issues/26109), [#26503](https://github.com/trinodb/trino/issues/26503), [#25279](https://github.com/trinodb/trino/issues/25279)) mean Trino's native `OPTIMIZE` may produce files with **incorrect partition values** (e.g., NULL partition keys) or fail to reorganize data by the new column at all. Use Spark's `CALL iceberg.system.rewrite_data_files` with `rewrite-all=true` instead — `rewrite-all=true` forces Spark to rewrite every file regardless of size, which is required for cross-spec migration (the default bin-pack strategy skips well-sized old-spec files). Resume using Trino's `EXECUTE optimize` for routine compaction only **after** all files are on the new spec — verify via `SELECT spec_id, COUNT(*) FROM iceberg.analytics."events$files" GROUP BY spec_id` and wait until the old `spec_id` row disappears.

#### Per-tenant compaction (fairness, noisy-neighbor cleanup, urgent fixes)

When one tenant's partition is the source of slow queries — e.g., `tenant_id='acme'` just bulk-loaded 50K small files and is dragging down dashboard latency for everyone else — you want to compact **only that tenant**, not the entire table. Both engines support this; pick based on whether the job is ad-hoc or scheduled.

**Trino `OPTIMIZE` with WHERE — best for ad-hoc / quick per-tenant fixes.** Trino 467 **does** support a `WHERE` clause on partition columns in `OPTIMIZE`. This is the fastest way to compact one tenant's data from a Trino session — no Spark job required:

```sql
-- Trino 467 per-tenant compaction. WHERE supports any partition-column predicate.
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB')
WHERE tenant_id = 'acme';
```

Caveats:
- The `WHERE` predicate must reference a **partition column** (here, `tenant_id`). Predicates on non-partition columns are not supported.
- The newly-added-partition-column limitation above ([trinodb/trino#25279](https://github.com/trinodb/trino/issues/25279)) still applies: if `tenant_id` was added to the partition spec via partition evolution, Trino's `OPTIMIZE WHERE tenant_id = ...` cannot use it as a predicate until the table is fully re-laid-out under the new spec.

**Spark `rewrite_data_files` with `where` — preferred for scheduled / nightly per-tenant batches.** Spark's procedure exposes the full option set (target file size, min input files, partial progress, sort strategy) plus the same partition-scoped `where` filter. Use this for scheduled nightly compaction that processes per-tenant partitions in a loop:

```sql
-- Spark SQL. Note: `where` is a TOP-LEVEL named argument to the procedure,
-- NOT a key inside options => map(...). Putting it inside the map silently
-- does nothing — the procedure does not look for a 'where' key in options.
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  where   => 'tenant_id = ''acme''',
  options => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
);
```

> **CRITICAL — `where` is a top-level procedure argument, not an `options` map key.** This is the single most common bug in per-tenant Spark compaction. The WRONG form below looks plausible but silently ignores the filter and compacts the **entire table** instead of one tenant:
>
> ```sql
> -- WRONG — silently compacts the entire table.
> -- 'where' is NOT a recognized key inside options => map(); the procedure ignores it.
> CALL iceberg.system.rewrite_data_files(
>   table   => 'analytics.events',
>   options => map('where', 'tenant_id = ''acme''', 'target-file-size-bytes', '268435456')
> );
> ```
>
> The CORRECT form lifts `where` out to be a named argument of the procedure itself:
>
> ```sql
> -- CORRECT — only compacts the acme tenant's partition.
> CALL iceberg.system.rewrite_data_files(
>   table   => 'analytics.events',
>   where   => 'tenant_id = ''acme''',
>   options => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
> );
> ```
>
> Note the single-quote escaping: inside the SQL string literal that `where` accepts, a single quote is escaped by doubling it (`'acme'` becomes `''acme''`). The Spark `rewrite_data_files` procedure's full argument list is in the [Iceberg Spark procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/#rewrite_data_files).

**Engine choice for per-tenant compaction — which to pick:**

| Situation | Use |
|---|---|
| "Acme's dashboard is slow right now — I need to clean up their partition in the next 5 minutes" (ad-hoc from a Trino session) | **Trino `OPTIMIZE` with WHERE**. Single statement, no Spark cluster startup, immediate. |
| Scheduled nightly per-tenant fairness compaction (loop over tenant IDs, compact each one independently with size/min-files tuning) | **Spark `rewrite_data_files` with `where`**. Full option control, fits the Airflow / k8s CronJob model. |
| Per-tenant compaction immediately after partition evolution that added `tenant_id` as a new partition column | **Spark `rewrite_data_files` with `where`** (Trino can't use the newly-added partition column as a predicate — see limitation above). |
| Mixed batch — compact every tenant, but with different file-size targets per tenant tier (Enterprise tenants → 512 MB files, free-tier → 128 MB) | **Spark `rewrite_data_files` with `where`** — loop over tenants in a scheduler, vary `target-file-size-bytes` per tenant. |

### 2. `expire_snapshots` — run weekly

> **What is a snapshot?** An Iceberg snapshot is a point-in-time record of the complete state of a table — which data files exist and what their min/max statistics are. Every INSERT, UPDATE, DELETE, or MERGE creates a new snapshot. Snapshots are how time-travel queries (`FOR VERSION AS OF`) know exactly which data files to read.

**What it does:** removes old snapshot **metadata** from the table's snapshot list. After a snapshot is expired, no one can time-travel to it. The data files that *only that snapshot* referenced become eligible for deletion. (Files referenced by any still-living snapshot are kept.)

**Why it matters:** without this, every snapshot you've ever created is still tracked, and the data files those snapshots point to (including all the small files that compaction rewrote) cannot be removed from MinIO. Your storage grows forever.

> **Trino version availability for `expire_snapshots` parameters (READ BEFORE COPYING):**
> - `retention_threshold` — available since the original Trino Iceberg connector implementation. **Works on Trino 467 (production).**
> - `retain_last` — added in **Trino 479** (released Dec 14, 2025; PR #27362, issue #27357). **NOT available on Trino 467.** Attempting it on 467 fails with "Procedure expire_snapshots does not accept argument 'retain_last'" or a similar argument-not-recognized error.
> - `clean_expired_metadata` — also added in **Trino 479** (Dec 2025). **NOT available on Trino 467.**
>
> **For Trino 467 (the current production version):** the ONLY accepted argument is `retention_threshold`. If you need `retain_last` behavior on this stack (keep the last N snapshots regardless of age), run the Spark form instead: `CALL iceberg.system.expire_snapshots(table => 'analytics.events', older_than => current_timestamp - interval '30' day, retain_last => 10)` — `retain_last` has always been an Iceberg Spark-procedure parameter and works independently of the Trino version.
>
> Trino 467-compatible form (the only one you can use on production today):
> ```sql
> ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');
> ```
>
> Trino 479+ enhanced form (available ONLY after the cluster is upgraded to 479 or later — do NOT use on Trino 467):
> ```sql
> -- TRINO 479+ ONLY. Fails on Trino 467.
> ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(
>   retention_threshold     => '30d',
>   retain_last             => 10,
>   clean_expired_metadata  => true
> );
> ```

```sql
-- Spark SQL syntax (run via spark-submit or spark-sql).
-- Trino 467 equivalent (same operation, different syntax):
--   ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');
-- Trino 467 supports ONLY `retention_threshold`. `retain_last` and
-- `clean_expired_metadata` were added in Trino 479 (Dec 2025) and are NOT
-- available on Trino 467 — see the callout above. For retain_last behavior
-- on this stack, run from Spark (as below).
-- Trino requires retention_threshold >= iceberg.expire-snapshots.min-retention (default 7d);
-- 30d is comfortably above the floor so this Trino form runs without complaint.
-- Spark's 30-day older_than below is operationally equivalent.
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

What the options mean:
- `older_than` — drop snapshots older than the timestamp you pass (30 days back in the example). Adjust based on how far back you need to time-travel.
- `retain_last` — always keep the most recent N snapshots regardless of age. Safety net so a quiet table doesn't get wiped down to a single snapshot.

> **Defaults reminder — do not confuse a chosen 30-day operator schedule with Iceberg / Trino *defaults*.** Iceberg's actual default for the table property `history.expire.max-snapshot-age-ms` is **5 days** — that is the age at which `expire_snapshots` (with no `older_than` argument) drops a snapshot. Trino additionally enforces a **minimum-retention floor of 7 days** via the `iceberg.expire-snapshots.min-retention` catalog property — Trino refuses to expire snapshots newer than 7 days. The 30-day value in the example above is an **operator choice** for routine maintenance, not a documented default of either system. If you need to expire snapshots younger than 7 days (e.g., a GDPR right-to-erasure purge), run the procedure from **Spark** (no min-retention floor) or temporarily lower the Trino catalog property and restart the coordinator.

> **GOTCHA — table properties can silently prevent zero-day expiry.** Two Iceberg table properties act as a per-table minimum-retention floor that `expire_snapshots` cannot violate, regardless of the `older_than` / `retain_last` arguments you pass: **`history.expire.min-snapshots-to-keep`** (default `1`) keeps at least N most-recent snapshots, and **`history.expire.max-snapshot-age-ms`** (default 5 days) protects snapshots younger than the configured age from expiry. If a previous operator set, say, `history.expire.min-snapshots-to-keep=20` on the table, then `expire_snapshots(older_than => current_timestamp, retain_last => 1)` for an urgent GDPR purge will still keep 20 snapshots — and the rows you tried to physically purge remain reachable. **Always check `SHOW TBLPROPERTIES iceberg.analytics.events` (or query `"events$properties"`) before running a zero-day expiry**; if either property is set higher than your purge needs, `ALTER TABLE ... UNSET TBLPROPERTIES` (or set to `1` / `0`) temporarily, run the purge, then restore the prior values.

#### Table-level retention properties — set a defense-in-depth floor on the table itself

The same `history.expire.*` properties that can silently *block* a zero-day GDPR purge are also your best defense against the *opposite* mistake: a teammate who passes `retention_threshold => '7d'` to a scheduled `expire_snapshots` job when the policy says 30 days. Per-call arguments can be wrong; table-level properties are sticky. They apply automatically every time `expire_snapshots` runs — regardless of what `older_than` / `retention_threshold` the caller supplies — and Iceberg honors whichever floor is *more conservative*. Set them once and the retention contract is enforced by the table itself.

Three properties matter:
- `history.expire.min-snapshots-to-keep` (default `1`) — always keep at least N most-recent snapshots regardless of age.
- `history.expire.max-snapshot-age-ms` — auto-expire snapshots older than N milliseconds when the procedure runs with defaults; also enforced as a per-table floor when callers pass shorter values.
- `history.expire.max-ref-age-ms` — expire named references (tags / branches) older than N milliseconds.

```sql
-- Trino 467: set retention floor directly on the table.
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep' = '5',
    'history.expire.max-snapshot-age-ms'   = '2592000000'  -- 30 days in ms
);
```

After this, if someone accidentally schedules `expire_snapshots(retention_threshold => '7d')`, the table-level `max-snapshot-age-ms = 30 days` still protects the last 30 days of snapshots — the per-call argument cannot relax the table floor. Treat these properties as the durable policy and per-call arguments as one-off overrides.

**Schedule:** weekly. 30 days is a common operator-chosen retention setting (not an Iceberg or Trino default — see the defaults reminder above); you can keep 7 days if storage is tight, 90 days if compliance demands it. The actual built-in defaults are Iceberg's 5-day `history.expire.max-snapshot-age-ms` and Trino's 7-day `iceberg.expire-snapshots.min-retention` floor.

**Why this is the second-most-important step:** every compaction adds new data files (the merged ones) and orphans the old small files. If you compact but never expire, you actually use *more* storage than before — the old small files are still around because the old snapshot still references them.

### 3. `remove_orphan_files` — run weekly

**What it does:** scans the table's MinIO directory for any Parquet file that no current snapshot references and deletes it. These "orphans" usually come from Spark or Trino jobs that crashed mid-write — the file got uploaded to MinIO but the commit failed, so no snapshot points to it.

**Important safety guarantee:** a file referenced by *any* live snapshot — including snapshots you are about to expire — is **by definition not an orphan**. `remove_orphan_files` will never delete a file that any current snapshot points to. So the danger is *not* "I might delete data a snapshot still needs." The real danger is the race condition with in-flight writes described below.

```sql
-- =====================================================================
-- SPARK SQL signature (named args via =>):
-- CALL iceberg.system.remove_orphan_files(
--   table       => 'schema.table',          -- REQUIRED
--   older_than  => <timestamp>,             -- default = 3 days ago
--   dry_run     => true | false,            -- default false; preview-only when true
--   location    => 's3a://lakehouse/...',   -- optional override of table location
--   max_concurrent_deletes => <int>         -- optional concurrency knob
-- )
--
-- TRINO 467 signature (positional table via ALTER TABLE; named args after EXECUTE):
-- ALTER TABLE iceberg.<schema>.<table>
-- EXECUTE remove_orphan_files(retention_threshold => '7d');
--
-- IMPORTANT DIFFERENCES (do not mix the two signatures):
--   - Trino does NOT expose CALL iceberg.system.remove_orphan_files(...). The only
--     Trino syntax is `ALTER TABLE ... EXECUTE remove_orphan_files(...)`. Pasting
--     the Spark CALL form into a Trino session returns "procedure not registered".
--   - Trino does NOT support `dry_run` on `remove_orphan_files`. The dry-run option
--     exists only in Spark. If you need a preview, run dry_run from Spark first,
--     then run the actual deletion from either engine.
--   - Trino enforces a 7-day MINIMUM `retention_threshold` (catalog property
--     `iceberg.remove-orphan-files.min-retention`, default `7d`). Values shorter
--     than 7d are REJECTED with: "Retention specified (X.XXd) is shorter than the
--     minimum retention configured in the system (7.00d)". Spark has no such floor.
-- =====================================================================

-- STEP A — Spark dry-run (ALWAYS preview before deleting; takes seconds).
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.events',
  dry_run => true                    -- returns the list of files that WOULD be deleted
);

-- STEP B — Spark actual deletion (after reviewing the dry-run output).
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);

-- Trino equivalent for the actual deletion (no dry-run available in Trino):
--   ALTER TABLE iceberg.analytics.events
--   EXECUTE remove_orphan_files(retention_threshold => '7d');
```

> **DRY-RUN FIRST, ALWAYS.** Orphan-file deletion is irreversible — once `mc rm` runs against MinIO, the bytes are gone. The Spark `dry_run => true` form returns the list of files that would be removed without touching MinIO; review that list (especially file counts and any in-flight job paths) before running the real deletion. Trino has no equivalent dry-run for `remove_orphan_files`, which is one operational reason teams run orphan cleanup from Spark — the dry-run safety net is a Spark-only feature. If your scheduled job runs from Trino, manually invoke a Spark dry-run earlier in the maintenance window as a pre-flight check.

The `older_than` parameter (default 3 days) protects in-flight writes — a Spark job writing a file right now is not orphaned, it's just not committed yet. Setting `older_than` to "3 days ago" means "only delete files that have been sitting unreferenced for more than 3 days, so we never race with a live job."

> **The 3-day default IS the safe value — leave it alone for routine cleanup.** The Iceberg documented default for `remove_orphan_files.older_than` is **3 days**. That value is calibrated specifically so the procedure is safe to run **while ingestion is still active** — by the time a file is 3 days old and still unreferenced, every in-flight write that could ever have produced it has long since either committed or failed. **Using the default 3-day value, you do NOT need to pause ingestion.** Lowering `older_than` below the default (1 day, or worse, 1 hour) shrinks that safety window and **requires you to pause ingestion** for the duration of the cleanup, because a Spark write that is 6 hours into committing a large file becomes deletable mid-commit. The only reason to go below 3 days is GDPR right-to-erasure urgency — and even then, pause Debezium / Spark ingestion to that table first, then run with `older_than => '1' day` (or shorter), then resume ingestion. Trino's `iceberg.remove-orphan-files.min-retention` floor (default 7d) is a different mechanism and will block sub-7d values from the Trino side; Spark has no such floor and is the typical engine for sub-default runs.

> **SAFETY CALLOUT — never set `older_than` shorter than your longest possible in-flight write duration.** The 3-day default exists because it was deliberately chosen to be longer than any plausible single-batch ingestion or compaction job. If you lower it, you MUST lower it only to a value that still safely exceeds the longest write that could plausibly be in flight when the cleanup runs. Concrete guidance for the production stack:
>
> - **Nightly batch ETL that runs up to 4–6 hours**: leave the 3-day default in place. There is no safe way to push below 3 days while the nightly job might still be writing, even if the job *usually* finishes in 2 hours — the one night it hangs at 5h59m and your 6-hour `older_than` deletes the file it's still uploading is the night your table corrupts.
> - **Long Spark compaction jobs (multi-hour `rewrite_data_files` on a large fact table)**: same as above — keep 3 days. A failed compaction can leave partially-uploaded files that look like orphans the moment the job dies; you want a margin between "job died" and "we're allowed to sweep its leftovers."
> - **Streaming / CDC pipelines (Debezium → Spark Structured Streaming)**: individual micro-batches are short (seconds to minutes), but the pipeline runs continuously. The relevant duration is not "one micro-batch" but "the longest gap between a file landing in MinIO and the commit that references it" — usually under a few minutes for a healthy pipeline, but spikes during back-pressure or downstream stalls. The 3-day default is still the safe choice.
> - **Setting `older_than` to less than your longest possible in-flight write duration can corrupt the table.** The failure mode is the one described in the "Why this order matters" section: the cleanup deletes a file that a write is about to commit, the commit succeeds (Iceberg metadata now points at the file), and every subsequent query against that snapshot fails with "file not found." The only fix at that point is rolling back to a snapshot from before the bad commit, which may not exist if the corruption has been sitting for days.
>
> For nightly batch jobs that run up to 4–6 hours, **keep the 3-day default**. It is the right value, not a compromise. There is no "we run faster than that, we can be more aggressive" — the safety margin is the point.

**Why this comes after `expire_snapshots`:** see the next section. Running it before expiry is dangerous.

### 4. `rewrite_manifests` — run weekly

**What it does:** Iceberg's manifest files list which data files belong to a snapshot and carry per-column min/max statistics. After hundreds of writes, you can have hundreds of small manifests. Trino must read all of them during query planning to decide which data files to skip — this becomes the bottleneck on tables with lots of writes.

```sql
-- Spark SQL syntax (run via spark-submit or spark-sql).
-- Trino 467: NO equivalent — must run from Spark.
-- The `ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests` form
-- was added in Trino 470 (Feb 2025) and does NOT exist on Trino 467.
-- Attempting it on Trino 467 fails with a procedure / syntax error.
-- Available on Trino 470+:
--   ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests;
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

This rewrites the small manifests into fewer larger manifests, sorted by partition value so partition pruning is faster.

**Why this matters:** on a table with 50,000 manifests, "planning the query" can take 30+ seconds before any data is read. After `rewrite_manifests`, that drops to under 1 second.

**Schedule:** weekly is plenty. Most teams pair this with the `expire_snapshots` job since both are metadata-only operations.

---

## Safe scheduling order — get this right or risk data loss

The four operations have **mandatory ordering** for the weekly job. Running them out of order can delete files that are still in use.

**Correct order:**

```
compaction (nightly)
    │
    ▼
weekly maintenance window:
    1. expire_snapshots
    2. remove_orphan_files
    3. rewrite_manifests
```

### Why this order matters

**Why compaction must run BEFORE `expire_snapshots`:** compaction creates new data files and replaces the old small files in the current snapshot. The old small files are now only referenced by *prior* snapshots. If `expire_snapshots` runs first, you've lost the chance to compact the old data — you'd be compacting against the old (large) historical file set instead of the latest small files.

**Why `expire_snapshots` MUST run BEFORE `remove_orphan_files`:** the reason is **not** "otherwise you'll delete a file a snapshot still references." That can't happen — files referenced by any live snapshot (including ones you're about to expire) are by definition not orphans, and `remove_orphan_files` skips them. The real reason is to **shrink the race window with in-flight writes**.

Picture this sequence: a Spark write has uploaded a new Parquet file to MinIO but not yet committed the snapshot that references it. At that moment the file looks like an orphan to `remove_orphan_files` — no snapshot points to it (yet). If your `older_than` is set aggressively (e.g., a few hours) and `remove_orphan_files` happens to run while that write is in flight, the uncommitted file can be deleted out from under the write. When the write tries to commit, you get a corrupted commit pointing at a file that no longer exists.

Running `expire_snapshots` first doesn't change Iceberg's orphan logic, but it gives you a clean reason to keep `older_than` generous (default 3 days) on `remove_orphan_files`: by the time you run orphan cleanup, you know every snapshot that was going to commit in the last 3 days has already committed, so any file older than 3 days that isn't referenced really is dead.

**The exact failure mode if `older_than` is too aggressive:** `remove_orphan_files` runs with `older_than = 1 hour`, a Spark write is mid-flight at hour 0 and commits at hour 1, but the orphan cleanup sees the uncommitted file and deletes it. The commit then references a file that no longer exists. **The table is now broken**: any query that hits that snapshot errors out with "file not found."

The `older_than` default (3 days) is what actually prevents this. The ordering convention (`expire_snapshots` first, then `remove_orphan_files`) is a defense-in-depth habit, not the primary safety mechanism. Do not lower `older_than` below 1 day without strong reason.

### Concurrency safety with queries

- **Compaction and ad-hoc queries can run at the same time.** Iceberg's snapshot isolation means readers see the snapshot that was current when they started; compaction creates a new snapshot, but the running query keeps reading the old one until it finishes.
- **Compaction and ingestion jobs can conflict.** If your Spark ingestion job and `rewrite_data_files` try to commit changes to the same partition at the same time, one will be rejected with a `CommitFailedException` and have to retry. The cheap fix: **don't schedule compaction during the ingestion window**. Standard pattern is ingestion at 2 AM, compaction at 4 AM.
  - **Iceberg's built-in commit retry — know the actual default.** Iceberg's commit protocol auto-retries failed commits before surfacing `CommitFailedException`. The default retry count is **`commit.retry.num-retries=4`** (four retries, not three — verified against the Iceberg 1.5.2 `TableProperties.java`). Defaults for the related backoff knobs: `commit.retry.min-wait-ms=100`, `commit.retry.max-wait-ms=60000`, `commit.retry.total-timeout-ms=1800000` (30 minutes). For a busy table where concurrent writers regularly collide (e.g., Debezium CDC + nightly compaction), raise `commit.retry.num-retries` to 8–12 via `ALTER TABLE ... SET TBLPROPERTIES ('commit.retry.num-retries'='10')` rather than letting the job fail and re-running it externally — internal retries are cheaper than a full job restart.
- **`expire_snapshots` and `remove_orphan_files` should never overlap with ingestion.** Schedule them in a weekly maintenance window when ingestion is paused (e.g., Sunday 3 AM).

---

## What happens if you skip maintenance for 2 months

Concrete symptoms you'll see on the table, in roughly the order they appear:

| Week | Symptom | Root cause |
|---|---|---|
| 1–2 | Query latency starts to creep up (10–20% slower). | Small files accumulating, but partition pruning still saves you. |
| 3–4 | Specific queries that scan many partitions get noticeably slow. | 5,000+ small files; file-open overhead is now measurable. |
| 5–6 | MinIO storage usage doubles. Trino dashboards start timing out at 60s. | Snapshots accumulating; compaction's "new" big files are now also small because of new writes; manifest planning is taking 10+ seconds. |
| 7–8 | Random query failures: "too many open files," "query exceeded memory limit." | Tens of thousands of small files per partition; planning consumes coordinator memory. |
| 9+ | Ingestion job times out trying to commit because there are too many manifest files to read. | The metadata overhead exceeds the data work. |

**The recovery is straightforward:** run compaction once, then expire snapshots, then remove orphans, then rewrite manifests. Storage drops back to expected size within hours. Query speed returns the next day after Trino's file-listing caches refresh.

---

## Quick-start maintenance schedule (copy this)

Wire these up via Airflow, a Kubernetes CronJob, or a dbt operation — any scheduler the team already uses. **The CALL statements below are Spark SQL syntax** — submit them via `spark-submit` or `spark-sql`. If you prefer to run maintenance from Trino instead, every step has a Trino 467 equivalent (`ALTER TABLE ... EXECUTE` for the four routine procedures, and `CALL iceberg.system.rollback_to_snapshot('schema','table',snapshot_id)` for rollback). See the Spark-vs-Trino table near the top of this document. Most teams pick Spark for scheduled maintenance because (a) Spark does not enforce Trino's 7-day minimum-retention floor, giving you flexibility for tighter retention windows, and (b) the heavy compaction work fits naturally into the Spark batch-job model; Trino is left to focus on interactive queries. But either engine can run the routine schedule end-to-end.

```sql
-- Run in Spark (spark-submit or spark-sql)
-- ============================================================
-- NIGHTLY (runs at 4 AM, after 2 AM ingestion finishes)
-- ============================================================
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '5'
  )
);

-- ============================================================
-- WEEKLY (runs Sunday 3 AM, when ingestion is paused)
-- IMPORTANT: run in this exact order.
-- ============================================================

-- 1. Expire old snapshots first (frees data files from old snapshot refs)
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);

-- 2. Remove orphan files (now-unreferenced files can be safely deleted).
-- For scheduled jobs, prefer running a Spark dry_run first (in the same
-- spark-submit; capture output to logs) so a human review of the affected
-- files is possible before the actual delete commits — orphan deletion is
-- irreversible.
--
-- Optional pre-flight (uncomment to enable dry-run review in CI/CD):
-- CALL iceberg.system.remove_orphan_files(
--   table   => 'analytics.events',
--   dry_run => true
-- );

CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);

-- Trino 467 equivalent (no dry_run support in Trino):
--   ALTER TABLE iceberg.analytics.events
--   EXECUTE remove_orphan_files(retention_threshold => '7d');

-- 3. Compact manifest files (speeds up query planning)
CALL iceberg.system.rewrite_manifests(
  table => 'analytics.events'
);
```

**To run these for every table in your catalog,** loop in your scheduler. The procedures don't take a wildcard — you call them once per table. For 10 tables, that's 10 invocations per maintenance job.

**Tuning per table:**
- Small dim tables (<1 GB): drop `target-file-size-bytes` to 128 MB, run compaction weekly not nightly.
- High-volume fact tables (>100 GB/day): keep 256 MB, run compaction nightly.
- Tables with lots of UPDATEs/DELETEs: consider 128 MB and more aggressive compaction (every 6 hours) because delete files accumulate fast.

---

## Time travel for audits and billing disputes

Iceberg's snapshot history isn't only a maintenance concern — it's a query feature. You can run any `SELECT` **as of** a past snapshot or timestamp, which is exactly what you need when a customer disputes a billing line ("the August invoice says 1.2M API calls, prove it"), or when an auditor asks "show me the state of the `usage_report` table at end of Q1." This section covers the Trino 467 query syntax, how timestamp resolution actually works, and how to pin snapshots that must survive routine `expire_snapshots`.

### Query syntax (Trino 467)

```sql
-- Query the table as it existed at a specific timestamp.
SELECT tenant_id, SUM(api_calls) AS calls
FROM iceberg.analytics.usage_report
FOR TIMESTAMP AS OF TIMESTAMP '2026-04-01 00:00:00 UTC'
WHERE billing_month = '2026-03'
GROUP BY tenant_id;

-- Query the table at a specific snapshot ID (exact, no ambiguity).
SELECT tenant_id, SUM(api_calls) AS calls
FROM iceberg.analytics.usage_report
FOR VERSION AS OF 4823511203987654321
WHERE billing_month = '2026-03'
GROUP BY tenant_id;
```

To find the snapshot ID for a given billing period, query the `$snapshots` metadata table:

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."usage_report$snapshots"
WHERE committed_at BETWEEN TIMESTAMP '2026-03-31 23:00:00 UTC'
                       AND TIMESTAMP '2026-04-01 02:00:00 UTC'
ORDER BY committed_at;
```

#### `$history` vs `$snapshots` — pick the right metadata table for audit reconstruction

`$snapshots` lists **every snapshot ever created** for the table (including snapshots reachable only from named branches). `$history` shows the **ordered commit chain** — which snapshot was the *current* one at each point in time, including rollbacks and ref reassignments. For an audit question like "what was the table state at 3pm Tuesday?", `$history` is the right starting point because it tells you which snapshot a query at that moment would actually have seen; `$snapshots` would also show snapshots that existed in metadata but were never the live `current` pointer.

```sql
-- Trino 467: view the commit history (linear chain, captures rollbacks).
SELECT *
FROM iceberg.analytics."events$history"
ORDER BY made_current_at DESC
LIMIT 20;
```

The `made_current_at` column is the timestamp at which each snapshot became `current`. A rollback shows up as an older `snapshot_id` reappearing with a fresh `made_current_at` — that is the audit trail you can't reconstruct from `$snapshots` alone.

### How `FOR TIMESTAMP AS OF T` actually resolves

> **`FOR TIMESTAMP AS OF T` resolves to the latest snapshot with `committed_at <= T`** — not necessarily a snapshot committed at exactly T. If your report job ran at 09:00 but committed at 09:03, querying `FOR TIMESTAMP AS OF TIMESTAMP '09:00:00'` returns the pre-09:00 snapshot (the state **before** the report ran), not the snapshot that includes the report. Use `$snapshots` metadata to find the exact `committed_at` and query by snapshot ID with `FOR VERSION AS OF` for precision.

This matters for billing audits: if you say "show me the state of the table at end of business March 31," the snapshot you actually get back is whichever one was the latest one committed at or before that timestamp — which could be from minutes or hours earlier if writes were quiet, or several seconds before the timestamp if a write was actively committing. For audit-grade precision, **always pin the snapshot ID** rather than relying on timestamp resolution.

### Snapshot retention — Trino min-retention vs Iceberg table-level age

These two settings are **separate** and frequently conflated. Get them straight before you adjust either:

> **Trino enforces a catalog-level minimum retention floor** (`iceberg.expire-snapshots.min-retention`, default **7d**). This is a hard floor: Trino will reject any `expire_snapshots(retention_threshold => ...)` call with a value below the floor.
>
> **Iceberg's own table-level property** `history.expire.max-snapshot-age-ms` defaults to **5d** and is applied when expiration runs with table defaults (no explicit `older_than` argument).
>
> These are **separate settings — do not conflate them.** The Trino floor is a catalog-wide guard against accidental aggressive expiry. The Iceberg table property is what determines the default age cutoff when the procedure runs without an explicit threshold.

### Adjusting retention for long-term audit windows

For long-term audit retention (e.g., 90 days for SOX-compliant billing records), you can use either engine — both work since 90d is well above Trino's 7d floor:

```sql
-- Trino 467 (the on-stack query engine — what most engineers reach for first)
ALTER TABLE iceberg.analytics.usage_report
EXECUTE expire_snapshots(retention_threshold => '90d');

-- Spark (required when you need to bypass Trino's 7-day minimum floor,
-- e.g., for GDPR urgency where you must purge snapshots younger than 7d)
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.usage_report',
  older_than  => current_timestamp() - interval '90' day,
  retain_last => 10
);
```

Note: Trino enforces `iceberg.expire-snapshots.min-retention` (default 7d) as a catalog-level minimum. Use the **Spark form** to go below 7d for GDPR right-to-erasure compliance — Spark does not enforce this floor. For standard long-term retention (e.g., 90d), either form works.

### Pinning billing-period snapshots with tags

Quarter-end or month-end snapshots needed for audits will be deleted by routine `expire_snapshots` unless you explicitly pin them. Iceberg supports **named tags** for exactly this purpose — but on this stack you must understand which engine can do what:

> **Engine support for tags (CRITICAL — this is the most common fabrication).** **Trino 467 has NO SQL or `CALL` syntax to create or drop tags or branches.** Tag and branch DDL must be run from **Spark**. Trino can **READ** tags via the `$refs` metadata table and can **query** a tagged snapshot via `FOR VERSION AS OF '<tag_name>'`, but it cannot CREATE, DROP, or modify tags/branches. Do NOT attempt `CALL iceberg.system.create_tag(...)`, `CALL iceberg.system.create_branch(...)`, `CALL iceberg.system.drop_tag(...)`, or `CALL iceberg.system.drop_branch(...)` from Trino — those procedures do not exist in Trino 467 and the call fails with a procedure-not-found error. The correct Spark form is `ALTER TABLE ... CREATE TAG` / `CREATE BRANCH` (DDL, not a procedure).

The correct way to create a tag in Iceberg 1.5.2 is **Spark SQL DDL**:

```sql
-- Spark only (Iceberg 1.5.2) — create a named tag to pin a snapshot.
-- The snapshot_id (AS OF VERSION) comes from a $snapshots query.
ALTER TABLE iceberg.analytics.usage_report
  CREATE TAG `2026-03-billing-close`
  AS OF VERSION 4823511203987654321
  RETAIN 3650 DAYS;

-- Drop a tag when no longer needed (Spark only):
ALTER TABLE iceberg.analytics.usage_report DROP TAG `2026-03-billing-close`;

-- Read a tag via Trino (reading works, DDL does not).
SELECT * FROM iceberg.analytics.usage_report
FOR VERSION AS OF '2026-03-billing-close';
-- Note: prefer the numeric snapshot_id for audit reliability; tag names work
-- in recent Trino versions, but tag DDL (CREATE/DROP TAG) must be run from Spark.
```

Tagged snapshots are retained regardless of `expire_snapshots` retention policy — that is the whole point. The `RETAIN <N> DAYS` clause sets the tag's own expiry (so if the team forgets to drop it, it self-cleans after N days); omit it for "keep forever until explicitly dropped." Tag names are queryable via the `$refs` metadata table from either engine:

```sql
-- Works in both Trino and Spark — read-only metadata query.
SELECT name, type, snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."usage_report$refs"
WHERE type = 'TAG';
```

> To verify which snapshots currently have tags or branches protecting them:
> ```sql
> SELECT * FROM iceberg.schema."table$refs";
> ```
> This shows all current refs (tags and branches) along with their snapshot IDs, max-reference-age-ms settings, and whether they are protected from expiry. Any snapshot listed here is shielded from `expire_snapshots` cleanup regardless of how old it is — useful pre-flight check before running a retention-tightening expiry, or when investigating why a snapshot you expected to be gone is still present.

Recommended convention: name audit tags `YYYY-qN-audit` or `YYYY-MM-billing` so retention obligations are obvious from the tag name. Document who owns each tag and when it can be dropped in the same runbook that operates `expire_snapshots`.

### Practical billing-audit workflow

1. **At the close of each billing period**, immediately tag the relevant snapshot **from Spark**: query `$snapshots` (Trino or Spark) to find the latest snapshot committed on or before the cutoff timestamp, then run `ALTER TABLE ... CREATE TAG \`2026-03-billing-close\` AS OF VERSION <snapshot_id>` in Spark.
2. **When a customer disputes a charge**, query the tagged snapshot from Trino with `FOR VERSION AS OF <snapshot_id>` (or `FOR VERSION AS OF '<tag_name>'` in recent Trino versions) — look up the snapshot_id from `$refs` by tag name to reproduce the exact numbers shown on the invoice. Prefer the numeric snapshot_id for audit reproducibility.
3. **When the dispute window closes** (typically 60–90 days per contract), run `ALTER TABLE ... DROP TAG \`2026-03-billing-close\`` **from Spark** to release the snapshot. Routine `expire_snapshots` then cleans up the underlying data files on its next run.

This pattern gives you audit-grade reproducibility without paying storage costs forever — tags are kept exactly as long as you need them and no longer. The only operational catch is that tag DDL is Spark-only on this stack, so the billing-close automation must include a Spark step (typically a small Spark-SQL job triggered by Airflow at billing-period close, not a Trino statement run from your BI tool).

---

## Write-Audit-Publish (WAP) with Iceberg branches

The WAP pattern lets you write data, **audit it**, and only then make it visible to readers — instead of having every ingestion job commit directly to `main` where bad data is immediately seen by every dashboard. On this stack (Iceberg 1.5.2 + Spark + Trino 467), WAP is implemented via **Iceberg branches**. This section covers what branches are, the four-step WAP workflow, and the critical engine-support caveat: **branch DDL is Spark-only on Trino 467**.

### What an Iceberg branch is

A **branch** in Iceberg is an independent named pointer into the table's snapshot DAG (directed acyclic graph). Conceptually:
- `main` is the default branch — the snapshot every reader sees by default when they query the table.
- Any other branch (e.g., `audit-branch`) is a named pointer that lives in the same metadata as `main`, points at its own snapshot history, and is **invisible to readers of `main`** until you explicitly publish it.
- Writing to a branch creates new snapshots on that branch only. The `main` branch pointer does not move.
- A query against `main` continues to return the same data it did before any branch writes — there is no leak from branch to `main`.

This is exactly the property WAP needs: a place to stage data, run validation, and either promote (atomically merge into `main`) or discard (drop the branch) without ever exposing bad data to production readers.

> **ENGINE CALLOUT — branch DDL is Spark-only on Trino 467.** `CREATE BRANCH`, `DROP BRANCH`, the `fast_forward` procedure, and the `spark.wap.branch` write-redirect mechanism are all **Spark-only** on Trino 467. Trino 467 can **READ** from a branch (via `FOR VERSION AS OF <branch-snapshot-id>` or, in recent Trino versions, `FOR VERSION AS OF '<branch-name>'`) but cannot **CREATE**, **MODIFY**, **fast-forward**, or **DROP** branches. All branch management — every step of the WAP workflow except the read-side audit query — must go through Spark. Do NOT attempt `CALL iceberg.system.create_branch(...)` or `CALL iceberg.system.fast_forward(...)` from Trino — those procedures do not exist in Trino 467 and the call fails with a procedure-not-found error.

### The WAP workflow in four steps

#### Step 1 — Create the branch (Spark only)

Create the audit branch from the current `main` snapshot. This snapshots `main`'s state and gives the branch a starting point:

```sql
-- Spark SQL only — Trino 467 cannot run CREATE BRANCH.
-- Branch starts pointing at the current main snapshot. Future writes to the
-- branch diverge from main; main is untouched.
ALTER TABLE iceberg.analytics.events CREATE BRANCH `audit-branch`;

-- Optional: pin a retention so a forgotten branch self-cleans:
ALTER TABLE iceberg.analytics.events
  CREATE BRANCH `audit-branch`
  RETAIN 7 DAYS;
```

The backticks around `audit-branch` are required when the branch name contains a hyphen (Spark SQL identifier rules).

#### Step 2 — Write to the branch (Spark only)

Tell Spark that all subsequent writes from this session should target the branch instead of `main`. The cleanest way is via the `spark.wap.branch` session conf — Iceberg sees the conf and routes every Iceberg write to that branch:

```python
# PySpark — redirect all subsequent writes to the audit branch.
spark.conf.set("spark.wap.branch", "audit-branch")

# Now every write to this Iceberg table lands on audit-branch, NOT main.
# main is untouched and continues to serve every other reader's queries unchanged.
df.writeTo("iceberg.analytics.events").append()
```

Or via SQL:

```sql
-- Spark SQL — equivalent SET form.
SET spark.wap.branch=audit-branch;

INSERT INTO iceberg.analytics.events
  SELECT * FROM staging_events_2026_05_26;
```

After this, every snapshot Spark commits lives on `audit-branch`. A `SELECT * FROM iceberg.analytics.events` from Trino (or from a Spark session without `spark.wap.branch` set) still returns the old `main` contents — the new data is completely hidden from default readers.

**Don't forget to clear it.** Leaving `spark.wap.branch` set in a long-lived Spark session means a later "innocent" write also lands on the branch. After the WAP cycle finishes, `spark.conf.unset("spark.wap.branch")` (or restart the Spark session). The setting is session-scoped, not cluster-wide, but persists across statements within the session.

#### Step 3 — Audit the branch (Trino read is fine here)

This is the only WAP step where Trino is useful. Trino 467 can **read** a branch via `FOR VERSION AS OF <snapshot-id>`. First, find the branch's current snapshot ID from the `$snapshots` metadata table:

```sql
-- Trino 467 — find the latest snapshot on audit-branch.
-- The $snapshots table includes a 'parent_id' column you can chain through
-- to walk the branch history, plus a 'summary' map with a 'wap.id' / branch
-- info entry on snapshots committed via spark.wap.branch.
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 10;

-- Or use $refs to find the branch tip directly:
SELECT name, type, snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."events$refs"
WHERE name = 'audit-branch';
```

Then run your audit queries against that snapshot ID. The branch's snapshot is queryable as if it were any historical snapshot:

```sql
-- Trino 467 — audit the branch contents WITHOUT exposing it to default readers.
-- Replace <branch-snapshot-id> with the snapshot_id returned above.
SELECT COUNT(*)                    AS row_count,
       MIN(event_date)             AS min_date,
       MAX(event_date)             AS max_date,
       COUNT(DISTINCT tenant_id)   AS tenant_count
FROM iceberg.analytics.events
FOR VERSION AS OF <branch-snapshot-id>;

-- Typical audit checks:
--   1. Row count matches source-of-truth (Postgres COUNT(*) for the same window)
--   2. No NULL in PK / required columns
--   3. Per-tenant row counts are within expected ranges (no tenant doubled, none missing)
--   4. event_date range exactly matches the expected ingestion window
SELECT tenant_id, COUNT(*) AS rows
FROM iceberg.analytics.events
FOR VERSION AS OF <branch-snapshot-id>
GROUP BY tenant_id
ORDER BY rows DESC;
```

If any audit check fails, **do not publish**. Just drop the branch (Step 4b below) and re-run ingestion after fixing the bug. Production `main` was never touched.

> **Branch-name reading note.** Recent Trino versions also accept `FOR VERSION AS OF '<branch-name>'` (e.g., `FOR VERSION AS OF 'audit-branch'`) — Trino looks up the branch ref and resolves it to the current snapshot ID. This works on Trino 467 for reads. For audit reproducibility, prefer the numeric snapshot ID — if the branch advances mid-audit (another Spark write commits to it), the name resolves to the new tip, while the snapshot ID is stable.

#### Step 4a — Publish: fast-forward `main` to the branch (Spark only)

If the audit passes, atomically advance `main` to the branch's snapshot via the `fast_forward` procedure. This is a metadata-only operation — no data is rewritten, no files are copied, no readers see a partial state:

```sql
-- Spark SQL only — Trino 467 cannot run fast_forward.
-- Atomically moves main's pointer to audit-branch's snapshot.
-- After this commit, every reader of main immediately sees the new data.
CALL iceberg.system.fast_forward('analytics.events', 'main', 'audit-branch');
```

After this call:
- `main` now points at the same snapshot that was the branch tip.
- Trino queries against the table (which default to `main`) immediately return the new data.
- The branch still exists, still points at the same snapshot, but is now functionally redundant with `main`. Drop it (Step 4b) to clean up.

**Atomicity guarantee.** `fast_forward` is a single Iceberg commit on `main`. There is no window where readers see a partial view: every query before the commit sees the old `main`, every query after sees the new `main`. This is true ACID snapshot isolation — exactly what you want for a publish step.

**Pre-condition for fast-forward.** `fast_forward` requires the source branch (`audit-branch`) to be a **descendant** of the target branch (`main`). If someone else commits to `main` between Step 1 (CREATE BRANCH) and Step 4a (fast_forward), the branch is no longer a clean descendant — `main` has moved sideways — and `fast_forward` will fail. In that case, you have to either rebase your branch on top of the new `main` (re-run the ingestion against the new starting point) or use a regular `MERGE` instead of fast-forward. For most batch ingestion windows on this stack, this is rare because `main` is quiescent during the window — but be aware of it for tables with concurrent writers.

#### Step 4b — Drop the branch (Spark only)

Whether you published or aborted, drop the branch to release its metadata:

```sql
-- Spark SQL only — release the branch ref.
ALTER TABLE iceberg.analytics.events DROP BRANCH `audit-branch`;
```

If you set a `RETAIN N DAYS` on the branch when creating it, you can rely on Iceberg to auto-drop it after N days — useful belt-and-suspenders for forgotten branches.

### Full WAP example end-to-end

```python
# WAP for a nightly ingestion that must pass row-count and freshness checks
# before publishing to main.
from pyspark.sql import SparkSession
import trino  # python-trino client for the audit step

spark = SparkSession.builder.getOrCreate()
TABLE = "iceberg.analytics.events"

# --- Step 1: create the branch (Spark only) ---
spark.sql(f"ALTER TABLE {TABLE} CREATE BRANCH `audit-branch` RETAIN 7 DAYS")

# --- Step 2: write to the branch (Spark only) ---
spark.conf.set("spark.wap.branch", "audit-branch")
try:
    new_data = spark.read.format("iceberg").load("iceberg.staging.events_today")
    new_data.writeTo(TABLE).append()

    # --- Step 3: audit (Trino is fine, Spark works too) ---
    # Read the branch snapshot id from $refs.
    refs = spark.sql(f"SELECT snapshot_id FROM {TABLE}.refs WHERE name = 'audit-branch'").collect()
    branch_snap = refs[0]["snapshot_id"]

    audit = spark.sql(f"""
        SELECT COUNT(*) AS rows, COUNT(DISTINCT tenant_id) AS tenants
        FROM {TABLE} VERSION AS OF {branch_snap}
    """).collect()[0]

    if audit["rows"] < EXPECTED_MIN_ROWS or audit["tenants"] < EXPECTED_MIN_TENANTS:
        raise RuntimeError(f"Audit failed: {audit}. Not publishing.")

    # --- Step 4a: publish (Spark only) ---
    spark.sql(f"CALL iceberg.system.fast_forward('analytics.events', 'main', 'audit-branch')")

finally:
    # --- Step 4b: drop the branch (Spark only) — always, success or failure ---
    spark.conf.unset("spark.wap.branch")
    spark.sql(f"ALTER TABLE {TABLE} DROP BRANCH `audit-branch`")
```

### When to use WAP (and when not to)

**Use WAP when:**
- The ingestion job is high-stakes (billing, financial, compliance-relevant) and a bad write would cause customer-visible incidents.
- Downstream queries cannot tolerate seeing partial / unvalidated data even briefly.
- You have a meaningful audit check to run (row counts, key constraints, distribution shape) — the pattern's value is the validation gate, not just the staging.
- The table has many concurrent readers who must keep seeing a stable `main` throughout the ingestion window.

**Skip WAP when:**
- The ingestion is small / low-stakes (a developer table, an exploratory dataset).
- The only "validation" is "did Spark not error?" — that's already guaranteed by the atomic commit on `main`; WAP adds operational complexity without adding safety.
- You don't have a Spark job in the pipeline — WAP is Spark-only on this stack, so a pure-Trino ingestion (rare on this stack) cannot use it.

**Engine summary for WAP on Trino 467 + Spark + Iceberg 1.5.2:**

| Step | Engine required |
|---|---|
| CREATE BRANCH | Spark only |
| Set `spark.wap.branch` and write to branch | Spark only |
| Read / audit the branch (FOR VERSION AS OF) | Trino or Spark — Trino is fine |
| `fast_forward` to main | Spark only |
| DROP BRANCH | Spark only |

The Trino role in WAP is read-only auditing. Every state-changing step requires Spark.

---

## Emergency rollback (the safest cleanup tool)

When a bad ingestion job runs — duplicates, wrong schema, partial load — **roll back the snapshot before you try anything else.** It's instant, atomic, and doesn't touch a single data file.

`CALL iceberg.system.rollback_to_snapshot` is available in **BOTH Trino 467 AND Spark**. In an active incident, prefer the **Trino form** because you almost certainly already have a Trino session open from investigating the problem — there's no reason to spin up a Spark job just to move a pointer.

```sql
-- Step 1: find the snapshot that existed BEFORE the bad write.
-- Run in Trino or Spark — both can query $snapshots metadata.
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 10;

-- Step 2: roll back to the snapshot just before the bad one.

-- Trino 467 — the ONLY supported form is CALL with POSITIONAL args
-- (schema_name VARCHAR, table_name VARCHAR, snapshot_id BIGINT).
-- NOT named keyword arguments. Do not write `table =>` or `snapshot_id =>`
-- here — Trino's CALL form requires positional args.
CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321);

-- IMPORTANT: the `ALTER TABLE iceberg.analytics.events EXECUTE
-- rollback_to_snapshot(snapshot_id => ...)` syntax requires Trino 469+
-- (released Jan 2025). On Trino 467 (the current production version), that
-- form does NOT exist and fails immediately with a procedure / syntax error.
-- Use the CALL form above on Trino 467.

-- Spark SQL (alternative — same underlying Iceberg operation).
-- Spark uses NAMED keyword arguments via `=>`:
CALL iceberg.system.rollback_to_snapshot(
  table       => 'analytics.events',
  snapshot_id => 4823511203987654321
);
```

> **Argument-style gotcha — do not cross the syntaxes.** On **Trino 467** (the current production version), rollback is exposed only as `CALL iceberg.system.rollback_to_snapshot(<schema>, <table>, <snapshot_id>)` with positional VARCHAR, VARCHAR, BIGINT — NO `=>` named-arg syntax. The `ALTER TABLE iceberg.<schema>.<table> EXECUTE rollback_to_snapshot(snapshot_id => <id>)` form requires Trino 469+ (Jan 2025) and does NOT exist on Trino 467. **Spark** exposes only `CALL iceberg.system.rollback_to_snapshot(table => '...', snapshot_id => ...)` with named args. **Never** mix: passing Spark-style named args into Trino's `CALL` form, or Trino positional args into Spark, fails with a parse / argument-count error. The procedure name is identical across engines — only the calling convention differs.

Why this works:
- Iceberg's "current snapshot" is just a pointer in the table metadata. Rollback moves the pointer back.
- The bad data is still in MinIO, but no query sees it (no snapshot references it).
- Fully ACID: queries running during the rollback either see the pre-rollback state or the post-rollback state, never an inconsistent mix.

**`rollback_to_snapshot` vs `set_current_snapshot` — the escape hatch.** `rollback_to_snapshot` requires the target snapshot to be an **ancestor** of the current one (i.e., you can only roll back, not jump sideways to a snapshot from a different branch or out of lineage). If you need to point the table at an arbitrary snapshot (e.g., one from a different branch or an orphaned snapshot you've identified by ID), use `set_current_snapshot` instead. Both procedures exist in Trino and Spark.

**When rollback isn't enough:**
- If a correct write landed between the bad write and the moment you noticed, rolling back also undoes the correct write. In that case, use `overwritePartitions()` to re-do the affected partitions (see resource 13's "Idempotency and cleanup" section).
- If `expire_snapshots` already ran and removed the pre-bad snapshot, rollback can't reach it. Keep your snapshot retention at least 7 days so you always have a rollback window. (For deeper recovery from an expired snapshot or a dropped table, see "DROP TABLE recovery with `register_table`" below.)

> **CRITICAL — `rollback_to_snapshot` reverts ALL changes after the target snapshot, not just the bad operation.** Rolling back is moving the table's current-snapshot pointer back in time. Every commit between the target snapshot and the current one is undone — including legitimate writes that happened to land after the bad operation but before you noticed. If a nightly ingestion job at 02:00 added 5M new event rows for tenants B, C, D, E, and then at 09:00 an analyst accidentally ran `DELETE FROM iceberg.analytics.events WHERE tenant_id = 42`, rolling back to the 01:59 pre-ingest snapshot **loses the 5M new rows too** — every tenant suffers data loss to fix a problem that only affected one. Always inspect the snapshot lineage between the target and current snapshots first (`SELECT snapshot_id, committed_at, operation, summary FROM iceberg.analytics."events$snapshots" ORDER BY committed_at`); if there are legitimate commits in that window, do NOT roll back. Instead, **selectively re-insert** the affected rows using a `FOR VERSION AS OF` time-travel query against the pre-bad snapshot, scoped to only the data that needs to come back:
>
> ```sql
> -- Recover only tenant 42's rows from before the bad DELETE, without
> -- losing the new rows tenants B, C, D, E ingested afterward.
> -- <pre_delete_snapshot_id> is the snapshot_id from the $snapshots query
> -- that was current immediately BEFORE the bad DELETE committed.
> INSERT INTO iceberg.analytics.events
> SELECT * FROM iceberg.analytics.events FOR VERSION AS OF <pre_delete_snapshot_id>
> WHERE tenant_id = 42;
> ```
>
> This pattern reads the affected tenant's rows out of a historical snapshot (the bad DELETE has not happened "as of" that snapshot, so the rows are still there) and reinserts them into the current table — leaving every other tenant's post-DELETE writes untouched. Use rollback only when you can confirm no legitimate writes landed between the bad operation and now.

---

## DROP TABLE vs DROP TABLE PURGE — and recovery with `register_table`

A dropped Iceberg table is **not always lost**. Whether the data files survive depends on whether `PURGE` was specified, and recovery from MinIO is possible via `register_table` as long as the files are still there.

### The distinction that matters

| Statement | Hive Metastore entry | MinIO data + metadata files | Recoverable? |
|---|---|---|---|
| `DROP TABLE iceberg.analytics.events` | Removed | **Survive** — Parquet files and `metadata/v*.metadata.json` are NOT deleted | **YES** — via `register_table` against a surviving metadata file |
| `DROP TABLE iceberg.analytics.events PURGE` | Removed | **Deleted** — Iceberg issues S3 DELETE calls for every data file and metadata file | **NO** — without MinIO-level backups (snapshots, versioning, separate bucket) the data is gone |

Some catalog configurations expose this as `DROP TABLE iceberg.analytics.events WITH (purge = true)` instead. Either way, the meaningful flag is "did the engine delete the underlying object-storage files, or just remove the metastore pointer?"

**Default behavior in Trino 467 with the Hive Metastore catalog:** plain `DROP TABLE` does NOT purge — the files survive. You must explicitly add `PURGE` to delete the underlying storage. (Spark's behavior is configurable per catalog; check `engine.hive.enabled` and related properties if in doubt.)

### Recovery procedure: `register_table` against a surviving metadata file

If a table was dropped without `PURGE`, the Iceberg metadata files in MinIO under `metadata/v*.metadata.json` are intact. You can re-attach the table to the Hive Metastore by pointing `register_table` at the most recent metadata file:

```sql
-- Trino 467 (named args: schema_name, table_name, metadata_file).
CALL iceberg.system.register_table(
  schema_name   => 'analytics',
  table_name    => 'events',
  metadata_file => 's3a://lakehouse/analytics/events/metadata/v18.metadata.json'
);

-- Spark equivalent (named args: table, metadata_file).
CALL iceberg.system.register_table(
  table         => 'analytics.events',
  metadata_file => 's3a://lakehouse/analytics/events/metadata/v18.metadata.json'
);
```

**How to find the right `metadata_file`.** The `metadata/` directory under the table's base path contains one `v<N>.metadata.json` file per metadata version. The highest-numbered one is the latest:

```
# From the MinIO web console or `mc` CLI:
mc ls minio/lakehouse/analytics/events/metadata/
# Look for the highest-numbered v*.metadata.json:
#   v1.metadata.json
#   v2.metadata.json
#   ...
#   v18.metadata.json   <-- pick this one
```

If you also see a `version-hint.text` file in `metadata/`, it points to the current metadata version number — use that as a tiebreaker.

### Recovery runbook: table was accidentally dropped (without PURGE)

1. **Find the table's base path in MinIO.** This is typically `s3a://<warehouse-bucket>/<schema>/<table>/`. Check the catalog warehouse property if you don't remember the convention.
2. **List the `metadata/` directory** under that base path. Confirm `v*.metadata.json` files are present (if they're gone, the table was probably PURGE'd or the bucket has lifecycle rules that swept them).
3. **Identify the latest metadata version.** Highest `v<N>` in the file name, or whatever `version-hint.text` says.
4. **Run `register_table`** with that metadata file path (see Trino form above).
5. **Verify the recovery**:
   ```sql
   SELECT COUNT(*) FROM iceberg.analytics.events;
   -- And sanity-check the latest snapshot:
   SELECT snapshot_id, committed_at, operation
   FROM iceberg.analytics."events$snapshots"
   ORDER BY committed_at DESC LIMIT 5;
   ```
6. If the count and snapshot history look right, you're done. The table is back in the metastore and queryable.

### When `register_table` won't save you

- **The drop included `PURGE`.** Files are gone; only object-storage backups (MinIO bucket versioning, replication to a separate bucket, periodic snapshots) can recover them.
- **A bucket lifecycle policy deleted old metadata.** If your MinIO bucket has a rule that deletes `metadata/v*.metadata.json` older than N days, the metadata file may have been swept even though the data files survive. This is rare on lakehouse warehouse buckets but worth checking before assuming `register_table` will work.
- **The snapshot you actually want has been physically expired AND its data files removed.** `register_table` re-attaches the table at whatever the latest metadata file knows about. If `expire_snapshots` had already pruned the data files for the snapshot you want before the drop, those rows are gone regardless of `register_table`.

### Defense-in-depth recommendations

- **Enable MinIO bucket versioning on the warehouse bucket.** This is the single most effective protection against accidental PURGE — versioning preserves deleted object versions and lets you restore them.
- **Use OPA policy to require explicit confirmation for `DROP TABLE ... PURGE`** (or block it entirely for production schemas). Plain `DROP TABLE` without PURGE is the recoverable form; PURGE is the destructive one.
- **Keep your snapshot retention generous (7d+).** This gives you a rollback window for bad writes that's independent of the drop/register path.

---

## Hive Metastore HA — both layers must be HA, not just the pods

Every maintenance procedure in this document depends on the Hive Metastore (HMS) being reachable: Spark and Trino both call HMS to load table metadata, list snapshots, and commit new snapshots. If HMS is down, every job in this runbook fails immediately. So HMS availability is part of your maintenance story.

> **CRITICAL — running multiple HMS server pods behind a k8s Service is NOT high availability by itself.** Hive Metastore is a stateless Java service that stores ALL its state in a backing RDBMS (Postgres or MySQL). True HMS HA requires **both** layers to be redundant:
>
> 1. **Multiple HMS server pods** (typically 2-3 replicas in the k8s Deployment) behind a ClusterIP Service. This handles pod-level failure: if one HMS pod crashes or is rescheduled, the Service routes new connections to the surviving pods.
> 2. **AND an HA-configured backing RDBMS.** If both HMS pods point at the same single-instance Postgres, both pods fail together when that Postgres goes down — you have N pods but one point of failure. Provision Postgres with streaming replication and an automatic-failover controller (Patroni, repmgr, or a managed equivalent), or MySQL with Group Replication / Galera / a similar primary-failover setup. Point the HMS pods at the failover VIP / proxy (HAProxy, PgBouncer in TCP mode, ProxySQL), not at a single replica's address.
>
> A common production mistake: 2 HMS pods + 1 standalone Postgres pod. This survives an HMS pod crash but does NOT survive a Postgres crash, and Postgres crashes (disk full, OOM, slow query exhausting connections) are at least as frequent as Java-pod restarts.

**What goes wrong if the RDBMS is a single point of failure:** the backing DB falls over (typical causes on a small-cluster on-prem deployment: PVC out of inodes, autovacuum lockup, Postgres OOM killed by k8s memory limit). Both HMS pods immediately start returning errors. Every Trino query that needs to load table metadata fails with "Failed to connect to metastore." Every Spark write fails at commit. Every scheduled maintenance job in this document fails. Recovery time is bounded by how fast you can restore the DB — minutes if you have a hot standby, hours if you have only backups.

**Defense-in-depth checklist for the on-prem k8s stack:**
- HMS Deployment: `replicas: 2` (or 3), with a PodDisruptionBudget of `minAvailable: 1` so k8s drains don't take both pods at once.
- Backing RDBMS: Postgres with streaming replication, Patroni for automatic failover, and either an HAProxy fronting the cluster or a PgBouncer in TCP mode pointing at the Patroni-managed VIP. HMS connection string targets the proxy / VIP, not a pod IP.
- RDBMS storage: dedicated PVCs on reliable storage (not the same node-local disk as the application pods). Monitor disk usage and connection count — those are the two most common failure modes.
- Backups: daily Postgres `pg_basebackup` + WAL archiving to a separate MinIO bucket. Test restore quarterly — an untested backup is a hope, not a recovery plan.
- Monitoring: alert on HMS pod count below desired replicas, on Postgres replication lag, and on HMS connection-pool saturation. These are the leading indicators of impending failure.

If you only have budget for one improvement, **make the RDBMS HA first** — that's where the actual data lives. A second HMS pod with no DB failover gives a false sense of safety.

---

## Key terms

| Term | Plain meaning |
|---|---|
| **Snapshot** | A point-in-time version of an Iceberg table. Every write creates one. Lets you time-travel and roll back. |
| **Manifest file** | Iceberg metadata file listing which Parquet data files belong to a snapshot, plus column min/max stats. |
| **Compaction** | Merging many small Parquet data files into fewer larger files (~256 MB). Procedure: `rewrite_data_files`. |
| **Snapshot expiry** | Removing old snapshots from the table's snapshot list so the data files they held onto can be deleted. |
| **Orphan file** | A Parquet file in MinIO that no current snapshot references — usually left over from a failed write. |
| **Delete file** | A small file Iceberg writes when you `DELETE` or `UPDATE` rows. It marks which rows in existing data files to ignore. Compaction applies these and removes them. |
| **ACID** | Atomicity, Consistency, Isolation, Durability — guarantees that concurrent readers and writers see consistent data. |
| **Snapshot isolation** | The flavor of ACID Iceberg implements: a query reads the snapshot that was current when it started, even if writes happen mid-query. |
| **Rollback** | Moving the table's current-snapshot pointer back to an older snapshot. Instant, no data rewrite. |
| **Time travel** | Querying the table as it existed at an earlier snapshot or timestamp. Enabled by snapshot retention. |

---

## Summary

The unmaintained Iceberg table is the most common operational failure mode on this stack. Set up the four procedures, get the order right (compaction nightly; weekly: expire → orphan → manifests), and the table stays healthy indefinitely. If anything goes wrong with a write, reach for `rollback_to_snapshot` before you touch any data. Build these into your scheduler on day one — retrofitting later is harder than doing it correctly upfront.
