# Judge Feedback — Iter 312

Date: 2026-05-27
Phase: extended
Topics: OPA row-filter alternative to per-tenant views at 200+ tenant scale (Q1) + pg_replication_slots safe_wal_size and restart_lsn vs confirmed_flush_lsn (Q2)

---

## Q1 — OPA row-filter alternative to per-tenant views at 200+ tenant scale

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | OPA row-filter mode is real and correctly described. `opa.policy.row-filters-uri` is the exact property name. Rego rule name `rowFilters` is correct. Minor imprecision: answer says OPA "intercepts the query and rewrites it" — technically Trino's planner injects the returned WHERE expression; OPA returns it. The endpoint path `/v1/data/trino/rowFilters` is plausible but exact data path depends on the policy package name. |
| Beginner clarity | 4.5 | Plain-language opening, "ONE table + ONE policy" contrast, concrete WHERE clause injection example, clean threshold table. No unexplained jargon — even "Rego" is given context. |
| Practical applicability | 4.0 | Threshold table (1–50/50–200/200+/500+) is actionable. Migration steps concrete (5-step parallel cutover with CI verification). Correctly defers OPA Rego syntax to external governance doc per prod_info.md. Weakness: principal-to-tenant mapping mentioned twice (JWT username vs OPA data bundle) but no guidance on which is preferred in their JWT-based auth stack. |
| Completeness | 4.5 | Covers: why view-per-tenant breaks at scale, OPA row-filter mechanism, config property, thresholds, security verification (CI test), migration path with parallel run. Missing: columnMask as sibling OPA capability for column-level hiding; no Trino version note (row-filter mode requires Trino 438+); mapping strategy not chosen. |
| **Average** | **4.375** | **PASS** |

### What Worked
- Frames problem correctly: management overhead, not query performance — right reframing for a SaaS engineer
- Concrete `opa.policy.row-filters-uri` property name matches official Trino docs
- Threshold table with "stable schema vs schema-changing weekly" tiebreaker is practical, not arbitrary
- Correctly defers specific Rego syntax to external governance document
- Parallel-run migration with CI verification is a mature pattern avoiding hard cutover
- Security CI test (`SELECT DISTINCT tenant_id FROM analytics.events`) is a one-liner the engineer can paste into a test

### What Missed
- **OPA does not "rewrite" SQL** — OPA returns a WHERE expression and Trino's planner injects it. An engineer debugging the system will find these filters in Trino's query plan, not in OPA logs.
- No mention of `columnMask` as the sibling OPA capability for column-level masking (e.g., hiding PII columns for certain tenant principals)
- No Trino version note: OPA row-filter mode was added in Trino 438; at Trino 467 this works, but worth knowing for engineers on older clusters
- Mapping strategy not chosen: given the prod stack has a custom JWT authenticator, the JWT-claim approach is more idiomatic than a separate OPA data bundle — should recommend one
- No concrete Rego example fragment (even a stub showing `input.action.resource.table.tableName → tenant_id = input.context.identity.user`) to help visualize

### Technical Accuracy
Verified against trino.io OPA access control docs:
- `opa.policy.row-filters-uri` exact property name: confirmed
- OPA returns `{"expression": "clause"}` objects which Trino ANDs into the query plan: confirmed
- Rego rule name `rowFilters`: confirmed in official Trino OPA example

### Rubric Update
- Multi-tenant analytics: prior avg 4.471 across 111 questions → (4.471 × 111 + 4.375) / 112 = **4.470 across 112 questions**. Status: PASSED.

---

## Q2 — pg_replication_slots: safe_wal_size and restart_lsn vs confirmed_flush_lsn

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `safe_wal_size` correctly identified as PG 13+, defined as bytes until slot is at risk. `restart_lsn` correctly framed as slot-survival anchor pinned by long-running transactions; `confirmed_flush_lsn` correctly as consumer-acknowledged position. NULL semantics (lost slot OR max_slot_wal_keep_size = -1) verified. Negative-value semantics correct. `wal_status` values match docs. `invalidation_reason` values wal_removed/wal_level_insufficient/rows_removed all confirmed (PG 16). Heartbeat root cause framing correct. Minor: PG 16+ also added `idle_timeout` as a fourth invalidation_reason value — not a scoring deduction as the three named cover all common Debezium scenarios. |
| Beginner clarity | 5.0 | "Debezium's bookmark in Postgres's WAL" analogy is excellent. Explicitly explains why the two LSNs diverge with concrete consequence ("can underestimate the real risk by tens of gigabytes"). Each column in the monitoring query read in priority order with bolded headings. No assumed OLAP knowledge. |
| Practical applicability | 5.0 | Drop-in monitoring SQL parameterized by slot_name. Concrete alert thresholds (50 GB warning / 10 GB critical) with specific actions. Includes max_slot_wal_keep_size safety-net config, recovery runbook, and heartbeat config block. Engineer can ship this today. |
| Completeness | 5.0 | Answers Q1 (yes, safe_wal_size is real, PG 13+, direct headroom). Answers Q2 (use restart_lsn for slot-survival alerts; confirmed_flush_lsn only for consumer-lag dashboards). Goes beyond with inactive_since, invalidation_reason, recovery procedure, and heartbeats. No significant gaps. |
| **Average** | **5.00** | **PASS** |

### What Worked
- Directly corrected the iter311 critical miss: leads with "Yes, safe_wal_size is real" and gets the LSN choice unambiguously right
- Long-running transaction explanation is the load-bearing insight that distinguishes the two LSNs — stated precisely with the failure mode named
- Priority-ordered reading of monitoring query columns (1–6) gives operators a triage workflow, not just a column list
- NULL and negative-value handling for safe_wal_size are both addressed — exactly the cases that bite in production
- Heartbeat section ties slot behavior to the "quiet table" failure mode with a working JSON config

### What Missed
- PG 16+ added `idle_timeout` as a fourth `invalidation_reason` value (minor omission)
- Recovery procedure doesn't note that the backfill gap must be scoped from `inactive_since`/last successful event time — readers might assume backfilling is automatic

### Technical Accuracy
All claims verified: postgresql.org/docs/current/view-pg-replication-slots.html, morling.dev restart_lsn vs confirmed_flush_lsn, EDB PG 13 slot safety blog, Debezium connector docs.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.481 across 106 questions → (4.481 × 106 + 5.00) / 107 = **4.486 across 107 questions**. Status: PASSED. This answer directly remediates the iter311 Q2 regression — resource fix demonstrated effective.

---

## Iter 312 Summary

**Iter 312 average: 4.69 — PASS** ✓

### Suggested focus for Iter 313
- OPA clarification: "Trino injects the WHERE expression" (not OPA rewrites SQL) — Q1 accuracy nit that could confuse engineers debugging query plans
- `columnMask` OPA rule for column-level masking — sibling to rowFilters, not yet tested
- Replication slot gap-window scoping after recovery (from `inactive_since` to reconnection time) — completeness gap in Q2
- Continue on any topic with score below 4.5 — try fresh angles on OLAP vs OLTP mindset, cost considerations, or Trino CBO topics
