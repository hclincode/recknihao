# Score: Iteration 19, Question 4

**Date**: 2026-05-24
**Phase**: Final (final iteration)
**Question**: Enterprise customer ran full event history SELECT *, took down other tenants' dashboards in 10 minutes. Resource groups configured but didn't stop it. Why didn't they kick in? How to fix?
**Rubric topics**: Multi-tenant analytics: isolating customer data in SaaS; Query performance basics

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Root cause correctly identified: resource group selectors use `"user"` to match JWT principal name (JWT `sub` claim), not Trino role name. "The selector silently never matched" — correct behavior description. The JSON config example uses the JWT service account name (`"acme-service-account"`) not the role name — this directly applies the iter18 resource fix. The export recommendation (INSERT INTO ... SELECT as a Trino operation writing to MinIO) is correct and consistent with the iter17 resource fix. `query.max-execution-time` session override is the correct property. All percentage-based memory limits are realistic. Minor: `maxMemoryPerTask` is not a standard Trino resource group property name — the correct property is `hardConcurrentQueriesLimit` for query count and `softMemoryLimit`/`hardMemoryLimit` for memory. The field names in the JSON config example may not map exactly to Trino 467's config format. |
| Beginner clarity | 4.75 | The "your selector was looking for 'acme_role', the JWT said 'customer-123-service-account'" contrast is vivid and immediately comprehensible. "The resource group silently never applies — the noisy tenant is uncapped" is the clearest possible statement of the failure mode. The diagnosis-first structure (why it failed → how to check → correct config → hardening) is the right order. |
| Practical applicability | 4.50 | The diagnosis steps (coordinator logs, Trino audit query for `context.principal`) are actionable. The correct config fix (JWT principal in `"user"` field) is directly applicable. The INSERT INTO ... SELECT export pattern as the application-level alternative is correct and grounded in the production stack. Minor: some resource group field names (`maxMemoryPerTask`) may not be valid in Trino 467's resource groups configuration — reduces copy-paste reliability slightly. |
| Completeness | 4.75 | Covers: (1) why resource groups didn't kick in (JWT selector mismatch); (2) how to verify what went wrong (logs, audit); (3) correct configuration; (4) per-tenant caps explanation; (5) application-layer prevention (INSERT INTO ... SELECT); (6) per-query timeout override; (7) monitoring (queue depth metric). Minor gap: doesn't mention that resource-groups.json changes require a Trino coordinator restart (file-based rules don't hot-reload). |
| **Average** | **4.69** | |

---

## What the answer got right

1. Root cause: JWT principal name vs Trino role name selector mismatch — directly applies iter18 resource fix.
2. "Selector silently never matched" — exact silent failure behavior correctly described.
3. INSERT INTO ... SELECT as Trino operation for bulk exports — consistent with iter17 resource fix.
4. How to find the JWT principal from logs (`context.principal` in audit events) — correct.
5. query.max-execution-time session override — correct property name.
6. Per-tenant memory caps in resource groups — concept correct.

## What the answer missed

1. Resource-groups.json changes require coordinator restart — not mentioned.
2. Some JSON field names (`maxMemoryPerTask`) may not be valid Trino 467 resource group properties — `softMemoryLimit` and `hardMemoryLimit` are the correct memory fields.

## Topic score updates

**Multi-tenant analytics: isolating customer data in SaaS**
- Prior after Q3 this iter: 4.134 across 17 questions
- This answer: 4.69 (18th angle — why resource groups failed + JWT principal selector fix)
- New running avg: (4.134 × 17 + 4.69) / 18 = (70.278 + 4.69) / 18 = **4.166** across 18 questions
- Status: PASSED (solidly above 4.0)

**Query performance basics: partitioning, indexing strategy for analytics**
- Not recorded as primary for this topic (resource isolation is multi-tenant, not pure query perf)
