# Judge Feedback — iter1083 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source (dispositive over rendered HTML).

## Overall: 4.50 — PASS (threshold 3.5; margin +1.00)

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (avg resolution hours) | 4.5 | 2.5 | 4.0 | 3.75 | 3.69 |
| Q2 (lowercase name) | 5.0 | 4.75 | 5.0 | 4.75 | 4.88 |
| Q3 (DENSE_RANK leaderboard) | 5.0 | 4.75 | 5.0 | 4.75 | 4.88 |
| Q4 (filter NaN/Infinity) | 5.0 | 4.75 | 4.75 | 4.75 | 4.81 |

Overall average across 16 cells = **4.50 → PASS**.

## Per-question

### Q1 — 3.69 (MISSING-AVG COMPLETENESS GAP; mechanic correct)
- User asked for the **AVERAGE** resolution time in hours. Responder returned **per-ticket** `date_diff('hour', created_at, resolved_at) AS hours_to_resolve` and did **NOT** wrap it in `AVG()`.
- The date_diff mechanic is **correct and verified**: `date_diff(unit, ts1, ts2)` returns `timestamp2 - timestamp1 expressed in terms of unit` (whole-unit integer; doc example `date_diff('hour', 2020-03-01 00:00, 2020-03-02 00:00)` = 24). `'hour'` is the right unit and the `WHERE resolved_at IS NOT NULL` guard is correct.
- Complete answer: `SELECT AVG(date_diff('hour', created_at, resolved_at)) FROM support_tickets WHERE resolved_at IS NOT NULL`. For fractional-hour precision: `AVG(date_diff('minute', created_at, resolved_at)/60.0)` (whole-hour date_diff truncates fractional hours).
- This is a **Completeness/Actionability** deduction (gave per-row, not the aggregate the question asked for), NOT a correctness defect.

### Q2 — 4.88 (clean)
- `lower(name)`: string.md VERIFIED `lower(string)` "Converts string to lowercase." Trivially clean display normalization.

### Q3 — 4.88 (clean)
- `DENSE_RANK() OVER (ORDER BY total_revenue DESC)` over a `SUM(revenue) GROUP BY customer_id` subquery.
- window.md VERIFIED: `dense_rank` — "tie values do not produce gaps in the sequence" → 1,2,2,3 (the asked behavior); `rank` — "tie values...produce gaps" → 1,2,2,4. The RANK-vs-DENSE_RANK contrast is accurate. Ranking over a pre-aggregated subquery is valid; PARTITION BY note for per-group leaderboards is correct.

### Q4 — 4.81 (clean)
- `WHERE is_finite(bytes_transferred)` plus `IF(is_finite(bytes_transferred), bytes_transferred, NULL) AS clean_bytes`, mentions `is_nan()`/`is_infinite()`.
- math.md VERIFIED: `is_finite(x)` "Determine if x is finite", `is_nan(x)` "Determine if x is not-a-number", `is_infinite(x)` "Determine if x is infinite" — all exist in 467. is_finite returns true only for finite values (false for NaN and ±Infinity).
- Division claim accurate: integer/decimal `/0` throws DIVISION_BY_ZERO; double `/0` → Infinity per IEEE-754 (matches the pinned [Trino Division By Zero] reference).

## Source-verified dialect notes
- date_diff whole-unit integer + 'hour' unit: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- is_finite / is_nan / is_infinite exist, finite-only true: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md
- rank gaps / dense_rank no-gaps: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md
- lower(string) lowercases: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/string.md

No `::`/QUALIFY/false-semi-join/fabricated-function/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary issues found.

## Recommendation
DEFAULT NO-OP (margin +1.00). The only deduction is the Q1 per-ticket-vs-AVG completeness slip on an aggregate-intent question — a responder per-instance slip, not a resource gap. Re-probe an average/aggregate-intent question next sweep to confirm the responder wraps in AVG()/SUM() when the prompt asks for a single aggregate. Do NOT churn. MUST NOT bump state.json (already 1083).
