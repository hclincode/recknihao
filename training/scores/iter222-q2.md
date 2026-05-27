# Iter 222 Q2 Judge Score

## Score: 4.70

## Topic: Trino federation cross-source connectors (monitoring & circuit breakers)

## What the answer got right

1. **`system.runtime.queries` schema** — Correctly identifies `query_id`, `"user"` (with mandatory double quotes because `user` is reserved), `source`, `query`, `state`, and `started` as valid columns. Verified against Trino docs: these are real columns, plus `created`, `last_heartbeat`, `end`, `error_type`, `error_code`, `resource_group_id`, `queued_time_ms`, `analysis_time_ms`, `planning_time_ms`.

2. **`source` field semantics** — Correctly explains that `source` is populated by the JDBC `?source=` URL parameter or `X-Trino-Source` HTTP header, and crucially calls out the silent-failure mode in resource group selectors when clients fail to set it. This matches prior iter18/19 rubric notes.

3. **HTTP event listener configuration** — All property names verified correct against trino.io/docs/current/admin/event-listeners-http.html:
   - `event-listener.name=http`
   - `http-event-listener.connect-ingest-uri=...`
   - `http-event-listener.log-completed=true` (defaults to false)
   - `http-event-listener.log-created=false` (defaults to false)
   - Registration via `event-listener.config-files` in `etc/config.properties` is correct.

4. **`CALL system.runtime.kill_query(query_id => '...')`** — Correct named-parameter syntax. Optional `message =>` parameter exists but is not required.

5. **OSS Trino 467 has no native JDBC connection pool** — Verified correct: the OSS Trino MySQL/PostgreSQL connector docs do NOT list `connection-pool.*` properties. Connection pooling is a Starburst Enterprise feature, not OSS. The answer correctly establishes this as the rationale for the four-layer defense-in-depth.

6. **PgBouncer `SHOW POOLS` / `SHOW CLIENTS`** — Verified valid PgBouncer admin commands. `cl_waiting` is the relevant column for detecting pool starvation (the answer uses "waiting_clients" colloquially which is close enough but not the exact column name — see below).

7. **PostgreSQL `statement_timeout` units** — Verified: PostgreSQL's `statement_timeout` defaults to milliseconds when no unit is specified, so `300000` = 5 minutes is correct. `ALTER ROLE <user> SET statement_timeout = '<ms>'` is the right per-role syntax.

8. **MySQL `SHOW FULL PROCESSLIST` + `INFORMATION_SCHEMA.PROCESSLIST`** — Both are valid; the connection-count threshold query is a sensible alerting pattern.

9. **PostgreSQL `pg_stat_activity`** — Columns listed (`pid`, `query_start`, `state`, `query`, `wait_event`, `wait_event_type`, `usename`) are all real and correctly used.

10. **Resource group selector `source` field** — Verified: `source` is a documented selector field (alongside `user`, `userGroup`, `queryType`, `clientTags`, etc.) and is matched as a Java regex. The example `".*federation.*"` regex is syntactically valid.

11. **Resource group properties** — `hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued` are correct property names.

12. **Diagnostic narrative on predicate pushdown failure** — The connection between "physical_input_bytes near full table size" and "predicate pushdown failed" is the correct operational signal, and the recommendation to verify with `EXPLAIN (TYPE DISTRIBUTED)` is appropriate.

13. **Defense-in-depth layering** — PgBouncer pool size → Postgres role CONNECTION LIMIT → Trino resource groups → DB statement_timeout is the right architectural framing for a no-pool OSS Trino deployment.

## What the answer missed or got wrong

1. **Trino UI path `/ui/queries`** — Minor inaccuracy. The canonical Trino web UI root is `/ui/` (which is itself the queries landing page). There is no `/ui/queries` route in OSS Trino — the main page at `/ui/` lists active queries. The preview UI is at `/ui/preview`. This is a small but verifiable error; an engineer copy-pasting this URL would land on a 404 or the same page anyway, but the path is technically not what's documented.

2. **PgBouncer column naming** — The answer uses "waiting_clients" as the alert metric. The actual `SHOW POOLS` column is `cl_waiting` (and `SHOW CLIENTS` shows clients in `state = 'waiting'`). Not wrong as a conceptual metric, but a literal alert query would need the real column names.

3. **`system.runtime.tasks` columns** — Could not independently verify `physical_input_bytes` and `split_cpu_time_ms` as exact column names in the official docs (the System connector page does not enumerate task columns). Trino's task stats do expose physical input bytes (verified in QueryCompletedEvent / OperatorStats), so the concept is right, but the exact column names on `system.runtime.tasks` are not documented in the public docs page. Prior rubric note from iter29 Q4 warned that some users confuse `system.runtime.queries` vs `tasks` columns — the answer should ideally suggest `DESCRIBE system.runtime.tasks` to verify against the running cluster. Mild gap.

4. **Optional `message` parameter for `kill_query`** — Not mentioned. The full signature is `CALL system.runtime.kill_query(query_id => '...', message => 'reason')`, and including a reason is operationally valuable (it surfaces in audit logs and the killed-query error message). Minor omission.

5. **OPA / production stack tie-in** — The answer does not connect resource group selector matching to the JWT-principal vs role-name pitfall that iter18/19/20 emphasized. Since this prod uses JWT + OPA, a one-liner like "the selector's `user` field matches the JWT principal, not a Trino role" would have been appropriate (the answer uses `source` selectors which sidesteps this, but a brief note would harden the advice).

6. **No mention of `system.runtime.transactions`** — Long-running transactions can also pin JDBC connections to source DBs. Minor coverage gap for completeness.

7. **PostgreSQL `idle_in_transaction_session_timeout`** — Worth mentioning alongside `statement_timeout` because Trino-side hung sessions can leave Postgres connections in `idle in transaction`. Minor.

## WebSearch verification notes

- **https://trino.io/docs/current/admin/event-listeners-http.html** — Confirmed all HTTP event listener property names used in the answer. Defaults verified.
- **https://trino.io/docs/current/connector/system.html** — Confirmed `system.runtime.queries` and `system.runtime.tasks` exist. Column enumeration for queries verified (query_id, state, user, source, query, resource_group_id, queued_time_ms, analysis_time_ms, planning_time_ms, created, started, last_heartbeat, end, error_type, error_code).
- **https://trino.io/docs/current/connector/mysql.html** — Confirmed OSS MySQL connector has NO `connection-pool.*` properties (Starburst-only feature). Validates the four-layer defense rationale.
- **https://trino.io/docs/current/admin/resource-groups.html** — Confirmed `source` is a valid selector field matched as Java regex; `hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued` are valid properties.
- **https://www.pgbouncer.org/usage.html** — Confirmed `SHOW POOLS` and `SHOW CLIENTS` are valid admin commands. Column is `cl_waiting` (not `waiting_clients` literally).
- **https://www.postgresql.org/docs/current/runtime-config-client.html** — Confirmed `statement_timeout` defaults to milliseconds when no unit suffix; `ALTER ROLE ... SET statement_timeout` is the correct per-role syntax.
- **https://trino.io/docs/current/sql/call.html + System connector** — Confirmed `CALL system.runtime.kill_query(query_id => '...', message => '...')` syntax with named parameters.
- **https://trino.io/docs/current/admin/web-interface.html** — UI root is `/ui/`, not `/ui/queries`. Minor inaccuracy in the answer.

## Recommendation for teacher

The answer is strong (4.70) and demonstrates real operational maturity. Resource fixes for future iterations on this topic:

1. **Add a small "PgBouncer field reference" subsection** to the federation monitoring resource: explicitly map "waiting clients" to the `cl_waiting` column in `SHOW POOLS` (and `state='waiting'` rows in `SHOW CLIENTS`) so alert queries can reference the literal column names.

2. **Trino UI path correction**: standardize to `/ui/` (the root is the queries landing page) and `/ui/preview` for the preview UI. Avoid `/ui/queries` which does not exist as a documented route.

3. **`system.runtime.tasks` columns**: add a short DESCRIBE-based reference table to a federation/monitoring resource. The official System connector docs do not enumerate task columns, so engineers cannot copy-paste with confidence — the resource should either (a) list the columns observed from a 467 DESCRIBE, or (b) recommend `DESCRIBE system.runtime.tasks` as the verification step before writing alerting queries.

4. **Include `kill_query` `message` parameter** in the standard runbook snippet — operationally important for audit trail and so the killed user sees a meaningful error.

5. **Tie to OPA/JWT prod stack**: even on federation-monitoring topics, add a one-line callout that resource group selectors using `user` match the JWT principal (not Trino role names), continuing the iter18/19/20 fix.

6. **Add `idle_in_transaction_session_timeout`** alongside `statement_timeout` in the Postgres backstop layer — covers the case where a Trino session leaves a transaction open without an active statement.
