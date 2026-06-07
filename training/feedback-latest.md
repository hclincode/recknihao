# Iter653 Judge Feedback — 2026-06-08

## Verdict: PASS — Overall 4.6875

Mode: extended phase / NO-OP durability-breadth probe iteration. All four anticipated probes landed clean against Trino 467 docs. Lowest per-Q is Q4 at 4.00 (framing miss: LIST-vs-COUNT). Lock inventory (r28:413+ ROLLUP, r23:1187-1260 days-between, r07:862+ sequence, r23:741+ bool_or / COUNT DISTINCT both-present) is performing as designed. Synthesizable-from-primitives composition is intact.

---

## Per-question scoring

### Q1 — signups per channel + labelled grand-total row (ROLLUP + GROUPING())
Answer used:
```sql
SELECT channel, COUNT(*) AS signup_count,
       CASE GROUPING(channel) WHEN 0 THEN 'Detail'
                              WHEN 1 THEN 'ALL CHANNELS' END AS row_type
FROM signups
GROUP BY ROLLUP(channel)
ORDER BY GROUPING(channel), channel NULLS LAST
```

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | GROUP BY ROLLUP(channel) emits (channel) + () = per-channel + grand-total rows. For 1-column ROLLUP, GROUPING(channel) returns 0 on detail rows and 1 on the grand-total row — verbatim correct per r28:460-500. The ORDER BY GROUPING(channel), channel NULLS LAST cleanly pushes the total row to the bottom. |
| Completeness | 5 | Answered exactly what was asked: per-channel counts + one labelled grand-total row + label column distinguishing the two. |
| Clarity | 5 | CASE on GROUPING gives an explicit, human-readable `row_type` column — the iter620/621 GROUPING-label lock paid off. |
| Actionability | 5 | Drop-in Trino 467 query. |

**Q1 avg = 5.00**

---

### Q2 — days between trial_started and subscribed events per user (self-join)
Answer self-joined `events` against itself filtered to the two event types, with `subscribed.event_time > trial.event_time`, and computed `date_diff('day', date(trial.event_time), date(subscribed.event_time))`.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Self-join on user_id with event-type filters on both sides is the canonical shape. `date_diff('day', earlier, later)` matches Trino 467 docs exactly (`date_diff(unit, timestamp1, timestamp2) -> bigint, returns timestamp2 - timestamp1`). `date()` cast normalizes to calendar days. No `date - date` integer-subtraction (which Trino does not support). |
| Completeness | 5 | Addressed the question; answer also flagged the multi-event ambiguity (if a user has multiple trial or subscribe events, multiple rows result) — a useful caveat and not a bug. |
| Clarity | 4 | CTE form is readable; could mention the MIN_BY / conditional-aggregation alternative for the "one row per user" case. Minor. |
| Actionability | 5 | Drop-in. |

**Q2 avg = 4.75**

---

### Q3 — fill missing calendar days with zero (date spine)
Answer used `sequence(DATE '2026-06-01', DATE '2026-06-30', INTERVAL '1' DAY)` in a calendar CTE, LEFT JOIN to daily_orders, COALESCE(order_count, 0).

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | sequence(start, stop, INTERVAL '1' DAY) returns an array, both bounds inclusive — verified against trino.io/docs/467/functions/array.html. UNNEST into rows is correct. WHERE `order_time < DATE '2026-07-01'` uses a half-open upper bound on the source query while the spine is inclusive on both ends — both consistent on 06-30. GROUP BY 1 positional is valid Trino. LEFT JOIN + COALESCE(...,0) is the canonical zero-fill shape. |
| Completeness | 5 | All required pieces: spine generation, daily aggregate CTE, LEFT JOIN, zero-fill, ordering. |
| Clarity | 5 | Two-CTE structure makes the spine vs. data distinction explicit. |
| Actionability | 5 | Drop-in. |

**Q3 avg = 5.00**

---

### Q4 — count sessions that contain BOTH login AND checkout
Answer:
```sql
SELECT session_id, COUNT(*)
FROM events
WHERE event_type IN ('login','checkout')
GROUP BY session_id
HAVING COUNT(DISTINCT event_type) = 2
```
Plus a join-back-for-detail variant via `WHERE session_id IN (SELECT ...)`.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | After filtering to the two event types, `HAVING COUNT(DISTINCT event_type) = 2` correctly retains only sessions containing both — equivalent to `HAVING bool_or(event_type='login') AND bool_or(event_type='checkout')`. Both forms are docs-canonical per bool_or signature at trino.io/docs/467/functions/aggregate.html. |
| Completeness | 3 | **Framing miss**: the question asked to **count** how many such sessions exist. The answer returns one row per qualifying session, not a single scalar count. A trivial outer `SELECT COUNT(*) FROM (...) t` wrap gives the requested number. The both-present detection core is right, but the final shape doesn't directly answer "how many". |
| Clarity | 4 | Query is readable; framing miss noted above (no explicit instruction to wrap with COUNT(*)). |
| Actionability | 4 | Engineer can easily add the COUNT wrap, but the gap shouldn't exist in a templated answer. |

**Q4 avg = 4.00**

---

## Overall

| Q | Avg |
|---|---|
| Q1 ROLLUP + GROUPING-label | 5.00 |
| Q2 self-join + date_diff | 4.75 |
| Q3 sequence date-spine | 5.00 |
| Q4 both-present per session | 4.00 |
| **Overall** | **4.6875** |

(Recomputed: (5.00 + 4.75 + 5.00 + 4.00) / 4 = 4.6875)

**PASS** — overall ≥ 3.5 and no per-question dim < 3.

---

## Durability-breadth verdict

All four iter653 anticipated probes (ROLLUP+GROUPING-label, self-join+date_diff, sequence date-spine, both-present detection) **HELD CLEAN**. The lock inventory (r28:413+ ROLLUP, r23:1187-1260 days-between, r07:862+ sequence, r23:741+ bool_or) is performing as designed. Synthesizable-from-primitives composition is intact.

## Docs-verified facts (this iteration, 2026-06-08)

- `date_diff(unit, timestamp1, timestamp2) -> bigint, returns timestamp2 - timestamp1` — verified at trino.io/docs/467/functions/datetime.html.
- `sequence(start, stop, step)` for dates accepts INTERVAL DAY TO SECOND or INTERVAL YEAR TO MONTH step; returns an array; both bounds inclusive — verified at trino.io/docs/467/functions/array.html.
- `bool_or(boolean) -> boolean` returns TRUE if any input is TRUE — verified at trino.io/docs/467/functions/aggregate.html.
- ROLLUP(c1) emits (c1) and () = N+1 groupings (N=1 → 2 groupings); GROUPING(c1) returns 0 on detail rows, 1 on the grand-total row.

## iter654 directive

**DEFAULT NO-OP / DURABILITY-BREADTH**. No per-question avg fell below 3.5, so no FIX-A is required. The only soft signal is Q4's framing miss (LIST-vs-COUNT). If a future probe again asks "how many" and the responder returns rows instead of a count, consider adding a 1-line "wrap outer COUNT(*) when the question asks 'how many'" pointer at the bool_or canonical (r23:741+). Until then, hold per NO-OP discipline.

## Watch-items (carry forward)
- `corr` / `regr_*` / `covar_*` outside r22 — still synthesizable-from-primitives only (single docs-canonical aggregate calls). Add to r23 §11 only on verified failure signal, not pre-probe.
