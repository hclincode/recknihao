# Score: iter51-q1

**Topic**: Storage sizing and growth estimation
**Score**: 4.25 / 5.0

## What the answer got right
- Correctly leads with "Postgres 250 GB will become significantly less in Iceberg" — the right headline.
- Accurate decomposition of Postgres on-disk overhead: indexes (30–50%), MVCC dead tuples (20–40%), row header overhead (~23 bytes/row). Matches expected criteria.
- Provides a runnable `pg_total_relation_size` / `pg_indexes_size` SQL snippet for the engineer to verify their own baseline — directly closes the "wrong baseline" trap flagged repeatedly in prior iterations (Iter 3 Q4, Iter 5 Q2, Iter 11 Q4).
- Per-column-type compression breakdown is sound: low-card strings 10–50x (dictionary encoding), timestamps 10–20x (delta encoding), UUIDs 1.5–2x, numerics 3–5x. Aligns with parquet.apache.org documentation.
- Overall 5–10x ratio with ~7x average is reasonable for typical SaaS event data.
- Worked example shows the math cleanly: 250 → 160 (minus indexes) → 120 (minus bloat) → ~17 GB. Final 15–25 GB range matches the expected answer range.
- Growth estimation formula is correct: `parquet_bytes_per_row × 50M / 1e9`. Bytes/row range (50–200) is in the expected ballpark (expected was 100–400).
- 12-month projection (~77 GB + 50% headroom = ~115 GB) is actionable.
- MinIO erasure coding correctly framed as ~1.5x overhead for EC:4+2, NOT naive 2x/3x replication. Verified against MinIO docs (6 total / 4 data = 1.5x).
- Snapshot accumulation trap with `expire_snapshots` + `remove_orphan_files` runnable SQL is a valuable inclusion grounded in the prod stack.

## Gaps or errors
- **TECHNICAL ERROR (compression default)**: The answer states "Iceberg's default codec is Snappy." This is incorrect for Iceberg 1.5.2 (the production version per prod_info.md). Iceberg switched the default Parquet write codec from Snappy to **Zstd** in version 1.4.0. The "Zstd gives 20–30% better than Snappy, switch to it" recommendation is therefore moot for any table created on the production stack — the engineer is already on Zstd unless they explicitly overrode. This is a factually wrong statement that would mislead an engineer running `SHOW CREATE TABLE` and being surprised. The expected criteria itself shows the same outdated assumption, but the responder still owns the factual accuracy of the claim.
- **Math inconsistency in MinIO sizing**: The answer says "EC:4+2 gives roughly 1.5x raw disk overhead" then concludes "for ~77 GB of data: budget ~115 GB of raw MinIO disk." 77 × 1.5 = 115.5 GB, which checks out — but this is double-counting the 50% headroom already applied at the previous step. The 77 GB projection already had 50% safety added; multiplying by 1.5x erasure overhead on top means the engineer effectively budgets 2.25x of the actual ~50 GB data estimate. Not technically wrong, just an unflagged compounding that an FP&A reviewer would catch.
- Estimated initial migration (15–25 GB) is more aggressive than the expected range (25–50 GB). The 7x average compression assumption is on the optimistic end for mixed-schema event data with high-cardinality columns (UUIDs, free-text). Defensible but not central.
- Beginner clarity: "dictionary encoding," "delta encoding," "erasure coding," "EC:4+2," "manifest," "rewrite_data_files," "overwritePartitions," "expire_snapshots" used without inline plain-English glosses. This is the persistent clarity gap flagged across this topic.
- Minor: `ALTER TABLE ... SET PROPERTIES write.parquet.compression-codec = 'zstd'` syntax — verify Trino accepts this exact property name; Iceberg's Spark property is `write.parquet.compression-codec` but Trino syntax sometimes differs. Worth a verification note.

### Dimension scores
- Technical accuracy: 4 (Snappy-default claim is wrong for Iceberg 1.5.2; otherwise solid)
- Beginner clarity: 4 (good prose, several unglossed terms)
- Practical applicability: 5 (runnable SQL, clear budget number, actionable maintenance schedule)
- Completeness: 4 (covers all main expected points; missing inline glosses and double-counting nit)
- **Average**: 4.25

## Verdict
Strong, well-structured answer that delivers a defensible MinIO budget with runnable diagnostics, but contains one factual error (Iceberg 1.5.2's default codec is Zstd, not Snappy) that should be corrected in `resources/11-lakehouse-storage-sizing.md` before the next iteration.
