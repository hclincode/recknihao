# iter802 Judge Feedback — DEFAULT NO-OP / durability-breadth sweep

**Date:** 2026-06-09
**Teacher edits this iteration:** ZERO (expected — durability-breadth sweep). Four fresh adjacent probes over well-covered window/aggregate/map fundamentals.
**Verification:** Every dialect claim verified against trino.io/docs/467 (functions/aggregate.html, functions/window.html, sql/select.html) via WebSearch/WebFetch — not relying on resources/ as ground truth.

---

## Per-question scores

### Q1 — approx_distinct for daily unique visitors (~2% error ok)
- **Accuracy: 5** — `approx_distinct(visitor_id)` uses HyperLogLog; default standard error 2.3% (docs: "should produce a standard error of 2.3%"). approx_distinct(x,e) for custom error (e in [0.0040625, 0.26]). "~2.3% default" matches the ~2% tolerance ask. Verified.
- **Completeness: 5** — Covers the GROUP BY event_date shape, cheaper-than-COUNT(DISTINCT) rationale, the daily-HLL-sketch pre-agg note for rolling windows, and the do-not-use-for-billing caveat.
- **Clarity: 5** — Plainly maps "approximate" → "~2% error" and explains why it's cheaper. No unexplained jargon.
- **Actionability: 5** — Drop-in query; engineer knows exactly what to run.
- **Q1 avg: 5.00**

### Q2 — FIRST_VALUE landing_page repeated on every user row
- **Accuracy: 5** — `FIRST_VALUE(page) OVER (PARTITION BY user_id ORDER BY event_time ASC)`. CRITICAL nuance handled correctly: the default frame for an ORDER BY window is RANGE UNBOUNDED PRECEDING (= BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW); frame start = UNBOUNDED PRECEDING, so FIRST_VALUE returns the partition's first row on every row. Verified against docs ("contains all rows from the start of the partition up to the last peer of the current row"). The responder's default-frame claim is accurate. (Note: it correctly did NOT need the LAST_VALUE-default-frame trap here.)
- **Completeness: 5** — Explains the carry-onto-every-row behavior and why the default frame yields the first row.
- **Clarity: 5** — "first page per user, repeated on every row" framed clearly.
- **Actionability: 5** — Drop-in.
- **Q2 avg: 5.00**

### Q3 — UNNEST native MAP into one row per (key, value)
- **Accuracy: 5** — `CROSS JOIN UNNEST(attributes) AS t(key_name, key_value)`. Verified against docs: "Maps are expanded into two columns (key, value)" → TWO aliases required; a single alias is an error. `LEFT JOIN UNNEST(...) ON TRUE` to retain rows with empty/NULL map — correct.
- **Completeness: 5** — Two-alias requirement, single-alias-error warning, and the LEFT JOIN ON TRUE preservation pattern all covered.
- **Clarity: 5** — "maps expand to TWO columns so TWO aliases" is unambiguous.
- **Actionability: 5** — Drop-in.
- **Q3 avg: 5.00**

### Q4 — NTILE(4) quartiles by lifetime_spend
- **Accuracy: 5** — `NTILE(4) OVER (ORDER BY lifetime_spend ASC)`. Verified: ntile divides BY ROW COUNT (not value ranges); remainder distributed one-per-bucket starting at the first bucket → 101 rows = 26,26,25,24 (first buckets get the extra). Matches docs exactly. NULLS LAST default → NULL spend lands in the top (4th) quartile for ASC; filter-first advice correct. Window-runs-after-WHERE → can't filter NTILE in same WHERE → subquery wrap — correct. ASC → quartile 1 = lowest spenders mapping confirmed.
- **Completeness: 5** — by-count-not-value, leftover distribution, NULL handling, and window-after-WHERE subquery nuance all present.
- **Clarity: 5** — "roughly equal-sized buckets" → row-count division explained with the concrete 101-row split.
- **Actionability: 5** — Drop-in plus the subquery-wrap gotcha.
- **Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg: 5.00 — PASS** (threshold 3.5; overall average governs, no single-Q veto).

---

## Teacher feedback

No defects found. All four answers are dialect-accurate against Trino 467, fit the prod stack (Trino 467 + Iceberg + Hive Metastore on-prem), and carry the right gotchas (HLL not-for-billing, FIRST_VALUE default frame = UNBOUNDED PRECEDING, UNNEST-map-2-aliases, NTILE by-count + window-after-WHERE subquery wrap). No resource edits warranted. All standing pins (approx_distinct-HLL / first_value-default-frame-UNBOUNDED-PRECEDING / UNNEST-map-2-aliases / NTILE-by-count-window-after-WHERE) reconfirmed.

**iter803 designation: DEFAULT NO-OP / durability-breadth sweep.** No open defect — continue fresh adjacent probing over window/aggregate/map/array fundamentals. Suggested fresh angles for iter803: LAST_VALUE default-frame trap (the contrast Q2 deliberately avoided — confirm responder knows it needs an explicit `ROWS/RANGE BETWEEN ... UNBOUNDED FOLLOWING` frame to get the partition's actual last value), LEAD/LAG with default/offset, percent_rank vs cume_dist, or array_agg ORDER BY collapse-to-array. No FIX-A required.
