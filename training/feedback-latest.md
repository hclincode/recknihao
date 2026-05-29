# Judge Feedback — Iter 392

**Date**: 2026-05-30
**Phase**: extended
**Overall score**: (4.625 + 4.625) / 2 = **4.625 — STRONG PASS (>= 4.0)**

| Question | Average | Verdict |
|---|---|---|
| Q1 — Iceberg snapshot incremental reads (Spark hourly job) | 4.625 | STRONG PASS |
| Q2 — Multi-tenant row-level security via Trino views | 4.625 | STRONG PASS |

---

## Q1 — Iceberg snapshot incremental reads (Spark hourly job)

**RETRIEVAL FIX LANDED.** After two consecutive honest-punts on this topic in iter390 and iter391, the responder finally surfaced the canonical Spark DataFrameReader pattern. The iter390 teacher patch to resources/13 (adding `start-snapshot-id`/`end-snapshot-id` options) is now discoverable.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Correct DataFrameReader options (`start-snapshot-id`, `end-snapshot-id`); correct `$snapshots` metadata table for current snapshot id; correct four limits (append-only, Spark-only feature, validate snapshot exists, not for streaming). Minor: Trino's `system.table_changes` TVF mentioned as the Trino equivalent — good cross-reference. |
| Beginner clarity | 4.5 | Watermark-and-compare pattern is digestible; the four-limits framing prevents the engineer from misusing the API; QUICK REFERENCE callout helps. |
| Practical applicability | 5.0 | Engineer can write the hourly Spark job immediately: (1) read `$snapshots` for current_snapshot_id, (2) compare to stored watermark, (3) `spark.read.option("start-snapshot-id", X).option("end-snapshot-id", Y).load(table)`, (4) advance watermark on success. |
| Completeness | 4.5 | Covers options, watermark pattern, four limits, cross-reference to Trino. Could add a 5-line code skeleton for the watermark store but not required for the answer to land. |
| **Average** | **4.625** | **STRONG PASS** |

### Why this matters

The iter389-391 incremental-reads gap (three iterations of honest-punt) was the longest unbroken topic miss in recent history. Iter392 closes it. The four-limits framing is particularly strong because it shows the responder understands the API's CONSTRAINTS, not just its surface — this is the difference between an answer that works and an answer that fails silently when the engineer tries to use it on a table with deletes/overwrites.

---

## Q2 — Multi-tenant row-level security via Trino views

Hits the canonical security antipattern (views alone are bypassable because the user can still query the base table directly) and pairs it with the production-stack-correct fix.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Correct: views without base-table deny are bypassable; OPA deny on base table is the right Trino enforcement layer per prod_info.md; SECURITY DEFINER / view definer-mode is the right Trino concept for view privilege elevation; scale guidance (per-tenant views for 1-200, OPA row filters for 1000+) is reasonable. |
| Beginner clarity | 4.5 | Three-defense-layers framing is digestible; concrete scale numbers; verification step (query distinct tenant_ids) is concrete. |
| Practical applicability | 5.0 | Engineer knows exactly: (1) build view with `WHERE tenant_id = current_tenant`, (2) add OPA deny rule on base table, (3) set SECURITY DEFINER on view, (4) test by querying distinct tenant_ids visible to test user. Maps cleanly to prod JWT+OPA stack. |
| Completeness | 4.5 | Covers attack surface, three layers, scale threshold, testing. Minor optional gap: how JWT tenant claim flows into the view's WHERE clause (session property / context var pattern) — savable for a follow-up probe. |
| **Average** | **4.625** | **STRONG PASS** |

### Why this matters

The bypass-via-base-table antipattern is the #1 multi-tenant security failure in SaaS lakehouse setups, and the responder identified it without prompting. The production-stack fit is excellent — OPA is named as the deny layer because prod_info.md says OPA is the Trino authz backend, not because the responder defaulted to a generic answer. SECURITY DEFINER is the right Trino lever (most engineers from a Postgres background assume views are always definer-mode, which Trino doesn't guarantee).

---

## Pattern observation (iter370-392 trajectory)

`4.625 -> 4.375 -> 4.47 -> 3.98 FAIL -> 4.5625 -> 4.75 -> 4.1875 -> 4.4375 -> 4.40625 -> 4.5625 -> 3.25 FAIL -> 4.71875 -> 4.8125 -> 4.78125 -> 4.375 -> 4.094 -> 4.4375 -> 4.4375 -> 4.4375 -> 4.25 -> 3.125 FAIL -> 4.75 PASS -> 4.125 PASS -> 3.9375 FAIL -> 4.625 PASS`

Iter392 recovers from the iter391 FAIL with both questions scoring identically at 4.625. The three-iteration incremental-reads gap (iter389+390+391) is closed. Both topics tested today scored at or above the per-topic average, lifting both topic scores slightly.

---

## Topic score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Iceberg table maintenance | 4.4669 / 53 | 4.4698 / 54 | +0.0029 | PASSED |
| Multi-tenant analytics | 4.4515 / 145 | 4.4527 / 146 | +0.0012 | PASSED |

---

## Teacher actions for iter393

- **LOW**: incremental-reads finally retrievable — monitor next probe (esp. Trino-side `system.table_changes`) to confirm not a one-off
- **LOW**: Q2 multi-tenant was textbook; no immediate teacher action needed
- **OPTIONAL**: small follow-up to resources/13 — add a 5-line Spark code skeleton showing watermark read + range query + watermark advance, to lock in the iter392 retrieval win

## Judge probe targets for iter393

- **(1) HIGH**: Iceberg incremental reads FOURTH angle — "weekly CDC export to downstream Postgres" to force the Trino `system.table_changes` TVF path (today's Q1 was Spark-side; need Trino-side coverage confirmed)
- **(2) MED**: Multi-tenant row-level security SECOND angle — JWT tenant claim extraction in OPA policy (carry context-var pattern; how tenant_id flows from JWT through Trino session to OPA decision)
- **(3) Carry-forward standard backlog**: HMS->Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches fast_forward, bucket sizing, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd angle, fs.cache 3rd angle JMX
