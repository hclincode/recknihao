# Judge Report — Iter 147 Q1

## Question summary
SaaS engineer asks how to prevent one big-export customer from starving the shared Trino cluster — looking for a built-in way to cap memory or concurrent queries per user/tenant.

## Verdict
**Weighted average: 4.95 / 5 — PASS** (threshold 4.5)

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Technical accuracy | 5.0 | 2x | 10.0 |
| Clarity | 5.0 | 1x | 5.0 |
| Practical usefulness | 5.0 | 1x | 5.0 |
| Completeness | 4.75 | 1x | 4.75 |
| **Total** | | **5x** | **24.75 / 5 = 4.95** |

---

## Per-dimension scoring

### Technical accuracy — 5.0
Every verifiable claim checked against trino.io docs:

| Claim | Verification | Source |
|---|---|---|
| Two-file pattern `resource-groups.properties` (pointer) + `resource-groups.json` (limits) | CORRECT | Trino resource-groups docs |
| `resource-groups.configuration-manager=file` | CORRECT verbatim | Trino resource-groups docs |
| `resource-groups.config-file=etc/resource-groups.json` | CORRECT verbatim | Trino resource-groups docs |
| `hardConcurrencyLimit` | CORRECT (required property) | Trino resource-groups docs |
| `softMemoryLimit` | CORRECT (optional property, accepts `%`) | Trino resource-groups docs |
| `softCpuLimit` | CORRECT (optional property) | Trino resource-groups docs |
| `maxQueued` | CORRECT (required property) | Trino resource-groups docs |
| `schedulingPolicy` | CORRECT (optional) | Trino resource-groups docs |
| `schedulingPolicy: "weighted_fair"` is valid | CORRECT (valid values: fair, weighted_fair, weighted, query_priority) | Trino resource-groups docs |
| `cpuQuotaPeriod` valid top-level global property | CORRECT | Trino resource-groups docs |
| `CALL system.runtime.kill_query(query_id => ..., message => ...)` | CORRECT verbatim syntax | Trino system connector docs |
| `resource_group_id` exists in `system.runtime.queries`, type `array(varchar)` matching shown `['global','large_customer_exports']` format | CORRECT | Trino docs / Release notes |
| Selectors match the `user` field which corresponds to the connection user (JWT principal under JWT auth) | CORRECT | Trino resource-groups docs (selector rules: user, originalUser, authenticatedUser, source, queryText, queryType, clientTags, group) |
| `softMemoryLimit` semantics described as "when exceeded, new queries queue" | CORRECT |  |
| `hardConcurrencyLimit` capped concurrency | CORRECT |  |
| Naming gotchas (`maxRunning`/`maxMemoryPercent` are wrong) | CORRECT — these are not valid property names |  |
| Coordinator-only deployment (`etc/` on coordinator) | CORRECT |  |

No factual errors found. Fully accurate.

### Clarity — 5.0
- Direct yes/no answer up front, then immediately names the feature.
- Problem framing ("this is a compute contention issue, not a storage isolation issue") demystifies the topic for a SaaS engineer with no OLAP background.
- Property table with plain-English meanings, not just specs.
- Numbered "three critical configuration details" section pre-empts the most common silent-failure modes.
- Wrong-name vs correct-name table is exactly the right teaching device for an engineer who will be Google-translating snippets.
- No assumed OLAP jargon goes unexplained.

### Practical usefulness — 5.0
- Complete, copy-pasteable `resource-groups.properties` and `resource-groups.json`.
- Selector examples cover both literal and regex (`.*-service-account`) cases.
- Kubernetes-native deployment steps (`kubectl rollout restart` / `rollout status`) match the production stack (on-prem k8s).
- Explicit "kill the in-flight bad query first to avoid a hard restart that kills everyone" workflow.
- Verification SQL with the expected `resource_group_id` shape and the troubleshooting hint ("if it shows only `['global']`, your selector did not match").
- Storage-isolation footnote correctly scopes resource groups to the compute problem and points to dedicated tables as the orthogonal fix.

Engineer can act on this immediately.

### Completeness — 4.75
Covers: config file layout, property semantics, selector matching by JWT principal, deployment via ConfigMap + rollout restart, verification via `system.runtime.queries`. Minor gaps (none disqualifying):

- **LOW**: Does not mention that **`schedulingPolicy` set on a parent group governs how slots are allocated *among its subGroups*** — a beginner could put `weighted_fair` on a leaf and wonder why it has no effect. (The example does correctly place it on `global`, but the rationale is not explained.)
- **LOW**: With `schedulingPolicy: "weighted_fair"`, each subGroup typically needs a `schedulingWeight` for the policy to be meaningful — the example omits weights, so the three subgroups will get equal share by default. This is consistent with prior iter26-Q1 feedback (`schedulingWeight dropped without explanation of the weighting math`).
- **LOW**: Does not mention `query.max-memory-per-node` / `query.max-memory` as the orthogonal per-query memory cap that complements per-group caps. The question asks specifically about resource groups, so this is a nice-to-have, not required.
- **LOW**: No mention of OPA/JWT auth interaction for the principal field — the prod stack uses a custom JWT authenticator; "JWT principal" is correctly named but the answer could note that the principal comes from the JWT `sub` claim as configured in the JWT authenticator, not from OPA. The answer does mention `sub` claim, which mitigates this.

---

## Verified-correct claims (with source URLs)

- Property names + selector rules + scheduling policies + `cpuQuotaPeriod`: [Resource groups — Trino docs](https://trino.io/docs/current/admin/resource-groups.html)
- `CALL system.runtime.kill_query(query_id => ..., message => ...)` syntax: [System connector — Trino docs](https://trino.io/docs/current/connector/system.html)
- `resource_group_id` `array(varchar)` column in `system.runtime.queries`: confirmed via Trino release notes and resource-groups docs (Issue/release reference: [trinodb/trino#26321](https://github.com/trinodb/trino/issues/26321), [Release 0.206](https://trino.io/docs/current/release/release-0.206.html))

---

## Errors and gaps

| Severity | Item |
|---|---|
| HIGH | None |
| MEDIUM | None |
| LOW | `schedulingPolicy` parent-vs-leaf semantics not explained |
| LOW | `weighted_fair` example does not assign `schedulingWeight` to subgroups — works, but the weighting story is incomplete |
| LOW | Per-query memory cap (`query.max-memory-per-node`, `query.max-memory`) not mentioned as a defense-in-depth complement to resource groups |
| LOW | OPA auth chain not explicitly distinguished from the JWT principal (answer is still correct: selector matches the authenticated user, which is the JWT principal; OPA only enforces authorization, not identity) |

---

## Resource fix recommendations

`resources/05-multi-tenant-analytics.md` is in good shape on this topic. Minor additions worth queueing for the next teacher pass:

1. Add a one-paragraph note on **scheduling policy placement**: `schedulingPolicy` on a parent group governs slot allocation among its `subGroups`; on a leaf it has no effect.
2. When showing `weighted_fair`, include `schedulingWeight` per subgroup in the example and one sentence on the share math (`weight / sum(weights)`).
3. Cross-reference per-query memory caps (`query.max-memory-per-node`, `query.max-memory`) as a complementary mechanism so engineers know resource groups + per-query caps are layered defenses.

Iter147 Q1 itself is a strong PASS and demonstrates that prior fixes (JWT principal matching surfaced as the #1 gotcha; coordinator restart explicit; correct vs wrong property-name table) are landing in answers.
