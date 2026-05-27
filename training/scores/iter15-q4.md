# Score: Iteration 15, Question 4

**Date**: 2026-05-24
**Phase**: Final
**Question**: We have 50 enterprise customers and each one wants a "usage analytics" page that shows their own data — things like how many active users they have per month, which features they use most, that kind of thing. Right now every time a customer opens that page it runs a fresh query against our main app database and it's getting really slow. What's the right way to think about fixing this — do we just add indexes, or is there something more fundamental we're doing wrong?
**Rubric topics covered**: Multi-tenant analytics: isolating customer data in SaaS; When to add an OLAP layer vs staying on the transactional DB

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All key claims verified correct. Row-oriented read penalty is accurate. Read replica, materialized view, pg_partman partitioning, and EXPLAIN ANALYZE are all valid Postgres tuning steps. Spark → MinIO → Iceberg → Trino migration path is accurate for the production stack. Trino view with hard-coded WHERE tenant_id filter for tenant isolation is technically correct. Thresholds (50M rows, 2s queries, 3 users, multi-source) match resource exactly. |
| Beginner clarity | 4.75 | Excellent framing — "painting rust on a failing bridge" metaphor lands. Option A / Option B structure is highly readable. Step-by-step Postgres tuning list is actionable. Decision signals are concrete. |
| Practical applicability | 4.75 | Correctly identifies the production stack (Spark + Iceberg + MinIO + Trino) without any cloud tool recommendations. Tuning-first recommendation is exactly right. Tenant isolation mechanism via Trino views is the correct implementation. |
| Completeness | 4.50 | Strong. "Cost of moving too early" section is explicitly surfaced — this was a persistent gap in prior iterations and is correctly included here. Multi-tenant isolation via views is explained. Gaps: (1) GRANT/REVOKE mechanics for locking down base tables not mentioned (but question was about performance architecture, not RBAC, so this is acceptable); (2) OPA authorization mechanism not mentioned (correct per prod_info.md — defer to external governance doc). |
| **Average** | **4.688** | Above 3.5 pass threshold. Strongest answer of this iteration. |

---

## What the answer got right

1. Correctly identified the structural OLTP/OLAP mismatch — not just an index problem.
2. Provided a concrete, ordered Postgres tuning checklist (read replica → materialized views → pg_partman → EXPLAIN ANALYZE).
3. Correctly recommended the production stack (Trino + Iceberg + MinIO + Spark) for Option B — no cloud tools.
4. Correctly described tenant isolation mechanism: Trino view with hard-coded `WHERE tenant_id = 'acme'` — customers cannot bypass the filter.
5. **"Cost of moving too early" section explicitly surfaced** — this has been a recurring gap (flagged in iter14 feedback) and the answer addresses it directly with concrete consequences.
6. Provided measurable thresholds for when to move.
7. Recommended "start with a read replica and materialized views, run for 2–3 weeks, measure" — exactly the right decision process.

## What the answer missed

1. **Materialized view cadence tradeoff not flagged.** Materialized views require manual or scheduled refresh — this creates a freshness tradeoff (hourly refresh = up to 1 hour stale). The answer doesn't warn about this, which matters for "usage analytics" pages where customers may notice stale data.

2. **pg_partman as a dependency.** `pg_partman` is an extension that requires installation — it's not built into Postgres. The answer recommends it without noting this.

3. **JWT/OPA auth not mentioned** — acceptable per prod_info.md guidance (defer specific permission rules to external governance document). Not scored against.

---

## Resource assessment

No resource bugs identified. The resources (`05-multi-tenant-analytics.md`, `06-when-to-add-olap.md`) contain the correct content and the responder correctly surfaced the key elements. This answer demonstrates that the "cost of moving too early" callout from feedback-latest.md was absorbed (it was listed as Priority 3 for iter15). Recommend verifying whether resources/06-when-to-add-olap.md now has the explicit callout box for this content.

---

## Topic score updates

**Multi-tenant analytics: isolating customer data in SaaS**
- Prior: avg 3.841 across 11 questions
- This answer: 4.688 (12th angle — per-customer analytics page framing)
- New running avg: (prior_sum + 4.688) / 12 = approximately **3.904** across 12 questions
- Status: PASSED (unchanged, improving from 3.841)

**When to add an OLAP layer vs staying on the transactional DB**
- Prior: avg 4.344 across 4 questions (after iter15-q1 and iter15-q2 updates)
- This answer: 4.688 (5th angle — per-customer analytics performance degradation)
- New running avg: approximately **4.395** across 5 questions
- Status: PASSED (unchanged, improving)
