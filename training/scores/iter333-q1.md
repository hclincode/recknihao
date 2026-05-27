# Iter 333 — Q1 Score

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Question summary**: Trino resource limits (memory/time) per single query, with different limits per customer tier on a shared cluster.
**Current rubric avg before this score**: 4.479 across 127 questions

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All property names, file layout, and diagnostic SQL verified against official Trino docs. |
| Beginner clarity | 4.5 | "Lanes on a highway" analogy is excellent; free/enterprise selector example is concrete. Minor: "queues vs rejects" distinction could be clearer for a true beginner. |
| Practical applicability | 5.0 | JSON config is runnable as-is; selectors map directly to the SaaS engineer's JWT-based usernames; operational notes include live-incident playbook + DB-backed hot-reload alternative. |
| Completeness | 4.5 | Covers resource group concept, three limits, two-file setup, selector routing, diagnostic query, restart constraint, kill_query for incidents. Missing: no mention of per-query `query_max_memory` / `query_max_run_time` session-level caps (the question explicitly asks "how much memory OR TIME any single query is allowed to use" — the time dimension is not directly addressed). Also no CPU limits (`softCpuLimit`/`hardCpuLimit`) which would be the natural way to bound long-running runaway queries. |
| **Average** | **4.75** — PASS | |

## What worked

- **Technical accuracy is airtight**. Every Trino-specific claim verified:
  - `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued` are the exact official property names.
  - Two-file setup (`resource-groups.properties` pointer + `resource-groups.json` definition) is correct and matches resource 05 guidance.
  - `resource-groups.configuration-manager=file` is the correct property value.
  - `system.runtime.queries` does expose `resource_group_id` (added in Trino 0.206 per release notes).
  - File-based RG requires coordinator restart; DB-backed variant supports refresh-interval (1s default).
- **"Lanes on a highway" analogy** lands cleanly for a beginner.
- **JSON config is directly usable** — root + free_tier + enterprise_tier subgroups with sensible numbers, plus a fallback selector.
- **Selectors tied back to the engineer's JWT auth context** — concrete production fit.
- **Live-incident playbook** (`system.runtime.kill_query` → deploy → restart) bridges the gap between "config" and "what do I do when the runaway is happening RIGHT NOW".
- **Hot-reload alternative** flagged with its trade-off (extra DB dependency) so the engineer can choose.

## What missed

1. **Time dimension under-addressed**. Question asks about capping memory OR TIME per single query. Answer covers memory + concurrency, but does not mention:
   - `query_max_run_time` session property / coordinator config for per-query wall-clock cap.
   - `query_max_execution_time` for execution-phase cap.
   - `softCpuLimit` / `hardCpuLimit` at the resource group level (rolling CPU quota).
2. **No mention of `query_max_memory_per_node`** or per-query memory caps — only group-level memory. A single query can still hog a node if not capped per-query, even inside a tight group.
3. **Selector ordering nuance not flagged** — Trino evaluates selectors top-to-bottom; the catch-all `{"group": "global"}` at the end is correct, but a beginner might not realize order matters.
4. **No JMX / metric pointer** for monitoring queued query counts per group (useful for "is my free tier always queueing?" follow-up).

## Technical accuracy verification results

Verified against [Trino Resource Groups docs](https://trino.io/docs/current/admin/resource-groups.html) and Trino 467 references:

| Claim | Verified? | Notes |
|---|---|---|
| `softMemoryLimit` exists as RG property | YES | Optional, absolute or percentage string. |
| `hardConcurrencyLimit` exists as RG property | YES | Required field. |
| `maxQueued` exists as RG property | YES | Required field; new queries rejected when hit. |
| Two-file setup (`resource-groups.properties` + `resource-groups.json`) | YES | Matches resource 05 line 2266; pointer file registers JSON. |
| `resource-groups.configuration-manager=file` | YES | Exact property name. |
| `system.runtime.queries.resource_group_id` column exists | YES | Added in Trino 0.206, confirmed in release notes. |
| File-based RG requires coordinator restart | YES | Resource 05 line 2463 confirms; DB-backed alternative supports `refresh-interval=1s`. |
| `system.runtime.kill_query` syntax | YES | Standard Trino runtime procedure. |
| Selector key is `"user"` (not `"userRegex"`) | YES | Resource 05 line 2253 explicitly warns about this; answer uses correct `"user"`. |
| JSON config structure (rootGroups / subGroups / selectors) | YES | Matches official docs example. |

No fabrications. No invented property names. Selector key correct.

## Topic running average update

Multi-tenant analytics: (4.479 × 127 + 4.75) / 128 = **4.481 / 128 questions** — PASSED (stable, slight upward drift from this strong answer).
