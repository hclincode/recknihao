# Iter29 Q4 Score

**Question**: Moving to usage-based billing — charge per 1M rows scanned. How to extract per-tenant query usage from Trino and make it reliable enough for billing?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.88 |
| **Average** | **4.783** |

**Feedback**: Correctly identifies that `system.runtime.queries` is in-memory only and does not persist across coordinator restarts — this is the critical insight. CronJob collector with 5-minute interval and overlapping windows is the right durability approach. JWT principal to tenant_id lookup table mapping is correct and practical. Filter `state = 'FINISHED'` is required and present. Deduplication by query_id is important for billing correctness and included. HTTP event listener as more reliable alternative for billing-critical data is an excellent addition — push semantics avoid the polling gap problem. Billing SQL example with date_trunc('day') is practical. Minor: the answer could more explicitly call out that queries running when the coordinator restarts are permanently lost from `system.runtime.queries` — this is the main reliability argument for the HTTP event listener. Excluding internal query service accounts from billing is mentioned but could be more prominent as a billing correctness concern. HTML entities in code blocks.
