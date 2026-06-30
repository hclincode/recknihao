# Query Performance Regression Diagnosis

A guide for SaaS engineers and oncall members investigating why analytics queries suddenly got slower on the Trino 467 + Iceberg + MinIO stack.

---

## Common myths about query performance regression — read FIRST (the load-bearing wrong claims)

These are the absolutes most often stated incorrectly during query-perf triage on Trino 467 + Iceberg 1.5.2 + MinIO. Each TRUTH below has been verified against the [Trino EXPLAIN docs](https://trino.io/docs/current/sql/explain.html), the [Trino pushdown docs](https://trino.io/docs/current/optimizer/pushdown.html), and the [Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html). **Lead with the TRUTH; state the nuance.**

| MYTH (commonly said wrong) | TRUTH (correct framing) | Where in this doc |
|---|---|---|
| "If `EXPLAIN ANALYZE` shows a Filter node above TableScan, my predicate didn't push down — performance is doomed." | **NOT NECESSARILY.** A Filter node above TableScan means **residual filtering** — the predicate is too complex (or wrong type) to push to the connector, so Trino applies it post-scan. The performance impact depends on selectivity: a residual filter of `lower(name) LIKE '%foo%'` on a tiny table is fine. The right diagnostic is to look at `physicalInputDataSize` and `inputRows` in the TableScan operator — IF those are large relative to the FINAL output, THEN pushdown failure matters. See [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html). | [§ Reading EXPLAIN ANALYZE](#step-3-reading-explain-analyze) leading callout |
| "I see `inputRows = 800M` in TableScan — the query is reading 800M rows of data from MinIO." | **NO — `inputRows` is the row count AFTER file-level pruning but BEFORE row-level filtering.** It does NOT mean 800M rows of bytes streamed from MinIO. Iceberg + Parquet do file-level pruning (manifest min/max), row-group pruning (Parquet footer min/max), and column pruning (only requested columns are decoded). `physicalInputDataSize` in EXPLAIN ANALYZE shows the actual bytes read — often a tiny fraction of the implied raw scan. Use `physicalInputDataSize`, not `inputRows`, to gauge actual I/O. | [§ I/O metrics in EXPLAIN ANALYZE](#io-metrics-in-explain-analyze) callout |
| "Trino's CBO will figure out the optimal join order automatically — I don't need to think about it." | **ONLY IF you've run `ANALYZE table` on your Iceberg tables.** Without table statistics (NDV, null fraction, data size per column), Trino falls back to heuristics that often produce bad plans. Trino 467 has `iceberg.use-file-size-from-metadata=true` by default which gives BYTE-level estimates "for free" from Iceberg manifests, but NDV (number-distinct-values) for joins requires explicit `ANALYZE`. For frequently-joined tables, run `ANALYZE iceberg.x.y` weekly or after large loads. See resource 24-trino-cbo-analyze.md. | [§ CBO and statistics](#cbo-and-statistics) callout |
| "My query was fast yesterday and slow today, but the data didn't change much — must be a Trino bug." | **MORE OFTEN it's one of (in order of frequency): (1) compaction fell behind → 10x more small files → manifest planning cost spike, (2) a new heavy query landed in the same resource group, (3) a Postgres source got a 10x larger result via federation, (4) `ANALYZE` stats went stale and the join order regressed, (5) the dashboard frequency increased.** The Trino-bug hypothesis is the LAST hypothesis to test, not the first. Walk the 6-step triage in this resource before filing a Trino bug. | [§ Triage priority order](#triage-priority-order) leading callout |
| "Adding more Trino workers will always speed up my slow query." | **NO — Trino scaling is bounded by the SLOWEST FRAGMENT, and adding workers doesn't help if (a) the query is coordinator-bound (e.g., heavy planning, federation with many small remote calls), (b) one worker is doing all the work because of skew (one partition has 90% of rows), (c) the bottleneck is MinIO bandwidth not CPU.** Diagnose with EXPLAIN ANALYZE first — look for fragments with CPU ≈ Scheduled (CPU-bound, more workers help) vs Scheduled >> CPU (I/O-bound, more workers DON'T help). | [§ When more workers help](#when-more-workers-help) callout |
| "The Trino UI shows 'Running' for 5 minutes — the query is actively doing work." | **NOT NECESSARILY.** "Running" in the UI is a coarse state. The query could be (a) genuinely computing, (b) blocked on a downstream consumer not pulling results (client backpressure), (c) waiting on a slow remote catalog (federation), (d) doing nothing because resource-group queue downstream of it is saturated. The detail you need is in the per-fragment `Blocked` time and per-task state, accessible by clicking through to the task detail view in the UI. | [§ Reading the Trino UI](#reading-the-trino-ui) callout |
| "Partition pruning works automatically — I don't need to write `WHERE day(occurred_at) = ...` against partition columns explicitly." | **CORRECT — but only if the predicate is on the SOURCE COLUMN of the partition transform, in a form Trino can simplify.** `WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00' AND occurred_at < TIMESTAMP '2026-05-02 00:00:00'` PRUNES on a `day(occurred_at)` partitioned table. `WHERE date_trunc('day', occurred_at) = DATE '2026-05-01'` may NOT prune (depending on whether the optimizer can simplify the function call against the transform). `WHERE CAST(occurred_at AS DATE) = DATE '2026-05-01'` may NOT prune. **The safe predicate shape is a range comparison against the raw source column.** See [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html). | [§ Predicate shapes that prune](#predicate-shapes-that-prune) callout |
| "`SELECT COUNT(*) FROM iceberg.x.y` reads the whole table to count rows." | **NO — on Iceberg, `COUNT(*)` is a METADATA query.** Iceberg manifests track `record_count` per file. Trino 467's Iceberg connector sums the per-file record counts from manifests — no Parquet files are opened. Verify by running `EXPLAIN ANALYZE SELECT COUNT(*) FROM iceberg.x.y` and noting `physicalInputDataSize = 0B` for the TableScan. **Caveat (the #1 reason a plain `COUNT(*)` is SLOW): if the table is format-version 2 with POSITION-DELETE FILES (from `MERGE` / row-level `UPDATE`/`DELETE` — i.e. an MoR table), the connector can NO LONGER use the pure metadata count — it must open data files and apply the delete files to count surviving rows accurately, and slowness grows with delete-file count (can go from instant to minutes/hours). That is what a slow 2-3 min `COUNT(*)` means. Fix: clear the delete files — `EXECUTE optimize` then `expire_snapshots` (see §"Why is my COUNT(*) slow" below + r28 §delete-file diagnostic).** | [§ Cheap queries on Iceberg](#cheap-queries-on-iceberg) COUNT callout |
| "Too many small files always causes slow queries — that's the only file-count problem." | **THERE ARE TWO DISTINCT PROBLEMS.** (1) Too many SMALL data files (each <16MB): per-file overhead dominates I/O, and Parquet row-group benefits vanish. Fix with `OPTIMIZE` / `rewrite_data_files`. (2) Too many MANIFEST files: planning time spikes because Trino reads every manifest list entry to do file-level pruning. Fix with `rewrite_manifests` (Spark-only on Trino 467). Both can compound. Diagnose by looking at `splitsCreated` (data-file side) vs `analysisTime`/`planningTime` (manifest-side). | [§ Small files vs many manifests](#small-files-vs-many-manifests-two-different-problems) callout |
| "To cluster files by a non-partition column on Trino 467, run `ALTER TABLE ... EXECUTE rewrite_data_files(sort_order => ARRAY[...])`." | **NO — that's Spark CALL named-arg syntax pasted into a Trino EXECUTE statement, which Trino 467 rejects with `Procedure not registered`.** Trino 467's EXECUTE registry is exactly: `optimize` (only `file_size_threshold` arg), `optimize_manifests` (Trino 470+, NOT 467), `expire_snapshots`, `remove_orphan_files`, `drop_extended_stats`. `rewrite_data_files` is **NOT** in Trino's EXECUTE registry. The Trino-467-valid clustering recipe is two statements: `ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY['col']` then `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '512MB')`. The `sorted_by` table property is in Trino's modifiable-properties list since release 409 and Trino's EXECUTE optimize honors it at rewrite time. Drop to Spark CALL only for z-order, rewrite-all-true, MoR position-delete cleanup, post-partition-evolution rewrite, or `delete-file-threshold`. | [§ Fix recommendations table](#fix-recommendations--and-which-are-available-on-trino-467-the-production-version), [resources/17 EXECUTE-vs-CALL matrix](17-iceberg-table-maintenance.md#trino-execute-procedures-vs-spark-call-procedures--the-engine-confusion-disambiguation-matrix-read-before-writing-any-procedure-call) |

> **Why these specific myths matter.** Each is a load-bearing topic-specific claim about Trino/Iceberg query performance. Stated as an absolute, it causes engineers to either build expensive workarounds for non-problems (filing a Trino bug instead of running ANALYZE; adding workers when the bottleneck is skew) OR to confidently misdiagnose (claiming "pushdown failed" because of a Filter-above-TableScan when residual filtering is cheap; claiming `COUNT(*)` is expensive on Iceberg when it's metadata-only). **The correct discipline:** when about to say "this is slow because X", check (a) EXPLAIN ANALYZE for the actual mechanism, (b) `physicalInputDataSize` for real I/O, (c) `system.runtime.queries` for whether concurrency is the cause, (d) the team's own resource 18.

---

## Why is my `SELECT COUNT(*)` slow on Iceberg? (it should be metadata-only — a slow one means delete files)

> **Keyword anchors:** COUNT(*) slow on Iceberg, is COUNT(*) metadata-only, COUNT(*) takes minutes, total row count slow, count rows fast Iceberg, COUNT(*) scans whole table, fast approximate row count, COUNT(*) not instant, why is my row count query slow.

**YES — a plain unqualified `SELECT COUNT(*) FROM iceberg.schema.table` (no `WHERE`, no `GROUP BY`) IS metadata-only on Trino 467 and should return in well under a second even on a 400M- or 10B-row table.** Iceberg manifests store a `record_count` per data file; Trino sums those counts from the manifests and opens ZERO Parquet data files. Confirm with `EXPLAIN ANALYZE SELECT COUNT(*) FROM iceberg.x.y` → the TableScan shows `physicalInputDataSize = 0B`. (A `WHERE` on a non-partition column, or `GROUP BY` a non-partition column, breaks metadata-only and does scan — that's expected; this canonical is about the PLAIN total count.)

**So if your plain `COUNT(*)` takes 2-3 minutes, it is NOT "Iceberg always scans" — something broke the metadata path. In order of likelihood:**

1. **POSITION-DELETE FILES (the usual cause).** If the table is format-version 2 and has had `MERGE` / row-level `UPDATE` / `DELETE` (an MoR table), it accumulates position-delete files. Trino can no longer trust the raw per-file `record_count` (some of those rows are deleted), so it must OPEN the data files and apply the deletes to count surviving rows. Slowness scales with delete-file count — instant → minutes → (extreme) hours. **Diagnose:** `SELECT content, count(*) AS files, sum(record_count) AS rows FROM iceberg.analytics."events$files" GROUP BY content` — `content=0` is data files, `content=1` position deletes, `content=2` equality deletes. Many `content=1` rows = this is your cause (see r28 §delete-file diagnostic). **Fix:** `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '512MB')` (rewrites data files AND clears the position-delete files referencing them), then `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`.
2. **Manifest bloat / tiny-files explosion** — thousands of manifest entries to sum can add planning time (less common for a pure count; see the small-files-vs-manifests callout above).

**❌ DO NOT reach for `approx_distinct` to "speed up" a row count.** `approx_distinct(col)` is HyperLogLog **distinct-VALUE cardinality**, NOT a row count — `approx_distinct(*)` is not valid, and `approx_distinct(ROW(...))` counts distinct row-tuples (silently UNDERcounts duplicate rows). You do not need an approximate row count: exact `COUNT(*)` is already metadata-fast once the delete files are cleared. (`approx_distinct` is the right tool only for "how many DISTINCT users/sessions", not "how many rows".)

---

## Quick Reference: Key Terms (EXPLAIN ANALYZE vocabulary)

When you read Trino's EXPLAIN ANALYZE output, you'll hit these terms. Definitions you can use as a runtime crib sheet:

| Term | One-line meaning |
|---|---|
| **Fragment** | A unit of parallelism in Trino; a query compiles into fragments that run in parallel (e.g., `Fragment 0` = coordinator output, `Fragment 1` = source scan, `Fragment 2` = aggregation). |
| **Exchange** | Operator that moves data between fragments/workers. `RemoteExchange` crosses the network between workers; `LocalExchange` stays inside one worker (cheap). |
| **REPARTITION** | Exchange type that **hash-distributes rows by a key** (used for GROUP BY and distributed/hash joins) — every row goes to exactly one downstream worker chosen by hash(key). |
| **REPLICATE** | Exchange type that **copies all rows to every worker** (used for broadcast joins) — fast when the replicated side is small, OOM risk when it's not. |
| **CPU time** | Compute-only time (excludes waits). When CPU ≈ Scheduled, the operator is **compute-bound** (more cores would help). |
| **Scheduled time** | Wall-clock time for the operator including waits. When Scheduled >> CPU, the operator is **I/O-bound or network-bound** (waiting on data or downstream consumers). |
| **Blocked Input / Blocked Output** | Time waiting on upstream/downstream operators. Blocked Input = waiting for data from upstream; Blocked Output = downstream consumer is slow. |

---

## LEADING CANONICAL ONCALL WORKED EXAMPLE — "Dashboard query that ran in 2s last week now takes 45s" (read this FIRST when paged)

> **This is the findable canonical answer for the oncall-workflow question. If you are looking for "a slow query I need to diagnose right now", THIS is the workflow. Every step below has been verified against [trino.io/docs/current/sql/explain-analyze.html](https://trino.io/docs/current/sql/explain-analyze.html), [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html), the Trino 467 `system.runtime.*` schema, and the Iceberg connector procedure registry. Do NOT invent commands — paste verbatim from this section.**
>
> **Scenario:** A dashboard query that consistently ran in ~2 seconds last week now takes 45 seconds. No application code changed. The data volume grew "only a little." Question: what's the oncall checklist?
>
> **FIRST 60 SECONDS — the four-check rapid triage (do these IN ORDER; stop at the first one that explains the symptom):**
>
> ### Check 1 (≈10s): Is the cluster saturated? — Trino UI concurrency
>
> Open `http://trino-coordinator:8080/ui/queries`. Read three numbers off the top dashboard:
>
> - **Queued count > 0** → workers are saturated; everyone's queries are slow, not just this one. Root cause is **concurrency spike**, not the query. Skip to "Fixes for concurrency" in Step 1 below.
> - **Running count > 50** with a sustained burst (many queries started in the same 60-second window) → same conclusion: concurrency.
> - **Both queued = 0 AND running ≈ normal (5–20)** → this is NOT a cluster-wide problem. Move to Check 2.
>
> ### Check 2 (≈15s): Is it ALL queries on this table, or just this one? — Verify with a known-good query
>
> Re-run a known-fast query against the same table:
>
> ```sql
> -- Trino 467 — bare table count (Iceberg metadata-only, should be <1s).
> SELECT COUNT(*) FROM iceberg.analytics.user_events;
> ```
>
> - If `COUNT(*)` is also slow → table itself is the problem (metadata bloat, manifest list explosion). Jump to Step 7 (small files / manifest bloat).
> - If `COUNT(*)` is fast (<1s) → query-specific issue. Continue to Check 3.
>
> > **SPECIAL CASE — "unfiltered `COUNT(*)` is fast (~2s) but `COUNT(*) WHERE <partition_col> = X` is slow (~30s)" on a table partitioned by `<partition_col>`.** *(Keyword anchors: per-account COUNT slow, per-tenant COUNT slow, filtered count on the partition column slow, COUNT WHERE partition key slow but unfiltered fast, billing-dashboard per-account count slow.)*
> >
> > **DO NOT conclude "the `WHERE` on the partition column forces Trino to read the Parquet data files."** That is FALSE. A `COUNT(*)` whose predicate is **fully on an identity-partition column** is answered **METADATA-ONLY** in Trino 467 — partition pruning selects the matching files and the count is summed from their manifest `record_count`s, **no Parquet data is opened** (same fast path as the unfiltered count; see [r10 §metadata-only COUNT on a partition column](10-lakehouse-partitioning.md)). *(Caveat: this metadata-only fast path is disabled if the table has merge-on-read position-delete files — but then the UNfiltered count would also be slow, which it isn't here.)*
> >
> > So the slowness is **NOT a data scan** — it is almost always **PARTITION-COUNT EXPLOSION / manifest-planning overhead**: the table is identity-partitioned on a **high-cardinality** column (e.g. `account_id` with tens of thousands of values × day = millions of tiny partitions), so even a metadata-only count pays a huge **planning** cost walking an enormous manifest set. **Diagnose:** `SHOW CREATE TABLE <t>` (confirm it's `identity(account_id)` on a high-cardinality column) + `SELECT COUNT(*) FROM iceberg.<schema>."<t>$partitions"` (millions of partitions = the smoking gun). **Fix:** re-partition with `bucket(account_id, N)` (e.g. 32–64) to bound the partition count — see [r10 §bucket vs identity](10-lakehouse-partitioning.md). **Trade-off to state honestly:** the `bucket()` transform means a `WHERE account_id = X` count is no longer purely a partition predicate, so it gives up the metadata-only fast path for that filter (it prunes to one bucket's files but counts them) — usually a good trade because it eliminates the planning blow-up, but say so.
>
> **⭐ "Can I see how much this will SCAN *before* I run it?" — YES, use plain `EXPLAIN`, NOT `EXPLAIN ANALYZE`.** *Keyword anchors: estimate scan size before running, how much will Trino scan ahead of time, dry-run a query, preview I/O without executing, will this read the whole table, check scan size without running the slow query, pre-flight a query.* **`EXPLAIN ANALYZE` EXECUTES the query (it re-pays the full 40s) — it is NOT a pre-run estimate.** The pre-run, no-execution tools are:
> ```sql
> -- (a) Planner ESTIMATE of rows + bytes + which predicates push down — NO execution, returns instantly:
> EXPLAIN (TYPE IO, FORMAT JSON) <your query>;
> --     read `inputTableColumnInfos[].estimate` (estimated rows + size from table stats) and `columnConstraints`
> --     (which predicates pushed to the scan). This is the "how much will it scan" answer, before running.
> -- (b) The distributed plan with the TableScan constraint (also NO execution) — see Check 3 below:
> EXPLAIN (TYPE DISTRIBUTED) <your query>;
> ```
> (Estimates are only as good as your table stats — run `ANALYZE <table>` if the estimates look wildly off. For ACTUAL post-run bytes use `EXPLAIN ANALYZE` + `physicalInputDataSize`, but that runs the query.) **Note:** a filter on a NON-partition column (e.g. `status = 'failed'`) does NOT prune — Trino reads every file in the matching date-partitions and applies `status` at read, so a tiny *result* set can still mean a large *scan*. A bloom filter / sorted_by on `status`, or a partition transform, is what makes that filter skip files.
>
> ### Check 3 (≈20s): Did partition pruning silently break? — `EXPLAIN` and look at the TableScan
>
> ```sql
> -- Trino 467 — distributed plan with predicate stats (does NOT execute the query).
> EXPLAIN (TYPE DISTRIBUTED) <paste the slow dashboard query>;
> ```
>
> Look for one of these signatures on the `TableScan` node for the fact table:
>
> | Signature | Diagnosis |
> |---|---|
> | `TableScan` has a **predicate inside the connector** (`constraint = day(occurred_at) IN ...`) → pruning ON | Pruning is working; root cause is something else (skew, joins, file count). Go to Check 4. |
> | `TableScan` has **NO partition predicate inside the connector** + a `Filter` node ABOVE the TableScan applying the predicate | **Pruning broke.** The predicate now wraps the partition/sort column in an *opaque, non-invertible* expression the optimizer cannot rewrite into a bare-column range — e.g. `WHERE LOWER(tenant_id)='acme'` on a VARCHAR partition column, or a `regexp_like(...)` / JSON-extraction / UDF / `SUBSTR(col,...)` / non-monotonic-arithmetic wrap. **NOTE — the common *temporal* wraps do NOT break pruning in Trino 467:** `WHERE date(occurred_at)='...'`, `CAST(occurred_at AS DATE)='...'`, `date_trunc('day',occurred_at)='...'`, `year(occurred_at)=...` all still prune, because the default-on `Unwrap{Cast,DateTrunc,Year}InComparison` rules rewrite them into a bare-column range automatically (verified `UnwrapCastInComparison.java`@467; see [r07 §1](07-analytical-query-patterns.md#trino-467-reality)). Fix by removing the opaque wrap — compare the bare column directly (`WHERE tenant_id='acme'`) or pre-compute the value at ingest. See Step 4 below for the full predicate-shape rules. |
> | `TableScan` shows `inputRows` in the **billions** when the dashboard should only need one day | Same root cause as the row above — predicate didn't push. Same fix. |
>
> ### Check 4 (≈15s): Is one fragment doing all the work? — `EXPLAIN ANALYZE` and look at per-fragment time
>
> If you got here, pruning is fine — the question is *where* time is going. Run the slow query through `EXPLAIN ANALYZE` (this DOES execute the query):
>
> ```sql
> EXPLAIN ANALYZE <paste the slow query>;
> ```
>
> Read the per-fragment timings at the top of each fragment block. Three patterns:
>
> | Pattern | Diagnosis | Pointer |
> |---|---|---|
> | One fragment shows `CPU time` ≈ `Scheduled time` AND wall-clock dominates total query time | CPU-bound aggregation or hash-join build. Maybe a heavy `GROUP BY` with high-cardinality keys. Often fine — query is just expensive. | Step 6 (data model) |
> | One fragment shows `Scheduled time >> CPU time` | **I/O-bound or network-bound** — waiting on MinIO reads or downstream consumers. Often means small-files explosion at the storage layer (per-file open overhead dominates). | Step 7 (small files) |
> | The whole query runs on **one or two drivers** while others are idle (driver count = 1 in the heaviest operator) | **Skew** — one partition or one tenant has 95% of the rows. | Step 5 (partition skew) |
>
> **End of FIRST 60 SECONDS.** By this point you have narrowed the root cause to one of: (a) concurrency, (b) metadata bloat, (c) pruning failure, (d) skew, (e) small files, or (f) genuinely expensive query. The remaining steps in this document drill down into each.
>
> ### Worked example — the four-check triage applied
>
> > **Symptom**: dashboard query (90-day tenant funnel) ran in 2s last week, now 45s. No code change.
> >
> > **Check 1**: Trino UI shows queued=0, running=8 (normal). Not concurrency. Continue.
> >
> > **Check 2**: `SELECT COUNT(*) FROM iceberg.analytics.user_events` returns in 0.4s. Fast. Not metadata bloat. Continue.
> >
> > **Check 3**: `EXPLAIN (TYPE DISTRIBUTED)` shows TableScan with `inputRows = 1.4B` and a `Filter` node above it carrying `LOWER(tenant_id) = 'acme'`. **Pruning broke.** The dashboard's BI tool got upgraded last weekend and now lower-cases the tenant filter for "case-insensitive matching" — but `tenant_id` is a VARCHAR partition column and `LOWER()` is non-invertible, so the optimizer cannot rewrite it into a bare-column constraint and every partition is scanned. Old shape was the bare `tenant_id = 'acme'`. (Had the BI tool instead wrapped a *date* column in `date()`/`CAST AS DATE`, pruning would have been **fine** — Trino 467 unwraps those; the `LOWER()` on a string column is the genuine killer.)
> >
> > **Fix**: edit the dashboard SQL to drop the `LOWER()` wrap and compare the bare partition column (`WHERE tenant_id = 'acme'`); if case-insensitive matching is genuinely needed, fold `tenant_id` to lower-case **at ingest** so the stored partition values are already normalized. Re-run: query back to 2s. **Total triage time: ~60 seconds.**
>
> ### DO-NOT-WRITE — banned forms in the oncall checklist (these are the fabrications the responder tends to invent under pressure)
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `SELECT * FROM system.runtime.queries WHERE catalog = 'iceberg' ORDER BY peak_memory_bytes DESC` | The `catalog` column does NOT exist on `system.runtime.queries` (see Trino 467 schema below). The `peak_memory_bytes` column does NOT exist there either. Both are confidently-invented column names. | To find queries that touched a catalog, search the SQL text: `WHERE query LIKE '%iceberg.%' AND state = 'FINISHED'`. For peak memory, scrape JMX MBeans `trino.execution:name=QueryManager` or the persisted event-listener `QueryCompletedEvent`. **For per-query CPU + bytes scanned (the "which query is hammering the cluster / scanned the most data" question), DON'T stop here — there IS a live recipe: see §"Finding expensive queries on Trino 467" below, which JOINs `system.runtime.queries` to `system.runtime.tasks` on `query_id` (`tasks.split_cpu_time_ms` + `tasks.physical_input_bytes`).** |
> | `EXPLAIN PLAN FOR <query>` | This is **Oracle/Postgres syntax**, not Trino. Trino does NOT accept `PLAN FOR`. | `EXPLAIN <query>` (defaults to DISTRIBUTED), or `EXPLAIN (TYPE DISTRIBUTED) <query>`, or `EXPLAIN (TYPE IO) <query>`. See [trino.io/docs/current/sql/explain.html](https://trino.io/docs/current/sql/explain.html). |
> | `ANALYZE TABLE iceberg.analytics.user_events` | The `TABLE` keyword is **Spark/Hive dialect**. Trino's parser rejects it. | Bare `ANALYZE iceberg.analytics.user_events` — no `TABLE` keyword. See resource 24-trino-cbo-analyze.md §4 leading canonical statement. |
> | `CALL iceberg.system.rewrite_data_files(...)` pasted into the Trino query console | `CALL iceberg.system.*` is **Spark SQL only**; Trino rejects with parse error. Trino's equivalent is `ALTER TABLE ... EXECUTE`. | For compaction on Trino 467: `ALTER TABLE <t> EXECUTE optimize(file_size_threshold => '512MB')`. For procedures Trino lacks (rewrite-all=true, z-order, MoR delete cleanup, rewrite_manifests on 467), run via Spark — see resource 17 §"Trino EXECUTE vs Spark CALL" disambiguation matrix. |
> | `KILL QUERY '<query_id>'` | Not Trino syntax. Trino uses `CALL system.runtime.kill_query(query_id => '<id>', message => '<reason>')`. | The verified kill command is in the "Immediate remediation" subsection below. |
> | "The query is slow because the CBO chose a bad plan — Trino has known CBO bugs." | This is rarely the actual root cause. The CBO can choose a bad plan ONLY IF you've never run `ANALYZE` (no stats → heuristics → sometimes wrong). The fix is to run `ANALYZE`, not file a Trino bug. | First run `ANALYZE iceberg.<schema>.<table>` and re-test. The "Trino bug" hypothesis is the LAST hypothesis, not the first. See resource 24. |
> | "Adding more workers will speed up any slow query." | False. Trino scales by the slowest fragment. If the bottleneck is **skew** (one driver, others idle) or **coordinator-bound planning** (manifest explosion), more workers do NOT help. | Diagnose with EXPLAIN ANALYZE per-fragment timing FIRST. Add workers only after you've confirmed the query is CPU-bound across many drivers. |
> | "Restart the Trino cluster to fix slow queries." | This nukes all in-flight queries and the metadata cache. It is essentially never the right answer for a query-perf regression. | The metadata cache (`iceberg.metadata-cache-enabled=true`) can be flushed without restart via the JMX endpoint; query-perf bugs almost always have a non-restart fix (recompile predicate, run ANALYZE, compact). |
>
> **Why this DO-NOT-WRITE block exists:** under oncall pressure the temptation is to paste a "well-known" command from memory — but the well-known commands above are from **other engines** (Spark, Oracle, Postgres) or use **invented columns** that sound plausible. Each banned form has been observed as a confident-but-wrong response. **Always paste from this document, not from memory.**
>
> ### Cross-references for the FIRST 60 SECONDS workflow
>
> - **Resource 17 §"Trino EXECUTE vs Spark CALL"** — full disambiguation of which procedures run on Trino vs Spark.
> - **Resource 24 §4** — canonical `ANALYZE` syntax for Trino 467 (no `TABLE` keyword).
> - **Resource 28 §"EXPLAIN-driven optimization"** — complex-query CTE inlining, CorrelatedJoin, materialized=table dbt lever.
> - **Resource 10 §"Predicates that may defeat partition pruning"** — full catalog of function-wrapped / type-mismatch predicate shapes.

---

## LEADING CANONICAL ONCALL TUNING-LEVERS — "Which Trino session properties should I set to speed up a slow query?" (read this FIRST for SET SESSION / session-property tuning questions)

> **This is the findable canonical answer for the oncall session-property-tuning question. Every property name below has been verified against [trino.io/docs/current/admin/properties-general.html](https://trino.io/docs/current/admin/properties-general.html), [trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html), [trino.io/docs/current/admin/properties-task.html](https://trino.io/docs/current/admin/properties-task.html), [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html), and [trino.io/docs/current/admin/spill.html](https://trino.io/docs/current/admin/spill.html). Do NOT invent property names — paste verbatim.**
>
> **The naming rule that traps everyone (read this FIRST).** Every Trino tuning knob exists in TWO forms with DIFFERENT spellings — getting them mixed up is the #1 fab class under oncall pressure:
>
> | Form | Where it lives | Spelling convention | Example |
> |---|---|---|---|
> | **Config property** (cluster-wide, requires restart) | `etc/config.properties` on the coordinator/workers | **DOTS and HYPHENS** (no underscores) | `query.max-memory-per-node=8GB` |
> | **Session property** (per-query, no restart) | `SET SESSION <name> = <value>;` in your SQL session | **UNDERSCORES** (no dots/hyphens) | `SET SESSION query_max_memory_per_node = '8GB';` |
>
> The two forms control the SAME underlying setting. The session form can OVERRIDE the config default but **only DOWNWARD** for memory limits (you can lower the cap for a specific query, not raise it). For non-limit settings (`join_distribution_type`, `enable_dynamic_filtering`, `task_concurrency`) the session form can override in either direction.
>
> **The five session properties that matter most for query-perf oncall (verbatim).** Use these IN ORDER — each lever earlier in the list is cheaper to try and reversible:
>
> | # | Session property (UNDERSCORES) | Config equivalent (DOTS/HYPHENS) | What it does | When to reach for it |
> |---|---|---|---|---|
> | **1** | `join_distribution_type` (`'AUTOMATIC'` / `'BROADCAST'` / `'PARTITIONED'`) | `join-distribution-type` | The lever between broadcast (small build, replicated to every worker) and partitioned (hash-repartitioned across workers) join distribution. **Primary cost-based-optimizer override.** Default `AUTOMATIC`. | OOM on fact-to-dim join (try `'PARTITIONED'`); slow fact-to-dim join with a small dim (try `'BROADCAST'`). See r24 LEADING CANONICAL join-distribution block. |
> | **2** | `join_max_broadcast_table_size` (DURATION-like string `'50MB'`) | `join-max-broadcast-table-size` | The AUTOMATIC-mode broadcast threshold. If the planner estimates the smaller side is below this, it chooses BROADCAST. Default `100MB`. | Tune the auto-broadcast threshold down (force PARTITIONED) when you've blown memory on a "small but not that small" dim. Tune up to encourage BROADCAST when you have ample RAM. |
> | **3** | `enable_dynamic_filtering` (`true`/`false`, default `true`) | `enable-dynamic-filtering` | Master on/off for dynamic filtering — the runtime mechanism that pushes IN-list / range predicates from the build side of a join into the probe-side scan. Default ON. | NEVER disable in prod (huge perf loss). Only set `false` for diagnostic A/B testing when you suspect DF is producing wrong results — a rare path. |
> | **4** | `query_max_memory_per_node` (`'8GB'`) | `query.max-memory-per-node` | Per-query memory cap on ONE worker. Session form can only LOWER, not raise. Default **30% of JVM max heap** per [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html). | Throttle a heavy ad-hoc query to keep it from hogging cluster memory: `SET SESSION query_max_memory_per_node = '4GB';`. |
> | **5** | `task_concurrency` (integer, default = node physical CPU count, clamped to min 2 / max 32) | `task.concurrency` | Number of parallel drivers per worker for an operator (join/aggregation). Higher = more parallelism per worker; lower = leaves room for other concurrent queries. Default auto-derived from physical CPUs per [trino.io/docs/current/admin/properties-task.html](https://trino.io/docs/current/admin/properties-task.html) (8 under fault-tolerant execution mode). | Lower (e.g., `SET SESSION task_concurrency = 4`) when many queries run concurrently and you want each to use less worker CPU. Raise (e.g., `SET SESSION task_concurrency = 32`) for a single-tenant heavy query on an idle cluster. |
>
> **Verbatim usage examples (paste these, don't paraphrase):**
>
> ```sql
> -- Per-query tuning for a specific slow dashboard query.
> -- Issued in the SAME SQL session before the SELECT — Trino scopes session properties to the session only.
> SET SESSION join_distribution_type = 'BROADCAST';
> SET SESSION join_max_broadcast_table_size = '50MB';
> SET SESSION query_max_memory_per_node = '8GB';
>
> -- Run the actual query.
> SELECT ... FROM iceberg.analytics.events e JOIN iceberg.analytics.tenants t ON ...;
>
> -- Optional: clear an override when done (next query reverts to cluster default).
> RESET SESSION join_distribution_type;
> ```
>
> **Verify what's actually set in your current session:**
>
> ```sql
> -- Shows every session property that has been set / overridden in THIS session.
> SHOW SESSION LIKE 'join_distribution_type';
> SHOW SESSION LIKE '%dynamic_filter%';
> SHOW SESSION LIKE 'query_max_%';
> -- Bare `SHOW SESSION` lists all session properties and their current/default values.
> ```
>
> ### DO-NOT-WRITE — banned session-property forms in the oncall tuning checklist
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `SET SESSION query.max-memory-per-node = '8GB'` | **Mixing config-property spelling into a session statement.** `SET SESSION` requires the UNDERSCORE form. Trino rejects the dot/hyphen form with `Session property 'query.max-memory-per-node' does not exist`. | `SET SESSION query_max_memory_per_node = '8GB';` (underscores). |
> | `SET SESSION enable-dynamic-filtering = false` | Same class — config spelling pasted into session syntax. Hyphens are config-property delimiters, NOT session-property delimiters. | `SET SESSION enable_dynamic_filtering = false;` (underscores). |
> | `SET SESSION task.concurrency = 8` | Same class — dot is config-property delimiter, not session. | `SET SESSION task_concurrency = 8;` (underscores). |
> | `SET join_distribution_type = 'BROADCAST'` (missing `SESSION` keyword) | Trino requires the `SESSION` keyword (`SET SESSION <prop> = ...`). Bare `SET <prop>` is **PostgreSQL/MySQL syntax** for setting a session variable, NOT Trino. Trino rejects with `mismatched input '=' expecting ...`. | `SET SESSION join_distribution_type = 'BROADCAST';` (include the `SESSION` keyword). |
> | `SET SESSION join_distribution_type = 'HASH'` or `'SHUFFLE'` or `'REPARTITIONED'` | Invented values. The three valid values per [trino.io/docs/current/optimizer/cost-based-optimizations.html](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) are `'AUTOMATIC'`, `'BROADCAST'`, `'PARTITIONED'`. | `SET SESSION join_distribution_type = 'PARTITIONED';` (uppercase, exact). |
> | `SET SESSION iceberg.dynamic_filtering_wait_timeout = '30s'` ← **without** the catalog prefix on a federation case | This catalog-prefixed form IS correct for per-catalog DF tuning, but a bare-form `dynamic_filtering_wait_timeout` (no catalog prefix) does NOT exist as a system session property. The system-level master switch is `enable_dynamic_filtering` (boolean), NOT a wait-timeout. | Per-catalog: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '30s';` (catalog prefix required). System-level on/off only: `SET SESSION enable_dynamic_filtering = true;`. |
> | `SET SESSION /*+ BROADCAST(t) */ join_distribution_type = ...` (combining session set with `/*+ ... */` hint) | Trino 467 has NO query-hint syntax. `/*+ ... */` is silently parsed as a block comment (zero effect). Mixing hint syntax with `SET SESSION` is a sign the writer is composing from another engine's playbook (Oracle/Spark/Hive). | Just `SET SESSION join_distribution_type = 'BROADCAST';` — no hint comment. See r24 LEADING CANONICAL join-distribution block + r23 anti-patterns table. |
> | `ALTER SESSION SET join_distribution_type = 'BROADCAST'` | **`ALTER SESSION SET ...` is Oracle syntax.** Trino rejects with parse error. | `SET SESSION join_distribution_type = 'BROADCAST';` |
> | `SET LOCAL join_distribution_type = 'BROADCAST'` | **`SET LOCAL` is PostgreSQL syntax** (transaction-scoped variable). Trino has no transaction-scoped session variables and no `SET LOCAL` syntax. | `SET SESSION join_distribution_type = 'BROADCAST';` (session-scoped is the only form). |
> | "Disable dynamic filtering to speed up the query" | DF is enabled by default and almost always helps. Disabling it is rarely the right answer — usually the suggestion comes from someone debugging a corner case. | Leave `enable_dynamic_filtering = true`. If DF is causing measurable harm (very rare), file a Trino issue with EXPLAIN ANALYZE output rather than turning it off in prod. |
>
> **Why this DO-NOT-WRITE block exists:** under oncall pressure engineers paste session-property `SET` commands from memory. The dot-vs-underscore confusion is the single highest-frequency Trino-tuning fab (it spans every property family — memory, joins, DF, tasks) and produces a `Session property X does not exist` parse error that's easy to misdiagnose as "the property doesn't exist on this version." It exists; you wrote it in the wrong form. Also banned: `ALTER SESSION` (Oracle), `SET LOCAL` (Postgres), bare `SET <prop>` (Postgres/MySQL), hint-in-session-set composites (Spark/Oracle). **Always paste from this document; never paste a session-property `SET` from cloud-warehouse / Spark / Oracle muscle memory.**
>
> ### Cross-references for session-property tuning
>
> - **THIS RESOURCE, "LEADING CANONICAL — Trino 467 memory limits + spill-to-disk"** (immediately below) — the dedicated memory/spill card with the full session-vs-config split + the FAB matrix banning `task_max_memory` and `memory_revoking_enabled` (the two most-fabricated memory session-property names). Read this for OOM / `Query exceeded per-node memory limit` / spill questions.
> - **Resource 24 §"LEADING CANONICAL — How do I influence Trino's join distribution"** — the canonical three-lever join-distribution recipe with the same DO-NOT-WRITE matrix banning `/*+ USE_HASH_JOIN */` and other hint forms.
> - **Resource 23 §"SQL anti-patterns"** — the consolidated cross-dialect-spillover table including hint syntax, `ALTER SESSION`, `SET LOCAL`.
> - **Resource 22 §5.1** — federation-side dynamic filtering with the per-catalog `<catalog>.dynamic_filtering_wait_timeout` form.
> - **Resource 27 §4.4B** — the consolidated CROSS-DIALECT-SPILLOVER guardrail covering Oracle/Postgres/Snowflake/Spark forms that look valid but parse-error against Trino 467.

---

## LEADING CANONICAL — "Trino 467 memory limits + spill-to-disk: what knobs actually exist" (read this FIRST for `Query exceeded per-node memory limit`, OOM, spill, spill-to-disk, out of memory, memory limit, per-node memory questions)

> **This is the findable canonical answer for memory-limit-and-spill tuning. Every property name below has been verified against [trino.io/docs/current/admin/properties-memory-management.html](https://trino.io/docs/current/admin/properties-memory-management.html), [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html), [trino.io/docs/current/admin/properties-spilling.html](https://trino.io/docs/current/admin/properties-spilling.html), and [trino.io/docs/current/admin/spill.html](https://trino.io/docs/current/admin/spill.html). Do NOT invent session-property names. If a property name is not at one of those URLs, do NOT write it.**
>
> **Keywords this card answers**: `Query exceeded per-node memory limit`, `Query exceeded distributed memory limit`, `EXCEEDED_LOCAL_MEMORY_LIMIT`, `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT`, OOM, out of memory, memory limit, per-node memory, spill, spill to disk, spill-to-disk, enable spill, `SPILL_FAILED`, "lower memory per query", "lower memory limit one query", "per-query memory cap", "without restart", `spill_enabled`, `spill_order_by_enabled` (fabricated — see DO-NOT-WRITE matrix below), `spill_aggregations_enabled` (fabricated), `task_max_memory` (fabricated), `memory_revoking_enabled` (fabricated).
>
> ### The session-vs-config split (read this FIRST)
>
> Trino's memory and spill knobs come in TWO categories with VERY different semantics. **Confusing the two is the single most common fab class for this topic** — engineers write `SET SESSION <plausible_memory_name>` for a knob that is actually CONFIG-only, get `Session property <name> does not exist`, and waste an hour. Memorize this split:
>
> | Category | Where it lives | Spelling | Change requires | Per-query? |
> |---|---|---|---|---|
> | **SESSION property** | `SET SESSION <name> = <value>;` in your SQL session | UNDERSCORES (no dots/hyphens) | Nothing — applies to next query in this session | Yes — per-query / per-session |
> | **CONFIG property** | `etc/config.properties` on coordinator + every worker | DOTS and HYPHENS (no underscores) | Cluster restart (rolling worker + coordinator restart) | No — cluster-wide |
>
> **The REAL session properties for memory + spill (Trino 467) — these are the only ones that exist.** Every name below is verifiable at `trino.io/docs/current/admin/properties-*.html` or `trino.io/docs/current/admin/spill.html`:
>
> | # | Session property (UNDERSCORES) | Config equivalent (DOTS/HYPHENS) | What it does | Notes |
> |---|---|---|---|---|
> | **1** | `query_max_memory` | `query.max-memory` | Cluster-wide user-memory cap for THIS query (summed across all workers). | **CAN ONLY LOWER** the config ceiling — you cannot raise it above the `query.max-memory` config value. Default config value: `20GB` per [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html). |
> | **2** | `query_max_memory_per_node` | `query.max-memory-per-node` | Per-worker user-memory cap for THIS query. | **CAN ONLY LOWER** the config ceiling — you cannot raise it above the `query.max-memory-per-node` config value. Default config value: **30% of the JVM max heap** per [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html). |
> | **3** | `query_max_total_memory` | `query.max-total-memory` | Cluster-wide user+system memory cap for THIS query. | Same lower-only override semantics. Default config: `query.max-memory × 2`. |
> | **4** | `spill_enabled` | `spill-enabled` | The **single MASTER ENABLE switch** for spill-to-disk on THIS query. | Default config: `false`. **This is the ONLY lever to enable spill per-query**: `SET SESSION spill_enabled = true;`. When ON, spill applies AUTOMATICALLY to hash joins (build side), final/partial aggregations, `ORDER BY` sort buffers, and window functions. **There is NO per-operator spill-enable toggle in Trino 467** — no `spill_aggregations_enabled`, no `spill_joins_enabled`, no `spill_order_by_enabled`, no `spill_window_enabled`. The historical per-operator toggles `spill-ordering-aggregations-enabled` and `spill-distincting-aggregations-enabled` were REMOVED in Trino Release 366 (Dec 2021) per [trino.io/docs/current/release/release-366.html](https://trino.io/docs/current/release/release-366.html). |
>
> **CONFIG-ONLY properties (NOT session-settable; live in `etc/config.properties`; require cluster restart).** These control HOW the cluster behaves cluster-wide; you cannot toggle them per-query:
>
> | Config property | Default | What it does | Why it's config-only |
> |---|---|---|---|
> | `memory.heap-headroom-per-node` | 30% of max heap | Reserves a fraction of JVM heap that Trino refuses to use for query memory (kept for GC and non-query JVM overhead). | Process-level tuning; can't be per-query. |
> | `memory-revoking-threshold` | `0.9` | Fraction of the memory pool that triggers **revoking** (i.e., starts spilling memory from running queries) once `spill-enabled=true`. | Cluster-wide spill-trigger tuning; not session-settable. **Controls WHEN spill triggers, NOT whether spill is enabled.** |
> | `memory-revoking-target` | `0.5` | After revoking triggers, the fraction of the memory pool to drop to before stopping revocation. | Same — cluster-wide spill behavior tuning, not session-settable. |
> | `spiller-spill-path` | (none — required when `spill-enabled=true`) | Local disk path(s) for spill files (comma-separated for striping). | Filesystem path, can't be per-query. |
> | `max-spill-per-node` | `100GB` | Aggregate spill cap across ALL queries on one worker node. | Cluster-wide quota. |
> | `query-max-spill-per-node` | `100GB` | Per-query spill cap on one worker. | Cluster-wide quota per-query (set at config time). |
>
> **The key conceptual point about `memory-revoking-threshold` / `memory-revoking-target`**: these are NOT "spill enable/disable" knobs. They are tuning knobs that control WHEN spill triggers AFTER `spill-enabled=true` is set. Setting `memory-revoking-threshold=0.85` makes spill trigger sooner (at 85% of memory pool); setting `0.95` makes it trigger later. Neither value enables spill — only `spill-enabled=true` (config) or `SET SESSION spill_enabled = true;` does that.
>
> ### Practical fix for `Query exceeded per-node memory limit` (the canonical OOM remediation)
>
> When you see `Query exceeded per-node memory limit` or `EXCEEDED_LOCAL_MEMORY_LIMIT`, work through these in order — each step is cheaper to try than the next:
>
> 1. **Enable spill-to-disk for this query** (the actual enable-spill lever):
>    ```sql
>    SET SESSION spill_enabled = true;
>    -- Now re-run the failing query in the SAME session.
>    SELECT ... ;  -- the query that OOMed
>    ```
>    This is the single most actionable session-only fix. Requires `spill-enabled=false` cluster default (which is the Trino default) AND a worker `spiller-spill-path` configured in `etc/config.properties` (a one-time cluster config). If `spiller-spill-path` is not set, `SET SESSION spill_enabled = true` succeeds but no spill actually happens.
>
> 2. **Reduce the query's memory footprint** (no cluster config change needed):
>    - Add a tighter partition filter (smaller scan ⇒ smaller hash table).
>    - Pre-aggregate in a CTE or staging dbt model before the heavy join / GROUP BY.
>    - Replace `COUNT(DISTINCT high_cardinality_column)` with `approx_distinct(high_cardinality_column)` (HyperLogLog — bounded memory).
>    - Avoid high-cardinality GROUP BY that explodes the aggregation state (e.g., `GROUP BY user_id` on a billion-user table without partition filter).
>    - For fact-to-dim joins: `SET SESSION join_distribution_type = 'BROADCAST'` (when the dim is small) — see §9a above and r24 LEADING CANONICAL join-distribution block.
>
> 3. **Cluster-side: raise the per-node memory CEILING** (RAISING requires worker restart — only the config form can raise; the session form `query_max_memory_per_node` can LOWER below the ceiling per-query but cannot RAISE above it):
>    ```properties
>    # /etc/trino/config.properties on every worker + coordinator — requires restart.
>    query.max-memory-per-node=8GB
>    ```
>    This is the LAST-resort fix because it requires a cluster restart and raises the ceiling for ALL queries (so one bad query can hog more memory cluster-wide). Prefer the session-only fixes above. **Note**: if you only need to LOWER the per-node cap for one heavy query (defensive throttling — without restart), use `SET SESSION query_max_memory_per_node = '4GB';` instead. Session form lowers ONLY (cannot exceed config ceiling).
>
> 4. **Resource groups (cluster-level workload throttling — NOT a single-query memory lever)**: resource groups in `etc/resource-groups.properties` control concurrency, CPU, and memory **per workload class** (e.g., "BI dashboards get 30% of cluster memory and max 10 concurrent queries; ad-hoc analyst queries get 20% and max 3 concurrent"). They are NOT a knob you reach for to fix ONE query's OOM — they are a knob to prevent the "noisy neighbor" pattern where one workload starves another. If your OOM root cause is "this query genuinely needs more memory than the cluster has", resource groups are NOT the answer; spill (Step 1) or restructuring (Step 2) is.
>
> ### ⚠️ DIAGNOSIS GUARD — `ORDER BY ... LIMIT n` is a bounded-memory **TopN**, NOT a full sort. Don't reflexively blame "spilling" for a slow `ORDER BY + LIMIT`.
>
> *(Keyword anchors: ORDER BY LIMIT slow / dies, top-N query slow, "ORDER BY then LIMIT" runs for an hour, is my ORDER BY spilling, sort-then-limit out of memory, why is ORDER BY ... LIMIT slow on a huge table.)*
>
> Trino's optimizer rewrites `ORDER BY x LIMIT n` into a **TopN operator that keeps a bounded heap of only the top `n` rows per worker** — it does **NOT** sort all the input rows and then slice off `n`. So per-operator memory for the ordering step is bounded by ~`n` rows, not by the full input. **For a SMALL `n`, a `LIMIT`'d `ORDER BY` will essentially never OOM or spill on the sort itself.** If such a query is slow / dies on a 200M-row table, the dominant cost is almost always the **unfiltered TableScan reading all 200M rows** (and feeding them through the TopN), NOT a spilling sort. **Diagnose with `EXPLAIN`**: look for a `TopN[n]` (or `TopNPartial`) node — if it's there, the ordering is already bounded; chase the `TableScan` (`inputRows` near the full table, no `constraint=` ⇒ no partition pruning). **Fix:** add a time/partition predicate so the scan prunes (`WHERE event_time >= TIMESTAMP '...'`), project only needed columns, and (if it genuinely is a huge sort, e.g. a very large `n` or `ORDER BY` with no `LIMIT`) THEN enable spill per Step 1.
>
> **DO-NOT-WRITE (TopN/spill misdiagnosis):**
> | DO NOT say / write | Why it's wrong | The right framing |
> |---|---|---|
> | "`ORDER BY event_time LIMIT 100` sorts all 200M rows then takes 100, so it spills / OOMs on the sort." | Trino rewrites it to a **TopN** with a bounded heap of `n` rows — it does NOT materialize a full sort of the input. Spill on the ordering step is unlikely for a small `n`. | The slowness is the **unfiltered 200M-row TableScan** feeding the TopN. Add a partition/time predicate so the scan prunes; verify the plan shows `TopN[n]` + a pruned `TableScan`. |
> | "Lower `query_max_memory_per_node` so the query spills EARLIER." | **Backwards.** `query_max_memory_per_node` is a **hard cap** (session form can only LOWER it). Lowering it makes the query **FAIL earlier** with `Query exceeded per-node memory limit`, it does NOT make it spill earlier. The spill *trigger* is the config-only `memory-revoking-threshold`, not a session knob. | To enable spill: `SET SESSION spill_enabled = true;` (Step 1). To make spill trigger sooner, tune the CONFIG `memory-revoking-threshold` (cluster restart) — not the memory cap. |
>
> (Cross-ref: the TopN-vs-full-sort distinction and the determinism note also live in [r23 §ORDER BY / TopN](23-sql-best-practices-olap.md).)
>
> ### DO-NOT-WRITE — FABRICATED memory/spill session-property names (banned in every Trino 467 resource)
>
> | DO NOT write this | Why it's wrong | The right answer |
> |---|---|---|
> | `SET SESSION task_max_memory = '4GB'` | **FABRICATION.** No such Trino session property exists. There is no `task_max_memory` at [trino.io/docs/current/admin/properties-memory-management.html](https://trino.io/docs/current/admin/properties-memory-management.html) or anywhere else in the Trino 467 session-property catalog. The plausible-but-wrong sibling-name mash-up (looks like a sibling of `query_max_memory`). The per-node memory **CEILING** is config-only (`query.max-memory-per-node` in `etc/config.properties` — requires cluster restart to RAISE), but a per-query **DOWNWARD** override IS session-settable via `query_max_memory_per_node`. Trino rejects: `Session property task_max_memory does not exist`. | For per-query/per-node throttling DOWNWARD (no restart): `SET SESSION query_max_memory_per_node = '4GB';` (the session form — can LOWER but cannot raise above the config ceiling). For raising the cluster ceiling: `query.max-memory-per-node=8GB` in `etc/config.properties` + worker restart. |
> | `SET SESSION memory_revoking_enabled = true` | **FABRICATION.** No such Trino session property exists. The `memory-revoking-*` family (`memory-revoking-threshold`, `memory-revoking-target`) are CONFIG-ONLY in `etc/config.properties` and they control WHEN spill triggers, NOT whether spill is enabled. Trino rejects: `Session property memory_revoking_enabled does not exist`. | To enable spill per-query: `SET SESSION spill_enabled = true;` (the real master switch). Worth setting at the cluster level too: `spill-enabled=true` in `etc/config.properties` + `spiller-spill-path=/var/trino/spill`. |
> | `SET SESSION distributed_join_distribution_type = 'PARTITIONED'` (iter474-class regression, kept in matrix) | **FABRICATION** — dead `distributed_` prefix splice. Trino rejects: `Session property distributed_join_distribution_type does not exist`. | `SET SESSION join_distribution_type = 'PARTITIONED';` |
> | `SET SESSION task.max-memory = '4GB'` | **FABRICATION** + dot-spelling mash-up. There IS a config property `task.max-memory-per-task` (experimental, config-only), but NO session counterpart, and the bare `task.max-memory` form is not a valid property name. | Per-node CEILING: `query.max-memory-per-node` (config-only, requires restart to RAISE). Per-query DOWNWARD override (no restart): `SET SESSION query_max_memory_per_node = '4GB';` (session — LOWERS only, cannot raise above the config ceiling). |
> | `SET SESSION task_memory_limit = '4GB'` | **FABRICATION** — plausible-looking sibling-name mash-up. No `task_memory_limit` session property exists. | Same as above — `SET SESSION query_max_memory_per_node = '...';` (session, LOWERS only) or `query.max-memory-per-node` (config, requires restart to RAISE the ceiling). |
> | `SET SESSION memory_revoke_enabled = true` | **FABRICATION** — variant spelling of the `memory_revoking_enabled` fab above. Still does not exist. | `SET SESSION spill_enabled = true;` |
> | `SET SESSION spill_to_disk_enabled = true` | **FABRICATION** — verbose-name variant. No such session property. | `SET SESSION spill_enabled = true;` |
> | `SET SESSION enable_spill = true` | **FABRICATION** — `enable_*`-prefix variant. The actual session property is `spill_enabled` (suffix form), NOT `enable_spill`. | `SET SESSION spill_enabled = true;` |
> | `SET SESSION query.max-memory-per-node = '4GB'` (dot-spelling in a SET SESSION) | **WRONG FORM** — config-property spelling in a session statement. `SET SESSION` requires UNDERSCORE form. Trino rejects: `Session property query.max-memory-per-node does not exist`. | `SET SESSION query_max_memory_per_node = '4GB';` (underscores). |
> | `SET SESSION memory-revoking-threshold = 0.85` | **CATEGORY ERROR** — `memory-revoking-threshold` is CONFIG-ONLY. It is not session-settable in any form (with hyphens OR underscores). | Set in `etc/config.properties` cluster-wide: `memory-revoking-threshold=0.85` + cluster restart. There is no session knob for this. |
> | `SET SESSION spill_order_by_enabled = true` (and the config form `spill-order-by-enabled`) | **FABRICATION** — sibling-name extrapolation off the (also-fabricated) "per-operator spill toggle" pattern. **No such Trino 467 property exists in any form.** The closest historical Presto property was `spill-ordering-aggregations-enabled`, which was REMOVED in Trino Release 366 (Dec 2021) per [trino.io/docs/current/release/release-366.html](https://trino.io/docs/current/release/release-366.html). In Trino 467 there is **no separate ORDER BY spill toggle**: when `spill_enabled = true` (session) or `spill-enabled = true` (config), spill applies AUTOMATICALLY to sorts (ORDER BY) along with joins, aggregations, and window functions. The 9 documented spilling properties at [trino.io/docs/current/admin/properties-spilling.html](https://trino.io/docs/current/admin/properties-spilling.html) are: `spill-enabled`, `spiller-spill-path`, `spiller-max-used-space-threshold`, `spiller-threads`, `max-spill-per-node`, `query-max-spill-per-node`, `aggregation-operator-unspill-memory-limit`, `spill-compression-codec`, `spill-encryption-enabled`. **None of them is a per-operator spill-ENABLE toggle.** | `SET SESSION spill_enabled = true;` — that single switch covers ORDER BY (and joins, aggregations, windows). |
> | `SET SESSION spill_aggregations_enabled = true` / `spill_aggregation_enabled = true` | **FABRICATION** — same pattern. The historical `spill-distincting-aggregations-enabled` was REMOVED in Trino Release 366 (Dec 2021). Trino 467 has no per-operator enable toggle for aggregation spill. | `SET SESSION spill_enabled = true;` — enables aggregation spill automatically. |
> | `SET SESSION spill_joins_enabled = true` | **FABRICATION** — no per-operator join spill enable knob. | `SET SESSION spill_enabled = true;` — enables hash-join build-side spill automatically. |
> | `SET SESSION spill_window_enabled = true` | **FABRICATION** — no per-operator window spill enable knob. | `SET SESSION spill_enabled = true;` — enables window-function spill automatically. |
> | `SET SESSION spill_distinct_enabled = true` | **FABRICATION** — `spill-distincting-aggregations-enabled` (the closest historical sibling) was REMOVED in Trino Release 366. | `SET SESSION spill_enabled = true;`. |
>
> **The single rule for spill-enable in Trino 467**: the ONLY spill-enable lever is `spill_enabled` (session) / `spill-enabled` (config). When ON, spill applies to ALL spillable operators (hash joins, final/partial aggregations, ORDER BY sorts, window functions) AUTOMATICALLY. There is **no per-operator enable knob** anywhere in Trino 467. Any property name shaped like `spill_<operator>_enabled` is fabricated.
>
> **The general rule that pre-empts the entire fab class**: do NOT write `SET SESSION <plausible_memory_name>` from memory or by extrapolating sibling names. Every session-property name MUST be verifiable at one of:
> - [trino.io/docs/current/admin/properties-memory-management.html](https://trino.io/docs/current/admin/properties-memory-management.html)
> - [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html)
> - [trino.io/docs/current/admin/properties-spilling.html](https://trino.io/docs/current/admin/properties-spilling.html)
> - [trino.io/docs/current/admin/spill.html](https://trino.io/docs/current/admin/spill.html)
>
> If the property name you are about to write is NOT listed at one of those URLs as session-settable, **do not write it**. The four real memory/spill session properties for Trino 467 are exactly: `query_max_memory`, `query_max_memory_per_node`, `query_max_total_memory`, `spill_enabled`. There are no others in this family. In particular: **NO per-operator spill toggle exists** (no `spill_order_by_enabled`, no `spill_aggregations_enabled`, no `spill_joins_enabled`, no `spill_window_enabled`). `spill_enabled` is the single master switch — when ON, spill covers ALL spillable operators automatically.
>
> ### Quick verify — what session properties are actually set in your session?
>
> ```sql
> -- Trino 467 — shows every session property + current/default value.
> SHOW SESSION LIKE 'query_max_%';      -- the three memory session properties
> SHOW SESSION LIKE '%spill%';          -- spill_enabled (and ONLY spill_enabled)
> SHOW SESSION LIKE 'memory%';          -- there is NO memory_revoking_enabled — confirms the fab
> SHOW SESSION LIKE 'task_max_%';       -- empty result — confirms task_max_memory is a fab
> SHOW SESSION LIKE '%order_by%';       -- empty for spill_order_by_enabled — confirms the fab
> SHOW SESSION LIKE 'spill_%';          -- returns ONLY spill_enabled; no per-operator toggles
> ```
>
> Running `SHOW SESSION LIKE 'task_max_%'` will return ZERO rows on Trino 467 — that is the empirical proof that `task_max_memory` is fabricated. Same with `SHOW SESSION LIKE '%revoking%'` (empty — no `memory_revoking_*` session properties exist) and `SHOW SESSION LIKE 'spill_%'` (returns ONLY `spill_enabled` — no `spill_order_by_enabled`, no `spill_aggregations_enabled`, no per-operator spill toggles of any shape).
>
> ### Cross-references for memory + spill
>
> - **§Step 9 (this resource)** — the full memory pressure remediation workflow (join distribution → spill → SPILL_FAILED diagnostic).
> - **§9b (this resource)** — full spill-to-disk operational config (paths, compression, max-spill-per-node).
> - **§9c (this resource)** — `SPILL_FAILED` error code diagnosis (disk full, ephemeral-storage limit, permission errors).
> - **Resource 24 §LEADING CANONICAL join-distribution** — `join_distribution_type` BROADCAST/PARTITIONED lever (the cheapest OOM fix before reaching for spill).
> - **Resource 28** — complex SQL on Trino + dbt; covers approx_distinct, pre-aggregation patterns to reduce memory footprint.

---

## Triage priority order

When someone reports "queries are slow," work through these in order — each step takes 1–5 minutes and the answer in step 1 often makes the later steps irrelevant:

1. **Is it a concurrency spike?** — Are more queries running simultaneously than normal?
2. **Is it a specific query or all queries?** — Isolated regression vs. cluster-wide degradation.
3. **Did partition pruning break?** — Are you scanning more files than before?
4. **Is there partition skew?** — Is one partition carrying most of the data?
5. **Did the data model change?** — New joins, wider tables, missing filters?
6. **Are there too many small files?** — Compaction fell behind?

---

## Step 1: Check the Trino UI for concurrency

Open `http://trino-coordinator:8080/ui/queries`.

**Normal**: 5–20 concurrent queries, each completing in seconds.

**Abnormal signs:**
- **Queued queries**: "Queued" count > 0 means workers are saturated. Queries wait instead of running.
- **Long-running queries**: Any query > 2 minutes is a candidate for investigation.
- **Memory pressure**: Worker GC time > 20% of wall time in task detail view.

### Concurrency as the root cause

Each Trino worker has a fixed CPU and memory budget. If 50 dashboards all refresh at 9:00 AM simultaneously, the cluster serializes: each query gets less CPU, each takes longer, everyone complains about slowness.

**How to identify**: Look at the Trino UI query list sorted by start time. If many queries started within the same 60-second window, concurrency is the cause.

**Fixes:**
- Stagger dashboard refresh times (Metabase, Superset schedule settings).
- Set per-user resource group limits (see `05-multi-tenant-analytics.md`, resource groups section).
- Cache common aggregations in a pre-computed rollup table so 50 dashboards query a 10-row result instead of scanning the fact table.

### Query frequency as the root cause

A query that runs every 30 seconds for a live dashboard is 2,880 queries per day. If that query scans 1 GB each time, it's 2.8 TB of unnecessary I/O per day and constant worker load.

**How to identify**: In the Trino UI, look for the same query text repeating on a short interval. Or look at query history (`SELECT query, count(*) FROM system.runtime.queries GROUP BY query ORDER BY count(*) DESC LIMIT 10`).

**Fixes:**
- Cache the query result in your application layer (Redis, Memcached) for 60–300 seconds.
- Build a pre-aggregated table that refreshes every 5 minutes instead of querying the raw fact table live.
- Use Trino's `query.max-execution-time` limit to fail fast instead of hanging.

---

## Finding expensive queries on Trino 467 (verified SQL recipes)

> **READ THIS FIRST if your question is a CLUSTER-TRIAGE narrative (you may not know the table names):** "the cluster / Trino is **sluggish / slow during business hours** and I want to find out **which queries are hammering it / eating all the resources** before throwing more hardware at it"; "how do I see **what's running right now** / **which queries are running the longest** / **which queries are reading the most data**"; "**top resource-consuming** / heaviest / most-expensive queries"; "find the query that's pegging CPU / scanning the most bytes"; "which user/source/dashboard is generating the heavy load". **The answer is the `system.runtime.queries` JOIN `system.runtime.tasks` recipes in THIS section (and the mirror in r16 §"most expensive single Trino queries").** These are the live in-memory system tables — do NOT hedge or say "Trino has no way to see running queries." Note the table is EPHEMERAL (~15-min ring buffer, evicts past `query.min-expire-age` / `query.max-history`); for windows longer than ~15 min use the event listener (see the ephemeral-tables section below).

> **⭐ THE RECIPE (copy this first — per-query CPU + bytes scanned from the LIVE system tables, no event listener needed).** YES, Trino's own system tables give you per-query CPU and bytes-scanned: `system.runtime.queries` (SQL text + identity, one row per query) JOINed to `system.runtime.tasks` (the per-task metrics) on `query_id`. `tasks.split_cpu_time_ms` = CPU, `tasks.physical_input_bytes` = bytes scanned from storage. You MUST join the two — `queries` alone has neither column (that is NOT a reason to fall back to the event listener).
>
> ```sql
> -- Top 20 heaviest recent queries: bytes scanned + CPU, straight from the live system tables.
> SELECT
>   q.query_id,
>   q."user",                               -- "user" is reserved — MUST be double-quoted
>   q.source,                               -- the client/tenant tag, if set via X-Trino-Source
>   SUM(t.physical_input_bytes) / 1e9  AS gb_scanned,   -- bytes scanned from MinIO/S3
>   SUM(t.split_cpu_time_ms) / 1000.0  AS cpu_sec,      -- total CPU across all tasks
>   q.query
> FROM system.runtime.queries q
> JOIN system.runtime.tasks t ON q.query_id = t.query_id
> WHERE q.state = 'RUNNING'                 -- or state = 'FINISHED' for the just-completed window
> GROUP BY q.query_id, q."user", q.source, q.query
> ORDER BY gb_scanned DESC                   -- swap to cpu_sec DESC to rank by CPU instead
> LIMIT 20;
> ```
> Both tables are an admin-only in-memory ~15-min ring buffer (evicts past `query.min-expire-age` / `query.max-history`); for windows beyond that, the event listener is the durable path. Full column references + more recipes are below.

Before tuning anything, you need to know which queries are actually costing you the most CPU and I/O. Trino 467 exposes per-query telemetry through two system tables that you must JOIN together to get a useful view. The schema is strict — using the wrong column names is the single most common mistake in these recipes.

### The two source tables (Trino 467 schema)

**`system.runtime.queries`** — one row per query, holds the SQL text and lifecycle metadata.

> **`system.runtime.queries` — Actual Column Reference (Trino 467)**
>
> **This table has NO `catalog` or `schema` columns.** Writing `WHERE catalog = 'app_pg'` fails with `Column 'catalog' cannot be resolved`. The columns sound like they should exist (the Trino Web UI surfaces catalog per query) but they do not exist on this in-memory system table. **Source of truth**: `QuerySystemTable.java` in the Trino codebase.
>
> **Actual columns** (verified against Trino 467):
>
> - `query_id` — unique query identifier (string like `20260526_143012_00042_abcde`)
> - `state` — `RUNNING`, `FINISHED`, `FAILED`, `CANCELED`
> - `"user"` — **must be double-quoted** (unquoted `user` is parsed as the `current_user` builtin in expression contexts and silently returns the session user instead of the column value — wrong-value bug, not a syntax error). Per [trino.io/docs/current/language/reserved.html](https://trino.io/docs/current/language/reserved.html), `USER` itself is non-reserved but `CURRENT_USER` is reserved — the behavior comes from `user` being treated as shorthand for `current_user`.
> - `source` — client source name (set via JDBC `?source=<name>` URL param or the `X-Trino-Source` HTTP header)
> - `query` — the full SQL text submitted by the client (this is the ONLY place to recover the SQL on this table — there's no separate SQL column)
> - `resource_group_id` — which resource group ran the query
> - `queued_time_ms`, `analysis_time_ms`, `planning_time_ms` — phase timings in milliseconds
> - `created`, `started`, `last_heartbeat`, `end` — timestamps (end column is literally `end`, NOT `completed_at`)
> - `error_type`, `error_code` — populated for `FAILED` queries
>
> **To find queries that touched a specific catalog**, search the SQL text (no `catalog` column exists):
>
> ```sql
> SELECT query_id, "user", source, query, state, created, "end"
> FROM system.runtime.queries
> WHERE query LIKE '%app_pg%'
>   AND state = 'FINISHED'
> ORDER BY created DESC;
> ```
>
> **Caveat — `LIKE` matches can produce false positives.** A query that mentions the catalog name in a column value or a SQL comment will match spuriously. For production audit (low false-positive rate, durable past coordinator restarts), use the Trino **event listener** — the persisted `QueryCompletedEvent.metadata.catalog` field is properly catalog-keyed (see the CRITICAL — `system.runtime.*` is EPHEMERAL block below for setup).

Notable points: the **SQL text lives only on this table** (column `query`). End time is `end` (NOT `completed_at`). **No `catalog`, no `schema`, no `peak_memory_bytes` columns exist here** — those are the three most-frequently invented column names; do not write SQL against them.

> **CRITICAL — `"user"` quoting recap.** Always write `"user"` (double-quoted) when selecting, grouping, joining, or filtering on this column — every recipe below uses the quoted form. The unquoted form returns the session-user string from the `current_user` builtin on every row instead of the table's column value; the symptom is "every row shows my name" rather than a hard error, so the bug is easy to miss.

**`system.runtime.tasks`** — one row per task per stage per worker for in-flight or recently-completed queries. Holds the byte/CPU counters. Columns:

```
physical_input_bytes, split_cpu_time_ms, processed_input_bytes,
node_id, task_id, stage_id, query_id, state,
splits, queued_splits, running_splits, completed_splits,
output_bytes, output_rows, physical_written_bytes,
created, start, last_heartbeat, end
```

Notable points: CPU time is `split_cpu_time_ms` (NOT `cpu_time_ms`). There is **no `peak_memory_bytes` column on tasks** — peak memory per query lives in JMX MBeans (`trino.execution:name=QueryManager`), not in `system.runtime.tasks`. The `query` SQL text is NOT on tasks; you must JOIN to `queries` to get it.

### Recipe 1 — Top 50 most expensive queries by bytes scanned

```sql
SELECT
  q.query_id,
  q.query,
  q."user",                                 -- "user" is a Trino reserved word — MUST be quoted
  SUM(t.physical_input_bytes) / 1e9       AS input_gb,
  SUM(t.split_cpu_time_ms) / 1000.0       AS cpu_sec,
  q.created,
  q.end
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.state = 'FINISHED'
GROUP BY q.query_id, q.query, q."user", q.created, q.end
ORDER BY input_gb DESC
LIMIT 50;
```

This gives you the queries that pulled the most physical bytes from MinIO — usually the right ranking for "what costs us the most." Sort by `cpu_sec` instead if you suspect a CPU-bound query (heavy joins, aggregations) is the problem rather than I/O.

### Recipe 2 — Top high-frequency expensive queries (the dashboard-refresh killer)

A single 5-GB query is fine. The same 5-GB query running 200 times a day burns 1 TB of I/O daily for one dashboard. Group by query text to surface these patterns:

```sql
SELECT
  q.query,
  COUNT(*)                                              AS run_count,
  ROUND(AVG(t_agg.input_gb), 2)                         AS avg_input_gb,
  ROUND(COUNT(*) * AVG(t_agg.input_gb), 1)              AS total_gb_per_period
FROM system.runtime.queries q
JOIN (
  SELECT query_id, SUM(physical_input_bytes) / 1e9 AS input_gb
  FROM system.runtime.tasks
  GROUP BY query_id
) t_agg ON q.query_id = t_agg.query_id
WHERE q.state = 'FINISHED'
GROUP BY q.query
HAVING COUNT(*) > 10
ORDER BY total_gb_per_period DESC
LIMIT 20;
```

The `HAVING COUNT(*) > 10` filter excludes one-off ad-hoc queries; you want the *patterns* worth optimizing (e.g., a dashboard widget refreshing every 30 seconds). The `total_gb_per_period` column gives you the total work the cluster did for each query pattern over the visible window — that's the number to attack with a cache or rollup table.

### CRITICAL — `system.runtime.*` is EPHEMERAL

> **`system.runtime.queries` and `system.runtime.tasks` are in-memory views that live ONLY on the running coordinator process.** Every coordinator restart wipes them clean. The retention window is also bounded by `query.max-history` (default 100 queries) and `query.min-expire-age` (default 15 min) — queries are eligible for eviction once they exceed `query.min-expire-age` AND when `query.max-history` is exceeded, not strictly 15 minutes. There is no "6-month query history" available from `system.runtime.*`.
>
> For any historical analysis longer than a few hours — cost retrospectives, monthly tenant chargebacks, "what was that slow query last Tuesday?" forensics — you MUST configure a **Trino event listener** to persist `QueryCompletedEvent` records to durable storage. Trino ships with **four** built-in event listener plugins (verified against trino.io/docs/current/admin/event-listeners.html):
>
> - **HTTP event listener** (`event-listener.name=http`) — POSTs each `QueryCompletedEvent` as JSON to a configured HTTP endpoint. Good for shipping to an external collector (your logging stack, an internal API, a custom ingestion service).
> - **Kafka event listener** (`event-listener.name=kafka`) — publishes events to a Kafka topic. Best for high-throughput multi-coordinator setups; downstream Spark Structured Streaming consumers can land the events directly in an Iceberg observability table.
> - **MySQL event listener** (`event-listener.name=mysql`) — writes each event as a row into a MySQL database. Useful when you already operate MySQL and want SQL-queryable history without standing up Kafka.
> - **OpenLineage event listener** (`event-listener.name=openlineage`) — emits OpenLineage events for column-level lineage tracking. Useful if your org already runs Marquez or another OpenLineage backend.
>
> **There is NO built-in "file" event listener in Trino.** A common misconception is that `event-listener.name=file` ships out of the box and writes JSONL to local disk; it does not exist. The four plugins listed above are the only built-in choices. For local-disk JSONL output you would either (a) point the HTTP listener at a sidecar collector (e.g., Fluent Bit, Vector) that lands the events on disk, or (b) write a **custom event listener plugin** (`io.trino.spi.eventlistener.EventListenerFactory`) — a serious undertaking, not a config-only fix.
>
> Configure in `etc/event-listener.properties` on the coordinator (one file per listener; you can stack multiple by listing several `event-listener.config-files` paths in `config.properties`). Required for any non-trivial cost or performance retrospective work — without it, you can only see the last ~100 queries from `system.runtime.queries` before they're evicted.
>
> **CRITICAL — property prefix uses a hyphen, NOT a dot.** Each listener's properties use `<name>-event-listener.*` (hyphen), not `<name>.event-listener.*` (dot). Using the wrong delimiter causes Trino to reject the config file at startup with "configuration property not used" errors:
>
> ```properties
> # etc/http-event-listener.properties
> event-listener.name=http
> http-event-listener.connect-ingest-uri=http://audit-collector:8080/events   # hyphen, NOT http.event-listener.*
> http-event-listener.log-completed=true
> http-event-listener.log-created=false
>
> # etc/kafka-event-listener.properties
> event-listener.name=kafka
> kafka-event-listener.broker-endpoints=kafka1:9092,kafka2:9092              # NOT kafka.bootstrap.servers
> kafka-event-listener.completed-event.topic=trino-completed-queries          # NOT kafka.event-listener.topic
>
> # etc/mysql-event-listener.properties
> event-listener.name=mysql
> mysql-event-listener.db.url=jdbc:mysql://mysql-host:3306/trino_audit?user=u&password=p  # NOT mysql.event-listener.connection-url
> # NOTE: MySQL listener writes to a hard-coded table named `trino_queries` — the table name is NOT configurable.
> ```
>
> Register the listener file in `etc/config.properties`:
> ```properties
> event-listener.config-files=etc/http-event-listener.properties
> ```
>
> See the [Trino event listener docs](https://trino.io/docs/current/admin/event-listeners.html) for the full property reference. Once persisted, point your downstream pipeline at an Iceberg table (e.g., `iceberg.observability.trino_queries`) and rerun Recipes 1–2 above against the persistent table instead of `system.runtime.*`.

### Immediate remediation — kill a runaway query

Once a monitoring query identifies a single runaway (a query consuming most of cluster CPU/IO, blocking the queue, or stuck in `RUNNING` state for hours), you do not need to wait for it to finish or restart the cluster. Trino exposes a system procedure that cancels a specific query by ID:

```sql
-- Cancel a single runaway query identified from system.runtime.queries.
-- Use the query_id column value (string like '20260525_143012_00042_abcde').
CALL system.runtime.kill_query(query_id => '20260525_143012_00042_abcde');

-- Optional: include a message that will appear in the rejected query's
-- error metadata, so the user / dashboard owner understands why it died.
CALL system.runtime.kill_query(
  query_id => '20260525_143012_00042_abcde',
  message  => 'Killed by oncall — scanning entire fact table without partition filter'
);
```

**What this does:** the coordinator marks the query as `FAILED`, sends a cancel signal to every worker running the query's tasks, frees the memory and CPU slots, and unblocks any queued queries waiting for resources. The killed user sees an error in their client (the message you supplied, if any).

**What it does NOT do:** it does not blacklist the user, the SQL, or the source. The user can re-submit the same query immediately. Pair `kill_query` with a resource-group rule change (per-user concurrency cap, per-source memory limit) or a direct conversation with the dashboard owner — otherwise the same runaway re-spawns within minutes.

**Permissions:** the calling user needs the `kill_query` system privilege. In a hardened setup (the production stack uses OPA), this is typically granted only to the oncall service account or to users in an `sre-oncall` group via an OPA policy rule; regular analysts cannot kill arbitrary queries.

**Common oncall sequence:**

```sql
-- 1. Find the runaway (e.g., a query that's been RUNNING > 30 min and is scanning the most bytes).
--    NOTE: q."user" must be DOUBLE-QUOTED — `user` is a Trino reserved word; bare `user`
--    parses as the current-user keyword and the query fails with a syntax error.
SELECT
  q.query_id, q."user", q.source, q.query,
  date_diff('minute', q.started, current_timestamp) AS running_min,
  SUM(t.physical_input_bytes) / 1e9 AS gb_scanned_so_far
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.state = 'RUNNING'
  AND q.started < current_timestamp - INTERVAL '30' MINUTE
GROUP BY q.query_id, q."user", q.source, q.query, q.started
ORDER BY gb_scanned_so_far DESC;

-- 2. Kill it.
CALL system.runtime.kill_query(
  query_id => '<query_id from step 1>',
  message  => 'Killed — exceeded 30 min runtime, scanning <N> GB without filter'
);

-- 3. Verify it's gone.
SELECT query_id, state, error_code FROM system.runtime.queries
WHERE query_id = '<query_id>';
-- state should now be 'FAILED' with an error_code indicating user-initiated cancellation.
```

This is the fastest way to restore cluster health when a single bad query is starving everyone else. Use it before reaching for cluster restart, worker scaling, or resource-group reconfiguration — those are appropriate for sustained issues, not for one bad query.

### What does "cost" mean on an on-prem stack?

Translation table for engineers used to cloud $/TB-scanned thinking:

| Cloud cost concept | On-prem (your stack) equivalent |
|---|---|
| BigQuery $/TB scanned | k8s vCPU-hours consumed by the Trino worker pods scanning that data |
| Snowflake warehouse credits | k8s RAM-GB-hours held by Trino workers (capacity reserved 24/7) |
| Auto-suspend savings | Scaling Trino workers down at night via k8s HPA (still need ≥1 for stragglers) |
| Per-user spend cap | Trino resource groups: per-tenant concurrency and memory caps |
| S3 GetObject cost | MinIO disk IOPS budget + on-prem network bandwidth between Trino and MinIO |
| Query timeout / spend brake | `query.max-execution-time`, `query.max-memory-per-node`, resource group `softMemoryLimit` |

The marginal dollar cost of one extra query on already-provisioned k8s + MinIO is effectively zero. What you actually pay is **k8s capacity reservation** (CPU/RAM the Trino pods hold) and **queueing latency** (when concurrent queries exceed worker capacity, the slow-feeling experience for everyone). Optimize for the second one: a query that's "free" but blocks 20 other queries for 5 minutes still has a real cost.

---

## Step 2: Determine if it's one query or all queries

**One specific query regressed**: Go to step 3 (file/partition analysis).

**All queries are slower**: Usually concurrency, memory pressure, or infrastructure change (new Kubernetes node, MinIO capacity, network). Check Trino worker health in the UI and verify MinIO is responding.

---

## Step 3: Run EXPLAIN ANALYZE on the slow query

```sql
EXPLAIN ANALYZE
SELECT tenant_id, COUNT(*) AS events
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

> **Note**: `EXPLAIN ANALYZE` **actually executes the query** to collect runtime stats — re-running a slow production query has the same resource cost as the original (full I/O, full CPU, full memory pressure on workers). For plan-only inspection without executing, use `EXPLAIN (TYPE DISTRIBUTED)` instead — it shows the fragment graph, exchange types, and join order without touching any data. Reserve `EXPLAIN ANALYZE` for queries you're willing to pay the cost of re-running (i.e., already-fast queries you want to characterize, or a slow query you're actively debugging and accept will burn cluster resources again).
>
> ```sql
> -- Plan only — cheap, does not execute the query.
> EXPLAIN (TYPE DISTRIBUTED)
> SELECT tenant_id, COUNT(*) AS events
> FROM iceberg.analytics.feature_usage
> WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
> GROUP BY tenant_id;
> ```

### What to look for

> **Field-name reality check (Trino 467).** Default `EXPLAIN ANALYZE` does **not** print a `Files:` line and does **not** have a `Wall time` field. Those names commonly show up in incorrect guides — using them in a real diagnosis will leave you searching for fields that aren't there. The actual fields on each operator are shown below.

A real Trino `EXPLAIN ANALYZE` operator block looks roughly like this (abbreviated):

```
Fragment 1 [SOURCE]
    CPU: 12.34s, Scheduled: 45.67s, Blocked: 30.12s (Input: 28.50s, Output: 1.62s)
    Input: 12500000 rows (450MB), Physical Input: 2.10GB
    ScanFilterProject[table = iceberg:analytics.feature_usage$data, ...]
        Input: 12500000 rows (450MB), Physical Input: 2.10GB
        CPU: 8.12s, Scheduled: 40.05s, Blocked: 29.80s
```

The fields you actually care about, and what each one tells you:

| Field | What it means | When it points to a problem |
|---|---|---|
| `CPU:` | Total CPU compute time across all workers for this operator | High CPU with low `Scheduled:` gap → compute-bound (heavy joins/aggregations) |
| `Scheduled:` | Total wall-clock time the operator was scheduled on workers | Use this (not "Wall time" — no such field exists) for end-to-end operator time |
| `Blocked: Input` / `Blocked: Output` | Time the operator spent waiting on upstream input or downstream output | High `Blocked: Input` → waiting on storage/upstream; high `Blocked: Output` → downstream backpressure |
| `Input:` | Logical rows and uncompressed size read by the operator | Compare to a known-good baseline; if it jumped 100x, a filter disappeared |
| `Physical Input:` | Actual bytes read from MinIO (compressed Parquet) | The right metric for "are we scanning too much from storage?" — this is where partition-pruning failures show up first |

**Compute-bound vs I/O-bound (the replacement for the old "Wall vs CPU" rule):**

- `Scheduled:` ≈ `CPU:` → **compute-bound**. Filters, joins, aggregations are the bottleneck. Look at join order, predicate pushdown, pre-aggregation.
- `Scheduled:` >> `CPU:` (e.g., 5–10x) → **I/O-bound** (worker is spending most of its scheduled time blocked, not computing). Either reading too many files, too many small files (metadata overhead), or MinIO is slow. Cross-check by looking at `Blocked: Input` and `Physical Input:`.

**Checking how many files were opened — NOT via default `EXPLAIN ANALYZE`.**

The default `EXPLAIN ANALYZE` does not surface per-split file counts. The file/manifest counters (`dataFiles`, `dataManifests`) are Iceberg split-source metrics that only appear under `EXPLAIN ANALYZE VERBOSE`. Two reliable options:

```sql
-- Option A: EXPLAIN ANALYZE VERBOSE — look in the Iceberg connector
-- split-source section for `dataFiles` and `dataManifests` counters.
EXPLAIN ANALYZE VERBOSE
SELECT tenant_id, COUNT(*) AS events
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;

-- Option B: query the $files metadata table directly — works without
-- re-running the query and gives you a precise file count per partition spec.
SELECT spec_id, COUNT(*) AS file_count
FROM iceberg.analytics."feature_usage$files"
GROUP BY spec_id;
```

For day-to-day partition-pruning diagnosis, **`Physical Input:` from default `EXPLAIN ANALYZE` is usually enough**: if it shows 50 GB read for a query that should touch one day of data, pruning is broken regardless of the exact file count. Reach for `EXPLAIN ANALYZE VERBOSE` or `$files` when you specifically need to confirm a small-files problem (many files, low avg size) vs a wrong-filter problem (few files, large bytes per file).

**Interpreting `Physical Input:` for partition pruning:**

| Physical Input | What it means |
|---|---|
| ~1 day's worth × 90 (e.g., a few GB total) | Good — partition pruning working |
| ~100 GB on a query that should hit 90 days of one tenant | Bad — full table scan, partition pruning broken (filter on non-partition column?) |
| Reasonable bytes but high `Blocked: Input` and slow query | Possibly small-files problem — confirm via `$files` or `VERBOSE` |

If `Physical Input:` is much higher than expected: the WHERE clause isn't filtering on a partition column. See step 4.

### `EXPLAIN TYPE IO` and `EXPLAIN TYPE VALIDATE` — the two other EXPLAIN variants you should know

> **One-sentence summary:** `EXPLAIN (TYPE DISTRIBUTED)` is the everyday plan-only inspector you already know; **`EXPLAIN (TYPE IO, FORMAT JSON)`** answers "which tables/columns/partitions will this query touch and what predicates will hit them" (impact analysis without running the query); **`EXPLAIN (TYPE VALIDATE)`** answers "does this query parse and resolve against the catalog without executing" (a cheap pre-flight check). **Verified against [Trino EXPLAIN docs](https://trino.io/docs/current/sql/explain.html).**

The full set of `EXPLAIN TYPE` modes in Trino 467:

| Type | What it does | When to reach for it |
|---|---|---|
| `TYPE LOGICAL` | **DEPRECATED** per [trino.io/docs/current/sql/explain.html](https://trino.io/docs/current/sql/explain.html) (slated for removal in a future Trino release). Single-fragment plan tree (pre-distribution). Concise but doesn't show exchange boundaries. | **Do not use in new code.** Use `TYPE DISTRIBUTED` (the everyday default below) for join-order and predicate-placement inspection instead. |
| `TYPE DISTRIBUTED` (the everyday one) | Multi-fragment plan with exchange operators and distribution choices. Shows REPARTITION vs REPLICATE, dynamic filter wiring, predicate pushdown signatures. | Default plan-only inspection. Use 90% of the time. |
| `TYPE IO, FORMAT JSON` | JSON describing the input/output tables, columns accessed, column-level constraints (predicates pushed down), and estimated row counts per table scan. | **Impact analysis** — "what does this query touch?" Useful for change-impact review before running an unknown query on prod, for governance audits (which columns will the query read?), and for catalog observability. |
| `TYPE VALIDATE` | Returns a single boolean column `Valid`. Parses the SQL, resolves identifiers against the catalog, and confirms the query plans — without executing. Errors out on missing tables, type mismatches, or unresolvable references. | **Pre-flight check** — validate a generated SQL string (e.g., from a templating engine, BI tool, or user input) before exposing it to the cluster. Cheaper than `EXPLAIN DISTRIBUTED` because the optimizer doesn't have to produce a full plan. |

**`EXPLAIN (TYPE IO, FORMAT JSON)` — worked example.**

```sql
EXPLAIN (TYPE IO, FORMAT JSON)
SELECT tenant_id, SUM(amount)
FROM iceberg.analytics.orders
WHERE order_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
  AND tenant_id = 'acme'
GROUP BY tenant_id;
```

Returns a JSON object that looks (abbreviated) like:

```json
{
  "inputTableColumnInfos": [{
    "table": {
      "catalog": "iceberg",
      "schemaTable": {"schema": "analytics", "table": "orders"}
    },
    "columnConstraints": [
      {
        "columnName": "order_date",
        "type": "date",
        "domain": {
          "nullsAllowed": false,
          "ranges": [{"low": {"value": "2026-05-01", "bound": "EXACTLY"},
                      "high": {"value": "2026-05-31", "bound": "EXACTLY"}}]
        }
      },
      {
        "columnName": "tenant_id",
        "type": "varchar",
        "domain": {
          "nullsAllowed": false,
          "ranges": [{"low": {"value": "acme", "bound": "EXACTLY"},
                      "high": {"value": "acme", "bound": "EXACTLY"}}]
        }
      }
    ],
    "estimate": {"outputRowCount": 1.4E6, "outputSizeInBytes": 4.2E7}
  }],
  "outputTable": null
}
```

**Reading this output:**
- `inputTableColumnInfos[].table` — the tables this query will read. **Impact analysis: what does this query touch?** For an unknown query you've been asked to review, this is the fastest way to confirm it doesn't accidentally scan a sensitive table.
- `columnConstraints[].domain` — the predicates that Trino has resolved into ranges. **The presence of a `domain` with `EXACTLY` bounds confirms predicate pushdown** at plan time. If a predicate you wrote does NOT appear here, it didn't push down — Trino will filter on the worker side instead of asking the connector to filter.
- `estimate.outputRowCount` — CBO estimate of how many rows this table scan will produce after the predicates apply. Compare to the table's total row count to gauge selectivity.
- `outputTable` — null for `SELECT`; populated for `INSERT` / `CREATE TABLE AS` to show the write target.

**`EXPLAIN (TYPE VALIDATE)` — worked example.**

```sql
-- Valid query — returns Valid: true.
EXPLAIN (TYPE VALIDATE)
SELECT tenant_id, COUNT(*)
FROM iceberg.analytics.orders
WHERE order_date >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY tenant_id;
-- Result: a single column 'Valid' with value 'true'.

-- Invalid query — errors at validation, not execution.
EXPLAIN (TYPE VALIDATE)
SELECT tnant_id, COUNT(*)            -- typo: 'tnant_id' not 'tenant_id'
FROM iceberg.analytics.orders
GROUP BY tnant_id;
-- Result: error 'Column tnant_id cannot be resolved'.
```

**Why this is cheap.** `TYPE VALIDATE` stops after parse + identifier resolution + type checking — it does NOT produce a distributed plan, does NOT run the CBO, does NOT touch any data. On a query that takes 2 seconds to `EXPLAIN DISTRIBUTED`, `EXPLAIN VALIDATE` returns in < 50 ms.

**When to use each in practice:**

| Scenario | Reach for |
|---|---|
| "Why is this query slow?" — performance debugging | `EXPLAIN ANALYZE` (runs the query) or `EXPLAIN (TYPE DISTRIBUTED)` (plan only) |
| "Does this generated SQL even parse?" — before submitting templated SQL to the cluster | `EXPLAIN (TYPE VALIDATE)` — fastest sanity check |
| "What tables/columns does this query touch?" — impact analysis, governance, change review | `EXPLAIN (TYPE IO, FORMAT JSON)` — answers via the `inputTableColumnInfos` array |
| "Did my predicate push down?" — pushdown debugging | `EXPLAIN (TYPE DISTRIBUTED)` (look for `constraint=` on TableScan) AND/OR `EXPLAIN (TYPE IO, FORMAT JSON)` (look for `domain` ranges in `columnConstraints`) |
| "Will this query hit a sensitive column?" — pre-submit access-control review | `EXPLAIN (TYPE IO, FORMAT JSON)` — explicit list of accessed columns |

**Format options for `TYPE IO`:** the EXPLAIN grammar accepts `FORMAT { TEXT | GRAPHVIZ | JSON }` in general, but [Trino's EXPLAIN docs](https://trino.io/docs/current/sql/explain.html) **only document and exemplify `TYPE IO` with `FORMAT JSON`** — the `inputTableColumnInfos` / `columnConstraints` / `domain` structure described above only comes back in JSON form, which is what makes `TYPE IO` useful for predicate-pushdown verification and impact analysis. Treat `EXPLAIN (TYPE IO, FORMAT JSON) <query>` as the canonical form and write it exactly. Do not rely on `FORMAT TEXT` for `TYPE IO` — even if the grammar accepts it, the output is not documented and may not produce the structured fields you need.

> **`EXPLAIN (TYPE IO, FORMAT JSON)` IS the canonical predicate-pushdown verification tool at plan time.** When an engineer asks "did my WHERE predicate push down to the Iceberg connector without me running the query?", the answer is: run `EXPLAIN (TYPE IO, FORMAT JSON)` and look for the predicate's column in `inputTableColumnInfos[].columnConstraints[]` with a `domain.ranges[]` entry containing your literal bounds. If the column appears with a domain → **pushed down at plan time, no scan**. If the column is missing from `columnConstraints` but appears in your SQL → **the predicate did NOT push down**; Trino will filter on the worker side after scanning all rows. Contrast with `EXPLAIN ANALYZE`, which is the runtime-confirmation tool but actually executes the query (full scan, full cost). TYPE IO is **cheap** (no scan, no execution — just the CBO walking the plan) and is the right first step before reaching for `EXPLAIN ANALYZE`.

### GUARDRAIL — Trino EXPLAIN pushdown signature (Trino terms only; do NOT borrow Spark Catalyst terminology)

> **One-sentence summary.** Trino's predicate-pushdown EXPLAIN signature is a `constraint = {...}` annotation **INSIDE** the `TableScan` node (pushed) versus a separate `Filter` or `ScanFilterProject` operator **ABOVE** the `TableScan` (NOT pushed, filtered in Trino). **Verified per [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html) + [trino.io/docs/current/sql/explain.html](https://trino.io/docs/current/sql/explain.html).**
>
> **Q-pattern matchers this section answers:**
> - "How do I tell from Trino EXPLAIN output whether my WHERE predicate pushed to PostgreSQL / Iceberg / MySQL?"
> - "How do I read Trino EXPLAIN to verify predicate pushdown?"
> - "Where do I see pushdown info in a Trino plan?"

**The two signatures, side by side.**

```text
-- PUSHED — TableScan has constraint = {...} annotation INSIDE the node.
-- No Filter / ScanFilterProject operator sits above it.
Fragment 1 [SOURCE]
    Output layout: [...]
    Output partitioning: SINGLE []
    TableScan[table = postgresql:public.users
              constraint = {customer_id = 12345}]
        Layout: [customer_id:bigint, email:varchar, ...]
        customer_id := customer_id:bigint
        email      := email:varchar
```

```text
-- NOT PUSHED — a Filter operator sits ABOVE the TableScan, applying
-- the predicate on Trino workers after pulling rows from the source.
Fragment 1 [SOURCE]
    Output layout: [...]
    Output partitioning: SINGLE []
    Filter[customer_id = 12345]
        TableScan[table = postgresql:public.users]
            Layout: [customer_id:bigint, email:varchar, ...]
```

`ScanFilterProject[...]` (a fused operator that combines scan + filter + projection) above a TableScan-equivalent node also indicates Trino is doing the filtering itself — same diagnosis as a bare `Filter`. The presence of either operator above the scan means the predicate **did not** push down; the data source is being asked for all rows and Trino is filtering after.

**Read-the-plan checklist:**

1. Locate the `TableScan` (or scan-equivalent) node for the source table named in your WHERE clause.
2. Is there a `constraint = {...}` (or `predicate = {...}` on older grammars) inside that node mentioning the column from your WHERE? → **pushed.**
3. Is there a separate `Filter[...]` or `ScanFilterProject[...]` operator sitting on top of that TableScan, referencing your WHERE column? → **NOT pushed.** Trino is filtering after pulling rows from the source.
4. Both can co-exist when the WHERE has multiple predicates and only some are pushable — read the predicate references in each node, not just the operator names.

> **DO-NOT-WRITE — cross-engine EXPLAIN terminology CAUTION.** When reading **Trino** EXPLAIN output, **DO NOT** write or look for:
> - `PushedFilters: [...]`
> - `PostScanFilters: [...]`
> - `PartitionFilters: [...]`
> - `DataFilters: [...]`
>
> **These are SPARK Catalyst / DataSourceV2 EXPLAIN field names** (from `org.apache.spark.sql.connector.read.SupportsPushDownFilters` and Spark's `FileScan` operator). They DO NOT appear anywhere in Trino EXPLAIN output at any release. A reader who greps a Trino EXPLAIN plan text for `PushedFilters` or `PostScanFilters` will find nothing and conclude either that pushdown is broken or that the answer doesn't apply to their cluster — both wrong conclusions caused by wrong-engine terminology.
>
> Spark uses `PushedFilters` because Catalyst tracks a JVM list of pushed `Filter` objects on the `FileScan` / JDBC scan node. Trino uses an entirely different mechanism: `ConnectorMetadata.applyFilter(...)` returns a `TupleDomain<ColumnHandle>` that the planner attaches as the `constraint` annotation inside the `TableScan` node. The wire-level concepts (push a predicate to the source) are similar; the EXPLAIN output is unrelated.
>
> Trino EXPLAIN pushdown vocabulary you CAN write: `TableScan`, `constraint = {...}`, `predicate = {...}`, `Filter[...]`, `ScanFilterProject[...]`, `inputTableColumnInfos`, `columnConstraints`, `domain`. That is the complete list.

### GUARDRAIL — Validate or preview a query WITHOUT executing it (TYPE VALIDATE + TYPE IO)

> **Q-pattern matchers this section answers:**
> - "How can I cheaply validate a Trino SQL statement without executing it?"
> - "How do I check whether a generated SQL string is syntactically valid before running it?"
> - "How can I preview what a query will scan / what tables and columns it will touch without running it?"
> - "How do I validate templated SQL from dbt / a BI tool / user input before submitting to the cluster?"
> - "Is there a Trino built-in syntax checker?"

**The canonical two-tool answer:**

| You want to ... | Use | What it returns | Does it execute? |
|---|---|---|---|
| Check the SQL parses + identifiers resolve + types check | `EXPLAIN (TYPE VALIDATE) <query>` | Single boolean column `Valid` (value `true` on success; an error message surfaces parser/analyzer failure) | **NO** — no plan produced, no data touched |
| Preview which tables, columns, and predicate domains a query will scan | `EXPLAIN (TYPE IO, FORMAT JSON) <query>` | JSON document with `inputTableColumnInfos[]` (table + columnConstraints + per-column `domain`) | **NO** — CBO walks the plan only |

Both are verified per [trino.io/docs/current/sql/explain.html](https://trino.io/docs/current/sql/explain.html).

> **DO-NOT-WRITE — anti-claims and anti-patterns on validation/preview.**
>
> 1. **DO NOT WRITE: "Trino has no built-in syntax-checker."** That claim is **WRONG.** `EXPLAIN (TYPE VALIDATE)` **IS** the built-in syntax + semantic checker. It validates parser + identifier resolution + type checking without executing, returning a single boolean `Valid` column. It is the canonical answer to "is this SQL valid before I run it?"
> 2. **DO NOT WRITE: "Trino has no syntax checker outside of EXPLAIN parsing."** Same problem — TYPE VALIDATE is documented, supported, and canonical.
> 3. **DO NOT RECOMMEND `SELECT ... LIMIT 1` as a cheap validation alternative.** `LIMIT 1` **EXECUTES the query** (it just stops after one row is returned to the client); Trino still plans, dispatches splits to workers, opens connections to source connectors, scans data, and runs joins. The engineer who follows this advice pays real query cost on every "cheap" validation — and a query that fails on row two (e.g., a divide-by-zero, a type-coercion overflow) will pass the LIMIT 1 test and still fail in production. `LIMIT 1` is **NOT** validation.
> 4. **DO NOT WRITE: "Trino has no preview tool — you have to run the query."** That claim is **WRONG.** `EXPLAIN (TYPE IO, FORMAT JSON)` IS the canonical preview-what-will-it-scan tool. It returns the `inputTableColumnInfos` array describing every table the query will read, with per-column `domain` constraints showing exactly which value ranges Trino will request. No execution, no scan, no cost — just the CBO walking the logical plan and the connector returning the constraint shape.

**Worked example — validate a templated SQL string from dbt before submitting.**

```sql
-- Generated by a Jinja template; you want to confirm it parses against the catalog.
EXPLAIN (TYPE VALIDATE)
SELECT tenant_id,
       SUM(amount) AS revenue
FROM   iceberg.analytics.orders
WHERE  order_date >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY tenant_id;

-- Result: a single column 'Valid' with value 'true' if everything resolves.
-- If the template produced a typo'd column or unknown table, the statement
-- errors out at validation (cheap; no execution).
```

**Worked example — preview which tables/columns/predicates a query will touch.**

```sql
EXPLAIN (TYPE IO, FORMAT JSON)
SELECT tenant_id, SUM(amount)
FROM   iceberg.analytics.orders
WHERE  tenant_id = 'acme'
  AND  order_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
GROUP BY tenant_id;

-- Returns a JSON document with inputTableColumnInfos[] listing the
-- (catalog, schema, table), the columnConstraints with per-column
-- 'domain' ranges (your literal bounds appear here when pushed down),
-- and an estimate.outputRowCount from the CBO. No data is scanned.
```

**Pre-flight wrapper pattern (validate THEN preview):**

```sql
-- 1. Cheapest sanity check first: does the SQL even parse + resolve?
EXPLAIN (TYPE VALIDATE) <query>;

-- 2. If TYPE VALIDATE returned Valid=true, preview the IO impact.
EXPLAIN (TYPE IO, FORMAT JSON) <query>;

-- 3. Only after both pass, run the query for real (or run EXPLAIN ANALYZE
--    on a known-fast variant for performance characterization).
```

This three-step ladder is the canonical "validate generated SQL without paying execution cost" pattern. `LIMIT 1` is NOT on this ladder — it executes.

---

## Step 4: Check partition pruning

### Verify the table's partition spec

```sql
SHOW CREATE TABLE iceberg.analytics.feature_usage;
```

Look for the `partitioning` clause. Example of well-partitioned table:
```
partitioning = ARRAY['day(event_date)', 'tenant_id']
```

**If there's no partitioning clause**: the table is unpartitioned. Every query scans every file. This needs a table rebuild with partitioning.

### Verify the WHERE clause uses partition columns

| Filter | Result |
|---|---|
| `WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY` | Prunes to 90 day-partitions |
| `WHERE tenant_id = 'acme'` (with tenant_id partition) | Prunes to acme files only |
| `WHERE feature_name = 'invite'` (non-partition column) | Full table scan |
| No WHERE clause | Full table scan |

**Common regression trigger**: a WHERE clause that previously filtered the **partition column** gets changed to filter a **different (derived or non-partition) column**. Example: if the table is partitioned on `event_date` but the filter switches to `WHERE DATE(event_time) = CURRENT_DATE` (a *different* column, `event_time`), the predicate constrains `event_time`, not the `event_date` partition, so the `event_date` partitions are not pruned. The culprit is the **column mismatch**, NOT the `DATE()` wrap itself — wrapping the *same* partition column in `DATE()`/`CAST AS DATE`/`date_trunc('day',…)`/`year(…)` still prunes in Trino 467 (the Unwrap*InComparison rules; see [r07 §1](07-analytical-query-patterns.md#trino-467-reality)). Check that the filtered column matches the partition spec, and that any wrap on it is one of the auto-unwrapped temporal forms (not an opaque `LOWER`/`SUBSTR`/UDF/JSON wrap).

---

## Step 5: Check for partition / data skew — EXPLAIN ANALYZE `Input std.dev.`, one worker slow, one stage slow, uneven worker time, skewed join, skewed GROUP BY, salt the key (LEADING CANONICAL ONCALL WORKED EXAMPLE — read this FIRST when one stage / one worker is dragging the query)

> **Keyword anchors** (so this section is findable by the routing words): data skew, EXPLAIN ANALYZE skew, one worker slow, one stage slow, uneven worker/stage time, `Input std.dev.`, `Input avg.`, `Input rows distribution`, skewed join, skewed GROUP BY, whale tenant, salt the key, two-level GROUP BY, hot key, stragglers, p99 vs p50 gap, EXPLAIN ANALYZE VERBOSE skew.

> **The single tell — Trino 467 `EXPLAIN ANALYZE` data-skew indicator (verified at [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html)).** The per-operator field **`Input std.dev.`** — printed alongside **`Input avg.`** and expressed as a **percentage of the mean** across drivers/workers — IS the data-skew signal. Real outputs look like `Input avg.: 15.63 rows, Input std.dev.: 24.36%` (mild/healthy) vs `Input avg.: 15.63 rows, Input std.dev.: 793.73%` (extreme skew — one driver doing nearly all the work, the rest idle). **Rule of thumb:** `Input std.dev.` <30% is healthy; 30-80% is uneven worth investigating; >80% is genuine skew that's bottlenecking the stage. For deeper per-driver detail, **`EXPLAIN ANALYZE VERBOSE`** additionally prints the per-driver distributions (`Input rows distribution`, `CPU time distribution (s)`, `Scheduled time distribution (s)`) with percentile fields `count`, `p01`, `p05`, `p50`, `p99`, `min`, `max` — **a wide gap between `p99` and `p50` in `Input rows distribution` means the same thing: a few drivers are doing far more work than the median**. When you see a high `Input std.dev.` % on a `HashAggregation` or `HashBuilder`/`HashJoin` operator, the fix is below: **salt the hot key** (two-level GROUP BY for aggregation skew; `ON a.key=b.key AND a.salt=b.salt` for join skew). The worked salt-the-key example is in the **Fix 1** subsection below — read it.

Partition skew means one partition has far more data than others. Even with pruning working, a single oversized partition causes one Trino worker to do 100x the work of others. The same indicator (`Input std.dev.` on the relevant operator) catches GROUP BY skew and join skew too — see Fix 1 worked example below for the canonical salt-the-key remediation.

### How to detect skew

```sql
-- How many rows per partition?
SELECT
  event_date,
  tenant_id,
  COUNT(*) AS row_count
FROM iceberg.analytics.feature_usage
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY event_date, tenant_id
ORDER BY row_count DESC
LIMIT 20;
```

If one tenant_id has 200M rows and the others have 50K, that's 4,000x skew. All 200M rows land on one Trino worker; the others sit idle while that worker grinds.

### Detecting GROUP BY skew with EXPLAIN ANALYZE VERBOSE (per-driver distribution)

Default `EXPLAIN ANALYZE` aggregates stats across all drivers per operator, which **hides skew**: one driver doing 100x the work of others looks the same as evenly-distributed work because the totals are summed. To see per-driver distribution, you need `EXPLAIN ANALYZE VERBOSE`.

```sql
EXPLAIN ANALYZE VERBOSE
SELECT tenant_id, COUNT(*) AS event_count
FROM iceberg.analytics.feature_usage
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY tenant_id;
```

In the VERBOSE output, look at the **Aggregation** operator's per-driver stats — VERBOSE prints `inputRows`, `inputBytes`, `cpuTime`, and `wallTime` distributions across drivers (min / p50 / max). The telltale signs of GROUP BY skew:

| What you see | What it means |
|---|---|
| `inputRows` max ≈ 100x p50 across drivers on the Aggregation operator | One driver is processing the whale tenant; the rest finish quickly and idle. Classic whale-tenant skew. |
| `cpuTime` max >> p50 on Aggregation | Same — the skewed driver burns all the CPU; query wall time = the slowest driver's wall time. |
| `maxDriversPerTask` is low (e.g., 4) and you have skew | Even fewer drivers to spread work across. Bumping driver parallelism alone won't fix whale skew, but very low driver counts amplify the symptom. |
| Final aggregation has 1 driver but partial aggregation has N drivers | Expected — final aggregation merges partials at the coordinator. Skew problems live in the PARTIAL aggregation stage, not the FINAL. |

If the Aggregation operator's per-driver `inputRows` is roughly even (min ≈ p50 ≈ max), you do NOT have skew — go look elsewhere (compaction, partition pruning, concurrency). If max is 10-100x p50, you have skew and the fixes below apply.

### Fixes for skew

#### Fix 1 (primary fix for whale-tenant GROUP BY skew): two-level GROUP BY with a salt column

The canonical fix when one tenant dominates a GROUP BY is to **break that tenant's rows across N workers by adding a random salt**, aggregate first by `(tenant_id, salt)`, then merge the N partial results by `tenant_id`. The first aggregation distributes the whale's rows across N workers (no single worker holds them all); the second aggregation merges N partial counts per tenant, which is cheap because it's only N rows per tenant regardless of the tenant's row count.

```sql
-- Two-level GROUP BY: breaks whale-tenant skew at READ time.
-- Step 1: First-level aggregation with salt — distributes the whale across N workers.
WITH salted AS (
  SELECT
    tenant_id,
    CAST(FLOOR(RANDOM() * 8) AS BIGINT) AS salt,   -- 8 = number of worker buckets to spread across
    event_count
  FROM iceberg.analytics.feature_usage
  WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
),
partial AS (
  SELECT tenant_id, salt, COUNT(*) AS partial_count
  FROM salted
  GROUP BY tenant_id, salt                          -- N partial rows per tenant, distributed across workers
)
-- Step 2: Final aggregation merges the N partial counts per tenant. Cheap — only N rows per tenant.
SELECT tenant_id, SUM(partial_count) AS total_count
FROM partial
GROUP BY tenant_id;
```

**How to pick N (the salt cardinality):** N should roughly equal the number of Trino worker drivers available for the Aggregation stage. Too small (N=2) and you don't spread the whale enough; too large (N=1000) and the partial aggregation produces 1000 rows per tenant, which adds memory and shuffle overhead with no further skew benefit. Start with N = (number of workers × `task.concurrency`); typical values land at 8-32. Verify with `EXPLAIN ANALYZE VERBOSE` after — per-driver `inputRows` on the partial Aggregation operator should be roughly even.

**Works for SUM/COUNT/MIN/MAX (all algebraic aggregates).** For non-algebraic aggregates like `COUNT(DISTINCT col)` or `APPROX_DISTINCT`, the salt trick needs care — `SUM(partial_count)` over distinct-counts double-counts values that appear in multiple salt buckets. For exact distinct counts on whale tenants, use `approx_distinct(col)` (HyperLogLog-based, mergeable) at the partial level and merge with `approx_distinct` again at the final level, or fall back to fix 3 below (pre-aggregated rollup tables).

#### Fix 2: dedicated table for the whale tenant

For a single tenant that's persistently 100-1000x larger than others (an enterprise account, a noisy bot, etc.), the cleanest fix is to write that tenant to its own Iceberg table — `feature_usage_acme` — and route queries that filter on `tenant_id = 'acme'` to the dedicated table. The application or a thin SQL view picks the right table at query time. This trades schema complexity for fully-parallel scans on both the whale and the rest of the population. Best when there are only a handful of whales (≤5) and they're stable.

#### Fix 3: nightly pre-aggregated rollup

Build a daily rollup (one row per `tenant_id` × `event_date` × `feature_name`) via a nightly Spark job. Dashboards that ask "total events per tenant per day" then read 10K rows from the rollup instead of scanning 200M rows from the raw fact table. The whale stops being a hot path because the per-tenant rollup row is the same size regardless of how many events the tenant generated. Best for high-frequency dashboard queries where 5-15 minute staleness is acceptable. See `08-schema-design-for-analytics.md` for the rollup table pattern.

#### What about `bucket(tenant_id, N)` — does that fix GROUP BY skew? NO.

> **Critical clarification — bucket partitioning does NOT fix read-time GROUP BY skew.** A common (wrong) instinct is "we have one giant tenant, let's bucket the partition spec by `tenant_id` to spread it across files: `partitioning = ARRAY['day(event_date)', 'bucket(tenant_id, 64)']`." This does NOT solve whale-tenant GROUP BY skew, because Iceberg's `bucket()` transform **hashes each distinct value to exactly one bucket**. All rows for `tenant_id='acme'` still hash to the same bucket and still land on the same worker at GROUP BY time. The hash partitions the *set of tenants* across 64 buckets — not the rows of a single tenant.
>
> What `bucket(tenant_id, N)` actually achieves:
> - **WRITE side**: distributes write load across N buckets — useful when many tenants write concurrently and you want to spread ingestion across files (reduces small-files on writes, balances Spark task output).
> - **READ side, multi-tenant aggregation**: distributes the *scan* across workers when many tenants are queried together — e.g., a cross-tenant `GROUP BY plan_type` benefits because the 64 buckets read in parallel.
> - **READ side, whale tenant**: does NOTHING. One tenant's rows still hash to one bucket, so one worker still processes them at GROUP BY time.
>
> For the whale-tenant case, reach for **fix 1 (salt + two-level GROUP BY)**, **fix 2 (dedicated table)**, or **fix 3 (rollup)** — not bucketing.

#### Fix 4: bucket sub-partitioning when DATES are skewed (not tenants)

If the skew is on the time axis — one day has 10x the rows because of a product launch or campaign — adding a bucket sub-partition spreads each day's data across N parallel files. Here bucketing helps because the skew is in the cardinality of users-within-a-day (many users, not one whale), so `bucket(user_id, 100)` distributes them evenly:

```sql
-- Trino DDL: column-first bucket syntax.
ALTER TABLE iceberg.analytics.feature_usage
  SET PROPERTIES partitioning = ARRAY['day(event_date)', 'bucket(user_id, 100)'];
```

This splits each day's data into 100 equal buckets, enabling parallel reads when scanning a single day. Use this only when you have many users-per-day and the skew is at the day level, not when one tenant dominates.

> **ENGINE NOTE — `bucket()` argument order differs between Trino and Spark SQL.** The snippet above is **Trino syntax**, where the column comes first: `bucket(column, N)`. If you run the equivalent DDL in Spark SQL, the argument order is **reversed**: `bucket(N, column)` — e.g., `PARTITIONED BY (days(event_date), bucket(100, user_id))`. Same Iceberg transform on disk; different SQL spelling. Pasting Trino's column-first form into Spark (or vice versa) gives you a parse error.

> **Partition-spec changes are NOT retroactive.** `ALTER TABLE iceberg.analytics.feature_usage SET PROPERTIES partitioning = ARRAY['day(event_date)', 'bucket(user_id, 100)']` (the ONE Trino 467 form for partition evolution) changes how **NEW data** is written — existing historical files keep their **old partition layout**. Queries must handle both old and new layouts simultaneously, which means partition pruning won't behave the way it would on a freshly-loaded table. Until existing data is rewritten under the new spec, the skew you were trying to fix is only fixed for newly-written data; historical partitions remain skewed. **Note: `ALTER TABLE ... SET PARTITION SPEC (...)` is Spark/Iceberg-dialect syntax — it is NOT valid in Trino 467 and will parse-error. See [resource 17 § LEADING CANONICAL — Trino 467 Iceberg schema evolution](17-iceberg-table-maintenance.md) DO-NOT-WRITE matrix for the canonical partition-evolution forms.**
>
> A full `CALL iceberg.system.rewrite_data_files(table => 'analytics.feature_usage')` (Spark) — which uses the **current** spec — is needed to re-layout existing data under the new spec. Until that rewrite completes, queries that scan historical data will continue to see the old layout. Note also the Trino limitation called out in resource 17: Trino's `OPTIMIZE` cannot use newly-added partition columns as predicates, so post-partition-evolution rewrites must run via Spark.

---

## Step 6: Check data model

### Query complexity as the root cause

Complex queries — many JOINs, subqueries, window functions over large datasets — take more CPU and memory than simple aggregations.

**Signs:**
- EXPLAIN ANALYZE shows many fragments with exchanges between them.
- CPU time is high (not I/O-bound).
- The query involves 3+ table JOINs.

**Fixes:**
- **Denormalize**: pre-join dimension tables into a wide fact table so queries don't join at query time. (See `08-schema-design-for-analytics.md`.)
- **Pre-aggregate**: compute the expensive aggregation nightly and store results in a rollup table. The dashboard query reads 10 rows instead of 1B.
- **Simplify the join order**: Trino's query planner is good but sometimes benefits from explicit hints; the larger table should appear first in the FROM clause.

### Missing or wrong filters

A query that used to filter `WHERE plan_type = 'enterprise'` and now doesn't — or one where the filter column changed — will scan the entire fact table instead of a slice.

**How to catch**: Compare the EXPLAIN ANALYZE `Input:` rows (and `Physical Input:` bytes) from a recent successful run vs. today's run. If `Input:` jumped from 5M to 500M rows — or `Physical Input:` jumped from 2 GB to 200 GB — a filter disappeared.

---

## Step 7: Check for small files (compaction fell behind)

If compaction jobs haven't run:
- Nightly ingestion writes 300 tiny files per day (one per micro-batch or Spark partition).
- After 30 days without compaction: 9,000 files for a 30-day range query.
- Each file open has 10–50 ms metadata overhead.
- 9,000 files × 30 ms = 4.5 minutes just opening files, before reading any data.

### Diagnose small files

```sql
-- Snapshot summary shows file count and row count per snapshot.
-- On Trino's $snapshots metadata table, file/row counts live INSIDE the
-- summary map (a map(varchar, varchar)) — NOT as top-level columns.
-- The top-level columns are: committed_at, snapshot_id, parent_id,
-- operation, manifest_list, summary.
SELECT
  snapshot_id,
  committed_at,
  operation,
  summary['total-data-files'] AS total_data_files,
  summary['added-data-files'] AS added_data_files,
  summary['total-records']    AS total_records
FROM iceberg.analytics."feature_usage$snapshots"
ORDER BY committed_at DESC
LIMIT 5;

-- If you want per-manifest file counts (added/existing/deleted), query
-- $manifests instead — that metadata table DOES expose them as columns:
SELECT
  added_data_files_count,
  existing_data_files_count,
  deleted_data_files_count
FROM iceberg.analytics."feature_usage$manifests";
```

If `total_data_files_count` (from `$manifests`) — or `summary['total-data-files']` (from `$snapshots`) — is in the tens of thousands and the table isn't huge, compaction is needed.

For more granular small-files diagnosis, use the `$files` and `$partitions` metadata tables — they expose per-file and per-partition detail that snapshot-level summaries hide:

```sql
-- File-size distribution per partition: identifies WHICH partitions have many small files,
-- which is what you actually need to know to plan a targeted compaction.
SELECT
  partition,
  count(*)                                       AS file_count,
  avg(file_size_in_bytes) / 1024 / 1024          AS avg_file_mb,
  min(file_size_in_bytes) / 1024 / 1024          AS min_file_mb,
  max(file_size_in_bytes) / 1024 / 1024          AS max_file_mb
FROM iceberg.analytics."feature_usage$files"
GROUP BY partition
ORDER BY file_count DESC
LIMIT 20;

-- $partitions gives a partition-level summary including record_count, file_count,
-- and total_size — useful for spotting both file-count skew AND row-count skew at once.
SELECT
  partition,
  record_count,
  file_count,
  total_size / 1024 / 1024 AS total_size_mb
FROM iceberg.analytics."feature_usage$partitions"
ORDER BY file_count DESC
LIMIT 20;
```

This is much more actionable than the snapshot-level `total-data-files` summary key — instead of "the whole table has 47,000 files," you see "partition `event_date=2026-04-12, tenant_id='acme'` alone has 8,200 files averaging 0.4 MB each," which tells you exactly where to point `rewrite_data_files` with a `where` clause. Pair this with the per-tenant compaction pattern in resource 17 to fix the worst offenders first without rewriting the entire table.

### Fix: run compaction

Compaction must run in Spark (not Trino):

```python
# Submit via spark-submit or Airflow DAG
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
      table => 'analytics.feature_usage',
      options => map(
        'target-file-size-bytes', '268435456',
        'min-input-files', '5'
      )
    )
""")  # Spark SQL only — does not work in Trino
```

After compaction: 9,000 files collapses to ~45 files (256 MB each for a 10 GB partition). File open overhead drops from 4.5 minutes to 2 seconds.

### Verify compaction ran

Check the maintenance schedule: is the nightly compaction Kubernetes CronJob still running? Check the job logs:

```bash
kubectl get cronjobs -n data-platform
kubectl logs -l job-name=iceberg-compaction -n data-platform --since=24h
```

If the CronJob is failing silently, queries degrade over days as small files accumulate.

---

## Step 7b: Non-partition predicate is the bottleneck — Filter-above-TableScan + tightening min/max stats

A common variant of the residual-filter case: the WHERE clause filters on a **non-partition column** (e.g., `plan_type = 'enterprise'`), Iceberg's manifest min/max can't prune files because every file's range covers the wanted value, and `EXPLAIN ANALYZE` shows a Filter node above TableScan with a `physicalInputDataSize` much bigger than the post-filter row count would justify.

> **Lead with the truth.** A Filter node above TableScan is NOT itself a pushdown failure (see Common Myths #1). It is residual filtering. The question to answer is: **what does `physicalInputDataSize` look like compared to selectivity?** If a 0.1%-selective predicate reads 200 GB, you have a file-clustering problem (not a pushdown problem) — the column you're filtering on has overlapping min/max ranges across most files, so file-skipping can't help.

### Diagnose: `$files` lower_bounds / upper_bounds per-file

```sql
-- Verify per-file min/max for the predicate column.
-- If most files have (lower_bound='basic', upper_bound='enterprise'),
-- their ranges all overlap your filter value 'enterprise' — file-skipping
-- CANNOT help; you need to either re-cluster files OR add a bloom filter.
--
-- IMPORTANT: use readable_metrics (JSON, name-keyed) — NOT lower_bounds['plan_type'].
-- lower_bounds/upper_bounds are typed map(INTEGER, BIGINT) keyed by Iceberg
-- field id; a VARCHAR subscript fails Trino's analyzer.
-- See resources/10 § "LEADING CANONICAL — how to query $files.lower_bounds".
SELECT
  file_path,
  json_extract_scalar(readable_metrics, '$.plan_type.lower_bound') AS lo,
  json_extract_scalar(readable_metrics, '$.plan_type.upper_bound') AS hi,
  record_count,
  file_size_in_bytes / 1024 / 1024 AS size_mb
FROM iceberg.analytics."feature_usage$files"
WHERE content = 0
ORDER BY file_size_in_bytes DESC
LIMIT 20;
```

If most rows in the output have `lo = 'basic'` and `hi = 'enterprise'`, the column's values are uniformly distributed across files and min/max pruning cannot help.

### Fix recommendations — and which are available on Trino 467 (the production version)

> **READ THIS FIRST.** Several plausible-looking "set a Trino property" fixes for this case are **gated on Trino versions later than 467** and will fail with "unknown property" errors on prod. The table below lists each fix lever with its Trino-version availability so you don't recommend a fix that doesn't work on prod. Verified against [Trino 469 release notes](https://trino.io/docs/current/release/release-469.html) and [Iceberg Spark bloom-filter table properties](https://iceberg.apache.org/docs/latest/configuration/#write-properties).

> **ENGINE-CONFUSION GUARDRAIL (READ BEFORE COPYING ANY ROW BELOW).** The single most common iter-failure pattern when recommending a fix here is naming a **Spark `CALL iceberg.system.<proc>` procedure** as if it were a **Trino `ALTER TABLE ... EXECUTE` form**. Most recently, iter417 Q1 recommended `ALTER TABLE ... EXECUTE rewrite_data_files(sort_order => ARRAY[...])` on Trino 467 — that's Spark CALL named-arg syntax pasted into a Trino EXECUTE statement, which Trino 467 rejects with `Procedure not registered`. **The Trino 467 EXECUTE registry is exactly:** `optimize` (only `file_size_threshold` arg), `optimize_manifests` (Trino 470+, NOT 467), `expire_snapshots` (only `retention_threshold` arg on 467), `remove_orphan_files` (only `retention_threshold`), `drop_extended_stats`. **`rewrite_data_files`, `rewrite_position_delete_files`, `rewrite_manifests` are NOT in Trino's EXECUTE registry — they are Spark CALL procedures only.** See [resources/17 — Trino EXECUTE vs Spark CALL disambiguation matrix](17-iceberg-table-maintenance.md#trino-execute-procedures-vs-spark-call-procedures--the-engine-confusion-disambiguation-matrix-read-before-writing-any-procedure-call) for the full table. Below, the FIRST row is the Trino-467-native clustering recipe (no Spark hop needed); the Spark-CALL rows that follow are clearly marked as Spark-only.

| Fix lever | Available on Trino 467? | How to use |
|---|---|---|
| **Trino 467 native clustering** — `sorted_by` table property + `EXECUTE optimize`. THE Trino-only path. No Spark required for lexicographic single- or multi-column sort. | YES (Trino-native) | Two statements: `ALTER TABLE iceberg.analytics.feature_usage SET PROPERTIES sorted_by = ARRAY['plan_type ASC NULLS LAST', 'event_date ASC'];` then `ALTER TABLE iceberg.analytics.feature_usage EXECUTE optimize(file_size_threshold => '512MB');` (use a threshold larger than your largest existing file to force every file to rewrite for the initial sort migration). After the rewrite, verify with `$files` that `json_extract_scalar(readable_metrics, '$.plan_type.lower_bound') = json_extract_scalar(readable_metrics, '$.plan_type.upper_bound')` for most files (use `readable_metrics` JSON, NOT `lower_bounds['plan_type']` — see resources/10 § "LEADING CANONICAL — how to query $files.lower_bounds"). **WATCH OUT:** Trino's `sorted_by` is lexicographic only — does NOT support z-order; for that, drop to Spark (next row). |
| **Sort-strategy data rewrite (Spark)** — cluster files by the filter column via Spark CALL. Use when you need `rewrite-all => 'true'` (forces every file to rewrite regardless of size), or when you want Spark's richer tuning knobs. | YES (runs in Spark, not Trino) | `CALL iceberg.system.rewrite_data_files(table => 'analytics.feature_usage', strategy => 'sort', sort_order => 'plan_type ASC NULLS LAST', options => map('rewrite-all', 'true'))`. **This is Spark SQL only — do NOT paste into Trino as `ALTER TABLE ... EXECUTE rewrite_data_files(sort_order => ...)`; Trino 467 has no such procedure and will reject the statement.** After the rewrite, verify with `$files` that the new files have non-overlapping `(lower_bound, upper_bound)` ranges for `plan_type`. |
| **Z-order data rewrite (Spark)** — multi-column clustering when you filter on more than one non-partition column simultaneously (e.g., `plan_type AND region`). | YES (runs in Spark, not Trino) — **no Trino equivalent at any release**; Trino's `sorted_by` is lexicographic only. | `CALL iceberg.system.rewrite_data_files(table => 'analytics.feature_usage', strategy => 'sort', sort_order => 'zorder(plan_type, region)')`. **Spark SQL only.** |
| **Spark write-time bloom filter** — Spark writes Parquet bloom filter indexes per-file at write time; Trino 467 reads them at query time via its bloom-filter pushdown. THIS IS THE 467 BLOOM-FILTER PATH. | YES (write configured via Iceberg table properties on Spark; read happens automatically in Trino 467 with `parquet.use-bloom-filter=true`, the default) | Set the Iceberg table property in Spark: `ALTER TABLE iceberg.analytics.feature_usage SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.plan_type'='true')`. Then trigger a Spark `rewrite_data_files` so existing files are rewritten WITH bloom filters baked in. Subsequent Trino 467 queries with `WHERE plan_type = ...` get bloom-filter file-skipping for free. |
| **Trino `parquet_bloom_filter_columns` table property** — Trino-side write-time bloom filter config. | **PARTIAL on 467 — depends on CREATE vs ALTER.** `parquet_bloom_filter_columns` **IS** a valid Trino 467 Iceberg table property: **`CREATE TABLE ... WITH (parquet_bloom_filter_columns = ARRAY['plan_type'])` WORKS on 467** (new table / CTAS). What's 469+ is ONLY the **`ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns = ARRAY[...]`** form to add it to an EXISTING table ([PR #24573](https://github.com/trinodb/trino/pull/24573)) — that ALTER fails on 467. | **NEW table:** `CREATE TABLE ... WITH (parquet_bloom_filter_columns = ARRAY['plan_type'])` directly on 467. **EXISTING table on 467:** CTAS-rebuild into a new table with the WITH property (Trino-native, no Spark) and swap, OR use the Spark write-time row above. After upgrade to 469+, the in-place `ALTER SET PROPERTIES` + `EXECUTE optimize` becomes available. |
| **Schema redesign — re-partition by the filter column** (e.g., add `plan_type` to the partition spec) | YES — partition evolution is in-place via `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[..., 'plan_type']` | Best when the filter column has low cardinality (< 100 distinct values) and is filtered on most queries. High-cardinality filter columns would create too many partitions — use sort-strategy rewrite instead. See resource 10 (Lakehouse partitioning). |
| **Pre-aggregated rollup table** — for known dashboard queries, materialize the result so the dashboard reads K rows instead of scanning N billion. | YES (Trino + dbt or Spark) | See resource 25 (Trino materialized views) and resource 17 (rollup patterns). |
| **Trino native fs.cache** — caches Parquet blocks on worker local disk so repeated identical scans avoid MinIO round-trips. Does NOT fix the underlying selectivity problem, but speeds up repeated scans. | YES on Trino 467 | See Step 10 in this resource. |

> **Why parquet_bloom_filter_columns is version-gated and what you do on Trino 467.** Trino has **two** layers of bloom-filter support:
>
> 1. **Read-side (TRINO 467+)** — `parquet.use-bloom-filter=true` (catalog or session property, default `true`) makes Trino READ Parquet bloom filters that already exist in the files for filter pushdown at query time. This works on Trino 467 today, no upgrade needed.
> 2. **Write-side configuration via the `parquet_bloom_filter_columns` table property (CREATE works on TRINO 467; only the in-place ALTER is 469+)** — sets which columns Trino-side WRITES create bloom filters for. The property **IS valid on 467 at CREATE time**: `CREATE TABLE ... WITH (parquet_bloom_filter_columns = ARRAY['<col>'])` works (new table or CTAS-rebuild). What was added in **Trino 469** ([PR #24573](https://github.com/trinodb/trino/pull/24573)) is only the `ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns = ARRAY[...]` form to add it to an EXISTING table — THAT fails on 467 with "unknown table property" for the ALTER path. Do NOT say "the property is 469+ only" — say "the ALTER form is 469+; CREATE works on 467."
>
> For an EXISTING table on 467, the two paths are: **(Trino-native)** CTAS-rebuild — `CREATE TABLE t_new WITH (parquet_bloom_filter_columns = ARRAY['<col>']) AS SELECT * FROM t`, then swap (no Spark); OR **(Spark)** configure bloom filters at the Iceberg-table-property level: `ALTER TABLE iceberg.x.y SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.<col>'='true')`. Then run a Spark `rewrite_data_files` to bake bloom filters into existing files. Trino 467's read side then uses those bloom filters automatically. The Iceberg-spec table properties (`write.parquet.bloom-filter-enabled.column.<col>`, `write.parquet.bloom-filter-fpp.column.<col>`, `write.parquet.bloom-filter-max-bytes`) are honored by Spark's Iceberg writer ([Iceberg PR #5035](https://github.com/apache/iceberg/pull/5035)) — confirmed available on Iceberg 1.5.2 which is the prod ingestion version. See also the **Trino-version feature matrix in resource 17**, which is the canonical place for version-gated Trino-Iceberg features on this stack.

### Worked example — diagnose then fix on Trino 467

```sql
-- Step 1: confirm the residual filter on plan_type is the problem.
EXPLAIN ANALYZE
SELECT tenant_id, SUM(amount)
FROM iceberg.analytics.feature_usage
WHERE event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-07'
  AND plan_type = 'enterprise'
GROUP BY tenant_id;
-- Expected pattern: Filter[plan_type = 'enterprise'] sits ABOVE TableScan.
-- physicalInputDataSize on TableScan is much larger than what the final
-- output rows imply — confirms file-skipping isn't helping on plan_type.

-- Step 2: confirm per-file min/max for plan_type are too wide to prune.
-- Use readable_metrics (JSON, name-keyed); lower_bounds/upper_bounds are
-- integer-keyed (Iceberg field id), so a string subscript like
-- lower_bounds['plan_type'] is a Trino analyzer type error.
SELECT
  json_extract_scalar(readable_metrics, '$.plan_type.lower_bound') AS lo,
  json_extract_scalar(readable_metrics, '$.plan_type.upper_bound') AS hi,
  count(*) AS files,
  sum(file_size_in_bytes) / 1024 / 1024 / 1024 AS gb
FROM iceberg.analytics."feature_usage$files"
WHERE content = 0
GROUP BY 1, 2
ORDER BY files DESC;
-- If most rows show lo='basic', hi='enterprise', file-skipping cannot help
-- for plan_type — every file's range covers 'enterprise'.
```

```sql
-- Step 3-PREFERRED (Trino 467 native) — sorted_by + EXECUTE optimize.
-- No Spark hop required. Use this when you just need lexicographic clustering
-- by one or more columns and the table's files aren't all already maximally-sized.
ALTER TABLE iceberg.analytics.feature_usage
  SET PROPERTIES sorted_by = ARRAY['plan_type ASC NULLS LAST', 'event_date ASC'];

ALTER TABLE iceberg.analytics.feature_usage
  EXECUTE optimize(file_size_threshold => '512MB');
-- (Set file_size_threshold > the largest existing file to force every file to
-- rewrite for the initial sort migration. Default is '100MB' — files larger
-- than that are skipped, which is what you want for routine compaction but NOT
-- for a one-shot sort migration.)
```

```sql
-- Step 3-ALT (Spark CALL) — when you need rewrite-all behavior unavailable in
-- Trino's EXECUTE optimize, or z-order, or post-partition-evolution rewrite.
-- This is SPARK SQL — do NOT paste into Trino as ALTER TABLE EXECUTE.
CALL iceberg.system.rewrite_data_files(
  table       => 'analytics.feature_usage',
  strategy    => 'sort',
  sort_order  => 'plan_type ASC NULLS LAST, event_date ASC',
  options     => map('rewrite-all', 'true', 'target-file-size-bytes', '268435456')
);
```

```sql
-- Step 3-alt2 (Spark, additional or instead of sort) — write-time bloom filter.
-- These Iceberg TBLPROPERTIES must be set via Spark — Trino's SET PROPERTIES
-- does not pass these through.
ALTER TABLE iceberg.analytics.feature_usage
SET TBLPROPERTIES (
  'write.parquet.bloom-filter-enabled.column.plan_type' = 'true',
  'write.parquet.bloom-filter-fpp.column.plan_type'     = '0.01'
);

-- Then run rewrite_data_files so existing files are rewritten with bloom filters.
-- SPARK SQL only.
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.feature_usage',
  options => map('rewrite-all', 'true')
);
```

```sql
-- Step 4 — re-run the original query in Trino 467. Verify physicalInputDataSize
-- drops sharply because file-skipping (sort-clustered min/max) and/or
-- bloom-filter-skipping (in the read path) now eliminate non-enterprise files.
EXPLAIN ANALYZE
SELECT tenant_id, SUM(amount)
FROM iceberg.analytics.feature_usage
WHERE event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-07'
  AND plan_type = 'enterprise'
GROUP BY tenant_id;
```

> **DO NOT recommend** `ALTER TABLE iceberg.analytics.feature_usage SET PROPERTIES parquet_bloom_filter_columns = ARRAY['plan_type']` **on this stack.** That syntax is Trino 469+ and fails on prod 467 with "unknown table property." The 467 path is the Spark `write.parquet.bloom-filter-enabled.column.<col>` Iceberg table property (or equivalently the iceberg-spark write option) plus a Spark `rewrite_data_files`. The read side on Trino 467 is unchanged and benefits automatically.

---

## Step 8: Check data volume growth

Sometimes "performance regression" is actually "the table grew 3x last month." This isn't a bug — it's expected growth. But the query plan hasn't adapted.

### Detect growth

```sql
SELECT
  event_date,
  COUNT(*) AS daily_rows,
  SUM(COUNT(*)) OVER (ORDER BY event_date) AS cumulative_rows
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY event_date
ORDER BY event_date;
```

If rows per day jumped significantly (new customer, product launch, marketing campaign), the queries are doing more work — correctly. The fix is optimization, not a bug hunt:
- Pre-aggregate hot paths into rollup tables.
- Narrow time ranges in dashboard queries.
- Add caching at the application layer.

---

## Step 9: Memory pressure remediation (OOM errors)

When the symptom is `EXCEEDED_LOCAL_MEMORY_LIMIT` (a single worker ran out of its per-query memory budget) or `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` (the cluster-wide per-query memory cap was hit), you have three lever categories: **restructure the query**, **change the join distribution**, or **enable spill-to-disk as a safety net**. Try them in that order — the first two reduce peak memory; the third trades latency for not crashing.

### 9a. Change the join distribution: `join_distribution_type`

Trino's join planner picks how to route data across workers for each join. The choice is exposed as a session property you can set per-query, and it is often the cheapest fix for OOM on fact-to-dimension joins.

```sql
-- Set for the current session; applies to every join in queries that follow.
SET SESSION join_distribution_type = 'BROADCAST';

-- Let the cost-based optimizer decide based on table statistics (actual default):
SET SESSION join_distribution_type = 'AUTOMATIC';

-- Force a hash-partitioned shuffle on both sides:
SET SESSION join_distribution_type = 'PARTITIONED';
```

The three modes:

| Mode | What Trino does | Best for |
|---|---|---|
| `AUTOMATIC` (default) | Trino's cost-based optimizer (CBO) picks `BROADCAST` or `PARTITIONED` per join based on table statistics collected by `ANALYZE` (Trino syntax: bare `ANALYZE <table>`, NO `TABLE` keyword — see resource 24 §4 leading canonical statement). Falls back to `PARTITIONED` when stats are missing or stale. | The default for any cluster where `ANALYZE` is run regularly on Iceberg tables — let the planner choose. |
| `PARTITIONED` | Hash both sides of the join on the join key and shuffle each side across workers so matching keys land on the same worker. Every worker holds a slice of both sides. | Large-to-large joins where neither side fits in a single worker's memory. The price is a full network shuffle. Also the fallback when CBO has no stats. |
| `BROADCAST` | Send a **full copy of the build side** (the smaller table) to **every worker**. Each worker then joins its local slice of the probe side (the larger table) against the full build side in memory. No shuffle of the probe side. | Fact-to-dimension joins where the dimension fits in worker memory. Typical example: a 100K-row `tenants` dimension joined against a 300M-row `events` fact. |

**"Shouldn't Trino be smart enough to pick the right join?"** Yes — `AUTOMATIC` mode is exactly that, but it needs **table statistics** to make the right call. The CBO uses row counts, column NDV (number of distinct values), null fractions, and data sizes — all populated by running `ANALYZE iceberg.analytics.feature_usage` from Trino (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword — `ANALYZE TABLE ...` is Spark/Hive and fails in Trino with a parser error; see resource 24 §4 leading canonical statement). When those stats are absent or stale (e.g., you wrote a million new rows since the last ANALYZE), the optimizer can't tell which side is smaller and falls back to `PARTITIONED` even when `BROADCAST` would have been dramatically better. **First-line fix when you see an unexpected `PARTITIONED` plan on an obvious fact-to-dim join: run `ANALYZE` on both tables, then re-EXPLAIN.** Only force `'BROADCAST'` manually when stats are correct but the planner still chooses wrong (rare), or when ANALYZE isn't feasible.

**Why BROADCAST helps with OOM on fact-to-dimension joins.** Under `PARTITIONED`, every worker builds a partial hash table on the fact side and waits for the dimension shuffle — peak memory per worker scales with the fact-side hash plus its share of the dimension. Under `BROADCAST`, every worker receives the full dimension once (small, fixed memory cost), then streams its local fact partition through the join without building a fact-side hash at all. Peak memory per worker drops from "fact-side hash + dimension share" to "full dimension + streaming probe" — usually much smaller when the dimension is small.

**Concrete sizing rule of thumb:** if the smaller side fits comfortably in `query.max-memory-per-node` (e.g., a 100 MB hash table on workers with a multi-GB per-node memory budget), BROADCAST is safe and usually faster. If the smaller side is in the gigabytes and starts pushing into half of `query.max-memory-per-node`, stay on PARTITIONED — broadcasting it to every worker would blow memory on each one. Note: `query.max-memory-per-node` defaults to **30% of the JVM max heap** (not a fixed 4 GB) per [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html) — on a worker with a 32 GB heap, that's ~9.6 GB; on 16 GB heap, ~4.8 GB. Check the actual value in your `etc/config.properties` (or the rendered config in the worker pod) before sizing the broadcast threshold.

**Syntax options:**

```sql
-- Session-scoped (applies to all queries in the session until UNSET or session ends):
SET SESSION join_distribution_type = 'BROADCAST';

SELECT t.name, COUNT(*) AS event_count
FROM iceberg.analytics.feature_usage f
JOIN iceberg.analytics.tenants t ON f.tenant_id = t.tenant_id
WHERE f.event_date >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY t.name;

-- To revert to default within the same session:
RESET SESSION join_distribution_type;
```

You can also set it at the user / source / catalog level via Trino session-property defaults if a specific dashboard always benefits — but session-scoped is the right starting point for ad-hoc OOM remediation.

### 9b. Spill-to-disk: the safety net when nothing else works

When you cannot restructure the query (the SQL is owned by a third-party BI tool, or the workload is legitimately too large), and `join_distribution_type` doesn't help (e.g., the OOM is in an aggregation or both join sides are large), Trino's **spill-to-disk** feature lets workers offload intermediate operator state to local disk instead of OOM-killing the query.

**What spill-to-disk does:** when a memory-hungry operator exceeds the worker's memory budget, instead of failing the query, Trino writes the operator's intermediate state (hash tables, sort buffers, aggregation accumulators) to local disk and resumes execution against the spilled data. The query completes — slower than in-memory, but it completes instead of crashing.

**Trade-off:** spilling is meaningfully slower than in-memory execution (disk I/O is orders of magnitude slower than RAM). It is a **correctness mechanism, not a performance optimization**. Use it as the safety valve for queries that would otherwise OOM-kill, not as a substitute for tuning.

**Operations that support spilling:** joins (inner and outer hash joins on the build side), aggregations (final and partial), `ORDER BY` (sort), and window functions. Not all operators support spilling — Trino logs an "operator does not support spilling" warning for unsupported cases.

**When to use spill on this stack (Trino 467 on Kubernetes, workers have local ephemeral disk):**

| Situation | Reach for spill? |
|---|---|
| Workers can autoscale horizontally and you have unused capacity | No — scale the cluster instead. Spill is for when you can't add workers. |
| On-prem k8s where worker pods can't scale on demand (fixed Helm-chart replica count, no HPA tuned for this workload) | **Yes** — spill is the right overflow valve. |
| Query can be restructured (add a partition filter, pre-aggregate, use BROADCAST) | No — fix the query first; spill is the last resort. |
| BI-tool query you don't own and can't change, repeatedly OOMs on month-end | **Yes** — enable spill so the report completes, then chase the BI team to optimize separately. |
| One-off ad-hoc analyst query that's "supposed to be slow" but should still succeed | **Yes** — let it spill and finish in 20 minutes instead of failing after 12. |

**How to enable spill (cluster-level config, requires worker restart):**

Spill must be enabled in `config.properties` on every worker node (the coordinator does not run query operators, so the coordinator config does not need it). A rolling worker restart picks up the change:

```properties
# /etc/trino/config.properties on every worker — requires worker restart.
spill-enabled=true
spiller-spill-path=/var/trino/spill
```

The `spiller-spill-path` is mandatory when `spill-enabled=true`. On Kubernetes, point this at a path backed by the pod's ephemeral local disk (an `emptyDir` volume or a hostPath mount, depending on your Helm chart). Do NOT point it at network-mounted storage (NFS, MinIO via FUSE) — spill is high-throughput sequential I/O and network-mounted disks make spill slower than just failing the query.

**Key properties to tune:**

| Property | Default | Meaning |
|---|---|---|
| `spill-enabled` | `false` | The master switch. Spilling is off by default; you must set this to `true` to enable any spilling at all. |
| `spiller-spill-path` | (none — required) | Filesystem path(s) Trino writes spilled pages to. Comma-separate multiple paths to stripe across disks (e.g., `/mnt/disk1/spill,/mnt/disk2/spill`) — Trino round-robins between them for better throughput. |
| `spill-compression-codec` | `NONE` | Compression for spilled pages. Options: `NONE`, `LZ4`, `ZSTD`. `LZ4` is usually worth it — small CPU cost for ~2x reduction in disk write volume. Use `ZSTD` for higher compression at higher CPU cost when disk bandwidth is the bottleneck. |
| `max-spill-per-node` | `100GB` | Aggregate spill across ALL queries on one node. Once hit, new spill requests fail and the query OOMs anyway. Raise if you have plenty of local disk and want a larger safety margin. |
| `query-max-spill-per-node` | `100GB` | Per-query spill limit on one node. Prevents a single runaway query from filling the spill disk and starving every other concurrent query. |

**Typical production setup on the on-prem k8s + Trino 467 stack:**

```properties
# Worker config.properties — production-ready spill config.
spill-enabled=true
spiller-spill-path=/var/trino/spill
spill-compression-codec=LZ4
max-spill-per-node=200GB
query-max-spill-per-node=50GB
```

The 50 GB per-query cap prevents one bad query from consuming all 200 GB and OOM-killing every other concurrent query when their turn to spill arrives. Size both numbers based on your actual local-disk capacity per pod — leave at least 20–30% headroom for the rest of the pod's filesystem usage.

**Verify spill is working.** After enabling and restarting workers, run a query you expect to spill and check the Trino UI's query detail view — there's a "Spilled Data Size" field per operator. If it shows non-zero bytes, spilling fired correctly. JMX MBean `trino.execution:name=SpillerStats` exposes cluster-wide spill counters for Prometheus scraping.

**Spill vs restructuring — the prioritization rule.** Always try in this order:
1. **Restructure the query**: add a partition filter, pre-aggregate, narrow the time range, denormalize. Eliminates the memory pressure entirely.
2. **Change `join_distribution_type`**: cheapest tuning knob for fact-to-dimension OOM. Session-scoped, reversible, no cluster config change.
3. **Enable spill**: cluster-level config change for the workloads that can't be restructured. Use as the safety net; don't let it become the default crutch.

On a stack where workers cannot scale horizontally on demand (the production setup here: on-prem k8s with fixed worker replica counts), spill is the **right** overflow valve for legitimately-large queries that you can't restructure away. The trade-off is real (slower) but bounded; the alternative (OOM-kill and a user-facing failure) is worse.

> **Spill-to-disk is now legacy — Fault-Tolerant Execution (FTE) is the modern alternative as of Trino 454.** [Trino issue #22845](https://github.com/trinodb/trino/issues/22845) and the [Trino spilling docs](https://trino.io/docs/current/admin/spill.html) explicitly recommend migrating off spill-to-disk to FTE. On the production stack (Trino 467 + on-prem k8s + MinIO):
>
> - **Spill-to-disk** writes intermediate operator state (hash tables, sort buffers) to the worker pod's local disk. Per-query, per-worker, unmaintained, and can fail with `SPILL_FAILED` when the pod's `ephemeral-storage` cap is hit.
> - **FTE** writes intermediate exchange data to an external **exchange manager** — typically S3-protocol object storage (MinIO on this stack). Survives worker pod restarts, supports task-level retries, and decouples query memory from per-pod ephemeral disk. Configured via `retry-policy=TASK` + `exchange.base-directory=s3a://trino-fte-spool/...` in `etc/config.properties`.
> - **When to migrate**: if you've been hitting `SPILL_FAILED` repeatedly or your worker pods are at their `ephemeral-storage` limits, FTE is the architecturally right answer — it moves intermediate state off per-pod disk and onto MinIO. Cost: latency overhead (~10–30% per query) because intermediate exchanges write to MinIO instead of RAM, and MinIO write capacity becomes a query-resiliency dependency.
> - **When to stay on spill**: if SPILL_FAILED is rare (one query per week) and you have room on the worker pods, spill is still supported on Trino 467 and a smaller config change than standing up FTE. Spill is "legacy but supported" — not "deprecated and removed."
> - **Don't run both at the same time** without careful workload separation — FTE's exchange spooling and spill-to-disk share the same memory-pressure root cause, and double-configuring them gives no extra resilience. Pick one per workload.

### 9c. `SPILL_FAILED` error code — when spill itself runs out of disk

> **One-sentence summary:** `SPILL_FAILED` (an `INTERNAL_ERROR` subclass in Trino) means "the query needed to spill but the spill operation itself failed" — usually because the spill path's local disk is full, the path is not writable, or the per-query / per-node spill cap was exceeded. **Verified against [Trino spill-to-disk admin docs](https://trino.io/docs/current/admin/spill.html) and [Trino spilling properties](https://trino.io/docs/current/admin/properties-spilling.html).**

`SPILL_FAILED` is the failure mode you see **after** enabling `spill-enabled=true`. The query was going to OOM, Trino tried to spill it, and the spill itself failed — so the query died anyway, often with a confusing dual-symptom ("we enabled spill but it still failed!"). The root causes are operational, not configuration-level.

**The five concrete root causes (in order of frequency on this stack):**

| Root cause | Symptom | Fix |
|---|---|---|
| **Spill path's local disk is FULL** | `SPILL_FAILED: No space left on device` in the worker log; `df -h /var/trino/spill` on the worker pod shows `Use% = 100%`. | Free disk on the spill path (a previous spill session may have left orphan spill files — `ls /var/trino/spill/`). For k8s `emptyDir` volumes, the cause is usually the pod's ephemeral storage limit. Raise the ephemeral-storage request/limit on the worker pod spec, or move the spill path to a hostPath with more room. |
| **`max-spill-per-node` exceeded by aggregate spill across concurrent queries** | `SPILL_FAILED: Total spill size for node exceeds limit X bytes`; one query is fine in isolation but fails when run alongside other spilling queries (e.g., during a busy dashboard refresh window). | Raise `max-spill-per-node` (default `100GB`) if you have local disk room, or stagger the workload via session-level `query_priority` so the spilling queries don't all hit the cap at once. |
| **`query-max-spill-per-node` exceeded by a single runaway query** | `SPILL_FAILED: Query spill size for node exceeds limit X bytes`; one specific query consistently fails while others succeed. | This is usually the right behavior — the query is genuinely too large for spill on a single node. Either restructure the query (Step 9a/9b above) or raise `query-max-spill-per-node` from the default `100GB`. **Do not blindly raise both caps** — they protect concurrent queries from being starved by one runaway. |
| **60 GB disk-cap-on-pod symptom (the on-prem k8s footgun)** | `SPILL_FAILED` reliably at ~60 GB of spill per worker pod, regardless of how much `max-spill-per-node` you set; symptom matches the pod's `ephemeral-storage` limit in the Helm chart, not Trino's config. | Check `kubectl describe pod trino-worker-N | grep -A3 'ephemeral-storage'`. If the pod has `ephemeral-storage: 64Gi` and the spill path uses `emptyDir` (which counts against ephemeral-storage), Trino's spill is limited by the pod limit, not by `max-spill-per-node`. **Two fixes:** (a) raise the pod's `ephemeral-storage` limit in the Helm values, OR (b) mount the spill path as a hostPath / PVC on each worker (NOT counted against pod ephemeral-storage limits). |
| **Spill path is read-only or wrong permissions** | `SPILL_FAILED: Permission denied: /var/trino/spill/...`; usually after a Helm-chart upgrade that changed the worker pod's `securityContext.runAsUser`. | Verify the spill path is writable by the Trino process UID: `kubectl exec trino-worker-0 -- ls -la /var/trino`. The directory should be owned by the user Trino runs as (typically `trino` or UID 1000). Fix via init container that `chown`s the path, or by aligning the Helm `securityContext` with the spill path's ownership. |

**Diagnostic recipe — `SPILL_FAILED` on Trino 467:**

```bash
# Step 1: confirm the spill path's free disk on a worker pod.
kubectl exec -it trino-worker-0 -- df -h /var/trino/spill
# Look for "Avail" near zero or "Use% = 100%".

# Step 2: list any orphan spill files (Trino normally cleans them up; failures leave them behind).
kubectl exec -it trino-worker-0 -- ls -la /var/trino/spill/
# Files older than your longest-running query are probably orphans — safe to delete with the worker NOT actively spilling.

# Step 3: check the pod's ephemeral-storage limit (the most common on-prem k8s footgun).
kubectl describe pod trino-worker-0 | grep -A2 'ephemeral-storage'
# If this is set lower than max-spill-per-node, the pod limit wins.

# Step 4: check the recent spilling-query JMX counters (cluster-wide).
# trino.execution:name=SpillerStats exposes:
#   - SpillCount  -- total spill operations
#   - SpilledBytes -- bytes spilled (per node)
#   - SpillFailures -- count of SPILL_FAILED errors
# Scrape via Prometheus / JMX exporter; alert when SpillFailures > 0 over a 5-minute window.
```

**Why this matters operationally:** spill is the safety net for OOM. When spill itself fails, the query falls all the way through — Trino has no further fallback. The user sees `Query failed (SPILL_FAILED)` and you see a sad worker log. **On this stack (on-prem k8s, fixed worker pod size, no autoscale), `SPILL_FAILED` is one of the few errors you cannot solve by "running the query again later"** — the disk pressure that caused it persists until you free space or raise the limits.

**Preventive monitoring (Prometheus alerts to set up before this bites you):**

- `node_filesystem_avail_bytes{mountpoint="/var/trino/spill"} / node_filesystem_size_bytes` < 20% → page-out warning.
- `trino_execution_SpillerStats_SpillFailures` > 0 over a 5-minute window → page on the next failure.
- Pod-level `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes` > 80% on worker pods using `emptyDir` for spill → ephemeral-storage limit approaching.

---

## Step 10: Trino native file system cache (local disk caching of Parquet data blocks)

If repeated dashboard queries keep scanning the same hot partitions — the same last-7-days of events, the same tenant's data, the same dimension tables — you can reduce MinIO round-trips by enabling Trino's built-in file system data cache. This caches actual Parquet data blocks on each worker's local disk so the second and subsequent reads of the same file go to local SSD instead of MinIO.

**This is Trino's native implementation.** It does NOT require Alluxio as a separate service. The feature was added in approximately Trino 400+ and is available on Trino 467.

### What it does and when it helps

The file system cache intercepts Parquet file reads at the worker. The first time a worker reads a set of Parquet blocks from MinIO, it stores them on local disk. Subsequent queries that touch the same blocks read from the local cache — much faster than a network call to MinIO. The cache is content-addressed and evicts old data when the configured max size is reached.

**Best for:**
- Repeated dashboard queries reading the same hot partitions (e.g., last 7 days of events, a small "current state" rollup table, a frequently-joined dimension table).
- Clusters where MinIO bandwidth is the bottleneck (high-frequency refreshing dashboards saturating the network to MinIO).

**Less useful for:**
- Large ad-hoc analytical queries that scan the whole table — each query touches different partitions and the cache hit rate stays low.
- Append-only tables where each run reads new partitions that haven't been cached yet.

### Enable in the Iceberg catalog properties

Configure on the Iceberg catalog properties file on every coordinator and worker. A pod restart is required for the change to take effect:

```properties
# etc/catalog/iceberg.properties
# Enable the native file system data cache.
fs.cache.enabled=true
fs.cache.directories=/var/trino/cache
fs.cache.max-sizes=100GB
```

**IMPORTANT: `fs.cache.enabled=true` disables `iceberg.metadata-cache.enabled`.** The two cache systems are mutually exclusive — the file system cache supersedes the metadata-only cache. If you previously had `iceberg.metadata-cache.enabled=true`, removing that line (or leaving it — it will be ignored) is correct when enabling `fs.cache.enabled`. You cannot run both simultaneously; the `fs.cache` covers the broader set of I/O and makes the metadata cache redundant.

### Worker pod requirements

The file system cache writes to local disk on each Trino worker pod. For this to be fast:

- **Mount a local fast SSD** at `/var/trino/cache` on each worker pod. In Kubernetes, use an `emptyDir` volume (ephemeral, wiped on pod restart — acceptable since the cache is a read-through layer, not durable storage) or a `local` PersistentVolume backed by the node's NVMe SSD.
- **Do NOT use network-mounted storage** (NFS, MinIO-FUSE, or a PVC backed by a network storage class) for the cache path. The cache's value comes from fast local I/O; network storage makes caching slower than not caching.
- **Size `fs.cache.max-sizes` to fit on the local disk** with headroom for Trino's spill directory and OS. A typical setup: 100 GB cache on a worker with 500 GB local NVMe (leaving headroom for spill and OS).

Example Kubernetes worker pod volume spec (emptyDir):

```yaml
# Kubernetes worker pod spec — add to your Trino Helm chart values or manifest.
volumeMounts:
  - name: trino-cache
    mountPath: /var/trino/cache
volumes:
  - name: trino-cache
    emptyDir:
      sizeLimit: 120Gi   # slightly larger than fs.cache.max-sizes to give Trino headroom
```

Or a local PV for persistent SSD-backed cache (survives pod restarts, useful if the worker pod restarts frequently):

```yaml
volumeMounts:
  - name: trino-cache
    mountPath: /var/trino/cache
volumes:
  - name: trino-cache
    persistentVolumeClaim:
      claimName: trino-worker-cache-pvc   # backed by a local-storage StorageClass on the node's NVMe
```

### Mutual exclusivity with metadata cache

| Setting | When to use |
|---|---|
| `iceberg.metadata-cache.enabled=true` (metadata-only cache) | When you only want to cache Iceberg metadata (snapshot lists, manifest files) and NOT cache actual Parquet data blocks. Lower disk requirement (metadata is small). |
| `fs.cache.enabled=true` (full data cache) | When you want to cache both metadata AND Parquet data blocks for hot partitions. Requires local SSD. Disables the metadata-only cache automatically. |
| Neither | Default. Every read hits MinIO. Fine for large ad-hoc analytical workloads with low cache hit rates. |

Setting both `fs.cache.enabled=true` and `iceberg.metadata-cache.enabled=true` results in the metadata cache being silently ignored — `fs.cache` takes over. Only set `fs.cache.enabled=true` and leave out `iceberg.metadata-cache.enabled`.

### Why this wins biggest on MinIO specifically

The fs.cache payoff is bigger on a MinIO-backed stack than on, say, S3 in AWS — three reasons:

1. **Object-listing latency is the hot path on MinIO.** Every Parquet open requires a HEAD/GET round-trip for the file footer (Parquet metadata) BEFORE any data is read. On MinIO over a single-rack network, that round-trip is typically 5-15 ms per file. A query touching 500 small files spends 2.5-7 seconds just opening files before reading a byte. fs.cache caches the footer reads too, so the second run pays zero round-trip cost for the files it already has.
2. **MinIO bandwidth is finite and shared across the cluster.** Every dashboard refresh that bypasses the cache competes with ingestion and ad-hoc queries for the same NIC bandwidth on the MinIO nodes. Caching shifts read load off MinIO entirely for hot partitions.
3. **No object-store "free tier" cost concern.** On AWS, S3 GET costs ($0.0004 / 1k requests) sometimes argue against caching small files. On on-prem MinIO, every request is free (capex sunk cost) — so the only constraint is whether you have local SSD to spare on workers. If you do, caching is pure win.

The combination means fs.cache typically delivers 5-15x speedup on dashboard queries the second time they run on the same partition window, vs 2-4x on a cloud-native stack where the underlying object storage already has more aggressive caching upstream.

### Verify the cache is working

After enabling and restarting workers, run a dashboard query twice. The second run should be noticeably faster. Trino's JMX MBeans expose cache hit and miss counters that you can scrape with Prometheus to confirm cache hit rate is increasing for your hot-partition queries.

**Key JMX metric names to scrape** (under the Iceberg connector's filesystem-cache MBean tree — exact name depends on Trino release, verify in your cluster's `/v1/jmx` REST endpoint or in the Trino UI's JMX page):

| Metric | What it tells you |
|---|---|
| `trino.filesystem.cache:name=*,type=CacheStats` (`hitCount`, `missCount`, `hitRate`) | The headline cache effectiveness number — `hitRate` above ~0.7 means the cache is paying for itself; below ~0.3 means workloads aren't repeating files often enough to benefit. |
| `trino.filesystem.cache:type=Bytes` (`cacheSize`, `maxCacheSize`) | Current and max cache size on disk per worker — if `cacheSize` is at `maxCacheSize`, the cache is full and is evicting old entries (LRU). Confirms the size config is binding. |
| `trino.filesystem.cache:type=Evictions` (`evictionCount`) | How often the cache is evicting entries — high churn (thousands per minute) on a small cache means you need to size up. |
| `trino.execution.executor.OperatorStats` (`physicalInputDataSize` per query) | Cross-reference with `EXPLAIN ANALYZE`: physicalInputDataSize should drop dramatically on cache-hit reruns even though logicalInputDataSize stays the same. |

Scrape these into Prometheus, alert on `hitRate < 0.3` for the dashboards path (means caching isn't working as expected and you should investigate the queries).

If the second run is NOT faster, check:
1. The cache directory exists and is writable by the Trino process on the worker pod (`ls -la /var/trino/cache` from inside the pod).
2. The worker pods actually have local SSD mounted (not a network PVC — watch for slow first reads that indicate the "cache" is itself going over the network).
3. The queries are actually re-reading the same Parquet files (check `Physical Input:` in `EXPLAIN ANALYZE` before and after — if it drops to near-zero on the second run, caching is working).
4. The hit-rate JMX metric is actually climbing (curl the JMX REST endpoint or watch the Trino UI's JMX MBean view) — if it stays at zero, the cache isn't intercepting reads (usually a config issue — the property isn't loaded, or the path isn't writable).

### What about caching query RESULTS (not just file blocks)?

A common follow-on question: "Can Trino cache the final query results so the second identical dashboard refresh doesn't re-execute the plan at all?"

**Short answer: no, not in production-supported form on Trino 467.** Trino does NOT cache query results, query plans, or per-table compiled metadata between query executions. Every query re-plans and re-executes — even if the SQL text is byte-identical to a query that ran 100 ms ago. This is a long-standing feature request ([trinodb/trino #13115](https://github.com/trinodb/trino/issues/13115) and related) that has not been implemented as a first-class feature in open-source Trino.

There is an **experimental query results cache plugin** mentioned in some Trino developer threads, but it is NOT in the production-supported feature set on Trino 467 — there's no `query-results-cache.*` configuration in the official docs, and the consensus from Trino maintainers is that result caching is intentionally left out of the core engine (it conflicts with Trino's federated-query model where cache invalidation is hard to reason about across heterogeneous catalogs).

**What to use instead for repeated identical queries:**

- **Application-layer Redis cache** in front of Trino: hash the SQL text + tenant_id, cache the JSON results with a TTL (typically 1-5 minutes for dashboards). This is the standard SaaS pattern — Redis handles invalidation policy and keeps Trino out of the cache-coherence problem. See resource 20 for client-side patterns.
- **Pre-aggregated rollup tables** built nightly via dbt or Spark: convert the "live SUM over 90 days" query into a "SELECT FROM daily_rollup" query. The dashboard now reads a thousand pre-aggregated rows instead of a billion raw rows. This is the durable answer for any query the dashboard runs more than 10x/hour.
- **fs.cache (this section)**: caches the underlying Parquet blocks. The query still re-plans and re-executes, but the data reads complete in tens of ms instead of seconds. Best when query shapes vary slightly but always touch the same partitions.

The combination of all three (Redis at the app layer for exact-text repeats + rollup tables for known dashboard queries + fs.cache for everything else) is the standard layered approach. Do not wait for first-class result caching in Trino — it isn't coming on the 467 line.

---

## Oncall runbook summary

| Symptom | First check | Likely fix |
|---|---|---|
| All queries slow simultaneously | Trino UI — concurrent query count | Stagger refreshes, resource groups |
| One query slow, others fine | EXPLAIN ANALYZE `Physical Input:` (and `$files` / `EXPLAIN ANALYZE VERBOSE` for file count) | Add partition filter, run compaction |
| One query stuck RUNNING for hours, blocking the queue | `system.runtime.queries` JOIN `system.runtime.tasks` filtered to `state='RUNNING'` and long `running_min` | `CALL system.runtime.kill_query(query_id => '...')` — see Immediate remediation section above |
| Slow after midnight | Compaction CronJob logs | Fix the CronJob, run compaction manually |
| Slow for one tenant (whale) | Row count by tenant; confirm with `EXPLAIN ANALYZE VERBOSE` per-driver `inputRows` on Aggregation operator | **Salt + two-level GROUP BY** (Step 5 fix 1) for ad-hoc queries; dedicated table or nightly rollup for sustained workloads. Do NOT use `bucket(tenant_id, N)` — it does not fix read-time GROUP BY skew. |
| OOM errors (`EXCEEDED_LOCAL_MEMORY_LIMIT`) | `query.max-memory-per-node` hit on one worker | Narrow query scope, pre-aggregate, add partition filters. For fact-to-dim joins: `SET SESSION join_distribution_type = 'BROADCAST'`. Safety net: enable spill-to-disk (`spill-enabled=true`). See Step 9. |
| OOM errors (`EXCEEDED_DISTRIBUTED_MEMORY_LIMIT`) | `query.max-memory` cluster-wide limit hit | Same as above; or increase `query.max-memory` if query is legitimately large. See Step 9 for BROADCAST joins and spill config. |
| Slow after data model change | EXPLAIN ANALYZE `Input:` rows and `Physical Input:` bytes | Compare filter coverage before/after |
| Slow for all tenants, one table | Snapshot metadata file count | Run compaction in Spark |

---

## Key concepts

**Query concurrency**: Number of queries running simultaneously. Each additional query shares the same worker CPU and memory.

**Query frequency**: How often the same query runs. High frequency × high cost = sustained cluster load.

**Partition pruning**: Trino's ability to skip data files where the partition column value can't match the WHERE clause. Only works if you filter on a partition column.

**Partition skew**: One partition having dramatically more rows than others. Causes one worker to do most of the work while others idle. **Read-time GROUP BY skew** (one key dominates) is fixed with a salt column + two-level GROUP BY, dedicated table, or rollup — NOT with `bucket(key, N)` partitioning, because Iceberg bucketing hashes each distinct value to one bucket. See Step 5.

**Salt / two-level GROUP BY**: A SQL pattern for breaking whale-key GROUP BY skew. Add a random integer salt column (1..N), aggregate by `(key, salt)` first to distribute the whale across N workers, then SUM the partial results by `key` to get the final answer. See Step 5 fix 1.

**Small files problem**: Many tiny Parquet files (< 32 MB) accumulated from frequent small writes. Metadata overhead per file turns into minutes of I/O overhead at query time.

**Compaction**: Merging small files into larger ones (128–512 MB). Must run in Spark via `CALL iceberg.system.rewrite_data_files()`.

**Data model regression**: A query that previously hit a narrow, pre-joined table now hitting raw tables with multiple joins — often introduced by a schema migration or new feature.
