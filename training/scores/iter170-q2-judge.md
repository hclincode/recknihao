# Iter 170 Q2 Judge Score

**Date**: 2026-05-26
**Phase**: extended (post-final)
**Topic**: Trino federation / cross-source connectors (resource groups to isolate Postgres federation queries from internal Iceberg queries)
**Question**: 15 Postgres catalogs federated into Trino; cross-catalog joins crowd out internal Iceberg reports. Can Postgres federation queries be put into their own bucket, and what does the configuration look like?

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy (×2) | 4.5 | All major Trino 467 claims verified; minor imprecision on "hardConcurrencyLimit caps Postgres connections" (caps query concurrency; a single query can open multiple JDBC connections per split). |
| Beginner clarity | 4.5 | Clean two-file structure, kubectl restart command, inline explanations of selector semantics and JWT linkage. |
| Practical applicability | 5.0 | Engineer can paste-and-go: exact file paths (`etc/resource-groups.properties`, `etc/resource-groups.json`), full JSON example, deployment command, hot-tune alternative. Directly fits the on-prem k8s + JWT stack. |
| Completeness | 4.5 | Covers config, deployment, selectors, gotchas (silently-ignored property names, config.properties trap, restart-vs-hot-reload), and per-customer extension. Missing: how to verify the routing worked (`system.runtime.queries.resource_group_id`), CPU limits, soft limit semantics. |
| **Weighted (Tech×2)** | **(4.5×2 + 4.5 + 5.0 + 4.5) / 5 = 4.60** | **PASS** (general 3.5) / **PASS** (topic 4.5) |

---

## Verification (WebSearch against trino.io docs)

1. **`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`** — VERIFIED. Per Trino 480 docs (and consistent across recent versions including 467): `hardConcurrencyLimit` (required) = max running queries; `softMemoryLimit` (optional) = max distributed memory before queueing, may be absolute (`1GB`) or percentage (`80%`); `maxQueued` (required) = max queued queries before rejection. The example uses all three correctly. Source: https://trino.io/docs/current/admin/resource-groups.html
2. **`etc/resource-groups.properties` + `resource-groups.configuration-manager=file` + `resource-groups.config-file=...`** — VERIFIED. This is the canonical file-based registration pattern.
3. **Selectors match the JWT principal (`sub` claim)** — VERIFIED. Per Trino JWT docs (https://trino.io/docs/current/security/jwt.html), `http-server.authentication.jwt.principal-field` defaults to `sub`, and this populates the Trino principal/user. The resource-groups selector `user` field is a Java regex matched against the resolved Trino username, which equals the JWT `sub` value by default in this production setup. The phrasing is accurate.
4. **"Don't merge resource-groups settings into config.properties"** — VERIFIED as standard Trino plugin-loading pattern. Resource group manager plugin is loaded via its own properties file in `etc/`; settings placed in `config.properties` are not picked up by the resource group manager plugin.
5. **`resource-groups.configuration-manager=db` reloads every 1 second** — VERIFIED. Per Trino docs and GitHub issue #14514: "The configuration is reloaded from the database every second" — currently hardcoded (issue #14514 tracks making the interval configurable).
6. **`hardConcurrencyLimit: 8` caps concurrent Postgres connections** — PARTIALLY CORRECT but imprecise. It caps concurrent **queries**, not connections. A single federation query may open multiple JDBC connections (one per split/worker scanning a Postgres table). With 20 workers, an 8-query cap can still result in significantly more than 8 simultaneous JDBC connections. The wording "at most 8 customer federation queries can open Postgres connections simultaneously" is roughly correct at query level but conflates queries with connection count. Minor accuracy ding.
7. **"`maxRunning` / `queues` are silently ignored"** — These property names are not standard Trino resource-group fields, so the warning is technically valid, but flagging them as "common mistakes" feels arbitrary (they're not common typos). Low impact.

---

## Strengths

- **Correct fundamental architecture**: two separate properties files, file-based config-manager, JSON sub-groups with concurrency + memory + queue limits.
- **Production-fit deployment**: k8s rollout-restart command, named the actual coordinator deployment name pattern.
- **Hot-reload alternative**: correctly flags that file-based requires restart and points to `configuration-manager=db` with the 1-second reload behavior — directly answers "what if I need to tune without restarts."
- **JWT/selector integration**: correctly ties the `user` selector regex to the JWT `sub`-derived principal, which is the production auth mechanism.
- **Path to per-customer isolation**: gracefully extends the answer to address the natural follow-up of customer-level isolation without overcommitting.
- **No fabricated features**: unlike iter169 Q1, this answer does not invent or deny any Trino features.

---

## Gaps holding it below 5.0

1. **Connection-vs-query conflation** (Technical accuracy ding): `hardConcurrencyLimit` caps concurrent queries, not concurrent JDBC connections. For Postgres backpressure, the engineer should also size the PG connection pool (Trino PostgreSQL connector default + per-split parallelism) — the resource group limit and the connection pool are complementary, not equivalent. A more precise framing: "limits the number of concurrent federation queries; each query may open multiple JDBC connections per split, so combine with `postgresql.connection-pool.max-size` or PgBouncer for true connection caps."
2. **No verification path**: should mention `system.runtime.queries.resource_group_id` (or `SHOW RESOURCE GROUPS` if applicable) so the engineer can verify queries are landing in the intended group after deployment.
3. **Selector catch-all routes to `postgres_federation`**: the example's final selector `{ "user": ".*", "group": "global.postgres_federation" }` means *every* user not matching the data-team rule lands in the federation bucket — including internal Iceberg users not in `data-team`. A safer default is to route catch-all to a separate `default` sub-group or to the more conservative bucket. Minor design issue, not a correctness issue.
4. **Missing source/clientTags option**: when JWT principal is shared across query patterns, `source` (set via `--source` or JDBC `source` property) and `clientTags` (via `--client-tags` or `clientTags`) are often better selectors. A one-line callout would have helped engineers whose users submit both Postgres federation and Iceberg queries from the same JWT identity.
5. **No CPU control mention**: `hardCpuLimit` and `softCpuLimit` exist for time-based resource control; for heavy federation joins this can be relevant. Listed in the "What NOT to do" warning but not explained.

---

## Topic update

Trino federation / cross-source connectors — prior avg **4.061 across 18 questions** (after iter170 Q1 commit); new running avg (4.061 × 18 + 4.60) / 19 = (73.098 + 4.60) / 19 = **4.089 across 19 questions**.

**Status**: Still NEEDS WORK against 4.5 raised threshold. Q2's 4.60 helps modestly but the topic average remains well below threshold due to iter163/164/165/169 Q1 FAIL drag.
