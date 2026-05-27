# Score: iter226-q1
Score: 4.75
Topic: Trino federation / cross-source connectors (also touches Trino CBO / ANALYZE / Puffin / NDV / join ordering)

## What was correct

- **Build/probe orientation framing**: Accurately distinguishes build side (hash table in memory) vs probe side (streamed), and correctly identifies that getting it wrong causes OOM or wasted network. Matches standard Trino CBO behavior.
- **CBO needs cardinality estimates**: Correct that the optimizer estimates post-filter rowcounts and uses NDV + distribution + rowcount. Verified against trino.io optimizer/statistics docs.
- **Iceberg row count is metadata-free**: Correct — Iceberg manifests carry record counts so Trino has rowcount for free; only NDV requires ANALYZE / Puffin.
- **ANALYZE writes a Puffin file**: Verified against Trino Iceberg connector docs — NDV is written to Puffin files alongside table metadata.
- **ANALYZE syntax for Iceberg (no TABLE keyword)**: Correct — Trino's parser uses `ANALYZE <table>`, not `ANALYZE TABLE <table>`. The explicit "this differs from Spark/Hive" call-out is pedagogically valuable.
- **WITH (columns = ARRAY[...]) syntax**: Correct Trino syntax for restricting ANALYZE to specific columns.
- **MySQL JDBC connector reads stats from INFORMATION_SCHEMA**: Verified — table-level from INFORMATION_SCHEMA.TABLES, column-level from INFORMATION_SCHEMA.STATISTICS (index stats).
- **Native ANALYZE TABLE on MySQL side**: Correct guidance — Trino cannot ANALYZE a JDBC table, so the user must run native MySQL ANALYZE.
- **SHOW STATS FOR syntax + distinct_values_count column name**: Verified against trino.io SHOW STATS docs — exact column name is correct.
- **EXPLAIN output with Join[BROADCAST] / Join[PARTITIONED]**: These distribution labels do appear in Trino EXPLAIN output (verified against trino.io EXPLAIN docs).
- **Stats are not auto-updated**: Correct — Iceberg Puffin NDV requires re-ANALYZE on table changes.
- **Production-stack fit**: Mentions MinIO (Puffin file location) which matches prod_info.md. No incompatible advice.

## What was wrong or missing

- **MySQL column-level statistics caveat omitted**: The Trino MySQL connector returns column-level statistics ONLY when the column is the first column of an index. The answer tells the user to run `ANALYZE TABLE billing_mysql.invoices` and expect `distinct_values_count` to be populated, but if the join key `plan_tier` is not the first column of an index, `SHOW STATS` will still return NULL for that column. This is a load-bearing gotcha that the answer misses. The Trino docs also recommend MySQL 8.0 histogram statistics (`ANALYZE TABLE ... UPDATE HISTOGRAM ON column`) for better accuracy — not mentioned.
- **Schema namespace inconsistency for MySQL**: The answer writes `billing_mysql.public.invoices` in two SHOW STATS examples — `public` is a Postgres convention, not MySQL. MySQL uses the database name as the schema (e.g., `billing_mysql.billing.invoices` or similar). Minor but the engineer will hit a "schema not found" if they copy-paste.
- **No mention of session-level join distribution override**: For a fast workaround while the user is waiting on ANALYZE, the session property `join_distribution_type = 'BROADCAST'` (or `SET SESSION join_distribution_type = 'BROADCAST'`) gives an immediate fix. The answer focuses entirely on the long-term stats-based fix; a one-line fallback would have been useful.
- **No mention of dynamic filtering**: Trino 467 has dynamic filtering on by default, which often rescues the bad-build-side case at runtime even with poor stats. Worth a one-liner for context — explains why the user might see better-than-expected performance even before fixing stats.
- **`drop_extended_stats` re-analyze caveat absent**: Per Trino Iceberg docs, if stats were previously collected for ALL columns, you must call `drop_extended_stats` before re-ANALYZE with a column subset. Not critical for first-time ANALYZE but the answer recommends a weekly cadence without mentioning this.
- **ANALYZE cadence guidance is generic**: "Weekly" is reasonable but not tied to anything concrete; better guidance would be "after >10% of rows change" or "after major compaction/snapshot rewrites."

## Verdict

PASS. The answer is technically solid on the core CBO/NDV/ANALYZE/Puffin path and gives the engineer a runnable playbook for both the Iceberg and MySQL sides. The Iceberg ANALYZE syntax, Puffin storage, SHOW STATS column names, and EXPLAIN BROADCAST/PARTITIONED labels are all verified correct against trino.io 480/481 docs. The missing MySQL "first column of index" caveat and the `public` schema typo are real gaps that an engineer following the playbook will hit, but they don't invalidate the core advice. Above the 4.5 raised threshold for both Trino federation and CBO topics.

Dimension scores:
- Technical accuracy: 4.5 (correct on all big claims, missing MySQL column-stats caveat, minor schema namespace error)
- Beginner clarity: 5.0 (build/probe and broadcast/partitioned both explained from scratch, NDV defined with a concrete example, clear "this differs from Spark" warning)
- Practical applicability: 5.0 (copy-pasteable commands for both sides, verification path via SHOW STATS and EXPLAIN, cadence guidance, concrete "key takeaway" closer)
- Completeness: 4.5 (covers all three sub-questions — how Trino decides, why it gets it wrong, what to run — but misses session-level workaround and dynamic filtering context)

Average: (4.5 + 5.0 + 5.0 + 4.5) / 4 = 4.75
