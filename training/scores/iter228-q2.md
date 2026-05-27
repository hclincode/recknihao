# Score: iter228-q2
Score: 4.40
Topic: Trino federation / cross-source connectors

## What was correct
- `query.max-execution-time` and `query.max-run-time` are real Trino coordinator config properties, both defaulting to **100d** (verified at trino.io/docs/current/admin/properties-query-management.html). Definitions are accurate: execution-time = active compute only (excludes queue/analysis/planning); run-time = full lifecycle from creation.
- Per-query override syntax `SET SESSION query_max_execution_time = '30m'` and `SET SESSION query_max_run_time = '45m'` is the correct session-property syntax for system-level (non-catalog-scoped) timeouts. The explicit warning that these are NOT catalog-scoped (so `SET SESSION catalog.query_max_execution_time` is wrong) is a useful pitfall callout.
- Session-scope isolation (only the current connection affected) is correct, which directly answers the engineer's worry about hurting other users.
- Resource groups recommendation is correctly framed as the mechanism to bound concurrency and memory; the JWT-principal-as-selector mapping fits the production stack (JWT auth in prod_info.md).
- The two-file resource-groups setup warning is correct and important: `etc/resource-groups.properties` MUST exist (with `resource-groups.configuration-manager=file` + `resource-groups.config-file=...`) for the JSON to be loaded. This addresses the historically-noted resource bug.
- Dynamic filter wait-timeout behavior is correctly described as "does NOT kill the query, only stops waiting for filter" (verified — Trino just proceeds with the scan without the filter).
- The "innermost timeout should fire first" production guidance (DB cancels work cleanly so the connection survives) is sound architectural advice.
- Diagnosis tip — check Trino Web UI query details for the exact "Query exceeded maximum time limit of X" string to identify which layer fired — is actionable.
- Strong fit with prod stack (Trino 467, JWT, k8s, OPA-compatible language).

## What was wrong or missing
- **Minor naming error**: Resource group property is `hardCpuLimit` / `softCpuLimit`, not `cpuLimit` / `softCpuLimit`. An engineer searching docs for `cpuLimit` will fail to find it.
- **Minor naming error**: Trino client abandonment property is `query.client.timeout` (dot-separated middle), not `query.client-timeout` (mixed dot+hyphen). The default of 5m is correct.
- The 7-layer enumeration is reasonable but slightly loose: it merges "JDBC socket/connect timeout" and "DB connection idle timeouts" but doesn't flag that these properties are in MILLISECONDS for MySQL Connector/J (the iter227 Q2 trap). Given this exact pitfall caused a previous failure, a one-line "socketTimeout/connectTimeout in MILLISECONDS for MySQL Connector/J" reminder would have hardened the answer.
- Missing: no `query.max-planning-time` (10m default) — the third Trino query-time cap that can also produce a timeout error during expensive planning (e.g., wide federated joins).
- No mention of resource group `maxQueued` / `hardConcurrencyLimit` / `softMemoryLimit` — the specific JSON field names that the engineer will actually need to write. Saying "configure caps" without naming the keys leaves real-world wiring incomplete.
- No example `resource-groups.json` snippet. Engineer is told "this is the answer" but given no concrete starting config — they will still have to consult docs.
- "Resource group cpuLimit" reference also conceptually misleads: CPU limits in resource groups are **time-period budgets** (cpuQuotaPeriod-windowed) that throttle concurrency, not direct query-runtime caps. So they don't actually solve the "kill the runaway query" problem the engineer fears the way the answer implies — that job belongs to `query.max-execution-time` or per-query memory limits. A clearer separation would help.
- "10–15 minutes is probably your cluster's tightened value" is plausible but pure speculation — better to tell the engineer how to check (`SHOW SESSION LIKE 'query_max%'` or inspect `etc/config.properties`).

## Verdict
**PASS** (4.40, above 3.5 base threshold for individual answer). However, the topic's raised threshold is 4.5 and this answer falls just below at 4.40, so it does not lift the topic-level average enough to close the gap (currently 4.441 / 130; this score is roughly neutral). The answer is substantively a major improvement over iter227 Q2's 3.10 — it correctly identifies `query.max-execution-time` as the proximate cause (the central gap in iter227), provides correct session-property override syntax, and correctly warns about the two-file resource-groups wiring trap. Two small naming errors (`cpuLimit` should be `hardCpuLimit`; `query.client-timeout` should be `query.client.timeout`) and the missing resource-groups JSON example keep it from reaching the raised 4.5 bar.

**Per-dimension scoring:**
- Technical accuracy: 4.0 (correct on the main claims; two minor property-name errors; slightly conflating CPU-budget resource-group limits with query-kill timeouts)
- Beginner clarity: 4.5 (clear structure, jargon explained, layered approach helpful)
- Practical applicability: 4.5 (engineer knows exactly the session SQL to run; production-fit JWT principal mention; diagnosis hint via Web UI)
- Completeness: 4.6 (covers cluster config, session override, resource groups, full timeout stack; missing `query.max-planning-time`, resource-group JSON example, and millisecond unit reminder)

Average: (4.0 + 4.5 + 4.5 + 4.6) / 4 = **4.40**
