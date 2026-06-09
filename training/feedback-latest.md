# Judge Feedback — iter799 (ADDITIVE FINDABILITY FIX-A: explode-JSON-array-STRING re-probe + 3 fresh)

**Verdict: overall avg 4.84 — PASS** (threshold 3.5; overall average governs, no single-Q veto).
All dialect claims verified against trino.io/docs/467 (json / array / datetime / select .html) via WebFetch on 2026-06-09.

FIX-A context: iter798 Q3 used bare `UNNEST(varchar)` on a JSON-array-string column (type error). iter799 teacher added a native-vs-JSON-string disambiguator + `UNNEST(CAST(json_parse(...) AS ARRAY(VARCHAR)))` canonical at r07 §1a (lines 70-101, with a DO-NOT-COPY defang of the bare-`UNNEST(varchar)` form). Q1 re-probes it.

---

## Per-question scores

### Q1 — explode a JSON-array-STRING (varchar) column into one row per element — avg **5.00 PASS**
- Accuracy **5** · Completeness **5** · Clarity **5** · Actionability **5**
- Answer: `CROSS JOIN UNNEST(CAST(json_parse(roles_json) AS ARRAY(VARCHAR))) AS t(role)`; `json_parse` string->json, CAST json->array, UNNEST array->rows; `LEFT JOIN UNNEST(...) ON TRUE` to keep NULL/empty parents. Cites new r07 card (lines 70-101).
- **FIX CONFIRMED — explode-JSON-array-STRING CLOSED (1st clean post-fix datapoint).** The responder NOW LEADS with `json_parse`+`CAST`+`UNNEST` and did NOT emit the iter798 bare `UNNEST(varchar)` type error. Verified vs functions/json.html: `json_parse(string) -> json` ("Returns the JSON value deserialized from the input JSON text"); `CAST(json AS ARRAY(VARCHAR))` valid for a homogeneous string array. Verified vs sql/select.html: UNNEST requires an ARRAY/MAP — a varchar cannot be unnested, so the parse-first step is exactly what makes this compile. The LEFT-JOIN-ON-TRUE parent-preservation nuance is correct. Clean.

### Q2 — convert event_time (UTC) to 'America/New_York' incl. DST — avg **4.81 PASS**
- Accuracy **5** · Completeness **4.75** · Clarity **5** · Actionability **4.5**
- Answer: `event_time AT TIME ZONE 'America/New_York' AS event_time_eastern`; DST handled automatically; group via `date_trunc('day', event_time AT TIME ZONE 'America/New_York')`; IANA zone names. Cites r07.
- Verified vs functions/datetime.html: `AT TIME ZONE` "sets the time zone of a timestamp"; the doc example (`'2012-10-31 01:00 UTC' AT TIME ZONE 'America/Los_Angeles'` -> `2012-10-30 18:00`) shows it re-renders the SAME instant in the named IANA zone; IANA identifiers inherently carry DST rules, so DST is correct. For a UTC-normalized Iceberg `timestamp(p) with time zone` (the prod stack) the responder's usage is correct. Minor un-penalized nuance: if `event_time` were a plain `timestamp WITHOUT time zone`, `AT TIME ZONE` interprets it as being IN that zone rather than converting — not the prod case, and the responder's UTC-timestamptz assumption matches Iceberg ingestion; a one-line caveat about the without-tz case would have earned the last half-point. Solid.

### Q3 — subtotals + grand total (per region,product / per-region / one grand total) in one query — avg **4.94 PASS**
- Accuracy **5** · Completeness **5** · Clarity **4.75** · Actionability **5**
- Answer: `GROUP BY ROLLUP(region, product)`, `SUM(amount)`, label via `CASE GROUPING(region, product) WHEN 0 THEN 'Detail' WHEN 1 THEN 'Region Total' WHEN 3 THEN 'Grand Total' END`, `ORDER BY GROUPING(...), region NULLS LAST, product NULLS LAST`. Notes `ROLLUP(a,b) = GROUPING SETS ((a,b),(a),())` and "ROLLUP takes COLUMN NAMES only not expressions (pre-compute in a CTE)". Cites r28.
- Verified vs sql/select.html: ROLLUP generates subtotals; `ROLLUP(region,product)` = grouping sets `((region,product),(region),())` = detail + per-region subtotal + grand total. **GROUPING bitmask verified**: "a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise" -> bit=1 means rolled up; leftmost arg = higher-order bit. So Detail (both present)=0b00=0; region subtotal (product rolled up)=0b01=1; grand total (both rolled up)=0b11=3. The responder's WHEN 0/1/3 mapping is exactly right. The "ROLLUP takes column names only, not expressions" pin is correct (pre-compute derived grouping keys in a CTE). Tiny clarity ding only: the bitmask reasoning (why 1 and 3, not 2) is asserted rather than shown; otherwise textbook. Strong.

### Q4 — filter a NATIVE integer array per row, keep scores >= 60 — avg **4.63 PASS**
- Accuracy **5** · Completeness **4.5** · Clarity **5** · Actionability **4.0**
- Answer: `filter(scores, s -> s >= 60) AS passing_scores`; higher-order `filter` keeps elements where the lambda is true, array-in/array-out, no row explosion; `array_remove(scores, 40)` for exact-value removal. Cites r07.
- Verified vs functions/array.html: `filter(array(T), function(T,boolean)) -> array(T)` "Constructs an array from those elements of array for which function returns true" -> `filter(scores, s -> s >= 60)` on `ARRAY[55,90,72,40]` yields `ARRAY[90,72]`. Correct, array-in/array-out, no UNNEST/no row explosion. `array_remove(x, element)` "Remove all elements that equal element" is valid for the exact-value variant. Matches the higher-order-filter pin. Minor actionability ding: the answer does not contrast `filter` (keep-in-place, array out) vs `UNNEST + WHERE + array_agg` (explode/refilter/recollect) — a one-liner on when each is appropriate would have rounded it out, but for the question as asked `filter` is the right and most direct tool.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 explode-JSON-array-string | 5 | 5 | 5 | 5 | **5.00** |
| Q2 AT TIME ZONE named tz | 5 | 4.75 | 5 | 4.5 | **4.81** |
| Q3 ROLLUP + GROUPING bitmask | 5 | 5 | 4.75 | 5 | **4.94** |
| Q4 filter native array | 5 | 4.5 | 5 | 4.0 | **4.63** |

**Overall avg = (5.00 + 4.81 + 4.94 + 4.63) / 4 = 4.845 -> 4.84 — PASS.**

---

## Teacher feedback

**(a) Is explode-JSON-array-STRING CLOSED?** YES — Q1 fix WORKED (1st clean post-fix datapoint). The responder led with `UNNEST(CAST(json_parse(col) AS ARRAY(VARCHAR)))`, did NOT recur the iter798 bare-`UNNEST(varchar)` type error, and cited the new r07 §1a card. The native-vs-JSON-string disambiguator + DO-NOT-COPY defang at r07:70-101 routed correctly. Needs ONE more phrasing (e.g. a NUMERIC JSON-array-string `'[10,20,30]'` -> `CAST(json_parse(col) AS ARRAY(BIGINT))`, or a "tags stored as JSON text" wording) to move from CLOSED -> BULLETPROOFED.

**(b) iter800 designation: DEFAULT NO-OP / durability-breadth sweep.** No open defect surfaced this iteration — all 4 clean on-pin and docs-verified. Teacher should make ZERO edits. Suggested iter800 probes:
- 1 fresh explode-JSON-array-STRING re-probe with a NUMERIC array string (`ARRAY(BIGINT)` branch) to bank the 2nd post-fix datapoint and bulletproof.
- Fresh adjacent: `AT TIME ZONE` with a plain `timestamp WITHOUT time zone` source (the without-tz interpret-not-convert nuance from Q2) / `transform(array, lambda)` map-over-array (sibling to `filter`) / `GROUPING SETS` explicit form vs `CUBE` (sibling to ROLLUP).

**PRESERVE (verified clean, churn risk):** r07 §1a native-vs-JSON-string explode card + disambiguator + DO-NOT-COPY defang (lines 70-101, drove the Q1 fix); r07/r28 ROLLUP+GROUPING-bitmask card; r07 `AT TIME ZONE` card; r07 higher-order `filter`/`array_remove` card. Do not append or churn these.

**Standing pins all held:** UNNEST-needs-array (json_parse+CAST for JSON-string), AT-TIME-ZONE-named-IANA-tz-DST-aware, ROLLUP-GROUPING-bitmask (1=rolled-up, leftmost=high bit, column-names-only), higher-order-filter-lambda-array-in-array-out.
