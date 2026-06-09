# Judge Feedback — iter868 (EXTENDED PHASE)

**Overall: 4.97 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.875 = 19.875 / 4 = 4.96875; margin +1.47; overall average governs, no per-Q veto)

**Federation NOT probed** — r22 §13.x row UNCHANGED (4.49944 / 310, still FAIL).

---

## Dialect verification (trino.io/docs/467, multi-source, WebFetch 2026-06-10)

- **functions/list.html**: `median` ABSENT, `percentile_cont` ABSENT, `percentile_disc` ABSENT, `approx_percentile` PRESENT. P-section lists only `approx_percentile` as percentile-related; `percent_rank` is a window fn (rank-of-row, not value-at-percentile).
- **functions/aggregate.html**: `approx_percentile` has exactly 4 overloads — `(x, percentage)`, `(x, percentages array)`, `(x, w, percentage)`, `(x, w, percentages)`; percentage in [0,1], constant. `median`/`percentile_cont`/`percentile_disc` ABSENT.
- **functions/datetime.html**: `date_format(timestamp, fmt)` uses MySQL-style specifiers (`%Y`, `%m`); `format_datetime(timestamp, fmt)` uses JodaTime patterns (`yyyy`, `MM`). DATE→VARCHAR not explicitly enumerated on the page, but ISO 'YYYY-MM-DD' is the established Trino conversion (to_iso8601 / from_iso8601_date both use YYYY-MM-DD).

**EXPLICIT: Trino 467 has NO exact-median function and NO percentile_cont / percentile_disc / median(). approx_percentile (T-Digest) is the standard median/percentile approach.** The responder's "no exact median" claim is ACCURATE.

---

## Per-question scores

### Q1 — median of a numeric column — **5.00** (Acc5 / Comp5 / Clar5 / Act5)
`approx_percentile(amount, 0.5) AS median_amount` returns the approximate median — CORRECT. Multi-percentile array form `approx_percentile(x, ARRAY[0.5,0.95,0.99])` — CORRECT (overload #2). The CLAIM "Trino has no exact median / no PERCENTILE_CONT, approx_percentile is the standard accepted choice" — VERIFIED ACCURATE vs list.html + aggregate.html. No defect.

### Q2 — custom sort order urgent→normal→low — **5.00** (Acc5 / Comp5 / Clar5 / Act5)
`ORDER BY CASE status WHEN 'urgent' THEN 1 WHEN 'normal' THEN 2 WHEN 'low' THEN 3 END` is valid Trino and sorts ascending by the mapped priority. Secondary ORDER BY for ties is a correct, helpful nuance.

### Q3 — percent of users with is_churned=true — **5.00** (Acc5 / Comp5 / Clar5 / Act5)
`SUM(CASE WHEN is_churned THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS percent_churned` — correct proportion idiom. The 100.0 decimal-division explanation is correct: all-integer division truncates; the decimal literal forces non-truncating division. Equivalent alts `count_if(is_churned)*100.0/COUNT(*)` and `AVG(CAST(is_churned AS integer))*100` (count_if verified as a 467 aggregate); omission not a ding for this question.

### Q4 — group by month, sortable 'YYYY-MM' label — **4.875** (Acc5 / Comp4.5 / Clar5 / Act5)
`substr(CAST(event_date AS varchar), 1, 7) AS month_label` with matching GROUP BY — VALID. For a DATE, CAST→VARCHAR yields ISO 'YYYY-MM-DD' so chars 1-7 = 'YYYY-MM' and string-sorts chronologically. For a TIMESTAMP, CAST→VARCHAR prefixes 'YYYY-MM-DD' so substr 1-7 still yields 'YYYY-MM'. Correct and robust.
Minor completeness ding: the intent-explicit forms `date_format(event_date,'%Y-%m')` / `format_datetime(event_date,'yyyy-MM')` were not mentioned. substr is valid but relies on the implicit ISO-string contract; a dedicated formatter would be more self-documenting. Nuance, not an error.

---

## iter869 recommendation: DEFAULT NO-OP / durability sweep — teacher ZERO edits

All 4 answers clean; no defect; no FIX-A warranted. Do NOT add a "substr is wrong / must use date_format" card — substr is valid. Optional only (if Q4 ever under-scores): a one-line cross-ref that `date_format('%Y-%m')` / `format_datetime('yyyy-MM')` are intent-explicit alternatives to the substr trick.

HOLD all iter534-866 locks (approx_percentile 4-overload family + value-vs-rank clarifier iter842/843, no-median/percentile_cont pin, per-row CAST-sum flag-count §3.1E iter866, count_if SHAPE-ROUTER, harmonic/geometric/weighted mean §3.1B family, at_timezone column-zone §Fact 3b iter857, NTILE direction §C3 iter862, GREATEST-NULL). PIN Trino 467. NO federation edits (row stays 4.49944/310, still FAIL). DO NOT bump training/state.json (already 868/passed).

Optional fresh adjacents for iter869: approx_percentile weighted overload / median 2nd phrasing ("50th percentile value") / multi-key custom CASE sort with NULLS handling / date_trunc('month') vs substr label / percent-of-total with window SUM() OVER().
