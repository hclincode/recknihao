# Score — Iter285 Q2

**Score: 4.83/5.0 PASS**

## Breakdown
- Technical accuracy (40%): 5/5 — Verified against Trino 480 docs: no `catalog`/`connector` selector exists; valid selectors include `user`, `originalUser`, `authenticatedUser`, `userGroup`, `source`, `clientTags`, `queryType`, `sessionPropertyFilters` — the answer's enumeration is correct. `hardConcurrencyLimit` and `maxQueued` are the correct required property names per docs. The claim that file-based resource group config requires coordinator restart is correct (DB-backed has 1s hot reload, but the answer uses file-based and correctly notes the restart requirement). `prepareThreshold=0` is confirmed as the canonical fix for PgJDBC + PgBouncer transaction pooling. Reasoning that routing happens "before query parsing" so catalog can't be a selector is accurate.
- Completeness (25%): 5/5 — Covers all three valid layers (Postgres CONNECTION LIMIT, PgBouncer transaction pooling, Trino resource groups via source header). Includes selector enumeration, the source-tagging workaround for catalog routing, restart semantics, and a decision matrix. Mentions that PgBouncer 1.21+ alternative (max_prepared_statements) is not strictly required to teach, but using `prepareThreshold=0` is the safer baseline answer.
- Production fit (20%): 5/5 — Targets on-prem Trino 467 with k8s (mentions ConfigMap + rolling coordinator pod, `*.svc.cluster.local` DNS, catalog file paths under `etc/catalog/`). Correctly notes OSS Trino 467 has no native PostgreSQL pooling and avoids Starburst-only features. PgBouncer recommendation fits on-prem with no cloud-managed pooler assumption.
- Clarity (15%): 4/5 — Three-layer structure is well-organized with code blocks, limitations called out, and a closing decision matrix with immediate next steps ("today" vs "this week"). Minor nit: Layer 1 says "no Trino restart needed" which is only true if the catalog already uses that role; switching to a new role would require catalog reload/restart. Could be slightly clearer on this edge case.

## What was correct
- Definitive "no, Trino has no catalog selector" with the correct reason (routing precedes query parsing)
- Complete and accurate selector enumeration
- Three-layer architecture: DB-level cap, PgBouncer queuing, Trino resource groups
- `prepareThreshold=0` requirement for PgJDBC + PgBouncer transaction pool
- Correct `hardConcurrencyLimit` / `maxQueued` / `softMemoryLimit` properties
- File-based resource-groups.json requires coordinator restart (no hot-reload for file mode)
- Source header workaround for query tagging (CLI `--source` and JDBC `source=` connection property)
- Production fit: k8s ConfigMap, rolling coordinator pod, on-prem service DNS
- Decision matrix maps need to approach, with actionable rollout sequence

## Errors or gaps
- Minor: Layer 1 claim "takes effect immediately — no Trino restart needed" assumes the catalog already uses that Postgres role. If creating a new role and pointing the catalog at it, a catalog refresh/restart is needed. Worth one caveat sentence.
- Minor: Could have mentioned that DB-backed resource group config IS hot-reloaded (~1s) as an alternative to file-based, in case the team wants to avoid coordinator restarts for ongoing tuning. Not required for the question but useful nuance.

## Verification
- WebSearch (trino.io/docs/current/admin/resource-groups.html via Trino 480 docs): Confirmed selector fields are `user`, `originalUser`, `authenticatedUser`, `userGroup`, `source`, plus `clientTags`/`queryType`/`sessionPropertyFilters`. No `catalog` or `connector` selector exists.
- WebSearch confirmed `hardConcurrencyLimit` (max running queries) and `maxQueued` (max queued, beyond which queries are rejected) are the correct required property names.
- WebSearch confirmed file-based config requires Trino restart; database-backed config reloads every ~1s automatically.
- WebSearch (pgbouncer.org/faq.html and pgjdbc list): `prepareThreshold=0` on PgJDBC connection URL is the canonical way to make PgJDBC compatible with PgBouncer transaction pooling. Confirmed.

**Final: 4.83/5.0 — PASS** (above 4.5 threshold)
