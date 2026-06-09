# Judge Feedback — iter789 (EXTENDED PHASE)

**Designation:** DEFAULT NO-OP / durability-breadth sweep (teacher made ZERO resource edits; 4 fresh adjacent probes hitting well-covered fundamentals).

**Overall: 4.984 / 5.00 — STRONG PASS** (per-Q avg 5.00 / 5.00 / 5.00 / 4.9375 = 19.9375 / 4; threshold 3.5; margin +1.484; overall avg governs, no per-Q veto).

All four dialect claims docs-verified vs trino.io/docs/467 (datetime.html, string.html) on 2026-06-09. ZERO new defects. All standing pins held clean.

---

## Q1 — Multi-column GROUP BY (totals per region-and-product combination)

Answer: `SELECT region, product, SUM(sales_amount) AS total_sales FROM sales_table GROUP BY region, product ORDER BY region, product`. One row per (region, product); "nothing special needed." Cites r23.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Per-Q avg** | **5.00** |

VERIFIED: Standard SQL, valid Trino. `GROUP BY region, product` produces exactly one row per distinct combination; every non-grouped column in SELECT is inside an aggregate (`SUM`). The "one row per combination" framing is correct and the redundant reassurance ("nothing special needed") is appropriate for a beginner who fears multi-column grouping is exotic. Clean.

## Q2 — Date arithmetic (add 14 days / 3 months to subscription_start as a real date)

Answer: `date_add('day', 14, subscription_start) AS trial_expiry_date`; `date_add('month', 3, subscription_start)`. Signature `date_add(unit, value, timestamp)`; returns DATE if input DATE, TIMESTAMP if input TIMESTAMP; compare to `current_date`/`current_timestamp`. Caveat: Oracle `ADD_MONTHS` month-end clamp NOT replicated (Feb-28 + 1 month → Trino gives Mar 28, not Mar 31). Cites r27 §4.1.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Per-Q avg** | **5.00** |

VERIFIED vs datetime.html: `date_add(unit, value, timestamp)` returns the **same type as its input** — DATE in → DATE out, TIMESTAMP in → TIMESTAMP out. The responder's "returns DATE if input DATE, TIMESTAMP if input TIMESTAMP" claim is exactly correct. `date_add('day', 14, ...)` and `date_add('month', 3, ...)` both valid. The Oracle `ADD_MONTHS` month-end-clamp caveat is accurate and high-value for this on-prem Oracle-migration audience (Trino does NOT apply Oracle's "last-day-of-month → last-day-of-month" rule; Feb-28 + 1 month → Mar-28). Directionally correct example, not over-stated. The `INTERVAL '14' DAY` alternative was not shown but is not required — date_add is the more beginner-legible form. Clean.

## Q3 — Blank/empty text (notes NULL, empty, or whitespace-only in one filter)

Answer: `WHERE notes IS NULL OR trim(notes) = ''`. Catches NULL + empty + whitespace-only (`trim` strips leading/trailing whitespace → `''`). Notes `trim(s)` is whitespace-only; char-set strip needs `trim([LEADING|TRAILING|BOTH] chars FROM s)`. Cites r27 §4.3.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Per-Q avg** | **5.00** |

VERIFIED vs string.html: single-arg `trim(varchar)` removes leading/trailing whitespace. So `trim(notes) = ''` is TRUE for both empty-string and whitespace-only rows; `IS NULL` catches NULL. The `OR` covers all three "effectively blank" cases in one filter exactly as asked. The trim disambiguator (single-arg = whitespace-only; char-set removal needs `trim(LEADING|TRAILING|BOTH chars FROM s)`) matches the standing trim pin and is docs-correct. Clean.

## Q4 — Timestamp diff in hours (hours between created_at and resolved_at per ticket)

Answer: `date_diff('hour', created_at, resolved_at) AS hours_to_resolve`. Signature `date_diff(unit, ts1, ts2)` = `ts2 - ts1` as BIGINT; earlier as arg2, later as arg3 (swap → negative). Also minute/day/second units. Cites r23 §3.1D.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 4.75 |
| Actionability | 5 |
| **Per-Q avg** | **4.9375** |

VERIFIED vs datetime.html: `date_diff(unit, timestamp1, timestamp2)` returns `timestamp2 - timestamp1` expressed in the given unit as **BIGINT**. `date_diff('hour', created_at, resolved_at)` = whole hours elapsed. Arg-order note (earlier = arg2, later = arg3, swap → negative) is accurate. The mention of minute/day/second units is helpful.

Minor (-0.25 Clarity, NOT a defect): `date_diff('hour', ...)` counts whole hour boundaries crossed, so a 90-minute gap returns `1`, not `1.5`. For fractional/precise hours the user would need `date_diff('minute', ...) / 60.0` or `date_diff('second', ...) / 3600.0`. The responder did not flag the whole-unit truncation, which a ticket-SLA user might assume yields decimals. Optional polish, not required and not a correctness error — the answer as written is accurate for "whole hours."

---

## Standing pins — all held clean (zero drift)

- multi-col-GROUP-BY (one row per combination) — HELD (Q1)
- date_add(unit, value, ts) returns input type (DATE→DATE / TS→TS) + ADD_MONTHS-no-clamp caveat — HELD (Q2)
- IS NULL OR trim(s)='' covers NULL/empty/whitespace-blank — HELD (Q3)
- trim single-arg = whitespace-only vs char-set `trim(LEADING|TRAILING|BOTH chars FROM s)` — HELD (Q3)
- date_diff(unit, ts1, ts2) = ts2-ts1 BIGINT, arg-order earlier→later — HELD (Q4)
- All iter534–788 locks — HELD.

## Teacher action / iter790 designation

**iter790 = DEFAULT NO-OP / durability-breadth sweep.** No open defect, no new imprecision, no resource edit required. PRESERVE r23 (multi-col GROUP BY, date_diff §3.1D) and r27 (date_add §4.1, blank-text trim §4.3) cards — verified clean, churn risk.

Optional (NOT required) low-priority inoculation for a future phrasing: in the r23 date_diff card, a one-line note that `date_diff` counts whole-unit boundaries (90 min → 1 hour) and to divide `date_diff('second',...)/3600.0` for fractional hours. Add only if a fractional-hours phrasing surfaces and scores below threshold; do not churn the card pre-emptively.

Suggested fresh adjacent probes for iter790: `date_trunc('month', ...)` month-bucketing, `last_day_of_month(...)`, `COALESCE` vs `IS NULL OR` for blank-default substitution, `to_unixtime`-diff for fractional duration.
