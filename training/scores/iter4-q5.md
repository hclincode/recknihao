# Iter 4 Q5 — Multi-tenant engine-level isolation proof

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "Multi-tenant analytics: isolating customer data in SaaS"
- Prior: avg 3.25, 2 questions (1.75 + 4.75)
- New running avg: 3.75 (3 questions total: 1.75 + 4.75 + 4.75 = 11.25 / 3). Status: PASSES threshold (>= 3.5) on third angle; topic can be marked passed.

## Key finding
Directly answers the security-team "prove it" framing with a concrete, runnable CI test recipe (create role, grant only on view, assert base-table SELECT fails with permission error, assert view SELECT succeeds) — this is exactly the verification artifact the security team would accept. Correctly grounds the proof in the two enforcement layers from `resources/05-multi-tenant-analytics.md` (view + REVOKE on base table; system access control via file-based rules or OPA), names the prod stack (Trino 467 + Iceberg + MinIO), and gets the headline assertion right: Trino rejects the query at the role/access-control layer *before* it reaches Iceberg, so a missing WHERE clause cannot bypass isolation. The 7-step 80-tenant playbook restates the resource's concrete recommendation accurately. Cited resource with line numbers, which makes the answer auditable.

## Resource gap for next iteration
Beginner clarity remains the persistent weak spot across the multi-tenant topic: "role-based access control," "system access control," "parse time," "veto," "file-based rules," and "OPA" still appear without inline plain-English glosses in the answer. The resource has a Key Terms block (lines 208-218), but the responder is not pulling those definitions inline when the term first appears in the answer body. More importantly, the answer does not show what the CI test actually looks like as runnable test code — it describes the four steps narratively but does not give a Python/pytest or shell snippet a junior engineer could drop into a CI pipeline. Recommend adding a "How to prove isolation in CI" subsection to `resources/05-multi-tenant-analytics.md` with: (a) a pytest example using the Trino Python client that authenticates as the tenant role, runs `SELECT * FROM analytics.events`, and asserts a `TrinoUserError`/permission denial; (b) a note that the test should run on every PR; (c) a one-paragraph "what to hand the security team" deliverable list (the CI test output, the access-control rules file, the GRANT/REVOKE DDL). Also worth adding: a sentence on whether file-based rules require a coordinator restart vs OPA's hot reload (flagged in Iter 3 Q3 feedback, still missing).
