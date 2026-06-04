# Judge Feedback — Iter 467 (Extended Phase, end-of-iteration)

## Verdict: STRONG PASS — overall avg 4.672

All four questions cleared the 3.5 threshold by a comfortable margin. Three of four landed STRONG PASS at 4.656+. **Critical milestone: the Oracle ADD_MONTHS end-of-month CLAMP streak is RESTORED** after iter466's thin 4.0 PASS gap was closed by the iter467 teacher reconciliation in r27 §4.2.

## Per-question breakdown

| Q | Topic angle | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Oracle ADD_MONTHS month-end re-probe | 4.875 | 4.75 | 4.625 | 4.75 | **4.75** | STRONG PASS |
| Q2 | dbt incremental on Iceberg + MoR position-deletes | 4.75 | 4.625 | 4.5 | 4.75 | **4.656** | STRONG PASS |
| Q3 | Partition explosion + sorted_by file-level pruning | 4.375 | 4.625 | 4.625 | 4.625 | **4.563** | PASS |
| Q4 | UPDATE on V2 + expire_snapshots safety | 4.875 | 4.625 | 4.625 | 4.75 | **4.719** | STRONG PASS |

Overall avg = (4.75 + 4.656 + 4.563 + 4.719) / 4 = **4.672**

## ADD_MONTHS streak status: RESTORED

The iter466 thin-PASS Q3 gap (clamp rule omission) is closed. iter467 Q1 explicitly:
- Flagged the clamp difference (Trino `date_add('month',...)` does NOT replicate Oracle's last-day-in→last-day-out).
- Gave the divergent example pair (Feb 28→Mar 31 Oracle vs Mar 28 Trino) AND the convergent overflow pair (Jan 31→Feb 28 both).
- Provided the canonical CASE wrapper using `last_day_of_month`.
- Did NOT make any naive-equivalence claim.

This is exactly what the iter467 teacher reconciliation in r27 §4.2 was designed to deliver. The LEADING CANONICAL block landed on FIRST re-probe.

## Carry-forward verification: dbt + partitioning fixes HELD

- **Q2 dbt-trino keys** (materialized, incremental_strategy, unique_key, on_schema_change, properties.partitioned_by, properties.format_version): all real per docs.getdbt.com/reference/resource-configs/trino-configs. The MoR position-delete remediation correctly attributed to Spark `rewrite_position_delete_files` (Trino has no equivalent EXECUTE form). Carry-forward fix held.
- **Q3 sorted_by partition design**: sorted_by is a real Trino Iceberg property; partition-explosion math (547 days × 10k = 5.5M) is correct; file-level min/max pruning rationale via lower_bounds/upper_bounds is correct per Iceberg spec. The ALTER + EXECUTE optimize hook addresses the "sorted_by alone doesn't rewrite existing files" caveat (trinodb/trino#26112). Carry-forward fix held.

## Fabrications / inaccuracies found

**ZERO fabrications across all four answers.** Every claim was WebSearch-verified against:
- docs.oracle.com (ADD_MONTHS clamp man) — Q1 clamp rule.
- trino.io/docs/current/functions/datetime.html — Q1 `last_day_of_month(x) -> date`, `date_add('month', n, ts)`, timestamp arithmetic.
- docs.getdbt.com/reference/resource-configs/trino-configs — Q2 dbt-trino incremental keys.
- iceberg.apache.org/docs/latest/spark-procedures — Q2 `rewrite_position_delete_files`.
- starburst.io / trino.io/docs/current/connector/iceberg.html — Q3 sorted_by + file-level pruning.
- iceberg.apache.org/spec — Q3 lower_bounds/upper_bounds tracking.
- trino.io/docs/current/connector/iceberg.html — Q4 UPDATE on V2 MoR + expire_snapshots + $snapshots columns + 7d-floor.

Mild caveat (NOT a fabrication, just a completeness note): Q3 could have more explicitly stated that `ALTER TABLE SET PROPERTIES sorted_by = ...` only governs FUTURE writes — existing files are not re-sorted until `EXECUTE optimize` rewrites them. The responder did chain optimize after the ALTER, so the actionable flow is correct, but the rationale could be tightened. Not a score-dragging issue.

## Teacher actions for iter468 (concrete, breadth design, no federation probe)

### NO new urgent reconciliations

All four Q1–Q4 topics PASS at 4.563+. No semantic gaps, no fabrications, no carry-forward breakages. Resource state is healthy.

### Breadth-design candidates (pick 4 non-overlapping, non-federation)

1. **dbt snapshots / SCD2** — angle: `strategy='check'` vs `strategy='timestamp'`, `check_cols`, `unique_key`, `updated_at`, `target_schema`, hard-deletes handling. (dbt-trino snapshots topic adjacent to Oracle migration / dbt-incremental but not yet a probed angle.)
2. **Trino MERGE INTO** — angle: `WHEN MATCHED`, `WHEN NOT MATCHED`, dynamic filtering on MERGE, position-delete generation on V2. **Watchlist: `WHEN NOT MATCHED BY SOURCE` is Spark/Snowflake/T-SQL; Trino 467 does NOT have it** — responder must not invent it.
3. **Iceberg branch/tag on Trino 467** — angle: `EXECUTE fast_forward`, `EXECUTE create_branch`, `EXECUTE drop_branch`, `EXECUTE create_tag`, `FOR VERSION AS OF` / `FOR TIMESTAMP AS OF` time-travel. **Watchlist: confirm exact procedure names in Trino 467 — Spark uses different names (`CALL ... .system.create_branch`); cross-engine spillover risk.**
4. **Query governor / timeout settings** — angle: `query.max-run-time` (wall-clock) vs `query.max-execution-time` (excluding queuing) vs `query.max-cpu-time`, per-session SET SESSION overrides, OPA gating. **Watchlist: do NOT invent `query.max-elapsed-time` or `query.timeout` — they don't exist; cite real keys only.**

### NO dedicated federation probe

Federation row sits at 4.49944/310 — only 0.0006 below the raised 4.5 threshold. A thin probe in either direction locks or breaks the row. Keep federation OUT of iter468 unless explicitly directed. Status remains FAIL (just below threshold) but is not the priority gap.

### Citation-hygiene watchlist for iter468

Carry forward iter467's clean slate. Specific fab-classes to watch:

- **Cross-dialect spillover**: Trino MERGE has NO `WHEN NOT MATCHED BY SOURCE`. Trino has NO Oracle/MySQL bare `LAST_DAY` (use `last_day_of_month`). Trino has NO `MONTHS_BETWEEN` (use `date_diff('month', ...)`).
- **Version-pin spillover**: any Iceberg branch/tag procedure must be verified against Trino 467 (not 470+, not Spark). Confirm exact EXECUTE form vs CALL form per engine.
- **Fabricated dbt snapshot keys**: only `strategy`, `unique_key`, `check_cols`, `updated_at`, `target_schema`, `target_database`, `invalidate_hard_deletes`, `hard_deletes`, `dbt_valid_from`, `dbt_valid_to` are real. Watch for invented snapshot config.
- **Fabricated Trino governor config keys**: real are `query.max-run-time`, `query.max-execution-time`, `query.max-cpu-time`, `query.max-memory`, `query.max-memory-per-node`. Watch for invented `query.timeout`, `query.max-wall-time`, etc.
- **Fabricated capability restrictions**: do NOT claim Trino "cannot do MERGE on Iceberg" — it can on V2. Do NOT claim Iceberg branches "require Spark only" — Trino 467 supports them via EXECUTE procedures.

### Resource state summary

- r27 (Oracle PL/SQL→dbt/Trino migration): healthy at 4.5792/41. ADD_MONTHS canonical landed.
- r17 (Iceberg table maintenance): healthy at 4.4907/129. UPDATE+expire_snapshots clean.
- r09/r10 (partition design): healthy at 4.4995/33. sorted_by canonical clean.
- r22 (federation): UNCHANGED at 4.49944/310. Do not probe.
- dbt-trino incremental resources: healthy. All config keys real per latest re-verification.

## Bottom line

iter467 is a clean breadth pass with the primary iter466 reconciliation goal achieved. No new resource gaps surfaced. Recommended approach for iter468: continue breadth-design rotation on non-federation angles with the watchlist above. The system is in a stable extended-phase plateau.
