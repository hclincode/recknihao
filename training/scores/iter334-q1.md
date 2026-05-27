# Iter 334, Q1 — Judge Evaluation

**Topic**: Multi-tenant analytics — Trino resource group per-query time limits / per-tier query timeouts
**Question**: Can a per-query time limit be added to a Trino resource group (e.g., 5 min for free-tier, 30 min for enterprise)? If so, where does it go?
**Prior rubric avg**: 4.481 across 128 questions

---

## Score table

| Dimension | Score | Notes |
|---|---:|---|
| Technical accuracy | 3 | Correct that resource group JSON has no `maxExecutionTime` field. Correct that `softCpuLimit`/`hardCpuLimit` are aggregate-per-group/per-window (not per-query). MISSED the official mechanism: a **session property manager** that sets `query_max_execution_time` keyed on `resourceGroup` regex. Hedges on `query.max-run-time` ("may exist… consult the docs") when this is precisely the property that answers the question. Slight imprecision: implies the `softCpuLimit` would "throttle" but says it doesn't kill a single long-running query — true, and accurate, but the answer leaves the engineer to go figure out the real fix. |
| Beginner clarity | 4 | Short, no unexplained jargon. The "what resource groups CAN control" bullet list is helpful. Explicitly calls out the aggregate-vs-per-query distinction. Loses a point because the punchline ("here is what you actually do for the 5-min / 30-min ask") is missing — a beginner reads this and is left with "I guess I can't do it." |
| Practical applicability | 2 | The engineer asked three concrete questions: (1) does a time limit exist, (2) where does it go, (3) can it be set per tier. The answer says "no on resource groups, maybe globally, go read the docs." That's not actionable. The correct actionable answer is: configure a **session property manager** (`etc/session-property-config.properties` pointing to a JSON file with `match` rules keyed on `group` regex like `global\.free_tier` and `global\.enterprise`), set `query_max_execution_time: "5m"` and `"30m"` respectively, restart the coordinator. The answer never mentions session property managers at all — even though that is the documented Trino pattern for exactly this use case (the official Trino docs literally use a "global / global.interactive" 8h/1h tier example). |
| Completeness | 2 | (1) Time limit existence — partially answered (resource group field: no; global property: hedged as "may exist"). (2) Where it goes — not answered concretely. (3) Per-tier different limits — not answered; the answer implies "consult docs." Misses the session-property-manager-keyed-on-resource-group pattern entirely, which is THE answer to per-tier limits. |

**Average: (3 + 4 + 2 + 2) / 4 = 2.75 — FAIL (below 3.5 threshold)**

---

## What worked

- Correctly states that the resource group JSON schema has no `maxExecutionTime` / `executionTimeLimit` field. Verified against Trino 480 resource-groups docs — only `softMemoryLimit`, `softConcurrencyLimit`, `hardConcurrencyLimit`, `maxQueued`, `softCpuLimit`, `hardCpuLimit`, `schedulingPolicy`, `schedulingWeight`, `jmxExport`, `subGroups`. No time-execution-cap field exists.
- Correctly distinguishes `softCpuLimit`/`hardCpuLimit` as **aggregate per-group per rolling window**, NOT per-query duration. This is a subtle and commonly-confused point; the answer handles it correctly.
- Honest about a resource gap: "the resources don't document a per-resource-group execution time limit property."
- Suggests the right fallback levers (`hardConcurrencyLimit`, `maxQueued`, `softCpuLimit`) for back-pressure on free-tier.

## What missed

### 1. The official answer to the question — session property managers — is entirely absent
Trino's documented pattern for per-tier query time limits is the **session property manager** (`etc/session-property-config.properties` + a JSON match-rules file). It supports `group` regex matching against the resolved resource group path, so you can write:

```json
[
  { "group": "global\\.free_tier",   "sessionProperties": { "query_max_execution_time": "5m" } },
  { "group": "global\\.enterprise",  "sessionProperties": { "query_max_execution_time": "30m" } }
]
```

This is **exactly the pattern the official Trino docs demonstrate** (the docs literally use a "global / global.interactive" with 8h / 1h limits — the same shape as the engineer's question). The answer never mentions this mechanism, and that is the single biggest miss.

### 2. The answer hedges on `query.max-execution-time` instead of confirming it exists
The answer says: "you would need to check the Trino documentation for `query.max-run-time` or similar global properties and whether they can be set per resource group." Both `query.max-execution-time` (config + `query_max_execution_time` session property, added in 0.186) AND `query.max-run-time` (config + `query_max_run_time` session property, added in 0.116) are real, documented Trino properties — the answer should confirm this. The right framing is "the property absolutely exists at the coordinator level as `query.max-execution-time` / session `query_max_execution_time`; to get per-tier defaults, use a session property manager keyed on the resource group path."

### 3. Practical gap on the user's exact ask
The user explicitly asked "different time limits per tier, 5 min for free, 30 min for enterprise." This has a clean, documented Trino answer. The responder's deflection ("consult the official Trino docs") in a production environment where the engineer is already running Trino 467 with resource groups is a quality regression.

### 4. Minor accuracy nuance on `softCpuLimit` behavior
The answer says `softCpuLimit` will "throttle" — the resource (line 2436) is more precise: when soft CPU is exceeded, Trino reduces the effective `hardConcurrencyLimit` proportionally (i.e., admits fewer new queries from the group), it does not slow down running queries. This is a nit; calling it "throttle" is colloquially OK.

---

## Resource gap — does resources/05 cover this?

**Partial coverage; the resource has a real gap here.** Specifically:

- `query.max-execution-time` appears only TWICE in resources/05:
  - Line 2609: in passing, as a per-session bump for a long export query (`SET SESSION query_max_execution_time = '4h'`).
  - Line 3452: in the `errorCode` table for `EXCEEDED_TIME_LIMIT`.
- **The session-property-manager pattern is NEVER documented** in resources/05. There is no section explaining how to set different `query_max_execution_time` defaults per resource group via `etc/session-property-config.properties` and a match-rules JSON file. This is the documented Trino pattern for per-tier query timeouts, and the resource omits it entirely.
- The "Resource groups JSON" section (lines ~2212–2447) is extensive and accurate but does not connect resource groups to session property managers for per-group default session overrides.

The responder's "the resources don't document this" admission is **factually accurate** — resources/05 does not document the per-tier timeout pattern, and the responder cannot answer what isn't there. The failure is partly the responder's (didn't even mention `query.max-execution-time` as a confirmed-existing property despite the resource showing it in the error-code table and the SET SESSION example) and partly a real resource gap.

---

## Technical accuracy verification (WebSearch against trino.io docs)

| Claim under test | Verification result |
|---|---|
| (a) Trino resource groups have no per-query execution time limit property | CONFIRMED. The resource-groups schema (Trino 480 docs) lists no `maxExecutionTime`, `executionTimeLimit`, or `maxQueryDuration` field. The only time-window field is `hardCpuLimit`/`softCpuLimit`, which are aggregate-per-group CPU caps over a `cpuQuotaPeriod` rolling window — not per-query duration. |
| (b) `query.max-run-time` and `query.max-execution-time` exist as global Trino config properties | CONFIRMED both exist. `query.max-run-time` (added 0.116) measures total time from query creation incl. queue/planning. `query.max-execution-time` (added 0.186) measures only execution time excl. queue/planning. Both have matching `query_max_run_time` / `query_max_execution_time` session properties. The responder mentions only `query.max-run-time` and hedges its existence. |
| (c) Can per-query time limits be set per resource group? | YES, via a **session property manager** (`session-property-config.properties` + match-rules JSON). Rules can match on `user`, `source`, `queryType`, `clientTags`, and **`group`** (the resource group path). The official Trino docs use a global=8h / global.interactive=1h example — the same shape as the engineer's question. The responder did not surface this mechanism. |
| (d) `softCpuLimit`/`hardCpuLimit` described as aggregate-across-group | CORRECT. Confirmed against Trino docs and resources/05 line 2436. |
| (e) Native per-group per-query time limit doesn't exist as a resource-group field | CORRECT — but the answer misses that combining resource groups with session property managers achieves the same outcome end-to-end. |

---

## Topic & rubric impact

- **Topic**: Multi-tenant analytics
- This is the second resource-groups question recently (iter333 Q1 covered concurrency/memory; this one covers per-tier time limits). The earlier question scored well (4.75) because the resource fully covered concurrency/memory. This one exposes a real gap: per-tier timeout configuration via session property managers is not in resources/05.
- Score 2.75 will pull the multi-tenant avg slightly. With 128 prior questions at 4.481, adding 2.75 gives (4.481 * 128 + 2.75) / 129 = **4.467 / 129**.

---

## Recommended teacher action (resource gap)

Add a section to `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` covering:

1. **Session property managers as the per-tier timeout mechanism.** Place it directly after the "Resource groups JSON" section so the reader makes the connection. Show the two-file layout:
   - `etc/session-property-config.properties` (Java properties, pointer file):
     ```properties
     session-property-config.configuration-manager=file
     session-property-manager.config-file=etc/session-property-config.json
     ```
   - `etc/session-property-config.json` (match rules array) with a concrete free-tier/enterprise example matching the resolved resource group path (`group` regex like `global\\.free_tier` and `global\\.enterprise`) and setting `query_max_execution_time` accordingly.
2. **Clarify `query.max-execution-time` vs `query.max-run-time`** as a small comparison table — execution-time excludes queue/planning; run-time includes everything from creation. State which one most tenant-isolation cases want (usually `query_max_execution_time`, since you don't want to penalize a tenant for sitting in queue behind a noisy neighbor).
3. **Cross-link from the "Resource groups JSON" section** with a one-liner: "Resource groups govern admission and CPU/memory budgets but have no per-query time cap field. For per-tier query timeouts, pair this with the session property manager below."
4. **Note the failure mode**: session-property defaults are *defaults*, not enforcements — a user with `SET SESSION` privilege can override them up to the coordinator's `query.max-execution-time` ceiling. If hard enforcement is required, set the coordinator-level `query.max-execution-time` to the largest tier ceiling AND deny `SET SESSION query_max_execution_time` via OPA.

---

**Decision: FAIL (2.75) — below 3.5 threshold. Multi-tenant topic is already PASSED in the rubric so this does not reopen it, but the resource gap (session property managers) is real and should be filled to avoid future failures on similar phrasings.**
