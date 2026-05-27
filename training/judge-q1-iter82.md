# Judge Score — Iter 82 Q1

## Score: 4.25 / 5.0
| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 4 |

## Points covered
- **Cohort retention SQL pattern**: two CTEs (signups week 0, activity week 4) joined via LEFT JOIN on `(user_id, tenant_id)`, with `COUNT(*)` vs `COUNT(a.user_id)` for cohort size vs retained count. Standard and correct.
- **Partition pruning explanation**: correctly explains that Iceberg evaluates the two WHERE filters (event_ts range + tenant_id) independently and reads only the intersection of day partitions and tenant_id partitions.
- **Multi-week gap insight**: correctly explains that weeks 1–3 are skipped because partition pruning operates at the metadata layer per file, not as a continuous scan.
- **Multi-tenant scale framing**: 100 tenants × 52 weeks = ~5,200 partitions, with a per-tenant retention query touching ~2 — accurate intuition.
- **Two production gotchas**: (a) application-layer-only tenant filter is a security bug (must use views + OPA), (b) tenant_id filter without time range scans all-time for the tenant — both correct and well-targeted.
- **Production-stack fit**: mentions Trino views + OPA enforcement (matches the prod_info.md JWT + OPA stack); no cloud-only services referenced.
- **Real-world sizing example**: ~5 TB table, ~20 GB scan, 5–15 second query — plausible and concrete.

## Accuracy notes
**WebSearch verification against trino.io and Iceberg docs:**
1. **Independent partition pruning across two columns** (`day(event_ts)` and `tenant_id`): Verified. Iceberg evaluates partition predicates per filter and prunes manifests/data files at the intersection. AWS Prescriptive Guidance and Starburst's Iceberg partitioning blog both confirm multi-column partition pruning works when each filter is a direct predicate on the partition column (or its transform).
2. **CTE + literal-date-range pattern prunes correctly**: Verified. The Trino "Just the right time date predicates with Iceberg" blog (trino.io/blog/2023/04/11/date-predicates.html) confirms that explicit `TIMESTAMP '...'` literals push down as Iceberg partition predicates. The known anti-pattern (LATERAL/correlated joins where the time filter ends up as a post-join filter — trinodb/trino#29156) does NOT apply here because both CTEs have independent literal date ranges, not correlated predicates derived from the other side of the join.
3. **`(day(event_ts), tenant_id)` as recommended layout for hundreds of tenants**: Generally reasonable. For tens-to-low-hundreds of tenants, direct tenant_id partitioning works; for thousands, `bucket(N, tenant_id)` is preferred to avoid partition-count explosion. The answer's "hundreds of tenants" scope matches the engineer's framing, so the recommendation is appropriate, though a one-line note that bucket transforms become necessary at 1000s would have strengthened it.
4. **Cohort SQL pattern (signups CTE + activity CTE + LEFT JOIN)**: Standard analytics pattern; matches the common dbt/Trino retention recipe. Correct.

## Issues / gaps
1. **SQL/prose inconsistency on tenant_id filter** (−1 on Technical accuracy, −1 on Practical applicability): The prose repeatedly says "for the target tenant" and the sizing example claims "1 tenant × 7 days = 20 GB," but the example SQL does **not** include `AND tenant_id = 'customer_x'` in either CTE's WHERE clause. The SQL as written would scan all tenants for the date ranges, then GROUP BY tenant_id at the end. An engineer who copies this SQL verbatim will get a much larger scan than the prose advertises. The answer should either (a) add `AND tenant_id = 'customer_x'` to both CTEs and remove the final GROUP BY, or (b) keep the all-tenant variant but rewrite the "20 GB / 5–15 seconds" math to reflect scanning all tenants.
2. **Doesn't address the "signup is in users table, activity is in events table" common variant** (−1 on Completeness): Many real SaaS schemas store signup_date on a `users` dimension and only login/activity events in the events fact table. The answer assumes a single events table with an `event_name = 'signup'` row. Worth a one-line note acknowledging the alternative join shape against a `users` table.
3. **Doesn't address the "what if my table isn't partitioned by `(day, tenant_id)` already" path** (−1 on Completeness): The engineer asked whether the query will "blow up" on their existing table — the answer assumes a recommended partition spec rather than diagnosing what the engineer might already have. A short sentence ("if your table is only partitioned by event date, the query still prunes by date but scans all tenants per day — fine for small tenants, painful at scale") would help.
4. **Minor**: `COUNT(*)` in the final SELECT counts rows from `signups_week_0`, which is one row per `(user_id, tenant_id)` after the GROUP BY — that's correct, but worth noting because a beginner reading `COUNT(*)` against a JOIN sometimes worries about double-counting.

## Resource fix needed?
**Low priority, optional polish.** The topic is well above the pass threshold (4.422 avg across 78 questions). If the teacher wants to address the gap:

- **`resources/05-multi-tenant-analytics.md` or `resources/09-analytical-query-patterns.md`** — add a "Cohort retention on a shared multi-tenant Iceberg table" worked example that:
  1. Shows the SQL with `AND tenant_id = 'x'` actually present in both CTEs (eliminating the prose-vs-SQL inconsistency seen in this answer).
  2. Shows the all-tenant variant separately, with its own sizing math.
  3. Notes the partition-pruning behavior is identical whether you join signups against a `users` dimension or against an `event_name = 'signup'` row in the events table.
  4. Adds a one-line note about bucket(N, tenant_id) at 1000+ tenants.

This is genuinely useful as a teaching artifact but not required — the topic average is solidly passing and the weak-ai-responder's answer here is above threshold (4.25 ≥ 3.5).
