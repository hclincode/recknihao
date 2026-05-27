# Score — Iter 295 Q2

**Question topic**: Iceberg partition design for a multi-tenant SaaS events table (2B rows, 800 tenants, 5M users). Choosing between `day(occurred_at)`, identity `tenant_id`, `bucket(user_id, 16)`, and whether multiple partition columns are valid.

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core advice (use `day(occurred_at), tenant_id`) is correct and well-justified. Hidden partitioning, bucket transform semantics, partition pruning, and the metadata-only COUNT explanation are accurate. **Defect**: claims "Trino doesn't expose `CALL iceberg.system.*` procedures" and tells the engineer to run compaction "via Spark (NOT Trino)". Trino 467's Iceberg connector supports `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '...')` natively, which is the standard Trino path for compaction on this stack. The Spark `CALL` works too, but the framing misleads. Partition-count math (365 × 800 = 292,000) is correct; calling Iceberg's comfort zone "100k–1M partitions per table" is on the high end — most guidance suggests problems start well before 1M, but the claim that 292k is workable is reasonable. The "one tenant 80% of events → switch to bucket(tenant_id, 64)" threshold is heuristic but defensible. |
| Beginner clarity | 5 | Excellent jargon handling. "Partition pruning", "hidden partitioning", "bucket transform" are all defined with concrete examples. Plain-language framing ("rounds timestamps down to calendar days", "hashes user_id into one of 16 fixed buckets") is exactly right for a SaaS engineer with no OLAP background. Final summary table reinforces the takeaways. |
| Practical applicability | 4 | Provides a copy-paste-ready `CREATE TABLE` with the recommended partitioning, an example compaction call, and a decision rule for when to switch to bucketed tenant_id. Fits Trino 467 + Iceberg 1.5.2 + MinIO + Spark stack. **Half-deduction**: the "use Spark not Trino" guidance for compaction is the opposite of what a Trino-first user should do day-to-day — most teams on this stack should reach for `ALTER TABLE ... EXECUTE optimize` first because they already have Trino sessions open. Could also have mentioned `expire_snapshots` / `remove_orphan_files` to round out maintenance. |
| Completeness | 5 | Covers all four parts of the question: (1) which column to partition by, (2) can you use multiple, (3) what `bucket(user_id, 16)` and `day(occurred_at)` mean, (4) which is right for multi-tenant SaaS. Adds valuable nuance on partition-count limits, write-skew triggers for switching to bucketing, and the small-files / compaction follow-up. Mentions Bloom filters as the right answer for user-level lookups in the summary table. |

## Verification notes

- **Verified via WebSearch (trino.io, iceberg.apache.org)**:
  - `ALTER TABLE foo EXECUTE optimize(file_size_threshold => '100MB')` is the documented Trino path for Iceberg compaction. Trino 481 docs and the Starburst "file explosion" blog both confirm. The answer's claim that Trino lacks this is wrong.
  - Bucket transform semantics (hash + mod N, 0..N-1, even distribution, prunes only on equality predicates on the bucketed column) are confirmed.
  - Identity partition + manifest-stored partition values enabling metadata-only aggregates is supported by Trino's Iceberg internals blog and AWS prescriptive guidance.
  - Hidden partitioning (write normal SQL, Iceberg applies transform automatically) is confirmed by Iceberg/Trino docs and the Datalakehousehub masterclass post.
- **Production stack fit (prod_info.md)**: Trino 467 + Iceberg 1.5.2 + MinIO + Spark for ingestion + dbt. The recommended partitioning works on this stack. The Spark-only compaction framing is unnecessarily restrictive — Trino on this stack absolutely supports `EXECUTE optimize`. Otherwise everything (CREATE TABLE syntax, partition transforms, file sizes) is correct for Iceberg 1.5.2 on MinIO.

## Topic mapping

- **Iceberg partition design for SaaS: strategies, small-files, compaction** — primary topic. Currently PASSED at 4.589 / 15 questions. This answer scores 4.50.
- **Multi-tenant analytics: isolating customer data in SaaS** — secondary (tenant_id as partition column for tenant isolation/pruning).
- **Query performance basics: partitioning, indexing strategy for analytics** — secondary (partition pruning explanation, Bloom filter mention).
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — secondary (the compaction section, with the noted defect about Trino vs Spark).

## Verdict

**Average: (4 + 5 + 4 + 5) / 4 = 4.50 — PASS**

Strong, well-organized answer with one factual error: it incorrectly tells the engineer that Trino cannot run Iceberg compaction and must use Spark. On a Trino 467 + Iceberg connector stack this is wrong — `ALTER TABLE ... EXECUTE optimize` is the canonical Trino path. The error affects practical applicability (engineer might spin up unnecessary Spark jobs) but does not derail the core partitioning guidance, which is excellent.

### Suggested teacher fix
Update the compaction resource (and any partition-design resource that mentions compaction) to lead with `ALTER TABLE <iceberg_catalog>.<schema>.<table> EXECUTE optimize(file_size_threshold => '256MB')` as the Trino-native option, and present the Spark `CALL iceberg.system.rewrite_data_files(...)` as an alternative for batch maintenance windows — not as the only option.
