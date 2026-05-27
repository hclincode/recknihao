# Judge Score — Iter 165 Q2

**Topic**: Trino federation / cross-source connectors (Postgres schema change — column rename, Trino schema refresh behavior, view updates, migration coordination)
**Date**: 2026-05-26
**Phase**: extended (post-final)
**Answer evaluated**: `/Users/hclin/github/recknihao/training/answers/iter165-q2.md`

---

## Verification (WebSearch against trino.io/docs/467/connector/postgresql.html and postgresql.org)

### Claim 1: "Trino PostgreSQL connector reads schema fresh from Postgres via JDBC at query-plan time; no schema cache; no REFRESH SCHEMA command is needed"

**Verdict: INCORRECT — this is a material factual error.**

Verified against https://trino.io/docs/467/connector/postgresql.html:

- The PostgreSQL connector **does** support metadata caching via the catalog config property `metadata.cache-ttl`. The default is `0s` (caching disabled), but the property exists and is commonly enabled in production for high-QPS environments to reduce JDBC metadata roundtrips.
- The connector **does** expose a `system.flush_metadata_cache()` procedure (added in Trino release 369, present in 467). Usage:
  ```sql
  USE app_pg.public;
  CALL system.flush_metadata_cache();
  ```
- There is also `metadata.cache-missing` for negative caching.

The answer's flat claim "no schema cache" and "there isn't one needed" is doubly wrong: (a) the cache exists, and (b) a remediation procedure exists. While the default-off setting makes the answer accidentally correct for the most common production case, an engineer whose admin has enabled `metadata.cache-ttl` (e.g., `60s` or `5m`) would be misled into thinking the cache is impossible and waste debugging time. The right answer is: "By default the cache is off, so a rename is visible immediately. If your catalog sets `metadata.cache-ttl > 0`, you can wait for the TTL or call `CALL system.flush_metadata_cache()`."

This is the same class of authoritative-but-wrong claim that the iter163 critical fix tried to eliminate for `connection-pool.*` — the resource still has gaps about what the PostgreSQL connector actually supports.

### Claim 2: "Inconsistency is because different queries reference different columns by name"

**Verdict: CORRECT.** Logical and matches Trino's per-query metadata fetch behavior (when cache is off). Queries that name the dropped column fail; queries that don't reference it succeed. This is the right diagnostic story.

### Claim 3: `CREATE OR REPLACE VIEW myview AS ...`

**Verdict: CORRECT.** Verified against https://trino.io/docs/467/sql/create-view.html: syntax is `CREATE [ OR REPLACE ] VIEW view_name [ COMMENT view_comment ] [ SECURITY { DEFINER | INVOKER } ] AS query`. Trino 467 supports `OR REPLACE`. The example provided is valid.

### Claim 4: `SELECT * FROM information_schema.views WHERE view_definition LIKE '%old_column_name%'`

**Verdict: CORRECT in principle.** Trino exposes the standard SQL `information_schema.views` table with a `view_definition` column, per the ISO SQL standard. The query as written will scan the *current* catalog's views; for a cross-catalog search the engineer would need to iterate per catalog (e.g., `SELECT * FROM iceberg.information_schema.views WHERE ...`) since `information_schema` is per-catalog in Trino. A minor clarity nit: the answer doesn't tell the engineer they must run this per catalog.

### Claim 5: `ALTER TABLE accounts ADD COLUMN old_column_name TEXT GENERATED ALWAYS AS (new_column_name) STORED;`

**Verdict: CORRECT.** Verified against https://www.postgresql.org/docs/current/ddl-generated-columns.html: PostgreSQL generated columns can reference other (non-generated) columns using immutable expressions. A bare column reference (`new_column_name`) is an immutable expression. The `STORED` keyword is required (PostgreSQL only supports STORED generated columns through PG18). The shim is a valid approach and a nice practical touch.

One small caveat the answer doesn't mention: the new generated column will trigger a table rewrite (it's STORED), which on a large table can be a multi-minute lock window. For a small `accounts` table that's fine, but on a 100M-row table the engineer should know this is not a no-op.

### Claim 6: Read replica / replication lag guidance

**Verdict: CORRECT and useful.** The `now() - pg_last_xact_replay_timestamp()` query is valid PostgreSQL. The framing (point Trino at a dedicated replica; check lag before assuming a DDL is visible) is solid production advice. A column rename via `ALTER TABLE` does replicate through logical/streaming replication, so this is genuinely relevant.

### Claim 7: "Avoid `SELECT *`"

**Verdict: CORRECT, but slightly off-target for the column-rename scenario.** `SELECT *` is generally bad practice in analytical queries, but for the *specific* problem (renamed column), `SELECT *` actually *protects* the query because the column list is resolved fresh at each query — it would just return the new column name. The answer's framing ("doesn't break the query but may silently change schema seen by downstream consumers") is technically right but reads as if `SELECT *` is the cause of the problem, which it's not.

---

## Production-environment fit

- The production stack uses Trino 467 + Iceberg + MinIO + Hive Metastore (for the lakehouse side) and Postgres via JDBC (for the federated side). The answer is well-grounded in this environment.
- Recommends a read replica — appropriate for the on-prem K8s stack.
- The generated-column shim assumes the engineer has DDL access to the source Postgres, which is realistic for a SaaS team coordinating with their backend team.
- No fictional cloud-managed services or vendor-specific features invoked.

---

## Dimensional scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy (×2) | 3 | Central claim "no schema cache, no refresh needed" is materially wrong — `metadata.cache-ttl` config property exists (default `0s`) and `system.flush_metadata_cache()` procedure exists. All other technical claims (CREATE OR REPLACE VIEW, information_schema.views, GENERATED ALWAYS shim, replication lag query) check out. |
| Beginner clarity | 5 | Well-structured H2 sections, plain English, contextualizes the inconsistency clearly, all SQL examples are commented. No unexplained jargon. |
| Practical applicability | 3 | Strong runbook for migration coordination (search BI tools, search views, atomic deploy, generated-column shim). Replication lag check is real-world useful. But the missing `metadata.cache-ttl` / `flush_metadata_cache` knowledge means an engineer in a hardened production environment cannot resolve the actual symptom. |
| Completeness | 3 | Hits inconsistency root cause, view recreation, migration playbook, read-replica guidance. Misses metadata-cache discussion entirely; misses per-catalog scope of `information_schema.views`; misses the STORED-rewrite caveat on the generated-column shim. |

**Weighted score** = (3×2 + 5 + 3 + 3) / 5 = 17 / 5 = **3.40 / 5**

**Result: FAIL** (below 3.5 default threshold; well below 4.5 raised threshold for Trino federation topic).

---

## Key findings

1. **Critical resource gap**: `resources/22-trino-federation-postgresql.md` does not mention `metadata.cache-ttl`, `metadata.cache-missing`, or the `system.flush_metadata_cache()` procedure anywhere. The weak responder is repeating the same pattern as the iter163 `connection-pool.*` failure — confidently asserting "Trino doesn't have X" when it actually does.
2. The answer's structure and tone are good — it would be persuasive to an engineer, which makes the factual error more dangerous, not less.
3. The PostgreSQL-side advice (GENERATED ALWAYS shim, replication lag check) is solid production knowledge that should be preserved in any rewrite.

---

## Resource fix recommendations

- **HIGH (correctness)** — `resources/22-trino-federation-postgresql.md`: add a new section titled "Schema cache and metadata refresh on the PostgreSQL connector" that documents:
  - `metadata.cache-ttl` catalog config property — default `0s` (disabled), commonly raised to `60s`–`5m` in high-QPS production environments to reduce JDBC roundtrips.
  - `metadata.cache-missing` catalog config property — caches negative lookups so dropped tables don't keep re-hitting Postgres.
  - The `system.flush_metadata_cache()` procedure — how to invoke it after a Postgres DDL change. Show both the all-schemas form and the per-schema form.
  - When-to-use guidance: "If the default `0s` is kept, a Postgres column rename is visible to the next Trino query; if `metadata.cache-ttl > 0`, wait for TTL or call `flush_metadata_cache()`."
- **MEDIUM (correctness)** — `resources/22`: add a "handling source DDL changes" runbook that includes (a) check `metadata.cache-ttl` setting, (b) check Trino views for old column references with `information_schema.views`, (c) call out that `information_schema.views` is *per-catalog* in Trino (must be qualified or run per catalog), (d) coordinate Postgres rename + Trino view update + downstream BI query update as a single atomic deployment.
- **MEDIUM (completeness)** — `resources/22`: add a "generated-column compatibility shim" example for safe Postgres column renames, with the STORED-rewrite caveat (table rewrite triggers a multi-minute lock on large tables; consider VIEW-based compatibility instead for big tables).
- **LOW (clarity)** — `resources/22`: when discussing `SELECT *` against federated tables, distinguish "good for tolerating renames" vs "bad for stable downstream schema" — these are two different concerns.

---

## Sources verified

- [PostgreSQL connector — Trino 467 Documentation](https://trino.io/docs/467/connector/postgresql.html)
- [CREATE VIEW — Trino documentation](https://trino.io/docs/current/sql/create-view.html)
- [PostgreSQL 18: 5.4. Generated Columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html)
- [Release 369 (24 Jan 2022) — flush_metadata_cache procedure added](https://trino.io/docs/current/release/release-369.html)
- [Release 328 (10 Jan 2020) — metadata caching added to PostgreSQL connector](https://trino.io/docs/current/release/release-328.html)
