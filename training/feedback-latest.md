# iter947 Judge Feedback (EXTENDED PHASE, NO-OP durability sweep + HAVING-perf MONITOR + Q3 wrong-shape detection)

**Overall: 4.25 PASS** (margin +0.75; OVERALL AVERAGE governs; no per-Q veto). FEDERATION NOT PROBED (4.49944/310 row UNCHANGED). All dialect verified vs trino.io/docs/current (sql/select.html, functions/string.html, functions/datetime.html, functions/window.html, functions/aggregate.html) via WebFetch + WebSearch 2026-06-10 — NOT against resources/. PIN 467.

## Per-question scores

### Q1 (HAVING-perf MONITOR — URLs > 10,000 views on billions-of-rows pageviews)
- Acc 4.5 / Comp 4.5 / Clar 4.5 / Act 4.5 = **4.5**
- All dialect-correct: `GROUP BY url HAVING COUNT(*) > 10000 ORDER BY view_count DESC` valid 467; partition-pruning via bare-column WHERE; `approx_distinct` ~2.3% HLL framed correctly; HAVING-AFTER-aggregation pedagogy clean.

**★ ★ ★ HAVING-PERF MONITOR VERDICT — CLEAN, folklore did NOT escalate to a 3rd recurrence. ★ ★ ★**
The responder attributed memory pressure to the GROUP BY hash set ("each worker holds a hash set of all distinct URLs to detect duplicates") — CORRECT mechanism; prescribed WHERE pre-filter + STAGED pre-aggregation (materialize daily roll-up in dbt) as the memory remedy — CORRECT; explicitly stated "HAVING filters AFTER aggregation and is the correct place for group-threshold predicates; do not filter in a subquery first" — CORRECT, and crucially NO claim that HAVING reduces grouping memory. The "HAVING trims memory" folklore stays at 2 instances (iter941 Q1 + iter946 Q4); NOT a 3rd. Pre-emptive direct-question MONITOR confirms responder behaves correctly when the HAVING-perf question is asked head-on.

### Q2 (Most common email domain after @)
- Acc 5.0 / Comp 4.5 / Clar 5.0 / Act 5.0 = **4.875**
- `split_part(email, '@', 2)` valid 467 (verified functions/string.html — `split_part(string, delimiter, index)` 1-indexed, returns nth piece, null if index > #fields); GROUP BY repeats expression or uses ordinal (alias not allowed) — correctly noted; COUNT(*) + ORDER BY count DESC = canonical most-common shape. The `approx_distinct(email)` exploratory variant counts distinct emails per domain (slightly different metric from domain frequency) but framed as exploratory — minor, not a defect.

### Q3 (Per-month new vs returning customers) — **★ ★ ★ WRONG-SHAPE OVER-COUNT DEFECT ★ ★ ★**
- Acc 2.5 / Comp 2.5 / Clar 3.5 / Act 2.0 = **2.625**
- Query PARSES and RUNS as valid 467 SQL; window MIN() OVER (PARTITION BY customer_id) + outer GROUP BY + SUM(CASE) are all individually valid (window.html aggregate-as-window; select.html GROUP BY; aggregate.html SUM).
- **BUT the SHAPE is wrong**: the CTE `customer_first_order` produces ONE ROW PER ORDER (no dedup to one row per customer-month). The outer `SUM(CASE WHEN order_month = first_month THEN 1 ELSE 0 END) AS new_customers` counts ORDER ROWS, not CUSTOMERS. A customer placing 3 orders in their first month contributes 3 to `new_customers` (not 1 customer). Similarly `returning_customers` counts repeat-month ORDERS not distinct customers.
- Only `total_unique_customers` via COUNT(DISTINCT customer_id) is correctly an entity count.
- The question explicitly asks "how many CUSTOMERS were brand new that month vs how many had ordered before" — the two headline metrics count the wrong entity.
- Correct shape: pre-dedup the CTE to one row per (customer_id, order_month) first via `SELECT DISTINCT customer_id, DATE_TRUNC('month', created_at) AS order_month, MIN(...) OVER (PARTITION BY customer_id) AS first_month FROM orders`, OR use `COUNT(DISTINCT customer_id) FILTER (WHERE order_month = first_month) AS new_customers` / `COUNT(DISTINCT customer_id) FILTER (WHERE order_month > first_month) AS returning_customers`.
- No mention of dedup, no FILTER (WHERE) variant, no warning that multi-order customers inflate the count. Engineer ships and reports inflated numbers vs actual customer counts.

**Q3 WRONG-SHAPE VERDICT — CONFIRMED entity-vs-row dedup defect.** Counts orders, not distinct customers. Scope: RESPONDER SHAPE SLIP on the "how many customers" framing + FINDABLE GAP (no leading canonical for the first-order cohort dedup pattern). 1st instance of this specific cohort-dedup pattern slip.

### Q4 (Employees hired same calendar month+year as manager — self-join)
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.0**
- Self-join `employees e JOIN employees m ON e.manager_id = m.employee_id` valid 467; `DATE_TRUNC('month', e.hire_date) = DATE_TRUNC('month', m.hire_date)` — date_trunc 'month' truncates to first-of-month INCLUDING year, so equality correctly compares "same calendar month AND year" (NOT just month-of-year); INNER vs LEFT JOIN NULL-manager_id semantics correctly noted.

---

## Overall table

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 4.5 | 4.5 | 4.5 | 4.5 | 4.5 |
| Q2 | 5.0 | 4.5 | 5.0 | 5.0 | 4.875 |
| Q3 | 2.5 | 2.5 | 3.5 | 2.0 | 2.625 |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |

**Overall = (4.5 + 4.875 + 2.625 + 5.0) / 4 = 17.0 / 4 = 4.25 PASS** (>= 3.5; margin +0.75). Overall average GOVERNS; Q3 below 3.5 does NOT veto.

---

## r07 L37 RESOURCE DEFECT ASSESSMENT — CONFIRMED

r07 L37 reads verbatim (file inspected this iter):
> "What to watch for: if `GROUP BY` has high cardinality (e.g., `GROUP BY user_id` across 50M users), the engine has to keep all distinct groups in memory. Add a `HAVING COUNT(*) > N` to trim, or pre-aggregate."

**Verification (WebFetch trino.io/docs/current/sql/select.html, 2026-06-10):**
> "HAVING filters groups after groups and aggregates are computed."

By the time HAVING evaluates, the per-group hash-aggregation working set is ALREADY fully built. HAVING only filters OUTPUT rows; it does NOT shrink the build-side hash table or reduce peak aggregation memory. The "or pre-aggregate" half of L37 is SOUND. The "Add a `HAVING COUNT(*) > N` to trim [memory]" half is a MISCONCEPTION (technically wrong).

**VERDICT — r07 L37 IS A RESOURCE DEFECT** and the LIKELY LATENT SOURCE of the "HAVING trims memory" folklore that has surfaced twice (iter941 Q1, iter946 Q4) — a keyword search on "GROUP BY high cardinality memory" / "reduce GROUP BY memory" lands directly on this line. The fact that Q1 this iter was CLEAN does NOT exonerate the resource defect — the responder happened to phrase the answer in the correct frame on a direct probe, but the latent footgun remains in the resource for synthesis-slip recurrences.

**iter948 RECOMMENDATION — LIGHT FIX-A (RECONCILE-DON'T-APPEND on r07 L37):**

Reword L37 in place. Do NOT append a new defang card (defang-DO-NOT-WRITE backfire risk + New-Card-over-attracts-adjacent risk in dense COUNT(*)/HAVING/GROUP-BY-perf neighborhood). Proposed wording:

> "**What to watch for:** if `GROUP BY` has high cardinality (e.g., `GROUP BY user_id` across 50M users), the engine has to keep all distinct groups in memory during aggregation. HAVING does NOT reduce this memory — HAVING runs AFTER aggregation completes and only trims OUTPUT rows. To cut grouping memory you must either (a) reduce input rows with a WHERE on a partition/filter column, or (b) pre-aggregate in stages (e.g., materialize a daily roll-up in dbt, then aggregate those pre-computed rows)."

Why a fix-in-place, NOT a new card:
- The wrong claim already exists at a keyword-findable location. Adding a separate "HAVING does not reduce memory" defang card without reconciling L37 risks the responder citing the OLD line first.
- Reconcile-don't-append memory rule applies directly here (memory: feedback_reconcile_dont_append.md).
- Fix-the-wrong-claim-in-place, NOT a manufactured restriction. Verified BOTH directions before recommending (claim verified WRONG via official docs; alternative WHERE+pre-agg verified CORRECT via the same source).

This is LIGHT FIX-A (single-line reword + one anchoring sentence), not a full FIX-A package.

---

## Q3 cohort-dedup gap — SEPARATE FIX-A recommendation

The Q3 cohort-dedup defect (counting orders not customers in new-vs-returning per-month split) is a FINDABLE GAP adjacent to existing distinct-counting cards. The Q3 question shape ("brand new that month vs ordered before") is the canonical cohort/first-order-month pattern; resources teach COUNT(DISTINCT) and FILTER (WHERE) elsewhere but the "first-order cohort + new-vs-returning split" pattern lacks a leading findable canonical for the (customer, month) dedup step.

Recommend a SHORT additive card (NOT a re-write) in r07 or r23 under a "First-order cohort / new-vs-returning by month" header that:
1. LEADS with the CORRECT shape: pre-dedup to one row per (customer_id, order_month), OR use `COUNT(DISTINCT customer_id) FILTER (WHERE order_month = first_month) AS new_customers`.
2. Defangs the wrong shape (inline WRONG-mark): `SUM(CASE WHEN order_month = first_month THEN 1 ELSE 0 END)` over raw orders inflates the count when customers place multiple orders in a month.
3. Anchors on keywords "new customers per month", "returning customers", "first-time vs repeat", "cohort".

This is a SEPARATE FIX-A from the r07 L37 reconcile — distinct defect family.

---

## Defect scoping summary

| Defect | Scope | iter948 action |
|---|---|---|
| r07 L37 "HAVING trims memory" misconception | **RESOURCE DEFECT** (latent source of 2 prior responder slips iter941+iter946) | LIGHT FIX-A: reconcile-don't-append reword on L37 |
| Q3 new-vs-returning customers counts orders not customers | **RESPONDER SHAPE SLIP + FINDABLE GAP** (1st instance; no leading cohort-dedup canonical) | FIX-A: short additive cohort-dedup canonical card |
| Q1 HAVING-perf MONITOR | **CLEAN** (folklore did NOT escalate to 3rd recurrence on direct probe) | none |
| Q2 / Q4 | clean | none |

---

## Pinned dialect facts reinforced

- HAVING runs AFTER aggregation; does NOT reduce GROUP BY working-set memory (only trims OUTPUT rows). Memory reduction = WHERE pre-filter or staged pre-aggregation. [VERIFIED 2026-06-10 trino.io/docs/current/sql/select.html verbatim "HAVING filters groups after groups and aggregates are computed."]
- `split_part(s, delim, n)` 1-indexed; returns nth field; null if index > #fields. Valid 467 functions/string.html.
- `GROUP BY split_part(...)` (repeat expr) or `GROUP BY 1` (ordinal); GROUP BY does NOT accept SELECT alias.
- `MIN() OVER (PARTITION BY x)` aggregate-as-window valid; window fn cannot appear in WHERE/GROUP BY/HAVING (wrap in subquery — no QUALIFY in 467).
- `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` counts ROWS — for distinct entities use `COUNT(DISTINCT x)` or `COUNT(*) FILTER (WHERE ...)` / `COUNT(DISTINCT x) FILTER (WHERE ...)`.
- `DATE_TRUNC('month', date)` truncates to first-of-month INCLUDING year — safe for "same calendar month AND year" equality comparison (NOT just month-of-year).
- Self-join with aliases canonical; INNER drops NULL FK rows, LEFT preserves.
- `approx_distinct` ~2.3% HLL standard error (NOT approx_percentile).
- Default NULLS LAST regardless of direction.
- COUNT(DISTINCT *) invalid; multi-arg COUNT(DISTINCT a, b) invalid (use COUNT(DISTINCT ROW(a,b)) for distinct pairs).

---

## iter948 directive

1. **LIGHT FIX-A on r07 L37** — reconcile-don't-append the "HAVING trims memory" claim (proposed wording above). Single-line reword + one anchoring sentence. DO NOT add a separate new defang card.
2. **FIX-A on Q3 cohort dedup** — additive short canonical card (one block) for "new vs returning customers per month" with explicit dedup-first pattern; anchor on the question keywords ("new customers per month", "returning vs new", "first-time vs repeat", "cohort").
3. **Re-probe next sweep:**
   - HAVING-perf via a 3rd direct question framing ("make this GROUP BY use less memory" / "is HAVING a memory optimization") — verify the reconciled r07 L37 holds.
   - Cohort/new-vs-returning re-probe via a fresh first-month split question with explicit multi-order schema framing — verify responder leads with the dedup-first canonical and uses COUNT(DISTINCT customer_id) FILTER (WHERE).
4. **Do NOT touch:** federation (4.49944/310 row), percentile cards, PARTITIONED-BY guidance, INTERVAL qualifiers, GROUP-BY-output-shape rule, COUNT(DISTINCT) single-arg pin.
5. **PIN 467.**
6. **Cap Opus parallelism at 2-3** to avoid socket timeouts (memory: feedback_parallel_opus_timeout.md).
7. **DO NOT bump training/state.json** (orchestrator does that; already 947; passed=true preserved; overall 4.25 PASS holds).
