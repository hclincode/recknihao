# Iteration 47, Q1 — Score

**Question**: We set up Trino isolation for one of our enterprise tenants — created a role called `acme_role`, ran `GRANT ROLE acme_role TO USER 'acme-service-account'`, granted the role SELECT on our per-tenant view, and then ran `REVOKE ALL ON analytics.events FROM ROLE acme_role` to block base-table access. But when I test with the acme service account it can still run `SELECT COUNT(*) FROM analytics.events` and get a number that includes other tenants' rows. I thought the REVOKE would have locked them out of the base table. What did we do wrong?

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

---

## Technical verification (via WebSearch against trino.io)

1. **Is `REVOKE ALL ON table FROM USER "name"` valid Trino syntax?**
   YES — confirmed by Trino REVOKE docs. The exact grammar is:
   ```
   REVOKE [ GRANT OPTION FOR ] ( privilege [, ...] | ALL PRIVILEGES )
   ON [ BRANCH branch_name IN ] ( table_name | TABLE table_name | SCHEMA schema_name )
   FROM ( user | USER user | ROLE role )
   ```
   The FROM clause explicitly accepts `USER user` as a principal target. The answer's `REVOKE ALL ON analytics.events FROM USER "acme-service-account"` is syntactically correct, though Trino docs technically write `REVOKE ALL PRIVILEGES` — `REVOKE ALL` is the common shorthand and is accepted.

2. **Under Trino's default access control, do USER PRINCIPALS have implicit base-table access?**
   YES — confirmed by Trino access control docs. "If no rules are provided at all, then access is granted." In the absence of a system access control plugin, all users have read access to all tables by default. This is the foundation of the responder's diagnosis.

3. **Is a freshly-created role's privilege set empty (does NOT inherit the default allow-all)?**
   YES — confirmed by Trino CREATE ROLE / GRANT semantics. A role created via `CREATE ROLE` starts with zero privileges. The role only gets what you explicitly `GRANT` to it. The default allow-all behavior lives on the USER principal, not the ROLE. This means `REVOKE ALL ... FROM ROLE acme_role` is a no-op when the role never had an explicit grant — exactly as the responder explained.

4. **In an OPA-backed Trino deployment, does SQL GRANT/REVOKE affect OPA decisions?**
   NO by default — confirmed by Trino OPA access control docs. OPA contacts the policy on every query and uses the boolean `allow` field from Rego. SQL GRANT/REVOKE permission management is disabled by default in OPA-backed deployments ("defaults to false due to the complexity and potential unexpected consequences"). The responder's note that the OPA policy must also explicitly deny base-table SELECT is correct for the production stack.

5. **Production-stack fit**: Answer correctly anchors to prod_info.md — names OPA as the authorization backend and explicitly tells the engineer that SQL REVOKE is not sufficient in an OPA deployment. It also defers specific OPA policy authorship to the platform team / external governance document, matching the prod_info.md instruction at lines 38–41.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every claim verified against trino.io. The core diagnosis — REVOKE-from-ROLE is a no-op because the role never had the privilege in the first place — is correct. USER PRINCIPAL has default allow-all access; only revoking from the USER principal removes it. The four-step isolation sequence (CREATE VIEW, CREATE ROLE + GRANT ROLE, GRANT SELECT on view to ROLE, REVOKE ALL on base table from USER PRINCIPAL) is correct. OPA caveat is correct. `REVOKE ALL` shorthand (vs the documented `REVOKE ALL PRIVILEGES`) is the common in-the-wild form and matches the user's own syntax in the question. |
| **Beginner clarity** | 4 | Strong opening that names the problem in one sentence ("you revoked from a role that never had access to begin with"). Uses runnable SQL for each step. Plain-English narration of why the REVOKE was a no-op ("Trino said okay, acme_role no longer has base-table access — but acme_role never had base-table access to begin with"). Beginner-clarity weakness: "USER principal," "role," "default allow-all," "system access control," "OPA / authorization backend" appear without inline plain-English glosses. A reader who doesn't already know what "principal" means in Trino's access-control vocabulary will struggle. |
| **Practical applicability** | 5 | Engineer leaves with: (a) exact reason their setup leaked (the REVOKE targeted the wrong principal), (b) the one-line SQL fix (`REVOKE ALL ON analytics.events FROM USER "acme-service-account"`), (c) the complete four-step isolation recipe with runnable SQL for each step, (d) a verification test (run both SELECTs as the service account, expect Access Denied on the base table and success on the view), and (e) the critical OPA caveat that SQL REVOKE alone is not enough in the production stack. Cleanest possible "what do I do right now" output. |
| **Completeness** | 5 | Addresses all five points from the expected-answer outline: (1) REVOKE was against the ROLE — silent no-op, (2) USER PRINCIPALS have implicit base-table access under default allow-all, (3) fix is `REVOKE ALL ON table FROM USER`, (4) the correct four-step sequence (CREATE ROLE + GRANT ROLE + GRANT SELECT on view to ROLE + REVOKE on base from USER), (5) OPA note that SQL REVOKE doesn't affect OPA decisions. Bonus: includes a test recipe and the original CREATE VIEW step (not strictly required but completes the picture). |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

Topic: Multi-tenant analytics: isolating customer data in SaaS
- Prior: avg 4.250 across 48 questions (per state.json notes)
- New entry: 4.75 — running avg increases very slightly.
- Status: PASSED (well above 3.5 threshold).

## Notes for teacher

No new resource gaps identified for this specific answer. The responder correctly diagnosed the USER-vs-ROLE principal issue, surfaced the default allow-all behavior of Trino's no-access-control baseline, gave the correct one-line fix, walked the full four-step isolation sequence, and correctly flagged that SQL REVOKE is insufficient in the OPA-backed production stack.

Persistent beginner-clarity gap across the multi-tenant topic (now flagged in iter 3 Q3, iter 4 Q5, iter 5 Q5, iter 13 Q4, and again here): "USER principal," "role," "default allow-all," "system access control," "authorization backend / OPA" are still being used without inline one-line plain-English glosses. The teacher should add a top-of-section glossary box to `resources/05-multi-tenant-analytics.md` defining:

- **Principal**: a user, service account, or role — anything Trino can identify as the actor running a query
- **USER principal**: a specific human/service-account identity (e.g., `acme-service-account`) — distinct from a ROLE, which is a privilege bundle that can be granted TO a USER
- **Default allow-all**: when no system access control is configured, Trino grants every user read access to every table; you must explicitly REVOKE from the USER principal to block this
- **System access control**: the cross-catalog authorization plugin (file-based rules or OPA in this production stack); not the same as per-catalog grants

Optionally, add a "Why REVOKE from ROLE is a no-op when the role has no explicit grants" callout box to `resources/05-multi-tenant-analytics.md` — this is the exact misconception this question tested, and it would prevent future weaker pulls from missing it.
