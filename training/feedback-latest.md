# Judge Feedback — iter759 (FIX-A verification: cume_dist stronger fix + 3 probes)

**Verdict: PASS — overall avg 5.00**

All four answers verified against trino.io/docs/467 (window.html, datetime.html, array.html) on 2026-06-09. Resources are NOT treated as ground truth. Production stack (Trino 467 + Iceberg, on-prem MinIO/HMS) accounted for; no auth/authz scope involved. No defects, no dialect errors, no contradictions.

---

## Per-question scores

### Q1 — cume_dist RE-PROBE (third scenario): fraction of cities at or below this city's response time, slowest = 1.0
- **Accuracy 5** — `cume_dist() OVER (ORDER BY avg_response_time_minutes)`. window.html: cume_dist = (rows preceding or peer)/total = fraction AT OR BELOW (ties included), top/slowest row = 1.0, lowest ≈ 1/N. Exactly matches the question.
- **Completeness 5** — Explicitly steered AWAY from percent_rank ("You want CUME_DIST(), not PERCENT_RANK") and stated the slowest city always gets 1.0. Both function choice and boundary behavior correct.
- **Clarity 5** — cume_dist-vs-percent_rank contrast stated plainly; no assumed knowledge.
- **Actionability 5** — Drop-in, correct ORDER BY direction (ascending → slowest = highest = 1.0).
- **Per-Q avg: 5.00**

**cume_dist is now CLOSED.** The iter759 stronger fix WORKED: the responder lands on the percent_rank Pattern C2 card (its keyword-landing point) and, because the at-or-below ROUTER + inline percent_rank-DO-NOT-COPY defang now sit AT THE TOP of that card before the COPY block, it correctly routed to cume_dist and explicitly rejected percent_rank. 1st clean post-stronger-fix datapoint, breaking the iter757+iter758 two-iteration repeat-miss streak.

### Q2 — running-product RE-PROBE: cumulative pass-through across ordered onboarding funnel stages
- **Accuracy 5** — `exp(sum(ln(pass_through_rate)) OVER (ORDER BY stage_sequence ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))`. sum() valid as window fn; ln/exp confirmed; no native product(). Idiom correct.
- **Completeness 5** — Worked example 0.9/0.8/0.7 → 0.9/0.72/0.504 (hand-trace correct); x>0 caveat present; noted no native product().
- **Clarity 5** — log-sum-exp = product explained clearly with a worked trace.
- **Actionability 5** — Drop-in with correct look-back frame.
- **Per-Q avg: 5.00**

**running-product is now BULLETPROOFED** (2nd consecutive clean datapoint: iter758 4.75 + iter759 5.00).

### Q3 — FRESH: forward-fill / LOCF over a daily-price table with gaps
- **Accuracy 5** — `COALESCE(price, LAST_VALUE(price) IGNORE NULLS OVER (PARTITION BY product_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))` over a `sequence(...)+UNNEST` date-spine LEFT JOINed to sparse prices. window.html explicitly: value functions (first_value/last_value/lag/lead) support IGNORE NULLS — "all rows where x is null are excluded." Explicit look-back-only frame + IGNORE NULLS returns the most recent non-null at-or-before the current row = correct LOCF. `sequence(DATE, DATE, INTERVAL '1' DAY)` confirmed valid (array.html).
- **Completeness 5** — Explained IGNORE NULLS skips gaps, the look-back-only frame, the date-spine build, and the COALESCE fill. The critical detail (default frame would give the current row; the explicit UNBOUNDED PRECEDING→CURRENT ROW + IGNORE NULLS is what makes it LOCF) is correctly handled — the responder included that frame.
- **Clarity 5** — Each piece (spine, left join, ignore-nulls fill) explained for a beginner.
- **Actionability 5** — Complete, runnable pattern.
- **Per-Q avg: 5.00**

**Q3 LOCF is FRESH-CLEAN** (1st datapoint).

### Q4 — FRESH: minutes since the same user's previous event
- **Accuracy 5** — `date_diff('minute', LAG(event_timestamp) OVER (PARTITION BY user_id ORDER BY event_timestamp), event_timestamp)`. datetime.html: `date_diff(unit, ts1, ts2)` returns `ts2 - ts1`; here ts1=LAG (earlier), ts2=current (later) → positive minutes. LAG first row = NULL → date_diff = NULL. Both correct.
- **Completeness 5** — Explained LAG = prev ts, date_diff('minute', earlier, later) returns an integer/bigint, first event NULL, compare to an integer not an INTERVAL, and that timestamp-minus-timestamp is not the way (use date_diff). All accurate for Trino 467.
- **Clarity 5** — Arg order and sign convention explained clearly.
- **Actionability 5** — Drop-in, correct partition/order.
- **Per-Q avg: 5.00**

**Q4 event-gap is FRESH-CLEAN** (1st datapoint).

---

## Overall

- Q1 5.00 | Q2 5.00 | Q3 5.00 | Q4 5.00
- **Overall avg: 5.00 — STRONG PASS**

## Status of tracked items
- **cume_dist: CLOSED** — the iter759 stronger fix (router + inline defang AT THE TOP of the percent_rank landing card) worked on the first re-probe, ending the iter757/758 repeat-miss. Re-probe ONCE more in iter760 for BULLETPROOFED.
- **running-product: BULLETPROOFED** — 2nd consecutive clean datapoint.
- **Q3 LOCF: FRESH-CLEAN** (1st datapoint).
- **Q4 event-gap: FRESH-CLEAN** (1st datapoint).

## Teacher feedback / iter760 designation
No new gap or defect surfaced. No resource edits needed. **iter760 = RE-PROBE-for-BULLETPROOFED**:
- Re-probe cume_dist a 4th angle (e.g., "percentile standing of each value, 0..1, top=1.0") to confirm CLOSED → BULLETPROOFED. Watch that the responder still rejects percent_rank when the phrasing emphasizes "percentile/standing" rather than the literal "at or below."
- Optionally re-probe LOCF (Q3) and event-gap (Q4) for their 2nd datapoint.
- 1 fresh durability-breadth pick.
- Do NOT re-edit r07 percent_rank Pattern C2 card / cume_dist sibling / §5 running-product (churn-risk; all now producing clean answers).
