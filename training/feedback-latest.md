# Iter632 Judge Feedback

**Overall average: 4.46875 — PASS**

Four answers scored against Trino 467 docs (WebFetch-verified at trino.io/docs/current). One single-snippet accuracy bug found in Q3 (concat on BIGINT args is a type error in Trino 467). Overall average safely above the 3.5 threshold; one per-Q below threshold (Q3 = 3.375) is flagged separately as FIX-A candidate per directive (the AVERAGE governs PASS/FAIL).

---

## Per-question scores

### Q1 — New vs returning customers per day (MIN(order_date) OVER (PARTITION BY customer_id))

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 4 | `MIN(order_date) OVER (PARTITION BY customer_id) = order_date` is valid Trino 467 (aggregate-as-window confirmed in trino.io/docs/current/functions/window.html — "All Aggregate functions can be used as window functions by adding the OVER clause"). Boolean from equality is standard SQL. Minor accuracy gap below. |
| Completeness | 4 | Core idiom + LEFT-JOIN alternative covered. MISSING: the "two orders same first day" edge case. If a customer places 2 orders on their first-ever day, BOTH rows have `MIN(order_date) = order_date` so BOTH count as "new" — that inflates the new-customer count vs counting DISTINCT new customers per day. For "new CUSTOMERS per day" the safer aggregation is `COUNT(DISTINCT CASE WHEN is_new_customer THEN customer_id END)` rather than `SUM(CASE WHEN is_new_customer THEN 1 ELSE 0 END)` (the latter is "new ORDERS by first-time customers"). Answer did not flag the orders-vs-customers distinction. |
| Clarity | 5 | Clear, two-step structure (subquery flags rows, outer groups), well-explained. |
| Actionability | 5 | Engineer can drop the SQL straight in. |
| **Q1 avg** | **4.5** | |

### Q2 — Median order value per category (approx_percentile)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `approx_percentile(order_amount, 0.5) GROUP BY product_category` is the canonical Trino 467 idiom (confirmed at trino.io/docs/current/functions/aggregate.html — `approx_percentile(x, percentage) → [same as x]` and the ARRAY form `approx_percentile(x, percentages) → array<[same as x]>`). T-Digest reference is correct. PERCENTILE_CONT/MEDIAN inoculation is correct — neither exists in Trino 467 (verified absent from the aggregate-functions docs page). Approximate-vs-exact: `approx_percentile` IS the standard Trino idiom for median; no exact equivalent exists short of PERCENT_RANK + window scan, so "approximate" is the right answer here. |
| Completeness | 5 | Single-percentile form + ARRAY form for IQR + PERCENTILE_CONT inoculation = full coverage of likely follow-ups. |
| Clarity | 5 | Explains T-Digest at the right level (mentions sketch without going deep). |
| Actionability | 5 | Drop-in SQL + the multi-percentile form for quartile dashboards. |
| **Q2 avg** | **5.0** | |

### Q3 — Response time per ticket in hours and minutes (date_diff + concat)

**CRITICAL ACCURACY ISSUE: the second snippet is invalid Trino 467.**

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 2.5 | First snippet (two integer columns: `date_diff('hour', a, b) AS response_hours`, `date_diff('minute', a, b) % 60 AS response_minutes`) is fully correct. `date_diff(unit, ts1, ts2) → bigint` is confirmed at trino.io/docs/current/functions/datetime.html. BUT the formatted-string snippet `concat(date_diff('hour', a, b), 'h ', date_diff('minute', a, b) % 60, 'm')` is a TYPE ERROR in Trino 467. The string-functions docs (trino.io/docs/current/functions/string.html) define `concat(string1, ..., stringN) → varchar` — it requires varchar arguments. `date_diff(...)` returns BIGINT and Trino does NOT implicitly coerce BIGINT to VARCHAR (Trino's type system is strict — confirmed via web search showing the exact "Trino will not convert between character and numeric types" behavior). Engineer running this snippet will get a function-resolution error like `Unexpected parameters (bigint, varchar(2), bigint, varchar(2)) for function concat`. The fix is either `CAST(... AS varchar)` on each BIGINT or `format('%dh %dm', hour_val, minute_val)`. Half-credit because the integer-column form works perfectly; the formatted snippet would fail on first run. |
| Completeness | 4 | Covers hour and minute separation + the %60 modulo pattern (which is correct). Missing the alternative `format()` idiom (which is the cleanest Trino way to combine BIGINT into a display string). |
| Clarity | 4 | Two snippets clearly labeled, modulo logic explained. Lost a point because the formatted version misleads beginners into thinking it works. |
| Actionability | 3 | The hours/minutes column pair is actionable; the formatted-string snippet is NOT actionable because it errors at parse/analysis time. Engineer has to fix it before it runs. |
| **Q3 avg** | **3.375** | |

### Q4 — Most common product pairs (self-join inequality dedup)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Self-join `o1 JOIN o2 ON o1.order_id = o2.order_id AND o1.product_id < o2.product_id` is the textbook combinatorial-pairs dedup pattern in standard SQL — `<` (strict less-than) simultaneously excludes self-pairs (`o1.product_id = o2.product_id` would be a degenerate same-line-item join) AND duplicate ordered pairs (it picks only the canonical `(a,b)` with a<b, not both `(a,b)` and `(b,a)`). COUNT + GROUP BY two product columns + ORDER BY DESC LIMIT 20 is correct. `SUM(count) OVER ()` empty-window for share-of-grand-total is valid Trino 467 (verified above — aggregate-as-window with empty OVER produces grand total broadcast to every row). |
| Completeness | 5 | Pair-dedup + ranking + share-of-total = full coverage of typical follow-ups. |
| Clarity | 5 | Clear explanation of WHY `<` (not `<=` or `!=`). |
| Actionability | 5 | Drop-in. |
| **Q4 avg** | **5.0** | |

---

## Overall

| Question | Avg |
|---|---|
| Q1 | 4.5 |
| Q2 | 5.0 |
| Q3 | 3.375 |
| Q4 | 5.0 |
| **Overall** | **4.46875** |

**Verdict: PASS** (4.46875 >= 3.5). Per directive, the OVERALL AVERAGE governs PASS/FAIL — no per-Q quality-gate override. Q3 (3.375) is below the per-Q threshold and is named as the iter633 FIX-A candidate.

---

## iter633 FIX-A recommendation: concat()/format() type-coercion guardrail

The Q3 failure is a concrete, reproducible Trino 467 accuracy gap: the responder produced `concat(bigint, varchar, bigint, varchar)` which is a function-resolution error. This is fixable with one tight CANONICAL card.

**Recommended FIX-A location**: r23 (the SQL/dialect guardrails resource), inoculation card near the existing string-function neighborhood.

**Recommended canonical content** (teacher to write — judge does not author resources):

1. **Rule**: `concat()` in Trino 467 accepts varchar/array/varbinary ONLY. BIGINT / INTEGER / DOUBLE / DATE / TIMESTAMP are NOT implicitly coerced and produce a function-resolution error. Same is true of the `||` operator.
2. **Two correct idioms for "combine number + label" display strings**:
   - **CAST form**: `concat(CAST(hours AS varchar), 'h ', CAST(minutes AS varchar), 'm')`
   - **format() form (preferred for readability)**: `format('%dh %dm', hours, minutes)` — `format()` is the printf-style function and DOES accept BIGINT/INTEGER args natively.
3. **DO-NOT-WRITE rows**:
   - `concat(date_diff('hour', a, b), 'h')` — type error (BIGINT not coercible)
   - `concat(123, 'rows')` — type error
   - `'count: ' || 42` — type error (`||` is also varchar-only)
4. **Worked example** for the response-time scenario:
   ```sql
   SELECT
     ticket_id,
     date_diff('hour', created_at, first_reply_at) AS response_hours,
     date_diff('minute', created_at, first_reply_at) % 60 AS response_minutes,
     format('%dh %dm',
            date_diff('hour', created_at, first_reply_at),
            date_diff('minute', created_at, first_reply_at) % 60) AS response_display
   FROM tickets
   WHERE first_reply_at IS NOT NULL
   ```

**Findability cross-refs**:
- Cross-ref from any existing `date_diff` example that builds a display string.
- Cross-ref from any "user-facing string" / "format" / "concat" neighborhood in r07/r13/r18.

**Secondary suggestion (Q1 nuance, not FIX-A)**: When the teacher next touches the "new vs returning customers per day" neighborhood, add a one-line WATCH-ITEM about COUNT(DISTINCT customer_id) vs SUM(CASE WHEN ...) — call out that the SUM form counts ORDERS by first-time customers (which double-counts when one customer places two orders on their first day), and that COUNT(DISTINCT customer_id) with the same is_new_customer filter counts CUSTOMERS. This is a 2-line WATCH, not a full FIX-A.

---

## What worked well this iteration

- Q2 (approx_percentile + PERCENTILE_CONT inoculation) executed flawlessly — the existing canonical at r05 + r23 is producing crisp, complete answers from very different phrasings. Continue holding that lock.
- Q4 (self-join inequality pair-dedup + SUM() OVER ()) showed the responder synthesizing a non-trivial combinatorial pattern correctly from primitive JOIN + window idioms in resources. No worked "product pairs" example was needed — the synthesis worked.
- Q1 MIN() OVER (PARTITION BY) first-event flagging was synthesized correctly from the established first_event_at / signed_up_at neighborhood patterns. Findability working as designed.

## Patterns to watch

- The concat()/format() type-coercion gap is the second time in recent iterations a string-display formatting question has surfaced a Trino-strict-typing miss. After FIX-A lands, probe with another display-string question (e.g., "format currency", "build a status label from numeric tier") to verify the canonical sticks.
