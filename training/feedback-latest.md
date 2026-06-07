# Iter631 — Judge Feedback

**Overall average: 4.6875 PASS** (margin +1.1875 above 3.5 floor; +0.28125 swing from iter630's 4.40625)

**HEADLINE**: iter631 FIX-A canonical LANDED CLEAN. The responder used `date_trunc('hour', event_ts + INTERVAL '30' MINUTE)` — the +30min-then-floor idiom — NOT the iter630 CEILING CASE expression that mis-rounded 2:15->3:00. Worked examples confirm: 4:12 PM -> 4:00 (correct nearest, NOT the naive ceiling's 5:00), 4:48 PM -> 5:00 (correct), 2:30 half-hour tie -> 3:00 (rounds up, explicitly noted). Q2/Q3/Q4 all clean Trino 467 dialect; one minor Q3 polish opportunity (positional GROUP BY 1,2 not mentioned as an alternative to the "repeat the expression" rule).

---

## Per-question scores

### Q1 — Snap timestamp to NEAREST whole hour
**Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5 | Avg 5.0**

- Used `date_trunc('hour', event_ts + INTERVAL '30' MINUTE)` — the iter631 canonical landed exactly. WebFetch-verified vs trino.io/docs/467/functions/datetime.html: (a) date_trunc('hour', x) floors (docs example `2001-08-22 03:04:05.321` -> `2001-08-22 03:00:00.000`); (b) timestamp + INTERVAL arithmetic valid (docs example `time '01:00' + interval '3' hour` -> `04:00:00.000`); (c) interval-literal `INTERVAL '<n-quoted>' UNIT` is canonical Trino form.
- Worked examples correct: 4:12+0:30=4:42 floor 4:00 (matches the asker's required 4:00), 4:48+0:30=5:18 floor 5:00 (matches required 5:00), 2:30 tie -> 3:00 (half-up tie explicitly noted as a behavior caveat).
- Distinguished from plain FLOOR `date_trunc('hour', event_ts)` and flagged Postgres `INTERVAL '30 minutes'` form as wrong for Trino.
- **FIX-A from iter630 LANDED**: responder did NOT regress to the CEILING CASE pattern that mis-rounded 2:15.

### Q2 — Month-over-month signups + percent change
**Accuracy 5 | Completeness 5 | Clarity 4 | Actionability 5 | Avg 4.75**

- `date_trunc('month', created_at)` + COUNT(*) GROUP BY repeating the expression — correct per Trino 467 GROUP BY rules (verified: output aliases NOT allowed in GROUP BY; must repeat expression or use positional ordinal).
- Self-LEFT-JOIN on `prev.month = date_add('month', -1, cur.month)` — date_add signature verified `date_add(unit, value, timestamp)` and accepts negative values per docs example `date_add('day', -1, TIMESTAMP '2020-03-01 00:00:00 UTC')`.
- `(cur - prev)*1.0 / NULLIF(prev, 0) * 100` — both the decimal-promotion (*1.0) and zero-guard (NULLIF) are textbook-correct.
- Gap-safe self-join chosen over LAG — defensible for sparse months where LAG would compare to the previous non-empty month, not the prior calendar month. Worth a one-line note that LAG is fine when every month has at least one signup.
- Clarity -1: a one-liner contrasting `LAG(signups) OVER (ORDER BY month)` vs the self-join with the gap-safety rationale would have made the trade-off explicit.

### Q3 — Signups by month AND channel
**Accuracy 5 | Completeness 4 | Clarity 5 | Actionability 5 | Avg 4.75**

- Two-column GROUP BY `date_trunc('month', created_at), acquisition_channel` with COUNT(*) — correct.
- "Alias-not-allowed-in-GROUP-BY" claim VERIFIED accurate for Trino 467 per trino.io/docs/467/sql/select.html: "A simple GROUP BY clause may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position (starting at one)." Output aliases are not in that list — the docs explicitly say "input column names" or positional. So repeat-the-expression is correct guidance.
- Mentioned conditional aggregation CASE pivot as alternative — good.
- Completeness -1: did NOT mention `GROUP BY 1, 2` positional ordinal as the lighter-weight workaround to repeating the date_trunc expression. Trino 467 supports positional GROUP BY and it's a common idiom in production SQL. Adding "or use `GROUP BY 1, 2` for brevity" would have been complete.

### Q4 — Cohort comparison (Q1 vs Q2 avg actions in first 30 days)
**Accuracy 4 | Completeness 4 | Clarity 5 | Actionability 5 | Avg 4.5**

- `date_trunc('quarter', created_at)` for cohort labels — verified (Trino 467 docs explicitly list `quarter` as a truncation unit with example output `2001-07-01 00:00:00.000`).
- `action_time >= signup_date AND action_time < signup_date + INTERVAL '30' DAY` — verified (timestamp + INTERVAL DAY arithmetic valid per docs example `timestamp '2012-08-08 01:00' + interval '29' hour` = `2012-08-09 06:00:00.000`).
- Two-level aggregation (count per user, then avg per cohort) correctly answers "average actions per user in first 30 days" — methodologically sound.
- **Accuracy -1 / Completeness -1 caveat**: INNER JOIN to `user_actions` silently drops users with ZERO actions in the first 30 days. For "average actions per cohort", excluding zero-action users biases the average UP. The correct construction is either (a) LEFT JOIN with COALESCE(count, 0), or (b) per-user count via `(SELECT COUNT(*) FROM user_actions ua WHERE ua.user_id = c.user_id AND ua.action_time BETWEEN c.signup_date AND c.signup_date + INTERVAL '30' DAY)` with a LEFT context so zero-action users contribute 0 to the average. The responder did not flag this denominator/zero-user trap. For cohort analytics this is a real semantic bug, not just a stylistic note.

---

## Verification summary (WebFetch trino.io/docs/467, 2026-06-07)

| Claim | Verified |
|---|---|
| `date_trunc('hour', ts)` floors | YES (docs example 03:04:05.321 -> 03:00:00.000) |
| `ts + INTERVAL '30' MINUTE` valid Trino | YES (operators table: `time '01:00' + interval '3' hour`) |
| Nearest-hour idiom `date_trunc('hour', ts + INTERVAL '30' MINUTE)` | YES (algebraically correct + dialect valid) |
| `date_add('month', -1, ts)` signature | YES (docs: `date_add(unit, value, timestamp)`, negatives OK) |
| `date_trunc('quarter', ts)` supported | YES (docs truncation units table lists `quarter`) |
| `ts + INTERVAL '30' DAY` valid | YES (operators + `interval '29' hour` example) |
| Trino 467 disallows output alias in GROUP BY | YES (docs: only "input column" or "ordinal number" allowed) |
| Trino 467 allows positional `GROUP BY 1, 2` | YES (docs: "ordinal number selecting an output column by position") |

---

## FIX-A recommendation for iter632

**DEFAULT NO-OP / durability-breadth.** No per-question average < 3.5. Lowest per-Q avg is Q4 at 4.5 (zero-action-users INNER-JOIN bias caveat). No required topic is below threshold this iter.

If a probe slot is available, two SMALL, ADDITIVE, ANCHOR-ONLY enhancements are worth considering (NOT rewrites of any locked canonical):

1. **r07 cohort/first-30-days block — add a one-line LEFT-JOIN-vs-INNER-JOIN zero-user caveat**: "Use LEFT JOIN + COALESCE(count, 0) to include zero-action users in the cohort average; INNER JOIN excludes them and biases the average upward." Worked example with two users: one with 5 actions, one with 0; INNER-JOIN avg = 5.0, LEFT-JOIN avg = 2.5. Verify a locked cohort canonical doesn't already cover this before adding.

2. **r07 or r28 GROUP BY rule block — add a one-line positional ordinal alternative anchor**: "Trino 467 does NOT allow output-column aliases in GROUP BY; either repeat the expression OR use `GROUP BY 1, 2` positional ordinals." This is purely additive and complements the existing "repeat the expression" guidance.

Both are pure additions; neither touches any locked canonical. Both should be docs-verified via WebFetch before being added. If the iter632 directive prefers strict durability-breadth (no FIX-A), the NO-OP is also defensible — Q4 at 4.5 is comfortably above 3.5, and the overall 4.6875 has +1.1875 margin.

---

## Score history entry

iter631 - 4.6875 PASS - nearest-hour FIX-A LANDED clean (+30min-then-floor), Q4 zero-user INNER-JOIN bias minor caveat
