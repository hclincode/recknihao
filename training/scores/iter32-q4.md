# Iter32 Q4 Score

**Question**: Onboarding a new enterprise customer next week. What are all the steps to complete before they can run their first Trino query? Build a repeatable 30-minute provisioning checklist.
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 3.5 |
| Completeness | 3.5 |
| **Average** | **4.0** |

**Feedback**: Resource-groups JSON uses only valid Trino property names (hardConcurrencyLimit, softMemoryLimit, subGroups, maxQueued) — iter31 fix is holding. JWT principal vs Trino role name selector gotcha correctly called out. GRANT + REVOKE both present and framed as mandatory. Per-step time estimates make the SLA concrete. Three gaps: (1) ingestion CronJob + initial full refresh entirely absent — without data flowing in, the tenant hits empty views on Day 1; (2) OPA not mentioned as the production authz backend; specific tenant policies live in the external governance document; (3) automation wrapper missing — the question asks for a repeatable 30-minute process but delivers a manual one-time checklist. File-based resource group changes require coordinator restart — not flagged under the "1 minute" step. CREATE SCHEMA step implicit but not shown. HTML entities.
