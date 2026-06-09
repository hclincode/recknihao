# Judge Feedback — iter792 (DEFAULT NO-OP / durability-breadth sweep)

**Teacher made ZERO resource edits this iteration (expected).**
**Verification:** every dialect claim checked against trino.io/docs/467 (datetime.html, conditional.html, comparison.html). resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — Days between signup_date and cancellation_date (account lifespan) — **SLIP RE-PROBE**
Answer: `date_diff('day', signup_date, cancellation_date) AS days_active`; signature `date_diff(unit, ts1, ts2) = ts2 - ts1`; earlier value as arg2, later as arg3 (swap → negative); `WHERE cancellation_date IS NOT NULL`. Cites r23.

- **Verified:** trino.io/docs/467/functions/datetime.html — `date_diff(unit, timestamp1, timestamp2) → bigint`, returns "timestamp2 - timestamp1 expressed in terms of unit". `date_diff('day', signup_date, cancellation_date)` = whole days active. Arg-order note (earlier=arg2, later=arg3, swap→negative) is correct. The NULL-guard on cancellation_date is apt for still-active accounts.
- **CRITICAL — SLIP DID NOT RECUR:** the responder USED `date_diff` and did NOT repeat the iter791 `date2 - date1` date-minus-date slip. Slip is CONFIRMED ONE-OFF.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

### Q2 — Distinct status values in orders (no duplicates)
Answer: `SELECT DISTINCT status FROM orders ORDER BY status`; one row per unique value. Cites r23.

- **Verified:** SELECT DISTINCT returns unique values; ORDER BY sorts. Standard, correct, minimal, exactly answers the ask.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

### Q3 — Clamp discount_pct to [0,100] without a big CASE
Answer: `greatest(0, least(discount_pct, 100)) AS discount_pct_clamped`; least caps top at 100, greatest floors at 0. Caveat: greatest/least return NULL if ANY arg is NULL in Trino (unlike Postgres which only returns NULL if ALL are NULL); wrap `greatest(0, least(coalesce(discount_pct,0),100))` if NULL possible. Cites r23.

- **Verified:** trino.io/docs/467/functions/comparison.html — `greatest(v1,...,vN)` / `least(v1,...,vN)`; docs state "Like most other functions in Trino, they return null if any argument is null" and explicitly contrast with PostgreSQL ("only return null if all arguments are null"). The responder's caveat is EXACTLY correct, including the Postgres contrast. `greatest(0, least(x,100))` clamps to [0,100]. coalesce wrap is apt.
- This matches the standing iter778-verified greatest/least-NULL-if-any-null pin.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

### Q4 — % of customer rows with phone_number filled (completeness ratio)
Answer: `100.0 * COUNT(phone_number) / COUNT(*) AS pct_with_phone`; COUNT(col) counts non-null, COUNT(*) all rows, 100.0 forces float division; `ROUND(...,2)` for display; also `COUNT(*)-COUNT(phone_number) AS without_phone`. Cites r07+r23.

- **Verified:** COUNT(col) counts non-null values, COUNT(*) all rows; `100.0 *` forces double division (avoids integer truncation); ROUND(x,2) valid. Correct and complete; the without_phone bonus is a nice touch.
- Matches standing COUNT(col)-vs-COUNT(*) + 100.0-float-division pins.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 5.00 → PASS** (threshold 3.5).

---

## Verdicts

- **(a) date-minus-date slip recurrence:** DID NOT RECUR. The responder used `date_diff('day', signup_date, cancellation_date)` — not `date2 - date1`. The iter791 date-minus-date slip is CONFIRMED ONE-OFF. **No iter793 FIX-A needed.**
- **(b) iter793 designation:** DEFAULT NO-OP / durability-breadth sweep (expected). All four answers clean and Trino-467-accurate; no new defects flagged.

## Teacher feedback
No edits required. This was an expected-strong durability sweep and every answer was bulletproof. Q1 cleanly cleared the slip re-check. Q3's greatest/least NULL-if-any-null caveat (with the Postgres contrast and coalesce wrap) is precisely correct and well-positioned. Keep r23/r07 as-is; continue probing only bulletproofed adjacent angles. No new pin introduced.
