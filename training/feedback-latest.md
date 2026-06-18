# Judge Feedback — iter1089 (2026-06-18)

Verified BOTH directions against RAW git-tag 467 source (functions/math.md, functions/window.md, functions/aggregate.md, functions/map.md, sql/select.md). Clean sweep; ZERO source-verified defects.

## Q1 — round cost_price UP to next full dollar (4.25→5, 12.80→13, 7.00→7)
**Answer:** `ceil(cost_price) AS price_rounded_up`; notes lowercase `ceil()` (also `ceiling()`).

- **Accuracy: 5** — RAW math.md VERIFIED: `ceiling(x) -> [same as input]` "Returns x rounded up to the nearest integer", and `ceil(x)` "This is an alias for ceiling". Rounds toward +infinity (up), so 4.25→5, 12.80→13, and 7.00 stays 7.00 (already whole). Return type is same-as-input (decimal in → decimal out), so the value is the rounded-up whole number expressed as decimal — value-correct for every example given. `ceil` and `ceiling` both exist and are aliases; lowercase note correct.
- **Completeness: 5** — Directly answers; covers both alias names. Could note return type is decimal (display still `5.00` not `5`), but the VALUE is exactly what was asked.
- **Clarity: 5** — Walks all three example values through the function. Zero assumed knowledge.
- **Actionability: 5** — Drop-in SQL.
- **Avg: 5.00**

## Q2 — monthly_active_users running "peak so far" per row in date order
**Answer:** `MAX(monthly_active_users) OVER (ORDER BY event_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS peak_so_far`.

- **Accuracy: 5** — RAW window.md VERIFIED "All aggregate functions can be used as window functions by adding the OVER clause"; MAX is an aggregate so MAX-as-window is valid. select.md VERIFIED the default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`; the responder's explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is the standard explicit running-window form, and `ROWS` (vs default `RANGE`) is actually PREFERRED here because it avoids peer-tie lumping on duplicate event_dates. Computes the correct running maximum from partition start through the current row.
- **Completeness: 5** — Answers the window-vs-subquery framing implicitly by giving the window form, which is the right tool (a correlated self-join subquery would be O(N^2)). No PARTITION BY needed since it's a single series.
- **Clarity: 4.5** — Clear; "running max from start through current row" is well phrased. Could have one sentence on why window beats a self-join subquery (the question explicitly asked which to use).
- **Actionability: 5** — Drop-in.
- **Avg: 4.875**

## Q3 — build a MAP session_id→user_id in SQL so map['session123'] returns the user_id
**Answer:** `map_agg(session_id, user_id) AS session_to_user_map`; `element_at(map,'session123')` safe (NULL if missing) vs subscript `map['session123']` (throws if missing); optional `json_format(CAST(map AS JSON))` to serialize. Prose first says "using the map() function" but the SQL uses `map_agg`.

- **Accuracy: 4.75** — RAW aggregate.md VERIFIED `map_agg(key, value) -> map<K,V>` "Returns a map created from the input key/value pairs" — exactly right for folding (session_id, user_id) rows into one dictionary. RAW map.md VERIFIED BOTH missing-key behaviors: subscript `[]` "throws an error if the key is not contained in the map" and `element_at()` "Returns value for given key, or NULL if the key is not contained in the map." The element_at-vs-subscript safety guidance is dispositively correct and directly relevant to the user's `map['session123']` ask. Answers "can I do it in SQL, not app code?" → yes. The prose mislabel "using the map() function" is imprecise: `map()` IS a real Trino function but it's the empty-map / `map(keys_array, values_array)` constructor, NOT the row-folding aggregate; it is NOT what the shown SQL uses. Since the actual SQL is `map_agg` and is correct, this is harmless imprecision in the noun, not a query defect — small Accuracy shave only.
- **Completeness: 5** — Builds the map, shows safe lookup, flags the throw-on-missing footgun, and offers serialization. Fully addresses SQL-vs-app-code.
- **Clarity: 4.5** — Strong, but the "map() function" prose vs `map_agg` SQL could momentarily confuse a beginner reading the prose before the code.
- **Actionability: 5** — Drop-in, plus the element_at safety steer is exactly the next thing they'd hit.
- **Avg: 4.8125**

## Q4 — each order's revenue AND previous order's revenue (by date), default 0 instead of NULL
**Answer:** `LAG(revenue, 1, 0) OVER (ORDER BY order_date) AS prev_order_revenue` — 3-arg LAG, third arg is the default 0 for the first order.

- **Accuracy: 5** — RAW window.md VERIFIED the 3-arg lag form: returns the value `offset` rows before the current row, and "If the offset refers to a row that is not within the partition, the default_value is returned, or if it is not specified null is returned." So `LAG(revenue, 1, 0)` yields 0 for the first order (no prior row) instead of NULL — exactly the requested behavior. Note: lag is a ranking/value window fn for which "the window frame must not be specified" — the responder correctly used OVER(ORDER BY ...) with NO frame, so no analyzer error.
- **Completeness: 5** — Hits offset=1, default=0, and the first-order edge case.
- **Clarity: 5** — Explains each of the three args.
- **Actionability: 5** — Drop-in.
- **Avg: 5.00**

## Overall
- Q1: 5.00
- Q2: 4.875
- Q3: 4.8125
- Q4: 5.00
- **Overall average: 4.92 — PASS** (threshold 3.5)

## Defects
ZERO source-verified defects. No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary patterns. The only blemish is a harmless prose noun mislabel in Q3 ("map() function" while the SQL correctly uses `map_agg`) — the executable SQL is correct, so it is not a query defect.

## Recommendation
DEFAULT NO-OP (margin +1.42). NO resource edit; NO commit; NO federation probe. MUST NOT bump state.json (already 1089).
