# Iter130 Q1 — Judge Score
**Score**: 4.81 / 5 (Tech 5, Clarity 4.75, Practical 5, Completeness 4.5)

## Verdict
PASS. Strong, production-ready answer that gets all the high-risk technical details right (file pair, property names, scheduling policy value, restart requirement, kill_query syntax, ARRAY return type) and frames the fix exactly as the on-prem Trino 467 + JWT + OPA stack needs. Includes the live-incident kill lever that prior iter 30-series answers missed. Beginner clarity is good with the "priority queues with capacity limits" framing, the property-name gotcha table, and the explicit "silently never apply" failure mode warning.

## What was verified correct (via WebSearch)
- **Two-file setup** — `resource-groups.properties` containing `resource-groups.configuration-manager=file` + `resource-groups.config-file=etc/resource-groups.json` is the documented Trino setup; confirmed against trino.io/docs/current/admin/resource-groups.html. CORRECT.
- **Property names** — `hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`, `schedulingWeight` are all valid Trino resource group fields in 467 (unchanged from current docs). CORRECT.
- **`schedulingPolicy: "weighted_fair"`** — confirmed as one of four valid values (`fair`, `weighted`, `weighted_fair`, `query_priority`). CORRECT.
- **Coordinator restart for file-based config** — confirmed: file manager does not hot-reload; database manager reloads every 1s. CORRECT, and well-contrasted implicitly.
- **`CALL system.runtime.kill_query(query_id => '...', message => '...')`** — confirmed as the documented named-argument syntax. CORRECT.
- **`resource_group_id` is `array(varchar)`** — confirmed in system.runtime.queries schema; the `ARRAY['global','dashboards']` example output format is accurate. CORRECT.
- **Production fit** — JWT principal selector matching called out (resource-fix from iter18/19/27/29 carried through). Kubernetes `kubectl rollout restart` matches the on-prem k8s deployment described in prod_info.md. No public-cloud refs. CORRECT.
- **`cpuQuotaPeriod` + `softCpuLimit`/`hardCpuLimit`** — valid Trino properties; CORRECT optional add.

## Errors or gaps [HIGH/MEDIUM/LOW]
- **[LOW]** The selector example uses `"source": ".*dashboard.*"` which matches against the X-Trino-Source header. Production stack uses JWT — source header is set by the client (BI tool / app), not by the JWT. The example would benefit from a one-liner saying "source comes from the client's `X-Trino-Source` HTTP header (e.g., set by the dashboard app), not from the JWT — your app must set it explicitly." Without this, an engineer may wonder why selectors don't fire.
- **[LOW]** `softMemoryLimit` percentages (`"30%"`, `"50%"`, `"80%"`) are valid, but the answer doesn't mention that percentages are computed against the cluster general pool memory, not per-worker — a beginner could misread `"30%"` as per-node. One sentence would have closed this.
- **[LOW]** "Expect 30–60 seconds of downtime. All in-flight queries are killed." is correct for a hard restart, but Trino supports graceful coordinator shutdown via `SHUTTING_DOWN` state that drains queries; not mentioning it isn't wrong, just less complete. For a SaaS engineer doing this for the first time, hard-restart guidance is the safer default.
- **[LOW]** The selector regex `".*dashboard.*"` will match anything containing "dashboard" anywhere; anchor guidance (`^dashboard$` for exact match) would help avoid false matches in production. Not an error, just a gap.
- **[LOW]** No mention of OPA interaction — the answer doesn't need to dive in, but a one-line note that "resource groups are orthogonal to OPA authorization; OPA decides if a query is allowed, resource groups decide when and how it runs" would tie the production stack together.

## Resource fix recommendations
None required for this iteration — all prior iter18/19/27/29-series resource fixes (correct property names, JWT principal in selectors, coordinator restart called out, kill_query as the immediate-relief lever, `system.runtime.queries` not `.tasks`) are all present and correct in this answer. Suggested small additions for `resources/05-multi-tenant-analytics.md` or a Trino-specific resource:
1. Add a callout that `source` selector matches the `X-Trino-Source` HTTP header (set by the client app) — not the JWT principal or sub claim.
2. Add one sentence clarifying `softMemoryLimit` percentages are against the cluster general pool, not per-worker.
3. Add a one-liner contrasting resource groups (admission/queuing) vs OPA (authorization) so engineers don't conflate the two.

## Topic state
- **Trino resource groups / query queueing / workload isolation** — sits under "Multi-tenant analytics: isolating customer data in SaaS" which is the most-tested topic in this run. Prior running avg after iter121 series was ~4.42 across 30+ questions. This 4.81 answer pushes the avg up further. Topic remains PASSED solidly above 4.0.
- No other rubric topic touched by this question.
