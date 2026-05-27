# Score: iter254 Q1
Score: 4.85
Pass/Fail: PASS (>=4.5)

## What was correct
- **Pushdown vs no-pushdown framing**: The opening "two paths" section is crisp and exactly what a SaaS engineer needs — "1 row over the network vs 1 million rows" makes the stakes immediately clear. Beginner-friendly.
- **Equality / IN / IS NULL on VARCHAR pushes down**: Confirmed against trino.io/docs/current/connector/postgresql.html ("Equality predicates, such as IN or =, and inequality predicates, such as != on columns with textual types are pushed down").
- **Equality on numeric/date pushes down**: Correct.
- **Non-anchored LIKE (`'%foo%'`, `'%foo'`) does NOT push**: Correct — these patterns cannot use a B-tree index and Trino does not push them.
- **ILIKE does NOT push**: Correct.
- **Range predicates on VARCHAR do NOT push by default**: Correct per official docs ("does not support pushdown of range predicates, such as >, <, or BETWEEN, on columns with character string types").
- **`enable_string_pushdown_with_collate` experimental session property**: Correctly identified as the toggle to enable range pushdown on VARCHAR; correctly notes it is experimental and does not affect LIKE/ILIKE. Verified against trinodb/trino PR #9746.
- **EXPLAIN (TYPE DISTRIBUTED) verification rule**: The "predicate inside TableScan constraint = pushed; separate Filter/ScanFilterProject node above TableScan = not pushed" rule matches the official optimizer/pushdown docs ("If predicate pushdown for a specific clause is successful, the EXPLAIN plan for the query does not include a ScanFilterProject operation").
- **EXPLAIN ANALYZE Input: rows count** as a runtime verification — correct and very actionable.
- **pg_stat_activity check on the replica** with example SQL — correct ground-truth method.
- **Postgres slow log enable/disable workflow** — extra credit; correct and includes the cleanup step.
- **`system.query()` table function escape hatch** — correctly recommended for predicates that won't push; syntax is correct (TABLE(...), nested single quotes via doubling).
- **Two-step filtering pattern** (selective pushed predicate + in-memory LIKE) — practical and correct.
- **Production fit**: The advice is environment-neutral (works on the on-prem Trino 467 + Postgres setup). pg_stat_activity / slow log advice fits the on-prem operator-accessible model.

## What was missing or wrong
- **Anchored LIKE (`'foo%'`) "MAYBE" framing is slightly soft**: The official Postgres connector docs do not explicitly document LIKE pushdown behavior, but Trino's JDBC LIKE pushdown (PR #11045) implements LIKE pushdown including anchored patterns, subject to collation. The answer's "MAYBE — verify with EXPLAIN" is defensibly correct (collation-dependent) and the recommendation to verify is the right operational advice. Could be slightly more direct: "anchored LIKE typically pushes for default collation columns; non-default collations may block it."
- **Domain compaction threshold not mentioned**: A small omission — when a customer has a very long IN list, the `domain_compaction_threshold` default (256) silently converts the IN list to a range, which CAN reduce pushdown selectivity. Not core to the question, but a SaaS engineer hitting "my IN (10000 ids) is slow" hits this. Minor completeness gap.
- **Could mention `JOIN PUSHDOWN`**: For a question about federation joins, a brief note that join pushdown is a separate setting (`join-pushdown.enabled`) and that it interacts with predicate pushdown would round out the picture. Slightly out of scope for this specific question, so not a real deduction.

## Overall assessment
This is a strong, well-structured answer that gives the SaaS engineer exactly what they need: a clear mental model, four concrete verification methods ordered by ease/safety, correct LIKE-pattern rules with the right collation caveat, and three actionable workarounds when pushdown fails. Technical accuracy is high — verified against trino.io official docs for the PostgreSQL connector and pushdown optimizer pages. The minor "MAYBE" hedge on anchored LIKE is operationally correct given collation variability; could be made slightly more direct but is not wrong. Pushes the federation topic average in the right direction.
