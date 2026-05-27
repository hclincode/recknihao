# Iter 110 Q2 — Judge Verdict

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Question summary**: 400-tenant table with a few 50–100M-row enterprise tenants; per-tenant queries with `WHERE tenant_id = ?` slow on big tenants. Is it a fact of life or a table-design problem?

---

## Dimension scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Root-cause analysis is correct: `tenant_id` not in the partition spec means manifest pruning cannot eliminate other tenants' files. ALTER TABLE SET PROPERTIES partitioning = ARRAY[...] syntax is correct for Trino 467 (verified against trino.io). Correctly labels `CALL iceberg.system.rewrite_data_files` as Spark-only — Trino's native equivalent is `ALTER TABLE ... EXECUTE optimize`, which the answer fails to mention. The claim that partition column ORDER does not affect pruning is correct (order affects file clustering / sort, not the manifest-level predicate evaluation). The `$files` query with `partition.tenant_id` and `partition.day` uses ROW dot-notation, which is valid Trino syntax when those fields exist in the current partition spec (and the answer's caveat at the end about column-not-found is appropriate). Minor inaccuracy: `partition.day >= CAST(CURRENT_DATE - INTERVAL '1' DAY AS VARCHAR)` — `day(timestamp)` in Iceberg materializes as an INT (days since epoch) or DATE in the partition struct, not a string; the CAST to VARCHAR is wrong and will fail or implicit-cast unexpectedly on Trino 467. |
| Beginner clarity | 4.5 | Opens with a direct yes/no ("not just a fact of life") that beginners can act on. Explains WHY small tenants are fast "by accident". Step-by-step structure (new table → existing table → why this order → small files → diagnostic) is clean. Jargon (manifest pruning, partition spec, snapshot expiration) used but each is contextualized. Could briefly define "partition pruning" once. |
| Practical applicability | 4.0 | Engineer can act immediately: a CREATE TABLE example, an ALTER TABLE migration, a rewrite step, an expire-snapshots step, a small-files compaction step, and a diagnostic query. However: (a) the diagnostic query has a CAST bug that will trip up the engineer; (b) does NOT mention Trino's native `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '...')` which is the in-stack way to compact without going to Spark; (c) does NOT warn about manifest explosion risk when adding `tenant_id` to a 400-tenant table (this is the classic catch — answer would benefit from a one-line note that bucket(tenant_id, N) is often the better choice when the tenant count is large but here 400 distinct tenant values × daily partitions is borderline; the answer pushes raw `tenant_id` partitioning without that nuance); (d) does not estimate how long the rewrite_data_files step will take, nor warn about MinIO write amplification on a 50–100M-row tenant. |
| Completeness | 4.0 | Covers the diagnostic (why it's slow), the structural fix (add tenant to partition spec), partition evolution for existing tables, the order-doesn't-matter-for-pruning subtlety, small-files compaction, and snapshot expiration. Misses: (1) the bucket(tenant_id, N) alternative for high-cardinality cases — important caveat since the engineer has 400 tenants and 400 × daily partitions × any sub-partitioning quickly creates a manifest explosion; (2) Trino-native OPTIMIZE; (3) sort-order recommendation within tenant partitions (e.g., ORDER BY event_ts) for row-group min/max effectiveness; (4) recommendation to verify the fix with EXPLAIN ANALYZE showing reduced "input rows" / "files read" after the change. |

**Weighted overall score** (simple average): (4.5 + 4.5 + 4.0 + 4.0) / 4 = **4.25 / 5**

PASSES the ≥ 3.5 threshold.

---

## WebSearch verification summary

1. **Partition order does NOT affect pruning** — Verified. Iceberg pruning uses per-file partition metadata in manifests independent of the column order in the spec. Order affects file layout / sort clustering, not the pruning predicate. Answer is correct.
2. **`ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]`** — Verified correct for Trino Iceberg connector (trino.io 481 docs, Starburst blog). Answer correct.
3. **`$files` with `partition.tenant_id` dot-notation** — `partition` column on `$files` is a ROW type; ROW dot-access is standard Trino. Valid when the partition column exists in the current spec. Answer correct, and its caveat at the bottom about column-not-found is appropriate. Sub-bug: the CAST of `partition.day` to VARCHAR is wrong — `day(...)` materializes as INT/DATE.
4. **`CALL iceberg.system.rewrite_data_files` Spark-only from Trino** — Verified. Trino's Iceberg connector does NOT expose `rewrite_data_files`; Trino uses `ALTER TABLE ... EXECUTE optimize(...)`. Answer correctly labels it as "Spark SQL only" but FAILS to mention the Trino-native alternative — a practical applicability gap for an on-prem Trino 467 + Spark stack.

---

## Errors and gaps

**Bugs that will surface in the engineer's terminal:**
- `WHERE partition.day >= CAST(CURRENT_DATE - INTERVAL '1' DAY AS VARCHAR)` — type-mismatch. `partition.day` is INT (days-since-epoch) when the partition transform is `day(event_ts)`. The right form is something like `WHERE partition.day >= date_diff('day', DATE '1970-01-01', CURRENT_DATE - INTERVAL '1' DAY)` or compare against a date-typed expression.

**Missing content:**
- No mention of `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` as the Trino-native compaction path. The answer routes the user to Spark for both the migration rewrite and the routine compaction, which is unnecessarily heavy for the production stack.
- No warning that adding raw `tenant_id` to a partition spec creates one partition per tenant per day, which at 400 tenants × 90 days = 36k partitions — large but tolerable, but the answer should call out the manifest size implication and the `bucket(tenant_id, N)` alternative for cases where tenant count is high. The previous Q1 (iter 109) on the same topic specifically rewarded bucket(tenant_id, N) thinking — this answer skips it.
- No recommendation to add a `sort_order` (e.g., sorted on event_ts within tenant partition) so that row-group min/max enables further within-file pruning for time-range dashboards.
- No EXPLAIN ANALYZE verification step ("after the migration, run EXPLAIN ANALYZE and confirm 'input rows' drops to roughly the tenant's row count").

---

## Resource fix recommendations

1. **`resources/05-multi-tenant-analytics.md`** (or wherever the per-tenant partitioning recipe lives): Add a callout: "For tenant counts up to ~50, `partitioning = ARRAY['day(event_ts)', 'tenant_id']` is fine. For 100+ tenants, prefer `bucket(tenant_id, 32)` (or N) to avoid manifest growth — large-tenant queries still prune to 1 bucket via Iceberg's bucket-pruning of equality predicates."
2. **Same resource**: Add Trino-native compaction recipe alongside the Spark one — `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '100MB')` — with a note that this is the on-prem default since the stack already has Trino 467 and we can avoid a Spark hop.
3. **Same resource**: Fix the `$files` diagnostic SQL to use the correct INT/DATE comparison against `partition.day`. Add an explicit note that partition fields' types in `$files.partition` match the transform output type (`day(...)` → INT, `month(...)` → INT, `bucket(..., N)` → INT, identity → source type).
4. **Same resource**: Add an "Always verify" closing step: run `EXPLAIN ANALYZE` before and after partition evolution, compare "input: rows" and number of splits.

---

## Running average update

Prior topic running average: **4.460** across **104** questions.
This question score: **4.25**.
New running average: (4.460 × 104 + 4.25) / 105 = (463.84 + 4.25) / 105 = 468.09 / 105 = **4.458** across **105** questions.
Status: **PASSED** (well above 3.5 threshold; well-tested with 105 questions across many angles).
