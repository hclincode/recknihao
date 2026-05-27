# Iter262 Q1 Score

Score: 4.81

## Verdict
PASS (PASS = 4.5+)

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |
| **Average** | **4.81** |

## Strengths
- Correctly identifies FTE as a real Trino feature, correctly names `retry-policy=TASK` and `retry-policy=QUERY` as the two modes, correctly places them in `etc/config.properties` on the coordinator.
- Correctly states that an **exchange manager is required** for intermediate shuffle results to survive worker death. This matches the official docs (exchange manager is mandatory for TASK policy).
- The Postgres-snapshot-isolation risk is **the standout pedagogical content of this answer**. The reasoning is sound: on task retry, a brand-new JDBC connection is opened, which issues a fresh `SELECT` and therefore gets a fresh `READ COMMITTED` snapshot — any rows committed in between are now visible. This is exactly the subtle inconsistency window an engineer needs to know about before flipping the flag in production. Official docs do not surface this clearly; the answer adds real value.
- Correctly contrasts Iceberg's snapshot-at-plan-time consistency vs Postgres's per-task snapshot drift — engineer leaves with the right mental model of *which side of the join is risky*.
- Correctly states FTE **does NOT cover coordinator failure** — important and often missed.
- Production-stack fit is excellent: MinIO and PVC-based exchange spill are exactly the right two on-prem options for the described environment (no public cloud).
- Risk checklist before enabling is concrete and actionable (inconsistency tolerance, exchange manager infra, non-prod test, connection pool capacity).
- "Better alternative: materialize the Postgres dimension into Iceberg" is the right escape hatch and matches the federation-vs-ingest tradeoff the resource set teaches.
- "Enable FTE if / Avoid FTE if" decision section gives the engineer a clean go/no-go framework.

## Gaps / Errors
- **Minor accuracy gap on connector support framing.** The Trino PostgreSQL connector page explicitly states "Read and write operations are both supported with any retry policy." The answer's framing is broadly correct but does not explicitly reassure the engineer that the PostgreSQL connector is on the supported-connectors list. A reader who has seen the generic Trino warning ("This connector does not support query retries") might still worry. One sentence — "the Trino PostgreSQL connector is on the FTE-supported list, so you won't get a 'connector does not support query retries' error" — would close this.
- **Local-filesystem exchange caveat missing.** The answer mentions "filesystem-based exchange spill (using a Kubernetes PVC)" as an option, but the official docs flag local filesystem as **non-production only**. For an on-prem k8s setup the right production path is MinIO (S3-compatible) exchange manager; PVC-backed local filesystem on a single worker would be lost on pod eviction. The MinIO recommendation is correct; the PVC mention should have carried a caveat.
- **TASK vs QUERY trade-off underexplained.** The answer says `retry-policy=TASK or retry-policy=QUERY` but does not explain when to pick which (TASK = large batch, retry individual stages; QUERY = many small queries, retry whole query). For the engineer's 20-30 minute federated joins, TASK is the right pick — the answer implies this but does not say it outright.
- **Performance/latency overhead under-discussed.** FTE adds intermediate-result spooling to disk/object storage on every shuffle stage; this is a measurable per-query latency tax even when no failure happens. Worth one sentence in the downsides section.
- **No mention of `exchange.compression-enabled` or the storage footprint of spooled exchanges**, which can be significant for 20-30 minute queries scanning a lot of data — relevant to the "spare storage capacity" bullet in the checklist but not quantified.

## Technical accuracy notes
WebSearch verifications against trino.io official docs:
- `retry-policy=TASK` and `retry-policy=QUERY` confirmed as the two modes; TASK retries individual tasks, QUERY retries the whole query. Answer is correct.
- Exchange manager is **required for TASK policy**, optional for QUERY (QUERY limited to 32MB without one). Answer is correct on the requirement.
- PostgreSQL connector docs state: "The connector supports Fault-tolerant execution of query processing. Read and write operations are both supported with any retry policy." So FTE *does* work with Postgres — answer is correct that it works, and correct that there's a subtle consistency cost.
- FTE protects against worker failures, **not coordinator failures**. Answer correctly highlights this.
- Supported exchange manager backends include S3-compatible (MinIO qualifies), HDFS, Azure Blob, GCS, Alluxio, and local filesystem (non-production only). MinIO recommendation is correct for the prod stack; PVC mention should have carried the "non-production" caveat from the docs.
- The READ COMMITTED snapshot-on-retry inconsistency is not explicitly documented on trino.io, but is a correct inference from how the JDBC connector opens a fresh connection per task attempt; the PostgreSQL connector docs do flag non-transactional INSERT/MERGE caveats around partial-update risk, supporting the answer's general "consistency is not free" framing.

Overall this is a strong PASS — the Postgres-snapshot-drift insight is genuinely valuable and not commonly covered, and the production-stack fit (MinIO, k8s, on-prem) is appropriate. Minor docking on omissions rather than errors.
