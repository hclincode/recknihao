# Judge Score — Iter 164 Q1

**Topic**: Trino federation / cross-source connectors (PostgreSQL connector tuning, fetch sizes, connection-pool config, performance levers)
**Date**: 2026-05-26
**Phase**: extended (post-final)
**Answer evaluated**: `/Users/hclin/github/recknihao/training/answers/iter164-q1.md`

---

## Verification (WebSearch against trino.io/docs/467 and postgresql.org)

### Claim 1: "OSS Trino 467 has NO native PostgreSQL connection pooling; `connection-pool.*` is Starburst Enterprise only"
**Verdict: CORRECT.** Verified against https://trino.io/docs/467/connector/postgresql.html — only `connection-url`, `connection-user`, `connection-password`, and credential providers are documented. No `connection-pool.*` properties. The OSS-vs-Starburst callout is exactly what iter163's feedback asked for and is durable.

### Claim 2: "Default `dynamic_filtering_wait_timeout` is 2 seconds"
**Verdict: INCORRECT — same factual error flagged in Q2.** Verified against the Trino 467 docs:
- `iceberg.dynamic-filtering.wait-timeout` default is **`1s`** (Iceberg connector config property)
- `dynamic_filtering_wait_timeout` as a **PostgreSQL connector session property** defaults to **`20s`** ("Maximum duration for which Trino waits for dynamic filters to be collected from the build side of joins before starting a JDBC query")
- There is no Trino 467 default of `2s` for any dynamic filtering wait property.

The answer is doubly wrong: (a) the number "2 seconds" matches neither documented default, and (b) the answer doesn't specify *which* connector's timeout it is naming, which conflates two different properties that live in two different catalogs. In a federated query, the relevant one depends on which side is the build side — and the PostgreSQL session property at 20s default is actually quite generous already, so the "raise it" advice may be misleading for a Postgres-as-probe scenario.

### Claim 3: `dynamic_filtering_wait_timeout` session property scope and SET SESSION syntax
The Q1 answer does **not** include an explicit `SET SESSION dynamic_filtering_wait_timeout = '15s'` example (unlike Q2). It just says "Raise `dynamic_filtering_wait_timeout` if your Postgres replica is slow." This means Q1 does **not** reproduce the invalid-bare-form syntax bug verbatim, but the implicit instruction is still ambiguous — a copy-paste-prone engineer is left to guess the catalog prefix. The Iceberg path requires `iceberg.dynamic_filtering_wait_timeout` and the Postgres path requires `<pg_catalog>.dynamic_filtering_wait_timeout`. The answer doesn't disambiguate.

### Claim 4: PgBouncer in transaction-pooling mode as Trino-to-Postgres intermediary
**Verdict: CORRECT, but incomplete.** Verified against pgbouncer.org and JDBC PgBouncer guidance — transaction pooling works for JDBC clients including Trino. **However, the answer omits a critical practical caveat**: Trino's PostgreSQL connector uses JDBC prepared statements, which historically broke under PgBouncer transaction pooling. The JDBC standard fix is to append `?prepareThreshold=0` to the `connection-url` (or use PgBouncer 1.21+ which tracks prepared statements transactionally). An engineer following the answer's example URL `jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb` will hit `prepared statement "S_1" does not exist` errors. This is a meaningful practical gap.

### Claim 5: `ALTER ROLE trino_reader CONNECTION LIMIT 50;`
**Verdict: CORRECT.** Verified against https://www.postgresql.org/docs/current/sql-alterrole.html — valid syntax. `CONNECTION LIMIT` is a documented role attribute. `-1` disables the limit.

### Other claims spot-checked
- `EXPLAIN (TYPE DISTRIBUTED)` and the `ScanFilterProject` vs separate `Filter` node distinction: **correct** per Trino EXPLAIN docs.
- `dynamicFilterSplitsProcessed` as the EXPLAIN ANALYZE field name: **correct** per Trino dynamic-filtering docs.
- `postgresql.experimental.enable-string-pushdown-with-collate=true`: **correct property name** per PostgreSQL connector docs.
- `pg_stat_activity` filtering by `usename`: **correct** PostgreSQL DBA pattern.
- `statement_timeout` as a per-role/per-database Postgres setting: **correct**.

---

## What the question actually asked

The engineer asked specifically about: "config we should be looking at in the Trino catalog setup for Postgres that actually affects query speed? Like are there connection timeout settings, fetch sizes, anything like that — or is slow-via-Trino just the price you pay for federation?"

**What the answer addressed well:**
- The implicit "no, fetch-size and connection-pool tunables don't exist in OSS" framing.
- Where the real levers live (pushdown, dynamic filtering, connection congestion).
- Concrete "what to do right now" 3-step sequence.

**What the answer could have addressed more directly:**
- It never says explicitly "there is no documented `postgresql.fetch-size` or `postgresql.connection-timeout` property in OSS Trino 467, so the catalog file itself has very little speed-tuning surface." That direct denial would have closed the engineer's exact ask.
- It doesn't mention that JDBC-level fetch-size can be passed via `connection-url` parameters (`?defaultRowFetchSize=N`), which IS an actual catalog-level performance lever the engineer was looking for.
- No mention of `join_distribution_type='BROADCAST'` for small-dim × big-fact federated joins (same gap flagged in Q2).
- No mention of `prepareThreshold=0` caveat for PgBouncer transaction pooling (see Claim 4).

---

## Scores (1–5)

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** (×2) | **3.5** | The OSS-vs-Starburst pooling callout, predicate-pushdown advice, EXPLAIN field names, PgBouncer recommendation, `CONNECTION LIMIT`, `statement_timeout`, and `postgresql.experimental.enable-string-pushdown-with-collate` are all correct. **One material factual error**: "default is 2 seconds" for `dynamic_filtering_wait_timeout` is wrong — Iceberg defaults to 1s, the PG session property defaults to 20s, and the answer doesn't disambiguate which connector's timeout. Practical gap: PgBouncer `prepareThreshold=0` caveat is missing. |
| **Beginner clarity** (×1) | **4.5** | Well-structured (lead with reality, then levers, then concrete next steps). Explains pushdown and dynamic filtering at a level a SaaS engineer can grasp. Examples include actual SQL and catalog URLs. Minor friction: assumes the engineer knows what a "read replica" is. |
| **Practical applicability** (×1) | **4.5** | Highly actionable: gives an exact `connection-url`, a runnable `pg_stat_activity` query, the exact `ALTER ROLE` syntax, the right EXPLAIN commands to run, and a 3-step "what to do right now" sequence. Engineer knows exactly what to do next. |
| **Completeness** (×1) | **4.0** | Covers the core well (pushdown, DF, connection congestion). Misses: (a) direct denial that `fetch-size` / `connection-timeout` catalog properties exist; (b) JDBC `defaultRowFetchSize` as an actual catalog-level lever via `connection-url` params; (c) `join_distribution_type='BROADCAST'` for small-dim federated joins; (d) `prepareThreshold=0` caveat for PgBouncer JDBC. |

**Weighted score** = (3.5×2 + 4.5 + 4.5 + 4.0) / 5 = (7.0 + 4.5 + 4.5 + 4.0) / 5 = **20.0 / 5 = 4.00**

**Pass threshold**: 4.5 (topic-specific raised threshold for Trino federation)
**Verdict**: **FAIL** (4.00 < 4.5)

Note: 4.00 is above the *default* 3.5 pass threshold, but the Trino federation topic carries a raised threshold of 4.5 (per rubric line 15) because of the iter158 critical failure. By the default rubric this answer is a pass; by the topic-specific raised bar it falls short.

---

## Comparison to Q2 (same topic, same iteration)

Both Q1 and Q2 reproduce **Error 1** from the resource (default `dynamic_filtering_wait_timeout = 2s`). Q1 does **not** reproduce **Error 2** (invalid bare `SET SESSION` syntax) only because Q1 never gives an explicit SET SESSION example — but the underlying ambiguity (no catalog prefix shown anywhere) is still present. Q1 scores higher than Q2 (4.00 vs 3.40) primarily because:
- Q1's question is more general (catalog config landscape) and the answer's strongest section (OSS-vs-Starburst pooling reality) directly answers the core ask.
- Q1 doesn't surface the SET SESSION bug as visibly because no SET example appears.
- Q1 has a tighter "what to do right now" close, which lifts the practical-applicability score.

The same resource fixes prescribed in the Q2 feedback (correct the `1s` default, add catalog-prefix callout for session properties, add `join_distribution_type`, add `prepareThreshold=0` for PgBouncer JDBC) would fix Q1 as well.

---

## Required resource fix (additional to Q2's list)

5. **MEDIUM (completeness)** — `resources/22-trino-federation-postgresql.md`: add a callout that the OSS PostgreSQL connector does NOT document `fetch-size` or `connection-timeout` catalog properties, but JDBC-level `defaultRowFetchSize=N` (and other PostgreSQL JDBC parameters) CAN be passed via the `connection-url` query string. Show an example: `connection-url=jdbc:postgresql://host:5432/db?defaultRowFetchSize=1000&prepareThreshold=0`. The `prepareThreshold=0` half of that example also handles the PgBouncer transaction-pooling gap.
