# Iter 5 Q5 — Service account isolation: write vs read path

## Scores
- Technical accuracy: 4
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 4
- Average: 4.25

## Topic updated
- Topic name: "Multi-tenant analytics: isolating customer data in SaaS"
- Prior: avg 3.75 across 3 questions (PASSED)
- New: avg (1.75 + 4.75 + 4.75 + 4.75 + 4.25) / 5 = 20.25 / 5 = **4.05** across 4 questions
- Note: The question is fundamentally about multi-tenant isolation enforcement (write vs read path separation as a defense-in-depth pattern), not about the OLTP-to-OLAP mindset topic suggested in the prompt header. The answer's content (Trino roles, GRANT/REVOKE, k8s ServiceAccounts as enforcement layer) maps squarely to topic 05-multi-tenant-analytics.md. Recommend the rubric reflect this attribution; OLTP-to-OLAP mindset (topic 12) is untouched by this question and remains at 0 questions.

## Key finding
Strong, actionable answer that correctly extends the multi-tenant playbook to the *ingestion* side — recognizing that the Spark write user and the Trino read user must be different principals with disjoint grants, and that k8s ServiceAccount separation lines up with Trino role separation. The runnable CREATE ROLE / GRANT SELECT on views / REVOKE ALL on base tables snippet is exactly what the engineer needs, and the CI test recommendation closes the loop with Iter 4 Q5. One technical imprecision: the answer says "Trino evaluates permissions before parsing" — access control is actually evaluated during analysis/planning (after the SQL is parsed into an AST), not before parsing. The substantive point the responder was making (engine-level rejection, not app-level enforcement) is correct; the parse-time framing is wrong on a detail a security reviewer will catch. Beginner clarity dinged because "ServiceAccount", "role", "analytics_service", "system access control" again appear without inline glosses — the persistent gap flagged in Iter 3 Q3 and Iter 4 Q5 across this topic.

## Resource gap
`resources/05-multi-tenant-analytics.md` does not currently have an explicit **"write path vs read path: separate principals"** subsection. The existing content has separate role examples (acme_role, beta_role, admin role) but does not name the ingestion service account as its own principal that must be locked out of reads, nor does it map Trino roles to k8s ServiceAccounts (the production stack runs Trino + Spark in k8s per prod_info.md). Recommend adding:
1. A "Two service accounts, not one" section with a table: `spark-ingest-sa` (writes to base tables, no read on views) vs `trino-query-sa` (reads via per-tenant views, no write/no base-table access).
2. A correction to any "permissions evaluated before parsing" framing — Trino access control runs during the analysis phase of the query lifecycle (post-parse, pre-execution); the user-facing guarantee is "rejected before any data is read from MinIO," which is the accurate version of the responder's intent.
3. A k8s ServiceAccount -> Trino user mapping example (JWT or password auth) so the engineer knows how the pod identity actually becomes the Trino principal.
