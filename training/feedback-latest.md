# Iter 656 — Judge Feedback

**Overall: 4.625 STRONG PASS** (margin +1.125 above 3.5 floor; swing UP from iter655's 4.00; FIX-A LANDED — the iter655 Q3 window-mixed-with-GROUP-BY invalid hybrid did NOT recur on the symmetric Q1 re-probe)

---

## Per-question scores

### Q1 — first AND current firmware version per device in one row (FIX-A re-probe) — **4.50 PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | **FIX-A INOCULATION HELD.** Responder gave TWO valid forms and did NOT reproduce the iter655 Q3 invalid hybrid. FORM 1 — `first_value/last_value` window functions over PARTITION BY device_id ORDER BY updated_at, with the `last_value(...) ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame override, NO GROUP BY: valid Trino 467 (verified trino.io/docs/current/functions/window.html — default frame is `RANGE UNBOUNDED PRECEDING` = up to CURRENT ROW's peer group, which is why the explicit ROWS-BETWEEN-UNBOUNDED override is REQUIRED to get the actual partition-last value; responder got this detail right). Responder correctly flagged that FORM 1 emits one row per event and "needs SELECT DISTINCT to collapse to one-per-device" — that is the correct caveat. FORM 2 — `ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY updated_at ASC) AS rn` + symmetric DESC rn_desc in a subquery, then outer `MAX(CASE WHEN rn=1 THEN firmware_version END) AS first_version, MAX(CASE WHEN rn_desc=1 THEN firmware_version END) AS current_version GROUP BY device_id`: valid Trino 467 (window functions live in the inner subquery referencing ungrouped cols there, outer wraps in MAX aggregate over CASE so GROUP BY device_id is satisfied — every SELECT col is either device_id or an aggregate). One row per device, correct. **Neither form repeats the iter655 bug** (window function in SELECT referencing ungrouped col under GROUP BY in the same query level). |
| Completeness | 4 | Covered the question with two valid alternatives. Missed the cleanest one-pass idiom `min_by(firmware_version, updated_at) AS first_version, max_by(firmware_version, updated_at) AS current_version GROUP BY device_id` — which is the docs-canonical, no-subquery, no-window-function form (verified trino.io/docs/current/functions/aggregate.html: "Returns the value of x associated with the minimum/maximum value of y over all input values" — both aggregates, one row per group). The new FIX-A DECISION block in r23 explicitly preferred this idiom; responder did not route to it. Minor completeness ding — both forms given are correct, just verbose. |
| Clarity | 4 | Two-form presentation is helpful for choice but slightly more cognitive load than needed. The "needs DISTINCT to collapse" caveat on FORM 1 is clear. FORM 2 is a well-known pattern; outer MAX(CASE WHEN rn=...) reads cleanly. |
| Actionability | 5 | Engineer can paste either form and ship. No analyzer error. The DISTINCT caveat on FORM 1 is actionable. FORM 2 is drop-in. |

**FIX-A verdict: LANDED.** The iter656 FIX-A inoculation (the new r23 DECISION block + DO-NOT-WRITE for the symmetric "first AND last" shape) prevented recurrence of the iter655 Q3 window-mixed-with-GROUP-BY-on-ungrouped-column invalid hybrid. Responder gave two valid alternatives instead. Did NOT reach the cleanest min_by/max_by idiom, but the alternatives are CORRECT — this is a clarity/completeness ding, not a validity bug. Recommend monitoring: if min_by/max_by non-selection recurs over the next 3-5 iters as a stable pattern, consider a future nudge in r23 to put min_by/max_by ABOVE the ROW_NUMBER+MAX(CASE) and window-no-GROUP-BY alternatives in the decision-routing ordering. For now: the valid forms are acceptable, no immediate action needed.

### Q2 — count distinct city+country pairs — **5.00 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | `COUNT(DISTINCT ROW(country, city)) AS unique_pairs FROM users WHERE country IS NOT NULL AND city IS NOT NULL` — exact canonical Trino multi-column distinct count form. Verified via web search of trino/trino GitHub issue #613: "Trino/Presto does not support the syntax `count(distinct col_1, col_2, ...)` but instead requires wrapping multi-columns into a row type like `count(distinct (col_1, col_2, ...))`" — the ROW() constructor is the supported composite-distinct key. The bare-tuple `COUNT(DISTINCT (a,b))` parses as a row in some contexts but the explicit `ROW(a,b)` form is the safest, most explicit, and docs-canonical (matches r23:116 verbatim). NULL guards in WHERE pre-filter the dataset cleanly (avoids ROW-with-NULL-component sorting/equality edge cases). |
| Completeness | 5 | Single-pass clean query, NULL-handling explicit, no surplus complexity. |
| Clarity | 5 | One natural query, plain reads as "distinct (country, city) pairs". |
| Actionability | 5 | Drop-in production-ready. |

### Q3 — products never ordered (anti-join) — **5.00 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Two valid anti-join forms: (a) `NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.product_id = p.product_id)` — the NULL-safe canonical, verified at r23:1572-1626 PIN. (b) `LEFT JOIN order_items ... WHERE oi.product_id IS NULL` — equivalent docs-canonical anti-join. Responder correctly flagged NOT EXISTS as NULL-safe vs the NOT IN pitfall (when right-side contains a NULL, NOT IN returns all-NULL/UNKNOWN and the outer filter drops everything — the classic NOT IN NULL trap, locked at r23:1572-1626). Both forms are valid Trino 467. |
| Completeness | 5 | Two equivalent forms + NOT IN NULL inoculation. Complete coverage of the anti-join decision space. |
| Clarity | 5 | Plain framing, two routes, NULL-safety note is well placed. |
| Actionability | 5 | Engineer picks either form and ships. |

### Q4 — active subscriptions on the 1st of each of the last 6 months (point-in-time as-of count) — **4.00 PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | The composite lock fires cleanly. Month-spine via `sequence(date_trunc('month', current_date - INTERVAL '5' MONTH), date_trunc('month', current_date), INTERVAL '1' MONTH)` then `UNNEST(...) AS t(d)` — verified at trino.io/docs/current/functions/datetime.html: sequence() accepts INTERVAL step and date_trunc('month', date) returns month-start, UNNEST expands the array into rows. Six month-starts: today's month and the previous 5. The as-of predicate `s.started_at <= months.month_start AND (s.ended_at IS NULL OR s.ended_at > months.month_start)` correctly tests "active on month_start" (started on/before that day, not yet ended on that day — open intervals on the upper bound) — matches the docs-canonical interval-overlap form (r07:~947). The range-JOIN + COUNT per month-start + GROUP BY months.month_start + ORDER BY DESC are all standard. |
| Completeness | 4 | Hits all three composed locks (month-spine, interval-overlap, range-JOIN COUNT). One small note: the phrase "last 6 months" is slightly ambiguous between (a) current month + 5 prior = 6 month-starts (what the responder did) and (b) 6 months STRICTLY prior, excluding current. The responder's interpretation (current + 5 back) is the more common reading and matches the docs-canonical interpretation. Could have surfaced the choice explicitly in a one-line caveat. |
| Clarity | 3 | The SQL is correct but dense — a beginner would need to mentally compose three patterns (sequence/UNNEST, date_trunc to month-start, range-JOIN with interval overlap) to read it. A short one-line comment or step-by-step ("month-spine → join active subscriptions to each month_start → count") would have helped. |
| Actionability | 4 | Engineer pastes and ships; works as-is. Minor risk that the "last 6 months" interpretation does not match the engineer's exact intent; explicit caveat would have de-risked. |

---

## Overall computation

Per-Q averages: (4.50 + 5.00 + 5.00 + 4.00) / 4 = 18.50 / 4 = **4.625**

Dim-avg cross-check:
- Accuracy: (5+5+5+5)/4 = 5.00
- Completeness: (4+5+5+4)/4 = 4.50
- Clarity: (4+5+5+3)/4 = 4.25
- Actionability: (5+5+5+4)/4 = 4.75
- Overall: (5.00 + 4.50 + 4.25 + 4.75)/4 = 18.50/4 = **4.625** — agrees.

**Governing label = STRONG PASS** (overall avg 4.625 >= 3.5 by margin +1.125; +0.625 swing UP from iter655's 4.00). No per-Q FAIL — all four answers individually >= 4.00. FIX-A on the symmetric "first AND last per group" shape LANDED cleanly.

---

## FIX-A landing confirmation (iter656)

**LANDED.** The iter656 FIX-A target was the iter655 Q3 invalid hybrid (`first_value/last_value` window functions referencing ungrouped `status`/`changed_at` columns combined with `GROUP BY ticket_id` — analyzer rejects). The iter656 FIX-A edit inserted a new DECISION block at r23 (between r23:650 worked example and r23:652 MAX-vs-max_by DO-NOT-WRITE) that:
1. Explicitly preferred min_by/max_by aggregates for the symmetric "first AND last per group" shape.
2. Inoculated the invalid hybrid via an explicit DO-NOT-WRITE with the verbatim iter655 Q3 broken SQL labeled INVALID + analyzer-rule citation.
3. Gave two valid fallback forms if the responder really wants the window route: (a) drop GROUP BY + SELECT DISTINCT, (b) min_by/max_by aggregate (preferred).

On the iter656 Q1 re-probe ("first AND current firmware version per device in one row"), the responder gave TWO valid forms — neither reproduces the iter655 hybrid:
- FORM 1 = first_value/last_value WINDOW form WITHOUT GROUP BY (one row per event; correctly flagged "needs DISTINCT to collapse"). This is one of the two fallback fixes the new r23 block prescribed.
- FORM 2 = ROW_NUMBER+MAX(CASE) GROUP BY (one row per device; aggregates outer, windows inner). Standard, valid.

The cleanest min_by/max_by aggregate idiom (the PREFERRED form in the new r23 block) was NOT selected by the responder. Both given forms are valid and correct, so this is a clarity/completeness ding (-0.50 on Q1) rather than a validity bug. The FIX-A inoculation against the invalid hybrid worked; the routing-to-cleanest is a softer signal.

---

## iter657 directive recommendation

**DEFAULT NO-OP / DURABILITY-BREADTH.** No per-Q FAIL, overall 4.625 STRONG PASS, FIX-A landed. Lowest per-Q (Q1 at 4.50, Q4 at 4.00) are both well above the 3.5 floor. Recommend iter657 probe durability across:
- a different symmetric "first AND last per group" phrasing (e.g., "earliest and most recent login per user", "opening and closing price per ticker per day") to confirm the FIX-A inoculation holds across keyword variants — and to test whether min_by/max_by gets selected when the entity noun changes.
- a fresh composite shape from the un-re-probed backlog (e.g., a percentile + window shape, or a cohort-retention composite) to keep breadth coverage.

**Soft watch (no immediate fix):** if min_by/max_by non-selection recurs over the next 3-5 iters as a stable pattern (responder consistently picks ROW_NUMBER+MAX(CASE) or window-no-GROUP-BY over the cleaner aggregate idiom), consider reordering the r23 decision-routing so min_by/max_by appears FIRST with a "PREFER THIS" callout, and the alternatives appear with explicit "use only if X" gating. Not needed yet — one data point of non-selection is not enough to act on.

**Do NOT add new FIX-A.** No validity bugs to inoculate against this iter. The federation HARD LOCK on resources/22 remains; no edits to r22.

---

## Sources verified

- [Trino 467 Aggregate functions](https://trino.io/docs/current/functions/aggregate.html) — min_by/max_by aggregate semantics confirmed.
- [Trino 467 Window functions](https://trino.io/docs/current/functions/window.html) — first_value/last_value, default RANGE UNBOUNDED PRECEDING frame, ROWS-BETWEEN-UNBOUNDED override required for partition-last.
- [Trino SELECT / GROUP BY rules](https://trino.io/docs/current/sql/select.html) — analyzer rule on grouping columns vs aggregates.
- [Trino 467 Date/time functions](https://trino.io/docs/current/functions/datetime.html) — sequence(), date_trunc(), UNNEST patterns.
- [trino/trino issue #613 — multi-col distinct via ROW()](https://github.com/trinodb/trino/issues/613) — ROW(a,b) composite distinct key.
