# Iter940 Feedback — DEFAULT NO-OP durability sweep (teacher made ZERO resource edits)

**Date**: 2026-06-10
**Phase**: EXTENDED (passed=true preserved)
**Overall verdict**: **4.9375 PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.75 = 19.75/4 = 4.9375; margin +1.4375; OVERALL AVERAGE governs)
**Dialect verification**: All claims verified vs trino.io/docs/467 (sql/select.html, functions/window.html, functions/datetime.html) + WebSearch 2026-06-10 — NOT against resources/; iter882 verify-BOTH-directions discipline applied.
**Federation row (4.49944/310)**: NOT PROBED this iter — bulletproofed-only constraint honored, no federation probe attempted.

---

## Per-question scores

### Q1 — "Customers with >= 10 total orders; where does the count filter go?" — **5.00**
- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5**
- Query `GROUP BY customer_id HAVING COUNT(*) >= 10` is canonical and dialect-clean. Verified against sql/select.html: *"HAVING filters groups after groups and aggregates are computed"* — exact match to responder's exposition.
- WHERE-cannot-reference-aggregates claim CONFIRMED — `WHERE COUNT(*) >= 10` would be a parse error (aggregates resolve at GROUP BY level, not at WHERE).
- HAVING repeats the aggregate `COUNT(*) >= 10` (not the SELECT alias `total_orders`) — Trino HAVING cannot reference SELECT aliases (standard SQL behavior). Correctly handled.
- ORDER BY can reference the alias `total_orders` (ORDER BY runs after SELECT projection) — also correct.

### Q2 — "Percentage of sessions from mobile vs desktop" — **5.00**
- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5**
- Query `SELECT device_type, COUNT(DISTINCT session_id), ROUND(100.0 * COUNT(DISTINCT session_id) / SUM(COUNT(DISTINCT session_id)) OVER (), 2) FROM events GROUP BY device_type` — CONFIRMED VALID 467 BOTH DIRECTIONS:
  - **The key check**: `SUM(COUNT(DISTINCT session_id)) OVER ()` — window function (SUM OVER) wrapping a GROUPED aggregate (COUNT DISTINCT). VALID in Trino because window functions are evaluated AFTER GROUP BY/HAVING (standard SQL semantics; verified via WebSearch — "rolling sum" and "percentage of total" idioms are canonical Trino patterns). The inner COUNT(DISTINCT session_id) produces one row per device_type group; the outer SUM(...) OVER () then sums those per-group counts into a grand total broadcast on every row. NOT a "nested aggregate" error (those are illegal only when both nests resolve at the same aggregation level — here the outer SUM is at window-frame level, not at GROUP BY level).
  - **Empty OVER ()** — confirmed = whole result set as one window frame (no PARTITION BY = single partition; no ORDER BY = full-partition frame).
  - **`100.0 *` decimal-promo** — correct; without it the `COUNT(DISTINCT)/SUM(COUNT(DISTINCT))` integer division would truncate to 0 (per Division pin).
  - **COUNT(DISTINCT session_id) vs COUNT(\*)** — correct preference call (sessions are the unit of analysis, not events).
  - ROUND(..., 2) and ORDER BY session_count DESC — both clean.

### Q3 — "Products with ZERO sales in LAST 30 DAYS — anti-join-with-date-filter" — **5.00**
- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5**
- **Q3 ANTI-JOIN-DATE-FILTER VERDICT — ON-PLACEMENT CORRECT.**
- Query: `LEFT JOIN sales s ON s.product_id = p.product_id AND s.sale_date >= current_date - INTERVAL '30' DAY WHERE s.product_id IS NULL`
- Date predicate placed in **ON clause** (not WHERE) — this IS the canonical correct form. Verified BOTH directions:
  - **ON-placement (correct)**: Filter is applied DURING the join, so non-matching products survive with NULL sales columns; the outer `WHERE s.product_id IS NULL` then keeps zero-recent-sales products (anti-join preserved).
  - **WHERE-placement (would break)**: If `s.sale_date >= current_date - INTERVAL '30' DAY` were in WHERE, the NULL sale_date from unmatched LEFT JOIN rows would fail the `>=` comparison (NULL >= anything yields NULL/false), silently dropping exactly the products we want and turning the anti-join into an inner-join filter — the classic trap.
  - WebSearch 2026-06-10 confirmed Trino follows standard outer-join semantics: WHERE predicates on the null-supplying table convert LEFT JOIN to inner-join semantics; ON-clause predicates preserve the outer-join.
- `INTERVAL '30' DAY` — DAY qualifier valid per types.html (only YEAR/MONTH/DAY/HOUR/MINUTE/SECOND legal; iter933 INTERVAL-qualifier pin honored — no QUARTER/WEEK misuse).
- NOT IN alternative mentioned but de-prioritized — defensible: NOT IN has the nullable 3VL trap (if any sale_id were NULL, NOT IN returns NULL → entire predicate fails). Responder explicitly preferred LEFT JOIN/IS NULL form — solid call.
- The "clearer/more efficient" framing is a tiny soft-heuristic, but for the actual zero-recent-sales semantic + null safety the LEFT JOIN form IS legitimately safer; defensible without ding.

### Q4 — "Customers with >= 1 order in EVERY calendar month so far this year" — **4.75**
- **Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5**
- Primary query: `WHERE order_date >= DATE '2026-01-01' AND order_date < DATE '2027-01-01' GROUP BY customer_id HAVING COUNT(DISTINCT date_trunc('month', order_date)) = 12` — fully valid 467.
  - `date_trunc('month', order_date)` returns date; COUNT(DISTINCT date_trunc(...)) is dialect-clean per pin.
  - Half-open year-bounded WHERE correct (`>= 2026-01-01 AND < 2027-01-01`).
  - "= 12" only correct at YEAR-END — the question said "so far this year" (today 2026-06-10 = only 5 complete calendar months Jan-May; June is partial). Strict "= 12" form would return zero rows until December 31, 2026.
- Secondary variant: `WHERE order_date >= date_add('month', -5, date_trunc('month', current_date)) AND order_date < date_trunc('month', current_date) ... HAVING COUNT(DISTINCT date_trunc('month', order_date)) = 5` — CORRECTLY frames "so far this year" as "5 complete months excluding partial current month" (current_date 2026-06-10 → date_trunc gives 2026-06-01, minus 5 months gives 2026-01-01, so window is Jan-1 through May-31 = 5 complete months).
  - `date_add('month', -5, ...)` valid per datetime.html; date_trunc('month', current_date) returns date.
- **Completeness ding (4/5)**: The "so far this year" interpretation should have LED, with the "= 12 (full-year)" form as the secondary variant. The responder gave BOTH forms (saves the answer from a Comp 3 dock), but the lead query implicitly assumes a question the user didn't ask. A reader skimming might copy the "= 12" form and not realize it returns empty until December. Small Completeness ding only — not a defect, not findable gap, just ordering nuance.
- COUNT(*) = 12 mistake correctly flagged ("counts orders, not months").

---

## Defect scope

**NO RESOURCE DEFECT.** All four answers were dialect-clean; no canonical card needs editing.

**NO RESPONDER SLIP on taught content.** Q1/Q2/Q3 are exemplary; Q4 covered both interpretations and explicitly flagged the COUNT(*) vs COUNT(DISTINCT) trap.

**NO FINDABLE GAP.** Q4's "so far this year" lead-ordering nuance is presentation polish, not a missing card.

**iter940 = DEFAULT NO-OP confirmed** — all 4 dialect-clean, zero new defects, all locks intact per state.json note.

---

## Optional re-probes next sweep (SKIP IF DUPLICATIVE — no pin touch warranted)

- Anti-join-with-date-filter where the responder is shown ONLY the WHERE-placement form first and must catch the trap (verify defang holds when prompt biases the wrong way).
- "so far this year" / partial-period question with a deliberately ambiguous "every month" phrasing to confirm the variant LEADS, not trails.
- Window-fn-over-grouped-aggregate ("share of total within category") to keep the SUM(COUNT(...)) OVER () idiom durable across PARTITION-BY framings.

**Federation (4.49944/310)** — only un-passed row. Bulletproofed angles only; no federation edits this sweep.

**PRESERVE full iter534-937 pin inventory.** PIN 467. **DO NOT bump training/state.json** (orchestrator bumps; passed=true preserved; overall 4.9375 PASS holds).
