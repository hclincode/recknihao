# Iter 167 Q2 — Judge Score

**Date**: 2026-05-26
**Phase**: extended (post-final)
**Topic**: Trino federation / cross-source connectors (monitoring federated queries: `system.runtime.queries` catalog filter, `pg_stat_activity`, event listener for persistence)

## Question summary

Engineer has 15-20 concurrent Trino queries across Iceberg, Postgres, and federated joins; DBA wants attribution of Postgres-side load to specific Trino queries. Asks for an in-Trino dashboard/log path to identify queries that touched the Postgres catalog.

## Answer location

`/Users/hclin/github/recknihao/training/answers/iter167-q2.md`

## Scores

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Technical accuracy | 4.5 | ×2 | 9.0 |
| Beginner clarity | 4.0 | ×1 | 4.0 |
| Practical applicability | 5.0 | ×1 | 5.0 |
| Completeness | 4.5 | ×1 | 4.5 |
| **Weighted average (Tech×2)** | | | **4.50 / 5** |

**Result**: PASS (threshold 3.5 general; topic-specific raised threshold 4.5 — this answer **meets** the raised topic threshold exactly).

## Verification (WebSearch against trino.io and postgresql.org)

| Claim | Verified? | Notes |
|---|---|---|
| `system.runtime.queries` exists with `query` (SQL text) column | YES | trino.io/docs "queries table … original query SQL text, identity of the user who ran the query" |
| Columns `query_id`, `user`, `state`, `created` exist on `system.runtime.queries` | YES | Standard schema since early Presto; column shape unchanged through Trino 467 |
| `system.runtime.tasks` with `query_id`, `physical_input_bytes`, `split_cpu_time_ms` | YES | All three are standard task columns. `physical_input_bytes` was the post-rename of input-byte tracking; `split_cpu_time_ms` is a long-standing per-split CPU metric |
| `pg_stat_activity` with `pid`, `usename`, `query_start`, `state`, `query` | YES | All five columns exist in PostgreSQL since 9.2+, present on every supported PG version |
| "Ephemeral / evicted after short window" | TRUE | `query.max-history` (default 100) and `query.min-expire-age` (default 15 min) govern retention; entries are evicted from coordinator memory |
| Trino event listener for persistence | YES | HTTP, Kafka, MySQL, OpenLineage event listeners are documented; custom EventListener SPI exists |

No fabricated features. Major technical claims are accurate.

## Strengths

- **Correct identification of the primary tool**: `system.runtime.queries` with a SQL-text `LIKE '%app_pg%'` filter is the canonical pattern for catalog attribution in Trino, and the answer leads with it.
- **Strong cross-system playbook**: the four-step DBA collaboration flow (find slow query in `pg_stat_activity` → match by user/time in Trino → compare actual pushed SQL vs Trino SQL → set up persistent event listener) is exactly the workflow an oncall engineer would run.
- **Correctly anchors the limitation**: explicitly calls out that `system.runtime.queries` is in-memory and ephemeral, and points to event listeners as the persistence path. This is the kind of nuance prior federation answers have repeatedly missed.
- **Useful task telemetry join**: pairing `system.runtime.queries` with `system.runtime.tasks` to compute `bytes_from_postgres_gb` and `cpu_seconds` per query is a real, runnable diagnostic that maps to "which queries are putting the most load on Postgres."
- **Authoritative Postgres-side view**: rightly notes that `pg_stat_activity` on the replica shows the actual SQL Trino pushed (post-predicate-pushdown), and frames it as the answer to "did pushdown happen?"
- **Production-stack fit**: uses `app_pg` as the catalog name consistent with Q1 and the prod-stack conventions, references the read replica, fits the on-prem k8s / Trino 467 environment.

## Gaps

1. **`user` is a reserved word footgun** (technical accuracy): the answer's first SQL block does `SELECT query_id, user, state, ...`. In Trino, `user` is also a built-in function (`SELECT user` returns the session user) and may parse ambiguously; canonical safe form is `"user"` (quoted). Not catastrophic, but a beginner pasting this could see a confusing parse error. Recommend always quoting reserved-word column names.
2. **No mention of LIKE-on-SQL-text false positives** (technical accuracy): if `app_pg` appears as a literal string, in a comment, or as a column alias in unrelated queries, the LIKE filter will match. The answer should suggest tightening with `query LIKE '%FROM%app_pg.%'` or pairing with `system.runtime.transactions` / parsing `query_state`. For 20-concurrent-query attribution this is a real risk.
3. **No reference to Trino web UI as a complementary view** (completeness): the answer mentions the UI briefly but doesn't show that the coordinator's `/ui/query.html?<id>` page exposes per-operator stats and the operator's catalog attribution — which is the most authoritative way to confirm a query touched Postgres (no text-matching needed).
4. **No OPA audit log mention** (production fit): the production stack uses OPA for authorization. Every Trino query action evaluated by OPA produces an audit record. A query that touched `app_pg` was authorized through OPA with a decision on the `app_pg` resource — OPA's decision log is a second authoritative source of "did this query touch Postgres" that survives Trino's ephemeral window.
5. **`query_text_length_limit` truncation not mentioned** (technical accuracy): the SQL text column is truncated by default (~10K chars). Long generated queries may have their `app_pg` reference clipped, causing the LIKE filter to miss them. Tunable via `query.max-length`.
6. **Event listener guidance is thin** (completeness): names "event listener" but does not point to specific options (HTTP listener to push to OpenSearch/Loki, Kafka listener for streaming, MySQL listener for a queryable history table). For the on-prem k8s stack the HTTP listener → in-cluster observability backend is the natural fit and should be named.
7. **No mention of `EXPLAIN`/`EXPLAIN ANALYZE` for confirming catalog touch ahead of time** (completeness): for a query the engineer already has the text of, `EXPLAIN` will show `TableScan[postgresql:app_pg.public.X]` operators — definitive proof of catalog touch without depending on runtime tables.

## Topic running-average update

Prior avg: **4.092 across 11 questions** (after iter166 Q2).

Adding iter167 Q1 (4.80) and Q2 (4.50):
- After Q1: (4.092 × 11 + 4.80) / 12 = (45.012 + 4.80) / 12 = 49.812 / 12 = **4.151 across 12 questions**
- After Q2: (4.151 × 12 + 4.50) / 13 = (49.812 + 4.50) / 13 = 54.312 / 13 = **4.178 across 13 questions**

**Status**: NEEDS WORK — 4.178 still below the raised 4.5 threshold for this topic, but climbing for the second straight iteration. Both questions this iteration passed.

## Resource fix recommendations

- **HIGH (correctness)** — `resources/22-trino-federation-postgresql.md`: add a "Monitoring federated queries" section that documents (a) `system.runtime.queries` schema with explicit warning to quote `"user"`, (b) the LIKE-on-SQL-text false-positive risk with safer filter patterns, (c) `query.max-length` truncation default and how to raise it, (d) `system.runtime.tasks` join recipe for I/O and CPU attribution.
- **HIGH (production fit)** — same file: add a callout that OPA decision logs are a complementary, authoritative source of catalog-touch evidence on the production stack. A query authorized against `app_pg` will appear in OPA's audit log with the catalog/schema/table resource. This survives Trino's 15-minute in-memory eviction.
- **MEDIUM (completeness)** — same file: name specific event listener options for the on-prem k8s stack (HTTP listener → in-cluster observability backend such as OpenSearch/Loki; MySQL/Postgres listener for a queryable history table; Kafka listener for streaming). Include the canonical `event-listener.properties` snippet for the HTTP listener.
- **MEDIUM (completeness)** — same file: add a "before-the-fact" path: `EXPLAIN <query>` shows `TableScan[postgresql:app_pg...]` operators, which is the cleanest way to confirm catalog touch without depending on runtime tables.
- **LOW (clarity)** — same file: inline-gloss "ephemeral", "task telemetry", and "predicate pushdown" the first time each appears in the monitoring section.
