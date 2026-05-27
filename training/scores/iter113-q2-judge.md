# Iter 113 Q2 — Judge Report

**Question topic**: Multi-tenant analytics — noisy-neighbor problem with two enterprise tenants degrading 78 small tenants on a shared Iceberg `events` table partitioned by `(tenant_id, event_date)`. The engineer asks (a) is it a partitioning problem, (b) what to actually do, (c) dedicated tables vs same-table tactics.

**Production environment fit**: Trino 467 + Iceberg 1.5.2 + Hive Metastore + MinIO on-prem Kubernetes, OPA-backed authorization, JWT auth. Resource groups (file-based or DB-backed) are valid on this stack.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every SQL, JSON config, and Iceberg/Trino claim verified against official docs. See "Verified correct" below. |
| Beginner clarity | 4 | Clear structure: problem decomposition (3 mechanisms), then 2-part fix (storage isolation + compute isolation), then concrete steps. Terms like "manifest list", "snapshot expiry", "orphan-file cleanup", "QUEUED state", "principal", "JWT sub claim", "resource group" are used without inline glosses — a SaaS engineer new to Trino/Iceberg will follow the high-level narrative but may need to look up the metadata vocabulary. Not enough to fail the dimension, but it's the only weak spot. |
| Practical applicability | 5 | Engineer can execute immediately. Numbered 5-step cutover with abort semantics, exact JSON property names that match the Trino 467 schema, kubectl restart commands, a verify-via-`system.runtime.queries` step, and a closing 5-item operational checklist including the "promote any tenant past 30% of table size" preventive alert. |
| Completeness | 5 | Answers all three sub-questions directly: (a) "is it a partitioning problem?" — partly yes (mechanisms 1+2 are metadata/maintenance, mechanism 3 is unrelated to partitioning); (b) "what to actually do" — 5-step cutover + resource groups + verification; (c) "dedicated tables vs same-table" — both are needed for different reasons. Includes the storage-vs-compute distinction that is the core teaching point of this scenario. |

**Average: 4.75 — PASS (well above 3.5 threshold)**

**Verdict: STRONG PASS.** This is one of the cleanest answers I've seen on the multi-tenant noisy-neighbor topic. It demonstrates the exact synthesis the consolidated iter112 judge feedback asked the teacher to enable: three-mechanism root-cause analysis + storage isolation + compute isolation as complementary (not alternative) levers.

---

## What was verified correct (via official docs + resources)

1. **Resource-groups two-file pattern.** Confirmed against [trino.io/docs/current/admin/resource-groups.html](https://trino.io/docs/current/admin/resource-groups.html): `resource-groups.configuration-manager=file` + `resource-groups.config-file=etc/resource-groups.json` is the correct registration mechanism. The answer correctly creates both files; without `resource-groups.properties` the JSON would be inert. This matches the "CRITICAL — the JSON file alone is INERT until you register it" callout in `resources/05-multi-tenant-analytics.md`.
2. **Property names** (`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`, `softCpuLimit`, `hardCpuLimit`, `cpuQuotaPeriod`) all exist in the Trino 467+ resource-groups schema. Confirmed against the official docs. `cpuQuotaPeriod` is correctly placed at the root level (not per group). Duration string format (`"1h"`, `"2h"`, `"3h"`) is correct.
3. **Selector `"user"` field** — confirmed; the answer correctly uses `"user"` (not the commonly-invented `"userRegex"`). The Java-regex semantics of the value are also implicit in the `.*` catch-all selector.
4. **`CREATE TABLE LIKE ... INCLUDING PROPERTIES`** — confirmed against [trino.io/docs/current/sql/create-table.html](https://trino.io/docs/current/sql/create-table.html). The answer correctly uses `INCLUDING PROPERTIES` (not `INCLUDING ALL`, which is the common foot-gun the resources file explicitly warns about).
5. **`system.runtime.queries`** has the columns `query_id`, `user`, `resource_group_id`, `state` — verified. The verification query is well-formed. Minor nuance: `resource_group_id` is `array(varchar)` rather than a single string, but `SELECT resource_group_id` and visual inspection works fine — the answer doesn't make a wrong-type claim about it.
6. **Iceberg `$partitions`** exposes `partition`, `record_count`, `file_count`, `total_size` — confirmed. The answer's identify-heavy-tenants query is metadata-only (no full table scan) which is the right pattern for an 80-tenant fleet on identity-partitioned `tenant_id`.
7. **Cutover ordering** — INSERT → verify → view swap → DELETE. This matches the resources file's "safe cutover sequence" and the failure-mode analysis (every intermediate failure is recoverable because the destructive DELETE is last). The answer's framing "safe to abort at any step before Step 5" is exactly correct.
8. **Storage isolation vs compute isolation are complementary, not alternative.** This is a load-bearing teaching point that the resources file explicitly added in iter113 ("Tenant migration and resource groups are complementary, not alternative, levers"), and the answer surfaces it cleanly in the introductory framing.

---

## Errors or gaps found

**None substantive.** Minor nits below — none would meaningfully mislead the engineer:

1. **OPA-vs-grants nuance not mentioned for the view step.** The answer creates `tenant_acme.events` as a view and assumes the existing grant/role wiring carries over. On the production OPA-backed stack, the actual access decision for the new view (and for the dedicated table) must also be reflected in the OPA Rego bundle. The resources file has a long "SQL GRANT/REVOKE vs OPA — which one is the actual enforcement layer?" callout that this answer doesn't reference. For this question (which is about performance, not access control), the omission is reasonable — but a slightly more careful answer would have one sentence: "Don't forget to update the OPA bundle to allow the tenant principal SELECT on the new view and the dedicated table; SQL GRANT alone is inert on this stack."

2. **Dedicated table partitioning loses tenant_id but keeps `day(event_ts)`.** This is correct (single-tenant table doesn't need `tenant_id` in the partition spec), but the answer doesn't mention that for a 200M-row tenant generating events constantly, the engineer should also consider whether `day(event_ts)` alone is the right grain or whether they want `hour(event_ts)` or to add a `bucket(user_id, N)` secondary partition for parallelism within a day. Minor — the day-grain default is fine to ship with and revisit.

3. **`system.runtime.queries` access** — the verification query assumes the running user has SELECT on `system.runtime.queries`. On a hardened multi-tenant cluster (per the resources file's "system catalog leak" section), this is denied to tenant principals and only allowed for admin/data-team. The answer should be read as "run this as the admin who deployed the resource-groups change." Not wrong, but slightly under-specified.

4. **Coordinator restart side effects not surfaced.** The kubectl rollout restart brings down the coordinator briefly. In-flight queries are lost. The answer doesn't mention this — for an engineer used to rolling-deployment app servers, this is a small surprise. The resources file's "Changes affect only NEW queries submitted after the restart" callout would have been a useful one-liner to include.

None of these gaps would cause harm; they're polish items.

---

## Resource fix recommendations

**No HIGH or MEDIUM resource fixes warranted from this question.** The resources file (`resources/05-multi-tenant-analytics.md`) already covers everything the answer drew from, and the iter113 teacher additions (three-mechanism noisy-neighbor subsection, post-cutover verification, `INCLUDING PROPERTIES` correction, 200-tenant bucket case study, complementary-levers framing) clearly enabled this strong answer.

**LOW priority polish items** (file: `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`):

1. **LOW — Add a one-liner to the noisy-neighbor section about coordinator restart blast radius.** Suggested addition near the existing "Changes affect only NEW queries submitted after the restart" callout: "Note that `kubectl rollout restart deployment/trino-coordinator` causes a brief coordinator outage; in-flight queries are lost and clients see connection errors for ~10–30 seconds. Schedule resource-group config pushes during low-traffic windows, or migrate to the database-backed resource group manager for hot reload."

2. **LOW — Add a cross-link from the cutover section to the OPA bundle update step.** The 5-step cutover is correct, but doesn't remind the reader that on the OPA-backed prod stack, granting access to the new dedicated table or the swapped view requires an OPA bundle update — SQL GRANT alone won't do it. One sentence cross-referencing the "SQL GRANT/REVOKE vs OPA" callout would close the loop.

3. **LOW — Mention single-tenant dedicated table partitioning options.** In the dedicated-table CREATE TABLE example, add a short note that for very high-volume single-tenant tables, `day(event_ts)` alone may not give enough write/scan parallelism — consider `(day(event_ts), bucket(user_id, N))` or `hour(event_ts)` depending on query patterns. The 200M-row case in this question is borderline but the answer doesn't surface the option.

None of these are blocking.

---

## Topic checklist update

This question exercises **Multi-tenant analytics: isolating customer data in SaaS** (the noisy-neighbor / scaling-isolation angle, with bridge into Iceberg partitioning and table maintenance). The topic was already PASSED with 103 questions and avg 4.456; this answer's 4.75 raises the running average. No status change.

Also lightly touched:
- **Iceberg partition design for SaaS** (dedicated-table partitioning choice, identity-partition vs scale)
- **Iceberg table maintenance** (compaction / snapshot expiry cost on shared vs dedicated tables)
- **Query performance regression diagnosis** (the three-mechanism root-cause framework)

All three are already PASSED; this answer reinforces them.

---

## Sources verified

- [Trino Resource groups documentation](https://trino.io/docs/current/admin/resource-groups.html) — verified property names, selector key, file pattern
- [Trino CREATE TABLE documentation](https://trino.io/docs/current/sql/create-table.html) — verified `INCLUDING PROPERTIES` grammar
- [Trino Iceberg connector documentation](https://trino.io/docs/current/connector/iceberg.html) — verified `$partitions` metadata columns
- [Trino system.runtime.queries schema](https://github.com/trinodb/trino/issues/5464) — verified `user`, `state`, `resource_group_id` columns exist with correct types
