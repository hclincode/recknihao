# Iter 109 Q1 — Judge Verdict

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Question summary**: Noisy-neighbor problem — one heavy customer's nightly 2-year scan slows other tenants' dashboards. Trino config? Data layout? Both?
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter109-q1.md`

---

## Technical verification (WebSearch against trino.io and iceberg.apache.org)

| Claim | Verdict | Source |
|---|---|---|
| `CALL system.runtime.kill_query('<query_id>')` is valid Trino syntax | CORRECT. Positional single-arg form is accepted; optional `message` arg also supported. | Trino docs (System connector) |
| `etc/resource-groups.properties` two-line setup (`resource-groups.configuration-manager=file` + `resource-groups.config-file=etc/resource-groups.json`) | CORRECT. This is exactly the file-based resource group manager setup. JSON file is loaded on the coordinator only. | Trino 480 Resource groups docs |
| `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued`, `schedulingWeight` property names | CORRECT for Trino 467 (unchanged from earlier versions). `hardConcurrencyLimit` and `maxQueued` are required; `softMemoryLimit` and `schedulingWeight` are optional. | Trino Resource groups docs |
| Iceberg compound partition `ARRAY['tenant_id', 'day(event_ts)']` prunes on both columns via hidden partitioning | CORRECT. Iceberg evaluates partition transforms for both partition dimensions during planning; filters on either `tenant_id` or `event_ts` (or both) participate in pruning automatically. | Iceberg partitioning docs, Dremio/RisingWave/Alex Merced explainers |
| `CALL iceberg.system.rewrite_data_files(...)` from Spark | CORRECT in form (catalog.system.procedure). Assumes the production Iceberg catalog is named `iceberg`, which is a reasonable convention but should be parameterized. | Iceberg Spark procedures docs |
| Migration path comment (partition evolution: new data on new spec, old on old) | CORRECT. Iceberg partition evolution is a core feature; old data files retain the old spec until rewritten. | Iceberg partitioning docs |
| Production fit (Kubernetes ConfigMap, coordinator restart, JWT principal selector caveat) | CORRECT and aligned with `prod_info.md` (k8s on-prem, JWT auth, OPA). |

### Minor technical nits (not score-affecting individually)

1. **`schedulingPolicy` omitted at parent level**: The example uses `schedulingWeight` on sub-groups but doesn't set `"schedulingPolicy": "weighted"` (or `"weighted_fair"`) on the parent `global` group. Without that, `schedulingWeight` is ignored by the default `fair` policy. In this example both sub-groups have weight 1 so behavior is unchanged in practice — but the field is dead code as written.
2. **Catalog naming**: `CALL iceberg.system.rewrite_data_files(...)` assumes the catalog is named `iceberg`. Production may use a different name. A one-line note ("replace `iceberg` with your catalog name") would help.
3. **Kill query authorization caveat**: The Trino docs note that for external clients, the `ADMIN` queryType must be configured in resource groups for kill_query to execute immediately rather than queue behind the target query. Not mentioned. Low-impact for the answer's flow but worth knowing.

---

## Scoring

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All headline claims verified correct against official Trino and Iceberg docs. Minor gap: `schedulingPolicy: "weighted"` should accompany `schedulingWeight` at the parent level for the weights to matter (here it's effectively a no-op since both children have weight 1, so no functional bug). |
| Beginner clarity | 4.75 | Opens with "noisy-neighbor problem" framing, clearly states "both configuration AND data layout", and explains *why* each layer matters in the comparison table. Property names called out in plain English. The `selectors` JSON shape is shown without explaining selector evaluation order (first-match wins) — a minor clarity gap for newcomers. |
| Practical applicability | 5.0 | Concrete file paths, exact two-file setup, ConfigMap-aware deployment via `kubectl rollout restart`, verification SQL against `system.runtime.queries`, immediate-remediation kill_query, partition spec DDL, Spark rewrite procedure for migration. Engineer can copy-paste and execute. Matches on-prem k8s + Trino 467 + Iceberg + JWT stack from prod_info.md. |
| Completeness | 4.75 | Covers: resource groups, partitioning, migration path, immediate remediation, deployment, verification, common pitfalls. Misses: per-query memory cap (`query.max-memory-per-node`), CPU-limit fields (`softCpuLimit`/`hardCpuLimit`) which are particularly relevant for a 20-30 minute scan, and OPA's role (the production authz backend per prod_info.md — though OPA is more about authz than resource control). |

**Weighted average**: (4.75 + 4.75 + 5.0 + 4.75) / 4 = **4.8125 / 5**

---

## Running average update

Prior: 4.456 × 103 = 458.968
New: 458.968 + 4.8125 = 463.7805
New running avg: 463.7805 / 104 = **4.460** across 104 questions

(Note: rubric Q-count for this topic at end of iter108 was 103 with running avg 4.456 per state.json. After iter109 Q1: avg 4.460 across 104 questions.)

Status: **PASSED** (well above 3.5 threshold; multi-question, multi-angle coverage already established).

---

## Resource fix recommendations

Low priority — answer is strong. If teacher wants to push the topic above 4.5:

1. **`resources/05-multi-tenant-analytics.md`** — Add a one-line note on `schedulingPolicy` requirement when using `schedulingWeight`:
   > Note: `schedulingWeight` only has effect when the parent group sets `"schedulingPolicy": "weighted"` (or `"weighted_fair"`). The default `fair` policy ignores weights.

2. **`resources/05-multi-tenant-analytics.md`** — Add CPU-limit fields (`softCpuLimit`, `hardCpuLimit`) alongside memory limits, since long-running scans are CPU-bound as much as memory-bound.

3. **`resources/05-multi-tenant-analytics.md`** (optional) — Add a selector-evaluation note: "Selectors are evaluated top-to-bottom; first match wins. Always put the catch-all selector last."

4. **`resources/05-multi-tenant-analytics.md`** (optional) — Note that `CALL system.runtime.kill_query` requires the caller's resource group to be configured with `queryType: 'ADMIN'` (or for the caller to be a system user) so the kill command doesn't queue behind the very query it's trying to terminate.

---

## Verdict

**PASS** — 4.8125 / 5. High-quality answer that fits the on-prem k8s + Trino 467 + Iceberg 1.5.2 stack. All key technical claims verified against official Trino and Iceberg documentation. Only minor polish opportunities remain.
