# Iter88 Q1 — Judge Score

## Score: 4.75 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4.5 |

## Points covered
- What $files and $partitions metadata tables expose (file-level vs partition-level aggregates) — covered
- Concrete SQL query using $files to get per-tenant file_count and total_gb — covered
- How to interpret the output (high file_count vs high GB) — covered (small-files vs storage footprint)
- Decision guidance: which tenants to migrate vs keep shared — covered (top 3 > 50 GB, 30 percent threshold, < 1 GB stay shared)
- Security note: never grant tenant principals access to $-suffix metadata tables — covered (OPA deny rule called out)
- Bonus: safe migration cutover sequence — covered (INSERT, verify, swap view, then delete)

## Technical accuracy gaps
- The `partition.tenant_id` accessor in the `$files` query is correct Trino syntax for accessing the nested partition struct field — verified via Trino docs and GitHub issue #26746. Good.
- `file_size_in_bytes` is the correct column name in `$files`. Verified.
- `$partitions` columns referenced (`record_count`, `file_count`) are correct. Verified.
- Minor caveat not flagged: `partition.tenant_id` only works cleanly when the table's CURRENT partition spec includes `tenant_id`. If the partition spec was ever evolved (e.g., add bucketing later), the `$partitions` table only reflects the current spec (Trino GitHub issue #12323), and `$files.partition` may have field-ID-ordering caveats (issue #26109). For an 80-tenant table partitioned by `tenant_id` from creation this is fine, but worth a one-line note.
- Minor caveat not flagged: `$files.file_size_in_bytes` for ORC files can be slightly off due to Trino issue #9810 (5 extra bytes per varchar column). Not material for "which tenant is heavy" sizing, but technically inaccurate at the byte level. Not penalized heavily.
- Migration step 1 SQL uses backticks around table names. Trino uses double quotes, not backticks. The shown statement `INSERT INTO analytics.acme_events SELECT * FROM analytics.events WHERE tenant_id = 'acme'` would actually run fine without quoting, but the formatted backticks in the prose are misleading if a reader copies them literally. Minor.
- Production fit (prod_info.md: Trino 467 + OPA + MinIO + Hive Metastore): all advice fits. The OPA deny-on-$-suffix recommendation aligns with the production auth model. Good.

## Completeness gaps
- Does not mention that `$files` reads only the CURRENT snapshot — engineers asking "is my tenant growing" might want to know `$snapshots` / `$history` exist for trend analysis. The answer suggests "run weekly via cron" which solves this practically, so this is a minor gap.
- Does not mention `$partitions.total_size` column, which would have given a single-table alternative (no need to SUM from $files) for the primary query. The chosen approach via $files is still correct and arguably more flexible.
- Does not flag that `partition.tenant_id` syntax requires the partition column to literally be `tenant_id` (identity transform). If the production table partitions via `bucket(N, tenant_id)`, the field becomes `partition.tenant_id_bucket` and the query needs adjustment. For an engineer with no OLAP background this could trip them up.

## Verified (WebSearch)
- Verified `$files` table column names (`file_path`, `file_size_in_bytes`, `record_count`, `partition`) against Trino Iceberg connector documentation.
- Verified `partition.<column>` dot-notation access syntax against Trino GitHub PR #26746 and issue threads — confirmed correct.
- Verified `$partitions` columns (`partition`, `record_count`, `file_count`, `total_size`) against Trino docs and Starburst blog.
- Verified file_size_in_bytes ORC accuracy caveat (Trino issue #9810) — minor and not relevant for heavy-tenant detection.
- Verified production environment fit: Trino 467 + Iceberg connector + OPA authorization all align with the answer's recommendations.

## Sources
- [Iceberg connector — Trino Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Trino on ice IV: Deep dive into Iceberg internals](https://trino.io/blog/2021/08/12/deep-dive-into-iceberg-internals.html)
- [Trino PR #26746 — Fix $files partition column construction](https://github.com/trinodb/trino/pull/26746)
- [Trino issue #12323 — $partitions only uses current Spec](https://github.com/trinodb/trino/issues/12323)
- [Trino issue #9810 — Iceberg ORC file_size_in_bytes inaccuracy](https://github.com/trinodb/trino/issues/9810)
