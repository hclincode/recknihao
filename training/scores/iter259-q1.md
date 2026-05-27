# Iter259 Q1 Score

**Score: 4.9 / 5.0** — PASS (threshold: 4.5)

## What was correct
- Correctly states Top-N pushdown IS supported for the PostgreSQL connector (corrects the iter258 regression that wrongly denied this).
- EXPLAIN success signature is accurate: `sortOrder=[created_at DESC NULLS LAST]` and `limit=100` annotations INSIDE the `TableScan` node, NO separate `TopN` operator above. This matches the official Trino docs example (`sortOrder=[id:integer:int4 ASC NULLS LAST] limit=5`).
- EXPLAIN failure signature is accurate: separate `TopN[topN=100, orderBy=[...]]` operator above a bare `TableScan` — exactly what the docs say to look for.
- Session property name and catalog prefix requirement are correct: `SET SESSION postgres.topn_pushdown_enabled = false`. Verified against trino.io (`set session postgresql."topn_pushdown_enabled" = true` form).
- `system.query()` escape-hatch syntax is correct: `SELECT * FROM TABLE(postgres.system.query(query => '...'))` — matches docs verbatim.
- `pg_stat_activity` verification method is correct and called out as the "ground truth" — excellent practical guidance.
- "When pushdown may NOT fire" list is well-targeted: joins, aggregations above, function/expression sort keys, OFFSET, standalone ORDER BY without LIMIT. All correct.
- Keyset pagination recommendation for the OFFSET case is excellent practical advice.
- Quick debugging checklist gives the engineer a concrete sequence of actions.
- Correctly tells the engineer this is "on by default" — matches Trino 467 behavior.

## Gaps or errors
- MINOR: Could mention the known char/varchar correctness caveat (sorting on char/varchar columns can yield incorrect results in some versions due to collation differences) — this is a documented limitation but not in scope for the engineer's `created_at` timestamp column, so absence is not a substantive error.
- MINOR: The TopN-into-TableScan optimization can fail when there is a non-identity projection between them (Trino issue #25138). Not necessary for this answer but worth knowing as a possible "pushdown failed despite simple-looking query" cause.
- MINOR: The session property example uses `postgres.` as the catalog prefix; the engineer's actual catalog name may differ. The answer notes the prefix requirement but could explicitly say "replace `postgres` with your catalog name as configured in `etc/catalog/`."

## WebSearch verification notes
- Verified topN pushdown IS supported in the PostgreSQL connector: trino.io/docs/current/optimizer/pushdown.html and trino.io/docs/current/connector/postgresql.html.
- Verified the EXPLAIN signature: official example shows `sortOrder=[...] limit=N` embedded directly in the TableScan node, with no separate TopN operator above — matches the answer exactly.
- Verified the session property: `topn_pushdown_enabled` with catalog-name prefix is the correct form.
- Verified `system.query()` table-function syntax: `SELECT * FROM TABLE(<catalog>.system.query(query => '...'))` matches.
- Verified pushdown limitations: char/varchar collation caveat, non-identity projection blocking (Trino issues #25138, #7170), and joins/aggregations interfering — answer's "when it may not fire" list aligns with documented behavior.

This answer is a strong recovery from the iter258 failure and demonstrates the teacher's resource fix landed correctly.
