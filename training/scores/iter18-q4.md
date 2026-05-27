# Score: Iteration 18, Question 4

**Date**: 2026-05-24
**Phase**: Final
**Question**: One large enterprise customer's heavy queries slow down all other customers' dashboards. How do we prevent the noisy neighbor problem?
**Rubric topics**: Multi-tenant analytics: isolating customer data in SaaS; Query performance basics

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.50 | Three-part structure is correct. Partitioning by tenant + date (Part 1) is correct. Trino resource groups concept (Part 2) is correct — the JSON config structure (rootGroups, subGroups, selectors, softMemoryLimit, hardMemoryLimit, maxQueued) is consistent with Trino's resource group config format. query.max-memory-per-node (Part 3) is the correct config property. Minor nuance: the resource group `selectors` use `"user": "big_customer_role"` — in Trino resource groups, `user` is a regex matching against the connection user name, not a Trino role name. If the production stack uses JWT tokens and OPA, each customer's queries land with a specific JWT principal/user. The selector approach works if the customer service account username matches the selector pattern, but the config example conflates Trino roles with resource group selector users. Directionally correct, implementation detail is imprecise. |
| Beginner clarity | 4.75 | "Noisy neighbor" metaphor is immediately clear. Three-part structure breaks the solution into manageable steps. JSON config example is concrete. Implementation checklist at the end is actionable. |
| Practical applicability | 4.50 | Kubernetes ConfigMap approach for mounting resource-groups.json is correct. `resource-groups.configuration-manager=file` config property is correct. Resource group concept is the right mechanism for this problem. JWT/OPA integration nuance (selectors work on JWT principals, not Trino roles directly) makes the config example not directly copy-pasteable without adjustment. |
| Completeness | 4.75 | Covers partitioning (resource scoping), resource groups (hard limits), per-query memory cap, app-side timeouts, monitoring, why partitioning alone is insufficient. |
| **Average** | **4.625** | |

---

## What the answer got right

1. Partitioning by tenant + date is a prerequisite for performance isolation — correct.
2. Trino resource groups as the mechanism for resource isolation — correct.
3. resource-groups.json config structure and mount via Kubernetes ConfigMap — correct approach.
4. query.max-memory-per-node as a per-query cap — correct property name.
5. "Queues instead of starves" behavior when limit is hit — correct Trino behavior.
6. App-side timeouts and query audit as complementary measures — correct.
7. "Why partitioning alone is insufficient" section — correct and important distinction.

## What the answer missed / was imprecise on

1. **Selector syntax conflates Trino roles with JWT principals.** In Trino resource groups, `"user"` in selectors matches against the connection's user name (JWT sub/principal), not against a Trino role name. The example `"user": "big_customer_role"` would only work if the JWT user name IS literally "big_customer_role." The correct approach for JWT auth is to configure selectors to match the JWT principal name for each customer's service account.

## Resource note

`resources/05-multi-tenant-analytics.md` should include a note about Trino resource groups: "Resource group selectors match on JWT principal names (the `user` field), not on Trino role names. Configure selectors to match the service account username your SaaS platform uses for each tenant's connections."

## Topic score updates

**Multi-tenant analytics**
- Prior after Q3 this iter: 4.055 across 15 questions
- This answer: 4.625 (16th angle — noisy neighbor / resource groups)
- New running avg: (60.825 + 4.625) / 16 = **4.091** across 16 questions
- Status: PASSED (solidly above 4.0)

**Query performance basics**
- Prior: avg 4.25 across 2 questions
- This answer partially exercises query performance (resource limits, memory caps)
- Not recording as primary for this topic (resource isolation is multi-tenant, not pure query perf)
