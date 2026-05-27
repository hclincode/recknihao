# Iter 167 Q1 — Judge Score Report

**Date**: 2026-05-26 (EXTENDED PHASE)
**Topic**: Trino federation — two separate Postgres catalogs (catalog isolation, no shared connection pool, PgBouncer per catalog)
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter167-q1.md`

---

## Question recap

SaaS engineer asks whether they can point two Trino catalog files at two different Postgres hosts (main app DB + 3rd-party metrics DB) without a shared connection pool causing interference, and what the catalog files would look like in practice.

---

## Verification (WebSearch)

| Claim | Verified | Source |
|---|---|---|
| Separate `.properties` file per Postgres DB is the standard pattern | YES | Trino PostgreSQL connector docs — connector can only access a single DB per instance; must configure multiple connector instances for multiple DBs/servers |
| `connector.name=postgresql` | YES | Trino 467 docs |
| `metadata.cache-ttl`, `metadata.cache-missing` are valid PostgreSQL connector properties | YES | Trino docs (added in release 369, Jan 2022; still present in 467/475/481) |
| `defaultRowFetchSize`, `socketTimeout`, `connectTimeout` as pgjdbc URL params | YES | pgjdbc docs (PGProperty); socketTimeout/connectTimeout in seconds |
| `prepareThreshold=0` for pgjdbc behind PgBouncer transaction-pooling mode | YES | Standard pgjdbc + PgBouncer workaround; disables named prepared statements to avoid "prepared statement already exists" cross-session collisions |
| OSS Trino 467 PostgreSQL connector has no native JDBC connection pool; `connection-pool.*` is Starburst-only | YES | Starburst docs document `connection-pool.enabled` as a SEP-only catalog property; OSS Trino docs do not list it |

No factual errors detected.

---

## Scoring

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy (×2) | 5 | Every technical claim verifies against Trino 467 docs and pgjdbc docs. The OSS-vs-Starburst connection-pool distinction is stated correctly and explicitly — this has been a recurring trip-up in earlier iterations and is handled cleanly here. PgBouncer `prepareThreshold=0` guidance is precise. ConfigMap mount + pod restart is the correct on-prem k8s workflow for new catalogs in Trino 467. |
| Beginner clarity (×1) | 4 | Clear structure with headers; directly addresses the "shared pool" worry from the question in plain language ("Each catalog in Trino is completely independent"). Some terms (transaction pooling, resource groups, JDBC, `prepareThreshold`) are used without short definitions — a complete beginner won't know *why* `prepareThreshold=0` matters with PgBouncer transaction mode. The answer still reads well overall. |
| Practical applicability (×1) | 5 | Two complete catalog file examples, env-var secret pattern, k8s ConfigMap + restart instruction, verification SQL (`SHOW CATALOGS`, `SHOW TABLES`), a runnable join example, and a separate per-catalog PgBouncer URL example. An engineer can copy-paste and adapt with no further research. The per-catalog PgBouncer split directly answers the "do they share a pool" worry. |
| Completeness (×1) | 4 | Covers: catalog isolation, file layout, secrets, k8s deploy step, PgBouncer (with the right caveat), Postgres role connection limit, resource groups (mentioned), read-replica warning, runnable join. Missing/light: (1) no mention of OPA-side write-deny on these read-only Postgres catalogs (production stack), (2) no mention of JWT auth on the Trino side, (3) no discussion of predicate pushdown across federated joins (would help the engineer reason about join performance), (4) no mention of `case-insensitive-name-matching` or schema-visibility settings — minor but commonly hit. |

**Weighted score** = (5×2 + 4 + 5 + 4) / 5 = 23 / 5 = **4.60 / 5**

**Result**: PASS (≥3.5 threshold; also ≥4.5 raised threshold for the Trino federation topic).

---

## Notes for teacher (not feedback to deliver yet — Q2 judge will consolidate)

Strengths to preserve:
- Crisp, correct OSS-vs-Starburst connection-pool boundary statement.
- Concrete PgBouncer `prepareThreshold=0` snippet with separate per-catalog instances.
- Explicit ConfigMap + pod-restart instruction matches the on-prem k8s prod stack.
- Read-replica advisory is the right operational guardrail.

Gaps worth tightening in a future iteration:
- One sentence per "what is transaction pooling" and "what does `prepareThreshold=0` actually do" would lift clarity to 5.
- A short sentence noting that on this stack, write protection on Postgres catalogs is enforced via OPA (and that Trino auth is JWT) would tie the answer to the prod environment cleanly.
- A brief note on predicate pushdown / dynamic filtering behavior across two JDBC catalogs would round out completeness for federated joins.

---

## Topic average update

- Trino federation / cross-source connectors prior: 4.092 across 11 questions.
- New: (4.092 × 11 + 4.60) / 12 = (45.012 + 4.60) / 12 = 49.612 / 12 = **4.134 across 12 questions**.
- Status: NEEDS WORK (4.134 < 4.5 raised threshold). Trending up but recovery from earlier failures is gradual; sustained ≥4.5 needed.
