# Iter 230 Q2 Score

**Score: 4.50 / 5.0**
**Pass: YES** (threshold is 4.5 in extended/final phase)

## What was correct

- **Core diagnosis nailed**: Trino MySQL connector does NOT push down predicates on textual (CHAR/VARCHAR) columns. This is the canonical, documented behavior and is the most likely root cause for the engineer's symptom. Verified at trino.io/docs/current/connector/mysql.html: "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR... to preserve correctness, the data source may compare strings case-insensitively." This matches the answer almost word-for-word.
- **Collation-correctness rationale correct**: MySQL defaults to case-insensitive collation; Trino's bytewise comparison would give different results — Trino prioritizes correctness over performance pushdown. Verified via trinodb/trino#6746 and PR #6753.
- **Dynamic filtering interaction with VARCHAR join keys correct**: A VARCHAR join key produces dynamic filters that the MySQL connector likewise will not push down for the same correctness reason. This is a real and frequently-missed gotcha.
- **EXPLAIN-based diagnostic approach correct**: Reading the TableScan node for a `constraint` field vs. seeing a `ScanFilterProject`/`Filter` node above it is the documented way to confirm pushdown. Verified at trino.io/docs/current/optimizer/pushdown.html: "If predicate pushdown for a specific clause is successful, the EXPLAIN plan does not include a ScanFilterProject operation."
- **EXPLAIN (TYPE DISTRIBUTED) syntax valid**: Correct Trino syntax.
- **MySQL slow query log diagnostic correct**: Inspecting the actual SQL Trino sent over JDBC on the MySQL side is the gold-standard confirmation step.
- **Workaround pattern is practical and sound**: Pairing a non-pushing predicate with a pushing predicate (date/numeric range) to limit the rowset MySQL returns is the standard, idiomatic fix.
- **domain-compaction-threshold / large IN-list compaction mention correct**: Default 256 (answer says >1000 — see below), compacted to BETWEEN min/max is real and documented.
- **EXPLAIN ANALYZE + physical_input_bytes guidance correct**: Standard federated-query diagnostic.

## What was wrong or missing

- **SQL syntax bug in the EXPLAIN example (lines 47–53)**: The example shows `FROM ... WHERE ... JOIN ...`, which is invalid SQL — JOIN must come before WHERE. This would not parse if a beginner pasted it. Minor but real correctness issue, and undermines the "exact commands" practicality.
- **domain-compaction-threshold default stated as ">1000" (line 95)**: Documentation says the default is **256**, not 1000. The mechanism described is correct but the threshold number is off.
- **Iceberg-side filter framing slightly off**: The answer says "Push the date filter down to Iceberg via partition pruning + file skipping" — true if `event_date` is the partition column or has min/max stats, but the answer never reminds the engineer to confirm Iceberg partitioning. A one-line check would have made the diagnosis tighter.
- **Missing: how to confirm dynamic filtering actually fired / didn't**: The JMX dynamic-filtering metrics table per catalog is the canonical observability surface and isn't mentioned. EXPLAIN ANALYZE VERBOSE also surfaces dynamic-filter wait time. Either reference would have strengthened the "how to figure out why" half of the question.
- **No mention of join-reorder / build-vs-probe side as a possible factor**: If the MySQL table is on the build side, dynamic filtering flows the other direction. A sentence on this would round out the diagnosis.
- **No mention of `query.dynamic-filtering-wait-timeout` / `dynamic-filtering.enabled` catalog properties** that an engineer might check or tune.
- **No production-environment fit note**: The repo's prod_info.md describes Trino 467 on-prem with JWT/OPA. None of this is specifically violated, but the answer could have noted the MySQL connector behavior is identical in 467.

## Verification notes

- **trino.io/docs/current/connector/mysql.html**: Confirmed "does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR" — applies to equality, range, IN, LIKE. Answer's table is accurate.
- **trino.io/docs/current/optimizer/pushdown.html**: Confirmed EXPLAIN-based detection method (ScanFilterProject vs. TableScan-with-constraint). Confirmed domain-compaction-threshold default of **256** (answer said ">1000").
- **trinodb/trino#6746 + PR #6753**: Confirmed the case-insensitive collation correctness rationale the answer cites.
- **trinodb/trino PR #13334**: Confirmed dynamic filtering implementation for JDBC connectors; 20s default wait timeout; JMX metrics surface for observability.
- **trinodb/trino#7413**: Historical issue — timestamp pushdown regression in earlier versions. Answer's claim that date/timestamp range pushes today is generally true but version-sensitive; for Trino 467 it works.
- **SQL syntax check**: `FROM ... WHERE ... JOIN ...` is invalid ANSI SQL. The example must read `FROM ... JOIN ... ON ... WHERE ...`.

## Recommendation for teacher

The MySQL-connector federation resource is in good shape — the core VARCHAR-no-pushdown story, EXPLAIN diagnostic, and pairing-workaround pattern are landing accurately and consistently. Two small fixes worth adding:

1. **LOW** — Fix the SQL syntax in any EXPLAIN example: `JOIN ... ON ...` must come before `WHERE`. Worth adding a "syntax-checked SQL examples" note to the teacher checklist since this is a recurring class of paste-and-fail bug.
2. **LOW** — Correct the `domain-compaction-threshold` default to **256** (not 1000) wherever it appears in resources.
3. **MEDIUM** — Add a short paragraph on observing dynamic-filtering effectiveness: (a) JMX dynamic-filter metrics table per catalog, (b) `EXPLAIN ANALYZE VERBOSE` shows dynamic-filter wait time and the actual filter values applied, (c) `dynamic-filtering.enabled` / `dynamic-filtering.wait-timeout` catalog properties. This would close the "how do I figure out why" half of questions like this one more completely.
4. **LOW** — One-line reminder for federated-diagnosis answers: confirm the Iceberg side's filter actually prunes (partition column or min/max stats) before blaming the MySQL side; sometimes the surprise is on the Iceberg side.
