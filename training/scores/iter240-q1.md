# Score: iter240-q1 — MySQL vs PostgreSQL Connector Differences

**Score: 4.8 / 5.0**

## What was correct

1. **Split = unit of parallelism framing** — Correct conceptual model. A split is a unit of work distributable across workers; Iceberg yields one split per file (and gets cluster-wide parallelism), JDBC connectors yield one split per non-partitioned table. The contrast with Iceberg (80 splits = 80 parallel readers) is the right mental model and is well-tuned to the prod stack (MinIO + Iceberg + Trino 467).

2. **MySQL = 1 split per table, no partition-column splitting in OSS Trino 467** — Verified via WebSearch. Trino issue #389 ("Parallel read in JDBC-based connectors") has been open since 2019 and remains unimplemented in OSS Trino. The answer's claim that you cannot add Spark-JDBC-style `partitionColumn` / `lowerBound` / `upperBound` / `numPartitions` to a Trino MySQL catalog file is accurate — those properties do not exist in the OSS MySQL connector.

3. **PostgreSQL is identically 1 split per non-partitioned table** — Correct and important. The answer correctly says PostgreSQL has the same single-split limitation, so the user's surprise should not be "PostgreSQL is fast, MySQL is slow" on scan parallelism alone — both are 1 split. The actual differentiator is pushdown.

4. **MySQL refuses VARCHAR predicate pushdown (=, IN, IS NULL, LIKE)** — Verified against trino.io/docs/current/connector/mysql.html which states: "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR. This ensures correctness of results since the data source may compare strings case-insensitively." This is the conservative-correctness rationale the answer gives, and it is the documented behavior.

5. **PostgreSQL DOES push VARCHAR equality and IN-list** — Verified. trino.io/docs/current/connector/postgresql.html and PR #6753 confirm equality predicates (=, IN, !=) on textual types are pushed for PostgreSQL. The answer's PostgreSQL behavior column in the summary table is accurate.

6. **Numeric and date predicates DO push to MySQL** — Verified. The MySQL connector pushes numeric (=, >=, <=) and date/timestamp predicates; only textual-column predicates are blocked. The answer correctly identifies `event_id >= 1000000` and `created_at > DATE '...'` as pushdown-friendly.

7. **Mixed-predicate workaround (pair VARCHAR filter with a date/numeric filter)** — Excellent practical advice grounded in how Trino's pushdown actually works. The narrative that the date filter ships only May-20-onward rows over JDBC and Trino then does the VARCHAR filter on the smaller result set is technically accurate and gives the engineer something concrete to try.

8. **Dynamic filtering + VARCHAR join keys** — Verified. VARCHAR-based dynamic filter IN-lists also fail to push to MySQL (same blanket VARCHAR rule). The suggested fixes (numeric surrogate key, or move dimension to PostgreSQL) are correct and actionable.

9. **MySQL collation rationale** — Accurate. MySQL's default collations (utf8mb4_0900_ai_ci) are case- and accent-insensitive, while Trino's string comparison is bytewise. PR #6753 fixed prior incorrect-results bugs exactly because of this asymmetry. The "silent bugs" framing is correct.

10. **Use MySQL for dimensions only / replicate large tables to Iceberg** — Correct fit with prod stack (Spark + Iceberg 1.5.2 + MinIO + Trino 467). The "keep MySQL tables under ~5M rows" rule of thumb is a reasonable heuristic, though it's not in official Trino docs.

## What was wrong or missing

1. **Minor: PostgreSQL `IS NULL` on VARCHAR pushdown** — The summary table claims `IS NULL` on text columns pushes to PostgreSQL with a checkmark. This is generally true (PostgreSQL pushes `IS NULL`/`IS NOT NULL` for text columns, since it doesn't depend on collation), but the answer doesn't cite the asymmetry. Not wrong, just under-supported.

2. **Minor: `LIKE` pushdown to PostgreSQL is not the same as `=` pushdown** — The answer's summary table doesn't address `LIKE`. PostgreSQL pushes `LIKE` with the `enable-string-pushdown-with-collate` workaround or with certain pattern forms; it is not as blanket as equality pushdown. The answer simplifies this away, which is acceptable for a beginner but slightly incomplete.

3. **Minor: Aggregate-pushdown distinction not surfaced** — Section 2A.2 of the source resource notes that aggregate pushdown (COUNT/SUM/AVG/GROUP BY) and predicate pushdown are evaluated independently — one can succeed while the other fails. The answer doesn't mention that a `SELECT COUNT(*) WHERE status='active'` against MySQL would still push the COUNT aggregate to MySQL even though the VARCHAR predicate doesn't. This is a useful nuance for performance reasoning that was omitted.

4. **Minor: "1 split" might appear differently in the UI** — The Trino UI also reports splits per stage; the answer could clarify that the 1-split figure shows up at the source-stage TableScan node specifically. Engineers looking at the UI may see multiple splits in other stages (exchange, aggregation) and get confused.

## Verification notes

- **Claim 1 (MySQL 1 split, no parallel reads)**: VERIFIED via Trino issue #389 (parallel JDBC reads open since 2019), and the official MySQL connector docs which document no `partitionColumn` / parallel-read properties. The Spark-JDBC-style properties are NOT supported in OSS Trino.
- **Claim 2 (MySQL no VARCHAR pushdown)**: VERIFIED via [trino.io/docs/current/connector/mysql.html](https://trino.io/docs/current/connector/mysql.html). Direct quote: "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR. This ensures correctness of results since the data source may compare strings case-insensitively."
- **Claim 3 (PostgreSQL DOES push VARCHAR equality / IN-list)**: VERIFIED via [trino.io/docs/current/connector/postgresql.html](https://trino.io/docs/current/connector/postgresql.html) and PR #6753. Equality (=, !=, IN) on textual columns is pushed.
- **Claim 4 (MySQL pushes numeric and date)**: VERIFIED. MySQL connector pushes predicates on numeric and temporal types; only the textual-type blocker applies.
- **Claim 5 (Dynamic filtering + VARCHAR join keys to MySQL)**: VERIFIED. Same blanket VARCHAR rule applies to dynamic-filter IN-lists; they will not push to MySQL.

## Recommendation for teacher

The answer is at or near a 5.0. The resource (`22-trino-federation-postgresql.md`, Section 2A.2) is clearly well-developed and the answer pulls from it cleanly. Two small enhancements would push the next answer over the top:

1. **Add an aggregate-pushdown vs predicate-pushdown side-note to the MySQL summary table** in Section 2A.2 — make it explicit that `SELECT COUNT(*) WHERE status='active'` would still push COUNT to MySQL even though the WHERE doesn't push. This nuance is in the resource (line 1569) but didn't make it into the answer.

2. **Add a one-line "where in the Trino UI you see 1 split"** clarification — the engineer specifically said "in the Trino UI it says something like 1 split" so a teacher note about the source-stage TableScan node would help future answers be more diagnostic.

Topic status: Trino federation is now at 4.428 average across 154 questions and is the only NEEDS WORK item left at threshold 4.5. A 4.8 here continues the recovery trend (iter239 Q1 was 4.9). Keep iterating on this topic — small consistent gains will push the rolling average over the 4.5 threshold.
