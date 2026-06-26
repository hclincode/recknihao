# Iter1140 Judge Feedback

**Verdict: 4.7188 STRONG PASS NO-OP.** DOUBLE FIX-A re-probe — BOTH iter1139 WATCHES CLOSE on first re-probe. Q1 INDF-as-NVL-substitute silent-wrong WATCH CLOSED (responder used `COALESCE(plan_tier, 'free') = 'free'`, did NOT recommend `IS NOT DISTINCT FROM 'free'`). Q2 SCD-2-need-without-the-word-snapshot routing WATCH CLOSED (responder routed to dbt SNAPSHOT canonical with config + 4 meta cols + as-of point-in-time query + LAG-based transitions on a question that DELIBERATELY AVOIDS "snapshot"/"SCD"/"Type 2", did NOT bail). Q3 EXTRACT(QUARTER) clean 5.0 breadth. Q4 MinIO `mc ilm` tiering + `expire_snapshots` clean 4.75. ZERO source-verified defects this iter.

NO new watch streams opened. NO resource edits warranted — both iter1139 surgical edits worked exactly as designed on first re-probe.

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---:|---:|---:|---:|---:|
| Q1 | SQL best practices for OLAP — Oracle NVL→COALESCE; INDF-vs-NVL defang re-probe | 5.0 | 4.5 | 5.0 | 4.0 | **4.625** |
| Q2 | dbt snapshots SCD2 — change-history-without-the-word-snapshot routing re-probe | 4.5 | 4.5 | 4.5 | 4.5 | **4.500** |
| Q3 | Analytical query patterns on Iceberg+Trino — EXTRACT(QUARTER FROM ts) fiscal grouping | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q4 | Storage tiering on Trino+Iceberg+MinIO — `mc ilm tier add`/`mc ilm rule add` + `expire_snapshots` | 5.0 | 4.5 | 5.0 | 4.5 | **4.750** |

**Iter average: (4.625 + 4.500 + 5.000 + 4.750) / 4 = 4.71875 → 4.7188 STRONG PASS**
Margin above 3.5 threshold: **+1.2188**

---

## Per-question analysis

### Q1 (4.625) — Oracle `NVL(plan_tier, 'free') = 'free'` → Trino; engineer heard about a "null-safe equality operator" and wants NULL rows INCLUDED, not silently filtered

**Responder answer**: `WHERE COALESCE(plan_tier, 'free') = 'free'` — includes 'free' rows AND NULL rows, exactly like Oracle NVL; noted `''` is not NULL in Trino, suggested testing against sample data. Did NOT recommend `IS NOT DISTINCT FROM 'free'`.

**Verdict**: Correct and clean. The iter1139 r23 §2947-2952 inline-WRONG DO-NOT-WRITE block against INDF-as-NVL-substitute did its job — responder didn't even cite INDF as an option. Silent-wrong slip from iter1139 Q3 DID NOT RECUR.

**Verified at** [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html): `NULL IS NOT DISTINCT FROM <non-null literal>` returns FALSE; the form `WHERE col IS NOT DISTINCT FROM 'literal'` is just `WHERE col = 'literal'` when the right operand is a non-null literal, silently filtering NULL rows out — opposite of `NVL(col,'literal')='literal'` semantics. Responder correctly avoided this trap.

**Minor completeness shave** (4.0): the engineer explicitly mentioned hearing about a "null-safe equality operator" and explicitly said they wanted to be sure NULL rows are INCLUDED not silently filtered. A "recall-then-defang" answering style ("you heard about IS NOT DISTINCT FROM — here's why that one would actually filter the NULL rows out against 'free', here's the COALESCE form that does what you want") would have been more pedagogically complete. The responder gave the right answer without explicitly addressing the operator the engineer asked about. This is responder bias toward minimum-sufficient answer — NOT a defect, NOT a new FIX-A; recall ceiling, no resource fix.

**iter1139 FIX-A1 REACH VERDICT: CONFIRMED CLEAN. INDF-as-NVL-substitute silent-wrong WATCH: CLOSED.**

---

### Q2 (4.5) — Mutable `customer_accounts` overwritten in place, no history; analysts want "what plan was account 5872 on at start of Q1" + "how many moved Pro->Starter last quarter"; build something in dbt that records every change with effective start/end dates (question DELIBERATELY AVOIDS the words "snapshot"/"SCD"/"Type 2")

**Responder answer**: Correctly identified "You need a dbt SNAPSHOT — SCD Type 2"; gave snapshot config (target_schema, unique_key='account_id', strategy='timestamp', updated_at='<col>'); listed the 4 meta cols dbt_valid_from / dbt_valid_to / dbt_scd_id / dbt_updated_at; gave the as-of point-in-time predicate `TIMESTAMP '2025-01-01' >= dbt_valid_from AND (dbt_valid_to IS NULL OR TIMESTAMP '2025-01-01' < dbt_valid_to)` matching r09 §348 verbatim; transitions via `LAG(plan_type) OVER (PARTITION BY account_id ORDER BY dbt_valid_from)`; strategy='check' fallback if no updated_at column.

**Verdict**: Routed correctly to the r09 dbt SNAPSHOT canonical despite the question deliberately avoiding the keyword "snapshot". The iter1139 r27 TL;DR pt4 keyword-anchor + r09 §305-309 SCD-section-opener routing block did their job. Bail from iter1139 Q4 DID NOT RECUR.

**Verified against** [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots): the 4 meta cols are the correct standard set; strategy='timestamp' requires `updated_at` (correct); strategy='check' uses `check_cols` (correct). As-of predicate is verbatim r09 §348.

**Two minor cosmetic shaves** (not load-bearing):
1. Aliased "upgrade_count" for a Pro->Starter transition, which is actually a DOWNGRADE not an upgrade. Column-name mislabel only; LAG comparison logic is correct.
2. "Last quarter" filter has a lower bound but no upper bound (one-sided range). Transitions are still bounded by the LAG window but the temporal cutoff is asymmetric — analyst might double-count a Q1 transition when asking about Q4.

Both are responder secondary-fill cosmetic slips. They fit the existing "responder-broken-secondary-alternative" memory-pin family — responder fills in beyond the core answer with insufficient editing. Per the memory pin: don't churn the resource trying to fix these; recall ceiling, no per-instance resource fix.

**iter1139 FIX-A2 REACH VERDICT: CONFIRMED CLEAN. SCD-2-need-without-the-word-snapshot routing WATCH: CLOSED.**

---

### Q3 (5.0) — Group revenue by fiscal quarter; built-in to pull quarter number from a timestamp or manual CASE?

**Responder answer**: `EXTRACT(QUARTER FROM event_date)` built-in returns 1-4, no CASE needed; also `EXTRACT(YEAR FROM event_date)` for year-quarter grouping; lists supported EXTRACT fields.

**Verdict**: Correct, complete, clear. Verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): EXTRACT supports QUARTER field; equivalent standalone `quarter(date)` / `quarter(timestamp(p))` returning bigint also exists.

---

### Q4 (4.75) — 4yr Iceberg data on MinIO, analysts rarely look past 90d, old data costs same per GB + slows weekly compaction; pattern to auto-move old data to cheaper/slower storage but keep queryable

**Responder answer**: Routed to MinIO object-lifecycle (NOT Trino SQL — no per-partition tier DDL in Trino); `mc ilm tier add` to register cold tier + `mc ilm rule add --transition-days 90 --transition-tier <NAME>` scoped to data/ prefix; keep metadata/ on hot tier (Iceberg planning needs metadata.json/manifest hot, only data parquet files tier-eligible); Trino queries old data transparently at higher latency; load-bearing caveat: weekly `expire_snapshots` required or tiering can't reclaim space (old snapshots reference data files, MinIO can't retire referenced objects).

**Verdict**: All correct. Verified at [docs.min.io mc-ilm-tier-add](https://docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-tier/mc-ilm-tier-add/) + [mc-ilm-rule-add](https://docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-rule/mc-ilm-rule-add/): `--transition-days` and `--transition-tier` flags + bucket-prefix scope documented. The data/-vs-metadata/ split is the correct Iceberg-on-MinIO tiering pattern.

**Small shaves**: didn't explicitly explain the data/ vs metadata/ prefix distinction (assumes engineer knows the Iceberg-on-MinIO layout); didn't surface the compression_codec or recent/archive-tables UNION ALL via dbt view alternatives (both are in the storage-tiering canonical). The MinIO ILM answer alone is sufficient but a one-line "alternative if you can't change MinIO config" would round out the options. Neither is load-bearing.

---

## Topic averages updated

| Topic | Before | After | Δ | New margin | Status |
|---|---:|---:|---:|---:|---|
| SQL query best practices for OLAP | 4.5527 / 202 | 4.5530 / 203 | +0.0003 | +1.0530 | PASSED |
| dbt snapshots SCD2 | 4.0848 / 17 | **4.1079 / 18** | +0.0231 | +0.6079 | PASSED |
| Analytical query patterns on Iceberg+Trino | 4.4690 / 91 | 4.4748 / 92 | +0.0058 | +0.9748 | PASSED |
| Storage tiering on Trino+Iceberg+MinIO | 4.0739 / 11 | **4.1302 / 12** | +0.0563 | +0.6302 | PASSED |

All required topics REMAIN PASSED. Both topics that took the iter1139 hit (dbt-snapshots SCD2, Storage-tiering) recover this iter — neither is the thinnest required-topic anymore.

---

## Watch verdicts

**iter1139 FIX-A1 (r23 §2947-2952 inline-WRONG DO-NOT-WRITE defang against INDF-as-NVL-substitute) WATCH: CLOSED**

- Q1 re-probe used `COALESCE(plan_tier, 'free') = 'free'`, did NOT recommend INDF.
- Silent-wrong slip from iter1139 Q3 did not recur.
- Surgical resource edit worked as designed on first re-probe.

**iter1139 FIX-A2 (r27 TL;DR pt4 keyword-anchor extension + r09 §305-309 SCD-section-opener routing block) WATCH: CLOSED**

- Q2 re-probe routed to dbt SNAPSHOT canonical despite question avoiding "snapshot"/"SCD"/"Type 2".
- Bail from iter1139 Q4 did not recur.
- Two-touch surgical resource edit worked as designed on first re-probe.

**NO new watch streams opened.**

---

## Source-verified defects this iter

**0 resource-sourced factual errors. 0 responder one-off defects. 0 silent-wrong slips.**

Q2 has two cosmetic shaves (upgrade_count label for a downgrade transition; one-sided last-quarter filter). Both fit the existing "responder-broken-secondary-alternative" memory pin (responder fills in beyond the core answer with insufficient editing). Don't churn — no per-instance resource fix.

Q1 has one minor completeness shave (didn't name and rule out the INDF operator the engineer asked about). NOT a defect — responder gave the right answer; just didn't do the "recall-then-defang" pedagogy. Recall ceiling, no resource fix.

---

## Recommendation

**NO-OP this iteration.** Commit rubric + this feedback file. NO resource edits.

Both FIX-A watches CLOSED on first re-probe — exactly the expected behavior:
- Pattern A (inline-WRONG DO-NOT-WRITE for hybrid responder-over-extrapolation + missing-defang): clean recall.
- Pattern B (additive keyword-anchor sentences at TL;DR + section-opener for routing/findability miss with content-that-exists): clean routing.

Don't extend either edit further.

---

## Teacher guidance

- **No resource edits this iter.** Both surgical fixes from iter1139 worked exactly as designed.
- **Don't fix Q2 cosmetic shaves** — they're textbook responder-broken-secondary-alternative slips (memory pin), not a content gap.
- **Don't fix Q1 completeness shave** — recall-then-defang style is a recall ceiling, not a resource gap.

---

## Re-probe queue

1. **PRIORITY 1 — Q1 INDF durability check**: probe a sneakier phrasing where the engineer ALREADY HAS `IS NOT DISTINCT FROM 'pending'` in Oracle code and asks if it's safe to keep in Trino. Confirm responder reaches the "INDF-against-a-non-null-literal is just `=`, will silently filter NULL rows" explanation, NOT a "yes, equivalent" pass-through.
2. **PRIORITY 1 — Q2 SCD-2 routing durability check**: probe another no-snapshot phrasing, e.g., "Postgres customer table mutated in place, no audit log; want plan history for Stripe reconciliation" or "Build a slowly-changing-dimension table from a mutable source — what's the dbt mechanism?" Confirm routing holds to r09 §SCD Option 1.
3. **query-perf-basics 24th angle** (NEW thinnest required-topic, untouched 6+ iters).
4. **cost-considerations 24th angle** (second-thinnest band).
5. **Q4 storage-tiering follow-up** — probe the archive-table UNION ALL via dbt view alternative (compression_codec + recent/archive workaround surface, not yet probed in this band).

---

## Thinnest-margin order after iter1140

1. query-perf-basics 4.1771 / 23 (+0.6771) — **NEW thinnest required-topic**
2. storage-tiering 4.1302 / 12 (+0.6302) — Q4 lift; no longer thinnest
3. dbt-snapshots SCD2 4.1079 / 18 (+0.6079) — Q2 lift; no longer thinnest
4. cost-considerations 4.3074 / 23 (+0.8074) — untouched
5. query-perf-regression-diagnosis 4.3436 / 21 (+0.8436) — untouched
6. Oracle-migration 4.4381 / 118 (+0.9381) — untouched
7. Iceberg-partition-design 4.4616 / 47 (+0.9616) — untouched
8. Analytical-query-patterns 4.4748 / 92 (+0.9748) — Q3 lift
9. Iceberg-maintenance 4.4800 / 179 — untouched
10. federation 4.5024 / 312 (+0.0024) — untouched, fragile-PASS preserved
11. SQL-best-practices-OLAP 4.5530 / 203 (+1.0530) — Q1 slight lift
12. CBO/ANALYZE 4.6105 / 22 (+0.1105) — untouched
13. improving-complex-SQL-perf-dbt 4.6111 / 25 — untouched

---

## Pattern observation

23-iter sustainment band:
- STRONG PASS: 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131/1133/1134/1137/**1140**
- LIGHT FIX-A: 1091/1116/1124/1129/1132/1136/1138
- NO-OP+WATCH: 1120/1123/1126/1130/1135
- PASS+DOUBLE-LIGHT-FIX-A: 1139

**iter1140 4.7188 STRONG PASS NO-OP is the EXPECTED recovery from iter1139's thinnest-margin iter (3.8750).** Both FIX-As reached cleanly on first re-probe, confirming both surgical edits worked exactly as designed.

**Two confirmed fix patterns from this DOUBLE re-probe:**

- **Pattern A** (inline-WRONG DO-NOT-WRITE block for hybrid responder-over-extrapolation + missing-defang): Q3 iter1139 INDF-as-NVL-substitute closed on first re-probe. Responder didn't even cite INDF as an option.
- **Pattern B** (additive keyword-anchor sentences at TL;DR + section-opener for routing/findability miss with content-that-exists): Q4 iter1139 SCD-2-need-without-the-word-snapshot routing closed on first re-probe. Responder routed cleanly via the new phrasings ("build change history", "track changes over time", "what plan was X on a past date") without needing the literal word "snapshot".

Both fix patterns are confirmed DURABLE on a single re-probe each. Don't extend either edit; the recall is clean. Q2 cosmetic shaves (mislabel + one-sided range) are textbook responder-broken-secondary-alternative slips and don't open a new defect class — per memory pin, don't try to resource-fix.
