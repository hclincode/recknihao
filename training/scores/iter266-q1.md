# Score: iter266-q1

**Score**: 3.50 / 5.0
**Pass**: NO (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Two material errors: (1) `http-server.max-connections` is NOT a real Trino property — the actual coordinator HTTP threading control is `http-server.threads.max` (Trino 480/481 HTTP server docs list no `max-connections` property). (2) The resource-groups.json property is `maxQueued`, not `maxQueuedQueries`. Trino docs are unambiguous: the required property name is `maxQueued`. `hardConcurrencyLimit`, `softMemoryLimit`, `rootGroups`, `subGroups`, and the `system.runtime.queries` + `state = 'QUEUED'` query are correct. The dual-layer framing (HTTP vs resource groups) is conceptually reasonable, but the recommended Layer-1 fix uses a wrong property name, which would mislead the engineer when they try to apply it. |
| Beginner clarity | 5 | Excellent layered presentation, plain-language symptom-to-cause table, concrete JSON and SQL snippets, no unexplained jargon. The "Critical Distinction" table is especially useful for a beginner. |
| Practical applicability | 3 | The structure is action-oriented and fits an on-prem k8s Trino 467 stack, but a beginner who pastes `http-server.max-connections=1500` into `config.properties` will hit a Trino startup failure (unknown config property), which is a hard regression. The `maxQueuedQueries` JSON key would similarly be rejected by Trino's resource-groups manager. These would block the engineer from successfully completing the recommended fixes. |
| Completeness | 4 | Covers diagnosis (UI + SQL), both queueing layers, fix options (raise limit / stagger / subgroup isolation), and prevention. Missing: no mention that file-based resource groups support hot reload via `resource-groups.config-refresh-period` (no coordinator restart strictly required for Fix 2), no mention of `softConcurrencyLimit` or selectors that decide which group a query lands in. The connection-layer discussion is overstated as a typical cause — most "stuck waiting" cases in practice are resource-group queueing. |
| **Average** | **3.75** | |

Note: Computed average is 3.75 but the overall score is 3.50 because the two incorrect property names are copy-paste-into-config-and-fail errors that meaningfully reduce trust in the answer; rounding down reflects the production-applicability risk on an on-prem Trino 467 cluster.

## What the answer got right
- Correct identification of `system.runtime.queries` with `state = 'QUEUED'` as the right diagnostic SQL.
- Correct property names: `hardConcurrencyLimit`, `softMemoryLimit`, `rootGroups`, `subGroups`, `name`.
- Correct semantic of `softMemoryLimit` (queues new queries when group memory exceeds threshold even if concurrency limit not reached).
- Good `etc/resource-groups.json` example structure with a parent + subgroup pattern.
- Clear symptom/problem/fix table aimed at a non-OLAP engineer.
- Good workload isolation guidance (dashboards vs exports subgroups).

## Gaps or errors
- **WRONG property name**: `http-server.max-connections` is not a valid Trino HTTP server property. The actual controls in Trino 480/481 HTTP server documentation are properties like `http-server.threads.max` (and on the client side `exchange.http-client.max-requests-queued-per-destination`). Recommending `http-server.max-connections=1500` in `config.properties` will cause coordinator startup to fail with an "unused configuration property" error.
- **WRONG property name**: `maxQueuedQueries` should be `maxQueued`. The Trino resource-groups documentation consistently uses `maxQueued`. Both JSON snippets and the prose use the wrong key — the file-based resource-groups manager will reject the file.
- Overstates the prevalence of HTTP-layer connection rejection as a cause of "queries waiting before they run" — for almost all SaaS users this is resource-group concurrency, not HTTP connection cap.
- Does not mention that file-based resource groups support hot reload via `resource-groups.config-refresh-period`, so restarting the coordinator may be unnecessary for Fix 2.
- Does not mention selectors (`selectors: [...]`) that route queries to a group — without selector config, the engineer cannot direct queries into the `analytics` or `dashboards` subgroup shown in the example.
- Does not mention `softConcurrencyLimit` (soft limit before scheduling weight kicks in), which is relevant to "prevent blocking other queries".
- 503 response example for HTTP rejection is plausible but not verified against documented Trino behavior for connection-pool exhaustion.

## Verified sources
- [Resource groups — Trino 480 Documentation](https://trino.io/docs/current/admin/resource-groups.html) — confirms `hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued` (NOT `maxQueuedQueries`), `rootGroups`, `subGroups`, `selectors`.
- [HTTP server properties — Trino 480 Documentation](https://trino.io/docs/current/admin/properties-http-server.html) — confirms `http-server.max-connections` is NOT a listed property.
- [Query management properties — Trino 481 Documentation](https://trino.io/docs/current/admin/properties-query-management.html) — no `http-server.max-connections` here either.
- [System connector — Trino 480 Documentation](https://trino.io/docs/current/connector/system.html) — confirms `system.runtime.queries` exists and tracks queued time and query state.
- [Trino Max Connection Exceeded 1024 (issue #25031)](https://github.com/trinodb/trino/issues/25031) — community discussion pointing to `exchange.http-client.max-requests-queued-per-destination` and HTTP thread settings, not `http-server.max-connections`.
