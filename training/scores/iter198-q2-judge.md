# Iter 198 Q2 Judge — Iceberg Snapshot Expiry + Federation

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings

**Correct claims (verified):**
- "Iceberg does NOT automatically protect in-flight queries from snapshot expiry" is correct. Iceberg's serializable snapshot isolation guarantees that a reader sees a consistent committed snapshot, BUT the *physical files* underlying that snapshot can be physically deleted by `expire_snapshots` if the reader started before the GC executed. Apache Iceberg docs and community guidance explicitly recommend retention intervals that exceed expected operation duration precisely because in-flight readers are not file-locked. The answer's framing is accurate.
- `rewrite_data_files`/compaction is correctly described as safe to run concurrently with readers: it creates a new snapshot containing rewritten files; readers on the prior snapshot keep reading the original files until expiry removes them. Verified against Iceberg's MVCC/optimistic-concurrency model.
- `expire_snapshots` and `remove_orphan_files` are correctly flagged as the dangerous ones (file deletion).
- Trino's `iceberg.expire-snapshots.min-retention` default of 7 days is correct (verified at trino.io/docs/current/connector/iceberg.html). The note that `retention_threshold` must be >= this value or the procedure fails is consistent with Trino docs.
- The Postgres side being protected by Postgres MVCC (long-running query won't see federated rows disappear under it) is correct.
- The Trino-level failure semantics (if Iceberg leg fails, whole federated query fails) is correct.
- Using `ALTER TABLE ... EXECUTE optimize` for Trino-native compaction is correct syntax for Trino 467; `CALL iceberg.system.expire_snapshots(...)` syntax is correct for Spark (the answer doesn't explicitly engine-label this, see minor gap below).

**Minor issues / nitpicks:**
- The CALL `iceberg.system.expire_snapshots(...)` example is Spark SQL syntax and is not explicitly labeled as such. Trino 467 exposes expire via `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`. Given the production stack uses both Spark (ingestion/maintenance) and Trino (queries), the reader should be told which engine. This is a recurring pattern flagged in the rubric notes — still slightly persistent here.
- "deletes the manifest metadata first, then issues S3 DELETE calls" is a reasonable description of the practical effect but glosses over the exact ordering (commits new metadata.json pointing to fewer snapshots, then GC walks unreferenced manifests/data files). Not wrong, but oversimplified.
- "Retain_last => 5" with 7-day older_than is fine but a brief note that `retain_last` overrides older_than (keeps the N most recent regardless) would help a beginner.
- Production environment fit: the answer correctly references MinIO/S3 protocol and stays within the on-prem k8s + Trino 467 + Iceberg + Hive Metastore stack. Good fit.

**Completeness:**
- Covers compaction safety: YES
- Covers expire_snapshots risk: YES
- Covers retention thresholds + Trino min-retention floor: YES
- Covers federation-specific impact: YES (explicit Postgres/MVCC discussion)
- Covers practical scheduling guidance + retry suggestion: YES

**Beginner clarity:**
- "Snapshot isolation" is used without an inline gloss for an OLAP novice. A one-line "snapshot isolation = each query gets a frozen view of the table at the moment it started" would lift this to 5.
- "MVCC" appears once without explanation.
- Otherwise the tone, table, and code blocks are accessible. The compaction-vs-expiry contrast is well-drawn.

## Resource fix suggestions

1. `resources/17-iceberg-table-maintenance.md` (or wherever expire_snapshots is documented): add a side-by-side syntax block showing **Trino 467** (`ALTER TABLE catalog.schema.tbl EXECUTE expire_snapshots(retention_threshold => '7d')`) vs **Spark** (`CALL iceberg.system.expire_snapshots(...)`), since the responder keeps defaulting to Spark CALL syntax without labeling it. This is a multi-iteration persistent pattern visible in rubric notes.
2. Add a short glossary blurb (one sentence each) to define "snapshot isolation" and "MVCC" so the responder can drop them inline when answering. Beginner clarity slips a notch on every answer that uses these terms bare.
3. Consider a runbook-style resource: "Iceberg maintenance scheduling with active Trino queries" that codifies the safe/unsafe matrix the responder produced. Promoting it from inline table to a top-level resource would let the responder lift it verbatim in future iterations.

Sources verified:
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg Maintenance](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg Spec — snapshot isolation](https://iceberg.apache.org/spec/)
- [Apache Iceberg Reliability — concurrent commits](https://iceberg.apache.org/docs/latest/reliability/)
- [Trino issue #19096 — Iceberg Expire Snapshots](https://github.com/trinodb/trino/issues/19096)
