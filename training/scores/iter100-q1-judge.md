# Iter100 Q1 — Judge Score

**Question topic**: Multi-tenant analytics — noisy-neighbor isolation when onboarding a 10x-volume enterprise tenant on a shared Iceberg events table.

**Verdict**: PASS (4.25 average) — strong, structured, mostly correct, but contains one production-impacting configuration bug that an engineer would hit on first deploy.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | One real config-file-location bug (see below). Every other technical claim verified correct against Trino 480 and Iceberg latest docs. |
| Beginner clarity | 5 | "Highway lanes" analogy, clear noisy-neighbor framing, step-by-step structure, explains JWT principal matching and common mistakes inline. Zero unexplained jargon. |
| Practical applicability | 4 | Three-tier escalation (resource groups → dedicated table → dedicated cluster) is exactly right. Diagnostic query lets engineer self-verify. But the `etc/config.properties` mislocation would cause a silent config failure if followed literally. |
| Completeness | 4.5 | Covers Trino layer, Iceberg layer, table-structure question, verification, and escalation. Minor gaps: doesn't mention `softCpuLimit`/`hardCpuLimit` for time-based CPU quotas, and doesn't discuss bucket-by-tenant as a secondary partition for the big tenant's date partitions. |
| **Average** | **4.25** | |

---

## Verified correct (via WebSearch)

1. **Resource group JSON property names** — `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued`, `subGroups`, `selectors`, `rootGroups` all match Trino official docs (trino.io/docs/current/admin/resource-groups.html). Example structure mirrors the canonical example in the docs.
2. **`rewrite_data_files` syntax** — Procedure name, `options => map(...)`, and option keys `target-file-size-bytes` / `min-input-files` all verified correct against iceberg.apache.org/docs/latest/spark-procedures/.
3. **`expire_snapshots` syntax** — `older_than` and `retain_last` are the correct named-argument forms in Iceberg Spark procedures.
4. **`system.runtime.queries.resource_group_id` column** — Verified present; was added in 0.206. Diagnostic query is valid in Trino 467.
5. **`fair` default scheduling policy** — Trino docs confirm `fair` (FIFO) is the default when `schedulingPolicy` is omitted. The answer doesn't set it but the default is safe for this use case.
6. **JWT principal matching** — Correct caveat that the selector `user` field matches the principal name from JWT in this production stack.
7. **Default selector regex behavior** — Selectors are evaluated in declaration order; the enterprise selector listed first will match before the catch-all `.*-service-account`. Correct ordering shown.

---

## Bug found (technical accuracy)

**The answer instructs the engineer to add `resource-groups.configuration-manager=file` and `resource-groups.config-file=etc/resource-groups.json` to `etc/config.properties`. This is wrong.**

Per the official Trino docs (https://trino.io/docs/current/admin/resource-groups.html), these properties belong in a dedicated file: **`etc/resource-groups.properties`**. `etc/config.properties` is the main Trino node configuration file (coordinator/worker settings, query memory, HTTP server, etc.). Resource group manager configuration is loaded from a separate plugin configuration file.

If an engineer follows the answer literally:
- They add the two lines to `etc/config.properties`.
- Trino starts successfully — `config.properties` does not enforce strict unknown-property rejection for these plugin-style keys.
- The resource group manager is never loaded; the JSON file is never read.
- The diagnostic query later shows everything in `global` (or the default group), and the engineer has to debug from scratch.

The fix is one word: change "Add these two lines to `etc/config.properties`" to "Create a new file `etc/resource-groups.properties` containing these two lines". The answer's diagnostic query would catch this on a sharp engineer, but a less experienced engineer would burn an hour.

---

## Strengths

- **Production-stack awareness**: explicitly calls out JWT principal matching, names `etc/resource-groups.json`, and addresses the on-prem k8s reality implicitly (no managed-service hand-waving).
- **Right answer to the meta-question**: correctly tells the engineer "no, don't rethink the table structure — the shared `tenant_id, date` layout is the standard and is correct."
- **Tiered escalation**: resource groups first, then dedicated table, then dedicated cluster. Exactly the pragmatic ordering an SRE would recommend.
- **Compaction integrated into the answer**: doesn't just stop at resource groups — explains why the enterprise tenant's daily 50M-event writes create small-file accumulation and why nightly `rewrite_data_files` is necessary to prevent file-open overhead from compounding the noisy-neighbor problem.
- **Diagnostic query is gold**: gives the engineer a concrete way to confirm the setup is working and to diagnose silent selector mismatches.
- **Common-mistakes callout**: noting that wrong property names silently load but never apply is genuinely useful production wisdom.

---

## Gaps

1. **Config-file-location bug** (see above) — the single most important issue. Costs 1.5 points on technical accuracy.
2. **No mention of `softCpuLimit` / `hardCpuLimit`** — Trino supports time-window CPU quotas in resource groups, which would be a stronger fit for "compaction is CPU-intensive" framing earlier in the answer. Memory + concurrency alone don't cap CPU.
3. **No mention of bucket partition for the big tenant** — if the enterprise tenant generates 50M events/day, single daily partitions of ~50M rows may need a second-level bucket (e.g., `bucket(16, user_id)`) to parallelize scans. The answer says partitioning is "good" but doesn't address the enterprise tenant's specific partition size.
4. **Selectors ordering note missing** — the answer doesn't tell the engineer that selectors are evaluated top-down and first-match-wins. The example is correctly ordered, but if the engineer rearranges later they could silently route enterprise traffic into `standard_tenants`.

---

## Resource fix recommendations

Search `resources/` for any guidance that places resource-groups properties in `config.properties` and correct to `resource-groups.properties`. If the bug is in a resource file, the weak-responder is echoing it — that's the root cause, not a model error. A one-line fix in the canonical resource will resolve this across all future answers.

Also worth adding to resources:
- A note that `softCpuLimit` / `hardCpuLimit` exist for time-window CPU quotas (with `cpuQuotaPeriod` at root level).
- A note on selector ordering (top-down, first-match-wins).

---

## Topic state update

**Multi-tenant analytics: isolating customer data in SaaS**
- Prior: 4.439 avg over 95 questions
- This answer: 4.25
- New running avg: (4.439 × 95 + 4.25) / 96 = (421.705 + 4.25) / 96 = 425.955 / 96 ≈ **4.437** across 96 questions
- Status: **PASSED** (well above 3.5 threshold, tested from many angles)
