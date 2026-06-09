# Judge Feedback — iter790 (DEFAULT NO-OP / durability-breadth sweep)

**Mode:** Extended phase, end-of-iteration feedback. Teacher made ZERO resource edits this iter (4 fresh adjacent probes on well-covered fundamentals).

**Verification:** All dialect claims verified against trino.io/docs/467 (sql/select.html, functions/aggregate.html) — not taken from resources/ as ground truth.

---

## Per-question scores

### Q1 — EXISTS / has-at-least-one (boolean flag for any order > $1000)
Answer: `CASE WHEN EXISTS (SELECT 1 FROM orders o WHERE o.customer_id=c.customer_id AND o.amount>1000) THEN true ELSE false END AS has_large_order`. Notes EXISTS = semijoin, short-circuits at first match, SELECT 1 is a dummy. Cites r07.

- **Verified:** trino.io/docs/467 confirms EXISTS predicate "determines if a subquery returns any rows"; correlated `WHERE EXISTS` and `CASE WHEN EXISTS (...) THEN true ELSE false END` are valid; planned as semijoin, no full count needed. Correct.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 4.5 | 5 | 5 | **4.875** |

### Q2 — Conditional sum (positive + negative totals, one pass)
Answer: `SUM(amount) FILTER (WHERE amount > 0) AS total_credits, SUM(amount) FILTER (WHERE amount < 0) AS total_debits`. One pass, ANSI FILTER modifier. Cites r23 §3.1E.

- **Verified:** trino.io/docs/467 aggregate docs confirm the FILTER (WHERE cond) modifier removes rows from aggregation. Both totals in one pass. Correct. (Equivalent `SUM(CASE WHEN amount>0 THEN amount ELSE 0 END)` also valid — FILTER form is the cleaner idiom.)

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.0** |

### Q3 — Pagination (page 3 = rows 51-75, ORDER BY signup_date)
Answer: `SELECT * FROM users ORDER BY signup_date ASC OFFSET 50 LIMIT 25`. Notes OFFSET comes BEFORE LIMIT in Trino clause order; LIMIT applies after ORDER BY. Cites r27 pagination.

- **Verified:** trino.io/docs/467/sql/select.html confirms "If the OFFSET clause is present, the LIMIT or FETCH FIRST clause is evaluated after the OFFSET clause" — OFFSET-before-LIMIT clause order is CORRECT. OFFSET 50 LIMIT 25 = rows 51-75. Correct.
- **Optional completeness note (not a defect):** deep OFFSET is inefficient at scale; keyset/seek pagination (`WHERE signup_date > :last`) is better for deep pages. The answer is correct as-is for the asked page.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 4.5 | 5 | 5 | **4.875** |

### Q4 — MIN + MAX per group (first_order / last_order per customer)
Answer LEADS with `min_by(order_date, order_date) AS first_order, max_by(order_date, order_date) AS last_order`, THEN notes plain `MIN(order_date)`/`MAX(order_date)` GROUP BY are the simpler/clearer choice for just the dates, and correctly explains min_by/max_by are for pulling a value from a DIFFERENT column.

- **Verified:** trino.io/docs/467 confirms MIN/MAX and min_by(x,y)/max_by(x,y) all exist. `min_by(order_date, order_date)` is functionally equivalent to `MIN(order_date)` (and max_by analogously) — it WORKS but is pointlessly indirect for the same-column case.
- **Q4 verdict — CLARITY IMPRECISION, NOT A DEFECT:** Both forms compile and return the correct earliest/latest dates. The answer DID surface plain MIN()/MAX() as the clean/recommended choice and correctly scoped min_by/max_by to the different-column case. The only flaw is presentation order: it LED with the redundant `min_by(date, date)` before the clean MIN/MAX. The correct answer is present and recommended, so no accuracy loss — Clarity docked for leading with the convoluted form.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 4.5 | 3.5 | 4.5 | **4.375** |

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 4.875 |
| Q2 | 5.0 |
| Q3 | 4.875 |
| Q4 | 4.375 |
| **Overall** | **4.781** |

**Result: PASS** (overall 4.781 >= 3.5; no single-Q veto, all four well above threshold).

---

## Teacher feedback

(a) **Q4 lead-with-min_by note:** Plain `MIN(order_date)`/`MAX(order_date)` IS surfaced as the clean answer and correctly recommended — so this is a **clarity imprecision, not a defect**. The responder led with the redundant `min_by(date, date)` form before the clean MIN/MAX. No accuracy loss (both compile, the clean form is given and recommended). Watch for a pattern in iter791: if "lead-with-the-convoluted-form" recurs on a same-column MIN/MAX-style probe, a light additive nudge in r23 §3.1D (lead MIN/MAX first; demote min_by/max_by to "when the returned value comes from a DIFFERENT column than the one you rank by") would fix it. NOT urgent — single occurrence, answer still correct.

(b) **iter791 designation: DEFAULT NO-OP / durability-breadth.** No open defect — all four fundamentals (EXISTS-semijoin / sum-FILTER-conditional-sum / OFFSET-before-LIMIT-pagination / MIN-MAX-per-group-vs-min_by-max_by) verified correct against trino.io/docs/467. Continue the durability-breadth sweep on fresh adjacent topics. Keep an eye on the Q4 lead-ordering note above — second occurrence on a different phrasing escalates to a light FIX-A on r23 §3.1D; otherwise stay NO-OP.

**Standing pins held this iter:** EXISTS-as-semijoin, sum-FILTER conditional-sum, OFFSET-before-LIMIT pagination, MIN/MAX-per-group vs min_by/max_by-for-other-column. All four reconfirmed accurate. No regressions.
