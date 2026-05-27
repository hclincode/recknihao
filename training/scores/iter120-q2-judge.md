# Iter120 Q2 — Judge Score

**Question topic**: Using Trino resource groups to isolate enterprise vs free-tier query compute, preventing noisy neighbors.

**Production stack reminder**: On-prem k8s, Trino 467, Iceberg 1.5.2, Spark, MinIO, Hive Metastore, JWT auth, OPA.

---

## Verification against trino.io/docs/current/admin/resource-groups.html

| Claim in answer | Verified? | Notes |
|---|---|---|
| Two-file setup: `etc/resource-groups.properties` + `etc/resource-groups.json` | YES | Confirmed by Trino docs as the canonical file-based configuration manager approach. |
| `resource-groups.configuration-manager=file` and `resource-groups.config-file=etc/resource-groups.json` | YES | Property names verified. |
| Field names `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued`, `hardCpuLimit`, `softCpuLimit` | YES | All match official Trino 467 schema. |
| `cpuQuotaPeriod` at root | YES | Present in the docs as a top-level config field. |
| `selectors[].user` matches against the connection username (= JWT principal in this stack) | YES | Docs: "Java regex to match against username". For JWT auth, the JWT subject becomes the Trino principal/user. The answer is correct. |
| Resource group config requires coordinator restart (no hot reload for file manager) | YES | Docs distinguish file-based (no hot reload) from database manager (1-second reload). Correct call-out. |
| `system.runtime.queries` exposes `resource_group_id` | YES | Column exists; type is `array(varchar)` (path components). The answer's SELECT and GROUP BY against it works, though the column is technically an array — not strictly a string. Minor imprecision but the queries themselves run fine. |
| `kubectl rollout restart deployment/trino-coordinator -n trino` for k8s | YES | Reasonable approach for the on-prem k8s stack. |

### Minor technical issues
1. `resource_group_id` is `array(varchar)`. The answer's monitoring SQL uses it as if it prints cleanly as a path string (e.g., `global.free_tier`). In practice it renders as an array like `['global', 'free_tier']`. The GROUP BY and SELECT still work, but the reader may be confused by the actual output format. A small example of the array output would have prevented confusion.
2. The answer says: "During the restart (30–60 seconds), existing queries may drop." Trino coordinator restarts will kill all in-flight queries (workers cannot continue without coordinator coordination for new stages, and running queries fail). The "may drop" language softens what actually happens.
3. "21st free-tier query in queue is rejected" — correct behavior when `maxQueued` is exceeded (query is rejected with `QUERY_QUEUE_FULL`). Good.
4. Hard CPU limit behavior: "New queries from the group are rejected until the rolling window advances." — The actual behavior is that queries continue to **queue** (or run, depending on group sub-config) and the group's effective concurrency is throttled. Saying "rejected" overstates it. Minor imprecision.
5. The answer covers JWT principal matching but does not explicitly explain that with JWT auth, the JWT subject becomes the principal — leaving a small inference gap for a beginner who has never wired JWT into Trino.

### Strengths
- Two-file structure shown explicitly with the right property names and JSON shape.
- Clear distinction that `resource-groups.properties` must NOT be merged into `config.properties` — a real and common foot-gun.
- Coordinator restart requirement explicitly stated with the k8s command.
- `system.runtime.queries` debug query with `resource_group_id` is the right diagnostic path.
- Practical noisy-neighbor narrative (Acme's 12-month export ties up 5/20 enterprise slots, but free-tier 3 slots remain unaffected) — concrete and grounded.
- Selector regex examples (`acme-service-account`, `customer-.*`, `free-tier-.*`) align with how JWT principals would be issued.
- Trade-off table (resource groups vs separate clusters) is appropriate guidance.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All major fields, file structure, restart requirement, and selector semantics are correct against Trino 467 docs. Minor errors: `resource_group_id` type is array (rendering nuance), CPU-limit phrasing slightly overstates "rejected", coordinator restart "may drop" softens what really happens. |
| Beginner clarity | 4.5 | "Noisy neighbor" labeled upfront, Acme analogy is concrete, field-meaning table is a clear glossary. JWT-principal → selector connection could be one sentence more explicit for a true beginner. |
| Practical applicability | 4.75 | Engineer can copy both files, deploy with the exact `kubectl rollout restart` command, and run the debug SQL. End-to-end actionable. |
| Completeness | 4.5 | Covers: resource group config, JWT-principal selector routing, queue-vs-reject behavior at limits, coordinator restart requirement, `system.runtime.queries` debug + monitoring SQL, common config-file-misplacement failure mode, separate-clusters trade-off. Missing: explicit note that JWT subject becomes the Trino principal; subgroup memory % is fraction of parent not cluster (one common point of confusion not called out). |

**Average: (4.5 + 4.5 + 4.75 + 4.5) / 4 = 4.5625**

**Verdict: PASS** (well above 3.5 threshold).

---

## Topic checklist update (rubric)

This question touches the existing **Multi-tenant analytics: isolating customer data in SaaS** topic (specifically the resource-groups / noisy-neighbor sub-angle, which has been tested multiple times in iter18, 19, 20, 31). With this answer (4.56), the running average continues comfortably above 4.0.

No new required topic to add. Topic remains **PASSED**.

---

## Notable improvements vs prior iterations of this question family

- Iter18/19 answers had wrong `"user"` selector semantics (matched against role name instead of JWT principal). This answer correctly identifies it as JWT principal — the iter18+19 resource fix has stuck.
- Iter20 answer omitted the coordinator restart requirement. This answer includes it explicitly with the k8s command.
- Iter31 answer had production-breaking JSON errors. This answer's JSON is syntactically and semantically valid Trino 467.

The iter120 teacher fixes are visible in this answer's accuracy on resource-group specifics.

---

## Sources
- [Trino Resource Groups Documentation](https://trino.io/docs/current/admin/resource-groups.html)
- [system.runtime.queries resource_group_id (GitHub issue context)](https://github.com/trinodb/trino/issues/5464)
