# iter965 Judge Feedback — 4 Qs (latest-value / week-bucketing / HAVING / MoM LAG)

**Overall: 4.56 — PASS** (overall avg governs; no per-Q override)

Verified every dialect/logic claim against trino.io/docs/467 (aggregate, datetime, window, select) and traced the multi-step date math on a concrete calendar week. PIN: Trino 467.

| Q | Accuracy | Clarity | Actionability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 latest plan per account (max_by) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 weekly new-customer bucketing | 3 | 4 | 3 | 4 | 3.50 |
| Q3 lifetime total > $10k (HAVING) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 MoM % change without self-join (LAG) | 4.5 | 5 | 5 | 4.5 | 4.75 |

**Overall avg = (5.00 + 3.50 + 5.00 + 4.75) / 4 = 4.56 → PASS**

---

## Q1 — max_by latest-value-per-group — CLEAN (5.00)

VERIFIED against trino.io/docs/467 functions/aggregate.html:
- `max_by(x, y)` "Returns the value of `x` associated with the maximum value of `y` over all input values." → `max_by(plan_name, changed_at)` returns the plan at the latest timestamp. Single-pass aggregate. CORRECT.
- `max(x)` for varchar follows standard comparison ordering = lexicographic (Unicode code-point). The responder's "MAX sorts plan names alphabetically; 'silver' > 'pro'" is CORRECT ('s' 0x73 > 'p' 0x70). MAX(plan_name) returns the alphabetically-largest plan, NOT the latest-by-timestamp. CORRECT explanation.

The single-pass vs ROW_NUMBER/subquery two-pass framing is accurate.

### iter964-Q3 MAX(varchar)-as-latest mislabel — CONFIRMED ONE-OFF (re-probe CLEAN)
This Q1 was the deliberate re-probe of the iter964-Q3 `MAX(varchar)`-as-latest mislabel. The responder not only used the correct idiom (`max_by(plan_name, changed_at)`) but ADDED a "Why not MAX(plan_name)?" section that correctly explains the exact trap it fell into last iteration (MAX on varchar = alphabetical, not chronological). **The iter964-Q3 mislabel is a CONFIRMED ONE-OFF — re-probe clean from a fresh angle.** No resource action; the as-of/argmax canonicals (r23 L1298-1305 max_by 'value as of latest event') held.

## Q2 — weekly new-customer bucketing — RESPONDER SLIP on the Sunday-shift secondary (3.50)

PRIMARY answer is correct and well-explained:
- `date_trunc('week', created_at)` truncates to **Monday** (ISO 8601). VERIFIED: docs example `date_trunc('week', TIMESTAMP '2001-08-22 ...')` → `2001-08-20`, and Aug 20 2001 was a Monday; day_of_week() is 1=Mon..7=Sun, Monday-fixed. Returns a timestamp. CORRECT. "Does week-start day matter? Yes" framing is right.

DEFECT — the Sunday-start workaround is the INVERTED (wrong) form:
- Responder gave: `date_trunc('week', created_at - INTERVAL '1' DAY) + INTERVAL '1' DAY`.
- The CORRECT canonical (and the form ACTUALLY IN THE RESOURCE, r07 L2305 / L2308) has the OPPOSITE signs: `date_trunc('week', event_ts + INTERVAL '1' DAY) - INTERVAL '1' DAY` ("shift forward 1 day, truncate to Monday, shift back").
- TRACE of the responder's WRONG form (ISO week Mon Aug 13 – Sun Aug 19 2001):
  - Sat Aug 18: `-1`→Fri Aug 17 → date_trunc('week')→Mon Aug 13 → `+1`→**Tue Aug 14**
  - Sun Aug 19: `-1`→Sat Aug 18 → date_trunc('week')→Mon Aug 13 → `+1`→**Tue Aug 14**
  - Sat Aug 18 and Sun Aug 19 land in the SAME bucket. Under a Sunday-start convention they MUST be in different weeks. Label is a Tuesday, not a Sunday. The form does NOT produce Sunday-start weeks.
- TRACE of the CORRECT resource form:
  - Sat Aug 18: `+1`→Sun Aug 19 → date_trunc('week')→Mon Aug 13 → `-1`→**Sun Aug 12** (week start)
  - Sun Aug 19: `+1`→Mon Aug 20 → date_trunc('week')→Mon Aug 20 → `-1`→**Sun Aug 19** (new week). Correct Sunday boundaries.

**Scope: RESPONDER SLIP, NOT a resource defect.** r07 L2304-2309 carries the CORRECT Sunday-shift canonical with an explanatory comment; the responder inverted both interval signs when transcribing. This is the "broken secondary alternative" family (per feedback_responder_broken_secondary_alternative.md) — the responder nailed the primary (Monday/date_trunc) and mangled the optional secondary form. Per that memory, scope as a per-instance one-off re-probe, NOT a resource fix (the canonical is already correct and copy-attractive). Re-probe a Sunday/custom-week-start question next sweep to confirm one-off; if it RECURS, consider a defang making the correct shift form more copy-magnetic vs the inverted form. Do NOT churn now.

## Q3 — lifetime total > $10k via HAVING — CLEAN (5.00)

VERIFIED against trino.io/docs/467 sql/select.html:
- WHERE filters rows BEFORE GROUP BY and CANNOT reference aggregates (SUM) — error. HAVING filters groups AFTER aggregation. CORRECT.
- `HAVING SUM(amount_cents) > 1000000` correct; $10,000 = 1,000,000 cents arithmetic correct.
- The cited r23 §8 title ("Filter with WHERE before GROUP BY, not HAVING") is about the PERF principle of pushing RAW-column filters to WHERE; using HAVING for the AGGREGATE filter is the correct, non-contradictory application. Responder distinguished the two correctly (raw cols → WHERE, aggregates → HAVING). No contradiction.

## Q4 — MoM % change without self-join via LAG — STRONG (4.75)

VERIFIED against trino.io/docs/467 functions/window.html + sql/select.html:
- `LAG(COUNT(*)) OVER (ORDER BY date_trunc('month', order_date))` is legal — window functions are evaluated AFTER GROUP BY, so LAG validly wraps the aggregate COUNT(*). CORRECT.
- MoM formula `ROUND(100.0 * (curr - prev) / prev, 1)`: `100.0` promotes to double (avoids integer division), `ROUND(x, 1)` valid. CORRECT.
- The CTE version (monthly_orders CTE → `LAG(order_count) OVER (ORDER BY month)`) is cleaner and correct.
- lag() supports IGNORE NULLS / RESPECT NULLS in 467 (default RESPECT NULLS). The closing aside "LAG(col) IGNORE NULLS ... is the canonical form" is a SLIGHT OVERSTATEMENT — for a dense monthly series the default RESPECT NULLS is the norm; IGNORE NULLS is for sparse/gappy series. Minor Accuracy note (−0.5), not a defect.
- Minor completeness nuance: if the ask is per-customer, add `PARTITION BY customer_id` (+ scope WHERE). The all-months MoM shape is the right pattern; trivial add. (−0.5 Completeness.)

Scope: fine. No resource action.

---

## Disposition
- iter964-Q3 MAX(varchar)-as-latest mislabel: **CONFIRMED ONE-OFF** (Q1 re-probe clean + responder self-corrected the very trap).
- Q2 inverted Sunday-shift: **responder slip on a secondary alternative**; resource canonical (r07 L2305) is CORRECT and intact — NO resource edit; re-probe-don't-churn (broken-secondary-alternative family). Watch for recurrence on a different custom-week surface.
- Q3, Q4: clean. Q4 IGNORE-NULLS-canonical aside is a minor overstatement only.
- Federation (r22 §13.x) hard-locked — not probed, not suggested (OVERRIDDEN).
- state.json NOT modified by judge.
