# Iter 13 Q2 — Spark JDBC Parallelism: lowerBound/upperBound Row Filtering Claim

## Question summary
An engineer asks how to parallelize a single-connection Spark JDBC read on an 80-million-row Postgres orders table. Specifically: what are the four JDBC parallelism options, and can wrong settings cause missed rows?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | The central factual claim — "lowerBound/upperBound do NOT filter rows, all rows always return; wrong bounds cause skew not data loss" — is verified correct by the official Spark documentation: "lowerBound and upperBound are just used to decide the partition stride, not for filtering the rows in table. So all rows in the table will be partitioned and returned." This directly and explicitly fixes the critical error from Iter 12 Q1, which stated that "Setting upperBound too low silently drops rows above the bound." The answer also correctly explains partition stride math and names all four parameters with their roles. |
| Beginner clarity | 4 | The plain-English "fold into whichever partition they map to" explanation is effective for a zero-OLAP-background engineer. The pre-flight max ID lookup is practical. Minus one point: "partition skew," "stride," and "JDBC connection" are used without inline one-line glosses; an engineer who does not know what a connection pool is may not grasp the "one connection per partition" warning's significance. |
| Practical applicability | 5 | The numPartitions=16 code example with a pre-flight MAX(id) lookup is immediately runnable. The connection-budget warning (numPartitions open connections simultaneously) is the most important operational callout and is present. The answer maps directly to the production stack (Spark JDBC reading from Postgres into Iceberg on the on-prem k8s cluster). |
| Completeness | 4 | Covers the core question (four parameters + no-rows-dropped guarantee) and the skew risk. Minus one point: the answer does not mention the `dbtable` subquery alternative (useful when `partitionColumn` is not a simple numeric column), and does not address the Postgres connection pool budget shared with Trino on the same on-prem k8s cluster (flagged as a gap in Iter 12 Q1 notes). |
| **Average** | **4.50** | |

## Topic updated

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior avg: 3.393 (7 questions through end of Iter 12, including all corrections)
- New score this question: 4.50
- Running avg note: (4.50 + 3.50 + 3.25 + 3.25 + 3.75 + 2.75 + 3.393×7_avg_placeholder) — merge agent should recompute as (sum of all raw question scores) / (total question count). This question adds 4.50 as the 8th scored entry. Approximate new running avg: (3.393 × 7 + 4.50) / 8 = (23.751 + 4.50) / 8 = 28.251 / 8 ≈ **3.531** across 8 questions.
- Status: **NEEDS WORK -> tracking toward PASSED** — the prior avg was 3.393 (below 3.50 threshold); with this question's 4.50 score the running avg rises to approximately 3.53, which is just above the 3.50 pass threshold. However this is the final phase and the margin is thin. The topic should be considered borderline.

## Key finding

The teacher's Iter 13 resource fix for the lowerBound/upperBound row-filtering bug (flagged in Iter 12 Q1) is working correctly. The weak-ai-responder now produces the technically accurate answer that the official Spark docs confirm: bounds determine partition stride only, all rows always return, and the real risk is skew not data loss. This is a direct reversal of the Iter 12 Q1 error where the answer stated that upperBound too low "silently drops rows."

## Resource gap

Two gaps remain but are minor relative to the corrected core:

1. The `dbtable` subquery alternative (`.option("dbtable", "(SELECT * FROM orders WHERE status = 'active') AS subq")`) is not mentioned — useful when the partition column must be pre-filtered or when the engineer wants to read a subset of columns for memory efficiency.
2. The Postgres connection pool budget shared between Spark ingestion and Trino query connections on the same on-prem k8s cluster is not surfaced. With numPartitions=16, the engineer is opening 16 simultaneous Postgres connections; if Trino query workers also hit Postgres (e.g., via a federated connector), this tightens the budget. A one-sentence callout in `resources/13-postgres-to-iceberg-ingestion.md` under the JDBC parallelism section would close this gap.
