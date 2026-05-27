# Iter 7 Q4 — Tenant-only partitioning skew: why big customers got slower

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Two concrete errors: (1) the answer quotes the resource's correct recommendation (`day(occurred_at), tenant_id`) then immediately reverses the order in the ALTER TABLE SQL (`ARRAY['tenant_id', 'day(occurred_at)']`), creating an internally inconsistent recommendation that contradicts `resources/10-lakehouse-partitioning.md` §"Partition spec for the 80-tenant SaaS case"; (2) the math "50M ÷ 365 days = ~140 partitions/year" is dimensionally wrong — the number of daily partitions for one tenant is 365 (one per day), not 136K; dividing event count by days does not produce partition count. Neither error is trivial: the order reversal degrades internal cross-tenant dashboards, and the math error will confuse an engineer who tries to verify it. |
| Beginner clarity | 4 | Opens with a concrete hook, explains skew via 50M-vs-1K contrast, and the "can't be split across workers" intuition is accessible. However, "compaction", "partition evolution", and "partition spec" are used without inline glosses; hidden partitioning (the Iceberg feature where `WHERE occurred_at >= ...` auto-derives the partition filter) is never mentioned, which is a real gap for someone learning why they don't write `WHERE event_day = ...`. |
| Practical applicability | 4 | The workflow — ALTER TABLE partition evolution + one-time rewrite_data_files + nightly compaction — is the correct sequence and is directly executable. Docked one point because the reversed partition order (tenant_id first) in the ALTER TABLE SQL will produce suboptimal file layout for time-range-first cross-tenant queries, which is the dominant internal-dashboard pattern. An engineer following this verbatim will get a functional but suboptimal layout. |
| Completeness | 3 | Covers diagnosis, partition evolution fix, historical rewrite, and small-files compaction — the four main pillars. Misses: (1) the `bucket(tenant_id, N)` recommendation from the resource for extreme single-tenant skew (the resource's anti-patterns section explicitly says "consider bucketing the big tenant"); (2) hidden partitioning behavior — the engineer doesn't learn that Trino auto-derives partition filters from regular column predicates; (3) the full maintenance schedule (rewrite_manifests weekly, expire_snapshots nightly with 30-day retention) that the resource provides and the prior Iter 3 Q2 answer surfaced. |
| **Average** | **3.5** | |

## Topic updated

**Topic**: Iceberg partition design for SaaS: strategies, small-files, compaction
**Prior avg / count**: 4.75 / 1 question (Iter 3 Q2)
**New running avg**: (4.75 + 3.50) / 2 = **4.125** across 2 questions
**Status**: PASSED (avg 4.125 >= 3.5 threshold, 2 questions asked)

## Key finding

The answer is internally inconsistent: it correctly quotes the resource's recommended partition order (`day(occurred_at), tenant_id`) but then implements it reversed in the ALTER TABLE SQL, producing a recommendation that would degrade internal cross-tenant dashboard performance. The dimensionally-wrong math (50M events ÷ 365 = ~140 "partitions") adds a second factual error that a careful engineer will catch.

## Resource gap

`resources/10-lakehouse-partitioning.md` — add a "Why order matters: day-first vs tenant-first" subsection immediately after the partition spec table in §"Common partition strategies for SaaS". The subsection should: (a) state explicitly that `day(occurred_at)` should be listed first because most dashboards filter by time range before tenant, making day-level pruning the primary I/O reduction lever; (b) show the ALTER TABLE partition evolution example with the correct order (`ARRAY['day(occurred_at)', 'tenant_id']`) so the responder does not reverse it when quoting; (c) add a one-sentence clarification that "number of partitions per year = tenants × days, not events ÷ days" to prevent the math error from recurring.
