# Iter 112 Q1 — Judge Report

**Question topic**: Multi-tenant analytics — "Why are *small*-tenant queries getting slower after we onboarded two enterprise tenants? Trino+Iceberg, all tenants share one table partitioned by `tenant_id`. How do I fix it without splitting every tenant?"

**Phase**: extended (post-final). State pass = true. This judge run continues the per-iteration evaluation cadence.

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4 | Causal model correct, but two technical inaccuracies: (a) the partition-spec-change Fix 1 is incomplete — partition evolution is metadata-only; the `rewrite_data_files` call as written does NOT rewrite files into the new spec (it bin-packs under whatever spec the files were committed under), and `min-input-files=1` will rewrite every file (correct, but the comment "rewrite historical data under the new spec" is the inaccurate part — only manually specifying the new spec on rewrite produces that effect, and Spark's `rewrite_data_files` does so via the `partial-progress.enabled` / `where` filter combinations, not the options shown); (b) "Trino reads through the full manifest at query planning time" is a too-strong simplification — Iceberg's **manifest list** pre-filters manifests by partition value ranges before any manifest file is opened (verified against iceberg.apache.org/docs/latest/performance/ and the manifest-list pruning behavior). The small-tenant slowdown is real but the dominant mechanism is **manifest-list growth + per-file stats overhead inside the surviving manifests + worker-side small-file open cost**, not "reads the full manifest." Fix 2 (cutover sequence) and Fix 3 (resource groups JSON) are both technically correct, match Trino 467 syntax, and use valid property names. |
| Beginner clarity | 5 | Names the symptom ("noisy neighbor"), states the surprising part up front ("partition pruning still works, but three other things are hurting you"), uses plain-English explanations of manifest, compaction, and resource groups inline. The numbered "Why small tenant queries got slower" section is exactly the framing an app engineer needs. |
| Practical applicability | 5 | The engineer can execute today: Fix 1 is a single `ALTER TABLE`, Fix 2 is the 5-step cutover with a SQL-level verification step, Fix 3 is a complete `resource-groups.json` plus a registration `.properties` file plus the `kubectl rollout restart` command. The "complementary, not alternative" callout at the end is exactly the right pedagogical move — it tells the engineer NOT to pick one fix over the other. Closing checklist gives a concrete ordered execution plan. |
| Completeness | 4 | Covers the three main causes (manifest bloat, maintenance contention, no CPU isolation) and pairs each with a concrete fix. Two notable gaps: (a) **does not mention the `bucket(tenant_id, N)` option for >100 tenants** — the engineer has 200 customers, which is exactly the threshold where the resource recommends switching from identity partitioning to bucket partitioning to bound manifest size, but the answer just suggests adding `day(event_ts)` while keeping `tenant_id` as an identity partition; (b) **does not mention `EXECUTE optimize` from Trino 467** (the in-session compaction path the resource now recommends as default) — instead jumps to Spark `rewrite_data_files`, which is correct but not the lowest-friction option for this engineer who is already in a Trino session. Also misses: (c) verification step (run `$partitions` query after the migration to confirm tenant Acme has 0 rows in the shared table), (d) the JWT-principal-vs-role caveat for the selector `"user"` field that the resource explicitly calls out as the #1 silent-failure mode. |
| **Average** | **4.50** | **PASSING** (≥ 3.5 threshold) |

**Verdict**: PASS

---

## What WebSearch verified as correct

1. **`ALTER TABLE iceberg.analytics.events SET PROPERTIES partitioning = ARRAY[...]`** — verified at trino.io/docs/current/connector/iceberg.html. The syntax is correct for Trino 467. The behavior is correctly characterized as "for new writes" (the answer's comment says "change partition spec for new writes" — accurate per Iceberg evolution docs at iceberg.apache.org/docs/latest/evolution/).

2. **Manifest-list partition pruning exists in Iceberg** — verified at iceberg.apache.org/docs/latest/performance/. The query planner does NOT read every manifest; the manifest list acts as an index. The answer's phrasing "the Trino coordinator still reads through the full manifest at query planning time" is misleading (see Technical Accuracy notes above) but the *direction* of the claim (more entries → slower planning) is supported by the e6data and Cazpian articles documenting 200ms → 45s planning regressions at scale.

3. **Resource group JSON property names** (`hardConcurrencyLimit`, `softMemoryLimit`, `hardCpuLimit`, `cpuQuotaPeriod`, `selectors[].user`) — all verified against trino.io/docs/current/admin/resource-groups.html. The answer uses every valid name correctly.

4. **`CREATE TABLE LIKE ... INCLUDING ALL` syntax** — Trino supports `CREATE TABLE new LIKE existing [INCLUDING/EXCLUDING PROPERTIES]`. The `INCLUDING ALL` form is not the documented syntax in current Trino docs (the documented forms are `INCLUDING PROPERTIES` / `EXCLUDING PROPERTIES`), though some downstream forks accept `INCLUDING ALL`. This is a minor inaccuracy worth flagging.

5. **`kubectl rollout restart deployment/trino-coordinator -n trino`** — matches the production stack (Kubernetes on-prem per `prod_info.md`). Correct command.

6. **5-step cutover order (INSERT → verify → swap view → DELETE)** — matches the resource's documented safe sequence exactly. The "view swap happens before DELETE so the dedicated table is a complete backup" reasoning is correct.

---

## Errors and gaps found

### Technical inaccuracy 1 — `CREATE TABLE LIKE ... INCLUDING ALL`
The documented Trino `CREATE TABLE LIKE` clause supports `INCLUDING PROPERTIES` or `EXCLUDING PROPERTIES` (and column-copy is implicit). `INCLUDING ALL` is not in the trino.io/docs/current/sql/create-table.html grammar for the standard Trino 467 distribution. Engineers copying this DDL will hit a parse error. The correct form is `LIKE iceberg.analytics.events INCLUDING PROPERTIES`.

### Technical inaccuracy 2 — "manifest" terminology overstatement
The answer says: "Trino coordinator still reads through the full manifest at query planning time to find which files to skip." Two issues:
- Iceberg's manifest **list** (the top-level metadata file) pre-prunes manifests by partition-value ranges, so the planner does NOT open every manifest.
- Even within surviving manifests, the per-file column statistics let the planner skip individual data-file entries.

A more accurate phrasing: "the manifest list and surviving manifests both grow, so even though only your tenant's files end up scanned, the planner has more metadata to traverse to find them, which adds tens to hundreds of milliseconds to planning latency." The directional claim is right; the mechanism description oversimplifies.

### Technical inaccuracy 3 — Fix 1's rewrite call comment
The answer's Python block comments: "Spark: rewrite historical data under the new spec." With `target-file-size-bytes` and `min-input-files` alone, `rewrite_data_files` bin-packs files but does NOT eagerly rewrite them under the new partition spec. To actually re-layout historical data under the new spec, you typically need a CTAS, OR use the Spark procedure with explicit per-partition rewrite scope. This is the same pitfall the Iceberg evolution docs warn about: partition evolution is metadata-only by design.

### Completeness gap 1 — missing `bucket(tenant_id, N)` recommendation
The engineer has 200 tenants. The resource explicitly says: "switch to `bucket(tenant_id, 32)` (or larger) above ~100 tenants; revisit `N` if the tenant count crosses 1000." The answer does not mention this option at all — it only suggests adding `day(event_ts)` while keeping `tenant_id` as an identity partition (which at 200 × 90 days = 18,000 partitions is exactly the bloat zone the resource warns about). This is a meaningful omission for a 200-tenant case.

### Completeness gap 2 — Trino-native `EXECUTE optimize` not mentioned
The resource now positions `ALTER TABLE ... EXECUTE optimize` as the default routine compaction path on the on-prem stack ("no Spark hop, runs from the dashboard SQL session"). The answer skips it entirely and reaches for Spark `rewrite_data_files`. For an engineer already in Trino diagnosing a query problem, the Trino-native path is the lower-friction option.

### Completeness gap 3 — selector "user" matches JWT principal warning
The resource has a prominent callout: resource group selectors match the JWT principal (e.g., `acme-service-account`), NOT a Trino role name. The answer's selector uses `acme-service-account` (correct in spirit) but does not explain WHY — meaning an engineer who decides to label tenants differently (e.g., `acme_role` instead of `acme-service-account`) will hit the silent-failure mode the resource explicitly warns about.

### Completeness gap 4 — no verification of the cutover
The 5-step cutover ends at DELETE. The resource recommends a post-cutover verification: connect as the tenant principal and run `SELECT DISTINCT tenant_id FROM <view>` to confirm it returns exactly one value, and run the `$partitions` query against the shared table to confirm Acme is gone. Without these, the engineer has no way to prove the migration succeeded.

---

## Resource fix recommendations

### HIGH priority

1. **File: `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` — Noisy neighbor section**
   Add an explicit subsection titled "Why **small-tenant** queries get slower when you add a few large tenants" that explains the three mechanisms (manifest-list growth, shared maintenance contention, no per-tenant CPU isolation) and links them to the three corresponding fixes (partition strategy revisit, dedicated table migration for outliers, resource groups). This is the *exact* question the engineer asked, and the resource currently only documents the cross-tenant query slowdown direction (large tenant slows everyone), not the reverse direction (large tenant slows the *small* tenants). The weak-AI got the answer mostly right by inference, but the resource doesn't directly address this framing — which is why two of the four answer dimensions ended at 4 instead of 5.

### MEDIUM priority

2. **File: `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` — Iceberg partition strategy section**
   Add a "200-tenant case study" example that walks through the decision: at 200 tenants, identity-partition `(day, tenant_id)` produces ~18,000 partitions over 90 days — past the comfort zone. Show the `bucket(tenant_id, 32)` migration with the partition count math (90 × 32 = 2,880) and the tradeoff that you lose per-tenant `$partitions` metadata. The current Option C section describes this for 400 tenants but should add the 200-tenant decision point because that's the question's actual scale.

3. **File: `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` — Safe cutover sequence section**
   Add a "Step 5: post-cutover verification" subsection with two SQL snippets: (a) as the tenant principal, `SELECT DISTINCT tenant_id FROM tenant_acme.events` must return exactly one row; (b) as admin, `SELECT * FROM iceberg.analytics."events$partitions" WHERE partition.tenant_id = 'acme'` must return zero rows. Without these the cutover is "done" but unverified.

### LOW priority

4. **File: `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` — `CREATE TABLE LIKE` example**
   The `LIKE iceberg.analytics.events INCLUDING ALL` form in the cutover SQL section should be replaced with `LIKE iceberg.analytics.events INCLUDING PROPERTIES` to match Trino 467's documented `CREATE TABLE` grammar. `INCLUDING ALL` will parse-error on a vanilla Trino 467 distribution.

5. **File: `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` — manifest terminology**
   Tighten the language anywhere the resource implies the planner "reads the full manifest." Replace with "Iceberg's manifest list pre-filters manifests by partition range, but as the manifest count grows the planner has more entries to traverse to find the surviving manifests." This affects both the noisy-neighbor section and the "Why small tenant queries got slower" framing the HIGH-priority fix introduces.

6. **File: `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` — Fix-1 partition-spec change example**
   Add a one-line callout: "Iceberg partition evolution is metadata-only. Old files keep their old partition spec; only new writes use the new spec. To re-layout historical data under the new spec, you need a CTAS or a per-partition `EXECUTE optimize` loop — `rewrite_data_files` alone bin-packs but does not re-layout."

---

## Summary

PASS at 4.50 average. The answer is well-structured, names the right root causes, and gives complete, executable fixes for two of the three causes (cutover + resource groups). The two weak spots are (a) Fix 1's partition-spec-change instructions are technically loose about what `rewrite_data_files` actually does, and (b) the answer doesn't mention `bucket(tenant_id, N)` for the 200-tenant scale, which is exactly the resource's documented recommendation for that tenant count. None of these are blocking; they are resource-improvement opportunities that would push next iteration's answer from 4.5 to 5.0.

Sources consulted via WebSearch:
- [Iceberg connector — Trino 481 docs](https://trino.io/docs/current/connector/iceberg.html)
- [Resource groups — Trino docs](https://trino.io/docs/current/admin/resource-groups.html)
- [Iceberg Evolution docs](https://iceberg.apache.org/docs/latest/evolution/)
- [Iceberg Performance docs](https://iceberg.apache.org/docs/latest/performance/)
- [Tackling Apache Iceberg Metadata at Massive Scale — e6data](https://www.e6data.com/blog/apache-iceberg-million-files-metadata)
- [Iceberg Query Performance Tuning — Cazpian](https://www.cazpian.ai/blog/iceberg-query-performance-tuning-partition-pruning-bloom-filters-and-spark-configs)
