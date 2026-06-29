# Iteration 1243 — Judge Feedback

## Verdict

**Overall: 4.56 — STRONG PASS** with a real **LIGHT RECONCILE FIX-A** warranted on Q2 (corpus inconsistency, not a responder defect by itself). Per-Q scores: Q1=5.0, Q2=3.75, Q3=4.5, Q4=5.0. Average (5.0+3.75+4.5+5.0)/4 = 18.25/4 = **4.5625**.

**SIX HEADLINE FINDINGS:**

1. **Q1 (cumulative distinct) CORRECT and the iter1242 Q2 cumulative-distinct soft watch CLOSES on the 1st re-probe.** Responder wrote the canonical r07 §3059 Pattern A4 first-appearance + running-SUM form verbatim. Detail in §Q1.
2. **Q2 (date_trunc=DATE pruning) PARTIALLY MIS-FRAMED — responder OVERSTATED fragility for the asked shape.** Trino 467 RELIABLY unwraps `date_trunc('month', col) = DATE 'literal'` on identity / `day()` / `month()` partition transforms via the default-on `UnwrapDateTruncInComparison` rule (verified). The defensive bare-range fix the responder gave is still production-correct and EXPLAIN-verifiable. Detail in §Q2.
3. **CORPUS INCONSISTENCY CONFIRMED — LIGHT RECONCILE FIX-A WARRANTED on Q2.** r28 §710 (myth table) / §1093 / §1097 / §1319 + r22 §3261 all carry an "FRAGILE / MAY rewrite / typically will NOT prune" framing that CONTRADICTS the verified-accurate r28 §1072 lead + r23 §2522-§2528 + r10 §1458-§1461. The responder lifted the "FRAGILE / NOT guaranteed" wording from the r28 §1097 row. Exact lines + reconcile direction in §FIX-A.
4. **Q3 (--full-refresh) CORRECT** — drop+recreate via dbt-trino adapter (CREATE OR REPLACE TABLE on Iceberg = atomic snapshot commit) + `on_schema_change='append_new_columns'` for the historical-NULL fix. Verified against docs.getdbt.com.
5. **Q4 (Oracle ADD_MONTHS migration) CORRECT** — `date_add('month', n, dt)` is the replacement, the Oracle end-of-month snap divergence is correctly explained (Oracle clamps to last-day when INPUT is last-day; Trino preserves day-number), `last_day_of_month()` exists in Trino 467, `LAST_DAY` / `end_of_month` do not, and the CASE wrapper correctly replicates Oracle's snap. Verified against trino.io/docs/467/functions/datetime.html.
6. **TWO new soft watches** (Q2 corpus reconcile re-probe + Q3 dbt-trino on-Iceberg full-refresh atomicity).

---

## Per-question scoring

### Q1 — Cumulative distinct customers month-by-month (RE-PROBE of iter1242 Pattern A4 broken-SQL) — **5.0**

| Dim | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | First-appearance-cohort + running-SUM is the EXACT r07 §3059 Pattern A4 LEADING CANONICAL. Each customer contributes EXACTLY ONE row (their first-appearance month) → COUNT(*) per month = new-this-month → SUM() OVER (ORDER BY cohort_month) = monotonically-non-decreasing cumulative distinct count. Bounded by total customer base — cannot overshoot. Engineer's broken `SUM(COUNT(DISTINCT)) OVER` form double-counts any customer active in 2+ months (the iter692 Pattern A4 origin bug, exact iter1242 BANNED form). |
| Beginner clarity | 5.0 | Engineer-mental-model bridge included ("each customer contributes 1 to exactly one month") which explicitly states WHY the running SUM cannot overshoot. |
| Practical applicability | 5.0 | Drop-in CTE with explicit column aliases (`new_customers_this_month`, `cumulative_unique_customers`). |
| Completeness | 5.0 | Diagnoses the broken form + gives the correct form + explains the invariant. |

**WATCH STATUS — iter1242 Q2 cumulative-distinct prose-says-first-appearance-SQL-does-active-per-week soft watch: CLOSES** (1st re-probe). Responder both wrote correct PROSE and correct SQL this iter — the iter1242 prose-vs-SQL coherence slip did not recur. Per the carried "1st-re-probe-closes-soft-watch" pattern (now 23rd consecutive), no resource churn.

---

### Q2 — Iceberg day(event_date) partitions: `WHERE date_trunc('month', event_date) = DATE '2026-05-01'` "brutally slow" — does Trino 467 prune? — **3.75**

| Dim | Score | Notes |
|---|---|---|
| Technical accuracy | 3.0 | **OVERSTATED FRAGILITY for the asked shape.** Verified facts (sources below): (a) Trino 467 has the `UnwrapDateTruncInComparison` optimizer rule (PR #14011), default-on, no session gate; (b) supported units = `HOUR, DAY, MONTH, YEAR` (verified in `core/trino-main/src/main/java/io/trino/sql/planner/iterative/rule/UnwrapDateTruncInComparison.java` 467 tag — `SupportedUnit { HOUR, DAY, MONTH, YEAR }`); (c) the rewrite produces `BETWEEN argument, rangeLow, calculateRangeEndInclusive(rangeLow, ...)` — i.e., `event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'`; (d) the resulting bare-column range DOES prune partitions on identity / `day()` / `month()` transforms (per [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html)). The asked shape — month-unit `date_trunc` = DATE literal on a `day(event_date)`-partitioned column — is the EXACT central case the rule covers. The responder's "you CANNOT rely on it / NOT guaranteed for bucket(), function compositions, or non-literal constants" is half-right: those legitimately-fragile cases are real but DO NOT apply to the asked shape (literal RHS, day() partition, month-unit). Hedge belongs on bucket/hour/non-literal-RHS/function-composition, NOT on the simple `date_trunc('month'|'day'|'year', col) = literal` form. The defensive bare-range fix is still production-correct and EXPLAIN-verifiable, so the engineer arrives at a working query, but the diagnostic story ("Trino is full-scanning because the simplifier can't unwrap") is the WRONG mental model — if the engineer is observing "brutally slow", it's almost certainly something else (manifest bloat, stats staleness, type-mismatched-literal, or measurement artifact), not a failure of `UnwrapDateTruncInComparison`. |
| Beginner clarity | 4.0 | Names the rule (`SimplifyDateTrunc` — the rule's actual class is `UnwrapDateTruncInComparison`; the blog calls it the "simplify date_trunc" rewrite, so the wording is forgivable but slightly imprecise), names the EXPLAIN `constraint=` annotation as the verification handle. |
| Practical applicability | 4.5 | Engineer can act: rewrite to bare-range half-open form + verify with EXPLAIN. That IS the right defensive habit even if the framing of WHY is overstated. |
| Completeness | 3.5 | Addresses the rewrite question but misses (a) the unit-coverage detail (HOUR/DAY/MONTH/YEAR yes, WEEK no), (b) the actual likely cause of the observed slowness (not the simplifier — stats / manifest bloat / etc.). |

**ACCURATE 467 ANSWER FOR THE ASKED SHAPE** — `WHERE date_trunc('month', event_date) = DATE '2026-05-01'` on a `day(event_date)`-partitioned Iceberg table on Trino 467: the `UnwrapDateTruncInComparison` rule (default-on, no session toggle, PR #14011) RELIABLY rewrites this to `event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'`, and the resulting bare-column range DOES drive partition pruning on the `day()` transform. The "brutally slow" observation is NOT explained by Trino failing to unwrap — investigate alternative causes (manifest bloat, stale stats / missing ANALYZE, a different actual predicate shape in the real query, a measurement-confound where the "slow" run hit a cold cache). The bare half-open range is still the recommended defensive form **for portability and clarity**, not because the wrapped form breaks pruning in 467.

**Sources verified this iter (judge WebFetch/WebSearch):**
- [trinodb/trino PR #14011 "Simplify predicates involving date_trunc"](https://github.com/trinodb/trino/pull/14011) — introduces `UnwrapDateTruncInComparison`, default-on iterative rule.
- [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html) — Trino blog; describes the rewrite to bare-column range.
- 467-tag source `core/trino-main/src/main/java/io/trino/sql/planner/iterative/rule/UnwrapDateTruncInComparison.java` — supported units enum = `HOUR, DAY, MONTH, YEAR`; EQUAL case produces `between(argument, rangeLow, calculateRangeEndInclusive(rangeLow, ...))`; no session-property gate.
- [trinodb/trino PR #14161](https://github.com/trinodb/trino/pull/14161) — follow-up adding HOUR support.

**CONSISTENT WITH carried memory** `reference_trino_unwrap_temporal_predicates.md` (iter871): "Trino 467 default-on Unwrap{Cast,Year,DateTrunc}InComparison rules rewrite year(col)=lit / date_trunc / CAST(col AS date) / EXTRACT(YEAR) into bare-column ranges that STILL prune partitions; 'function-on-column=full scan' is a FALSE imported sargability prior."

---

### Q3 — `--full-refresh` on incremental model, added `churn_risk` column with historical NULLs — **4.5**

| Dim | Score | Notes |
|---|---|---|
| Technical accuracy | 4.5 | Verified against [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) (verbatim: "This flag will cause dbt to drop the existing target table in the database before rebuilding it for all-time") and [docs.getdbt.com/reference/resource-configs/full_refresh](https://docs.getdbt.com/reference/resource-configs/full_refresh) (`drop cascade` then rebuild). Responder's "atomic CREATE OR REPLACE TABLE (Iceberg snapshot)" is dbt-trino-adapter-correct for Iceberg-backed models (dbt-trino emits `CREATE OR REPLACE TABLE` on Iceberg, which IS a single atomic Iceberg metadata commit — no DROP+CREATE race window on this stack). `on_schema_change='append_new_columns'` is the documented value for "new column shows up at the source, don't fail, just ADD it to the target schema" (which keeps historicals NULL because no backfill is performed — exactly the engineer's observed shape). Mild caveat shave: should have noted that even with `append_new_columns`, historicals stay NULL — the column is added to the target schema but only newly-inserted rows get a populated value. `--full-refresh` is the only way to backfill historicals (which IS what the engineer ran). |
| Beginner clarity | 4.5 | "Sets `is_incremental()` to false → the delta WHERE filter is skipped → full rebuild" is a clean mental-model bridge. |
| Practical applicability | 4.5 | Engineer can act: run with `--full-refresh` to backfill the new column, or add `on_schema_change='append_new_columns'` to avoid the next forward-only column-add failure. |
| Completeness | 4.5 | Covers full-refresh mechanics + atomicity + the actual root cause of the NULL historicals + the on_schema_change fix. Minor miss: didn't explicitly say "even append_new_columns won't backfill — that's why you ran --full-refresh in the first place" which would tie the two answer halves together. |

---

### Q4 — Oracle `ADD_MONTHS(contract_start_date, 12)` → Trino — **5.0**

| Dim | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | Verified against [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): (a) `ADD_MONTHS` is NOT a Trino function — correct ("Function not registered" matches the reported error); (b) `date_add('month', 12, contract_start_date)` IS the replacement and is the canonical Trino form for unit-month arithmetic; (c) Oracle's end-of-month snap behavior is correctly characterized — Oracle clamps the result to last-day-of-target-month when the INPUT was last-day-of-source-month (`ADD_MONTHS(DATE '2026-02-28', 1) → 2026-03-31`), Trino preserves the day-number (`date_add('month', 1, DATE '2026-02-28') → 2026-03-28`). The non-trivial nuance: Trino DOES clamp for the day-overflow case (`date_add('month', 1, DATE '2026-01-31') → 2026-02-28`/29) — that's standard day-overflow handling, NOT Oracle's last-day snap. The two behaviors converge on Jan-31 → Feb-end but diverge on Feb-28 → Mar-28 (vs Oracle's Mar-31). The responder's specific example is the right test-case for the divergence. (d) `last_day_of_month(date)` IS a real Trino 467 function — verified. `LAST_DAY` / `end_of_month` are NOT — verified. (e) The CASE wrapper correctly replicates Oracle's snap: `CASE WHEN contract_start_date = last_day_of_month(contract_start_date) THEN last_day_of_month(date_add('month', 12, contract_start_date)) ELSE date_add('month', 12, contract_start_date) END`. |
| Beginner clarity | 5.0 | Before/after with concrete dates (Feb-28 → Mar-31 vs Mar-28) makes the divergence visceral. |
| Practical applicability | 5.0 | Drop-in for both the simple case (`date_add`) and the snap-faithful case (CASE wrapper). Production-stack aligned. |
| Completeness | 5.0 | Covers function replacement + divergence + workaround. |

---

## FIX-A — LIGHT RECONCILE warranted on Q2 corpus inconsistency

**Conflict to adjudicate:** the corpus contains BOTH "Trino 467 reliably unwraps `date_trunc(unit, col) = literal` and prunes" (accurate) AND "FRAGILE / MAY rewrite / NOT guaranteed / typically will NOT prune" (inaccurate for the simple-shape case). The responder lifted the inaccurate framing this iter (Q2 2.95 -> 3.75 on hedged-but-overstated framing). Reconcile in place — do not append a new card.

**ACCURATE position to align to** (verified this iter):
- Trino 467 `UnwrapDateTruncInComparison` (PR #14011) is **default-on, no session gate**.
- Supports `HOUR, DAY, MONTH, YEAR` units (NOT `WEEK`).
- Rewrites `date_trunc(supported_unit, col) = DATE 'literal'` to a bare-column BETWEEN range.
- The bare-column range DOES drive partition pruning on **identity / `day()` / `month()` / `year()`** transforms.
- LEGITIMATELY fragile cases (preserve these caveats): `bucket()` partition transform, function compositions (`LOWER(date_trunc(...))`, `date_trunc(...) + INTERVAL ... = ...`), non-literal RHS that doesn't constant-fold, `WEEK` unit (not in the supported enum), `timestamp(6) with time zone` columns with TZ-normalized boundary handling.

**Exact lines to reconcile (do NOT just append — fix in place):**

| File | Line | Current framing | Reconcile to |
|---|---|---|---|
| `resources/22-trino-federation-postgresql.md` | §3261 (the federated-query diagnostic heuristic block, sentence "a `WHERE occurred_at >= DATE '...'` ... will prune correctly, but `WHERE date_trunc('day', occurred_at) = DATE '...'` typically will NOT prune because the partition transform isn't recognized in the literal") | **FLAT-WRONG for 467.** | "`WHERE date_trunc('day', occurred_at) = DATE '...'` DOES prune on Trino 467 — the default-on `UnwrapDateTruncInComparison` rule (PR #14011) rewrites it to a bare-column range that the `day()` transform pruner picks up. Genuine pruning-killers in this position are function compositions (`LOWER(date_trunc(...))`), `bucket()`-transform columns, or non-literal RHS that doesn't constant-fold." |
| `resources/28-complex-sql-performance-trino-dbt.md` | §710 (myth-table row "Wrapping a partition column in `date_trunc()` is fine") | Currently says "NUANCED ... fragile ... NOT guaranteed for bucket() / hour() ... function compositions ... non-literal constant". This is INCONSISTENT with §1072 lead. | Keep the "NUANCED" framing BUT restructure so the lead claim is "RELIABLE on Trino 467 for `date_trunc(HOUR\|DAY\|MONTH\|YEAR, col) = literal` on identity / `day()` / `month()` / `year()` partitions" — THEN list the legitimately-fragile cases (bucket() transform, function-composition, non-literal RHS, `timestamp with time zone` boundary, WEEK unit). |
| `resources/28-complex-sql-performance-trino-dbt.md` | §1093 (the "VERSION-SENSITIVE NOTE on `date_trunc`" block) | Currently says "The simplification is FRAGILE — not guaranteed for `bucket()` / non-default transforms, function compositions, or non-literal constants." | Same restructure: lead with "RELIABLE for the simple `date_trunc(supported_unit, col) = literal` shape on identity / `day()` / `month()` / `year()` partitions"; preserve the fragility caveat for the genuinely-fragile cases only. Cross-reference §1072 lead so the lead and the detail agree. |
| `resources/28-complex-sql-performance-trino-dbt.md` | §1097 (the 4.2 broken-shape table row `WHERE date_trunc('day', event_ts) = DATE '2026-05-30'` Reason cell) | Currently classifies as a BROKEN shape with "FRAGILE on Trino 400+" reason. | Move this row OUT of the "What breaks pushdown" table — it doesn't break in 467 — and put it in a new "What used to break but Trino 467 unwraps" subsection. OR keep it in the table but flip the Reason cell to "Trino 467 UNWRAPS this via `UnwrapDateTruncInComparison`; row preserved as documentation that the bare-range form remains the recommended defensive practice for portability/clarity, NOT because pruning fails in 467." Either rewrite makes the table internally consistent with the §1072 lead. |
| `resources/28-complex-sql-performance-trino-dbt.md` | §1319 (correlated-example commentary: "The Trino 400+ `SimplifyDateTrunc` rule handles the simple `date_trunc(...) = LITERAL` shape on identity / `day()` partitions, but the `>= NON_LITERAL` shape here is fragile") | This one is more nuanced — `CURRENT_DATE - INTERVAL '7' DAY` IS constant-foldable at plan time, so the simplification likely fires. | Re-test in 467: if the constant-folding-then-unwrap fires, soften the "fragile" framing to "the constant-folding-then-unwrap path may or may not fire on `>= CURRENT_DATE - INTERVAL '<N>' DAY`; verify with EXPLAIN; if it doesn't fire, use the naked-range form below". If it doesn't fire, the "fragile" framing is correct as-is — but mark explicitly that the failure mode is non-literal-RHS-doesn't-constant-fold, NOT the simplifier missing. |

**Why reconcile rather than append:** per carried `feedback_reconcile_dont_append.md` — the responder will lift the wording from whichever paragraph the keyword path leads to. Today it found the "FRAGILE" row in §1097 / §710. If a new accurate card is appended without fixing the wrong ones, the wrong wording will still attract on the next pruning-related question. Reconcile in place; preserve the legitimately-fragile caveats (bucket/hour/composition/non-literal-RHS/TZ/WEEK).

**SCOPE OF FIX-A: LIGHT** — 5 line-localized edits in 2 files (r22 §3261; r28 §710, §1093, §1097, §1319). No new keyword cards. No new sections. Per memory `feedback_new_card_over_attracts_adjacent.md` — adding new cards in a date_trunc-pruning-anchored region risks over-attracting adjacent pruning-question recall.

---

## New / closed watches

**CLOSED this iter:**
- `iter1242 Q2 cumulative-distinct prose-vs-SQL coherence` (soft watch) — 1st re-probe (Q1) CLOSES it. Responder wrote both correct prose and correct SQL.

**NEW this iter:**
- `iter1243 Q2 date_trunc-DATE-literal-pruning fragility-overstatement` — re-probe under "wrapped temporal predicate on day/month/year partition" framings 4-8 iters post-FIX-A. Verify the §710/§1093/§1097 reconcile actually flips the responder's wording from "FRAGILE / NOT guaranteed" to "RELIABLE for the simple shape; fragility limited to bucket()/composition/non-literal-RHS/WEEK". If post-FIX-A re-probe still says "you cannot rely on it" for the simple month-unit-DATE-literal-day-partition shape, escalate to in-place strengthening of the §1072 lead.
- `iter1243 Q3 dbt-trino-on-Iceberg --full-refresh atomicity-mechanism` (soft) — re-probe under "does --full-refresh have a downtime/data-loss window on Iceberg" framings 4-8 iters. Verify dbt-trino's Iceberg adapter emits a single `CREATE OR REPLACE TABLE` atomic commit (vs DROP + CTAS race-window) — if the engineer hits a window where the table is missing or schema-shifted, the responder's "no downtime / no data loss" claim needs softening.

**Carried-forward watches** (no change this iter):
- iter1241 concat-auto-coerces (soft)
- iter1240 orphans-$files (soft)
- iter1239 DF-wait-timeout (soft)
- iter1238 broadcast-hedge (soft)
- iter1236 rn=1-within-batch (soft)
- iter1234 ROLLUP-date_trunc-expr
- iter1231 NEXT_DAY-note
- iter1230 EXISTS-overwarning/::cast
- iter1215 strpos-3-arg CEILING
- iter1213 session_properties/(+)
- iter1229 @v1-Spark
- iter1208 width_bucket

---

## Topic coverage this iter

- **Q1** — Common analytical query patterns: aggregations, funnels, cohort, time-series **AND** Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL (cumulative-distinct first-appearance pattern).
- **Q2** — SQL query best practices for OLAP **AND** Query performance basics: partitioning, indexing strategy for analytics (predicate-pushdown / partition-pruning shape).
- **Q3** — Improving complex SQL performance on Trino with dbt **AND** Oracle PL/SQL → dbt + Trino SQL migration (the --full-refresh + on_schema_change incremental contract).
- **Q4** — Oracle PL/SQL → dbt + Trino SQL migration (Oracle function rewrite + dialect divergence).

---

## Meta-commentary

This iter is the **3rd consecutive flag-to-verify save** where the teacher's pre-flag prior was tentative-but-correct ("VERIFIED PRIOR... reliable... overstatement on the responder's part") and the judge's WebFetch/WebSearch confirmed it. The teacher correctly identified the corpus inconsistency BEFORE asking the judge to adjudicate. The win pattern: hedge unverified dialect priors as "verify-first" rather than asserting, and grep the corpus for the wrong claim BEFORE classifying a responder slip as a responder defect. In this case the responder's framing slip turned out to be **resource-sourced** (lifted from r28 §1097's "FRAGILE" wording) — making it a true FIX-A, not a recall ceiling. Compare iter1238/1239/1242 where similar diagnostic flags resolved to "responder slip on accurate corpus, no FIX-A" — the diagnostic discipline correctly separates the two cases.

Carried memory references invoked: `reference_trino_unwrap_temporal_predicates.md` (the verified-accurate position on the unwrap rules), `feedback_reconcile_dont_append.md` (the in-place edit discipline), `feedback_new_card_over_attracts_adjacent.md` (don't add a new keyword card in this region), `feedback_trace_recurring_folklore_to_resource_root_cause.md` (grep corpus before classifying as recall ceiling — exactly what surfaced the §710/§1093/§1097/§1319/§3261 cluster).
