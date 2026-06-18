# Judge Feedback — iter1055

**Overall: Q1 4.875 / Q2 4.9375 / Q3 4.9375 / Q4 4.90625 → 4.9140625 PASS** (margin +1.414)

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/...), NOT resources/. NO federation probe this iter. RECOMMENDATION = **DEFAULT NO-OP** — zero source-verified resource defects, zero 2-in-2 same-shape slips.

---

## Q1 — current month-to-date revenue (watch (w) re-probe) — 4.875

`SELECT SUM(amount) AS monthly_revenue FROM orders WHERE order_date >= date_trunc('month', current_date) AND order_date < current_date + INTERVAL '1' DAY;`

**Verified (datetime.md):**
- `date_trunc('month', x)` truncates to first-day-of-month at 00:00 (doc: `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00') -- 2022-10-01 00:00:00.000`). With `current_date` → first day of THIS month. CORRECT lower bound.
- `current_date` = current date as of query start (date type). `current_date + INTERVAL '1' DAY` = start of tomorrow; operators table confirms `date + interval day` valid (`date '2012-08-08' + interval '2' day`).
- Half-open `>= start_of_month AND < start_of_tomorrow` correctly captures month-start through end-of-today inclusive, no double-count, boundary-safe regardless of order_date being timestamp (date↔timestamp coercion implicit; bare column on the left preserves partition pruning).

**FINDING (1) — watch (w): iter1054 last-month off-by-one DID NOT RECUR.** iter1054 used `date_trunc('month',current_date) - INTERVAL '1' MONTH`, selecting the PREVIOUS complete month. This question asked for CURRENT month-to-date and correctly used `date_trunc('month', current_date)` with NO month subtraction. The off-by-one is CLEAN. Per-instance logic slip resolved; not a resource issue either way.

Half-open, bare-column-left, pruning-friendly canonical form. Minor clarity note (no tier ding): the `current_date + INTERVAL '1' DAY` upper bound is exactly right; an equivalent `date_trunc('day', current_timestamp)+INTERVAL '1' DAY` could have been mentioned but isn't needed.

---

## Q2 — features array contains ALL of {'api_access','sso'} — 4.9375

`WHERE cardinality(array_except(ARRAY['api_access','sso'], features)) = 0;` AND alt `all_match(ARRAY['api_access','sso'], x -> contains(features, x))`.

**Verified (array.md):**
- `array_except(x, y)` = "elements in x but not in y, without duplicates." With `x = required`, `y = features`: result = required-elements-NOT-present-in-features. Empty (cardinality 0) ⇔ every required element present. CORRECT all-of-set logic — required is correctly the first arg.
- `all_match(array(T), function) -> boolean`: true iff every element matches; checks each required element is `contains(features, x)`. Equivalent and correct.
- `contains(x, element) -> boolean` membership confirmed.

Both forms valid and correctly distinguish ALL-of (vs ANY-of). Excellent.

---

## Q3 — average completed session length in minutes — 4.9375

`SELECT AVG(date_diff('minute', started_at, ended_at)) AS avg_session_minutes FROM sessions WHERE ended_at IS NOT NULL;`

**Verified (datetime.md / aggregate.md):**
- `date_diff(unit, ts1, ts2) -> bigint`, "returns ts2 - ts1 expressed in terms of unit," complete/truncated units. `date_diff('minute', started_at, ended_at)` → whole minutes elapsed. CORRECT.
- `WHERE ended_at IS NOT NULL` filters to completed sessions (NULL = incomplete). AVG additionally ignores NULL, so the filter is correct AND defensively redundant.
- AVG over bigint → double average; returns NULL on empty set (acceptable).

Tight and correct. Sub-minute precision not requested; complete-minute granularity is the natural reading of "in minutes."

---

## Q4 — group events by nested JSON device.os (watch (r) re-test) — 4.90625

`SELECT json_extract_scalar(metadata, '$.device.os') AS os_type, COUNT(*) ... GROUP BY json_extract_scalar(metadata, '$.device.os') ORDER BY event_count DESC.` Proactively warns Trino does NOT allow GROUP BY to reference a SELECT alias (#16533).

**Verified (json.md / sql/select.md):**
- Trino has NO Postgres-style `->`/`->>` arrow operators (json.md lists json_extract/json_extract_scalar/json_query/json_value only). Responder correctly translated the user's Postgres `metadata -> 'device' -> 'os'` to `json_extract_scalar(metadata, '$.device.os')`.
- `json_extract_scalar(json, json_path) -> varchar`; doc example `'$.store.book[0].author'` confirms nested-path scalar extraction → `'$.device.os'` is the correct nested form.
- **#16533 caveat ACCURATE:** select.md states GROUP BY accepts "any expression composed of input columns OR an ordinal number selecting an output column by position" — it does NOT list SELECT-list aliases. So `GROUP BY os_type` → "Column 'os_type' cannot be resolved"; `GROUP BY 1` or repeating the expression is required. Responder repeated the expression in GROUP BY (valid) AND proactively taught the alias prohibition.

**FINDING (2) — watch (r): JSON GROUP-BY-expression + #16533 proactive caveat is DURABLE.** Consecutive positive JSON-group-by re-probe (cf. iter1048 Q4). The r13 L3371/L3366 FIX-A teaching the #16533 caveat and the no-arrow translation continues to surface correctly. Watch (r) stays CLOSED/passive.

Minor clarity note (no tier ding): could have led with an outright "Trino has no `->` arrow operator," but it translated correctly and the caveat it foregrounded (#16533) is the higher-value gotcha.

---

## Cross-cutting

No `::`-cast, QUALIFY, false-semi-join, fabricated function, regex-backslash, INTERVAL quarter/week, OFFSET-before-LIMIT, over-warning folklore, or broken-secondary-alternative in any of the 4. Both prior watch items confirmed clean: (w) current-month window correct / off-by-one non-recurrence; (r) JSON group-by + #16533 durable.

**RECOMMENDATION: DEFAULT NO-OP.** No resource edit, no commit. MUST NOT bump state.json (already 1055).
