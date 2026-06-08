# Judge Feedback — iter761 (EXTENDED PHASE) — MINOR FIX-A verification

**Overall: 4.875 PASS** (per-Q avg 5.00 / 4.75 / 5.00 / 4.75 = 19.50/4; margin +1.375; overall avg governs, no per-Q veto)

Headline: **ROLLUP selection is now CLOSED (1st post-fix datapoint — the iter760/r28 selection-router + business anchors + copy-attractive clean ROLLUP example WORKED).** The responder used `GROUP BY ROLLUP(department, team)` — NOT CUBE — for the "subtotal per department + one grand total (NOT every combination)" ask. Q2 arbitrary/any_value, Q3 15-min epoch-floor bucket, and Q4 null-rate SUM(CASE)*100.0 are all fresh-clean. Zero dialect defects.

---

## Per-question scores

### Q1 — ROLLUP RE-PROBE (dept,team detail + per-dept subtotal + grand total, hierarchical NOT all-combinations) — avg 5.00
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- VERIFIED trino.io/docs/467/sql/select.html: `GROUP BY ROLLUP(department, team)` = GROUPING SETS ((department,team),(department),()) = detail + per-department subtotal + grand total, and does NOT emit the (team)-only rows that CUBE would add. EXACT fit for "hierarchical subtotals, not every combination." The responder correctly chose ROLLUP over CUBE — **the r28 selection-router fix worked on the 1st re-probe.**
- VERIFIED GROUPING() bitmask (rightmost arg = LSB, bit=1 when rolled up): GROUPING(department,team)=0 both present (Detail), =1 team rolled up (Department Total), =3 both rolled up (Grand Total). The responder's `CASE GROUPING(...) WHEN 0 / WHEN 1 / WHEN 3` is docs-correct, and correctly **omits a WHEN 2 branch** — GROUPING=2 (dept rolled up, team present) is the (team)-only row that ROLLUP never produces. Sharp, correct detail.
- ORDER BY GROUPING(...), department NULLS LAST, team NULLS LAST is the right idiom to keep subtotals/grand-total below their detail rows (NULLS LAST is Trino 467 default but stating it explicitly is good).

### Q2 — pick ANY representative value per group (any user_agent per session) — avg 4.75
- Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5
- VERIFIED trino.io/docs/467/functions/aggregate.html: both `arbitrary(x)` and `any_value(x)` are native; docs state `arbitrary()` is "Identical to any_value()". Both return an arbitrary non-null value from the group. `arbitrary(user_agent)` is correct.
- The "any_value is the SQL-standard alias" framing is accurate (any_value is the SQL-standard spelling; arbitrary is Trino's historical name; functionally identical). The "lighter than MAX — don't signal lexical-ordering intent" rationale is sound semantic guidance.
- Minor (-0.25 Completeness): did not flag the NULL caveat — both functions return an arbitrary NON-null value, so a group whose only user_agent values are NULL yields NULL. For a representative-value pick this is almost always fine, but worth a one-liner. No actionability/clarity hit.

### Q3 — floor event timestamp to 15-minute bucket — avg 5.00
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- VERIFIED trino.io/docs/467/functions/datetime.html: `to_unixtime(ts)` returns double seconds-since-epoch; `% 900` is valid on the double; `from_unixtime(double)` returns a timestamp. `from_unixtime(to_unixtime(event_ts) - to_unixtime(event_ts) % 900)` floors to the 15-min boundary, epoch-aligned to :00/:15/:30/:45. Worked examples (10:07/10:14→10:00, 10:22→10:15) are correct.
- The alternative `date_trunc('minute', event_ts) - (EXTRACT(minute FROM event_ts) % 15) * INTERVAL '1' MINUTE` is also valid: date_trunc('minute') drops seconds first, then subtracting minute%15 minutes aligns to the 15-min boundary — correct flooring. Offering both forms with the epoch form as canonical is exactly right.

### Q4 — null rate / percentage of phone_number IS NULL — avg 4.75
- Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5
- VERIFIED: `ROUND(SUM(CASE WHEN phone_number IS NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)` is correct. The `100.0` literal forces decimal division, avoiding the integer-division-truncates-to-0 trap. SUM(CASE) counts NULLs; /COUNT(*) is the fraction; ROUND(...,2) for a clean percentage. The `*1.0` ratio variant is also correct.
- Minor (-0.25 Completeness): did not mention the equivalent `count(x)` idiom — `1 - count(phone_number)*1.0/count(*)` (count(x) excludes NULLs) is a tidy alternative. Not required; the responder's form is fully correct and more readable. No deduction beyond completeness.

---

## Topic-closure status

- **ROLLUP-vs-CUBE-vs-GROUPING-SETS: CLOSED** (1st post-fix datapoint). The r28 selection-router + business anchors + copy-attractive clean ROLLUP example worked: responder selected ROLLUP (not CUBE) and applied the correct 0/1/3 GROUPING bitmask with no spurious WHEN 2 branch. **Re-probe ONCE MORE at iter762 from a different business phrasing to mark BULLETPROOFED** (standing two-angle rule; do not declare bulletproofed on one datapoint).
- **arbitrary / any_value: fresh-clean.** Native, identical, correctly chosen over MAX.
- **15-min epoch-floor bucket: fresh-clean.** Both epoch and date_trunc-interval forms valid.
- **null-rate SUM(CASE)*100.0: fresh-clean.** Decimal-division trap correctly avoided.

## Gaps / defects for iter762
- **No new gap or dialect defect surfaced.** No FIX-A needed.
- Two cosmetic completeness nits (Q2 all-NULL-group→NULL caveat; Q4 count(x) equivalent idiom) — both optional polish, NOT findability/selection gaps. Do NOT churn resources for these; only add if a future probe shows the responder mis-stating them.

## iter762 designation: **RE-PROBE + FRESH PICKS** (no FIX-A)
- Re-probe ROLLUP once more from a fresh business phrasing (e.g. "year then month subtotals + overall total" or "category then subcategory drill-down totals") to drive ROLLUP selection to BULLETPROOFED (2nd consecutive clean datapoint).
- Add 2-3 FRESH picks from the unprobed standing inventory.
- HOLD all iter534-761 locks incl. the iter761 r28 ROLLUP router/anchors/clean-example (PRESERVE — do not churn CUBE/GROUPING-SETS/GROUPING-bitmask content), iter759 percent_rank at-or-below router+defang, iter758 running-product r07 §5. Federation r22 untouched. DO NOT bump training/state.json (already 761).
