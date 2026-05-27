Score: 5.00/5.0 PASS

## Dimension scores
- Technical accuracy (40%): 5/5
- Beginner clarity (25%): 5/5
- Completeness (20%): 5/5
- Actionability (15%): 5/5

## What the answer got right
- Correctly states OSS Trino 467 has no native per-catalog Postgres connection pool; flags `connection-pool.*` as Starburst Enterprise-only and warns that OSS silently ignores those properties (matches trinodb/trino#15888 still-open status).
- Property names `hardConcurrencyLimit` and `maxQueued` exactly match official Trino resource-groups docs; explanation of "queued vs running vs rejected" is precise (e.g., the 53rd query gets rejected, not queued).
- Source selector caveat is the most important real-world gotcha for this question and the answer leads with it correctly: if BI tools don't send the source, selectors silently don't match and queries fall through to the default group with no cap. JDBC `source=`, CLI `--source`, and HTTP `X-Trino-Source` are all listed correctly.
- Correctly separates `etc/resource-groups.properties` (plugin config: `resource-groups.configuration-manager=file`, `resource-groups.config-file=...`) from `etc/resource-groups.json` (rules). This is a common confusion point the answer avoids.
- Coordinator restart requirement for file-based resource groups is called out explicitly — matches docs (file manager has no auto-reload by default; database-backed manager hot-reloads every ~1s).
- Multi-connection-per-query nuance is accurate: a query joining N Postgres tables can open N Postgres connections, so worst-case Postgres connection count is `hardConcurrencyLimit × max_tables_per_query`. The 2 queries × 3 tables = 6 worst case is a useful concrete bound.
- PgBouncer + Postgres role-level `CONNECTION LIMIT` framed as the Postgres-side safety net, not a replacement for resource groups — correct layering and consistent with iter163/164 teacher fix guidance.
- Verification SQL against `system.runtime.queries` plus the Trino UI "Resource group" field check both give the engineer concrete ways to confirm the selector matched.
- JSON example has correct shape: `rootGroups[].subGroups[]`, `selectors[]` with `source` regex + `group` dotted path (`federation.analysts`), `schedulingPolicy: "fair"`, `softMemoryLimit: "60%"` — all valid fields.
- Production-stack fit (on-prem k8s, MinIO, JWT auth, OPA) is implicit but compatible: nothing in the answer relies on cloud services or features absent from Trino 467.

## Errors or gaps
None identified. The answer addresses the exact question (cap concurrent queries at Trino before they hit Postgres, queue the rest), names the correct mechanism, flags the silent-failure mode, gives runnable config, and honestly acknowledges that resource groups alone don't cap raw connection count — which is why PgBouncer/role CONNECTION LIMIT still matter.

Minor (not deducted): could have mentioned `softConcurrencyLimit` as a soft cap that allows borrowing from parent slack, and the database-backed resource group manager as an alternative that hot-reloads (avoiding coordinator restart for tenant-onboarding churn). Neither is required to answer the question.

## Verification notes
WebSearch against trino.io and trinodb/trino issues confirmed:
1. `hardConcurrencyLimit` and `maxQueued` are the correct, required field names in the resource groups JSON (Trino 480 docs match Trino 467 schema). CONFIRMED.
2. The source selector matches against the source string the client sends via JDBC `source` property, CLI `--source`, or HTTP `X-Trino-Source` header. `${SOURCE}` substitution works in selector group names. CONFIRMED.
3. File-based resource groups require a coordinator restart by default; only the database-backed manager hot-reloads (every ~1s). This matches the answer's "do not hot-reload" claim. CONFIRMED (trinodb/trino#14514).
4. OSS Trino 467 PostgreSQL connector does NOT support native JDBC connection pooling; the feature request remains open (trinodb/trino#15888). The Oracle connector has pooling, but PostgreSQL does not in OSS. CONFIRMED. Starburst Enterprise's PostgreSQL connector supports pooling — the answer's "Starburst Enterprise-only" framing is accurate.
