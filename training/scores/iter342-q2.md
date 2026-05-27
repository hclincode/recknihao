# Score: Iter 342 Q2 — Postgres-to-Iceberg ingestion: MERGE INTO ON clause primary key requirement

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Core thesis (ON clause must uniquely identify a target row, i.e., the primary key) is correct and well-stated. Composite PK guidance is correct. Idempotency framing is correct. However, the "three failure modes" framing has technical inaccuracies: (1) "parse error" is the wrong term — Iceberg's check is a runtime cardinality violation, not a parse-time error; (2) "cross-join blowup" misdescribes the actual behavior — Iceberg detects the multi-match condition and raises a `MERGE_CARDINALITY_VIOLATION`/user error at execution time rather than fanning out rows. Only failure mode #3 ("silent over-update") is technically accurate, and it actually describes a different scenario (one source row → many target rows) than #1 and #2 (many source rows → one target row). The answer conflates the two directions of cardinality. |
| Beginner clarity | 4.5 | Strong beginner accessibility: opens with a one-line rule, explains "uniquely identifies a single row" in plain English, gives a concrete failure table for `updated_at`/`tenant_id`/`created_at`/`id`. No unexplained jargon. The "one rule" callout at the end is memorable. Minor: terms like "cross-join blowup" and "parse error" are thrown out without a glossary, but readers can mostly follow. |
| Practical applicability | 4.5 | Engineer leaves with: (1) the rule, (2) a runnable single-column MERGE template, (3) a runnable composite-key template, (4) a "what columns NOT to use and why" table, and (5) the idempotency rationale tying it back to the engineer's incremental-sync use case. Directly actionable. Could be even stronger with a pre-MERGE dedup snippet (`row_number() OVER (PARTITION BY id ORDER BY updated_at DESC)`) for cases where the source itself has dupes — common in incremental sync overlap windows. |
| Completeness | 4.0 | Hits the core question (why PK, what breaks if not). Covers composite keys and ties to idempotency. Missing: (1) what the **actual** Iceberg error message looks like (`MERGE_CARDINALITY_VIOLATION` / `Cannot perform Merge as multiple source rows matched...`) so the engineer can recognize it in logs, (2) the source-side dedup recipe for when overlap-window reads duplicate the PK, (3) note that the cardinality constraint is one-target-many-source (not the reverse), (4) mention that ON predicates that include the partition column also enable file pruning (perf benefit, not just correctness). |
| **Average** | **4.125** | **PASS** |

## What Worked

- The single-sentence rule at the top ("ON clause must use a column or column tuple that uniquely identifies a single row in the target table") is exactly the right framing for the question asked.
- The failure table (`updated_at` → multiple rows share timestamp; `tenant_id` → many rows per tenant) directly addresses the engineer's two examples in the question.
- Composite primary key example is correct Spark/Iceberg syntax and answers the natural follow-up.
- Idempotency tie-back to the incremental-sync use case is excellent — it explains *why* the rule matters for the engineer's actual job, not just abstractly.
- The "if you can't name what makes a row unique, you can't write a correct MERGE INTO" closing line is memorable and beginner-friendly.

## What Missed

- **Failure-mode #1 mislabeled as "parse error"**: Iceberg's cardinality check fires at *runtime/execution*, not at SQL parse time. The actual error is `MERGE_CARDINALITY_VIOLATION` (or in older Spark: `UnsupportedOperationException: Cannot perform Merge as multiple source rows matched and attempted to modify the same target row`). Calling it a "parse error" will confuse engineers who grep their logs for the wrong string.
- **Failure-mode #2 "cross-join blowup" is not how Iceberg actually behaves**: Iceberg explicitly detects the multi-source-to-one-target case and fails the query — it does not let the query proceed and produce a cartesian explosion. The "cross-join blowup" framing is more accurate for Delta Lake's older behavior or for hand-rolled UPDATE-from-join patterns, but not for Iceberg MERGE INTO with the cardinality check in place.
- **Conflation of two cardinality directions**: The Iceberg constraint is "one target row may match at most one source row." When one source row matches *many target rows* (e.g., source has one row with `tenant_id=42`, target has 10,000 rows with `tenant_id=42`), Iceberg does NOT throw — it updates all 10,000 target rows. That is exactly failure-mode #3 ("silent over-update"), and it is the real risk when ON clause is `tenant_id`. The answer's framing makes it sound like all three failure modes can happen for the same wrong ON clause; in reality, the direction of the cardinality violation determines which one fires.
- **Missing recognition pattern**: No mention of what the engineer will actually see in logs/Spark UI when this fails. Engineers debugging a real MERGE failure need the error string to grep for.
- **Missing source-side dedup recipe**: Incremental sync with an overlap window will often produce duplicate primary keys in the *source* DataFrame (the same row read twice across overlapping windows). Even with a correct PK ON clause, this triggers the cardinality violation. A `row_number() OVER (PARTITION BY pk ORDER BY updated_at DESC)` dedup before the MERGE is the standard fix and is a natural follow-on to this question.
- **No mention of partition-column-in-ON for file pruning**: A correctness-focused answer can skip this, but a fully complete answer would note that putting the partition column in the ON clause (in addition to the PK) lets Iceberg prune files and avoid a full-table scan.

## Technical Accuracy Verification

Verified against iceberg.apache.org/docs/latest/spark-writes/, Databricks MERGE INTO docs, and apache/iceberg GitHub issues:

1. **Confirmed**: MERGE INTO ON clause must produce at-most-one source row per target row. "By SQL semantics of Merge, when multiple source rows match on the same target row, the result may be ambiguous" — Spark/Delta and Iceberg both enforce this.
2. **Confirmed**: The error is a runtime cardinality violation (`Cannot perform Merge as multiple source rows matched...` / `MERGE_CARDINALITY_VIOLATION`), NOT a parse error and NOT a cross-join expansion. Answer's failure-mode #1 and #2 labels are inaccurate.
3. **Confirmed**: Composite-key ON clauses must include all PK columns. Answer's composite-key syntax (`ON t.tenant_id = s.tenant_id AND t.event_id = s.event_id`) is correct Spark/Iceberg syntax.
4. **Confirmed**: Idempotency of MERGE INTO with correct PK ON clause — re-running with overlapping data updates rows in place rather than duplicating. Answer's idempotency framing is correct.
5. **Confirmed**: Spark Iceberg MERGE INTO syntax shown (`MERGE INTO ... USING ... ON ... WHEN MATCHED THEN UPDATE SET * WHEN NOT MATCHED THEN INSERT *`) matches the Iceberg 1.5 docs exactly.
6. **Partially confirmed / partially inaccurate**: The "silent over-update" failure mode (one source row → many target rows) IS real behavior — Iceberg does update all matching target rows in this direction. This is exactly what would happen with `tenant_id` as the ON clause. So failure-mode #3 is correct, but the answer's framing makes it sound like the same wrong ON clause triggers all three modes simultaneously, which is not how Iceberg actually behaves.

Sources:
- [Apache Iceberg Spark Writes documentation](https://iceberg.apache.org/docs/latest/spark-writes/)
- [Iceberg 1.5 Spark Writes](https://iceberg.apache.org/docs/1.5.0/spark-writes/)
- [Databricks MERGE INTO](https://docs.databricks.com/aws/en/sql/language-manual/delta-merge-into)
- [Spark MERGE multiple source rows matched issue (delta-io/delta#218)](https://github.com/delta-io/delta/issues/218)
- [SQL with Manoj — Cannot perform Merge as multiple source rows matched](https://sqlwithmanoj.com/2021/06/18/spark-cannot-perform-merge-as-multiple-source-rows-matched/)
- [Cazpian — Writing Efficient MERGE INTO Queries on Iceberg with Spark](https://cazpian.ai/blog/writing-efficient-merge-into-queries-on-iceberg-with-spark)
- [IOMETE — Iceberg tables INSERT, MERGE, DELETE Operations](https://iomete.com/resources/reference/iceberg-tables/writes)
