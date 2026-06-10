# Judge Feedback — iter916 (re-probe sweep)

**Overall: 4.40 PASS** (Q1 5.00 / Q2 5.00 / Q3 3.00 / Q4 4.75 = 17.75 / 4 = 4.4375).
OVERALL AVERAGE governs — no per-Q veto.

All dialect claims verified vs trino.io/docs/467 (datetime.html, types.html, select.html) + multi-source WebSearch on Trino timestamp coercion, 2026-06-10. Trino 467 PINNED.

---

## Per-question scores

### Q1 — count products ordered by >3 distinct customers (single number) — **5.00 CLEAN**
`SELECT COUNT(*) FROM (SELECT product_id, COUNT(DISTINCT customer_id) AS num_customers FROM order_items GROUP BY product_id HAVING COUNT(DISTINCT customer_id) > 3) grouped_products`

**SHAPE ANALYSIS:** Inner query produces exactly one row per product whose distinct-customer count exceeds 3 (HAVING `COUNT(DISTINCT customer_id) > 3` filters on the inner group's OWN aggregate — valid Trino 467, verified select.html "HAVING used in conjunction with aggregate functions and GROUP BY to control which groups are selected"). The OUTER `SELECT COUNT(*)` collapses that set to ONE number = the count of qualifying products. This is the CORRECT shape (a single scalar), NOT the iter915 muddle (which returned one row per entity).

**WRONG-SHAPE SLIP: ONE-OFF CONFIRMED — did NOT recur. iter915 slip CLOSED. NO findability-anchor FIX-A needed.** Responder LED with the correct single-count form (outer COUNT(*) over the GROUP BY...HAVING subquery), no per-entity-row leak. COUNT(DISTINCT) + GROUP BY + HAVING-on-own-aggregate + outer COUNT(*) all valid → returns one number. Clean.

### Q2 — count refunds where refund_amount > original_order_amount — **5.00 CLEAN**
`SELECT COUNT(*) FROM refunds WHERE refund_amount > original_order_amount`
Simple two-column comparison filter-count. Valid Trino 467, correct. No division/NULL/type gotcha.

### Q3 — average days active subscriptions have run — **3.00 DEFECT (type mismatch)**
`SELECT AVG(date_diff('day', started_at, current_timestamp)) FROM subscriptions WHERE status='active'`

**Q3 TIMESTAMP-vs-TIMESTAMPTZ VERDICT: HARD TYPE ERROR (no implicit coercion).**
- `current_timestamp` returns `TIMESTAMP(3) WITH TIME ZONE` (verified datetime.html: "current timestamp with time zone as of the start of the query, with 3 digits of subsecond precision").
- `started_at` is most plausibly a plain `TIMESTAMP` (without time zone).
- **Trino REMOVED implicit coercion from TIMESTAMP to TIMESTAMP WITH TIME ZONE** because the conversion is session/environment-dependent (verified multi-source: trino types.html documents them as distinct types with NO coercion note; trinodb/trino issue #37 + #7450 + release notes confirm implicit TIMESTAMP→TIMESTAMP WITH TIME ZONE coercion was intentionally removed for SQL-standard compliance).
- `date_diff` is a polymorphic scalar with separate `timestamp(p)` and `timestamp(p) with time zone` registrations; with mixed args there is NO common super-type and NO implicit coercion → function resolution FAILS ("Unexpected parameters / cannot be applied"). **The query as written does NOT run.**

**This is a REAL dialect defect, not a stylistic nit.** The CONCEPT is correct (`AVG(date_diff('day', started_at, <now>)) WHERE status='active'` is the right approach), which is why this is scored 3.00 (partial) not lower — the structure/intent is sound and a small type alignment fixes it. **Fix (align types):**
- Cleanest for "days": `AVG(date_diff('day', CAST(started_at AS date), current_date))` (both DATE), OR
- `AVG(date_diff('day', started_at, CAST(current_timestamp AS timestamp)))` (drop tz to match plain TIMESTAMP), OR
- `AVG(date_diff('day', CAST(started_at AS timestamp with time zone), current_timestamp))` (promote started_at).

### Q4 — avg rating per product (1 decimal), only products with reviews — **4.75 CLEAN**
`SELECT p.product_id, ROUND(AVG(r.star_rating), 1) FROM products p INNER JOIN reviews r ON p.product_id=r.product_id GROUP BY p.product_id`
INNER JOIN correctly EXCLUDES products with zero reviews (matches "only products with >=1 review"). `ROUND(AVG(star_rating), 1)` valid Trino 467; one row per product via GROUP BY product_id. Correct. Minor ding only for not noting the INNER-vs-LEFT contrast (LEFT would include no-review products with NULL avg) — informative nicety, not a defect.

---

## Defect / gap summary

- **Q3 timestamp-vs-timestamptz date_diff = HARD TYPE ERROR** (no implicit coercion in Trino 467). This is a genuine, findable dialect defect. The responder mixed a plain-TIMESTAMP column with `current_timestamp` (TIMESTAMP WITH TIME ZONE) inside `date_diff`.
- **Q1 wrong-shape slip: ONE-OFF CONFIRMED, did NOT recur, iter915 slip CLOSED.** No FIX-A for shape.

## iter917 recommendation — **LIGHT FIX-A (Q3 type alignment)**
Add/strengthen a small fenced "days-active / age-in-days" canonical in the datetime card that uses **type-aligned** forms:
- For a DATE answer: `date_diff('day', CAST(started_at AS date), current_date)`.
- Explicitly note: **`current_timestamp` is TIMESTAMP WITH TIME ZONE; a plain TIMESTAMP column does NOT implicitly coerce to it — `date_diff('day', plain_ts, current_timestamp)` is a TYPE ERROR. Use `current_date` (date answer) or `CAST(current_timestamp AS timestamp)` to match a without-tz column.**
- Keyword-land on "days active", "age in days", "how long has X run", "since started_at". Inline-mark the mixed-type form WRONG/un-copyable (per the defang-DO-NOT-WRITE lesson); make the type-aligned form the copy-attractive block.

Re-probe the days-since / age-in-days family next sweep from a different phrasing to confirm the fix lands and the responder LEADS with a type-aligned form.

PRESERVE full iter534-915 pin inventory. NO federation edits (federation 4.49944/310, UNCHANGED — not probed this iter). DO NOT bump training/state.json (already 916).
