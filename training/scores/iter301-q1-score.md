# Iter 301 Q1 Judge Score

## Topic
Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 3.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 5.0 |
| **Average** | 4.375 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification

Verified against docs.getdbt.com (incremental-strategy, incremental-models, trino-configs) and Iceberg/Dremio docs.

**Correct claims:**
- `is_incremental()` returns false on first run; SQL inside the block filters source rows on subsequent runs. Correct.
- `unique_key` with `merge` strategy compiles to a SQL `MERGE INTO` upsert. Correct.
- Iceberg 1.5.2 ships with Copy-on-Write as the default `write.merge.mode`. Correct.
- CoW rewrites data files entirely; MoR uses delete files; explicit `ALTER TABLE` to switch modes is correct syntax.
- Iceberg schema evolution via `ALTER TABLE ADD COLUMN` is metadata-only and backward-compatible. Correct.
- Trino `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` syntax is correct.
- Snapshot rollback via `CALL iceberg.system.rollback_to_snapshot(...)` is correct catalog-name pattern (this is Spark syntax; Trino uses `ALTER TABLE ... EXECUTE rollback_to_snapshot(...)` — minor engine-labeling miss since prod uses Trino).
- `xmin` as alternative watermark for missed-backdated rows is a valid Postgres trick.

**Incorrect or misleading claims:**
1. **`on_schema_change` default is wrong.** The answer says `fail` is the default. Per dbt docs, **`ignore` is the default**. (Confirmed via docs.getdbt.com.)
2. **The three incremental strategies for Iceberg are wrong for dbt-trino.** Answer lists `append`, `merge`, `insert_overwrite`. For dbt-trino (the likely adapter in this prod stack), the actual strategies are `append` (default), `merge`, and `delete+insert`. `insert_overwrite` is the **dbt-spark** strategy and is NOT supported for Iceberg in dbt-trino (IOMETE docs explicitly state insert_overwrite is rejected with Iceberg). Since prod runs Trino 467 with the Iceberg connector, this is the more likely adapter, so the answer's strategy list is incorrect for the production environment.
3. **"`merge` (default on Iceberg)"** — for dbt-trino, the default is `append`, not `merge`. Engineer would need to explicitly set `incremental_strategy='merge'`.
4. **MERGE INTO compiled SQL.** The simplified compiled SQL adds `AND s.updated_at > t.updated_at` to the MATCHED branch. dbt's default merge does NOT add that predicate — it overwrites matched rows unconditionally. To get this conditional update, the engineer would need `incremental_predicates` or a custom `merge_update_columns`. This is a misleading simplification.
5. **`macros.timedelta(days=4)`** — the correct dbt Jinja is `modules.datetime.timedelta(days=4)`. Engineer would get a Jinja error trying to run this snippet.
6. **Engine labeling miss.** `CALL iceberg.system.rollback_to_snapshot(...)` is Spark syntax. The prod stack uses Trino — Trino syntax is `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)`. The answer does not flag this.

## What worked
- Excellent narrative structure: watermark → unique_key → strategies → CoW/MoR → schema change → Iceberg considerations → summary code block.
- The "this is not automatic magic" framing on watermarks is exactly the mental model a SaaS engineer new to dbt needs.
- Late-arriving data widening pattern is a real production concern that was correctly surfaced.
- Compaction recommendation and small-file warning are appropriate for daily incremental MERGE workloads.
- CoW vs MoR trade-off explained at the right level for a beginner — write cost vs read cost framing is correct and actionable.
- Final summary code block ties it all together with a concrete copy-paste config.

## What was wrong or missing
- Wrong default for `on_schema_change` (`fail` claimed, actual default is `ignore`).
- Wrong adapter's strategy list — `insert_overwrite` doesn't exist in dbt-trino for Iceberg; `delete+insert` is the third strategy and was omitted.
- Wrong default strategy for dbt-trino (`append` is default, not `merge`).
- The compiled MERGE INTO example over-specifies what dbt actually generates.
- `macros.timedelta` is not valid dbt Jinja (should be `modules.datetime.timedelta`).
- Engine syntax: `CALL` is Spark, not Trino. For prod-fit answer, should mention Trino's `ALTER TABLE ... EXECUTE` form.
- Missing: dbt-trino's `incremental_predicates` config, which is the right way to add target-side scan pruning to the MERGE — would help the engineer with their large mutable orders table.
- Missing: note that since prod uses both Spark (for ingestion) and Trino (for query/dbt), the adapter choice (`dbt-spark` vs `dbt-trino`) materially changes which strategies are available — would have caught the insert_overwrite vs delete+insert confusion.

## Suggested topic score update
Old: 4.476 / 100 questions
New avg if this scores 4.375: (4.476 * 100 + 4.375) / 101 = 447.975 / 101 ≈ **4.475 across 101 questions**
