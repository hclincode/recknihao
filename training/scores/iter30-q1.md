# Iter30 Q1 Score

**Question**: Noisy-neighbor tenant consuming 80% of cluster resources. How to identify the culprit and enforce per-tenant resource limits in Trino without revoking access?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 2.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 3.0 |
| Completeness | 3.75 |
| **Average** | **3.44** |

**Feedback**: Structure (Identify → Limit → Fix underlying query) and "noisy neighbor" framing are strong. Multiple production-breaking technical errors in the resource-groups.json: `maxRunning`, `maxMemoryPercent`, `maxCpuPercent`, and `queues` are not valid Trino resource group property names (verified against trino.io/docs). Correct names are `hardConcurrencyLimit` (integer), `softMemoryLimit` (e.g., "10GB"), and `subGroups`. System table confusion: diagnostic SQL queries `system.runtime.tasks` for columns (`user`, `bytes_read`) that live on `system.runtime.queries` — the query fails. Missing `CALL system.runtime.kill_query()` as immediate-relief step during the live incident. JWT principal vs Trino role name distinction correctly noted but not explicitly contrasted. Coordinator restart correctly required. HTML entities.
