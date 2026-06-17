# iter980 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.64 STRONG PASS** (Q1 4.75 / Q2 4.75 / Q3 4.3125 / Q4 4.75 = 18.5625/4 = 4.6406; margin +1.14; OVERALL AVERAGE governs, no per-Q veto).

All 4 dialect/logic claims verified BOTH directions vs trino.io/docs/467 (functions/window.html row_number()="unique sequential number ... starting with one, according to the ordering"; functions/aggregate.html count(x)="number of non-null input values" + "all aggregate functions ignore null values" w/ five named exceptions count/count_if/max_by/min_by/approx_distinct → avg & min ignore NULL; min_by/max_by exist) + WebSearch QUALIFY-absence 2026-06-17 — NOT against resources/. Q1/Q2/Q3/Q4 logic TRACED on concrete examples. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — answers fit.

---

## Q1 — Second-most-recent login per user (clean way or self-join?) — 4.75 CLEAN
`SELECT user_id, login_timestamp FROM (SELECT user_id, logged_at AS login_timestamp, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY logged_at DESC) AS rn FROM user_events WHERE event_name='login') WHERE rn = 2`.

- VERIFIED row_number() starts at 1 in the ORDER BY ordering (window.html). DESC → rn1 = most recent, rn2 = second-most-recent.
- **TRACE** [Jan1, Jan5, Jan20]: ORDER BY logged_at DESC → Jan20=rn1, Jan5=rn2, Jan1=rn3 → `rn=2` returns Jan5, the **second-most-recent** — CORRECT.
- Correctly explains <2 logins → user absent from result (no rn=2 row). Correct.
- **QUALIFY-absent claim VERIFIED** (Trino 467 has no QUALIFY; subquery-wrap is the canonical Nth-per-group form). Legitimate guard, NOT the false-mechanism tic.
- Correctly generalizes: =1 for latest, <=5 for top-5; implies **max_by gives only the single latest** (not the 2nd) — accurate, max_by(x,y) returns value at the single MAX y.

Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — Distinct IPs per account over past 90 days — 4.75 CLEAN
`SELECT account_id, COUNT(DISTINCT ip_address) AS unique_ips FROM login_events WHERE logged_at >= current_date - INTERVAL '90' DAY GROUP BY account_id`.

- **VERIFIED COUNT(DISTINCT x) ignores NULL** (aggregate.html count(x)="non-null input values") → NULL IPs skipped. Responder's "DISTINCT+COUNT skip NULL IPs" CORRECT.
- `INTERVAL '90' DAY` valid 467 (DAY is a supported interval qualifier; not the QUARTER/WEEK parse-error trap).
- **90-day window CARRIED THROUGH** to aggregation (WHERE filters input rows before GROUP BY) — not dropped; partition-pruning framing accurate for a bare/coerced timestamp predicate.

Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q3 — Split revenue NEW (first order) vs RETURNING — 4.3125 (single minor comp ding: exact-tie edge)
`CASE WHEN created_at = MIN(created_at) OVER (PARTITION BY customer_id) THEN 'new' ELSE 'returning' END`; then `WITH tagged_orders AS (...) SELECT customer_type, SUM(order_total), COUNT(*) GROUP BY customer_type`.

- **TRACE** customer with orders t1<t2<t3: MIN() OVER = t1 for all rows; CASE created_at=t1 → 'new' (the t1 row), else 'returning' (t2,t3). SUM(order_total) GROUP BY customer_type splits first-order revenue ('new') from later-order revenue ('returning') — CORRECT.
- No self-join, no fan-out; MIN() OVER (PARTITION BY customer_id) = per-row customer-earliest-order ts — correct as-of mechanism.
- CTE column scope CLEAN (tagged_orders projects all referenced cols).
- **MINOR COMP ding (per directive, do NOT heavily ding):** exact-timestamp ties — if a customer has 2 orders at the identical MIN(created_at), BOTH match the CASE and tag 'new' (slight over-count of 'new' revenue). Strictly-precise form: ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at, order_id)=1 → 'new', or a created_at+order_id tiebreaker. Acceptable common simplification; responder did not surface the tie. Comp ding only.

Acc 4.5 / Clar 4.5 / App 4.25 / Comp 4.0.

## Q4 — Average order value, subtotal only, some tax NULL (just AVG(subtotal)?) — 4.75 CLEAN
`SELECT AVG(subtotal) AS avg_order_value FROM checkout` (+ GROUP BY store_id variant).

- **VERIFIED avg ignores NULL** (aggregate.html, avg not among the five exceptions) — but moot since subtotal always populated.
- KEY: tax_amount NULLs are **irrelevant** because tax is NOT in the AVG expression. Responder correctly explains "AVG(subtotal) ignores the tax column entirely."
- **Correctly AVOIDS the AVG(subtotal+tax) NULL-poisoning trap** (a NULL tax would null the per-row sum and drop that row from the average) — exactly the right caution.

Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## SCOPE NOTES
- Q1 ROW_NUMBER()=2-in-subquery = canonical Nth-per-group; QUALIFY correctly flagged absent; max_by correctly noted as single-latest-only. CLEAN.
- Q2 COUNT(DISTINCT) NULL-skip + INTERVAL '90' DAY + 90-day window carried. CLEAN.
- Q3 MIN() OVER first-order classification CORRECT; lone item = unaddressed exact-timestamp tie (BOTH rows tag 'new') — acceptable simplification, minor comp ding NOT a logic defect.
- Q4 AVG(subtotal) correct; NULL tax irrelevant (not in expr); avoids AVG(subtotal+tax) poisoning. CLEAN.

## TICS — ALL CLEAN
No QUALIFY-misuse (Q1 correctly says absent) / no false-mechanism-semi-join mislabel / no MAX(varchar)-as-latest (Q1 used ROW_NUMBER, noted max_by=single-latest) / no percent_rank inversion / no fabricated fn-or-rule-or-issue# / no PARTITIONED-BY foreign DDL / no broken-secondary-alternative / no false-justification perf aside / no mid-churn / no missing-column-in-CTE (Q3 CTE projects all) / no JOIN-fan-out / no ts-minus-ts.

## RECOMMENDATION — DEFAULT NO-OP
Margin +1.14; the lone non-clean item (Q3 exact-timestamp tie) is an acceptable common simplification, NOT a resource/findability gap. Three of four answers fully clean. Re-probe next sweep:
- (a) another Nth-per-group / "2nd-most-recent" Q (ROW_NUMBER()=N subquery stays clean; QUALIFY stays correctly-absent),
- (b) another first-event-vs-rest classification Q — does responder surface the exact-tie tiebreaker (ROW_NUMBER ORDER BY ts, id) when ties matter? (deferring/omitting acceptable for a non-strict ask).

Federation r22 §13.x hard-locked, NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 980; passed=true preserved; final_iterations_remaining 0).
