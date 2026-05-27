# Iter 299 Q2 Judge Score

## Topic
Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 5.00 |

## Pass/Fail
PASS (threshold: 4.5)

## Technical accuracy verification

1. **EXPLAIN ANALYZE runs the query** — VERIFIED. Trino docs confirm EXPLAIN ANALYZE actually executes the query to gather runtime statistics, similar to Postgres. Answer correctly warns user about this.
2. **EXPLAIN (TYPE DISTRIBUTED) does not run the query** — VERIFIED. Docs confirm it "creates a distributed plan in text format" without execution. Correctly recommended as safe alternative.
3. **ANALYZE syntax has no TABLE keyword** — VERIFIED. Trino docs show `ANALYZE table_name [ WITH (...) ]`. The answer's "CRITICAL syntax warning" is correct: `ANALYZE TABLE x` is Spark/Hive syntax and fails in Trino.
4. **`partitions = ARRAY[...]` is Hive-only, not valid for Iceberg** — VERIFIED. The Iceberg connector docs only document the `columns` property for ANALYZE; the `partitions` property is Hive-connector-only and throws "analyze property 'partitions' does not exist" on Iceberg.
5. **`join_reordering_strategy = 'AUTOMATIC'`** — VERIFIED. Three valid values (NONE, ELIMINATE_CROSS_JOINS, AUTOMATIC) match Trino optimizer docs exactly. Fallback to ELIMINATE_CROSS_JOINS when stats unavailable is correctly described.
6. **Puffin files store NDV stats** — VERIFIED. Trino Iceberg connector writes NDV statistics to Iceberg Puffin file format.
7. **Iceberg auto-collects min/max but NOT NDV** — VERIFIED. Min/max per file is collected on every write (manifest stats for file skipping); NDV requires explicit ANALYZE.
8. **SHOW STATS FOR returns `distinct_values_count`** — VERIFIED. Correct column name in Trino's SHOW STATS output.
9. **`rows: ?` indicates missing stats** — VERIFIED. Standard Trino EXPLAIN output convention.

All major technical claims are verified against trino.io official docs (480/481 current). No factual errors detected.

## What worked

- Directly addressed the Postgres analogy with clear distinction: EXPLAIN ANALYZE runs the query in both, but offers a safer alternative for plan-only inspection.
- The "CRITICAL syntax warning" about `ANALYZE TABLE` vs `ANALYZE` (no TABLE keyword) is exactly the kind of trap that bites users coming from Spark/Hive. Calling it out explicitly is high-value.
- Three-table concrete example with realistic row counts (500M events x 50K accounts x 365 days) shows *why* join order matters — not just *that* it matters.
- The three-layer optimization table at the end perfectly separates partition pruning vs file skipping vs CBO. Critical for engineers who confuse "more stats = faster reads" — the answer correctly notes ANALYZE only improves Layer 3.
- Diagnostic checklist (7 steps) gives an actionable, ordered workflow.
- Mentions Puffin file location in MinIO (production-relevant).
- k8s CronJob suggestion fits production stack exactly.
- Notes stats don't auto-update — the operational gotcha that causes weekly regressions in production.
- Correctly shows `SHOW STATS` verification step — closes the loop on whether ANALYZE actually populated what was needed.
- Names the actual Iceberg-only property (`columns`) and the Hive-only failure mode (`partitions = ARRAY[...]`) — prevents the user from copying a Hive example.

## What was wrong or missing

Essentially nothing of substance. Possible micro-nits (not score-affecting):
- Could have explicitly named the Puffin blob type (Theta sketch) for completeness, but this is internal-implementation detail not needed for engineer-level diagnosis.
- Could mention `EXPLAIN (TYPE DISTRIBUTED, FORMAT JSON)` for tooling integration, but the text form is the right default for human reading.

No errors of substance. Answer is essentially production-ready as written.

## Suggested topic score update
Old: 4.763 / 4 questions
New avg if this scores 5.00: (4.763 * 4 + 5.00) / 5 = (19.052 + 5.00) / 5 = **4.810 across 5 questions**
Status: PASSED (well above 4.5 raised threshold).
