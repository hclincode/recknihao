# Judge Feedback — iter1004

**Phase:** extended (durability-breadth sweep). Verified BOTH directions vs trino.io/docs/467 + RAW git-tag 467 source (functions/map.md, functions/window.md, functions/math.md, functions/datetime.md, functions/aggregate.md) — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 Qs fit; no federation drag-in; no auth angle.

## Per-question scores

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 month-over-month new-signup growth + pct change | 5.0 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q2 bucket price_cents into labeled UI ranges | 5.0 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q3 pull utm_source key out of MAP | 5.0 | 4.75 | 4.875 | 4.875 | 4.875 |
| Q4 does AVG skip NULLs or must COALESCE | 5.0 | 4.625 | 4.75 | 4.875 | 4.8125 |

**Overall = (5.0+4.75+4.75+4.75 + 5.0+4.75+4.75+4.75 + 5.0+4.75+4.875+4.875 + 5.0+4.625+4.75+4.875) / 16 = 76.5/16 = 4.7813**

## PASS — overall average 4.7813 (>= 3.5; margin +1.281). OVERALL AVERAGE governs, no per-Q veto.

## Q3 element_at-vs-subscript verdict (REQUIRED)

**Responder is FULLY CORRECT on BOTH halves.** Verified against RAW git-tag 467 source `docs/src/main/sphinx/functions/map.md`:
- (a) `element_at(map, key)` — "Returns value for given `key`, or `NULL` if the key is not contained in the map." → returns NULL on missing key. CONFIRMED.
- (b) Subscript `map[key]` — "This operator throws an error if the key is not contained in the map." → THROWS on absent key. CONFIRMED.

So the responder's guidance ("use element_at, it returns NULL if key absent; DO NOT use metadata['utm_source'] subscript because it ERRORS if the key is missing; element_at is NULL-safe") is exactly right, including the WHERE element_at(...) IS NOT NULL filter and the "MAP is a true key-value type not a JSON string" framing. CLEAN, no defect.

## `::` cast check (REQUIRED)

**`::` did NOT appear in any of the 4 answers.** All casts/arithmetic use proper Trino forms (ROUND(100.0*..., 2), integer literals, element_at, AVG/COUNT). The iter1003 Q1 PostgreSQL `::` slip did NOT recur. No 2-in-2; the `::`-ban double-lock (r23 §3.1C + r27 §4.4A) holds and was not exercised this iter.

## Other dialect verifications (all CLEAN)

- Q1: `DATE_TRUNC('month', created_date)` on a DATE column is valid — date_trunc returns same type as input (DATE in, DATE out); `month` is a supported unit (millisecond..year). `LAG(x) OVER (ORDER BY ...)` valid, default offset 1, returns NULL outside partition; repeated LAG inside CASE is valid (analyzer recognizes the identical window expression). `COUNT(DISTINCT user_id)` is single-arg — VALID (the COUNT(DISTINCT a,b) multi-arg parse-error trap is NOT triggered). `ROUND(x, 2)` and `100.0` DECIMAL literal correct; CASE guard avoids divide-by-NULL.
- Q2: CASE/WHEN ascending-threshold bucketing valid; first-match-wins ordering correct; ELSE catch-all correct. `width_bucket(x, bound1, bound2, n)` and `width_bucket(x, bins)` both exist in 467 — responder correctly scoped it to regular-interval bins and chose CASE for the irregular labeled ranges. price_cents/100 framing (100 cents = $1) correct.
- Q4: AVG ignores NULL — verified (aggregate.md: aggregates "ignore null values" except count/count_if/max_by/min_by/approx_distinct; avg NOT in that list). `COUNT(col)` = non-null count, `COUNT(*)` = all rows — correct; the COUNT(*)>COUNT(col) diagnostic to reveal NULL rows is apt. The (10,20,30)+2 NULLs → AVG=20 not 12 example is correct.

## TICS — ALL CLEAN

No QUALIFY / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn (date_trunc/lag/count/avg/element_at/width_bucket ALL real & verified) / regex-backslash (no regex Q) / GREATEST-LEAST-NULL / date-minus-integer / `::`-cast (ABSENT — did NOT recur) / broken-secondary-false-justification (Q2 width_bucket aside accurate+correctly-scoped, Q4 diagnostic accurate — neither is a broken alt) / mid-churn / column-scope / ILIKE-conflation / INTERVAL-quarter-week / MAP-subscript-vs-element_at (Q3 CORRECT both halves).

## Recommendation — DEFAULT NO-OP

Margin +1.281; all 4 deliverables correct & verified both directions; zero tics; zero fabricated functions; the targeted Q3 element_at-vs-subscript check resolved CORRECT both halves; `::` did NOT recur (iter1003 slip confirmed a per-instance one-off, no 2-in-2). No findable resource gap, no resource defect, no 2-in-2 recurrence. **No resource edit; no FIX-A.**

Re-probe watch next sweep:
- (a) `::`-cast shorthand — iter1003 was the FIRST occurrence; iter1004 CLEAN. Stays a per-instance one-off (ban double-locked); only a 2-in-2 recurrence would warrant a LIGHT findability nudge.
- (b) another MAP-extraction Q — confirm element_at-NULL-safe-vs-subscript-throws lead holds; watch for the INVERSE slip (wrongly claiming subscript is NULL-safe).
- (c) another date-bucket + window Q (date_trunc/LAG/LEAD over monthly aggregate) — confirm date_trunc-returns-DATE + LAG-default-NULL + CASE-divide-by-NULL guard stays sharp.
- (d) another labeled-binning Q — confirm CASE-for-irregular vs width_bucket-for-regular-interval distinction.
- (e) another AVG/aggregate-NULL Q — confirm "aggregates skip NULL, COUNT/count_if are the exceptions" framing.

Federation r22 §13.x hard-locked, NOT probed (stays 4.49944/310). MUST NOT bump training/state.json (already 1004; passed=true; final_iterations_remaining 0; orchestrator commits).
