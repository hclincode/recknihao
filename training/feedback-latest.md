# Iter 478 Judge Feedback — Extended phase, end-of-iteration

**Overall: 4.0625 PASS** (avg of 4.5 / 5.0 / 1.75 / 5.0 across Q1–Q4). 77th consecutive overall PASS in extended phase, BUT softest in many iters — Q3 is a HARD FAIL (1.75) with TWO fabricated session-property names. The high Q2 + Q4 scores (both 5.0) and a clean Q1 (4.5) saved the iteration. Federation NOT probed this iter (4.49944/310 row stays held per iter472-477 directive).

---

## Per-question breakdown

### Q1 — Spark writeTo vs saveAsTable / createOrReplace (4.5 STRONG PASS)
- **Accuracy 5.0**: All three API claims verified against iceberg.apache.org/docs/latest/spark-writes/. `df.writeTo("iceberg.analytics.events").append()` is the canonical DataFrameWriterV2 API. v1 `saveAsTable` with `format("iceberg")` "loads an isolated table reference that will not automatically refresh tables used by queries" — the catalog-routing caveat is real. `createOrReplace()` drops + recreates (erases snapshot history) — correct.
- **Completeness 4.0**: Three APIs + semantics covered. Could mention Hive Metastore catalog routing on the production stack.
- **Clarity 4.0**: Legacy-vs-v2 framing is clear.
- **Actionability 5.0**: Exact API + code snippet copy-paste runnable.
- **Fabs**: None.

### Q2 — Iceberg partition transforms + bucket arg order (5.0 STRONG PASS)
- **Accuracy 5.0**: The Trino `bucket(column, N)` (column FIRST) vs Spark `bucket(N, column)` (count FIRST) cross-engine distinction is the known real difference, verified at:
  - trino.io/docs/current/connector/iceberg.html — `partitioning = ARRAY['city', 'bucket(userid, 16)']` (column-first)
  - iceberg.apache.org/docs/latest/spark-ddl/ — `PARTITIONED BY (bucket(16, id), days(ts), category)` (count-first)
  - day()/month()/truncate(col,N) transforms all valid in Trino.
- **Completeness 5.0**: Decision tree (day for time-range, bucket for high-cardinality IDs, truncate for coarse buckets) + arg-order table + worked CREATE TABLE with `partitioning = ARRAY['day(occurred_at)','bucket(tenant_id, 64)']`.
- **Clarity 5.0**: Decision-tree format excellent for beginners.
- **Actionability 5.0**: Engineer can copy-paste the DDL.
- **Fabs**: None.

### Q3 — Trino memory limit / spill / resource groups (1.75 HARD FAIL — TWO FABS)
- **Accuracy 1.0**: Of the three "knobs" in the responder's table:
  - **`query_max_memory` — REAL session property** (per trino.io/docs/current/admin/properties-memory-management.html; "this session property cannot increase the limit above the limit set by the query.max-memory configuration option"). VERIFIED.
  - **`task_max_memory` — FABRICATED**. No such Trino session property exists. Per-node task memory is the CONFIG property `query.max-memory-per-node` (set in `config.properties` at cluster start, NOT session-settable). There is an experimental `task.max-memory-per-task` config but no session counterpart. Engineer copy-pasting `SET SESSION task_max_memory='4GB'` gets `Session property task_max_memory does not exist`.
  - **`memory_revoking_enabled` — FABRICATED, AND the functional claim is wrong**. There is no such Trino session property. The claim that it "enables spill-to-disk for GROUP BY" is incorrect: the correct lever is `SET SESSION spill_enabled = true` (config `spill-enabled`), per trino.io/docs/current/admin/properties-spilling.html. The terms `memory-revoking-threshold` and `memory-revoking-target` are CONFIG (not session) properties that control WHEN spill triggers (e.g., when JVM heap exceeds 90%, revoke memory until it drops to 70%) — NOT a knob to enable/disable spill. Engineer copy-pasting `SET SESSION memory_revoking_enabled=true` gets `Session property memory_revoking_enabled does not exist` AND has no spill behavior because `spill_enabled` was never set.
  - The resource-groups-cluster-level claim is CORRECT (resource groups in `etc/resource-groups.properties` are cluster-level, not query-level).
- **Completeness 2.0**: Covers three knobs but two are invented. Missing: `query_max_total_memory` (real session property — user+system limit), `spill_enabled` (the actually correct spill-enable lever), the config-only nature of per-node limits, the resource-groups soft-vs-hard memory limit framing.
- **Clarity 3.0**: Table format is clear and skimmable — but clarity of confidently-wrong facts is anti-helpful (responder writes the wrong fact crisply, which makes the engineer trust it).
- **Actionability 1.0**: 2 of 3 copy-paste examples FAIL with "Session property does not exist" parse errors. Engineer trying to fix an OOM will run these, see the error, and lose trust. No actionable correct guidance for spill-to-disk.
- **Fabs**:
  - **FAB 1**: `task_max_memory` — fabricated session-property name. Correct lever: per-node memory is config-only `query.max-memory-per-node` (cluster-level, in `config.properties`, requires restart). Source: trino.io/docs/current/admin/properties-memory-management.html.
  - **FAB 2**: `memory_revoking_enabled` — fabricated session-property name. Correct lever to enable spill-to-disk: `SET SESSION spill_enabled = true` (or cluster-level `spill-enabled=true` in `config.properties`). `memory-revoking-threshold` / `memory-revoking-target` are config-only knobs that tune WHEN spill triggers, not WHETHER it is enabled. Source: trino.io/docs/current/admin/properties-spilling.html + trino.io/docs/current/admin/spill.html.
- **Fab class**: Same as iter474 (`distributed_join_distribution_type`) — fabricated-session-property-name via sibling-name extrapolation. The responder reaches for a plausible-sounding name (`task_max_memory` looks like a sibling of `query_max_memory`; `memory_revoking_enabled` looks like a sibling of `spill_enabled`) and presents it as real.

### Q4 — dbt-trino incremental_strategy (5.0 STRONG PASS)
- **Accuracy 5.0**: All three strategies real per docs.getdbt.com/reference/resource-configs/trino-configs:
  - `append` — default, insert-only, no `unique_key` needed, NOT idempotent on re-run.
  - `delete+insert` — two-phase, idempotent, no MERGE required.
  - `merge` — constructs Trino MERGE, requires `unique_key`, idempotent.
  - `partitioned_by`, `is_incremental()` guard, COALESCE(MAX) watermark, 3-day lookback variant — all valid.
- **Completeness 5.0**: Strategy comparison table + canonical merge model + watermark + lookback variant.
- **Clarity 5.0**: Decision-tree-friendly table.
- **Actionability 5.0**: Canonical model template ready to copy-paste.
- **Fabs**: None.

---

## Topic averages updated

- **Iceberg partition design** 4.4995/33 → 4.5147/34 (Q2 5.0 above topic avg, +0.0152).
- **Query performance basics** 4.4598/14 → 4.2791/15 (Q3 1.75 HARD FAIL drag, -0.1807 — biggest single-iter topic drag in extended-phase streak; topic still PASSED at 4.2791 above 3.5 but margin tightened by ~0.18).
- **Oracle PL/SQL→dbt/Trino migration** 4.5230/53 → 4.5318/54 (Q4 5.0 above topic avg, +0.0088 — dbt-trino incremental_strategy probe maps here via "incremental/materialization strategy choice").
- **Postgres-to-Iceberg ingestion** 4.5/159 → 4.5/160 (Q1 at topic avg, no change).
- **Federation** 4.49944/310 — UNCHANGED, NOT probed this iter, held per iter472-477 directive.

---

## Teacher actions for iter479

### PRIMARY: Fix Q3 fabricated session-property names (memory + spill)

This is the SAME fab class as iter474 (`distributed_join_distribution_type` → `join_distribution_type`). The fix pattern is identical: explicit DO-NOT-WRITE rows + canonical-form card + sibling-name fab variant list.

Find or create a "Trino memory/spill tuning" leading-canonical block (likely in r24 or wherever Trino tuning lives — grep for `query.max-memory-per-node` and `spill_enabled` to locate). Add:

1. **DO-NOT-WRITE table** banning these fabricated session-property names with the correct alternative:

   | Fabricated (do NOT write) | Correct lever | Reason |
   |---|---|---|
   | `SET SESSION task_max_memory='4GB'` | Per-node memory is CONFIG-only: `query.max-memory-per-node=4GB` in `config.properties` at cluster start (requires Trino restart). Not session-settable. | No such session property exists. |
   | `SET SESSION memory_revoking_enabled=true` | `SET SESSION spill_enabled = true` (or cluster config `spill-enabled=true`) | Spill-to-disk is gated on `spill_enabled` session property; `memory_revoking_*` are CONFIG-only knobs (`memory-revoking-threshold`, `memory-revoking-target`) that control WHEN spill triggers after spill is enabled, not WHETHER it is enabled. |
   | `SET SESSION distributed_join_distribution_type='PARTITIONED'` (iter474 regression — keep in matrix) | `SET SESSION join_distribution_type = 'PARTITIONED'` | No `distributed_` prefix in Trino session-property name. |

2. **Canonical-form card** with the FULL set of real Trino memory/spill session properties + their config-property counterparts:

   - **Session properties (per-query, SET SESSION):**
     - `query_max_memory` — cluster-wide user-memory cap for this query (cannot exceed config `query.max-memory`).
     - `query_max_total_memory` — cluster-wide user+system memory cap for this query.
     - `spill_enabled` — enable spill-to-disk for this query (default false unless config `spill-enabled=true`).
   - **Config properties (cluster-wide, config.properties, restart required):**
     - `query.max-memory-per-node` — per-worker user-memory cap (NOT session-settable).
     - `query.max-memory` — cluster-wide user-memory cap.
     - `query.max-total-memory` — cluster-wide user+system memory cap.
     - `spill-enabled` — default for spill across all queries.
     - `memory-revoking-threshold` — heap fraction at which memory revocation triggers (default ~0.9).
     - `memory-revoking-target` — heap fraction to drop to during revocation (default ~0.7).
     - `spiller-spill-path` — local disk path(s) for spill files.

3. **Sources to cite inline:**
   - trino.io/docs/current/admin/properties-memory-management.html
   - trino.io/docs/current/admin/properties-spilling.html
   - trino.io/docs/current/admin/spill.html

4. **Sibling-name fab variant list to ban explicitly** (pre-empt future regressions in this fab class):
   - `task_max_memory`, `task.max-memory`, `task_memory_limit`, `query_max_memory_per_node` (the per-node knob is config-only, not session).
   - `memory_revoking_enabled`, `memory_revoke_enabled`, `spill_to_disk_enabled`, `enable_spill`.
   - `distributed_join_distribution_type`, `broadcast_join_distribution_type` (kept from iter474).

5. **Reconcile, do not append**: if the existing resource has stale memory/spill content showing any of these fabricated names, fix in place — do not append a new section. Responder may cite the wrong one if both exist.

### SECONDARY: breadth design 4-Q for iter479

- Continue NO dedicated federation probe (4.49944/310 held).
- Consider a Q3-style re-probe in iter479 or iter480 to confirm the memory/spill fab fixes landed (different phrasing than iter478 Q3 — e.g., "how do I prevent a single query from consuming all cluster memory" or "my GROUP BY OOMs on the coordinator, what session properties should I set"). Confirm both `task_max_memory` and `memory_revoking_enabled` get explicitly rejected by the responder.
- Other topic-row health: Query-performance-basics dropped -0.18 to 4.2791 — still PASSED but the margin is now thinner than most extended-phase passes; another fab here would put it close to threshold. Watch for additional Trino-tuning fabs.

### Fab-class hygiene reminders (carry forward)

- **fabricated-session-property-name** class: iter474 + iter478 both hit this. Pattern is sibling-name extrapolation (`distributed_` prefix; `task_` instead of `query_`; `memory_revoking_enabled` instead of `spill_enabled`). Every session-property recommendation in resources MUST be docs-anchored — if not in trino.io/docs/current/admin/properties-*.html, do not write it.
- **cross-dialect-spillover**: held this iter (Spark vs Trino bucket arg-order was correctly distinguished in Q2 — that is a WIN, the responder did not conflate them).
- **version-pin**: held (no 468+/Iceberg-v3 features cited).

---

## Verdict

**4.0625 PASS** — but the Q3 fab pair is the kind of regression-class issue that should not slip twice. Iter474 closed `distributed_join_distribution_type`; iter478 opened TWO more in the same class. Iter479 PRIMARY action is the memory/spill DO-NOT-WRITE matrix + canonical-form card, then optional re-probe in iter480 to verify it landed.
