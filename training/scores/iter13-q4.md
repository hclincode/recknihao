# Iter 13 Q4 — Trino Role Enforcement: GRANT ROLE TO USER as the Missing Step

## Question summary
An engineer created a per-customer Trino role but a test user can still see all data. They suspect they skipped a step between creating the role and enforcing it for a specific login.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | The three-step sequence (CREATE ROLE → GRANT ROLE acme_role TO USER → GRANT SELECT on view + REVOKE on base table) is correct and matches Trino docs. The "silent no-op" framing is accurate: a role that no principal holds cannot convey any permissions. The causal explanation for why the user still sees all data ("access control finds no explicit grants and defaults to allowing access") is partially oversimplified. The more precise mechanism is: (a) if no system access control plugin is configured, Trino's default allow-all behavior applies regardless of role grants; (b) even with a plugin, the GRANT SELECT on the view TO ROLE has no bearing on a user not in the role. The answer conflates these into a single "defaults to allowing access" statement that is directionally correct but will not survive a security review. One point docked for this imprecision. |
| Beginner clarity | 5 | Excellent. The "role without an assigned user is a silent no-op" metaphor is beginner-friendly and memorable. The three-step sequence is presented as a numbered list with SQL, and the explanation of why the auth principal "maps through" to the role is sufficient for a zero-OLAP-background engineer to act on. No unexplained jargon. |
| Practical applicability | 5 | The exact SQL that was missing is named and shown. An engineer reading this can immediately run GRANT ROLE acme_role TO USER "acme-service-account" and verify the fix. The explanation of the authentication path (Kubernetes token/JWT/password → principal → role → access control check) gives enough context to debug similar issues. Directly addresses the production stack (Trino 467, on-prem k8s). |
| Completeness | 4 | Fully addresses the question asked (what is the missing step). One nuance missing: the answer does not mention that GRANT ROLE ... TO USER alone is still insufficient if the base table's access is not explicitly revoked or if no system access control plugin is configured. Without REVOKE ALL ON analytics.events FROM ROLE or a system access control rule blocking direct base-table reads, a user in the role can still query the base table directly and see all tenants' data. The answer includes the REVOKE in step 3, but does not call out its necessity explicitly or warn that omitting it leaves the base table open. |
| **Average** | **4.50** | |

## Topic updated

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

- Note: Q3 this iteration also scored this topic — merge agent will compute combined running avg
- Prior running avg: 3.75 (9 questions through Q3 of Iter 12 per rubric table; Q3 of Iter 13 adds one more entry before this one)
- New score this question: 4.50

## Key finding

The Iter 13 resource fix (adding the explicit CREATE ROLE → GRANT ROLE TO USER → GRANT SELECT sequence with the "silent no-op" warning callout) is working. This is the direct complement to the Iter 12 Q2 gap identified there: "answer created the role but omitted the GRANT ROLE ... TO USER step." The responder now reproduces the full three-step sequence and the correct "silent no-op" framing. The technical accuracy deduction is minor — the causal explanation is a useful simplification for beginners even if it collapses two distinct mechanisms into one.

## Resource gap

The resource accurately covers all three steps and the silent-no-op warning. One remaining gap worth flagging: the resource does not explicitly state that REVOKE ALL on the base table is a required companion step to the GRANT SELECT on the view. An engineer who reads only the step-2 explanation ("GRANT ROLE is what was missing") might perform that step alone and consider the job done — the user is now in the role, but the base table remains accessible to everyone. A one-sentence callout after step 2 noting "step 3 (REVOKE on base table) is equally required or the role conveys view access but doesn't block direct base-table reads" would close this gap. The resource does include REVOKE in the code block but the prose does not call it out as a mandatory companion.
