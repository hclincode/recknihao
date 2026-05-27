# Iter 9 Q1 — Read replica vs structural fix: why analytics queries are fundamentally disruptive

## Question summary
Rails + Postgres app with analytics dashboards causing database lockups even when the intent is to route to a read replica. Two-part question: (1) is a read replica the right fix? (2) why are analytics queries fundamentally more disruptive than regular app queries?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core mechanics are correct: row-oriented scans, I/O saturation, CPU/RAM consumption during aggregation, and the structural mismatch. Minor gap: the answer says "disk I/O becomes saturated" and "replica has to do the same structural work" but doesn't fully explain *why a Postgres read replica still causes query degradation* — specifically that the replica is still row-oriented (reads entire rows), that heavy analytical queries can cause replication lag on the replica, and that Postgres's autovacuum conflict with active scans can amplify contention. The production stack migration path (Spark -> Iceberg -> Trino via Hive Metastore) is accurate and correctly grounded in prod_info.md. |
| Beginner clarity | 4 | Excellent opening query contrast (point lookup vs full-table aggregate) is the best teaching device in the answer. "Row-oriented, still reading entire rows even when it only needs one column" is a clean plain-English explanation. Weak spots: "Hive Metastore," "materialized views," "pg_partman," and "EXPLAIN ANALYZE" appear without inline glosses. The production stack terms (Spark, Iceberg, Trino, MinIO) are dropped without explanation for a reader who might be seeing them for the first time. "Disk I/O becomes saturated" and "holding everything in memory during aggregation" are clear enough without technical jargon. |
| Practical applicability | 5 | This answer delivers exactly what the engineer needs: a clear "yes, do this first (read replica), but here's why it's not enough," a 4-step migration path grounded in their exact on-prem stack (MinIO + Iceberg + Hive Metastore + Trino), and a concrete decision rule for when to proceed (>2 seconds after tuning + more than one ad-hoc user). The Postgres tuning checklist (read replica, materialized views, pg_partman, EXPLAIN ANALYZE) is actionable. The "you already have MinIO, Iceberg, and Trino" reframe is the right production-stack pivot — the engineer doesn't need to buy anything. |
| Completeness | 4 | Both halves of the question are answered. The "why analytics are disruptive" explanation covers I/O, CPU, and RAM correctly. The "why a read replica isn't enough" answer identifies the structural issue (row-oriented format). Gap: the answer does not explain that Postgres replicas can lag under analytical load because replication and heavy scan I/O compete for the same disk, and that this can cause the replica's lag to grow, potentially making it stale for reads. Also missing: the Postgres-level lock behavior (AccessShareLock held for the duration of a long analytical scan) that can block even DDL operations — the answer frames this as "disk I/O saturation" only, which is one factor but not the complete picture. The "why the replica still consumes the same resources" explanation is present but brief. |
| **Average** | **4.25** | |

## Topic updated

**Topic**: OLAP vs OLTP — difference and why it matters for SaaS

- Prior avg: 5.0 (1 question, Iter 1 Q1 — GROUP BY / COUNT slowdown as rows grow)
- New score: 4.25 (this question — read replica vs structural fix angle)
- New running avg: (5.0 + 4.25) / 2 = **4.625** across 2 questions
- Status: **PASSED** (avg 4.625 >= 3.5 threshold, 2 questions from different angles)

## Key finding

The answer correctly delivers the OLAP vs OLTP framing from `resources/01-olap-vs-oltp.md` and pivots cleanly to the production stack, but the core explanation of *why the replica still suffers* stays at the I/O-saturation level without naming the row-oriented format as the structural culprit clearly enough, and misses replication lag as a replica-specific failure mode.

## Resource gap

`resources/01-olap-vs-oltp.md` should add a "Why read replicas help but don't fully solve it" subsection under the Postgres tuning checklist that covers: (1) a Postgres replica is still row-oriented — every analytical query still reads full rows, consuming the same I/O and CPU as the primary would; (2) heavy analytical scans on a replica can cause replication lag to grow, making replica reads stale; (3) AccessShareLock held during long scans can block DDL on the replica. This would give the responder the precise mechanism to explain "structurally different" rather than relying on the I/O-saturation framing alone.
