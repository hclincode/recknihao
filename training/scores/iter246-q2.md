# Iter246 Q2 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths
- Correctly identifies the core architectural truth: OSS Trino's PostgreSQL connector emits a single split per non-partitioned table scan, so only one worker reads. Verified against trino.io/docs/current/connector/postgresql.html — no partition-column/numPartitions properties exist in the documented catalog properties list.
- Correctly states that `partition-column`/`numPartitions` are Spark JDBC parameters and do NOT exist in OSS Trino. Verified: those properties are absent from the official Trino PostgreSQL connector docs.
- Correctly cites trinodb/trino#389 as the open feature request (verified: opened March 2019, still open with "enhancement" and "roadmap" labels).
- Correctly frames Starburst Enterprise as the commercial fork with parallel JDBC capability (the Greenplum SEGMENTS-style parallelism is a Starburst-specific pattern; OSS Trino does not have it).
- Numerical reasoning is honest and useful: "50M rows at ~100K rows/sec ≈ 500s" gives the engineer a sanity check that they are JDBC-bound, not Trino-bound. This reframes the problem from "config bug" to "architectural ceiling," which is exactly the right diagnosis.
- Dynamic filtering recommendation is technically correct: small dimension on build side, large fact on probe side. Verified against trino.io dynamic filtering docs — smaller table belongs on build side, and DF pushes the IN-list to the probe side scan. Direction is right (this was the iter244 fix area; iter246 maintains it correctly).
- Solution ranking is well-prioritized for the prod environment: snapshot to Iceberg on MinIO first (fits the on-prem stack), then DF join trick, then Postgres-side pre-aggregation, then "only use Postgres for small dimensions." All four are actionable.
- PgBouncer + `prepareThreshold=0` and transaction-pooling note is accurate and a real-world pattern.
- Correctly states OSS Trino 467 has no native JDBC connection pooling for the PG connector — adding pool properties to the catalog file is a no-op. This avoids a common foot-gun.
- "Use a read replica, not the application primary" and statement_timeout advice are sound operational guardrails.

## Gaps / Errors
- 100K rows/sec is presented as "typical for JDBC" without caveat. Real JDBC throughput depends heavily on row width, fetchsize, network, and column types; for a wide row it could be 10-30K rows/sec, for narrow rows 200K+. A one-line "varies by row width, set fetchsize" caveat would strengthen the claim.
- `fetchsize` JDBC tuning is not mentioned as a quick partial win. Even though the single-split limit is the dominant ceiling, raising fetchsize from the default 1000 to 10000+ can materially help — worth one line.
- Beginner clarity: terms "split," "build side," "probe side," "dynamic filtering," and "domain compaction" are used without a one-line gloss. A SaaS engineer with no OLAP background may need "split = a chunk of work a single worker reads sequentially" up front. Costs 0.5-1 point on beginner clarity.
- Minor: "1 split = 1 JDBC connection = 1 worker thread" is the right mental model, but Trino may open a few extra connections for metadata lookups before the scan. Not load-bearing for the answer.
- The "snapshot Postgres into Iceberg" recommendation does not mention CDC vs. full refresh trade-offs or scheduling cadence specifics — but the question did not require that depth, so this is a completeness nit, not a gap.
