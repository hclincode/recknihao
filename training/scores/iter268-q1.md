# Score: iter268-q1

**Score**: 4.94 / 5.0
**Pass**: YES (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All major claims verified against official Trino 480/481 docs. File-based manager does NOT support hot-reload — confirmed. `resource-groups.refresh-interval` is the correct property name and only works with `configuration-manager=db` (introduced in Release 405) — confirmed. The explicit warning that `config-refresh-period`/`reload-interval` do not exist directly addresses the iter267 failure. `schedulingPolicy: "weighted"` is a valid value — confirmed. `hardConcurrencyLimit`, `maxQueued`, `softMemoryLimit`, `schedulingWeight` are all valid properties — confirmed. Selector field names `source`, `user`, `group` are correct. Catch-all selector targeting the leaf `federation.global` (not the parent `federation`) is correct — the constraint "A resource group may have sub-groups OR accept queries, but not both" is explicitly enforced. `system.runtime.queries` with `resource_group_id` column for monitoring — confirmed. |
| Beginner clarity | 5 | Excellent layered structure: opens with the two-manager dichotomy, then concrete properties file examples, then a summary table. JSON example is realistic and shows the federation→subgroups pattern. Jargon (subgroup, leaf, catch-all, selector) is introduced with context. JDBC/CLI source examples make the abstract `source` matching tangible. |
| Practical applicability | 5 | Engineer gets a concrete action plan: edit JSON → restart coordinator → verify with system.runtime.queries query. Notes restart is brief (15-30s) and that active queries on workers continue, which addresses the operator's restart anxiety. Calls out the most common failure mode (client not setting `source`) and shows both JDBC and CLI fixes. Fits the on-prem k8s production environment in prod_info.md (file-based or db-based both work on-prem). |
| Completeness | 4.75 | Covers both managers, hot-reload property, schedulingWeight prioritization, the leaf-group selector constraint, the source-setting gotcha, and verification via system.runtime.queries. Minor gap: could have mentioned `system.runtime.queries` is only useful for currently RUNNING/QUEUED queries — for historical analysis the event listener or `web UI` is more typical. Also did not mention that the database manager's reload happens automatically every second by default (refresh-interval is for tuning), but this is a small nuance. |
| **Average** | **4.94** | |

## What the answer got right
- Direct, unambiguous statement that file-based manager requires coordinator restart (no hot-reload)
- Correct property name `resource-groups.refresh-interval` for db-based manager, with explicit warning that `config-refresh-period` does NOT exist (directly fixes iter267 regression)
- Correct catch-all selector targets the leaf group `federation.global`, not the parent `federation`, with explicit explanatory sentence about the leaf-group rule
- Valid `schedulingPolicy: "weighted"` value used correctly
- Correct monitoring query using `system.runtime.queries` with `resource_group_id` column
- Practical JDBC and CLI examples for setting `source` to fix routing
- Summary table at the end is a clean reference
- Fits the on-prem production stack — does not invent cloud-only tooling

## Gaps or errors
- Minor: the database manager's default reload behavior (every 1 second) is not explicitly stated — the answer implies `refresh-interval` is required, when in fact it's a tuning override
- Minor: `softMemoryLimit` at the root level "federation" with value "80%" is correct, but the answer does not explain that percentages are relative to cluster memory while absolute values (like "10GB") are also supported
- Minor: no mention of `queued_queries` and `running_queries` columns in `system.runtime.resource_groups` table, which is the most direct way to see per-group utilization

## Verified sources
- [Resource groups — Trino 480 Documentation](https://trino.io/docs/current/admin/resource-groups.html)
- [Release 405 (28 Dec 2022) — Trino documentation](https://trino.io/docs/current/release/release-405.html)
- [Why can resource-groups.refresh-interval only be set in db? — Discussion #24309](https://github.com/trinodb/trino/discussions/24309)
- [Control the frequency of configuration reload from DB backed resource group manager — Issue #14514](https://github.com/trinodb/trino/issues/14514)
- [Updating resource groups without restarting Trino — posulliv.github.io](https://posulliv.github.io/posts/dynamic-resource-groups/)
