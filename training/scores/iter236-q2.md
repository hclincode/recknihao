# Score: iter236-q2 — Cross-Catalog INSERT into MySQL

**Score: 4.70 / 5.0**

## What was correct

- **Cross-catalog INSERT syntax**: The `INSERT INTO mysql_catalog.db.table SELECT ... FROM iceberg_catalog... JOIN mysql_catalog...` form is correct standard Trino SQL. No "special" cross-catalog INSERT syntax is needed — Trino treats fully-qualified catalog.schema.table names uniformly.
- **Execution model**: Correctly explained that the cross-catalog JOIN runs on Trino workers — Iceberg side reads files from MinIO, MySQL side reads via JDBC, join happens in Trino memory, write goes back to MySQL.
- **Transactional default**: Correct that the MySQL connector defaults to a temporary-table-and-rename wrapper for INSERTs, providing atomic semantics.
- **`insert.non-transactional-insert.enabled` property name**: Verified against trino.io docs — this is the correct catalog property name. The corresponding session property `non_transactional_insert` is also correct (verified: "It can also be controlled using non_transactional_insert session property").
- **Non-transactional risk warning**: Correct that partial failures leave rows committed with no rollback. Matches the official Trino warning: "With this property enabled, data can be corrupted in rare cases where exceptions occur during the insert operation. With transactions disabled, no rollback can be performed."
- **Single JDBC connection on read side**: Correct — the Trino MySQL connector reads via a single JDBC connection, has no partition-column/parallel-read configuration equivalent to Spark's `partitionColumn`/`lowerBound`/`upperBound`. Verified via Trino GitHub issue #389 and Starburst's "JDBC bottleneck" blog: "JDBC-based tables in these connectors use a single connection which could be slow."
- **CTAS targeting MySQL**: Trino CTAS works against the MySQL connector — same transactional wrapper applies.
- **MySQL MERGE flag**: Correctly identified that MySQL MERGE requires `merge.non-transactional-merge.enabled=true` (catalog) or `non_transactional_merge_enabled` (session). Verified: both property names and the "non-transactional" caveat are accurate per Trino docs.
- **Trino vs Spark decision framework**: Solid practical guidance on row-count threshold (under a few million), idempotency consideration, lack of resume-from-failure in Trino vs Spark Structured Streaming checkpointing.
- **Middle-ground pattern**: The "materialize in Iceberg, then MERGE to MySQL once a day" suggestion is a good production pattern that separates analytical compute from operational write.
- **Production fit**: Answer works within the on-prem Trino 467 + Iceberg/MinIO/HMS stack from `prod_info.md`. No fabricated cloud-only features.

## What was wrong or missing

- **Session property syntax inconsistency**: The answer uses `SET SESSION <catalog>.non_transactional_insert = true;` for INSERT (correct form), but for MERGE shows `SET SESSION mysql_catalog.non_transactional_merge_enabled = true;`. Both names are confirmed correct per Trino docs, but the answer never highlights the inconsistency that the INSERT session property is `non_transactional_insert` (no `_enabled` suffix) while the MERGE session property is `non_transactional_merge_enabled` (with `_enabled` suffix). The answer does call out the MERGE name explicitly at the end, but readers could be confused that the INSERT property doesn't follow the same pattern. Minor.
- **Bulk-INSERT write side**: The answer says "the INSERT itself is a single operation sent to MySQL" — slightly imprecise. With the default temp-table wrapper, the connector writes batched INSERTs to the temp table from Trino workers (can use multiple connections for writes via the `write.batch-size` and write parallelism on the connector); the "single operation" framing undersells write throughput slightly. Not a meaningful error in production but technically a small oversimplification.
- **No mention of MySQL connector write batch tuning**: For a bulk operation like the one described, properties like `write.batch-size` (or session equivalents) materially affect write throughput. A complete answer would mention this lever. Missing.
- **CTAS atomicity claim**: "Same transactional-by-default behavior as INSERT" is essentially correct for MySQL CTAS, but CTAS creates a new table — if the query fails mid-way, the partially-created table may be left behind on some connectors. The answer doesn't address what happens to the new table on failure. Minor completeness gap.
- **MERGE example uses ellipses** (`...`) in several places — slightly unhelpful for a beginner who would want to copy/paste. Style nit.

## Verification notes

Checked against trino.io official docs and GitHub issues:

1. **Cross-catalog INSERT supported**: Confirmed — standard SQL, no special syntax needed. Trino supports `INSERT INTO catalogA.schema.table SELECT ... FROM catalogB.schema.table JOIN catalogA.schema.other_table` natively. The optimizer pushes per-catalog filters down where possible; join executes on Trino workers.
2. **Temp-table-and-rename for MySQL INSERT**: Confirmed — Trino MySQL connector "writing data to a temporary table" is the documented default behavior to provide transactional semantics on a non-transactional sink.
3. **`insert.non-transactional-insert.enabled` and `non_transactional_insert`**: Both confirmed exact in trino.io docs (verified for current and 444/475/476/480 versions; applies to 467 by extension since the property was stable across this range).
4. **CTAS to MySQL**: Standard CTAS works against the MySQL connector. Confirmed.
5. **MySQL MERGE**: `merge.non-transactional-merge.enabled=true` catalog property and `non_transactional_merge_enabled` session property both verified per trino.io docs. The "non-transactional" caveat with possible partial updates is the official Trino warning. MySQL MERGE support landed via PR #24428.
6. **Spark JDBC parallel reads vs Trino**: Confirmed — Trino MySQL connector does NOT have an equivalent to Spark's `partitionColumn`/`lowerBound`/`upperBound` for parallel JDBC reads. Verified via Trino GitHub issue #389 and Starburst blog. The Spark comparison in the answer is accurate.

## Recommendation for teacher

The cross-catalog INSERT/MERGE coverage is strong. Two minor improvements would tighten the resource further:

1. **MEDIUM (completeness)**: Add a short callout to the MySQL/Postgres connector resource about the session-property naming asymmetry: `non_transactional_insert` for INSERT vs `non_transactional_merge_enabled` for MERGE — and the catalog-property equivalents `insert.non-transactional-insert.enabled` vs `merge.non-transactional-merge.enabled`. This naming inconsistency is a documented source of typos and would help responders cite both correctly without ambiguity.
2. **LOW (completeness)**: Add a sentence about MySQL connector write tuning levers (`write.batch-size`, and the `non-transactional-insert` tradeoff for bulk loads) so that future answers about large INSERT/CTAS operations can reference throughput tuning beyond just the transactional/non-transactional flag.
3. **LOW (correctness)**: Add a one-line note about CTAS partial-failure semantics on JDBC sinks — what happens to the target table if the query fails mid-stream (partial table created? cleaned up?). Currently underspecified in the resource.

Topic average lift expected: this is a strong cross-catalog write answer that should help nudge the federation topic average upward from 4.422.
