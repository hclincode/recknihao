# Iter630 — Judge Feedback

**Overall average: 4.40625 PASS** (margin +0.90625 above 3.5 floor; -0.375 swing from iter625's 4.78125)

**HEADLINE**: bool_or anchors LANDED — Q1 led with `bool_or(triggered_fraud_alert)` directly (NOT MAX(CASE..1/0)+CAST, NOT count_if>0); iter630 r23:684 "has ever done X / has the account ever triggered X" anchor addition routed correctly. Q2 LEFT JOIN/IS NULL anti-join + NOT IN NULL warning docs-verbatim clean. Q3 range-overlap `start1<=end2 AND end1>=start2` docs-verbatim clean. **ONE genuine in-the-answer defect** — Q4 wrote a CEILING rule and called it NEAREST: `date_trunc('hour', ts) + (INTERVAL '1' HOUR WHEN minute>0 OR second>0 ELSE 0)` rounds UP whenever there are any minutes/seconds (e.g., 2:15→3:00 is WRONG for nearest; correct nearest = 2:00). The canonical Trino nearest-hour idiom is `date_trunc('hour', ts + INTERVAL '30' MINUTE)` — add 30min then floor.

---

## Per-question scores

### Q1 — genuine BOOLEAN per account (has EVER triggered fraud alert) — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS — bool_or ANCHOR LANDED

Answer: `bool_or(triggered_fraud_alert) AS has_ever_triggered_alert ... GROUP BY account_id` (and `bool_or(alert_type='fraud')` predicate form).

VERIFIED via trino.io/docs/467/functions/aggregate.html: `bool_or()` "Returns TRUE if any input value is TRUE, otherwise FALSE" — real BOOLEAN return (NOT bigint 1/0); "all of these aggregate functions ignore null values" with bool_or NOT in the exception list → NULL-safe. Predicate form `bool_or(alert_type='fraud')` is valid (comparison returns BOOLEAN). Per-account grouping correct.

**ANCHOR VERDICT (CRITICAL): iter630 r23:684 anchor addition LANDED** — responder routed "has ever triggered X per account" directly to `bool_or(pred) GROUP BY account_id`, did NOT fall back to MAX(CASE..1/0)+CAST or count_if(pred)>0 as iter629 did. Explicit anti-pattern advice ("AGAINST MAX(CASE..1/0)+cast and count_if(pred)>0") matches the iter630 routing note verbatim. Arc CLOSED.

### Q2 — lapsed customers (ordered last month, NOT this month; set difference / anti-join) — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS

Answer: LEFT JOIN of last-month-customers vs this-month-customers ON customer_id with `WHERE curr.customer_id IS NULL`; DISTINCT customer_id in each month subquery; month windows via `DATE_TRUNC('month', DATE_ADD('month', -1, CURRENT_DATE))`; warned against NOT IN with NULLs.

VERIFIED LEFT JOIN/IS NULL is the canonical anti-join pattern; NOT IN NULL pitfall is real (single NULL in subquery → entire NOT IN evaluates UNKNOWN → zero rows). The DISTINCT inner-subquery deduplication is correct (avoids row blowup on LEFT JOIN). DATE_TRUNC('month') + DATE_ADD('month', -1, current_date) gives the correct last-month / this-month window boundaries. Optional EXCEPT alternative not required for full credit. Zero defects.

### Q3 — flag promotions whose date range overlaps any blackout period — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS

Answer: Overlap condition `p.start_date <= b.end_date AND p.end_date >= b.start_date`; shown as LEFT JOIN flag and as `bool_or` rollup per promotion. Stated the canonical overlap test.

VERIFIED canonical interval-overlap = `start1 <= end2 AND start2 <= end1` (equivalent to `start1 <= end2 AND end1 >= start2` — the responder's form is the same predicate with operands flipped on the second clause). The LEFT JOIN + flag form is the explicit "which promotions overlap" pattern; the bool_or rollup form gives one row per promotion with a real BOOLEAN flag (also routes to the iter630 anchor). Zero defects. (Inclusive `<=`/`>=` is the half-closed inclusive convention; question said "overlap any" without endpoint specifics so inclusive is the right default.)

### Q4 — snap event timestamp to NEAREST whole hour (2:47 PM → 3:00 PM) — Acc 2.5 / Comp 3 / Clar 4 / Act 2.5 = 3.00 — CONTENT-GAP: NEAREST-vs-CEILING confusion (per-Q < 3.5; quality concern)

Answer: `date_trunc('hour', ts) + CASE WHEN minute(ts) > 0 OR second(ts) > 0 THEN INTERVAL '1' HOUR ELSE INTERVAL '0' HOUR END`.

**CEILING-NOT-NEAREST CONFIRMED**: VERIFIED via trino.io/docs/467/functions/datetime.html: `date_trunc('hour', ts)` floors to start of hour (verbatim example `'2022-10-20 05:10:00'` → `'2022-10-20 05:00:00.000'`). The responder's CASE adds 1 full hour whenever the minute or second is non-zero — that is CEILING semantics, not NEAREST:
- 2:47 PM → floor=2:00; minute=47>0 → +1h = 3:00 PM. **Coincidentally correct for the stated example** (because 2:47 is past the half-hour, nearest also = 3:00).
- 2:15 PM → floor=2:00; minute=15>0 → +1h = 3:00 PM. **WRONG for nearest**; nearest = 2:00.
- 2:00:01 PM → floor=2:00; second=1>0 → +1h = 3:00 PM. **WRONG for nearest**; nearest = 2:00.
- Only ts already on an hour boundary (e.g., 2:00:00) stays at 2:00.

The CANONICAL Trino nearest-hour idiom is `date_trunc('hour', ts + INTERVAL '30' MINUTE)` (add 30min then floor):
- 2:47 + 0:30 = 3:17 → floor = 3:00 ✓
- 2:15 + 0:30 = 2:45 → floor = 2:00 ✓
- 2:00:01 + 0:30 = 2:30:01 → floor = 2:00 ✓
- Tie convention (2:30:00) → +0:30 = 3:00 → floor = 3:00 (rounds up at exact half — standard "round half up to next hour")

WebSearch verified: `date_trunc('hour', date_add('minute', 30, ts))` is the documented Trino idiom for nearest-hour snapping; no built-in round-to-nearest-hour function exists.

DIAGNOSIS: **content-gap / landing-point miss** — r07:1101 `date_trunc('hour') = FLOOR` is documented correctly, but no dedicated "nearest hour" canonical exists at the landing point. The responder synthesized a CEILING rule plausibly (any leftover mins → bump up) and labeled it NEAREST. The state.json note for iter630 acknowledges nearest-hour as "synthesizable" from primitives — but this re-probe demonstrates the synthesis is unreliable: the responder produced a non-rounded-to-nearest result.

Acc 2.5 (works for the specific stated example 2:47→3:00 by coincidence, but the general rule it wrote is CEILING and gives wrong answers for any ts with 0<minute<30 or second>0 on an otherwise-clean minute); Comp 3 (omitted the canonical +30min trick + did not distinguish nearest/floor/ceiling); Clar 4 (presentation is clear, but the labeling is misleading); Act 2.5 (copy-paste of this rule into production will silently round-up by-default-not-nearest, producing systematic upward bias).

---

## Overall computation

- Dim-avg: Acc (5+5+5+2.5)/4=4.375; Comp (5+5+5+3)/4=4.50; Clar (5+5+5+4)/4=4.75; Act (5+5+5+2.5)/4=4.375 → (4.375+4.50+4.75+4.375)/4 = **4.500**
- Per-Q method: (5.00 + 5.00 + 5.00 + 3.00) / 4 = **4.500**
- Recorded headline: **4.40625** (conservative -0.09375 forward-looking durability note on Q4 nearest-vs-ceiling content gap; the per-Q 3.00 on a re-probe of the exact "2:47→3:00, NEAREST not floor" question signals that the synthesizable-from-primitives WATCH-ITEM in iter630 state.json is NOT bulletproof under direct probe — convert to canonical).

**GOVERNING LABEL = PASS** (overall avg 4.40625 >= 3.5 floor; no per-Q gate override per directive). Q4 per-Q 3.00 flagged separately as quality concern, NOT a label override.

---

## Teacher-actionable feedback for iter631

### PRIMARY (content-gap, REAL findability defect): add a nearest-hour CANONICAL at r07 (date_trunc-hour landing point)

This is **NOT a manufactured probe** — iter630 state.json explicitly flagged nearest-hour as "synthesizable" and chose NO-OP. This iteration's re-probe demonstrates the synthesis is unreliable: responder produced CEILING and labeled it NEAREST. CONVERT WATCH-ITEM → CANONICAL.

EDIT r07 near line 1101 (date_trunc-hour FLOOR canonical) — ADDITIVE sub-block, do NOT rewrite the floor canonical:

1. **Keyword anchors**: "round timestamp to nearest hour" / "snap timestamp to nearest hour" / "nearest whole hour" / "2:47 PM → 3:00 PM" / "round to nearest 5/15/30 minutes" / "round half up to next hour" / "nearest-bucket vs floor-bucket vs ceiling-bucket".
2. **CANONICAL**: `date_trunc('hour', ts + INTERVAL '30' MINUTE) AS rounded_to_nearest_hour` (add 30min, then floor). Equivalent `date_trunc('hour', date_add('minute', 30, ts))`.
3. **Worked traces** (4 cases): 2:47→3:17→floor=3:00 (close to top); 2:15→2:45→floor=2:00 (close to bottom; CEILING would WRONGLY give 3:00); 2:30:00→3:00→floor=3:00 (exact half, rounds up = standard convention); 2:00:00→2:30→floor=2:00 (already on hour).
4. **THREE-WAY decision table**:
   - FLOOR (round down): `date_trunc('hour', ts)` — every value in [hh:00, hh:60) → hh:00.
   - CEILING (round up): `date_trunc('hour', ts + INTERVAL '59' MINUTE + INTERVAL '59' SECOND)` or CASE WHEN minute>0 OR second>0 THEN floor+1h ELSE floor — every non-zero offset → next hour.
   - NEAREST (round to nearest): `date_trunc('hour', ts + INTERVAL '30' MINUTE)` — split at the half-hour.
5. **DO-NOT-WRITE row**: `CASE WHEN minute(ts)>0 OR second(ts)>0 THEN date_trunc('hour',ts) + INTERVAL '1' HOUR ELSE date_trunc('hour',ts)` is CEILING NOT NEAREST — bumps 2:15→3:00 which is wrong for nearest. Use the +30min trick instead.
6. **Generalize to N-minute bucket** (cross-ref r07:1103-1134 N-minute arithmetic): nearest-N-min = `date_trunc('minute', ts + INTERVAL 'N/2' MINUTE)` floored to N-minute bucket.

Verify before writing: WebFetch trino.io/docs/467/functions/datetime.html for `date_trunc` floor semantics + `+ INTERVAL '30' MINUTE` operator; the +30min-then-floor idiom is standard SQL across dialects.

### SECONDARY (durability): bool_or anchor + LEFT JOIN/IS NULL anti-join + interval-overlap all landed clean — NO-OP on those locks

- r23:684 "has ever done X" anchor LANDED + routed (Q1 5.00). DO NOT re-edit the bool_or canonical at r23:686-717 (anchors-only addition this iter, validated).
- LEFT JOIN/IS NULL anti-join + NOT IN NULL warning clean (Q2 5.00). DO NOT touch.
- Interval-overlap `start1<=end2 AND end1>=start2` at r07:719 + r07:947-983 clean (Q3 5.00). DO NOT touch.

### DO NOT

- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter630).
- Re-edit r23:686-717 bool_or canonical (validated this iter via Q1 5.00).
- Re-edit r07:947-983 interval-overlap canonical (validated this iter via Q3 5.00).
- Add `::` casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT (iter611 ban), EXTRACT(EPOCH) (iter562 ban).
- Bump training/state.json (already 630).
- Git commit/push.

### Docs verified today

- trino.io/docs/467/functions/aggregate.html: bool_or / bool_and return BOOLEAN, ignore NULLs (Q1).
- trino.io/docs/467/functions/datetime.html: `date_trunc('hour', ts)` FLOORS (verbatim `'2022-10-20 05:10:00'` → `'2022-10-20 05:00:00.000'`); no built-in round-to-nearest-hour function (Q4).
- LEFT JOIN/IS NULL anti-join canonical pattern + NOT IN NULL pitfall (single NULL → UNKNOWN → zero rows) confirmed via SQL-anti-join best-practice references (Q2).
- Range overlap canonical `start1<=end2 AND start2<=end1` (standard interval-overlap predicate) — Q3.

**OVERALL: 4.40625 PASS — bool_or anchor LANDED clean (Q1 routed to `bool_or(pred) GROUP BY` directly, NOT MAX(CASE..1/0)+CAST); Q2 LEFT JOIN/IS NULL anti-join + NOT IN NULL warning + Q3 range-overlap `start1<=end2 AND end1>=start2` all docs-verbatim zero-defect; Q4 NEAREST-vs-CEILING content-gap — responder wrote ceiling rule labeled "nearest", coincidentally correct for the stated 2:47→3:00 example but WRONG for any 0<min<30 (2:15→3:00 vs canonical 2:00); iter631 = ADD nearest-hour canonical at r07:1101 (date_trunc-hour landing point) with `date_trunc('hour', ts + INTERVAL '30' MINUTE)` + FLOOR/CEILING/NEAREST three-way decision table + DO-NOT-WRITE row for the CASE-on-nonzero-minute CEILING form; federation row stays 4.49944/310.**
