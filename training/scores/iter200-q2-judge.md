# Iter 200 Q2 Judge — JDBC Connection Model and PgBouncer

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings

**Technical accuracy (5)** — Every load-bearing technical claim was verified against authoritative sources:

- **JDBC connection model**: Answer correctly states the PostgreSQL connector creates **one split per non-partitioned table scan**, mapping to one JDBC connection — NOT one per worker. This matches the resource and is confirmed by trinodb/trino#389 and the Trino developer docs: "For data sources that don't have partitioned data, a good strategy is to simply return a single split for the entire table" and "JDBC-based tables currently use a single connection."
- **No native pool in OSS Trino 467**: Verified. The Trino 481 PostgreSQL connector docs (current) make NO mention of `connection-pool`, `pool`, `pooling`, `BoneCP`, or `HikariCP`. The same property `connection-pool.enabled` IS documented in Starburst Enterprise's PostgreSQL connector page (with default `false`, max-size `10`, max-connection-lifetime `30m`, connection-timeout `30s`). Issue trinodb/trino#15888 remains **Open** since January 2023. The answer's framing — and its explicit warning that these properties will be "silently ignored" — is correct.
- **`prepareThreshold=0` required**: Verified. PgBouncer in transaction mode breaks server-side prepared statements because the backend connection rotates between transactions; pgjdbc caches a server-side prepared statement after 5 executions (default `prepareThreshold=5`) and the next transaction may land on a different backend without that statement, surfacing `prepared statement "S_1" does not exist`. Setting `prepareThreshold=0` disables server-side prepared statements. (Note: PgBouncer 1.21.0+ added optional prepared-statement tracking via `max_prepared_statements`, but the answer's recommendation remains the safe and broadly correct one — and the answer's stack is not pinned to 1.21+.)
- **Resource-groups JSON field names**: Verified against the Trino 480 admin docs. `rootGroups`, `hardConcurrencyLimit`, `maxQueued`, `schedulingPolicy`, `selectors`, `softMemoryLimit`, `name` all match exactly. `"schedulingPolicy": "fair"` is a valid value (alongside `weighted`, `weighted_fair`, `query_priority`).
- **Postgres error string**: `FATAL: too many connections for role "trino_reader"` is the canonical message when `CONNECTION LIMIT` is exceeded for a role.
- **`statement_timeout` units**: `'300000'` (ms) at role level is correct syntax (`ALTER ROLE ... SET statement_timeout = '300000'`). The value is interpreted as milliseconds when no unit suffix is provided.

No factual errors detected.

**Beginner clarity (4)** — Strong overall, but loses one point:
- The opening "JDBC Connection Model: The Critical Mental Shift" section uses heavy jargon up front (`splits`, `worker task`, `partition-column`, "custom split strategy") without inline gloss. A SaaS engineer who hasn't read the federation resource may need to re-read paragraph 2.
- "Resource group queue full (100 queued)" — fine for someone who read the answer linearly, but the queue-vs-concurrency distinction (`hardConcurrencyLimit=10` vs `maxQueued=100`) is not labeled as cleanly as it could be ("at most 10 running concurrently, up to 100 more waiting in line, beyond that rejected").
- Otherwise excellent: the four-layer scaffolding, the worked example table, and the final error-behavior table all walk the engineer through the mental model without dropping jargon bombs.

**Practical applicability (5)** — Engineer can act immediately:
- Concrete catalog properties block with the exact JDBC URL parameters.
- Complete `pgbouncer.ini` snippet with `pool_mode=transaction`, `max_client_conn=1000`, `default_pool_size=50`, `reserve_pool_size=10`.
- Complete `etc/resource-groups.json` AND the `resource-groups.properties` companion file (many answers forget the latter).
- A worked-example sizing table that ties the four layers together with realistic numbers (`max_connections=300`, app uses 150, leaves 250 of headroom — explicit math).
- Crucially, names the production stack correctly (Kubernetes service names, `app.svc.cluster.local`, on-prem fit).

**Completeness (5)** — Covers all six items in the rubric:
- JDBC connection model (single split = single connection): yes, with the capacity-planning formula.
- No native pool in OSS Trino 467: yes, with the Starburst-vs-OSS warning.
- PgBouncer with transaction pooling + `prepareThreshold=0`: yes, with the prepared-statement failure mode explained.
- Role-level `CONNECTION LIMIT` plus the `pg_stat_activity` monitoring query: yes.
- Resource groups with `hardConcurrencyLimit` + `maxQueued` + selector wiring via `source`: yes.
- `statement_timeout` on the Postgres replica: yes.
- Error behavior at each ceiling: yes, summarized in a final table — each layer's failure mode is named with the actual error string.

The only thing that could be added is a note that the answer's `default_pool_size=50` + `hardConcurrencyLimit=10` combo is intentionally over-provisioned at the PgBouncer layer (50 connections / 10 concurrent queries = 5x headroom for multi-table joins), but the worked example implies this without stating it.

## Resource fix suggestions

The answer is materially stronger than minimum bar. The resource file (`22-trino-federation-postgresql.md`) is already excellent on this material. Two minor polish items:

1. **Add an inline gloss for "split" in Section 2.3** — even though Section 2.3 explains the JDBC connection model, the term `split` appears 10+ times before any beginner-friendly definition. Suggest one sentence near first use: "A *split* in Trino is a unit of work assigned to one worker — for the PostgreSQL connector, one split = one JDBC connection held for the duration of that part of the query."

2. **Add a one-line note about PgBouncer 1.21+ optional prepared-statement support** to Section 8.2A. Currently the resource implies `prepareThreshold=0` is the only option; in PgBouncer 1.21+ users can set `max_prepared_statements` to a non-zero value to let PgBouncer track prepared statements across transactions. Still recommend `prepareThreshold=0` as the default-safe path, but acknowledge the alternative exists.

Neither item blocks the topic from reaching the 4.5 threshold.
