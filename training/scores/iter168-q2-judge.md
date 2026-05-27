# Iter 168 Q2 — Judge Score

**Date**: 2026-05-26
**Phase**: extended (post-final)
**Topic**: Trino federation / cross-source connectors (timeout behavior when downstream Postgres is slow: `statement_timeout`, JDBC `socketTimeout`, `query.max-execution-time`, all-or-nothing failure semantics)

## Question summary

Engineer runs a federated query joining an Iceberg usage_events table with a live Postgres account-metadata table. Asks: when Postgres gets slow, does Trino wait forever or time out? On timeout, does the entire query fail or just the Postgres branch? What do users see?

## Answer location

`/Users/hclin/github/recknihao/training/answers/iter168-q2.md`

## Scores

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Technical accuracy | 4.5 | x2 | 9.0 |
| Beginner clarity | 4.5 | x1 | 4.5 |
| Practical applicability | 5.0 | x1 | 5.0 |
| Completeness | 4.0 | x1 | 4.0 |
| **Weighted average (Tech x2)** | | | **4.50 / 5** |

**Result**: PASS (general threshold 3.5; topic-specific raised threshold 4.5 — this answer **meets** the raised topic threshold exactly).

## Verification (WebSearch against trino.io and pgjdbc docs)

| Claim | Verified? | Notes |
|---|---|---|
| Postgres `statement_timeout` kills long-running queries | YES | Standard Postgres GUC; can be set in `postgresql.conf` or per role |
| pgjdbc `socketTimeout` is a valid URL parameter (seconds, 0 = disabled) | YES | jdbc.postgresql.org documentation confirms; "timeout value used for socket read operations" |
| pgjdbc `connectTimeout` is a valid URL parameter (seconds, 0 = disabled) | YES | jdbc.postgresql.org documentation confirms |
| Trino `query.max-execution-time` config property exists | YES | trino.io "Query management properties" — "maximum allowed time for a query to be actively executing before terminated; excludes analysis, planning, queue wait" |
| Cross-catalog join executes on Trino workers, not pushed to Postgres | YES | trino.io PostgreSQL connector docs — cost-based join pushdown only applies *within a single catalog*; cross-catalog joins (Iceberg + Postgres) cannot push down to either source and must run on workers |
| Entire query fails on JDBC TableScan failure (no partial results) | YES | OSS Trino has no partial-result mechanism; a failed split causes the parent stage and parent query to fail |
| Resource group `hardConcurrencyLimit` is a real Trino property | YES | trino.io resource groups documentation |
| `prepareThreshold=0` required with PgBouncer transaction pooling | YES | pgjdbc + PgBouncer transaction-pooling well-known requirement |

No fabricated features. All technical claims are accurate for Trino 467.

## Strengths

- **Correct layered timeout model**: Postgres-side `statement_timeout`, JDBC `socketTimeout`/`connectTimeout`, Trino `query.max-execution-time` are all real, all distinct, and all correctly described as defense-in-depth.
- **Correct all-or-nothing framing**: "Trino cannot partially succeed" is accurate for OSS Trino 467. There is no partial-result mechanism; a failed JDBC scan propagates to the parent stage and fails the entire query.
- **Correct join execution model**: "The join between Iceberg events and Postgres accounts runs on Trino workers, not inside either database." Cross-catalog joins between Iceberg and Postgres cannot be pushed down to either source and must execute on workers.
- **Correct user-experience progression**: "hangs during overload → after timeout, error" maps to what users actually see in this scenario.
- **Strong actionable mitigation list**: 5 concrete, copy-pasteable actions (Postgres `statement_timeout`, JDBC `socketTimeout`, PgBouncer transaction pooling, Trino resource group `hardConcurrencyLimit`, always use a read replica). All are real, all are correct, all fit the on-prem k8s stack.
- **Threshold guidance is practical**: "longer than your normal query SLO but short enough to fail before users give up and hammer the retry button" — exactly the heuristic an oncall engineer needs.
- **The JDBC URL example carries the catalog-level config the engineer can paste directly**, including `prepareThreshold=0` (which is the correct value for PgBouncer transaction-pooling compatibility).

## Gaps

1. **No mention of `query_max_execution_time` session property** (technical accuracy / completeness): the global `query.max-execution-time` has a session-level counterpart that an engineer can set per-query without changing cluster config. For a federation query that may legitimately need a longer timeout than the cluster default, this is the right knob.
2. **No mention of dynamic filtering behavior under failure** (completeness): when Postgres is the build side of a federated join, dynamic filter generation depends on the Postgres scan completing. If Postgres is slow, the Iceberg side may also stall waiting for the filter. Worth naming as a secondary failure mode.
3. **No mention of OPA/event-listener capture of the failure** (production fit): on the prod stack, OPA decision logs and the Trino event listener will record the failed query — useful for postmortem attribution when "Postgres was slow at 14:23". This is the same OPA/event-listener gap that has been called out for three iterations.
4. **`socketTimeout` semantic nuance not explained** (technical accuracy): the answer says "after 60 seconds of no data from Postgres". This is correct, but worth nuance: `socketTimeout` applies to *every* socket read, so a *long-running but actively-streaming* Postgres query (one that returns one row per ~30 seconds) will NOT trigger a 60-second `socketTimeout`. It is not a total query timeout. The Scout24 "socketTimeout trap" article is a well-known reference here.
5. **No mention of `query.max-planning-time` or `query.max-run-time`** (completeness): there are three related "max time" properties in Trino — `max-planning-time`, `max-execution-time`, `max-run-time` (queue + plan + exec). The answer names only one. For a complete timeout story, naming all three helps the engineer pick the right knob.
6. **Error message "java.io.IOException: Query aborted" is a paraphrase, not a verbatim message** (technical accuracy, minor): not wrong, but a beginner grepping logs for that exact string may not find it. The actual Postgres-side timeout typically surfaces as `org.postgresql.util.PSQLException: ERROR: canceling statement due to statement timeout`.
7. **No mention of retry strategy / idempotency** (completeness): the answer correctly notes "no retry, no partial data — users must retry manually". A natural follow-up is whether the SaaS product should auto-retry on timeout, and the answer doesn't address it.

## Topic running-average update

Prior avg (after iter167 Q2): **4.162 across 13 questions**.

- After iter168 Q1 (3.60): (4.162 x 13 + 3.60) / 14 = (54.106 + 3.60) / 14 = 57.706 / 14 = **4.122 across 14 questions**
- After iter168 Q2 (4.50): (4.122 x 14 + 4.50) / 15 = (57.706 + 4.50) / 15 = 62.206 / 15 = **4.147 across 15 questions**

**Status**: NEEDS WORK — 4.147 still below the raised 4.5 threshold. Q1 (3.60) cleared the general 3.5 pass bar but is well under the raised 4.5 topic bar; Q2 (4.50) hit the topic bar exactly. The SSL resource gap (Q1) pulled the topic average back relative to where consecutive Q2-style 4.5+ answers would have taken it.

## Resource fix recommendations

- **HIGH (correctness gap from Q1)** — `resources/22-trino-federation-postgresql.md`: add a "Securing the connection: SSL/TLS to Postgres" section that covers the full pgjdbc SSL parameter set (`ssl=true`, `sslmode={disable,allow,prefer,require,verify-ca,verify-full}`, `sslrootcert`, `sslcert`, `sslkey`, `sslpassword`), the threat model each `sslmode` defends against, and the on-prem k8s mounting pattern (cert files as a Kubernetes Secret mounted into the Trino pods, referenced by path in `connection-url`). The complete catalog `.properties` snippet should include both the URL params and the Secret-mount references. Q1 explicitly punted on this entire area.
- **HIGH (correctness extension from Q2)** — same file: add a "Timeout layers and failure semantics" section that documents (1) the three layers (Postgres `statement_timeout`, pgjdbc `socketTimeout`/`connectTimeout`, Trino `query.max-execution-time` / `query_max_execution_time` session); (2) the all-or-nothing failure model with the actual error chains (Postgres → `PSQLException: canceling statement due to statement timeout`, JDBC socket → `IOException`, Trino-side → `QUERY_EXECUTION_TIMEOUT`); (3) the `socketTimeout` per-read nuance (it does NOT bound total query time on streaming responses); (4) dynamic-filtering build-side stall as a secondary failure mode when Postgres is the small side of the join.
- **HIGH (production fit, recurring across 4 iterations now)** — same file: OPA + event listener as the persistent record of federated-query failures on the on-prem k8s stack. A timed-out query produces (a) an OPA audit record for the catalog/schema/table resources it touched, (b) an event-listener record capturing the failure reason and timing. Together these are the postmortem source of truth — Trino's in-memory `system.runtime.queries` evicts after 15 minutes.
- **MEDIUM (completeness)** — same file: name all three Trino "max time" properties (`query.max-planning-time`, `query.max-execution-time`, `query.max-run-time`) and which one to set for what failure mode. Add the session-property forms.
- **MEDIUM (practical)** — same file: a "should the SaaS product auto-retry on federation timeout?" callout, with the answer being "only for idempotent reads; surface the error to the user with a clear 'metadata source slow, please retry' message for writes."
- **LOW (clarity)** — same file: inline-gloss "transaction pooling", "build side", "dynamic filter", "predicate pushdown" the first time each appears.
