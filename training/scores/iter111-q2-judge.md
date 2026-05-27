# Iter111 Q2 — Judge Verdict

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Question**: 200 tenants on shared Iceberg tables — 3-4 enterprise tenants dominate cross-tenant scan; can we structure data/query so small tenants don't wait?
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter111-q2.md`

---

## Technical verification (WebSearch)

| Claim | Verified | Notes |
|---|---|---|
| `iceberg.<schema>."events$partitions"` exposes `partition.<col>`, `record_count`, `file_count`, `total_size` | YES | Trino Iceberg connector docs confirm `$partitions` metadata table with `partition`, `record_count`, `file_count`, `total_size` columns. Answer correctly caveats that `partition.tenant_id` only works if `tenant_id` is in the current partition spec — matches Trino issue #12323 (`$partitions` only reflects current PartitionSpec). |
| `CREATE TABLE ... AS SELECT ... WHERE tenant_id = 'acme'` valid Trino Iceberg CTAS | YES | Confirmed in `trino.io/docs/current/sql/create-table.html` and Iceberg connector docs. CTAS with WHERE filter is supported. |
| `DELETE FROM iceberg.<schema>.events WHERE tenant_id = 'acme'` valid Trino Iceberg | YES | Trino Iceberg connector supports row-level DELETE via merge-on-read positional delete files. |
| `CREATE OR REPLACE VIEW` valid Trino syntax | YES | Confirmed in `trino.io/docs/current/sql/create-view.html` — `CREATE [OR REPLACE] VIEW view_name AS query`. |

All four key SQL constructs in the answer are valid Trino 467 / Iceberg 1.5.2 syntax.

---

## Scoring

### Technical accuracy — 5/5
- Root cause framing (partition skew on no-filter cross-tenant scan) is correct.
- Correctly notes that `WHERE tenant_id = X` prunes via partition pruning, but cross-tenant scans cannot prune.
- Bucketing observation is right: `bucket(tenant_id, 32)` reduces manifest bloat at 100+ tenants but does not fix skew on cross-tenant scans.
- `$partitions` metadata-table query syntax is correct and the caveat about `partition.tenant_id` requiring `tenant_id` in current spec is accurate (Trino Iceberg issue #12323).
- CTAS, DELETE, CREATE OR REPLACE VIEW all valid Trino 467 / Iceberg 1.5.2 forms.
- Cutover sequence (create dedicated → verify → swap view → delete last) is safe and correct; explicitly preserves shared table as backup until step 4.
- OPA row-filter section honors the prod_info.md constraint (mentions OPA conceptually for per-tenant injection, does NOT invent Rego rules).
- Honestly states OPA row-filter does NOT solve the cross-tenant report problem — exactly right.
- Minor: the `$partitions` query uses `partition.tenant_id` without addressing that on a `bucket(tenant_id, 32)` spec the column would be `partition.tenant_id_bucket` (INT bucket id, not the tenant value). On identity-partitioned tenant_id it works as written. Acceptable because the answer explicitly hedges this.

### Beginner clarity — 4.5/5
- Excellent framing ("not a throw-more-hardware problem — it's partition skew + multi-tenant").
- Each solution clearly tagged with effort tier (lowest effort / recommended long-term / for per-tenant queries).
- "Recommended approach" prioritization at the end (immediate / sprint / ongoing) is exactly what a SaaS engineer needs.
- Tiny gap: terms like "manifest bloat" and "partition pruning" are used without one-line definitions. A pure beginner would benefit from a brief gloss. Most SaaS engineers in this codebase already know enough to follow, so it's a minor deduction.

### Practical applicability — 5/5
- Concrete, runnable SQL for every step.
- 4-step migration sequence with the critical safety guarantee ("shared table is backup until step 4").
- Explicit rollback plan if anything fails before step 4.
- Threshold heuristic ("3 tenants >50 GB, 197 under 1 GB" → migrate; ">10M rows at onboarding → dedicated table from the start") gives the engineer a decision rule.
- Notes the post-migration shape: enterprise dashboards hit dedicated tables, internal report hits shared + UNION ALL across dedicated.
- Acknowledges OPA row-filter doesn't fix the asked problem rather than padding the answer.

### Completeness — 4.75/5
- Addresses both halves of the question: (a) restructure data (solutions 1 & 2), (b) is it hardware (no, with reason).
- Covers the immediate fix (rollup) and the durable fix (dedicated tables).
- Distinguishes per-tenant query problem from cross-tenant scan problem.
- Small gap: doesn't discuss Trino resource groups / query memory caps as a complementary lever (e.g., enterprise customer queries getting their own resource group so they don't starve small-tenant queries). This is a known angle on this topic and would round out the answer. Also doesn't mention sort order within partitions (`sorted_by = ARRAY['event_ts ASC']`) as another way to help even the cross-tenant scan. These are nice-to-haves, not required.

---

## Weighted score

(5 + 4.5 + 5 + 4.75) / 4 = **4.8125 / 5**

Pass threshold (≥ 3.5): **PASSED** comfortably.

---

## Errors / gaps

1. **Bucketed-tenant `$partitions` column name**: If the table is bucket-partitioned on tenant_id, the `$partitions.partition.tenant_id` column does not exist — it would be the bucket id. The answer hedges with "if the query errors, you don't have tenant_id as a partition column," which covers this, but doesn't explicitly mention the bucketed case. Minor.
2. **Resource groups not mentioned**: A practical complementary lever (enterprise queries in their own resource group with hardMemoryLimit cap) is missing. Would round out the "throw hardware at it" framing.
3. **Sort order**: `sorted_by = ARRAY['event_ts ASC']` for row-group min/max skipping on time-bounded cross-tenant scans is a relevant additional structural fix not mentioned.

---

## Resource fix recommendations

Topic running average is already 4.46 (PASSED) and this answer scores higher. No urgent resource fixes required. Optional polish:

- **resources/05-multi-tenant-analytics.md** (LOW): Add a note that on bucket-partitioned tables the `$partitions.partition.<col>` becomes `partition.<col>_bucket` (an INT bucket id), so per-tenant size queries on a bucketed spec must aggregate differently (group by bucket id, or fall back to `GROUP BY tenant_id` on the data table with a low-effort COUNT(*) sample).
- **resources/05-multi-tenant-analytics.md** (LOW): When discussing "dedicated tables for whale tenants," cross-reference the resource-groups section so engineers know to also cap memory/concurrency per tenant class.

Neither rises to the level of blocking another iteration.

---

## Running average update

- Prior: 4.458 across 105 questions
- This score: 4.8125
- Sum prior: 4.458 × 105 = 468.09
- New sum: 468.09 + 4.8125 = 472.9025
- New average: 472.9025 / 106 = **4.4626** across 106 questions

Status: **PASSED** (well above 3.5 threshold; topic has been tested across 100+ questions from many angles).
