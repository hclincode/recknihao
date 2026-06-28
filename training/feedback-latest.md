# Iteration 1220 — Judge Feedback

**Verdict: 4.47 PASS + LIGHT FIX-A on Q1 (cross-spec pruning overstatement).** Q2 `min_by(channel, created_at)` value-at-min-timestamp pin-perfect (4.875). Q3 `on_schema_change='append_new_columns'` auto-ALTER + four-value matrix verified clean (4.75). Q4 Oracle `SYSDATE-7` → `current_timestamp - INTERVAL '7' DAY` + `date_diff('hour', t1, t2)` pin-perfect (5.0). **Q1 partition-evolution OVERSTATEMENT (3.25)** — responder correctly identifies spec_id mechanics, the `rewrite_data_files(rewrite-all=true)` fix, `$files` diagnostic, and `expire_snapshots` cleanup, **BUT misdiagnoses cross-spec pruning** as "Trino sees month-spec files and CANNOT apply day-level pruning to them — so it scans ALL 400M rows." The accurate framing per Iceberg/Trino semantics is: **old (month-spec) files DO still prune at the OLD spec's MONTH granularity** (the `event_date='2026-01-15'` predicate gets projected through the month transform, keeping ONLY the 2026-01 month-partition files and pruning all other months). Day-level pruning is what's lost on old files; pruning isn't lost entirely. The engineer is told their old queries can't prune at all when actually they prune to ~1 month of data; the FIX (Spark rewrite) is still the correct remediation for day-level pruning. **LIGHT FIX-A** — add a row to r10's PARTITION EVOLUTION canonical (§98-117 or the LEADING CANONICAL §126-228) explicitly distinguishing **transform-refinement evolution (month→day, day→hour)** = old files prune at the COARSER old granularity (NOT full scan) FROM **adding-a-new-column evolution (added tenant_id)** = old files cannot be pruned by the new column at all. Resource L1242 ("Cannot be pruned by the new column") is correct for the latter case but the responder generalized it to the transform-refinement case. NO over-warning / no imported-prior / no broken-secondary.

Open watches carried forward: iter1219 CoW-vs-MoR findability (re-probe 4-8), iter1219 format-%08d co-located canonical (5-9), iter1218 `accepted_values` NULL behavior (4-8), iter1215 strpos-3-arg ceiling (6-10 no churn), iter1213 session_properties + (+)-mnemonic (4-7), iter1206 LIKE-on-ROW+$partitions (3-7), light-monitors.

---

## Per-question scores

### Q1 — month→day partition evolution; pre-migration date query "scans all 400M rows"; expected? what does Trino do pruning files? — **PARTIAL (OVERSTATED DIAGNOSIS) + LIGHT FIX-A**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 2.5 | **WRONG diagnosis**: "Trino sees month-spec files and CANNOT apply day-level pruning to them — so it scans ALL 400M rows." Accurate: old-spec files prune at the OLD spec's MONTH granularity (predicate `event_date='2026-01-15'` is projected through the month transform → keeps only the 2026-01 month partition's files; January's old data is read, not all months). Day-level pruning IS lost on old files; cross-spec pruning is NOT lost entirely. Verified at [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/) (Dremio engineering blog quotes: "evolving from month to day partitioning... old files at month granularity (coarser)"). Spec_id mechanics, `rewrite-all=true`, `expire_snapshots`, "Trino EXECUTE optimize cannot cross-spec re-layout" all CORRECT. |
| Beginner clarity | 4 | Clear stepwise walkthrough with copy-pasteable Spark CALL form and Trino diagnostic query. Distinguishes the three engines/syntaxes well. |
| Practical applicability | 3.5 | The remediation (rewrite_data_files with rewrite-all=true → restamp under new spec → expire_snapshots) IS correct and will solve the problem. **But** the diagnosis misleads — the engineer might wrongly conclude that **all** old-date queries are full table scans (rather than month-scoped scans), which affects their triage/prioritization decisions on OTHER queries hitting old dates. They might also overestimate the savings from rewriting (a 1-month scan → 1-day scan = ~30x, not 400M-row → 1-day = ~120000x). |
| Completeness | 3 | Misses the key nuance that distinguishes **transform refinement** (same column, finer transform: month→day) from **column addition** (added partition column: e.g. + tenant_id). Both cases need rewrite to activate new pruning, but only the latter loses cross-spec pruning entirely. |

**Average: (2.5 + 4 + 3.5 + 3)/4 = 3.25 — PARTIAL.**

**VERIFICATION — Iceberg/Trino cross-spec pruning semantics.**

[iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/) and Dremio engineering blog confirm:

> "If you evolve from month to day partitioning and then run a query for 'yesterday,' Dremio prunes new files at day granularity (very precise) and **old files at month granularity (coarser)**."

> "When a query runs: Iceberg reads all manifest files. For manifests written with the old spec, **it applies the old partition pruning logic**. For manifests written with the new spec, it applies the new partition pruning logic. Results are merged transparently."

Iceberg's predicate-projection-through-partition-transform machinery (the same mechanism that makes `WHERE event_date='2026-01-15'` prune `month(event_date)='2026-01'` partitions on a freshly-month-partitioned table) ALSO applies to mixed-spec scenarios. The transform is `month(date)` for old files; the predicate `event_date='2026-01-15'` projects to `month(event_date)='2026-01'`, keeping ONLY the 2026-01 month and pruning all others. So:

- **Old (month-spec) files**: 1 month of data scanned (~1/N of the historical data, where N = months in history)
- **New (day-spec) files**: 1 day scanned
- The query for `event_date='2026-01-15'` (a pre-migration date) hits ZERO new-spec files (since migration was 10 weeks ago, all pre-migration dates are in old-spec files); the actual scan is January's old data.

**GREP — RESOURCE ROOT CAUSE.** Searching r10 for cross-spec pruning behavior:

- `resources/10-lakehouse-partitioning.md` L98-117 (PARTITION EVOLUTION pin) — keyword-anchors month→day evolution and the in-place ALTER + Spark rewrite recipe, but says nothing explicit about old-spec PRUNING granularity.
- L126-228 (LEADING CANONICAL "Migrating from date-only to (date, tenant_bucket)") — this is the **column-addition** case (added tenant_bucket); L143 correctly says "continue to **defeat tenant-bucket pruning**" — correct for THIS case (the new column wasn't in the old spec).
- L1242 (table row): "Files written **before** the ALTER | Old spec (or unpartitioned) | **Cannot be pruned by the new column.** Trino has to open and read these files for any query, even one that filters on the new partition column." — correct for the column-addition case; not applicable to transform-refinement.
- No section explicitly handles the **transform-refinement** subcase (same column, finer transform), so the responder generalized "Cannot be pruned" from the new-column case to the transform-refinement case.

**Decision: LIGHT FIX-A on r10.** Add a 5-7 line disambiguation row to the PARTITION EVOLUTION pin and/or LEADING CANONICAL clarifying:

```
TRANSFORM REFINEMENT (month → day, day → hour, identity → bucket on same column):
  Old-spec files prune at the OLD COARSER granularity (NOT full scan).
  WHERE event_date = '2026-01-15' on a month→day evolved table → old files prune to month(event_date)='2026-01' (one month scanned); new files prune to day(event_date)='2026-01-15' (one day).
  Rewrite to activate finer (day) pruning on old data.

COLUMN ADDITION (added tenant_id to spec, was day(occurred_at) → (day, tenant_id)):
  Old-spec files CANNOT be pruned by the NEW column at all (the column isn't in the old manifest partition struct).
  WHERE tenant_id = 'acme' on a day-only → (day, tenant_id) table → old files: full scan (no tenant pruning); new files: prune by tenant_id.
  Rewrite to activate tenant-column pruning on old data.
```

The "rewrite_data_files(rewrite-all=true)" fix is unchanged for both cases — only the DIAGNOSIS framing needs the disambiguation. Keyword anchors to add: "month to day pruning behavior", "old data prunes to month not day", "cross-spec pruning granularity", "do old queries full scan after partition evolution", "transform refinement vs new column".

---

### Q2 — user_events `MIN(channel)` returns alphabetical, want channel at earliest created_at — **STRONG PASS (4.875)**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 5 | `min_by(channel, created_at)` returns the value of `channel` at the row with min `created_at` per group. Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): "`min_by(x, y)` — Returns the value of `x` associated with the minimum value of `y` over all input values." Distinct from `MIN(channel)` which is alphabetical (lexicographic min of the channel string). Also correctly mentions `min_by(x, y, n)` 3-arg form for top-N. `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at ASC, event_id ASC) <= 1` tiebreaker pattern correct (recommended when you need ALL columns of the earliest row, not just one). |
| Beginner clarity | 5 | Crystal clear with the contrast against MIN(channel)'s alphabetical surprise, which is exactly the engineer's mental model. The "use min_by per column for multiple values, or ROW_NUMBER for all columns" routing is the right shape. |
| Practical applicability | 5 | Engineer pastes `SELECT user_id, min_by(channel, created_at) AS first_channel, MIN(created_at) AS first_event_time FROM user_events GROUP BY user_id` and runs. Tiebreaker addressed correctly. |
| Completeness | 4.5 | Minor: didn't note that `min_by` ignores rows where `created_at IS NULL` (more precisely: per Trino docs, `min_by` does NOT ignore null `x` values but the ordering column `y` follows standard MIN semantics on NULLs). Recall ceiling, not load-bearing for this question. |

**Average: (5 + 5 + 5 + 4.5)/4 = 4.875 — STRONG PASS.**

Citations correct: r07/r23 §3.1D min_by/max_by leading canonical.

---

### Q3 — Spark added country_code column; dbt incremental merge fails; on_schema_change value? does dbt auto-ALTER or manual? — **STRONG PASS (4.75)**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 5 | `on_schema_change='append_new_columns'` correct + **dbt auto-runs ALTER TABLE ADD COLUMN** before the MERGE (verified at [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) + community sources). Four values correctly enumerated: `ignore` (default, silent drop), `fail` (error/halt), `append_new_columns` (recommended), `sync_all_columns` (add + drop). Default = `ignore` (NOT `fail`) — correct per the dbt official page: "ignore - Default behavior (see below)." `sync_all_columns` correctly flagged as too aggressive for production (drops removed columns). |
| Beginner clarity | 5 | Four-value matrix with consequences is exactly the right shape for an engineer who's never seen this config. Calling out `ignore` as the default (and the silent data-loss risk) is load-bearing. |
| Practical applicability | 5 | Engineer adds `on_schema_change='append_new_columns'` to model config, runs `dbt run --select fct_events`, the ALTER fires automatically, the merge picks up country_code. No manual ALTER required. Exactly the actionable shape. |
| Completeness | 4 | Minor gaps: (a) didn't mention that **historical rows get NULL for the new column** (no backfill — engineer might expect populated values for prior runs); (b) didn't note that `append_new_columns` only fires when new columns ARE detected (no-op when schemas match); (c) didn't mention `--full-refresh` as the alternative if backfill is needed. Recall ceiling. |

**Average: (5 + 5 + 5 + 4)/4 = 4.75 — STRONG PASS.**

Citations correct: r13/r27 + dbt official docs.

---

### Q4 — Oracle `SYSDATE-7` and `event_time-SYSDATE` port to Trino errors; correct N-days-ago WHERE filter? correct hour-diff between two timestamps? — **STRONG PASS (5.0)**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 5 | (a) `current_timestamp - INTERVAL '7' DAY` valid per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) — unit OUTSIDE single-quotes, singular, uppercase. `INTERVAL '7 days'` (plural unit INSIDE quotes) is a parse error — verified. `date_add('day', -7, current_timestamp)` valid alt (Trino docs: "Subtraction can be performed by using a negative value"). (b) `date_diff('hour', t1, t2)` correct duration form returning integer hours (`timestamp2 - timestamp1` in units). Direct `timestamp - timestamp` subtraction is NOT a documented operator (returns parse error / type error). `(to_unixtime(t2) - to_unixtime(t1)) / 3600.0` valid epoch-seconds fallback returning fractional hours. All forms compatible with the `from_unixtime` returns timestamp-with-tz pin per memory. |
| Beginner clarity | 5 | The "unit OUTSIDE quotes" callout is the SINGLE most-confused syntax point for Oracle/Postgres migrants. Showing both INTERVAL and date_add forms covers two ergonomic preferences. The "timestamp - timestamp throws" defang prevents the engineer from retrying that exact wrong form. |
| Practical applicability | 5 | Engineer pastes `WHERE event_time >= current_timestamp - INTERVAL '7' DAY` and `SELECT date_diff('hour', start_ts, end_ts) AS duration_hours` and ships. |
| Completeness | 5 | Covers (a) and (b) cleanly. Could optionally mention `current_date - INTERVAL '7' DAY` for date-only (no time-of-day) windows but the current_timestamp form is the more general/Oracle-equivalent translation. No imported-prior, no over-warning. |

**Average: 5.0 — STRONG PASS.**

Citations: r27 Oracle→Trino port + r23 date/time canonicals.

---

## Iteration aggregate

| Q | Topic | Score | Status |
|---|---|---|---|
| Q1 | Iceberg partition design — partition evolution cross-spec pruning | 3.25 | PARTIAL — LIGHT FIX-A r10 |
| Q2 | Analytical query patterns — `min_by` value-at-min-timestamp | 4.875 | STRONG PASS |
| Q3 | Oracle PL/SQL → dbt+Trino — `on_schema_change` auto-ALTER | 4.75 | STRONG PASS |
| Q4 | Oracle PL/SQL → dbt+Trino — INTERVAL/date_diff temporal port | 5.0 | STRONG PASS |
| **Avg** | | **4.47** | **PASS + LIGHT FIX-A** |

All required topics remain PASSED. Margins safe. Q1 dent is FINDABILITY/FRAMING (a coarser-vs-no-pruning disambiguation row missing from r10's partition-evolution canonical), NOT a deep accuracy collapse — the responder got 6/7 of the technical mechanics right and the FIX recommendation is correct.

**Recurring pattern note**: this is the FIRST cross-spec PRUNING-granularity question on a transform-refinement (month→day) evolution scenario. Prior partition-evolution questions in the rubric (155+ iterations) were almost all column-addition cases (added tenant_id, added bucket(tenant_id, 64), etc.) where "cannot prune by the new column" IS the correct answer. The teacher should ADD the transform-refinement disambiguation row but NOT remove the column-addition framing — both cases are real.

**Carry-forward watches**:
- iter1219 CoW-vs-MoR findability (re-probe 4-8): keyword anchors added at r13 §2994; needs re-probe under varied phrasings (GDPR/right-to-be-forgotten/slow Spark delete job/which delete mode/45-minute rewrite). NO churn unless re-FAIL.
- iter1219 format-%08d co-located canonical (5-9): r23 §716-758 has the canonical with truncation-hazard callout; responder LPAD form passed but missed format(). Soft watch.
- iter1218 `accepted_values` NULL behavior (4-8): re-probe varied phrasings.
- iter1215 strpos-3-arg recall ceiling (6-10): no resource fix possible (Haiku recall ceiling); accept occasional Q cost.
- iter1213 session_properties + (+)-mnemonic (4-7).
- iter1206 LIKE-on-ROW+$partitions (3-7).
- NEW iter1220 cross-spec pruning granularity disambiguation (re-probe 4-8 after FIX-A lands).
