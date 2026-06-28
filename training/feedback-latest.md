# Iter 1208 — 4.30 PASS, two real responder slips (Q3 selector-direction backwards, Q2 boundary-label off-by-one), NO FIX-A

## Overall verdict
PASS. Average 4.297 across 4 questions. Two real defects flagged but BOTH are recall-ceiling responder slips not resource-sourced (no FIX-A recommended). Q1 + Q4 clean within scoring tolerance; Q2 has a real boundary-label off-by-one (responder's `ARRAY[30,90,180,365]` semantics correct but mismatches the question's literal labels — engineer-noticeable); Q3 has a real impact-analysis selector-direction slip (`+model:fct_daily_usage` returns ANCESTORS, but exposures live DOWNSTREAM, so the engineer gets zero results).

## Per-question scoring

### Q1 — Iceberg metadata files (v{N}.metadata.json + .avro) on MinIO: what they do, why not directory listing
- **Acc 5.0 / Clar 4.5 / App 4.5 / Compl 4.5 → 4.625 PASS**
- **Pin-perfect Iceberg metadata-tree canonical**. Five load-bearing facts all correct + verified:
  - (1) **`v{N}.metadata.json` = snapshot-root files** (point-in-time table state: schema, partition spec, snapshot log, current-snapshot pointer); current snapshot is "active", older retained for time-travel/rollback. VERIFIED at [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) hierarchy: Metadata File → Snapshot → Manifest List → Manifest → Data Files. Also see [Dremio: A Hands-On Look at the Structure of an Apache Iceberg Table](https://www.dremio.com/blog/a-hands-on-look-at-the-structure-of-an-apache-iceberg-table/).
  - (2) **`.avro` = manifest files** listing Parquet data files + per-file column min/max stats; manifests are grouped into a **manifest list** referenced from `metadata.json`. VERIFIED verbatim "A manifest is an immutable Avro file that lists data files or delete files, along with each file's partition data tuple, metrics, and tracking information" + manifest-list "lists manifest files; one per snapshot."
  - (3) **Atomic commit via compare-and-swap on metadata pointer in HMS**: new write → new Parquet → new manifest → new metadata.json → CAS update of HMS pointer to new metadata.json path. Single-row metastore update is the atomic boundary. VERIFIED verbatim "All changes to an Iceberg table are committed in a single, atomic operation ... by updating the catalog's pointer from the old metadata.json file to the new one. This is a 'compare-and-swap' (CAS) operation."
  - (4) **Hive directory-listing contrast**: Hive tracks partitions as metastore rows per directory; planner must list dirs to find files; scales poorly when partitions grow into millions. Iceberg planner reads metadata.json → manifest list → manifests to get file paths directly; NO directory listing required.
  - (5) **Never hand-delete**: chain of references (HMS → metadata.json → manifest list → manifest → data file) means orphaning any link breaks time-travel/rollback for that snapshot. Correct cleanup tool is `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` + orphan-file cleanup procedure.
- **Mild completeness shave (-0.5 Compl, -0.5 App)**: did not explicitly name the Trino-side `expire_snapshots` + `remove_orphan_files` procedures as the SANCTIONED way to drop old metadata; engineer asks "what should I do if old files accumulate" and the answer is left implicit ("Iceberg manages it" / "snapshot maintenance"). Minor — not load-bearing.
- **Engineer mental model lands**: metadata-first planning, atomic CAS commit, never hand-delete = three correct takeaways from the coworker's warning.
- Cites r17/r21 conceptual coverage (Iceberg metadata layout canonicals).

### Q2 — Account-age histogram 0-30 / 31-90 / 91-180 / 181-365 / 365+: width_bucket for uneven bins
- **Acc 4.25 / Clar 4.5 / App 4.0 / Compl 4.5 → 4.3125 PASS**
- **`width_bucket` correctly named + array form correctly used.** VERIFIED at [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) both overloads exist:
  - `width_bucket(x, bound1, bound2, n)` — equi-width
  - `width_bucket(x, bins)` — array form for uneven bins (the right tool for this question)
- **Array-form semantics correct**: 0-based; returns 0 if `x < bins[0]`, `i` for `bins[i-1] <= x < bins[i]`, `n` if `x >= bins[n-1]`. For `ARRAY[30, 90, 180, 365]` (n=4) you get 5 buckets (0..4). Confirmed via [Trino source `WidthBucketArrayFunction.java`](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/operator/scalar/WidthBucketArrayFunction.java) lower-bound-inclusive convention.
- **BOUNDARY-LABEL OFF-BY-ONE (real defect, -0.75 Acc, -0.5 App)**: with `ARRAY[30, 90, 180, 365]` and `[a, b)` half-open semantics:
  - bucket 0 = `x < 30` → days 0..29 (label says "0-30" → MISSING day 30)
  - bucket 1 = `30 <= x < 90` → days 30..89 (label says "31-90" → day 30 wrongly in here)
  - bucket 2 = `90 <= x < 180` → days 90..179 (label says "91-180" → day 90 wrongly in here)
  - bucket 3 = `180 <= x < 365` → days 180..364 (label says "181-365" → day 180 wrongly in here)
  - bucket 4 = `x >= 365` → 365+ (label OK, but day 365 here not in "181-365")
- To exactly match the engineer's literal labels (where day 30 should be in "0-30"), boundaries should be `ARRAY[31, 91, 181, 366]`. Engineer pasting the query will get histogram counts shifted by 1 day at each cutoff. Real bug, not a label nuance — affects every per-bucket COUNT slightly. Engineer-recoverable on careful review but easy to ship un-noticed.
- **NO FIX-A**: width_bucket boundary semantics ARE correctly explained in resources (lower-bound-inclusive convention named); responder over-quickly matched bin literal `30` to the label `0-30` without adjusting for half-open semantics. Recall-ceiling. Per `feedback_responder_overwarning_folklore.md` adjacent family — peripheral slip on a correct primary answer.
- Cites r07/r23 width_bucket canonicals.

### Q3 — dbt model rename silently breaks 3 Metabase dashboards: declare dashboard consumers inside dbt for lineage + impact warning
- **Acc 3.5 / Clar 4.5 / App 3.5 / Compl 4.5 → 4.0 PASS**
- **dbt EXPOSURES correctly named as the native (no-plugin) mechanism.** VERIFIED at [docs.getdbt.com/docs/build/exposures](https://docs.getdbt.com/docs/build/exposures): exposures YAML supports `name`, `label`, `type` (dashboard/notebook/analysis/ml/application), `owner` (name/email), `url`, `description`, `depends_on` with `ref()`/`source()`/`metric()`; exposures are metadata-only (`dbt run` does NOT execute them); they surface in `dbt docs generate` lineage with downstream-consumer marker; integrated into `manifest.json`. Responder's YAML schema mirrors the docs example accurately.
- **IMPACT-ANALYSIS SELECTOR DIRECTION IS BACKWARDS (real defect, -1.5 Acc, -1.5 App)**: responder wrote
  > `dbt ls --select +model:fct_daily_usage --resource-type exposure`
- per dbt graph operator semantics ([docs.getdbt.com/reference/node-selection/graph-operators](https://docs.getdbt.com/reference/node-selection/graph-operators)): **`+model_name` selects model AND its ANCESTORS (upstream parents); `model_name+` selects model AND its DESCENDANTS (downstream children).** Exposures DEPEND ON models (exposure → ref(model)), so exposures live DOWNSTREAM of the model. To find exposures consuming `fct_daily_usage`, the correct selector is **`fct_daily_usage+ --resource-type exposure`** (plus on the RIGHT). The responder's `+model:fct_daily_usage` returns ANCESTORS of the model — staging models, sources — which are NEVER exposures by definition. Engineer pastes the command, sees an empty list, may falsely conclude "no dashboards depend on this model" and proceed with the rename → repeats the original problem. This is the bug the engineer asked to PREVENT.
- **The CI selector `+exposure:daily_usage_dashboard` IS CORRECT** — that one wants the exposure AND its ANCESTORS (upstream models that need rebuilding to refresh the dashboard). Plus-on-left is right when the exposure is the anchor.
- **NO FIX-A**: dbt selector-direction is a recall-ceiling slip (correct concept, wrong side of the operator). Resources teach the directional convention; responder mis-applied to a specific impact-analysis case. Per `feedback_responder_broken_secondary_alternative.md` — primary answer (use exposures) is correct, secondary tooling example is broken. Re-probe under "dbt selector direction / impact analysis of a model on its dashboards" framing in 4-8 iters; if recurs, light additive card pinning the directional mnemonic ("plus is the direction you want to GROW the selection").
- Cites general dbt exposures coverage (r27/dbt fundamentals).

### Q4 — Oracle MONTHS_BETWEEN(SYSDATE, subscription_start_date) → Trino 467 replication
- **Acc 4.0 / Clar 4.5 / App 4.0 / Compl 4.5 → 4.25 PASS**
- **Correct on the primary mapping**: no MONTHS_BETWEEN in Trino 467 (VERIFIED — not in [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html)). Integer complete months via `date_diff('month', subscription_start_date, current_timestamp)` — VERIFIED Trino's `date_diff` returns COMPLETE/day-aware month diff (drops fractional, per pinned `reference_trino_datediff_dayaware.md`).
- **45-day example**: Oracle MONTHS_BETWEEN ~1.48, Trino `date_diff('month', ...)` = 1 (complete only). Numerically reasonable for the question's spec.
- **APPROXIMATION CALLED OUT, NOT EXACT MATCH (-1.0 Acc on fractional reconstruction)**: responder recommended `date_diff('day', start, current) / 31.0` for fractional months. This is an APPROXIMATION not exact match of Oracle's formula:
  - Oracle MONTHS_BETWEEN = `whole_months + (day_of_month(d1) - day_of_month(d2)) / 31` — the `/31` applies only to the **day-component delta**, not total days.
  - Oracle returns INTEGER when `day_of_month(d1) == day_of_month(d2)` OR both are last-day-of-month. VERIFIED at [docs.oracle.com MONTHS_BETWEEN](https://docs.oracle.com/cd/B13789_01/server.101/b10759/functions083.htm).
  - Example divergence: 2024-01-15 → 2024-03-15: Oracle = 2.0 exactly (same day-of-month), Trino days/31 = 60/31 ≈ 1.935. Off by 0.065 month.
  - Example divergence: 2024-01-31 → 2024-02-29: Oracle = 1.0 (both last-day-of-month), Trino days/31 = 29/31 ≈ 0.935. Off by 0.065 month.
- Responder did flag "rounding differences" + downstream-guidance ("integer fine for cohort, fractional for accrual via day-diff"). The exact-Oracle-equivalent formula would be:
  ```sql
  date_diff('month', start, current)
    + (day_of_month(current) - day_of_month(start)) / 31.0
  ```
  This was not surfaced. Engineer migrating prorated-billing logic with strict Oracle parity needs the exact formula; days/31 introduces ~3% drift on day-of-month-aligned anniversaries.
- **NO FIX-A**: not a fabrication, the approximation IS workable + flagged as approximate. Recall-ceiling completeness shave on the exact-formula variant. Per `feedback_synthesis_ceiling_stop_churning.md` — exact procedural rewrite of Oracle date math is a known Haiku synthesis ceiling on rare numeric formulas.
- Cites r27/r28 Oracle-to-Trino migration date-fn canonicals.

## Topic mapping (rubric updates)

| Topic | Prior | New | Delta |
|---|---|---|---|
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup (Q1) | 4.4403/216 | (4.4403*216 + 4.625)/217 = **4.4412/217** | +0.0009 |
| SQL query best practices for OLAP (Q2 width_bucket) | 4.5913/275 | (4.5913*275 + 4.3125)/276 = **4.5903/276** | -0.0010 |
| Improving complex SQL performance on Trino with dbt (Q3 dbt exposures) | 4.5762/39 | (4.5762*39 + 4.0)/40 = **4.5618/40** | -0.0144 |
| Oracle PL/SQL → dbt + Trino SQL migration (Q4 MONTHS_BETWEEN) | 4.4768/170 | (4.4768*170 + 4.25)/171 = **4.4743/171** | -0.0025 |

All four required topics remain PASSED with healthy margins.

## Watches (carry forward)

- **NEW iter1208 Q3 dbt selector direction** (`+model_name` ancestors vs `model_name+` descendants for impact analysis): re-probe in 4-8 iters with structurally similar "which dashboards consume my model" framing. If recurs, light additive directional-mnemonic card in dbt-exposures coverage; do NOT churn now.
- **NEW iter1208 Q2 width_bucket boundary off-by-one** for half-open-interval labeled histograms: re-probe under generic histogram-binning question in 4-8 iters; recall ceiling, NO resource fix.
- iter1207 GDPR Spark-CALL-vs-Trino-EXECUTE engine-tag (4-8 iters) — soft.
- iter1206 NVL-coercion edge — soft.
- iter1206 Q1 LIKE-on-ROW + `$partitions`-omission — soft.
- iter1204 `--full-refresh` `on_table_exists` atomicity — soft.
- iter1199 r17 position-delete adjacent — soft.

## Status

iter1208 = **4.30 PASS** (mid-band, two real recall-ceiling slips on Q2 & Q3, neither resource-sourced). NO FIX-A this iter. All required topics PASSED with healthy margins. Continue breadth.
