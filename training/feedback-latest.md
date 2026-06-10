# iter964 Judge Feedback — 2026-06-11 (EXTENDED PHASE)

**OVERALL: 4.21875 PASS** (Q1 4.5 / Q2 4.6875 / Q3 3.0625 / Q4 4.625 = 16.875/4; margin +0.71875). OVERALL AVERAGE governs — NO per-Q veto. Q3 is the weak answer but does not sink the iteration.

Production env: on-prem Trino 467 + Iceberg/Hive Metastore, MinIO, Spark ingest, dbt. All 4 Qs are pure SQL-pattern questions — no auth/federation/DDL surface touched. Federation row (4.49944/310) UNCHANGED; r22 §13.x hard-locked, NOT probed (OVERRIDDEN per run-prompt).

All dialect/logic verified BOTH directions vs trino.io/docs/467 + git-tag 467 + WebSearch 2026-06-11 (NOT against resources/). iter882 verify-both-directions discipline.

---

## Q1 — Coupons never redeemed (anti-join) — **4.5**
Acc 4.5 / Comp 4.5 / Clar 4.5 / Act 4.5.
- LEAD CORRECT: `LEFT JOIN coupons c -> orders o ON c.coupon_id = o.coupon_id WHERE o.coupon_id IS NULL` is the canonical anti-join; `NOT EXISTS` form also correct and NULL-safe. Both answer "clean query or join+filter" directly.
- MINOR (Acc -0.5): the aside "NOT EXISTS sometimes slightly faster when the subquery is non-correlated" is loosely worded — the EXISTS subquery here IS correlated (references `c.coupon_id`); Trino decorrelates IN/EXISTS to a SemiJoin/AntiJoin regardless. Imprecise but not flatly wrong; same false-mechanism-padding meta-pattern (iter960/963 family). Per-instance, NOT a resource defect.
- VERIFIED: LEFT JOIN/IS NULL anti-join + NOT EXISTS NULL-safe both valid 467.

## Q2 — Gap > 7 days between consecutive logins (LAG) — **4.6875**
Acc 4.75 / Comp 4.75 / Clar 4.75 / Act 4.5.
- TEXTBOOK-CORRECT, LEGITIMATE use of LAG. `LAG(login_date) OVER (PARTITION BY user_id ORDER BY login_date)` + `date_diff('day', prev_login_date, login_date) > 7` filtering `prev_login_date IS NOT NULL`.
- This is NOT the iter961 LAG-as-of misuse and NOT a gaps-and-islands always-zero construction. It is exactly the right tool for "gap between two CONSECUTIVE logins."
- TRACED user logins [Jan1, Jan5, Jan20]: gaps = NULL, 4, 15 → flags the Jan5->Jan20 pair (15 > 7). Correct.
- VERIFIED: `date_diff('day', a, b)` is unit-first (functions/datetime.html); TIMESTAMP works with the same 'day' unit. NO QUALIFY used (WITH CTE shape, valid 467).
- The resource CITATION name-drops "gaps-and-islands" but the QUERY is correct consecutive-pair gap detection — did NOT ding the query for the citation label.
- Trivial Act note: didn't elaborate scale/partition-pruning for "millions of rows" beyond the partitioned window — negligible.

## Q3 — Orders by fulfillment status without double-counting multi-parcel orders — **3.0625** (WEAK)
Acc 2.5 / Comp 3.5 / Clar 2.75 / Act 3.5.
TRACE: order 7 has parcels [shipped, delivered, shipped].
- **(a) Abandoned FIRST form is WRONG for differing statuses.** `SELECT DISTINCT order_id, fulfillment_status ... GROUP BY fulfillment_status` yields TWO distinct pairs for order 7: (7, shipped) and (7, delivered) -> order 7 counted in BOTH the 'shipped' AND 'delivered' buckets -> STILL double-counts the order across statuses. Does NOT solve the stated problem.
- **(b) FINAL form dedups to one-row-per-order** (`MAX(fulfillment_status) GROUP BY order_id` -> outer GROUP BY status) — this DOES avoid the cross-status double-count (one status per order). Partially right on the headline ask.
- **(c) BUT MAX-as-latest is MISLABELED.** VERIFIED vs trino.io/docs/467: `MAX(varchar)` is LEXICOGRAPHIC/alphabetical, NOT temporal. Trace order 7: MAX('shipped','delivered') — 'd' < 's' so MAX = 'shipped', arbitrary w.r.t. real fulfillment progression ('delivered' is the later real-world state). The comment "picks the latest/max status" CONFLATES alphabetical-max with temporal-latest — a real factual mislabel. (Confirmed via comparison.html `'Paul' BETWEEN 'John' AND 'Ringo' = true` + aggregate.html "max returns the maximum value" with lexicographic varchar comparison.)
- **(d) Visible mid-answer churn** ("Wait — that's not quite right") after a failed max_by attempt — Clarity ding (presentation).
- **CORRECT answer**: needs a DEFINED order-level status — `max_by(fulfillment_status, updated_at)` for true latest, OR a priority/severity CASE ranking, OR an all-parcels-delivered aggregation if that's the business rule.

**RESOURCE-vs-SLIP DETERMINATION = PURE RESPONDER SYNTHESIS SLIP, NOT a resource defect.**
Grep confirms resources teach the CORRECT idiom for exactly this shape: r23 L1298 worked example "latest status per order (deterministic by `updated_at`)" uses `max_by(status, updated_at) AS latest_status`; r23 L1346 mapping table "value of x associated with the largest value of sortable y (e.g. latest status by updated_at) -> `max_by(x, y)`, deterministic by y"; r23 L1383 explicitly warns `arbitrary(status)` is the WRONG TOOL for latest status. NO resource teaches `MAX(varchar) = latest`. The only `MAX(...) AS latest` hit in resources (r23 L1765 `MAX(reading_time)`) is over a TIMESTAMP column where MAX legitimately = latest time — a different, correct use. The responder reached PAST the correct, findable `max_by(status, updated_at)` canonical and substituted lexicographic `MAX(varchar)` with a wrong "latest" label. This is the broken-secondary / wrong-construct meta-pattern (iter936/943/948/950/954/958/959/960/961/963 family) on an admittedly-ambiguous question — per-instance Haiku synthesis miss, NOT a content/findability gap. **Re-probe, do NOT churn.**

## Q4 — % sessions ending in a purchase (suspected double-count) — **4.625**
Acc 4.75 / Comp 4.5 / Clar 4.75 / Act 4.5.
- Form A (DISTINCT session_id CTE + scalar-subquery ratio) CORRECT. Form B (the "elegant" one) CORRECT and directly diagnoses the user's double-counting.
- VERIFIED Form B: `COUNT(DISTINCT o.session_id)` over `sessions s LEFT JOIN orders o ON s.session_id = o.session_id` — sessions with no order produce NULL `o.session_id`; COUNT(DISTINCT) IGNORES NULL (aggregate.html: count/count_if/max_by/min_by/approx_distinct are the NULL exceptions; count ignores NULL) so numerator = distinct purchasing sessions; denominator `COUNT(DISTINCT s.session_id)` = all sessions; LEFT-JOIN fan-out (multi-order sessions) collapsed by DISTINCT; `100.0 * .../...` forces decimal promotion (verified). Correct.
- The "COUNT(o.session_id) WITHOUT DISTINCT inflates when a session has many orders" explanation is CORRECT and precisely names the user's reported symptom. Strong actionable diagnosis.

---

## SCOPE / RECOMMENDATION for iter965
- **iter965 = DEFAULT NO-OP breadth sweep.** Overall 4.21875 PASS, margin +0.72. No resource defect, no findability gap surfaced.
- Q1 anti-join solid (minor NOT-EXISTS-correlation imprecision = false-mechanism padding, per-instance). Q2 textbook-correct LAG consecutive-gap (NOT the iter961 as-of misuse — clean). Q4 COUNT(DISTINCT)-over-LEFT-JOIN ratio + inflation diagnosis clean.
- **Q3 = the one weak answer**: dedups to one-row-per-order (avoids the cross-status double-count) BUT mislabels lexicographic `MAX(varchar)` as temporal "latest" + abandoned first DISTINCT-pair form is wrong for differing statuses + visible churn. PURE RESPONDER SYNTHESIS SLIP — resources teach the correct `max_by(status, updated_at)` canonical (r23 L1298/L1346) and warn against wrong-tool picks (L1383). Adding more would risk adjacent over-attraction per feedback_new_card_over_attracts_adjacent.md and addresses no content gap.
- **Optional LIGHT FIX-A only if** the MAX(varchar)-as-latest mislabel (or a parcel/order-level status-collapse that picks lexicographic-MAX instead of max_by) RECURS on a different surface in the next 2 sweeps. If so: reinforce ONE inline note at the existing r23 max_by canonical (L1298 area) that `MAX(varchar)` is ALPHABETICAL not temporal — use `max_by(status, ts)` for "latest status"; brief, no isolated DO-NOT-WRITE snippet (feedback_defang_donotwrite_snippets.md).
- **NEXT SWEEP PROBES**: re-probe a "latest status per group with multiple sub-rows" / collapse-to-one-row dedup Q (confirm Q3 MAX-vs-max_by slip is a one-off — verify responder reaches for `max_by(status, updated_at)` not `MAX(varchar)`); GROUPING SETS / CUBE; window frame BETWEEN N PRECEDING AND N FOLLOWING (centered) + RANGE INTERVAL; lateral JOIN UNNEST; EXCEPT / anti-membership. Do NOT re-probe gaps-and-islands streak-construction.

## PINS REINFORCED
- **Anti-join "never matched"**: `LEFT JOIN b ON a.k=b.k WHERE b.k IS NULL` (+ SELECT DISTINCT if needed) or `NOT EXISTS` (NULL-safe); both valid 467. "NOT EXISTS faster when non-correlated" is loose padding — the EXISTS here IS correlated; Trino decorrelates IN/EXISTS to SemiJoin/AntiJoin regardless.
- **Consecutive-pair gap detection** (LEGITIMATE LAG use): `LAG(date_col) OVER (PARTITION BY k ORDER BY date_col)` + `date_diff('day', prev, curr) > N`, filter `prev IS NOT NULL`. date_diff is unit-first. This is NOT as-of (iter961) and NOT gaps-and-islands; it is correct. NO QUALIFY in 467.
- **Latest status per group / collapse multi-row to one status**: use `max_by(status, updated_at)` (r23 L1298/L1346) — deterministic by the timestamp. **`MAX(varchar)` is LEXICOGRAPHIC/alphabetical, NOT temporal-latest** (verified comparison.html + aggregate.html); labeling `MAX(status)` as "latest status" is a factual mislabel. DISTINCT (order_id, status) then GROUP BY status STILL double-counts an order across differing statuses.
- **Conversion-rate / % ratio over a join**: `COUNT(DISTINCT b.k)` over `a LEFT JOIN b` — COUNT(DISTINCT) IGNORES NULL (count is one of the NULL-exception aggregates) so non-matching rows drop from numerator; `100.0 * num/den` forces decimal promotion. `COUNT(b.k)` WITHOUT DISTINCT inflates when one a-row fans out to many b-rows.
- **Broken-secondary / false-mechanism / wrong-construct meta-pattern (iter936/943/948/950/954/958/959/960/961/963/964 family) persists** — LEADS routinely correct, tacked-on aside or substituted construct ships an imprecise/wrong claim (Q1 NOT-EXISTS-correlation, Q3 MAX-as-latest); per-instance Haiku slip, NOT a resource defect.
- **default NULLS LAST in 467.**

Federation (4.49944/310) only un-passed-margin row — bulletproofed angles only. PRESERVE full iter534-963 pin inventory; NO federation edits. PIN 467. DO NOT bump training/state.json (already 964; passed=true preserved; overall 4.21875 PASS holds; final_iterations_remaining 0).
