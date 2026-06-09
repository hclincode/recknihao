# Judge Feedback — iter876 (EXTENDED PHASE)

**Overall: 4.97 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.875 = 19.875/4 = 4.96875; margin +1.47; overall avg governs, no per-Q veto)
**Federation NOT probed** (4.49944/310 row UNCHANGED).
**Verdict drivers:**
- (a) **iter876 gaps-and-islands FIX-A LANDED CLEAN.** The iter875 Q3 defect (1.81) is GONE. Responder now emits the correct **3-LAYER** form — Layer1 LAG gap-flag + DISTINCT dedup, Layer2 `SUM(is_new_streak) OVER (...)` streak_id in its OWN CTE, Layer3 `GROUP BY user_id,streak_id COUNT(*)` then outer `GROUP BY user_id MAX`. **No nested window function, no double-GROUP-BY.** Responder also explicitly STATES the rule: you cannot nest a window function inside another window's PARTITION BY/ORDER BY — each window must be materialized in its own CTE.
- (d) **Both Q4 15-minute bucketing forms are VALID Trino 467 and equivalent.** FORM A (`%` on double epoch) and FORM B (`bigint * INTERVAL '1' MINUTE`) both verified against 467 source.

All dialect facts VERIFIED vs trino.io/docs/467 (functions/window.html, sql/select.html, functions/datetime.html, functions/math.html) + **git-tag 467 source** (ExpressionAnalyzer.java NESTED_WINDOW; DoubleOperators.java MODULUS; IntervalDayTimeOperators.java MULTIPLY) + WebSearch, 2026-06-10. Trino 467 PINNED.

---

## Q1 — Personal-best workout streak (longest run of consecutive days per user, gaps-and-islands) — 5.00

Responder used the 3-LAYER form:
- Layer1: `CASE WHEN date_diff('day', LAG(completion_date) OVER (PARTITION BY user_id ORDER BY completion_date), completion_date) = 1 THEN 0 ELSE 1 END AS is_new_streak` over `SELECT DISTINCT user_id, completion_date`.
- Layer2: `SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY completion_date) AS streak_id` — in its own CTE.
- Layer3: `MAX(streak_len)` over `(COUNT(*) AS streak_len GROUP BY user_id, streak_id)`, `GROUP BY user_id`.

VERIFICATION (this is the iter875 Q3 1.81 DEFECT re-probe — the FIX):
- **VALID Trino, no NESTED_WINDOW.** git-tag 467 `ExpressionAnalyzer.analyzeWindow` extracts a window's PARTITION BY / ORDER BY / frame child expressions and, if any is itself a window expression, throws `semanticException(NESTED_WINDOW, …, "Cannot nest window functions or row pattern measures inside window specification")`. The 3-layer form never places a window fn inside another window's OVER — Layer2's `SUM(...) OVER` consumes Layer1's *materialized* `is_new_streak` column. Clean.
- **No double-GROUP-BY.** Each query level has exactly one GROUP BY (Layer3 inner `GROUP BY user_id,streak_id`; outer `GROUP BY user_id`). The iter875 parse-error draft is gone.
- **Algorithm correct.** `date_diff('day', LAG(...), d)` → bigint (datetime.html); on the first row LAG is NULL → `date_diff` NULL → `NULL = 1` is not TRUE → ELSE branch → flagged as a new streak (correct boundary). Running SUM of the flag assigns a monotonic streak_id; consecutive days share an id; COUNT per (user,streak_id) = streak length; MAX per user = longest streak. Textbook gaps-and-islands.
- `DISTINCT user_id, completion_date` correctly collapses multiple same-day completions so a busy day doesn't break the +1 logic.
- **Rule stated explicitly** — responder articulates the no-nested-window rule and the must-materialize-each-window-in-a-CTE requirement.

Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**. **FIX LANDED — no escalation.**

## Q2 — User IDs in BOTH subscriptions and trial_users (converted users) — 5.00

`SELECT user_id FROM trial_users INTERSECT SELECT user_id FROM paid_subscriptions`; noted INTERSECT dedups + is NULL-safe (unlike NOT IN); gave INNER JOIN + DISTINCT alternative.

VERIFIED vs sql/select.html: "INTERSECT returns only the rows that are in the result sets of both"; default mode is DISTINCT ("If neither is specified, the behavior defaults to DISTINCT"). Both-in + dedup correct. The NULL-safety contrast with `NOT IN` is accurate and a genuinely useful pointer. Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**.

## Q3 — Latest version of each row from a CDC Iceberg table (multiple upsert rows per id) — 5.00

`SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn FROM customers) WHERE rn = 1`; noted it beats the max-timestamp subquery-join.

VERIFIED vs window.html: `row_number()` "Returns a unique, sequential number for each row … according to the ordering of rows within the window partition." PARTITION BY key + ORDER BY updated_at DESC + outer `WHERE rn=1` = latest-row-per-key. Subquery wrap is required (window fns can't appear in WHERE; no QUALIFY in 467) — responder did exactly that. Correct. Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**.

## Q4 — Count webhook events per 15-minute bucket — 4.875

Responder gave TWO forms and claimed both produce the same result.

**FORM A (epoch floor):** `from_unixtime(to_unixtime(event_timestamp) - to_unixtime(event_timestamp) % 900) AS window_start`.
- `to_unixtime(ts)` → **double** (datetime.html). `%` on DOUBLE operands is VALID — git-tag 467 `DoubleOperators` has `@ScalarOperator(MODULUS) double modulus(double left, double right){ return left % right; }`. Subtracting the remainder floors epoch seconds to a 900s (15-min) boundary. `from_unixtime(double)` → `timestamp(3) with time zone`. **Floors correctly.** 900 = 15·60 is right.
- Minor type note (not dinged into accuracy): FORM A returns `timestamp with time zone` while the input column is likely plain `timestamp`; boundaries are UTC-epoch-anchored. Doesn't change bucket assignment, but a one-line "FORM A yields a tz-timestamp" note would have been ideal.

**FORM B (interval):** `date_trunc('minute', event_timestamp) - (EXTRACT(minute FROM event_timestamp) % 15) * INTERVAL '1' MINUTE`.
- `date_trunc('minute', ts)` → same type as input, seconds zeroed (datetime.html). `EXTRACT(minute FROM ts)` → **bigint** (extract → bigint). `% 15` → bigint. **`bigint * INTERVAL '1' MINUTE` is VALID** — git-tag 467 `IntervalDayTimeOperators` defines all four MULTIPLY orderings: `multiplyByBigint(interval,bigint)`, `multiplyByDouble(interval,double)`, `bigintMultiply(bigint,interval)`, `doubleMultiply(double,interval)`. The responder's `bigint * INTERVAL` hits `bigintMultiply`. `timestamp - interval` → timestamp. **Floors to :00/:15/:30/:45 correctly.**
- Responder's claim "EXTRACT(minute…) returns BIGINT so % works without a cast" is **CORRECT**.

**Equivalence:** both floor to the same 15-min boundary; equivalent for bucketing/GROUP BY (FORM A carries a tz-timestamp result type, the only difference, immaterial to counts). Claim holds.

Only ding: completeness — the tz-timestamp result-type shift in FORM A is unmentioned, and the simpler canonical `from_unixtime(floor(to_unixtime(ts)/900)*900)` isn't offered. Both forms WORK, so this is a nuance, not a defect.

Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5 = **4.875**.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 streak (gaps-and-islands FIX) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 INTERSECT | 5 | 5 | 5 | 5 | 5.00 |
| Q3 ROW_NUMBER latest-per-key | 5 | 5 | 5 | 5 | 5.00 |
| Q4 15-min bucketing (2 forms) | 5 | 4.5 | 5 | 5 | 4.875 |

**Overall = 19.875 / 4 = 4.96875 → STRONG PASS** (margin +1.47).

**(a) Q1 gaps-and-islands FIX-A: LANDED CLEAN.** Valid 3-layer form, no nested window, no double GROUP BY, rule stated. No escalation to iter877.
**(d) Q4 both bucketing forms: VALID Trino 467 and equivalent.** `%` on double (FORM A) and `bigint * INTERVAL` (FORM B) both source-verified.

## iter877 recommendation — DEFAULT NO-OP

All 4 answers dialect-clean. The iter876 FIX-A (r07 3-layer streak card / NESTED_WINDOW rule) is confirmed working on its first re-probe; the gaps-and-islands topic should be re-probed once more from a 2nd phrasing (e.g. "longest consecutive login streak" or "max consecutive days a sensor stayed online") to bulletproof the fix before considering it locked, but NO resource edit is warranted now.

- Do NOT add any "wrong" card for Q2/Q3/Q4 — all forms correct.
- Do NOT touch the iter876 B-Streak card (clean), the iter875 reconciliation card, or any percent-of-total / DATE-coercion pin.
- HOLD all iter534-875 locks. PIN 467. NO federation edits.
- **DO NOT bump training/state.json.**
- Optional fresh adjacents: gaps-and-islands 2nd phrasing (bulletproof) / `EXCEPT` vs `NOT IN` NULL-safety / `from_unixtime` tz-result vs `from_unixtime_nanos` / simpler `floor(to_unixtime/900)*900` bucketing / `width_bucket` for time bins.
