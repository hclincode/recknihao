# Iter 299 Q1 Judge Score

## Topic
Multi-tenant analytics: isolating customer data in SaaS

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 5.00 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification

Verified via WebSearch against Trino/Iceberg official docs and ecosystem articles:

1. **Iceberg partitioning syntax** `partitioning = ARRAY['day(occurred_at)', 'tenant_id']` — correct. Trino's Iceberg connector accepts identity transforms as bare column names alongside time transforms like `day(...)` in the ARRAY. Confirmed via trino.io connector docs and Starburst's Iceberg partitioning guide.
2. **`events$partitions` metadata table** with `partition.tenant_id`, `total_size`, `record_count` — correct fields and structure. The Iceberg `$partitions` table exposes the partition struct, record_count, file_count, and total_size; for identity partitions on `tenant_id`, `partition.tenant_id` dereferences the field as shown. Matches the existing resource guidance at `resources/05-multi-tenant-analytics.md` lines 90–108.
3. **Partition pruning behavior** — accurate. Iceberg's manifest-driven file pruning skips files belonging to other tenants when `tenant_id` is in the predicate.
4. **`tenant_id` cardinality at 80 values being safe** — correct. The high-cardinality concern (millions of partitions) does not apply at this scale; 80 partition values per day partition is well within healthy Iceberg metadata budgets.
5. **OPA as production Trino authorizer** — correct per `prod_info.md`. The answer correctly speaks in conceptual terms (DENY base table, ALLOW per-tenant view) without inventing specific OPA Rego rules — which fits the production guidance that specific policies live in an external governance document.
6. **Trino views with hard-coded filters** — correct standard pattern, matches resource guidance.
7. **Postgres RLS vs Iceberg file-level pruning contrast** — accurate. Postgres RLS evaluates per-row after reading, while Iceberg file-level skipping avoids reading non-matching files entirely.
8. **Whale tenant promotion to dedicated table** — correct architectural pattern, matches the documented promotion playbook in `resources/05-multi-tenant-analytics.md`.

No technical errors found.

## What worked

- **Direct answer up front**: opens with a clear "keep one shared table at 80 tenants; table-per-tenant is a mistake at your scale" — the engineer gets the recommendation before any explanation.
- **Three-model framing** maps to the three real options and explicitly says which one is recommended and why each alternative fails or is risky.
- **Defense-in-depth narrative**: clearly explains why physical partitioning + view + OPA gives belt-and-suspenders isolation that table-per-tenant promises but at far lower ops cost.
- **Production-stack alignment**: invokes Trino, Iceberg, and OPA exactly as `prod_info.md` describes. Avoids inventing specific OPA rules.
- **Operational realism**: surfaces concrete pain points of the alternative (UNION ALL across 80 tables, onboarding friction, schema drift) — the kind of detail an engineer can take to their team.
- **Whale-tenant escape hatch**: provides the next step if a tenant later outgrows the shared layout, including a runnable `$partitions` monitoring query.
- **Postgres RLS bridge**: explicitly contrasts the engineer's current isolation mechanism with the lakehouse equivalent — relates new concepts to what they already know.
- **Tidy summary table** at the end lets the engineer quote the recommendation back to their team.

## What was wrong or missing

Nothing material. Minor possible additions (not gaps):
- Could mention that view ownership/SECURITY DEFINER vs INVOKER matters in the Trino + OPA model, but at this question's scope this is appropriate to omit.
- Could explicitly note that JWT authentication carries the tenant identity into Trino so OPA can scope by principal — but this is one level deeper than the question asks.

Neither omission affects the score.

## Suggested topic score update
Old: 4.456 / 106 questions
New avg if this scores 5.00: (4.456 * 106 + 5.00) / 107 = (472.336 + 5.00) / 107 = 477.336 / 107 = **4.461 across 107 questions**
