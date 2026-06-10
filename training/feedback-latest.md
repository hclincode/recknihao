# Iter 936 Feedback — DEFAULT NO-OP durability sweep (teacher ZERO edits)

**Overall**: 4.625 PASS (Q1 5.00 / Q2 3.875 / Q3 5.00 / Q4 4.625 = 18.50/4 = 4.625; margin +1.125 over 3.5 threshold; OVERALL AVERAGE governs, no per-Q veto).

**Federation NOT probed** (4.49944/310 row UNCHANGED).

All dialect claims verified vs trino.io/docs/467 (functions/aggregate.html, functions/window.html, functions/datetime.html, sql/select.html, language/types.html) + Trino git-tag 467 source signals + WebSearch/WebFetch 2026-06-10 — NOT against resources/; iter882 verify-first applied BOTH directions.

---

## Per-question scores

### Q1 — accounts with >=1 overdue 'unpaid' invoice
**Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = 5.00 CLEAN**

`SELECT COUNT(DISTINCT account_id) FROM invoices WHERE due_date < CURRENT_DATE AND status='unpaid'` — fully correct.

- VERIFIED `CURRENT_DATE` is a built-in returning the current date (datetime.html: "Returns the current date as of the start of the query").
- VERIFIED `CAST(CURRENT_TIMESTAMP AS DATE)` is valid for timestamp due_date (datetime.html: `date(x)` is alias for `CAST(x AS date)`).
- VERIFIED `date < current_date` comparison valid (same-type orderable).
- VERIFIED COUNT(DISTINCT x) single-arg form valid (standing pin).
- DISTINCT correctly dedups accounts with multiple overdue invoices; `status='unpaid'` correctly excludes NULL status (3VL). Bonus `SELECT DISTINCT account_id` alternative apt.

### Q2 — first AND most-recent order date per customer
**Acc 3.5 / Comp 4.5 / Clar 3.5 / Act 4.0 = 3.875 (proportional ding for misleading first-draft framing; correct lead delivered)**

The DELIVERED/RECOMMENDED answer is the clean canonical: `SELECT customer_id, MIN(created_at) AS first_order_date, MAX(created_at) AS most_recent_order_date FROM orders GROUP BY customer_id` — fully correct, idiomatic min/max-per-group.

★ **DEFECT: the throwaway FIRST form is presented as merely "more verbose than necessary" when it is actually a PARSE/SEMANTIC ERROR.** The responder wrote a SELECT with `first_value(...) OVER (...) AS first_order_date` and `last_value(...) OVER (...) AS most_recent_order_date` and then placed those same `first_value(...) OVER (...)` / `last_value(...) OVER (...)` window-function expressions INSIDE the GROUP BY clause. VERIFIED Trino 467 rejects this: window functions are evaluated AFTER GROUP BY/HAVING, so a window function CANNOT appear in GROUP BY — Trino raises a semantic error of the form "GROUP BY clause cannot contain aggregations, window functions or grouping operations" (cf. trinodb/trino #25984 and pinned dialect fact). So the framing "Actually that's more verbose than necessary" UNDER-STATES the problem: a reader who copies the first block hits an error, not a verbose-but-valid query.

VERIFY-BOTH-DIRECTIONS: (a) the FIRST form IS broken — confirmed; (b) the SECOND/lead-recommended form IS valid + correct — confirmed; min/max(created_at) GROUP BY customer_id is the canonical pattern (also a strong simplification — no need for window functions at all for this question).

SCOPE = **RESPONDER SLIP on taught content (synthesis/presentation slip on an optional throwaway draft), NOT a findable resource gap**: resources already teach (i) MIN/MAX per group as the canonical first/last-per-customer pattern; (ii) the window-function-evaluation-order rule and the GROUP-BY-cannot-contain-window-function constraint; (iii) the default-frame trap for `last_value` (which is itself a separate gotcha the responder side-stepped by not relying on the OVER form). The correct answer WAS delivered as the LEAD recommendation; only the "more verbose than necessary" characterization of the discarded draft is wrong. → RE-PROBE-DON'T-CHURN, NO FIX-A this iter. If a future probe asks "first AND last in one row" and the responder again presents a window-in-GROUP-BY draft as merely "verbose", escalate (2nd instance) to a small router card under the first/last-per-group neighborhood that explicitly states "window functions cannot appear in GROUP BY (semantic error), prefer MIN/MAX-per-group for first/last-by-time questions."

### Q3 — most popular product category per region (argmax-per-group)
**Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = 5.00 CLEAN**

`SELECT region, max_by(category, order_count) FROM (SELECT region, category, COUNT(*) AS order_count FROM orders GROUP BY region, category) GROUP BY region` — fully correct argmax-per-group shape.

- VERIFIED `max_by(x, y)` returns x at max y (aggregate.html: "Returns the value of `x` associated with the maximum value of `y` over all input values").
- VERIFIED nested subquery shape: inner COUNT(*) GROUP BY (region, category) computes per-(region, category) order counts, outer max_by(category, order_count) GROUP BY region selects the category at the max count per region — canonical argmax-per-group pattern.
- VERIFIED `max_by(category, ROW(order_count, category))` tie-break form: ROW types in Trino 467 are comparable/orderable when their fields are (PR #4647 simplifies comparable/orderable type operators); bigint+varchar are both orderable; ROW comparison is lexicographic by field order, so `ROW(order_count, category)` first sorts by count, then breaks ties by category for deterministic ordering. Responder's tie-break framing is correct.
- Arbitrary tie behavior of plain max_by also correctly flagged.

### Q4 — avg line items per order for orders with total > $100
**Acc 4.75 / Comp 4.5 / Clar 4.5 / Act 4.75 = 4.625 (small ding for the awkward first draft, lead-recommended form correct)**

The DELIVERED/RECOMMENDED answer is the clean canonical:
```
SELECT AVG(line_item_count) FROM (
  SELECT o.order_id, COUNT(ol.order_id) AS line_item_count
  FROM orders o INNER JOIN order_lines ol ON o.order_id = ol.order_id
  WHERE o.total_amount > 100
  GROUP BY o.order_id
)
```

- VERIFIED nested aggregate: inner per-order COUNT(*)-style aggregate, outer AVG over the subquery with NO GROUP BY — a bare aggregate query without GROUP BY collapses to ONE scalar row (standard SQL + Trino behavior); the discarded `GROUP BY CAST(1 AS BIGINT)` "dummy grouping" the responder rejected was unnecessary AND the responder correctly removed it.
- VERIFIED INNER JOIN excludes orders with no line items (zero-count orders excluded); LEFT JOIN alternative correctly flagged for the inclusive interpretation.
- VERIFIED `WHERE o.total_amount > 100` is pre-aggregation row-filter (correct placement; HAVING would be wrong). "Pushed down/sargable" framing approximately correct (Trino can push the total_amount predicate into the orders scan).
- `COUNT(ol.order_id)` counts non-NULL matched line-item rows per order; since `ol.order_id` is the join key (always present in matched rows), it behaves identically to `COUNT(*)` here.

★ **MINOR DEFECT: the throwaway first draft included `GROUP BY CAST(1 AS BIGINT)` ("dummy grouping") which the responder labeled merely "awkward" before discarding.** The dummy GROUP BY is not an ERROR per se (grouping by a constant produces one group, same result as no GROUP BY) but the framing as "awkward" rather than "unnecessary / a bare aggregate with no GROUP BY already collapses to one scalar row" is a slight clarity miss. Proportional small ding only because the lead-recommended form IS the clean correct shape.

SCOPE = RESPONDER SLIP on taught content (presentation/draft polish), NOT a findable resource gap. The bare-aggregate-no-GROUP-BY-collapses-to-one-row fact is already implicit across many resources via dozens of `SELECT COUNT(*) FROM t` / `SELECT AVG(x) FROM t` examples. RE-PROBE-DON'T-CHURN.

---

## Defect scope summary

- **Q1**: NO defect — clean.
- **Q2**: RESPONDER SLIP on taught content (window-fn-in-GROUP-BY presented as "verbose" not "broken" on a discarded first draft; lead-recommended form correct). NO findable gap; resources teach the rule + the canonical MIN/MAX-per-group answer. RE-PROBE-DON'T-CHURN. 1st instance of this specific framing-slip → escalate ONLY if recurs (2nd instance) — small router card under first/last-per-group neighborhood.
- **Q3**: NO defect — clean argmax-per-group with correct ROW tie-break.
- **Q4**: RESPONDER SLIP on taught content (dummy-GROUP-BY-CAST(1 AS BIGINT) framed as "awkward" not "unnecessary"; lead-recommended form correct). NO findable gap.

NO RESOURCE DEFECTS. NO FINDABLE GAPS. NO FIX-A.

---

## iter937 directive — DEFAULT NO-OP

- Teacher ZERO edits this iter (already zero).
- DO re-probe a "first-and-last-per-group" / "earliest-and-latest-in-one-row" question next sweep to confirm responder leads with MIN/MAX-per-group and does NOT present window-functions-inside-GROUP-BY as merely "verbose". Escalate to a small router card under r07 first/last-per-group neighborhood ONLY if the framing-slip recurs (2nd instance).
- DO re-probe a "bare aggregate over a subquery" question next sweep to confirm responder skips the dummy-GROUP-BY draft entirely. Same escalation rule.
- Optional adjacents (NO pin touch, SKIP if duplicative): argmax-per-group with explicit tie-break (max_by(x, ROW(y, x))); per-customer first-and-last ORDER BY with NULLs in created_at; AVG-over-per-group-COUNT with LEFT JOIN to include zero-count groups.
- CONSIDER federation (thinnest passing row 4.49944/310, long un-retested — bulletproofed angles only). PRESERVE full iter534-935 pin inventory; NO federation edits.
- PIN 467. DO NOT bump training/state.json (already 936; passed=true preserved; overall 4.625 PASS holds).

Pinned dialect facts touched this iter (all verified against trino.io/docs/467 + Trino source/GitHub):
- Window functions CANNOT appear in GROUP BY (semantic error "GROUP BY clause cannot contain aggregations, window functions or grouping operations").
- MIN/MAX per group via GROUP BY is the canonical first/last-by-time-per-entity pattern (no window function needed).
- max_by(x, y) returns x at max y; ROW types are comparable/orderable when fields are; max_by(x, ROW(y, x)) is the canonical deterministic tie-break shape.
- COUNT(DISTINCT col) single-arg valid.
- CURRENT_DATE built-in; CAST(CURRENT_TIMESTAMP AS DATE) valid for DATE-column compare against timestamp.
- Bare aggregate (SELECT AVG(x) FROM t) with no GROUP BY produces one scalar row; no dummy GROUP BY needed.
- AVG over a subquery of per-group COUNT computes per-entity averages correctly.
- INNER vs LEFT JOIN semantics for zero-count entities preserved.
