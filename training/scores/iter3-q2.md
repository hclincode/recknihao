# Iter 3 Q2 — Iceberg partitioning / small files

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "Iceberg partition design for SaaS: strategies, small-files, compaction"
- Questions asked so far for this topic: 0 -> 1
- New running avg: 4.75

## Key finding
The answer hits all three sub-questions cleanly: it recommends `(day(occurred_at), tenant_id)` for the 80-tenant case with the right math (~29,000 partitions/year), explains hidden partitioning via the Trino-rewrites-the-predicate contrast with Hive/Postgres, and walks through the small-files problem with concrete numbers (10-50ms per file open × 23,000 files = minutes of overhead). It also closes the loop with a full maintenance schedule (rewrite_data_files nightly, rewrite_manifests weekly, expire_snapshots nightly with 30-day retention, remove_orphan_files weekly) that maps directly to the prod stack (Iceberg 1.5.2 + Spark + Trino + MinIO). Mentioning `bucket()` as the alternative at the high-tenant-count scale shows the answer understood the resource's scaling guidance, not just the default case.

## Resource gap for next iteration
Beginner clarity is the only soft spot: the answer drops several terms (`manifest`, `rewrite_manifests`, `expire_snapshots`, `bucket()`, "target 256MB") in passing without a one-line plain-English gloss for each. The resource has a Key Terms table at the bottom of `10-lakehouse-partitioning.md`, but the responder isn't surfacing those definitions inline. Recommend the teacher add a short "if you only remember three sentences" block at the top of the maintenance section that names each procedure in plain English (e.g., "rewrite_manifests = compact the index that lists your files; expire_snapshots = actually delete the file versions you no longer need for time-travel"). This will help the weak responder echo the definitions when it cites the procedures.
