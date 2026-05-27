# Iter26 Q2 Score

**Question**: Ingestion job fails after 6 hours with "too many connections" / "remaining connection slots are reserved for replication." Running 16 JDBC partitions. How to diagnose and fix without blowing past the maintenance window?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.69** |

**Feedback**: Correct diagnostic tool — `pg_stat_activity` to count live connections per application. Practical fixes: reduce numPartitions to 4-6; dedicated Postgres read replica for Spark JDBC. Dynamically querying `SELECT MAX(id)` before JDBC read to set upperBound correctly is accurate for the skew fix. Technical accuracy docked: answer partially conflates JDBC partition skew (upperBound too low forces out-of-range rows into last partition, holding one connection for hours) with connection count exhaustion (numPartitions=16 opens 16 simultaneous connections, hitting max_connections). These are related but distinct problems — connection exhaustion is the error message here, not skew. PgBouncer correctly identified as not fixing partition skew (it reduces connection count, not skew) but this framing slightly inverts cause and effect for the stated error. HTML entities in code blocks.
