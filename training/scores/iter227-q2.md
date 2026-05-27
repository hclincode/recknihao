# Score: iter227-q2
Score: 3.10
Topic: Trino federation / cross-source connectors

## What was correct
- **MySQL connector `dynamic_filtering_wait_timeout` default = 20s** — verified against https://trino.io/docs/current/connector/mysql.html. Correct.
- **Catalog session property syntax** — `SET SESSION billing_mysql.dynamic_filtering_wait_timeout = '30s'` is the correct form for a catalog-scoped session property. Correct.
- **MySQL `max_execution_time` default = 0 (unlimited), unit = milliseconds** — verified against MySQL docs. Summary table correctly states "0 (unlimited)" and the example correctly uses 300000 ms for 5 minutes. Correct.
- **MySQL `max_execution_time` only applies to SELECTs** — not stated explicitly, but the answer doesn't mislead here. (Minor missing nuance.)
- **Symptom-to-layer triage table** is genuinely useful for an on-call engineer trying to disambiguate which layer killed the query — this is exactly the framing the SaaS engineer asked for.
- **Slow-query log debugging step** is a good practical tactic: confirms whether the query even reached MySQL before being killed.
- **Practical guidance to "start with SET SESSION (no restart)"** is correct and exactly the right operational ordering.
- Structure of "three timeout layers, outer to inner" is a clear mental model for a beginner.

## What was wrong or missing

### CRITICAL technical errors

1. **Iceberg connector default is WRONG.** Answer states: *"Default: 20 seconds for both `iceberg.dynamic_filtering_wait_timeout` and `billing_mysql.dynamic_filtering_wait_timeout`"*. Per the official Iceberg connector docs (https://trino.io/docs/current/connector/iceberg.html), the Iceberg connector default is **1 second**, not 20 seconds. Only the JDBC family (MySQL, PostgreSQL, etc.) defaults to 20s. This is the exact same factual error called out in iter164 Q2 (see rubric line 5102: "change '2s' to '1s' per official Iceberg connector docs"). The teacher's fix from iter164 has either not landed in resources or has not been internalized by the weak-ai-responder.

2. **`socketTimeout` unit is WRONG.** Answer states: *"socketTimeout=60 means 'fail if no data for 60 seconds.'"* This is incorrect. Per the MySQL Connector/J docs (https://dev.mysql.com/doc/connector-j/en/connector-j-connp-props-networking.html), `socketTimeout` is specified in **milliseconds**, default `0` (no timeout). So `socketTimeout=60` actually means 60 *milliseconds* — i.e., 0.06 seconds, which would immediately kill every query. The correct value for "60 seconds" would be `socketTimeout=60000`. An engineer who copy-pastes the snippet from this answer into their `billing_mysql.properties` will catastrophically break their production catalog.

3. **`socketTimeout` default is WRONG.** Answer says "Default: 60 seconds if set via the `socketTimeout` JDBC parameter (undefined/unlimited if not set)" — the phrasing is muddled and incorrect. The driver default is simply `0` (no timeout). There is no "60 seconds if set" default.

### MAJOR completeness gap

4. **Missing Trino's own `query.max-execution-time` config / `query_max_execution_time` session property.** This is the most likely cause of the user's specific symptom — a query "hanging for 5-10 minutes then dying with 'query was cancelled'". The Trino-side query timeout has a default of **100d** (so not the firing layer here unless overridden), BUT a session-level or resource-group-level override is one of the most common reasons for the exact error message the user reports. Also missing: `query.max-run-time` (default 100d), `query.client-timeout`, and the resource-group `cpuLimit` / `softCpuLimit`. The answer's "three layers" framing is incomplete — there are at least 4-5 layers, and the most commonly-misconfigured one (Trino's own query timeout / resource group) is omitted.

5. **No mention of `EXPLAIN ANALYZE` / Trino Web UI** to determine which stage is stalled. For a "I can't tell which layer is timing out" question, pointing the engineer at the Trino UI's query timeline / stage details is the single most actionable diagnostic step.

6. **`SET SESSION query_max_execution_time = '10m'`** is the per-session way to constrain Trino's own query timeout and would have been the natural counterpart to the `SET SESSION` pattern used for dynamic filtering. Missing.

### MINOR issues

7. Confuses "dynamic filtering wait timeout" with a "query timeout". DF wait timeout does NOT kill the query; it only causes Trino to give up waiting for the build-side filter and proceed unfiltered. The answer correctly says this in one place ("Trino gives up waiting and launches the probe scan...unfiltered") but the "outer to inner" framing implies it's a query-killing timeout, which it is not.

8. `max_execution_time` is described as MySQL "aborts the query server-side if it runs longer than this limit" — true, but only for SELECT statements. INSERT/UPDATE/DELETE are unaffected. Not load-bearing for this question, but a nuance worth noting.

9. No mention of production-environment fit: the engineer runs Trino 467 in k8s on-prem (per `prod_info.md`). The "requires coordinator restart" note for catalog property changes is correct but should mention this means a k8s rolling restart of the coordinator pod.

## Per-dimension scoring

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | Iceberg DF wait timeout default wrong (1s, not 20s); socketTimeout unit wrong (ms, not s) — would break production if copy-pasted; socketTimeout default wrong; Trino query.max-execution-time omitted entirely. The MySQL-side facts are accurate. |
| Beginner clarity | 4.0 | Mental model of "three layers" is clear; symptom triage table is excellent; jargon (dynamic filtering, build/probe) is explained reasonably. |
| Practical applicability | 3.5 | Symptom→layer triage is exactly what the engineer asked for; SET SESSION ordering is correct. BUT the wrong socketTimeout value is a live foot-gun, and missing query.max-execution-time means the engineer may chase the wrong layer for hours. |
| Completeness | 2.5 | Misses Trino's own query-level timeout (the very layer most commonly responsible for "query was cancelled"); misses EXPLAIN ANALYZE / Web UI diagnosis; misses session-level query_max_execution_time. |

**Weighted average (Tech×2)**: (2.5×2 + 4.0 + 3.5 + 2.5) / 5 = 14.5 / 5 = **2.90**
**Simple average**: (2.5 + 4.0 + 3.5 + 2.5) / 4 = **3.125**

Reported score: **3.10** (rounded simple average, slight downweight for the production-foot-gun socketTimeout error)

## Verdict
**FAIL** (3.10 < 4.5 raised threshold for Trino federation topic; also < 3.5 general pass threshold).

Two critical correctness errors (Iceberg DF default = 1s not 20s; socketTimeout in milliseconds not seconds) plus a major completeness gap (omits Trino's own `query.max-execution-time`, which is the single most plausible cause of the user's "query was cancelled" symptom). The iter164 Q2 feedback specifically called out the Iceberg DF default error and recommended fixing it in `resources/22-trino-federation-postgresql.md` — the recurrence here suggests the fix did not propagate, or the weak-ai-responder is not reading the corrected section.

## Resource fix recommendations

- **CRITICAL** — Add a prominent warning in the federation resource: **MySQL Connector/J `socketTimeout` is in MILLISECONDS, default 0 (no timeout)**. Show a worked example: `socketTimeout=60000` = 60 seconds. Same for `connectTimeout`. Same warning applies to `max_execution_time` (also ms) — call out both to avoid unit confusion.
- **CRITICAL** — Fix the Iceberg DF wait timeout default to **1 second** wherever it appears. Add an explicit table: "JDBC connectors (MySQL/Postgres): 20s. Object-store connectors (Iceberg/Hive/Delta): 1s." This error has now recurred across iter164 Q2 and iter227 Q2; the teacher should grep all resources for "dynamic_filtering_wait_timeout" and audit every default mentioned.
- **HIGH** — Add a "federated query timeout layering" section that lists ALL the layers in order:
  1. Trino client timeout (`query.client-timeout`, default 5m)
  2. Trino `query.max-execution-time` / session `query_max_execution_time` (default 100d)
  3. Resource group `cpuLimit` / `softCpuLimit` if configured
  4. Trino dynamic filtering wait timeout (per-catalog, JDBC=20s, Iceberg=1s) — does NOT kill the query, only stops waiting
  5. MySQL `max_execution_time` (default 0, milliseconds, SELECT only)
  6. MySQL Connector/J `socketTimeout` (default 0, milliseconds)
  7. MySQL `wait_timeout` / `net_read_timeout` / `net_write_timeout` at the server side
- **HIGH** — Add a "which layer killed my query" diagnostic flowchart: start with Trino Web UI → query state + error message; then EXPLAIN ANALYZE for stage-level timing; then MySQL slow-query log / `SHOW PROCESSLIST` on the replica.
- **MEDIUM** — Note that DF wait timeout is NOT a query-killing timeout — it only controls how long Trino waits before giving up on filter pushdown and proceeding with an unfiltered scan. Several answers in this iteration series conflate the two.
