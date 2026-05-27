# Iter 149 Q2 — Judge Report

**Question**: Trino JDBC connection pooling (HikariCP-style) + prepared-statement-style query plan reuse to fix "Too many open connections" under 50-80 concurrent users.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter149-q2.md`

## Overall Score

**Weighted average: 3.0 / 5  -> FAIL (threshold 4.5)**

Weights: Technical accuracy x2, Clarity x1, Practical usefulness x1, Completeness x1. Total weight = 5.

Calculation: (3 x 2 + 4 + 3 + 2) / 5 = 15 / 5 = **3.0**

## Per-Dimension Scores

### Technical accuracy: 3 / 5 (x2 weight)

**What is correct**
- The resource-groups JSON shown (`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`) uses Trino's real property names. Cross-checked against `resources/05-multi-tenant-analytics.md` lines 1413-1447 and the official [Trino resource groups docs](https://trino.io/docs/current/admin/resource-groups.html). All property names and units are correct for Trino 467.
- The framing that resource groups produce a `QUERY_QUEUE_FULL` rejection (not a TCP-level refusal) when `maxQueued` is exceeded is accurate.
- The partition-pruning advice for parameterized queries on a partition column (e.g., `event_date`) is correct general guidance.
- The honest "what is missing" call-out names two real, specific gaps (JDBC pooling, PREPARE/EXECUTE) by their correct technical names.

**What is wrong or misleading**
- **The resource-group advice is mis-targeted at the actual error.** "Too many open connections" on Trino is an HTTP-server / coordinator socket limit (`http-server.max-concurrency`, default-class connection-per-server caps; see [Trino HTTP server properties](https://trino.io/docs/current/admin/properties-http-server.html) and [trinodb/trino issue #25031](https://github.com/trinodb/trino/issues/25031)). Resource groups gate **query admission after the HTTP connection is already established** — they cap concurrent *running queries*, not concurrent TCP/HTTP connections. The answer even concedes this in passing ("This does not directly reduce the number of open JDBC connections"), but still leads with resource groups as "the most direct tool" for the connection-overload symptom. That is misdirection: resource groups will NOT fix `Too many open connections` errors. The correct first lever is either (a) increase `http-server.max-concurrency` on the coordinator, or (b) introduce client-side connection pooling so each API request reuses an existing connection rather than opening a new one. The answer does neither.
- The phrase "more graceful than a connection-refused error at the TCP level" implies resource groups are a substitute for the connection-level fix. They are not.

### Clarity: 4 / 5

- The structure clearly separates "what resources cover," "what's missing," and "what you can do now."
- The acknowledged-gap section explicitly names the three missing topics, so a reader knows where the answer stops.
- One clarity deduction: the answer does not make clear to a beginner that resource groups and connection pooling solve *different problems*. A SaaS engineer reading this could believe configuring resource groups will resolve their `Too many open connections` symptom, which it will not.

### Practical usefulness: 3 / 5

- Telling the engineer to "consult the Trino 467 JDBC driver documentation directly" is honest but leaves the engineer with no concrete next step on the two things they actually asked about (pooling, prepared statements).
- The three "what you can do now" bullets are real and actionable (configure resource groups, verify partition pruning, check `system.runtime.queries` for planning vs execution time), but they do not address the immediate production incident (50-80 concurrent users hitting `Too many open connections`). The diagnostic on planning time is the most useful single suggestion in the answer.
- A more useful answer would have at minimum named the coordinator config knob (`http-server.max-concurrency`) and pointed at the standard pattern of putting a JDBC connection pool in front of the Trino driver — both of which are directly addressed by the production Trino docs.

### Completeness: 2 / 5

- The engineer asked two clear questions: (1) Can I pool Trino JDBC connections like Postgres? (2) Is there a prepared-statement equivalent so Trino does not re-plan? The answer says "the resources do not cover this" for both.
- WebSearch confirmed both have direct, well-documented answers in Trino:
  - **JDBC pooling**: The Trino JDBC driver (class `io.trino.jdbc.TrinoDriver`) works behind standard JDBC connection pools including HikariCP, configured via `jdbcUrl` (not `dataSourceClassName`, since the Trino driver does not ship a `javax.sql.DataSource` class). See [Trino JDBC driver docs](https://trino.io/docs/current/client/jdbc.html) and the open [trinodb/trino discussion #15827](https://github.com/trinodb/trino/discussions/15827). The Trino JDBC "connection" is a thin wrapper over the HTTP client to the coordinator — pooling it primarily limits *concurrent HTTP connections to the coordinator*, which IS exactly the lever for the engineer's `Too many open connections` problem.
  - **Prepared statements**: Trino supports `PREPARE name FROM <sql>` and `EXECUTE name USING (...)`, available via standard JDBC `PreparedStatement` (`?` placeholders). See [Trino PREPARE docs](https://trino.io/docs/current/sql/prepare.html) and [EXECUTE docs](https://trino.io/docs/current/sql/execute.html). Trino 425+ added `EXECUTE IMMEDIATE` which collapses prepare+execute into one round-trip, reducing client/coordinator chatter for large SQL.
- **However** — and this is the nuance the answer also missed — Trino does **NOT cache the query plan across prepared statement executions**. Each `EXECUTE` re-plans the statement on the coordinator (see Presto/Trino issue #1141: plan trees become contaminated with session-specific tuple-domain analysis, so plan reuse is not implemented). So the engineer's *expectation* — "Postgres-style plan reuse" — is partially incorrect for Trino, and the most accurate answer is: "Yes, Trino has PREPARE/EXECUTE and `?` placeholders work via JDBC, but unlike Postgres, Trino re-plans on each EXECUTE. The win you get from prepared statements in Trino is parameter binding hygiene and (with EXECUTE IMMEDIATE) one fewer round-trip — not plan caching. To actually reduce planning cost, focus on partition pruning, manifest compaction, and possibly caching results at the API layer." That nuanced answer would have been the gold standard. The provided answer captures none of it.

## What WebSearch Found

| Question | Finding | Source |
|---|---|---|
| Does Trino JDBC work with HikariCP? | Yes, via standard `jdbcUrl` configuration. The Trino driver class is `io.trino.jdbc.TrinoDriver`. There is no Trino-provided `DataSource` class, so `dataSourceClassName`-style HikariCP config is not used; the `jdbcUrl` form is. | [Trino JDBC docs](https://trino.io/docs/current/client/jdbc.html), [trinodb/trino #15827](https://github.com/trinodb/trino/discussions/15827) |
| Does Trino support PREPARE / EXECUTE? | Yes, both as SQL and via JDBC `PreparedStatement` with `?` parameters. `EXECUTE IMMEDIATE` (Trino 425+) collapses round-trips. | [Trino PREPARE](https://trino.io/docs/current/sql/prepare.html), [Trino EXECUTE](https://trino.io/docs/current/sql/execute.html), [trinodb/trino #17353](https://github.com/trinodb/trino/issues/17353) |
| Do prepared statements cache the plan across executions? | **No.** Trino re-plans on each EXECUTE; plan caching for parameterized queries has been requested but is not implemented because plans become session/parameter-contaminated. | [trinodb/trino #1141](https://github.com/prestosql/presto/issues/1141) |
| What actually causes "Too many open connections" on Trino? | Coordinator HTTP server connection limits (`http-server.max-concurrency`, default ~1024); not resource group state. | [Trino HTTP server properties](https://trino.io/docs/current/admin/properties-http-server.html), [trinodb/trino #25031](https://github.com/trinodb/trino/issues/25031) |

## Coverage Gap Severity: HIGH

This is a **HIGH-severity coverage gap** for three reasons:

1. **Both asked-about features (JDBC pooling, PREPARE/EXECUTE) exist in Trino 467 with first-class support, are documented on trino.io, and have unambiguous, short answers.** Saying "the resources do not cover this" leaves a SaaS engineer hanging on a basic question that the official Trino docs answer in two pages.
2. **The connection-pooling question maps directly to the production scenario in `prod_info.md`** (on-prem Trino 467, embedded analytics API serving multi-tenant SaaS). This is a high-frequency real-world pattern — an analytics API in front of Trino needs pooling. The current resources do not equip the responder to answer it.
3. **The answer that WAS given (resource groups) is mis-targeted at the symptom.** Resource groups do not reduce open HTTP connections to the coordinator. So the engineer would deploy the suggested change and still see `Too many open connections` errors. That is a worse outcome than "I don't know" because it costs the engineer time.

## Resource Fix Recommendations

Add a new resource (or extend `resources/05-multi-tenant-analytics.md` with a new section) that covers **Trino client patterns for embedded analytics APIs**:

1. **JDBC connection pooling for Trino**
   - The Trino JDBC driver class: `io.trino.jdbc.TrinoDriver`
   - Standard pool libraries (HikariCP) work via `jdbcUrl` configuration (not `dataSourceClassName`, since Trino does not ship a `DataSource`).
   - Sample HikariCP config snippet pointing at `jdbc:trino://coordinator:8080/...` with reasonable `maximumPoolSize` (e.g., 20-40 for a 50-80 concurrent user API).
   - Explain that a Trino JDBC "connection" is a long-lived HTTP client to the coordinator — pooling caps the HTTP fan-in, which is exactly the lever for `Too many open connections` errors.
   - Note the coordinator-side knob: `http-server.max-concurrency` in `etc/config.properties` controls the coordinator's accept limit; raise it carefully on the k8s coordinator pod.
   - Mention that pooled connections must be returned promptly — long-running query results can starve the pool; either size the pool for peak concurrency or set per-query timeouts.

2. **Trino prepared statements via JDBC**
   - `PREPARE name FROM <sql>` / `EXECUTE name USING (...)` SQL syntax.
   - Standard JDBC `PreparedStatement` with `?` placeholders is supported.
   - `EXECUTE IMMEDIATE` (available in Trino 425+, so present in 467) collapses the prepare/execute into one HTTP call — preferred for one-shot parameterized queries.
   - **Critical caveat**: unlike Postgres, Trino does **not** cache the query plan across executions of the same prepared statement. Each EXECUTE re-plans. So the value of prepared statements in Trino is parameter binding hygiene + (with EXECUTE IMMEDIATE) round-trip reduction — NOT plan reuse. To reduce real planning cost, the levers are partition pruning, manifest compaction, dynamic filtering, and (for cheap repeated dashboards) caching results at the API layer.
   - Cite [trinodb/trino issue #1141](https://github.com/prestosql/presto/issues/1141) as the upstream explanation for the no-plan-cache design.

3. **Mapping symptoms to the right lever** — a small table for the responder:

   | Symptom | Wrong lever | Right lever |
   |---|---|---|
   | `Too many open connections` from API | Resource groups (gate query admission, not connections) | JDBC connection pool in the API; raise `http-server.max-concurrency` on coordinator |
   | Cluster saturating under one tenant's load | Connection pool (does not bound query concurrency) | Resource groups with per-tenant `hardConcurrencyLimit` |
   | Same parameterized query re-planned every request | PREPARE/EXECUTE alone (Trino re-plans) | Partition pruning + manifest compaction + API-layer result cache |

This addition would close the gap for this question and several adjacent ones (rate limiting, connection budget sizing, Trino client patterns).

## Rubric Update

This question primarily exercises **Multi-tenant analytics: isolating customer data in SaaS** (resource groups angle) but also opens a new functional area not yet represented in the rubric: **Trino client patterns for embedded analytics APIs (JDBC pooling, prepared statements, coordinator HTTP limits)**. Consider adding this as a new rubric topic if it has not been added in earlier iterations; the current 20-topic checklist does not cover it.

For the Multi-tenant analytics topic average: this answer at 3.0 will pull the long-running average down slightly (4.458 across 104 questions before this one).
