# Iter 3 Q3 — Multi-tenant isolation in Trino/Iceberg

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "Multi-tenant analytics: isolating customer data in SaaS"
- Prior avg: 1.75, prior questions: 1
- New running avg: 3.25 (across 2 questions)

## Key finding
The answer is a near-complete reversal of the failure in Iter 2 Q4 — it directly addresses all three sub-questions: (1) Trino's default behavior (no auto-isolation), (2) what to build vs what the engine gives you (views + roles + system access control), and (3) the bad-query scenario (denied at the role level, not silently leaked). It correctly grounds the recommendation in the production stack (Trino 467 + Iceberg + MinIO), gives runnable CREATE VIEW / GRANT / REVOKE syntax, and closes with a concrete 80-tenant playbook plus noisy-neighbor mitigation. Technical accuracy is solid: the claim that base-table SELECT is denied to tenant roles, the partition spec `(tenant_id, day(event_ts))`, and the defense-in-depth framing are all correct for Trino 467.

## Resource gap for next iteration
Beginner clarity is the weak dimension — "role-based access control", "system access control", "resource groups", and "noisy-neighbor" are used without inline explanation in the answer summary. The resource has a Key Terms section but the responder did not surface those definitions when first using the terms. Also, the answer does not warn that file-based rules require coordinator restart (or OPA for hot reload) — a real operational gotcha the SaaS engineer will hit. To pass the topic with a second clean angle, the next question should probe either (a) the CI test / verification flow ("how do I prove to my security team that the isolation actually works?") or (b) the customer-offboarding angle ("when a customer leaves, how do I delete their data?") since shared-table designs make GDPR-style deletes harder than namespace-per-tenant.
