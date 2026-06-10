# Judge Feedback — iter971 (EXTENDED PHASE)

**Verification basis:** All dialect/logic claims verified BOTH directions against trino.io/docs/467 (functions/datetime.html) + WebFetch 2026-06-11 + pinned memory (TIMESTAMP→TZ coercion, division-by-zero). NOT against resources/. Q2 and Q4 TRACED on concrete examples for JOIN fan-out and denominator double-count. Prod stack: Trino 467 + Iceberg, on-prem — all four answers fit the stack (pure SQL).

## Per-question scores

### Q1 — auto-renew next calendar month — **4.88 CLEAN**
`WHERE auto_renew = true AND date_trunc('month', renewal_date) = date_trunc('month', current_date) + INTERVAL '1' MONTH`
- VERIFIED: `date_trunc('month', date)` returns same type as input → a DATE (e.g. 2026-06-01). `date + INTERVAL '1' MONTH` yields a TIMESTAMP per 467 docs (date+interval-month example returns timestamp). LHS is a date, RHS a timestamp; the equality holds via implicit DATE→TIMESTAMP coercion (TIMESTAMP-coercion pin) — a July renewal: LHS date_trunc=2026-07-01 coerced to 2026-07-01 00:00:00 = RHS. Logic (renewal falls in the next calendar month) is CORRECT, no string hacks, handles year-boundary (Dec→Jan) automatically.
- `auto_renew = true` boolean comparison valid. GROUP BY plan_type variant correct.
- Acc 5.0 / Clar 4.75 / App 5.0 / Comp 4.75. Tiny nit: could mention LHS date vs RHS timestamp coercion explicitly, but result is right.

### Q2 — refund/sales ratio per region — **2.50 JOIN FAN-OUT BUG (KEY CHECK, CONFIRMED)**
`FROM sales s LEFT JOIN refunds r ON s.region = r.region ... SUM(s.amount), SUM(r.amount) ... GROUP BY s.region`
- **CONFIRMED REAL many-to-many fan-out over-count.** TRACE — region X: sales rows {100,200,50} (3 rows), refund rows {10,20} (2 rows). LEFT JOIN on region alone → 3×2 = 6 rows for X.
  - `SUM(s.amount)` = (100+200+50)×2 = **700** (each sale repeated once per refund row — inflated by #refund rows).
  - `SUM(r.amount)` = (10+20)×3 = **90** (each refund repeated once per sale row — inflated by #sales rows).
  - True ratio = 30/350 = **8.57%**. Query ratio = 90/700 = **12.86%**. WRONG.
- The bug fires whenever a region has >1 sales row AND >1 refund row — i.e. the NORMAL case for "MANY rows each." The COALESCE(…,0) / NULLIF / 100.0* decimal mechanics are individually correct but are applied on top of cross-product-inflated SUMs, so the headline number is wrong. This is a LEAD-level accuracy defect, not a secondary aside.
- **CORRECT pattern:** pre-aggregate EACH table to one-row-per-region BEFORE joining:
  `WITH s AS (SELECT region, SUM(amount) gross FROM sales GROUP BY region), r AS (SELECT region, SUM(amount) refunds FROM refunds GROUP BY region) SELECT s.region, s.gross, COALESCE(r.refunds,0), COALESCE(r.refunds,0)*100.0/NULLIF(s.gross,0) FROM s LEFT JOIN r ON s.region=r.region`.
- **RESOURCE-vs-SLIP = RESPONDER SYNTHESIS SLIP, NO resource defect.** Resources teach the fan-out trap and the pre-aggregate-in-CTEs-before-join canonical (r23 fan-out guidance + many-side/one-side). The responder mis-assembled (joined raw then SUMmed) rather than missing knowledge.
- **FAN-OUT-FAMILY RECURRENCE ASSESSMENT:** iter958 muddled-then-self-corrected, iter959 correct, now iter971 a clean FALL-IN on the SAME specific construct (SUM over a fanned multi-table join). This is the 2nd defective instance of the SUM-over-cross-product construct within recent sweeps (intermittent: iter959 was correct in between). NOT yet a 2-in-2 consecutive recurrence. Recommendation: RE-PROBE the two-many-tables ratio construct next sweep before any resource action. If it FAILS again next sweep (would be 2 consecutive defective instances of pre-aggregate-before-join), escalate to a LIGHT FIX-A / findability router toward the per-table-CTE pattern. Do NOT churn now.
- Acc 1.5 (headline number wrong on the normal case) / Clar 3.5 (well-explained but explains a wrong query) / App 2.5 (copyable but produces wrong ratios) / Comp 2.5 (addresses the no-refund-region edge correctly via LEFT JOIN+COALESCE, but core math broken).

### Q3 — most signups by day of week — **4.81 CLEAN**
`day_of_week(created_at)` + CASE 1→Monday … 7→Sunday + COUNT(*) GROUP BY/ORDER BY the expression; top-day LIMIT 1 CTE variant.
- VERIFIED: `day_of_week()` returns ISO 1=Monday..7=Sunday (467 docs, matches pin — NOT Postgres 0=Sunday). CASE mapping 1→Monday..7→Sunday is CORRECT.
- VERIFIED: Trino 467 has NO `dayname()` (not in datetime function list — correct to disclaim). `format_datetime(CAST(created_at AS timestamp),'EEEE')` is valid: format_datetime uses JodaTime DateTimeFormat where 'EEEE' = full text day name. Correct alternative.
- GROUP BY / ORDER BY on the `day_of_week()` expression is valid Trino. Top-day variant ordered by signup_count DESC LIMIT 1 correct.
- Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75. The Postgres-vs-ISO disambiguation is a genuine value-add.

### Q4 — share of orders per payment method — **3.13 FALSE-JUSTIFICATION + METRIC REDEFINITION**
`payment_method_orders` CTE: `COUNT(DISTINCT order_id) per method`; `totals` CTE: `SUM(order_count)`; final pct = order_count*100.0/total_orders.
- **NUMERATOR CORRECT:** `COUNT(DISTINCT order_id)` per method correctly dedups a multi-row method and counts unique orders using each method. Good dedup insight.
- **DENOMINATOR WRONG + FALSE CLAIM.** TRACE — Order#1 uses {credit_card, paypal}; Order#2 uses {credit_card}. True total orders = 2. Per-method counts: cc=2, paypal=1. `SUM(order_count)` = 3 ≠ 2. Order#1 is counted in BOTH the cc bucket AND the paypal bucket, so the responder's claim "every order contributes to exactly one denominator count (total_orders)" is **FALSE** — order#1 contributes to two buckets. The denominator is the sum of bucket memberships, not the distinct order count.
- Result: percentages sum to 100% (cc=2/3=66.7%, paypal=1/3=33.3%) but they represent "share of (order,method) MEMBERSHIPS," NOT "share of orders that USED method X." The responder silently REDEFINED the metric to force a 100% total, then defended it with a false justification.
- **CORRECT answer for the question as asked:** numerator = COUNT(DISTINCT order_id) per method; denominator = COUNT(DISTINCT order_id) over the WHOLE payments table (= true total distinct orders, 2). Then cc=2/2=100%, paypal=1/2=50% — these LEGITIMATELY sum to >100% because "used method X" is a non-mutually-exclusive metric, and that is the honest answer. The responder should have explained why >100% is correct here, not engineered it away.
- **RESOURCE-vs-SLIP = RESPONDER REASONING SLIP, NO resource defect.** Resources teach COUNT(DISTINCT) + share-of-true-total correctly; the responder reached past it with a wrong denominator + false supporting claim. False-justification-claim family.
- Acc 2.5 (right numerator/dedup; wrong denominator + false "exactly one count" claim) / Clar 3.5 / App 3.5 (CTE structure copyable; numbers answer the wrong question) / Comp 3.0 (misses the actual asked metric and the legitimate-sum-over-100% nuance).

## Overall

| Q | Acc | Clar | App | Comp | Q-avg |
|---|----|----|----|----|----|
| Q1 | 5.0 | 4.75 | 5.0 | 4.75 | 4.88 |
| Q2 | 1.5 | 3.5 | 2.5 | 2.5 | 2.50 |
| Q3 | 5.0 | 4.75 | 4.75 | 4.75 | 4.81 |
| Q4 | 2.5 | 3.5 | 3.5 | 3.0 | 3.13 |

**OVERALL = (4.88 + 2.50 + 4.81 + 3.13) / 4 = 15.32/4 = 3.83 PASS** (overall average governs; threshold 3.5; margin +0.33, thin). No per-Q veto.

## Scope notes
- **Q2 = the headline finding:** confirmed real many-to-many JOIN fan-out — SUM over a raw multi-table cross-product inflates both numerators (×#refund rows) and denominators (×#sales rows); the ratio is wrong for any region with >1 row in both tables (the normal case). RESPONDER synthesis slip (resources teach pre-aggregate-before-join). Fan-out-family: iter958 muddled-self-corrected / iter959 correct / iter971 fall-in = intermittent, NOT 2-in-2 consecutive. RE-PROBE the two-many-tables ratio next sweep; LIGHT FIX-A only if it recurs consecutively.
- **Q4 = false-justification + metric redefinition:** numerator (COUNT(DISTINCT order_id) per method) correct; denominator SUM(order_count) double-counts multi-method orders; the claim "every order contributes to exactly one denominator count" is FALSE. Correct = COUNT(DISTINCT order_id) over whole table as denominator, shares legitimately >100%. RESPONDER reasoning slip; resources guard it.
- Q1 + Q3 CLEAN, both verified against 467 docs (date_trunc type-preserving + date+interval-month coercion; day_of_week 1=Mon ISO + no dayname + format_datetime 'EEEE' Joda).
- No QUALIFY / semi-join-mislabel / MAX(varchar)-as-latest / percent_rank-inversion / fabricated-function / mid-churn / missing-column-in-CTE slips this sweep.
- Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).
- NO resource edits warranted this iteration. state.json NOT bumped (already 971; passed=true preserved).

## iter972 recommendation
DEFAULT NO-OP. Re-probe: (a) another two-many-tables ratio/division Q to confirm whether the SUM-over-fanned-join pre-aggregate construct is intermittent or hardening into a recurrence; (b) another non-mutually-exclusive share Q (multi-label membership) to confirm whether the responder reaches the COUNT(DISTINCT total) denominator + accepts a legitimate >100% sum, or re-redefines the metric. Escalate to LIGHT FIX-A only on a 2-in-2 consecutive recurrence of either.
