# Iceberg Partition Design for SaaS Workloads

> **Production note:** Iceberg 1.5.2 + Trino 467 + Spark + MinIO. Partition choices made on day 1 cost a *lot* to change later because they determine your physical file layout. Read this before you create your first big fact table.

---

## Quick answer (TL;DR)

- Partitioning splits a table's data into separate files grouped by a column (usually time). Queries that filter on the partition column skip files they don't need.
- For a typical SaaS event table, start with `PARTITIONED BY (day(occurred_at), tenant_id)`. It covers ~95% of queries (time-range + per-tenant filters).
- Iceberg uses **hidden partitioning** — you write `WHERE occurred_at >= ...`, not `WHERE event_day = ...`. Iceberg figures out which files to read.
- Frequent small writes create the **small-files problem**. Run a nightly Spark `rewrite_data_files` compaction to merge into ~128MB–512MB Parquet files.
- Target ~1,000–100,000 partitions per table. Far more than that (e.g., `bucket(user_id, 10000)` — an Iceberg transform that hashes `user_id` into 10,000 fixed groups) makes metadata huge and pruning slow.

---

## Common myths about Iceberg partitioning — read FIRST (the load-bearing wrong claims)

These are the absolutes most often stated incorrectly about Iceberg partitioning on Trino 467 + Iceberg 1.5.2 + Spark. Each TRUTH below has been verified against the [Iceberg partitioning docs](https://iceberg.apache.org/docs/1.5.1/partitioning/), the [Iceberg evolution docs](https://iceberg.apache.org/docs/1.5.1/evolution/), and the [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html). **Lead with the TRUTH; state the nuance.**

| MYTH (commonly said wrong) | TRUTH (correct framing) | Where in this doc |
|---|---|---|
| "Iceberg partitioning can't be changed after table creation — pick carefully on day 1, you're stuck with it." | **NO — Iceberg supports PARTITION EVOLUTION as a metadata-only operation, and Trino 467 supports it via `ALTER TABLE x SET PROPERTIES partitioning = ARRAY[...]`.** Old data files written under the OLD partition spec keep their old partition values; NEW data is written under the new spec. The connector queries across both specs transparently. Verified at [iceberg.apache.org/docs/1.5.1/evolution/](https://iceberg.apache.org/docs/1.5.1/evolution/) ("Iceberg tables can be partitioned by different fields over time"). Caveat: existing files are NOT rewritten — old partitions don't benefit from the new pruning shape unless you also run `rewrite_data_files`. | [§ Changing partitioning later](#changing-partitioning-later) leading callout |
| "If `plan_type` isn't in the partition spec, Iceberg can't skip files based on `WHERE plan_type = ...`." | **NO — Iceberg tracks `lower_bounds` and `upper_bounds` PER COLUMN for every file (not just partition columns).** File-level min/max pruning works for ANY column. The reason a `plan_type` filter often doesn't help in practice is that rows arrive in random order, so every file's `plan_type` min/max range spans 'basic'..'starter' and pruning can't prove the filter absent. The fix is **sort the data with `rewrite_data_files` (Spark sort strategy)** so per-file ranges narrow — not "add `plan_type` to the partition spec." | [§ How Iceberg file pruning actually works](#how-iceberg-file-pruning-actually-works-read-this-before-partition-design) main misconception |
| "Hidden partitioning means I need to write `WHERE day(occurred_at) = DATE '2026-05-01'` — that's the partition column." | **NO — that's the OPPOSITE of hidden partitioning.** You write the natural predicate: `WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00' AND occurred_at < TIMESTAMP '2026-05-02 00:00:00'`. Iceberg internally applies the partition transform (`day(occurred_at)`) to your timestamp filter and prunes files. Writing `WHERE day(occurred_at) = ...` will compile and may even work, but **the canonical hidden-partitioning idiom is to write predicates against the source column, not the transform output.** See [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html). | [§ Hidden partitioning](#hidden-partitioning) callout |
| "I should partition by `tenant_id` so each tenant's data lives in its own physical group — it's the cleanest isolation." | **DEPENDS — partitioning by raw `tenant_id` is correct ONLY IF tenant count stays under ~10,000.** Each unique partition value creates a separate physical group in metadata. With 100,000+ tenants the partition count explodes, manifests bloat, query planning slows, and small-files-per-tenant becomes severe. For high-cardinality tenant fields, use `bucket(tenant_id, 64)` or `bucket(tenant_id, 256)` instead — a fixed-count hash that distributes tenants across buckets while keeping partition count bounded. | [§ Choosing partition columns](#choosing-partition-columns) high-cardinality callout |
| "`PARTITIONED BY (day(occurred_at), tenant_id)` is the same as `PARTITIONED BY (tenant_id, day(occurred_at))` — order doesn't matter." | **TECHNICALLY THE PRUNING IS THE SAME** (Iceberg uses both fields independently for file-level pruning regardless of order) **but file LAYOUT differs.** The first field defines the outer grouping in the manifest tree. Put the field your most common filter uses FIRST — that maximizes manifest-level pruning. For a SaaS event table where 90% of queries filter by date range first, lead with `day(occurred_at)`. For a per-tenant lookup pattern where 90% of queries filter by `tenant_id` first, lead with `tenant_id`. | [§ Partition spec ordering](#partition-spec-ordering) callout |
| "`bucket(user_id, N)` partitions split a table into N physical buckets — pick N large to spread load." | **PICK N SMALL — bucket count creates partition count.** A `bucket(user_id, 10000)` on a daily-time-partitioned table creates `~365 * 10000 = 3.65M partitions per year`. Each partition contributes manifest entries; query planning becomes slow and per-partition files become tiny. Reasonable bucket counts are **64, 128, 256** — sometimes up to 1024 for very large facts. The bucket transform is a hash, not a Spark shuffle-target — you do NOT need it to match worker count. | [§ Bucket partitioning](#bucket-partitioning) sizing callout |
| "Partition pruning means a query only reads files for the partitions in my WHERE clause — no other I/O happens." | **MOSTLY TRUE for data files, but Iceberg ALSO reads METADATA files (manifest list + manifests) for every query, regardless of pruning.** For a 100K-file table with poorly-organized manifests, the metadata I/O alone can dominate query time before any data file is opened. The fix is `rewrite_manifests` (Spark-only on Trino 467) to consolidate manifests after large schema/partition churn. Manifest reads are usually small (~MB per manifest) but a 10,000-manifest table sees significant planning overhead. | [§ Why manifests matter](#why-manifests-matter-the-other-half-of-pruning) callout |
| "If I drop a partition column from my partition spec, the old data partitioned by that column gets re-partitioned automatically." | **NO — partition evolution is METADATA-ONLY. Old data files are NOT rewritten.** When you remove `tenant_id` from the partition spec, new writes won't partition by `tenant_id`, but old files retain their original `tenant_id` partition value in metadata. The connector queries both partition specs transparently. To physically un-partition the old data, you must run `rewrite_data_files` AFTER evolving the spec. Reference: [iceberg.apache.org/docs/1.5.1/evolution/#partition-evolution](https://iceberg.apache.org/docs/1.5.1/evolution/). | [§ Changing partitioning later](#changing-partitioning-later) "metadata only" callout |
| "Trino 467 can run `OPTIMIZE` on just one partition — I can target the hot day without rewriting the table." | **YES — Trino 467 supports `ALTER TABLE x EXECUTE optimize WHERE day = DATE '2026-05-01'`.** The WHERE clause filters which files participate in compaction; only files whose partition matches are rewritten. This is the right pattern for hot recent partitions. Verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). Note the Spark equivalent is `CALL system.rewrite_data_files(table => 'x', where => 'day = DATE \\'2026-05-01\\'')`. | [§ Compaction by partition](#compaction-by-partition) targeted callout |
| "If I have 18 month-partitions, that's about 18 data files — one file per partition." | **NO — a partition is a LOGICAL grouping (one distinct partition-key value), NOT a single data file.** The number of data files INSIDE a partition is driven by (a) `write.target-file-size-bytes` (Trino default write target ~512 MB; `EXECUTE optimize` uses `file_size_threshold`), (b) ingestion cadence — every write/commit adds at least one new file per partition it touches, so 15-min micro-batches → many files/day, (c) writer parallelism — each Spark task / Trino writer emits its own file. **It is NEVER one file per partition.** A single month-partition holding 27M rows can easily contain dozens to hundreds of Parquet files. That is exactly why compaction (`EXECUTE optimize` / `rewrite_data_files`) exists. To see ACTUAL file counts, use the `$partitions.file_count` column or `$files WHERE content=0`. | [§ PARTITIONS-ARE-NOT-FILES guardrail](#partitions-are-not-files--read-before-estimating-file-counts) leading callout |

> **Why these specific myths matter.** Each is a load-bearing topic-specific claim about what Iceberg partitioning "can / can't / does" do. Stated as an absolute, it causes engineers to either build expensive workarounds for non-problems (rebuilding tables from scratch because they thought partition spec was immutable; adding low-cardinality columns to the partition spec for skip-by-filter optimization that file-level min/max already supports) OR to confidently break things (creating `bucket(user_id, 10000)` partitions thinking "more buckets = more parallelism"; assuming `partitionBy()` in Spark `df.write` partitions the Iceberg table — it doesn't, see resource 13). **The correct discipline:** when about to say "partitioning can't / does / doesn't X", check (a) Iceberg evolution docs for whether partition spec changes are supported, (b) Iceberg manifest layout docs for whether file-level pruning needs the column to be in the spec, (c) Trino 467 release notes for procedure availability, (d) the team's own resource 10.

---

## LEADING CANONICAL PARTITION EVOLUTION WORKED EXAMPLE — "Migrating from date-only to (date, tenant_bucket) on a 3TB table" (read this FIRST for partition-spec-change questions)

> **This is the findable canonical answer for the "I want to change my partition spec" question. Every command below has been verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html), [iceberg.apache.org/docs/1.5.1/evolution/](https://iceberg.apache.org/docs/1.5.1/evolution/), and Trino issue tracker (#25279, #26109, #26503). Do NOT invent commands — paste verbatim.**
>
> **Scenario:** You have a 3TB fact table `iceberg.analytics.user_events` partitioned only by `day(occurred_at)`. Most queries are per-tenant ("show me acme's last 90 days") and they're getting slow because every file in the last 90 days is opened to filter on `tenant_id`. You want to migrate to `(day(occurred_at), bucket(tenant_id, 64))` — keep daily time pruning, add bucketed tenant pruning to skip files for other tenants.
>
> **Why `bucket(tenant_id, 64)` instead of identity `tenant_id`?** With 800 tenants and severe size skew (one whale tenant holds 60% of rows), identity partitioning would create 800 partitions per day × 365 days = 292K partitions/year — too many, and most would be tiny. `bucket(tenant_id, 64)` hashes tenants into exactly 64 fixed buckets per day, giving balanced file sizes and bounded partition count (23,360/year). The query `WHERE tenant_id = 'acme'` still prunes — Iceberg applies the same hash to the predicate and reads only the matching bucket. The trade-off: per-tenant `COUNT(*)` is no longer metadata-only (would need identity partitioning for that).
>
> ### The five-step rewrite procedure on Trino 467 + Spark + Iceberg 1.5.2
>
> ```sql
> -- STEP 1 (Trino 467) — Evolve the partition spec. Metadata-only operation, instant.
> -- This affects NEW writes ONLY. Old files keep their old spec_id.
> ALTER TABLE iceberg.analytics.user_events
> SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'bucket(tenant_id, 64)'];
> ```
>
> **What just happened:** the Iceberg table now has two partition specs in its metadata — `spec_id=0` (the old `day(occurred_at)` only) and `spec_id=1` (the new `(day, bucket(tenant_id, 64))`). New writes use spec_id=1. Existing files stay tagged with spec_id=0 and **continue to defeat tenant-bucket pruning until you rewrite them in step 3**.
>
> ```sql
> -- STEP 2 (Trino 467, run BEFORE rewrite) — Confirm the spec change took, and see the baseline file distribution.
> -- This metadata query works on BOTH Spark and Trino.
> SELECT spec_id, COUNT(*) AS file_count, SUM(file_size_in_bytes)/(1024.0*1024*1024) AS total_gb
> FROM iceberg.analytics."user_events$files"
> GROUP BY spec_id
> ORDER BY spec_id;
> -- Expected output right after step 1:
> --   spec_id | file_count | total_gb
> --   --------+------------+---------
> --         0 |     45,232 |  2978.4   <- everything still on the old spec
> ```
>
> ```sql
> -- STEP 3 (Spark SQL ONLY — Trino's EXECUTE optimize CANNOT do this) — Rewrite all old-spec files under the new spec.
> -- This is the ONLY procedure on this stack that re-stamps existing files with the new spec_id.
> -- Run from a spark-submit job; not from the Trino query console (will fail with parse error).
> CALL iceberg.system.rewrite_data_files(
>   table   => 'analytics.user_events',
>   options => map(
>     'rewrite-all',            'true',       -- force rewrite ALL files regardless of size
>     'target-file-size-bytes', '268435456'   -- 256 MB target output file size
>   )
> );
> ```
>
> **Why Spark and not Trino:** Trino's `ALTER TABLE ... EXECUTE optimize` only changes file SIZES (bin-pack within the existing partition layout). It does NOT repartition files to a new spec. Confirmed bugs ([trinodb/trino #25279](https://github.com/trinodb/trino/issues/25279), [#26109](https://github.com/trinodb/trino/issues/26109), [#26503](https://github.com/trinodb/trino/issues/26503)) mean post-evolution Trino `OPTIMIZE` may even produce files with incorrect/NULL partition values. **For partition spec migration, you MUST use Spark.**
>
> **Why `rewrite-all=true`:** the default bin-pack strategy only rewrites files that are "too small" — large healthy files from the old spec are skipped and stay on `spec_id=0`. `rewrite-all=true` forces Spark to rewrite every file regardless of size, restamping each with `spec_id=1` and the new bucket-partition path.
>
> **Cost and duration on a 3TB table:** ~1.5–3 hours on the production Spark cluster (depends on executor count). Temporary MinIO storage spike of ~2x table size (~6TB peak) until step 5's expire_snapshots runs.
>
> ```sql
> -- STEP 4 (Trino 467 OR Spark — metadata query) — Verify rewrite completed.
> -- Re-run periodically during the rewrite. When spec_id=0 row count = 0, migration is complete.
> SELECT spec_id, COUNT(*) AS file_count, SUM(file_size_in_bytes)/(1024.0*1024*1024) AS total_gb
> FROM iceberg.analytics."user_events$files"
> GROUP BY spec_id
> ORDER BY spec_id;
> -- Expected output after step 3 completes:
> --   spec_id | file_count | total_gb
> --   --------+------------+---------
> --         1 |     11,718 |  2978.4   <- all files now on the new spec, healthy 256MB sizes
> ```
>
> ```sql
> -- STEP 5 (Trino 467) — Expire snapshots so MinIO reclaims storage from the now-superseded old-spec files.
> -- This MUST follow step 3 — without it, MinIO holds both pre-rewrite AND post-rewrite copies of every file.
> ALTER TABLE iceberg.analytics.user_events
> EXECUTE expire_snapshots(retention_threshold => '7d');
> ```
>
> ### Query patterns that benefit from the new spec
>
> | Query pattern | Pre-migration | Post-migration (with full rewrite) |
> |---|---|---|
> | `WHERE occurred_at >= ... AND occurred_at < ... AND tenant_id = 'acme'` (date range + tenant filter) | Reads ALL files in the date range (every tenant) | Reads files in 1 out of 64 buckets per matching day — **~64x less I/O** |
> | `WHERE occurred_at >= ... AND tenant_id IN ('acme', 'globex', 'initech')` | Reads ALL files in date range | Reads files in 3 out of 64 buckets per matching day — **~21x less I/O** |
> | `WHERE occurred_at >= ... AND occurred_at < ...` (date only, no tenant) | Day pruning works as before | Same as before — bucket dimension is irrelevant when no tenant predicate |
> | `WHERE tenant_id = 'acme'` (no time predicate) | Reads ALL files in ALL days | Reads files in 1 out of 64 buckets across ALL days — **~64x less I/O** but still all-time scan |
> | `SELECT tenant_id, COUNT(*) FROM ... GROUP BY tenant_id` | Metadata-only on identity-partitioned tables; **NOT metadata-only on bucket-partitioned tables** | Same as before — must scan data files |
>
> ### DO-NOT-WRITE — banned forms in the partition evolution workflow
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `ALTER TABLE iceberg.analytics.user_events SET PARTITIONING = ARRAY['day(occurred_at)', 'bucket(tenant_id, 64)']` | The keyword is `SET PROPERTIES partitioning = ARRAY[...]`, NOT `SET PARTITIONING = ARRAY[...]`. The `partitioning` keyword goes INSIDE `PROPERTIES`, lowercase. | `ALTER TABLE <t> SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'bucket(tenant_id, 64)']` — verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). |
> | `ALTER TABLE iceberg.analytics.user_events ADD PARTITION FIELD bucket(tenant_id, 64)` | This is **Spark SQL syntax** (`ALTER TABLE ... ADD PARTITION FIELD`), not Trino. Trino 467 does NOT support `ADD PARTITION FIELD`. | Use Trino's `SET PROPERTIES partitioning = ARRAY[...]` (full re-specification, NOT additive). To add a column to the spec, write the FULL new spec including the existing columns. |
> | `ALTER TABLE iceberg.analytics.user_events EXECUTE optimize` to migrate files to the new spec | Trino's `EXECUTE optimize` only changes file SIZES (bin-pack within the existing partition layout). It does NOT repartition files to a new spec. Confirmed bugs ([trinodb/trino #25279](https://github.com/trinodb/trino/issues/25279), [#26109](https://github.com/trinodb/trino/issues/26109)) may even produce files with NULL/incorrect partition values. | Use Spark `CALL iceberg.system.rewrite_data_files(..., options => map('rewrite-all','true', ...))` for the spec-migration rewrite. After all files are on the new spec, you can resume Trino `EXECUTE optimize` for routine compaction. |
> | `CALL iceberg.system.rewrite_data_files(...)` pasted into the Trino query console | `CALL iceberg.system.*` is **Spark SQL only**. Trino rejects with a parse error. | Run via spark-submit or a Spark SQL session. Trino has no native equivalent of Spark's `rewrite-all=true` cross-spec rewrite. |
> | `CALL iceberg.system.rewrite_data_files(table => 'analytics.user_events', options => map('rewrite-all', 'true'), where => 'tenant_id = ''acme''')` | **Known bug — apache/iceberg #14667** — combining `rewrite-all=true` with a `where` predicate can produce DUPLICATE ROWS in the rewritten partition. | If you need to scope the rewrite (e.g., per-tenant), use `'min-input-files', '1'` with default bin-pack instead — see the full per-tenant safe form in the partition-evolution section later in this document. |
> | `OPTIMIZE TABLE iceberg.analytics.user_events PARTITION (day='2026-05-01')` | This is **Hive/Impala syntax**, not Trino. Trino 467 has no `OPTIMIZE TABLE` statement. | `ALTER TABLE iceberg.analytics.user_events EXECUTE optimize WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00' AND occurred_at < TIMESTAMP '2026-05-02 00:00:00'`. |
> | Skipping step 5 (`expire_snapshots`) after the rewrite | Without expire_snapshots, MinIO holds BOTH the pre-rewrite Parquet files AND the post-rewrite ones — a temporary ~2x storage spike becomes permanent. The old snapshots still reference the old files. | Always run `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` AFTER `rewrite_data_files`. Schedule weekly going forward. |
> | "After partition evolution, old queries break and must be rewritten." | False. Iceberg partition evolution is transparent to readers — the connector queries across both specs and merges results. Old queries continue to work and return identical results; they just don't benefit from the new pruning shape on old (pre-rewrite) files. | Reader queries are unchanged. Only the bulk rewrite is needed to ACTIVATE the new pruning on existing data. |
>
> **Why this DO-NOT-WRITE block exists:** the partition-spec-evolution question is high-stakes (3TB+ rewrites take hours; the wrong command can produce duplicate rows or NULL partition keys). Under pressure the temptation is to paste a remembered Spark/Hive/Impala syntax. Each banned form above has been observed as a confident-but-wrong response. **Always paste from this document.**
>
> ### Cross-references for the partition evolution workflow
>
> - **§"Partition evolution (changing partition spec later)"** later in this document — full rewrite details with the per-tenant safe alternative for scoped migrations.
> - **§"Bucket partitioning — the two production footguns"** — sizing N, `write.distribution-mode='hash'` requirement.
> - **Resource 17 §"Trino EXECUTE vs Spark CALL"** — the disambiguation matrix for every procedure call.
> - **Resource 17 §"Safe scheduling order"** — compaction → expire → orphan, never reversed.

---

## LEADING CANONICAL RECIPE — "How do I see this Iceberg table's CURRENT partition spec and properties on Trino 467?" (read this FIRST for inspection questions)

> **Keywords this block answers:** "show partitioning of an Iceberg table", "what's the current partition spec", "see table properties", "inspect Iceberg table on Trino", "what columns is this table partitioned by", "is partition evolution applied yet". **The FIRST tool to reach for is `SHOW CREATE TABLE`; the metadata tables `"<table>$properties"` and `"<table>$partitions"` cover the structured follow-ups.** Every form below has been verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) ("Metadata tables" section) and [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html) (System connector).
>
> ### Step 1 (canonical) — `SHOW CREATE TABLE` shows the bound partition spec verbatim
>
> ```sql
> -- This is the SINGLE most useful command for "what's the current partition spec".
> -- The Trino DDL docs explicitly state: "you can see the value with SHOW CREATE TABLE".
> SHOW CREATE TABLE iceberg.analytics.events;
> ```
>
> Expected output (abridged) — the `WITH (...)` clause contains the BOUND partition spec and properties for THIS table:
>
> ```sql
> CREATE TABLE iceberg.analytics.events (
>    event_id        BIGINT,
>    tenant_id       VARCHAR,
>    occurred_at     TIMESTAMP(6) WITH TIME ZONE,
>    payload         VARCHAR
> )
> WITH (
>    partitioning   = ARRAY['day(occurred_at)', 'bucket(tenant_id, 64)'],
>    format         = 'PARQUET',
>    format_version = 2,
>    location       = 's3a://lakehouse/warehouse/analytics/events'
> );
> ```
>
> Read the `partitioning = ARRAY[...]` line — that is the current spec.
>
> ### Step 2 (structured) — `"<table>$properties"` returns the table's BOUND key/value properties as rows
>
> ```sql
> -- Returns key/value pairs of properties actually set on the table.
> -- Columns: key VARCHAR, value VARCHAR (both NOT NULL).
> SELECT key, value
> FROM iceberg.analytics."events$properties"
> ORDER BY key;
> ```
>
> Expected output shape — one row per property bound on the table (`write.format.default`, `format-version`, `write.distribution-mode`, custom keys, etc.). The `partitioning` value itself is NOT a row in this view (it lives in the Iceberg schema's `partition-specs` metadata, surfaced via `SHOW CREATE TABLE`), but the surrounding properties (`write.target-file-size-bytes`, `write.distribution-mode`, `write.metadata.delete-after-commit.enabled`) ARE here. Use this when you need to programmatically diff property bags between tables or assert a property in CI.
>
> ### Step 3 (structured) — `"<table>$partitions"` enumerates partition VALUES with per-partition counts/sizes
>
> ```sql
> -- Columns (verified against trino.io/docs/current/connector/iceberg.html):
> --   partition        ROW(...)       -- struct with one field per partition column
> --   record_count     BIGINT
> --   file_count       INTEGER
> --   total_size       BIGINT
> --   data             ROW(...)       -- per-column min/max/null_count statistics
> SELECT
>   partition,
>   record_count,
>   file_count,
>   total_size
> FROM iceberg.analytics."events$partitions"
> ORDER BY partition DESC
> LIMIT 20;
>
> -- To access a specific partition field by name, dot into the struct:
> SELECT
>   partition.tenant_id     AS tenant_bucket,
>   partition.occurred_at_day AS day,         -- transform-named field
>   record_count,
>   file_count
> FROM iceberg.analytics."events$partitions"
> WHERE partition.tenant_id = 42
> ORDER BY day DESC;
> ```
>
> > **Field-name caveat for transforms.** When the partition spec contains a transform (e.g., `day(occurred_at)`, `bucket(tenant_id, 64)`), the resulting field name inside the `partition` struct is **transform-derived**, not the source column name. For `day(occurred_at)` the field is typically named `occurred_at_day`; for `bucket(tenant_id, 64)` it is `tenant_id_bucket`. If a dotted access fails, run the unqualified `SELECT partition FROM ...$partitions LIMIT 1` first and read the struct field names off the output — do NOT guess.
>
> ### DO-NOT-WRITE — banned forms for "see this table's partition spec"
>
> ```sql
> -- WRONG (a) — this query FABRICATES columns. system.metadata.table_properties
> -- is a REAL Trino system table, BUT its columns are
> --   (catalog_name VARCHAR, property_name VARCHAR, default_value VARCHAR,
> --    type VARCHAR, description VARCHAR)
> -- per https://trino.io/docs/current/connector/system.html.
> -- There is NO table_schema column, NO table_name column, NO property_key column,
> -- NO property_value column. Pasting this fails IMMEDIATELY at parse time with
> --   Column 'property_key' cannot be resolved
> SELECT property_key, property_value
> FROM system.metadata.table_properties
> WHERE table_schema = 'analytics'
>   AND table_name   = 'events'
>   AND property_key = 'partitioning';     -- WRONG: ALL FOUR REFERENCED COLUMNS ARE FABRICATED.
> ```
>
> > **Why the misconception keeps surfacing.** `system.metadata.table_properties` IS a real Trino system view — it just exposes a DIFFERENT thing. It enumerates the **AVAILABLE table-property NAMES** that each connector supports (e.g., for the `iceberg` catalog, it lists `partitioning`, `format`, `format_version`, `location`, `write.target-file-size-bytes`, ... — the menu of legal `WITH (...)` keys). It does **NOT** have per-table rows and does **NOT** expose the BOUND values for a specific table. The right query against it looks like this (verified against [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html) and [trinodb/trino #14000](https://github.com/trinodb/trino/issues/14000)):
> >
> > ```sql
> > -- CORRECT use of system.metadata.table_properties — list the property NAMES the Iceberg connector accepts.
> > -- Real columns: catalog_name, property_name, default_value, type, description.
> > SELECT catalog_name, property_name, default_value, type
> > FROM system.metadata.table_properties
> > WHERE catalog_name = 'iceberg'
> > ORDER BY property_name;
> > ```
> >
> > **To see the BOUND partition spec for a SPECIFIC TABLE, use `SHOW CREATE TABLE` (step 1) or `"<table>$properties"` (step 2). To enumerate partition VALUES, use `"<table>$partitions"` (step 3). The catalog-level `system.metadata.*` views are NEVER the right surface for "what is THIS table's partition spec".**
>
> ### Other banned forms
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `SELECT * FROM system.metadata.table_properties WHERE table_name = 'events'` | Same fabrication as above — no `table_name` column on this view. | `SHOW CREATE TABLE iceberg.analytics.events` |
> | `SELECT partitioning FROM information_schema.tables WHERE table_name = 'events'` | Trino's `information_schema.tables` (per [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html)) exposes `table_catalog, table_schema, table_name, table_type` — no `partitioning` column. | `SHOW CREATE TABLE iceberg.analytics.events` |
> | `DESCRIBE iceberg.analytics.events` to see partitioning | `DESCRIBE` shows column names + types ONLY, not the partition spec. Engineers running `DESCRIBE` and seeing no partition info sometimes conclude the table is unpartitioned. | `SHOW CREATE TABLE iceberg.analytics.events` |
> | `SELECT * FROM iceberg.analytics.events_partitions` (no quoting, underscore form) | The Iceberg connector requires the `$`-suffix metadata table to be quoted as `"events$partitions"` — without quoting, Trino looks for a real table named `events_partitions`. | `SELECT * FROM iceberg.analytics."events$partitions"` |
> | `SELECT * FROM iceberg.analytics.events."$partitions"` (split quoting) | The whole `events$partitions` token must sit inside ONE pair of double quotes; splitting the quote produces `Column 'partition' cannot be resolved` or schema errors. | `SELECT * FROM iceberg.analytics."events$partitions"` |
>
> ### Meta-rule (memorize this)
>
> > **If you want to introspect a SPECIFIC TABLE's properties / partition spec / column statistics, use `SHOW CREATE TABLE` or the `"<table>$<metatable>"` Iceberg metadata tables (`$properties`, `$partitions`, `$files`, `$snapshots`, ...). NEVER use the catalog-level `system.metadata.*` views — those describe what the CONNECTOR supports, not what THIS TABLE is bound to.**
>
> ### Cross-references
>
> - Resource 17 §"Iceberg metadata tables cheat sheet" — full column lists for `$snapshots`, `$files`, `$partitions`, `$manifests`, `$history`, `$refs`, `$properties`.
> - Resource 17 §"Metadata-table quoting — canonical Trino syntax" — the canonical quoting rule for every `$`-suffix table.
> - Resource 24 §"Statistics inspection" — `SHOW STATS FOR <table>` for CBO statistics (different surface, different question).

---

## PARTITIONS-ARE-NOT-FILES — read before estimating file counts

> **GUARDRAIL — Partition count NEVER equals file count.** A *partition* in Iceberg is a **logical grouping** (one distinct partition-key value, e.g., `day=2026-05-01` or `(day=2026-05-01, tenant_id='acme')`). The number of *data files* inside that partition is a separate, downstream quantity driven by three independent forces. **A partition typically holds many data files.** State this in every answer that estimates file counts from partition counts.

### Three forces that drive files-per-partition

1. **Target file size.** Iceberg's write target is set by the `write.target-file-size-bytes` table property — **default 512 MB** per [iceberg.apache.org/docs/latest/configuration/#write-properties](https://iceberg.apache.org/docs/latest/configuration/#write-properties). Trino's `EXECUTE optimize` accepts a `file_size_threshold` argument (default `100MB` — files larger than this are skipped during routine compaction; raise it for one-shot rewrites). Spark's `rewrite_data_files` accepts `target-file-size-bytes` in `options`. A partition holding more bytes than the target produces more files: `files_per_partition ≈ partition_bytes / target_file_size`.

2. **Ingestion cadence.** **EVERY write/commit adds AT LEAST one new file per partition it touches.** A streaming or micro-batch ingestion job that commits every 15 minutes touches the current day-partition 96 times/day → at least 96 new files/day land in that partition, regardless of how small each file is. Daily compaction reduces them, but until compaction runs, files-per-partition is `commits_per_day × writer_parallelism`.

3. **Writer parallelism.** Each Spark task (or Trino writer) emits its own Parquet file per partition it touches. A Spark job with 200 executors that writes to one day-partition produces up to 200 files for that partition in a single commit (unless `write.distribution-mode = 'hash'` is set — see the bucket-partitioning section for why this matters for bucket-partitioned tables).

### Worked example — 500M rows / 18 months partitioned monthly

The wrong claim (frequently stated): *"18 monthly partitions = ~18 files at most, one file per month."*

The correct math:
- 500M rows / 18 months ≈ 27.8M rows per month-partition.
- At an average row size of ~2 KB (typical SaaS event with a few JSON-ish columns), each month-partition ≈ 27.8M × 2 KB ≈ **~54 GB**.
- At Iceberg's default 512 MB target file size, that's `54 GB / 512 MB ≈ 108 files per month-partition`.
- 18 partitions × 108 files ≈ **~2,000 total data files**, not 18.

If the table is ingested via 15-min micro-batches without compaction, the live count is *much* higher — easily 5,000–20,000 files before the nightly `EXECUTE optimize` runs. **Compaction is what brings file count back toward the target-file-size estimate; it is also why compaction exists.**

### DO-NOT-WRITE list (banned framings)

When asked "how many files will N partitions produce?" or "what's the file count for monthly vs daily partitioning?", **never** write any of these:

- **"N partitions = N files"** — FALSE.
- **"One file per partition"** — FALSE (except in the trivial case of one tiny commit that hasn't been compacted yet, and even then only at writer parallelism 1).
- **"Monthly partitioning = ~12 files/year"** — FALSE.
- **"18 month-partitions = ~18 files at most"** — FALSE (iter434 confident-inaccuracy template; this exact phrasing produced the iter434 Q4 dock).
- **"547 day-partitions = ~547 files"** — FALSE for the same reason.
- **Any phrasing that treats `partition_count` as a proxy for `file_count`** — wrong abstraction.

The correct framing is always: **"18 month-partitions vs 547 day-partitions; the *file count per partition* is a separate concern determined by target-file-size and ingestion cadence — count actual files via `$partitions.file_count` or `$files WHERE content=0`."**

### How to see the ACTUAL file counts (run these queries, don't guess)

Iceberg exposes two metadata tables for this exact question (verified at [iceberg.apache.org/docs/latest/spark-queries/#inspecting-tables](https://iceberg.apache.org/docs/latest/spark-queries/#inspecting-tables) and the Trino Iceberg connector's metadata tables docs at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html)):

```sql
-- Method 1: $partitions has a `file_count` column per partition — the fastest answer
-- to "how many files does each partition hold?". Works in both Trino and Spark.
SELECT
  partition,
  record_count,
  file_count,
  total_size
FROM iceberg.analytics."events$partitions"
ORDER BY file_count DESC
LIMIT 20;

-- Method 2: $files lists EVERY data file. Group by partition for an exact count.
-- content = 0 is a data file (vs 1 = position delete file, 2 = equality delete file).
SELECT
  partition,
  COUNT(*) AS files,
  SUM(file_size_in_bytes) / 1024 / 1024 AS total_mb,
  AVG(file_size_in_bytes) / 1024 / 1024 AS avg_mb
FROM iceberg.analytics."events$files"
WHERE content = 0
GROUP BY partition
ORDER BY files DESC
LIMIT 20;

-- Method 3: total file count and average per partition — sanity check.
SELECT
  COUNT(DISTINCT partition) AS partitions,
  COUNT(*)                  AS files,
  CAST(COUNT(*) AS DOUBLE) / COUNT(DISTINCT partition) AS files_per_partition_avg
FROM iceberg.analytics."events$files"
WHERE content = 0;
```

If `files_per_partition_avg` is ≥ 1 and well above 1 on a non-trivial table, that confirms the rule: **partitions are logical groupings, files are physical artifacts, and there are typically many of the latter inside each of the former.** If you see a very small `file_count` (e.g., 1–2) on a busy partition, that means compaction has been aggressive and the partition is already at target size — that's the *goal* state of compaction, not the default state.

### Q-pattern matcher — when the question is "how many files will N partitions have?"

| Question shape | Correct answer shape |
|---|---|
| "I'll have 18 monthly partitions for 500M rows — how many files is that?" | **Files ≠ partitions.** "18 month-partitions, but each partition holds many files. At ~27M rows/month and 512MB target, expect ~100+ files per partition before compaction. Use `$partitions.file_count` to see actual counts on your table." |
| "Will monthly partitioning give me 12 files/year?" | **No.** "Monthly = 12 partitions/year, NOT 12 files/year. File count per partition depends on data volume and target-file-size; a busy table has dozens to hundreds of files per month-partition." |
| "How do I count files in my table?" | "Use `SELECT COUNT(*) FROM tbl\$files WHERE content=0` (data files only). For per-partition counts, `SELECT partition, file_count FROM tbl\$partitions`." |
| "Why are there 5,000 files in my one month-partition?" | "Frequent commits (each adds at least one file per partition touched) and writer parallelism (each Spark task emits one file). Run `EXECUTE optimize` or Spark `rewrite_data_files` to compact toward target-file-size." |

### Cross-references

- The "small-files problem" section below covers what to do when files-per-partition gets out of hand (compaction).
- The "Bucket partitioning — the two production footguns" section covers a specific case where forgetting `write.distribution-mode = 'hash'` causes per-commit file counts to multiply by writer count × bucket count.
- The "Don't over-partition time" anti-pattern covers the dual failure mode: too many partitions, each one too small to hold healthy files.
- Resource 17 (Iceberg table maintenance) covers `$partitions` and `$files` metadata tables in depth, including the `spec_id` column for diagnosing partition-evolution rewrite progress.

---

## Why partitioning matters

Without partitioning, every query scans every Parquet file in the table.

- **10 TB table, no partitions:** any query reads the full 10 TB. Even with columnar pruning down to a few columns, that's hundreds of GB of I/O.
- **10 TB table, partitioned by day:** a query for one month reads only that month's files, roughly 10 TB ÷ 12 = ~830 GB. A query for one day reads ~30 GB.

This skipping is called **partition pruning** or **file skipping** — Iceberg checks each file's partition metadata against your `WHERE` clause and never opens files that can't match.

### The wins compound
- Columnar storage → reads only the columns you need (5x–20x reduction).
- Partition pruning → reads only the files that match (10x–100x reduction).
- File-level min/max stats (in Iceberg manifests) → skips entire files whose min/max range proves the predicate value cannot be present (2x–10x — but only if the data inside each file is physically clustered, see next section).
- Row-group min/max stats (in Parquet footers) → within each file Iceberg does open, reads only the row groups whose stats overlap the predicate (2x–10x).

Together, a well-designed query touches <1% of the table's bytes.

---

## How Iceberg file pruning actually works (read this before partition design)

There are **three independent pruning layers** in an Iceberg + Parquet read. Most "queries are slow" diagnostics go wrong because engineers conflate them. Get them straight before you change a partition spec.

| Layer | Lives in | Granularity | What it prunes by |
|---|---|---|---|
| **Partition pruning** | Iceberg manifests (the `partition` struct field) | Whole files | Partition spec columns/transforms (e.g., `day(occurred_at)`, `tenant_id`, `bucket(tenant_id, 64)`) |
| **File-level min/max pruning** | Iceberg manifests (the `lower_bounds` / `upper_bounds` maps) | Whole files | **Any column** — Iceberg stores per-column min/max for every column by default |
| **Row-group pruning** | Parquet file footers | Row groups inside a file (~10–100 MB chunks) | Any column — Parquet stores per-column min/max per row group |

### The single most common misconception

> **WRONG:** "File-level pruning requires the filtered column to be in the partition spec. If `plan_type` isn't a partition column, Iceberg can't skip files based on it."
>
> **CORRECT:** "Iceberg stores `lower_bounds` and `upper_bounds` in the manifest entry for **every** column, not just partition columns. File-level pruning works for any column — but only if the data inside each file is physically clustered or sorted so the column's min/max range within that file is **narrow enough to prove the filter value is absent**."

Verify it yourself — the Iceberg table spec defines manifest entries with `lower_bounds: map<int, binary>` and `upper_bounds: map<int, binary>` keyed by **field ID for every column** (not just partition fields). Spark/Trino populate both maps on every write.

### Why `WHERE plan_type = 'enterprise'` on a day-partitioned table doesn't skip files

A common day-partitioned event table with a low-cardinality `plan_type` column ('basic', 'pro', 'starter', 'enterprise'):

```sql
CREATE TABLE iceberg.analytics.user_events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  plan_type   VARCHAR,        -- one of: 'basic', 'pro', 'starter', 'enterprise'
  occurred_at TIMESTAMP(6),
  ...
)
WITH (
  partitioning = ARRAY['day(occurred_at)'],   -- plan_type NOT in partition spec
  format = 'PARQUET'
);
```

Run:
```sql
SELECT COUNT(*) FROM iceberg.analytics.user_events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
  AND plan_type = 'enterprise';
```

You see: partition pruning correctly cuts to May's files, but **zero** files inside May are skipped by the `plan_type` filter. Why?

**Not because `plan_type` is missing from the partition spec.** Iceberg DOES track per-file min/max for `plan_type` — go look at `SELECT * FROM iceberg.analytics."user_events$files"` and you'll see `lower_bounds` and `upper_bounds` maps populated for every column, including `plan_type`.

**The real reason:** events are written in arrival order. Each Spark task writes a file containing a random mix of all plan types. So for every file in May:

```
file 00001-1.parquet:  plan_type lower_bound = 'basic',  upper_bound = 'starter'
file 00001-2.parquet:  plan_type lower_bound = 'basic',  upper_bound = 'starter'
file 00001-3.parquet:  plan_type lower_bound = 'basic',  upper_bound = 'starter'
...every file is identical: 'basic' .. 'starter'.
```

Iceberg's pruner checks: "is 'enterprise' in the range ['basic', 'starter']?" Answer: yes (alphabetically, 'enterprise' falls between 'basic' and 'starter'). So **no file can be proved safe to skip**. The pruning machinery is working; it just has no narrow ranges to work with.

**The fix is to narrow the per-file min/max ranges by physically clustering the data, not to add `plan_type` to the partition spec.**

### Fix 1 (canonical, recommended): cluster files by sort order

Iceberg can cluster rows within each file by a sort key so that most files contain only one or two `plan_type` values — after which the manifest min/max range narrows enough for pruning to skip non-matching files. There are **two ways** to do this on the production stack; pick by engine first.

> **ENGINE-CONFUSION GUARDRAIL.** The single most common iter-failure pattern in this resource family was pasting Spark CALL named-arg syntax `rewrite_data_files(sort_order => ARRAY[...])` into a Trino `ALTER TABLE ... EXECUTE` statement. **Trino 467 has no `rewrite_data_files` EXECUTE procedure** — it returns `Procedure not registered`. The Trino-467-native clustering path is `sorted_by` table property + `EXECUTE optimize`, shown FIRST below. The Spark CALL form follows as the fallback for cases the Trino-native path can't cover (z-order, `rewrite-all=true`, post-partition-evolution). See [resources/17 — Trino EXECUTE vs Spark CALL disambiguation matrix](17-iceberg-table-maintenance.md#trino-execute-procedures-vs-spark-call-procedures--the-engine-confusion-disambiguation-matrix-read-before-writing-any-procedure-call) for the full reference.

#### Path A (Trino 467 native, no Spark required) — `sorted_by` + `EXECUTE optimize`

The Trino Iceberg connector's `sorted_by` table property is in the modifiable-properties list (since Trino release 409 via [PR #14891](https://github.com/trinodb/trino/pull/14891)). Setting it then running `EXECUTE optimize` produces files sorted by the listed columns. **Use this as the default Trino-only path for lexicographic clustering by one or more columns.**

```sql
-- Trino 467 (CORRECT — this is the only first-class Trino path to cluster by a column).
-- Step 1: set the table's sort order. Multi-column lex sort is supported.
ALTER TABLE iceberg.analytics.user_events
  SET PROPERTIES sorted_by = ARRAY['plan_type ASC NULLS LAST', 'occurred_at ASC'];

-- Step 2: rewrite existing files so they pick up the sort order.
-- IMPORTANT: file_size_threshold must be LARGER than your existing files
-- to force a rewrite. Default '100MB' skips files larger than that, which is
-- what you want for routine compaction but NOT for one-shot sort migration.
ALTER TABLE iceberg.analytics.user_events
  EXECUTE optimize(file_size_threshold => '512MB');

-- Verify the sort took effect via the $files metadata table.
SELECT
  CAST(lower_bounds['plan_type'] AS VARCHAR) AS plan_lo,
  CAST(upper_bounds['plan_type'] AS VARCHAR) AS plan_hi,
  count(*) AS files
FROM iceberg.analytics."user_events$files"
WHERE content = 0
GROUP BY 1, 2
ORDER BY files DESC;
-- After sort: most rows show plan_lo = plan_hi (each file holds one plan_type).
```

> **WRONG syntax (do NOT recommend — Spark CALL form pasted into Trino EXECUTE).** Each line below is Spark CALL syntax that Trino 467 rejects:
> ```sql
> -- WRONG: rewrite_data_files is NOT a Trino EXECUTE procedure.
> ALTER TABLE iceberg.analytics.user_events EXECUTE rewrite_data_files(sort_order => ARRAY['plan_type']);
> ALTER TABLE iceberg.analytics.user_events EXECUTE rewrite_data_files(strategy => 'sort', sort_order => 'plan_type ASC');
> -- WRONG: Trino's optimize does NOT accept sort_order or strategy arguments.
> ALTER TABLE iceberg.analytics.user_events EXECUTE optimize(sort_order => 'plan_type');
> ALTER TABLE iceberg.analytics.user_events EXECUTE optimize(strategy => 'sort');
> ```

#### Path B (Spark CALL fallback) — when Trino-native isn't enough

Drop to Spark `CALL iceberg.system.rewrite_data_files` only when the Trino-native path can't cover the case. Specifically: **z-order**, **rewrite-all-true** (force rewrite of every file regardless of size — needed after partition evolution), **`delete-file-threshold`** (compact MoR files with many delete entries), or richer tuning.

```sql
-- Spark SQL only. Do NOT paste this into a Trino session as ALTER TABLE ... EXECUTE
-- rewrite_data_files(...) — Trino 467 has no such procedure (Procedure not registered).
CALL iceberg.system.rewrite_data_files(
  table      => 'analytics.user_events',
  strategy   => 'sort',
  sort_order => 'plan_type ASC NULLS LAST, occurred_at ASC',
  options    => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'rewrite-all',            'true'        -- force rewrite all files for initial sort
  )
);
```

> **CAUTION — `rewrite-all => 'true'` rewrites EVERY file in the table.** This is intentional and required for the initial sort migration (a normal bin-pack strategy would skip files that are already well-sized but unsorted). But on a multi-TB table, expect the job to run for **hours** and consume substantial Spark cluster resources — schedule it during a maintenance window, not in the middle of business hours.
>
> **Known bug — do NOT combine `rewrite-all=true` with a `where` predicate.** [apache/iceberg #14667](https://github.com/apache/iceberg/issues/14667): using `rewrite-all=true` together with `where => '...'` can produce **duplicate rows** in the rewritten partition. Until the bug is fixed, only use `rewrite-all=true` without a `where` clause (i.e., for whole-table rewrites). If you need per-partition rewrite-all behavior (e.g., for post-partition-evolution migration scoped to one tenant), the safe alternative is to drop `rewrite-all=true` and use the default bin-pack strategy with `min-input-files=1` — see the partition-evolution section below for details.

After this runs, each file holds a contiguous run of one plan type (or two adjacent ones). Files that contain only `'basic'` rows have `lower_bound = upper_bound = 'basic'` — the pruner now proves they cannot match `plan_type = 'enterprise'` and skips them entirely. On a typical workload this reduces the bytes read for the `enterprise` filter from 100% of May's files to ~2% (the 'enterprise' share).

**Use sort as the default fix when:** the filtered column is low-cardinality (4–100 distinct values) and is not a good partition candidate (skew, see below). This is the standard Iceberg pattern for non-partition column pruning.

For higher-cardinality clustering — e.g., a `user_id` filter on a multi-billion-row table — use `zorder` instead of `sort` (multi-column clustering with no leading-column bias):

```sql
-- Spark SQL only. Trino 467 has no rewrite_data_files EXECUTE procedure, and
-- Trino's sorted_by is lexicographic only (no z-order support). For multi-column
-- z-order clustering, Spark is the only path on this stack.
CALL iceberg.system.rewrite_data_files(
  table      => 'analytics.user_events',
  strategy   => 'sort',
  sort_order => 'zorder(user_id, session_id)'
);
```

### Fix 2 (optional): Parquet bloom filters for HIGH-cardinality equality predicates

**Use bloom filters on HIGH-cardinality columns** (UUIDs, `user_id`, `order_id`, `session_id`, `trace_id`, `event_id`) where equality predicates are common. **Do NOT use bloom filters on low-cardinality columns** (`status`, `country_code`, `plan_type`, `currency`) — dictionary encoding already handles those efficiently and Parquet's per-row-group min/max statistics already prune them well. Adding a bloom filter on a low-cardinality column just adds write overhead and file-size bloat with little to no skipping benefit.

**Why high cardinality benefits most.** For a UUID like `event_id = 'abc123...'`, every row group's min/max range covers basically the full ID space — min/max pruning skips nothing. The bloom filter is the only structure that can answer "is this specific ID in this row group?" without reading the column data. For a low-cardinality column like `country_code = 'JP'`, almost every row group contains some `'JP'` rows (or none of them, in which case min/max already tells you that), so the bloom filter does not add prune power beyond min/max + dictionary encoding.

For HIGH-cardinality equality filters (`WHERE event_id = ?`, `WHERE user_id = ?`, `WHERE session_id = ?`), Parquet **bloom filters** let the Parquet reader answer "is this value possibly in this row group?" in microseconds without reading any column data. If the bloom filter says no, the entire row group is skipped.

Bloom filters are configured at write time as Iceberg table properties. Set per-column:

```sql
-- Spark SQL (Trino's Iceberg connector uses a different property name — see below)
ALTER TABLE iceberg.analytics.user_events SET TBLPROPERTIES (
  'write.parquet.bloom-filter-enabled.column.event_id'      = 'true',
  'write.parquet.bloom-filter-fpp.column.event_id'          = '0.01',
  'write.parquet.bloom-filter-max-bytes'                    = '1048576'
);
```

```sql
-- Trino's Iceberg connector exposes a separate table property
ALTER TABLE iceberg.analytics.user_events
  SET PROPERTIES parquet_bloom_filter_columns = ARRAY['event_id', 'user_id'];
```

Once set, future writes embed a bloom filter for the configured columns in each Parquet row group. Trino's Parquet reader consults the filter before reading column data. Bloom filters add ~1–5% to file size; they pay off only for selective equality predicates on **high-cardinality** columns.

**Bloom filters do NOT apply to historical files.** To bake them into existing files, re-run a Spark `CALL iceberg.system.rewrite_data_files(table => '...', options => map('rewrite-all', 'true'))` after enabling the table property (Spark only — Trino's `EXECUTE optimize` cannot force-rewrite files that are already at target size, which is what you need for retrofit).

**When NOT to use bloom filters:**
- Low-cardinality columns (`<1000` distinct values): use dictionary encoding + min/max — they already prune well.
- Range predicates (`WHERE amount > 100`): bloom filters only help equality.
- Columns rarely used as a filter: pure write-side overhead with no read-side payoff.

### Fix 3 (anti-pattern): adding `plan_type` to the partition spec

You CAN add `plan_type` to the partition spec — but for a 4-value low-cardinality column with **uneven distribution**, this is an anti-pattern. Suppose plan share is 80% 'basic', 15% 'pro', 3% 'starter', 2% 'enterprise':

| Plan | Daily events (out of 10M) | Files per day (256 MB target) |
|---|---|---|
| basic | 8,000,000 | ~30 large files |
| pro | 1,500,000 | ~6 files |
| starter | 300,000 | ~1 file (well below target) |
| enterprise | 200,000 | ~1 tiny file (<64 MB) |

Problems this creates:
1. **Partition skew on writes.** The 'basic' partition is 40× larger than the 'enterprise' partition. Spark tasks writing 'basic' run 40× longer than tasks writing 'enterprise' — the longest task is the wall-clock latency of the whole job.
2. **Compaction skew.** `rewrite_data_files` per-partition cost scales with partition size — the 'basic' partition takes 40× longer to compact.
3. **Small-file problem on small plans.** The 'starter' and 'enterprise' partitions accumulate tiny files (<64 MB) that compaction can never grow to target size, because each daily partition only holds one plan type's worth of rows.
4. **Partition count explosion.** Combined with `day(occurred_at)` and `tenant_id`, you now have `days × tenants × 4` partitions — and most of those `(day, tenant, enterprise)` cells hold a handful of KB.

**Rule of thumb:** never partition by a column with <100 distinct values **and uneven distribution**. Sort-cluster it instead. Bucket-partitioning doesn't help here either — with 4 distinct values and any reasonable `N`, collisions force most buckets to hold all 4 plans.

### When to use which fix

| Situation | Fix |
|---|---|
| Low-cardinality column, occasional equality filter | Sort (`rewrite_data_files` with `strategy='sort'`) — rely on dictionary encoding + min/max, do NOT add bloom filter |
| Low-cardinality column, frequent equality filter, latency-critical | Sort by that column — min/max + dictionary encoding handle it; bloom filter is wasteful |
| High-cardinality column with point lookups (`user_id = ?`, `session_id = ?`, `event_id = ?`) | **Parquet bloom filter** + sort (or zorder if multi-column) |
| Time-range scan with secondary high-cardinality filter | Day partition + sort on the secondary column within the day |
| Predicate is on a column that genuinely partitions evenly (e.g., `region` with 4 ~equal regions) | OK to add to partition spec |

### Verifying file skipping actually fired

In Trino, run `EXPLAIN ANALYZE` on your query and look at the table scan node — it reports `Input: <N> rows, <X> bytes` and the number of files read. Compare:

```sql
EXPLAIN ANALYZE
SELECT COUNT(*) FROM iceberg.analytics.user_events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
  AND plan_type = 'enterprise';
```

- **Before sort:** Input bytes ≈ full May scan (no `plan_type` skipping).
- **After sort:** Input bytes drops to ~2% of May (only the 'enterprise' files).
- **After sort + bloom filter:** Input bytes drops further as row groups within partial files also skip.

If you do not see a drop after the rewrite (either Trino's `EXECUTE optimize` or Spark's `rewrite_data_files`), check that the rewrite actually completed (use the `$files` query in the partition-evolution section to see file counts and sort order) and that the predicate is on the same column you sorted by.

---

## Iceberg hidden partitioning

In old Hive tables, partitions were literal directories named `year=2024/month=03/day=15/`. Engineers had to write:

```sql
-- HIVE-STYLE: brittle, easy to forget
WHERE year = 2024 AND month = 3 AND day = 15 AND event_time >= '2024-03-15 00:00:00'
```

Forget the partition predicate → full table scan.

Iceberg fixes this. You declare the **partition spec** once at table creation.

> **ENGINE LABEL — two syntaxes for partition specs, same result:**
>
> **Trino DDL** (run in Trino query console — use this for one-off table creation from the query layer):
> ```sql
> CREATE TABLE iceberg.analytics.user_events (
>   event_id    VARCHAR,
>   tenant_id   VARCHAR,
>   user_id     VARCHAR,
>   event_name  VARCHAR,
>   occurred_at TIMESTAMP(6),
>   ...
> )
> WITH (
>   partitioning = ARRAY['day(occurred_at)', 'tenant_id'],
>   format = 'PARQUET'
> );
> ```
>
> **Spark SQL DDL** (run in a Spark session or ingestion job — use this for tables created from Spark):
> ```sql
> CREATE TABLE iceberg.analytics.user_events (
>   event_id    STRING,
>   tenant_id   STRING,
>   user_id     STRING,
>   event_name  STRING,
>   occurred_at TIMESTAMP,
>   ...
> )
> USING iceberg
> PARTITIONED BY (day(occurred_at), tenant_id);
> ```
>
> Both DDLs create the same Iceberg table — same partition spec, same result. Trino uses `WITH (partitioning = ARRAY[...])`. Spark uses `PARTITIONED BY (...)`. If you paste the Trino DDL into a Spark SQL shell or the Spark DDL into Trino, you get a syntax error.
>
> **WATCH OUT — `bucket()` argument order differs between engines.** This is the #1 copy-paste pitfall when moving DDL between Trino and Spark. The bucket transform name is the same in both engines but the argument order is **reversed**:
>
> - **Trino syntax: `bucket(column, N)`** — column first, bucket count second. Example (inside a Trino `WITH (partitioning = ARRAY[...])` clause): `'bucket(tenant_id, 64)'`.
> - **Spark SQL syntax: `bucket(N, column)`** — bucket count first, column second. Example (inside a Spark `PARTITIONED BY (...)` clause): `bucket(64, tenant_id)`.
>
> Same Iceberg transform on disk; different SQL spelling. Mixing them up gives you a parse error (when types don't match — e.g., a string in the int position) or, worse, silent acceptance with the wrong column being treated as the bucket count. **Every `bucket(...)` example in this document is written in Trino column-first form** (because the production query engine is Trino 467). If you copy a snippet into a Spark SQL session, swap the argument order: `bucket(tenant_id, 64)` → `bucket(64, tenant_id)`.

Then you write **normal SQL**:

```sql
SELECT COUNT(*)
FROM iceberg.analytics.user_events
WHERE occurred_at >= TIMESTAMP '2026-03-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-04-01 00:00:00'
  AND tenant_id = 'acme';
```

Trino translates your `occurred_at` predicate into the partition filter automatically. No `day=...` clause needed.

**Why this matters:** new team members write correct, fast queries by default. They can't accidentally bypass partitioning.

---

## Common partition strategies for SaaS

| Strategy | When to use | Watch out for |
|---|---|---|
| `day(event_ts)` | Most SaaS event tables; daily dashboards | Small files on low-volume days |
| `month(event_ts)` | Lower-volume tables (e.g., `subscription_changes`) | Larger partitions = less pruning granularity |
| `(tenant_id, day(event_ts))` | B2B SaaS with many tenants; per-tenant queries common | Partition explosion if you have thousands of tenants |
| `(day(event_ts), tenant_id)` | Same as above, but most queries are time-range first | Same; order affects file layout but not pruning |
| `bucket(tenant_id, 64)` | Many small tenants where you want even file sizes | Fixed fan-out; equality filter prunes to 1 bucket; range queries open one bucket per value. **Requires `write.distribution-mode = 'hash'` table property (see "Bucket partitioning — the two production footguns" below) or every Spark commit writes N tiny files per task.** Per-tenant `COUNT(*)` is NOT metadata-only — see the metadata-only callout above. |
| `truncate(user_id, 1)` | Rare — only when user_id queries dominate | Usually time-based is better |
| No partitioning | Dimension tables (small), lookup tables | Never for fact tables over ~10 GB |

**Bucket pruning for equality filters:** When you query `WHERE tenant_id = 'acme'`, Iceberg computes `bucket('acme', 64)` to find the matching bucket number, then prunes all other 63 bucket partitions. An equality filter reads **1 bucket, not all N buckets**. The limitation of `bucket()` is not that it skips pruning — it is that range queries (`WHERE tenant_id IN (...)` with multiple tenants) must open one bucket per distinct value in the IN list.

### Choosing between `day()` and `(tenant_id, day())`

- **Pick `day(occurred_at)` alone** if: most queries are cross-tenant (internal dashboards, totals), or you have fewer than ~20 tenants.
- **Pick `(day(occurred_at), tenant_id)`** if: you have a mix of cross-tenant time-range queries (WAU, monthly revenue) and per-tenant dashboards. Day-first is the safer default — see "Why partition order matters" below.
- **Pick `bucket(tenant_id, 64)` + `day(occurred_at)`** if: you have hundreds to thousands of tenants and they vary wildly in size — the bucket keeps file counts manageable. **See "Bucket partitioning — the two production footguns" below for the required `write.distribution-mode = 'hash'` table property and how to choose N.** Be aware that bucket partitioning gives up the metadata-only per-tenant `COUNT(*)` optimization (see the metadata-only callout above).

### Why partition order matters: day-first vs tenant-first

> **CRITICAL CLARIFICATION — partition declaration order does NOT affect Iceberg's partition-pruning capability.** This is the single most common misconception engineers carry over from Hive-style partitioning. **In Iceberg, a query with `WHERE tenant_id = 'acme' AND occurred_at BETWEEN '2026-05-01' AND '2026-05-31'` prunes on BOTH fields regardless of whether the partition spec is declared as `ARRAY['day(occurred_at)', 'tenant_id']` (day-first) or `ARRAY['tenant_id', 'day(occurred_at)']` (tenant-first).** Iceberg stores per-file partition values in the manifest as a struct with named fields; the pruner evaluates each predicate against each field independently. There is no leading-key-only restriction the way some database indexes have.
>
> **What partition declaration order DOES affect** (so the recommendation to default day-first is still defensible — just for the right reasons):
> 1. **Write-side file clustering.** Iceberg writers group rows by the partition tuple before writing Parquet files. With `day-first`, all rows for the same day land in the same physical "directory" (`day_occurred_at=2026-05-25/tenant_id=acme/...`) — better compression because adjacent rows on disk are temporally close (similar event types, similar URLs, similar user agents). With `tenant-first`, rows for the same tenant cluster together, which compresses well for per-tenant skew but worse for time-range scans.
> 2. **Manifest file organization.** Iceberg's manifests are sorted on the leading partition field. A single manifest file tends to cover a contiguous range of the leading field — so listing/pruning manifests for a query that filters on the **leading** field can drop more manifests early, before any per-file partition struct evaluation. The effect is real but small at moderate partition counts; it matters mostly at 100K+ partitions.
> 3. **Small-file accumulation patterns from incremental writes.** Incremental writes (one Spark job per day) produce one new partition's worth of files per run with day-first, vs N tenant-shaped files per run with tenant-first — the day-first layout is friendlier to incremental compaction.
>
> **What partition declaration order does NOT affect:**
> - Which predicates can prune partitions. **Both fields prune independently regardless of declaration order.** A `WHERE tenant_id = 'acme'`-only query prunes to acme's files under either declaration order; a `WHERE occurred_at BETWEEN ...`-only query prunes to the date range under either declaration order.
> - The set of files a query touches when **both** fields appear in the WHERE clause — it's identical under either order.
> - The set of partition values that exist. The same set of `(day, tenant_id)` partition tuples is produced regardless of declaration order.
>
> **Why day-first is still the SaaS default — the right reasoning.** Most SaaS analytical workloads have time-range predicates (`last 30 days`, `last week`, `this month`) across all tenants — funnel analyses, retention cohorts, cross-tenant billing rollups. Day-first clustering compresses better for those scans (similar timestamps adjacent on disk), keeps manifests smaller per-day-range, and produces cleaner small-file patterns for daily incremental ingestion. **It is a write-side and storage-shape optimization, not a query-pruning unlock.** If your workload were dominated by per-tenant scans (e.g., a per-tenant single-tenant dashboard product where >99% of queries have `WHERE tenant_id = ?`), tenant-first would compress better — but day-first still prunes every query correctly.

Iceberg's partition spec is an ordered list. The order does **not** change which files are pruned — partition pruning is set-based, both columns prune independently — but it does change **how files are physically grouped on disk**, which changes I/O efficiency for queries that filter on only one of the two columns.

**Day-first ordering — `ARRAY['day(occurred_at)', 'tenant_id']`** — groups files for the same day together, with tenant as a sub-grouping inside each day. This is the right default for SaaS because:

- A query like "weekly active users across all tenants for the last 4 weeks" filters by `occurred_at` only. Day-first clustering means the day's files are contiguous on disk — better compression, better sequential I/O, smaller manifests for the date range. The pruner would still prune to those days under tenant-first, but the files would be scattered across N tenant directories instead of clustered in 28 day directories.
- A query like "show acme's signups last week" filters by both `occurred_at` and `tenant_id`. **Pruning works identically under either declaration order** — the engine reads exactly acme's files for last week's date range. The layout choice doesn't change which files are read; it just changes compression density.

**Tenant-first ordering — `ARRAY['tenant_id', 'day(occurred_at)']`** — groups files per tenant first, with day inside. **It does NOT block cross-tenant time-range pruning** — those queries still prune to the date range — but the files for any single day are scattered across N tenant directories, hurting compression density and producing more, smaller manifest entries for cross-day scans. This only beats day-first when **nearly every query** has a `WHERE tenant_id = ?` filter, in which case per-tenant files clustering together gives better compression for the dominant workload. If you serve a mix of customer-facing per-tenant dashboards and internal cross-tenant dashboards, day-first wins on average on storage efficiency — not on pruning capability.

**Rule of thumb:** unless 100% of your queries filter on tenant_id, default to `ARRAY['day(occurred_at)', 'tenant_id']`. The reason is **write clustering and compression**, not partition pruning — pruning works on both fields in either order.

**Concrete example of the misconception, and the truth.**

| Misconception (wrong) | Reality |
|---|---|
| "If I switch from day-first to tenant-first, my per-tenant queries get faster because tenant_id is now the leading partition column and prunes first." | False. Per-tenant queries are already optimal under day-first — the pruner evaluates `tenant_id` independently regardless of position. The tenant-first switch may slightly improve per-tenant **scan compression** (acme's rows clustered together on disk) but does not unlock any new pruning. |
| "If I switch from day-first to tenant-first, my cross-tenant time-range queries break because `occurred_at` is no longer the leading partition column." | False. Cross-tenant time-range queries still prune to the date range under either order. The scan efficiency is worse under tenant-first (files for May 24 are scattered across 80 tenant directories instead of clustered in one day directory), but no files outside the date range are touched. |
| "Iceberg's partition pruning behaves like a Hive-style or Postgres-style multi-column index — only the leading column prunes efficiently." | False. Iceberg's manifests store per-file partition tuples as named struct fields; the pruner evaluates each predicate against each field independently and drops files that don't match any predicate. There is no leading-key restriction. |

### Partition spec for the 80-tenant SaaS case
For ~80 tenants with mixed sizes, `PARTITIONED BY (day(occurred_at), tenant_id)` is the right default:

- **Partition count math:** total partitions per year = tenants × days, **not** event count divided by days. For 80 tenants × 365 days = **29,200 partitions/year** — well within Iceberg's comfort zone (rule of thumb: stay under ~100,000 active partitions per table). The event count only affects partition *size*, not partition *count*.
- Per-tenant dashboards prune to one tenant × time range — tiny scans.
- Internal cross-tenant dashboards prune by day — still fast.

If a single huge tenant produces 80% of events, consider isolating that tenant into its own partition family or its own table. Spark's `rewrite_data_files` will keep file sizes balanced.

### Bucket partitioning — the two production footguns

Bucket partitioning (`bucket(tenant_id, N)`) is the right choice when you have hundreds of tenants with severe size skew and you need predictable file counts. But two configuration details cause >90% of the production bug reports against bucket-partitioned tables. If you skip either, you get either (a) millions of tiny files or (b) systematic tenant collisions that destroy pruning. Both are silent — your queries return correct results, they just get slower and slower.

#### Footgun 1: forgetting `write.distribution-mode = 'hash'` (the most common production footgun)

By default, Iceberg does NOT shuffle data by partition key before writing. Every Spark task holds rows for every bucket. When the task commits, it writes one Parquet file **per bucket it touched** — and with N buckets in the spec, that's up to N files per task. For a Spark job with 200 tasks and N=64 buckets, a single commit can produce **200 × 64 = 12,800 tiny Parquet files** instead of 64 healthy ones. Multiply by 288 micro-batch commits per day and you have 3.6M tiny files per day. Compaction can never catch up.

The fix is one table property — `write.distribution-mode = 'hash'` — which tells Iceberg to shuffle rows by partition key before writing so each bucket is owned by exactly one writer. Then you get one Parquet file per bucket per commit, ~64 files per commit instead of 12,800. **Set this property at table creation; do not rely on remembering to set it later.**

> **ENGINE LABEL — set `write.distribution-mode = 'hash'` at table creation for ALL bucket-partitioned tables. Both DDL forms shown.**
>
> **Trino DDL** (run in Trino query console):
> ```sql
> CREATE TABLE iceberg.analytics.events (
>   event_id    VARCHAR,
>   tenant_id   VARCHAR,
>   occurred_at TIMESTAMP(6),
>   payload     VARCHAR
> )
> WITH (
>   partitioning = ARRAY['day(occurred_at)', 'bucket(tenant_id, 64)'],
>   format = 'PARQUET',
>   extra_properties = MAP(
>     ARRAY['write.distribution-mode'],
>     ARRAY['hash']
>   )
> );
> ```
>
> **Spark SQL DDL** (run in Spark session or ingestion job):
> ```sql
> CREATE TABLE iceberg.analytics.events (
>   event_id    STRING,
>   tenant_id   STRING,
>   occurred_at TIMESTAMP,
>   payload     STRING
> )
> USING iceberg
> PARTITIONED BY (days(occurred_at), bucket(64, tenant_id))
> TBLPROPERTIES ('write.distribution-mode' = 'hash');
> ```
>
> **Spark DataFrame writer** (when creating the table from a write rather than DDL):
> ```python
> (df.writeTo("iceberg.analytics.events")
>    .partitionedBy(days("occurred_at"), bucket(64, "tenant_id"))
>    .tableProperty("write.distribution-mode", "hash")
>    .create())
> ```
> Or append to an already-existing table (canonical DataFrameWriterV2 form):
> ```python
> (df.writeTo("iceberg.analytics.events")
>    .option("write.distribution-mode", "hash")
>    .append())
> ```
>
> > **DO NOT** close a Spark-to-Iceberg write with `df.write.format("iceberg").mode("append").save(...)` or `.saveAsTable(...)`. That is the **legacy save() path** and does NOT route through the SparkCatalog plugin cleanly — see resource 13's "Spark write API — the API-CONFUSION GUARDRAIL" callout. On the production stack (Iceberg 1.5.2 + SparkCatalog with HMS), the canonical and ONLY supported write API is **DataFrameWriterV2**: `df.writeTo("iceberg.x.y").append()` / `.overwritePartitions()` / `.create()` / `.createOrReplace()`.
>
> Remember the `bucket()` argument-order difference between engines: Trino is `bucket(column, N)`, Spark is `bucket(N, column)`.

**Verifying it took effect.** After the first ingestion run, count files per partition:

```sql
SELECT partition, file_count, total_size, record_count
FROM iceberg.analytics."events$partitions"
ORDER BY total_size DESC LIMIT 20;
```

If `file_count` per bucket-partition is close to 1 (or close to the number of commits in the window), `write.distribution-mode = 'hash'` is working. If you see file counts in the hundreds or thousands per bucket, the property didn't take effect — check `SHOW CREATE TABLE` and confirm the property is present.

#### Footgun 2: choosing the wrong N for `bucket(tenant_id, N)`

N is fixed at table creation and cannot be changed without a full table rewrite. Pick it carefully.

**Rules of thumb for choosing N:**

- **N >= 2 × maximum concurrent large Spark writers.** If you have 8 Spark executors writing in parallel during a peak ingestion run, N = 16 is the floor; N = 32 leaves headroom. Below this floor, multiple writers contend for the same bucket and serialize on commits.
- **Target ~256–512 MB per bucket per write window after compaction.** Total daily ingested bytes ÷ N ÷ commits-per-day = bytes per bucket per commit. After nightly compaction, each bucket-partition should reach the target file size. If a typical bucket holds <64 MB after compaction, N is too high — buckets are starving. If a typical bucket holds >2 GB, N is too low — buckets are too big to parallelize well.
- **N should be SOMEWHAT greater than your tenant count, not equal.** If you have 200 tenants and pick N = 200, hash collisions guarantee some buckets hold 2–3 tenants and others hold 0. Pick N modestly larger than the tenant count for headroom — but not so large that each bucket starves.
- **For most B2B SaaS in the 80–500 tenant range, N = 64 is the practical sweet spot.** It leaves headroom over a typical 5–15-concurrent-writer Spark setup, produces healthy file sizes for tables in the 1–10 TB range, and gives good (but not perfect) tenant separation.

**Worked example: 200 tenants with 80/20 size skew.** 5 large tenants produce 80% of events; 195 small tenants share the remaining 20%. Pick N = 64:
- 5 large tenants in 64 buckets → almost certainly each in a distinct bucket (low collision probability for 5 keys into 64 slots ≈ 15%).
- 195 small tenants in 64 buckets → average ~3 per bucket; collisions are fine because small tenants' combined volume per bucket is still manageable.
- 64 buckets × ~256 MB per bucket per write window = ~16 GB per day comfortably handled.

**Verify whale placement after the first ingest.** Confirm that your 5 largest tenants landed in distinct buckets — if two of them collide, that bucket is double-size and will be slower than the rest:

```sql
-- Top 10 partitions by total size — the 5 whale tenants' buckets should appear
-- here, each in its own row (distinct partition values). If you see fewer than
-- 5 distinct entries among the top, two whales collided into one bucket.
SELECT partition, file_count, ROUND(total_size/1024/1024/1024, 2) AS gb, record_count
FROM iceberg.analytics."events$partitions"
ORDER BY total_size DESC LIMIT 10;
```

If two whales collided, your options are (a) accept the imbalance and live with one slower bucket, (b) increase N (requires full table rewrite — expensive), or (c) move the worst-offending whale tenant into its own dedicated table (Model 1 from the multi-tenant guide). Option (c) is the cleanest long-term answer for the top 1–2 tenants on most production stacks.

#### Footgun 3 (bonus, file-naming): on-disk path convention

Iceberg's on-disk path convention for partitioned files is `<column>_<transform>=<value>/`, not the Hive-style shorthand `<value>/`. Engineers who browse MinIO directly with `mc ls` or the MinIO console see the full names and may be confused if examples elsewhere use the shorthand. The actual paths look like:

```
s3a://lakehouse/warehouse/analytics/events/data/
    occurred_at_day=2026-05-25/tenant_id_bucket=12/00000-1-abc.parquet
    occurred_at_day=2026-05-25/tenant_id_bucket=37/00000-2-def.parquet
    occurred_at_day=2026-05-26/tenant_id_bucket=12/00000-3-ghi.parquet
```

Note `occurred_at_day=2026-05-25` (not `day=2026-05-25`) and `tenant_id_bucket=12` (not `bucket=12`). Iceberg builds the directory name from the source column name plus the transform name, joined by an underscore. For identity partitions (e.g., `PARTITIONED BY (tenant_id)`), there is no transform suffix — the path is just `tenant_id=acme/`.

If you grep your storage tier for partition values, use the full path form: `mc ls --recursive minio/lakehouse/warehouse/analytics/events/data/ | grep "tenant_id_bucket=12"`, not `grep "bucket=12"`.

### Bonus: metadata-only `COUNT(*) GROUP BY <partition column>` (billing-query gold)

When a column appears in the partition spec **as an identity transform** (i.e., the partition is the column value itself, not a hash bucket), an aggregation grouped by that column can be answered **entirely from Iceberg's manifest metadata** — without opening a single Parquet data file. This is a real, measurable speedup for the common billing/usage-metering query.

The reason: Iceberg's manifest files store, per data file, the **partition tuple** it belongs to plus a `record_count` of rows in that file. For an identity-partitioned table (e.g., `PARTITIONED BY (tenant_id)`), the partition tuple literally **is** the `tenant_id` value (e.g., `'acme'`). So for a query like `SELECT tenant_id, COUNT(*) FROM events GROUP BY tenant_id`, Trino reads the manifest summaries (a few megabytes of metadata for a multi-TB table), sums the per-file `record_count` by `tenant_id`, and returns the result. **No row data is read. No Parquet file is opened.** The query completes in seconds even on a 10 TB table.

> **CRITICAL — identity partitioning vs bucket/truncate/day/month/year partitioning behave DIFFERENTLY for metadata-only `COUNT(*) GROUP BY <column>`.** This is the single most common misconception about Iceberg metadata-only aggregations. Read this carefully before you choose between `tenant_id` and `bucket(tenant_id, N)` partitioning — the choice directly affects whether your hourly billing query runs in 2 seconds or 2 minutes. The same logic applies to **all derived-value transforms** (bucket, truncate, day, month, year): the manifest stores the **transformed** value, not the original column value, so any `GROUP BY original_column` requires opening data files.
>
> | Partition transform | Per-original-column `COUNT(*) GROUP BY tenant_id` (or original column) | Why |
> |---|---|---|
> | **Identity: `PARTITIONED BY (tenant_id)`** | **METADATA-ONLY** — answered from manifests in seconds, no data file reads. | The manifest entry for each data file stores the **actual `tenant_id` value** as the partition key (e.g., `partition = {tenant_id: 'acme'}`). Trino aggregates `record_count` grouped by that key directly from the manifest list. |
> | **Bucket: `PARTITIONED BY (bucket(tenant_id, 64))`** | **NOT metadata-only** — Trino must open data files (or read per-file column statistics) to break counts down by individual tenant. | The manifest stores the **bucket number** (an integer 0–63), NOT the original `tenant_id` string. Multiple tenants share each bucket (with 200 tenants and 64 buckets, ~3 tenants per bucket). The manifest knows "bucket 12 has 50M rows" but cannot tell you which of those rows belong to `'acme'` vs `'globex'` vs `'initech'`. **However**, total `COUNT(*)` without `GROUP BY` is still metadata-only — it's just the sum of all manifest `record_count`s regardless of partition transform. |
> | **Truncate: `PARTITIONED BY (truncate(user_id, 4))`** | **NOT metadata-only** for `GROUP BY user_id` — only metadata-only for `GROUP BY truncate(user_id, 4)`. | The manifest stores the truncated prefix (e.g., `'u_42'` for any `user_id` starting with `'u_42'`), NOT the full value. The manifest knows "prefix 'u_42' has 10K rows" but cannot tell you the split among `'u_4201'`, `'u_4202'`, etc. |
> | **Day/Month/Year: `PARTITIONED BY (day(occurred_at))`** | **NOT metadata-only** for `GROUP BY occurred_at` (the raw timestamp) — but **metadata-only** for `GROUP BY day(occurred_at)`. | The manifest stores the **rounded day** (e.g., `2026-05-25`), NOT the original timestamp. The manifest knows "day 2026-05-25 has 1M rows" but cannot tell you the per-second or per-hour breakdown without opening files. Aggregating by the transform itself (`day(occurred_at)` or `date_trunc('day', occurred_at)`) IS metadata-only because the GROUP BY key equals the partition key. |
>
> **General rule.** A metadata-only `GROUP BY` requires that the GROUP BY expression **exactly equals** the partition transform expression. `GROUP BY tenant_id` is metadata-only only under identity partitioning on `tenant_id`. `GROUP BY day(occurred_at)` is metadata-only under day-partitioning on `occurred_at`, but `GROUP BY occurred_at` (raw) is not — even though `occurred_at` "is partitioned." The manifest stores the **transformed** value (the partition key), and metadata-only aggregations only fire when the group key matches that exact stored value. Total `COUNT(*)` (no GROUP BY) is always metadata-only regardless of transform — it just sums `record_count` across manifest entries.
>
> **What this means for your billing queries.** If you partition by `bucket(tenant_id, 64)` for write-balance reasons, your per-tenant billing query (`SELECT tenant_id, COUNT(*) GROUP BY tenant_id`) silently degrades from metadata-only (seconds) to a full file scan (minutes), even though `tenant_id` is "in the partition spec." Iceberg's documentation says the column is partitioned, but the metadata-only optimization only fires when the partition key value **equals** the group-by column value — that requires the identity transform, not the bucket transform.
>
> **The asymmetry is a real trade-off you must choose between:**
>
> - **Identity `PARTITIONED BY (tenant_id)`** — wins on per-tenant billing query speed (metadata-only `COUNT(*)`), but write throughput suffers from skew (your 5 largest tenants each get their own giant partition; the 195 small tenants each get tiny partitions and tiny files).
> - **`PARTITIONED BY (bucket(tenant_id, N))`** — wins on write balance and small-file control (data spread evenly across N buckets regardless of tenant skew), but loses metadata-only per-tenant `COUNT(*)`.
> - **`PARTITIONED BY (day(occurred_at), tenant_id)` (identity tenant_id)** — usually the right compromise: time-range pruning, per-tenant pruning, AND metadata-only per-tenant `COUNT(*)`. The downside is no protection against tenant skew within a day-partition.
> - **`PARTITIONED BY (day(occurred_at), bucket(tenant_id, 64))`** — pick this only when tenant skew is so severe that small-file control is the dominant concern (200+ tenants with 1000x size variance). Accept the slower per-tenant billing query as the cost.

This optimization triggers when **all** conditions hold:

1. The `GROUP BY` column is part of the partition spec **as an identity transform** (e.g., `partitioning = ARRAY['day(occurred_at)', 'tenant_id']` — NOT `bucket(tenant_id, 64)`).
2. The aggregation is a simple `COUNT(*)` — no per-row predicates on non-partition columns.

```sql
-- METADATA-ONLY — answered from manifests in seconds. Partition spec
-- ARRAY['day(occurred_at)', 'tenant_id']; both group keys are partition columns.
SELECT tenant_id, COUNT(*)
FROM iceberg.analytics.events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
GROUP BY tenant_id;

-- ALSO metadata-only — both keys are partition transforms.
SELECT day(occurred_at) AS day, tenant_id, COUNT(*)
FROM iceberg.analytics.events
GROUP BY 1, 2;

-- NOT metadata-only — device_type is a regular column, not partitioned.
-- Trino must open Parquet files to read device_type values.
SELECT device_type, COUNT(*)
FROM iceberg.analytics.events
GROUP BY device_type;

-- NOT metadata-only — adds a predicate on a non-partition column (user_id),
-- so Trino must read row data to apply the filter before counting.
SELECT tenant_id, COUNT(*)
FROM iceberg.analytics.events
WHERE user_id = 'u_42'
GROUP BY tenant_id;
```

**Why this matters for billing queries.** "How many events did each tenant produce last month?" is the canonical SaaS metering query. With `tenant_id` in the partition spec, it's metadata-only. Without it (e.g., partitioned only by `day(occurred_at)`), Trino must open every file in the date range and read the `tenant_id` column. On a 5 TB table that's the difference between ~3 seconds and 2–4 minutes — and the metadata-only version barely loads the cluster, so you can run it every hour without thinking about cost.

**Verifying it actually fired.** Look at the query stats in the Trino UI or `system.runtime.queries`: a true metadata-only `COUNT(*) GROUP BY` shows near-zero `physical_input_bytes` (just the manifest reads, not data) and completes in seconds. If you see GB of `physical_input_bytes` on a `COUNT(*) GROUP BY tenant_id`, one of the trigger conditions failed — most often because (a) someone added a `WHERE` filter on a non-partition column, (b) the partition spec doesn't actually include `tenant_id` (it might only include `day(occurred_at)`), or **(c) the partition spec uses `bucket(tenant_id, N)` instead of identity `tenant_id` — bucketed partitions cannot answer per-tenant `COUNT(*)` from manifests because the manifest stores the bucket number, not the tenant value**. Check `SHOW CREATE TABLE iceberg.analytics.events` to confirm the transform.

**Connecting to multi-tenant design.** This is the concrete payoff of putting `tenant_id` in the partition spec, beyond pruning per-tenant queries. The same partition layout that makes "show acme's events" fast also makes "tenant_id, COUNT(*)" — the building block of every billing report — essentially free. If your team runs per-tenant usage rollups every hour for invoicing, this single optimization can drop those queries from "expensive batch jobs" to "throwaway cheap SELECTs."

---

## The small-files problem

### What goes wrong
Every Iceberg commit produces one or more new Parquet files. If your Spark streaming job writes every 5 minutes:
- 12 writes/hour × 24 hours = 288 commits/day.
- × 80 tenants × 1 day partition = 23,000 tiny files per day.
- Each Parquet file has open/metadata cost (~10–50 ms in Trino).
- A query that scans one day across all tenants opens 23,000 files → 4+ minutes just opening files, before reading any data.

### The fix: nightly compaction
Run Spark's `rewrite_data_files` procedure to merge small files into bigger ones:

> **ENGINE: The `CALL iceberg.system.*` procedures below are Spark SQL only. They do not run in Trino. Run them via `spark-submit` or a Spark session, not in the Trino query console.**

```sql
-- Spark SQL only — CALL iceberg.system.rewrite_data_files does not exist in Trino.
-- Trino equivalent for bin-pack file compaction:
--   ALTER TABLE iceberg.analytics.user_events EXECUTE optimize(file_size_threshold => '128MB');
-- Note: Trino's OPTIMIZE does NOT accept strategy => 'sort' — for sort-based clustering
-- of existing data, use Spark (see Fix 1 in the file-pruning section above).
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.user_events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '5'
  )
);
```

What it does:
- Reads each partition's small files, rewrites them as 256 MB Parquet files.
- Atomic — Iceberg snapshots make it safe to run while queries are live.
- Old files become unreferenced; `expire_snapshots` (an Iceberg maintenance procedure that deletes older table versions and the files only those versions used) cleans them up later.

### Target file size
- **128 MB** — good for highly selective queries (small file = cheaper to skip).
- **256 MB** — sensible default for most SaaS event tables.
- **512 MB** — better when scans are usually large (full-day analytics).

Below 64 MB: too many file-open calls. Above 1 GB: poor parallelism — one worker per file means few workers can share the load.

### Schedule it
- For high-volume tables: compact every night during low-traffic hours.
- For lower-volume tables: weekly is fine.
- Always pair with `expire_snapshots` (see "Snapshot management" below).

---

## Snapshot management and cleanup

Iceberg keeps every snapshot of the table (every commit) so you can time-travel:

```sql
SELECT * FROM iceberg.analytics.user_events FOR TIMESTAMP AS OF TIMESTAMP '2026-05-01';
```

Snapshots reference data files. Old snapshots = old files still held even after compaction. Storage creeps up.

### Expire old snapshots

> **ENGINE NOTE — `expire_snapshots` exists in BOTH engines but uses different parameter names. Pick the form that matches where you run your maintenance job.**

```sql
-- Spark SQL only — uses `older_than` (absolute timestamp) and optional `retain_last`.
CALL iceberg.system.expire_snapshots(
  table         => 'analytics.user_events',
  older_than    => TIMESTAMP '2026-04-23 00:00:00',
  retain_last   => 5
);
```

```sql
-- Trino only — uses `retention_threshold` (a DURATION STRING like '7d' or '24h').
-- Do NOT use `older_than` here — it is not a valid Trino parameter and will error.
ALTER TABLE iceberg.analytics.user_events
EXECUTE expire_snapshots(retention_threshold => '7d');
```

- Spark `older_than`: hard cutoff — anything older than this absolute timestamp is eligible.
- Spark `retain_last`: always keep this many most-recent snapshots even if they're old.
- Trino `retention_threshold`: a relative duration string. `'7d'` means "anything older than 7 days from now."

### Remove orphan files
Sometimes Spark fails mid-write and leaves files in MinIO that no snapshot references. The procedure has different syntax in Spark vs Trino — they are NOT interchangeable.

```sql
-- =====================================================================
-- SPARK SQL (run via spark-submit / spark-sql)
-- =====================================================================
-- Spark signature: CALL iceberg.system.remove_orphan_files(
--   table              => 'schema.table',
--   older_than         => current_timestamp - interval '3' day,  -- default 3 days
--   dry_run            => true,    -- ALWAYS preview first
--   location           => 's3a://lakehouse/...'  -- optional override
-- )

-- Step 1: preview which files would be removed (NEVER skip this).
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.user_events',
  dry_run => true
);

-- Step 2: after reviewing the dry-run output, run the actual deletion.
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.user_events',
  older_than => current_timestamp - interval '3' day
);

-- =====================================================================
-- TRINO 467 (run from any Trino client)
-- =====================================================================
-- The Trino signature is ENTIRELY DIFFERENT:
--   ALTER TABLE iceberg.<schema>.<table> EXECUTE remove_orphan_files(
--     retention_threshold => '7d'
--   )
-- Notes:
--   - Trino does NOT use `CALL iceberg.system.remove_orphan_files(...)` —
--     that signature does not exist in Trino's Iceberg connector. Pasting
--     the Spark CALL form into a Trino session fails with a "procedure not
--     registered" error.
--   - Trino does NOT support a `dry_run` parameter on this procedure (only
--     Spark does). If you need a preview from Trino, run dry_run from Spark
--     first.
--   - Trino enforces a 7-day MINIMUM for `retention_threshold` via the
--     catalog property `iceberg.remove-orphan-files.min-retention` (default
--     `7d`). Values shorter than 7d are REJECTED with
--     "Retention specified (X.XXd) is shorter than the minimum retention
--     configured in the system (7.00d)". The floor is enforced regardless
--     of what you pass in `retention_threshold`.
ALTER TABLE iceberg.analytics.user_events
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

**Always dry-run first (Spark only).** Before any production deletion run, execute the Spark `dry_run => true` form and review the returned file list — orphan-file cleanup is irreversible. Trino has no equivalent dry-run; preview from Spark, then run the actual deletion from either engine.

### Recommended maintenance schedule
| Job | Frequency | Purpose |
|---|---|---|
| `rewrite_data_files` | Nightly | Merge small Parquet files into 128–512 MB (target file size — the size each compacted Parquet file is rewritten to; 256 MB is the default sweet spot, see "Target file size" above) |
| `rewrite_manifests` | Weekly | Compact **manifest files** (Iceberg metadata files that list which data files belong to a snapshot and their per-column min/max stats); many small manifests slow down query planning |
| `expire_snapshots` (older than 30 days, retain 10) | Nightly | Delete old table snapshots so MinIO can free the data files they were holding onto |
| `remove_orphan_files` | Weekly | Clean up after failed writes |

These can be cron'd via your Spark/Airflow setup, or scheduled as dbt operations if your dbt project includes operational macros.

---

## Partition evolution (changing partition spec later)

You picked `day(occurred_at)` six months ago. Now you realize you should have added `tenant_id`. In Hive, you'd have to rewrite the entire table. In Iceberg, you change the partition spec in place:

```sql
-- Correct Trino DDL: SET PROPERTIES, NOT "SET PARTITIONING"
ALTER TABLE iceberg.analytics.user_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

> **Cross-reference — should `tenant_id` be identity or bucketed?** The example above uses identity partitioning on `tenant_id` — the right default for tables with fewer than ~200 tenants. **For tables with more than ~200 tenants, or with severe tenant-size skew, consider `bucket(tenant_id, 32)` (or 64) instead of direct identity partitioning** — see "Bucket partitioning — the two production footguns" earlier in this document for the full tradeoff. The identity form gives you metadata-only per-tenant `COUNT(*)` (billing-query gold); the bucket form gives you predictable file counts under heavy tenant skew but loses metadata-only `COUNT(*)`. Pick before you ALTER — switching from identity to bucket later requires another full rewrite.

> **Common syntax bug:** older docs and copy-pasted examples sometimes show `SET PARTITIONING = ARRAY[...]`. That is **not** valid Trino syntax and will throw a parser error. The correct form on Trino 467 with the Iceberg connector is `SET PROPERTIES partitioning = ARRAY[...]`. The `partitioning` keyword goes *inside* `PROPERTIES`, lowercase, no equals between `partitioning` and `ARRAY`.

Iceberg supports **partition evolution**:
- Old files keep their old partition spec.
- New writes use the new spec.
- Queries automatically prune across both specs.

This is a real superpower — start simple, add partitioning later as you learn the query patterns.

### Partitioning existing tables — important caveat (read this if your "added partition" didn't speed up queries)

This is the **single most common confusion** when engineers change a partition spec. Read carefully.

**`ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` changes the partition spec for NEW writes only. It does NOT touch any data file that already exists.**

What that means concretely, the day after you run the ALTER:

| Files | Partition layout | Pruning behavior |
|---|---|---|
| Files written **before** the ALTER | Old spec (or unpartitioned) | Cannot be pruned by the new column. Trino has to open and read these files for any query, even one that filters on the new partition column. |
| Files written **after** the ALTER | New spec | Pruned correctly by the new column. |

Queries still return correct results — Iceberg transparently reads files from both specs and merges them. **But your old data is still slow.** If 95% of your table sits in pre-ALTER files, 95% of your query I/O sees no improvement.

**Symptom:** "I added `tenant_id` to the partition spec yesterday. New data is fast, but my dashboard that scans the last 90 days is still slow." This is exactly the case — 89 of those 90 days are pre-ALTER files that the new spec can't prune.

**The fix: rewrite the historical files under the new spec.** `rewrite_data_files` re-writes existing Parquet files and, in the process, places them into the new partition structure:

```sql
-- Step 1: change the spec for new writes (Trino syntax shown).
-- Equivalent Spark SQL: ALTER TABLE analytics.user_events SET TBLPROPERTIES (...)
ALTER TABLE iceberg.analytics.user_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

> **ENGINE NOTE — read this before step 2.** Step 1 (`ALTER TABLE ... SET PROPERTIES partitioning`) is **Trino syntax**. Step 2 (`CALL iceberg.system.rewrite_data_files(...)`) and step 4 (`CALL iceberg.system.expire_snapshots(...)`) below are **Spark SQL only** — they do not run in Trino. **Never copy a `CALL iceberg.system.*` procedure into the Trino query console — it will fail with a parse error.** Run those steps via `spark-submit` or a Spark SQL session. The Trino-equivalent procedures (where they exist) use the `ALTER TABLE ... EXECUTE <procedure>(...)` form with different parameter names; both are shown below for `expire_snapshots`.

```sql
-- Step 2: rewrite ALL existing data files under the new spec (Spark SQL only).
-- This is a one-time, potentially expensive operation — schedule it during low traffic.
-- Note for Trino users: Trino's `ALTER TABLE ... EXECUTE optimize` has confirmed bugs after
-- partition spec changes (trinodb/trino issues #26109, #26503, #25279) — it may produce
-- files with incorrect partition values or fail to reorganize data by the new partition
-- column at all. ALWAYS use Spark's rewrite_data_files with rewrite-all=true for the
-- initial cross-spec migration; see the WARNING callout below for details.
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.user_events',
  options => map(
    'rewrite-all',            'true',      -- force rewrite ALL files regardless of size
    'target-file-size-bytes', '268435456'  -- 256 MB target output file size
  )
);
```

> **Why `rewrite-all=true` is required for partition spec migration:** The default bin-pack strategy only rewrites files that are "too small" or "too many." Large, well-sized files from the old partition spec are skipped — they stay in the old monthly directories and continue to defeat pruning. Setting `rewrite-all=true` forces the procedure to rewrite every file regardless of size, migrating all data to the new spec. Use this once for the initial migration; **ongoing nightly compaction jobs do NOT need `rewrite-all=true`** and should omit it to avoid unnecessary rewrites — for routine compaction, the default bin-pack behavior (or `min-input-files=5`) is what you want.

> **CAUTION — `rewrite-all=true` is EXPENSIVE on large tables.** Because it rewrites every file regardless of size, the job touches the entire table's data — expect **multi-hour runtimes on TB-scale tables** (e.g., 1 TB takes 30–90 min on the production Spark cluster; 10 TB can take 4–8 hours), plus a temporary ~2x storage spike on MinIO until the post-rewrite `expire_snapshots` runs. Schedule it during a low-traffic window and plan for the storage headroom.
>
> **Known bug — do NOT combine `rewrite-all=true` with a `where` predicate.** [apache/iceberg #14667](https://github.com/apache/iceberg/issues/14667): using `rewrite-all=true` together with `where => '...'` can produce **duplicate rows** in the rewritten partition. Only use `rewrite-all=true` for full-table rewrites (no `where` clause). If the migration must be scoped (e.g., one tenant or one date range at a time to spread cost), the **preferred safe alternative is the default bin-pack strategy with `min-input-files=1`** — this forces a rewrite of every old-spec file (because any partition with 1+ files is now eligible for compaction) without the duplicate-rows risk of `rewrite-all=true`:
>
> ```sql
> -- Spark SQL only — safer per-tenant post-partition-evolution migration.
> -- Uses default bin-pack strategy + min-input-files=1 to rewrite every old-spec file
> -- in the scoped partition WITHOUT the duplicate-row bug of rewrite-all=true + where.
> CALL iceberg.system.rewrite_data_files(
>   table   => 'analytics.user_events',
>   where   => 'tenant_id = ''acme''',
>   options => map(
>     'min-input-files',        '1',          -- rewrite even a single old-spec file
>     'target-file-size-bytes', '268435456'   -- 256 MB target
>   )
> );
> ```
>
> This is the recommended pattern when you need to migrate one tenant's data (or any partition-scoped subset) to the new partition spec. For a full-table migration with no scoping, the `rewrite-all=true` form above is fine and is the conventional choice.

> **WARNING: Do not use Trino's `ALTER TABLE ... EXECUTE optimize` for post-partition-evolution migration.** Confirmed bugs in Trino ([trinodb/trino #26109](https://github.com/trinodb/trino/issues/26109), [#26503](https://github.com/trinodb/trino/issues/26503), [#25279](https://github.com/trinodb/trino/issues/25279)) mean that after a partition spec change, Trino's native `OPTIMIZE` command may produce files with **incorrect partition values** (e.g., NULL partition keys) or fail to reorganize data by the new partition column at all. For the initial spec migration, **always use Spark's `CALL iceberg.system.rewrite_data_files` with `rewrite-all=true`**. Once the migration is complete and all files are on the new spec (verify via the `$files` `spec_id` check in step 3 — wait until the old `spec_id` row reports 0 files), you can resume using Trino's `OPTIMIZE` for routine compaction.

> **EXPLICITLY — what Trino `ALTER TABLE ... EXECUTE optimize` does and does NOT do after a partition spec change. Read this if you ran optimize and your old files are STILL on the old spec.**
>
> `ALTER TABLE iceberg.analytics.user_events EXECUTE optimize` performs **file-size compaction within the partition layout each file already has**. It merges small files into larger ones — but it does **NOT repartition** files to the current (new) partition spec. After running Trino `EXECUTE optimize` on a table that just had a new partition column added:
>
> - Files originally written under spec_id=0 (the old `day(occurred_at)` spec) **stay tagged with spec_id=0** and remain in the old partition layout.
> - Trino's optimize may merge small spec_id=0 files into bigger spec_id=0 files, but they still don't carry the new partition column (`tenant_id`) in the manifest's partition struct.
> - Queries filtering on the new partition column (`tenant_id`) still cannot prune those files — exactly the original problem you were trying to fix.
>
> **Why:** Trino's `EXECUTE optimize` is wired to the IcebergMetadata applyFilter / TableExecuteStructureValidator code path, which currently rejects predicates on newly-added partition columns and cannot push a cross-spec rewrite plan ([trinodb/trino #25279](https://github.com/trinodb/trino/issues/25279), [#26503](https://github.com/trinodb/trino/issues/26503)). The bin-pack rewrite strategy Trino uses only changes file *sizes*, not partition *layout*.
>
> **The ONLY procedure on this stack that repartitions old files to the new spec is Spark's `CALL iceberg.system.rewrite_data_files(..., options => map('rewrite-all', 'true'))`.** `rewrite-all=true` forces Spark to rewrite every file regardless of size — this is what re-stamps each file with the current (new) spec_id and places it in the new partition directory structure. Without `rewrite-all=true`, even Spark's `rewrite_data_files` may skip well-sized old-spec files (the default bin-pack strategy only targets undersized files).
>
> **Diagnostic — confirm Trino optimize did NOT repartition by checking spec_id distribution:**
>
> ```sql
> -- Run this BEFORE and AFTER trying Trino EXECUTE optimize on a freshly-evolved table.
> -- If the spec_id=0 row count is unchanged, optimize did not repartition (expected behavior).
> SELECT spec_id, COUNT(*) AS file_count, SUM(file_size_in_bytes)/1024/1024 AS total_mb
> FROM iceberg.analytics."user_events$files"
> GROUP BY spec_id
> ORDER BY spec_id;
> ```
>
> If you see `spec_id=0` files persist after Trino optimize, that is expected — switch to Spark `rewrite_data_files` with `rewrite-all=true` to actually migrate them. Once `spec_id=0` row count reaches 0, the migration is complete and Trino `EXECUTE optimize` is fine to resume for routine compaction.

```sql
-- Step 3: verify rewrite progress (works in BOTH Spark and Trino — metadata query).
-- Each data file is tagged with the spec_id it was written under: 0 = original spec,
-- 1 = spec after the first ALTER, 2 = spec after the second ALTER, etc. When the count
-- for the old spec_id (typically 0) reaches 0, every historical file has been rewritten
-- under the new spec and queries on the new partition column will prune fully.
SELECT spec_id, COUNT(*) AS file_count
FROM iceberg.analytics."user_events$files"
GROUP BY spec_id
ORDER BY spec_id;

-- Example progression while rewrite is running:
--  spec_id | file_count
--  --------+-----------
--        0 |    14,532   <- pre-ALTER files, still on the old spec
--        1 |     8,219   <- post-ALTER files, already on the new spec
-- Re-run periodically; rewrite is complete when spec_id=0 row disappears (or count = 0).
```

```sql
-- Step 4: expire old snapshots so the pre-rewrite Parquet files become unreferenced
-- and MinIO can reclaim the storage. Two engine syntaxes — pick the one that matches
-- where you're running the maintenance job.

-- Spark SQL only (uses `older_than` with an INTERVAL expression):
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.user_events',
  older_than   => current_timestamp() - INTERVAL '7' DAY,
  retain_last  => 5
);

-- Trino syntax (uses `retention_threshold` with a DURATION STRING — NOT `older_than`):
ALTER TABLE iceberg.analytics.user_events
EXECUTE expire_snapshots(retention_threshold => '7d');
```

> **WATCH OUT — Trino's `expire_snapshots` parameter is `retention_threshold`, NOT `older_than`.** The Trino form takes a single duration string like `'7d'`, `'24h'`, or `'30d'`. The Spark form takes `older_than` (an absolute timestamp expression) plus an optional `retain_last` count. Confusing the two — e.g., trying `EXECUTE expire_snapshots(older_than => current_timestamp() - INTERVAL '7' DAY)` in Trino — produces a "procedure does not accept this parameter" error. Verified against trino.io docs and trinodb/trino issue #27357.

After steps 2-4 complete, every file in the table follows the new partition spec, the metadata for the old spec is cleaned up, and queries filtering on the new column prune correctly.

**Cost and scheduling notes:**
- Rewriting 1 TB of data on the production stack takes roughly 30–90 minutes depending on Spark resources. Plan for it.
- The rewrite creates new snapshots and leaves the old files as candidates for future `expire_snapshots` cleanup — expect a temporary storage spike (~2x the table size) until expiry runs.
- Run it once after the ALTER, not on a schedule.
- Safe to run while queries are live (snapshot isolation), but **don't overlap it with ingestion** — it will conflict on commits.

**TL;DR:** `ALTER TABLE ... SET PROPERTIES` flips the switch for future writes. `rewrite_data_files` is what actually migrates your historical data. If you forget step 2, old data stays slow.

---

## Anti-patterns

### Don't partition by high-cardinality columns directly
`PARTITIONED BY (user_id)` with 1M users creates 1M partitions. Manifest metadata balloons; queries get slower from metadata overhead alone. Use `bucket(user_id, N)` if you really need user-level locality.

### Don't over-partition time — `hour()` and `minute()` are almost always wrong

This is the time-axis version of the high-cardinality anti-pattern, and it's the one teams reach for when "queries feel slow, let me make pruning more precise." The intuition seems right — more partitions = finer pruning = faster queries — but the math goes the wrong way fast.

**The arithmetic of over-partitioning by time.** Compare three partition specs on the same fact table over 3 years:

| Spec | Partitions / year / tenant | 80 tenants, 3 years | Realistic file count if you compact to 256MB targets |
|---|---|---|---|
| `day(occurred_at), tenant_id` | 365 | **87,600 partitions** | Healthy: a busy tenant gets ~30 files/day, a quiet tenant gets 1 small file/day → ~30M total files cluster-wide for a 5TB table, manageable. |
| `hour(occurred_at), tenant_id` | 8,760 | **2.1 million partitions** | Most partitions hold a few MB of data each. Compaction can't fix it — there isn't enough data per hour to fill a 256MB file. You end up with millions of tiny Parquet files. |
| `minute(occurred_at), tenant_id` | 525,600 | **126 million partitions** | Catastrophic. Each partition averages <1KB of data. Trino spends ~10–50 ms per file open; even a one-day query opens >100K files for a single tenant. Query times go from 2 seconds to 4+ minutes. Query planning alone can take minutes. |

**Why finer partitioning makes things slower, not faster.** Three compounding costs:

1. **Metadata size grows linearly with partition count.** Iceberg's manifest files list every data file with partition info and per-column statistics. At 126M partitions you have GB-scale manifests, and the Trino coordinator must read and traverse them on every query — even queries that only touch one day. Query *planning* (deciding which files to read) becomes the slow part, before any data is even scanned.
2. **The small-files problem becomes unfixable.** Iceberg's `rewrite_data_files` can merge small files within a partition, but it cannot merge files *across* partitions — different partitions are separate logical buckets and must stay separate on disk. If every hour-partition holds only 5MB, no compaction can produce 256MB files. You're permanently stuck with thousands of tiny files per day.
3. **Per-file overhead dominates the I/O budget.** Opening a Parquet file in object storage (MinIO/S3) takes ~10–50ms — read the footer, decode the schema, decode the row-group statistics, then start reading data. For a query that needs to scan 100,000 tiny files, you spend 10–50 minutes on file opens alone, before reading a single row of actual data. Columnar compression and predicate pushdown can't help if the bottleneck is file-open count.

**The right granularity.** For nearly every SaaS event table on the production stack:

- **Default to `day(event_ts)`.** Even at 100M events/day, day partitions are ~30GB of post-compression Parquet — enough for compaction to produce healthy 256MB–1GB files, few enough partitions per year that manifest metadata stays small.
- **Use `month(event_ts)` for low-volume tables** (`subscription_changes`, `account_audit`, `feature_flag_history`) where daily partitions would each hold <100KB. Month partitions consolidate the data into larger files; you sacrifice precision in time-range pruning, but at this volume that's a non-issue.
- **Never reach for `hour()` unless you can prove you produce ≥10 GB/hour after compression.** This is roughly 100M events/hour for a typical event row — i.e., genuine planet-scale workloads. Below that threshold, hour-partitioning produces files too small to compact into healthy sizes.
- **`minute()` and finer have no production use case on a query engine like Trino.** If you genuinely need minute-level data freshness, the solution is streaming ingest with frequent compaction — not finer partitioning.

**What if I really do query by hour?** You don't actually need hour-partitioning to query by hour. With `day(occurred_at)` partitioning, a query like `WHERE occurred_at >= TIMESTAMP '2026-05-22 14:00:00' AND occurred_at < TIMESTAMP '2026-05-22 15:00:00'` prunes to **one day's files** (correct — only 1/365th of the table), and then Iceberg's per-file column min/max statistics on `occurred_at` skip the row groups within those files that don't overlap the hour window. You get hour-grained read efficiency with day-grained partition layout. The partition column doesn't have to match the predicate granularity to prune effectively — it just has to bound it.

**Symptom you've over-partitioned.** Query planning time (the part before any data scan starts) exceeds 5 seconds on simple queries. The Trino coordinator's heap is mostly consumed by manifest metadata. `SELECT count(*) FROM iceberg.analytics."events$files"` returns millions. Compaction jobs run for hours but the file count doesn't drop. All of these point to too many partitions, not too few.

**The fix once you've over-partitioned.** Partition evolution (`ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id']`) changes the spec for new writes only. The historical hour-partitioned files stay where they are until you run `rewrite_data_files` to re-layout them under the new (coarser) spec — at which point Spark physically merges the tiny per-hour files into healthy per-day files. Plan for a multi-hour rewrite job, scheduled during off-hours, with ~2x table-size temporary storage spike until the post-rewrite `expire_snapshots` runs.

### Don't partition by columns you don't filter on
Partitioning by `country` when no one queries by country wastes file-layout opportunities. Partition by what your `WHERE` clauses actually use.

### Don't ignore partition skew
If one tenant produces 90% of events and you partition by `(tenant_id, day)`, that tenant's partitions are 100x bigger than the others. Queries on that tenant get one giant file per day; queries on small tenants get hundreds of tiny ones. Tune `target-file-size-bytes` per table, and consider bucketing the big tenant.

### Don't combine streaming writes with no compaction
Streaming ingest into Iceberg without a compaction job is the #1 way to make Trino slow. Always pair them.

### Don't forget to `expire_snapshots`
Without snapshot expiry, MinIO storage grows ~30% per year just from old file retention. Compaction *adds* files until expiry removes the old ones.

### Watch out: predicates that may defeat partition pruning

A frequently repeated rule is "any function around the partition column breaks pruning." This is **imprecise**. Trino has predicate-unwrapping logic that recognizes certain common shapes and rewrites them into the equivalent partition predicate. Other shapes — particularly non-day-aligned timestamps or arithmetic — still defeat pruning. Knowing the difference saves debugging time.

**Guaranteed pruning failure (avoid these):**

```sql
-- WRONG: non-day-aligned predicate on a day(ts) partition.
-- Trino cannot translate a partial-day timestamp into a day-boundary partition match,
-- so it falls back to a full scan of the affected days — and on some plans, more.
WHERE occurred_at >= TIMESTAMP '2026-05-01 10:00:00'

-- WRONG: complex arithmetic on the partition column.
-- Trino cannot algebraically invert this to reason about partition boundaries.
WHERE occurred_at + INTERVAL '7' DAY >= TIMESTAMP '2026-05-08 00:00:00'

-- WRONG: function transforms that don't match a recognized special case.
WHERE substr(format_datetime(occurred_at, 'yyyy-MM-dd'), 1, 7) = '2026-05'
WHERE year(occurred_at) = 2026 AND month(occurred_at) = 5  -- separate scalar fns; no unwrap
```

**May still prune correctly in Trino (special-case unwrapping):**

```sql
-- Trino has special-case unwrapping for simple CAST(ts AS DATE) comparisons against
-- DATE literals on a day(ts)-partitioned table. The UnwrapCastInComparison optimizer
-- rule (PR #13567) rewrites this to an equivalent timestamp range predicate before
-- partition pruning, so this form does prune partitions on Trino 467.
WHERE CAST(occurred_at AS DATE) >= DATE '2026-05-01'

-- date_trunc('day', ts) = DATE '...' is also handled by Trino 467 — specifically
-- by the UnwrapDateTruncInComparison rule (PR #14011). Like CAST/DATE(), it is
-- rewritten to a timestamp range predicate and partition pruning works.
WHERE date_trunc('day', occurred_at) = DATE '2026-05-01'
```

These may work fine in practice — if you've been writing `CAST(occurred_at AS DATE)` or `date_trunc('day', occurred_at)` predicates and seeing reasonable scan sizes in the query stats, you are not necessarily losing pruning. Check the `EXPLAIN` plan or the `system.runtime.queries` row's `physical_input_bytes` to confirm. **However, this behavior depends on the Trino version's optimizer rules**, on the `unwrap_casts` session property staying enabled, and on the exact shape of the predicate (e.g., `timestamp with time zone` columns have known unwrap limitations); minor changes to any of these can silently disable the unwrap.

**The safest pattern is always filtering on the raw column with a TIMESTAMP literal** — this is guaranteed to allow pruning regardless of Trino version, regardless of optimizer rule changes, and regardless of partition spec evolution:

```sql
-- BEST: raw column, TIMESTAMP literals on day boundaries.
-- Guaranteed prunable on every Trino version. Use this in any query that ships to production.
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
```

**Practical rule:** in ad-hoc analysis, `CAST(ts AS DATE)` is fine and reads well. In dashboards, scheduled reports, customer-facing APIs, or anywhere query performance is a contract, use raw-column TIMESTAMP-literal range predicates. The two-line cost of writing the explicit range is much smaller than the silent regression cost when an optimizer rule changes and your "simple" CAST stops pruning.

### Querying by a non-partition column bypasses partition pruning entirely (late-arriving-events trap)

> **Performance warning: querying by `occurred_at` on an `ingested_at`-partitioned table bypasses partition pruning.**
>
> The most common production manifestation of this issue is the two-timestamp pattern for late-arriving events (resource 14): partition by `day(ingested_at)` so each Spark job appends to one fresh partition, then query/aggregate by `occurred_at` so dashboards show user-time business behavior. The pruning consequence is easy to miss because the queries return **correct** results — they just scan the whole table.
>
> When you partition by `day(ingested_at)` but filter only by `occurred_at` in your query, Iceberg **cannot use the partition index for `occurred_at`** (because `ingested_at` is the partition column, not `occurred_at`). The query planner falls back to file-level column statistics (per-file min/max for `occurred_at`). For large tables this can be significantly slower than a partition-pruned scan — every manifest entry must be evaluated and many more files opened.
>
> **Fix — add a bounded `ingested_at` predicate alongside the `occurred_at` filter to recover partition pruning:**
> ```sql
> -- PARTITION-PRUNED via the bounded ingested_at window; same correct result.
> SELECT tenant_id, COUNT(*) FROM iceberg.analytics.events
> WHERE occurred_at >= TIMESTAMP '2026-05-21 00:00:00'
>   AND occurred_at <  TIMESTAMP '2026-05-22 00:00:00'
>   AND ingested_at >= TIMESTAMP '2026-05-21 00:00:00'   -- prune via partition key
>   AND ingested_at <  TIMESTAMP '2026-05-27 00:00:00'   -- 6 days covers a 5-day late-arrival window
> GROUP BY tenant_id;
> ```
>
> Set the `ingested_at` window to your known maximum late-arrival delay plus 1 day of buffer. Without this, every query that filters on `occurred_at` alone must scan files across all ingestion partitions in the table. See resource 14 for the full late-arriving-events partition strategy and the alternative `day(occurred_at)`-partitioned pattern.
>
> **The general rule:** filtering only on a non-partition column always bypasses partition pruning, regardless of whether the column happens to correlate with the partition column in practice. Iceberg's partition pruner only consumes predicates on partition columns; it never infers a partition predicate from a correlated column's stats. If your dominant query filter is on a non-partition column, add a redundant predicate on the partition column to recover pruning.

---

## Key terms

| Term | Meaning |
|---|---|
| **Partition** | A logical group of rows sharing a partition key value, stored in a separate set of files. |
| **Partition spec** | The Iceberg definition of how a table is partitioned (e.g., `day(occurred_at), tenant_id`). |
| **Hidden partitioning** | Iceberg's feature where partition predicates are derived automatically from regular column filters. |
| **Partition pruning / file skipping** | Skipping files that can't match a query's `WHERE` clause based on partition metadata. |
| **Partition evolution** | Changing a table's partition spec without rewriting old data. |
| **Bucket transform** | Hashes a column into N fixed-size buckets; gives stable fan-out for high-cardinality keys. **Trino syntax: `bucket(column, N)`** (column first). **Spark SQL syntax: `bucket(N, column)`** (count first — reversed). Equality filter (`WHERE tenant_id = 'acme'`) prunes to exactly 1 bucket. Range queries (`WHERE tenant_id IN (...)`) open one bucket per distinct value in the list. |
| **Compaction** | Merging many small Parquet files into fewer larger ones; via `rewrite_data_files`. |
| **Snapshot** | A point-in-time version of an Iceberg table; enables time travel and rollback. |
| **Orphan file** | A file in MinIO that no Iceberg snapshot references (usually from a failed write). |
| **Manifest file** | Iceberg metadata file listing data files in a snapshot, with column min/max statistics. |
| **`lower_bounds` / `upper_bounds`** | Per-file min/max value maps stored in each Iceberg manifest entry, keyed by field ID **for every column** — not just partition columns. The basis for file-level pruning on any column. |
| **File-level pruning** | Skipping a whole data file because its `lower_bounds`/`upper_bounds` for the filtered column prove the predicate value cannot be present. Works for any column — but only when the file's min/max range is narrow (data is clustered/sorted on that column). |
| **Sort-based clustering** | Running `rewrite_data_files` with `strategy='sort'` to physically reorder rows within files by one or more columns. Narrows per-file min/max ranges on the sort key, unlocking file-level pruning for non-partition columns. |
| **Parquet bloom filter** | Optional per-column probabilistic data structure embedded in Parquet row groups that lets the reader skip row groups for equality predicates without reading column data. Use on **HIGH-cardinality** columns (UUIDs, `user_id`, `session_id`, `event_id`); **do NOT use on low-cardinality columns** (`status`, `country_code`, `plan_type`) where dictionary encoding + min/max already prune efficiently. Configurable via Spark's `write.parquet.bloom-filter-enabled.column.<col>` Iceberg table property, or Trino's `parquet_bloom_filter_columns` array property. |
