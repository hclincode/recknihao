# Judge Feedback — Iter 335

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / Trino session property manager JSON schema (Q1) + Postgres-to-Iceberg ingestion / full-refresh vs incremental vs CDC decision tree (Q2)

---

## Q1 — Trino Session Property Manager JSON Schema (FAIL)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | Correctly identifies that resource groups lack a per-query time-kill property and that session property manager is the right mechanism. BUT the JSON structure is materially wrong: official docs specify a flat top-level list of match rules, not a `{"defaultSessionProperties": {...}, "sessionPropertySpecs": [...]}` wrapper. The `"match"` nested object and `"name"` field do not exist in the real schema. An engineer who copy-pastes this JSON will get parser errors on coordinator startup. |
| Beginner clarity | 4.0 | Clear explanation of the conceptual gap (resource groups vs. session properties), readable file/property breakdown, plain-English caveats, and a quick verification query. A new engineer can follow the logic, even if the config they paste won't work. |
| Practical applicability | 2.5 | The shape of the solution is right (file-based session property manager keyed on resource group name) but the JSON example is non-functional as written — the file would fail to parse. The kubectl rollout restart, OPA override caveat, and kill_query are genuinely useful, but the broken config is the centerpiece. |
| Completeness | 4.0 | Covers: resource-group limitation, session-property-manager mechanism, free/enterprise differential, restart requirement, OPA SET SESSION bypass risk, kill_query, verification SQL. Missing: cluster-wide `query.max-execution-time` as fallback default, actual OPA action name (`SetSystemSessionProperty`), regex escape requirement. |
| **Average** | **3.25** | **FAIL** |

### What Worked
- Correctly diagnosed the real problem: resource group JSON has no per-query execution-time-kill property.
- Identified file-based session property manager as the documented solution, keyed off `group` regex against resource group path.
- Explained `query_max_execution_time` vs `query_max_run_time` in a beginner-friendly way.
- Operationally rich: included k8s rollout restart, OPA bypass warning, runtime `kill_query` for incident response, verification query.

### What Missed
1. **JSON schema is wrong** — Per https://trino.io/docs/current/admin/session-property-managers.html, the file contains a top-level JSON **array** of match-rule objects. Each rule directly contains optional `user`, `source`, `queryType`, `clientTags`, `group` fields plus a `sessionProperties` map. There is no `defaultSessionProperties` key, no `sessionPropertySpecs` wrapper, no `"name"` field, and no nested `"match"` object. The example as written will not parse.
2. **Regex dot must be escaped** — `group` is matched as a Java regex, so `global.free_tier` should be `global\\.free_tier`. An unescaped dot matches any character.
3. **OPA action is `SetSystemSessionProperty`** — Trino OPA plugin distinguishes `SetSystemSessionProperty` and `SetCatalogSessionProperty`; for `query_max_execution_time` (a system property) the correct action to deny is `SetSystemSessionProperty`.
4. **No mention of cluster-wide `query.max-execution-time`** — for queries that match no session property manager rule, the global `query.max-execution-time` cluster property applies as a safety net.

### Resource Fix Applied
- resources/05-multi-tenant-analytics.md: corrected session-property-manager.json to flat top-level array schema (not wrapper object); added SCHEMA callout explaining the correct format vs what does NOT exist; fixed regex escaping (`global\\.free_tier`); updated OPA action name from `SetSessionProperty` to `SetSystemSessionProperty`; added note about `query.max-execution-time` as fallback for unmatched queries.

### Technical Accuracy (verified)
1. Resource groups have no per-query execution time kill property — CORRECT
2. Session property manager with `group` regex is the per-tier time limit mechanism — CORRECT (trino.io/docs/current/admin/session-property-managers.html)
3. JSON format is flat top-level array, not wrapper object — CORRECT (verified against official docs)
4. `query_max_execution_time` = wall-clock from execution start; `query_max_run_time` = from submission including queue — CORRECT
5. OPA action for system session properties is `SetSystemSessionProperty` — CORRECT

### Rubric Update
- Multi-tenant analytics: prior avg 4.468/129 → (4.468 × 129 + 3.25) / 130 = 579.622 / 130 = **4.459 across 130 questions**. Status: **PASSED** (second consecutive drop; resource fix applied).

---

## Q2 — Postgres-to-Iceberg Ingestion Strategy (PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Three-pattern taxonomy (Full Refresh / Incremental / CDC) correct. `overwritePartitions()` idempotency, `append()` non-idempotency, `updated_at` vs `created_at` watermark, late-arriving rows trap with MERGE INTO fix, hot_standby_feedback, and 10M threshold all verified accurate. Minor issues: CDC "~3x more infrastructure" is imprecise (it's an entirely new infrastructure footprint: Kafka, Connect, Debezium, streaming consumer, schema registry, replication slot management). |
| Beginner clarity | 4.5 | Three patterns presented clearly with When/Pros/Cons. Concrete trigger SQL, index check SQL. Acronyms expanded. "What NOT to do" framing effective. "Start here" summary at end gives a clear decision flowchart. |
| Practical applicability | 4.5 | Engineer knows exactly what to do for each table type. Decision rule (10M threshold), index preflight SQL, trigger snippet, and hot_standby_feedback tip all concrete and actionable. No off-stack tools recommended. |
| Completeness | 4.0 | Covers three patterns, decision criteria per table type, watermark column choice, late-arrivals trap (MERGE INTO fix), index preflight, read replica strategy. Missing: (a) hard-DELETE invisibility to incremental loads and soft-delete pattern (`deleted_at`); (b) lag-buffer calibration (15-30 min P99 calibration from resources/13); (c) no JDBC throttling guidance despite "can't slow down the live database" concern; (d) maintenance follow-up (compaction/snapshot expiration). |
| **Average** | **4.375** | **PASS** |

### What Worked
- Three-pattern taxonomy mapped cleanly to user's two-table scenario.
- Pushed back on CDC as default; gave concrete bar for when to escalate.
- Late-arriving rows trap with MERGE INTO is the most important gotcha and was called out correctly.
- `hot_standby_feedback = on` is sophisticated and accurate.
- `updated_at` vs `created_at` trap correctly described as most common new-pipeline failure.
- Index preflight SQL and trigger SQL are immediately runnable.
- Fits on-prem Spark + Iceberg + MinIO production stack.

### What Missed
1. **Hard DELETEs invisible to incremental loads** — "a few tables get heavy writes all day" likely includes deletes. Soft-delete (`deleted_at` column) pattern from resources/13 should have been mentioned.
2. **Lag buffer / replica freshness calibration** — resources/13 has 15-min default with P99 calibration; answer omitted.
3. **Throttling against live database** — user's stated concern was "can't afford to slow it down." Answer mentions read replicas for bootstrap but not JDBC `fetchsize`, partitioned parallel reads, or off-peak scheduling for ongoing pulls.
4. **Maintenance follow-up** — Iceberg compaction and snapshot expiration necessary after these patterns; not mentioned.

### Resource Fix Applied
None required. Gaps are completeness, not factual errors. Resources/13 already covers lag buffer and soft-delete; responder simply didn't surface them.

### Technical Accuracy (verified)
All major claims verified: overwritePartitions idempotency, append non-idempotency, MERGE INTO for late arrivals, hot_standby_feedback correctness, updated_at/created_at trap, staging+view swap, CDC threshold (sub-minute or hard deletes). Sources: Iceberg Spark writes docs, PostgreSQL hot standby docs.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.503/119 → (4.503 × 119 + 4.375) / 120 = 540.232 / 120 = **4.502 across 120 questions**. Status: **PASSED** (stable).

---

## Iter 335 Summary

**Iter 335 average: (3.25 + 4.375) / 2 = 3.813 — PASS** ✓ (Q1 FAIL / Q2 PASS)

### Notable
- Q1 3.25: Session property manager JSON schema error — worst accuracy failure since resources were added. The responder correctly identified the mechanism but had the wrong JSON format (wrapper object vs flat array). The resources/05 fix itself had the wrong format, which caused the resources to propagate incorrect config to the responder. Resources corrected immediately.
- Q2 4.375: Postgres-to-Iceberg decision tree — solid three-pattern answer. Missed hard-DELETE invisibility and lag buffer from resources/13; otherwise comprehensive.

### Resource fixes applied this iteration
- **resources/05-multi-tenant-analytics.md**: corrected session-property-manager.json to flat top-level array; added SCHEMA callout; fixed regex escaping; updated OPA action to `SetSystemSessionProperty`; added `query.max-execution-time` cluster property as fallback for unmatched queries.

### Suggested focus for Iter 336
- **Multi-tenant analytics** (4.459/130, second consecutive drop): Probe the corrected JSON schema directly — ask an engineer who has the wrong wrapper format how to verify their session property manager config is valid. Confirm the responder now surfaces the flat array format.
- **Postgres-to-Iceberg ingestion** (4.502/120, stable): Probe hard DELETEs — ask what happens to deleted rows in an incremental pipeline and how to handle them. Also probe lag buffer calibration.
- **Iceberg table maintenance** (4.594/29): Consider probing orphan file removal — what `remove_orphan_files` catches that `expire_snapshots` doesn't.
