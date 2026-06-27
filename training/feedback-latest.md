# Iter1190 Judge Feedback

**Overall verdict: STRONG PASS — NO-OP. Avg 4.828 / 5.** Load-bearing Q1 claim (optimize honors sorted_by) is CORRECT in fact; resources r28 §6.3 and r17 §276 / §1238 already make the same claim and are accurate.

## Q1 — Iceberg EXECUTE optimize + sorted_by — STRONG, CORRECT, NO-OP

**Verdict: 4.875.** Responder's "YES — EXECUTE optimize honors `sorted_by` and physically re-sorts" is **factually correct** for Trino 467. The Trino Iceberg connector reuses the Hive connector's `SortingFileWriter` during `EXECUTE optimize` and writes sorted output that honors the table-level `sorted_by` property.

- **PR [trinodb/trino #14891](https://github.com/trinodb/trino/pull/14891)** ("Support sorted writes in the Iceberg connector"): explicitly added support for sorting during `optimize`. From the author's comment: *"added support for sorting during updates and during `optimize`."* The implementation reuses the `SortingFileWriter` from the Hive connector.
- **Issue [trinodb/trino #18136](https://github.com/trinodb/trino/issues/18136)** ("Iceberg optimize fails when sorted_by UUID columns"): the failure stack trace shows the failure originates in `SortingFileWriter.writeTempFile()` while running `ALTER TABLE … EXECUTE optimize` — confirming optimize DOES attempt to sort by `sorted_by` columns (the bug is in temp-file serialization of UUID, not in the design).
- **[Starburst blog — Improving performance with Iceberg sorted tables](https://www.starburst.io/blog/improving-performance-with-iceberg-sorted-tables/)**: *"the Optimize command will sort the data based on the DDL of the table"* + *"This command will optimize the `catalog_sales_sorted` table by combining smaller files into larger ones that are sorted by the `cs_sold_date_sk` column."*

**Caveat on doc page wording:** the [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) `optimize` section is silent on `sorted_by` interaction (it only says "merged into fewer but larger files"); the `sorted_by` property section says "Data is sorted during **writes** within each file" — which technically includes the rewrite-as-write produced by `EXECUTE optimize`. So the doc text doesn't *explicitly* state the integration even though it does happen. A skeptical engineer who only reads the docs page may not be sure; the PR + Starburst blog + bug stack trace are needed to confirm. Responder's confidence is appropriately calibrated against actual behavior, not against the doc-page wording strictness — fine.

**Resource source-check (r28 §6.3 / r17 §276 / r17 §1238):** these all state the same claim. Verified all three:

- `resources/28-complex-sql-performance-trino-dbt.md:1238` — *"Trino 467: bin-packs and re-sorts to honor the table's sorted_by property."* CORRECT.
- `resources/17-iceberg-table-maintenance.md:276` — *"Trino's EXECUTE optimize reads sorted_by at OPTIMIZE time and produces sorted output."* CORRECT.

No FIX-A needed. Resources are accurate; responder routed cleanly. (The pinned [reference_trino_parquet_bloom_filter_469.md](https://github.com/hclin-code/recknihao/blob/main) caution about CREATE-vs-ALTER versioning is the right model for similar version-edge claims; this one stands.)

- Minor shave (-0.5 Compl): could have explicitly named that the `file_size_threshold => '256MB'` controls which existing files are eligible for re-sort + re-pack (files ALREADY larger than threshold are skipped — so for a one-shot full-table re-sort you must set the threshold above the largest existing file, per r17 §279-281). Engineer running a recurring `file_size_threshold => '256MB'` schedule will get the streaming-small-files merged-and-sorted as expected on each tick, but won't re-sort big already-existing files. The Spark-streaming-many-small-files scenario in the question is exactly the case where this works as designed, so the practical answer is fine.

## Q2 — RANGE INTERVAL window frame for 3-month rolling avg — STRONG

**Verdict: 4.9375.** Verified at [trino.io/blog/2021/03/10/introducing-new-window-features.html](https://trino.io/blog/2021/03/10/introducing-new-window-features.html) (RANGE with `<value>` PRECEDING was added in Trino 346): *"Since version 346, it is possible to specify RANGE with an offset value, where the frame includes all rows whose value is within this range from the current row."* Example from blog: `AVG(totalprice) OVER (PARTITION BY custkey ORDER BY orderdate RANGE BETWEEN INTERVAL '1' MONTH PRECEDING AND CURRENT ROW)`. Direct shape match. Trino 467 supports DATE / TIMESTAMP ordering columns with `INTERVAL` offset.

- `AVG(revenue) OVER (PARTITION BY account_id ORDER BY month RANGE BETWEEN INTERVAL '2' MONTH PRECEDING AND CURRENT ROW)` — correct frame for "current month + 2 prior" on a DATE ordering column.
- ROWS-vs-RANGE distinction CORRECT: ROWS counts physical rows (so a gap row pulls in months further back than wanted); RANGE+INTERVAL on a date column is calendar-value-based (frame includes all rows whose ordering-column value falls in `[current - 2 months, current]`). Engineer's missing-Feb example: for the 2025-03 row the frame includes any row with month in `[2025-01, 2025-03]` — captures Jan + Mar correctly; ROWS-2-PRECEDING would walk back through the previous 2 physical rows regardless of date and grab e.g. 2024-12 + 2025-01.
- COALESCE / densify-a-calendar-spine caveat for empty frames / NULL avg also correct — when the 3-month window has no rows (first 2 months of the partition's history) the AVG is NULL; engineer needs `COALESCE(...,0)` if widget needs a numeric or LEFT JOIN against a calendar spine if they need every month present.
- Minor shave (-0.25 Compl): could have noted that the first month of each account's history will have a 1-month frame (only itself); whether that's the desired semantics depends on definition. Recall ceiling, not load-bearing.

## Q3 — dbt-trino incremental_strategy='merge' for Iceberg — PASS

**Verdict: 4.5.** Technically correct: `incremental_strategy='merge'` IS supported by dbt-trino for Iceberg tables. Trino 467 has native MERGE INTO on the Iceberg connector ([trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html)). dbt-trino compiles `incremental_strategy='merge'` into a Trino MERGE statement using `unique_key` as the ON predicate ([docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs)): *"With the `merge` incremental strategy, dbt-trino constructs a Trino MERGE statement to insert new records and update existing records, based on the `unique_key` property."*

Responder's troubleshooting hints (wrong catalog `hive.*` vs `iceberg.*`, old dbt-trino `<1.3`) are plausible — the Hive connector has very limited MERGE support, while the Iceberg connector supports MERGE natively; if the model resolves to a Hive-backed table the error matches. The dbt-trino docs explicitly warn: *"Be aware that there are some Trino connectors that don't support `MERGE` or have limited support."*

- Minor shave (-0.5 Tech / -1.0 Compl): the framing "YES fully supported, no adapter limitation" is slightly over-absolute. Should have noted (a) the dbt docs explicitly warn that some Trino connectors have limited MERGE support and Hive is one of them — so verifying the target catalog is Iceberg is genuinely load-bearing; (b) the explicit fallback if MERGE isn't viable on a particular connector is `incremental_strategy='delete+insert'` (constructs DELETE+INSERT keyed on `unique_key`) — should have named this as the "if you're stuck" alternative; (c) `format_version: 2` is required for Iceberg MERGE / row-level deletes (V2 default in recent Iceberg, but worth a sanity-check if their table predates the V2 default).
- Practical applicability shave: engineer hitting the error needs the diagnostic order: (1) check `dbt --version` (need dbt-trino ≥ 1.3); (2) check the model's target catalog (`{{ target.catalog }}` / profiles.yml — must resolve to an Iceberg catalog, not Hive); (3) check the table's `format_version` if it's a pre-existing table; (4) if stuck, fall back to `delete+insert`. Responder named (1) and (2) but not (3) or (4).

## Q4 — Oracle MINUS → Trino EXCEPT — STRONG PASS

**Verdict: 5.0.** All facts verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html):
- `query EXCEPT [ALL | DISTINCT] [CORRESPONDING] query` — supported; default is `DISTINCT` (dedupes).
- `EXCEPT ALL` preserves duplicates from left input.
- `INTERSECT` and `UNION` / `UNION ALL` also supported.
- `MINUS` is NOT a Trino keyword (Oracle-specific synonym for EXCEPT DISTINCT).
- NULL-safety contrast with `NOT IN` correctly stated: `EXCEPT` compares rows structurally including NULLs (two NULLs in the same column position match each other for EXCEPT-elimination purposes); `NOT IN (...)` returns no rows when the right side contains any NULL (the classic 3VL trap). For an Oracle engineer trained to write `WHERE col NOT IN (SELECT ...)` as a MINUS-substitute, this NULL caveat is the genuinely load-bearing nuance.

## Topic updates

| Topic | Q | Old | New |
|---|---|---|---|
| Iceberg partition design for SaaS | Q1 = 4.875 | 4.4465/53 | 4.4544/54 |
| Analytical query patterns on Iceberg+Trino | Q2 = 4.9375 | 4.5045/138 | 4.5076/139 |
| Oracle PL/SQL → dbt+Trino migration | Q3 = 4.5, Q4 = 5.0 | 4.4592/148 | 4.4630/150 |

Total iter1190 score: **(4.875 + 4.9375 + 4.5 + 5.0) / 4 = 4.828 / 5 STRONG PASS NO-OP**.

## Next iteration

Return to BREADTH. No new watches, no resource defects, no FIX-A. Q1 confirms r28 §6.3 + r17 §276/§1238 `EXECUTE optimize honors sorted_by` claim is correct (re-verified against PR #14891 + issue #18136 + Starburst blog); this anchors the "compaction undoes our sort" worry-class. Q3 dbt-trino merge / Iceberg framing was good but slightly over-absolute — re-probe with a more pointed "but the dbt docs say some connectors have limited MERGE — does that include Iceberg?" framing in 5-10 iters to make sure responder routes to the connector-matrix nuance (Iceberg = native, Hive = limited) on the first try. Q4 EXCEPT vs MINUS is a clean recall; don't re-probe soon.
