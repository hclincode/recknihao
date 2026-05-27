# Score: iter238-q2 — PostgreSQL WHERE Pushdown

**Score: 4.70 / 5.0**

## What was correct

- **VARCHAR equality (`status = 'active'`) pushes down**: Correct. Trino docs explicitly state "Equality predicates, such as `IN` or `=`, and inequality predicates, such as `!=` on columns with textual types are pushed down." The answer correctly explains PostgreSQL receives the WHERE clause and filters server-side.
- **Date BETWEEN (`created_at BETWEEN ...`) pushes down**: Correct. Temporal types (DATE/TIMESTAMP) support range pushdown in the PostgreSQL connector. The reformulated query shown to PostgreSQL is accurate.
- **LIKE with leading wildcard (`'%acme%'`) does NOT push down**: Correct. Pattern-matching with a leading wildcard is not pushed by default; it falls under the unsupported string range/pattern predicates category. The hedge that anchored patterns "may push down (behavior is collation-dependent)" is appropriate.
- **Net result explanation**: Accurate. Trino issues a query to PostgreSQL with the first two predicates and applies LIKE in worker memory post-fetch.
- **EXPLAIN verification guidance**: Correct. The doc-aligned rule is "TableScan alone = pushed; ScanFilterProject (or separate Filter node above TableScan) = not pushed." The answer states this correctly: "inside TableScan = pushed to database; above TableScan in a Filter node = applied in Trino memory."
- **MySQL contrast**: Correct. Trino's MySQL connector docs state "The connector does not support pushdown of any predicates on columns with textual types like `CHAR` or `VARCHAR`." This matches the answer's claim that MySQL excludes ALL VARCHAR predicates.
- **Practical applicability**: The selectivity reasoning (10M -> 200K rows reaches worker memory, then LIKE applied) gives the engineer concrete intuition about wire traffic.
- **Specific query syntax**: `EXPLAIN (TYPE DISTRIBUTED)` is valid and useful for this verification.

## What was wrong or missing

- **Minor imprecision on date range "unconditionally"**: Saying "numeric/date ranges are unconditionally pushed" is slightly overstated. Date pushdown is generally reliable, but "unconditionally" is a strong word — the answer would be more precise saying "by default for temporal types." Not material to the answer's correctness for this scenario.
- **LIKE anchored-pattern caveat could be sharper**: The phrase "Anchored patterns like `'foo%'` may push down (behavior is collation-dependent)" understates that by default in OSS Trino 467, LIKE pushdown to PostgreSQL requires the experimental `postgresql.experimental.enable-string-pushdown-with-collate` setting. The hedge ("may push down") covers this loosely, but a precise mention of the experimental flag would be more useful.
- **No mention of how to confirm via EXPLAIN ANALYZE VERBOSE**: The answer recommends EXPLAIN DISTRIBUTED, which is fine, but EXPLAIN ANALYZE VERBOSE would show actual rows read vs filtered, giving an even stronger verification signal. Minor omission.
- **No mention of the production environment fit**: The answer assumes a PostgreSQL catalog is configured (`app_pg.public.subscriptions`). Given prod_info.md says the production stack is Iceberg-only with no mentioned PostgreSQL catalog, the answer could briefly flag that this analysis assumes a PostgreSQL connector is configured. However, the question explicitly says "querying our PostgreSQL subscriptions table through Trino," so the assumption is reasonable.

## Verification notes

Checked against official Trino docs:
- **trino.io/docs/current/connector/postgresql.html**: Confirms VARCHAR equality/IN pushed; range predicates on CHAR/VARCHAR NOT pushed by default (experimental collation flag exists); temporal type predicates pushed.
- **trino.io/docs/current/connector/mysql.html**: Confirms MySQL connector does NOT push ANY predicates on CHAR/VARCHAR columns (including equality), due to collation/case-sensitivity correctness concerns.
- **trino.io/docs/current/optimizer/pushdown.html**: Confirms the EXPLAIN heuristic — successful pushdown shows TableScan alone; failed pushdown shows ScanFilterProject operator.

All three pushdown verdicts in the answer match official docs. The MySQL comparison is accurate. The EXPLAIN guidance is doc-aligned.

## Recommendation for teacher

Resources are now correctly aligned on PostgreSQL pushdown behavior (previous iteration's "VARCHAR does NOT push down on PostgreSQL" error has been fixed). Minor polish suggestions:

1. Document the `postgresql.experimental.enable-string-pushdown-with-collate` flag explicitly so the LIKE/anchored-pattern hedge can become precise rather than vague.
2. Add EXPLAIN ANALYZE VERBOSE (with "Rows: X, Input: Y rows" interpretation) as the gold-standard verification — complement to EXPLAIN DISTRIBUTED.
3. Consider tightening "unconditionally" wording for date ranges to "by default" to avoid overclaim.

No critical errors. The answer is publishable as-is for an application engineer.
