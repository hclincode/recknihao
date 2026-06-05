# Iter 480 Judge Feedback (EXTENDED PHASE — end-of-iteration)

## Overall verdict

**4.6953 / 4 — STRONG PASS.** 79th consecutive overall PASS in extended phase. Matches iter475's 4.6953 high-water mark and represents the second-strongest extended-phase score in the last 10 iters (+0.086 above iter479's 4.6094).

**Streak status:**
- **fabricated-session-property streak — CLOSED for 2 consecutive iters.** Iter478 (`task_max_memory` + `memory_revoking_enabled`) and iter479 (`spill_order_by_enabled`) fabs are all fully closed. Q1 this iter used `query_max_memory_per_node` correctly as DOWNWARD-only session-settable with the underscore-vs-dot syntax warning. The iter479 r18 LEADING CANONICAL memory/spill card edit was decisive.
- **citation-hygiene streak — RESTORED.** ZERO load-bearing fabs across Q1–Q4.
- **cross-dialect-spillover / version-pin / fabricated-capability-restriction streaks — ALL HOLD.**

Federation NOT probed; 4.49944/310 near-miss row UNCHANGED per multi-iter judge directive.

## Per-question breakdown

### Q1 — memory/spill 3rd RE-PROBE (LOWER-per-query angle) — 4.6875 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | `query_max_memory_per_node` confirmed REAL Trino session property, session-settable DOWNWARD-only. Verified at trino.io/docs/current/release/release-318.html via WebFetch: "These properties can be used to decrease limits for a query, but not to increase them." Underscore-vs-dot syntax warning correct (`query.max-memory-per-node` config form fails as session-property name). `SHOW SESSION LIKE` recipe correct. `RESET SESSION` correct. |
| Completeness | 4.75 | Covered BEFORE-the-heavy-query SET SESSION pattern + cluster-default-already-below-4GB caveat (showing downward-only mastery) + verification recipe + clear command. Did not cite Release 318 as introducing release — non-load-bearing nit. |
| Clarity | 4.5 | Concrete "4GB throttle" example, plain-language downward-only explanation. |
| Actionability | 4.75 | Engineer can copy-paste the SET SESSION + SHOW SESSION + RESET sequence directly. |

**CRITICAL — ZERO fabricated session properties:** no `task_max_memory`, no `memory_revoking_enabled`, no `spill_order_by_enabled`, no `spill_aggregations_enabled`, no `spill_joins_enabled`, no `spill_window_enabled`, no per-operator spill toggles. The iter479 r18 LEADING CANONICAL memory/spill card edit (10 surgical reconciliations + 5 new DO-NOT-WRITE rows + dual-axis CEILING-vs-DOWNWARD-OVERRIDE corrections in 3 task_* rows + bottom-line single-rule statement + 2 new probe rows in verify recipe) LANDED CLEAN. **3rd consecutive memory/spill re-probe with the fab class closed.**

### Q2 — split fact/dimension vs flat table — 4.75 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | Split-when-criteria (columns change infrequently + queried separately + small/reusable across fact tables) is standard Kimball dimensional modeling. Denormalize-hot-columns-INTO-fact-table (plan_type, country) accurate for Trino/Iceberg where JOINs are expensive vs scan-and-aggregate. Start-with-2-3-facts-plus-1-2-dims pragmatic. |
| Completeness | 4.75 | Both branches covered (when to split, when to denormalize); pragmatic starting point given. |
| Clarity | 4.75 | No unexplained jargon; concrete column-name examples (plan_type, country). |
| Actionability | 4.75 | Engineer knows how to make the call for their next table design. |

**ZERO fabs.** Standard dimensional-modeling guidance.

### Q3 — Iceberg $manifests / $partitions metadata tables — 4.75 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | `$snapshots` / `$manifests` / `$files` / `$partitions` all confirmed REAL per trino.io/docs/current/connector/iceberg.html (WebFetch verified). `$partitions` columns (partition ROW, record_count BIGINT, file_count BIGINT, total_size BIGINT) correct. Metadata-reads-KB-not-GB-of-data performance claim correct. **bucket-transform partition.tenant_id_bucket naming CORRECT** — Iceberg default-names bucket partition fields `<col>_bucket` (int, holding bucket number not original value) unless overridden with `AS <name>` per iceberg.apache.org/docs/latest/spark-ddl/. DESCRIBE-first defensive pattern is the right reflex. |
| Completeness | 4.75 | All 4 metadata tables named + per-tenant storage report SQL + bucket-transform gotcha + DESCRIBE recipe. Did not mention `$history` or `$properties` — non-load-bearing. |
| Clarity | 4.75 | Concrete "KB of manifests not GB of data" performance framing; the gotcha is exactly the kind of trap a beginner would hit. |
| Actionability | 4.75 | Copy-pasteable SELECT + DESCRIBE recipe with explicit double-quoting reminder. |

**ZERO fabs.**

### Q4 — Oracle BULK COLLECT/FOR loop → dbt/Trino set-based — 4.625 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | Procedural→declarative framing correct; cursor-loop→SELECT+JOIN/GROUP BY correct; BULK COLLECT+FORALL→single INSERT...SELECT or MERGE correct; Oracle MERGE→dbt incremental_strategy='merge'+unique_key correct per docs.getdbt.com/reference/resource-configs/trino-configs (verified via WebSearch). `is_incremental()` guard with COALESCE(MAX(event_date), DATE '1970-01-01') watermark canonical. `CAST(occurred_at AS DATE)` valid Trino. no-loop / no-COMMIT framing correct. **Minor non-load-bearing nit**: composite unique_key list `['tenant_id','event_date']` is correct dbt syntax, BUT dbt-trino has a known issue (#465 starburstdata/dbt-trino) where older adapter versions may treat composite keys as separate — not a fab, just a known adapter quirk the answer did not flag. |
| Completeness | 4.5 | Full worked rewrite (config block + incremental guard + watermark + GROUP BY + composite key). Did not flag the dbt-trino composite-key adapter quirk. |
| Clarity | 4.75 | Concrete tenant-daily-summary example end-to-end. |
| Actionability | 4.75 | Engineer has a working template they can adapt to their own table. |

**ZERO load-bearing fabs.**

## Fabrications found

**NONE this iter** across all 4 questions.

The 3 fab classes from iter474 / iter478 / iter479 (`distributed_join_distribution_type`, `task_max_memory`+`memory_revoking_enabled`, `spill_order_by_enabled`) are ALL CLOSED for 2 consecutive iters. The iter479 r18 LEADING CANONICAL memory/spill card edit was the decisive fix — it banned the entire sibling-name-extrapolation fab class via the DO-NOT-WRITE matrix and corrected the dual-axis CEILING-vs-DOWNWARD-OVERRIDE distinction in the 3 task_* rows.

## Topic score updates

| Topic | Before | After | Delta | Note |
|---|---|---|---|---|
| Query performance basics (Q1 memory/spill) | 4.2941 / 17 | **4.3164 / 18** | +0.0223 | Q1 4.6875 above topic avg; recovery continues from iter478's drag |
| Lakehouse schema design (Q2 split-fact-vs-flat) | 4.5240 / 13 | **4.5401 / 14** | +0.0161 | Q2 4.75 above topic avg |
| Iceberg table maintenance (Q3 $partitions/$manifests metadata) | 4.4936 / 135 | **4.4954 / 136** | +0.0019 | Q3 4.75 above topic avg |
| Oracle PL/SQL→dbt/Trino migration (Q4) | 4.5318 / 54 | **4.5349 / 55** | +0.0031 | Q4 4.625 above topic avg |
| Trino federation (NOT probed) | 4.49944 / 310 | 4.49944 / 310 | 0 | Row held per multi-iter directive |

## Teacher actions for iter481

**Phase**: extended (no `final_iterations_remaining` decrement; iter480 at 79 consecutive PASSes).

**Federation guidance**: **NO dedicated federation probe.** Hold 4.49944/310 per the iter472-480 multi-iter directive — let count grow naturally via non-federation breadth probes only.

**PRIMARY action — breadth design (4-Q non-federation)**:

Memory/spill topic now has 3 consecutive PASS re-probes (iter478 HARD FAIL → iter479 THIN PASS → iter480 STRONG PASS) and the fab class is closed. Direction options:

1. **Memory/spill 4th angle (optional hardening)** — different question shape: resource-group-level memory limit (`etc/resource-groups.json` + `softMemoryLimit` / `hardConcurrencyLimit` / `schedulingPolicy`) vs session-level. Would harden the 3-consecutive-PASS lock and probe a non-session-property memory lever.

2. **Low-count topic breadth probes** — these topics are still at low datapoint counts:
   - dbt sources / source freshness 4.219 / 3 (loaded_at_field, warn_after / error_after, blocking semantics)
   - dbt model contracts 4.1146 / 3 (config.contract.enforced, build-time preflight)
   - Storage tiering 4.25 / 2 (no built-in per-partition tier DDL; MinIO lifecycle workarounds)
   - dbt snapshots SCD2 4.5625 / 2 (dbt_valid_from/to, NO dbt_is_current, validity-window pattern)
   Pick 1-2 to add resilience and remove single-/double-point-fragility.

3. **Iceberg metadata-table 2nd angle** — Q3 this iter probed `$partitions` for per-tenant storage. A 2nd angle could probe `$history` (parent_snapshot_id rollback chain) or `$properties` (table-level write.format.default / write.parquet.compression-codec) to broaden iceberg-metadata-tables surface area.

4. **Oracle-migration breadth** — topic at 55 datapoints / 4.5349 avg. Probe a construct not yet tested:
   - Oracle `CONNECT BY PRIOR` hierarchical → Trino recursive CTE `WITH RECURSIVE`
   - Oracle PIPELINED table functions → dbt model + UNNEST pattern
   - Oracle SAVEPOINT / ROLLBACK TO inside PL/SQL → dbt's transactional behavior (no SAVEPOINT in dbt-trino; each materialization is atomic via Iceberg snapshot)

**SECONDARY action — no resource edits required.** ZERO fabs this iter means no DO-NOT-WRITE matrix updates, no reconciliation edits, no canonical-form corrections needed. Resources are in a clean state.

**Suggested iter481 question set**:
- Q1: dbt sources freshness loaded_at_field + warn_after / error_after blocking semantics (4th-angle re-probe of low-count topic)
- Q2: Iceberg $history rollback chain or $properties table-level configuration (metadata-table breadth)
- Q3: Oracle CONNECT BY PRIOR → Trino WITH RECURSIVE (Oracle-migration breadth)
- Q4: Resource-group memory limits vs session-level (memory/spill 4th angle, optional)

**Do NOT probe federation.** Hold the 4.49944/310 row per directive.
