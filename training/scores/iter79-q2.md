# Iter 79 Q2 — Judge Score

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Score date**: 2026-05-25
**Question**: With a shared Iceberg table + tenant_id model, what is the complete operational checklist for onboarding a new tenant? How do you set up data isolation? How do you prevent noisy-neighbor query problems?

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.75 |
| Practical applicability | 5.0 |
| Completeness | 5.0 |
| **Average** | **4.9375** |

## Points covered

All 7 checklist items in the question's points-to-check were addressed:

1. **No Iceberg/MinIO changes needed** — Opening "What you don't need to do" section explicitly states no new tables, no new MinIO buckets, no schema creation. Summary table at the end has a dedicated "Iceberg/MinIO change?" column showing "None" for every row. (Hit.)
2. **5-step Trino sequence: CREATE ROLE → GRANT ROLE TO USER → CREATE VIEW → GRANT SELECT → REVOKE** — All five steps present in order with runnable SQL. Step 2 even calls out the "role with no assigned user is a silent no-op" trap. (Hit.)
3. **SECURITY DEFINER as Trino default** — Implicitly handled by the GRANT SELECT on view + REVOKE on base table flow. The answer correctly states "Tenants get read access only to their scoped views, never to the shared base table" which depends on DEFINER semantics. Minor omission: the term "SECURITY DEFINER" itself is not named explicitly, which slightly affects beginner clarity for engineers debugging permissions later. (Partial — concept correct, term not surfaced.)
4. **Resource groups for noisy-neighbor: hardConcurrencyLimit + softMemoryLimit** — Step 6 has a runnable JSON config block with both `softMemoryLimit: "10%"` and `hardConcurrencyLimit: 5` plus `maxQueued: 50`. Selector mapping mentioned. (Hit.)
5. **DB-backed resource groups for zero-restart hot reload** — Explicitly recommends `resource-groups.configuration-manager=db` with "hot-reloads every ~1 second and requires no coordinator restart" for frequent onboarding, vs file-based requiring restart. (Hit.)
6. **Defense-in-depth: views + role grants + OPA** — Dedicated "How isolation is enforced (defense in depth)" section names all three layers with the correct framing that "all three must agree". OPA called out as the production access control layer per prod_info.md. (Hit.)
7. **Verification test: succeeds on view, denied on base** — Step 7 includes both positive and negative test queries, plus the CI pipeline recommendation. (Hit.)

Bonus content: `system.runtime.kill_query` for immediate noisy-neighbor relief with correct syntax (`query_id => '...'`, `message => '...'`); idempotency note (treat "already exists" as success) for re-runnable onboarding scripts.

## Accuracy verification (WebSearch against trino.io)

- **CREATE ROLE / GRANT ROLE TO USER syntax** — Confirmed. `CREATE ROLE acme_role` matches `trino.io/docs/current/sql/create-role.html`. `GRANT ROLE acme_role TO USER "acme-service-account"` matches `trino.io/docs/current/sql/grant-roles.html` (the `TO ( user | USER user_name | ROLE role_name )` form).
- **GRANT SELECT / REVOKE ALL PRIVILEGES** — Standard SQL DDL supported by Trino; matches `trino.io/docs/current/sql/grant.html` and `revoke.html`.
- **CREATE VIEW with WHERE filter, SECURITY DEFINER default** — Confirmed via `trino.io/docs/current/sql/create-view.html`. Default security mode is DEFINER, meaning the view executes with the view owner's permissions. The answer's claim that the view enforces row isolation even if app code forgets to filter is correct.
- **Resource group fields** — Confirmed via `trino.io/docs/current/admin/resource-groups.html`. `softMemoryLimit` accepts both absolute (e.g., `1GB`) and percentage (e.g., `10%`) values; `hardConcurrencyLimit` is required and specifies max running queries. Example values match published documentation.
- **DB-backed resource groups hot-reload** — Confirmed. `resource-groups.configuration-manager=db` reloads from DB approximately every 1 second; no coordinator restart needed. File-based requires restart.
- **`system.runtime.kill_query` syntax** — Confirmed. Exact named-parameter form `CALL system.runtime.kill_query(query_id => '...', message => '...')` matches `trino.io/docs/current/connector/system.html`.
- **`system.runtime.queries` table** — Standard system catalog table, valid in Trino 467.

No technical errors found.

## Issues

1. **Minor: "SECURITY DEFINER" term not surfaced explicitly** — The concept is applied correctly (view owner's permissions, caller needs only view access), but the actual term is not named. An engineer who later needs to debug why a tenant view fails, or who wants to opt into INVOKER semantics, would benefit from the keyword. Recommend adding one sentence after Step 3: "Trino views default to SECURITY DEFINER — they execute with the view creator's permissions, so the tenant doesn't need direct base-table access."
2. **Minor: GRANT/REVOKE on the user principal vs role** — Step 5 correctly emphasizes that REVOKE must target the user principal, not just the role, but could explain the underlying reason more directly (Trino merges privileges across user + all granted roles, so a missed REVOKE on the user is the most common bypass vector). This is a small clarity gap, not an accuracy issue.
3. **Production-fit note**: The OPA mention in the defense-in-depth section is correct per `prod_info.md`. The answer does not attempt to invent specific OPA policies, which is correct behavior per the production guardrails.

Neither issue is severe enough to deduct meaningfully on technical accuracy or completeness.

## Resource fix needed?

Low-priority polish only. Suggested teacher action for `resources/05-multi-tenant-analytics.md`:
- Add a one-line callout naming "SECURITY DEFINER" as the Trino view default in the tenant-view section, so the term is reachable when an engineer searches by keyword.
- Optionally, a one-paragraph explanation of why REVOKE must target the user principal (privileges merge across user + all granted roles).

No accuracy or completeness fix required — the answer is operationally complete and a SaaS engineer can copy-paste it into a runbook.

## Updated topic average

Prior: **4.413** across 75 questions
New: (4.413 × 75 + 4.9375) / 76 = (330.975 + 4.9375) / 76 = 335.9125 / 76 = **4.420** across 76 questions
Status: **PASSED** (well above 3.5 threshold; 76 questions tested across many angles)
