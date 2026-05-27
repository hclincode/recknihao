# Iter 12 Q1 — Spark JDBC parallel reads and Postgres connection risks

## Question summary
The engineer is running a single-connection Spark JDBC job against Postgres that takes 45 minutes. They want to know how to parallelize the read using the partitionColumn/lowerBound/upperBound/numPartitions settings, and what can go wrong if they enable them.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Core mechanic (partition stride across numPartitions tasks, pick a numeric column) is correct. The connection-count warning and uneven-distribution warning are both real. However, item 5 in the "What can go wrong" list is factually wrong: "Setting upperBound too low → silently drops rows above the bound." Per official Spark documentation (spark.apache.org), lowerBound and upperBound are only used to compute the partition stride; they do NOT filter rows. All rows are returned regardless of bounds. Rows beyond upperBound are folded into the last partition. An engineer who reads this will believe they have a data-loss risk they don't have, and may chase a phantom bug. The practical error from wrong bounds is performance skew (two partitions doing all the work), not data loss. This is a clear factual inversion of documented behavior. |
| Beginner clarity | 4 | Good overall clarity for a beginner. Opens with the single-connection default as context, explains partition stride naturally ("divide that column's range into 16 chunks"), and lists risks in plain English. The pre-flight MAX(id) code is a practical, beginner-safe touch. Minor issue: the answer opens by naming "three settings" but then lists four option names (partitionColumn, lowerBound, upperBound, numPartitions), which creates a small contradiction that a beginner will notice. No jargon is left unexplained. |
| Practical applicability | 4 | Starting with numPartitions=8 and running a pre-flight MAX(id) query are directly actionable. The connection math (numPartitions connections open simultaneously) is the most important operational warning and it is surfaced clearly. The fact that the critical "wrong" warning (item 5, data loss) is actually wrong deducts from applicability — an engineer may waste time debugging a non-existent problem. The answer does not address the production-specific concern of running this against Postgres during peak hours being compounded by k8s executor pod count (which determines how many of those 16 connections actually run in parallel at once). |
| Completeness | 4 | Addresses the mechanism and the main failure modes. The question asks two things: "how does it work?" and "what can I mess up?" Both are answered. Missing: (1) that lowerBound/upperBound have no effect on what rows are returned — only on partition sizing, which changes the "what can I mess up" answer materially (skew, not data loss); (2) the option to use a custom WHERE-clause subquery as dbtable instead of the partition parameters, which is useful for non-numeric columns or complex filtering; (3) the production-stack-specific callout that in the on-prem k8s setup the Postgres connection budget is shared with the Trino query engine, so the actual safe headroom for JDBC parallelism is lower than Postgres max_connections alone suggests. |
| **Average** | **3.75** | |

## Topic updated

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior avg: 3.625 (4 questions)
- New score this question: 3.75
- New running avg: (4.50 + 3.50 + 3.25 + 3.25 + 3.75) / 5 = **3.65**
- Status: PASSED (avg 3.65 >= 3.5 threshold)

## Key finding

The answer contains a factually inverted claim about a core JDBC option: it states that setting `upperBound` too low will silently drop rows above the bound. This is wrong. Per the official Spark documentation, lowerBound and upperBound are only used to compute the partition stride and do not filter any rows — all rows are returned, with out-of-bounds rows folded into the first or last partition. The actual risk of wrong bounds is performance skew (unbalanced partitions), not data loss. An engineer who follows this advice will look for a data-loss bug that cannot exist.

## Resource gap

`resources/13-postgres-to-iceberg-ingestion.md` already contains the JDBC parallelism snippet at line 150 (partitionColumn / lowerBound / upperBound / numPartitions) with a correct description ("parallelize the JDBC read") but does not explicitly address what wrong bounds actually do. Add a callout beneath the JDBC parallelism code block stating:

- lowerBound and upperBound define partition stride only — they do NOT filter rows. Rows with id < lowerBound go into partition 1; rows with id > upperBound go into the last partition. No rows are dropped.
- The real risk of wrong bounds is performance skew: if you set upperBound=1_000_000 but most IDs are above 900_000, nearly all rows land in partition 16 and parallelism provides no benefit.
- Best practice: set lowerBound to MIN(id) and upperBound to MAX(id) from a pre-flight query, not a fixed hardcoded value.
- Connection count: numPartitions concurrent connections open against Postgres simultaneously. On the on-prem k8s stack, this budget is shared with Trino query connections — keep numPartitions <= 8 unless you have confirmed headroom in Postgres max_connections.
