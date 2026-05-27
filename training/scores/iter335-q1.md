# Score: Iter 335 Q1 — Trino Per-Tier Query Time Limits

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | Correctly identifies that resource groups lack a per-query time-kill property and that session property manager is the right mechanism. BUT the JSON structure is materially wrong: official docs specify a flat top-level **list** of match rules, not a `{"defaultSessionProperties": {...}, "sessionPropertySpecs": [...]}` wrapper. The `"match"` nested object and `"name"` field do not exist in the real schema. `group` is a top-level rule field, not nested under `match`. An engineer who copy-pastes this JSON will get parser errors on coordinator startup. |
| Beginner clarity | 4.0 | Clear explanation of the conceptual gap (resource groups vs. session properties), readable file/property breakdown, plain-English caveats, and a quick verification query. A new engineer can follow the logic, even if the config they paste won't work. |
| Practical applicability | 2.5 | The shape of the solution is right (file-based session property manager keyed on resource group name) and matches the on-prem Trino-on-k8s environment (no cloud-only tooling). However, the JSON example is non-functional as written — the file would fail to parse. The `kubectl rollout restart` instruction, OPA override caveat, and immediate `kill_query` are genuinely useful, but the broken config is the centerpiece of the answer, so usability is heavily degraded. |
| Completeness | 4.0 | Covers: resource-group limitation, session-property-manager mechanism, free/enterprise differential, restart requirement, OPA `SET SESSION` bypass risk, immediate remediation via `kill_query`, verification SQL. Missing: mention that `query_max_execution_time` can also be expressed as a cluster-wide default (`query.max-execution-time`), and the actual OPA action name (`SetSystemSessionProperty`) for the override-blocking rule. |
| **Average** | **3.25** | **FAIL** |

## What Worked
- Correctly diagnosed the real problem: resource group JSON has no per-query execution-time-kill property; this trips up many engineers.
- Identified file-based session property manager as the documented solution, keyed off the `group` regex against resource group path.
- Explained `query_max_execution_time` vs `query_max_run_time` in a useful, beginner-friendly way (execution = post-start, run = since submission/queue).
- Operationally rich: included k8s rollout restart command, OPA bypass warning, runtime `kill_query` for incident response, and `system.runtime.queries` verification query.
- Production fit: on-prem Trino-on-k8s + OPA acknowledged; no cloud-only assumptions.

## What Missed
- **JSON schema is wrong.** Per https://trino.io/docs/current/admin/session-property-managers.html, the file contains a top-level JSON **array** of match-rule objects. Each rule directly contains optional `user`, `source`, `queryType`, `clientTags`, `group` fields plus a `sessionProperties` map. There is no `defaultSessionProperties` key, no `sessionPropertySpecs` wrapper, no `"name"` field, and no nested `"match"` object. The example as written will not parse.
- The correct shape for the free-tier rule should look like:
  ```json
  [
    {
      "group": "global\\.free_tier",
      "sessionProperties": {
        "query_max_execution_time": "5m"
      }
    },
    {
      "group": "global\\.enterprise_tier",
      "sessionProperties": {
        "query_max_execution_time": "30m"
      }
    }
  ]
  ```
- The OPA action mentioned (`SetSessionProperty`) is non-specific; the Trino OPA plugin distinguishes `SetSystemSessionProperty` and `SetCatalogSessionProperty`. The advice should name the system-level action since `query_max_execution_time` is a system property.
- No mention that `query.max-execution-time` can be set as a cluster-wide default in `config.properties` as a safety net independent of the session property manager.
- The dot in `global.free_tier` regex should be escaped (`global\\.free_tier`) since `group` is matched as a Java regex per docs.

## Technical Accuracy Verification
- **Claim: "Resource groups do NOT have a built-in property to kill individual queries after a time limit"** — CORRECT. Resource groups control concurrency, queueing, soft/hard memory, soft CPU limits, but not per-query wall-clock kill. Source: https://trino.io/docs/current/admin/resource-groups.html and confirmed by issue https://github.com/trinodb/trino/issues/28373 explicitly requesting per-query limits in resource groups.
- **Claim: config file is `etc/session-property-config.properties` with `session-property-config.configuration-manager=file` and `session-property-manager.config-file=...`** — CORRECT property names. Source: https://trino.io/docs/current/admin/session-property-managers.html.
- **Claim: JSON uses `defaultSessionProperties` + `sessionPropertySpecs` with `"name"` and `"match"` nested object** — INCORRECT. Per official docs the JSON is a flat top-level list of match-rule objects; fields `user`/`source`/`queryType`/`clientTags`/`group` sit directly on each rule alongside `sessionProperties`. No `name`, no `match`, no `defaultSessionProperties`, no `sessionPropertySpecs`. Source: https://trino.io/docs/current/admin/session-property-managers.html.
- **Claim: `group` is a regex matched against the resource group path** — CORRECT. Source: same page.
- **Claim: `query_max_execution_time` is wall-clock from query start; `query_max_run_time` includes queue time** — DIRECTIONALLY CORRECT. Trino docs phrase execution time as the time actively executing on the cluster, and run time as total time since creation (including queue, analysis, planning). Source: https://trino.io/docs/current/admin/properties-query-management.html.
- **Claim: changes to session-property-manager JSON require coordinator restart** — PLAUSIBLE/LIKELY CORRECT. Docs do not document a hot-reload mechanism for this file; absence of a refresh-interval property suggests restart is needed. Not explicitly contradicted.
- **Claim: `CALL system.runtime.kill_query(query_id => '...', message => '...')`** — CORRECT syntax. Source: https://trino.io/docs/current/connector/system.html.
- **Claim: `system.runtime.queries` exposes `resource_group_id`, `state`, etc.** — CORRECT. Source: same page.
- **Claim: OPA can deny `SetSessionProperty`** — PARTIALLY CORRECT. The Trino OPA plugin distinguishes `SetSystemSessionProperty` and `SetCatalogSessionProperty`; for `query_max_execution_time` (a system property) the relevant action is `SetSystemSessionProperty`. The generic name used in the answer is imprecise.
