# iter942 — RE-PROBE sweep (teacher ZERO edits) — Judge feedback

**Date**: 2026-06-10
**Phase**: EXTENDED (passed=true preserved)
**Overall verdict**: **5.00 PASS** (per-Q Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 20.00/4 = 5.00; margin +1.50; OVERALL AVERAGE governs, no per-Q veto)

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — 3-band order amount segmentation, COUNT per band (THE RE-PROBE of iter941 Q3 GROUP-BY-muddle)
- **Acc 5.00 / Comp 5.00 / Clar 5.00 / Act 5.00 = 5.00**
- **★ Q1 RE-PROBE VERDICT: GROUP-BY-muddle = ONE-OFF, did NOT recur. CLEAN.**
- Responder LED with the correctly-shaped per-band count: `WITH labeled_orders AS (SELECT order_id, order_total, CASE WHEN order_total<50 THEN 'under_50' WHEN order_total<200 THEN '50_to_200' ELSE 'over_200' END AS price_bucket FROM orders) SELECT price_bucket, COUNT(*) AS order_count FROM labeled_orders GROUP BY price_bucket ORDER BY MIN(order_total)`.
- **GROUP BY price_bucket ONLY** — no unique `order_id` in GROUP BY → produces exactly 3 rows (one per band) with correct per-band COUNT(*). This is the SAME shape that was MISSED in iter941 Q3 lead.
- **Explicit anti-trap warning correctly given**: "if you write GROUP BY order_id, price_bucket you get one row per order with COUNT(*)=1 — not the 3-bucket summary." Matches pinned GROUP-BY-output-shape rule verbatim.
- **ORDER BY MIN(order_total)** VERIFIED VALID 467 (sql/select.html: "ORDER BY clause is evaluated after any GROUP BY or HAVING clause" — aggregate exprs allowed in ORDER BY of a grouped query; documented example `ORDER BY totalbal DESC` where totalbal is a sum() aggregate alias; bare-aggregate form equivalently valid).
- CTE-then-GROUP-BY-label form is canonical, copy-attractive, dialect-correct.

### Q2 — Busiest hour of day
- **Acc 5.00 / Comp 5.00 / Clar 5.00 / Act 5.00 = 5.00**
- `SELECT EXTRACT(HOUR FROM created_at) AS hour_of_day, COUNT(*) AS order_count FROM orders GROUP BY EXTRACT(HOUR FROM created_at) ORDER BY order_count DESC, hour_of_day ASC` — VERIFIED VALID 467 (datetime.html: `EXTRACT(HOUR FROM timestamp)` returns bigint; equivalent shorthand `hour(timestamp)` returns bigint 0-23).
- GROUP BY repeats the expression (NOT alias) — correct per pinned rule.
- ORDER BY uses SELECT alias `order_count` — VERIFIED VALID 467 (select.html ORDER BY references output columns).
- Deterministic tiebreaker `hour_of_day ASC` is a nice touch.
- Responder correctly notes EXTRACT returns bigint 0-23.

### Q3 — Average rating per product, products with >=10 reviews
- **Acc 5.00 / Comp 5.00 / Clar 5.00 / Act 5.00 = 5.00**
- `SELECT product_id, COUNT(*) AS review_count, AVG(rating) AS avg_rating FROM reviews GROUP BY product_id HAVING COUNT(*) >= 10 ORDER BY avg_rating DESC` — VERIFIED VALID 467 (select.html: "HAVING filters groups after groups and aggregates are computed" exact match).
- HAVING repeats `COUNT(*)` (NOT the alias `review_count`) — correct per pinned rule that HAVING cannot reference SELECT aliases.
- ORDER BY uses alias `avg_rating` — valid.
- WHERE-vs-HAVING pedagogy ("WHERE filters rows before grouping, HAVING filters grouped results") matches docs verbatim.

### Q4 — Customers with exactly one order
- **Acc 5.00 / Comp 5.00 / Clar 5.00 / Act 5.00 = 5.00**
- `SELECT customer_id FROM orders GROUP BY customer_id HAVING COUNT(*) = 1 ORDER BY customer_id` — canonical one-and-done idiom; HAVING COUNT(*) = N for per-group count filter (pinned, exact form).
- Detail variant with `MIN(order_id)`, `MIN(created_at)` surfaces the unique order's metadata while keeping group size = 1 — both MIN/MAX over a single-row group are well-defined and valid.
- Clean textbook.

## Overall

- **Per-Q: Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 5.00 → 20.00 / 4 = 5.00**
- **PASS** (margin +1.50 over 3.5 threshold; overall avg governs, no per-Q veto).
- FEDERATION NOT PROBED (4.49944/310 row UNCHANGED).
- All dialect verified vs trino.io/docs/467 (functions/datetime.html, sql/select.html) + WebFetch 2026-06-10 — NOT against resources/; iter882 verify-in-BOTH-directions discipline applied.

## ★ Q1 RE-PROBE VERDICT (explicit)

**GROUP-BY-muddle = ONE-OFF, did NOT recur.** The iter941 Q3 GROUP-BY-output-shape slip was a single-instance responder synthesis error, NOT a systemic gap. On the iter942 re-probe (same shape: per-bucket COUNT from a CASE-WHEN bucketization over a table with a unique key), the responder:

1. LED with GROUP BY the band-expression ONLY (`GROUP BY price_bucket`), no unique key.
2. Produced exactly 3 rows with correct per-band COUNT(*).
3. Explicitly WARNED against the wrong shape ("if you write GROUP BY order_id, price_bucket you get one row per order with COUNT(*)=1 — not the 3-bucket summary").

The GROUP-BY-output-shape rule taught at r07 L1905 / L2283 / L2677 / L2697 and reinforced across iter909/915/936 locks IS findable and IS being applied correctly under fresh probes. **The iter941 slip was the iter909/915/936 family 4th cumulative recurrence-with-intervening-clean-answers, and iter942 is the 1st clean re-probe confirming "ONE-OFF, slip closed."** No FIX-A needed.

## Defect scope

- **NO RESOURCE DEFECT.**
- **NO RESPONDER SLIP** on any question.
- **NO FINDABLE GAP.**
- All 4 answers dialect-clean, structurally correct, copy-attractive, with the explicit anti-trap warning on Q1 reinforcing the pinned GROUP-BY-shape rule.

## Action for next iteration

**iter943 = DEFAULT NO-OP** — teacher ZERO edits, no FIX-A, no "wrong" card, no churning. The GROUP-BY-output-shape rule is durable; the explicit anti-trap warning in Q1 ("don't GROUP BY order_id") shows the responder is now WARNING about the wrong shape proactively. Escalation threshold for a dedicated "per-bucket count canonical = GROUP BY bucket only, NOT unique-key+bucket" router card requires the slip to recur in 2+ further sweeps WITHOUT an intervening clean answer — iter942 resets the counter.

**Optional re-probes (NO pin touch, SKIP if duplicative):**
- Per-customer tenure-band COUNT (another per-bucket-count shape) to keep the rule durable.
- `width_bucket(x, ARRAY[...])` custom-bin probe (low-priority completeness — not required, defer unless asked).
- Federation (4.49944/310) only un-passed row — bulletproofed angles only.

## Pinned facts carried forward (verified iter942)

- Per-bucket count = `GROUP BY bucket-expr ONLY`, NOT unique-key+bucket (unique key collapses COUNT(*) to 1).
- CASE WHEN bucketing valid (repeat expr or ordinal in GROUP BY; no alias in GROUP BY).
- `width_bucket(x,min,max,n)` + `width_bucket(x,ARRAY[...])` exist (math.html).
- `EXTRACT(HOUR FROM ts)` + `hour(ts)` return bigint 0-23 (datetime.html).
- GROUP BY repeats expr, NOT alias.
- ORDER BY CAN use SELECT alias + CAN use aggregate exprs (including bare aggregates like `MIN(col)`) in a grouped query.
- HAVING runs after aggregation, repeats aggregate (cannot reference SELECT aliases).
- HAVING `COUNT(*) >= N` / `= N` for per-group count filters.
- WHERE before GROUP BY (row-level filter).
- AVG / MIN / MAX over groups; bare aggregate w/o GROUP BY = one scalar row.
- Default ORDER BY null ordering = NULLS LAST regardless of direction.

**DO NOT bump training/state.json** (already 942; passed=true preserved; overall 5.00 PASS holds).

PIN 467. NO federation edits. PRESERVE full iter534-941 pin inventory.
