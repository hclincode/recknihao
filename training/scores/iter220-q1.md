# Iter 220 Q1 Judge Score

## Score: 4.85

## Topic: Trino federation cross-source connectors

## What the answer got right
- **VARCHAR pushdown correctly stated as NOT supported**: matches official Trino MySQL connector docs verbatim — "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR." Equality, LIKE, IN, and range on VARCHAR all correctly listed as non-pushing.
- **DATE/timestamp range pushdown correctly stated as supported**: `>=`, `<=`, `=`, `<>`, `BETWEEN` on DATE/TIMESTAMP correctly listed as pushing. Matches the documented MySQL connector behavior (non-textual types push down).
- **Numeric pushdown correctly listed**: integer/float/decimal predicates pushed down.
- **No `experimental.enable-string-pushdown-with-collate` flag for MySQL**: correctly states this is PostgreSQL-only. This directly fixes the iter219 Q1 regression that hallucinated such a flag for MySQL.
- **EXPLAIN plan reading guidance is accurate**: "constraint under TableScan = pushed; Filter/ScanFilterProject above = not pushed" matches how Trino's distributed plan exposes connector constraints versus residual filters.
- **EXPLAIN ANALYZE guidance is accurate**: pointing at the `Input:` and `Filtered:` fields on the TableScan is the right runtime confirmation method.
- **Workaround pattern is correct and immediately actionable**: pairing a pushing date predicate with a non-pushing VARCHAR predicate so MySQL ships fewer rows for Trino to filter — this is the standard mitigation for the MySQL connector's textual-pushdown limitation.
- **Production-fit recommendation**: the closing pivot to "consider ingesting into Iceberg — VARCHAR equality benefits from Parquet column statistics for file pruning" fits the on-prem Iceberg+Trino+MinIO stack in `prod_info.md`.
- **Clear summary table** maps each predicate in the engineer's query directly to behavior — concrete and zero-jargon.
- **Concrete data-shipping example** (10M invoices → 50K paid → 9.95M wasted rows over JDBC) makes the cost of non-pushdown visceral for a beginner.

## What the answer missed or got wrong
- **Minor — IS NULL / IS NOT NULL on VARCHAR**: The answer's table groups IS NULL/IS NOT NULL as pushing without qualifying that on VARCHAR columns the textual-pushdown ban applies broadly. The Trino doc statement is "any predicates on columns with textual types," which is ambiguous but commonly interpreted to include NULL checks on VARCHAR. Not a load-bearing error but worth a footnote.
- **Minor — case-sensitivity rationale not mentioned**: The official docs explicitly state the reason VARCHAR pushdown is disabled is to guarantee correctness because the data source may compare strings case-insensitively. Mentioning this would have helped the engineer understand it's a correctness-not-perf decision and not something to wait for a fix on.
- **Minor — `domain_compaction_threshold` not mentioned**: For large IN-list pushdown (numeric/date), the connector's 256-entry default compaction can convert IN lists into range predicates. Out of scope for this specific query but adjacent.
- **Minor — does not mention `EXPLAIN (TYPE IO)` or `EXPLAIN (TYPE VALIDATE)`**: `EXPLAIN (TYPE IO)` can show the connector-level table layout/constraint, which is sometimes clearer than DISTRIBUTED. DISTRIBUTED is fine and standard, just not the only option.
- **Minor — no mention of join/limit/aggregate pushdown**: not asked about, but adjacent to the broader "what does push down" question; the engineer might benefit knowing aggregate pushdown works (and could help if they ever rewrite the query as `SELECT count(*) WHERE invoice_date >= ... AND status = 'paid'`).

None of the above is a factual error; they are nuance gaps.

## WebSearch verification notes
Verified against `https://trino.io/docs/current/connector/mysql.html`:
- CONFIRMED: "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR." → answer is correct on VARCHAR equality/LIKE/IN/range.
- CONFIRMED: No `mysql.experimental.enable-string-pushdown-with-collate` property exists in the MySQL connector. The collate-based string pushdown flag is PostgreSQL-only.
- CONFIRMED: Non-textual predicates (numeric, DATE, TIMESTAMP) push down by default; documentation does not exclude them.
- CONFIRMED: Join, limit, top-N, and aggregate pushdowns are supported (answer does not mention these but does not need to for the asked question).
- CONFIRMED: The case-insensitive comparison correctness concern is the documented rationale for the textual-pushdown ban.

## Recommendation for teacher
The MySQL connector resource fix shipped between iter219 and iter220 worked — the responder produced an accurate, production-fit answer that directly closes the iter219 Q1 regression. Suggested small additions to `resources/22-trino-federation-postgresql.md` (or its MySQL companion):
1. Add a one-line "why" for the VARCHAR-pushdown ban: "MySQL collations may make string comparisons case-insensitive; Trino disables pushdown to guarantee correctness." This converts a surprising rule into a memorable one.
2. Add IS NULL / IS NOT NULL behavior on VARCHAR columns explicitly to the pushdown table — engineers will ask.
3. Add `EXPLAIN (TYPE IO)` as a second verification option alongside `EXPLAIN (TYPE DISTRIBUTED)`.
4. Brief mention that aggregate pushdown still works on MySQL even when the WHERE clause has VARCHAR predicates that don't push — this changes the cost calculus for `SELECT COUNT(*) WHERE status = 'paid'` queries.

Score breakdown (1.0–5.0 in 0.05 increments):
- Technical accuracy: 4.95 (all load-bearing facts verified correct; minor nuance gaps only)
- Beginner clarity: 4.80 (great concrete numbers and table; "ScanFilterProject" and "JDBC" used without inline gloss)
- Practical applicability: 4.95 (engineer can run EXPLAIN today, apply the workaround today, and has a clear escalation path to Iceberg)
- Completeness: 4.70 (covers all three sub-questions; misses case-sensitivity rationale, IS NULL behavior, EXPLAIN TYPE IO alternative)

Average: (4.95 + 4.80 + 4.95 + 4.70) / 4 = **4.85**
