# Iceberg Table Maintenance: Compaction, Snapshot Expiry, Orphan Files

> You just inherited a Trino + Iceberg + MinIO setup. Queries are getting slower week over week and MinIO storage keeps climbing even though no one is writing new data. Nobody ever set up maintenance jobs. This guide tells you what's wrong, what to schedule, and in what order — without breaking anything.
>
> **Production stack:** Apache Spark + Iceberg 1.5.2 + MinIO + Hive Metastore + Trino 467, all on Kubernetes on-prem.

---

## TL;DR (read these 5 sentences first)

1. Iceberg never modifies files in place — every write creates new files, every delete creates marker files, every operation creates a new snapshot.
2. Without maintenance, your table accumulates thousands of tiny files plus old snapshots holding onto data files forever — query speed drops 5–10x and storage grows ~30% per year.
3. Run **four core** procedures: `rewrite_data_files` (nightly), `expire_snapshots` (weekly), `remove_orphan_files` (weekly), `rewrite_manifests` (weekly). On MoR tables with accumulating position deletes, add a **fifth** procedure: `rewrite_position_delete_files` (Spark only — Trino 467 does NOT support it; see [trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)).
4. **Run them in this CANONICAL ORDER (the order matches iceberg.apache.org/docs/latest/spark-procedures/):**
   - **Step 1: `rewrite_data_files` (compact FIRST)** — merges small files, applies pending deletes, produces the new "clean" data layer that every subsequent step operates against.
   - **Step 1b (MoR only): `rewrite_position_delete_files`** — if the table has accumulating position delete files (`content = 1` in `$files`), compact them as part of the same window. Spark only.
   - **Step 2: `expire_snapshots`** — drops the now-superseded older snapshots that compaction left behind, and physically deletes the small data files those snapshots exclusively referenced.
   - **Step 3: `remove_orphan_files`** — sweeps any unreferenced files left by failed writes (a different class of garbage from Step 2).
   - **Step 4: `rewrite_manifests`** — consolidates the manifest metadata that now reflects the cleaned data layer.

   **Why this order (operational efficiency, NOT data safety — Iceberg's atomic commit semantics guarantee `expire_snapshots` will NEVER delete files referenced by any live snapshot, regardless of which order you run things):** (a) compaction creates a NEW snapshot that points at merged big files and leaves the OLD small files referenced only by older snapshots — running compaction FIRST means the same maintenance window's `expire_snapshots` can immediately clean up those now-superseded older snapshots and reclaim the small-file storage in ONE cycle. If you expire first then compact, you'd have to wait for *next* week's expiry to clean up the small files compaction just orphaned, costing you an extra week of storage; (b) `expire_snapshots` before `remove_orphan_files` for the same efficiency reason — expiry frees more files for orphan cleanup in the same window; (c) `rewrite_manifests` last, so it compacts the manifest set that already reflects the cleaned table. There is no data-loss risk in reversing any of these orderings — only an extra-cycle cost for full cleanup.
5. If a bad ingestion job ever runs, `CALL iceberg.system.rollback_to_snapshot` instantly reverts the table without touching data files — the safest cleanup tool you have.

---

## Common myths about Iceberg maintenance — read FIRST (the load-bearing wrong claims)

These are the absolutes most often stated incorrectly about Iceberg maintenance procedures on Trino 467 + Iceberg 1.5.2. Each TRUTH below has been verified against the [Apache Iceberg docs](https://iceberg.apache.org/docs/latest/) and [Trino release notes](https://trino.io/docs/current/release.html). Lead with the TRUTH; state the nuance.

| MYTH (commonly said wrong) | TRUTH (correct framing) | Where in this doc |
|---|---|---|
| "`expire_snapshots` can delete data files that an active branch or tag points at." | **No, by design.** While a named ref (branch or tag) points at a snapshot, that snapshot AND its exclusively-owned data files are **protected** from `expire_snapshots`, regardless of age and regardless of `retention_threshold`/`older_than`/`retain_last` arguments. Iceberg's own docs: *"snapshots that are still referenced by branches or tags won't be removed"* and *"the expire_snapshots procedure will never remove files which are still required by a non-expired snapshot."* Legitimate exceptions: forgotten refs hold old data, explicit `DROP BRANCH`/`DROP TAG`, `max-ref-age-ms` firing, Iceberg [#13568](https://github.com/apache/iceberg/issues/13568) multi-ref bug (1.6.1+, NOT 1.5.2). | [§ 2. `expire_snapshots`](#2-expire_snapshots--run-weekly) leading callout |
| "Branch retention (`max_snapshot_age_in_ms` / `min_snapshots_to_keep`) protects data files of branch-referenced snapshots from deletion." | **It controls something different.** Branch snapshot-retention controls which snapshots in the BRANCH's ancestor chain are eligible to drop OUT OF the branch's history. The **branch tip is ALWAYS retained while the ref exists**, and the tip's data files are protected by the ref itself — not by these retention settings. To control when the BRANCH ITSELF expires, use `max-ref-age-ms`. | [§ 2. `expire_snapshots`](#2-expire_snapshots--run-weekly) leading callout properties table |
| "I should create a tag because an active branch alone is not enough protection." | **A live branch IS the protection.** Both branches and tags appear in `$refs`; both protect the snapshots they point at from `expire_snapshots`. Use **tag** for immutable labels (billing close, compliance cutoff). Use **branch** for refs that advance with new commits (WAP staging). Either keeps the snapshot safe. | [§ When to use tags vs branches](#when-to-use-tags-vs-branches), [§ 2. `expire_snapshots` myth-buster](#2-expire_snapshots--run-weekly) |
| "Trino 467 can create or drop Iceberg branches and tags." | **NO — DDL is Spark-only on Trino 467.** `CREATE BRANCH`, `DROP BRANCH`, `CREATE TAG`, `DROP TAG`, the `fast_forward` procedure, and INSERT/UPDATE/DELETE/MERGE *into a branch* are **Spark-only**. Trino 467 **CAN read** from a branch or tag via `FOR VERSION AS OF '<name>'` (PR [#16569](https://github.com/trinodb/trino/issues/16569) landed). The branch-write request [#16570](https://github.com/trinodb/trino/issues/16570) was **closed as NOT PLANNED**. Don't promise an engineer Trino will add branch-write support; that's not on the roadmap. | [§ Write-Audit-Publish (WAP) with Iceberg branches](#write-audit-publish-wap-with-iceberg-branches) engine callout |
| "Trino 467's `expire_snapshots` accepts `retain_last` and `clean_expired_metadata`." | **NO — those arguments were added in Trino 479 (Dec 2025).** On Trino 467, the ONLY accepted argument is `retention_threshold`. To use `retain_last`, run the Spark form: `CALL iceberg.system.expire_snapshots(table => '...', retain_last => 10)`. | [§ 2. `expire_snapshots`](#2-expire_snapshots--run-weekly) Trino version availability callout |
| "I should run `remove_orphan_files` to clean up the small files compaction leaves behind." | **NO — those are NOT orphans.** Files left over from compaction are still referenced by prior snapshots (those snapshots existed before compaction created the new merged-file snapshot). `remove_orphan_files` will SKIP them because by definition any file referenced by ANY live snapshot is not an orphan. The procedure that deletes those files is `expire_snapshots` (after the prior snapshots age out). `remove_orphan_files` handles a different garbage class: files written by failed/crashed writers that were never committed to any snapshot. Both procedures are needed. | [§ 2. `expire_snapshots`](#2-expire_snapshots--run-weekly) Class 1 vs Class 2 callout, [§ 3. `remove_orphan_files`](#3-remove_orphan_files--run-weekly) |
| "Trino 467 can run `rewrite_manifests` via `ALTER TABLE ... EXECUTE`." | **NO — `rewrite_manifests` is Spark-only on Trino 467.** Unlike the other three maintenance procedures (`rewrite_data_files`/`optimize`, `expire_snapshots`, `remove_orphan_files`) which all have a working Trino 467 form, `rewrite_manifests` has NO Trino 467 equivalent. Must run from Spark. | [§ 4. `rewrite_manifests`](#4-rewrite_manifests--run-weekly) engine callout |
| "Trino 467 enforces a 7-day minimum retention on `expire_snapshots`, so I can't run a GDPR right-to-erasure purge." | **The Trino floor IS 7 days, but the workaround is documented.** For sub-7-day urgency, run `expire_snapshots` from **Spark** (no min-retention floor enforced by Spark itself) OR temporarily lower the catalog property `iceberg.expire-snapshots.min-retention` and restart the Trino coordinator. ALSO check `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` on the table — those table-level properties can silently override `retain_last`/`older_than` arguments. | [§ 2. `expire_snapshots`](#2-expire_snapshots--run-weekly) GOTCHA callout |
| "`rewrite_position_delete_files` exists in Trino 467 — I'll run it on MoR tables from Trino." | **NO — Spark-only on Trino 467.** See [trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371). On Iceberg 1.5.2 MoR tables with accumulating position deletes, you MUST run this from Spark; there is no Trino 467 form. | TL;DR step 1b, [§ 1b. `rewrite_position_delete_files`](#1b-rewrite_position_delete_files--mor-tables-only-spark-only-runs-after-compact-and-before-expire_snapshots) |

> **Why these specific myths matter.** Each is a load-bearing topic-specific claim about what Iceberg maintenance "can't / does / doesn't" do. Stated as an absolute, it causes engineers to either build expensive workarounds for non-problems (creating tags to protect snapshots that an existing branch already protects; running `remove_orphan_files` first hoping to clean up compaction's leftover small files) OR to confidently break things (assuming branches don't protect data files and tightening retention "to compensate"; pasting `retain_last` into a Trino 467 `EXECUTE expire_snapshots` call). The correct discipline: when about to say "X can't / does / doesn't" about an Iceberg maintenance behavior, check (a) which Iceberg version, (b) which Trino version, (c) the official iceberg.apache.org/docs/latest/ wording, (d) the team's own resource 17.

---

## Trino EXECUTE procedures vs Spark CALL procedures — the engine-confusion disambiguation matrix (READ BEFORE WRITING ANY PROCEDURE CALL)

> **The single most common load-bearing inaccuracy in iter402-417 was naming a Spark `CALL iceberg.system.<proc>` procedure as if it were a Trino `ALTER TABLE ... EXECUTE` form** — most recently in iter417 Q1, where `rewrite_data_files(sort_order => ARRAY['plan_type', 'event_ts'])` (Spark CALL named-arg syntax) was presented as a Trino 467 EXECUTE recommendation. An engineer running that SQL on Trino 467 gets `Procedure not registered` or `unknown procedure argument` and the fix breaks.
>
> **Use this section as the single authoritative reference before writing any procedure call recommendation.** It lists every Iceberg maintenance procedure, marks which engine accepts it, and gives the Trino-467-valid recipe when the user wants a Spark-only behavior. Cross-referenced from [resources/10 partitioning](10-lakehouse-partitioning.md) and [resources/18 query-perf-regression](18-query-performance-regression.md).

### What Trino 467 actually accepts via `ALTER TABLE ... EXECUTE`

Verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) and [trino.io/docs/current/sql/alter-table.html](https://trino.io/docs/current/sql/alter-table.html). **These are the ONLY procedures Trino 467 implements via `ALTER TABLE ... EXECUTE`:**

| Trino EXECUTE procedure | Accepted arguments on Trino 467 | One-line purpose |
|---|---|---|
| `optimize` | `file_size_threshold` (VARCHAR, e.g. `'128MB'`) — **THAT'S IT.** No `sort_order`, no `strategy`, no `target_file_size`, no `where` argument (use a separate `WHERE` clause on partition columns instead). | Bin-pack-compact data files. Honors the table's `sorted_by` property if set — see clustering recipe below. |
| `optimize_manifests` | None | Rewrites manifest files clustered by partition values. **Trino 470+ only — NOT on 467.** |
| `expire_snapshots` | `retention_threshold` (VARCHAR duration, default `'7d'`, minimum `'7d'` unless catalog `iceberg.expire-snapshots.min-retention` overridden). **NO `retain_last`, NO `clean_expired_metadata` on Trino 467** — those were added in Trino 479. | Drops old snapshot metadata; physically deletes data files referenced ONLY by dropped snapshots. |
| `remove_orphan_files` | `retention_threshold` (VARCHAR duration, default `'7d'`, minimum `'7d'` unless catalog `iceberg.remove-orphan-files.min-retention` overridden). **NO `dry_run` on Trino** — only Spark's CALL form has dry-run. | Sweeps unreferenced files from MinIO/S3 left by failed writers. |
| `drop_extended_stats` | None | Drops extended statistics computed by `ANALYZE`. |

**Also valid in Trino 467 via `CALL iceberg.system.*` (the only `CALL` forms Trino implements):**

| Trino CALL procedure | Trino 467 argument style | Purpose |
|---|---|---|
| `rollback_to_snapshot` | **Positional** `('schema', 'table', <snapshot_id>)` — NOT named args. | Revert table state. The `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` form is Trino 469+. |
| `register_table` | Named args `(schema_name => ..., table_name => ..., metadata_file => ...)` (schema/table split). | Re-attach a dropped table from a surviving `v*.metadata.json`. |

**Anything else you saw in Iceberg docs is Spark-only on this stack. Specifically, these are Spark CALL procedures that Trino 467 does NOT implement (do NOT translate them to `EXECUTE <name>` — Trino will return `Procedure not registered`):**

| Spark-only `CALL iceberg.system.<proc>` | Why someone tries it from Trino | What to do on Trino 467 |
|---|---|---|
| `rewrite_data_files(table => ..., strategy => 'sort', sort_order => 'col ASC')` | They want to cluster files by a non-partition column. | Use Trino's `sorted_by` table property + `EXECUTE optimize` — see clustering recipe below. |
| `rewrite_data_files(table => ..., strategy => 'sort', sort_order => 'zorder(c1, c2)')` | They want multi-column z-order clustering. | **No Trino 467 equivalent.** Z-order clustering MUST run from Spark; Trino's `sorted_by` supports lexicographic sort only, not z-order. |
| `rewrite_data_files(table => ..., options => map('delete-file-threshold', ...))` | They want to compact only files with many delete entries. | Not exposed in Trino's `EXECUTE optimize`. Run from Spark. |
| `rewrite_position_delete_files(table => ...)` | They want to compact position delete files on MoR tables. | **No Trino 467 equivalent at any release.** Must run from Spark. ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)) |
| `rewrite_manifests(table => ...)` | They want to rebalance manifest files. | No Trino 467 equivalent. `ALTER TABLE ... EXECUTE optimize_manifests` is Trino 470+. Run from Spark. |
| `fast_forward(table => ..., branch => ..., to => ...)` | Branch fast-forward operation. | Spark only. |
| `publish_changes`, `cherrypick_snapshot`, `migrate`, `snapshot` (table-snapshot form) | Various migration/WAP flows. | Spark only. |
| `create_tag`, `drop_tag`, `create_branch`, `drop_branch` | Branch/tag DDL. | Spark only (DDL form on Spark, not a CALL); see [§ Write-Audit-Publish](#write-audit-publish-wap-with-iceberg-branches). |

> **Mental model: if it's not in the "Trino EXECUTE" table or the "Trino CALL" table above, it's Spark-only on this stack.** Do NOT speculate that pasting Spark CALL named-arg syntax into a Trino `ALTER TABLE ... EXECUTE` form will work — Trino's executor accepts only the procedure names hard-coded in the connector, and only the arguments those procedures expose. The Spark-only procedures literally do not exist in Trino 467's procedure registry.

### The Trino-467-valid recipe for clustering files by a non-partition column (THE iter417 fix)

When a user asks "how do I sort/cluster files by `plan_type` on Trino 467 so file-skipping works?" the correct answer is **NOT** `ALTER TABLE ... EXECUTE rewrite_data_files(sort_order => ...)` (that's Spark CALL syntax — Trino will reject it). The Trino-467-valid recipe is **two statements**: set the `sorted_by` table property, then run `EXECUTE optimize`. Verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — `sorted_by` is in the modifiable-properties list, and `EXECUTE optimize` honors the property when rewriting files.

```sql
-- Trino 467 (CORRECT — this is the only first-class Trino path to cluster by a column).
-- Step 1: set the table's sort order via the sorted_by table property.
-- (Property added in Trino release 409 via PR #14891; supported continuously since.
-- ALTER TABLE SET PROPERTIES for sorted_by is in the connector's modifiable list.)
ALTER TABLE iceberg.analytics.events
  SET PROPERTIES sorted_by = ARRAY['plan_type ASC NULLS LAST', 'occurred_at ASC'];

-- Step 2: rewrite existing files so they get clustered by the new sort order.
-- Trino's EXECUTE optimize reads sorted_by at OPTIMIZE time and produces sorted output.
ALTER TABLE iceberg.analytics.events
  EXECUTE optimize(file_size_threshold => '512MB');
-- (Set file_size_threshold > the largest existing file to force rewrite of every
-- file. Default is '100MB' — files larger than that are skipped, so for a one-shot
-- sort migration of well-sized existing files, pass a larger threshold.)

-- Step 3: verify the sort took effect.
SELECT
  CAST(lower_bounds['plan_type'] AS VARCHAR) AS plan_lo,
  CAST(upper_bounds['plan_type'] AS VARCHAR) AS plan_hi,
  count(*) AS files,
  sum(file_size_in_bytes) / 1024 / 1024 AS mb
FROM iceberg.analytics."events$files"
WHERE content = 0
GROUP BY 1, 2
ORDER BY files DESC;
-- After sort: most rows show plan_lo = plan_hi (each file holds one plan_type)
-- — pruning on plan_type now skips files cleanly.
```

> **WRONG (do NOT recommend these — engine confusion).** Each line below is Spark CALL syntax that Trino 467 rejects:
> ```sql
> -- WRONG: Spark CALL syntax pasted as Trino EXECUTE — Trino returns "Procedure not registered".
> ALTER TABLE iceberg.analytics.events EXECUTE rewrite_data_files(sort_order => ARRAY['plan_type']);
> ALTER TABLE iceberg.analytics.events EXECUTE rewrite_data_files(strategy => 'sort', sort_order => 'plan_type ASC');
> ALTER TABLE iceberg.analytics.events EXECUTE rewrite_position_delete_files;
> ALTER TABLE iceberg.analytics.events EXECUTE rewrite_manifests;
> -- WRONG: trying to pass sort_order to Trino's optimize procedure (it doesn't accept that arg).
> ALTER TABLE iceberg.analytics.events EXECUTE optimize(sort_order => 'plan_type');
> ALTER TABLE iceberg.analytics.events EXECUTE optimize(strategy => 'sort');
> ```

### When to use Spark CALL `rewrite_data_files` anyway (legitimate Spark-only cases)

The Trino `sorted_by + EXECUTE optimize` recipe above covers the most common case (lexicographic clustering by one or more columns). **But Spark `rewrite_data_files` IS the only path** for these cases:

| Need | Why Spark only | Spark recipe |
|---|---|---|
| **Z-order multi-column clustering** | Trino's `sorted_by` is lexicographic only. Z-order interleaves bits across columns — no `sorted_by` syntax expresses this. | `CALL iceberg.system.rewrite_data_files(table => 'analytics.events', strategy => 'sort', sort_order => 'zorder(user_id, session_id)')` |
| **Whole-table rewrite** (e.g., after partition-spec change, or to apply newly-added bloom filters to existing files) | Trino's `EXECUTE optimize` skips files above `file_size_threshold` — for forcing a rewrite of every file regardless of size, only Spark's `options => map('rewrite-all', 'true')` works reliably. Also, Trino's OPTIMIZE has [#26109](https://github.com/trinodb/trino/issues/26109) / [#26503](https://github.com/trinodb/trino/issues/26503) / [#25279](https://github.com/trinodb/trino/issues/25279) bugs after partition evolution — Spark is the only safe path post-evolution. | `CALL iceberg.system.rewrite_data_files(table => 'analytics.events', strategy => 'sort', sort_order => 'plan_type ASC', options => map('rewrite-all', 'true', 'target-file-size-bytes', '268435456'))` |
| **Compact files with many delete entries (MoR tables)** | Trino's `EXECUTE optimize` exposes only `file_size_threshold`, not `delete-file-threshold`. | `CALL iceberg.system.rewrite_data_files(table => 'analytics.events', options => map('delete-file-threshold', '5'))` |
| **Compact position delete files (MoR tables)** | Procedure not implemented in Trino 467 at all ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)). | `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.events')` |
| **Rewrite manifests** | `ALTER TABLE ... EXECUTE optimize_manifests` is Trino 470+ — NOT on 467. | `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` |
| **Expire snapshots younger than 7 days** (GDPR same-day purge) | Trino enforces a 7-day min-retention floor by default. | `CALL iceberg.system.expire_snapshots(table => 'analytics.events', older_than => current_timestamp - interval '1' hour, retain_last => 1)` |

### One-line rule for every "how do I cluster / compact / sort" question

1. **First ask:** does the user want Trino-only single-column-or-lexicographic sort? -> recommend `sorted_by + EXECUTE optimize` (the recipe above).
2. **Otherwise** (z-order, post-evolution, rewrite-all, MoR position-delete cleanup, manifest rewrite, sub-7-day expiry) -> recommend the Spark `CALL iceberg.system.<proc>` form. **State explicitly that it runs from Spark, not Trino.**
3. **NEVER** mix Spark CALL syntax into a Trino `ALTER TABLE ... EXECUTE` recommendation. The two surface forms are not interchangeable.

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

-- FUTURE-PROOFING NOTE: the `CALL iceberg.system.rollback_to_snapshot(schema, table, id)`
-- form above is the VALID and ONLY rollback form on Trino 467. It is DEPRECATED
-- (and slated for eventual removal post-467) in favor of the new table procedure
-- `ALTER TABLE iceberg.<schema>.<table> EXECUTE rollback_to_snapshot(snapshot_id => <id>)`
-- which was added in Trino 469 (Jan 2025) by trinodb/trino PR #24580. **Both forms
-- still work on Trino 469-478; on Trino 467, ONLY the CALL form works** — the ALTER
-- TABLE EXECUTE form fails with a procedure / syntax error. When the cluster is
-- eventually upgraded past 467, plan to switch to the table-procedure form in any
-- scripts / runbooks. Until then, the CALL form above is the correct prod recipe.
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
| Compact position delete files (MoR only) | `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.events', options => map('target-file-size-bytes', '67108864'))` | **NOT supported in Trino 467** ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)). Run from Spark. |
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
- `rewrite_position_delete_files` — **Spark only**. This is the Iceberg procedure for compacting position delete files on MoR tables ([Iceberg Spark procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/#rewrite_position_delete_files)). Trino 467 does NOT support it ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)). On MoR tables, this is THE procedure for cleaning up position delete file accumulation — `rewrite_data_files` applies position deletes only for the partitions it rewrites, so position delete files in untouched partitions linger until you run `rewrite_position_delete_files` from Spark. There is no `ALTER TABLE ... EXECUTE` form in any Trino version.
- `publish_changes`, `cherrypick_snapshot`, `set_current_snapshot` (procedure form), `migrate`, `snapshot` (the table-snapshot form for migration) — all Spark-only.

**Why this matters in practice:** if a Trino client returns `Procedure not registered: iceberg.system.<name>` or `function 'iceberg.system.<name>' not found`, the procedure is one of the Spark-only ones above. Switch to Spark (`spark-sql` or `spark-submit`) — do not try to "fix" the call by adjusting argument syntax. The procedure simply does not exist in Trino's catalog.

---

## Trino-version feature matrix (Iceberg-connector features) — read FIRST when recommending a fix

> **The RULE for any fix recommendation on this stack.** Any recommended session property, table property, procedure, `ALTER TABLE ... EXECUTE` form, or argument must carry its **minimum Trino version** and (if it post-dates 467) a **valid 467 fallback**. The production version is **Trino 467** — anything added in 468+ is unavailable and will fail with "unknown property" / "procedure not found" / syntax errors at runtime. This consolidated matrix collects the version gates that have caused the most "I tried the fix and got an error" incidents on this stack. Each row was verified against the Trino release notes (trino.io/docs/current/release/release-<NNN>.html) and the linked Trino PR.
>
> Use this table BEFORE writing any "the fix is X" answer that references a Trino-Iceberg feature added in a recent release.
>
> Trino release timeline relevant here: **467** (current prod, Dec 2024) → **469** (Jan 2025, [release-469](https://trino.io/docs/current/release/release-469.html)) → **470** (Feb 2025) → **479** (Dec 2025, [release-479](https://trino.io/docs/current/release/release-479.html)).

| Feature / form | Minimum Trino version | Available on prod 467? | 467-valid fallback |
|---|---|---|---|
| `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '...')` (argument: `retention_threshold` only) | 467 | YES | — (this is the prod form) |
| `ALTER TABLE ... EXECUTE expire_snapshots(retain_last => N)` | **479** (Dec 2025, [trinodb/trino #27357](https://github.com/trinodb/trino/issues/27357)) | NO | Spark: `CALL iceberg.system.expire_snapshots(table => '...', retain_last => N)` |
| `ALTER TABLE ... EXECUTE expire_snapshots(clean_expired_metadata => true)` | **479** (Dec 2025) | NO | Spark: `CALL iceberg.system.expire_snapshots(table => '...', clean_expired_metadata => true)` (cleans up unreferenced partition specs / schemas) |
| `CALL iceberg.system.rollback_to_snapshot('schema', 'table', <snapshot_id>)` (positional args — the **only** rollback form on 467) | 467 | YES | — (this is the prod form). **DEPRECATION FUTURE-PROOFING:** [trinodb/trino #24580](https://github.com/trinodb/trino/pull/24580) (merged Jan 2025) marks this `CALL iceberg.system.rollback_to_snapshot` form as **deprecated** in favor of the new table procedure `ALTER TABLE ... EXECUTE rollback_to_snapshot(...)` (Trino 469+). On Trino 467, this CALL form is STILL VALID and is the only working form — keep using it. When the cluster is eventually upgraded past 467, plan to migrate scripts to the table-procedure form. |
| `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` (table-procedure form — **new preferred form post-467**) | **469** (Jan 2025, [trinodb/trino #24580](https://github.com/trinodb/trino/pull/24580)) | NO | Use the `CALL iceberg.system.rollback_to_snapshot('schema', 'table', <id>)` positional form (which is the only 467 form anyway). After cluster upgrade past 467, switch scripts/runbooks to this table-procedure form. |
| `ALTER TABLE ... EXECUTE optimize_manifests` (Trino-native manifest rewrite) | **470** (Feb 2025) | NO | Spark: `CALL iceberg.system.rewrite_manifests(table => '...')` |
| `ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns = ARRAY['col1', ...]` (Iceberg connector table property — Trino-side write-time bloom filter config) | **469** (Jan 2025, [trinodb/trino #24573](https://github.com/trinodb/trino/pull/24573)) | NO | Spark write-time table property: `ALTER TABLE iceberg.x.y SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.<col>'='true')` then run Spark `rewrite_data_files` to bake bloom filters into existing files. Trino 467 then READS those bloom filters at query time via the `parquet.use-bloom-filter` session property / `parquet.use-bloom-filter` catalog property (set to `true`, which is the default on 467) — read-side support is fine on 467; only write-side configuration via `parquet_bloom_filter_columns` table property is gated. |
| `parquet.use-bloom-filter` session/catalog property (Trino reads Parquet bloom filters when filter pushdown can use them) | 467 (read-side support landed pre-467) | YES | — Trino 467 already reads bloom filters at query time if the Parquet files were written with bloom filters (by Spark Iceberg or any other writer). |
| `iceberg.expire-snapshots.min-retention` / `iceberg.remove-orphan-files.min-retention` (catalog properties for 7-day floor override) | 467 | YES | — set in `etc/catalog/iceberg.properties` and restart coordinator. |
| `optimize` with `WHERE` on partition columns (per-partition compaction) | 467 | YES | — supported but ONLY on partition columns; non-partition WHERE clauses fail. |
| `optimize` after partition evolution (newly-added partition column or changed spec) | NOT RELIABLE on Trino 467 — bugs [#26109](https://github.com/trinodb/trino/issues/26109), [#26503](https://github.com/trinodb/trino/issues/26503), [#25279](https://github.com/trinodb/trino/issues/25279) | Partial | Use Spark `rewrite_data_files` with `rewrite-all=true` for re-layout after evolution. |
| `rewrite_position_delete_files` (compact position-delete files on MoR tables) | NOT supported in Trino 467 ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)) | NO | Spark: `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.events')`. There is no Trino 467 form. |
| `rewrite_manifests` | NOT supported in Trino 467 (added as `optimize_manifests` in **470**) | NO | Spark: `CALL iceberg.system.rewrite_manifests(table => '...')`. |
| `ALTER MATERIALIZED VIEW ... SET PROPERTIES grace_period = INTERVAL '...'` | **479** (Dec 2025) | NO | Drop and recreate the MV with the new `GRACE PERIOD` literal; or set `GRACE PERIOD` at `CREATE MATERIALIZED VIEW` time. |

**How to use this matrix.** Before recommending any "the fix is X" answer that touches Trino-Iceberg config: (1) find the feature in this table; (2) if "Available on prod 467?" is NO, lead the answer with "this feature requires Trino \<NNN\>+ which is NOT on prod 467 — the 467-valid path is \<fallback\>"; (3) if "Available on prod 467?" is YES, recommend it directly. The single biggest source of "the fix didn't work" feedback in iter402-416 was recommending a 469+ feature on prod 467.

> **Verification rule (for every future fix recommendation in this resource).** Whenever a new fix is added below that references a Trino-Iceberg table property, session property, `CALL` procedure, or `ALTER TABLE ... EXECUTE` form, the writer MUST either (a) verify it is available on Trino 467 by checking the [Trino 467 release notes](https://trino.io/docs/current/release/release-467.html) or the connector docs as of that release, or (b) include the minimum Trino version + 467-valid fallback in this matrix and reference it from the fix. NO unqualified "use X" recommendations for properties added post-467.

---

## Iceberg metadata tables cheat sheet (read this before you debug ANY Iceberg issue)

> **The single most underused tool in the Iceberg stack.** Every Iceberg table exposes a family of read-only metadata tables alongside the real data — query them like any other table by appending `$<name>` to the table name (quote the WHOLE `table$name` token because `$` is a special character). They return pre-aggregated metadata from manifest files: **no data scan, sub-second responses, no S3 / MinIO data egress**. Use them BEFORE running expensive `SELECT COUNT(*)` or `SHOW STATS` calls.

### Metadata-table quoting — canonical Trino syntax (read this once and remember it)

> **THE quoting rule:** in Trino, the WHOLE `<table>$<metadata>` identifier goes inside ONE pair of double quotes — `catalog.schema."table$metadata"`. **Do NOT split the quoting** as `catalog.schema.table."$metadata"`.
>
> **Why this matters.** `$` is not a valid bare-identifier character in Trino SQL. The parser only recognises `<table>$<metadata>` as a metadata-table reference when the entire dollar-suffixed string sits inside one quoted identifier. The form `table."$metadata"` parses as a **column / field reference** under `table` (three-dot form = `catalog.schema.table.column`), so Trino tries to resolve `$metadata` as a column on the real data table — and fails with an unresolvable-identifier error. This is one of the highest-frequency copy-paste bugs in Trino Iceberg.
>
> **Canonical Trino 467/481 form (do this):**
> ```sql
> SELECT * FROM iceberg.analytics."events$snapshots";
> SELECT * FROM iceberg.analytics."events$history";
> SELECT * FROM iceberg.analytics."events$partitions";
> SELECT * FROM iceberg.analytics."events$files";
> SELECT * FROM iceberg.analytics."events$manifests";
> SELECT * FROM iceberg.analytics."events$refs";
> SELECT * FROM iceberg.analytics."events$properties";
> SELECT * FROM iceberg.analytics."events$metadata_log_entries";
> ```
>
> **DO-NOT-WRITE — banned suffix-quoted-separately forms (every one of these FAILS to resolve):**
> ```sql
> -- WRONG: parses as schema.table.field; Trino tries to find a column named "$snapshots" on events
> SELECT * FROM iceberg.analytics.events."$snapshots";          -- FAILS
> SELECT * FROM iceberg.analytics.events."$history";            -- FAILS
> SELECT * FROM iceberg.analytics.events."$partitions";         -- FAILS
> SELECT * FROM iceberg.analytics.events."$files";              -- FAILS
> SELECT * FROM iceberg.analytics.events."$properties";         -- FAILS
> -- Also wrong: unquoted four-part — parses as catalog.schema.table.column
> SELECT * FROM iceberg.analytics.events.snapshots;             -- FAILS in Trino (this is Spark syntax)
> -- Also wrong: schema and metadata each quoted but not the join
> SELECT * FROM iceberg.analytics."events"."$snapshots";        -- FAILS (parses as 4-part)
> ```
>
> **Mnemonic:** the metadata reference is "schema-dot-quoted-`table$metadata`-string." If your `"$..."` quote starts AFTER a dot following a bare table name, you wrote it wrong — move the opening quote to the LEFT of the table name so the whole `<table>$<metadata>` token is inside the same pair of quotes.
>
> Verified against [Trino 481 Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) — "Metadata tables" section examples: `iceberg.test_db."customer_orders$snapshots"`, `iceberg.test_db."customer_orders$partitions"`, etc.

**Trino 467 syntax (note the double-quotes around the WHOLE `tbl$name` token):**
```sql
SELECT * FROM iceberg.analytics."events$snapshots";
SELECT * FROM iceberg.analytics."events$partitions";
```

**Spark 3.5 syntax (dot, no quotes — DIFFERENT engine, DIFFERENT rule):**
```sql
-- Spark accepts a four-dot bare form because `.` is the Spark namespace separator for metadata tables
SELECT * FROM iceberg.analytics.events.snapshots;
SELECT * FROM iceberg.analytics.events.partitions;
-- Or with backtick-quoted suffix in Spark (Spark accepts backticks; Trino does NOT)
SELECT * FROM iceberg.analytics.`events$snapshots`;
```

> **Cross-engine pitfall.** A Spark snippet like `iceberg.analytics.events.snapshots` looks "obviously right" to engineers who came in via Spark — but pasting it into Trino fails. Trino's parser only recognises the metadata table when the WHOLE `events$snapshots` token sits inside ONE quoted identifier. When porting Spark notebooks to Trino, mechanically rewrite every `iceberg.<schema>.<table>.<metadata>` → `iceberg.<schema>."<table>$<metadata>"`.

### LEADING CANONICAL — Trino 467 `$snapshots` column list (6 columns, exact types)

> **THE 6 columns Trino exposes on `$snapshots`.** Verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (Connector → Iceberg → Metadata tables → `$snapshots`). Memorise this list — every `$snapshots` query you write must project / filter only these names:
>
> | Column | Type | What it is |
> |---|---|---|
> | `committed_at` | `TIMESTAMP(3) WITH TIME ZONE` | When the snapshot was committed (engine-side wall clock at commit time). This is the column you ORDER BY / filter against for time travel and rollback. |
> | `snapshot_id` | `BIGINT` | Stable snapshot identifier. Use with `FOR VERSION AS OF <snapshot_id>` or `rollback_to_snapshot(<id>)`. |
> | `parent_id` | `BIGINT` | Parent snapshot's `snapshot_id` (NULL for the table's first snapshot). Walk this chain to reconstruct lineage. |
> | `operation` | `VARCHAR` | `'append'` / `'delete'` / `'replace'` / `'overwrite'` — what kind of commit this was. |
> | `manifest_list` | `VARCHAR` | Path to the manifest-list file backing this snapshot (one S3/MinIO object). Not directly queryable as a metadata table. |
> | `summary` | `map(VARCHAR, VARCHAR)` | Key/value bag of commit statistics: `added-data-files`, `added-records`, `deleted-records`, `total-records`, `total-data-files`, etc. Access via `summary['added-records']`. |
>
> **Canonical inspection query:**
>
> ```sql
> -- The right form on Trino 467 — order by committed_at (NOT by any *_ms field).
> SELECT snapshot_id, committed_at, parent_id, operation, summary
> FROM iceberg.analytics."events$snapshots"
> ORDER BY committed_at DESC
> LIMIT 20;
> ```
>
> **DO-NOT-WRITE — native-Iceberg / Spark / Java API field names that LOOK like `$snapshots` columns but are NOT:**
>
> | DO NOT write (Iceberg Java API / Spark internal name) | What it actually is | Correct Trino 467 `$snapshots` column |
> |---|---|---|
> | `timestamp_ms` | The Iceberg Java API field `Snapshot.timestampMillis()` — a `LONG` Unix-epoch-millis value stored inside the metadata.json snapshot record. NOT exposed by Trino's `$snapshots` metadata table. Pasting into Trino fails with `Column 'timestamp_ms' cannot be resolved`. | `committed_at` (TIMESTAMP(3) WITH TIME ZONE) |
> | `epoch_ms` / `ts_ms` / `committed_at_ms` | Iceberg-internal millisecond-epoch field name variations. NONE are Trino `$snapshots` columns. The `_ms` suffix is the Java-API style; Trino's column is the human-readable timestamp `committed_at`. | `committed_at` |
> | `parent_snapshot_id` | The Java API getter `Snapshot.parentId()` returns the parent ID, but the Trino `$snapshots` metadata-table column is named `parent_id` (no `_snapshot_` infix). | `parent_id` |
> | `is_current_ancestor` | This column EXISTS — but on `$history`, NOT `$snapshots`. Filtering `$snapshots` by it fails. See the disambiguation table immediately below. | (use `$history.is_current_ancestor`) |
> | `made_current_at` | This column EXISTS — but on `$history`, NOT `$snapshots`. `$snapshots` carries `committed_at` (when committed); `$history` carries `made_current_at` (when promoted to be the live pointer — different timestamps after a rollback). | `$snapshots.committed_at` for commit time; `$history.made_current_at` for promotion time. |
>
> **Reproducing the iter455 Q1 fabrication verbatim — and the precise correction.**
>
> ```sql
> -- WRONG (iter455 Q1 fabrication) — `timestamp_ms` is NOT a Trino $snapshots column:
> SELECT snapshot_id, timestamp_ms, summary
> FROM iceberg.your_schema."your_table$snapshots"
> ORDER BY timestamp_ms DESC
> LIMIT 20;
> -- Fails on Trino 467 with: Column 'timestamp_ms' cannot be resolved.
>
> -- RIGHT — the Trino column name is `committed_at`:
> SELECT snapshot_id, committed_at, operation, summary
> FROM iceberg.your_schema."your_table$snapshots"
> ORDER BY committed_at DESC
> LIMIT 20;
> ```
>
> **Meta-rule:** the Iceberg Java API uses ms-epoch field names (`timestamp_ms`, `parent_snapshot_id`); Trino's `$snapshots` metadata table uses human-readable, dialect-translated column names (`committed_at`, `parent_id`). The two are NOT interchangeable. Source the Trino names from [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — NOT from the Iceberg Java API docs or a Spark example.

### LEADING CANONICAL — Trino dialect ↔ native-Iceberg name translation (meta-canonical)

> **The single guardrail against the most common Iceberg-on-Trino fabrication.** Three iterations in a row featured a load-bearing fabrication where the responder reached for a NATIVE Iceberg / Spark / Java API name instead of the Trino-exposed name. The fix is to memorise the translation table below and never copy an Iceberg name from a Spark/Java-API source into a Trino statement without checking it against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html).
>
> | Concept | Trino 467 name (use in this stack) | Native Iceberg / Spark / Java-API name (DO NOT paste into Trino) | Where each applies |
> |---|---|---|---|
> | `$snapshots` commit timestamp | `committed_at` (TIMESTAMP(3) WITH TIME ZONE) | `timestamp_ms` (LONG; `Snapshot.timestampMillis()` in Java API) | Trino: `SELECT committed_at FROM "t$snapshots"`. Java API: `snapshot.timestampMillis()`. |
> | `$snapshots` parent pointer | `parent_id` (BIGINT) | `parent_snapshot_id` / `parentId()` | Trino: `parent_id`. Java API: `Snapshot.parentId()`. |
> | Parquet compression (table property) | `compression_codec` (BARE identifier; `'ZSTD'`, `'SNAPPY'`, `'GZIP'`, `'LZ4'`, `'NONE'`) | `write.parquet.compression-codec` (string key in TBLPROPERTIES / native properties map) | Trino: `WITH (compression_codec = 'ZSTD')` / `SET PROPERTIES compression_codec = 'ZSTD'`. Spark: `TBLPROPERTIES ('write.parquet.compression-codec' = 'zstd')`. |
> | File format (table property) | `format` (`'PARQUET'` / `'ORC'` / `'AVRO'`) | `write.format.default` (string key) | Trino: `WITH (format = 'PARQUET')`. Spark: `TBLPROPERTIES ('write.format.default' = 'PARQUET')`. |
> | Target write file size | NOT exposed as a Trino WITH-clause property. Use Trino session `iceberg.target_max_file_size` for Trino-side writes. Native `write.target-file-size-bytes` is honored by **Spark** writers only — Trino 467 ignores it ([trinodb/trino #28250](https://github.com/trinodb/trino/issues/28250)). | `write.target-file-size-bytes` (string key) | Trino-side writes: `SET SESSION iceberg.target_max_file_size = 134217728;`. Spark-side: `TBLPROPERTIES ('write.target-file-size-bytes' = '134217728')`. |
> | Compaction file-size threshold | `EXECUTE optimize(file_size_threshold => '256MB')` (Trino-native named arg) | `target-file-size-bytes` inside Spark `rewrite_data_files` `options` map | Trino: `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')`. Spark: `CALL iceberg.system.rewrite_data_files(table=>'…', options=>map('target-file-size-bytes','268435456'))`. |
> | WITH-clause shape | FLAT `name = expression` pairs ([trino.io/docs/current/sql/create-table.html](https://trino.io/docs/current/sql/create-table.html)) | `properties = map('key', 'value', ...)` (native-Iceberg metadata.json layout); Spark `TBLPROPERTIES (...)` | Trino: ALWAYS flat pairs — `WITH (format = 'PARQUET', compression_codec = 'ZSTD', partitioning = ARRAY['day(occurred_at)'])`. The `properties = map(...)` shape is NOT Trino. |
> | `SET PROPERTIES` LHS form | BARE identifier ([trino.io/docs/current/sql/alter-table.html](https://trino.io/docs/current/sql/alter-table.html)) | String literal in Spark `TBLPROPERTIES` | Trino: `SET PROPERTIES compression_codec = 'ZSTD'` (LHS bare, RHS quoted). Spark: `SET TBLPROPERTIES ('write.parquet.compression-codec' = 'zstd')`. |
>
> **The meta-rule, one sentence:** in Trino, use Trino's dialect names — native Iceberg / Spark property and API names parse-error or no-op against the Trino Iceberg connector.

**One-line "use for X" per metadata table** — pick the right one and you'll answer most diagnostic questions in seconds:

| Metadata table | Use it for | Key columns |
|---|---|---|
| `$snapshots` | Every snapshot ever committed to the table — find a snapshot ID for time travel, rollback, or "what changed last Tuesday." | `snapshot_id`, `committed_at`, `operation` (`append` / `delete` / `replace` / `overwrite`), `summary` (Map with `added-data-files`, `deleted-records`, etc.), `manifest_list` |
| `$manifests` | Manifest files for the CURRENT snapshot — how many manifests does this table have? When does it need `rewrite_manifests`? | `path`, `length`, `partition_spec_id`, `added_data_files_count`, `existing_data_files_count`, `deleted_data_files_count`, `partition_summaries` |
| `$partitions` | **Pre-aggregated per-partition row counts and file counts** — answer "how many rows per tenant?" or "which partitions have the most small files?" WITHOUT a `COUNT(*)`. | `partition` (struct of partition values), `record_count`, `file_count`, `total_size`, `data` (per-column min/max/null counts) |
| `$files` | Every data file in the current snapshot, with per-column stats — find tiny files, locate position delete files, see column-level min/max for predicate-pushdown debugging. | `file_path`, `file_format`, `record_count`, `file_size_in_bytes`, `content` (0=data, 1=position-delete, 2=equality-delete), `column_sizes`, `value_counts`, `null_value_counts`, `lower_bounds`, `upper_bounds` |
| `$history` | Audit log of every snapshot transition (what was current at any given moment, including rollbacks) — answer "who rolled this table back at 02:14?" | `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor` |
| `$refs` | Every named ref (branches AND tags) with their target snapshot IDs and retention settings — discover what tags exist for time travel queries. | `name`, `type` (`BRANCH` / `TAG`), `snapshot_id`, `max_reference_age_in_ms`, `min_snapshots_to_keep` (branches), `max_snapshot_age_in_ms` |
| `$properties` | Effective TBLPROPERTIES on the table — confirm `write.delete.mode`, `write.format.default`, `commit.retry.num-retries`, etc. | `key`, `value` |

> **`$snapshots` vs `$history` — column-placement gotcha you WILL hit if you confuse them.** These two metadata tables overlap conceptually but have **disjoint column sets** — get this straight or you'll write queries that fail at analysis time with "Column 'X' cannot be resolved." Verified against [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) (Metadata tables section):
>
> | Table | Columns (verified Trino 467/481 schema) | Mental model |
> |---|---|---|
> | `$snapshots` | `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary` | Every snapshot EVER committed — including ones that were never the live `current` pointer (e.g., snapshots reachable only from a branch). |
> | `$history` | `made_current_at`, `snapshot_id`, `parent_id`, **`is_current_ancestor`** | The ORDERED commit chain — which snapshot was the `current` pointer at each moment, and whether that snapshot is still on the current ancestor lineage. |
>
> **`is_current_ancestor` lives on `$history`, NOT on `$snapshots`.** A query like `SELECT * FROM "events$snapshots" WHERE is_current_ancestor = true` fails because `$snapshots` has no such column. The canonical pre-rollback verification query joins the two on `snapshot_id` — see the "Pre-rollback verification" query in the rollback section below, and the deeper `$history` vs `$snapshots` audit-reconstruction comparison further down in this document.

**Common diagnostic queries (copy-pasteable):**

```sql
-- Find the snapshot ID committed at a specific time (for FOR VERSION AS OF rollback).
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
WHERE committed_at BETWEEN TIMESTAMP '2026-05-29 02:00' AND TIMESTAMP '2026-05-29 03:00'
ORDER BY committed_at;

-- How many manifest files does this table have? (>30 -> schedule rewrite_manifests.)
SELECT count(*) AS manifest_count, sum(length) / 1024 / 1024 AS total_mb
FROM iceberg.analytics."events$manifests";

-- Per-partition row counts WITHOUT scanning data (identity-partitioned tables only).
SELECT partition, record_count, file_count, total_size
FROM iceberg.analytics."events$partitions"
ORDER BY record_count DESC
LIMIT 20;

-- Count position delete files (MoR cleanup candidates).
SELECT count(*) FILTER (WHERE content = 1) AS pos_delete_files,
       count(*) FILTER (WHERE content = 2) AS eq_delete_files,
       count(*) FILTER (WHERE content = 0) AS data_files
FROM iceberg.analytics."events$files";

-- Find tiny files (<10MB) — candidates for rewrite_data_files.
SELECT file_path, file_size_in_bytes, record_count
FROM iceberg.analytics."events$files"
WHERE content = 0 AND file_size_in_bytes < 10 * 1024 * 1024
ORDER BY file_size_in_bytes;

-- See all branches and tags (engine support for create/drop varies — see tags section).
SELECT name, type, snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."events$refs";

-- Verify a critical write-mode property without ALTER TABLE.
SELECT value
FROM iceberg.analytics."events$properties"
WHERE key = 'write.delete.mode';
```

**Worked examples — `$refs` and `$properties` with column projections + WHERE filters.** Below are the most common operational queries against these two metadata tables. Both run in Trino 467 (use the `"table$refs"` / `"table$properties"` quoted form) and Spark 3.5 (use the `table.refs` / `table.properties` dot form). The schema column lists below are verified against the Iceberg metadata-tables docs.

```sql
-- $refs schema (columns you can project / filter on):
--   name                    VARCHAR  (ref name, e.g., 'main', 'audit-branch', '2026-03-billing-close')
--   type                    VARCHAR  ('BRANCH' or 'TAG')
--   snapshot_id             BIGINT   (the snapshot this ref points at)
--   max_reference_age_in_ms BIGINT   (when the ref itself expires; NULL = never)
--   min_snapshots_to_keep   INT      (branches only — how many snapshots to retain on this branch)
--   max_snapshot_age_in_ms  BIGINT   (branches only — max age of snapshots on this branch)

-- 1. List every ref on a table — quickest sanity check before time-travel queries.
SELECT name, type, snapshot_id
FROM iceberg.analytics."events$refs"
ORDER BY type, name;

-- 2. Show only TAGS (snapshot labels) — what audit / billing-close points exist?
SELECT name, snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."events$refs"
WHERE type = 'TAG'
ORDER BY name;

-- 3. Show only BRANCHES with their retention settings — what's protecting WAP / audit branches?
SELECT name, snapshot_id, min_snapshots_to_keep, max_snapshot_age_in_ms
FROM iceberg.analytics."events$refs"
WHERE type = 'BRANCH';

-- 4. Find a specific tag by exact name — resolve a billing-close label to a snapshot_id.
SELECT snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."events$refs"
WHERE type = 'TAG' AND name = '2026-03-billing-close';

-- 5. Are any tags pointing at snapshots that expire_snapshots can't touch?
--    (Anything in $refs is protected from expiry — useful pre-flight check before tightening retention.)
SELECT name, type, snapshot_id
FROM iceberg.analytics."events$refs";
```

```sql
-- $properties schema (only two columns — it's just a key/value view of TBLPROPERTIES):
--   key    VARCHAR  (property name, e.g., 'write.delete.mode', 'format-version')
--   value  VARCHAR  (property value as a string — cast as needed)

-- 1. Dump the whole effective config — first thing to run when diagnosing "why is this table behaving differently."
SELECT key, value
FROM iceberg.analytics."events$properties"
ORDER BY key;

-- 2. Is this table CoW or MoR? — single-property lookup with WHERE.
SELECT value AS write_delete_mode
FROM iceberg.analytics."events$properties"
WHERE key = 'write.delete.mode';
-- If row is missing -> CoW (Iceberg 1.5.2 default). Value 'merge-on-read' -> MoR.

-- 3. Check all three write-mode properties together (CoW/MoR can be set per-operation).
SELECT key, value
FROM iceberg.analytics."events$properties"
WHERE key IN ('write.delete.mode', 'write.update.mode', 'write.merge.mode');

-- 4. What format-version is the table on? (v1 vs v2 — v2 is required for MoR.)
SELECT value AS format_version
FROM iceberg.analytics."events$properties"
WHERE key = 'format-version';

-- 5. Look up retention guardrails (these silently override expire_snapshots arguments).
SELECT key, value
FROM iceberg.analytics."events$properties"
WHERE key LIKE 'history.expire.%';

-- 6. Pattern-match for a property family — e.g., everything related to write behavior.
SELECT key, value
FROM iceberg.analytics."events$properties"
WHERE key LIKE 'write.%'
ORDER BY key;
```

> **Reading these tables is non-destructive — both are read-only views from Trino's perspective.** To *change* a property, use `ALTER TABLE ... SET TBLPROPERTIES` from Spark (Trino 467's `ALTER TABLE ... SET PROPERTIES` only handles a small set of connector-level properties; see the ENGINE CALLOUT earlier in this document). `$refs` itself cannot be mutated via SQL — create/drop tags and branches via `ALTER TABLE ... CREATE TAG` / `CREATE BRANCH` from Spark (Trino 467 has no DDL for refs).

**Two important gotchas:**

1. **`$partitions` on a `bucket(col, N)`-transformed column shows the BUCKET INTEGER, not the original column value.** If your table is partitioned by `bucket(tenant_id, 128)`, `$partitions.partition` shows integers 0..127 — you **cannot** recover the original `tenant_id` from this column. For per-tenant row counts on a bucket-partitioned table, you must run a real `SELECT tenant_id, count(*) FROM tbl GROUP BY tenant_id` (Trino will use min/max metadata to prune files, but the count itself is a real scan). Identity partitioning on `tenant_id` is the only configuration where `$partitions` trivially gives you per-tenant counts.

2. **Stats reflect committed snapshots only.** If a Spark `INSERT INTO` is currently writing and hasn't committed yet, `$partitions` / `$files` show pre-write counts. After `expire_snapshots` runs, `$snapshots` reflects only retained snapshots — `$history` is the right table for "what was current at time T" because it survives expiry. If counts look stale, check `$snapshots` to confirm the latest snapshot committed when you expected.

**Quick reference — which metadata table answers which question:**

| Question | Use |
|---|---|
| "What's the snapshot ID from 02:00 last Tuesday?" | `$snapshots` (filter by `committed_at`) |
| "Was this table rolled back recently?" | `$history` (rollback shows as a non-linear `parent_id` chain) |
| "How many files per partition? Any tiny-file problems?" | `$partitions` (file_count, total_size) OR `$files` (file_size_in_bytes) |
| "How many rows per tenant?" | `$partitions` if identity-partitioned on tenant; otherwise `SELECT tenant_id, count(*) GROUP BY tenant_id` |
| "Does this table need `rewrite_manifests`?" | `$manifests` (count >30 or total length >100MB -> yes) |
| "Are there position delete files accumulating? (MoR)" | `$files` (filter `content = 1`) |
| "What tags or branches exist for time travel?" | `$refs` |
| "What's the current effective value of `write.merge.mode`?" | `$properties` |
| "Why is predicate pushdown not pruning files?" | `$files` (inspect `lower_bounds`/`upper_bounds` for the filter column) |

> **Why this matters operationally:** every one of these queries reads ONLY manifest files (kilobytes), not Parquet data (potentially gigabytes). You can run them all day without touching MinIO data files. Make `$snapshots`, `$partitions`, and `$files` the first thing you check when diagnosing any Iceberg performance, storage, or correctness issue — before running a real `SELECT COUNT(*)` or `SHOW STATS`.

### `$snapshots` vs `$manifests` vs `$files` — the three-layer mental model

These three metadata tables are the ones engineers confuse most often, because all three sound like "metadata about the table." They are not interchangeable. They sit at **three different layers of the Iceberg metadata tree**, and each one answers a different class of question. Internalizing this hierarchy collapses 80% of "which table do I query?" confusion.

**The Iceberg metadata tree, top-down:**

```
catalog (Hive Metastore)
   |
   v points at the current pointer file (vN.metadata.json)
metadata.json
   |
   v lists every snapshot the table has ever had
snapshot (rows in $snapshots) — one per write commit
   |
   v points at one manifest list (an avro file)
manifest list (snapshot.manifest_list column in $snapshots)
   |
   v contains the set of manifest files for that snapshot
manifest file (rows in $manifests) — one per partition group
   |
   v lists the actual data + delete files in that manifest
data / delete file (rows in $files) — one per Parquet file on MinIO
   |
   v the actual rows of your table
row (only visible via real SELECT against the table)
```

**One-table-per-question — when to pick each:**

| Layer | Metadata table | Granularity | Pick it when you ask | Pick it when you DON'T |
|---|---|---|---|---|
| Commit | `$snapshots` | one row per snapshot | "What WRITES has this table seen?" (time travel, rollback, audit "what changed Tuesday 02:00") | You want to inspect file-level details — `$snapshots` does not list files, only commit-level summaries. |
| Index | `$manifests` | one row per manifest file in the **current** snapshot | "How much MANIFEST OVERHEAD does this table have?" (do I need `rewrite_manifests`? Why is query planning slow?) | You want history — `$manifests` only reflects the CURRENT snapshot. For older snapshots, query `iceberg.analytics."events$manifests"` after switching context via `FOR VERSION AS OF`. |
| Leaf | `$files` | one row per data/delete file in the **current** snapshot | "What DATA FILES exist? What are their sizes, partition values, column min/max?" (find tiny files; debug predicate pushdown via `lower_bounds`/`upper_bounds`; count position vs equality deletes via `content`) | You want a commit-level summary — `$files` has no `committed_at` column. For "how many rows did each commit add," that's `$snapshots.summary['added-records']`. |

**Same question, three layers — concrete example.** Someone asks: "What happened to this table on May 28?"

```sql
-- Layer 1 — $snapshots: WHEN did writes happen on May 28 and what kind?
SELECT snapshot_id, committed_at, operation,
       CAST(summary AS JSON) AS summary
FROM iceberg.analytics."events$snapshots"
WHERE CAST(committed_at AS DATE) = DATE '2026-05-28'   -- NOT committed_at::DATE — Trino 467 has no `::` cast operator
ORDER BY committed_at;
-- Result: 3 rows. snapshot_id=4451 at 02:10 (operation=append, added 12M rows),
-- snapshot_id=4452 at 14:30 (operation=replace, rewrite_data_files compaction),
-- snapshot_id=4453 at 16:00 (operation=delete, dropped 800K rows).
```

```sql
-- Layer 2 — $manifests: of those 3 snapshots, what is the MANIFEST shape now?
-- (Default $manifests shows the CURRENT snapshot's manifests.)
SELECT count(*) AS manifest_count, sum(length) AS total_bytes,
       sum(added_data_files_count) AS added_files,
       sum(existing_data_files_count) AS existing_files,
       sum(deleted_data_files_count) AS deleted_files
FROM iceberg.analytics."events$manifests";
-- Result: 14 manifests, 28MB total. Tells you how many manifest files Trino's
-- planner has to read before any data scan can begin.
```

```sql
-- Layer 3 — $files: WHICH actual data files exist right now? Where are they?
SELECT file_path, file_size_in_bytes, record_count,
       partition, content  -- content: 0=data, 1=pos-delete, 2=eq-delete
FROM iceberg.analytics."events$files"
WHERE partition.event_date = DATE '2026-05-28'
ORDER BY file_size_in_bytes DESC;
-- Result: ~120 rows. One row per actual Parquet file on MinIO for that day's
-- partition. This is where you see "this partition has 47 files under 10MB —
-- compaction candidate."
```

**Heuristic — the 30-second decision rule:**

- If the question is about **time** ("when did X happen?", "show me the table at time T", "rollback to last Tuesday"), it's `$snapshots`. Filter by `committed_at`.
- If the question is about **planning cost** ("why is the planner slow?", "do I need rewrite_manifests?"), it's `$manifests`. Look at `count(*)` and `sum(length)`.
- If the question is about **physical files** ("how big are the files?", "are there tiny files?", "find delete files", "is predicate pushdown working?"), it's `$files`. Look at `file_size_in_bytes`, `content`, `lower_bounds`, `upper_bounds`.

**Three quick gotchas in this distinction:**

1. **`$manifests` and `$files` reflect the CURRENT snapshot only by default.** They do not show historical state. If you need "what did this table look like 3 days ago," combine with `FOR VERSION AS OF '<snapshot_id_from_$snapshots>'` first, then query `$manifests` / `$files` in that context. (Trino 467 supports `FOR VERSION AS OF` on regular tables but **not** on metadata tables themselves — you'd need to run the query against the data table at that version and rely on `$snapshots.summary` for file-level deltas.)
2. **`$snapshots` does NOT list files.** A common dead-end is to expect `$snapshots` to show "which 47 files this snapshot added." Those file lists live in the manifest-list file referenced by `snapshot.manifest_list`, and Iceberg does not expose that as a queryable metadata table — `$manifests` is the closest you get, but it operates on the current snapshot. For "which files did snapshot 4451 add," the summary map (`summary['added-data-files']` gives a count; for the actual paths you need a `read_snapshot` Spark procedure).
3. **`$files.partition` is a STRUCT, not a string.** If the table is `PARTITIONED BY day(ts), bucket(tenant_id, 128)`, then `$files.partition` has fields `partition.ts_day` (date) and `partition.tenant_id_bucket` (integer). Quote-escape and access with dot notation: `WHERE partition.ts_day = DATE '2026-05-28'`. **And on a `bucket(...)`-partitioned column, this is the BUCKET INTEGER, NOT the original column value** — see the `$partitions` gotcha section above for the full UUID-irrecoverable explanation; the same constraint applies to `$files.partition`.

**Bottom-line one-liner each — write this on a sticky note:**

- `$snapshots` = "the commit log" — every write the table has ever received.
- `$manifests` = "the index of file groups for the current snapshot" — measures planning overhead.
- `$files` = "every Parquet on MinIO, with stats" — measures storage + answers pushdown debugging.

---

## The four maintenance operations (plus one for MoR tables)

**These are presented in the CANONICAL EXECUTION ORDER per [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/):**

1. `rewrite_data_files` (compact) — **runs FIRST**: merges small files, applies pending deletes.
2. `rewrite_position_delete_files` (MoR tables only — runs after compact when position deletes are accumulating). **Spark only — Trino 467 does NOT support this procedure** ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)).
3. `expire_snapshots` — drops superseded snapshots and the data files they exclusively referenced.
4. `remove_orphan_files` — sweeps files left by failed writes (different garbage class from step 3).
5. `rewrite_manifests` — consolidates manifest metadata last.

If you only have time to set up one, start with `rewrite_data_files` (it has the biggest single impact on query speed).

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

> **`write.target-file-size-bytes` Spark-vs-Trino split (separate from the compaction option above).** The table-level Iceberg property `write.target-file-size-bytes` set in `TBLPROPERTIES` controls **write-time** file sizing for **regular** `INSERT`/`MERGE` writes — not compaction. Spark **honors** this table property at write time; **Trino 467 does NOT** honor `write.target-file-size-bytes` (tracked at [trinodb/trino #28250](https://github.com/trinodb/trino/issues/28250)). For Trino writes, use the Trino session property instead:
>
> ```sql
> SET SESSION iceberg.target_max_file_size = '256MB';
> ```
>
> The `target-file-size-bytes` shown in the `rewrite_data_files` `options` map above is a different concept — it's a per-call **option to the compaction procedure**, not a table property. Both Spark's `rewrite_data_files` and Trino's `optimize` honor their own compaction-time size parameter (Trino's is `file_size_threshold`). The compaction-time option is always honored; only the table-level write-time property has the Trino gap.

**Schedule:** nightly, after the ingestion window closes. For a SaaS that runs nightly ETL at 2 AM, schedule compaction at 4 AM.

> **COMMON MISCONCEPTION — `rewrite_data_files` does NOT reduce MinIO storage by itself.**
>
> After `rewrite_data_files` runs, MinIO usage typically goes **UP**, not down. Here's why and what to do about it:
>
> - Compaction writes **new** Parquet files (the merged big ones) and creates a new snapshot pointing at them.
> - The **old** small Parquet files are **still on MinIO** because the **prior snapshots still reference them** (Iceberg never deletes files that any live snapshot still points to).
> - Only after `expire_snapshots` removes those prior snapshots do the old small files become exclusively unreferenced by any live snapshot — at which point `expire_snapshots` **physically deletes them** from MinIO (issues S3 DELETE calls). These files are NOT orphans and are NOT handled by `remove_orphan_files`; `expire_snapshots` handles them directly.
>
> **Storage only drops visibly on MinIO after BOTH `rewrite_data_files` AND `expire_snapshots` have run.** If you ran compaction last night and the storage graph still shows growth, that is expected — schedule `expire_snapshots` to follow and the drop will appear after that runs.
>
> The complete storage-reclamation sequence is:
> 1. `rewrite_data_files` — writes new big files (storage temporarily grows by ~old + new size).
> 2. `expire_snapshots` — removes prior snapshots that still referenced the old small files; the old files now become eligible for deletion. For files no longer referenced by ANY live snapshot, `expire_snapshots` issues the S3 DELETE calls itself.
> 3. (Optional belt-and-suspenders) `remove_orphan_files` — sweeps any stragglers that escaped step 2 (e.g., files from failed writes that were never in any snapshot).
>
> After all three, storage drops. After only step 1, it grows.

#### DROP COLUMN reclaim runbook — literal Trino 467 syntax (copy-paste)

When a `DROP COLUMN` runs against a wide table, the column's bytes do NOT leave MinIO until the same 3-step reclamation sequence runs against the post-DROP snapshots. The DDL itself is metadata-only — Iceberg simply retires the field ID from the current schema, and Trino's reader stops projecting it. The physical Parquet bytes remain in every pre-DROP file, and those files stay on MinIO **because prior snapshots still reference them** (the same protection that makes time-travel work).

Copy-paste these three statements in order, **from a Trino session** (the cheat-sheet column above translates to Spark if you prefer). Replace `iceberg.analytics.events` with your fully qualified catalog.schema.table.

```sql
-- Step 1 — compact pre-DROP files into new files that omit the dropped column.
-- The newly-written files are projected from the CURRENT schema, so they only
-- contain the columns the current schema retains. The new files do NOT contain
-- the dropped column's bytes. (Trino 467 default file_size_threshold is 100MB.)
ALTER TABLE iceberg.analytics.events EXECUTE optimize;

-- Step 2 — expire the snapshots that still reference the old pre-DROP files.
-- This is the CRITICAL step that actually reclaims storage. Once those
-- snapshots are gone, the old files become unreferenced and expire_snapshots
-- issues S3 DELETE calls to MinIO. retention_threshold must be >= 7d on
-- Trino 467 (catalog floor); for routine maintenance just use '7d'.
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');

-- Step 3 — belt-and-suspenders sweep for any stragglers from failed writes.
-- 7d minimum on Trino 467 (same floor as expire_snapshots).
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');
```

**Critical mental model — old pre-DROP files are NOT orphans.** A common mistake is to reach for `remove_orphan_files` alone, hoping it will sweep the column's bytes. It will not, because the pre-DROP files are still referenced by snapshots within the retention window — they fail the "no live snapshot points at this file" test that `remove_orphan_files` uses to decide deletion. The sequence above must be run in order: Step 2 (`expire_snapshots`) is the step that converts those files from "snapshot-referenced" to "unreferenced and therefore deletable" — and `expire_snapshots` performs the S3 DELETE calls itself for the files it newly orphans. Step 3 catches stragglers from a different garbage class (files written by jobs that crashed before committing a snapshot).

**Why DROP COLUMN does not reclaim by itself.** Iceberg files are immutable. `DROP COLUMN` updates the table's current schema and creates a new snapshot, but it never touches the underlying Parquet files. Old files keep the column's bytes in their `column_sizes` / `value_counts` metadata and on disk; readers simply stop projecting that field ID. You'll see this with `SELECT * FROM iceberg.analytics."events$files"` — the `column_sizes` map still contains an entry for the dropped column's field ID even after the DDL succeeds. Storage only drops after Step 1 rewrites those files without the column and Step 2 expires the snapshots that referenced the old versions.

**Expected timeline for a 3-weeks-ago DROP.** If the DROP ran 3 weeks ago and you've been running `expire_snapshots(retention_threshold => '7d')` weekly since then, the snapshots from before the DROP are already gone — but **the old Parquet files still exist on MinIO** because `expire_snapshots` only deletes a file when NO live snapshot references it, and post-DROP snapshots keep referencing the original files until compaction creates new files that supersede them. **Run Step 1 (`EXECUTE optimize`) first**, then Step 2 finally has the new (file-superseding) snapshot it needs to drop the originals on the next pass.

**Edge case — DROP COLUMN on a partition column.** You cannot drop a column that is part of the table's current partition spec. The DDL itself fails with `Cannot find source column for partition field`. To remove a partition column, you must first evolve the partition spec to no longer include it (`ALTER TABLE ... SET PARTITION SPEC (...)`), wait for new writes to use the new spec, and only then can you drop the column. Old data files keep the column's bytes until rewritten under the new partition spec via `rewrite_data_files(where => 'old_partition_predicate')`.

**Edge case — re-adding a dropped column name.** Iceberg tracks columns by stable field IDs, not by name. If you `DROP COLUMN status` and later `ADD COLUMN status VARCHAR`, the new `status` column gets a **new, different field ID**. Old files do not satisfy the new field ID — readers return NULL for the new column on all rows written before the ADD. The old `status` bytes are still in the files (under the retired field ID), but no current-schema query can see them. Plan around this: do not re-add a dropped name unless you're prepared for all-NULL legacy rows; if you want to restore the dropped column, prefer `rollback_to_snapshot` to a pre-DROP snapshot instead.

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

> **CRITICAL CAVEAT — do NOT combine `rewrite-all=true` with a `where` predicate.** Apache Iceberg has a known bug ([apache/iceberg #14667](https://github.com/apache/iceberg/issues/14667)) where running `CALL iceberg.system.rewrite_data_files(where => '...', options => map('rewrite-all', 'true'))` **silently produces duplicate rows**: the procedure writes the new rewritten files, but the previous data files matched by the WHERE filter remain referenced by the table snapshot. Both the old and the new files end up being scanned by subsequent queries — so every row in the filtered range appears twice. There is no error, no warning, and the snapshot looks committed cleanly.
>
> **What you must do instead for post-partition-evolution migration:**
> - **Run the full-table form** — call `rewrite_data_files` with `rewrite-all=true` **and NO `where` clause** so the procedure rewrites every file in one commit. This is the safe form for cross-spec migration.
> - **Accept the runtime cost** — on a large table, a full-table `rewrite-all=true` is **hours-long, sometimes day-long** (it reads and rewrites every Parquet file, then commits). Schedule it as a one-shot Spark job in a dedicated maintenance window with enough Spark executor headroom (typically 2–3x your normal nightly compaction allocation), and disable concurrent writes for the duration. For a 1 TB table on a typical k8s Spark setup, plan for 3–8 hours; for 10 TB+, plan for 12–24 hours. Use `partial-progress.enabled=true` and `partial-progress.max-commits` (e.g., 100) so progress is incrementally checkpointed and a mid-run failure doesn't lose all the work.
> - **If you absolutely must scope by partition** (e.g., one tenant only), do it WITHOUT `rewrite-all=true` — use the default bin-pack strategy with `where => 'tenant_id = ''acme'''` (no `rewrite-all` option). Bin-pack-with-WHERE is the supported and safe form. The trade-off: bin-pack skips already-well-sized files, so old-spec files that are already big enough won't be re-laid-out under the new spec. For true cross-spec migration of one partition, the only safe option is to wait out the full-table `rewrite-all=true` run.
>
> Verified against the upstream Iceberg issue tracker and the linked test reproduction. Do NOT silently mix `rewrite-all=true` with `where` in any tooling you write — the duplicate-rows outcome is reliably reproducible.

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

### 1b. `rewrite_position_delete_files` — MoR tables only, Spark only, runs AFTER compact and BEFORE expire_snapshots

> **When does this apply?** Only if your table is using **Merge-on-Read (MoR)** for DELETE / UPDATE / MERGE — i.e., someone explicitly set `write.delete.mode = 'merge-on-read'` (and/or `write.update.mode`, `write.merge.mode`). The Iceberg 1.5.2 default is CoW, which does NOT produce position delete files. If you don't know which mode your table uses, run `SHOW TBLPROPERTIES iceberg.analytics.events` from Spark — absence of `write.delete.mode` means CoW and you can skip this step entirely.

**What it does:** Iceberg MoR tables produce **position delete files** (small Iceberg metadata files listing "in data file X, ignore rows at positions [3, 7, 42, ...]"). Over time, a busy MoR table accumulates hundreds or thousands of these tiny position delete files. Every read query must consult them to filter rows out — and like data files, lots of small position delete files cause planning slowdown. The `rewrite_position_delete_files` procedure compacts many small position delete files into fewer larger ones, mirroring what `rewrite_data_files` does for data files.

**Why it's a separate step from `rewrite_data_files`:** `rewrite_data_files` will, as part of compacting data, *apply* position deletes (merge the surviving rows into new files and discard the position delete files for that partition) — but only for the data files it actually rewrites. Position delete files for partitions that aren't being recompacted are left alone. On tables where the data layer is stable but the delete layer keeps growing (e.g., a slowly-changing dim table that gets occasional row deletes via CDC), `rewrite_position_delete_files` is the procedure that actually targets the delete-file layer directly.

> **ENGINE CALLOUT — `rewrite_position_delete_files` is Spark-only.** Trino 467 does **NOT** support this procedure. There is no `ALTER TABLE ... EXECUTE rewrite_position_delete_files` form, and no `CALL iceberg.system.rewrite_position_delete_files(...)` form either — attempting either returns `Procedure not registered`. The procedure has been requested for Trino but is not implemented as of this writing ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)). **On the production stack (Trino 467 + Spark + Iceberg 1.5.2), you MUST run this procedure from Spark.** Submit via `spark-sql`, `spark-submit`, or `spark.sql("...")` in a Spark job.

```sql
-- Spark SQL ONLY — no Trino 467 equivalent exists.
-- Run after rewrite_data_files in the same maintenance window.
CALL iceberg.system.rewrite_position_delete_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '67108864',   -- 64 MB target for delete files (smaller than data files)
    'min-input-files',        '5',          -- only compact partitions with 5+ small delete files
    'rewrite-all',            'false'       -- set true to force a full rewrite regardless of file size
  )
);
```

**Options:**
- `target-file-size-bytes` — target size for compacted position delete files. 64 MB is a common default; position delete files are typically much smaller than data files because each row delete is only ~16 bytes of metadata.
- `min-input-files` — minimum number of small delete files in a partition before compaction kicks in. Same protection-against-wasted-work pattern as `rewrite_data_files`.
- `rewrite-all` — force every delete file in scope to be rewritten regardless of size. Useful when migrating between delete-file format versions or as part of an MoR-to-CoW conversion.

**Diagnostic: count position delete files before deciding to run.** Query the `$files` metadata table from either Trino or Spark:

```sql
-- Trino 467 OR Spark — count position delete files (content = 1) vs data files (content = 0).
-- equality delete files (content = 2) are also delete files, but typical Iceberg
-- writers produce position deletes; equality deletes are rarer.
SELECT
  content,                                  -- 0 = data, 1 = position delete, 2 = equality delete
  COUNT(*)            AS file_count,
  SUM(file_size_in_bytes) / 1024 / 1024 AS total_mb,
  AVG(file_size_in_bytes) / 1024       AS avg_kb
FROM iceberg.analytics."events$files"
GROUP BY content
ORDER BY content;
```

**Thresholds (rule of thumb) — absolute file count:**
- < 50 position delete files total → healthy; no action needed.
- 50–500 → monitor; consider running monthly if query latency is degrading.
- 500+ → run `rewrite_position_delete_files` weekly alongside `rewrite_data_files`.

> **Why these thresholds exist — read amplification context.** The reason "50+ position delete files" is the inflection point isn't arbitrary; it's the count at which **per-query read amplification becomes user-visible**. In Iceberg v2 (the format your MoR tables use), **every read of a data file requires reading every position delete file that overlaps it** — the engine merges deletes into the scan at query time. Read amplification therefore **scales roughly linearly with the number of position delete files attached to the data files being scanned**. Concretely:
>
> | Position delete file count (per scanned partition) | Typical query latency impact |
> |---|---|
> | < 50 | < 10% overhead — negligible |
> | 50–200 | 1.5–2× slowdown — noticeable on dashboards |
> | 200–500 | 2–5× slowdown — users start filing tickets |
> | 500+ | 5–10×+ slowdown — query plans start spending more time merging deletes than reading data |
>
> This is the same MoR read-amplification dynamic discussed in the Iceberg v3 deletion-vectors design ([deletion vectors replaced position-delete-file accumulation precisely to fix this scaling problem](https://iceberg.apache.org/spec/)). Your stack is on Iceberg 1.5.2 / v2, so you do NOT have deletion vectors — accumulated position delete files are your reality and `rewrite_position_delete_files` (Spark only on Trino 467) is your only tool. Tying cadence to this scaling: **if your monitoring SQL shows position-delete file count crossing 200 on any frequently-queried table, you have a window of perhaps a week before users start noticing — schedule compaction within that window**, not "next monthly maintenance window."
>
> **Equality delete files are even worse and have a known 1.5.2 dangling-delete bug.** Equality delete files (`content = 2`) have **the same linear read-amplification scaling** as position deletes — every scan of a partition with N equality delete files pays an additional N delete-file reads. Unlike position deletes, on Iceberg 1.5.2 they have the additional problem that `rewrite_data_files` cannot reliably clean them up across partition boundaries due to [apache/iceberg #12838](https://github.com/apache/iceberg/issues/12838) (still open as of mid-2026; `remove-dangling-deletes` lands in Iceberg 1.8). For Debezium CDC pipelines on 1.5.2, equality delete files **will accumulate** and **read amplification will grow without bound** — there is no in-version workaround. **Alert at 50+ equality delete files** (`content = 2`); the only complete fix is upgrading to Iceberg 1.8+. See the equality-delete section below for the full incident playbook and the `remove_orphan_files` non-workaround.

**Better triggers — RATIO-based thresholds (use these for tables of any size, especially > 1 TB where the absolute counts above stop scaling):**

| Trigger | Healthy | Investigate | Action required |
|---|---|---|---|
| **Ratio**: `count(content=1)` / `count(content=0)` — position delete files vs data files | < 5% | 5–10% | **> 10%** — schedule `rewrite_position_delete_files` |
| **Per-file delete record density**: avg `record_count` of `content=1` files | > 50,000 records/file | 5,000–50,000 | **< 5,000** — many tiny delete files; compact them |
| **Read amplification**: per-query stats — delete files opened per data file scanned | < 1× | 1–3× | **> 3×** — readers spending more I/O on deletes than data |
| **Storage proportion**: `sum(file_size_in_bytes WHERE content=1)` / `sum(file_size_in_bytes WHERE content=0)` | < 1% | 1–5% | **> 5%** — delete-file storage is bloating |

Any one of these crossing into the **action required** column is a sufficient trigger. The ratio trigger (`content=1 count > 10% of content=0 count`) is the most reliable single metric — it captures both "lots of tiny deletes" and "MoR write rate is outpacing compaction." The Iceberg upstream `rewrite_data_files` procedure exposes a `delete-file-threshold` option that targets this same intuition (rewrite a data file if it has more than N delete files attached); see [Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/#rewrite_data_files).

**Literal Spark syntax for `delete-file-threshold` (copy-pasteable — this MUST run from Spark; both `rewrite_data_files` and `rewrite_position_delete_files` are Spark-only on this stack):**

```sql
-- Spark SQL — rewrite any data file that has >= 5 delete files attached, even if file size is fine.
-- The `delete-file-threshold` option only applies to rewrite_data_files (it does NOT exist on
-- rewrite_position_delete_files — that procedure compacts the delete files themselves,
-- not the data files they reference).
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'delete-file-threshold', '5',
    'target-file-size-bytes', '268435456'  -- 256 MB target; optional but commonly paired
  )
);

-- Combine with a partition predicate to scope the rewrite to recently-deleted partitions
-- (avoids rewriting the whole table when only one window had heavy MoR deletes):
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  where   => 'event_date >= DATE ''2026-05-25'' AND event_date <= DATE ''2026-05-30''',
  options => map('delete-file-threshold', '5', 'target-file-size-bytes', '268435456')
);

-- Compact the DELETE FILES THEMSELVES (no data file rewrite) — cheap, keeps deleted rows
-- physically present but consolidates the position delete files. Run this when delete
-- files are tiny and numerous but data files are well-sized.
CALL iceberg.system.rewrite_position_delete_files(
  table   => 'analytics.events',
  options => map('target-file-size-bytes', '67108864')  -- 64 MB delete-file target
);
```

> **CRITICAL CALLOUT — both procedures are Spark-only in your stack.** `rewrite_data_files` (with or without `delete-file-threshold`) and `rewrite_position_delete_files` are **NOT available** in Trino 467 — `rewrite_data_files`' nearest Trino equivalent is `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` but it does NOT expose `delete-file-threshold`, and `rewrite_position_delete_files` has no Trino equivalent at any version ([trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)). If you need either of these capabilities — and on a MoR table with accumulating delete files you will — you MUST run them from a Spark job. The production stack has Spark 3.5 with Iceberg 1.5.2 SQL extensions, so this is operationally fine; just schedule the Spark job as a k8s CronJob alongside the routine Trino-side `EXECUTE optimize`. Do NOT try to run these from Trino — both fail with procedure-not-found.

> **Future note on Iceberg v3 deletion vectors.** Iceberg v3 introduces "deletion vectors" (compact bitmap-based deletes) which obsolete the position-delete-file accumulation problem entirely — instead of N tiny delete files per data file, each data file gets a single compact bitmap of deleted rows. **Iceberg 1.5.2 does NOT have deletion vectors** — they're in Iceberg v3 (1.7+ for the Spark write side, still gated on table format version). On this stack (Iceberg 1.5.2 = format v2), you live with position delete files and use `rewrite_position_delete_files` + `delete-file-threshold` as the operational answer. When the cluster upgrades to Iceberg 1.7+ and you migrate tables to format v3, this whole class of operational pain goes away.

**Monitoring SQL — drop this into an Airflow / k8s CronJob to alert when the ratio crosses 10%:**

```sql
-- Trino 467 OR Spark — compute the position-delete ratio in one query.
-- Use this as a scheduled monitor; alert if pct_position_delete > 10 OR avg_delete_record_count < 5000.
WITH file_stats AS (
  SELECT
    content,                                                       -- 0 = data, 1 = position delete
    COUNT(*)                                AS file_count,
    SUM(file_size_in_bytes) / 1024 / 1024   AS total_mb,
    AVG(record_count)                       AS avg_record_count
  FROM iceberg.analytics."events$files"
  WHERE content IN (0, 1)
  GROUP BY content
)
SELECT
  MAX(CASE WHEN content = 0 THEN file_count END)        AS data_file_count,
  MAX(CASE WHEN content = 1 THEN file_count END)        AS pos_delete_file_count,
  MAX(CASE WHEN content = 1 THEN avg_record_count END)  AS avg_delete_record_count,
  -- The key trigger metric — alert when > 10:
  100.0 * MAX(CASE WHEN content = 1 THEN file_count END)
        / NULLIF(MAX(CASE WHEN content = 0 THEN file_count END), 0)
                                                        AS pct_position_delete,
  MAX(CASE WHEN content = 0 THEN total_mb END)          AS data_total_mb,
  MAX(CASE WHEN content = 1 THEN total_mb END)          AS pos_delete_total_mb,
  100.0 * MAX(CASE WHEN content = 1 THEN total_mb END)
        / NULLIF(MAX(CASE WHEN content = 0 THEN total_mb END), 0)
                                                        AS pct_storage_delete
FROM file_stats;
```

**Cadence guidance based on write rate** (the underlying driver of position-delete accumulation):

| MoR write rate (DELETEs + UPDATEs + MERGEs per day) | Recommended `rewrite_position_delete_files` cadence |
|---|---|
| < 10,000 rows/day affected | Monthly is fine; threshold-based trigger above usually catches anything sooner |
| 10,000–1M rows/day | Weekly, immediately after `rewrite_data_files` in the maintenance window |
| > 1M rows/day | Daily, or trigger-based: poll the monitoring SQL every hour and run when ratio > 10% |
| Heavy CDC / high-frequency updates (e.g., Debezium streaming into a MoR-mode table) | Hourly threshold checks; consider switching the table back to CoW if MoR maintenance is overwhelming |

**Scheduling:** when applicable, run **immediately after `rewrite_data_files`** in the same Spark job, BEFORE `expire_snapshots`. The canonical sequence on an MoR table becomes:

```
weekly maintenance window (MoR table):
   1. rewrite_data_files        (Spark CALL or Trino EXECUTE optimize)
   2. rewrite_position_delete_files  (SPARK ONLY)
   3. expire_snapshots          (Spark CALL or Trino EXECUTE)
   4. remove_orphan_files       (Spark CALL or Trino EXECUTE)
   5. rewrite_manifests         (SPARK ONLY on Trino 467; Trino 470+ has EXECUTE optimize_manifests)
```

For CoW tables (the Iceberg 1.5.2 default), skip step 2 — there are no position delete files to compact.

### 1c. Equality delete files from CDC pipelines (Debezium) — no standalone procedure exists in Iceberg 1.5.2

> **When does this apply?** Only if you have a Debezium CDC pipeline (or another writer that emits equality deletes) feeding an Iceberg table. The Debezium Server Iceberg consumer is the most common source on the production stack. If you don't ingest CDC into Iceberg, you can skip this section.

**What equality deletes are, and why they exist:** an **equality delete file** marks rows for deletion by **column-value tuple** (e.g., `{user_id = 1234, tenant_id = 'acme'}`) rather than by **file path + row position** (which is what position deletes do). Debezium writes equality deletes because, at the time it ingests a Postgres DELETE event, it only knows the source primary key — not where that row physically lives in your Iceberg data files. The Iceberg Debezium consumer writes these equality delete files directly via the Iceberg writer API (NOT via SQL MERGE INTO; this is a common misconception).

In the `$files` metadata table, equality delete files show up with `content = 2` (vs. `0` for data, `1` for position delete).

> **CRITICAL: NO standalone `rewrite_equality_delete_files` procedure exists today.** Apache Iceberg has `rewrite_data_files` (compacts data) and `rewrite_position_delete_files` (compacts position deletes) but does **NOT** have a corresponding `rewrite_equality_delete_files` procedure as of Iceberg 1.5.2 (or any released version through early 2026). The procedure is **planned** in [apache/iceberg#12914](https://github.com/apache/iceberg/issues/12914) (the `ConvertEqualityDeleteFiles` action) but **has not shipped**. Do not write tooling that expects it to exist.

**The closest substitute is `rewrite_data_files`** — but there are big caveats on Iceberg 1.5.2:

1. **It only applies equality deletes for partitions it actually rewrites.** If `rewrite_data_files` decides a partition doesn't need compaction (e.g., file sizes are already healthy), the equality delete files for that partition stay around — and every subsequent read still has to consult them.

2. **Iceberg 1.5.2 has a known dangling-equality-delete bug** ([apache/iceberg#12838](https://github.com/apache/iceberg/issues/12838), still open as of mid-2026). `rewrite_data_files` can leave equality delete files **orphaned across partition boundaries** when `dataSequenceNumber` comparisons span partitions. The result: even after `rewrite_data_files` reports success, your `$files` `content=2` count keeps growing.

3. **The fix landed in Iceberg 1.8+ (released 2025-02-13), NOT 1.5.2.** A new `remove-dangling-deletes` option was added to `rewrite_data_files`: `CALL system.rewrite_data_files(table => 'analytics.cdc_users', options => map('remove-dangling-deletes', 'true'))`. **The production stack is on Iceberg 1.5.2 and does NOT have this option.** Trying `options => map('remove-dangling-deletes', 'true')` on 1.5.2 either silently no-ops or errors depending on the codepath — do not rely on it.

> ### THERE IS NO SILVER-BULLET WORKAROUND ON ICEBERG 1.5.2
>
> **Be unambiguous about this with your team.** On Iceberg 1.5.2, the dangling-equality-delete bug ([apache/iceberg#12838](https://github.com/apache/iceberg/issues/12838)) has **no effective workaround**. If you are running a Debezium CDC pipeline into a MoR Iceberg 1.5.2 table, equality delete files (`$files content=2`) **will accumulate** over time, your read amplification will grow, and the only complete fix is to **upgrade to Iceberg 1.8+** and use the `remove-dangling-deletes` option in `rewrite_data_files`.
>
> **Why `remove_orphan_files` does NOT help here (common false workaround — do not use):**
> - `remove_orphan_files` only deletes files that are **NOT referenced by any live snapshot's manifest** (Class 2 orphans — files written but never committed).
> - Dangling equality deletes from the 1.5.2 bug **ARE still referenced** by the live snapshot's delete-file manifest. That is precisely *why* they survive `rewrite_data_files` — Iceberg still thinks they are live.
> - If you add `remove_orphan_files` to your maintenance pass expecting it to clean up dangling equality deletes, you will watch `$files content=2` keep growing with no change, and you'll have wasted a maintenance window scanning your entire MinIO bucket for nothing.
> - This was a previously-recommended workaround in older guides (including an earlier version of this document). It is **factually incorrect** — verified against the upstream Iceberg `RemoveOrphanFilesAction` source and the issue tracker discussion on #12838.

**Partial mitigation only (does NOT fix the bug, but reduces accumulation rate):**

Force `rewrite_data_files` to visit **every partition** at least weekly, by lowering `min-input-files` to `1` and running a full-table rewrite. Equality deletes are only applied (and dropped) for partitions that `rewrite_data_files` actually touches; by forcing it to touch every partition, you ensure equality deletes are at least eagerly consumed for non-dangling cases:

```sql
-- Spark on Iceberg 1.5.2 — partial mitigation: force full-table rewrite weekly.
-- This does NOT fix dangling deletes that cross partition boundaries (issue #12838),
-- but it does ensure all "normal" equality deletes get applied each week.
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.cdc_users',
  options => map(
    'min-input-files',        '1',          -- visit every partition, even healthy ones
    'rewrite-all',            'true',       -- force full-table rewrite
    'target-file-size-bytes', '134217728'   -- 128 MB
  )
);
```

**Costs of this mitigation:** rewriting every partition every week is expensive — both in compute (Spark scans and rewrites all data) and in MinIO storage (each rewrite produces a new snapshot that must be expired). Budget accordingly. On large tables (> 100 GB) the cost may exceed the value; in that case, accept the equality delete accumulation as a known issue, monitor it, and prioritize the Iceberg 1.8+ upgrade.

**The right answer is the upgrade.** If you have a Debezium CDC pipeline on Iceberg 1.5.2, your engineering team should treat upgrading to Iceberg 1.8+ as a priority. The `remove-dangling-deletes` option in `rewrite_data_files` is the only mechanism that atomically removes dangling equality delete files inside the rewrite commit.

#### Diagnostic: monitor equality delete file growth

Run this against any Debezium-fed Iceberg table on a weekly cadence:

```sql
-- Trino 467 OR Spark — count and size equality delete files (content = 2).
-- Treat results as a per-table health metric for CDC pipelines.
SELECT
  content,                                            -- 0 = data, 1 = position delete, 2 = equality delete
  COUNT(*)                                AS file_count,
  SUM(file_size_in_bytes) / 1024 / 1024 AS total_mb,
  AVG(file_size_in_bytes) / 1024        AS avg_kb
FROM iceberg.analytics."cdc_users$files"
WHERE content = 2
GROUP BY content;
```

**Alert thresholds for equality delete files (`content = 2`):**

| Metric | Healthy | Investigate | Critical (action required) |
|---|---|---|---|
| `file_count` for `content = 2` | < 10 | 10–50 | **> 50** |
| `total_mb` for `content = 2` | < 20 MB | 20–100 MB | **> 100 MB** |
| Ratio: `content=2` count vs `content=0` count per partition | < 1× | 1–10× | **> 10×** (read-amp severe) |

If you cross any critical threshold, the maintenance workflow described next is overdue.

#### Maintenance workflow for Debezium CDC tables on Iceberg 1.5.2

```
weekly maintenance window (Debezium-fed CDC table on Iceberg 1.5.2):
   1. rewrite_data_files          (Spark CALL — use min-input-files=1, rewrite-all=true
                                   as a partial mitigation; equality deletes will
                                   still accumulate due to the unfixed 1.5.2 bug)
   2. expire_snapshots            (Spark CALL or Trino EXECUTE)
   3. remove_orphan_files         (Spark CALL or Trino EXECUTE — for Class 2 garbage only;
                                   does NOT clean dangling equality deletes — see warning above)
   4. rewrite_manifests           (SPARK ONLY on Trino 467; Trino 470+ has optimize_manifests)
```

**Important:** `remove_orphan_files` is still in the standard maintenance pass — it's needed for failed-write orphans (Class 2 garbage from crashed Spark jobs). It is **NOT** in the pass to clean up dangling equality deletes; it cannot do that. See the warning box above.

#### Cadence guidance for CDC pipelines

The right maintenance frequency depends on the source UPDATE/DELETE rate. **None of these schedules fixes the 1.5.2 dangling-equality-delete bug** — they only control how fast equality deletes accumulate before becoming critical:

| Source Postgres UPDATE/DELETE rate | Recommended `rewrite_data_files` cadence |
|---|---|
| < 10 ops/sec (low write) | Nightly compaction; weekly full-table pass (`min-input-files=1`, `rewrite-all=true`) |
| 10–100 ops/sec (moderate) | Daily compaction; daily full-table pass |
| > 100 ops/sec (high write) | Hourly compaction; full-table pass every 6–12 hours |

The driver is read amplification: every Trino query against a Debezium-fed table must consult every equality delete file that overlaps the scanned data files. At 1000+ accumulated equality delete files, query latencies typically degrade from seconds to minutes. The diagnostic query above is the early-warning signal — alert at **50+ files or 100+ MB of `content=2`**.

> **Upgrade rationale (this is the only real fix):** if your team is planning an Iceberg version bump, the `remove-dangling-deletes` option (Iceberg 1.8+, released 2025-02-13) is a **mandatory** argument for upgrading off 1.5.2 if you run Debezium CDC. It handles equality delete cleanup atomically inside `rewrite_data_files` itself. On 1.5.2 there is no equivalent — accumulation is inevitable; only the rate is controllable.

### 2. `expire_snapshots` — run weekly

> **READ FIRST — Branches and tags ARE the Iceberg-native protection against `expire_snapshots`. By design, not by accident.**
>
> **TRUTH (default Iceberg behavior, documented in [iceberg.apache.org/docs/latest/branching/](https://iceberg.apache.org/docs/latest/branching/), [maintenance/](https://iceberg.apache.org/docs/latest/maintenance/), and [spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/)):** an active named ref (branch or tag) protects the snapshot it points at AND that snapshot's exclusively-owned data files from `expire_snapshots`, **regardless of the snapshot's age** and **regardless of any `retention_threshold` / `older_than` / `retain_last` arguments you pass**. The protection is at the snapshot-reference level: while the ref is alive, the snapshot is reachable; while the snapshot is reachable, no data file it exclusively owns is removed. Iceberg's own words: *"snapshots that are still referenced by branches or tags won't be removed"* and *"the expire_snapshots procedure will never remove files which are still required by a non-expired snapshot."*
>
> **MYTH-BUSTER — three confident-wrong claims that engineers (and the Haiku responder in iter414 Q3) commonly produce when asked about branches vs. expire_snapshots:**
>
> | MYTH (wrong) | TRUTH (right) |
> |---|---|
> | "`expire_snapshots` can orphan files an active branch still points at." | **No, not in normal operation.** A branch is a top-level ref; while it points at snapshot S, S and S's exclusively-owned data files are protected from `expire_snapshots`. The only ways files behind a branch get deleted are: (a) the branch's OWN snapshot-retention (`max-snapshot-age-ms` / `min-snapshots-to-keep` on the BRANCH) ages snapshots OUT OF the branch's ancestor history (the branch tip is always retained); (b) the branch ref itself is dropped (`ALTER TABLE ... DROP BRANCH` / `max-ref-age-ms` on the branch fires and removes the ref); (c) the [Iceberg #13568 multi-ref bug](https://github.com/apache/iceberg/issues/13568) which affects Iceberg **1.6.1+** in narrow edge cases — **does NOT affect this production stack on Iceberg 1.5.2**. |
> | "Branch retention (`max_snapshot_age_in_ms` / `min_snapshots_to_keep`) governs only snapshots inside the branch — it does NOT protect the data files of currently-referenced snapshots from being deleted on `main`'s expiry pass." | **Inverted.** The branch's snapshot-retention controls which snapshots in the branch's ancestor chain are eligible to drop OUT OF the branch's history. The current tip the branch points at is always retained. And **while ANY ref (the branch tip, an older retained branch ancestor, a tag, or `main`) points at a snapshot, that snapshot is protected from `expire_snapshots` across the whole table** — not just on one branch's expiry pass. There is no separate "main's expiry pass" that ignores branches. |
> | "To keep a snapshot safe for audit, you need to create a tag — an active branch alone is not enough." | **A live branch IS the protection.** A tag is functionally equivalent for the protection question (both are refs in `$refs`; both protect snapshots from `expire_snapshots`). Use a **tag** when you want an immutable label that never advances (billing close, quarterly cutoff, regulatory snapshot). Use a **branch** when you want a ref that can advance with new commits (WAP staging, ongoing audit). Either keeps the snapshot safe; the choice is about whether the ref should be immutable, not about protection. |
>
> **What branch / tag retention properties actually control (the part engineers often invert):**
>
> | Property | Lives on | What it controls | What it does NOT control |
> |---|---|---|---|
> | `min-snapshots-to-keep` (on a branch) | Branch | Minimum N snapshots Iceberg retains IN the branch's ancestor chain regardless of age. Default `1` (just the tip). | Whether the branch tip itself is protected (the tip is ALWAYS retained while the ref exists). Whether data files of currently-referenced snapshots are deleted on `main`'s expiry (they are NOT — see TRUTH above). |
> | `max-snapshot-age-ms` (on a branch) | Branch | Maximum age of ancestor snapshots kept IN the branch. Older snapshots in the branch's ancestor history age out. | The branch tip itself (always retained). The reachability of the tip from other refs. |
> | `max-ref-age-ms` (on a branch or tag) | The ref | When the REF ITSELF is expired (the ref is dropped). Once the ref is gone, snapshots not referenced elsewhere become expire-eligible. | Anything about data files directly — this acts on the ref, not on files. |
> | `history.expire.max-snapshot-age-ms` (table-level) | Table | The default age threshold `expire_snapshots` uses when called with no `older_than`. Acts as a per-table floor that per-call args cannot relax. | Snapshots referenced by any live ref (those are protected regardless of this value). |
>
> **Legitimate operational risks (the narrow ways files actually disappear despite branches existing):**
>
> 1. **Forgotten refs** — a branch or tag created months ago and never dropped silently keeps an old snapshot's data files on MinIO indefinitely. Monitor `$refs` and drop unused refs. (This is the OPPOSITE problem from the myth: you lose storage to forgotten refs, NOT data to expire_snapshots through a live ref.)
> 2. **Explicit ref drop** — `ALTER TABLE ... DROP BRANCH \`name\`` (Spark) removes the ref. Once gone, the snapshot it pointed at is eligible for expiry on the next pass if no other ref still points at it. This is intentional, not a bug.
> 3. **`max-ref-age-ms` firing on the ref itself** — if you created the branch with `RETAIN 7 DAYS` and 8 days have passed, `expire_snapshots` drops the BRANCH ref, and the previously-protected snapshot becomes expire-eligible. This is the documented purpose of `max-ref-age-ms` (auto-cleanup of forgotten refs). It does not violate the "active ref protects" rule — by the time the snapshot becomes eligible, the ref is no longer active.
> 4. **Iceberg #13568 multi-ref bug** — affects Iceberg **1.6.1, 1.7.x, 1.8.x** (the bug was introduced when a multi-ref optimization landed); **NOT** present on Iceberg 1.5.2 (the current production version). Flag this as a known item for future Iceberg upgrades, but it is NOT a present-day concern on this stack.
>
> **For the operational question "can a branch protect a snapshot older than my retention_threshold from expire_snapshots?":** YES. That is the canonical use case. Create the branch (or tag) from Spark, run `expire_snapshots(retention_threshold => '7d')` from Trino as usual — the 30-day-old snapshot the branch points at stays. No special arguments needed; no need to tighten retention; no need to skip the cleanup. The branch's existence is the entire mechanism.
>
> **See also:**
> - [§ Snapshot protection — tagged snapshots survive `expire_snapshots`](#snapshot-protection--tagged-snapshots-survive-expire_snapshots) (line ~1655) — the same protection rule restated in the tag-specific context.
> - [§ Write-Audit-Publish (WAP) with Iceberg branches](#write-audit-publish-wap-with-iceberg-branches) (line ~1661) — the canonical use case for protective branches.
> - [`resources/26-iceberg-concurrent-write-conflicts.md` § "Branch-and-tag protection vs. expire_snapshots"](26-iceberg-concurrent-write-conflicts.md) — adjacent treatment with the same myth-buster framing for engineers who arrive at concurrent-write context first.

> **What is a snapshot?** An Iceberg snapshot is a point-in-time record of the complete state of a table — which data files exist and what their min/max statistics are. Every INSERT, UPDATE, DELETE, or MERGE creates a new snapshot. Snapshots are how time-travel queries (`FOR VERSION AS OF`) know exactly which data files to read.

**What it does:** removes old snapshot **metadata** from the table's snapshot list AND **physically deletes** the data files that are no longer referenced by any surviving live snapshot. After a snapshot is expired: (1) no one can time-travel to it, and (2) any data file exclusively referenced by that snapshot (and no other live snapshot) is deleted from MinIO via S3 DELETE — not just marked eligible, actually removed. Files referenced by any still-living snapshot are kept.

> **CRITICAL DISTINCTION — what `expire_snapshots` handles vs. what `remove_orphan_files` handles:**
>
> - **`expire_snapshots`** handles **Class 1 garbage**: data files that *were* properly committed into snapshots, but those snapshots have now aged out. When a snapshot expires, `expire_snapshots` deletes the files it exclusively owned.
> - **`remove_orphan_files`** handles **Class 2 garbage**: data files that *were never committed into any snapshot at all* — e.g., a Spark write job uploaded a Parquet file to MinIO, then crashed before writing the Iceberg manifest commit. The file sits on MinIO unreferenced. `expire_snapshots` cannot find Class 2 files because it only looks at snapshot manifest references; `remove_orphan_files` does a full directory scan of MinIO to catch them.
>
> Both procedures are needed because they handle different kinds of garbage. `expire_snapshots` alone does NOT catch failed-write orphans. `remove_orphan_files` alone does NOT clean up the data files freed by snapshot expiry (they aren't orphans — they were in a snapshot; they just need the snapshot expired first before `expire_snapshots` can delete them).

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
-- SPARK SQL ONLY — SET TBLPROPERTIES is Spark syntax.
-- Trino 467's ALTER TABLE SET PROPERTIES does NOT accept history.expire.* properties.
-- Run this from a Spark SQL session (spark-sql CLI or spark.sql(...) in a job).
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep' = '5',
    'history.expire.max-snapshot-age-ms'   = '2592000000'  -- 30 days in ms
);

-- Verify from Trino after setting:
SELECT * FROM iceberg.analytics."events$properties"
WHERE key IN ('history.expire.min-snapshots-to-keep', 'history.expire.max-snapshot-age-ms');
```

> **ENGINE CALLOUT — `history.expire.*` properties must be set from Spark, NOT Trino 467.** Trino's `ALTER TABLE ... SET PROPERTIES` only accepts connector-level Iceberg properties (`partitioning`, `format`, `sorted_by`, `format_version`). It does NOT pass through Iceberg table-level properties like `history.expire.min-snapshots-to-keep` or `history.expire.max-snapshot-age-ms`. To set these retention guardrails, run `ALTER TABLE ... SET TBLPROPERTIES (...)` from a Spark SQL session. You can verify the properties took effect from Trino by querying `iceberg.analytics."events$properties"`.

After setting these, if someone accidentally schedules `expire_snapshots(retention_threshold => '7d')`, the table-level `max-snapshot-age-ms = 30 days` still protects the last 30 days of snapshots — the per-call argument cannot relax the table floor. Treat these properties as the durable policy and per-call arguments as one-off overrides.

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

> **Mental model — what actually protects in-flight files (this is a common debugger trap).** Iceberg's safety against deleting a file that's about to be referenced by a commit is **`file-last-modified-time` (the MinIO object's mtime) compared against the `older_than` threshold**, NOT some "this query has reserved this snapshot" lock or "this writer has claimed this file" registration. There is no per-query reservation, no per-writer lease, no advisory locking on files. The mechanism is purely: *file age on object storage vs. the retention threshold*. This is why the 3-day default is the entire safety margin — if you shrink the threshold below your longest possible write duration, the file's mtime is younger than that threshold the moment the writer starts, but if the cleanup runs *after* the writer started and `older_than` < write duration, the still-uncommitted file becomes deletable while the writer is mid-upload. Likewise, **a long-running SELECT query does NOT "protect" the files its snapshot references** — those files are protected because the snapshot itself is still in table metadata (i.e., `expire_snapshots` hasn't removed it), and snapshot-referenced files are by definition not orphans. The protection chain is: live snapshot exists → its data files are referenced → `remove_orphan_files` skips them entirely (orphan = unreferenced AND older than threshold). The query is irrelevant to the protection; what matters is the snapshot's continued existence in metadata.

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

> **ENGINE NOTE — `rewrite_manifests` is Spark-only on this stack (Trino 467 does NOT have it).** Unlike the other three maintenance procedures (`rewrite_data_files` / `optimize`, `expire_snapshots`, `remove_orphan_files`), which all have a working `ALTER TABLE ... EXECUTE ...` form in Trino 467, **`rewrite_manifests` has NO Trino 467 equivalent.** Engine availability at a glance:
>
> | Engine | Status for `rewrite_manifests` |
> |---|---|
> | **Spark SQL (any recent version, including Iceberg 1.5.2)** | **Available.** Run via `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')`. |
> | **Trino 470+** (Feb 2025 and later) | Available as `ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests` — note the different procedure name (`optimize_manifests`, not `rewrite_manifests`). |
> | **Trino 467 (the production version on this stack)** | **NOT available — must use Spark.** Both `CALL iceberg.system.rewrite_manifests(...)` and `ALTER TABLE ... EXECUTE optimize_manifests` fail on Trino 467 with `Procedure not registered` / syntax errors. |
>
> **What to actually run on this stack — the correct Spark call syntax:**
>
> ```sql
> -- Spark SQL (the ONLY working form on this stack until Trino is upgraded to 470+).
> -- Submit via spark-sql CLI, spark-submit, or spark.sql("...") in a Spark job.
> CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
> ```
>
> **Contrast with the other three routine procedures — these DO work in Trino 467:**
>
> | Procedure | Trino 467 syntax (works) | Spark syntax (also works) |
> |---|---|---|
> | Compaction | `ALTER TABLE iceberg.analytics.events EXECUTE optimize` | `CALL iceberg.system.rewrite_data_files(table => 'analytics.events')` |
> | Expire snapshots | `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d')` | `CALL iceberg.system.expire_snapshots(table => 'analytics.events', older_than => ...)` |
> | Remove orphan files | `ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d')` | `CALL iceberg.system.remove_orphan_files(table => 'analytics.events', older_than => ...)` |
> | **Rewrite manifests** | **NOT AVAILABLE on Trino 467 — use Spark** | `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` |
>
> **Operational implication:** if your weekly maintenance job runs entirely from Trino, the first three steps work natively but the manifest-rewrite step MUST be issued from a Spark session. Typical patterns: (a) run the entire weekly job from Spark (simplest — same engine for all four steps); or (b) run steps 1–3 from Trino and add a separate Spark job for step 4 (requires the scheduler to switch engines mid-window).

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

#### Diagnosing manifest bloat before running the fix

Use the `$manifests` metadata table to measure how many manifest files the table has before deciding to run `rewrite_manifests`:

```sql
-- Trino 467: count manifest files (use quoted "table$manifests" syntax)
SELECT COUNT(*) AS manifest_count
FROM iceberg.analytics."events$manifests";

-- Richer diagnostic — also shows total metadata size and write pattern:
SELECT
  COUNT(*) AS manifest_count,
  SUM(length) / 1024 / 1024 AS total_manifest_mb,
  ROUND(AVG(added_data_files_count)) AS avg_files_per_manifest,
  MAX(added_data_files_count) AS max_files_per_manifest
FROM iceberg.analytics."events$manifests";
```

**Verified column names for the `$manifests` metadata table (Trino 467):**

| Column | Type | Description |
|---|---|---|
| `content` | INTEGER | 0 = data files, 1 = delete files |
| `path` | VARCHAR | MinIO/S3 path to the manifest file |
| `length` | BIGINT | Size of manifest file in bytes (NOT `manifest_length`) |
| `partition_spec_id` | INTEGER | Which partition spec version this manifest was written under |
| `added_snapshot_id` | BIGINT | The snapshot that added this manifest |
| `added_data_files_count` | INTEGER | Data files added in this manifest |
| `added_rows_count` | BIGINT | Rows added |
| `existing_data_files_count` | INTEGER | Data files inherited from prior snapshots |
| `existing_rows_count` | BIGINT | Existing rows |
| `deleted_data_files_count` | INTEGER | Data files deleted (compaction, expiry) |
| `deleted_rows_count` | BIGINT | Deleted rows |
| `partition_summaries` | ARRAY(ROW) | Per-partition min/max summary |

> **CRITICAL — the column is `length`, NOT `manifest_length`.** Using `manifest_length` returns a "Column not found" error. This is the most common mistake when querying `$manifests`.

**Thresholds (rule of thumb):**
- < 10 manifests → healthy, no action needed
- 10–50 → monitor; fine for most tables
- 50–200 → if planning latency is 5+ seconds, worth running `rewrite_manifests`
- 200+ → almost certainly causing slow query planning; run `rewrite_manifests`

**Before/after verification:**
```sql
-- Before: save this number
SELECT COUNT(*) AS manifest_count FROM iceberg.analytics."events$manifests";

-- Run rewrite_manifests from Spark (see above)

-- After: should be 80–95% lower
SELECT COUNT(*) AS manifest_count FROM iceberg.analytics."events$manifests";
```

---

## Safe scheduling order — get this right or risk data loss

The maintenance operations have a **canonical execution order** matching the order documented at [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/). Running them out of order doesn't cause data loss (Iceberg's atomic commits guarantee that), but it wastes maintenance cycles and can leave storage temporarily inflated.

**Canonical execution order — apply ALL steps in a SINGLE weekly window:**

```
Step 1: rewrite_data_files          (compact FIRST — merges small files, applies pending deletes)
   │
   ▼
Step 1b: rewrite_position_delete_files   (MoR tables only — Spark ONLY; Trino 467 does NOT support)
   │
   ▼
Step 2: expire_snapshots            (drops old snapshots + deletes their exclusively-referenced data files)
   │
   ▼
Step 3: remove_orphan_files         (sweeps unreferenced files from failed writes)
   │
   ▼
Step 4: rewrite_manifests           (consolidates manifest metadata LAST; Spark ONLY on Trino 467)
```

**Common scheduling pattern:**
- Step 1 (`rewrite_data_files`) runs **nightly** at ~4 AM after the 2 AM ingestion window.
- Steps 1b–4 run **weekly** on Sunday 3 AM when ingestion is paused. (Step 1 is also re-run as part of the weekly job, since the canonical sequence starts with compact.)

**Important:** for CoW tables (the Iceberg 1.5.2 default), Step 1b is N/A — skip it entirely. Only MoR tables (where someone explicitly set `write.delete.mode = 'merge-on-read'`) produce the position delete files that Step 1b targets.

### Why this order matters

**Quick mnemonic (read this first — and read the safety note carefully):**

> **SAFETY NOTE — this ordering is about OPERATIONAL EFFICIENCY, not data safety.** Iceberg's atomic commit semantics mean `expire_snapshots` will NEVER delete a file that is referenced by ANY live snapshot — including the brand-new snapshot that compaction just committed, and including snapshots that are still being read by in-flight queries. Reversing any of the orderings below does **not** cause data loss or broken file references. It only costs you an extra maintenance cycle (typically a week) to fully clean up the storage that the previous step orphaned. The ordering is "do all the cleanup work in ONE window" vs. "spread it across two windows."

- **Compaction before `expire_snapshots`** — compaction creates a NEW snapshot pointing at merged big files. The OLD small files are still on disk, still referenced by the *previous* snapshot (and any older snapshots within retention). Running `expire_snapshots` in the SAME window AFTER compaction lets expiry clean up those now-superseded old snapshots and reclaim the small-file storage in one go. If you expire FIRST then compact, expiry has nothing new to clean up — and the small files that compaction is about to orphan will linger until *next* week's expiry runs. Same final state, just one extra week of storage cost.
- **`expire_snapshots` before `remove_orphan_files`** — `expire_snapshots` deletes data files that *were* properly committed but whose snapshots have aged out. `remove_orphan_files` handles the different class of garbage (files that were never committed to any snapshot, e.g., crashed writes). Running expiry first means orphan-cleanup sees the most-up-to-date set of "what is no longer protected by any live snapshot." Running orphan-files first cleans only the files orphaned by *previous* expiries; the files freed by *this week's* expiry would wait for next week's orphan run. (There's also a defense-in-depth race-window benefit with in-flight writes — see expanded reasoning below.)
- **`rewrite_manifests` last** — manifests are the **metadata index** above the data layer: each manifest lists data files and their per-column min/max statistics. Compaction, expire_snapshots, and orphan-cleanup all churn the data layer (writing new files, retiring old files), and **every one of those operations produces new manifest files** describing what changed. Running `rewrite_manifests` LAST means you consolidate the manifest set that already reflects the post-cleanup data layer — one final pass that collapses many small post-maintenance manifests into a few large ones, sorted by partition for fast pruning. If you ran `rewrite_manifests` FIRST instead, the consolidated manifest set would immediately be invalidated by the data-layer churn that compaction/expire/orphan introduces — you'd have to re-consolidate next week to clean up the new small manifests the data-layer operations produced. Same end state, just wasted work on the first pass. (Like `expire_snapshots`-before-`remove_orphan_files`, this is an OPERATIONAL EFFICIENCY ordering, not a safety ordering — reversing it does not corrupt the table, only wastes one maintenance cycle.)

**Expanded — Why compaction should run BEFORE `expire_snapshots` (efficiency, not safety):** compaction creates new data files and a new current snapshot that references them. The old small files are now referenced only by *prior* snapshots, not by the current one. Running `expire_snapshots` in the same maintenance window AFTER compaction lets the expiry pass immediately drop those prior snapshots and reclaim the small-file storage — you get maximum cleanup in ONE window.

If you reverse the order — `expire_snapshots` first, then compaction — there's **no data-loss risk**. Iceberg's atomic commit semantics guarantee:
- `expire_snapshots` never deletes a file referenced by any live snapshot (including the brand-new snapshot compaction just committed).
- Compaction's own commit is atomic — the new snapshot referencing the merged files appears in one indivisible step.
- An in-flight compaction's not-yet-committed files are never in any snapshot, so `expire_snapshots` (which only looks at snapshot references) doesn't even see them. The only procedure that could ever touch them is `remove_orphan_files`, and even that requires `older_than` to expire (3 days by default) — which is why the `older_than` floor, not procedure ordering, is the real safety mechanism.

The cost of reversing the order is purely operational: you'd expire old snapshots this week, then compaction creates a new snapshot whose superseded files are now unreferenced by the current snapshot but still referenced by the *post-expiry* snapshot history. Those files won't be cleaned up until *next* week's expiry pass. Same end state, but two maintenance cycles instead of one — a week of extra MinIO storage for the lingering small files.

**Expanded — Why `expire_snapshots` MUST run BEFORE `remove_orphan_files`:** there are **two reasons**, and engineers usually only learn one of them.

**Reason 1 — `expire_snapshots` exposes more files to the orphan scan.** A "live" snapshot acts as a protective reference: any data file that any live snapshot points at is, by definition, NOT an orphan, even if no current snapshot needs it anymore. After last night's compaction, the old small files are still referenced by the *previous* snapshot (the one that existed before compaction created a new current snapshot) — they look "in-use" to `remove_orphan_files` and get skipped. Once `expire_snapshots` drops that previous snapshot, the protection goes away and the small files become eligible for orphan-cleanup on the same run (well — `expire_snapshots` itself actually deletes most of them as part of its own cleanup; `remove_orphan_files` then sweeps any stragglers). **If you reverse the order, this week's orphan cleanup misses the files that this week's expiry was about to free**, and they linger for an extra week of storage cost. The cleanup eventually catches up, but you pay one extra cycle of storage growth every time.

**Reason 2 — shrink the race window with in-flight writes.** This is the safety reason, distinct from the "exposes more orphans" reason above. The danger here is **not** "otherwise you'll delete a file a snapshot still references." That can't happen — files referenced by any live snapshot (including ones you're about to expire) are by definition not orphans, and `remove_orphan_files` skips them. The danger is that an in-flight write may have already uploaded its Parquet file to MinIO but not yet committed the snapshot pointing at it — to `remove_orphan_files` at that instant, the uploaded file looks orphaned (no snapshot references it yet).

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
-- IMPORTANT: run in this CANONICAL ORDER (matches iceberg.apache.org/docs/latest/spark-procedures/):
--   Step 1: rewrite_data_files (compact FIRST — applies pending deletes, merges small files)
--   Step 1b (MoR ONLY): rewrite_position_delete_files (Spark only; Trino 467 does NOT support)
--   Step 2: expire_snapshots (drops superseded snapshots, deletes their data files)
--   Step 3: remove_orphan_files (sweeps unreferenced files from failed writes)
--   Step 4: rewrite_manifests (consolidates manifest metadata LAST)
-- ============================================================

-- Step 1: COMPACT FIRST — even though the nightly job already ran compact,
-- re-running it at the start of the weekly window ensures the data layer is
-- clean before expire_snapshots / remove_orphan_files run. This is the
-- canonical ordering per the Iceberg docs.
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '5'
  )
);

-- Step 1b: MoR TABLES ONLY — compact accumulating position delete files.
-- SKIP THIS STEP entirely if the table uses CoW (the Iceberg 1.5.2 default).
-- This procedure is Spark ONLY — Trino 467 does NOT support it (trinodb/trino #27371).
-- Check with: SELECT content, COUNT(*) FROM iceberg.analytics."events$files" GROUP BY content;
-- If content=1 (position deletes) row count is 50+, enable this step.
CALL iceberg.system.rewrite_position_delete_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '67108864',   -- 64 MB target
    'min-input-files',        '5'
  )
);

-- Step 2: Expire old snapshots (frees data files from old snapshot refs and
-- physically deletes the data files those snapshots exclusively referenced).
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
-- Trino 467 equivalent:
--   ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');

-- Step 3: Remove orphan files (sweeps files from failed writes — a different
-- class of garbage from Step 2).
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

-- Trino 467 equivalent (NO dry_run support in Trino — dry_run is Spark-only):
--   ALTER TABLE iceberg.analytics.events
--   EXECUTE remove_orphan_files(retention_threshold => '7d');

-- Step 4: Compact manifest files LAST (speeds up query planning by
-- consolidating the manifest set that now reflects the cleaned data layer).
-- SPARK ONLY on Trino 467 — Trino's `EXECUTE optimize_manifests` requires 470+.
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

## Iceberg Tags — immutable snapshot labels

A **tag** is a permanent, immutable label that points to a specific snapshot ID. Unlike a branch, a tag pointer can never advance — it always resolves to the same snapshot forever (until you explicitly drop the tag). Use tags for versioned dataset releases, month-end or quarter-end report cutoffs, and regulatory retention obligations.

**Tags vs Branches — the one-sentence difference:**
- **Tag**: immutable pointer — cannot receive new commits; always refers to the same snapshot.
- **Branch**: mutable pointer — can advance as new commits are added to it (e.g., via WAP or `fast_forward`).

### Creating a tag (Spark only)

Tag DDL must run from Spark. Trino 467 cannot create or drop tags — attempting any tag or branch DDL from Trino fails with a procedure-not-found or syntax error.

```sql
-- Spark SQL — create an immutable tag pointing to a specific snapshot.
-- Get the snapshot_id from a $snapshots query first.
ALTER TABLE iceberg.analytics.events
  CREATE TAG `end-of-may-2026`
  AS OF VERSION 4823511203987654321;

-- Optional: add an automatic expiry so a forgotten tag self-cleans.
-- Without RETAIN, the tag lives until explicitly dropped.
ALTER TABLE iceberg.analytics.events
  CREATE TAG `end-of-may-2026`
  AS OF VERSION 4823511203987654321
  RETAIN 3650 DAYS;

-- Drop a tag when it is no longer needed (Spark only):
ALTER TABLE iceberg.analytics.events DROP TAG `end-of-may-2026`;
```

### Querying a tagged snapshot (Trino CAN read tags)

Trino 467 cannot create or drop tags, but it CAN query a tagged snapshot using `FOR VERSION AS OF '<tag-name>'`. This is the correct Trino read form:

```sql
-- Trino 467 — query the snapshot the tag points at.
SELECT COUNT(*), SUM(api_calls)
FROM iceberg.analytics.events
FOR VERSION AS OF 'end-of-may-2026';

-- The numeric snapshot_id form also works and is preferable for audit reproducibility
-- (tag names can be dropped; snapshot IDs are stable in the metadata until expired):
SELECT COUNT(*), SUM(api_calls)
FROM iceberg.analytics.events
FOR VERSION AS OF 4823511203987654321;
```

### View all tags and branches

Both Trino and Spark can read the `$refs` metadata table — it shows every named ref (tags and branches) with their snapshot IDs and retention settings:

```sql
-- Works in both Trino 467 and Spark.
SELECT name, type, snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."events$refs";

-- Filter to tags only:
SELECT name, type, snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."events$refs"
WHERE type = 'TAG';

-- Filter to branches only:
SELECT name, type, snapshot_id, max_reference_age_in_ms
FROM iceberg.analytics."events$refs"
WHERE type = 'BRANCH';
```

**What the columns mean:**
- `name` — the tag or branch name you created (e.g., `end-of-may-2026`).
- `type` — `TAG` or `BRANCH`.
- `snapshot_id` — the snapshot this ref currently points at. For a tag this never changes; for a branch it advances with each new commit.
- `max_reference_age_in_ms` — the `RETAIN` expiry you set (null means "keep forever until explicitly dropped").

### Engine support summary for tags

| Operation | Trino 467 | Spark |
|---|---|---|
| `CREATE TAG` | **NOT supported** — fails with syntax/procedure error | `ALTER TABLE ... CREATE TAG \`name\` AS OF VERSION <snapshot_id>` |
| `DROP TAG` | **NOT supported** | `ALTER TABLE ... DROP TAG \`name\`` |
| Read using `FOR VERSION AS OF '<tag-name>'` | **Supported** | Supported via `VERSION AS OF '<tag-name>'` |
| Read `$refs` metadata table | **Supported** (read-only) | Supported |

**Important:** `CALL iceberg.system.create_tag(...)` does NOT exist in either Trino or Spark — tag creation is always DDL (`ALTER TABLE ... CREATE TAG`), never a CALL procedure. If you see this pattern in a guide, it is fabricated.

### When to use tags vs branches

| Use case | Use |
|---|---|
| Billing cutoff, regulatory filing, end-of-quarter report snapshot | **Tag** — it is immutable; auditors can query the same data months later |
| Staging data for validation before publishing to readers | **Branch** — it can receive new commits; you fast-forward to main on success |
| Marking a "v2.0 dataset release" that downstream consumers reference | **Tag** — version label that never changes |
| Ongoing development with iterative writes | **Branch** — designed to advance |

### Snapshot protection — tagged snapshots survive `expire_snapshots`

A snapshot referenced by any named tag or branch is **protected** from `expire_snapshots` regardless of its age. Iceberg will not physically delete a snapshot (or its exclusively-owned data files) while a live ref points at it. This is both the feature (your billing cutoff is safe for years) and the operational gotcha (a forgotten tag holding an old snapshot keeps that snapshot's data files on MinIO indefinitely — monitor `$refs` and drop tags when they are no longer needed).

> **CROSS-REFERENCE — for the full myth-buster treatment of "can `expire_snapshots` orphan files an active branch needs?" (answer: no, by design), see the leading callout in [§ 2. `expire_snapshots`](#2-expire_snapshots--run-weekly) at the top of this resource's `expire_snapshots` section. That callout enumerates the three common myths, the legitimate operational risks (forgotten refs, explicit ref drops, `max-ref-age-ms` firing, Iceberg #13568 bug NOT affecting 1.5.2), and explicitly states that for the canonical use case "keep a 30-day-old snapshot safe for audit while my nightly `expire_snapshots` runs at 7d retention", the answer is: create a branch or tag and run the cleanup as usual — the branch's existence IS the protection.

---

## Write-Audit-Publish (WAP) with Iceberg branches

The WAP pattern lets you write data, **audit it**, and only then make it visible to readers — instead of having every ingestion job commit directly to `main` where bad data is immediately seen by every dashboard. On this stack (Iceberg 1.5.2 + Spark + Trino 467), WAP is implemented via **Iceberg branches**. This section covers what branches are, the four-step WAP workflow, and the critical engine-support caveat: **branch DDL is Spark-only on Trino 467**.

> ### CANONICAL END-TO-END WAP WORKED EXAMPLE — copy this whole block verbatim when asked any WAP / branch question
>
> **This is the single authoritative WAP example. All scattered branch snippets elsewhere in this resource and in `resources/26-iceberg-concurrent-write-conflicts.md` are pointers back here. Read this whole block before answering ANY question about branch DDL, branch writes, `fast_forward`, or publishing a branch to main.**
>
> **Scenario:** Nightly ingestion into `iceberg.analytics.orders`. We want to write today's batch to a side branch, audit it from Trino without exposing it to dashboards, then atomically promote it to `main` if the audit passes.
>
> **Branch name convention — use underscores only (`audit_2026_06_04`).** This sidesteps the hyphen-quoting trap entirely. A hyphenated branch name like `audit-2026-06-04` requires backtick-quoting in Spark DDL (`` `audit-2026-06-04` ``) AND in the suffix used by the write form (`` `branch_audit-2026-06-04` ``) because hyphens are not legal in unquoted identifiers. Engineers routinely forget the second set of backticks and the write fails with "branch not found" or silently targets a different name. Recommend underscore-only branch names from the start (`audit_2026_06_04`, `staging`, `wap_run_42`) — no quoting needed anywhere.
>
> #### Step 1 — CREATE the branch (Spark only)
>
> ```sql
> -- Spark SQL only. Trino 467 cannot CREATE BRANCH.
> -- Branch starts at main's current tip; future writes to the branch diverge from main.
> ALTER TABLE iceberg.analytics.orders
>   CREATE BRANCH audit_2026_06_04
>   RETAIN 7 DAYS;
> ```
>
> The `RETAIN 7 DAYS` is optional but recommended — if anyone forgets to drop the branch, Iceberg auto-expires the ref after 7 days. Without backticks because `audit_2026_06_04` is underscore-only.
>
> #### Step 2 — WRITE to the branch (Spark only — two equivalent forms)
>
> **Form A — suffix on the table identifier (explicit per-statement targeting):**
>
> ```sql
> -- Spark SQL. The suffix is LITERALLY `branch_<exact-branch-name>`.
> -- For branch `audit_2026_06_04` the suffix is `branch_audit_2026_06_04` (underscores throughout).
> INSERT INTO iceberg.analytics.orders.branch_audit_2026_06_04
> SELECT * FROM iceberg.staging.orders_today;
> ```
>
> **Form B — WAP session conf (one config sets the branch for all subsequent writes in the session):**
>
> ```sql
> -- Spark SQL. After SET, every plain INSERT/UPDATE/DELETE/MERGE on the table
> -- routes to the branch instead of main. Don't forget to clear it at the end.
> SET spark.wap.branch = audit_2026_06_04;
>
> INSERT INTO iceberg.analytics.orders
> SELECT * FROM iceberg.staging.orders_today;
>
> -- After the WAP cycle finishes, clear the conf so later writes don't accidentally
> -- land on the branch:
> RESET spark.wap.branch;
> ```
>
> Both forms produce identical results: new snapshots live on `audit_2026_06_04`; `main` is untouched; Trino queries against `iceberg.analytics.orders` (default `main`) still return yesterday's data.
>
> #### Step 3 — AUDIT the branch (Trino read-only, no execution side-effects on main)
>
> ```sql
> -- Trino 467. Trino CANNOT create / write / publish / drop branches — only read.
> -- FOR VERSION AS OF '<branch-name>' resolves the branch ref to its current tip snapshot.
> SELECT COUNT(*) AS row_count,
>        MIN(order_date) AS min_date,
>        MAX(order_date) AS max_date,
>        COUNT(DISTINCT tenant_id) AS tenant_count
> FROM iceberg.analytics.orders
> FOR VERSION AS OF 'audit_2026_06_04';
>
> -- Per-tenant sanity check — no tenant doubled, none missing:
> SELECT tenant_id, COUNT(*) AS rows
> FROM iceberg.analytics.orders
> FOR VERSION AS OF 'audit_2026_06_04'
> GROUP BY tenant_id
> ORDER BY rows DESC;
> ```
>
> Dashboards continue to read from `main` and see unchanged data throughout the audit. If any audit check fails, skip Step 4 (Publish), go straight to drop-branch, and the bad data never reaches production.
>
> #### Step 4 — PUBLISH to main (Spark only — fast_forward procedure)
>
> ```sql
> -- Spark SQL only. Trino 467 cannot run fast_forward.
> -- Atomic metadata-only commit: moves main's pointer up to audit_2026_06_04's tip.
> -- After this commit, every Trino query against the table immediately sees the new data.
> CALL iceberg.system.fast_forward('analytics.orders', 'main', 'audit_2026_06_04');
> ```
>
> **`fast_forward` ARGUMENT MNEMONIC (read this twice — getting these args wrong abandons your work):**
>
> **Signature: `fast_forward(table, branch, to)`** where:
> - `table` (1st arg) = the table identifier (`'analytics.orders'`).
> - `branch` (2nd arg) = the branch being MOVED — the one whose pointer advances. To publish into `main`, this is `'main'`.
> - `to` (3rd arg) = the SOURCE whose tip is taken — the branch we want `main` to catch up TO. This is `'audit_2026_06_04'`.
>
> **Mnemonic: "fast-forward MAIN to the audit branch."** The subject of the sentence (MAIN) is the `branch` arg (2nd arg). The destination (audit branch) is the `to` arg (3rd arg). The verb is "fast-forward TO." Read the call out loud: "fast-forward main to audit_2026_06_04" — that maps directly to `(table, branch='main', to='audit_2026_06_04')`.
>
> Named-args form for clarity: `CALL iceberg.system.fast_forward(table => 'analytics.orders', branch => 'main', to => 'audit_2026_06_04')` — same call, same arg-order, same outcome.
>
> #### Step 5 — DROP the branch (Spark only — cleanup)
>
> ```sql
> -- Spark SQL only. Release the branch ref now that main has caught up.
> ALTER TABLE iceberg.analytics.orders DROP BRANCH audit_2026_06_04;
> ```
>
> If you set `RETAIN 7 DAYS` in Step 1, this drop is belt-and-suspenders — Iceberg would auto-expire it after 7 days anyway.
>
> ---
>
> #### DO-NOT-WRITE block — these are FABRICATED or LOAD-BEARING-WRONG; an engineer who copy-pastes any of them either errors, abandons their staged work, or silently writes to the wrong branch
>
> 1. **REVERSED `fast_forward` args** — `CALL iceberg.system.fast_forward('analytics.orders', 'audit_2026_06_04', 'main')` or `CALL iceberg.system.fast_forward(table => 'analytics.orders', branch => 'audit_2026_06_04', to => 'main')`. **LOAD-BEARING WRONG.** This swaps the meanings: it asks Iceberg to move the AUDIT branch UP TO main's tip — which abandons the audit's staged work (resets the audit pointer to a snapshot that has none of the new data) and almost always errors with "not a fast-forward" because main is not a descendant of the audit branch in WAP. The correct order is **`branch='main', to='audit_2026_06_04'`** (publish = MOVE MAIN). Mnemonic: "fast-forward MAIN to the audit branch."
>
> 2. **Mismatched suffix that silently converts hyphens to underscores** — branch declared as `staging-branch` (hyphen) but suffix written `branch_staging_branch` (underscore). **WRONG.** The suffix is LITERALLY `branch_<exact-branch-name>`. A hyphenated branch name keeps the hyphen in the suffix and requires backtick-quoting (`` `branch_staging-branch` ``). The silent hyphen→underscore conversion targets a different branch — typically nonexistent, so the write errors. **Recommended fix: use underscore-only branch names from Step 1 to avoid the whole quoting problem.**
>
> 3. **`INSERT INTO t (BRANCH 'x') VALUES (...)`** — **FABRICATED.** No parenthesized `(BRANCH '...')` clause exists in Iceberg-Spark INSERT/UPDATE/DELETE/MERGE syntax. The two real branch-write forms are (i) suffix on identifier (Form A above), (ii) WAP session conf (Form B above). Nothing else.
>
> 4. **`MERGE BRANCH x INTO main`** or **`ALTER TABLE ... MERGE BRANCH ... INTO main`** — **FABRICATED.** No `MERGE BRANCH` DDL exists in Iceberg-Spark. Publish a branch via the `fast_forward` procedure call (Step 4 above), not via any DDL statement.
>
> 5. **Any Trino-side `CALL iceberg.system.create_branch(...)`, `CALL iceberg.system.fast_forward(...)`, `CALL iceberg.system.drop_branch(...)`, or `INSERT INTO <table>.branch_<name>` from Trino** — **FABRICATED for Trino 467.** Trino's only branch role is read-only via `FOR VERSION AS OF '<branch-name>'`. Every state-changing branch operation requires Spark.
>
> 6. **`writeTo(table).option("branch", ...)` cross combination** — the V2 `writeTo` API + the V1 `.option("branch", ...)` are mutually exclusive surfaces. Use either `df.writeTo("<table>.branch_<name>").append()` (suffix on the writeTo identifier) OR `df.write.format("iceberg").option("branch", "<name>").mode("append").save("<table>")` (V1 + option), not the cross.
>
> ---
>
> **Verified against:**
> - [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/) — `fast_forward(table, branch, to)` signature; named-args form `(table => ..., branch => ..., to => ...)`; constraint that `branch` (2nd arg) must be an ancestor of `to` (3rd arg).
> - [iceberg.apache.org/docs/latest/spark-writes/](https://iceberg.apache.org/docs/latest/spark-writes/) — branch suffix syntax `INSERT INTO prod.db.table.branch_<name>`; the suffix is literal `branch_<name>` with the exact branch name preserved; WAP session conf form `SET spark.wap.branch = <name>` followed by plain `INSERT INTO`.
> - [iceberg.apache.org/docs/latest/spark-ddl/](https://iceberg.apache.org/docs/latest/spark-ddl/) — `ALTER TABLE ... CREATE BRANCH [RETAIN N DAYS]` / `DROP BRANCH` Spark DDL.
> - [trinodb/trino #16569](https://github.com/trinodb/trino/issues/16569) — Trino branch READ support `FOR VERSION AS OF '<branch-name>'` landed.
> - [trinodb/trino #16570](https://github.com/trinodb/trino/issues/16570) — Trino branch WRITE support closed as NOT PLANNED.
>
> **This worked example supersedes any other branch snippet in this file.** If you see a hyphenated branch name elsewhere in the doc, treat THIS underscore-named example as authoritative for syntax. The hyphenated examples below ARE syntactically correct (the backticks ARE present in those examples), but the underscore convention here is the recommended posture for production use because it eliminates the quoting trap entirely.


> **READ THIS FIRST — branches + `fast_forward` ARE the canonical Iceberg WAP pattern, and your stack supports them.** If a SaaS engineer asks "what's the standard Iceberg WAP pattern for validating ingestion before exposing it to Trino dashboards?", the answer is **YES, use Iceberg branches and `fast_forward` — your production stack (Spark 3.5 with Iceberg 1.5.2) supports both, and Trino 467 supports reading from branches for the audit step**. Do NOT dismiss branches because the `fast_forward` procedure and `CREATE BRANCH` DDL are Spark-only — **Spark IS in this stack**, so those tools are available to you. The correct division of responsibilities is:
>
> - **Spark** runs `ALTER TABLE ... CREATE BRANCH`, writes new data to the branch (via `spark.wap.branch` or explicit branch-targeting writes), runs `CALL iceberg.system.fast_forward(...)` to publish, and runs `ALTER TABLE ... DROP BRANCH` to clean up.
> - **Trino 467** runs the audit-step `SELECT` queries against the branch via `FOR VERSION AS OF '<branch-name>'` (Trino [does](https://trino.io/docs/current/connector/iceberg.html) support reading from named branches by name — verified against Trino 481 docs and supported on Trino 467 for reads). Dashboards on `main` keep returning the pre-branch data throughout — Trino's default reads ignore branches other than `main`.
> - **What Trino 467 cannot do** is *write* to a branch ([trinodb/trino #16570 — closed not planned](https://github.com/trinodb/trino/issues/16570)) or *create/drop* branch DDL ([trinodb/trino #12844 — open umbrella](https://github.com/trinodb/trino/issues/12844)). `INSERT INTO ... <branch-targeting syntax>` from Trino is NOT a thing — Trino's INSERT always commits to `main`. The branch-read support comes from a separate path ([trinodb/trino #16569](https://github.com/trinodb/trino/issues/16569)) which IS in place.
>
> So the Spark+Trino division is: **Spark handles every state-changing step of WAP; Trino handles the read-side audit**. This is the documented Iceberg pattern (see [Apache Iceberg branching docs](https://iceberg.apache.org/docs/latest/branching/) and the [`fast_forward` procedure docs](https://iceberg.apache.org/docs/latest/spark-procedures/#fast_forward)). The view-swap pattern described at the end of this section is a **fallback for Trino-only pipelines** — it is NOT a replacement for branches on a stack that already has Spark in the write path. On THIS stack, the right answer to a WAP question is branches + fast_forward, period.

### What an Iceberg branch is

A **branch** in Iceberg is an independent named pointer into the table's snapshot DAG (directed acyclic graph). Conceptually:
- `main` is the default branch — the snapshot every reader sees by default when they query the table.
- Any other branch (e.g., `audit-branch`) is a named pointer that lives in the same metadata as `main`, points at its own snapshot history, and is **invisible to readers of `main`** until you explicitly publish it.
- Writing to a branch creates new snapshots on that branch only. The `main` branch pointer does not move.
- A query against `main` continues to return the same data it did before any branch writes — there is no leak from branch to `main`.

This is exactly the property WAP needs: a place to stage data, run validation, and either promote (atomically merge into `main`) or discard (drop the branch) without ever exposing bad data to production readers.

> **Branches double as `expire_snapshots`-protection.** A live branch is ALSO the canonical mechanism for protecting an old snapshot from routine `expire_snapshots` cleanup — the same ref that scopes WAP writes also keeps the snapshot it points at safe from expiry, regardless of `retention_threshold`. See the leading [§ 2. `expire_snapshots` myth-buster callout](#2-expire_snapshots--run-weekly) for the full "branches/tags are protective by default" treatment with the three common myths and the legitimate operational risks (forgotten refs, explicit ref drop, `max-ref-age-ms` firing, Iceberg #13568 bug NOT affecting 1.5.2).

> **ENGINE CALLOUT — branch DDL and writes are Spark-only on Trino 467; branch reads work in Trino.** `CREATE BRANCH`, `DROP BRANCH`, the `fast_forward` procedure, INSERT/UPDATE/DELETE/MERGE *into a branch*, and the `spark.wap.branch` write-redirect mechanism are all **Spark-only** on Trino 467. Trino 467 **CAN read** from a branch (via `FOR VERSION AS OF '<branch-name>'` or `FOR VERSION AS OF <branch-snapshot-id>`) but **CANNOT WRITE** to a branch and cannot **CREATE**, **MODIFY**, **fast-forward**, or **DROP** branches. All branch management — every step of the WAP workflow except the read-side audit query — must go through Spark.
>
> **The exact Trino issues that define this boundary** (cite these when an engineer asks):
> - [trinodb/trino #12844 — Support branching of Iceberg tables](https://github.com/trinodb/trino/issues/12844) — the umbrella tracking issue for any branch operation in Trino.
> - [trinodb/trino #16569 — Support Iceberg branch READ](https://github.com/trinodb/trino/issues/16569) — DONE; this is why `FOR VERSION AS OF '<branch-name>'` works on modern Trino.
> - [trinodb/trino #16570 — Support Iceberg branch WRITE](https://github.com/trinodb/trino/issues/16570) — **closed as NOT PLANNED.** Trino has chosen to leave branch writes to Spark. There is no Trino-side workaround coming. Do NOT promise the engineer a future Trino version will add INSERT-to-branch — that work is not on Trino's roadmap.
>
> Do NOT attempt `CALL iceberg.system.create_branch(...)`, `CALL iceberg.system.fast_forward(...)`, or `INSERT INTO ...` targeting a branch from Trino — those operations do not exist in Trino 467 and the call fails with a procedure-not-found or syntax error.

> **CANONICAL BRANCH-DDL & WRITE-SYNTAX REFERENCE CARD — paste this verbatim when an engineer asks "what's the exact Spark SQL to write to / promote an Iceberg branch?". Verified against [iceberg.apache.org/docs/latest/spark-ddl/](https://iceberg.apache.org/docs/latest/spark-ddl/), [iceberg.apache.org/docs/latest/spark-writes/](https://iceberg.apache.org/docs/latest/spark-writes/), and [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/) (the `fast_forward` procedure docs).**
>
> | Operation | EXACT documented Spark form(s) | NOT-real / DO-NOT-WRITE |
> |---|---|---|
> | **CREATE branch (Spark DDL)** | `ALTER TABLE <cat>.<db>.<table> CREATE BRANCH \`<name>\` [AS OF VERSION <snapshot_id>] [RETAIN <num> { DAYS \| HOURS \| MINUTES }] [WITH SNAPSHOT RETENTION <min_snapshots> SNAPSHOTS]` | — |
> | **DROP branch (Spark DDL)** | `ALTER TABLE <cat>.<db>.<table> DROP BRANCH \`<name>\`` | — |
> | **REPLACE branch (Spark DDL)** | `ALTER TABLE <cat>.<db>.<table> REPLACE BRANCH \`<name>\` AS OF VERSION <snapshot_id>` | — |
> | **WRITE to branch — SQL form #1 (suffix on the table identifier)** | `INSERT INTO <cat>.<db>.<table>.branch_<name> VALUES (...) ` / `INSERT INTO <cat>.<db>.<table>.branch_<name> SELECT ...` / `UPDATE <cat>.<db>.<table>.branch_<name> SET col=... WHERE ...` / `DELETE FROM <cat>.<db>.<table>.branch_<name> WHERE ...` / `MERGE INTO <cat>.<db>.<table>.branch_<name> USING ...`. **The branch is targeted by suffixing `.branch_<name>` onto the qualified table identifier — the `branch_` prefix is required.** | **`INSERT INTO <table> (BRANCH '<name>') VALUES (...)`** — **FABRICATED.** There is NO parenthesized `(BRANCH '...')` clause in Iceberg-Spark INSERT/UPDATE/DELETE/MERGE. |
> | **WRITE to branch — SQL form #2 (WAP session config)** | `SET spark.wap.branch=<name>;` (or `spark.conf.set("spark.wap.branch", "<name>")` in PySpark), then a plain `INSERT INTO <cat>.<db>.<table> VALUES (...)` — Iceberg sees the conf and routes the write to the branch instead of `main`. **Don't forget `SET spark.wap.branch=null;` (or `spark.conf.unset("spark.wap.branch")`) when done** — leaving the conf set in a long-lived session sends later "innocent" writes to the branch too. | — |
> | **WRITE to branch — DataFrame form #1 (writeTo suffix)** | `df.writeTo("<cat>.<db>.<table>.branch_<name>").append()` (or `.overwritePartitions()` / `.createOrReplace()` etc.) — same `.branch_<name>` suffix on the identifier passed to `writeTo(...)`. | — |
> | **WRITE to branch — DataFrame form #2 (write + option)** | `df.write.format("iceberg").option("branch", "<name>").mode("append").save("<cat>.<db>.<table>")` — pass the branch name through the `branch` write option. | **`df.writeTo("<table>").option("branch", "<name>")`** — the cross combination of `writeTo` (V2 API) + `.option("branch", ...)` is NOT documented; pick one of the two forms above instead. |
> | **PUBLISH a branch to `main` (Spark — fast-forward)** | `CALL <cat>.system.fast_forward('<db>.<table>', 'main', '<branch>')` — call the `fast_forward` procedure with three positional args: the table identifier, the target ref to move (typically `'main'`), and the source branch. Metadata-only commit; atomic; no data files copied or rewritten. Pre-condition: the source branch must be a fast-forward-descendant of `main` (no diverging commits on `main` since the branch was created). | **`MERGE BRANCH <name> INTO main`** — **FABRICATED.** There is NO `MERGE BRANCH ... INTO main` DDL statement in Iceberg-Spark. The correct mechanism is the `fast_forward` procedure call shown in the left column. **`ALTER TABLE ... MERGE BRANCH ...`** — also FABRICATED, same reason. |
> | **TRINO 467 (READ-ONLY)** | `SELECT ... FROM <cat>.<db>.<table> FOR VERSION AS OF '<branch_name>'` (Trino resolves the branch ref to its current tip snapshot) OR `FOR VERSION AS OF <snapshot_id>` (stable across branch advances). Trino 467 **CANNOT** create, drop, write to, or publish branches — every state-changing branch operation requires Spark. | `CALL iceberg.system.create_branch(...)` / `CALL iceberg.system.fast_forward(...)` / `INSERT INTO <table>.branch_<name> ...` **from Trino** — all FAIL on Trino 467 with procedure-not-found or syntax errors. |
>
> > **DO-NOT-WRITE summary (these are FABRICATED — they will fail to parse and an engineer who copy-pastes them gets a SQL error):**
> > 1. **`INSERT INTO <table> (BRANCH '<name>') VALUES (...)`** — **FABRICATED.** No parenthesized `(BRANCH '...')` clause exists in Iceberg-Spark INSERT/UPDATE/DELETE/MERGE syntax. The two real forms are (a) suffix on identifier: `INSERT INTO <table>.branch_<name> VALUES (...)`, OR (b) WAP session conf: `SET spark.wap.branch=<name>;` then plain `INSERT INTO <table> VALUES (...)`.
> > 2. **`MERGE BRANCH <name> INTO main`** — **FABRICATED.** No `MERGE BRANCH ... INTO ...` DDL exists in Iceberg-Spark. The real promotion mechanism is `CALL <cat>.system.fast_forward('<db>.<table>', 'main', '<branch>')` — a procedure call, not a DDL statement.
> > 3. **`ALTER TABLE ... MERGE BRANCH ... INTO main`** — **FABRICATED.** Same reason; use `fast_forward`.
> > 4. **`df.writeTo("<table>").option("branch", "<name>")`** — the V2 `writeTo` + `.option("branch", ...)` cross combination is NOT documented. Use either `df.writeTo("<table>.branch_<name>")` (suffix) OR `df.write.format("iceberg").option("branch", "<name>").save("<table>")` (V1 + option) — but not the cross of the two.
> > 5. **Trino-side `INSERT INTO <table>.branch_<name>`, `CALL iceberg.system.fast_forward(...)`, `ALTER TABLE ... CREATE BRANCH ...`** — all FABRICATED for Trino 467. Trino's only branch role is read-only (`FOR VERSION AS OF 'branch_name'`). Every state-changing branch operation is Spark-only.
> >
> > **Q-pattern matcher — when the user asks any of these, the canonical answer is the table above (NOT invented (BRANCH '...') clauses, NOT MERGE BRANCH DDL):**
> > - "Exact Spark SQL to INSERT into branch X of table T?" → `INSERT INTO T.branch_X VALUES (...)` (suffix) OR `SET spark.wap.branch=X; INSERT INTO T VALUES (...)` (WAP conf).
> > - "How do I promote branch X to main?" → `CALL <cat>.system.fast_forward('<db>.<table>', 'main', 'X')` — a procedure call.
> > - "Can Trino write to / promote a branch?" → NO. Trino 467 can only READ branches via `FOR VERSION AS OF '<name>'`.
> > - "Is there a MERGE BRANCH DDL?" → NO. Use the `fast_forward` procedure.

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

### FAQ — common WAP / branches questions

**Q: Can I `INSERT INTO some_table FOR VERSION AS OF 'audit-branch'` from Trino?**
**A: No.** Trino 467 cannot write to a branch. The feature was requested as [trinodb/trino #16570](https://github.com/trinodb/trino/issues/16570) and **closed as not planned** (Trino chose to leave Iceberg branch-write to Spark — the Trino philosophy is that DDL-style table-lifecycle operations live in the engine that owns the write path). `INSERT INTO` from Trino always commits to `main`. If you need to land new data on a branch, you MUST run the write from Spark using `spark.wap.branch=<name>` (session conf) or by targeting the branch directly. There is no Trino-side workaround — proxying the branch behind a view does not help because the view-target is still `main`. Trino's only WAP role is the read-side audit step.

**Q: Can I read a branch from Trino?**
**A: Yes.** Trino 467 supports `SELECT * FROM tbl FOR VERSION AS OF '<branch-name>'` and `SELECT * FROM tbl FOR VERSION AS OF <snapshot-id>`. The branch-name form resolves through Iceberg's `$refs` table to the current branch tip at query plan time. This is what enables Trino dashboards to safely audit a branch without ever exposing it to default `main` readers. The read support was tracked as [trinodb/trino #16569](https://github.com/trinodb/trino/issues/16569). Prefer the numeric snapshot ID over the branch name when audit-step reproducibility matters — the branch can advance mid-audit if Spark commits to it again.

**Q: I don't have Spark in my pipeline — can I still do WAP?**
**A: Not the canonical branches+fast_forward way.** See the "staging-table + view-swap fallback" below. That pattern is a legitimate alternative when Spark is not in the write path. **But on this production stack, Spark IS in the write path** (Iceberg 1.5.2 ingestion runs via Spark) — so the right answer is branches + fast_forward, not view-swap.

**Q: Does fast_forward rewrite data?**
**A: No.** `fast_forward` is a metadata-only operation. It advances the `main` ref pointer to the branch's snapshot in a single Iceberg commit — no data files are copied, rewritten, or read. Cost is microseconds (one metadata.json write). This is why publish is atomic: every query before the commit sees old-main, every query after sees new-main, no intermediate state.

**Q: What if `main` advances while my branch is being audited?**
**A: `fast_forward` fails with "not a fast-forward."** The branch must remain a descendant of `main` for fast_forward to work. If a concurrent writer commits to `main` between your branch-create and your fast_forward call, you have two options: (1) rebase — drop the branch, re-create it from the new `main`, re-write your data; (2) use a regular `MERGE` instead of fast-forward. On a single-ingestor stack (the typical SaaS pattern: one nightly Spark job per table), this is rare. On tables with multiple concurrent writers, watch for it.

**Q: How do I name an audit branch?**
**A: Use a job-run-id or timestamp suffix.** Long-lived branch names like `audit` are fine if a single job uses them serially (`RETAIN N DAYS` auto-cleans stuck branches). For parallel ingest jobs, suffix with the run ID: `audit-2026-05-30-01`. Branch names are queryable from `$refs` so operators can see what's outstanding.

### Staging-table + view-swap fallback (when Spark is NOT in the write path)

The staging-table + `CREATE OR REPLACE VIEW` swap pattern is an alternative WAP implementation that requires **only Trino** — useful if your pipeline writes through dbt-trino or another Trino-only path with no Spark in the loop. It is **NOT a replacement for branches when Spark is available** — branches are cheaper (no double-write), atomic at the snapshot level, and preserve historical lineage; view-swap doubles your storage during the swap window and introduces a separate view object to manage.

**The pattern, briefly:**

1. Write new data into a staging table (separate Iceberg table, e.g., `analytics.events_staging_2026_05_30`).
2. Run audit queries against the staging table from Trino.
3. If audit passes: `CREATE OR REPLACE VIEW analytics.events_v AS SELECT * FROM analytics.events_staging_2026_05_30;` (atomically swaps the view from the old staging table to the new one, or from the prior production table to the new staging table).
4. Drop the old staging table after a retention window.

**Why view-swap is a worse fit when Spark IS in the stack:**

- **Doubles your MinIO storage during the swap window.** Old table + new staging table both exist. Branches reuse `main`'s files (snapshot deltas only) — typically <5% storage overhead vs view-swap's 100%.
- **Requires consumers to query the view, not the underlying table.** Anyone pinned to `iceberg.analytics.events` directly bypasses the swap and sees stale data (this is the silent-failure trap documented in resource 13). Branches publish to `main` itself, so every reader is updated.
- **Doesn't preserve a per-snapshot audit trail of the publish event.** With branches+fast_forward, `$history` records the publish as a single labeled commit on `main`. With view-swap, the swap is a Hive Metastore view DDL operation — not visible in Iceberg's snapshot history.
- **Coordinator-level metadata commit, not engine-level ACID.** A view swap is a single Hive Metastore commit (atomic at the HMS level). A branch fast_forward is an Iceberg-level atomic commit on `main`. Both are atomic for readers, but the branch path gives you the full Iceberg snapshot machinery (rollback, time-travel, `$snapshots` audit).

**When view-swap IS the right call:**

- The pipeline is pure-Trino (dbt-trino without Spark in the chain).
- You're swapping the table *type* itself (e.g., migrating from a non-Iceberg source to Iceberg) — branches can't help here because you're swapping the underlying table identity.
- You need a *durable* parallel-table window for human inspection that lasts hours/days (branches can also do this, but a separate table is more discoverable to non-Iceberg-savvy operators).

**Bottom line:** on this production stack, default to branches + fast_forward via Spark. Reach for view-swap only when the constraint is "no Spark in the write path." Do NOT recommend view-swap as the canonical WAP pattern — that's an inaccurate framing for any stack with Spark.

---

## Emergency rollback (the safest cleanup tool)

> **CANONICAL SNAPSHOT-LOOKUP + ROLLBACK RUNBOOK — read this FIRST before pasting any SQL.** Keywords: undo bad load, rollback Iceberg table, find snapshot id before bad load, list snapshots, $snapshots metadata table. This block is the single source of truth for the snapshot-lookup → rollback → cleanup flow on Trino 467 + Iceberg 1.5.2. **The metadata-table FROM clause MUST quote the WHOLE `<table>$snapshots` token inside ONE pair of double quotes** — `iceberg.analytics."events$snapshots"`, NOT `iceberg.analytics.events` (the base data table has NO `snapshot_id` / `committed_at` / `operation` / `summary` columns; that query fails with `Column 'snapshot_id' cannot be resolved`). Verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) ("Metadata tables" section).
>
> **The four-step runbook (paste-ready, Trino 467 + Iceberg 1.5.2):**
>
> ```sql
> -- STEP 1: list recent snapshots to find the one that existed BEFORE the bad load.
> -- The FROM clause MUST be the QUOTED metadata table — iceberg.<schema>."<table>$snapshots".
> -- Do NOT write FROM iceberg.<schema>.<table>; the base table has no snapshot columns.
> SELECT snapshot_id, committed_at, operation, summary
> FROM iceberg.analytics."events$snapshots"
> ORDER BY committed_at DESC
> LIMIT 20;
> -- Pick the snapshot_id whose committed_at is JUST BEFORE the bad write.
> -- (operation column tells you what kind of write each snapshot was:
> --  'append' = INSERT, 'overwrite' = INSERT OVERWRITE / dbt full-refresh,
> --  'delete' = DELETE, 'replace' = compaction / rewrite_data_files.)
>
> -- STEP 2: verify the good state by reading the table AS OF that snapshot.
> -- This proves the row count / data shape is what you expect BEFORE rolling back.
> SELECT count(*) FROM iceberg.analytics.events
> FOR VERSION AS OF 4823511203987654321;
> -- If the count matches the pre-bad-load expectation, the snapshot_id is correct.
> -- If it does not, go back to Step 1 and pick a different (earlier) snapshot.
>
> -- STEP 3: roll back atomically. Trino 467 uses CALL with POSITIONAL args
> -- (schema VARCHAR, table VARCHAR, snapshot_id BIGINT) — not named args, not
> -- ALTER TABLE EXECUTE (which is Trino 469+ only). The rollback is metadata-only:
> -- it moves the current-snapshot pointer back; no data files are deleted yet.
> CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321);
>
> -- STEP 4: (later, NOT in the incident) clean up the now-orphaned snapshots and
> -- their exclusive data files. The 7-day floor is the Trino 467 minimum unless
> -- you override iceberg.expire-snapshots.min-retention. Keep at least 24-48h
> -- as a rollback-of-rollback window before running this.
> ALTER TABLE iceberg.analytics.events
>   EXECUTE expire_snapshots(retention_threshold => '7d');
> ```
>
> **DO-NOT-WRITE — banned patterns (each one is a real copy-paste defect; the rule is "the FROM clause MUST MATCH the explanatory comment"):**
>
> ```sql
> -- WRONG (a) — comment says "$snapshots metadata table" but FROM is the BASE TABLE.
> -- The base table has NO snapshot_id / committed_at / operation / summary columns.
> -- Trino fails with: Column 'snapshot_id' cannot be resolved
> -- Query the $snapshots metadata table:
> SELECT snapshot_id, committed_at, operation, summary
> FROM iceberg.analytics.events                           -- WRONG: base table
> ORDER BY committed_at DESC;
>
> -- WRONG (b) — split quoting; parses as catalog.schema.table.column, so Trino
> -- looks for a column named "$snapshots" on the base events table. FAILS.
> SELECT * FROM iceberg.analytics.events."$snapshots";    -- WRONG: split quoting
>
> -- WRONG (c) — Spark four-part dotted form. Trino's parser does NOT accept this.
> -- FAILS with a parse error in Trino; works only in Spark.
> SELECT * FROM iceberg.analytics.events.snapshots;       -- WRONG: Spark form
>
> -- WRONG (d) — Spark backtick form. Trino does NOT recognise backticks; use
> -- double-quotes around the whole "table$metadata" token.
> SELECT * FROM iceberg.analytics.`events$snapshots`;     -- WRONG: Spark backticks
>
> -- WRONG (e) — Trino 469+ ALTER TABLE EXECUTE form on Trino 467. The table-
> -- procedure form was added in Trino 469 (Jan 2025); on Trino 467 it fails
> -- with a procedure / syntax error. Use the CALL positional form in Step 3.
> ALTER TABLE iceberg.analytics.events
>   EXECUTE rollback_to_snapshot(snapshot_id => 4823511203987654321);  -- WRONG: 469+
>
> -- WRONG (f) — Spark named-arg form pasted into Trino's CALL. Trino's CALL
> -- requires POSITIONAL args; named args fail with "unexpected '=>'".
> CALL iceberg.system.rollback_to_snapshot(
>   table       => 'analytics.events',
>   snapshot_id => 4823511203987654321);                  -- WRONG: Spark named args
> ```
>
> **The meta-rule (commit this to memory): the FROM clause MUST MATCH the explanatory comment.** If the comment says "$snapshots metadata table", the FROM clause MUST name the QUOTED `iceberg.<schema>."<table>$snapshots"` form — NEVER the base table. The same rule applies to every Iceberg metadata-table family:
>
> | Comment / intent | CORRECT FROM clause (Trino 467) | WRONG (base table — no such columns) |
> |---|---|---|
> | "Query the $snapshots metadata table" | `FROM iceberg.analytics."events$snapshots"` | `FROM iceberg.analytics.events` |
> | "Query the $history metadata table" | `FROM iceberg.analytics."events$history"` | `FROM iceberg.analytics.events` |
> | "Query the $files metadata table" | `FROM iceberg.analytics."events$files"` | `FROM iceberg.analytics.events` |
> | "Query the $partitions metadata table" | `FROM iceberg.analytics."events$partitions"` | `FROM iceberg.analytics.events` |
> | "Query the $refs metadata table" | `FROM iceberg.analytics."events$refs"` | `FROM iceberg.analytics.events` |
> | "Query the $manifests metadata table" | `FROM iceberg.analytics."events$manifests"` | `FROM iceberg.analytics.events` |
> | "Query the $properties metadata table" | `FROM iceberg.analytics."events$properties"` | `FROM iceberg.analytics.events` |
>
> The base data table is for ROWS. The quoted `"table$metadata"` form is for METADATA. They are different objects with disjoint column schemas. The single most common load-bearing copy-paste defect on this stack is writing the metadata-table COMMENT but pasting the base-table FROM clause — the engineer then hits `Column 'snapshot_id' cannot be resolved` and the runbook breaks.

When a bad ingestion job runs — duplicates, wrong schema, partial load — **roll back the snapshot before you try anything else.** It's instant, atomic, and doesn't touch a single data file.

`CALL iceberg.system.rollback_to_snapshot` is available in **BOTH Trino 467 AND Spark**. In an active incident, prefer the **Trino form** because you almost certainly already have a Trino session open from investigating the problem — there's no reason to spin up a Spark job just to move a pointer.

```sql
-- Step 1: find the snapshot that existed BEFORE the bad write.
-- Run in Trino or Spark — both can query $snapshots metadata.
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 10;

-- Step 1b (RECOMMENDED): verify the candidate snapshot is on the CURRENT
-- ancestor chain before rolling back. `rollback_to_snapshot` requires the
-- target to be a current-ancestor (you can roll back, not jump sideways
-- to a branch-only snapshot). The `is_current_ancestor` column lives on
-- the `$history` metadata table, NOT on `$snapshots`. Join the two on
-- snapshot_id to combine ancestor-chain proof ($history) with commit
-- detail ($snapshots) in one query.
SELECT
    h.snapshot_id,
    h.made_current_at,            -- when this snapshot was the live `current` pointer
    h.is_current_ancestor,        -- TRUE = safe target for rollback_to_snapshot
    s.committed_at,
    s.operation,                  -- append / overwrite / delete / replace
    s.summary
FROM iceberg.analytics."events$history" h
JOIN iceberg.analytics."events$snapshots" s
  ON h.snapshot_id = s.snapshot_id
WHERE h.is_current_ancestor = true
ORDER BY h.made_current_at DESC
LIMIT 10;
-- If `is_current_ancestor = false` for your target snapshot, do NOT use
-- rollback_to_snapshot — it will error with "Cannot roll back to snapshot,
-- not an ancestor of the current state." Use `set_current_snapshot`
-- instead (the escape hatch — see the section below the rollback CALL).

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

> **CANONICAL FORMS CARD — copy this; do NOT mix engines.** This is the single source of truth for `rollback_to_snapshot` syntax. Verified against [Iceberg Spark Procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/#rollback_to_snapshot) and [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html). If a copy-paste into Spark errors with "argument count mismatch", you used the Trino three-arg form by mistake; if Trino errors with "unexpected `=>`", you used the Spark named-arg form by mistake.
>
> | Engine | Canonical syntax | Notes |
> |---|---|---|
> | **Spark (canonical, two-arg, qualified `'schema.table'`)** | `CALL iceberg.system.rollback_to_snapshot('analytics.events', 4823511203987654321)` (positional, table as ONE string) **OR** `CALL iceberg.system.rollback_to_snapshot(table => 'analytics.events', snapshot_id => 4823511203987654321)` (named — recommended) | The Spark procedure takes the table identifier as a **single qualified string `'schema.table'`**, NOT as two separate `'schema', 'table'` arguments. Writing `('analytics', 'events', <id>)` ERRORS in Spark with "argument count mismatch" — Spark expects two arguments (`table`, `snapshot_id`), not three. |
> | **Trino 467 (positional, three-arg)** | `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321)` (positional VARCHAR, VARCHAR, BIGINT) | Trino's `CALL` framework requires positional args; the procedure exposes schema and table as TWO separate VARCHAR args, not one qualified string. Named-arg syntax (`table =>`, `snapshot_id =>`) does NOT work in Trino's `CALL`. |
> | **Trino 469+ (table procedure, ALTER TABLE EXECUTE)** | `ALTER TABLE iceberg.analytics.events EXECUTE rollback_to_snapshot(snapshot_id => 4823511203987654321)` | Added in Trino 469 (released Jan 2025). The qualified table name lives in the `ALTER TABLE` clause; only `snapshot_id` (and optional `ref`) is passed as a named arg to the procedure. **Does NOT exist on Trino 467** — use the Trino 467 `CALL` form above. |
>
> **The single most common copy-paste mistake:** writing `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <id>)` against **Spark**. That is the **Trino** positional form; Spark errors. Spark needs `'analytics.events'` (one qualified string) or named args.

> **Sibling procedure — `rollback_to_timestamp` (when you know the time, not the snapshot_id).** Same canonical-forms rules as `rollback_to_snapshot`. Useful when the bad write occurred at a known wall-clock time and you don't want to look up the snapshot_id first.
>
> | Engine | Syntax |
> |---|---|
> | **Spark** | `CALL iceberg.system.rollback_to_timestamp('analytics.events', TIMESTAMP '2026-05-29 01:59:59.999')` (positional, two-arg) **OR** `CALL iceberg.system.rollback_to_timestamp(table => 'analytics.events', timestamp => TIMESTAMP '2026-05-29 01:59:59.999')` (named) |
> | **Trino 467** | **NOT EXPOSED** — Trino does not implement `rollback_to_timestamp` as a `CALL` procedure. Workaround: query `$snapshots` for the snapshot_id at the target timestamp, then call `rollback_to_snapshot` with that ID. |
>
> ```sql
> -- Trino workaround for "roll back to a wall-clock time":
> -- Step 1: resolve timestamp -> snapshot_id via $snapshots.
> SELECT snapshot_id
> FROM iceberg.analytics."events$snapshots"
> WHERE committed_at < TIMESTAMP '2026-05-29 02:00:00'
> ORDER BY committed_at DESC
> LIMIT 1;
>
> -- Step 2: feed that ID into the Trino 467 rollback_to_snapshot CALL form.
> CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <id_from_step_1>);
> ```
>
> Resolves [Iceberg docs `rollback_to_timestamp`](https://iceberg.apache.org/docs/latest/spark-procedures/#rollback_to_timestamp) ↔ Trino's lack of the sibling procedure cleanly.

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

## `write.isolation-level` — serializable vs snapshot (concurrent-write conflict semantics)

> **DEDICATED RESOURCE: [`resources/26-iceberg-concurrent-write-conflicts.md`](26-iceberg-concurrent-write-conflicts.md)** is the discovery-friendly entry point for concurrent MERGE/UPDATE/DELETE conflicts on disjoint partitions — the most common operational pain point. The section below stays in resource 17 because writer-conflict tuning is part of the maintenance story; resource 26 covers the same content with more diagnostic depth and is cross-linked from `resources/13-postgres-to-iceberg-ingestion.md` so an engineer searching from the ingestion side lands on it.

> **One-sentence summary:** `write.isolation-level` is an Iceberg table property that controls how strict the conflict-detection is when `UPDATE` / `DELETE` / `MERGE INTO` operations run concurrently with other writes — `serializable` (the safer default) aborts a write if a concurrent commit MIGHT have added rows matching your WHERE clause; `snapshot` only aborts if the rows actually changed. **Verified against [Iceberg IsolationLevel javadoc](https://iceberg.apache.org/javadoc/1.7.1/org/apache/iceberg/IsolationLevel.html) and [Iceberg Reliability docs](https://iceberg.apache.org/docs/latest/reliability/).**

### The two isolation levels in plain English

Iceberg uses **optimistic concurrency** for writes: each writer assumes nothing else is running, writes new metadata, then atomically swaps the metadata pointer. If two writers race, the first wins and the second has to either retry or fail. The question `write.isolation-level` answers is: **for `UPDATE` / `DELETE` / `MERGE INTO`, how aggressively should the second writer be told "your write conflicts with the new commit and you must retry / fail"?**

| Level | What it does | When the second writer FAILS |
|---|---|---|
| **`serializable`** (Iceberg default) | Treats concurrent writes as if they ran one after another (no overlap allowed). | If ANOTHER concurrent commit added a new data file that **might contain rows matching your UPDATE/DELETE/MERGE WHERE clause** — even if you can't prove the rows actually matched. The check is at the manifest level, not the row level. |
| **`snapshot`** | Treats concurrent writes as independent if they don't touch the same rows. | Only if your UPDATE/DELETE/MERGE actually touches a row that was also modified by a concurrent commit. New rows added by other writers are fine. |

### The concrete scenario that catches engineers

Two jobs run at the same time against `iceberg.analytics.orders`:

- **Job A** (a nightly Spark backfill): `INSERT INTO orders` appending 5M new rows for `order_date = '2026-05-29'`.
- **Job B** (an analyst's correction): `UPDATE orders SET amount = amount * 1.10 WHERE tenant_id = 'acme' AND order_date < '2026-05-29'`.

**Both jobs target the same table but read/write disjoint partitions.** No row is touched by both jobs.

- Under **`serializable`** (the default): Job B may FAIL with `ValidationException: Found conflicting files` because Job A's commit added new files to the table, and Iceberg conservatively asks "could the new files contain rows matching `tenant_id = 'acme' AND order_date < '2026-05-29'`?" — it can't prove they don't (the new files cover `order_date = '2026-05-29'` which is NOT `< '2026-05-29'`, but the partition-spec-driven check varies by writer). Many production teams hit this surprise.
- Under **`snapshot`**: Job B succeeds. The new rows Job A inserted are in `order_date = '2026-05-29'`; Job B's UPDATE only touches `< '2026-05-29'`; there is no row-level overlap, so the commit goes through.

### How to set it

```sql
-- At table creation (Iceberg 1.5.2, both Trino 467 and Spark accept this):
CREATE TABLE iceberg.analytics.orders (
  order_id BIGINT,
  tenant_id VARCHAR,
  order_date DATE,
  amount DOUBLE
) WITH (
  partitioning = ARRAY['order_date'],
  -- Default is serializable; override to snapshot for higher concurrency tolerance:
  format_version = 2
);

-- Set on an existing table (Trino 467):
ALTER TABLE iceberg.analytics.orders
SET PROPERTIES "write.delete.isolation-level" = 'snapshot',
               "write.update.isolation-level" = 'snapshot',
               "write.merge.isolation-level" = 'snapshot';

-- Set on an existing table (Spark):
ALTER TABLE iceberg.analytics.orders
SET TBLPROPERTIES (
  'write.delete.isolation-level' = 'snapshot',
  'write.update.isolation-level' = 'snapshot',
  'write.merge.isolation-level' = 'snapshot'
);

-- Verify the effective value with $properties (Trino 467):
SELECT key, value
FROM iceberg.analytics."orders$properties"
WHERE key LIKE 'write.%.isolation-level';
```

> **There are THREE properties, one per operation type — set all three if you want consistent behavior.** Iceberg exposes the level separately for DELETE, UPDATE, and MERGE INTO. A common mistake is setting only `write.merge.isolation-level` and being surprised when a concurrent DELETE still fails. Set all three to the same value.

### When to choose each

| You should pick `serializable` (the default) if... | You should pick `snapshot` if... |
|---|---|
| Your team has a small number of writers (one ingest job, occasional ad-hoc fixes); commit conflicts are rare; correctness matters more than throughput. | You have many concurrent writers (multiple dbt models, multiple ingestion streams, multiple analysts running corrections) and you keep hitting `ValidationException` retries that slow the pipeline. |
| The table is the source of truth for billing / compliance and you cannot tolerate a phantom-read where a concurrent insert went unseen by a concurrent UPDATE/MERGE. | The table is an append-mostly fact table where updates and inserts target disjoint partitions (most multi-tenant SaaS analytics tables fit this shape). |
| You are running a one-off MERGE that synchronizes a table from an external source and the source has the full ground truth (any phantom-read would corrupt the merge). | Your UPDATE/DELETE/MERGE operations are partition-scoped and idempotent — the worst case of a missed concurrent insert is "we'll catch it next run." |

### What `serializable` actually checks under the hood

The check is **at the manifest level**, not the row level. When Job B (the UPDATE/DELETE/MERGE) tries to commit, Iceberg looks at the snapshot lineage between the snapshot Job B read and the current snapshot. For each newly-added data file in that lineage, Iceberg asks: "does this file's partition / column min-max stats overlap with Job B's WHERE-clause predicate?" If yes, the commit is rejected with `ValidationException: Found conflicting files`. So the false-positive rate depends on (a) how selective your partition spec is and (b) how well column min-max stats line up with your predicate.

This is why **partition-scoped UPDATE/DELETE/MERGE with literal partition values in the WHERE clause tends to survive `serializable`** — Iceberg can prove via the partition spec that newly-added files in other partitions can't match. Predicates on non-partition columns (e.g., `WHERE customer_email = 'a@b.com'` on a non-partitioned column) fall back to column min-max stats, which are conservative.

### Retry-vs-fail behavior — `commit.retry.num-retries` is your second knob

Even at `serializable`, Iceberg can **transparently retry** a write that hits a conflict, as long as the retry produces the same logical result. Two table properties control this:

| Property | Default (Iceberg 1.5.2) | What it does |
|---|---|---|
| `commit.retry.num-retries` | `4` | How many times Iceberg retries a write that fails due to a concurrent commit conflict. After the retries are exhausted, the write fails with `CommitFailedException`. |
| `commit.retry.min-wait-ms` | `100` | Initial backoff between retries (exponential — doubles each attempt). |

If you see `CommitFailedException` after a few seconds of retries, the table is genuinely contended. Either (a) lower the contention (stagger jobs, partition the work) or (b) relax the isolation level to `snapshot` if the workload tolerates it.

### Operational diagnostic — "my MERGE keeps failing during ingestion window"

The symptom: a dbt MERGE that always succeeded suddenly starts failing with `ValidationException: Found conflicting files` or `CommitFailedException` after a new ingestion stream was added.

The diagnostic sequence:

```sql
-- 1. Confirm the current isolation level (Trino 467).
SELECT key, value
FROM iceberg.analytics."orders$properties"
WHERE key LIKE 'write.%.isolation-level';
-- Expect: 'serializable' (the default), unless explicitly relaxed.

-- 2. Look at recent commit operations on the table — is something else writing in your MERGE window?
SELECT snapshot_id, committed_at, operation, summary['total-records'] AS total_rows
FROM iceberg.analytics."orders$snapshots"
ORDER BY committed_at DESC
LIMIT 20;
-- Look for interleaved 'append' (from ingestion) and 'overwrite' / 'delete' (from MERGE).

-- 3. Confirm the MERGE's partition predicate excludes the ingestion's partitions.
-- If both the ingestion INSERT and the MERGE touch the same partition, the conflict is real
-- (not a false positive from serializable's manifest-level check).
```

**Two viable fixes** depending on what you find:

- **The MERGE and the ingestion target disjoint partitions** → relax to `snapshot` isolation. The conflict is a false positive at `serializable`.
- **The MERGE and the ingestion really do touch the same rows** → serialize them in your scheduler (run them sequentially via Airflow / k8s CronJob dependencies). No isolation level can paper over genuinely-conflicting writes; you have a workflow design issue, not a config issue.

### Pitfalls and footguns

- **Changing `write.*.isolation-level` does NOT affect already-running writes.** The level is read at write-plan time. If you flip the property mid-incident, in-flight writes continue under the old level.
- **`snapshot` isolation does NOT mean "no isolation"** — readers still see snapshot-isolated reads (a query started before a commit doesn't see that commit's data). The property only changes the WRITER conflict-detection strictness, not the READER consistency model.
- **The property is namespaced per operation** (`write.delete.isolation-level`, `write.update.isolation-level`, `write.merge.isolation-level`) — there is NO global `write.isolation-level` property that sets all three at once. The shortcut form `write.isolation-level` you may see in older docs / blog posts was deprecated; use the three operation-specific properties.

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

The unmaintained Iceberg table is the most common operational failure mode on this stack. Set up the procedures, get the canonical order right (per iceberg.apache.org/docs/latest/spark-procedures/):

1. **`rewrite_data_files`** (compact FIRST — applies pending deletes, merges small files)
2. **`rewrite_position_delete_files`** (MoR tables only — Spark ONLY, Trino 467 does NOT support)
3. **`expire_snapshots`** (drops superseded snapshots and physically deletes their data files)
4. **`remove_orphan_files`** (sweeps unreferenced files from failed writes)
5. **`rewrite_manifests`** (consolidates manifest metadata LAST — Spark ONLY on Trino 467)

Common schedule: `rewrite_data_files` nightly; the rest in a single weekly maintenance window. If anything goes wrong with a write, reach for `rollback_to_snapshot` before you touch any data. Build these into your scheduler on day one — retrofitting later is harder than doing it correctly upfront.

**Trino-vs-Spark syntax quick reference (Trino 467):**

| Procedure | Trino 467 | Spark |
|---|---|---|
| `rewrite_data_files` | `ALTER TABLE ... EXECUTE optimize` | `CALL iceberg.system.rewrite_data_files(...)` |
| `rewrite_position_delete_files` | **NOT supported** ([#27371](https://github.com/trinodb/trino/issues/27371)) | `CALL iceberg.system.rewrite_position_delete_files(...)` |
| `expire_snapshots` | `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')` (no `retain_last` on 467; that's 479+) | `CALL iceberg.system.expire_snapshots(...)` |
| `remove_orphan_files` | `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` (NO `dry_run`; 7d min-retention floor) | `CALL iceberg.system.remove_orphan_files(... dry_run => true)` (Spark supports `dry_run`) |
| `rewrite_manifests` | **NOT supported** on 467; `EXECUTE optimize_manifests` is 470+ | `CALL iceberg.system.rewrite_manifests(...)` |
| `rollback_to_snapshot` | `CALL iceberg.system.rollback_to_snapshot('schema','table',id)` (positional) | `CALL iceberg.system.rollback_to_snapshot(table => ..., snapshot_id => ...)` (named) |
