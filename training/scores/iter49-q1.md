# Iteration 49, Q1 — Score

**Question**: We have about 50 tenants sharing one Trino cluster. Right now we create a separate view per tenant with hardcoded `WHERE tenant_id = '<x>'`. Could we use `WHERE tenant_id = current_user` in a single shared view instead? Would it work? Safe? Trade-offs?

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

---

## Technical verification (via WebSearch against trino.io)

1. **Does Trino support `current_user` in view definitions?**
   YES — confirmed by `trino.io/docs/current/sql/create-view.html`: "the `current_user` function will always return the user executing the query and thus may be used within views to filter out rows or otherwise restrict access." This works regardless of security mode.

2. **Is `SECURITY INVOKER` vs `SECURITY DEFINER` a real Trino view option? What is the default?**
   YES — both are documented options on `CREATE VIEW`. **DEFINER is the default** (confirmed against trino.io/docs/current/sql/create-view.html). The responder's claim "the default is `SECURITY DEFINER`" is correct.

3. **Does `current_user` resolve differently under DEFINER vs INVOKER?**
   NO — and this is where the responder's framing is slightly imprecise. Per the Trino docs, `current_user` resolves to the executing user in BOTH modes. The WHERE filter therefore works correctly in DEFINER mode too. The actual security difference is which user's grants are used to read the *base table*: in DEFINER mode the view runs with the owner's grants (so a misconfigured filter could expose all rows to any view-grantee); in INVOKER mode the view runs with the executing user's grants (so even if the filter breaks, the user must independently have base-table SELECT). The responder's recommendation to prefer INVOKER for defense-in-depth is correct — but the wording "MUST be created with SECURITY INVOKER" and "DEFINER is unsafe" is a slight overstatement of what the Trino docs say. DEFINER + WHERE filter works; INVOKER + WHERE filter + base-table REVOKE is just stronger defense-in-depth.

4. **Is `REVOKE ALL ON table FROM USER` correct Trino syntax?**
   PARTIALLY — confirmed against `trino.io/docs/current/sql/revoke.html` that `FROM USER <name>` is supported, but the privilege keyword is `ALL PRIVILEGES`, not `ALL`. The documented syntax is `REVOKE ALL PRIVILEGES ON test FROM alice;` or `REVOKE ALL PRIVILEGES ON <table> FROM USER <name>;`. The responder's `REVOKE ALL ON analytics.events FROM USER "acme-service-account"` is missing the `PRIVILEGES` keyword — an engineer copy-pasting will get a parse error. Minor but real.

5. **Production-stack fit**: prod_info.md states authorization is via **OPA**, not built-in Trino RBAC. GRANT/REVOKE statements are still parsed but enforcement is delegated to OPA's policy set, which may or may not honor in-engine GRANT state. The responder's REVOKE recommendation also conflicts with the prod-info guidance that "resources should not attempt to document specific permission rules... defer to the external governance document." The answer does not mention OPA, JWT, or the external governance document at all. This is a notable production-stack-fit miss given that this is question 50+ on the multi-tenant topic and the OPA framing has been called out repeatedly in prior iterations.

6. **Blast-radius trade-off framing**: The "per-tenant views at 50, revisit at 150–200" recommendation matches the expected answer outline and the resource guidance from prior iterations. The blast-radius argument is original and pedagogically strong — it gives the engineer a memorable frame for the decision.

7. **Username-vs-tenant_id mismatch**: The responder correctly surfaces that `tenant_id` values must match Trino usernames exactly OR a lookup table is needed. The example lookup-table view is runnable. Good catch.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 4 | Three of the four key technical claims verified: `current_user` works in views, DEFINER is the default, the lookup-table pattern is sound. Two imprecisions: (a) the framing that DEFINER is "unsafe" for the WHERE-filter use case overstates the docs — the filter applies correctly in DEFINER mode; the INVOKER recommendation is defense-in-depth, not a correctness fix; (b) `REVOKE ALL ON ... FROM USER` is missing the `PRIVILEGES` keyword (correct syntax is `REVOKE ALL PRIVILEGES ON ... FROM USER ...`). Neither error invalidates the recommendation but both will trip up an engineer who copy-pastes. |
| **Beginner clarity** | 4 | Strong structure (short answer, how it works, trade-offs, REVOKE callout, path forward). "Blast radius" framing is memorable. Inline glosses are mostly present but a few terms drop without explanation: `SECURITY INVOKER` / `SECURITY DEFINER` are introduced with what-they-mean prose (good) but "view owner's grants" assumes the reader knows views have an owner principal; "USER PRINCIPAL" is capitalized and quoted but never defined; "P0 failure surface" appears without gloss. Hive Metastore "500+ schemas slowdown" claim drops without context. The 150-200 tenant threshold is asserted without showing the math, but the surrounding reasoning makes it defensible. |
| **Practical applicability** | 4 | Engineer leaves with: (a) clear yes/no on the proposed shared-view approach (yes, works; not recommended at your scale), (b) two concrete prerequisites (matching usernames or lookup table; INVOKER mode), (c) the REVOKE-on-base-table reminder, and (d) a 4-step path forward with CI test recommendation. The actionable rating is docked one point for: (1) the REVOKE syntax error noted above, (2) no mention of how this advice maps to the prod OPA + JWT stack — at 50 questions deep on this topic this gap is conspicuous, and (3) the lookup-table pattern is shown but no guidance on where to host it (Iceberg config schema? a Postgres lookup via Trino's PostgreSQL connector? a JWT claim?) — engineer leaves with the right concept but a missing implementation choice. |
| **Completeness** | 5 | Hits every item on the expected-answer outline: `current_user` works (yes), filter is correct (yes), username-vs-tenant_id matching requirement + lookup-table workaround (yes), INVOKER vs DEFINER (yes, with INVOKER recommendation), trade-off framing (per-tenant simpler maintenance + stronger isolation vs shared-view scale) (yes), base-table REVOKE still required (yes), 50-tenant recommendation (yes, stick with per-tenant). Plus the original blast-radius framing, the audit-trail benefit of per-tenant naming, the schema-evolution argument, and a clean 4-step action plan. Goes beyond the outline in useful ways without padding. |

**Average**: (4 + 4 + 4 + 5) / 4 = **4.25**

---

## Rubric update

Topic: Multi-tenant analytics: isolating customer data in SaaS
- Prior: 4.270 across 50 questions (per state.json iter48 notes)
- This question: 4.25
- New running avg: (4.270 × 50 + 4.25) / 51 ≈ **4.270** across 51 questions
- Status: **PASSED** (unchanged — avg well above 3.5 threshold)

---

## Notes for teacher

Three resource gaps worth addressing — all small refinements, not new structural content.

1. **REVOKE syntax precision**: anywhere `resources/05-multi-tenant-analytics.md` shows `REVOKE ALL ON ... FROM USER ...`, change to `REVOKE ALL PRIVILEGES ON ... FROM USER ...`. The `PRIVILEGES` keyword is required per trino.io docs. Add a one-line "syntax note" near the first REVOKE example.

2. **`current_user` + view security mode — precision pass**: the resource (or the new section if one is added on shared-view + `current_user`) should state clearly that:
   - `current_user` works correctly in both DEFINER and INVOKER modes — the WHERE filter is enforced in both.
   - INVOKER is preferred for defense-in-depth: if the WHERE filter is misconfigured or removed, INVOKER mode requires the executing user to have independent base-table SELECT (which they shouldn't), so the misconfiguration fails closed. In DEFINER mode it would silently fail open to the view owner's full base-table grants.
   - This nuance matters for security reviews — "DEFINER is unsafe" is too strong; the correct framing is "DEFINER + WHERE filter = single layer of defense; INVOKER + WHERE filter + base-table REVOKE = two independent layers."

3. **OPA + JWT framing for this Q-pattern**: the responder did not surface that prod uses OPA, not in-engine GRANT/REVOKE. For shared-view + `current_user` patterns specifically, the engineer needs to know: (a) `current_user` in Trino resolves from the JWT subject after authentication, (b) OPA can also access the user identity for policy decisions, (c) the in-engine REVOKE-on-base-table recommendation may be a no-op if OPA is the only effective enforcement layer, in which case the equivalent guidance is "OPA policy must deny base-table reads to tenant principals while permitting view reads." Add a short callout in `resources/05-multi-tenant-analytics.md` that bridges the conceptual GRANT/REVOKE examples to "what this means in an OPA-backed deployment" — deferring specific OPA rules to the external governance doc per prod_info.md.

No new structural resource is needed — these are three targeted edits to `resources/05-multi-tenant-analytics.md`.
