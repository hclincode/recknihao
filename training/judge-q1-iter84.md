# Judge Score — Iter 84 Q1

## Score: 4.38 / 5.0
| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 4.5 |

## Points covered
- Multi-tenant analytics: isolating customer data in SaaS
  - Two enforcement patterns presented: per-tenant view + GRANT/REVOKE, and OPA as external policy engine
  - Concrete failure scenario worked through: "what happens when ad-hoc query forgets `WHERE tenant_id = ?`"
  - Critical detail flagged: default Trino permission model is allow-all, so REVOKE on base table is required, not optional
  - Scale guidance: views < 150 tenants, OPA above
  - Production-fit note: prod stack already uses OPA, so policies live in external governance doc — Rego is presented as pseudocode rather than fabricated
  - Verification commands: connect as tenant role and run both queries (success on view, denied on base table)

## Accuracy notes
Verified via WebSearch against trino.io docs:
- Trino built-in system access control: default is "all operations permitted, except for user impersonation" — answer's claim that GRANT alone is insufficient and explicit REVOKE is needed is correct for the built-in model.
- `REVOKE ALL PRIVILEGES` syntax: confirmed valid; ALL PRIVILEGES expands to DELETE, INSERT, SELECT in Trino 476/481 docs (same in 467).
- OPA access-control plugin in Trino: confirmed as a first-class authorization plugin; contacts OPA per query, returns boolean `allow`, supports row filters and column masking.
- View-as-tenant-filter pattern: documented as a multi-tenant approach in industry practice, though search results emphasized OPA row-filter / database-level RLS as more modern and dynamic. The answer's framing (views simpler, OPA more powerful) is fair.
- "Rejection happens during analysis phase before MinIO files are opened": this is the documented intent, but GitHub issue trinodb/trino#22804 notes that Trino sometimes checks metadata before access control, so the strict ordering claim is slightly idealized. Minor inaccuracy, not a blocker.

## Issues / gaps
1. **GRANT/REVOKE vs OPA enforcement layer confusion** (Technical accuracy -1). The answer presents SQL `GRANT SELECT ... TO ROLE acme_role; REVOKE ALL PRIVILEGES ... FROM USER ...` as the enforcement mechanism for the view approach. In the production environment described in `prod_info.md`, OPA is the authorization backend — SQL-level grants are not the enforcement layer at all. When OPA is configured, the access-control plugin replaces the SQL grant model. The answer should have noted that in this stack, the engineer would need to request an OPA policy change ("acme-service-account may select tenant_acme.events but not analytics.events"), not run a REVOKE statement. The current framing could mislead the engineer into running SQL that has no effect.
2. **OPA row filters not explained as a third option** (Completeness -0.5). OPA can return row-filter expressions that Trino applies as an automatic WHERE clause — this is arguably the closest match to what the engineer asked ("automatically filter rows based on who's running the query"). The answer references row filters only in passing in Approach 2's preamble; it never shows that OPA's row-filter mode is the direct answer to "auto-inject the tenant_id filter without creating per-tenant views." This is a meaningful gap given the question wording.
3. **Column masking unmentioned**. Adjacent OPA capability worth a one-line callout.
4. **"Analysis phase before files opened on MinIO" is slightly overconfident**. The documented intent is correct; the runtime behavior has known edge cases per Trino GitHub issues. Not a blocker but worth softening.
5. **Trino view security mode unmentioned** (`SECURITY DEFINER` vs `SECURITY INVOKER`). The view-as-isolation pattern depends on the view running with definer privileges so the tenant role does not need direct base-table access. Iter 64 Q1 covered this — the topic exists in the resource base but is missing here. The REVOKE workaround is essentially a substitute, but mentioning SECURITY DEFINER would have been the canonical pattern.

## Production fit
- Stack alignment: stays on Trino + Iceberg + MinIO + OPA (all on-prem, per `prod_info.md`). No cloud-only services suggested.
- Auth governance deference: correctly says Rego policies live in the external governance document and presents Rego as pseudocode rather than inventing concrete rules. This is the right behavior for OPA-managed environments.
- Slight production-fit deduction: the SQL GRANT/REVOKE pattern is described as "what to do" without flagging that in the OPA-backed production stack, the engineer cannot enforce isolation with SQL alone — they need the OPA policy change. This is the most important practical-applicability gap.

## Resource fix needed?
No required fix — topic average remains well above pass threshold. Two optional polishes:
1. In `resources/05-multi-tenant-analytics.md` (or wherever the views vs OPA section lives), add a brief OPA-row-filter section showing that OPA can inject a per-tenant WHERE clause automatically without per-tenant views — this is the most direct answer to "automatically filter rows based on who's running the query."
2. Add a one-line note distinguishing the SQL GRANT/REVOKE enforcement model from OPA-plugin enforcement: in an OPA-managed cluster, SQL grants are bypassed; the engineer must request a policy change rather than run REVOKE.
