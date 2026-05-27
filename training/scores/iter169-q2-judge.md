# Iter 169 Q2 — Judge Score Report

**Date**: 2026-05-26
**Phase**: extended (post-final)
**Topic**: Trino federation / cross-source connectors (PostgreSQL connector: PK vs index, predicate pushdown diagnostic, dynamic filtering, `CREATE INDEX CONCURRENTLY`)
**Question**: We have one of our heavier Postgres tables that has no primary key — it's a log-style table that just accumulates rows and nobody ever set up a PK on it. I noticed our federated queries that join Iceberg data against this table seem slower than joins against our other Postgres tables that do have primary keys. Is the lack of a primary key actually affecting query performance when Trino talks to Postgres, or is that just a coincidence and something else is going on?

---

## Verdict

**Score: 4.30 / 5 — PASS (general 3.5) / FAIL topic threshold (4.5) — short by 0.20**

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Technical accuracy | 4.0 | ×2 | 8.0 |
| Beginner clarity | 4.5 | ×1 | 4.5 |
| Practical applicability | 5.0 | ×1 | 5.0 |
| Completeness | 4.0 | ×1 | 4.0 |
| **Total** | | /5 | **21.5 / 5 = 4.30** |

---

## Dimension reasoning

### Technical accuracy: 4.0

**Strengths (verified against trino.io and postgresql.org):**

1. **Core thesis correct** — "PK absence doesn't drive Trino federation performance; index absence does." This is the right diagnosis. Trino's PostgreSQL connector does NOT use Postgres primary-key metadata for optimization beyond what indexes provide. The PG connector's optimizations are: (a) cost-based decisions via PG-provided table/column statistics, (b) predicate/projection pushdown via JDBC, (c) join pushdown within a single catalog. None of these consult PK metadata directly. The reason PK tables tend to be faster in practice is the automatic unique B-tree index PG creates for every PRIMARY KEY constraint — *that index* is what the pushed-down predicate uses for Index Scan instead of Seq Scan. The answer's framing is correct.

2. **"PK tables automatically have an index on the join key"** — verified correct. Per PostgreSQL docs: "Adding a primary key will automatically create a unique B-tree index on the column or group of columns listed in the primary key, and this index is the mechanism that enforces the constraint." (postgresql.org/docs/current/indexes-unique.html). The answer's inference — that users join on the PK column and unknowingly benefit from this auto-index — is sound.

3. **`CREATE INDEX CONCURRENTLY` syntax** — verified correct PG syntax. Holds `ShareUpdateExclusiveLock` (allows reads + writes) during the bulk of the operation; brief `AccessExclusiveLock` only at the very end to mark the index valid. Does not block INSERT/UPDATE/DELETE — perfectly suited to a "log-style table that accumulates rows." Important caveat the answer omits: `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block, can fail and leave an INVALID index that must be `DROP`ped and retried, and takes ~2x longer than a normal index build. Not a fatal omission for this Q, but worth a sentence.

4. **`pg_indexes` query columns** — verified correct. `schemaname`, `tablename`, `indexname`, `tablespace`, `indexdef` are the five real columns. The shown query `SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'your_log_table'` is valid and useful, though it would be more correct to also filter by `schemaname` to avoid ambiguity if the table name appears in multiple schemas.

5. **Range pushdown column types** — "numeric, temporal, UUID, DATE" — correct on which types support range pushdown. The PG connector's documented limitation is that range pushdown (`>`, `<`, `BETWEEN`) does NOT work on character types (CHAR/VARCHAR) unless the experimental `postgresql.experimental.enable-string-pushdown-with-collate` flag is set. The answer correctly omits strings from the range-pushdown list.

**Weaknesses (where the answer is imprecise or partially wrong):**

1. **ScanFilterProject vs Filter node diagnostic — framing is muddled and partially backward.** The answer says: "If predicates are embedded inside the `ScanFilterProject` node for the Postgres table, pushdown worked. If you see a separate `Filter` node *above* the scan, Trino is filtering in-memory after pulling the full table." This is not how the EXPLAIN signal actually reads in Trino. The canonical interpretation (per Trino docs): **successful predicate pushdown means the filter does NOT appear in the plan at all — you see a `TableScan` node with the predicate listed inside its `constraint:` / domain info, not a `ScanFilterProject`.** When pushdown *fails*, you see a `ScanFilterProject` (or equivalently, a `Filter` followed by a `TableScan`) doing the filtering inside Trino. The answer reverses the meaning of `ScanFilterProject` — it treats `ScanFilterProject` as a sign that pushdown worked, when in fact `ScanFilterProject` is the operator that runs the filter *inside Trino* (after the data has been pulled from Postgres). This is a meaningful factual error that would confuse a beginner trying to diagnose. **The correct diagnostic** for a beginner is to (a) run `EXPLAIN (TYPE LOGICAL)` or `EXPLAIN (TYPE DISTRIBUTED)`, (b) look for the TableScan node on the Postgres side, (c) check whether the WHERE clause's predicates appear within that node's tuple-domain/constraint info, or whether they remain as a separate Filter/ScanFilterProject above it. Better still, run the query and check `pg_stat_activity` to see the actual SQL Trino sent — which the answer also recommends, and is the more reliable check.

2. **`dynamicFilterSplitsProcessed` on "the Iceberg side"** — direction is questionable. In a join where Iceberg is the build side and Postgres is the probe side, the dynamic filter flows FROM the Iceberg scan (which collects the build-side keys) INTO the Postgres scan. The `dynamicFilterSplitsProcessed` metric is reported on the **scan that consumed the dynamic filter** — i.e., the Postgres scan, not the Iceberg scan. The answer's "check `dynamicFilterSplitsProcessed` on the Iceberg side" is the wrong side; the user should check it on the Postgres scan operator. Additionally, JDBC connectors (PostgreSQL included) have historically had limited dynamic-filter support — Trino can push dynamic filters into Postgres queries but the mechanism and metric reporting differ from the Hive/Iceberg case. The metric will appear, but the direction the answer points the user at is wrong.

3. **"Trino pushes down IN-lists (generated by dynamic filtering)"** — generally correct in spirit, but the wording conflates two distinct things. Static IN-list predicates from the user's SQL (e.g., `WHERE id IN (1,2,3)`) are pushed down separately from dynamic filters (runtime-generated lists from join build sides). Both end up as predicates Postgres can use, but framing dynamic filters as "IN-lists" is a simplification — they're actually pushed as tuple-domain ranges or hash sets depending on cardinality. Minor pedagogical imprecision, not a hard error.

4. **Missing nuance** — the answer doesn't mention that even with an index on the join column, the join still runs **inside Trino's workers**, not inside Postgres. Cross-catalog joins cannot be pushed down (only joins within the same catalog can). So the index helps Postgres serve the filtered/projected rows quickly, but the join itself is still Trino-side. The user might benefit from knowing this — it constrains how much an index can actually buy them.

### Beginner clarity: 4.5

**Strengths:**
- Opens with the bottom line ("PK itself almost certainly not causing slowness; index is what matters") — exactly the framing a frustrated engineer needs.
- The three-numbered list (predicate pushdown / dynamic filtering / join key index) gives a clear mental model.
- Concrete SQL examples (`SELECT indexname, indexdef FROM pg_indexes...`, `CREATE INDEX CONCURRENTLY ON...`) are copy-pasteable.
- "The bottom line" closing reinforces the core insight without repeating the body verbatim.

**Weaknesses:**
- "ScanFilterProject," "dynamicFilterSplitsProcessed," "dynamic filtering," "Seq Scan vs Index Scan," "predicate pushdown" appear without inline glosses. A pure beginner could read this and still not know what a "Filter node above a scan" means visually. A one-line "(this shows up as a separate `Filter[...] -> TableScan[...]` pair in your EXPLAIN output)" would have helped.
- The phrase "embedded inside the `ScanFilterProject` node" is itself jargon stacked on jargon — and as noted, the framing is also factually muddled, so it hurts both clarity and accuracy.

### Practical applicability: 5.0

**Strengths:**
- Three concrete diagnostic actions: (1) EXPLAIN to verify pushdown, (2) `pg_stat_activity` to see actual SQL + Seq Scan vs Index Scan, (3) `pg_indexes` query to check index presence.
- Fix is concrete and production-safe: `CREATE INDEX CONCURRENTLY` is the only acceptable index-creation pattern on a "heavier" log-style table during business hours. Recommending it (vs plain `CREATE INDEX`) shows awareness of the OLTP/availability constraint.
- Closing diagnostic ("pre-ingesting into Iceberg for repeated analytical use") matches the production stack — Spark + Iceberg + MinIO + Hive Metastore is exactly where the user should land if the federation latency proves chronic.

**Minor practical gaps (not enough to dock a point):**
- Doesn't mention `EXPLAIN ANALYZE` (vs plain `EXPLAIN`) — only `EXPLAIN ANALYZE` actually executes the query and shows real timing/row counts and dynamic-filter statistics. `EXPLAIN (TYPE DISTRIBUTED)` shows the plan but not runtime metrics, so the "check dynamicFilterSplitsProcessed" advice requires `EXPLAIN ANALYZE` not `EXPLAIN`.
- Doesn't mention checking the `pg_stat_user_tables` `seq_scan` vs `idx_scan` counters as a longer-term post-hoc indicator of whether the new index is being used.
- Doesn't mention partial indexes as an option for log-style tables where most queries hit recent data (`WHERE created_at > now() - interval '7 days'`).

### Completeness: 4.0

**Covered:**
- Direct answer to the user's question: PK absence not the root cause.
- Root cause hypothesis (index missing on join key) with verification path.
- Concrete fix.
- Escalation path (ingest into Iceberg if federation latency persists).

**Missing:**
- The factual correction on ScanFilterProject means the EXPLAIN-based diagnostic the user will try first is misaligned with what they'll see. That's a completeness hit.
- No mention that the join itself runs on Trino workers (cross-catalog join pushdown does not exist). User may still see slow joins even with the new index if the Postgres-side row count is large, because Trino must pull all matching rows over JDBC and join them in worker memory.
- No mention of how to estimate cost: if the log table is huge, a probe-side index lookup PER joined row from Iceberg may still be slow at scale. Some quick math (e.g., "if Iceberg side has 100K rows and the join issues 100K indexed lookups, expect ~30s on the Postgres side") would have helped scope expectations.
- No mention of statistics — running `ANALYZE your_log_table;` on the Postgres side after creating the index is what teaches Postgres to use it. Without fresh stats, the new index may not be picked by the PG planner.
- No mention of `CREATE INDEX CONCURRENTLY` failure mode (can fail and leave an INVALID index).
- No mention of OPA decision logs / event listener for the persistent diagnostic trail (recurring 5-iteration miss).

---

## Comparison to other recent answers on this topic

- **iter164 Q2** (similar diagnostic question, scored 3.40 FAIL) — described dynamic filtering somewhat incorrectly. This answer makes a similar (smaller) error around `dynamicFilterSplitsProcessed` direction. Both errors share a root cause: the resource file's dynamic-filtering section needs tightening.
- **iter167 Q2** (monitoring/EXPLAIN angle, 4.50 PASS) — got the EXPLAIN semantics right because it stayed at the conceptual level. This Q2 went deeper and tripped on the ScanFilterProject vs Filter distinction.
- **iter168 Q2** (timeout behavior, 4.50 PASS) — clean technical content. The pattern: when the answer stays in well-understood territory it gets 4.5+; when it ventures into specific EXPLAIN-node semantics that the resource doesn't fully document, it hits 4.0-4.3.

---

## Topic average update

Trino federation / cross-source connectors:
- Prior avg: 4.147 across 15 questions (after iter168 Q2)
- Iter 169 Q1: **2.40 (FAIL)** — the responder asserted "no documented hot-reload or dynamic credential provider mechanism in OSS Trino 467" which is wrong. Trino 467 supports Dynamic Catalog Management (`catalog.management=dynamic` + DROP CATALOG / CREATE CATALOG at runtime) and DROP "does not interrupt running queries." The Postgres dual-password framing was also wrong (mainline PG has no native dual-password; the real pattern is the dual-role approach). Graceful worker shutdown was missed entirely.
- Running avg after Q1: (4.147 × 15 + 2.40) / 16 = (62.205 + 2.40) / 16 = **4.038 across 16 questions**
- Iter 169 Q2: **4.30 (FAIL topic threshold, PASS general threshold)**
- New running avg: (4.038 × 16 + 4.30) / 17 = (64.608 + 4.30) / 17 = **4.053 across 17 questions**

Status: **NEEDS WORK** (4.053 < 4.5 raised threshold for this topic). Gap to threshold: 0.447. Both iter169 questions missed the topic threshold; the topic average ticked **down** from 4.147 → 4.053. Iter169 was a regression iteration on Trino federation — Q1's flagship-feature miss (Dynamic Catalog Management) cost ~0.07 on the topic average; Q2's 4.30 was insufficient to recover.

---

## Resource fix recommendations (HIGH priority for next iteration)

### HIGH (correctness) — `resources/22-trino-federation-postgresql.md`

**Add a "Predicate pushdown — how to verify with EXPLAIN" section** covering:
- The TableScan-vs-ScanFilterProject distinction with **annotated EXPLAIN output snippets** (so the responder doesn't have to reason from memory). Specifically:
  - **Successful pushdown** — EXPLAIN shows `TableScan[table = app_pg:public.users, constraint = (id = 42)]` (predicate appears inside the TableScan's constraint field). No ScanFilterProject above it.
  - **Failed pushdown** — EXPLAIN shows `ScanFilterProject[filterPredicate = (status = 'active')] -> TableScan[table = app_pg:public.users]` (filter applied in Trino after a full table scan).
- Worked example queries (one with pushdown succeeding on an indexed numeric column, one failing on a string range predicate) and their full EXPLAIN outputs.
- The recommendation to **always pair Trino EXPLAIN with Postgres-side verification via `pg_stat_activity`** — the JDBC SQL Trino sent is the ground truth.

### HIGH (correctness) — same file

**Tighten the dynamic-filtering section** to clarify direction:
- Dynamic filters flow FROM the build side (typically the smaller table, scanned first) INTO the probe side (typically the larger table). The metric `dynamicFilterSplitsProcessed` appears on the **probe-side TableScan operator** in EXPLAIN ANALYZE output, because that's the scan that consumed the dynamic filter.
- For the typical Iceberg-as-build / Postgres-as-probe join pattern, check `dynamicFilterSplitsProcessed` on the **Postgres** TableScan, NOT the Iceberg one.
- For the reverse direction (Postgres-as-build / Iceberg-as-probe), the metric appears on the Iceberg side.
- Note that JDBC-connector dynamic-filter support has matured across Trino releases but historically lagged the Hive/Iceberg connectors.

### HIGH (production fit — Postgres-side fix completeness) — same file or a new `resources/22b-postgres-side-tuning.md`

**Add a "Postgres-side index creation for federation joins" section** covering:
- The PK-vs-index distinction (PK auto-creates a B-tree index; the index is what enables Index Scan; absent PK doesn't matter as long as the join column has *some* index).
- `CREATE INDEX CONCURRENTLY` with the full lifecycle: cannot run in a transaction, can fail and leave INVALID indexes (check `pg_index.indisvalid`), takes ~2x as long as plain CREATE INDEX, but does not block writes.
- Partial indexes for log-style tables with hot-recent / cold-old access patterns.
- Post-creation: `ANALYZE table_name;` to refresh stats so the PG planner picks up the new index.
- `pg_stat_user_tables` `seq_scan` vs `idx_scan` counters as the post-hoc verification that the new index is being used.

### HIGH (production fit — recurring across 5 iterations) — same file

**OPA decision logs + Trino event listener as the persistent record of federation activity.** This is now the FIFTH consecutive iteration this gap has been flagged (iter165, iter166, iter167, iter168, now iter169). The teacher must address this in the next teaching cycle.

### MEDIUM (clarity) — same file

Inline-gloss the first appearance of: "ScanFilterProject," "TableScan," "dynamic filter," "build side," "probe side," "Seq Scan," "Index Scan."

### MEDIUM (completeness) — same file

A "cross-catalog joins always run in Trino workers, never in Postgres" callout. This frames why even an indexed Postgres side won't magically make a 10M-row join fast — the work happens in Trino, not Postgres, and dynamic filtering / row count caps are the real performance levers.

---

## Bottom line

A solid, honest answer with the right top-level diagnosis (it's not the PK, it's the index) and concrete, production-safe remediation (`CREATE INDEX CONCURRENTLY`). Held back from the topic threshold (4.5) by:
1. A factual misframing of the ScanFilterProject vs Filter EXPLAIN diagnostic.
2. Pointing the user at the wrong side of the join for `dynamicFilterSplitsProcessed`.
3. Missing nuance on join-execution location (Trino workers, not Postgres) and on `ANALYZE`-after-index for the PG planner to actually pick up the new index.

These are all resource-coverage problems, not responder-judgment problems. The responder correctly inferred the high-level architecture; the specific EXPLAIN-node semantics need to be documented in the resource file so the responder can quote them rather than reason from memory.
