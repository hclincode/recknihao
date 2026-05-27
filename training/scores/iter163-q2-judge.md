# Iter 163 Q2 — Judge Report

## Question
"We're querying our Postgres production database directly from Trino for some of our customer-facing analytics... Is there a way to tell Trino to limit how many connections it makes to a specific Postgres database, and if so, where does that configuration live — is it something we set per query or is it a server-level setting?"

## Answer file
/Users/hclin/github/recknihao/training/answers/iter163-q2.md

---

## Verification via WebSearch + WebFetch

### 1. Are `connection-pool.enabled`, `connection-pool.max-size`, `connection-pool.max-connection-lifetime` valid properties in **open-source Trino 467**?

**NO.** This is a major factual error.

- The official Trino PostgreSQL connector documentation (`https://trino.io/docs/current/connector/postgresql.html` and `https://trino.io/docs/467/connector/postgresql.html`) does **not** document any connection pool properties. The connector simply does not expose pool configuration in OSS Trino.
- GitHub issue [#15888 ("Enable connection pooling for Postgresql")](https://github.com/trinodb/trino/issues/15888), opened January 2023, is still an **open feature request** for OSS Trino. It has not been implemented.
- The properties `connection-pool.enabled`, `connection-pool.max-size`, `connection-pool.max-connection-lifetime` (with defaults of `false`, `10`, and `30m`) ARE documented — but in the **Starburst Enterprise PostgreSQL connector** (`docs.starburst.io/latest/connector/postgresql.html`), which is a commercial product, not OSS Trino 467.
- The OSS Trino connector that DOES support connection pooling is the **Oracle** connector, and it uses the `oracle.connection-pool.*` prefix (e.g., `oracle.connection-pool.enabled`, `oracle.connection-pool.max-size`), not the unprefixed form.

**Impact**: An engineer who copies the answer's three properties into a Trino 467 catalog file will see Trino silently ignore them — Trino will continue to open unbounded JDBC connections to Postgres exactly as before, and the Postgres team's complaint will not be resolved.

### 2. Is the "per-worker" claim correct?

Partially defensible in concept (per-node pools exist for Starburst), but moot for OSS Trino 467 where no pool exists. The arithmetic example (20 workers × 10 = 200) is only true in Starburst, not in the user's stack.

### 3. Is the "use dots not hyphens" gotcha accurate?

Misleading. The answer warns against `postgresql.connection-pool-max-size` (hyphen inside the suffix) and tells the user the correct form is `connection-pool.max-size`. Two problems:
- For OSS Trino 467 PostgreSQL, **neither** form exists.
- For Oracle (and other JDBC connectors that DO have pool support), the correct form is `oracle.connection-pool.max-size` — i.e., it DOES use the connector prefix. So the "no prefix" advice would also be wrong if applied by analogy to Oracle.

### 4. Catalog properties file location (`etc/catalog/app_pg.properties`)

Correct in concept. ConfigMap-mounted catalog properties files are the right place for static catalog settings on the on-prem Kubernetes Trino 467 stack.

### 5. `pg_stat_activity` monitoring

Correct. `SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';` is a standard and accurate way to monitor connection counts from the Postgres side.

### 6. "Always use a read replica, never the OLTP primary"

Correct and standard advice. The point about `statement_timeout` on the replica is also good practice.

### 7. The "ingest into Iceberg if you need more flexibility" closing note

Correct and well-aligned with the production stack (Iceberg via Spark/HMS is the documented ingestion path).

---

## Production environment fit (prod_info.md)

The stack is **Trino 467 (OSS) on on-prem Kubernetes**, NOT Starburst Enterprise. The advice given is therefore not directly applicable. The engineer would need either:
- Upgrade to Starburst Enterprise (commercial), OR
- Put a connection pooler (e.g., PgBouncer) in front of Postgres at the infrastructure layer, OR
- Reduce concurrency from the Trino side via resource groups / session concurrency limits (not the same as a JDBC pool, but caps query-level pressure).

None of these alternatives are mentioned in the answer.

---

## Scores (1-5)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy (weight 2) | **2** | Core technical claim (the three `connection-pool.*` properties exist in Trino 467 OSS) is wrong; these are Starburst Enterprise properties. The "per-worker" arithmetic is therefore inapplicable. Peripheral facts (catalog file location, `pg_stat_activity`, read-replica advice, `statement_timeout`) are correct. The "dots vs hyphens" gotcha is misleading. |
| Beginner clarity (weight 1) | **4** | Clear structure, jargon explained, good worked example. Easy to read for a SaaS engineer. |
| Practical applicability (weight 1) | **2** | An engineer following this answer will set properties that Trino 467 silently ignores. No mention of PgBouncer, resource groups, session concurrency, or that OSS Trino PostgreSQL does not have native JDBC pooling — all of which would have been the correct actionable guidance for this stack. |
| Completeness (weight 1) | **3** | Addresses "per query vs server-level" directly and discusses monitoring + sizing + rollout. Missing the critical fact that the feature does not exist in OSS Trino; missing alternative mitigations. |

**Weighted average**: (2×2 + 4 + 2 + 3) / 5 = **2.6**

**Pass threshold**: 3.5. **Result: FAIL.**

---

## Key issues to feed back to teacher

1. **Hallucinated feature**: The resources are teaching weak-ai-responder to recommend a Starburst-only feature as if it were OSS Trino. Resources `22-trino-federation-postgresql.md` (and any related) need an explicit callout: **OSS Trino 467 PostgreSQL connector does NOT support JDBC connection pooling** ([GitHub #15888 still open](https://github.com/trinodb/trino/issues/15888)).
2. **Correct mitigations for the on-prem k8s + OSS Trino stack**:
   - Run **PgBouncer** in front of Postgres (transaction-pooling mode is typical) — this is the standard fix for "Trino opens too many Postgres connections."
   - Use **Trino resource groups** to cap concurrent queries against the catalog (reduces upstream JDBC pressure).
   - Tune **`statement_timeout`** on the Postgres replica and connection limits at the Postgres role level (`ALTER ROLE trino_reader CONNECTION LIMIT 50;`).
3. **Connector-prefix rule**: When a Trino JDBC connector DOES expose pool properties (Oracle, SQL Server in some forks), the prefix matches the connector name (e.g., `oracle.connection-pool.max-size`). The teacher should not generalize "no prefix" as the rule.

## Sources

- [Trino 467 PostgreSQL connector docs](https://trino.io/docs/467/connector/postgresql.html)
- [Trino current PostgreSQL connector docs](https://trino.io/docs/current/connector/postgresql.html)
- [Trino Oracle connector docs](https://trino.io/docs/current/connector/oracle.html)
- [GitHub Issue #15888 — Enable connection pooling for Postgresql (still open)](https://github.com/trinodb/trino/issues/15888)
- [Starburst Enterprise PostgreSQL connector docs](https://docs.starburst.io/latest/connector/postgresql.html)
