# Score: iter235-q2 — PostgreSQL vs MySQL Connector Differences

**Score: 3.85 / 5.0**

## What was correct

1. **MySQL VARCHAR pushdown failure** — Correctly stated that MySQL connector does NOT push down ANY predicates on CHAR/VARCHAR columns (including equality, range, LIKE, IN-list, IS NULL/IS NOT NULL), and that the root cause is case-insensitive collation semantics. Verified against trino.io/docs/current/connector/mysql.html.
2. **PostgreSQL string equality pushdown** — Correctly stated that PostgreSQL pushes down equality (=, IN, !=) on VARCHAR. Verified against trino.io/docs/current/connector/postgresql.html.
3. **PostgreSQL VARCHAR range limitation** — The answer claims `created_at > TIMESTAMP '...'` pushes; range on VARCHAR is correctly omitted (the answer wisely doesn't claim VARCHAR range pushes by default). Range on VARCHAR is gated behind the experimental `enable-string-pushdown-with-collate` flag, which the answer doesn't claim works by default — good.
4. **Parallelism limitation correct** — Neither connector creates multiple splits per scan in OSS Trino 467; trinodb/trino#389 is the open issue. `partitionColumn`/`numPartitions` are Spark/Starburst patterns and do not exist in OSS Trino's JDBC connectors. Recommendation to ingest into Iceberg + use dynamic filtering on Iceberg side is the right architectural answer for production.
5. **UPDATE constant-assignment limitation** — Correct for both connectors; arithmetic and expression assignments (e.g., `balance + 100`) are rejected by the JDBC connector framework.
6. **MySQL MERGE flag** — Correct that MySQL MERGE requires `merge.non-transactional-merge.enabled=true` (catalog) / `non_transactional_merge_enabled` (session). Verified against PR #24428 and current MySQL connector docs.
7. **MySQL INSERT non-transactional flag** — Correct property name `insert.non-transactional-insert.enabled` and session form `non_transactional_insert`. Verified.
8. **socketTimeout unit mismatch** — Verified: MySQL Connector/J uses milliseconds, PostgreSQL JDBC uses seconds. This is a real and dangerous trap and is well-flagged.
9. **MySQL fetch size requires both `defaultFetchSize` AND `useCursorFetch=true`** — Verified against MySQL Connector/J docs; without `useCursorFetch=true`, `defaultFetchSize` is silently ignored and the driver streams the entire result into client memory.
10. **DELETE pushdown gating** — Correct: DELETE only works on JDBC connectors when the WHERE pushes down. MySQL DELETE WHERE on a VARCHAR column will fail at planning time.
11. **Dynamic filter wait-timeout numbers** — Correct: 20s default for JDBC dynamic filtering, 1s default for Iceberg (this matches the rubric-documented correction made in iter164 Q2).

## What was wrong or missing

1. **CRITICAL — PostgreSQL MERGE claim is incorrect for production**. The answer says "PostgreSQL: supported by default — transactional, safe." This is wrong on two counts:
   - **MERGE support for the PostgreSQL connector was first added in Trino 470** (Feb 2025) per PR #24467 — it does NOT exist at all in the production environment's **Trino 467**. A user issuing `MERGE INTO postgres_catalog.tbl ...` in Trino 467 will get an unsupported-operation error.
   - Even in current Trino (475+), PostgreSQL MERGE requires the same `merge.non-transactional-merge.enabled=true` flag as MySQL by default. Transactional MERGE was added later (PR #24467 is named "Support transactional MERGE for Postgresql connector"). The answer's "transactional, safe, no flag needed" framing is misleading.
   - This is a meaningful failure on practical applicability given the production stack is pinned to Trino 467.

2. **PostgreSQL LIKE pushdown claim is overstated**. The answer says "Simple LIKE patterns: `WHERE name LIKE 'foo%'` — pushes down by default in Trino 467." LIKE pushdown for PostgreSQL was added (PR #11045) but it is gated by the JDBC complex-function pushdown machinery and behaves more conservatively than the answer implies (e.g., it depends on column collation; ICU/non-default collation prevents pushdown). The blanket "pushes down by default" framing is too strong.

3. **"IS NULL / IS NOT NULL on text columns — NO, these are considered textual predicates and stay in Trino"** for MySQL. The docs say "any predicates on columns with textual types" are not pushed — this technically includes IS NULL. However, this claim is more nuanced than it appears (IS NULL is not a value comparison, so the collation rationale doesn't really apply), and Trino has at times allowed `IS NULL` pushdown on textual columns. The answer states this confidently without a citation. Low impact, but a small accuracy risk.

4. **"trinodb/trino#389 since 2019"** — The issue number and topic (parallel JDBC reads) are correct. Minor: a closer phrasing would be "tracked as a long-standing feature request" — calling it a "hard limitation" tracked since 2019 is accurate enough.

5. **`metadata.cache-ttl` default** — The answer says default is `0s` (disabled). For Trino JDBC connectors the actual default for `metadata.cache-ttl` is 0 (disabled), so the claim is fine. Slightly worth noting that some JDBC sub-properties (`statistics.cache-ttl`) inherit the metadata setting — not load-bearing for this answer.

6. **No mention of Trino 467 production version** in any caveats. Given the production environment is pinned to Trino 467, the answer should have flagged PG MERGE as not-yet-available and any "by default in 467" claim should have been double-checked.

7. **"PgBouncer / ProxySQL" pooling advice is fine conceptually**, but the answer should call out that ProxySQL on bare-metal/k8s adds operational overhead; not a correctness issue.

## Verification notes

- **MySQL VARCHAR pushdown**: Verified via https://trino.io/docs/current/connector/mysql.html — "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR."
- **PostgreSQL VARCHAR pushdown**: Verified via https://trino.io/docs/current/connector/postgresql.html — equality/inequality pushed, range NOT pushed (experimental flag exists).
- **MySQL MERGE flag**: Verified via PR #24428 — `merge.non-transactional-merge.enabled` required.
- **PostgreSQL MERGE**: Verified via PR #24467 and release notes for Trino 470 (Feb 2025) — MERGE for PG connector was added in 470, transactional MERGE added later. **Not available in Trino 467.**
- **socketTimeout units**: Verified MySQL Connector/J docs and PostgreSQL JDBC docs — milliseconds vs seconds confirmed.
- **defaultFetchSize + useCursorFetch**: Verified via MySQL Connector/J performance docs — both required for cursor-based fetching.
- **Parallel reads**: Verified via trinodb/trino#389 — open issue, no native support; partitionColumn is a Spark/Starburst concept.
- **UPDATE constant-only**: Verified across multiple JDBC connector docs.

## Recommendation for teacher

1. **HIGH (correctness)** — Update `resources/22-trino-federation-postgresql.md` (or equivalent) to make the MERGE support matrix explicit by Trino version:
   - Trino 467: PostgreSQL MERGE NOT supported. MySQL MERGE supported with `merge.non-transactional-merge.enabled=true`.
   - Trino 470+: PostgreSQL MERGE supported with the same non-transactional flag.
   - Trino 475+: Transactional MERGE for PostgreSQL via PR #24467.
   The current resource (or the teacher's model of it) appears to allow the responder to claim PG MERGE is "supported by default" which is doubly wrong for production.

2. **MEDIUM (precision)** — Tighten the LIKE pushdown claim for PostgreSQL: note that LIKE pushdown is supported but collation-dependent. Avoid the blanket "pushes by default" phrasing.

3. **MEDIUM (production fit)** — Add a "Trino 467 caveats" callout to the federation resource listing features added after 467 (PG MERGE, transactional MERGE, etc.) so the responder knows to flag them as unavailable in production.

4. **LOW** — Add an `IS NULL` pushdown note for MySQL VARCHAR columns with a citation; current claim is plausible but uncited.
