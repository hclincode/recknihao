# Judge Feedback — iter917 (NO-OP durability sweep)

**Overall: 5.00 STRONG PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 20.00 / 4 = 5.00).
OVERALL AVERAGE governs — no per-Q veto.

All dialect claims verified vs trino.io/docs/467 (datetime.html, select.html) + git-tag 467 `DateTimeFunctions.java` / `timestamp/DateDiff.java` + Joda `BaseDateTimeField`/`DateTimeField` javadoc, multi-source WebSearch/WebFetch, 2026-06-10. Trino 467 PINNED. Teacher made ZERO edits — pure durability re-confirm sweep. **NO-OP declared (no defect, no FIX-A).**

---

## Per-question scores

### Q1 — days since last heartbeat per device — **5.00 CLEAN**
`SELECT device_id, date_diff('day', last_seen, current_timestamp) AS days_since_last_heartbeat FROM heartbeats` + precision note.

**(1) TIMESTAMP -> TIMESTAMP WITH TIME ZONE COERCION HOLDS — RE-CONFIRMED, NOT a type error.** `last_seen` is TIMESTAMP, `current_timestamp` is TIMESTAMP WITH TIME ZONE. Trino 467 has implicit TIMESTAMP -> TIMESTAMP WITH TIME ZONE coercion (git-tag `TypeCoercion.java`: `case StandardTypes.TIMESTAMP -> case TIMESTAMP_WITH_TIME_ZONE returns createTimestampWithTimeZoneType(precision)`). So `last_seen` coerces to timestamp-with-tz at the session zone and `date_diff('day', last_seen, current_timestamp)` is VALID and RUNS. This is the standing PINNED FACT (iter882-onward); it is explicitly NOT a defect.

**(2) PRECISION NOTE IS CORRECT — VERIFIED date_diff('day') is TRUNCATED-ELAPSED, not calendar-boundary.** The responder claims `date_diff('day', ts1, ts2)` between two timestamps counts whole elapsed days from the time components (last_seen 23:00, now 01:00 next calendar day -> `date_diff('day')` = **0**), and that calendar-day differences require casting both to date: `date_diff('day', date(last_seen), date(current_timestamp))`. **This is the verified truth.**

VERIFICATION CHAIN (BOTH directions, settled from git-tag source — NOT from the doc's DATE example, which does not disambiguate):
- git-tag 467 timestamp `date_diff` -> `getTimestampField(ISOChronology.getInstanceUTC(), unit).getDifferenceAsLong(epochMillis2, epochMillis1)`.
- Joda `BaseDateTimeField.getDifferenceAsLong` delegates to `getDurationField().getDifferenceAsLong(...)`; the day duration field in the UTC/fixed-offset ISO chronology is a **precise** fixed-86,400,000 ms duration -> the difference is the millis-delta divided into whole day-units with **"any fractional units are dropped"** (Joda `DateTimeField` javadoc). This is duration/elapsed-based, NOT a boundary-crossing count.
- Inverse-property proof: Joda guarantees `getDifference(add(instant, v), instant) == v`. `add('day', 1, 2020-03-01 23:00) = 2020-03-02 23:00`, so `date_diff('day', 2020-03-01 23:00, 2020-03-02 23:00) = 1`; but `2020-03-01 23:00 -> 2020-03-02 01:00` is only +2h, which cannot reach one full day-unit -> **0**. Confirms truncated-elapsed.
- The trino.io datetime.html example `date_diff('day', DATE '2020-03-01', DATE '2020-03-02') = 1` returns 1 ONLY because DATE inputs sit at midnight (exactly 24h elapsed), so it coincides with both interpretations and does NOT disambiguate the time-of-day case. An interim WebFetch that inferred "1" for the 23:00->01:00 timestamp case extrapolated from that DATE example and is **REJECTED**; the git-tag + Joda mechanism governs.
- Consistent with verified memory `reference_trino_datediff_dayaware` (calendar+fixed-duration date_diff families both "drop the fractional remainder / complete-units"; sub-day units are millis-division-elapsed, NOT boundary crossings).

So the responder's precision note (23:00->01:00 = 0; `date()`-cast for calendar diff) is an accurate sophisticated nuance, not an inaccuracy. **Q1 = 5.00.**

### Q2 — each channel's revenue split weekend vs weekday, one query — **5.00 CLEAN**
`SUM(CASE WHEN day_of_week(order_date) IN (6,7) THEN order_value ELSE 0 END) AS weekend_revenue, SUM(CASE WHEN day_of_week(order_date) IN (1,2,3,4,5) THEN order_value ELSE 0 END) AS weekday_revenue ... GROUP BY sales_channel`.

VERIFIED datetime.html: `day_of_week(x)` returns "the ISO day of the week ... 1 (Monday) to 7 (Sunday)" -> Sat = 6, Sun = 7 correct; weekday = 1-5 correct. Conditional-aggregation pivot computes both columns in one pass over the GROUP BY sales_channel. Correct and idiomatic.

### Q3 — new customers per quarter (year included) — **5.00 CLEAN**
`CONCAT(CAST(year(signup_date) AS VARCHAR), ' Q', CAST(quarter(signup_date) AS VARCHAR)) AS quarter_label, COUNT(*) ... GROUP BY year(signup_date), quarter(signup_date)`.

VERIFIED datetime.html: `year(x)` -> bigint, `quarter(x)` -> bigint ranging 1-4; **no `quarter_of_year` function exists** (matches the standing WHICH-QUARTER pin; only `quarter()`/`EXTRACT(QUARTER FROM ...)`). Responder correctly notes the absence of any `quarter_of_year` alias. `CAST(... AS VARCHAR)` + `CONCAT` valid; GROUP BY repeats the **expressions** (not the SELECT alias) — correct (Trino does not allow grouping by output alias for computed expressions reliably; repeating the expr is the safe form). Correct.

### Q4 — count items sold below cost — **5.00 CLEAN**
`SELECT COUNT(*) FROM order_items WHERE sale_price < unit_cost`. Simple filter-count; single scalar; correct shape. No dialect concerns.

---

## Verdict

- **Q1 TIMESTAMP -> TIMESTAMP WITH TIME ZONE coercion HOLDS** — `date_diff('day', last_seen, current_timestamp)` is VALID and RUNS; re-confirmed, NOT a type error.
- **date_diff('day', ts, ts) is TRUNCATED-ELAPSED** (whole 24h-periods between the two instants, fractional dropped; 23:00->01:00-next-day = 0), NOT calendar-date-boundary — verified from git-tag 467 source + Joda mechanism. The responder's precision note (cast to `date()` for calendar-day diff) is CORRECT.
- **NO DEFECT** — no fabrication, no wrong signature, no crossed family, no findability slip, no GROUP-BY muddle, no prod-env conflict. Every function verified present + correct-signature in Trino 467. All four answers are pure SQL; on-prem Trino 467 + Iceberg 1.5.2 + MinIO + Hive Metastore + JWT/OPA stack unaffected.
- **iter918 = DEFAULT NO-OP / durability-breadth.** Re-probe truncated-elapsed `date_diff` from a different angle to keep the precision nuance durable (e.g. `date_diff('hour'/'minute', ts, ts)` elapsed-vs-alignment; `date_diff('day', date(a), date(b))` calendar-diff form; `date_diff('month', signup, current_date)` complete-months). Optional fresh adjacents: `day_of_week` Sunday-start variants, `EXTRACT(QUARTER FROM ...)` mirror of Q3, FILTER (WHERE ...) form of the weekend/weekday pivot. PRESERVE full iter534-916 pin inventory; NO federation edits (federation 4.49944 / 310, UNCHANGED — not probed this sweep).

DO NOT bump training/state.json (already 917).
