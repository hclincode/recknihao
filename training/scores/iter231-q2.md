# Iter 231 Q2 Score

**Score: 4.75 / 5.0**
**Pass: YES** (threshold is 4.5 in extended/final phase)

## What was correct

- **Web UI first step**: `http://trino-coordinator:8080/ui/queries` is the right fastest visual check and a beginner-friendly entry point before diving into SQL. Good progressive structure.
- **`system.runtime.queries` exists and the listed columns are real**: `query_id`, `user`, `source`, `query`, `state`, `created`, `started` are all documented columns. Filter by `state = 'RUNNING'` is the standard idiom.
- **`"user"` double-quoting note is technically correct and a real gotcha**: `user` is a reserved keyword in Trino (it resolves to the `CURRENT_USER` builtin function when unquoted), so it must be double-quoted to refer to the column. The explanatory framing ("silently returns the session user … a subtle bug that looks like data corruption") is the kind of practical detail a SaaS engineer needs.
- **`system.runtime.tasks` join pattern is valid**: `physical_input_bytes` and `split_cpu_time_ms` are real columns on `system.runtime.tasks` (added in Release 330 per the PR #2803 in trinodb/trino). The join key `q.query_id = t.query_id` is correct.
- **`CALL system.runtime.kill_query(query_id => '...', message => '...')`**: signature is exactly correct per trino.io/docs/current/connector/system.html, including the named-argument form.
- **Retention properties `query.max-history` (default 100) and `query.min-expire-age` (default 15 minutes)**: both names and defaults are correct per trino.io/docs/current/admin/properties-query-management.html.
- **Limitations section is honest and useful**: calls out (a) ephemeral nature of system.runtime, (b) no connector-level breakdown in system tables — you must infer from SQL text and byte patterns, (c) EXPLAIN ANALYZE limitation. Recommending an event listener for durable historical analysis is the right architectural pointer.
- **MySQL inference approach via `LIKE '%billing_mysql%'` plus the false-positive caveat** is honest and practical given the limitation that system tables don't expose connector-level routing.

## What was wrong or missing

- **No mention of `resource_group_id` column**: prior iterations confirmed this is a real and useful column on `system.runtime.queries` — relevant for a multi-tenant shared cluster context (the question explicitly says "shared Trino cluster used by several teams"). Including it in the SELECT would help the engineer immediately see which team's resource group is responsible.
- **`elapsed_time` / `queued_time` columns not used**: the answer reinvents elapsed time via `date_diff('minute', started, current_timestamp)` rather than using the built-in `elapsed_time` (interval) column on `system.runtime.queries`. Minor stylistic miss.
- **Production-stack fit (prod_info.md) not explicitly tied in**: the question mentions MySQL replica, but prod_info.md lists Iceberg as the primary catalog with no MySQL connector mentioned. The answer assumes the MySQL connector is wired up. Not a hard error (engineer asked about it), but a quick "verify your MySQL catalog name in `etc/catalog/*.properties`" would have helped.
- **No mention of dynamic filter / predicate pushdown angle on MySQL**: a MySQL-hammering query usually has missing predicate pushdown — the actual remedy after identification is often "add `WHERE` clauses that push down" or "ingest into Iceberg instead of federating live." A one-line bridge to that next-step would lift completeness.
- **Group-by columns include `q.query`**: in the Top-Level View example, grouping by the entire `query` text (potentially very long) is correct but worth a comment — substringing in the SELECT but grouping by the full column works, just verbose.

## Verification notes

Verified against official Trino documentation via WebSearch:
- `system.runtime.queries`: CONFIRMED real table on the system connector; documented columns include `query_id`, `user`, `source`, `query`, `state`, timestamps, `planning_time_ms`, `resource_group_id`. (https://trino.io/docs/current/connector/system.html)
- `system.runtime.tasks` with `physical_input_bytes`: CONFIRMED — added in Release 330 (PR trinodb/trino#2803). (https://trino.io/docs/current/release/release-330.html)
- `split_cpu_time_ms`: CONFIRMED via prior iteration verification and Trino source; column is part of task statistics exposed in system.runtime.tasks.
- `"user"` double-quoting requirement: CONFIRMED — `user` is reserved in Trino's grammar (resolves to CURRENT_USER builtin), must be quoted to refer to a column. (https://trino.io/docs/current/language/reserved.html)
- `CALL system.runtime.kill_query(query_id => '...', message => '...')`: CONFIRMED exact signature with named arguments. (https://trino.io/docs/current/connector/system.html)
- `query.max-history` = 100 and `query.min-expire-age` = 15min: CONFIRMED defaults. (https://trino.io/docs/current/admin/properties-query-management.html)

## Recommendation for teacher

Minor enhancements, not blocking. Future Trino federation diagnostics resources should:
1. Add `resource_group_id` to the canonical "list active queries" SELECT template — this is the single most useful column in shared/multi-tenant clusters.
2. Include `elapsed_time` (interval type) as the idiomatic Trino way to show query duration rather than always reaching for `date_diff()`.
3. Add a brief "after you identify the bad query" section pointing to predicate pushdown / federation-vs-ingest trade-off — that's the actual next step a SaaS engineer needs after finding the culprit. Federation topic is currently NEEDS WORK in the rubric (4.443) and tying identification to remediation strengthens it.
4. Keep the `"user"` double-quoting callout — it's a high-signal practical detail that this answer handled well.

Topic update: Trino federation / cross-source connectors — this answer is a solid contribution toward closing the gap on federation diagnostics. Recommend continuing the federation series with one more question on predicate pushdown verification (`EXPLAIN ANALYZE` output and pushdown indicators) to reach the 4.5 threshold.
