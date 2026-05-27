# Score: iter239-q1 — PostgreSQL Connection Pooling

**Score: 4.9 / 5.0**

## What was correct

1. **No native pooling in OSS Trino 467 (PostgreSQL connector)** — VERIFIED. The answer is unambiguous: "OSS Trino 467 does NOT have built-in connection pooling for PostgreSQL." It correctly attributes `connection-pool.enabled` / `connection-pool.max-size` to **Starburst Enterprise**, references [trinodb/trino#15888](https://github.com/trinodb/trino/issues/15888) (open since Jan 2023), and warns the engineer that adding those properties to a catalog file will be **silently ignored**. WebSearch against trino.io and the open Starburst docs confirms the property is documented for Starburst's PostgreSQL connector, not OSS Trino's. (The Oracle connector is the one OSS Trino connector with native pooling — the resource captures this nuance; the answer does not need to, given the question is Postgres-specific.)

2. **Per-split model — one JDBC connection per table** — VERIFIED. The answer correctly explains that for a non-partitioned PostgreSQL table, the connector creates **one split = one JDBC connection = one worker task = one thread**. This matches the Trino architecture for JDBC connectors ("a good strategy is to simply return a single split for the entire table"). It correctly disambiguates: it is **one connection per table in the query, not one per Trino worker** — a common engineer misconception. The peak-connection formula `concurrent_queries × tables_per_query × 1` is correct for non-partitioned tables on OSS Trino 467 and matches the resource's Section 4.4.

3. **PgBouncer transaction pooling requires `prepareThreshold=0`** — VERIFIED. WebSearch confirms this is the standard, documented workaround (PgBouncer FAQ, Crunchy Data, OpenSourceDB blog, and the pgjdbc issue tracker). The answer correctly explains the mechanism: transaction pooling reuses backends across client connections; pgjdbc's server-side prepared statements survive across statements but not across backend swaps, producing the classic `prepared statement does not exist` failure mode. The answer also correctly notes the failure is **intermittent and shows up days into production** — matching the resource's "day 2 or 3" warning.

4. **`hardConcurrencyLimit` is the correct Trino resource-group property name** — VERIFIED against trino.io's resource-groups docs. The JSON snippet is well-formed. Minor: the selector uses an array form (`"user": [".*"]`) which is acceptable in current Trino versions; some older docs use the string scalar form, but the array form is current.

5. **`ALTER ROLE trino_reader CONNECTION LIMIT 50`** — VERIFIED valid PostgreSQL syntax (postgresql.org docs for ALTER ROLE, consistent across PG 12–18). `-1` is unlimited (default), `0` blocks the role, positive integer caps concurrent connections per role.

6. **Production-stack fit (on-prem k8s)** — The answer correctly recommends running PgBouncer as a Kubernetes Deployment + Service in the same cluster, points the Trino catalog at the in-cluster service DNS (`pgbouncer.app.svc.cluster.local:6432`), and uses environment-variable injection (`${ENV:APP_PG_USER}`) consistent with the on-prem k8s deployment described in `prod_info.md`. No cloud-vendor-specific advice was inserted.

7. **Defense in depth** — Three-layer architecture (PgBouncer pool + Postgres role-level `CONNECTION LIMIT` + Trino resource-group `hardConcurrencyLimit`) plus `statement_timeout` is the production-standard pattern and is exactly what Section 8.2 of the resource recommends. The answer ranks the layers correctly and gives the engineer a runnable starting point for each.

8. **Concrete numbers** — "10 concurrent queries × 4 tables = 40 connections" is the right kind of arithmetic to ground the abstract advice in the engineer's observed `40–50` symptom. The PgBouncer example (`max_client_conn=1000`, `default_pool_size=50`) is realistic and matches industry defaults.

## What was wrong or missing

1. **PgBouncer 1.21+ caveat not mentioned.** The resource (Section 8.2A) explicitly discusses that PgBouncer 1.21+ supports server-side prepared statements in transaction pooling mode if `max_prepared_statements > 0`, in which case `prepareThreshold=0` is optional. The answer states `prepareThreshold=0` is **mandatory** without this nuance. For a brand-new PgBouncer deployment on a modern version, this is overstated — though for **safe-default** purposes the mandatory framing is operationally defensible. Docking a tiny amount on Technical Accuracy for this.

2. **`partition-count` / parallel-splits multiplier not flagged.** The resource warns (Section near `partition-count = 8`) that some Starburst/future-OSS configurations introduce an additional `splits_per_table` multiplier that breaks the simple `× 1` formula. The answer's formula is correct for **OSS Trino 467 today** (the production stack) so this is not an error, but a one-line caveat "if you ever migrate to Starburst or a future OSS version with parallel JDBC splits, multiply by `partition-count` as well" would have made the formula more durable. Minor completeness nit.

3. **No mention of `query.max-execution-time` vs `query.max-run-time` distinction** for queue-time accounting under resource groups. The answer recommends `hardConcurrencyLimit` without warning that queued queries can sit invisibly behind the cap. The resource covers this in Section 8.3; the answer skips it. Not a blocker — the user's question was about connection counts, not query timeouts — but a sentence pointing at it would help.

4. **PgBouncer `pool_mode=transaction` justification is brief.** The answer says "transaction pooling, not session" without explaining why session-pooling defeats the purpose. The resource's "Why not use session-pooling instead?" paragraph would be a useful sentence to include for a beginner audience that doesn't know what the modes differ on.

## Verification notes

- **Trino PostgreSQL connector native pooling**: GitHub issue [trinodb/trino#15888](https://github.com/trinodb/trino/issues/15888) is still open. Starburst Enterprise's `connection-pool.enabled` is documented at https://docs.starburst.io/latest/connector/starburst-postgresql.html. OSS Trino's PostgreSQL connector docs (https://trino.io/docs/current/connector/postgresql.html) do NOT list any `connection-pool.*` properties. The Oracle connector docs (https://trino.io/docs/current/connector/oracle.html) DO document `oracle.connection-pool.enabled` — consistent with the resource's "Oracle is the exception" framing.
- **Per-split model**: Confirmed via Trino connector developer docs ("a good strategy is to simply return a single split for the entire table") and the long-open feature request "Parallel read in jdbc-based connectors" (prestosql/presto#389).
- **PgBouncer + pgjdbc + `prepareThreshold=0`**: Confirmed at https://www.pgbouncer.org/faq.html, Crunchy Data blog "Prepared Statements in Transaction Mode for PgBouncer", and OpenSourceDB's article. PgBouncer 1.21.0 added server-side prepared statement support that changes the requirement when `max_prepared_statements > 0`.
- **`hardConcurrencyLimit`**: Confirmed at https://trino.io/docs/current/admin/resource-groups.html — "required parameter that specifies the maximum number of running queries."
- **`ALTER ROLE … CONNECTION LIMIT`**: Confirmed at https://www.postgresql.org/docs/current/sql-alterrole.html — `-1` is no limit (default).

## Dimension scoring

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five key claims verified against official docs. `prepareThreshold=0` "mandatory" framing is slightly overstated for PgBouncer 1.21+ but operationally safe — not enough to dock a full point. |
| Beginner clarity | 5 | Opens with a bold one-sentence verdict, explains the per-split architecture with concrete arithmetic (10 × 4 = 40 matches engineer's observed number), defines "transaction pooling" by what it does, names every config file path. The engineer can read top-to-bottom without a glossary. |
| Practical applicability | 5 | Five-step "do this now" list at the end, runnable k8s service DNS, runnable `pgbouncer.ini`, runnable Trino catalog file, runnable resource-groups.json, runnable `ALTER ROLE` statements. Engineer can paste-and-tune. |
| Completeness | 4.5 | Hits all sub-questions (pool? no; PgBouncer? yes, here's how; what else? role limit + resource groups + statement_timeout). Misses PgBouncer 1.21 caveat, the `max-execution-time` vs `max-run-time` queue-time distinction, and a one-liner on why session pooling is wrong for this workload. None are blockers; collectively a half-point ding. |

**Average: (5 + 5 + 5 + 4.5) / 4 = 4.875 → rounded to 4.9**

This is well above the federation topic's raised threshold of 4.5 and continues the topic's recovery trajectory (prior avg 4.422 across 152 questions, gap 0.078 to threshold).

## Recommendation for teacher

The resource (`22-trino-federation-postgresql.md`) is already comprehensive on this topic — the answer is essentially a faithful, well-organized summary of Sections 0, 4.4, 8.2A, 8.2B, 8.2C. **No structural resource changes needed.** Two small optional polish items if there is idle teacher capacity:

1. **Promote the "PgBouncer 1.21+ optional prepareThreshold" caveat to a callout block.** Right now it's buried in a multi-paragraph note inside Section 8.2A. If the responder had surfaced this caveat in iter239 Q1, the answer would have scored a clean 5.0. A short "TL;DR if your PgBouncer is ≥ 1.21 AND `max_prepared_statements > 0`, this is optional" callout near the `prepareThreshold=0` example would make it harder to miss.

2. **Add a "Three-layer defense summary table" near the top of Section 8.2** mapping each layer (PgBouncer / Postgres role / Trino resource group / replica `statement_timeout`) to (a) what it caps, (b) where it lives, (c) the one config line to add. The answer effectively reconstructed this table inline — preformatting it would make the next responder more likely to reproduce all four layers consistently.

Neither is required. The answer passes the raised topic threshold cleanly.
