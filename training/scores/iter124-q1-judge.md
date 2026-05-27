# Iter124 Q1 — Judge Score

**Score**: 4.5 / 5 (Tech 4, Clarity 5, Practical 5, Completeness 4)

## Verdict
Strong, well-structured answer that maps a Postgres user's `pg_stat_activity` / `pg_stat_statements` mental model onto Trino with concrete, runnable SQL. Column names on `system.runtime.queries` are exact and the `query.max-history` / `query.min-expire-age` defaults are correct against current docs. The main accuracy issue is the claim that Trino ships a built-in "file event listener" — current Trino (v467) ships HTTP, Kafka, MySQL, and OpenLineage built-ins, not a file listener. Two minor gaps: no mention that `user` is a reserved word and typically needs quoting, and no mention of `CALL system.runtime.kill_query()` as the immediate-relief lever once a culprit is identified.

## What was verified correct (via WebSearch)
- `system.runtime.queries` columns: `query_id`, `state`, `user`, `source`, `query`, `resource_group_id` (array(varchar)), `queued_time_ms`, `analysis_time_ms`, `planning_time_ms`, `created`, `started`, `last_heartbeat`, `end`, `error_type`, `error_code` — all match Trino docs exactly. The answer's note that the timestamp column is `end` (not `end_time`) is correct.
- `physical_input_bytes` and `split_cpu_time_ms` are real columns on `system.runtime.tasks` (confirmed across multiple prior iterations and matches naming convention in Trino source).
- `system.runtime.*` being ephemeral / in-memory / wiped on coordinator restart: confirmed by trino.io docs (described as "currently and recently running queries", dynamic transient views).
- `query.max-history` default = 100 and `query.min-expire-age` default = 15m: CONFIRMED exact match against trino.io/docs/current/admin/properties-query-management.html.
- `EXPLAIN ANALYZE` actually executes the query at full cost (confirmed against trino.io/docs/current/sql/explain-analyze.html). The answer's warning to use `EXPLAIN (TYPE DISTRIBUTED)` for a plan-only check is correct.
- HTTP and Kafka event listeners exist as built-in Trino plugins (confirmed).
- Note: `analysis_time_ms` is technically a historical misnomer — planning time is in `planning_time_ms`. The answer correctly lists both columns.

## Errors or gaps
- **MEDIUM**: The answer lists a "File event listener (`event-listener.name=file`)" as a built-in plugin. Current Trino built-in event listeners are HTTP, Kafka, MySQL, and OpenLineage — there is no built-in file event listener. The HTTP listener is closest to "log to a file" but writes nothing locally on its own. This claim will mislead an engineer trying to find the config docs.
- **LOW**: `user` is a Trino reserved word; the SQL `SELECT ... user, ...` will work in many positions but quoting as `"user"` is safer and more idiomatic. Not called out.
- **LOW**: The answer doesn't mention `CALL system.runtime.kill_query(query_id => '...', message => '...')` as the immediate action once you find a bad query. Prior judge notes (see rubric line 2017) flagged this as the "immediate-relief lever" that engineers expect alongside diagnosis.
- **LOW**: No mention that the `system.runtime.queries` table itself is a cross-tenant disclosure surface (full SQL text including WHERE-clause literals visible to anyone with `system` catalog access). Not strictly the question asked, but a B2B SaaS engineer should be flagged once.
- **LOW**: The `total_gb_per_period` calculation `COUNT(*) * AVG(input_gb)` is mathematically equivalent to `SUM(input_gb)` and is less clear — `SUM(t_agg.input_gb)` would be both simpler and more correct.

## Resource fix recommendations
- Correct the event listener section in `resources/` to list the actual current built-ins: **HTTP, Kafka, MySQL, OpenLineage**. Drop the "file event listener" reference, or clarify that file-based logging requires either the HTTP listener pointing at a local sink or a custom plugin.
- Add a one-line `CALL system.runtime.kill_query()` example to any "find the slow query" resource as the immediate triage action.
- Add a note that `user` is a reserved keyword and should be quoted in `SELECT` lists.
- Optionally tighten the "high-frequency culprit" SQL to use `SUM()` instead of `COUNT(*) * AVG()`.

## Topic state
**Topic**: Query performance regression diagnosis: oncall workflow for slow queries — concurrency, partition skew, data model, file layout (currently PASSED, avg 5.0, 2 questions).

This answer keeps the topic passing. Score 4.5 still well above the 3.5 threshold. The event listener inventory error is the only thing preventing a 5.0 and should be corrected in resources before the next related question, but does not change topic pass status.
