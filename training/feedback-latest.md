# iter574 Judge Feedback

**Pinned target:** Trino 467 + Iceberg connector (Hive Metastore + MinIO/S3) per `prod_info.md`.

## Per-question scores

### Q1 — Daily ACTIVE subscribers per plan, no missing days, derive bounds from data
A1 builds the dynamic-bounds spine correctly (good) but the `daily_active` CTE is a single-point-in-time snapshot. The result series is wrong for all historical days.

**(i) Dynamic-bounds spine — CORRECT (durability lock held).**
```sql
bounds   : SELECT MIN(subscription_start_date) AS earliest_date, CURRENT_DATE AS latest_date FROM subscriptions
calendar : SELECT date_add('day', n, bounds.earliest_date) AS day
           FROM bounds
           CROSS JOIN UNNEST(sequence(0, CAST(date_diff('day', bounds.earliest_date, bounds.latest_date) AS INT))) AS t(n)
```
- Bounds derived from data — no hardcoded literal. PASS.
- `sequence` + `CROSS JOIN UNNEST` is the canonical spine pattern. PASS.
- No GROUP-BY-on-aggregate; no `::`-cast; CAST(INT) form is valid Trino 467 dialect. PASS.

Quote (Trino current — https://trino.io/docs/current/functions/array.html#sequence): `sequence(start, stop)` returns an array of values from `start` to `stop` (inclusive). Cross-joining `UNNEST(sequence(...))` to expand to per-row days is the documented canonical.

**(ii) `daily_active` CTE — SEMANTIC BUG (point-in-time snapshot, not per-day series).**
```sql
SELECT CURRENT_DATE AS day,                       -- <-- HARDCODES single day
       plan_type,
       COUNT(*) AS active_count
FROM subscriptions
WHERE subscription_start_date <= CURRENT_DATE     -- <-- snapshot AS OF TODAY
  AND (subscription_end_date IS NULL OR subscription_end_date > CURRENT_DATE)
GROUP BY plan_type
```
Then `LEFT JOIN ... ON c.day = d.day`. Because `d.day` is *always* `CURRENT_DATE`, only the today-row matches. For every historical calendar day, `d.*` is NULL and `COALESCE(...,'No Activity'/0)` fires. The query returns:
- A real count only for `c.day = CURRENT_DATE`.
- `'No Activity', 0` for every other day in the spine.

That is NOT a per-day active-subscriber series over history. It is a today-snapshot + zeros.

**Correct pattern — interval-overlap / "active-on-each-day" range join** (count, for each calendar day `c.day`, every subscription whose active interval covers that day):
```sql
WITH bounds AS (
  SELECT MIN(subscription_start_date) AS earliest_date,
         CURRENT_DATE                  AS latest_date
  FROM iceberg.saas.subscriptions
),
calendar AS (
  SELECT date_add('day', n, b.earliest_date) AS day
  FROM bounds b
  CROSS JOIN UNNEST(sequence(0, CAST(date_diff('day', b.earliest_date, b.latest_date) AS INT))) AS t(n)
)
SELECT
  c.day,
  s.plan_type,
  COUNT(*) AS active_count
FROM calendar c
JOIN iceberg.saas.subscriptions s
  ON s.subscription_start_date <= c.day
 AND (s.subscription_end_date IS NULL OR s.subscription_end_date > c.day)
GROUP BY c.day, s.plan_type
ORDER BY c.day, s.plan_type;
```
Notes:
- This is a RANGE / interval-overlap join (each subscription row joins to every calendar day in its `[start, end)` interval).
- For "no missing days even when no plan is active that day", LEFT JOIN the calendar against this aggregated result on `day` and `COALESCE(active_count, 0)`.
- For very large fact tables, consider materializing per-plan boundary events and using a cumulative `SUM(+1) - SUM(-1)` on the start/end edges instead of the broadcast range join.

This is a separate pattern from forward-fill (iter566 IGNORE NULLS) — forward-fill propagates the last-known value forward across gap rows; range-overlap counts active *intervals* per day. The current resources have a forward-fill canonical but **no interval-overlap canonical**. That is the iter575 gap.

**Scores Q1:** Accuracy 2 (spine right; aggregation semantically wrong — returns wrong result), Completeness 2 (misses the actual ask: "daily count over history"), Clarity 3, Actionability 2. **Avg 2.25.**

---

### Q2 — One row per customer: count, sum, latest shipping address via `max_by`
Primary: `MAX_BY(o.shipping_address, o.order_date) AS latest_shipping_address` alongside `COUNT(o.order_id)`, `SUM(o.amount)`, GROUP BY customer_id. ROW_NUMBER subquery given as the multi-column alternative.

Verification (Trino current — https://trino.io/docs/current/functions/aggregate.html#max_by): *"Returns the value of x associated with the maximum value of y over all input values."* This is exactly the "value as of latest event" idiom — and crucially it composes with other aggregates in the SAME `GROUP BY customer_id` (no self-join, no MAX(address)). The ROW_NUMBER + WHERE rn=1 alternative is correct for pulling multiple latest-order columns at once (avoids paying for one `max_by` per column).

- Tiebreak on `order_date` collisions: A2 should ideally mention that `max_by` on ties is non-deterministic — for production-grade idempotency, use a composite ordering column `max_by(shipping_address, ROW(order_date, order_id))` or fall back to the ROW_NUMBER approach with `ORDER BY order_date DESC, order_id DESC`. A2 did not call this out but this is a minor completeness nit, not an accuracy defect.
- LEFT JOIN orders + GROUP BY customer_id is correct — preserves customers with zero orders (`COUNT(o.order_id) = 0`, `SUM(o.amount) = NULL`; consider `COALESCE(SUM(o.amount), 0)` for clean output).

**Scores Q2:** Accuracy 5, Completeness 4, Clarity 5, Actionability 5. **Avg 4.75.**

---

### Q3 — `approx_distinct` custom error + HLL sketch precompute/merge
`approx_distinct(user_id, 0.01)` with valid range `[0.0040625, 0.26]` and "smaller e = tighter = more memory" framing. HLL: `CREATE TABLE ... AS SELECT event_date, CAST(approx_set(user_id) AS varbinary) AS user_id_hll ... GROUP BY event_date`, then `cardinality(merge(CAST(s.user_id_hll AS HyperLogLog)))` for the weekly rollup.

Verification (Trino current):
- https://trino.io/docs/current/functions/aggregate.html#approx_distinct — `approx_distinct(x, e) → bigint`; the error e must be a value between [0.0040625, 0.26]. PASS — the range and the two-arg form are correct.
- https://trino.io/docs/current/functions/hyperloglog.html — `approx_set(x) → HyperLogLog`: *"Returns the HyperLogLog sketch of the input data set of x."* `merge(HyperLogLog) → HyperLogLog`: *"Returns the HyperLogLog of the aggregate union of the individual hll HyperLogLog structures."* `cardinality(HyperLogLog) → bigint`: *"This will perform approx_distinct() on the data summarized by the hll HyperLogLog data sketch."* PASS.
- CAST round-trip HyperLogLog ↔ varbinary for storage is documented; the responder's CTAS-as-varbinary then `CAST(... AS HyperLogLog)` for merge is the canonical persistence pattern. PASS.
- Trade-off framing (tighter = more memory per sketch) is accurate.

**Scores Q3:** Accuracy 5, Completeness 5, Clarity 5, Actionability 5. **Avg 5.0.**

---

### Q4 — Percent-of-total via window aggregate (single pass, no separate grand-total query)
```sql
SELECT category,
       SUM(revenue)                                       AS category_revenue,
       SUM(SUM(revenue)) OVER ()                          AS grand_total,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS percent_of_total
FROM iceberg.analytics.sales
GROUP BY category
```
Verification (Trino current — https://trino.io/docs/current/functions/window.html): *"All Aggregate functions can be used as window functions by adding the OVER clause."* The window runs over the post-GROUP-BY rows; empty `OVER ()` = single window over the whole result, so `SUM(SUM(revenue)) OVER ()` is the grand total of the per-category sums. Pattern A2 in r07 already documents this nested-aggregate-in-window-after-GROUP-BY shape and explicitly calls out the post-GROUP-BY evaluation order.

- Correct grand-total math; `100.0 * ... / ...` forces decimal division (no integer-truncation trap).
- `ROUND(..., 2)` is valid Trino 467.
- No `QUALIFY`, no alias-in-GROUP-BY, no `::`-cast.

**Scores Q4:** Accuracy 5, Completeness 5, Clarity 5, Actionability 5. **Avg 5.0.**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 2 | 2 | 3 | 2 | 2.25 |
| Q2 | 5 | 4 | 5 | 5 | 4.75 |
| Q3 | 5 | 5 | 5 | 5 | 5.0  |
| Q4 | 5 | 5 | 5 | 5 | 5.0  |

**Overall avg = (2.25 + 4.75 + 5.0 + 5.0) / 4 = 4.25 → PASS** (overall avg >= 3.5).

Margin notes: durability locks for max_by-in-larger-aggregate (Q2), approx_distinct custom-error + HLL precompute/merge (Q3), and window-aggregate percent-of-total (Q4) all held perfectly. The 4.25 overall masks a real Q1 semantic miss; the responder constructed the right spine but applied the wrong aggregation shape because resources have no canonical for "count active/open intervals per day" (interval-overlap / as-of range-join). This is a NEW pattern gap, not a regression of a hardened lock.

## iter575 directive — for the teacher

**ADD an interval-overlap / "active-on-each-day" canonical to r07** (distinct from forward-fill, distinct from running totals). Place it as a new card under §1 / Pattern family so the responder finds it by keywords like "active subscribers per day", "open tickets per day", "concurrent sessions per day", "as of each day", "interval overlap per day", "range join per day", "count active intervals".

Required elements of the new canonical (all must be present in one place):
1. **Header + keyword anchors** — must include "active subscribers per day", "as of each day", "interval overlap", "range join calendar", "open tickets per day".
2. **The shape** — `calendar c JOIN entity e ON e.start_ts <= c.day AND (e.end_ts IS NULL OR e.end_ts > c.day) GROUP BY c.day [, dim]`. Call out that this is `[start, end)` half-open by convention (avoid double-counting the boundary day).
3. **Dynamic-bounds spine reuse** — the new card should explicitly reuse the iter573-locked `MIN(...)/CURRENT_DATE` bounds + `sequence` + `CROSS JOIN UNNEST` spine. Cross-link to the existing spine card.
4. **Worked example** — daily active subscribers per plan over full history (the Q1 scenario).
5. **DO-NOT-WRITE matrix** — must include the exact A1 anti-pattern: *"Computing the snapshot once at `CURRENT_DATE` and LEFT JOIN'ing on `c.day = d.day` produces a single today-row plus zeros for all history. The join key must be the calendar day, and the matching condition must be the interval-overlap predicate `start <= c.day AND (end IS NULL OR end > c.day)`."*
6. **Contrast card** — table distinguishing the three patterns the responder must NOT conflate:
   - Forward-fill (last-known value across gap rows) — IGNORE NULLS LAST_VALUE.
   - Running total (cumulative over a partition) — `SUM(...) OVER (ORDER BY ...)`.
   - Interval overlap (count active intervals per day) — calendar x entity range join (this new card).
7. **Performance note** — for billion-row fact tables, mention the boundary-event alternative (`SUM(+1) at start, SUM(-1) at end, cumulative SUM over date`) as the streaming/cheap variant; range-join is fine for moderate cardinality.

**Reconcile, don't append:** the new card goes IN r07 §1.x adjacent to the existing spine/forward-fill cards, with bidirectional cross-references. r23 §3 should get a one-line cross-link from the existing time-series section. Do NOT touch r22 (federation guardrails — iter436 lock).

**Locks to preserve in full** (do not regress while adding the new card):
- iter566 forward-fill / IGNORE-NULLS placement.
- iter573 GROUP-BY-on-aggregate ban (line 892 DO-NOT-WRITE bullet 5).
- iter570/571/572 COMBINED-composition canonical (the spine + bounds CTE pattern).
- r07 approx_distinct two-arg + HLL precompute/merge cards (Q3 lock).
- r07 Pattern A2 nested-aggregate-in-window-after-GROUP-BY (Q4 lock).
- r23 max_by docs-verbatim card + ties-tiebreaker note (Q2 lock).

**Sources cited:**
- https://trino.io/docs/current/functions/aggregate.html#max_by
- https://trino.io/docs/current/functions/aggregate.html#approx_distinct
- https://trino.io/docs/current/functions/hyperloglog.html
- https://trino.io/docs/current/functions/window.html
- https://trino.io/docs/current/functions/array.html#sequence
- https://trino.io/docs/current/sql/select.html
