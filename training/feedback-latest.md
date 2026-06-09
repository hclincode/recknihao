# Judge Feedback — iter872

**Verdict: PASS** — overall average **4.875** (overall average governs; no per-question veto).

**Q1 DATE-coercion over-claim: CORRECTED / FIX LANDED.** The responder no longer asserts a CAST is required or that a bare DATE errors. It now explicitly states "Trino implicitly coerces DATE to TIMESTAMP(0)" and that no timestamp conversion is needed; the CAST in the example is labeled optional "for clarity." This is exactly the acceptable framing.

---

## Verification performed (all against trino.io/docs/467 + git-tag 467)

- **functions/datetime.html** — format_datetime(timestamp, format)→varchar; date_format(timestamp, format)→varchar (first arg typed `timestamp`); month() returns month-of-year (1–12).
- **git-tag 467 `io/trino/type/TypeCoercion.java`** — `coerceTypeBase` has `case StandardTypes.DATE -> switch (resultTypeBase) { case StandardTypes.TIMESTAMP -> Optional.of(createTimestampType(0)); ... }`. Confirms the implicit DATE→TIMESTAMP(0) function-argument coercion path: a bare DATE is accepted by format_datetime WITHOUT a required CAST and does NOT throw.
- **Joda DateTimeFormat (joda.org)** — 'MMMM' = full month name ('March'), 'MMM' = abbreviated ('Mar'), 'MM' = numeric. Responder's MMMM/MMM mapping correct.
- **functions/window.html** — percent_rank() = (r-1)/(n-1), first row (per ORDER BY) = 0.0; cume_dist() = rows preceding-or-peer / total.
- **WebSearch + aggregate.html** — aggregate functions usable as window functions via OVER; nested `SUM(SUM(x)) OVER ()` over a GROUP BY is the canonical grand-total pattern (inner SUM aggregates per group, outer empty-OVER window sums across all groups). Confirmed valid Trino.
- **sql/select.html** — "Maps are expanded into two columns (key, value)"; CROSS JOIN UNNEST drops empty/NULL-map rows; `LEFT JOIN UNNEST(...) ON TRUE` preserves them (and ON TRUE is the only supported LEFT JOIN condition); map_entries(map) → array(row(key,value)).

---

## Per-question scoring

### Q1 — Format a DATE as full month name; need timestamp conversion first?
| Dim | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
**Avg: 5.00.** Directly answers "no conversion needed," states the implicit DATE→TIMESTAMP(0) coercion (verified in source), MMMM/MMM correct, month() 1–12 for calendar ordering. The optional-CAST-for-clarity note is accurate and harmless. The iter871 over-claim is fully reversed.

### Q2 — Region revenue + % of grand total in one query, no join
| Dim | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 4 |
| Actionability | 5 |
**Avg: 4.75.** `ROUND(100.0 * SUM(monthly_revenue) / SUM(SUM(monthly_revenue)) OVER (), 1)` is correct: inner SUM aggregates per region, outer empty-OVER window sums across all grouped rows = grand total; 100.0 forces float division. Minor clarity ding only: a one-line note on *why* the doubled SUM is legal (window over the post-GROUP-BY aggregate) would help a beginner; the mechanics are otherwise sound.

### Q3 — Categorize deals by percentile position (top 10% / bottom 25%)
| Dim | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
**Avg: 5.00.** percent_rank() in a CTE, CASE thresholds, and the DESC orientation explanation (0.0 = highest, so top 10% = <=0.10; bottom 10% = >=0.90; flip if ASC) are all correct per window.html. cume_dist is a valid alternative but optional — completeness nuance only, not docked.

### Q4 — Explode a MAP into one row per key-value pair
| Dim | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
**Avg: 5.00.** `CROSS JOIN UNNEST(metadata) AS t(metadata_key, metadata_value)` (two aliases for the map's key/value) is correct; the empty/NULL-map drop vs `LEFT JOIN UNNEST(...) ON TRUE` preservation is correct and well-flagged; the `map_entries(metadata)` → `t(entry)` with entry.key/entry.value alternative is also correct.

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.00 |
| Q2 | 4.75 |
| Q3 | 5.00 |
| Q4 | 5.00 |
**Overall average: 4.875 — PASS.**

No defects. All four dialect-fact families verified against authoritative sources. No federation probed this iteration — the 4.49944/310 row is UNCHANGED.

## iter873 recommendation: **DEFAULT NO-OP**

All answers clean; the iter872 DATE-coercion FIX-A held on re-probe (Q1 no longer claims CAST-required). No new defect surfaced. Continue durability sweeps with fresh adjacent probes. No FIX-A needed; no escalation.
