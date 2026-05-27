# Iter117 Q2 — Judge Report

**Question topic**: GDPR data portability + right-to-erasure — exporting a tenant's 3-year dataset out of a shared multi-tenant Iceberg table as Parquet/CSV without melting the cluster, then physically purging the tenant's data from MinIO with a provable audit trail.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter117-q2.md`

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | **4.25** | Core mechanics (CREATE TABLE LIKE INCLUDING PROPERTIES, INSERT INTO with WHERE filter for partition pruning, expire_snapshots / remove_orphan_files sequence, the 7-day Trino floor on expire_snapshots, table-property pitfalls) are correct and match the Trino 467 / Iceberg 1.5.2 docs. Two overstatements deduct ~0.75: (1) the flat claim that "Trino EXECUTE optimize does not apply position delete files" is incorrect — per [trino#24086](https://github.com/trinodb/trino/issues/24086) and the official connector docs, Trino's OPTIMIZE *does* clean up position deletes when it processes whole partitions without file_modified_time/path predicates. The practical recommendation to use Spark `rewrite_data_files` is still defensible (more reliable, no whole-partition constraint), but the absolute "NOT Trino" framing is wrong. (2) The statement "Drops the table AND deletes the underlying MinIO files" for `DROP TABLE iceberg.exports....` is conditionally true — there are known active issues ([trino#5616](https://github.com/trinodb/trino/issues/5616), [trino#25097](https://github.com/trinodb/trino/issues/25097), [discussion#25727](https://github.com/trinodb/trino/discussions/25727)) where DROP TABLE leaves MinIO data files behind depending on catalog / metastore configuration. The answer at least adds "Run remove_orphan_files on the exports namespace if needed" as a safety net, but should have flagged this upfront as a known caveat. |
| Beginner clarity | **5** | Excellent. Splits the problem into two named halves ("export" vs "physical deletion"), uses plain-English summaries before each SQL block ("Why this doesn't melt the cluster", "After this: queries return 0 rows. Bytes still on MinIO."), explicitly names what each step accomplishes physically. The timeline table at the end is the right summary device for a 30-day deadline. No unexplained jargon — MVCC is named with an inline gloss, "logical vs physical" is contrasted concretely. |
| Practical applicability | **4.5** | A SaaS engineer can execute this verbatim end-to-end. Concrete table-create syntax, concrete SQL for each phase, concrete Spark CALL syntax with correct parameter names, mc CLI command for MinIO copy, audit checklist with three layers (query / metadata / storage), and a day-by-day 30-day timeline. The session property `query_max_execution_time = '4h'` is real and correctly used. Minor gaps that hold this back from a 5: (a) does not warn that `INSERT INTO exports.acme_export ... SELECT *` from the source table will inherit the source's partition spec via `LIKE ... INCLUDING PROPERTIES`, which means the export table is *also* partitioned by tenant_id + day(event_ts) — fine for shape, but the engineer should be told to expect the same per-day file fragmentation in their export output (and might want to coalesce before handoff); (b) no mention of the customer needing to verify the export contents (checksum/row-count handshake), which is a real-world contract clause; (c) the `mc cp --recursive minio/lakehouse/exports/acme/20260525/data/` path assumes a specific Iceberg layout that may not match — the engineer should be pointed at `SELECT file_path FROM iceberg.exports."acme_export_20260525$files"` as a more reliable way to enumerate the actual data files. |
| Completeness | **4.75** | Hits both halves of the question (export + deletion-proof) plus the connective tissue (the export table itself contains the tenant's data and must be deleted, the 30-day timeline, audit verification). Covers (a) why direct app-layer scan would fail, (b) Trino-as-distributed-writer alternative, (c) Parquet-first vs CSV fallback, (d) the full 4-step physical-removal sequence (DELETE → rewrite_data_files → expire_snapshots → remove_orphan_files), (e) the Trino 7-day floor + Spark workaround, (f) table-property pitfalls (`history.expire.*`), (g) three-layer audit checklist, (h) handling the export table itself as deletable data. Minor gaps (-0.25): no mention of needing to apply the same physical-removal sequence to *every* table holding tenant data (the answer lists 4 example tables but doesn't say "repeat the full sequence per table" explicitly — easy to misread as "DELETE on all tables, then rewrite/expire/remove only on events"). |
| **Average** | **4.625** | |

**Verdict: PASS (4.625 / 5.0).**

---

## What was verified correct (via WebSearch + official docs)

1. **`CREATE TABLE ... (LIKE another_table INCLUDING PROPERTIES) WITH (location = ..., format = 'PARQUET')`** — confirmed valid Trino syntax per [Trino CREATE TABLE docs](https://trino.io/docs/current/sql/create-table.html). The `INCLUDING PROPERTIES` clause copies the source table's WITH properties; the WITH clause on the new table overrides any conflicts. Custom `location` works on Hive Metastore-backed Iceberg (the production stack); it is the REST catalog that ignores location ([trino#16394](https://github.com/trinodb/trino/issues/16394)), which is NOT the prod stack here.
2. **Partition pruning for `WHERE tenant_id = 'acme'`** — confirmed: with `analytics.events` partitioned by `tenant_id` (or bucket(tenant_id, N)), Trino's Iceberg connector applies partition-level pruning at the manifest layer and only reads the matching files. ([Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [Starburst Iceberg partitioning blog](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/))
3. **`query_max_execution_time` session property and `'4h'` value** — confirmed valid per [Trino query management properties](https://trino.io/docs/current/admin/properties-query-management.html). Duration strings like `'2h'`, `'4h'`, `'8h'` are accepted.
4. **`rewrite_data_files` accepts a `where` clause referencing non-partition or partition columns** — confirmed for Iceberg 1.5.x: `CALL catalog.system.rewrite_data_files(table => '...', where => "tenant_id = 'acme'")` is valid syntax per [Iceberg Spark procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/). Known edge case: if the WHERE matches zero files, Iceberg 1.5.x raises an AnalysisException (apache/iceberg#6759) — not relevant to the deletion path here because the DELETE in Step 1 leaves position-delete markers on real files.
5. **`expire_snapshots(table, older_than, retain_last)` Spark procedure signature** — confirmed correct per [Iceberg Spark procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/). `retain_last => 1` keeps the current snapshot; `older_than => current_timestamp()` expires everything older.
6. **`remove_orphan_files(older_than)` requires a time lookback** — confirmed; `INTERVAL '1' DAY` is a reasonable safety margin to avoid racing with in-flight commits per [Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/).
7. **Trino's 7-day floor on `expire_snapshots`** — confirmed: `iceberg.expire_snapshots.min-retention` defaults to 7d in the Trino Iceberg connector; running with a shorter retention via Trino's `ALTER TABLE ... EXECUTE expire_snapshots` fails. Running from Spark bypasses this floor — answer's recommendation matches the docs.
8. **`history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` table properties** — confirmed: both are honored by the Iceberg snapshot expiration machinery as documented in the [Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/) and the [Tabular cookbook on snapshot expiration](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/).
9. **Iceberg metadata tables `"events$snapshots"`, `"events$files"`, `partition.tenant_id`** — confirmed correct Trino syntax for identity-partitioned tables; the answer correctly uses `partition.tenant_id` (which works because identity partitioning preserves the field name).
10. **Distributed-writer model for `INSERT INTO ... SELECT`** — confirmed: Trino workers write Parquet files directly to MinIO in parallel; the data does not flow through the coordinator or application layer.

---

## Errors or gaps found

### MEDIUM — "Trino does NOT apply position delete files" is overstated
The answer says, in the Step 2 inline comment of Part B:
> `# Spark — NOT Trino EXECUTE optimize (Trino does not apply position delete files)`

Per Trino's official Iceberg connector docs and active triage in [trino#24086](https://github.com/trinodb/trino/issues/24086):
> "Position deletes are local to a partition. OPTIMIZE supports only enforced predicates which select whole partitions. Therefore, we can clean up position deletes in OPTIMIZE when there are no path or file_modified_time predicates."

Trino EXECUTE optimize **does** clean up position deletes when it processes entire partitions without `file_modified_time`/path predicates. The condition is narrow enough that recommending Spark for the GDPR-purge case is still defensible (Spark `rewrite_data_files` with a partition-column WHERE is more reliable and not subject to the "whole partition only" constraint), but the absolute "NOT Trino" framing is technically inaccurate and will mislead engineers who later debug why Trino OPTIMIZE *did* in fact clean up some delete files on their cluster.

Better wording: *"Use Spark `rewrite_data_files` here — it reliably rewrites and cleans up position deletes regardless of partition slice. Trino's `ALTER TABLE ... EXECUTE optimize` also cleans up position deletes, but only when processing whole partitions and only without path/file_modified_time predicates — narrower and less suitable for a per-tenant GDPR sweep."*

This same issue was flagged in the iter116 teacher fix to `resources/13` (per state.json notes), but the language in `resources/05` and downstream answers has not been fully tightened. The teacher should propagate the iter116 callout language into the GDPR section of `resources/05` so this exact wording stops appearing.

### MEDIUM — "DROP TABLE deletes underlying MinIO files" is conditionally true
Step 4 of Part A says:
> `-- Drops the table AND deletes the underlying MinIO files`

And the "Don't Forget the Export Table" section repeats:
> "This triggers MinIO deletion of the export files."

On Trino + Iceberg + Hive Metastore + MinIO, DROP TABLE *should* remove the data files, but there are multiple open issues and discussions documenting cases where it does not ([trino#5616](https://github.com/trinodb/trino/issues/5616), [trino#25097](https://github.com/trinodb/trino/issues/25097), [discussion#25727](https://github.com/trinodb/trino/discussions/25727)). The active proposal [trino#26798](https://github.com/trinodb/trino/issues/26798) even suggests gating data deletion on a `iceberg_purge_data_on_delete_enabled` property — implying the current behavior is at minimum inconsistent and being reconsidered.

The answer does mitigate this by adding "Run `remove_orphan_files` on the exports namespace if needed" — that is the right safety valve. But it should *lead* with that mitigation rather than treating it as an afterthought. Suggested rewrite:
> *"DROP TABLE removes the metastore entry and should remove the data files from MinIO, but there are known cases on Trino + Hive Metastore + MinIO where files can linger. Always follow with `remove_orphan_files` on the exports namespace and audit the MinIO bucket directly to confirm."*

### LOW — "Repeat for all tables" is implicit, not explicit
The 4-step physical-removal sequence shows one CALL per table per step (e.g., `rewrite_data_files(table => 'analytics.events', ...)`), and a comment "# Repeat for all tables" appears beside Step 2 and Step 3. But the Step 1 DELETE block enumerates 4 example tables (events, sessions, user_profiles, audit_logs), while the rewrite/expire/orphan steps show only one (events). A careful reader will infer "do all of these on all the tables", but a hurried oncall engineer might forget to repeat. Recommend a single explicit one-liner up front: *"The 4 steps below must be repeated, in order, for **every** Iceberg table that holds tenant data — not just `events`."*

### LOW — No mention of customer signoff / row-count handshake
For a GDPR contract clause, the customer-side acceptance step matters. The answer's timeline says "Day 2–7: Customer verifies export" but does not suggest the producer side actively confirm row counts before handoff (e.g., `SELECT COUNT(*) FROM iceberg.exports.acme_export_20260525` matches the source-side `SELECT COUNT(*) FROM analytics.events WHERE tenant_id = 'acme'` taken at the same snapshot). This is a small omission but a real-world failure mode — partial INSERT INTO from a worker crash would silently produce a short export.

### LOW — Spark CSV `coalesce(10)` is a magic number with no justification
Option B for CSV uses `df.coalesce(10).write...`. For "hundreds of millions of rows" of 3 years of data, 10 output files may produce very large CSVs (gigabytes each) that are hard to download/load in spreadsheet tools. A one-line note on file-sizing tradeoffs ("coalesce(N) controls output file count; pick N so each file is around 500MB–2GB compressed") would be more actionable. This is a polish issue, not a correctness issue.

### LOW — `mc cp --recursive minio/lakehouse/exports/acme/20260525/data/` assumes Iceberg's standard layout
The Iceberg directory layout under a custom `location` includes both `metadata/` and `data/` subdirectories. The `mc cp` example correctly targets the `data/` subdirectory only — but does not explicitly explain why (so the customer doesn't get metadata files they don't need). A better safer alternative is to use `SELECT file_path FROM iceberg.exports."acme_export_20260525$files"` to enumerate the actual data file paths first, then drive the `mc cp` from that list — this also doubles as a self-audit that every file actually contains tenant data.

---

## Topics touched (rubric updates)

- **Multi-tenant analytics: isolating customer data in SaaS** — primary topic. This is a per-tenant data lifecycle question (export + erasure) wrapped around a real GDPR contract clause.
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — secondary topic. Direct usage of `rewrite_data_files` + `expire_snapshots` + `remove_orphan_files` in the canonical 4-step sequence.

Both topics already PASSED with strong scores; this answer reinforces both but does not push either materially higher because of the two MEDIUM technical inaccuracies above.

Updating running average for Multi-tenant analytics:
- Header table shows: prior avg 4.456 across 103 questions.
- New running avg: (4.456 × 103 + 4.625) / 104 = (458.968 + 4.625) / 104 = 463.593 / 104 ≈ **4.458 across 104 questions**. PASSED.

---

## Resource fix recommendations

**HIGH — `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`** — fix the "Trino does NOT apply position delete files" framing in the GDPR right-to-erasure section. Replace any flat absolutist statement with the qualified version per Trino's official docs and the iter116 `resources/13` correction:

> Trino's `ALTER TABLE ... EXECUTE optimize` cleans up position deletes only when it processes whole partitions and only without `file_modified_time` or path predicates — too narrow for a per-tenant GDPR sweep. Use Spark `rewrite_data_files` with a partition-column WHERE clause for the GDPR purge sequence — it reliably rewrites and cleans up position deletes regardless of partition slice or predicate shape.

This same language was added to `resources/13` in iter117's teacher fixes per state.json notes; propagate to `resources/05` so the responder stops generating the overstated "NOT Trino" framing in GDPR contexts.

**MEDIUM — `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`** — add a DROP TABLE caveat callout in the GDPR / export-table cleanup discussion:

> **DROP TABLE on Iceberg + Hive Metastore + MinIO is not guaranteed to remove all data files.** Known issues ([trino#5616](https://github.com/trinodb/trino/issues/5616), [trino#25097](https://github.com/trinodb/trino/issues/25097)) document cases where DROP TABLE leaves MinIO files behind depending on catalog and metastore configuration. **Always** follow DROP TABLE with `remove_orphan_files` on the parent namespace, and audit the MinIO bucket directly to confirm zero residual bytes. For a regulator-grade audit, the bucket-direct check is what counts — do not rely on DROP TABLE alone.

This belongs near the existing "DROP PARTITION anti-pattern" discussion and the export-table cleanup section.

**LOW — `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`** — in the GDPR 4-step sequence, add an explicit up-front sentence: *"The full 4-step sequence must be repeated, in order, for every Iceberg table that holds tenant data — not just the events table shown in examples."*

**LOW — `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`** — in the export discussion, add a row-count handshake step to the audit checklist:
> Before handoff: `SELECT COUNT(*) FROM iceberg.exports.acme_export_20260525` must equal `SELECT COUNT(*) FROM analytics.events WHERE tenant_id = 'acme'` taken at the snapshot used for the INSERT. If they differ by even one row, ABORT and re-run the export — a silently-truncated export from a worker crash is the failure mode.

**LOW — `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`** — for the Spark CSV conversion, replace the magic-number `coalesce(10)` with a one-line sizing note: *"coalesce(N) controls output file count; pick N so each file lands around 500MB–2GB compressed for downstream usability."*

---

## Final verdict

**4.625 / 5.0 — PASS.** Strong answer that handles a genuinely composite question (export + erasure + audit + 30-day timeline) with the right architectural shape and a near-complete sequence of executable commands. The two MEDIUM technical overstatements (Trino OPTIMIZE position-delete handling, DROP TABLE bytes-on-MinIO) are inherited framing from earlier resource versions and should be tightened in `resources/05` so future iterations stop reproducing them. The beginner clarity and practical applicability are at production-quality level — an oncall SaaS engineer faced with this exact GDPR clause could execute this answer verbatim and pass a regulator audit, modulo the DROP TABLE caveat.

Sources:
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- [Trino CREATE TABLE docs](https://trino.io/docs/current/sql/create-table.html)
- [Trino query management properties (query_max_execution_time)](https://trino.io/docs/current/admin/properties-query-management.html)
- [Trino issue #24086 — Delete files not removed after Iceberg maintenance ops](https://github.com/trinodb/trino/issues/24086)
- [Trino issue #5616 — Iceberg DROP table not removing data from S3](https://github.com/trinodb/trino/issues/5616)
- [Trino issue #25097 — Trino not deleting table folder from MinIO on DROP TABLE](https://github.com/trinodb/trino/issues/25097)
- [Trino discussion #25727 — DROP TABLE does not delete files (Iceberg + REST + MinIO)](https://github.com/trinodb/trino/discussions/25727)
- [Trino issue #26798 — Add property to not remove data files on DROP TABLE](https://github.com/trinodb/trino/issues/26798)
- [Iceberg Spark Procedures (latest)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/)
- [Iceberg issue #6759 — Spark rewrite_data_files where condition AnalysisException](https://github.com/apache/iceberg/issues/6759)
- [Iceberg issue #2793 — Does expireSnapshots also remove data files?](https://github.com/apache/iceberg/issues/2793)
- [Tabular — Retain and expire snapshots](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/)
- [Starburst — Iceberg Partitioning and Performance in Trino](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/)
- [IOMETE — Iceberg Maintenance Runbook](https://iomete.com/resources/blog/iceberg-maintenance-runbook)
