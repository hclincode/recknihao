# Iter651 Judge Feedback — CLEAN PASS (durability-breadth NO-OP)

**Iteration**: 651
**Phase**: extended
**Verdict**: PASS
**Overall average**: 4.94

---

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | Pct of orders with discount code (NOT NULL share) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | Explode ARRAY tags into one row per (order, tag) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | Extract field by key from JSON payload column | 5 | 5 | 4 | 5 | 4.75 |
| Q4 | 4-week retention rate per signup cohort | 5 | 5 | 5 | 5 | 5.00 |

**Per-question averages**: Q1=5.00, Q2=5.00, Q3=4.75, Q4=5.00
**Overall**: (5.00+5.00+4.75+5.00)/4 = **4.94 PASS**

All four answers cleared the 3.5 pass bar with comfortable margin. None of the per-Q averages dipped below 3.5; no FIX-A required.

---

## Per-question verification notes

### Q1 — Discount-code share (5.00)
- `ROUND(100.0 * COUNT(CASE WHEN discount_code IS NOT NULL THEN 1 END) / COUNT(*), 2)` — correct decimal promotion, correct null semantics (CASE returns NULL by default for the ELSE branch, which COUNT excludes).
- Verified against trino.io aggregate docs: `count_if(x)` returns bigint = number of TRUE inputs, documented as "equivalent to `count(CASE WHEN x THEN 1 END)`". The responder's CASE WHEN shape and the noted `count_if(discount_code IS NOT NULL)` alternative are both idiomatic Trino 467.
- No deductions.

### Q2 — UNNEST array (5.00)
- `CROSS JOIN UNNEST(tags) AS t(tag)` in FROM, before WHERE — correct clause-order.
- `LEFT JOIN UNNEST(tags) AS t(tag) ON TRUE` to preserve rows with NULL/empty arrays — verified against trino.io SELECT docs and the explicit "left join on true" idiom called out in Trino issue #8471 doc clarification.
- `TRIM(tag)` is a sensible cleanup. No deductions.

### Q3 — JSON extract by key (4.75)
- `json_extract_scalar(payload, '$.plan')` returns VARCHAR — verified against trino.io JSON functions docs ("returns the result value as a string").
- `json_extract` returns JSON — verified ("returns the result as a JSON string").
- `JSON_VALUE(payload, '$.plan' RETURNING VARCHAR NULL ON EMPTY NULL ON ERROR)` — VALID Trino 467 syntax per official docs. Exact grammar supported: `JSON_VALUE(json_input, json_path [PASSING ...] [RETURNING type] [{ERROR|NULL|DEFAULT expr} ON EMPTY] [{ERROR|NULL|DEFAULT expr} ON ERROR])`. Responder's clause order (RETURNING then ON EMPTY then ON ERROR) matches the documented grammar.
- $.path navigation + CAST guidance for numeric comparison all correct.
- Minor clarity deduction (5 -> 4): offering both json_extract_scalar AND the full JSON_VALUE RETURNING/ON-EMPTY/ON-ERROR form in one answer is a lot for a beginner; a one-line "use json_extract_scalar; JSON_VALUE is the SQL-standard alternative" framing would have helped. Content is fully accurate; only the cognitive load nudged clarity down.

### Q4 — 4-week cohort retention (5.00)
- `DATE_TRUNC('week', signup_date)` for cohort bucketing — verified Trino week truncation rounds to Monday (ISO).
- `signup_week + INTERVAL '28' DAY` and `+ INTERVAL '35' DAY` — verified date + interval arithmetic is valid Trino syntax, and the half-open `>= signup_week + 28d AND < signup_week + 35d` window correctly captures days 28..34 (the 4th week after signup).
- `COUNT(DISTINCT user_id)` cohort sizing and active-user counting — canonical.
- `COALESCE(users_active_4w, 0)` + `100.0 *` decimal promotion — correct null-safe percentage.
- Incomplete-cohort guardrail `WHERE date_diff('day', c.signup_week, CURRENT_DATE) >= 35` — verified `date_diff('day', a, b)` returns bigint days; the >= 35 filter correctly removes cohorts that haven't yet had time to complete their week-4 window.
- No deductions.

---

## Durability-breadth probe summary

This iter651 NO-OP run probed four fresh question shapes against the iter534-iter650 lock inventory without any resource edits. All four held cleanly:

1. **count_if / NOT NULL share** — primitive at r23 §3.1E + §11; share-of-grand-total at r07:1170+. Composition was one-step and the responder synthesized correctly.
2. **UNNEST ARRAY** — r07 §1a CROSS JOIN UNNEST + LEFT JOIN UNNEST ON TRUE + clause-order rule at r07 §1a.1 all materialized in the answer verbatim shape.
3. **json_extract_scalar + JSON_VALUE** — r09:551+, r13:3361+ landed both the primary and the SQL-standard alternative. Both verified accurate against Trino 467 docs.
4. **DATE_TRUNC('week') cohort retention** — r07 §3 cohort canonical held; 28/35 INTERVAL day arithmetic + incomplete-cohort guardrail both correct.

Zero file edits this iteration. resources/22 untouched. All iter534-iter650 locks preserved in place.

---

## Recommendation for iter652

**DEFAULT NO-OP / DURABILITY-BREADTH continuation.** No FIX-A needed. No per-question average dipped below 3.5; the lowest (Q3 at 4.75) is still well above threshold and the minor deduction was clarity, not accuracy.

Suggested iter652 probe directions (all durability-breadth, no resource edits expected):
- HOF on map column (`transform_values`, `map_filter`) — verify the r09 map HOF anchor still lands when phrased as "filter keys by predicate".
- `array_distinct` / `array_agg(DISTINCT)` shape — verify r23 listagg/array_join + DISTINCT guardrail.
- Trino-Iceberg time-travel `FOR VERSION AS OF` / `FOR TIMESTAMP AS OF` — verify the r10/r17 time-travel canonical.
- `INSERT OVERWRITE` partition semantics in Trino-Iceberg — verify the r18 partition-write canonical.

If any of those four breadth-probes scores a per-Q avg < 3.5 in a future iteration, name it the iter-N+1 FIX-A. Until then, keep the no-edit durability cadence.
