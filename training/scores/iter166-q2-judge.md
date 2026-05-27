# Iter 166 Q2 — Judge Score Report

**Question topic**: Trino federation — cross-catalog CTAS (Postgres + Iceberg → new Iceberg table), single-statement materialization, INSERT INTO across catalogs, HMS commit semantics
**Date**: 2026-05-26 (EXTENDED PHASE)
**Model under test**: weak-ai-responder (Haiku)

---

## Verification against Trino 467 docs

| Claim in answer | Verified? | Notes |
|---|---|---|
| `CREATE TABLE iceberg.analytics.x AS SELECT ... FROM app_pg.public.y JOIN iceberg.analytics.events ...` is a valid single-statement cross-catalog CTAS | YES | Trino supports CTAS where the SELECT spans multiple catalogs; target catalog is determined by the table-qualified name in CREATE TABLE. Confirmed via trino.io/docs CTAS + Iceberg connector docs. |
| `INSERT INTO iceberg.analytics.x SELECT ... FROM app_pg.public.y ...` works the same way | YES | Confirmed. Iceberg connector documents INSERT, CTAS, CREATE OR REPLACE TABLE, INSERT OVERWRITE as supported writes. |
| "Trino handles the entire operation — reads from both catalogs, joins on workers, writes to MinIO" | YES | Cross-catalog joins always execute on Trino workers (no cross-catalog pushdown); the resulting rows are written by the Iceberg connector to the configured object store. Aligns with resources/22 sec. 4. |
| "HMS is required at commit time" | PARTIALLY CORRECT | Iceberg-via-HMS CTAS actually touches the metastore at **both** the start (creates the Iceberg+Hive table entries; table exists empty during execution) and end (atomic metadata-pointer swap on commit). Answer's framing implies HMS is only needed at commit, which is incomplete. |
| "The SELECT part completes but write commit fails if HMS is down" | PARTIALLY CORRECT | The commit-failure direction is right, but if HMS is down at start the CTAS won't even register the empty table, so the query fails before SELECT executes. Answer overstates how far the query progresses before HMS issues surface. |
| Selective WHERE on Postgres side + dynamic filtering | YES | Correct framing — matches resource 22 sec. 5 guidance. |
| Iceberg partitioning examples `day(created_at)`, `tenant_id` | YES | Valid Iceberg partition transforms. |
| Trino writes results as Parquet (default) | YES | Iceberg connector defaults to Parquet. |
| Schedule via Airflow / k8s CronJob | YES | Both are valid orchestration patterns; k8s CronJob fits the on-prem k8s production stack. |

**Missing from answer:**
- Doesn't mention `CREATE OR REPLACE TABLE` as an alternative to drop-and-rebuild for periodic full refreshes (added to Iceberg in recent Trino versions, present in 467).
- Doesn't mention `MATERIALIZED VIEW` as a Trino-native alternative when freshness needs Trino-managed refresh (Iceberg materialized views are supported on the Iceberg connector).
- Doesn't mention OPA authorization on the production stack — a CTAS to an Iceberg schema is a write action that OPA policy can allow/deny.
- Doesn't mention CTAS atomicity: on failure, no partial table is exposed (the empty registered table during execution is invisible to queries — only the commit makes data visible). This is reassuring and worth saying.
- Doesn't mention how this differs from `MATERIALIZED VIEW` (managed refresh) vs CTAS (one-shot materialization).
- Doesn't mention sort order (`WITH (sorted_by = ...)`) for query-time pruning of the new Iceberg table.

---

## Dimension scores

### Technical accuracy: 4.5 / 5
- Core technical claims all verified: cross-catalog CTAS works, cross-catalog INSERT works, Trino handles join + write in one statement, HMS is involved, results land in MinIO as Parquet.
- Minor inaccuracy: HMS framing presents it as "needed at commit time" when it's actually needed at both start (table registration) and commit (pointer swap). The "SELECT completes but commit fails" description is also slightly off — if HMS is down at start, the query fails before SELECT runs.
- Partitioning syntax, dynamic-filtering framing, and Parquet default are all correct.
- No fabricated features (notably does NOT invent any non-existent CTAS option, which was the failure pattern in iter163/164/165).

### Beginner clarity: 5 / 5
- Opens with a direct "Yes" — exactly what the engineer asked.
- Two complete SQL examples (CTAS + INSERT) the engineer can copy-paste.
- "How it works" paragraph is jargon-free and frames Trino as the orchestrator.
- "Compared to your current approach" closing perfectly addresses the engineer's pain point (no recompute on every dashboard refresh).
- Zero unexplained jargon.

### Practical applicability: 5 / 5
- Concrete, runnable SQL with realistic column names and a real WHERE filter.
- Caveats section is actionable: selective WHERE, partitioning decisions, file-size compaction, scheduling.
- Scheduling guidance names two production-realistic options (Airflow, k8s CronJob) — the latter directly fits the on-prem k8s stack.
- The engineer knows exactly what to do next: try the CTAS, decide partitioning, optionally schedule it.

### Completeness: 4 / 5
- Both questions answered: yes single-statement is possible, yes cross-catalog, with example.
- Covers both CTAS and INSERT INTO variants.
- Covers caveats: HMS dependency, selectivity, partitioning, scheduling.
- Missing: MATERIALIZED VIEW alternative (significant — it's the "Trino-managed refresh" option vs the manual CTAS pattern); `CREATE OR REPLACE TABLE` for repeatable full refreshes; OPA write-authorization on the production stack; atomicity reassurance (table only becomes visible on commit).

---

## Weighted score

(4.5 × 2 + 5 + 5 + 4) / 5 = (9 + 5 + 5 + 4) / 5 = 23 / 5 = **4.60 / 5 — PASS**

---

## Key strengths
- Direct, confident "yes" answer matched by working SQL.
- Does not hallucinate any non-existent feature — strong improvement over the iter163/164/165 pattern of confidently asserting "Trino doesn't have X" when it does.
- Correctly identifies that the join executes on Trino workers and the write lands in MinIO.
- "Compared to your current approach" framing directly addresses the engineer's motivating problem.
- Scheduling guidance fits the on-prem k8s stack (CronJob suggestion).

## Key gaps
- HMS commit description is slightly imprecise (HMS is hit at both start and commit, not only at commit).
- No mention of MATERIALIZED VIEW as the managed-refresh alternative — a SaaS engineer building a recurring summary table would benefit from knowing the trade-off.
- No mention of OPA on the production stack (a CTAS is a write action that OPA policy gates).
- No mention of `CREATE OR REPLACE TABLE` for periodic full-refresh patterns.

## Recommended teacher action
- Add a "Cross-catalog CTAS and INSERT" section to `resources/22-trino-federation-postgresql.md` (or a new section under the materialization heading) that covers:
  - CTAS, INSERT INTO, CREATE OR REPLACE TABLE, and MATERIALIZED VIEW as four distinct patterns with trade-offs.
  - HMS commit semantics: register-at-start, commit-with-atomic-pointer-swap-at-end, table invisible during execution.
  - OPA write authorization callout (defense in depth on the production stack).
  - Partitioning + sort-order recommendations when materializing federated results to Iceberg.
