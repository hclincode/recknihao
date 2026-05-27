# Iteration 45, Q1 — Score

**Question**: Tenant service accounts can run `SELECT * FROM system.runtime.queries` and `system.runtime.nodes` against the Trino system catalog. Are per-tenant views and roles sufficient, or is this a cross-tenant leak path?

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

---

## Technical verification (via WebSearch against trino.io)

1. **Does `system.runtime.queries` expose other users' SQL by default?**
   YES — confirmed by Trino's built-in system access control documentation: "If no system access control is installed, then all users are able to view and kill any query. However, users always have permission to view or kill their own queries." Query Rules (queryOwner / view permission) are the mechanism that restricts cross-user query visibility.

2. **Does the `system` catalog have default-open access?**
   YES — confirmed by Trino's file-based access control documentation: "by default, all users have access to the `system` catalog." This default can be overridden by a catalog rule with `allow: "none"` matching `catalog: "system"`.

3. **Is catalog-level access control via file-based rules or OPA the correct fix?**
   YES — the docs explicitly call out catalog rules as the coarse-grained control (`all`, `read-only`, `none`) for restricting catalog access, and OPA is listed as the alternative authorization backend (matches the prod_info.md setup).

4. **Production-stack fit**: The responder correctly identifies that the prod stack uses OPA (matches prod_info.md line 33) and explicitly refuses to invent specific OPA policies (matches the prod_info.md instruction at lines 38–41 to defer specific rules to the external governance document). This is exactly the right behavior.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every factual claim verified against trino.io. Correctly states the default-open behavior of both `system` catalog and query visibility, names the right two enforcement mechanisms (catalog rule and Query Rules / queryOwner), correctly distinguishes that view/role isolation does not touch the system catalog, and correctly defers OPA policy specifics to the external governance document. The only nit: the answer focuses on catalog-level deny (which is what blocks `system.runtime.nodes` and similar), but could also have mentioned Query Rules as a finer-grained alternative that still allows users to see their own running queries (sometimes needed for Web UI / "kill my own query" workflows). This is a refinement, not a correction. |
| **Beginner clarity** | 4 | Strong opening framing ("critical cross-tenant data leak"), clear what-leaks list (other tenants' SQL text, customer IDs in WHERE clauses, cluster metadata), and an actionable verification step with runnable SQL. Beginner-clarity weakness: "catalog-level deny rule," "JWT principal," "internal-services allow-list," "system access control," "P0 data leak" appear without inline plain-English glosses. A reader who doesn't already know what "catalog-level" means in the Trino access-control hierarchy will not learn it from this answer. |
| **Practical applicability** | 5 | Engineer leaves with: (a) confirmed severity assessment ("yes, worried, this is real"), (b) what to test right now (two specific SELECT statements to run as a tenant SA, expected outcome = Access Denied), (c) where the fix lives (OPA, matching prod stack), (d) what NOT to do (don't write OPA policy yourself — defer to governance doc), and (e) a CI gate to prevent regression. Cleanest possible "what do I do Monday morning" output. |
| **Completeness** | 5 | Covers all three sub-questions: (1) "can tenant SAs see other tenants' queries?" — yes, explicit list of what's exposed including SQL text and customer IDs embedded in WHERE clauses; (2) "is this independent of the view/role setup?" — explicitly stated that view and role grants do not touch the system catalog; (3) "should we be worried?" — direct yes with severity framing. Includes a verification recipe and CI test recommendation, which the expected-answer outline did not even ask for. The only completeness nit is that `system.runtime.tasks` and `system.metadata.table_properties` (other sensitive system tables) are not enumerated beyond the two the user named — but the answer correctly generalizes via "the `system` catalog" rather than table-by-table whack-a-mole, which is the right framing. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

Topic: Multi-tenant analytics: isolating customer data in SaaS
- Prior: avg 4.239 across 47 questions (per state.json notes)
- New running avg: depends on exact prior sum; with one more 4.75 question at 48 questions total, avg increases slightly. Status remains PASSED.

## Notes for teacher

No new resource gaps identified for this answer — the responder handled the system-catalog leak correctly and ALREADY incorporated the prod_info.md guidance to defer specific OPA policy rules to the external governance document. If the resource file (`resources/05-multi-tenant-analytics.md`) does not yet have a "system catalog leak path" subsection explicitly covering `system.runtime.queries` / `system.runtime.nodes` / `system.runtime.tasks`, the teacher should add one — the responder gave a strong answer here but a future weaker pull could miss this without explicit resource coverage. The subsection should also briefly mention Query Rules (queryOwner + view permission) as a finer-grained alternative to a blanket catalog-level deny, for cases where you want users to be able to see their own running queries via the Web UI.

Minor beginner-clarity improvement opportunity: add inline glosses for "catalog-level rule" (a Trino access-control rule that applies to an entire catalog, before any table or column rules are evaluated) and "P0" (severity tier — drop everything and fix) on first use.
