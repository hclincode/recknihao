# iter922 Judge Feedback — NO-OP Durability Sweep

**Verdict: PASS — overall average 4.875 / 5 (19.5/4). NO-OP. Zero edits warranted for iter923.**

Phase: extended. Teacher made ZERO edits this iteration (durability/breadth sweep). All four probes are simple GROUP BY / aggregate / LEFT JOIN-CTE adjacents. Every dialect claim verified against trino.io/docs/467 (functions/aggregate.html + sql/select.html) via WebFetch 2026-06-10, Trino 467 PINNED. NOT verified against resources/.

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | late shipments per carrier | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | subscriptions per renewal_status | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | avg discount per product category | 5 | 4.5 | 5 | 5 | 4.875 |
| Q4 | count partially-refunded orders | 5 | 4.5 | 4.5 | 4.5 | 4.625 |

**Overall = (5.00 + 5.00 + 4.875 + 4.625) / 4 = 4.875 STRONG PASS.** OVERALL AVERAGE governs (no per-Q veto).

## Verification notes (Trino 467, docs-verified)

- **Q1** `SELECT carrier, COUNT(*) AS late_shipments FROM shipments WHERE actual_delivery_date > promised_date GROUP BY carrier` — CLEAN. WHERE filters late-delivery rows BEFORE grouping; GROUP BY carrier yields one row per distinct carrier; COUNT(*) ("Returns the number of input rows", aggregate.html) tallies late rows per carrier. select.html confirms GROUP BY "divides the output into groups of rows containing matching values" and the `count(*) ... GROUP BY nationkey` example. Correct.
- **Q2** `SELECT renewal_status, COUNT(*) FROM subscriptions GROUP BY renewal_status` — CLEAN. Grouping by the STATUS LABEL gives one row per status with per-bucket totals. Responder's note that putting a row-id (unique key) in GROUP BY would degenerate to COUNT(*)=1 per group is correct and a useful clarification. Correct.
- **Q3** `SELECT product_category, AVG(discount_amount) FROM order_lines GROUP BY product_category` — CLEAN. AVG GROUP BY valid; aggregate.html: "avg() does not include null values in the count" → rows with NULL discount_amount are skipped (numerator and denominator both exclude them), reasonable for "average discount given." Treating no-discount as 0 (COALESCE(discount_amount,0)) is a legitimate ALTERNATIVE interpretation, not a defect. Minor completeness ding (-0.5 Comp) for not surfacing the NULL-vs-zero interpretation choice explicitly — informative-not-wrong.
- **Q4** `WITH order_refunds AS (SELECT o.order_id, o.order_total, SUM(r.refund_amount) AS total_refunded FROM orders o LEFT JOIN refunds r ON r.order_id=o.order_id GROUP BY o.order_id, o.order_total) SELECT COUNT(*) FROM order_refunds WHERE total_refunded > 0 AND total_refunded < order_total` — CLEAN. CTE pre-aggregates multi-row refunds per order (SUM over the LEFT-JOINed refund rows). LEFT JOIN keeps no-refund orders (select.html: unmatched right columns → NULL); SUM of all-NULL = NULL (aggregate.html: "sum() returns null rather than zero"). Outer `total_refunded > 0` → NULL>0 yields NULL/not-true so no-refund orders are excluded; `total_refunded < order_total` excludes full refunds (=order_total). Net: isolates PARTIAL refunds exactly. Correct. Minor ding (-0.5 Comp/Clar/Act) only for not flagging the edge case where over-refunds (total_refunded > order_total) fall outside both partial and full buckets — a real-data nuance, not a logic error.

## Defect scan

No fabricated functions. No wrong signatures. No crossed-family idioms. No findability slips. No GROUP-BY muddle (contrast iter909/iter915 — those slips remain one-off/CLOSED; Q1/Q2 here lead with the correct shape). No prod-env conflict — pure standard SQL, on-prem Trino 467 + Iceberg 1.5.2 + MinIO + Hive Metastore + JWT/OPA unaffected.

## Directive for iter923

**iter923 = DEFAULT NO-OP / durability-breadth.** No open defect, no source-verified findable-but-missing gap, no dialect defect. Do NOT churn the passing aggregate/GROUP-BY/LEFT-JOIN cards.

Optional fresh adjacents to probe next sweep (confirm durability from new phrasings):
- COUNT(*) FILTER (WHERE …) vs WHERE-then-COUNT (single-pass conditional count).
- AVG with COALESCE(x,0) "treat absent as zero" phrasing (confirm responder surfaces the NULL-vs-zero choice).
- LEFT JOIN + SUM where over-refund (total_refunded > order_total) edge appears — confirm responder flags it.
- Multi-bucket CASE-aggregation (count partial/full/none refunds in one query via SUM(CASE)).

PRESERVE full iter534-921 pin inventory. NO federation edits (federation 4.49944/310, UNCHANGED — not probed this sweep).

**DO NOT bump training/state.json (already 922; passed=true preserved).**
