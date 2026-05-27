# Score: iter267-q1

**Score**: 4.25 / 5.0
**Pass**: NO (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Property names for the JSON config (`maxQueued`, `hardConcurrencyLimit`, `softMemoryLimit`, `schedulingPolicy`, `schedulingWeight`) are correct. Selector field names (`source`, `user`, `group`) are correct and use Java regex. However, `resource-groups.config-refresh-period` is NOT a real property — the correct property is `resource-groups.refresh-interval`, and it ONLY works with the database-based configuration manager (`configuration-manager=db`). The file-based manager does NOT support hot-reload at all — this is a confirmed limitation in upstream Trino (see discussion #24309). Claiming file-based hot-reload works every 10s is factually wrong and will mislead an engineer. Also, the catch-all selector `{ "group": "federation" }` points to a non-leaf group (one with subGroups), which is an inconsistency point in Trino (see issue #6133) — queries to non-leaf groups produce inconsistent behavior. The "no selector matches → query rejected" claim is approximately correct but the answer doesn't show a proper leaf-group catch-all pattern (e.g., `global.adhoc.other.${USER}` style). |
| Beginner clarity | 4.5 | The "traffic cops for queries" metaphor is concrete and useful. Each property is explained with an example scenario (e.g., "if 10 dashboards are running and an 11th arrives, it waits"). Selectors-by-source examples for JDBC URL, CLI flag, and HTTP header are concrete and actionable. The "Common Property Name Mistakes" table is particularly helpful for a beginner. Could be slightly clearer on what `softMemoryLimit` actually accepts as values (the answer uses "20%" but doesn't explain that absolute sizes also work). |
| Practical applicability | 4.5 | Q1 maps directly onto the SaaS engineer's problem: route dashboards, exports, and ETL to separate pools. The example JSON is copy-paste ready and aligned with the question. The instructions on where to put files (`etc/resource-groups.properties` and `etc/resource-groups.json`) are correct for on-prem Trino on k8s. The `system.runtime.queries` verification query gives a concrete next step. The `config-refresh-period` claim, however, will cause real damage: an engineer who deploys this and edits the JSON expecting hot-reload will be confused when nothing changes — and may not realize they need to restart the coordinator. Did not mention that for the production env (on-prem k8s + JWT auth + OPA), selectors based on `user` may interact with how the JWT subject is mapped — minor omission given the production stack. |
| Completeness | 4.5 | Covers: what resource groups are, all three main limits, how selectors route queries, where clients set `source`, queue behavior (run/queue/reject/memory), example JSON for the exact use case in the question, verification via `system.runtime.queries`, common mistakes. Misses: that file-based config does NOT hot-reload, db-based vs file-based manager tradeoff, that the catch-all should point to a leaf group, brief note on how this interacts with cluster memory pools / `query.max-memory-per-node`. |
| **Average** | **4.25** | |

## What the answer got right
- All five JSON property names (`maxQueued`, `hardConcurrencyLimit`, `softMemoryLimit`, `schedulingPolicy`, `schedulingWeight`) — confirmed against Trino 480 docs
- Selector field names (`source`, `user`, `group`) and that they use Java regex
- `schedulingPolicy: "weighted"` is a valid policy (along with `fair`, `weighted_fair`, `query_priority`)
- Behavior when `maxQueued` is reached: query rejected — confirmed in docs
- Two-file setup (`resource-groups.properties` + `resource-groups.json`) is correct
- `resource-groups.configuration-manager=file` and `resource-groups.config-file=...` properties are correct
- `system.runtime.queries.resource_group_id` exists (array(varchar) type) and is the right way to monitor routing
- Strong "common mistakes" table specifically addresses prior iteration errors (`maxQueuedQueries` etc.)

## Gaps or errors
- **MAJOR: `resource-groups.config-refresh-period=10s` is fabricated.** The actual property is `resource-groups.refresh-interval`, AND it only works with the database-based configuration manager. The file-based manager does not support hot-reload — see Trino discussion #24309. The answer's claim "Trino hot-reloads the JSON file every 10 seconds — you can tune limits without restarting the coordinator" is incorrect for the file-based config it just showed.
- **MODERATE: Catch-all selector points to a non-leaf group.** `{ "group": "federation" }` targets the root group which has subGroups. Per Trino issue #6133, submitting queries to a non-leaf group produces inconsistent/buggy behavior. The idiomatic pattern is a leaf catch-all like `global.adhoc.other.${USER}` with `name` templating.
- **MINOR: No note on `softMemoryLimit` accepting both percentages ("20%") and absolute values ("10GB")** — beginner may not know both forms exist.
- **MINOR: Does not mention production-stack interaction.** Since the prod env uses JWT auth, the `user` selector matches the JWT subject after Trino's user mapping — worth a one-liner. Not penalized heavily because the question didn't ask about auth.
- **MINOR: Does not mention db-based resource group manager as an alternative** for teams that genuinely need dynamic updates without restart.

## Verified sources
- [Trino Resource Groups (current docs)](https://trino.io/docs/current/admin/resource-groups.html) — confirmed property names, selector fields, maxQueued behavior
- [Trino discussion #24309 — Why can resource-groups.refresh-interval only be set in db?](https://github.com/trinodb/trino/discussions/24309) — confirms file-based manager does NOT support hot-reload; only db-based does
- [Trino issue #6133 — Query Submission to Non-leaf Resource Groups](https://github.com/trinodb/trino/issues/6133) — confirms inconsistent behavior when selectors point to non-leaf groups
- [Trino issue #5464 — system.runtime.queries](https://github.com/trinodb/trino/issues/5464) — confirms `resource_group_id` column is array(varchar)
