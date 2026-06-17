# Judge Feedback — iter1034

**Overall: Q1 4.625 / Q2 4.5 / Q3 4.8125 / Q4 4.75 → 4.671875 PASS** (margin +1.171875; overall average governs, no per-Q veto). Verified BOTH directions vs RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/...), NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO + Hive Metastore) — all 4 fit; no federation/auth angle, federation hard-locked NOT probed.

---

## Q1 — approx_percentile ARRAY p50/p90/p99 per service, one call vs three — **4.625**

Verified `functions/aggregate.md` (RAW 467): approx_percentile has **4 overloads**, including the ARRAY form
`approx_percentile(x, percentages) -> array<[same as x]>` — accepts an array of percentages and returns an array of values. EXISTS and returns an array. CORRECT.

- `approx_percentile(response_time_ms, ARRAY[0.5, 0.9, 0.99])` → array of 3 percentiles in input order — CORRECT.
- Arrays in Trino are **1-based**, so unpacking `pcts[1]` p50 / `pcts[2]` p90 / `pcts[3]` p99 is **CORRECT** SQL.
- `current_date - INTERVAL '7' DAY` is valid date arithmetic — CORRECT.
- "One sketch, far faster than 3 separate calls" — CORRECT (single T-Digest pass vs three).
- GROUP BY service_name + WHERE event_ts >= ... for past week — CORRECT and partition-pruning-friendly.

**Prose 0-based slip (assessed):** the explanatory prose says "call them p[0], p[1], p[2]" (0-based) while the actual SQL correctly uses `pcts[1]/[2]/[3]` (1-based). This is a **self-contradictory prose aside sitting next to CORRECT SQL** — the copyable SQL is right. Severity = **minor CLARITY ding only, NOT an accuracy defect**: the engineer who copies the SQL gets the right answer; only the narration is internally inconsistent. Acc 5 / Comp 4.75 / Clar 4.0 / App 4.75 → **4.625**.

## Q2 — rank customers, ties share rank WITHOUT gaps; user's example "three tied 2nd → next 4th" — **4.5**

Verified `functions/window.md` (RAW 467): **RANK** "tie values in the ordering will produce gaps in the sequence"; **DENSE_RANK** "tie values do not produce gaps in the sequence." Responder's stated behaviors (RANK: tied-2nd → next 5; DENSE_RANK: tied-2nd → next 3) are **EXACTLY correct**.

**Question-intent call (assessed):** The user's requirement is **internally inconsistent** — "WITHOUT leaving gaps" = DENSE_RANK, but the example "three tied 2nd → next 4th" matches NEITHER RANK(=5) NOR DENSE_RANK(=3). No Trino window function yields the muddled example. Choosing **DENSE_RANK** (honoring the EXPLICIT "without gaps" requirement) AND clearly explaining BOTH behaviors so the user can self-diagnose their contradiction is a **sound, defensible answer**. The user's muddled example is NOT ground truth and is correctly not treated as such. This should NOT be penalized heavily.

- `DENSE_RANK() OVER (ORDER BY SUM(order_amount) DESC)` with GROUP BY customer_id — CORRECT (aggregate inside window over grouped rows is valid in Trino).
- `WHERE date_trunc('month',created_at)=date_trunc('month',current_date)` for "this month" — CORRECT.

Minor App ding: could have flagged the user's example contradiction even more explicitly ("your example matches neither — confirm which you want"); the engineer still must reconcile their own contradictory spec. Acc 5 / Comp 4.5 / Clar 4.5 / App 4.0 → **4.5**.

## Q3 — per-region subtotals + grand total in ONE query, no UNION — **4.8125**

Verified `sql/select.md` (RAW 467): `GROUP BY ROLLUP(x)` single column ≡ `GROUPING SETS ((x), ())` — detail + grand total. GROUPING: "a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise" → detail row GROUPING(region)=0, grand-total row GROUPING(region)=1. Responder's mapping is **EXACT**.

- `GROUP BY ROLLUP(region)` → detail + grand total, no UNION — CORRECT.
- `CASE GROUPING(region) WHEN 0 THEN 'Region Detail' WHEN 1 THEN 'Grand Total'` — labels CORRECT.
- `ORDER BY CASE WHEN GROUPING(region)=1 THEN 1 ELSE 0 END, region` — pushes grand total to the bottom, details sorted by region — CORRECT and clean.

Fully correct both directions. Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75 → **4.8125**.

## Q4 — YoY monthly revenue 2024 vs 2023 side-by-side per row — **4.75**

Verified `functions/datetime.md` (RAW 467): `date_add('month', -12, ts)` — "Subtraction can be performed by using a negative value" — subtracts 12 months, CORRECT. EXTRACT(YEAR/MONTH FROM timestamp) → bigint, both valid.

- Self-join of two identical monthly-aggregate subqueries — CORRECT approach for pulling prior-year into the same row.
- Join `ON date_add('month',-12,cur.month_start)=prev.month_start` — **fully anchors same-month-prior-year**; the additional `EXTRACT(MONTH FROM cur)=EXTRACT(MONTH FROM prev)` equality is **redundant but harmless** (not a defect; both conditions hold simultaneously).
- `WHERE cur year=2024` filters output to 2024 rows with 2023 matched — CORRECT.
- Output month_num, revenue_2024, revenue_2023, `yoy_growth_pct = ROUND((cur-prev)*100.0/NULLIF(prev,0),2)` — NULLIF(prev,0) guards divide-by-zero, CORRECT. (INTEGER/DECIMAL `/` by zero throws in Trino; NULLIF correctly avoids it.)

Produces 2024 vs 2023 side by side correctly. Minor App ding: a self-join is slightly heavier than single-pass conditional aggregation (SUM(CASE WHEN year=2024...)) — but the self-join is correct and readable, not a defect. Acc 5 / Comp 4.75 / Clar 4.75 / App 4.5 → **4.75**.

---

## TICS scan
`::` cast ABSENT all 4. No QUALIFY, no false semi-join, no fabricated function (approx_percentile / RANK / DENSE_RANK / ROLLUP / GROUPING / date_add / EXTRACT all real & verified), no regex-backslash, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no broken-secondary, no over-warning folklore. All SQL is valid Trino 467 dialect.

## Source-verified defect
**NONE.** Q1 prose 0-based slip is a self-contradictory narration aside next to CORRECT 1-based SQL → minor clarity ding, NOT an accuracy defect, NOT a findable resource gap, 1st-occurrence. No 2-in-2 same-shape recurrence.

## Recommendation — DEFAULT NO-OP
Margin +1.171875; all 4 PASS; both KEY question-intent calls (Q1 array-overload + 1-based indexing, Q2 DENSE_RANK on contradictory spec) resolved in the responder's favor; Q3 GROUPING bitmask and Q4 self-join YoY both fully correct & source-verified. No source-verified resource defect, no 2-consecutive same-shape slip → **NO resource edit; NO FIX-A; NO git commit.** MUST NOT bump state.json (already 1034; orchestrator commits).

**Monitor only (no action):**
- (a) approx_percentile ARRAY overload + 1-based array indexing — watch for 0-based prose/SQL relapse; if the SQL itself goes 0-based that IS a defect.
- (b) RANK gaps vs DENSE_RANK no-gaps when user spec is self-contradictory — confirm responder keeps explaining both.
- (c) ROLLUP single-col GROUPING 0=detail/1=grand-total mapping.
- (d) self-join / conditional-aggregation YoY same-month-prior-year via date_add('month',-12,...).

Federation r22 §13.x hard-locked NOT probed (4.49944/310).
