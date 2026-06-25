# Judge Feedback — iter1096 (2026-06-26)

**Overall: 4.844 STRONG PASS** (overall average governs; NO per-question veto). Q1 date_diff FIX-A durability re-probe **PASSED on a SECOND angle** (full-months-active, not age). One real-but-cosmetic Q2 defect (illustrative GROUP BY example would parse-error if copy-pasted). FIX-A REACHING CLEANLY ACROSS TWO INDEPENDENT MONTH/YEAR ANGLES NOW.

Verified BOTH directions vs RAW git-tag 467 source + Joda-Time API + official Trino docs:
- `DateTimeFunctions.java` (467) `diffDate` → Joda `getDifferenceAsLong` (carried + [Trino date_diff Day-Aware] pin)
- Joda-Time `DateTimeField.getDifferenceAsLong` Javadoc: "Any fractional units are dropped from the result"
- `functions/json.md` 467: `json_extract_scalar(json, json_path)` with JSONPath dot notation `$.a.b.c` returns VARCHAR; non-scalar paths → NULL (use `json_extract` for object/array)
- `functions/window.md` 467: ROW_NUMBER OVER (PARTITION BY ... ORDER BY ...); aggregate function inside window's ORDER BY is allowed when the outer SELECT has the matching GROUP BY (window phase runs AFTER aggregation phase)
- `functions/aggregate.md` 467: `COUNT(...) FILTER (WHERE predicate)` is standard-SQL filtered aggregate; supported in 467
- `sql/select.md` 467: no native PIVOT/UNPIVOT keyword; conditional-aggregate is the canonical pivot
- WebSearch official trino.io docs (json.html, window.html) re-verified this iter

---

## Q1 — Full months active: Feb-3 → May-20 → expect 3 not 4 — 5.00  ← FIX-A DURABILITY CONFIRMED (2nd angle)

- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

`SELECT date_diff('month', subscription_start, subscription_end) AS months_active;`

**FIX-A durability:** this is the SECOND independent re-probe of the iter1095 root-cause reconciliation (r23 ~L2213 + r27 L732/L739/L768). iter1095 tested *years* (loyalty); iter1096 tests *months* (subscription tenure), a different unit, different sign of partial period. Both produced the **bare `date_diff(unit, start, end)` with NO CASE adjustment** — exactly the canonical post-FIX-A pattern. The reconciliation holds across units.

**True value verification:**
- Feb-3 + 1 month = Mar-3 (≤ May-20) ✓ → complete month 1
- Feb-3 + 2 months = Apr-3 (≤ May-20) ✓ → complete month 2
- Feb-3 + 3 months = May-3 (≤ May-20) ✓ → complete month 3
- Feb-3 + 4 months = Jun-3 (> May-20) ✗ → 4th month incomplete, dropped
- date_diff('month', DATE '2024-02-03', DATE '2024-05-20') = **3** ✓ matches responder

**Day-aware narration correct:** responder stated "Trino's date_diff drops the fractional unit — Feb-3 to May-20 is 3 complete months because the 4th anniversary day Jun-3 has not yet been reached by May-20". Verbatim alignment with Joda Javadoc + [Trino date_diff Day-Aware] pin.

**Engineer expectation alignment:** engineer explicitly asked "will it give 3 not 4?" — responder answered **3 (yes)** with the day-aware justification. The pre-FIX-A wrong canonical would have predicted 4 (Feb→Mar→Apr→May = 4 boundary crossings) — the responder's 3 confirms the wrong canonical is no longer being cited.

**Oracle contrast clean:** responder noted Oracle MONTHS_BETWEEN returns a fractional Number (e.g. `MONTHS_BETWEEN('2024-05-20','2024-02-03') ≈ 3.55`) and that Trino's date_diff is the integer/day-aware equivalent — no truncation function wrapping needed. Matches r27 L766-768 reconciled mapping.

No CASE/subtract-1/boundary-correction noise. No fabricated alternative. Clean.

---

## Q2 — Pull nested JSON field metadata.device.os_version — 4.375

- Accuracy 4 | Completeness 4.5 | Clarity 4.75 | Actionability 4.25

`json_extract_scalar(metadata, '$.device.os_version') AS os_version`

**Core function recommendation CORRECT:**
- `json_extract_scalar(json, json_path)` returns VARCHAR — VERIFIED `functions/json.md` 467
- JSONPath dot notation `$.device.os_version` for nested traversal — VERIFIED (WebSearch official docs: `json_extract_scalar(json, '$.store.book[0].author')` style)
- "Shorter than nested calls" — TRUE; one call vs `json_extract_scalar(json_extract_scalar(json_extract(metadata,'$.device'),'$.os_version'),...)` chain
- Scalar-vs-object caveat correct: `json_extract_scalar` on a non-scalar returns NULL; use `json_extract` then chain for nested objects

**REAL DEFECT (Accuracy shave to 4) — illustrative GROUP BY example is syntactically broken:**

The responder's example query `SELECT event_id, json_extract_scalar(metadata, '$.device.os_version') AS os_version FROM events GROUP BY os_version` is a **parse-time error** in Trino 467. `event_id` is in the SELECT but is neither aggregated nor in the GROUP BY → Trino throws `Column must be an aggregate expression or appear in GROUP BY clause`. If the engineer copy-pastes the example for the "group by extracted field" use-case the engineer asked about, the query fails before returning a row.

**Verdict on judge-prompt's "real defect vs cosmetic" question: REAL but LOW-IMPACT.**
- It's not the headline answer (the function recommendation is the headline and is correct).
- It IS a copy-paste-fail SQL snippet — same family as the [Responder Broken Secondary Alternative] pin (e.g. iter1013 ORDER-BY-ungrouped).
- The fix the engineer would discover in seconds (drop `event_id` from SELECT, or aggregate it with `array_agg`, or GROUP BY both `os_version` and `event_id` — depending on intent).
- Scored as a moderate Accuracy shave (4 not 3), not a per-question fail (no per-question veto regardless).

**No resource fix needed.** This is a one-off responder padding pattern (the broken-secondary family from the pin); base resources for json_extract_scalar are correct. Per pin guidance: "scope each as per-instance one-off re-probe NOT a resource defect, don't churn".

---

## Q3 — Top 5 customers per pricing plan by 90-day spend — 5.00

- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

```sql
WITH plan_spend AS (
  SELECT plan, customer_id,
         SUM(amount) AS total_spend,
         ROW_NUMBER() OVER (PARTITION BY plan ORDER BY SUM(amount) DESC) AS rn
  FROM payments
  WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
  GROUP BY plan, customer_id
)
SELECT plan, customer_id, total_spend
FROM plan_spend
WHERE rn <= 5;
```

**All four critical pieces correct:**
1. **Aggregate-inside-window-ORDER-BY pattern** — `ROW_NUMBER() OVER (PARTITION BY plan ORDER BY SUM(amount) DESC)` with GROUP BY plan, customer_id at the same SELECT level is VALID Trino 467 SQL. Window functions run AFTER GROUP BY aggregation in the logical execution order, so `SUM(amount)` inside `OVER ORDER BY` is resolved against the grouped row. Re-verified via WebSearch window.html. No defect.
2. **Outer WHERE rn <= 5** — subquery/CTE wrap is REQUIRED in Trino because window functions cannot appear directly in WHERE, and Trino 467 has NO QUALIFY clause (matches the [Trino No QUALIFY] family pin context). Responder correctly stated this.
3. **`INTERVAL '90' DAY`** — valid Trino 467 syntax (DAY is one of the supported interval qualifiers per [Trino INTERVAL Qualifiers] pin — YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only; no QUARTER/WEEK). `CURRENT_DATE - INTERVAL '90' DAY` returns a DATE. Clean.
4. **PARTITION BY plan + ORDER BY SUM(amount) DESC + rn <= 5** correctly implements top-N-per-group (vs the engineer's naive `LIMIT 5` after `ORDER BY total_spend` which gives top 5 globally, not per-plan — responder explicitly diagnosed this).

No per-customer non-determinism risk worth flagging (ties on SUM(amount) within a plan can change which 5 customers are picked across re-runs; ROW_NUMBER vs DENSE_RANK trade-off not asked). No defects.

---

## Q4 — Pivot to one row per user with per-event-type counts — 5.00

- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

```sql
SELECT user_id,
       COUNT(*) FILTER (WHERE event_type = 'login')  AS logins,
       COUNT(*) FILTER (WHERE event_type = 'export') AS exports,
       COUNT(*) FILTER (WHERE event_type = 'invite') AS invites
FROM events
GROUP BY user_id;
```

**All correct:**
- `COUNT(*) FILTER (WHERE predicate)` — VERIFIED Trino 467 aggregate.html supports standard-SQL FILTER clause on aggregate functions; counts rows matching predicate per group.
- One pass over `events`, no self-joins (directly answers engineer's "without multiple self-joins" ask).
- `SUM(CASE WHEN event_type='login' THEN 1 ELSE 0 END)` alternative also correct and equivalent (slightly more verbose, same plan after Trino's optimizer rewrites).
- "No native PIVOT keyword in Trino" — TRUE; Trino 467 has no PIVOT/UNPIVOT (not in `sql/select.md` grammar); conditional-aggregate IS the canonical Trino pivot pattern.

NULL handling is correct: `COUNT(*) FILTER` returns 0 (not NULL) for users with no events of a given type, because the outer COUNT runs on a (possibly empty) filtered set per group — exactly what the engineer wants for a per-user dashboard.

No defects. No fabricated alternative. No over-warning. Clean.

---

## Score table

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 — full months active (FIX-A 2nd re-probe) | 5.00 | 5.00 | 5.00 | 5.00 | **5.000** |
| Q2 — json_extract_scalar nested path | 4.00 | 4.50 | 4.75 | 4.25 | **4.375** |
| Q3 — top-N per group ROW_NUMBER | 5.00 | 5.00 | 5.00 | 5.00 | **5.000** |
| Q4 — pivot via FILTER | 5.00 | 5.00 | 5.00 | 5.00 | **5.000** |

**Overall average: (5.000 + 4.375 + 5.000 + 5.000) / 4 = 4.844 → STRONG PASS** (margin +1.344 above 3.5 threshold)

---

## Source-verified defects this iter

1. **Q2 illustrative SELECT not in GROUP BY** — `SELECT event_id, json_extract_scalar(...) AS os_version FROM events GROUP BY os_version` is a Trino parse-time error (column must be aggregated or grouped). REAL defect (would fail if copied), LOW IMPACT (not the headline recommendation; engineer asked for a "shorter path" function recommendation, and the function pick is correct). Matches the [Responder Broken Secondary Alternative] pin family — one-off responder padding, no resource fix.

ZERO accuracy defects on Q1/Q3/Q4. ZERO fabricated functions. ZERO QUALIFY/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning slips.

---

## FIX-A durability ruling — date_diff day-aware

**FIX-A REACHING CLEANLY ACROSS TWO INDEPENDENT ANGLES.**

| Iter | Angle | Unit | Partial-period direction | Responder bare-form? | Numbers correct? | Notes |
|---|---|---|---|---|---|---|
| iter1095 | Loyalty years (signup → today) | year | partial 26th/4th year DROPPED | YES (no CASE) | YES (3, 4) | Quietly corrected engineer's "2 years" prior |
| iter1096 | Subscription full-months (start → end) | month | partial May DROPPED (May-20 < Jun-3) | YES (no CASE) | YES (3) | Matched engineer's stated expectation 3 not 4 |

Both probes confirm:
- The iter1095 r23 ~L2213 reconcile (removed wrong "year-field subtraction =26 + CASE-subtract-1" canonical) holds.
- The iter1095 r27 L732/L739/L768 reconcile (removed "boundary crossings, =2" narration) holds.
- The responder learns the day-aware/complete-units contract from the new canonicals, not from boundary-crossing folklore.
- The reconciliation generalizes across UNITS (year + month tested; day/hour/quarter/week not yet re-probed but Joda contract is uniform).

**FIX-A bake complete on month/year angles.** Federation (lone NEEDS-WORK row, 4.4994 / 310) is now safe to re-probe in iter1097 per state.json plan.

---

## Teacher guidance

**NO resource edit recommended this iter.**

Rationale:
1. The headline Q1 FIX-A is durable across two independent angles. No further reconciliation needed for date_diff day-aware on month/year.
2. Q2 illustrative-GROUP-BY defect is per-instance responder padding (broken-secondary family per pin), NOT a resource gap. The `json_extract_scalar` resource canonical is correct; the responder added a broken example on its own.
3. Q3/Q4 are clean canonical patterns; resources already strong.
4. Per [Synthesis Ceiling — Stop Churning] pin: after a FIX-A confirms on multiple re-probes, return to breadth, do not add defang for one-off responder padding.

**For iter1097 plan:**
- The federation row (4.4994 / 310, lone NEEDS-WORK) is the only path-to-PASSED-everywhere remaining. Suggested next iter: a bulletproofed federation probe (per [All Topics Passed] note + iter1095 deferral). Pick angles the resource explicitly covers (predicate pushdown on JDBC `catalog.schema.table`, cross-catalog join broadcast, when-to-federate-vs-ingest); avoid ILIKE-pushdown angle (hard-locked per [Trino No ILIKE] pin).
- No `prod_info.md` mismatch this iter — all four answers use Trino 467 with Iceberg connector, MinIO/Hive-Metastore agnostic; pure SQL dialect questions.

**Recommendation: DEFAULT NO-OP** (margin +1.344 with clean Q1 FIX-A confirm and only a cosmetic Q2 cosmetic). NO state.json bump (already 1096). NO commit beyond rubric + feedback. Federation deferred to iter1097.

---

## Source citations

- [Trino 467 JSON functions](https://trino.io/docs/current/functions/json.html)
- [Trino 467 Window functions](https://trino.io/docs/current/functions/window.html)
- [Trino 467 Aggregate functions](https://trino.io/docs/current/functions/aggregate.html)
- [Trino 467 Date and time functions](https://trino.io/docs/current/functions/datetime.html)
- [Joda-Time DateTimeField API (getDifferenceAsLong "fractional units dropped")](https://joda-time.sourceforge.net/apidocs/org/joda/time/DateTimeField.html)
