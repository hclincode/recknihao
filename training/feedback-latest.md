# Judge Feedback — Iter 629 (EXTENDED PHASE)

**Overall: 4.875 STRONG PASS** (margin +1.375 above 3.5 floor) — Trino pinned 467, docs verified live today (2026-06-07) — FEDERATION NOT PROBED (4.49944/310 row UNCHANGED).

**HEADLINE:** Two inoculations held cleanly under fresh phrasing. Q2 QUALIFY trap CORRECTLY retracted (responder recognized Trino has no QUALIFY and replaced with MIN/MAX). Q4 PERCENTILE_CONT/MEDIAN inoculation HELD (used approx_percentile). All four final answers valid Trino 467 and correct. The only soft spot is Q1: the MAX(CASE..1/0) form is correct and the BOOLEAN cast is offered, but the cleaner Trino-native `bool_or()` (which the question's "true/false" phrasing points at, and which exists as a canonical at r23:682) was not led with — a minor landing-point nuance, NOT a defect.

---

## Per-question scores

### Q1 — true/false per user for "has EVER upgraded to a paid plan" (has-ever-done-X)
**Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 = 4.75 PASS**

Answer: `MAX(CASE WHEN event_name = 'plan_upgraded' THEN 1 ELSE 0 END) AS has_ever_upgraded ... GROUP BY user_id`; noted returns 1 if any row matches, CAST AS BOOLEAN optional.

- VERIFIED trino.io/docs/467/functions/aggregate.html: `max(x)` "Returns the maximum value of all input values." Over a per-user group, `MAX(CASE WHEN cond THEN 1 ELSE 0 END)` returns 1 iff at least one row satisfies the predicate, else 0 — correct has-ever-done-X semantics. Valid Trino 467 (CASE expression inside an aggregate is standard).
- The CAST AS BOOLEAN note is accurate: `CAST(1 AS BOOLEAN)` → true, `CAST(0 AS BOOLEAN)` → false in Trino, so the offered cast does produce a real boolean.
- **Completeness ding (-1):** the question asks for a "true/false column." MAX(CASE..1/0) returns 1/0 (boolean only via the optional cast). The cleaner, more direct Trino-native idiom is `bool_or(event_name = 'plan_upgraded') AS has_ever_upgraded`, returning a real boolean directly. VERIFIED aggregate.html: `bool_or(boolean)` "Returns TRUE if any input value is TRUE, otherwise FALSE." This canonical exists in resources at r23:682. Responder reached a correct equivalent but did not lead with the more natural boolean-typed form.
- DIAGNOSIS: **landing-point-nuance** (MAX(CASE) reached instead of bool_or). MAX(CASE) is correct + the boolean cast is acknowledged → watch-item, not a real ding to accuracy.

### Q2 — each device's first AND last check-in timestamp side by side in one row (no self-join)
**Accuracy 5 / Completeness 5 / Clarity 4.5 / Actionability 5 = 4.875 STRONG PASS**

Answer trajectory: first sketched a `QUALIFY` + FIRST_VALUE/LAST_VALUE form, then explicitly RETRACTED it ("Wait — Trino does NOT support QUALIFY") and gave the final form: `MIN(timestamp) AS first_checkin, MAX(timestamp) AS last_checkin ... GROUP BY device_id`.

- **QUALIFY CHECK — CONFIRMED ABSENT:** VERIFIED trino.io/docs/467/sql/select.html — the SELECT grammar clause list is WITH / SELECT / FROM / WHERE / GROUP BY / HAVING / WINDOW / set-ops / ORDER BY / OFFSET / LIMIT-FETCH. There is NO QUALIFY clause. QUALIFY is a Snowflake/Teradata/BigQuery extension, not Trino — a QUALIFY query would be a PARSE ERROR. The responder's retraction is factually correct.
- **Final answer CORRECT:** VERIFIED aggregate.html: `min(x)` "Returns the minimum value of all input values" + `max(x)` "Returns the maximum value of all input values." Over `GROUP BY device_id`, MIN(timestamp)/MAX(timestamp) yield earliest and latest check-in side by side in one row, no self-join. Exactly on target.
- **Clarity ding (-0.5):** showing the invalid QUALIFY form first before retracting is a messy presentation. The self-correction demonstrates real "QUALIFY-not-in-Trino" knowledge (a GOOD signal — it did NOT leave an invalid query as the answer, it explicitly replaced it), but the engineer reads a wrong-then-right sequence. Minor.

### Q3 — count of DISTINCT sessions per user per calendar day
**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS**

Answer: `COUNT(DISTINCT session_id) AS num_sessions ... GROUP BY user_id, session_date`.

- VERIFIED valid Trino 467: COUNT(DISTINCT x) is standard aggregate-with-DISTINCT; GROUP BY user_id, session_date produces one row per (user, day) with the distinct-session count. Correct for "distinct sessions per user per calendar day."
- Assumes a pre-derived `session_date` (e.g., `date_trunc('day', event_ts)` or a date column) — reasonable given the "per calendar day" phrasing; not a ding.
- Zero defects.

### Q4 — median time-to-resolution in hours per ticket priority
**Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5 = 4.875 STRONG PASS**

Answer: `approx_percentile(resolution_hours, 0.5) AS median_hours ... GROUP BY priority`; explicitly stated Trino has NO PERCENTILE_CONT or MEDIAN(); noted the ARRAY form for multiple percentiles.

- **PERCENTILE_CONT INOCULATION — HELD:** VERIFIED aggregate.html — neither `PERCENTILE_CONT` nor `MEDIAN` appears in the Trino 467 aggregate function list. The responder did NOT fabricate either; it correctly said they do not exist and used approx_percentile. The iter611 PERCENTILE_CONT ban held under this fresh "median per group" phrasing.
- **approx_percentile CORRECT:** VERIFIED aggregate.html: single-percentage form "Returns the approximate percentile for all input values of x at the given percentage"; array form "Returns the approximate percentile for all input values of x at each of the specified percentages." `approx_percentile(resolution_hours, 0.5)` = the median (50th percentile); GROUP BY priority gives median per priority. The ARRAY-form note for multiple percentiles is accurate.
- **Minor completeness note (-0.5):** the question says "time-to-resolution in hours," implying `resolution_hours` must be computed, e.g. `date_diff('hour', opened_at, resolved_at)`. The responder assumed `resolution_hours` pre-exists and focused on the median mechanic. Showing `approx_percentile(date_diff('hour', opened_at, resolved_at), 0.5)` would fully close the question. Minor — the median mechanic (the hard part) is correct and date_diff arg-order is documented (r07:602), so a small completeness nick, not a defect.

---

## Overall computation

Dim-avg method:
- Accuracy: (5+5+5+5)/4 = 5.00
- Completeness: (4+5+5+4.5)/4 = 4.625
- Clarity: (5+4.5+5+5)/4 = 4.875
- Actionability: (5+5+5+5)/4 = 5.00
- Overall = (5.00 + 4.625 + 4.875 + 5.00)/4 = **4.875**

Per-Q-avg cross-check: (4.75 + 4.875 + 5.00 + 4.875)/4 = **4.875** — agree.

**Recorded overall: 4.875 STRONG PASS** (overall-avg GOVERNS the label; no per-Q gate applied).

---

## Q2 verdict
**QUALIFY correctly retracted + MIN/MAX final answer correct — YES.** The responder recognized QUALIFY is not in Trino (verified: no QUALIFY in the 467 SELECT grammar), explicitly replaced it, and landed on `MIN(timestamp)/MAX(timestamp) GROUP BY device_id` — the correct no-self-join first/last-per-device form. Only cost: a minor clarity ding for showing the wrong form first.

## Q4 verdict
**PERCENTILE_CONT inoculation HELD — YES.** Responder explicitly stated PERCENTILE_CONT/MEDIAN do not exist in Trino (verified) and used `approx_percentile(x, 0.5)` for the median per priority (verified). No fabrication.

---

## Slip diagnosis + iter630 fix

- **Q1 (bool_or vs MAX(CASE)):** landing-point-nuance, NOT a defect. MAX(CASE..1/0) is correct and the BOOLEAN cast is acknowledged; bool_or (r23:682) would be the more direct boolean-typed answer for a "true/false column." **WATCH-ITEM**, not worth a forced edit. OPTIONAL low-priority directive only: at the bool_or canonical (r23:682) or the MAX(CASE) conditional-aggregation block, add a keyword anchor pairing "true/false flag per user / boolean column / has ever / did this user ever do X" → bool_or as the lead, with MAX(CASE..1/0)+CAST as the equivalent. Since MAX(CASE) is correct, this is purely a findability/landing nicety — defer unless probing this exact angle again.
- **Q4 (date_diff omission):** scope nuance, not a defect — the median mechanic (the question's core) is correct. No edit warranted.
- No content-gap, no routed-but-mis-applied, no resource-defect this iter.

## Fabrication / slip flags
**NONE.** No fabricated feature or absence (PERCENTILE_CONT/MEDIAN correctly absent; QUALIFY correctly absent), no `::`-cast, no QUALIFY left in a final answer, no invalid-clause-placement, no off-by-one, no type-mismatch, no wrong-function-choice. bool_or, max, min, approx_percentile, COUNT(DISTINCT) all real Trino 467 functions correctly used.

## iter630 recommendation
**DURABILITY NO-OP.** Both inoculations (QUALIFY-not-in-Trino, PERCENTILE_CONT/MEDIAN-not-in-Trino) held first-probe; Q3 COUNT(DISTINCT) and Q2 MIN/MAX clean. Push fresh breadth. **DO NOT**: touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter629); re-edit the bool_or / MAX(CASE) / MIN-MAX / COUNT(DISTINCT) / approx_percentile landing points (all clean/correct); add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY; PERCENTILE_CONT (iter611 ban); fabricate dayname()/initcap; touch iter534-628 locks; bump training/state.json (already 629); git commit/push. Optional only: re-probe Q1 with explicit "boolean column" phrasing to confirm responder SWITCHES to bool_or.

WebFetched/verified today (2026-06-07): trino.io/docs/467/functions/aggregate.html (bool_or "TRUE if any input value is TRUE"; bool_and; max/min "maximum/minimum value of all input values"; approx_percentile single + array; PERCENTILE_CONT/MEDIAN ABSENT), trino.io/docs/467/sql/select.html (SELECT grammar clause list — NO QUALIFY; WHERE/GROUP BY/HAVING/WINDOW only).

**OVERALL: 4.875 STRONG PASS — Q2 QUALIFY correctly retracted (MIN/MAX final), Q4 PERCENTILE_CONT inoculation held (approx_percentile), Q3 COUNT(DISTINCT) clean; Q1 MAX(CASE..1/0)+CAST correct but bool_or would be the more direct boolean form (landing-point watch-item, not a defect); iter630 = durability NO-OP; federation row stays 4.49944/310.**
