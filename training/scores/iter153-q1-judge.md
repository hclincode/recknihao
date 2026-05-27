# Iter 153 Q1 — Judge Report

**Question topic**: Trino "Query exceeded per-node memory limit" on 90-day funnel join (300M-row events × customers); does spill-to-disk need to be enabled; rewrite vs. config tradeoff.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter153-q1.md`

---

## Overall

| Metric | Value |
|---|---|
| Technical accuracy (weight 2x) | 4.25 |
| Clarity (weight 1x) | 4.75 |
| Practical usefulness (weight 1x) | 4.50 |
| Completeness (weight 1x) | 3.25 |
| **Weighted average** | **(4.25*2 + 4.75 + 4.50 + 3.25) / 5 = 4.20** |
| **Verdict** | **FAIL** (below 4.5 threshold) |

The answer is technically clean on memory error names and config properties, gives a strong query-rewrite playbook (partition filter, pre-aggregation, denormalization), and correctly recommends `EXPLAIN ANALYZE` for diagnosis. It fails on the question's **primary ask**: the engineer explicitly asked whether spill-to-disk needs to be turned on and how it works. The answer admits the resources don't cover it and then dismisses spill as "a last resort." That is an unacceptable punt — Trino 467 fully supports spill-to-disk and the production stack (on-prem k8s, MinIO, no autoscaling) is exactly where spill is most useful as a safety net.

---

## Per-dimension scoring

### Technical accuracy — 4.25 / 5

**Verified correct**:
- `EXCEEDED_LOCAL_MEMORY_LIMIT` is a real Trino error code raised when a query's user memory on a single worker hits `query.max-memory-per-node` ([trinodb/trino #25465](https://github.com/trinodb/trino/issues/25465), [Trino issue #20398](https://github.com/trinodb/trino/issues/20398)).
- `query.max-memory-per-node` and `query.max-memory` are the correct property names per [Trino Resource management properties](https://trino.io/docs/current/admin/properties-resource-management.html).
- Build-side hash table memory pressure in a hash join growing with the larger input is correctly described.
- Partition-pruning rewrite using `WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY` is sound for an Iceberg table partitioned by `event_date` (transforms permitting).
- Pre-aggregation before join (CTE that reduces 300M rows to one row per tenant before joining the customer dim) is a valid and standard Trino optimization for star-schema joins with skewed large fact sides.
- `EXPLAIN ANALYZE` is the right diagnostic step.

**Minor accuracy issues** (−0.75):
- `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` is presented as the canonical name. Modern Trino raises `EXCEEDED_GLOBAL_MEMORY_LIMIT` / sometimes `EXCEEDED_PER_QUERY_LIMIT` (cluster-wide) and the docs talk about `query.max-memory` / `query.max-total-memory` ([Resource management properties](https://trino.io/docs/current/admin/properties-resource-management.html)). `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` is older Presto-era nomenclature still used in places but no longer the precise error code in Trino 467. Not catastrophically wrong, but the engineer copy-pasting that string into a grep will not find it in newer logs.
- The `EXPLAIN ANALYZE` example tells the user to look for "operator with highest `Physical Input:` bytes." `Physical Input:` is a real Trino field but it is **not the right signal for memory pressure** — memory pressure shows up as `Peak Memory Reservation` / per-operator memory in the EXPLAIN ANALYZE VERBOSE output. (This is the same field-naming class of error flagged in iter152 Q1.)
- The answer doesn't mention that increasing `query.max-memory-per-node` also has the constraint `query.max-memory-per-node + memory.heap-headroom-per-node < JVM Xmx`, which is the most common pitfall when raising this limit ([Resource management properties](https://trino.io/docs/current/admin/properties-resource-management.html)).

### Clarity — 4.75 / 5

Well-organized: error-meaning table up front, then "in order of preference" options with code, then a diagnosis step, then a summary table. SQL examples are concrete and reflect the engineer's actual scenario (events vs. customers, 90-day funnel, tenant_id). Easy to follow with no OLAP knowledge required. Minor deduction (−0.25) for the section labelled "On spill-to-disk" being only 2 sentences and burying the actual answer to the user's primary question.

### Practical usefulness — 4.50 / 5

The query rewrites are immediately actionable — engineer can copy the CTE pattern and run it. Config change command (`query.max-memory-per-node=16GB` in `etc/config.properties`, restart workers) is concrete and correct for on-prem Trino. The diagnostic flow (run EXPLAIN ANALYZE, look at hottest operator, decide between Option 1 vs Option 2) is exactly the playbook a SaaS engineer needs. Deduction (−0.50) because the engineer's literal question "do we need to configure something in Trino to enable spill-to-disk for large joins" is not actually answered — no `spill-enabled=true`, no `spiller-spill-path`, no comment on the on-prem MinIO/k8s implication for choosing a local spill directory.

### Completeness — 3.25 / 5

Covers:
- Both error types and config properties.
- Query rewrite options (partition filter, pre-aggregation, denormalization).
- Memory bump path.
- Diagnosis with EXPLAIN ANALYZE.

Misses:
- **Spill-to-disk configuration**, the question's headline ask. Trino 467 ships full spill-to-disk support (`spill-enabled`, `spiller-spill-path`, `spill-compression-codec`, `spill-encryption-enabled`, `max-spill-per-node`, `query-max-spill-per-node`) per [Trino Spilling properties](https://trino.io/docs/current/admin/properties-spilling.html) and [Trino Spill to disk](https://trino.io/docs/current/admin/spill.html). Spilling supports inner+outer joins, aggregations, sort, and window. The answer should have described enabling spill, picking spill directories on local NVMe (not the JVM log disk), the per-node spill cap defaults (100GB), and the "slower but the query finishes" tradeoff. Instead it punts with "the current resources do not document Trino's spill-to-disk configuration for this on-prem stack."
- **Broadcast vs. partitioned join distribution** (`join_distribution_type` session property, or `PARTITIONED` vs `BROADCAST`). A common per-node OOM cause when the planner picks BROADCAST for a dim that turned out to be larger than expected, or PARTITIONED when one tenant_id is heavily skewed. This is a one-session-property fix that often resolves the exact error.
- **`task.concurrency`** and the relationship between concurrency and memory pressure per operator.
- **Fault-tolerant execution (FTE)** as the modern alternative recommended by Trino docs for OOM resilience — worth at least a mention even if out of scope for the immediate fix.
- The 200GB cluster limit and 8GB per-node limit in the answer are presented as if they come from "production runbook" but `prod_info.md` does not specify these — the answer invents specific values without flagging the assumption.

---

## Verified-correct claims (sources)

1. `EXCEEDED_LOCAL_MEMORY_LIMIT` error — confirmed: [trinodb/trino #25465](https://github.com/trinodb/trino/issues/25465), [Trino issue #20398](https://github.com/trinodb/trino/issues/20398).
2. `query.max-memory-per-node` and `query.max-memory` property names — confirmed: [Trino Resource management properties](https://trino.io/docs/current/admin/properties-resource-management.html).
3. Constraint `query.max-memory-per-node + memory.heap-headroom-per-node < JVM heap` — confirmed (answer omits this constraint).
4. Spill-to-disk is supported in Trino 467 — confirmed: [Trino Spill to disk](https://trino.io/docs/current/admin/spill.html), [Trino Spilling properties](https://trino.io/docs/current/admin/properties-spilling.html). Properties include `spill-enabled` (default false), `spiller-spill-path` (required when enabled, comma-separated for multi-disk), `spill-compression-codec` (NONE/LZ4/ZSTD), `spill-encryption-enabled`, `max-spill-per-node` (default 100GB), `query-max-spill-per-node` (default 100GB).
5. Spill works for joins (inner + outer), aggregations, sort, window — confirmed: [Trino Spill to disk](https://trino.io/docs/current/admin/spill.html).
6. Pre-aggregation before joining a dim table — standard star-schema Trino optimization, sound advice.

---

## Errors and gaps

| Severity | Finding |
|---|---|
| **HIGH** | Spill-to-disk is the primary user ask and the answer punts. Resources do not document it; the answer admits this and then dismisses spill as last-resort without explaining `spill-enabled`, `spiller-spill-path`, supported operations, per-node spill caps, or local-disk siting concerns on k8s pods. Trino 467 fully supports it. |
| **HIGH** | Coverage gap in `resources/`: there is no Trino spill-to-disk page. Grep for "spill" returns only passing Spark / Postgres references. Needs a new section in `resources/18-query-performance-regression.md` or a dedicated subsection in a Trino memory tuning resource. |
| **MEDIUM** | `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` is presented as a current Trino error code. Trino 467 uses `EXCEEDED_GLOBAL_MEMORY_LIMIT` / cluster-wide variants tied to `query.max-memory` / `query.max-total-memory`. Engineer searching logs for the answer's string may not find it. |
| **MEDIUM** | `EXPLAIN ANALYZE` diagnostic guidance points at `Physical Input:` for memory pressure. Memory pressure shows in `Peak Memory Reservation` / VERBOSE memory fields, not `Physical Input:` (which is bytes scanned). Same class of field-naming error as iter152 Q1. |
| **MEDIUM** | No mention of `join_distribution_type` (BROADCAST vs PARTITIONED) — a frequent one-property fix for per-node OOMs on dim joins. |
| **LOW** | `query.max-memory-per-node + memory.heap-headroom-per-node < JVM Xmx` constraint not stated when telling user to raise per-node limit. |
| **LOW** | Specific values "8GB per-node, 200GB cluster" presented as the prod runbook config but `prod_info.md` doesn't specify these. Answer should flag as illustrative. |
| **LOW** | No mention of Trino fault-tolerant execution as the modern alternative path for OOM resilience. |

---

## Resource fix recommendations

1. **HIGH — create or extend a Trino memory tuning resource** (suggest extending `resources/18-query-performance-regression.md`) with a section "Trino spill-to-disk for large joins/aggregations" covering:
   - `spill-enabled=true`, `spiller-spill-path=/mnt/disk1/trino-spill,/mnt/disk2/trino-spill` (comma-separated, separate from JVM log disk).
   - On k8s: use `emptyDir` or local PV mounted to fast NVMe; document the spill volume must be sized for `max-spill-per-node` (default 100GB).
   - `spill-compression-codec=ZSTD` for the on-prem disk-bound case.
   - Supported operations: joins (inner + outer), aggregations, sort, window — with caveat that single very large window does not spill.
   - Tradeoff framing: spill turns OOM-fail into "slower but completes." Not a replacement for query rewrites, but a legitimate safety net for the production stack where you can't scale up workers on demand.
   - Sources: [Trino Spill to disk](https://trino.io/docs/current/admin/spill.html), [Trino Spilling properties](https://trino.io/docs/current/admin/properties-spilling.html).
2. **MEDIUM — correct error-code naming** in any existing memory tuning content. Use `EXCEEDED_LOCAL_MEMORY_LIMIT` and the current cluster-wide code names tied to `query.max-memory` / `query.max-total-memory`. Drop the older `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` form or label it as legacy.
3. **MEDIUM — fix the EXPLAIN ANALYZE field-name guidance**, propagating the iter152 Q1 fix. For memory diagnosis, point to `Peak Memory Reservation` and VERBOSE per-operator memory, not `Physical Input:` bytes.
4. **MEDIUM — add a section on `join_distribution_type`** (BROADCAST vs PARTITIONED) and `task.concurrency` as session-level levers for per-node OOM on joins.
5. **LOW — add the `query.max-memory-per-node + memory.heap-headroom-per-node < JVM heap` constraint** in any "raise the limit" guidance, with a worked example for an 8-core / 32GB-heap worker.

---

## Rubric impact note

This question primarily exercises Trino memory management + query performance regression topics. If those topics' running average drops below 4.0 after this 4.20, that's a signal the resources need the spill-to-disk addition before declaring done in the extended phase.
