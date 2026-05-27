# Iter274 Q2 Score

**Score**: 4.81 / 5.0
**Pass/Fail**: PASS

## Dimension scores
- Technical accuracy: 4.75/5
- Beginner clarity: 5/5
- Practical applicability: 5/5
- Completeness: 4.5/5

## What the answer got right
- **Correct headline fact**: OSS Trino's PostgreSQL connector does not expose `connection-pool.*` properties (unlike the Oracle connector, which does). Verified against trino.io PostgreSQL connector docs — connection pool properties are absent. Calling out that adding them is silently ignored is exactly the kind of false-confidence trap an engineer needs to know.
- **PgBouncer + `prepareThreshold=0` is the standard, verified workaround.** PgJDBC docs and the PgBouncer FAQ both document that transaction-mode pooling breaks server-side prepared statements (the pgjdbc default prepares after the 5th execution of the same SQL). Setting `prepareThreshold=0` forces the Simple Query Protocol and eliminates the "prepared statement does not exist" failures. The explanation of WHY (transaction mode routes successive transactions to different backends) is accurate and well-targeted.
- **Resource group property names and semantics are correct.** `hardConcurrencyLimit` = max running queries, `maxQueued` = queue ceiling beyond which queries are *rejected* — both verified against trino.io/docs/current/admin/resource-groups.html. The "queries 1-15 run, 16-200 queue, 201+ rejected" flow precisely matches the documented behavior.
- **`resource-groups.properties` configuration manager wiring is correct** — the dual-file setup (separate from `config.properties`) and the `file` configuration manager declaration are right.
- **Source selector caveat is highly valuable**: explicitly warning that the `source` selector only matches if the client sets `X-Trino-Source` / `?source=` is the kind of operational gotcha that traps real engineers in production. Excellent practical nuance.
- **Queue-vs-fail behavior is answered directly and accurately.** Trino queues at the resource group layer, does not hit Postgres until execute slot opens, and only rejects on queue overflow. Matches docs verbatim.
- **Postgres-side `ALTER ROLE ... CONNECTION LIMIT` and `statement_timeout`** are correct PostgreSQL DBA-side defense-in-depth measures. The "tripwire, not the primary control" framing is the right mental model.
- **Sizing table is concrete and internally consistent**: 15 concurrent × 1-3 tables per dashboard = 15-45 connections, fits inside the 50-connection PgBouncer pool. The numbers tell a story the engineer can replicate.
- **Monitoring section spans all three layers** (Postgres `pg_stat_activity`, PgBouncer `SHOW POOLS/CLIENTS/SERVERS`, Trino UI "Queued time"). Engineer knows exactly where to look during an incident.
- **Production-fit**: PgBouncer + Trino + on-prem k8s is fully compatible with the prod stack (Trino 467 + Iceberg + MinIO + HMS). The recommendation to eventually ingest to Iceberg as the "remove Postgres from the hot path" fix also fits the prod stack and is the architecturally correct long-term answer.
- **Four-layer defense framing** is structurally helpful for a beginner — gives a mental model rather than a flat list of knobs.

## Errors or gaps
- **"One Trino query = exactly 1 JDBC connection" is a simplification.** For the PostgreSQL connector with default settings, this is accurate — the OSS PostgreSQL connector does not split JDBC reads by default. However, if the engineer ever joins multiple Postgres tables in one query, each table scan opens its own connection. The answer does hint at this ("more if individual dashboards join multiple Postgres tables") but could be slightly more explicit that each Postgres TableScan node = 1 connection. Minor.
- **No mention of `connection-user`/`connection-password` rotation or per-catalog credential strategies** — out of scope for the question but worth a one-liner that the catalog-level connection credentials are global (all queries use the same Postgres user), which is why the role-level `CONNECTION LIMIT` actually works as a defense.
- **No mention of OPA implications.** In the production stack, the OPA policy must allow the dashboard source/user to execute against `app_pg`. Worth a one-line note since resource group selectors don't bypass OPA.
- **PgBouncer in k8s deployment detail missing.** The answer assumes PgBouncer is already running as a k8s service (`pgbouncer.svc.cluster.local:6432`) but doesn't mention sidecar vs StatefulSet vs single deployment trade-offs. For a SaaS engineer who's never deployed PgBouncer on k8s, a one-liner pointing at the bitnami chart or a sidecar pattern would close the gap.
- **`pool_mode = transaction` is asserted as the right choice** without contrasting with `session` mode. Transaction mode is the right answer for Trino's stateless analytical query pattern, but a one-line note ("session mode would defeat the multiplexing benefit; statement mode breaks anything that uses a transaction") would help the engineer defend the choice in a code review.
- **No mention that PgBouncer 1.21+ now natively supports prepared statements in transaction mode** with `max_prepared_statements > 0`. This is a relatively new alternative that could remove the need for `prepareThreshold=0`. Mentioning it as an alternative would future-proof the advice. Minor.
- **The `softMemoryLimit: "60%"` value is dropped into the resource group config without explanation.** A new reader won't know what 60% of what means (it's % of cluster query memory). One-liner needed.

## WebSearch findings
- **PostgreSQL connector docs (trino.io/docs/current/connector/postgresql.html)**: Confirmed no `connection-pool.*` properties documented for the PostgreSQL connector. The Oracle connector docs DO list `oracle.connection-pool.max-size` etc., showing that Trino exposes pool properties when the underlying driver supports them — PostgreSQL doesn't. Answer's claim is verified.
- **Resource groups docs (trino.io/docs/current/admin/resource-groups.html)**: Confirmed `hardConcurrencyLimit` is "maximum number of running queries" and `maxQueued` is "maximum number of queued queries. Once this limit is reached new queries are rejected." Exactly matches the answer's flow description (execute → queue → reject).
- **pgjdbc + PgBouncer interaction**: Confirmed via pgjdbc issue #742 and PgBouncer FAQ that `prepareThreshold=0` is the documented workaround for transaction-mode pooling with the PostgreSQL JDBC driver. Also confirmed that PgBouncer 1.21.0+ supports `max_prepared_statements` as a newer alternative — answer doesn't mention this, but the `prepareThreshold=0` advice remains correct and is the most widely-deployed solution.
- **Trino split/connection model for PostgreSQL connector**: The PostgreSQL connector in OSS Trino does not parallelize reads — each Postgres table scan is one split executed on one worker, opening one JDBC connection. Answer's "1 query = 1 connection per Postgres table" is correct for the default case.

## Topics updated
Trino federation — prior avg 4.485 across 221 questions (note: iter274-Q1 score file not yet written; this judgment applies Q2 directly to the iter273 closing average). If iter274-Q1 lands later, the running average for this iteration will need to be recomputed in order: 4.485/221 → +Q1 → +Q2(4.81).

Direct application (Q2 only, assuming Q1 still pending): (4.485 × 221 + 4.81) / 222 = (991.185 + 4.81) / 222 = **4.486 across 222 questions**. Status: NEEDS WORK (4.486 < 4.500 raised threshold). Gap: 0.014 (narrowed from 0.015).

Iter274-Q2 contributes +0.001 to the running average and continues the iter272-274 streak of strong federation answers (all ≥ 4.75). Topic needs ~6-8 more answers at 4.75+ to cross the 4.500 raised threshold. The connection-pool / PgBouncer angle is a new sub-topic that has not been heavily tested before — this answer covers it strongly and could become a reference response if the resource gets enriched with the PgBouncer 1.21+ prepared statement alternative.
