# Iter 12 Q2 — Internal ops admin role vs per-tenant view isolation

## Question summary
Engineer has per-tenant Trino views that filter to a single tenant. The ops team wants cross-tenant aggregate dashboards. The question is whether to build a second set of views for internal use or give ops users direct access to the base tables.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core pattern (separate role with direct base-table SELECT, REVOKE on base table from tenant roles) is correct and maps to valid Trino SQL. "System access control plugin runs before query execution" is imprecise — access control fires during analysis/planning (post-parse, pre-execution), not strictly "before query execution"; the practical outcome described is accurate but the phrasing would not survive a security audit. File-based rules vs OPA mentioned but no warning that file-based rules require `security.refresh-period` to hot-reload (coordinator restart otherwise required). |
| Beginner clarity | 4 | Clear conceptual separation (customer role vs ops_admin role) established early. SQL is readable and grounded. "System access control plugin" introduced without definition. `partition strategy (tenant_id, day(event_ts))` assumes Iceberg familiarity. The "Access Denied before data is touched" outcome is well-explained. |
| Practical applicability | 4 | Directly answers "separate views or not?" (no). Provides runnable CREATE ROLE / GRANT / REVOKE SQL. Useful Spark separation callout. Missing: no `GRANT ops_admin TO USER <username>` step — the ops_admin role exists but there is no instruction for assigning users to it. An engineer who runs the SQL verbatim ends up with a role nobody is in. |
| Completeness | 4 | Core question answered. Performance callout (date-pruned cross-tenant queries) is useful. Missing: (1) `GRANT ROLE ops_admin TO USER` step to actually attach users to the role; (2) no mention of admin-level aggregate views as a performance option on top of direct base-table access (relevant when ops dashboards are expensive); (3) no restart/refresh warning for file-based rules. |
| **Average** | **4.00** | |

## Topic updated

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

- Prior avg: 3.958 (6 questions)
- New score this question: 4.00
- New running avg: (1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00 + 4.00) / 7 = **3.964**
- Status: PASSED (avg 3.964 >= 3.5 threshold, 7 questions asked)

## Key finding

The answer correctly solves the question's central tension (roles + direct base-table access for ops, no extra view layer required) and gives runnable SQL, but omits the `GRANT ROLE ops_admin TO USER <username>` step needed to actually assign a user to the new role. An engineer who follows the code exactly ends up with an unreachable role. The "access control runs before query execution" framing is also imprecise (it fires during analysis/planning), though the practical effect (denied before data is read) is correct.

## Resource gap

`resources/05-multi-tenant-analytics.md` should add:
1. A `GRANT ROLE <role_name> TO USER <username>` example immediately after the `CREATE ROLE` block — this is the step that makes the role usable and is currently absent from the answer pattern.
2. A one-sentence clarification that access control fires during query analysis (not strictly "before execution"), with the practical implication: "Trino rejects the query before any data is read from MinIO."
3. A note that file-based system access control requires either a coordinator restart or `security.refresh-period=<interval>` in `etc/access-control.properties` to pick up rule changes; OPA hot-reloads natively. This has been flagged in prior iterations (Iter 3 Q3, Iter 4 Q5, Iter 5 Q5) and remains absent.
