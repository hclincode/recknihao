# Score: Iteration 19, Question 3

**Date**: 2026-05-24
**Phase**: Final (final iteration)
**Question**: Getting ready to enable a new enterprise customer with 10x query volume. What do we verify before enabling their analytics access? Don't want cross-tenant leak or their queries taking down everyone else.
**Rubric topics**: Multi-tenant analytics: isolating customer data in SaaS

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All six parts technically correct. Test 1a (role grants, view access, base table denied) is correctly specified. Test 1b (checking grants table) is correct. Test 1c (resource group selector uses JWT principal, not role name) is the key insight from the iter18 resource fix — the answer correctly identifies this as a silent failure mode: "the resource group silently never applies." The `iceberg.system.*` catalog name is correctly used in CALL statements. The INSERT INTO ... SELECT export pattern is correctly attributed to Trino (not Spark). Both parts of the grant (GRANT SELECT on view AND REVOKE ALL on base table) correctly identified as mandatory. |
| Beginner clarity | 4.75 | Six-part structure makes the checklist scannable. The "why this matters" paragraphs after each test explain the failure mode, not just the procedure. Naming the JWT principal vs role name distinction as "this specific pitfall" is the right framing for a beginner. The CI test pseudocode at the end is concrete and runnable. |
| Practical applicability | 5.0 | This is the most practically applicable answer in the iteration. The checklist maps exactly to what an ops team needs to verify before a go-live. The stress test structure (QPS × duration), the EXPLAIN file count check, the compaction timing check — all are actionable verification steps. The summary checklist at the end is a direct handoff artifact. JWT principal name guidance is directly actionable. |
| Completeness | 4.75 | All major concerns covered: isolation (role + view + revoke), resource groups (with JWT principal fix), query performance (stress test, partition pruning), maintenance windows, schema (view columns), monitoring (audit log), CI automation. Minor gap: doesn't mention OPA deferred to external governance document — but this is appropriate since OPA-specific policy is not in-scope per prod_info.md. |
| **Average** | **4.81** | |

---

## What the answer got right

1. Test 1c: "resource group selector must use JWT principal name, not Trino role name" — directly addresses the iter18 resource fix. Correctly identifies silent failure mode.
2. Both parts of step 3 required (GRANT SELECT on view AND REVOKE ALL on base table).
3. GRANT ROLE ... TO USER required — the "silent no-op" pitfall explicitly named.
4. INSERT INTO ... SELECT export as Trino operation — correct (from iter17 fix).
5. Audit logging verification (HTTP event listener, `context.user`, `metadata.query`) — correct nested JSON fields.
6. Compaction timing check — practical and often overlooked.
7. CALL statements use `iceberg.system.*` — correct catalog name.

## What the answer missed

1. Doesn't mention OPA deferred to external governance doc — but this is appropriate per prod_info.md.
2. Snapshot retention window for rollback not mentioned — minor gap.

## Topic score updates

**Multi-tenant analytics: isolating customer data in SaaS**
- Prior: avg 4.091 across 16 questions
- This answer: 4.81 (17th angle — pre-enablement validation checklist for enterprise tenant)
- Running avg: (4.091 × 16 + 4.81) / 17 = (65.456 + 4.81) / 17 = **4.134** across 17 questions
- Status: PASSED (solidly above 4.0)
