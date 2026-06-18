# Judge Feedback — iter1050

**Phase:** extended (state.json phase="extended", passed=true). Overall-average governs; no per-question veto.
**Verification:** BOTH directions vs RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/...), NOT resources/.

Production fit (prod_info.md): Trino 467 + Iceberg connector, on-prem. None of the 4 questions touch auth/authz or platform-specific constraints; all are pure ANSI-ish Trino SQL analytics. No production-fit concerns.

---

## Q1 — Monthly revenue with prior month + percent change (LAG over pre-aggregated subquery)

**Scores:** Accuracy 4.9 / Completeness 4.6 / Clarity 4.8 / Actionability 4.9 → **4.8**

The answer pre-aggregates monthly revenue in a SUBQUERY (`SELECT DATE_TRUNC('month',order_date) AS month, SUM(amount) AS revenue ... GROUP BY DATE_TRUNC('month',order_date)`), then in the outer query applies `LAG(revenue) OVER (ORDER BY month)`. Because `revenue` is a **plain column of the subquery** by the time the window runs, `LAG(revenue)` is a SINGLE, non-nested window function. This is correct and runnable.

**WATCH (v) — nested-window-LAG-over-SUM-OVER — DID NOT RECUR.** The iter1049 broken lead was `LAG(SUM(amount) OVER(PARTITION BY...)) OVER(...)` — a window function passed as an argument to another window function ("cannot nest window functions"). The iter1050 answer is the clean canonical shape: subquery-then-LAG. No nesting present. The broken lead did NOT recur.

- LAG signature `lag(x[, offset[, default]])` accepts a plain column reference — VERIFIED (functions/window.md, RAW 467).
- `DATE_TRUNC('month', ...)` + `SUM ... GROUP BY DATE_TRUNC(...)` correct; outer `ORDER BY month` correct.
- The CASE guards `LAG(...) IS NOT NULL` (first-month NULL) — correct for the NULL case.

**Minor completeness ding only:** division by a *zero* prior month would still throw (integer/DECIMAL `/0` throws DIVISION_BY_ZERO in Trino; the IS NOT NULL guard does not cover prev=0). `NULLIF(LAG(revenue) OVER (...), 0)` in the denominator would be more robust. Revenue is rarely exactly 0, so this is a minor robustness note, not a defect.

The note "can't reference a SELECT alias inside a window function" is loosely worded but directionally true (you can't reference a same-level SELECT alias inside the window expression — hence the subquery). Acceptable.

---

## Q2 — TEXT price strings ('19.99') → numeric SUM

**Scores:** Accuracy 4.9 / Completeness 4.5 / Clarity 4.8 / Actionability 4.9 → **4.775**

`SUM(CAST(amount AS DECIMAL(10,2))) AS total_revenue FROM prices`. Correct.

- Trino has **NO implicit varchar↔numeric coercion** — VERIFIED (functions/conversion.md, RAW 467: "Trino will not implicitly convert between character and numeric types"). The bare `SUM(amount)` on a varchar therefore errors; explicit CAST is required. Responder's reasoning is correct.
- `CAST(varchar AS DECIMAL(10,2))` for '19.99'/'149.00' is exact (DECIMAL avoids float drift) — sound choice over DOUBLE.
- `SUM(DECIMAL(10,2))` widens result to `DECIMAL(38,2)` — established Trino decimal-aggregation semantics; responder's stated widening is correct.

**Minor completeness note (optional):** real CSV-ingested TEXT often has dirty rows (empty strings, '$', commas, 'N/A'); `CAST` THROWS on bad input, so `SUM(TRY_CAST(amount AS DECIMAL(10,2)))` (returns NULL on bad rows, skipped by SUM) is the robustness upgrade. `TRY_CAST` confirmed (functions/conversion.md: "Like cast, but returns null if the cast fails"). Not raised by the responder; optional, minor.

---

## Q3 — sessions.tags array contains BOTH 'mobile' AND 'paid'

**Scores:** Accuracy 5.0 / Completeness 4.8 / Clarity 4.7 / Actionability 4.9 → **4.85**

Two valid forms offered, both correct for the "all of a required set present" (subset) test:

1. `cardinality(array_except(ARRAY['mobile','paid'], tags)) = 0` — required-set MINUS tags is empty ⇒ every required element is in tags. VERIFIED: `array_except(x,y)` returns elements in x not in y, deduplicated (functions/array.md, RAW 467). Correct subset test.
2. `all_match(ARRAY['mobile','paid'], x -> contains(tags, x))` — every required element is contained in tags. VERIFIED: `all_match(array, fn)` returns true iff all elements match the predicate (empty array → true, vacuous); `contains(x, element)` is membership test (functions/array.md, RAW 467). Correct.

Both are accurate. The simplest form `contains(tags,'mobile') AND contains(tags,'paid')` would be slightly more beginner-readable, but the given forms are correct and generalize to larger required sets — a reasonable trade. No defect.

---

## Q4 — events.properties MAP: count frequency of each KEY, keys unknown in advance

**Scores:** Accuracy 4.9 / Completeness 4.8 / Clarity 4.0 / Actionability 4.8 → **4.625**

**Final delivered SQL is CORRECT:**
`SELECT key, COUNT(*) AS frequency FROM events CROSS JOIN UNNEST(properties) AS t(key, value) GROUP BY key ORDER BY frequency DESC`

- `histogram(properties)` over a MAP column was correctly ABANDONED — `histogram(x)` returns a map of value→count and over a MAP column does not yield per-key frequency. Right call to drop it.
- `UNNEST(map)` yields TWO columns `(key, value)` — VERIFIED (sql/select.md, RAW 467: "Maps are expanded into two columns (key, value)" with the map_from_entries example).
- `GROUP BY key, COUNT(*)` gives per-key occurrence count across all events — correct, and works without knowing keys in advance.
- The note that `CROSS JOIN UNNEST` DROPS rows with null/empty maps while `LEFT JOIN UNNEST ... ON TRUE` KEEPS them is correct and a genuinely useful nuance — VERIFIED (sql/select.md, RAW 467: ON TRUE is the only supported condition; LEFT JOIN preserves parent rows).

**WATCH (c) — "Wait —" self-correction (sloppy-illustrative).** The answer showed `histogram(properties)` first, then mid-stream wrote "Wait — that returns a map of the entire column" before landing on the correct UNNEST query. The delivered SQL is right, but the visible self-correction is a presentation artifact (the responder "thinking out loud" in the final answer). This is a **clarity ding only**, not a correctness defect. Per-instance monitor — same family as prior sloppy-illustrative artifacts; not a resource defect.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Q-avg |
|---|---|---|---|---|---|
| Q1 | 4.9 | 4.6 | 4.8 | 4.9 | 4.800 |
| Q2 | 4.9 | 4.5 | 4.8 | 4.9 | 4.775 |
| Q3 | 5.0 | 4.8 | 4.7 | 4.9 | 4.850 |
| Q4 | 4.9 | 4.8 | 4.0 | 4.8 | 4.625 |

**Overall average = (4.800 + 4.775 + 4.850 + 4.625) / 4 = 4.7625 → PASS** (threshold 3.5; margin +1.26).

---

## Recommendation — DEFAULT NO-OP (no resource edit, no commit)

1. **Q1 watch (v) — nested-window LAG-over-SUM-OVER: did NOT recur.** The iter1050 answer used the clean subquery-then-LAG canonical (LAG over a plain pre-aggregated column, no window nesting). One clean re-probe after the iter1049 single slip. Since iter1049 was classified as a per-instance responder slip (not 2-in-2) and the very next re-probe is clean, **DOWNGRADE/CLOSE watch (v)** — treat as a passive monitor. r07's CTE-then-LAG + nested SUM(SUM) OVER guards are intact; no FIX-A warranted.

2. **Q4 "Wait —" self-correction (watch c):** clarity-only ding; final query correct. Keep as **per-instance passive monitor**. No resource fix (no single resource change addresses responder think-aloud padding; same family as broken-secondary / illustrative-artifact slips — re-probe-don't-churn).

3. No `::` cast, no QUALIFY, no false semi-join, no fabricated function, no regex-backslash, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no over-warning folklore across all 4. Strong, durable sweep.

**No resource edit. No commit. Do NOT bump state.json (already 1050).**
