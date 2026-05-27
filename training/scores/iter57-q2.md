# Score: iter57-q2
**Topic**: Postgres-to-Iceberg ingestion
**Score**: 4.9 / 5.0

## Dimension scores
- Completeness: 4.5/5
- Accuracy: 5/5
- Clarity: 5/5
- No hallucination: 5/5

## What the answer got right
- Correctly diagnosed why `createOrReplace()` causes the 25-minute outage: it drops the entire Iceberg table, recreates it empty, and only then writes 8M rows — readers during that window see missing or partial data. The mental model "the DataFrame schema IS the table" is implicit in the explanation.
- Proposed the right primary solution: write into a separate `product_catalog_staging` table while the live table stays fully available, then atomically swap via a Trino view. This is exactly the production-correct pattern for the prod stack (Spark + Iceberg + Trino).
- Code-complete walkthrough: parallel JDBC read with `partitionColumn` / `numPartitions`, write to staging with `createOrReplace()` (which is now safe because the live table is untouched), then `CREATE OR REPLACE VIEW` to swap.
- Correctly explained Iceberg snapshot isolation: every write commits as an atomic immutable snapshot; readers always see one complete consistent snapshot, never a partial write. Verified against Iceberg docs (snapshot isolation + atomic metadata swap via compare-and-swap).
- Correctly stated that `CREATE OR REPLACE VIEW` in Trino is atomic — verified via Iceberg view-spec and Trino docs: view metadata is replaced via atomic swap delegated to the metastore.
- Rollback pattern via `ALTER TABLE ... RENAME` to `_prev` is sensible and operationally practical — engineer can revert the view to the previous staging table if data quality is bad.
- Included maintenance hooks (`rewrite_data_files`, `expire_snapshots`) which the engineer would otherwise have to ask about next.
- Crisp summary at the end ties the whole flow together.

## What the answer missed or got wrong
- Did NOT discuss `overwritePartitions()` as an alternative path when the table is partitioned. For a `product_catalog` table that happens to be partitioned (e.g., by `category` or `tenant_id`), a single `overwritePartitions()` call commits as one atomic snapshot and would also eliminate the gap without needing a staging table — this is in the expected coverage list and was a legitimate gap. Minor because product_catalog is plausibly unpartitioned, but the engineer asking might have a partitioned dimension table next quarter.
- The example `CREATE TABLE iceberg.analytics.product_catalog_staging (...) USING iceberg;` uses `USING iceberg` syntax which is Spark SQL — fine in context, but mixing Spark SQL DDL with Trino view DDL in the same snippets without flagging the engine for each could trip a reader. A one-line note ("the CREATE TABLE runs in Spark SQL; the VIEW runs in Trino") would have helped.
- Did not mention that the view-swap approach requires analysts to query the view, not the table — if any dashboard still hits `product_catalog` directly, it will continue to see the old (now stale) data after the swap. This consumer-discipline angle was a small miss but production-relevant.

## Recommendation for teacher
Resource 13 already covers the staging-table + view-swap pattern well, judging from the answer's quality. Two small additions would close the remaining gap:
1. Add an "if your table is partitioned, prefer `overwritePartitions()`" subsection to the full-refresh pattern in resource 13. Show that one atomic snapshot commit avoids the staging dance for partitioned tables.
2. Add a one-line "remember to repoint all consumers to the view, not the base table" warning to the view-swap cutover section. Engineers will otherwise ship the staging+view machinery and still see stale dashboards because one Looker/Tableau report kept its old table reference.

No core content gaps. The answer demonstrated correct fluency on snapshot isolation, atomic view swap, and rollback discipline — all of which are explicitly in the resource.

---

## Rubric update arithmetic

Prior avg for Postgres-to-Iceberg ingestion: 4.309 across 56 questions.
This score: 4.875 (computed as (4.5 + 5 + 5 + 5) / 4 = 19.5 / 4 = 4.875).

New running avg = (4.309 × 56 + 4.875) / 57
               = (241.304 + 4.875) / 57
               = 246.179 / 57
               ≈ 4.319

Status: PASSED (avg >= 3.5 threshold).
