# Common Analytical Query Patterns

> **Production note:** All SQL examples below run on Trino against Iceberg tables in MinIO. Trino syntax is standard ANSI SQL with a few extras (`date_trunc`, `unnest`, window functions) that are well documented.

---

## Quick answer

Four patterns cover ~90% of SaaS analytics:

1. **Aggregations** — "how many X by Y" (signups by plan, revenue by month). `COUNT`, `SUM`, `GROUP BY`.
2. **Funnels** — "what % of users moved from step A to step B to step C." Sequence of events with drop-off at each step.
3. **Cohort analysis** — "of users who signed up in week 0, how many were still active in week 4." Group by join date, measure retention over time.
4. **Time-series** — "show me signups per day for the last 30 days, with zeros on days no one signed up." Bucket by time + fill gaps.

Each pattern stresses an OLAP engine differently — knowing which is which helps you debug slow queries.

---

## 1. Aggregations (the bread and butter)

**The SaaS question:** "How many signups did we get this month, broken down by plan?"

```sql
SELECT plan_type, COUNT(*) AS signups
FROM iceberg.analytics.user_events
WHERE event_name = 'signup'
  AND event_date >= date_trunc('month', current_date)
GROUP BY plan_type
ORDER BY signups DESC;
```

**Why it's slow on Postgres, fast on Trino + Iceberg:**
- Postgres reads every row of `user_events`, including columns it doesn't need (row-oriented storage).
- Trino reads only `plan_type`, `event_name`, and `event_date` columns from the Parquet files. Iceberg skips files that don't fall in the current month.

**What to watch for:** if `GROUP BY` has high cardinality (e.g., `GROUP BY user_id` across 50M users), the engine has to keep all distinct groups in memory. Add a `HAVING COUNT(*) > N` to trim, or pre-aggregate.

---

## 1a. Exploding an array column to one row per element (UNNEST / array to rows / LEFT JOIN UNNEST)

**The SaaS question:** "I have a `users` table with a `tags ARRAY(VARCHAR)` column — give me one row per (user, tag) so I can `GROUP BY tag`." Same shape: "one row per element", "explode array", "array to rows", "flatten array column".

**Keyword anchor:** UNNEST array column, explode array Trino, array to rows, one row per element, one row per tag, flatten array, LEFT JOIN UNNEST, CROSS JOIN UNNEST, keep empty array rows, preserve NULL array rows.

**Two forms — they have DIFFERENT row semantics:**

```sql
-- FORM 1 — CROSS JOIN UNNEST: DROPS parent rows whose array is NULL or empty.
-- Semantically an INNER join: zero array elements -> zero output rows for that parent.
SELECT u.user_id, t.tag
FROM iceberg.analytics.users u
CROSS JOIN UNNEST(u.tags) AS t(tag);

-- FORM 2 — LEFT JOIN UNNEST(...) ON TRUE: KEEPS parent rows whose array is NULL or empty,
-- emitting one row with NULL in the unnested column. ON TRUE is the only join condition the
-- LEFT JOIN UNNEST form supports.
SELECT u.user_id, t.tag
FROM iceberg.analytics.users u
LEFT JOIN UNNEST(u.tags) AS t(tag) ON TRUE;
```

**Rule of thumb:** if dropping the user when their `tags` array is NULL or `ARRAY[]` is WRONG for your metric (e.g., "users per tag, but also count untagged users"), use FORM 2 (`LEFT JOIN UNNEST ... ON TRUE`). If you genuinely want to skip empty/NULL arrays (e.g., "tag popularity — untagged users don't count"), FORM 1 is correct and slightly cheaper.

Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) (UNNEST section: "LEFT JOIN is preferable in order to avoid losing the row containing the array/map field in question when referenced columns from relations on the left side of the join can be empty or have NULL values").

> **Note:** the `UNNEST(sequence(...))` patterns in §4 (time-series gap-fill) and §5 Pattern B2 (YoY gap-fill spine) never drop rows because `sequence(start, stop, step)` always returns a non-NULL, non-empty array — the NULL/empty-array gotcha only applies to UNNEST over a real ARRAY column whose values can be NULL or `ARRAY[]`.

> **Sub-note — `WITH ORDINALITY` for the ORIGINAL array position (1-based, appended LAST in the alias list).** **Keyword anchor:** UNNEST with ordinality Trino, array element index/position, original array offset, explode array keep index, which position in array. Append `WITH ORDINALITY AS t(elem, idx)` to either UNNEST form to recover the 1-based ORIGINAL array offset of each element. The ordinality column is appended as the **LAST** column in the alias list — element first, ordinality last: `CROSS JOIN UNNEST(arr) WITH ORDINALITY AS t(elem, idx)`. Worked example: `SELECT user_id, tag, idx FROM iceberg.analytics.users CROSS JOIN UNNEST(tags) WITH ORDINALITY AS t(tag, idx)` — for `tags = ARRAY['analytics','billing','admin']`, `'billing'` gets `idx = 2`. Also works on the LEFT form: `LEFT JOIN UNNEST(arr) WITH ORDINALITY AS t(elem, idx) ON TRUE`. **DO NOT WRITE:** "Trino has no `WITH ORDINALITY` — it is Postgres-only" (FALSE — Trino 467 supports it, verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html)); using `ROW_NUMBER() OVER (ORDER BY ...)` to recover the original array index — `ROW_NUMBER` assigns a NEW ordering per its own `ORDER BY`, NOT the array offset. Use `WITH ORDINALITY` to get the original position.

### 1a.1 CLAUSE-ORDER RULE — `CROSS JOIN UNNEST` / `LEFT JOIN UNNEST ... ON TRUE` is part of the FROM clause and MUST appear BEFORE `WHERE`

**Keyword anchor:** UNNEST WHERE order, CROSS JOIN UNNEST WHERE position, mismatched input 'CROSS' parse error, SQL clause order JOIN before WHERE, split comma-separated string and count, split delimited string count per value, tags array count per tag, explode and filter then group, SPLIT then UNNEST then WHERE.

**The rule (memorize this — it is a parse-error trap, not a runtime bug).** SQL written-clause order is:

```
FROM / JOIN  →  WHERE  →  GROUP BY  →  HAVING  →  SELECT  →  ORDER BY
```

`CROSS JOIN UNNEST(...)` and `LEFT JOIN UNNEST(...) ON TRUE` are **JOIN syntax — they are part of the FROM clause**. They MUST appear BEFORE the `WHERE` clause. Putting `WHERE` between `FROM` and the `JOIN` is a syntax error, NOT a semantic gotcha — Trino fails to parse with `mismatched input 'CROSS'` (or `mismatched input 'LEFT'`) before the query ever runs.

#### DO NOT WRITE — WHERE placed BEFORE the CROSS JOIN UNNEST (parse error)

```sql
-- BROKEN — parse error: "mismatched input 'CROSS'. Expecting: '<EOF>', ',', 'GROUP', 'HAVING', ...".
-- Cause: WHERE appears between FROM and the JOIN. WHERE must come AFTER all FROM/JOIN clauses.
SELECT TRIM(tag) AS tag, COUNT(*) AS n
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-26'
  AND tags IS NOT NULL
CROSS JOIN UNNEST(SPLIT(tags, ',')) AS t(tag)   -- <-- parser fails HERE
GROUP BY TRIM(tag)
ORDER BY n DESC;
```

The same shape is broken for `LEFT JOIN UNNEST(...) ON TRUE` — moving `WHERE` above the JOIN is a parse error regardless of which UNNEST form you use.

#### CORRECT — split a comma-separated string and count per value (the canonical worked example)

```sql
-- CORRECT — WHERE comes AFTER the CROSS JOIN UNNEST.
-- "Split the comma-separated `tags` VARCHAR column into one row per tag, then count per tag."
SELECT TRIM(tag) AS tag, COUNT(*) AS n
FROM iceberg.analytics.events
CROSS JOIN UNNEST(SPLIT(tags, ',')) AS t(tag)   -- JOIN is part of FROM
WHERE event_date = DATE '2026-05-26'             -- WHERE comes AFTER all JOINs
GROUP BY TRIM(tag)
ORDER BY n DESC;
```

**Why this works.** The CROSS JOIN UNNEST is a relational source (it produces rows the WHERE clause will filter). Filtering happens AFTER the row source is fully built — that is the universal SQL evaluation order, not a Trino-specific quirk.

**`SPLIT(tags, ',')`** returns `ARRAY(VARCHAR)`. The UNNEST then explodes that array into one row per element. `TRIM(tag)` strips leading/trailing whitespace from `'a, b, c'` style inputs. For richer string-split forms (`split_to_map`, `split_part`, `split_to_multimap`) see [resource 23 §3.1A — Trino string-split family reference](23-sql-best-practices-olap.md#31a-trino-string-split-family-reference--split-split_part-split_to_map-split_to_multimap).

**Filter the parent table BEFORE the UNNEST (faster) — use a subquery, NOT a misplaced WHERE.** If you want partition pruning to fire BEFORE the explode (it should, for selectivity), wrap the filter in a subquery — do NOT move WHERE above the JOIN:

```sql
-- CORRECT — partition-prune in a subquery, then UNNEST the surviving rows.
SELECT TRIM(tag) AS tag, COUNT(*) AS n
FROM (
  SELECT tags
  FROM iceberg.analytics.events
  WHERE event_date = DATE '2026-05-26'
    AND tags IS NOT NULL
) e
CROSS JOIN UNNEST(SPLIT(e.tags, ',')) AS t(tag)
GROUP BY TRIM(tag)
ORDER BY n DESC;
```

Functionally equivalent to the one-block form above for an Iceberg partitioned table — Trino's optimizer pushes the `event_date` predicate to the scan in either spelling. The subquery form is purely for readability.

**The minimal mental model.** "JOIN before WHERE" is not optional in standard SQL — it is the grammar. Every JOIN form (INNER, LEFT, RIGHT, CROSS, FULL OUTER, CROSS JOIN UNNEST, LEFT JOIN UNNEST ON TRUE, lateral joins) sits inside the FROM clause and must be written before the WHERE clause. Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) (Trino SELECT grammar — FROM/relation precedes WHERE).

### 1a.2 `ARRAY_AGG` over LEFT-JOIN unmatched groups returns `ARRAY[null]`, NOT NULL and NOT `[]` — use `FILTER (WHERE col IS NOT NULL)`

**Keyword anchor:** array_agg empty array, collect tags into list, users with no tags empty list not null, array_agg filter where not null, array_agg LEFT JOIN no match, COALESCE array_agg ARRAY[], reverse of UNNEST collect.

**The trap.** You write `SELECT u.user_id, ARRAY_AGG(t.tag) AS tags FROM users u LEFT JOIN user_tags t ON t.user_id = u.user_id GROUP BY u.user_id`. For a user with NO matching tag rows, the LEFT JOIN emits ONE row with `t.tag = NULL`. `ARRAY_AGG(t.tag)` over that single NULL-padded row produces **`ARRAY[null]`** — a one-element array whose only element is NULL. It is **NOT** NULL and **NOT** `ARRAY[]` (empty). So the popular guard `COALESCE(ARRAY_AGG(t.tag), ARRAY[])` **never fires** — the aggregate result is non-NULL, so COALESCE returns the original `ARRAY[null]` unchanged.

**The fix — `FILTER (WHERE col IS NOT NULL)` (per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) — "A common and very useful example is to use FILTER to remove nulls from consideration when using array_agg").** With FILTER, the unmatched LEFT-JOIN row's NULL is excluded from aggregation BEFORE `array_agg` sees it — leaving zero rows for that group, which makes `array_agg` return NULL. Wrap THAT NULL in `COALESCE(..., ARRAY[])` if you need an empty array literal for no-match groups:

```sql
-- CORRECT — empty array for users with no tags (and no spurious [null] elements).
SELECT u.user_id,
       COALESCE(ARRAY_AGG(t.tag) FILTER (WHERE t.tag IS NOT NULL), ARRAY[]) AS tags
FROM iceberg.analytics.users u
LEFT JOIN iceberg.analytics.user_tags t ON t.user_id = u.user_id
GROUP BY u.user_id;
-- Result for user 42 with no matching tags: ARRAY[]
-- Result for user 43 with tags ['vip', 'beta']: ARRAY['vip', 'beta']
```

**DO NOT WRITE:**

| Wrong shape | Why it doesn't work |
|---|---|
| `COALESCE(ARRAY_AGG(t.tag), ARRAY[])` (no FILTER) | Ineffective. The LEFT-JOIN unmatched row gives `ARRAY_AGG` one NULL input — the result is `ARRAY[null]` (non-NULL). `COALESCE` never fires; you still get `[null]` instead of `[]`. |
| "`ARRAY_AGG` returns NULL or empty array for no-match LEFT JOIN groups." | False in this exact scenario. The unmatched LEFT-JOIN row IS a row (NULL-padded) — `ARRAY_AGG` aggregates over one row, returning `ARRAY[null]`. NULL is what you get when ZERO rows reach the aggregate, which only happens AFTER FILTER excludes the NULL row. |

**Mental model.** `ARRAY_AGG` is the reverse of `UNNEST` — it collects rows into an array. LEFT JOIN's NULL-padding is an actual row, not an absence of a row, so it gets collected too. `FILTER (WHERE x IS NOT NULL)` removes that NULL row BEFORE collection, restoring "no matching tags = empty array" semantics. Same fix applies to `MAP_AGG`, `MULTIMAP_AGG`, and any other collection aggregate over a LEFT-JOIN unmatched side.

### 1a.2A LEADING CANONICAL — `array_agg(x ORDER BY y)` ordered aggregation (+ DISTINCT; cross-ref `listagg` / `array_join(array_agg(...), ',')`)

> **READ THIS FIRST if your question contains any of these keywords:** `array_agg order`, `array_agg ORDER BY`, `ordered aggregation Trino`, `array_agg DISTINCT`, `collect ordered list`, `array_agg ORDER BY production`, `is array_agg ordered`, `does array_agg preserve order`, `collect rows into array in order`, `event sequence array`. Verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) on 2026-06-06.

**The one-fact summary.** Without an inline `ORDER BY` inside the aggregate call, the element order in the resulting array is **non-deterministic** — Trino is free to collect rows in whatever order partitions return them, and that order can change between runs. To get a deterministic element sequence, write the `ORDER BY` **INSIDE the aggregate call**: `array_agg(event_name ORDER BY occurred_at)`. Trino docs verbatim under "Ordering during aggregation": *"array_agg(x ORDER BY y DESC)"* and *"array_agg(x ORDER BY x, y, z)"*. Do NOT rely on an outer `ORDER BY` on the SELECT — that orders rows AFTER aggregation, not elements WITHIN each array.

```sql
-- CORRECT — deterministic ordered event sequence per user (oldest event first):
SELECT user_id,
       array_agg(event_name ORDER BY occurred_at) AS event_sequence
FROM iceberg.analytics.user_events
GROUP BY user_id;

-- WITH DISTINCT (dedup elements) — `array_agg(DISTINCT x)` dedupes before collection:
SELECT user_id,
       array_agg(DISTINCT event_name ORDER BY event_name) AS unique_events
FROM iceberg.analytics.user_events
GROUP BY user_id;
```

> **DO NOT WRITE.** (1) `array_agg(x)` without `ORDER BY` and expect chronological / insertion / file order — **non-deterministic**; will silently break the next time partitioning changes. (2) Outer `SELECT ... ORDER BY occurred_at` to "order the array" — that orders the OUTER ROWS, not the array's elements. ORDER BY must be **inside** the aggregate. (3) `array_agg(x ORDER BY y) OVER (PARTITION BY k)` — Trino does NOT support inline `ORDER BY` combined with `OVER (...)` in the same `array_agg`; see [resource 27 § 7A.2A](27-oracle-plsql-to-dbt-trino.md) for the pre-sorted CTE workaround. (4) `array_agg` for string-joining when you really want a delimited STRING — use `listagg(col, ',') WITHIN GROUP (ORDER BY col)` (one row per group) OR `array_join(array_agg(col ORDER BY col), ',')` (when you need windowed/array form); see [resource 27 § 7A.2A / § 7A.2B](27-oracle-plsql-to-dbt-trino.md) — do not rewrite that family here. (5) **`listagg(DISTINCT product, ',')` is NOT supported in Trino — listagg takes no DISTINCT keyword; for a distinct comma-separated roll-up / dedupe roll-up / unique values rolled up into one cell use `array_join(array_agg(DISTINCT product ORDER BY product), ', ')`.** *Keyword anchors: distinct comma-separated list, dedupe roll-up, listagg distinct, distinct array_agg join, unique values in one cell.* Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — the documented `listagg` signature is `LISTAGG( expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, ...) [FILTER (WHERE condition)]`. There is **no `DISTINCT` slot** in that signature; writing `listagg(DISTINCT x, ',')` fails at analysis. The `array_agg(DISTINCT x ORDER BY x)` form dedupes BEFORE collection, then `array_join(..., ', ')` concatenates with the separator — semantically identical to "Oracle's `LISTAGG(DISTINCT col, ',')` 12c+ extension", with the caveat that `array_join` skips NULLs by default in the 2-arg form (matching `listagg` NULL-skip behavior) and has no `ON OVERFLOW` clause (use explicit length checks if the joined string risks the 1 MiB row limit). See [resource 27 § 7A.2B](27-oracle-plsql-to-dbt-trino.md) for the broader string-aggregation choice between `listagg` and `array_join(array_agg(...))`.

#### Sub-canonical — rolling up **NUMERIC ids/values** into a comma-separated string: `listagg` and `array_join` BOTH require **VARCHAR** input — `CAST(... AS varchar)` first (iter639 FIX-A)

> **READ THIS FIRST — keyword anchors:** roll up ids into a comma-separated string, concatenate order ids into one field, comma-separated list of numeric ids, join numbers into a string with listagg, listagg numeric error, listagg bigint error, listagg integer must be varchar, array_join of an id column, array_join numeric array, array_join bigint integer cast, single text field of all a customer's order ids, glue order ids into one string per customer, comma list of order_ids per customer, listagg of order_id, array_join(array_agg(order_id)), `Unexpected parameters (bigint, varchar) for function listagg`, `Unexpected parameters (array(bigint), varchar) for function array_join`.

**The one-fact lead.** Both Trino string-rollup aggregates take a **VARCHAR** payload and **Trino does NOT implicitly convert numeric -> varchar** in either of them (verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html), [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html), and [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) verbatim: *"Trino will not convert between character and numeric types"*).
> - `listagg(x, separator) -> varchar`: `x` **must be VARCHAR**. A `bigint` / `integer` / `decimal` / `double` `x` errors at analysis with `Unexpected parameters (bigint, varchar) for function listagg. Expected: listagg(varchar, varchar)`. The Trino docs show the canonical fix verbatim: `SELECT listagg(CAST(v AS varchar), ',') WITHIN GROUP (ORDER BY v) FROM (VALUES 1, 3, 2) t(v)` — **cast the INPUT to varchar; the `ORDER BY` keeps the underlying numeric so it sorts numerically (1, 2, 3 — not '1','2','3' lexicographic).**
> - `array_join(array, delimiter) -> varchar`: requires the array to be `array(varchar)`. `array_join(array_agg(order_id ORDER BY order_id), ', ')` over a `bigint` `order_id` errors with `Unexpected parameters (array(bigint), varchar) for function array_join. Expected: array_join(array(varchar), varchar)`. **Cast inside `array_agg`** so the array element type is varchar from the start: `array_join(array_agg(CAST(order_id AS varchar) ORDER BY order_id), ', ')` (the `ORDER BY` still references the numeric `order_id` and sorts numerically).
> - **Same family as the [§3.1A concat / format / `||` number→varchar coercion guardrail (resource 23)](23-sql-best-practices-olap.md#sub-canonical--building-a-formatted-duration-string-like-2h-15m-concat--need-explicit-castas-varchar-on-every-number--or-just-use-format).** The one-line rule is identical across `listagg` / `array_join` / `concat` / `||`: **Trino has no implicit number-to-varchar coercion anywhere — always `CAST(num AS varchar)` first.**

```sql
-- RIGHT idiom 1 — listagg over a NUMERIC order_id (one row per customer, comma-separated order ids):
SELECT customer_id,
       listagg(CAST(order_id AS varchar), ', ') WITHIN GROUP (ORDER BY order_id) AS order_ids
FROM iceberg.analytics.orders
GROUP BY customer_id;
-- The ORDER BY references the NUMERIC order_id so the sort is numeric (1, 2, 10, 100 — not '1','10','100','2' lexicographic).
-- Only the listagg INPUT is cast to varchar; the ORDER BY column stays numeric.

-- RIGHT idiom 2 — array_join(array_agg(...)) form (use when you need a windowed/array shape OR DISTINCT):
SELECT customer_id,
       array_join(array_agg(CAST(order_id AS varchar) ORDER BY order_id), ', ') AS order_ids
FROM iceberg.analytics.orders
GROUP BY customer_id;
-- CAST goes INSIDE array_agg so the resulting array is array(varchar) — then array_join can concatenate it.
-- For the DISTINCT-roll-up variant: array_join(array_agg(DISTINCT CAST(order_id AS varchar) ORDER BY CAST(order_id AS varchar)), ', ').
```

**DO NOT WRITE (the EXACT iter638-class failure modes — both error at analysis on a numeric `order_id`):**

| Wrong shape | Why it errors |
|---|---|
| `listagg(order_id, ', ') WITHIN GROUP (ORDER BY order_id)` (numeric `order_id`) | `listagg(x, sep)` requires `x` to be **VARCHAR**. A `bigint` / `integer` `order_id` raises `Unexpected parameters (bigint, varchar) for function listagg. Expected: listagg(varchar, varchar)`. **Trino does NOT auto-convert numeric -> varchar** ([trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) verbatim: *"Trino will not convert between character and numeric types"*). Fix: `listagg(CAST(order_id AS varchar), ', ') WITHIN GROUP (ORDER BY order_id)` — cast the INPUT, keep the numeric ORDER BY for numeric sort. |
| `array_join(array_agg(order_id ORDER BY order_id), ', ')` (numeric `order_id`) | `array_join(arr, sep)` requires `arr` to be `array(varchar)`. `array_agg` over a `bigint` column produces `array(bigint)` — `array_join` then raises `Unexpected parameters (array(bigint), varchar) for function array_join. Expected: array_join(array(varchar), varchar)`. Same no-implicit-coercion rule. Fix: `array_join(array_agg(CAST(order_id AS varchar) ORDER BY order_id), ', ')` — cast INSIDE `array_agg` so the element type is varchar. |
| `array_join(transform(array_agg(order_id ORDER BY order_id), x -> CAST(x AS varchar)), ', ')` | **Works** but unnecessarily verbose — `transform()` casts AFTER aggregation. Prefer casting inside `array_agg` (one less step, one less lambda). Keep this form only if `array_agg` was produced elsewhere (e.g. windowed). |
| `listagg(order_id::varchar, ', ') WITHIN GROUP (ORDER BY order_id)` (Postgres-style `::` cast) | Trino does **NOT** parse `::` as a cast — raises `mismatched input ':'` at parse time. Use ANSI `CAST(order_id AS varchar)`. |

**One-line rule.** **`listagg` and `array_join` are VARCHAR-only on their payload.** Numeric `order_id` / `user_id` / `product_id` / `amount` etc. **must** be wrapped in `CAST(... AS varchar)` before they enter `listagg` (as the input) or `array_agg` (so the resulting array is `array(varchar)` for `array_join` to consume). The **ORDER BY** can — and should — keep the original numeric column so the sort is numeric, not lexicographic. Cross-link: [resource 23 §3.1A `format()` / `concat()` / `||` number→varchar coercion guardrail](23-sql-best-practices-olap.md#sub-canonical--building-a-formatted-duration-string-like-2h-15m-concat--need-explicit-castas-varchar-on-every-number--or-just-use-format) — same family, same rule.

**Cross-references.** [§1a.2](#1a2-array_agg-over-left-join-unmatched-groups-returns-arraynull-not-null-and-not--use-filter-where-col-is-not-null) for the LEFT-JOIN `FILTER (WHERE col IS NOT NULL)` trap (same `array_agg`). [Resource 23 § 3 / § 3.1D](23-sql-best-practices-olap.md) for the rest of the Trino aggregate family (`approx_percentile`, `arbitrary`, `max_by`) and the FILTER clause. [Resource 27 § 7A.2A — Oracle WINDOWED LISTAGG → Trino](27-oracle-plsql-to-dbt-trino.md) for string-aggregation choice between aggregate `listagg` and `array_join(array_agg(...))`.

### 1a.3 Trino array-function quick reference — `contains` / `cardinality` / `array_distinct` / `element_at` / `array_join` / `array_position` (DO NOT claim Trino lacks a `contains`)

**Keyword anchor:** Trino array contains, does array contain element, does array contain value, array membership test Trino, cardinality array length Trino, array_distinct dedup, array_intersect array_union array_except set operations on arrays, element_at array negative index, check if array has value, array has element, array membership without UNNEST, join array to string Trino, concat array elements Trino, array_join delimiter, array_position find element index, position of element in array Trino, where in array is value.

**These are companions to `UNNEST` (§1a / §1a.1) and `array_agg` (§1a.2): UNNEST explodes an array to rows; the functions below operate on the array AS A WHOLE — no UNNEST needed for membership / length / dedup / set ops / position / join-to-string.** Verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html).

| Function | Signature | What it does |
|---|---|---|
| `contains` | `contains(array, element) -> boolean` | **Membership test.** Use THIS, NOT `UNNEST + EXISTS / WHERE`, to ask "does this array hold value X?". Example: `WHERE contains(event_tags, 'upload')`. |
| `cardinality` | `cardinality(array) -> bigint` | **Element count (array length).** Also accepts MAP — returns key count. |
| `array_distinct` | `array_distinct(array) -> array` | Dedup array elements; preserves first-occurrence order. Per-row distinct count = `cardinality(array_distinct(x))`. |
| `array_intersect` / `array_union` / `array_except` | `array_intersect(a, b)`, `array_union(a, b)`, `array_except(a, b)` | Set operations on two arrays; result is deduped. |
| `element_at` | `element_at(array, n) -> E` | **NULL-safe positional access — 1-based.** Returns NULL if `n` is out of range (unlike the `array[n]` subscript, which RAISES an error). **Negative `n` counts from the end** (`element_at(arr, -1)` = last element). |
| `array_join` | `array_join(x, delimiter) -> varchar` / `array_join(x, delimiter, null_replacement) -> varchar` | **Concatenate the elements of an array into a single string** using the delimiter. The 3-arg form substitutes `null_replacement` for any NULL element (the 2-arg form skips NULLs). Example: `array_join(ARRAY['a','b','c'], ',') -> 'a,b,c'`. Use this on a per-row ARRAY column. For ACROSS-row string aggregation (`STRING_AGG`/`LISTAGG`/`GROUP_CONCAT` equivalents on Trino), see [resource 27 § 7A.2A/§ 7A.2B](27-oracle-plsql-to-dbt-trino.md). |
| `array_position` | `array_position(x, element) -> bigint` | **Returns the 1-based position of the first occurrence of `element` in array `x`, or `0` if not found** (verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html)). Use this when you want the index, not just a yes/no — e.g. funnel-step number from a step-name array. Note: 0 means "not found", NOT NULL. |

**WHEN TO USE WHICH:**
- Membership ("does the array hold X?"): `contains(arr, X)`.
- Per-row distinct count ("how many distinct tags on THIS row?"): `cardinality(array_distinct(arr))`.
- Cross-row distinct count over EXPLODED elements ("how many distinct tags across the whole table?"): UNNEST first, then `COUNT(DISTINCT tag)` — see §1a.1 worked example.
- "Get the last element of the array": `element_at(arr, -1)` — NULL-safe; `arr[cardinality(arr)]` is verbose and errors on empty arrays.

> **`contains` is an EXACT, case-SENSITIVE match** (`'Web'` != `'web'`, `'WEB'` != `'web'`); for case-insensitive matching, normalize BOTH sides via `lower()`: `contains(transform(categories, x -> lower(x)), lower('web'))`. The `transform` lambda lowercases each array element in place; `lower('web')` keeps the comparison symmetric so a hardcoded literal like `'Web'` still matches. Same rule for `array_position` (exact equality) and `array_intersect` / `array_union` / `array_except` (exact element identity). For the COMPLEMENTARY whitespace-safety gotcha on the `contains(split(col, ','), 'web')` shape (split returns elements with leading spaces), see [resource 23 § 3.1A DO NOT WRITE table](23-sql-best-practices-olap.md#31a-trino-string-vs-array--split-vs-array_join-vs-contains-vs-position-vs-strpos--what-to-use-when).

**DO NOT WRITE:**

| Wrong shape | Why it's wrong |
|---|---|
| "Trino has no `contains` function for arrays" / "Trino has no single-call array-membership function" | **FALSE.** `contains(array, element)` exists and is the documented array-membership test per [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html). |
| `WHERE EXISTS (SELECT 1 FROM UNNEST(arr) AS t(x) WHERE x = 'value')` purely to test membership | Works, but verbose. Use `WHERE contains(arr, 'value')` — simpler, the planner handles it, and it does not require the parent table to be UNNESTed. |
| `WHERE arr[1] = 'value'` to test "does the first element equal X" on a possibly-empty array | The `[]` subscript ERRORS on out-of-range indices. Use `element_at(arr, 1) = 'value'` (NULL-safe — falls out of `WHERE` cleanly). |
| `COUNT(DISTINCT arr)` to count distinct ELEMENTS inside the array | Counts distinct ARRAY VALUES (i.e., distinct rows) — not elements. For element-level distinct, UNNEST first OR use `cardinality(array_distinct(arr))` per row. |

> **Note on MAPs.** `contains` does NOT work on MAPs — for "does this map have key K?" use `element_at(map, key) IS NOT NULL` (see [resource 09 § MAP existence check](09-lakehouse-schema-design.md#critical--use-element_at-not--for-map-access-in-trino)) or `contains(map_keys(map), key)` (note `map_keys` returns an `ARRAY`, then `contains` on that array works).

### 1a.4 Trino ARRAY higher-order functions — `transform` / `filter` / `reduce` / `any_match` / `array_sort` apply a lambda IN-ARRAY (no UNNEST)

**Keyword anchor:** Trino array transform filter reduce, apply function to each array element, lambda array Trino, higher-order array function, map over array without unnest, transform array Trino, filter array by condition, reduce array to scalar, any_match all_match none_match array, array_sort comparator, zip_with two arrays, array HOF.

**The rule.** When you want to APPLY a function PER ELEMENT but keep the result AS AN ARRAY (one row in, one row out — a transformed/filtered ARRAY), use a Trino ARRAY higher-order function (HOF). HOFs take a lambda written with `->`. You only need to UNNEST when you actually want ROWS (one row per element, e.g. for GROUP BY / JOIN across elements). Verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) and [trino.io/docs/current/functions/lambda.html](https://trino.io/docs/current/functions/lambda.html).

| Function | Signature | What it does — worked example |
|---|---|---|
| `transform` | `transform(array(T), T -> U) -> array(U)` | Map each element through the lambda. `transform(prices, p -> p * 1.1)` -> ARRAY with each price scaled by 1.1. |
| `filter` | `filter(array(T), T -> boolean) -> array(T)` | Keep only matching elements. `filter(scores, s -> s >= 80)` -> ARRAY of scores >= 80. |
| `reduce` | `reduce(array(T), S initial, (S, T) -> S, S -> R) -> R` (4-arg) | Fold to a scalar. `reduce(amounts, 0, (s, x) -> s + x, s -> s)` -> sum of `amounts`. |
| `any_match` / `all_match` / `none_match` | `any_match(array(T), T -> boolean) -> boolean` | Did any / all / no elements satisfy the lambda? |
| `array_sort` | `array_sort(array(T))` or `array_sort(array(T), (a, b) -> int)` | Sort ascending; the 2-arg form takes a comparator returning -1/0/1. |
| `zip` / `zip_with` | `zip(a, b) -> array(row)` / `zip_with(a, b, (x, y) -> R) -> array(R)` | Element-wise pair / merge of two equal-length arrays. |

**When to UNNEST vs use an HOF.** UNNEST explodes an array to ROWS (one row per element) — use it when the next step needs `GROUP BY element`, `JOIN ... ON element = ...`, or `WHERE element IN (subquery)`. HOFs keep the result IN THE ARRAY (one row, transformed/filtered/reduced ARRAY) — use them when the downstream consumer wants the array shape preserved (e.g. you're rebuilding a column, projecting a per-row aggregate without losing other columns, or feeding the array to another function). See §1a / §1a.1 for UNNEST.

**DO NOT WRITE.** "Trino has no `transform` / `filter` / `reduce` over arrays — you must UNNEST and then re-aggregate to apply a function per element" — **FALSE**. These HOFs operate in-array and are documented at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) + [trino.io/docs/current/functions/lambda.html](https://trino.io/docs/current/functions/lambda.html). Reaching for UNNEST + ARRAY_AGG just to map/filter a single column is the wrong shape — it shuffles rows you didn't need to shuffle.

---

## 1a.5 LEADING CANONICAL — JOIN types and NULL-fill on unmatched rows (INNER vs LEFT vs RIGHT vs FULL OUTER + the COUNT(right_col) vs COUNT(*) pitfall)

### LEADING CANONICAL — INNER vs LEFT OUTER vs RIGHT OUTER vs FULL OUTER — which side keeps rows, what NULL-fill means, and how COUNT(right_col) vs COUNT(*) silently disagree

> **READ THIS FIRST if your question contains any of these keywords:** `LEFT JOIN Trino`, `LEFT OUTER JOIN`, `RIGHT JOIN`, `FULL OUTER JOIN`, `INNER vs LEFT JOIN`, `outer join null fill`, `null-fill unmatched rows`, `which side keeps rows`, `JOIN drops rows`, `JOIN missing rows`, `users with no orders`, `customers without purchases`, `keep parent rows when child missing`, `JOIN row count wrong`, `LEFT JOIN count zero rows missing`, `COUNT after LEFT JOIN`, `COUNT(col) vs COUNT(*)`, `COUNT inflated by JOIN`, `LEFT JOIN aggregate wrong`. Verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) on 2026-06-07; Trino follows standard ANSI SQL JOIN semantics.

**The one-fact summary.** A JOIN combines two relations on a predicate. The **JOIN TYPE** decides what happens to rows on each side that have **NO match** on the other side. Four types — pick by asking "which side's rows must I keep even when the other side has nothing?":

| JOIN type | Keeps unmatched LEFT rows? | Keeps unmatched RIGHT rows? | Unmatched-side columns filled with | SaaS phrasing |
|---|---|---|---|---|
| **`INNER JOIN`** (or just `JOIN`) | NO — dropped | NO — dropped | (no unmatched rows in result) | "users who have **at least one** order" |
| **`LEFT [OUTER] JOIN`** | **YES — kept** | NO — dropped | RIGHT columns = `NULL` for unmatched left rows | "**all** users; orders if any" |
| **`RIGHT [OUTER] JOIN`** | NO — dropped | **YES — kept** | LEFT columns = `NULL` for unmatched right rows | "all orders; user if any" (rare — usually flip the join to LEFT) |
| **`FULL [OUTER] JOIN`** | **YES — kept** | **YES — kept** | Whichever side is unmatched → that side's columns = `NULL` | "everything from both sides; matched where possible" |

The keyword `OUTER` is optional — `LEFT JOIN` and `LEFT OUTER JOIN` mean the same thing in Trino (and in ANSI SQL). **`INNER JOIN` and `JOIN` (with no qualifier) are identical** — the default is INNER.

**NULL-fill — what it means concretely.** When an `OUTER` JOIN keeps a row whose other-side match is missing, Trino fills the OTHER side's columns with `NULL` for that row. The row IS in the result; you can `SELECT` its left columns; the right columns are just `NULL`. This is the "padded with NULL" / "NULL-padded row" wording in the rest of these resources — same concept.

```sql
-- Setup. 3 users; user_3 has zero orders.
-- users:        (user_id=1, name='Alice'), (2, 'Bob'),  (3, 'Carol')
-- orders:       (order_id=10, user_id=1, amount=50), (11, 1, 30), (12, 2, 100)
--               (note: NO order rows for user_id=3)

-- (1) INNER JOIN — drops user_3 entirely (no matching order row).
SELECT u.user_id, u.name, o.order_id, o.amount
FROM iceberg.app.users u
JOIN iceberg.app.orders o ON o.user_id = u.user_id;
-- 3 rows: (1, Alice, 10, 50), (1, Alice, 11, 30), (2, Bob, 12, 100)
-- user_3 is GONE — INNER drops it because there's no match.

-- (2) LEFT JOIN — keeps user_3; right-side columns NULL-filled.
SELECT u.user_id, u.name, o.order_id, o.amount
FROM iceberg.app.users u
LEFT JOIN iceberg.app.orders o ON o.user_id = u.user_id;
-- 4 rows: (1, Alice, 10, 50), (1, Alice, 11, 30), (2, Bob, 12, 100),
--         (3, Carol, NULL, NULL)            <- user_3 kept; order_id/amount = NULL.

-- (3) FULL OUTER JOIN — keeps everything from both sides; NULL-fills the missing side.
--     (Useful when neither side is "the parent" — e.g., reconciling two ledgers.)
SELECT u.user_id, u.name, o.order_id, o.amount
FROM iceberg.app.users u
FULL OUTER JOIN iceberg.app.orders o ON o.user_id = u.user_id;
-- Includes the LEFT-JOIN result PLUS any orphan orders whose user_id is not in users
-- (would appear as (NULL, NULL, 99, 7) for an orphan order_id=99).
```

**THE COUNT(right_col) vs COUNT(*) PITFALL on a LEFT JOIN — the canonical silent-wrong-number trap.** After a `LEFT JOIN`, you frequently want a count "per user". Three plausible-looking phrasings give **three different answers**:

```sql
SELECT u.user_id,
       COUNT(*)         AS cnt_star,       -- counts ROWS in the group (incl. the NULL-padded row)
       COUNT(o.order_id) AS cnt_orderid,   -- counts NON-NULL order_id values
       SUM(CASE WHEN o.order_id IS NOT NULL THEN 1 ELSE 0 END) AS cnt_explicit
FROM iceberg.app.users u
LEFT JOIN iceberg.app.orders o ON o.user_id = u.user_id
GROUP BY u.user_id
ORDER BY u.user_id;

-- For user_3 (NO matching orders, ONE NULL-padded row in the result):
--   cnt_star     = 1   <- WRONG for "how many orders did user_3 place" (it's the row count, not the order count).
--   cnt_orderid  = 0   <- CORRECT — counts non-NULL order_ids; user_3's NULL-padded order_id is excluded.
--   cnt_explicit = 0   <- CORRECT (same as cnt_orderid, written long-hand).
```

The rule: **`COUNT(*)` counts ROWS in the group (it never skips NULL — there are no NULL rows, only NULL columns); `COUNT(col)` skips NULL values of `col`.** After a LEFT JOIN, the unmatched parent row IS a row (NULL-padded), so `COUNT(*)` inflates by 1 per zero-match parent. Use `COUNT(<right_side_key>)` (or `SUM(CASE WHEN right.key IS NOT NULL THEN 1 ELSE 0 END)`) to count actual matches. The same trap hits `SUM(o.amount)` — it correctly skips the NULL row (SUM ignores NULLs), so `SUM` is "self-healing" here, but `AVG(o.amount)` divides by the non-NULL count, which is correct — confirm with explicit `SUM/COUNT` if in doubt.

> **DO NOT WRITE.**
> 1. **"`LEFT JOIN` and `INNER JOIN` return the same rows; LEFT is just slower"** — **FALSE.** LEFT keeps unmatched left-side rows (NULL-fills the right); INNER drops them. The row counts differ on any predicate that has unmatched left rows.
> 2. **"After a LEFT JOIN, `COUNT(*)` per group gives the count of right-side matches"** — **FALSE.** `COUNT(*)` counts ROWS (incl. the NULL-padded row for a zero-match parent → returns 1, not 0). Use `COUNT(right.key)` or `SUM(CASE WHEN right.key IS NOT NULL THEN 1 ELSE 0 END)`.
> 3. **"`COALESCE(COUNT(*), 0)` on a LEFT JOIN converts the no-match row to zero"** — **FALSE.** `COUNT(*)` never returns NULL — it returns the row count (1 for the NULL-padded row). The fix is `COUNT(right.key)`, not COALESCE.
> 4. **"`WHERE right.col IS NULL` after a LEFT JOIN is the same as `WHERE right.col IS NOT NULL`'s complement"** — TECHNICALLY true (complement) but **load-bearing**: `WHERE right.col IS NULL` after a `LEFT JOIN` is the **anti-join** pattern (left rows with NO right match — see [resource 23 § correlated-subquery anti-join](23-sql-best-practices-olap.md)). Don't confuse it with `INNER JOIN` (which drops those rows entirely).
> 5. **"Moving a LEFT JOIN's filter from `ON` to `WHERE` is equivalent"** — **FALSE** and a classic silent-wrong-number trap. A predicate on the right-side column in the `WHERE` clause filters AFTER the join — and NULL-padded rows (where `right.col IS NULL`) fail the predicate, effectively turning the LEFT JOIN into an INNER JOIN. Predicates on the right table that should NOT eliminate unmatched left rows belong in the `ON` clause: `LEFT JOIN orders o ON o.user_id = u.user_id AND o.status = 'paid'`. If you need a predicate AFTER the join, write it explicitly as `WHERE o.status = 'paid' OR o.order_id IS NULL`.

**The 4-step decision rule for "which JOIN do I want":**
1. **Identify the "parent" / "must-keep" side.** "All users, even those with no orders" → users is the must-keep side. "All orders, even those with no user (orphan)" → orders is the must-keep side.
2. **Put the must-keep side on the LEFT** (convention; flip if needed). `FROM users LEFT JOIN orders ...` keeps all users.
3. **Use `LEFT JOIN`** (or `FULL OUTER JOIN` if BOTH sides are must-keep).
4. **For COUNT of matches per parent: use `COUNT(<right_side_key>)`, NOT `COUNT(*)`.** For SUM: `SUM(<right_amount>)` correctly skips NULL — you can leave it bare, but if downstream consumers need 0 instead of NULL for zero-match parents, wrap with `COALESCE(SUM(o.amount), 0)`.

**Cross-references.** [§ 1a.2 — `ARRAY_AGG` over LEFT-JOIN unmatched groups returns `ARRAY[null]` not `[]`](#1a2-array_agg-over-left-join-unmatched-groups-returns-arraynull-not-null-and-not--use-filter-where-col-is-not-null) for the array_agg analog of this same NULL-padded-row trap (use `FILTER (WHERE col IS NOT NULL)`). [§ 4 — gap-filling time series with calendar `LEFT JOIN`](#4-time-series-rollups-with-gap-filling) for the calendar densification pattern (LEFT JOIN a calendar dim onto sparse activity to surface zero-activity days). [Resource 23 § 10 — anti-join (`LEFT JOIN ... WHERE right IS NULL`) for "rows with no match" + the NULL-safety vs `NOT IN` discussion](23-sql-best-practices-olap.md). [Resource 23 § 9 — JOIN ordering and `ANALYZE` for the CBO](23-sql-best-practices-olap.md) for how Trino decides build vs probe side and BROADCAST vs PARTITIONED.

---

## 1b. LEADING CANONICAL — `WITH` / CTE semantics in Trino (readability tool; NOT a materialization barrier — referenced-N-times = inlined N times)

> **READ THIS FIRST if your question contains any of these keywords:** `WITH clause Trino`, `CTE materialized`, `CTE computed once or many`, `common table expression performance`, `WITH RECURSIVE Trino`, `CTE vs temp table`, `is a CTE cached`, `does Trino cache CTE results`, `CTE optimization fence`, `WITH AS MATERIALIZED Trino`, `should I rewrite repeated subqueries as a CTE`. Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) on 2026-06-06.

**The one-fact summary.** A `WITH name AS (SELECT ...)` block — called a **CTE** (Common Table Expression) — is a **named inline subquery** that exists ONLY for the duration of the outer statement. In Trino 467 a CTE is a **readability/reuse-in-text tool, NOT a materialization barrier and NOT a cache**. Trino docs verbatim: *"Currently, the SQL for the `WITH` clause will be inlined anywhere the named relation is used. This means that if the relation is used more than once and the query is non-deterministic, the results may be different each time."* Referencing the same CTE N times = the optimizer **inlines the CTE's SELECT N times** = re-executes it N times. There is **no `WITH ... AS MATERIALIZED` syntax** (Postgres 12+) and **no session flag** that forces materialization.

```sql
-- CTE = readability. Cheap to reference once, NOT cheap to reference twice.
WITH heavy AS (
  SELECT user_id, SUM(amount) AS total_spend
  FROM iceberg.analytics.orders
  WHERE order_date >= DATE '2026-01-01'
  GROUP BY user_id    -- 100 GB shuffle
)
SELECT big.user_id, big.total_spend, small.total_spend AS small_total
FROM heavy big
JOIN heavy small ON big.total_spend > small.total_spend * 10;
-- The 100 GB shuffle in `heavy` runs TWICE — once per textual reference.
```

**When to materialize instead of CTE.** If an expensive sub-result is referenced 2+ times in one query (or across many queries), materialize it ONCE and reference the materialized object:
- **In a dbt pipeline (default choice on this stack):** promote `heavy` to its own dbt model with `{{ config(materialized='table') }}` and `ref()` it from downstream — see [resource 28 § 3.2](28-complex-sql-performance-trino-dbt.md).
- **For a one-shot ad-hoc query:** `CREATE TABLE iceberg.tmp.heavy AS SELECT ...` first, then query the small table N times. Drop when done (the "ad-hoc extract" pattern in the prod environment).

**`WITH RECURSIVE` IS supported** for bounded hierarchy walks (org tree, parts explosion) — see [resource 27 § 7A.1](27-oracle-plsql-to-dbt-trino.md) for the Oracle `CONNECT BY` → `WITH RECURSIVE` migration with the depth-cap caveat (`max_recursion_depth` session property; only single-element recursive cycles supported).

> **DO NOT WRITE.** (1) "Defining a CTE makes Trino compute it once and reuse the result" — **FALSE on Trino 467**; the CTE is inlined per reference. (2) `WITH heavy AS MATERIALIZED (...)` — **parse error**; Trino has no `MATERIALIZED` modifier (open feature request: [trinodb/trino #10](https://github.com/prestosql/presto/issues/10)). (3) "More CTEs = faster — breaking a query into 10 CTEs lets the optimizer plan each one separately" — **FALSE**; CTE count is performance-neutral once inlined; materialization is the only lever (see [resource 28 § 3](28-complex-sql-performance-trino-dbt.md)). (4) Using a CTE as a "temp table" expecting cross-query persistence — a CTE's lifetime is **one statement only**; use `CREATE TABLE iceberg.tmp.X AS SELECT ...` for cross-statement reuse.

**Cross-references.** [Resource 28 § 3 — CTEs are inlined, materialize once with dbt](28-complex-sql-performance-trino-dbt.md) for the deep perf-tuning angle (worked example + `ephemeral` vs `table` vs `view` materialization cost model). [Resource 23 § 11 — Use CTEs or subqueries — don't re-run the same expensive query twice](23-sql-best-practices-olap.md) for the duplicate-subquery collapsing pattern + `aggregate(...) FILTER (WHERE ...)` alternative for single-scan multi-metric. [Resource 27 § 7A.1](27-oracle-plsql-to-dbt-trino.md) for `WITH RECURSIVE`.

---

## 2. Funnels (drop-off across a sequence of events)

**The SaaS question:** "Of users who signed up last week, how many completed onboarding, and of those, how many activated a paid feature within 7 days?"

A note on the `WITH ... AS (...)` blocks below: these are **CTEs** (Common Table Expressions — named, inline temporary result sets that you can reference later in the same query, similar to declaring a variable). They make multi-step queries readable without creating real tables. **See §1b above for the full CTE semantics canonical (CTEs are INLINED in Trino, NOT materialized — referencing a CTE twice runs it twice).**

```sql
WITH signups AS (
  SELECT user_id, MIN(event_time) AS signed_up_at
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup'
    AND event_date >= current_date - INTERVAL '14' DAY
  GROUP BY user_id
),
onboarded AS (
  SELECT s.user_id
  FROM signups s
  JOIN iceberg.analytics.user_events e
    ON e.user_id = s.user_id
   AND e.event_name = 'onboarding_complete'
   AND e.event_time BETWEEN s.signed_up_at AND s.signed_up_at + INTERVAL '7' DAY
),
activated AS (
  SELECT o.user_id
  FROM onboarded o
  JOIN iceberg.analytics.user_events e
    ON e.user_id = o.user_id
   AND e.event_name = 'paid_feature_used'
   AND e.event_time <= (SELECT signed_up_at FROM signups WHERE user_id = o.user_id) + INTERVAL '7' DAY
)
SELECT
  (SELECT COUNT(*) FROM signups)   AS step1_signups,
  (SELECT COUNT(*) FROM onboarded) AS step2_onboarded,
  (SELECT COUNT(*) FROM activated) AS step3_activated;
```

**Why funnels are hard:** each step is a separate scan of `user_events`. A 3-step funnel scans the table 3 times. This is exactly the work columnar storage + Iceberg partition pruning makes survivable — same query on Postgres would melt the DB.

### Single-pass funnel with `MATCH_RECOGNIZE`

When the CTE/JOIN funnel above gets slow (8+ minutes on hundreds of millions of rows) or you find yourself writing 5-step funnels with cascading JOINs, switch to `MATCH_RECOGNIZE`. It's a SQL-standard clause Trino supports that lets you describe an **ordered pattern of rows** — like a regex over event sequences — so Trino can match the whole funnel in a single pass per user instead of N joins.

Here's the same signup → activation → payment (within 7 days) funnel as a single MATCH_RECOGNIZE query:

```sql
SELECT user_id, funnel_start, funnel_end
FROM iceberg.analytics.user_events
MATCH_RECOGNIZE (
  PARTITION BY user_id
  ORDER BY event_time
  MEASURES
    FIRST(event_time) AS funnel_start,
    LAST(event_time)  AS funnel_end
  ONE ROW PER MATCH
  AFTER MATCH SKIP TO NEXT ROW
  PATTERN (signup activation+ payment+)
  DEFINE
    signup     AS event_name = 'signup',
    activation AS event_name = 'activation'
                  AND event_time <= FIRST(event_time) + INTERVAL '7' DAY,
    payment    AS event_name = 'payment'
                  AND event_time <= FIRST(event_time) + INTERVAL '7' DAY
);
```

How to read this:
- `PARTITION BY user_id ORDER BY event_time` — treat the table as one ordered timeline per user.
- `PATTERN (signup activation+ payment+)` — match a row labeled `signup`, then one or more `activation`, then one or more `payment`, in that order.
- `DEFINE` — what makes a row qualify as each label. The `event_time <= FIRST(event_time) + INTERVAL '7' DAY` check is the 7-day window.
- `MEASURES` — what to return per matched user (here: when they entered and exited the funnel).
- `ONE ROW PER MATCH` — return one row per user who completed the full funnel.

To get the funnel **counts** (step1/step2/step3 conversions like the CTE version above), you'd run two queries — one MATCH_RECOGNIZE for completion to step 2, one for completion to step 3 — or wrap this in a CTE and combine with the original signup count.

**When to use MATCH_RECOGNIZE vs the CTE/JOIN approach:**

| Use MATCH_RECOGNIZE when... | Use CTE/JOIN when... |
|---|---|
| Funnel has 4+ steps and the CTE version is hard to read. | 2–3 step funnels where the CTE version is fine and more debuggable. |
| Performance matters — single pass per user is much faster than N table scans. | You're prototyping and want to add/remove steps quickly. |
| The events must occur **in a strict order** (signup *then* activation *then* payment). | Order doesn't matter as much, or you need fuzzy logic (e.g., "completed any 2 of 4 steps"). |
| You need windowed events (within 7 days of start). | You're targeting portability — MATCH_RECOGNIZE is supported in Trino, Snowflake, Oracle, but not Postgres, MySQL, BigQuery, or DuckDB. |

Start with the CTE/JOIN version because it's easier to debug. Migrate to MATCH_RECOGNIZE only when the CTE version is too slow or too tangled.

---

## 3. Cohort analysis (retention over time)

**The SaaS question:** "Of users who signed up in the week of Jan 1, how many were active in week 0, week 1, week 2, week 3?"

The mental model is a triangular table:

| signup_week | week_0 | week_1 | week_2 | week_3 |
|---|---|---|---|---|
| 2026-01-01 | 1,000 | 620 | 480 | 410 |
| 2026-01-08 | 1,200 | 750 | 590 | — |
| 2026-01-15 | 980 | 610 | — | — |
| 2026-01-22 | 1,100 | — | — | — |

Conceptually:

```sql
WITH cohorts AS (
  SELECT user_id,
         date_trunc('week', MIN(event_time)) AS cohort_week
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup'
  GROUP BY user_id
),
activity AS (
  SELECT c.cohort_week,
         date_diff('week', c.cohort_week, e.event_time) AS week_offset,
         COUNT(DISTINCT e.user_id) AS active_users
  FROM cohorts c
  JOIN iceberg.analytics.user_events e ON e.user_id = c.user_id
  GROUP BY c.cohort_week, date_diff('week', c.cohort_week, e.event_time)
)
SELECT * FROM activity ORDER BY cohort_week, week_offset;
```

**Why this stresses OLAP:** the GROUP BY has two dimensions and `COUNT(DISTINCT user_id)` is memory-hungry. The bottleneck is **not** "all values get sent to one coordinator node" — Trino distributes distinct aggregation across workers. The real costs are (1) an **extra shuffle pass** per distinct column on top of the GROUP BY shuffle (Trino's MarkDistinct strategy partitions by `(group_key, distinct_col)` so duplicates can be resolved per partition), and (2) **per-group memory pressure** — each worker holds a hash set of distinct values for every group it's responsible for. A 26-week × 1M-distinct-user cohort forces each worker to keep thousands of large hash sets in memory simultaneously.

For large cohorts use `approx_distinct(user_id)` in Trino — a built-in function that returns an *approximate* distinct count using the **HyperLogLog** algorithm (a probabilistic data structure that estimates cardinality from a tiny fixed-size sketch instead of storing every value seen): **2.3% standard error** (per Trino docs), 100x less memory, and only one cheap merge shuffle instead of MarkDistinct's per-column re-shuffle.

> **Tuning precision — the optional 2nd argument `e`** (verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)). **Keyword anchor:** approx_distinct error bound, control precision approx_distinct, approx_distinct second argument e, approx_distinct standard error tuning, make approx_distinct more accurate. The 2.3% is the DEFAULT — `approx_distinct(x)` is `approx_distinct(x, 0.023)`. The **2-arg form `approx_distinct(x, e)`** lets you tune it: `e` is the maximum standard error, default `0.023`, **valid range `[0.0040625, 0.26000]`**. Smaller `e` = tighter estimate but more memory per sketch. Example: `approx_distinct(user_id, 0.01)` targets ~1% standard error. An `e` outside the valid range raises a runtime error. **DO NOT WRITE:** "you cannot control `approx_distinct`'s error / it is a fixed 2.3%" (FALSE — the optional 2nd arg `e` tunes it within `[0.0040625, 0.26]`).

**Before giving up exactness, try changing the distinct-aggregation strategy.** Trino exposes a session knob that controls how distinct aggregation is planned:

```sql
SET SESSION distinct_aggregations_strategy = 'pre_aggregate';
-- other values: 'mark_distinct' (default), 'single_step', 'split_to_subqueries', 'automatic'
```

`pre_aggregate` adds a per-worker partial-deduplication step before the final shuffle and often outperforms `mark_distinct` for queries with multiple distinct columns. `split_to_subqueries` rewrites each `COUNT(DISTINCT ...)` into its own subquery joined back together — best when you have many distinct expressions in one query. Try each strategy with `EXPLAIN ANALYZE` and compare actual CPU/wall time before deciding to approximate.

### `approx_distinct` vs `COUNT(DISTINCT)` — when to use each

The **2.3% standard error** for `approx_distinct` is worth understanding precisely before you put it on a customer-facing dashboard.

**The 2.3% is a standard deviation (σ), not a hard ceiling.** HyperLogLog's error is described as a *relative standard error* — meaning roughly 68% of estimates fall within ±2.3% of the true count, 95% fall within ±4.6%, and 99.7% fall within ±6.9%. It is **not** a guarantee that no answer will ever be off by more than 2.3%. In practice, however, for typical SaaS cohort sizes (1K–10M distinct users) the real-world error stays well within 2% the vast majority of the time — HyperLogLog is most accurate in exactly this range. The bad surprises happen when you (a) report a single number to a customer who's reconciling it against the in-app counter, or (b) use it on tiny cohorts (<1K) where the relative error widens.

**Decision rule:**

| Use `COUNT(DISTINCT)` when... | Use `approx_distinct` when... |
|---|---|
| Cohort is < 1M users (the exact count is fast enough — no memory pressure on Trino). | Cohort is > 10M users and the exact query is timing out or hitting `query_max_memory` limits. |
| The number is **customer-facing** and must match the app exactly (e.g., "your team had 42 active users this week" shown in the customer's dashboard, where they can count them by hand). | The number is **internal/operational** — engineering dashboards, capacity planning, weekly ops review — where 2.3% error is invisible and acceptable. |
| The metric drives **revenue or billing** (seat counts, per-active-user pricing, usage-based invoices). A 2.3% error here is a real money bug and a support-ticket generator. | You're charting trends over time — the shape of the curve matters more than the exact y-value on any one day. |

**Validation recipe — run this once before committing to either approach.** Don't take the "2%" claim on faith for your specific data shape; measure it:

```sql
-- Pick one recent partition (a single day works) and run both counts.
WITH sample AS (
  SELECT user_id
  FROM iceberg.analytics.user_events
  WHERE event_date = DATE '2026-05-15'
)
SELECT
  COUNT(DISTINCT user_id)        AS exact_count,
  approx_distinct(user_id)       AS approx_count,
  ROUND(
    100.0 * (approx_distinct(user_id) - COUNT(DISTINCT user_id))
    / COUNT(DISTINCT user_id),
    3
  ) AS pct_error
FROM sample;
```

Run this on 5–10 different partitions covering your typical query shapes (per-tenant slices, per-day slices, per-cohort slices). If `pct_error` stays under ~1% across all of them, `approx_distinct` is safe for that workload. If you see any sample over 3%, do **not** use it for customer-facing numbers without further sampling — your data shape may have characteristics (heavy skew, very small cohorts, unusual cardinality patterns) that push HyperLogLog past its sweet spot.

**One more nuance:** `approx_distinct` is non-deterministic in the sense that the same query *can* return a slightly different number on a different cluster version or after data reorganization (compaction, partition rewrites). For customer-facing numbers, determinism matters — customers notice if their "active users" jumps from 9,847 to 9,851 between two page loads. That alone is often enough reason to prefer exact `COUNT(DISTINCT)` for anything a customer sees.

### Pre-aggregated HLL sketches: the rolling-window production pattern

For DAU/WAU/MAU dashboards that need to refresh every minute against a 500M-row events table, even `approx_distinct` is wasteful if it re-scans raw events on every refresh. The production pattern is to **build a daily HyperLogLog sketch table once**, then merge sketches at query time for any window size you want.

> **`approx_set` precision is FIXED at ~2.3% — there is NO `approx_set(x, e)` overload** (verified at [trino.io/docs/current/functions/hyperloglog.html](https://trino.io/docs/current/functions/hyperloglog.html) — the only signature is `approx_set(x) -> HyperLogLog`). **Keyword anchors:** approx_set precision, tune HLL sketch error, approx_set no second argument, approx_distinct vs approx_set precision, tighter than 2.3% distinct sketch, control HLL standard error stored sketch. The stored sketch is fixed at ~2.3% and every sketch you later `merge()` shares that one fixed precision; for a tighter one-off (non-mergeable) count, use the SCALAR `approx_distinct(visitor_id, 0.01)` — see the `approx_distinct(x, e)` canonical above — or fall back to exact `COUNT(DISTINCT)`. **DO NOT WRITE:** `approx_set(x, e)` with a 2nd precision arg (does NOT exist — only `approx_distinct` takes `e`); claiming you can tune a stored HLL sketch's error after the fact.

```sql
-- Step 1: nightly job — one row per day, one sketch column.
-- approx_set(col) builds an HLL sketch (a few KB binary blob) for a column.
-- IMPORTANT: cast the sketch to varbinary before storing — Iceberg's Parquet
-- storage does not natively know about Trino's HyperLogLog type, so you must
-- serialize the sketch to binary. The on-disk column type is varbinary.
CREATE TABLE iceberg.analytics.daily_user_hll
WITH (partitioning = ARRAY['event_date'])
AS SELECT
    event_date,
    CAST(approx_set(user_id) AS varbinary) AS user_id_hll
FROM iceberg.analytics.events
GROUP BY event_date;

-- Step 2: compute rolling 7-day WAU without re-scanning raw events.
-- IMPORTANT: cast the stored varbinary back to HyperLogLog before calling
-- merge() — merge() and cardinality() only accept the HyperLogLog type.
SELECT
    s1.event_date AS window_end,
    cardinality(merge(CAST(s2.user_id_hll AS HyperLogLog))) AS wau_7d
FROM iceberg.analytics.daily_user_hll s1
JOIN iceberg.analytics.daily_user_hll s2
  ON s2.event_date BETWEEN s1.event_date - INTERVAL '6' DAY
                       AND s1.event_date
GROUP BY s1.event_date
ORDER BY s1.event_date;
```

**Why the casts?** Trino's `HyperLogLog` is an in-engine type — the Iceberg connector (and Parquet/ORC under it) has no native encoding for it. The standard pattern from the [official Trino HyperLogLog docs](https://trino.io/docs/current/functions/hyperloglog.html) is: **serialize to `varbinary` on the write side, deserialize back to `HyperLogLog` on the read side.** If you forget the write-side cast, the CTAS/INSERT fails with a type error like `Unsupported type: HyperLogLog`. If you forget the read-side cast, `merge()` fails with `Unexpected parameters (varbinary) for function merge`.

The three primitives:
- `approx_set(column)` — builds a HyperLogLog sketch for a column. Returns the `HyperLogLog` type (not a `BIGINT`). Cast to `varbinary` to persist.
- `merge(hll_column)` — aggregate function that unions multiple sketches into one. Input must be `HyperLogLog`, not `varbinary` — cast first when reading from a stored sketch table. Merging sketches and then taking cardinality is mathematically equivalent to running `approx_distinct` over the union of all underlying rows — that is the *whole point* of HLL: sketches compose.
- `cardinality(hll)` — extracts the approximate distinct count from a (merged) sketch.

Pay the sketch-building cost once per day. Every subsequent rolling-window query reads at most a few dozen tiny rows from the sketch table — no scan of the raw 500M-row events table. This pattern also works for arbitrary windows ("last 30 days", "last 90 days", "this calendar month") without rebuilding anything: same sketch table, different join range. It is the standard solution for rolling cardinality in Trino, Snowflake, BigQuery, and DuckDB.

#### LEADING CANONICAL — ROLLING N-DAY DISTINCT-USER COUNT PER DAY (Trino has NO `COUNT(DISTINCT) OVER (...)` — use HLL daily sketches + `merge()` over the trailing window, or an exact self-join `COUNT(DISTINCT)` grouped by window-end day) (iter637 PIN — FIX-B: rolling-distinct landing point + COUNT(DISTINCT) OVER inoculation)

> **READ THIS FIRST if your question contains any of these keywords:** `rolling 7-day distinct active users`, `rolling 7-day distinct users per day`, `7-day active users per day`, `trailing N-day unique count`, `rolling N-day unique count per day`, `distinct users in a moving window`, `rolling unique count per day`, `30-day active users per day`, `rolling DAU/WAU/MAU per day`, `trailing 30-day distinct users`, `unique users over a rolling window`, `COUNT(DISTINCT) OVER`, `COUNT(DISTINCT user_id) OVER`, `distinct count window function`, `windowed distinct count Trino`, `distinct in OVER clause`, `unique count moving window`, `unique users in last 7 days for each day`, `running count of unique users`, `daily WAU calendar`. Verified at [trino.io/docs/467/functions/hyperloglog.html](https://trino.io/docs/current/functions/hyperloglog.html) + [trinodb/trino issue #7885](https://github.com/trinodb/trino/issues/7885) on 2026-06-07.

**The one-fact summary — Trino does NOT support `DISTINCT` inside a window function.** `COUNT(DISTINCT user_id) OVER (ORDER BY occurred_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` is **NOT supported** in Trino (the same limitation exists in Redshift, SQL Server, and most engines — tracked at [trinodb/trino #7885](https://github.com/trinodb/trino/issues/7885)). For a **rolling N-day distinct user count per day**, reach for one of these two docs-verified patterns:

**PRIMARY — HLL daily-sketch + `merge()` over the trailing N-day window (cheap, scales to billions of events, ~2.3% standard error).** This is the canonical production pattern. Build a daily HLL sketch table once (see "Pre-aggregated HLL sketches" recipe immediately above), then self-join the sketch table on a trailing N-day range and merge the per-day sketches:

```sql
-- Trino 467 — "rolling 7-day distinct active users per day" — HLL daily-sketch + merge() form.
-- Pre-req: daily_user_hll table from the "Pre-aggregated HLL sketches" recipe above
-- (one row per event_date, one varbinary user_id_hll column = CAST(approx_set(user_id) AS varbinary)).
SELECT
    s1.event_date AS window_end_day,
    cardinality(merge(CAST(s2.user_id_hll AS HyperLogLog))) AS rolling_7d_distinct_users
FROM iceberg.analytics.daily_user_hll s1
JOIN iceberg.analytics.daily_user_hll s2
  ON s2.event_date BETWEEN s1.event_date - INTERVAL '6' DAY
                       AND s1.event_date
GROUP BY s1.event_date
ORDER BY s1.event_date;
```

For a 30-day window, change `INTERVAL '6' DAY` to `INTERVAL '29' DAY`; for 90-day, `INTERVAL '89' DAY`. The sketch table holds **one row per day** — joining it to itself over an N-day range and merging the sketches per `window_end_day` gives the trailing N-day distinct-user count without re-scanning the raw events table. Verified mechanics: `merge(HyperLogLog)` *"returns the HyperLogLog of the aggregate union of the individual `hll` HyperLogLog structures"* ([trino.io/docs/467/functions/hyperloglog.html](https://trino.io/docs/current/functions/hyperloglog.html)) — i.e. it is the aggregate that unions HLL sketches across the trailing-window rows; `cardinality(merged_hll)` then extracts the approximate distinct count from the merged sketch. The `CAST(... AS HyperLogLog)` is mandatory when reading from the stored `varbinary` column — `merge()` and `cardinality()` only accept the `HyperLogLog` type, not `varbinary`.

**SECONDARY — exact `COUNT(DISTINCT)` via self-join over the trailing window, grouped by `window_end_day` (use when exactness is required AND volume allows).** When the customer-facing number must match the exact count (no ~2.3% error), or when daily volume is small enough to scan directly:

```sql
-- Trino 467 — exact rolling 7-day distinct users per day via self-join over the trailing window.
-- Use when exactness is required AND the raw events volume is small enough to scan directly.
SELECT
    s1.event_date AS window_end_day,
    COUNT(DISTINCT s2.user_id) AS rolling_7d_distinct_users
FROM (SELECT DISTINCT event_date FROM iceberg.analytics.events) s1
JOIN iceberg.analytics.events s2
  ON s2.event_date BETWEEN s1.event_date - INTERVAL '6' DAY
                       AND s1.event_date
GROUP BY s1.event_date
ORDER BY s1.event_date;
```

Each `window_end_day` row aggregates the raw events in the trailing 7-day range and produces an EXACT `COUNT(DISTINCT user_id)` over those rows. The `s1` left side is the calendar driver (one row per day), the `s2` right side is the trailing-7-day event slice, and the outer `GROUP BY s1.event_date + COUNT(DISTINCT s2.user_id)` is a **plain `GROUP BY` aggregate** (not a window function) — that is why it is allowed to use `DISTINCT`.

**When to pick which.**

| Need | Reach for | Cost |
|---|---|---|
| **Rolling N-day distinct count, ~2.3% error acceptable** (internal dashboards, ops review, capacity planning, large events tables ≥100M rows/day) | HLL `merge()` over `daily_user_hll` sketches (PRIMARY above) | Cheap — reads ~N tiny sketch rows per output row. Sketches must be built once nightly. |
| **Rolling N-day distinct count, EXACT match required** (customer-facing numbers, billing-facing numbers, regulatory) | Exact self-join `COUNT(DISTINCT)` grouped by `window_end_day` (SECONDARY above) | Re-scans raw events for every output day. Only viable when daily volume is modest or you can pre-partition aggressively. |
| **Calendar-aware rolling NON-distinct aggregate** (rolling SUM, AVG, COUNT over a trailing window) | Pattern D `AVG(x) OVER (... RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW)` — see Pattern D below | Native window function form — works directly for non-distinct aggregates. |

> **DO NOT WRITE — `COUNT(DISTINCT) OVER (...)` is INVALID Trino.**
>
> | WRONG (Trino 467 — REJECTED) | WHY it fails | RIGHT |
> |---|---|---|
> | `COUNT(DISTINCT user_id) OVER (ORDER BY occurred_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)`  &nbsp;❌ | **Trino does NOT support `DISTINCT` inside window functions** — tracked at [trinodb/trino #7885](https://github.com/trinodb/trino/issues/7885). The same limitation exists in Redshift, SQL Server, and most engines. Parse / analysis error: `DISTINCT is not supported for window functions` (or analyzer rejection). | Use per-day `approx_set(user_id)` sketches + `merge()` over the trailing window with `cardinality()` (PRIMARY above) — or an exact self-join `COUNT(DISTINCT)` grouped by the window-end day (SECONDARY above). Both produce one row per window-end day with the trailing-N-day distinct user count. |
> | `COUNT(DISTINCT user_id) OVER (PARTITION BY tenant_id ORDER BY occurred_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW)`  &nbsp;❌ | Same limitation — `DISTINCT` is not allowed inside any window function in Trino, regardless of `PARTITION BY` or frame shape. | Add `tenant_id` to both sides of the self-join (HLL form: `daily_user_hll s1 JOIN daily_user_hll s2 ON s2.tenant_id = s1.tenant_id AND s2.event_date BETWEEN s1.event_date - INTERVAL '29' DAY AND s1.event_date GROUP BY s1.tenant_id, s1.event_date`) — same merge + cardinality pattern, just per-tenant. |
> | `approx_distinct(user_id) OVER (...)` &nbsp;❌ | `approx_distinct` is **NOT a window function** — it is a regular aggregate that only works with `GROUP BY` (or as the lone aggregate over the whole table). Trino rejects `approx_distinct(...) OVER (...)`. | Same HLL sketch + `merge()` recipe above. The sketch-merge form is the window-function-aware equivalent of `approx_distinct` over a trailing window. |

**Verify your rewrite paid off with `EXPLAIN ANALYZE`.** When you replace `COUNT(DISTINCT)` with `approx_distinct`, or replace a raw-events scan with a sketch-table merge, prove it actually reduced I/O — don't take it on faith. Run both versions wrapped in `EXPLAIN ANALYZE` (which actually executes the query and reports real bytes scanned, actual rows per stage, and wall time per stage). Compare the "Input" bytes line — if the rewrite didn't reduce bytes scanned, the optimization didn't land (most often: the rollup/sketch table wasn't picked because of a planner mismatch, or the partition filter wasn't pushed down). Plain `EXPLAIN` only shows the *estimated* cost; `EXPLAIN ANALYZE` shows the *actual* cost.

### Milestone-retention variant: % came back in 7 / 30 / 90 days

The weekly-offset matrix above counts how many users were active in each week. A complementary question is: "of users who first showed up in a given week, what % came back within 7, 30, or 90 days?" This collapses the matrix into three boolean columns — did the user return at all within each window?

```sql
WITH first_events AS (
  SELECT user_id,
         date_trunc('week', MIN(event_time)) AS cohort_week,
         MIN(event_time)                     AS first_event_at
  FROM iceberg.analytics.user_events
  GROUP BY user_id
),
cohort_sizes AS (
  SELECT cohort_week, COUNT(DISTINCT user_id) AS total_users
  FROM first_events
  GROUP BY cohort_week
),
returns AS (
  SELECT
    f.cohort_week,
    -- COUNT(DISTINCT CASE WHEN ...) counts each user once even if they returned multiple times
    COUNT(DISTINCT CASE WHEN date_diff('day', f.first_event_at, e.event_time) BETWEEN 1 AND 7  THEN e.user_id END) AS returned_7d,
    COUNT(DISTINCT CASE WHEN date_diff('day', f.first_event_at, e.event_time) BETWEEN 1 AND 30 THEN e.user_id END) AS returned_30d,
    COUNT(DISTINCT CASE WHEN date_diff('day', f.first_event_at, e.event_time) BETWEEN 1 AND 90 THEN e.user_id END) AS returned_90d
  FROM first_events f
  JOIN iceberg.analytics.user_events e ON e.user_id = f.user_id
  GROUP BY f.cohort_week
)
SELECT c.cohort_week,
       c.total_users,
       ROUND(100.0 * r.returned_7d  / c.total_users, 1) AS pct_retained_7d,
       ROUND(100.0 * r.returned_30d / c.total_users, 1) AS pct_retained_30d,
       ROUND(100.0 * r.returned_90d / c.total_users, 1) AS pct_retained_90d
FROM cohort_sizes c
JOIN returns r ON r.cohort_week = c.cohort_week
WHERE date_diff('day', c.cohort_week, current_date) >= 90  -- only cohorts old enough to measure
ORDER BY c.cohort_week DESC;
```

**The critical idiom:** use `COUNT(DISTINCT CASE WHEN ... THEN user_id END)`, **not** `SUM(CASE WHEN ... THEN 1 ELSE 0 END)`.

The SUM form counts *event rows*, not users. If a user fires 5 events in the 7-day window, they contribute 5 to `returned_7d` and 1 to `total_users`. That produces retention percentages above 100% on any active cohort — the query passes silently and the numbers look nonsensical.

`COUNT(DISTINCT CASE WHEN ... THEN user_id END)` counts each user_id at most once per window, regardless of how many events they fired. Trino supports `NULL` in DISTINCT aggregates — when the CASE does not match, it returns `NULL`, which COUNT(DISTINCT) ignores.

**Incomplete-cohort filter:** `date_diff('day', c.cohort_week, current_date) >= 90` is mandatory. A cohort from last week cannot have 90-day retention yet — without this filter, young cohorts show artificially low percentages and make retention look like it's falling.

**Overlapping vs non-overlapping buckets:** `BETWEEN 1 AND 7`, `BETWEEN 1 AND 30`, `BETWEEN 1 AND 90` are overlapping — a user who returns in 5 days counts as retained in all three windows. This matches industry convention (cumulative retention). If you want non-overlapping buckets (1–7, 8–30, 31–90), change the BETWEEN ranges accordingly.

**Date-vs-timestamp precision:** `date_diff('day', first_event_at, event_time)` between two *timestamps* measures elapsed whole days from the timestamp components. A user who fired their first event at 23:00 and returned at 01:00 the next day produces `date_diff = 0`. To measure calendar-day differences (more intuitive for daily retention windows), cast both sides to `date`: `date_diff('day', date(first_event_at), date(event_time))`.

### Wide-pivot variant: percentage retention as columns

> **Terminology — call the pattern by its right name.** The `SUM(CASE WHEN <key>=<value> THEN <metric> END) AS <value_col>` idiom shown below is **conditional aggregation** — also called **manual pivot** or **crosstab**. The CASE returns `<metric>` on match and `NULL` otherwise; `SUM` (like all Trino aggregates) ignores `NULL`, so each output column collapses to the metric for the matching key. This is the canonical Trino-native pivot pattern; there is **no `PIVOT` keyword** in Trino's SQL grammar — you write the manual conditional aggregation as shown.
>
> **DO-NOT-WRITE — these labels are WRONG and will mislead anyone who later looks them up:**
> - "SCD-1 pivot" / "Type-1 pivot" / "SCD pivot pattern" — **WRONG.** SCD-1 (Slowly Changing Dimension Type 1) is an **unrelated Kimball dimension-modeling concept**: a strategy for **overwriting** a dimension attribute on change with **no history retention** (e.g., overwriting `customer_email` when a user updates it). It has nothing to do with pivoting rows into columns. Conflating SCD-1 with the conditional-aggregation pivot pollutes the mental model — an engineer who later googles "SCD-1" will land on dimension-update content and waste time reverse-inferring a non-existent connection.
> - Correct labels to use: **"conditional aggregation"**, **"manual pivot"**, **"crosstab"**.
>
> **Alternative idiom — Trino aggregate `FILTER (WHERE ...)` clause.** Trino supports the SQL-standard aggregate `FILTER (WHERE <condition>)` modifier, which is **equivalent** to the `CASE WHEN` form and slightly cleaner. Both forms produce identical query plans on Trino 467/481. Verified against [Trino aggregate functions docs](https://trino.io/docs/current/functions/aggregate.html) ("The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause … supported for all aggregate functions"):
>
> ```sql
> -- Quarterly revenue pivot — CASE WHEN form (canonical, works on every dialect):
> SELECT region,
>        SUM(CASE WHEN quarter = 'Q1' THEN revenue END) AS q1_revenue,
>        SUM(CASE WHEN quarter = 'Q2' THEN revenue END) AS q2_revenue,
>        SUM(CASE WHEN quarter = 'Q3' THEN revenue END) AS q3_revenue,
>        SUM(CASE WHEN quarter = 'Q4' THEN revenue END) AS q4_revenue
> FROM iceberg.analytics.sales
> GROUP BY region;
>
> -- Equivalent FILTER (WHERE ...) form (Trino-supported, cleaner):
> SELECT region,
>        SUM(revenue) FILTER (WHERE quarter = 'Q1') AS q1_revenue,
>        SUM(revenue) FILTER (WHERE quarter = 'Q2') AS q2_revenue,
>        SUM(revenue) FILTER (WHERE quarter = 'Q3') AS q3_revenue,
>        SUM(revenue) FILTER (WHERE quarter = 'Q4') AS q4_revenue
> FROM iceberg.analytics.sales
> GROUP BY region;
> ```
>
> Both forms run on Trino 467/481 with the Iceberg connector. Use whichever reads more naturally to your team — the `FILTER` form is slightly more compact and signals "conditional aggregation" intent without the CASE noise. Note: when you want `COUNT(*)` for matching rows (not summing a metric), the FILTER form `COUNT(*) FILTER (WHERE event_type='purchase')` is the canonical idiom — the CASE-WHEN form `SUM(CASE WHEN event_type='purchase' THEN 1 ELSE 0 END)` is also valid but more verbose.
>
> **Cross-ref — "count of `bool_col` true per group" → `count_if` LEADS.** For the simple per-group boolean-count case (e.g., `count_if(is_fraud)` per region — every region appears, clean regions emit `0`, no zero-group drop trap), see [resource 23 § 11 LEADING CO-CANONICAL](23-sql-best-practices-olap.md#11-use-ctes-or-subqueries--dont-re-run-the-same-expensive-query-twice) for the three-form rank + the zero-group-safe `WHERE bool` DO-NOT-WRITE.
>
> **Alias-must-match-function rule.** Each output column's alias must reflect the function actually used. `SUM(revenue) FILTER (...) AS q1_revenue` is correct (SUM produces a total). If you instead want the per-quarter **average** order value, switch the function — `AVG(revenue) FILTER (WHERE quarter = 'Q1') AS q1_avg_order_value` — do NOT keep `SUM(...)` and rename the alias to `avg_*` (that ships a wrong-by-a-factor-of-row-count number under an average label). The FILTER (WHERE ...) clause is supported on every Trino aggregate function: `SUM`, `AVG`, `COUNT`, `MIN`, `MAX`, `array_agg`, `approx_distinct`, `approx_percentile`, etc. — pick the function that matches the metric, then use the alias that matches the function.

The query above returns the cohort grid in **long format** (one row per cohort_week × week_offset). That's fine for some BI tools, but stakeholders usually want the **wide format** with one column per week, showing percentage retention (week_N / week_0 × 100). Pivot it with `CASE WHEN` (conditional aggregation) and divide by the cohort size:

```sql
WITH cohorts AS (
  SELECT user_id,
         date_trunc('week', MIN(event_time)) AS cohort_week
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup'
  GROUP BY user_id
),
activity AS (
  SELECT c.cohort_week,
         date_diff('week', c.cohort_week, e.event_time) AS week_offset,
         COUNT(DISTINCT e.user_id) AS active_users
  FROM cohorts c
  JOIN iceberg.analytics.user_events e ON e.user_id = c.user_id
  WHERE date_diff('week', c.cohort_week, e.event_time) BETWEEN 0 AND 4
  GROUP BY c.cohort_week, date_diff('week', c.cohort_week, e.event_time)
),
pivoted AS (
  SELECT cohort_week,
         SUM(CASE WHEN week_offset = 0 THEN active_users END) AS week_0,
         SUM(CASE WHEN week_offset = 1 THEN active_users END) AS week_1,
         SUM(CASE WHEN week_offset = 2 THEN active_users END) AS week_2,
         SUM(CASE WHEN week_offset = 3 THEN active_users END) AS week_3,
         SUM(CASE WHEN week_offset = 4 THEN active_users END) AS week_4
  FROM activity
  GROUP BY cohort_week
)
SELECT cohort_week,
       week_0,
       ROUND(100.0 * week_1 / week_0, 1) AS pct_week_1,
       ROUND(100.0 * week_2 / week_0, 1) AS pct_week_2,
       ROUND(100.0 * week_3 / week_0, 1) AS pct_week_3,
       ROUND(100.0 * week_4 / week_0, 1) AS pct_week_4
FROM pivoted
ORDER BY cohort_week;
```

This produces the familiar triangular retention table — `week_0` is always 100%, and later columns show the percentage of the cohort still active.

**Tip:** Let your BI tool pivot if it supports it — most dashboards (Superset, Metabase) can pivot from the long format natively, so you can keep the simpler SQL and let the dashboard build the wide view. Only pivot in SQL when you're exporting to a flat file or when the BI tool can't do it.

---

## 4. Time-series rollups (with gap-filling)

> **DISAMBIGUATION SIGNPOST — FIRST, decide what you are counting per day (read BEFORE the SQL below). Keyword anchors:** active per day, occupied per day, open per day, how many were active on each day, count things spanning each day, interval active per day vs events per day, start_date GROUP BY wrong for active-per-day, subscriptions active per day, bookings/desks/rooms occupied per day, reservations active per day, tickets open per day, sessions concurrent per day, employees employed per day, leases active per day, point event vs interval, one row one date vs start-and-end.
>
> **If each fact row is a POINT EVENT** (one row = one thing that happened on **ONE** date — a payment, a signup event, a click, a page view, an order placement, a login), and you want a daily count/sum with **zero-fill for empty days**, the date-spine + LEFT JOIN + `COALESCE(..., 0)` recipe **below** is right: **group the facts by their date column** (e.g., `GROUP BY date_trunc('day', event_time)`), then LEFT JOIN the calendar spine onto that grouped aggregate.
>
> **BUT if each fact is an INTERVAL** — it has a **START and an END** (subscriptions with `start_date`/`end_date`; bookings/reservations with `check_in`/`check_out`; sessions with `started_at`/`ended_at`; tickets with `opened_at`/`closed_at`; leases/employment/desk-or-room occupancy with `begin`/`end`) — and you want **how many were ACTIVE / OPEN / OCCUPIED on each day** (every day shown, `0` must appear for empty days, AND a Mon-Fri interval must count on Mon AND Tue AND Wed AND Thu, NOT just Mon), that is a **DIFFERENT pattern**: **do NOT `GROUP BY <start_date>` / `GROUP BY DATE(check_in)` / `GROUP BY date_trunc('day', started_at)`** — that counts each interval **only on its START day** and shows **0 on the other days the interval is actually active** (the iter577/578 fab). Use the **INTERVAL-OVERLAP range join** — `calendar c LEFT JOIN intervals i ON i.start <= c.day AND (i.end IS NULL OR i.end > c.day)` then `COUNT(i.id)` (NOT `COUNT(*)` — that counts the LEFT-JOIN NULL-padded row as 1 in zero-active buckets). See the LEADING CANONICAL [§4 — count active/open intervals on each day (interval-overlap range join)](#leading-canonical--count-activeopen-intervals-on-each-day-interval-overlap-range-join--not-forward-fill-not-a-current_date-snapshot) below for the canonical query, the reservations/rooms variant, and the COUNT-LEFT-JOIN-trap card.

**The SaaS question:** "Show me signups per day for the last 30 days."

Naive version:

```sql
SELECT date_trunc('day', event_time) AS day, COUNT(*) AS signups
FROM iceberg.analytics.user_events
WHERE event_name = 'signup'
  AND event_time >= current_date - INTERVAL '30' DAY
GROUP BY 1
ORDER BY 1;
```

> **Trino "last N days" — both forms are VALID; INTERVAL is just more idiomatic.** Per [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html), Trino supports BOTH equivalent forms for date subtraction. Pick either; do NOT rewrite working code to switch between them.
>
> | Form | Example | Valid? | Notes |
> |---|---|---|---|
> | A — INTERVAL literal (preferred / idiomatic) | `WHERE event_date >= current_date - INTERVAL '30' DAY` | YES | Most common in Trino code; reads naturally. |
> | B — `date_add` with negative value | `WHERE event_date >= date_add('day', -30, current_date)` | YES | Signature `date_add(unit, value, timestamp) → same as input`; the docs explicitly state "Subtraction can be performed by using a negative value." Equally valid; use when programmatically computing the offset. |
> | C — bare integer subtraction | `WHERE event_date >= current_date - 30` | **NO — parse/type error** | Trino has NO implicit integer-day arithmetic on DATE/TIMESTAMP. The `-` operator requires an INTERVAL on the right side. This is the ONLY form that is invalid. |
>
> **Do NOT over-ban:** `date_add('day', -N, current_date)` is a real, supported Trino function — not a workaround, not deprecated. The only banned form is the bare integer `current_date - N`.

**The gotcha:** if no one signed up on Jan 14, that day is *missing from the result* — not zero. Dashboards then show a deceiving line that "skips" days.

**Fix: generate a calendar and LEFT JOIN.**

```sql
WITH calendar AS (
  SELECT date_add('day', n, current_date - INTERVAL '30' DAY) AS day
  FROM UNNEST(sequence(0, 29)) AS t(n)
),
signups AS (
  SELECT date_trunc('day', event_time) AS day, COUNT(*) AS cnt
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup' AND event_time >= current_date - INTERVAL '30' DAY
  GROUP BY 1
)
SELECT c.day, COALESCE(s.cnt, 0) AS signups
FROM calendar c
LEFT JOIN signups s ON s.day = c.day
ORDER BY c.day;
```

> **`sequence()` — the canonical Trino date-spine / generate-series / row-spine generator (signature pin).** Per [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html): `sequence(start, stop) -> array` (integer or date — step defaults to `+1` if `start <= stop`, else `-1`); `sequence(start, stop, step) -> array` (integer step for ints; `INTERVAL DAY TO SECOND` or `INTERVAL YEAR TO MONTH` step for dates and timestamps). Both bounds are **INCLUSIVE**. There is **NO `generate_series` function in Trino** — `generate_series` is the Postgres name; on Trino you write `sequence(...)` and `UNNEST` it to rows. Keyword anchors: `Trino generate_series`, `Trino date spine`, `Trino generate range of dates`, `Trino row spine`, `Trino generate calendar`, `Trino sequence function signature`, `Trino integer range`, `Trino date range UNNEST`.

> **Cross-reference — INTERVAL facts (start_date + end_date) need a DIFFERENT pattern.** The recipe above is right for **POINT-EVENT** facts (`GROUP BY date_trunc('day', event_time)` then LEFT JOIN the spine). If your fact has a start AND an end (subscriptions, bookings/reservations, sessions, tickets, leases, room/desk occupancy) and the question asks "how many were ACTIVE / OPEN / OCCUPIED on EACH day" (a Mon-Fri interval must count on Mon AND Tue AND Wed AND Thu), use the **INTERVAL-OVERLAP RANGE JOIN** — see the LEADING CANONICAL [§4 — count active/open intervals on each day (interval-overlap range join)](#leading-canonical--count-activeopen-intervals-on-each-day-interval-overlap-range-join--not-forward-fill-not-a-current_date-snapshot) further down in this section. Do NOT `GROUP BY <start_date>` and LEFT JOIN the spine to that aggregate — the multi-day interval gets credited on its start day only.

### LEADING CANONICAL — forward-fill / carry the last non-null value forward (`LAST_VALUE ... IGNORE NULLS`, look-BACK frame)

> **Keyword anchors (read this section FIRST if your question contains any of these):** forward fill Trino, fill forward, carry forward last non-null, fill NULL gaps with previous value, LAST_VALUE IGNORE NULLS, gap fill values, last observation carried forward, LOCF Trino, fill down, previous non-null per partition, value gap-fill (vs date gap-fill), sensor reading gap, IoT telemetry NULL between readings, last reported reading per device.

**The fact in one sentence.** To **carry the last non-null value forward** per partition (LOCF / fill-down), use `LAST_VALUE(col) IGNORE NULLS OVER (PARTITION BY id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` — the `IGNORE NULLS` skips gap rows, and the look-BACK frame ends at the current row so you see the most recent non-null **at or before** the current row.

**Trino docs verbatim** (verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html)): *"By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation."* `IGNORE NULLS` is valid on `first_value` / `last_value` / `nth_value` / `lag` / `lead`. (Default behavior is RESPECT NULLS; there is no separate `RESPECT NULLS` keyword in Trino — omit `IGNORE NULLS` to get the default.)

**Canonical recipe (copy-paste this).** Pair with the §4 date gap-fill above: the calendar `LEFT JOIN` first creates the dense `(id, day)` rows (many with NULL metric), then `LAST_VALUE ... IGNORE NULLS` fills the NULL gaps with the previous non-null value:

```sql
-- After the date gap-fill LEFT JOIN above produces dense (id, day, metric) rows with NULLs in the gaps:
SELECT
  id,
  day,
  COALESCE(
    metric,
    LAST_VALUE(metric) IGNORE NULLS OVER (
      PARTITION BY id ORDER BY day
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )
  ) AS metric_filled
FROM dense_series;
```

The outer `COALESCE` is optional but makes intent explicit when `metric` is non-NULL on the current row. `LAST_VALUE(metric) IGNORE NULLS` over the look-BACK frame already returns the current row's value when `metric` is non-NULL on that row.

**DO-NOT-WRITE (load-bearing — these are the iter565 forward-fill fab class):**

- *`LAST_VALUE(metric) IGNORE NULLS OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)`* for forward-fill — **FALSE: that is FUTURE-fill, not forward-fill.** The `UNBOUNDED FOLLOWING` upper bound makes every row see the partition's **globally-last** non-null value — including rows that come **BEFORE** the first non-null observation, which a true LOCF would leave NULL. Forward-fill needs the **look-BACK** frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` so the upper bound is the current row.
- *`PARTITION BY id, CASE WHEN x IS NOT NULL THEN 1 ELSE 0 END`* as a forward-fill trick — **BROKEN.** This splits non-null and NULL rows into **two separate partitions**, so the NULL-rows partition has no non-null values to carry forward and stays NULL. Do not use.
- Using a CASE-WHEN-inside-`LAST_VALUE` workaround (e.g., `LAST_VALUE(CASE WHEN x IS NOT NULL THEN x END) OVER (...)`) as **THE canonical** form — the workaround happens to work in some engines without `IGNORE NULLS`, but **Trino HAS native `IGNORE NULLS`**, which is cleaner and unambiguous. Reach for the native form first.
- *`LAG(x) IGNORE NULLS`* invoked **without an explicit `ORDER BY`** — `LAG`/`LEAD`/`LAST_VALUE` all require ORDER BY in the window spec for forward-fill to be deterministic.
- **Multi-series carry-forward — include `PARTITION BY entity_id` in the `OVER` clause.** The canonical recipe above shows `PARTITION BY id` for that reason: without `PARTITION BY`, all rows are treated as **a single series** and the last non-null value from entity A will leak across into entity B's NULL rows. For per-product / per-tenant / per-user / per-device carry-forward, write `LAST_VALUE(metric) IGNORE NULLS OVER (PARTITION BY entity_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` — substitute your entity column for `entity_id`.

**Complement / cross-reference.** This is the **value** forward-fill. The **row** densification (creating one row per `(id, day)` so there's something to fill) is the §4 date gap-fill recipe above (calendar `UNNEST(sequence(...))` LEFT JOIN'd to the sparse fact). Use them together: gap-fill the dates first, then forward-fill the values. For lookback comparisons that also need IGNORE NULLS, `LAG(x) IGNORE NULLS OVER (... ORDER BY day)` returns the **previous non-null** value (vs `LAG(x)` which returns the previous **row's** value even if NULL). See §5 Pattern B3 for the related `LAST_VALUE` **default-frame** footgun (when the frame is omitted, `LAST_VALUE` returns the current row's value — that section is about a different fab; this section is about correctly-framed forward-fill with `IGNORE NULLS`).

### COMBINED CANONICAL — composing the date-spine + forward-fill correctly (ORDERING MATTERS — iter570 PIN, iter572 REORDERED)

> **Keyword anchors (read this section FIRST if your question contains any of these):** forward-fill plus date spine, gap-fill dates AND forward-fill values, dense minute grid + LOCF, device heartbeat forward-fill, IoT minute-bucket forward-fill, sensor status carry-forward minute spine, fill missing minutes with last reported status, every minute per device last known status, combine sequence and LAST_VALUE IGNORE NULLS, date-spine forward-fill order of operations, IGNORE NULLS placement, IGNORE NULLS inside parentheses parse error, where does IGNORE NULLS go, IGNORE NULLS after closing paren before OVER, LAST_VALUE IGNORE NULLS syntax.

> **Copy this query as-is. Do NOT retype the `IGNORE NULLS` clause — it goes OUTSIDE the function's closing parenthesis, before `OVER`.** The correct form is `LAST_VALUE(status) IGNORE NULLS OVER (...)` — **NOT** `LAST_VALUE(status IGNORE NULLS) OVER (...)` (that is a parse error — see the DO-NOT-WRITE block below). Also: build the spine with **`sequence()` + `CROSS JOIN UNNEST`** (TRUE dense calendar) — **never** from `SELECT DISTINCT date_trunc('day', event_ts) FROM facts`, which silently drops days with zero events across all entities.

**Compact correct end-to-end query (device-heartbeat / minute-spine forward-fill — copy-paste this — the FIRST artifact in this section so you copy it rather than re-derive it):**

```sql
-- Step 1: dense (device_id, ts) grid — one row per device per minute in the lookback window.
WITH bounds AS (
  SELECT min(reported_at) AS lo, max(reported_at) AS hi
  FROM iceberg.iot.device_heartbeats
  WHERE reported_at >= current_timestamp - INTERVAL '1' DAY
),
minute_spine AS (                                  -- TRUE dense calendar via sequence()+UNNEST (NOT DISTINCT-event-days)
  SELECT t AS ts
  FROM bounds
  CROSS JOIN UNNEST(sequence(date_trunc('minute', lo),
                             date_trunc('minute', hi),
                             INTERVAL '1' MINUTE)) AS u(t)
),
devices AS (
  SELECT DISTINCT device_id
  FROM iceberg.iot.device_heartbeats
  WHERE reported_at >= current_timestamp - INTERVAL '1' DAY
),
grid AS (                                          -- dense (device_id, ts) — every minute, every device
  SELECT d.device_id, s.ts
  FROM devices d
  CROSS JOIN minute_spine s
),
-- Step 2a: collapse the sparse facts to ONE row per (device_id, minute) FIRST via max_by — fanout-safe.
--          Multiple heartbeats in the same minute? max_by keeps the LATEST reading within the bucket.
per_bucket AS (
  SELECT device_id,
         date_trunc('minute', reported_at) AS ts,
         max_by(status, reported_at)       AS status     -- ONE row per (device, minute) — no fanout
  FROM iceberg.iot.device_heartbeats
  WHERE reported_at >= current_timestamp - INTERVAL '1' DAY
  GROUP BY device_id, date_trunc('minute', reported_at)
),
-- Step 2b: LEFT JOIN the one-row-per-bucket result to the dense grid. Gap minutes => status IS NULL.
joined AS (
  SELECT g.device_id,
         g.ts,
         p.status                                  -- NULL on gap minutes (post-join)
  FROM grid g
  LEFT JOIN per_bucket p
    ON p.device_id = g.device_id
   AND p.ts        = g.ts
)
-- Step 3: apply the window AFTER the join, over the dense rows. NULLs are now visible to IGNORE NULLS.
--         IGNORE NULLS goes OUTSIDE the function's closing paren, BEFORE OVER — NOT inside the args.
SELECT device_id,
       ts,
       COALESCE(
         status,
         LAST_VALUE(status) IGNORE NULLS OVER (
           PARTITION BY device_id ORDER BY ts
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
         )
       ) AS status_filled
FROM joined
ORDER BY device_id, ts;
```

**The fact in one sentence.** When you need BOTH the dense `(entity, time)` grid AND the carry-forward fill, the window MUST be applied **AFTER** the LEFT JOIN to the spine — over the **post-join dense rows** where gap minutes are NULL. If you compute `LAST_VALUE(...) IGNORE NULLS` in a CTE over the **raw sparse facts FIRST** and then LEFT JOIN the spine, gap rows the join creates were never seen by that earlier window → they stay NULL → `COALESCE` over two NULLs returns NULL → **gaps NOT filled**.

**Ordering recipe — four numbered steps (copy this mental order):**

1. **Build the dense grid.** `CROSS JOIN UNNEST(sequence(min_ts, max_ts, INTERVAL '1' MINUTE))` × distinct entities (devices / users / tenants / products). The grid CTE contains every `(entity, ts)` pair you want in the output, with NO measure column yet. **DO NOT** build the spine from `SELECT DISTINCT date_trunc('day', event_ts) FROM facts` — days with **zero events across ALL entities** will be MISSING (you only get days that appear at least once in the raw facts). Use `sequence(start, end, INTERVAL '1' DAY)` + `CROSS JOIN UNNEST` for a TRUE dense calendar, then `CROSS JOIN` the distinct entity list to get a `(entity, day)` cross product.
2. **Step 2a — collapse the sparse facts to ONE row per `(entity, bucket)` FIRST (fanout-safe).** If the raw fact table can have MULTIPLE events per `(entity, bucket)` (multiple heartbeats per minute, many status updates per hour, several writes per day per row), the LEFT JOIN in Step 2b will FAN OUT — the grid row matches every fact row, multiplying the output. Pre-aggregate to **one row per `(entity, bucket)`** first using `max_by` to keep the LATEST reading within the bucket: `SELECT entity_id, date_trunc('hour', ts) AS bucket, max_by(metric, ts) AS metric FROM facts GROUP BY entity_id, date_trunc('hour', ts)`. **Use `max_by(metric, ts)` to keep the LATEST reading in the bucket — NOT `MAX(metric)` (largest ≠ latest); end-of-week balance, end-of-day reading, last-status-per-bucket all need `max_by(value, ts)`. See [resource 23 §3.1D](23-sql-best-practices-olap.md#31d-arbitrary--any_value-pick-one-value-per-group-and-max_by--min_by-deterministic-representative-value-pick).** **Keyword anchor:** fanout from multiple events per bucket, dedupe/aggregate per hour before forward-fill, one row per entity per time bucket, many updates per day collapse to last per day, multiple heartbeats per minute, `max_by` per bucket, end-of-week balance not MAX, latest value not largest value.
3. **Step 2b — LEFT JOIN that one-row-per-bucket result to the dense grid.** Gap-row entries (entity/bucket pairs with no real fact) now have NULL metric. This is where the NULLs you want to fill actually appear in the row stream — and there is NO row-multiplication risk because Step 2a guarantees at most one fact row per `(entity, bucket)`.
4. **Step 3 — THEN apply the window AFTER the join, over the post-join dense rows.** `COALESCE(metric, LAST_VALUE(metric) IGNORE NULLS OVER (PARTITION BY entity_id ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))` — the window now sees the NULL-padded dense rows, so `IGNORE NULLS` skips the gap rows and the look-BACK frame returns the most recent non-null value at or before each gap. **The `IGNORE NULLS` keyword goes OUTSIDE the function's closing paren, BEFORE `OVER`** — see DO-NOT-WRITE bullet (1) below.

**Why this works.** Step 2b's LEFT JOIN is what **manufactures the NULL rows that need filling**. Step 3's `LAST_VALUE(status) IGNORE NULLS` runs over the `joined` CTE — which contains both the non-NULL "real" reports and the NULL gap minutes. `IGNORE NULLS` skips the gap rows and the look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` returns the most recent non-NULL `status` at or before each gap minute, per device.

**DO-NOT-WRITE (load-bearing — iter570 forward-fill + spine composition fab class; iter572 PIN for IGNORE-NULLS placement regression):**

- **`IGNORE NULLS` placed INSIDE the function-args paren is a PARSE ERROR — every form below fails to parse on Trino 467.** The Trino 467 grammar (verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) + [SqlBase.g4 grammar referenced in PR #1244](https://github.com/trinodb/trino/pull/1244)) places the **null-treatment clause AFTER the closing paren of the function arguments and BEFORE `OVER`**: the grammar literally reads `functionCall: name '(' args ')' nullTreatment? filter? over?` — `nullTreatment` is a clause that sits OUTSIDE the args paren, between `)` and `OVER`. The Trino window-functions doc says verbatim: *"By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation."* — and shows the keyword **after** the closing paren of the args. **Grep-findable exact-wrong tokens (every one of these is a parse error — `mismatched input 'IGNORE'`):**
    - `LAST_VALUE(col IGNORE NULLS) OVER (...)` &nbsp;&nbsp;❌ PARSE ERROR
    - `FIRST_VALUE(col IGNORE NULLS) OVER (...)` &nbsp;&nbsp;❌ PARSE ERROR
    - `LAG(col IGNORE NULLS) OVER (...)` &nbsp;&nbsp;❌ PARSE ERROR
    - `LEAD(col IGNORE NULLS) OVER (...)` &nbsp;&nbsp;❌ PARSE ERROR
    - `NTH_VALUE(col, 2 IGNORE NULLS) OVER (...)` &nbsp;&nbsp;❌ PARSE ERROR
  **CORRECT** — the null-treatment clause goes **AFTER the closing args paren and BEFORE `OVER`**:
    - `LAST_VALUE(col) IGNORE NULLS OVER (...)` &nbsp;&nbsp;✅
    - `FIRST_VALUE(col) IGNORE NULLS OVER (...)` &nbsp;&nbsp;✅
    - `LAG(col) IGNORE NULLS OVER (...)` &nbsp;&nbsp;✅
    - `LEAD(col) IGNORE NULLS OVER (...)` &nbsp;&nbsp;✅
    - `NTH_VALUE(col, 2) IGNORE NULLS OVER (...)` &nbsp;&nbsp;✅
  The same rule covers `RESPECT NULLS` (the default — usually omitted). Mnemonic: **close the args, then `IGNORE NULLS`, then `OVER`** — three tokens, in that order, with whitespace between each.
- **Computing `LAST_VALUE(...) IGNORE NULLS` in a CTE over the RAW sparse facts FIRST and THEN LEFT JOIN-ing the spine — gaps NOT filled.** Every raw sparse-fact row already has a non-NULL `status` (the table only stores actual reports), so `IGNORE NULLS` skips nothing — the window is a no-op. The LEFT JOIN that comes AFTER then introduces gap rows with `h.status = NULL` AND `h.last_known_status = NULL` (the no-op output is also NULL on the gap side), so `COALESCE(NULL, NULL) = NULL` and the gaps stay empty. **The window MUST run on the POST-JOIN dense rows.** Build the spine, LEFT JOIN, THEN window — the three-step order above is the only correct composition.
- **Equivalent variant — replacing `COALESCE(status, LAST_VALUE(status) IGNORE NULLS OVER ...)` with bare `LAST_VALUE(status) IGNORE NULLS OVER (...)`** is also correct (the look-BACK frame already returns the current row's value when `status` is non-NULL on that row, per the standalone canonical above). Either form is fine; the `COALESCE` wrapper just makes intent explicit. **DO NOT** wrap with `COALESCE(status, last_known_status)` referencing a CTE column from a pre-join LAST_VALUE attempt — see the previous bullet.
- **DO NOT compute ANY `LAST_VALUE` / forward-fill window in a PRE-JOIN CTE over the raw facts — and ESPECIALLY NOT with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` (iter571 PIN).** A full-frame `LAST_VALUE(metric) OVER (PARTITION BY entity_id ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` collapses to the **PARTITION-GLOBAL-LAST value** (a single constant per entity) — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): `LAST_VALUE` returns the last value of the window frame, and `UNBOUNDED FOLLOWING` extends the frame to the partition's final row, so every row in the partition sees the SAME last value. If you compute that constant in a pre-join CTE and THEN LEFT JOIN the dense spine, EVERY gap row inherits the entity's globally-latest reading — NOT the as-of-bucket value the question actually asks for. **WRONG (pre-join CTE with full-frame `LAST_VALUE`, then LEFT JOIN):** `WITH sparse_logs AS (SELECT server_id, logged_at, cpu_percent, LAST_VALUE(cpu_percent) OVER (PARTITION BY server_id ORDER BY logged_at ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS latest_cpu FROM raw_facts) SELECT g.server_id, g.bucket, COALESCE(s.cpu_percent, s.latest_cpu) AS cpu FROM grid g LEFT JOIN sparse_logs s ON s.server_id = g.server_id AND date_trunc('hour', s.logged_at) = g.bucket` — produces the partition-global-last value for every gap, and ALSO fans out if `sparse_logs` has multiple rows per `(server_id, hour)`. **RIGHT (no pre-join window — collapse to one-row-per-bucket via `max_by`, LEFT JOIN, then forward-fill in the FINAL select over the post-join dense rows):** Steps 2a → 2b → 3 in the recipe above (`max_by(cpu_percent, logged_at) GROUP BY server_id, date_trunc('hour', logged_at)` first → LEFT JOIN onto the spine → final `LAST_VALUE(...) IGNORE NULLS OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` in the outer SELECT). The forward-fill window belongs **ONLY** in the final SELECT over the POST-JOIN dense rows — never in a pre-join CTE. The standalone forward-fill canonical above also bans `UNBOUNDED FOLLOWING` for forward-fill (it would be **future-fill**, not forward-fill); the recipe here additionally bans **any** window over raw sparse facts before the spine join, full-frame or otherwise.
- **DO NOT GROUP BY an aggregate when building the spine — it's a parse error (iter573 PIN).** *Keyword anchors:* GROUP BY cannot contain aggregations, GROUP BY an aggregate, spine from MIN date, generate weeks from min date, sequence from min to max date, cannot GROUP BY MIN, weeks_spine GROUP BY date_trunc MIN, **MAX(COUNT(*)) nested aggregate parse error, AVG(COUNT(...)) nested aggregate, busiest weekday per user MAX(COUNT(*)) — see also the busiest-weekday-per-user worked pattern at the `date_trunc('week') Monday-start + day_of_week 1..7 + format_datetime EEEE` canonical (search "iter665 FIX-A") for the CTE + ROW_NUMBER top-1-per-user rewrite that uses `day_of_week(...)` (ISO 1..7, NOT Postgres 0..6) and `format_datetime(CAST(order_date AS timestamp), 'EEEE')` for the weekday NAME — and the DO-NOT-WRITE list there bans `dayname()` (which does not exist in Trino 467) and bans `CAST(day_of_week(...) AS VARCHAR)` for the NAME (yields '1'..'7', not 'Monday'..'Sunday')**. **WRONG ❌ PARSE ERROR:** `SELECT date_add('day', n*7, date_trunc('week', MIN(posted_date))) AS week_start FROM ledger, UNNEST(sequence(0,52)) AS t(n) GROUP BY date_trunc('week', MIN(posted_date))` — Trino raises **"GROUP BY clause cannot contain aggregations, window functions or grouping operations"** (the analyzer's `verifyNoAggregateWindowOrGroupingFunctions` rule). Two distinct bugs in that snippet: (i) you cannot `GROUP BY` an expression that **contains** an aggregate (`MIN(posted_date)`); (ii) the derived value `n` (from the UNNEST) appears in `SELECT` but is neither grouped nor aggregated, which is its own GROUP BY violation. **RIGHT ✅ (two clean forms — pick one):** **Form A — scalar-subquery the MIN/MAX bound and drive the rows from the UNNEST** (no GROUP BY at all): `SELECT date_add('day', n*7, (SELECT date_trunc('week', MIN(posted_date)) FROM ledger)) AS week_start FROM UNNEST(sequence(0, 52)) AS t(n)`. **Form B — bounds CTE + sequence over the interval** (preferred — mirrors the device-heartbeat query above): `WITH bounds AS (SELECT MIN(posted_date) AS lo, MAX(posted_date) AS hi FROM ledger), weeks_spine AS (SELECT w AS week_start FROM bounds CROSS JOIN UNNEST(sequence(date_trunc('week', lo), date_trunc('week', hi), INTERVAL '7' DAY)) AS u(w)) SELECT * FROM weeks_spine`. Both forms put the aggregate **inside its own scalar subquery / CTE** where it is the SELECT-list expression — never inside a `GROUP BY`. Trino docs: SELECT grammar at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — the `GROUP BY` clause accepts column references and grouping-set lists; aggregate functions belong in the SELECT list, not the GROUP BY list. See also [Trino Issue #25984](https://github.com/trinodb/trino/issues/25984) for the literal error string.

### LEADING CANONICAL — count active/open intervals on each day (interval-overlap range join — NOT forward-fill, NOT a CURRENT_DATE snapshot)

> **Keyword anchors (read this section FIRST if your question contains any of these):** active subscribers per day, open tickets per day, concurrent sessions per day, count active intervals as of each day, how many were active on each date, range join calendar to intervals, point-in-time count per day, subscriptions active on day, headcount per day, occupancy per day, active members each day, open positions per day, count overlapping intervals, intervals covering each day, as-of count per day, daily snapshot count of in-progress entities. **Also (iter578 — reservations / rooms / bookings / hotel-desk-meeting-room domain):** reservations active per room per day, bookings per day, rooms occupied per day, desks occupied per day, check-in check-out overlap, how many bookings span each day, occupancy by room by day, concurrent bookings, hotel / meeting-room / desk occupancy, room utilization per day, "a reservation from Mon to Fri covers Mon Tue Wed Thu" (NOT just Mon), per-room per-day active reservation count.

**The fact in one sentence.** To count, for **EACH day `d`** in a date range, the entities whose active interval (`[start, end)`) **covers** `d`, range-**JOIN** the dense day spine to the interval table on `s.start <= d AND (s.end IS NULL OR s.end > d)` and `GROUP BY d` (plus any dimension column). Use the **half-open `[start, end)` convention** so that an interval ending on day `X` is **NOT** counted on day `X` (this avoids the boundary double-count where an interval ending on X and another starting on X would both be counted on X).

**Why this is its own pattern (NOT forward-fill, NOT a snapshot).** Forward-fill carries the last known VALUE into gap rows on a sparse `(entity, day, value)` table. A point-in-time snapshot (`WHERE start <= CURRENT_DATE AND (end IS NULL OR end > CURRENT_DATE)`) gives you ONE row: the count of active intervals **as of today**. Neither of those answers the question "how many were active on **EACH** historical day d?" The interval-overlap range join is the correct pattern: every calendar day `c.day` enters the JOIN predicate, so the count is re-evaluated **per day** — historical days get their historical active counts, today gets today's count, all in one result set.

**Canonical worked end-to-end query (the "active subscribers per day per plan over full history" scenario — reuses the dynamic-bounds spine from the COMBINED CANONICAL above):**

```sql
-- Active subscribers per day per plan_type, over the FULL history of the subscriptions table.
-- bounds: dynamic — start at the earliest subscription_start_date, end at today.
-- calendar: dense day spine from bounds via sequence() + CROSS JOIN UNNEST (TRUE dense calendar).
-- range JOIN: a subscription s is active on calendar day c.day iff s.subscription_start_date <= c.day
--             AND (s.subscription_end_date IS NULL OR s.subscription_end_date > c.day) — half-open [start, end).
-- INNER JOIN: only emit (c.day, plan_type) pairs that have >=1 active subscription on that day.
-- (Switch to LEFT JOIN + COALESCE(active_count, 0) if you need a row for every (day, plan_type) even when zero.)

WITH bounds AS (
  SELECT MIN(subscription_start_date) AS lo,
         CURRENT_DATE                  AS hi
  FROM iceberg.analytics.subscriptions
),
calendar AS (
  SELECT d AS day
  FROM bounds
  CROSS JOIN UNNEST(sequence(lo, hi, INTERVAL '1' DAY)) AS t(d)
)
SELECT
  c.day,
  s.plan_type,
  COUNT(*) AS active_count
FROM calendar c
JOIN iceberg.analytics.subscriptions s
  ON s.subscription_start_date <= c.day                                    -- interval STARTED on or before c.day
 AND (s.subscription_end_date IS NULL OR s.subscription_end_date > c.day)  -- AND has not ENDED by c.day (half-open)
GROUP BY c.day, s.plan_type
ORDER BY c.day, s.plan_type;
```

**Why this works.** For each calendar day `c.day`, the JOIN predicate evaluates against EVERY subscription: subscriptions whose `[start, end)` window covers `c.day` survive the join. `COUNT(*) GROUP BY c.day, s.plan_type` then tallies the survivors per `(day, plan)`. The dense `calendar` CTE guarantees every day in `[min_start, today]` gets evaluated — there are no gaps in the output day axis even if no subscription started or ended that day. The dynamic bounds (`MIN(subscription_start_date)` from a bounds CTE; see the iter573 GROUP-BY-aggregate-ban canonical above — put the `MIN` in a CTE, **not** in a `GROUP BY`) make the spine cover the full history without hardcoded dates.

**WORKED VARIANT — reservations active per room per day (hotel / meeting-room / desk-booking domain — iter578 PIN).** Same interval-overlap pattern, different domain vocabulary. The question reads "how many reservations are active per room per day?" — a Mon-Fri reservation must count on Mon AND Tue AND Wed AND Thu (the four days it covers, because `check_out` is half-open and excludes the checkout day, OR all five if your domain treats `check_out` as inclusive — adjust the predicate accordingly). Every `(room, day)` must appear in the output, including empty room-days (no reservations) where the count is `0`. This variant deliberately exercises BOTH the interval-overlap range join AND the iter577 COUNT-non-null-right-col-after-LEFT-JOIN trap:

```sql
-- Reservations active per room per day (every (room, day) kept; empty room-days = 0):
WITH calendar AS (
  SELECT d AS day FROM UNNEST(sequence(DATE '2026-05-01', DATE '2026-05-31', INTERVAL '1' DAY)) AS t(d)
)
SELECT c.day, ar.room_id, COUNT(r.reservation_id) AS active_count
FROM calendar c
CROSS JOIN meeting_rooms ar                              -- the ROOM DIMENSION (every room, even never-reserved)
LEFT JOIN reservations r
  ON r.room_id = ar.room_id
 AND r.check_in <= c.day                                  -- overlap: started on/before this day
 AND (r.check_out IS NULL OR r.check_out > c.day)         -- AND not yet ended (half-open [check_in, check_out))
GROUP BY c.day, ar.room_id
ORDER BY c.day, ar.room_id;
```

Two load-bearing details: (1) **Use a rooms DIMENSION table** (`meeting_rooms` / `rooms` / `desks` — whichever table is the authoritative room universe) for the room axis — `calendar c CROSS JOIN meeting_rooms ar` enumerates EVERY `(day, room)` pair so a never-reserved room still appears with `active_count = 0`. Do NOT derive the room universe with `(SELECT DISTINCT room_id FROM reservations)` — that drops rooms with zero reservations in the whole window. (2) **`COUNT(r.reservation_id)` — not `COUNT(*)`** — because the LEFT JOIN pads empty `(day, room)` buckets with NULL right-table columns; `COUNT(*)` would count that NULL-padded row as 1 and every empty room-day would WRONGLY show `1` (see the iter577 trap card below). Counting a non-NULL right-table column (`r.reservation_id` / `r.id` / `r.booking_id`) yields `0` for empty buckets.

**DO-NOT-WRITE (reservations-per-room-per-day specific — iter578 PIN — the exact iter577 Q1 responder miss):**

- **DO NOT pre-aggregate reservations by `DATE(check_in)` (or `GROUP BY check_in`) and join that to the calendar — a multi-day reservation will be credited ONLY on its start day, and shows 0 on every other day it is actually active.** **WRONG ❌:**
  ```sql
  -- WRONG: counts reservations by their CHECK-IN day only.
  WITH reservation_counts AS (
    SELECT room_id, DATE(check_in) AS day, COUNT(*) AS reservations_starting
    FROM reservations
    GROUP BY room_id, DATE(check_in)
  )
  SELECT c.day, ar.room_id, COALESCE(rc.reservations_starting, 0) AS active_count
  FROM calendar c
  CROSS JOIN meeting_rooms ar
  LEFT JOIN reservation_counts rc ON rc.room_id = ar.room_id AND rc.day = c.day
  ORDER BY c.day, ar.room_id;
  ```
  A Mon-Fri reservation `(check_in=Mon, check_out=Fri)` is counted ONLY on Mon (the start-day row in `reservation_counts`); Tue / Wed / Thu show `active_count = 0` for that room even though the reservation IS active on those days. **"Active on each day" REQUIRES the overlap RANGE JOIN** (`r.check_in <= c.day AND (r.check_out IS NULL OR r.check_out > c.day)`) — every calendar day must enter the JOIN predicate so each multi-day reservation is re-counted on every day it covers. **NOT a `GROUP BY DATE(check_in)`-then-join.** This is the exact iter577 Q1 responder miss; it is a wrong pattern. **RIGHT ✅:** the range-join query in the WORKED VARIANT above.
- **DO NOT `WHERE r.check_in >= <window_start>` to bound the reservations table to the window — that drops reservations that STARTED BEFORE the window but are still ACTIVE in it.** **WRONG ❌:** adding `WHERE r.check_in >= DATE '2026-05-01'` (or the equivalent inside the `ON` clause as `AND r.check_in >= DATE '2026-05-01'`) when the question asks "reservations active per room per day in May 2026" — a reservation `(check_in=2026-04-28, check_out=2026-05-05)` is ACTIVE on May 1-4 but is excluded by `check_in >= 2026-05-01`. **Bound the SPINE (the calendar CTE), NOT the fact's start date.** The overlap predicate evaluated against each calendar day automatically restricts the result to reservations active in the window, AND it correctly includes reservations that started before the window but are still active in it. **RIGHT ✅:** bound `sequence(DATE '2026-05-01', DATE '2026-05-31', INTERVAL '1' DAY)` (or relative `current_date - INTERVAL '30' DAY` etc.) in the `calendar` CTE; leave the reservations table unfiltered on `check_in`, and let the overlap predicate do the windowing.

**DO-NOT-WRITE (load-bearing — the iter574 Q1 fab class):**

- **DO NOT compute the active count as a `CURRENT_DATE` point-in-time snapshot CTE and then LEFT JOIN the calendar — every historical day will be 0 / 'No Activity', only TODAY's row will populate (iter574 PIN).** **WRONG ❌:**
  ```sql
  -- WRONG: this is a snapshot pinned to TODAY, NOT a per-day active count.
  WITH calendar AS (...),
  daily_active AS (
    SELECT CURRENT_DATE AS day, plan_type, COUNT(*) AS active_count
    FROM iceberg.analytics.subscriptions
    WHERE subscription_start_date <= CURRENT_DATE
      AND (subscription_end_date IS NULL OR subscription_end_date > CURRENT_DATE)
    GROUP BY plan_type
  )
  SELECT c.day, d.plan_type, COALESCE(d.active_count, 0) AS active_count
  FROM calendar c
  LEFT JOIN daily_active d ON c.day = d.day  -- joins ONLY on today's row → all other days are 0
  ORDER BY c.day;
  ```
  Only the row where `c.day = CURRENT_DATE` matches `d.day = CURRENT_DATE`; every other calendar day is LEFT-JOIN-padded to NULL → `COALESCE(NULL, 0) = 0`. The "active count" must be evaluated **PER calendar day** — the calendar day `c.day` must appear inside the JOIN predicate (`s.start <= c.day AND (s.end IS NULL OR s.end > c.day)`), **not** be hardcoded to `CURRENT_DATE`. **RIGHT ✅:** the range-join query above — `c.day` participates in the join predicate so the active count is recomputed for every historical day.
- **DO NOT use `BETWEEN s.start AND s.end` (closed interval) when you mean half-open `[start, end)` — closed BETWEEN double-counts the boundary day.** **WRONG ❌:** `JOIN subscriptions s ON c.day BETWEEN s.subscription_start_date AND s.subscription_end_date` — `BETWEEN x AND y` is `x <= c.day AND c.day <= y` (both inclusive). If subscription A ends on `2026-05-10` AND subscription B starts on `2026-05-10`, **BOTH** count on `2026-05-10` (A: `start <= 5/10 AND 5/10 <= end=5/10` true; B: `start=5/10 <= 5/10 AND 5/10 <= end` true) — you've double-counted the handoff day. **RIGHT ✅:** half-open `s.subscription_start_date <= c.day AND (s.subscription_end_date IS NULL OR s.subscription_end_date > c.day)` — only B counts on `2026-05-10` (A's `end > c.day` is `5/10 > 5/10` = false). Also: BETWEEN does NOT handle `s.end IS NULL` for still-active intervals — you'd need an extra `OR s.end IS NULL` branch and the result is messier. Stick with the explicit `<=` / `>` form.

**LOAD-BEARING TRAP — `COUNT(*)` vs `COUNT(s.session_id)` AFTER a LEFT JOIN on the interval-overlap predicate — zero-active buckets WRONGLY show 1 not 0 (iter577 PIN).**

> **Keyword anchors:** COUNT(*) LEFT JOIN counts padded row, zero-active bucket shows 1 not 0, COUNT(col) after LEFT JOIN, empty bucket count, overnight zero hours, count non-null right column, COUNT star left join trap, COALESCE(COUNT(*),0) vacuous, LEFT JOIN interval overlap zero shows 1, active per hour LEFT JOIN COUNT.

When you switch the interval-overlap join from `INNER JOIN` to `LEFT JOIN` to **guarantee a row for zero-active buckets** (every `(day, plan)` or `(hour, plan)` appears even when no interval is active), you MUST count a **non-NULL right-table column** — `COUNT(s.session_id)` / `COUNT(s.id)` / `COUNT(s.subscription_id)` — NOT `COUNT(*)`. With a `LEFT JOIN`, an empty bucket still produces **ONE row** (the calendar bucket + all-NULL right columns). `COUNT(*)` counts that NULL-padded row as **1**, so every zero-active bucket WRONGLY shows **1** instead of **0** (e.g., every overnight zero-active hour shows `active_count = 1`). An outer `COALESCE(active_count, 0)` is **vacuous** here because `COUNT(*)` **never** returns NULL — it already returned 1, so `COALESCE(1, 0) = 1`. The fix is to count a non-NULL right-table column, NOT to add a COALESCE.

**WRONG ❌** (every zero-active bucket shows 1):
```sql
SELECT c.bucket, COUNT(*) AS active_count                       -- counts the NULL-padded row → 1, not 0
FROM calendar c
LEFT JOIN iceberg.analytics.subscriptions s
  ON s.subscription_start_date <= c.bucket
 AND (s.subscription_end_date IS NULL OR s.subscription_end_date > c.bucket)
GROUP BY c.bucket;
```

**RIGHT ✅** (zero-active bucket = 0; no COALESCE needed):
```sql
SELECT c.bucket, COUNT(s.subscription_id) AS active_count        -- count any non-NULL right column → 0 for empty buckets
FROM calendar c
LEFT JOIN iceberg.analytics.subscriptions s
  ON s.subscription_start_date <= c.bucket
 AND (s.subscription_end_date IS NULL OR s.subscription_end_date > c.bucket)
GROUP BY c.bucket;
```

**Why `count(x)` gives 0 (not NULL) for empty groups.** Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): `count(*)` *"Returns the number of input rows"* and `count(x)` *"Returns the number of non-null input values"*. The Trino aggregate-page rule also states: *"Except for `count()`, `count_if()`, `max_by()`, `min_by()` and `approx_distinct()`, all of these aggregate functions ignore null values and return null for no input rows or when all values are null."* — `count()` is in the **exception list**: it returns **0** (not NULL) for zero non-null values, so the outer `COALESCE(active_count, 0)` is unnecessary on the RIGHT form. (For the generic LEFT-JOIN COUNT pitfall outside the interval-overlap composite, see the LEADING CANONICAL in § 1a.5 above — same root cause; this card is the interval-overlap-specific application.)

**Important — the INNER-JOIN form is unaffected.** The trap is **specifically** the `LEFT JOIN`-for-zero-rows + `COUNT(*)` pairing. The canonical INNER JOIN query at the top of this H3 uses `COUNT(*)` safely because INNER JOIN drops the zero-match bucket entirely — there is no NULL-padded row to over-count. The pattern: keep `COUNT(*)` with `INNER JOIN`; switch to `COUNT(<right_col>)` the moment you switch to `LEFT JOIN`.

**Bounded-window spine (just yesterday / this week — relative bounds, NOT `MIN(...)` full history).** When the question scopes the spine to a bounded window (e.g., "active sessions per hour **yesterday**", "open tickets per day **this week**"), set explicit relative bounds in the calendar CTE instead of deriving `lo` from `MIN(...)` — that gives you only the rows the question asks for, no full-history scan:

```sql
-- Yesterday only, HOUR grain (24 hourly buckets covering 00:00..23:00 of yesterday):
WITH calendar AS (
  SELECT t AS bucket
  FROM UNNEST(
    sequence(
      CAST(current_date - INTERVAL '1' DAY AS TIMESTAMP),                          -- lo: yesterday 00:00
      CAST(current_date AS TIMESTAMP) - INTERVAL '1' HOUR,                          -- hi: yesterday 23:00 (exclusive of today 00:00)
      INTERVAL '1' HOUR
    )
  ) AS t(t)
)
SELECT c.bucket, COUNT(s.session_id) AS active_count                                -- LEFT JOIN → COUNT(non-null right col), see trap card above
FROM calendar c
LEFT JOIN iceberg.analytics.sessions s
  ON s.session_start <= c.bucket
 AND (s.session_end IS NULL OR s.session_end > c.bucket)
GROUP BY c.bucket
ORDER BY c.bucket;
```

For a HOUR-grain spine over a bounded window, the spine size is tiny (24 rows for yesterday, 168 for last 7 days) — far cheaper than a `MIN(...)`-derived full-history spine. Use `MIN(...)` only when the question explicitly asks for full history.

**CONTRAST card — the THREE time-series patterns side-by-side (read this if you're not sure which one your question wants):**

| Pattern | One-line shape | Use when |
|---|---|---|
| **Forward-fill (LOCF)** | `LAST_VALUE(x) IGNORE NULLS OVER (PARTITION BY id ORDER BY d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` | Carry the **last known VALUE** into gap rows on a `(entity, day, value)` series — e.g., last reported temperature into minutes with no reading. See the LEADING CANONICAL forward-fill H3 above. |
| **Running total (cumulative sum)** | `SUM(x) OVER (PARTITION BY id ORDER BY d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` | Accumulate a numeric column from the start of the partition through each row — e.g., month-to-date revenue, lifetime signups. **Under `ROWS` each PHYSICAL row gets its OWN cumulative value (rows incrementing one at a time); same-`ORDER BY`-value rows do NOT collapse to a single peer-group total.** Only `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` peer-groups tied ORDER BY values into one shared cumulative value. For a per-DAY running total on a table that has MULTIPLE rows per day, **pre-aggregate to one-row-per-day FIRST** (a CTE: `SUM(amount) GROUP BY order_date`), then run `SUM(daily_total) OVER (ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` over the one-row-per-day result. See §5 Pattern A / A2 Bucketed running total below for the full ROWS-vs-RANGE worked example + the symptom/cause/fix inoculation. |
| **Share of grand total (percent of total)** | `100.0 * x / SUM(x) OVER ()` (whole-table denominator) or `100.0 * x / SUM(x) OVER (PARTITION BY g)` (per-group denominator) | Express each row as a **percent / fraction of a total** without collapsing rows — e.g., each region's % of company revenue, each product's share of category sales. The **empty `OVER ()`** is the grand total over ALL rows; add `PARTITION BY g` to make the denominator the per-group total. See the dedicated card just below. |
| **Interval-overlap (this H3)** | `calendar c JOIN intervals s ON s.start <= c.day AND (s.end IS NULL OR s.end > c.day) GROUP BY c.day [, dim]` then `COUNT(*)` | Count how many **interval rows** (subscriptions / tickets / sessions / employment) **cover** each calendar day — e.g., active subscribers per day, open tickets per day, concurrent sessions per day. |

If your question reads "what was X **as of** each day d?" think first: is X a VALUE I'm carrying forward (forward-fill), an ACCUMULATION (running total), or a COUNT of intervals covering d (interval-overlap)? The three are not interchangeable.

**Card — share of grand total / percent of total / each row's fraction of the whole (`SUM(x) OVER ()` — empty OVER).** *Keyword anchors:* percent of total, share of grand total, each row as a fraction of the total, ratio to total, % of total revenue, contribution to total, what portion of the total, normalize to total, SUM OVER no partition, empty OVER clause, grand-total denominator, pct of overall. **The one-fact summary.** To put each row's value next to a denominator that is the **grand total across ALL rows** — without a `GROUP BY` that would collapse the rows away — divide by **`SUM(x) OVER ()`**. The **empty `OVER ()`** (no `PARTITION BY`, no `ORDER BY`) makes the window the **entire result set**, so `SUM(x) OVER ()` is the same grand total repeated on every row. Verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): *"All Aggregate functions can be used as window functions by adding the OVER clause. The aggregate function is computed for each row over the rows within the current row's window frame"* — with no partition/order, that frame is the whole set.

```sql
-- Each region's revenue AS A PERCENT of total company revenue (rows preserved).
SELECT
  region,
  revenue,
  ROUND(100.0 * revenue / SUM(revenue) OVER (), 2) AS pct_of_total
FROM iceberg.analytics.region_revenue
ORDER BY pct_of_total DESC;

-- Per-GROUP share: each product's percent of ITS category's total (denominator scoped per category).
SELECT
  category,
  product,
  ROUND(100.0 * sales / SUM(sales) OVER (PARTITION BY category), 2) AS pct_of_category
FROM iceberg.analytics.product_sales;
```

- **`SUM(x) OVER ()` = grand total of `x` over the whole result, repeated on every row.** `SUM(x) OVER (PARTITION BY g)` = the per-`g` subtotal repeated on every row in that group. Pick the empty `OVER ()` for "% of the WHOLE", `PARTITION BY g` for "% within each group".
- **Why `100.0 *` and not `100 *`:** `revenue / SUM(...)` on two integers does **integer division** (truncates to 0). Multiply by the DECIMAL literal `100.0` (or `CAST` the numerator) so the division is done in floating/decimal — see [resource 23 §3 integer-division trap](23-sql-best-practices-olap.md). Wrap in `ROUND(..., 2)` for a clean percentage.
- **Guard against divide-by-zero:** if the total can be 0 (all rows zero / filtered to nothing), wrap the denominator in `NULLIF(SUM(x) OVER (), 0)` so the result is `NULL` instead of an error.
- **Do NOT collapse with `GROUP BY` to get the denominator** and then re-join — the empty-`OVER ()` window computes the grand total inline while keeping every detail row, no self-join needed. (For the grand-total/subtotal ROLLUP report shape — one explicit total ROW, not a per-row percent — see [resource 28 § GROUPING SETS / ROLLUP / CUBE](28-complex-sql-performance-trino-dbt.md) instead.)

##### LEADING CANONICAL — share of a SUBSET over the GRAND TOTAL (final-assembly form — single-pass conditional-SUM / FILTER, no CTE cross-join) (iter636 PIN — FIX-A: subset-share final-assembly column-scope bug)

> **Keyword anchors (READ THIS FIRST if your question contains any of these):** what share of revenue comes from the top quintile · what percent of total revenue comes from the top decile · top 20% revenue as a fraction of all revenue · subset sum over grand total · ratio of a filtered sum to the overall sum · what fraction of total X are Y · percent of total from a subset · share of revenue from the top X% / top N customers / top quintile / top decile / top quartile · how much of total revenue do the top spenders account for · subset/total revenue ratio · share of total contributed by a flagged subset · final assembly of share-from-subset · top_20_revenue / total_revenue.

> **The one-fact summary.** When the question is "**what percent of the TOTAL `X` comes from a SUBSET of the rows** (e.g. top quintile, top decile, churned users, flagged accounts)?", the answer is a single ratio: `SUM(x) over the subset` ÷ `SUM(x) over ALL rows`. The cleanest Trino 467 form is a **single-pass aggregation with TWO aggregates over the SAME row set** — one conditional, one unconditional — in ONE `SELECT`. No CTE, no cross-join, no scope-bug risk.

> **THE CANONICAL — single-pass conditional-SUM (preferred, one query, one scan):**
> ```sql
> -- "What percent of total revenue comes from the top spend quintile?"
> -- ranked_customers has columns: customer_id, total_spend, spend_quintile  (1 = top, 5 = bottom)
> SELECT
>   SUM(CASE WHEN spend_quintile = 1 THEN total_spend ELSE 0 END) * 100.0 / SUM(total_spend) AS pct_from_top_20
> FROM ranked_customers;
> ```
> **Why this is correct (verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html)):** Trino supports multiple aggregate functions in a single `SELECT` over the same row set — the conditional `SUM(CASE WHEN ...)` computes the subset sum (numerator) while the bare `SUM(total_spend)` computes the grand total (denominator), both in one pass over `ranked_customers`. No outer CTE, no scope confusion: `total_spend` is in scope here because it is a base column of the **only** table in the FROM list. The `100.0` (DECIMAL literal) forces decimal division, dodging the integer-division-truncates-to-0 trap.

> **EQUIVALENT — FILTER form (Trino 467 aggregate FILTER clause, same semantics, often more readable):**
> ```sql
> SELECT
>   SUM(total_spend) FILTER (WHERE spend_quintile = 1) * 100.0 / SUM(total_spend) AS pct_from_top_20
> FROM ranked_customers;
> ```
> Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): *"The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause."* `SUM(x) FILTER (WHERE cond)` aggregates only rows where `cond` is true; the parallel bare `SUM(x)` still aggregates ALL rows. Pick whichever reads cleaner — conditional `CASE` shows the bucket logic inline; `FILTER` reads more like the English question.

> **WORKED FULL-PIPELINE (with NTILE direction guardrail — see the PERCENT_RANK / NTILE direction guardrail card at line 1794 of this file).** This is the typical "share of revenue from the top quintile" pipeline end-to-end:
> ```sql
> WITH ranked_customers AS (
>   SELECT
>     customer_id,
>     total_spend,
>     NTILE(5) OVER (ORDER BY total_spend DESC) AS spend_quintile  -- DESC → bucket 1 = TOP spenders
>   FROM iceberg.analytics.customer_revenue
> )
> SELECT
>   SUM(total_spend) FILTER (WHERE spend_quintile = 1) * 100.0 / SUM(total_spend) AS pct_from_top_20
> FROM ranked_customers;
> ```
> One CTE, one final SELECT, two aggregates over the same rows — no cross-join, no aliasing trap.

> **CRITICAL — DO NOT WRITE (the iter635 column-scope bug — re-aggregating a base column that the CTE/subquery did not project):**
>
> | Form | Why it's wrong |
> |---|---|
> | `WITH top_quintile AS (SELECT SUM(total_spend) AS top_20_revenue FROM ranked_customers WHERE spend_quintile = 1) SELECT ROUND(100.0 * top_20_revenue / SUM(total_spend), 2) FROM top_quintile, (SELECT SUM(total_spend) AS total FROM ranked_customers)` | **WRONG — column-resolution error in Trino.** The outer SELECT references `SUM(total_spend)`, but at the outer level **only the projected ALIASES are in scope**: `top_20_revenue` (from the `top_quintile` CTE) and `total` (from the inline subquery). The base column `total_spend` is **NOT visible** at the outer level — neither the CTE nor the inline subquery projects it; both projected only the aggregated alias. Trino raises a column-not-found error at planning time. **The fix is one of two forms:** (a) reference the projected aliases — `100.0 * top_20_revenue / total` (NOT `100.0 * top_20_revenue / SUM(total_spend)`); or (b) **better**, collapse the whole assembly into the single-pass conditional-SUM / FILTER form above — one aggregation, no CTE/cross-join, no scope to get wrong. |
>
> **The general scope rule (universal SQL semantics):** a CTE or subquery in the FROM list exposes to the outer query **only the columns it projects** (the `SELECT` list). Base columns of the underlying tables are NOT carried through — once you aggregate to a single alias, only that alias is visible above. So `SUM(total_spend)` written at the outer level only works if `total_spend` is a column of a table or subquery in the **outer** FROM list — not just a base column buried inside a subquery's source.

> **If you DO split into CTEs (CTE-style assembly — correct form):**
> ```sql
> WITH ranked_customers AS (
>   SELECT customer_id, total_spend, NTILE(5) OVER (ORDER BY total_spend DESC) AS spend_quintile
>   FROM iceberg.analytics.customer_revenue
> ),
> totals AS (
>   SELECT
>     SUM(CASE WHEN spend_quintile = 1 THEN total_spend ELSE 0 END) AS top_20_revenue,
>     SUM(total_spend) AS grand_total
>   FROM ranked_customers
> )
> SELECT ROUND(100.0 * top_20_revenue / grand_total, 2) AS pct_from_top_20
> FROM totals;
> ```
> **Both** the numerator and the denominator are projected by the `totals` CTE — the outer SELECT references the projected aliases `top_20_revenue` and `grand_total`. No re-aggregation of base columns at the outer level, no scope error. (And note: the single-pass form earlier is shorter still; prefer it.)

> **SELECTION CHEAT-SHEET — which subset-share form to write:**
>
> | Shape of the question | Preferred Trino 467 form |
> |---|---|
> | "What percent of total X comes from a single subset (top quintile / flagged / churned)?" — **one scalar answer** | Single-pass: `SUM(x) FILTER (WHERE subset_pred) * 100.0 / SUM(x)` (or the `CASE` equivalent) — ONE row out, ONE scan. |
> | "What percent of total X does EACH bucket contribute?" — **one row per bucket** | `SELECT bucket, SUM(x) * 100.0 / SUM(SUM(x)) OVER () FROM t GROUP BY bucket` — see the per-group share card just above. |
> | "Show every customer with their % of total" — **rows preserved** | `SUM(x) OVER ()` window form (see the share-of-grand-total card just above — empty `OVER ()` keeps detail rows). |
> | "Both the per-bucket totals AND a grand-total row in one report" | `GROUPING SETS / ROLLUP / CUBE` — see [resource 28 § GROUPING SETS / ROLLUP / CUBE](28-complex-sql-performance-trino-dbt.md). |

> **Cross-references.** Direction-of-NTILE guardrail (which bucket is "top"?) — see the PERCENT_RANK / NTILE direction guardrail at r07 line 1794 (bucket 1 under DESC = top, bucket 1 under ASC = bottom). Integer-division trap (`100 *` vs `100.0 *`) — see [resource 23 §3 integer-division trap](23-sql-best-practices-olap.md) and the bullet just above on this card. Divide-by-zero guard — wrap the denominator in `NULLIF(SUM(x), 0)` if the table can be empty. Per-row share (every detail row tagged with its % of total) — use the `SUM(x) OVER ()` empty-window form on the card just above, NOT this final-assembly form (which collapses to a single scalar).

**Perf note (alternative for very large interval tables — boundary-event cumulative form).** When the intervals table is enormous and the calendar × intervals cross-product is too big, switch to the boundary-event form: emit `+1` at each `start` and `-1` at each `end` as separate rows on the EVENT day, then a running `SUM(delta) OVER (ORDER BY event_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` over the event-day union gives the concurrently-active count without ever materializing a (day × interval) join. This scales linearly in (# intervals) rather than (# days × # intervals). Use it as a perf alternative; the range-join form above is correct and clear for typical SaaS sizes — don't over-engineer.

**Cross-references.** Reuse the bounds-CTE + `sequence()` + `CROSS JOIN UNNEST` spine from the COMBINED CANONICAL composition card above (same dynamic-bounds spine, different downstream operation: instead of LEFT JOIN + forward-fill, do INNER JOIN with interval-overlap predicate). The "WHEN to use INNER vs LEFT" rule comes from § 1a.5 — INNER drops days/plans with zero active intervals; LEFT JOIN + `COALESCE(active_count, 0)` keeps a row for every `(day, plan)` even when zero. The range-join + inequality predicate uses no special Trino syntax — it is a plain INNER JOIN with inequality predicates in the ON clause, fully supported in Trino 467 (the planner recognizes range/inequality joins and applies sort-merge or nested-loop strategies; see the Trino window-functions / select docs for the underlying join grammar).

`date_trunc('day' | 'week' | 'month', col)` is the Trino function you'll use constantly. It rounds a timestamp down to the start of a bucket. **Return type — same as input** (per [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): `date_trunc(unit, x) -> [same as input]`): `timestamp -> timestamp`, `timestamp(p) with time zone -> timestamp(p) with time zone`, `date -> date`, `time -> time`. It does **NOT** convert to DATE — `date_trunc('day', some_timestamp)` returns a `timestamp` at midnight, not a `date`. If you need the result as a DATE, wrap in `CAST(... AS DATE)` explicitly.

#### LEADING CANONICAL — round / snap a timestamp to the NEAREST hour (FLOOR vs NEAREST vs CEILING — three distinct idioms, do NOT confuse) (iter631 PIN)

> **Keyword anchors (READ THIS FIRST if your question contains any of these):** round a timestamp to the nearest hour · snap a timestamp to the nearest hour · nearest whole hour · closest hour boundary · round to the nearest hour not just cut off the minutes · snap event time to the closest whole hour for an hourly chart · 4:12 -> 4:00 · 4:48 -> 5:00 · round to nearest hour Trino · which hour is closer · nearest-hour rounding · half-up to nearest hour · round timestamp to closest hour bucket.

> **The pitfall in one sentence.** "Round to the nearest hour" is **NOT** the same as `date_trunc('hour', ts)` (which FLOORS — always drops the minutes), and it is **NOT** the same as "round UP to the next hour" (which CEILINGS — always pushes forward when not on the hour). NEAREST chooses whichever hour boundary (previous or next) is closer to `ts`: `4:12 -> 4:00`, `4:48 -> 5:00`, `2:30:00 -> 3:00` (the half-hour tie rounds UP because `add-30-min then floor` lands on the next hour). Picking the wrong one silently corrupts hourly charts: a 2:15 event lands on 3:00 instead of 2:00.

> **The three idioms — pick the one that matches the question:**
>
> | Idiom | Trino 467 expression | Behavior — examples |
> |---|---|---|
> | **FLOOR** (drop the minutes; round DOWN to start of hour) | `date_trunc('hour', ts)` — see the existing FLOOR canonical immediately above. | `2:47 -> 2:00`; `2:15 -> 2:00`; `2:00 -> 2:00`. |
> | **NEAREST** (snap to the closer hour boundary — what people usually mean by "round to the nearest hour") | `date_trunc('hour', ts + INTERVAL '30' MINUTE)` | `2:47 -> 3:00` (`2:47 + 0:30 = 3:17`, floors to `3:00`); `2:15 -> 2:00` (`2:15 + 0:30 = 2:45`, floors to `2:00`); `4:12 -> 4:00`; `4:48 -> 5:00`; `3:00:00 -> 3:00` (on-the-hour input is unchanged); `2:30:00 -> 3:00` (half-hour tie rounds UP). |
> | **CEILING** (round UP to the next hour — use ONLY when the question explicitly says "round up") | `date_trunc('hour', ts - INTERVAL '1' SECOND) + INTERVAL '1' HOUR` | `2:47 -> 3:00`; `2:15 -> 3:00`; `2:00:00 -> 2:00` (exact-on-the-hour stays on the hour — `ts - 1s = 1:59:59`, floors to `1:00`, plus 1 hour = `2:00`). Sub-second precision: if `ts` can carry milliseconds (e.g. `2:00:00.500`), you may need `INTERVAL '1' MILLISECOND` instead of `INTERVAL '1' SECOND` to keep exact-on-the-hour values pinned. |

> **NEAREST — one fact + worked SQL.** Add 30 minutes, then floor to the hour: an event that is **MORE THAN** 30 minutes past the previous hour gets pushed into the next hour by the `+30` shift; an event that is **LESS THAN** 30 minutes past the previous hour does NOT cross the next hour boundary even after the shift, so it stays floored at the previous hour.
>
> ```sql
> SELECT date_trunc('hour', event_ts + INTERVAL '30' MINUTE) AS nearest_hour_bucket,
>        COUNT(*) AS events
> FROM iceberg.analytics.user_events
> WHERE event_ts >= current_timestamp - INTERVAL '1' DAY
> GROUP BY date_trunc('hour', event_ts + INTERVAL '30' MINUTE)
> ORDER BY nearest_hour_bucket;
> ```
> **Why this works (verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html)):** (a) `date_trunc('hour', x)` floors to the start of the hour (docs example: `2001-08-22 03:04:05.321` truncates to `2001-08-22 03:00:00.000`); (b) `timestamp + INTERVAL '30' MINUTE` is valid timestamp + interval arithmetic — the docs operator examples confirm this pattern (`timestamp '2012-08-08 01:00' + interval '29' hour` returns `2012-08-09 06:00:00.000`); (c) Trino interval-literal syntax is **`INTERVAL '<number-as-string-literal>' <UNIT-keyword>`** — the number is SINGLE-QUOTED, the unit is an unquoted keyword. **DO NOT** write Postgres-style `INTERVAL '30 minutes'` (number AND unit inside one string) — that is a parse error in Trino 467.

> **CRITICAL — DO NOT WRITE (the iter630 ceiling trap, banned for NEAREST):**
>
> | Form | Why it's wrong for NEAREST |
> |---|---|
> | `date_trunc('hour', ts) + CASE WHEN minute(ts) > 0 OR second(ts) > 0 THEN INTERVAL '1' HOUR ELSE INTERVAL '0' HOUR END` | **WRONG for NEAREST — this is CEILING / round-UP.** It pushes EVERY off-the-hour timestamp into the NEXT hour regardless of whether the previous hour is closer. **Mis-rounds `2:15 -> 3:00` (NEAREST is `2:00`, because 2:15 is only 15 min past 2:00 and 45 min before 3:00).** Mis-rounds `4:12 -> 5:00` (NEAREST is `4:00`). The CASE form only happens to be correct when the input is already past the half-hour mark (e.g. `2:47 -> 3:00`); for any input in the first half of an hour it gives the wrong bucket. If you really want round-UP, label it CEILING (third row of the table above) and use the documented `+ INTERVAL '1' HOUR` form; for NEAREST, **always** use the `date_trunc('hour', ts + INTERVAL '30' MINUTE)` add-30-then-floor form. |

> **Cross-references.** FLOOR canonical = the `date_trunc('hour', col)` paragraph immediately above this block (returns same type as input — drops minutes/seconds, does not round). N-minute (5 / 10 / 15 / 30) sub-hour bucketing — see the LEADING CANONICAL immediately BELOW (`date_trunc` has no sub-hour custom unit; floor-to-hour + add-integer-N-minute-steps arithmetic). The interval-literal syntax pin (`INTERVAL '30' MINUTE` not `INTERVAL '30 minutes'`) is the same form used everywhere in this file's date arithmetic; the `date_add('minute', n, ts)` function form (see the `date_add` block further down) accepts a column/variable n where INTERVAL needs a literal — but for the fixed-30 NEAREST recipe, the `+ INTERVAL '30' MINUTE` literal form is the most readable.

#### LEADING CANONICAL — N-minute (5 / 10 / 15 / 30-minute) timestamp buckets — `date_trunc` has NO sub-hour custom unit, use arithmetic (iter606 PIN)

> **Keyword anchors (READ THIS FIRST if your question contains any of these):** 5-minute buckets · 10-minute buckets · 15-minute windows · 30-minute buckets · N-minute buckets · bucket timestamps into X-minute windows · group events every 5 minutes · finer than hourly · sub-hour time buckets · truncate timestamp to 15 minutes · floor timestamp to nearest 5 minutes.

> **One fact.** `date_trunc(unit, ts)` supports only **FIXED units** — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): the units are `millisecond`, `second`, `minute`, `hour`, `day`, `week`, `month`, `quarter`, `year`. There is **NO `'5 minute'` / `'15 minute'` unit** — Trino raises an error if you pass one. So a custom sub-hour bucket (every 5 / 10 / 15 / 30 minutes) needs a little **arithmetic**: floor to the start of the hour, then add back the whole number of N-minute steps that have elapsed in that hour.

> **THE CANONICAL — 5-minute buckets shown EXACTLY (copy this; replace `5` with `10` / `15` / `30` for other bucket sizes):**
> ```sql
> date_trunc('hour', event_ts)
>   + INTERVAL '1' MINUTE * (CAST(EXTRACT(minute FROM event_ts) AS integer) / 5 * 5)
> ```
> Integer division **floors to the bucket boundary**: e.g. minute `37` → `37 / 5 * 5 = 35`, so `12:37:48` buckets to `12:35:00`. (Integer division truncates toward zero — verified at [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html): *"Division (integer division performs truncation)"* — and minutes are always non-negative, so truncation = floor here.) Replace `5` with `10`, `15`, or `30` for those bucket sizes; the `/ N * N` integer-division idiom floors to the nearest lower N-minute boundary.

> **CRITICAL inoculation — NO `::` cast in Trino.** Trino 467 has **NO `::` cast shorthand** — that is **PostgreSQL**. `EXTRACT(minute FROM ts)::int` is a **PARSE ERROR** in Trino. Always write `CAST(EXTRACT(minute FROM ts) AS integer)`. The cast form is verified at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) (`cast(value AS type) → type`; the `::` operator is **not** in Trino at all). Note `EXTRACT(minute FROM ts)` already returns **BIGINT** (verified same datetime page: *"extract(field FROM x) → bigint"*), so the explicit cast is only needed if you specifically want INTEGER — and `EXTRACT(minute FROM ts) % 5` (the modulo form) works **directly without any cast**.
>
> | | |
> |---|---|
> | **WRONG ❌ (PostgreSQL `::` — parse error in Trino)** | `EXTRACT(minute FROM ts)::int` |
> | **RIGHT ✅ (Trino CAST form)** | `CAST(EXTRACT(minute FROM ts) AS integer)` |

> **Equivalent documented form (if you prefer `date_add` over `INTERVAL '1' MINUTE * n`):** `date_add('minute', CAST(EXTRACT(minute FROM event_ts) AS integer) / 5 * 5, date_trunc('hour', event_ts))` — `date_add(unit, value, timestamp)` is the explicitly-documented add-an-interval function ([trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): *"Adds an interval `value` of type `unit` to `timestamp`"*). Both forms produce the same 5-minute floor; pick whichever reads cleaner.

> **Worked GROUP BY (5-minute event counts — repeat the full expression in GROUP BY, no alias per Trino #16533):**
> ```sql
> SELECT date_trunc('hour', event_ts)
>          + INTERVAL '1' MINUTE * (CAST(EXTRACT(minute FROM event_ts) AS integer) / 5 * 5) AS bucket_5min,
>        COUNT(*) AS events
> FROM iceberg.analytics.user_events
> WHERE event_ts >= current_timestamp - INTERVAL '1' DAY
> GROUP BY date_trunc('hour', event_ts)
>          + INTERVAL '1' MINUTE * (CAST(EXTRACT(minute FROM event_ts) AS integer) / 5 * 5)
> ORDER BY bucket_5min;
> ```

#### `date_trunc('week', ts)` ALWAYS starts the week on MONDAY (ISO-8601) — Trino canonical (iter536 PIN) + `day_of_week()` / `EXTRACT(DAY_OF_WEEK)` ALWAYS ISO 1..7 (Mon..Sun) — **NO `dayname()` in Trino**, NO Postgres `0=Sunday` convention (iter665 FIX-A — busiest-weekday-per-user inoculation)

> **Keyword anchors for this block (READ FIRST if your question contains ANY of these):** date_trunc week Monday, Trino week start day, weekly report week start, ISO week Trino, day_of_week Monday, Sunday vs Monday week, first day of week Trino, beginning of week Trino, European Monday week start, US Sunday week start, **busiest weekday per user, day of week they order most, which weekday, day-of-week, weekday name, name of the weekday, busiest weekday by name, day_of_week returns 0 or 1, EXTRACT(DOW) Trino value, EXTRACT(DAY_OF_WEEK) Trino value, dayname Trino, dayname function, get weekday name Trino, Monday Tuesday Sunday string from date, format weekday as name, format_datetime EEEE weekday**.

> **TRUTH 1 — `date_trunc('week', ts)` is Monday-start (ISO-8601), verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html).** Trino's `date_trunc('week', ts)` **always** starts the week on **MONDAY**. There is **NO Sunday-start option**, **NO locale setting**, and **NO `first_day_of_week` configuration** in Trino. A European Monday-start weekly-report requirement is met by the **bare** `date_trunc('week', ts)` function with **NO workaround at all**.

> **TRUTH 2 — `day_of_week(ts)` AND `EXTRACT(DAY_OF_WEEK FROM ts)` BOTH return ISO `1` = Monday .. `7` = Sunday — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) (*"Returns the ISO day of the week from `x`. The value ranges from `1` (Monday) to `7` (Sunday)."*).** `EXTRACT(DOW FROM ts)` **also parses in Trino** (`DOW` is the documented alias for `DAY_OF_WEEK` — see the EXTRACT supported-fields list at [resource 23 § EXTRACT-EPOCH canonical](23-sql-best-practices-olap.md#leading-canonical--postgress-extractepoch-from-ts-does-not-work-in-trino-use-to_unixtimets) line 1179 and [resource 13 § Trino EXTRACT supported fields](13-postgres-to-iceberg-ingestion.md) line 5677), **but it returns the SAME ISO 1..7 range** — it does **NOT** flip to the Postgres `0=Sunday..6=Saturday` convention just because the alias matches. **All three forms — `day_of_week(ts)`, `EXTRACT(DAY_OF_WEEK FROM ts)`, `EXTRACT(DOW FROM ts)` — return ISO 1..7 with Monday = 1 and Sunday = 7 in Trino 467.** Period.
>
> > **DO NOT WRITE — the Postgres `0=Sunday` carryover (the iter664 Q3 dialect leak):**
> >
> > | Wrong claim (Postgres carryover) | Correct Trino 467 fact |
> > |---|---|
> > | *"`day_of_week()` returns `0` = Sunday .. `6` = Saturday."* | **FALSE — that is the PostgreSQL `EXTRACT(DOW FROM ts)` convention.** Trino's `day_of_week(ts)` returns ISO `1` (Monday) .. `7` (Sunday) — there is **NO `0` value, ever**. |
> > | *"`EXTRACT(DOW FROM ts)` returns `0..6` with `0=Sunday` in Trino like it does in Postgres."* | **FALSE.** `DOW` parses in Trino as an alias for `DAY_OF_WEEK`, but Trino returns the **ISO `1..7` range** — Monday = 1, Sunday = 7. The Postgres `0=Sunday` semantics do **NOT** apply in Trino regardless of which alias you use. |
> > | *"To check for Sunday, use `day_of_week(ts) = 0`."* | **FALSE — that condition matches NOTHING in Trino** (the function never returns `0`). To check for Sunday in Trino, write `day_of_week(ts) = 7`. To check for Monday, write `day_of_week(ts) = 1`. |
> > | *"Trino has a `dayname(ts)` function that returns `'Monday'` / `'Tuesday'` / ... `'Sunday'`."* | **FALSE — `dayname()` does NOT exist in Trino 467.** Calling `dayname(ts)` raises `Function 'dayname' not registered`. Do NOT introduce it with hedges like *"if available"* / *"if your Trino has it"* — it is **definitely not** in the language. The correct weekday-name idiom is **`format_datetime(CAST(ts AS timestamp), 'EEEE')`** — see TRUTH 3 below. |

> **TRUTH 3 — for the weekday NAME (`'Monday'` .. `'Sunday'`) use `format_datetime(CAST(order_date AS timestamp), 'EEEE')`.** Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): *"`format_datetime(timestamp, format) → varchar` — Formats `timestamp` as a string using `format` … compatible with JodaTime's `DateTimeFormat` pattern format."* The Joda pattern `'EEEE'` (four-letter `E`) yields the **full English weekday name** (`'Monday'`, `'Tuesday'`, ..., `'Sunday'`); the three-letter `'EEE'` yields the short form (`'Mon'`, `'Tue'`, ..., `'Sun'`). Two pins on this idiom:
>
> 1. **`format_datetime` requires a `TIMESTAMP` input — CAST a `DATE` first** (the docs signature is typed `timestamp`, not `date`; passing a bare `DATE` raises a function-resolution error — see [resource 23 § format-vs-format_datetime block](23-sql-best-practices-olap.md) line 401). Write `format_datetime(CAST(order_date AS timestamp), 'EEEE')`, **not** `format_datetime(order_date, 'EEEE')`.
> 2. **`CAST(day_of_week(ts) AS VARCHAR)` yields the NUMBER `'1'`..`'7'`, NOT the name `'Monday'`..`'Sunday'`.** This is one of the most common day-of-week traps: a junior engineer wants the name, sees `day_of_week` returns an integer, and casts to VARCHAR — getting back the string `'1'` instead of `'Monday'`. **To produce the NAME, use `format_datetime(CAST(ts AS timestamp), 'EEEE')` — NOT `CAST(day_of_week(ts) AS VARCHAR)` and NOT `CAST(EXTRACT(DAY_OF_WEEK FROM ts) AS VARCHAR)`.** The CAST-of-an-integer route gives only the number as text.

> **Worked example (numbers).** `DATE '2020-01-01'` is a **Wednesday**. `date_trunc('week', DATE '2020-01-01')` returns `2019-12-30`, which is the **Monday** of that week. `day_of_week(DATE '2019-12-30')` returns `1` (Monday). `day_of_week(DATE '2020-01-01')` returns `3` (Wednesday). `day_of_week(DATE '2020-01-05')` returns `7` (Sunday — end of the ISO week). `EXTRACT(DAY_OF_WEEK FROM DATE '2020-01-05')` and `EXTRACT(DOW FROM DATE '2020-01-05')` both also return `7` — same ISO convention.

> **Worked example (NAMES — for a "weekday by name" report).** `format_datetime(CAST(DATE '2020-01-01' AS timestamp), 'EEEE')` returns `'Wednesday'`. `format_datetime(CAST(DATE '2020-01-05' AS timestamp), 'EEEE')` returns `'Sunday'`. Compare: `CAST(day_of_week(DATE '2020-01-05') AS VARCHAR)` returns the string `'7'` — NOT `'Sunday'`. Always use `format_datetime(..., 'EEEE')` for the **name**; use `day_of_week(...)` (or `EXTRACT(DAY_OF_WEEK FROM ...)`) for the **sortable 1..7 number**.

> **Worked pattern — BUSIEST WEEKDAY PER USER (iter665 FIX-A — landing point for "which day of the week does each user order most?" / "busiest weekday per user" / "name of the weekday with the most orders per user").** The structural primitive is **ROW_NUMBER top-1-per-group** ([resource 23 §3.1G ROW_NUMBER = 1 / top-1-per-group canonical](23-sql-best-practices-olap.md#31g-trino-has-no-distinct-on--use-row_number--1-or-max_by-for-one-row-per-group) at line 885), and the per-user weekday counts must be built in a CTE FIRST because a direct `MAX(COUNT(*))` is a **nested-aggregate parse error** in Trino (see the iter573 PIN at [r07:999](#) above: *"GROUP BY clause cannot contain aggregations, window functions or grouping operations"* — the same rule covers `MAX(COUNT(*))`, `AVG(COUNT(...))`, and any aggregate-of-aggregate). To **show the weekday NAME** in the output, carry `format_datetime(CAST(order_date AS timestamp), 'EEEE')` through the per-user GROUP BY (TRUTH 3 above — do NOT use `CAST(day_of_week(...) AS VARCHAR)`).
>
> ```sql
> -- Trino 467 — busiest weekday PER USER, with the weekday NAME ('Monday'..'Sunday').
> -- Step 1 (CTE): per-user per-weekday order counts.
> -- Step 2 (CTE): ROW_NUMBER top-1-per-user (PARTITION BY user_id ORDER BY order_count DESC).
> -- Step 3 (outer): WHERE rn = 1 picks each user's single busiest weekday.
> WITH per_user_weekday AS (
>   SELECT user_id,
>          day_of_week(order_date)                                       AS dow,         -- ISO 1..7 (Mon..Sun) — the sortable number
>          format_datetime(CAST(order_date AS timestamp), 'EEEE')        AS weekday_name, -- 'Monday'..'Sunday' — the NAME
>          COUNT(*)                                                      AS order_count
>   FROM iceberg.analytics.orders
>   GROUP BY user_id,
>            day_of_week(order_date),
>            format_datetime(CAST(order_date AS timestamp), 'EEEE')
> ),
> ranked AS (
>   SELECT user_id, dow, weekday_name, order_count,
>          ROW_NUMBER() OVER (PARTITION BY user_id
>                             ORDER BY order_count DESC, dow ASC) AS rn   -- secondary dow tiebreaker for determinism
>   FROM per_user_weekday
> )
> SELECT user_id, weekday_name, order_count
> FROM ranked
> WHERE rn = 1
> ORDER BY user_id;
> ```
>
> **DO NOT WRITE for the busiest-weekday-per-user shape:**
> 1. **`SELECT user_id, MAX(COUNT(*)) FROM orders GROUP BY user_id, day_of_week(order_date)`** — **nested-aggregate parse error** in Trino. `MAX(COUNT(*))` puts an aggregate inside an aggregate. Fix: build per-user-per-weekday counts in a CTE first, then aggregate or rank in the outer query (see r07:999 iter573 PIN and the worked pattern above).
> 2. **`SELECT user_id, CAST(day_of_week(order_date) AS VARCHAR) AS busiest_day_name ...`** — yields `'1'`..`'7'`, **NOT** `'Monday'`..`'Sunday'`. Use `format_datetime(CAST(order_date AS timestamp), 'EEEE')` for the name (TRUTH 3 above).
> 3. **`... CASE WHEN day_of_week(order_date) = 0 THEN 'Sunday' ...`** — `day_of_week()` **never returns `0`** in Trino. That branch is dead code and you will be missing the actual Sunday rows (which return `7`). Either map `1..7` via `CASE` (Option A in the ORDER-BY block below), or use `format_datetime(..., 'EEEE')` (TRUTH 3 — preferred for the name).
> 4. **`dayname(order_date)` with a hedge like "if your Trino version supports it"** — `dayname()` does **NOT** exist in Trino 467. There is no version to fall back to. Use `format_datetime(CAST(order_date AS timestamp), 'EEEE')`.

> **Cross-references.** [Resource 23 §3.1G ROW_NUMBER = 1 / top-1-per-group canonical](23-sql-best-practices-olap.md#31g-trino-has-no-distinct-on--use-row_number--1-or-max_by-for-one-row-per-group) at line 885 — the structural primitive for "single busiest X per Y" (busiest weekday per user, busiest hour per device, most-ordered product per customer). The iter573 PIN at [r07:999](#do-not-group-by-an-aggregate-when-building-the-spine--its-a-parse-error-iter573-pin) — the nested-aggregate / GROUP-BY-aggregate-ban canonical that covers `MAX(COUNT(*))` and `AVG(COUNT(...))`. The ORDER-BY-validity block immediately below — for sorting grouped weekday-NAME rows into chronological (Mon..Sun) order rather than alphabetic.

> #### ORDER-BY validity in a GROUP BY query — sorting grouped WEEKDAY-NAME (or MONTH-NAME) rows into CHRONOLOGICAL (non-alphabetic) order — three valid options + the iter660 Q2 silent-wrong bug (iter661 PIN — FIX-A)
>
> **Keyword anchors for this block (route here on any of these):** `order by weekday number to sort Mon to Sun`, `ORDER BY in a GROUP BY query`, `sort grouped weekday name chronologically`, `sort weekday name Monday to Sunday not alphabetical`, `sort weekday name in calendar order`, `sort month name in calendar order`, `sort month name January to December not alphabetical`, `order by ungrouped column error in ORDER BY`, `must be an aggregate expression or appear in GROUP BY in ORDER BY`, `ORDER BY day_of_week with GROUP BY weekday name`, `revenue by weekday name in calendar order`, `weekday revenue Mon to Sun order`, `format_datetime EEEE chronological sort`, `month name chronological sort GROUP BY`, `ORDER BY raw column not in GROUP BY`.
>
> **The one-fact lead — docs-verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html).** When a query has a `GROUP BY` clause, **every `ORDER BY` expression must also be a GROUPING column/expression, an AGGREGATE function, or a SELECT-list output alias / ordinal number** — the same docs rule that constrains the SELECT list (*"When a `GROUP BY` clause is used in a `SELECT` statement all output expressions must be either aggregate functions or columns present in the `GROUP BY` clause"*) extends to `ORDER BY` because `ORDER BY` operates on the rows produced AFTER `GROUP BY`. **You canNOT `ORDER BY` a raw ungrouped column — even when it is wrapped in a function** (e.g. `ORDER BY day_of_week(order_date)` when only `format_datetime(order_date, 'EEEE')` is in the `GROUP BY`). Trino raises: *"`order_date` must be an aggregate expression or appear in `GROUP BY` clause"*. The wrapping function does NOT make the column legal — the analyzer looks through the function and sees the bare ungrouped column underneath.
>
> **Why this hits the weekday/month-NAME report.** The natural output column is the **name** (`'Monday'`, `'Tuesday'`, ..., `'Sunday'` — or `'January'`...`'December'`) because that is what the report reads cleanly. But sorting alphabetically gives `Friday, Monday, Saturday, Sunday, Thursday, Tuesday, Wednesday` — chaotic. The fix is to either GROUP BY the **sortable number** alongside the name, or aggregate-wrap the sort key. Three valid options follow.
>
> **OPTION A — GROUP BY the sortable NUMBER (and map number→name via `CASE`).** Group by `day_of_week(order_date)` (returns ISO 1=Mon..7=Sun); project the name with a `CASE`; `ORDER BY` the same `day_of_week(order_date)` expression — now legal because it IS a grouping expression. This is the cleanest shape for the weekday-name report.
>
> ```sql
> -- Trino 467 — revenue per weekday name, sorted Mon..Sun (calendar order, not alphabetic).
> -- GROUP BY day_of_week(order_date) -> the sort key IS a grouping expression -> ORDER BY it is legal.
> SELECT day_of_week(order_date) AS dow,                       -- 1..7 (Mon..Sun) — the sortable key
>        CASE day_of_week(order_date)
>             WHEN 1 THEN 'Monday'    WHEN 2 THEN 'Tuesday'
>             WHEN 3 THEN 'Wednesday' WHEN 4 THEN 'Thursday'
>             WHEN 5 THEN 'Friday'    WHEN 6 THEN 'Saturday'
>             WHEN 7 THEN 'Sunday'  END                AS day_name,
>        SUM(amount)                                   AS revenue
> FROM iceberg.analytics.orders
> GROUP BY day_of_week(order_date)
> ORDER BY day_of_week(order_date);                            -- legal: grouping expression
> ```
>
> Drop the `dow` column from the SELECT if the report should display only the name + revenue — `ORDER BY day_of_week(order_date)` stays valid either way (the ORDER BY references the grouping expression, not the output alias). For **month name in calendar order**, the same shape works with `month(order_date)` (returns 1..12) as the grouping/sort key and a 12-branch `CASE` mapping to `'January'`..`'December'`.
>
> **OPTION B — Aggregate-wrap the sort key with `min(...)`.** Keep `GROUP BY format_datetime(CAST(order_date AS timestamp), 'EEEE')` (the Joda full-day-name pattern) and `ORDER BY min(day_of_week(order_date))` — `min(...)` is an aggregate, which IS valid in `ORDER BY` of a GROUP BY query. Every row inside a given weekday-name group shares the same `day_of_week(order_date)` value (every Monday row has `day_of_week=1`), so `min(day_of_week(order_date))` returns that number — exactly the right sort key.
>
> ```sql
> -- Trino 467 — same report via Joda weekday-name pattern; aggregate-wrap the sort key with min().
> SELECT format_datetime(CAST(order_date AS timestamp), 'EEEE') AS day_name,
>        SUM(amount)                                            AS revenue
> FROM iceberg.analytics.orders
> GROUP BY format_datetime(CAST(order_date AS timestamp), 'EEEE')
> ORDER BY min(day_of_week(order_date));                        -- legal: aggregate over the partition
> ```
>
> `max(day_of_week(order_date))` works identically here (every row in a weekday group ties, so min and max return the same value); `min(...)` is the conventional pick.
>
> **OPTION C — ORDINAL `ORDER BY 1`.** GROUP BY the day_of_week number, project the number first (column 1), then map to the name (column 2). `ORDER BY 1` references the first SELECT-list output column by position — always valid (positional refs are documented in [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): *"each expression may be composed of output columns, or it may be an ordinal number selecting an output column by position, starting at one"*).
>
> ```sql
> -- Trino 467 — ordinal ORDER BY (position 1 = dow column).
> SELECT day_of_week(order_date)                                AS dow,
>        CASE day_of_week(order_date) WHEN 1 THEN 'Monday' WHEN 2 THEN 'Tuesday'
>             WHEN 3 THEN 'Wednesday' WHEN 4 THEN 'Thursday'
>             WHEN 5 THEN 'Friday'    WHEN 6 THEN 'Saturday'
>             WHEN 7 THEN 'Sunday'  END                         AS day_name,
>        SUM(amount)                                            AS revenue
> FROM iceberg.analytics.orders
> GROUP BY day_of_week(order_date)
> ORDER BY 1;                                                   -- legal: ordinal -> output column 1 (dow)
> ```
>
> > **DO NOT WRITE — the EXACT iter660 Q2 bug (silent-wrong / parse-rejected by Trino's analyzer):**
> >
> > ```sql
> > -- WRONG ❌ — order_date is NOT in GROUP BY (only format_datetime(order_date,...) is) and NOT aggregated.
> > -- Trino rejects: "order_date must be an aggregate expression or appear in GROUP BY clause".
> > SELECT format_datetime(CAST(order_date AS timestamp), 'EEEE') AS day_name,
> >        SUM(amount)                                            AS revenue
> > FROM iceberg.analytics.orders
> > GROUP BY format_datetime(CAST(order_date AS timestamp), 'EEEE')
> > ORDER BY day_of_week(order_date);                             -- ❌ raw order_date is ungrouped + unaggregated
> > ```
> >
> > **Why it fails.** The `GROUP BY` contains `format_datetime(order_date, ...)` — only that exact expression. `day_of_week(order_date)` in the `ORDER BY` is a DIFFERENT expression over the same raw `order_date` column; the analyzer looks through `day_of_week(...)` and sees the bare ungrouped `order_date` underneath, which is neither in the GROUP BY nor wrapped in an aggregate. **Fix:** either also `GROUP BY day_of_week(order_date)` (OPTION A — most explicit) OR `ORDER BY min(day_of_week(order_date))` (OPTION B — aggregate-wrap the sort key) OR `GROUP BY 1` + `ORDER BY 1` (OPTION C — ordinal).
>
> **Why this rule is the GROUP-BY-rules-anchor extended to ORDER BY.** See the GROUP-BY-rules anchor at [resource 23 §8 (the "Trino GROUP BY rules" block)](23-sql-best-practices-olap.md#8-filter-with-where-before-group-by-not-having) — Rule 4 in that anchor says *"A SELECT alias may be used in the outer `ORDER BY` (after projection) but NOT in `GROUP BY` / `WHERE` / `HAVING`"*. The flip-side rule (this block) is: **`ORDER BY` may use an output alias / ordinal / aggregate / GROUPING expression, but NOT a raw ungrouped column** — even one wrapped in a function. This is the same query-level invariant (`ORDER BY` references must resolve to either a per-group value or an output column), applied to the weekday/month-name sort-key bug.
>
> **Cross-link:** [Resource 23 §8 GROUP-BY-rules anchor (Trino #16533 SELECT-alias-not-in-GROUP-BY)](23-sql-best-practices-olap.md#8-filter-with-where-before-group-by-not-having); [Resource 23 §LEADING CANONICAL extract-then-count](23-sql-best-practices-olap.md#leading-canonical--extract-then-count-count-per-derived-expression--every-select-column-must-be-either-grouped-or-aggregated--drop--wrap--regroup-the-stray-raw-column-iter647-pin--fix-a-for-the-count-users-per-email-domain-group-by-rule-violation) (the SELECT-side mirror of this ORDER-BY rule — every SELECT column must be GROUPED or AGGREGATED; this block extends it to ORDER BY).

> **Canonical Monday-start weekly bucket (copy-paste this — in-line signal on the line you copy):**
> ```sql
> SELECT date_trunc('week', event_ts) AS week_start,  -- Trino weeks ALWAYS start MONDAY (ISO-8601); no Sunday-start option, no workaround needed
>        COUNT(*) AS weekly_events
> FROM iceberg.analytics.user_events
> WHERE event_ts >= date_add('week', -12, current_date)
> GROUP BY date_trunc('week', event_ts)
> ORDER BY week_start;
> ```

> **DO NOT WRITE (CRITICAL — the iter535 harmful workaround, banned):** `date_trunc('week', event_date + INTERVAL '1' DAY) - INTERVAL '1' DAY` to "force Monday." The bare `date_trunc('week', event_date)` is **already** Monday-start; that interval-shift would **wrongly push the result to SUNDAY-start** (shifting the input forward 1 day means a Sunday input rounds to the NEXT Monday, then -1 day = the previous Sunday — you've built a Sunday-start bucket and labeled it "Monday fix"). Never write this expression as a Monday recipe.

> **The only legitimate use of the +1/-1 INTERVAL shift is to produce SUNDAY-START weeks** (e.g., a US-style report). Frame it that way explicitly:
> ```sql
> -- US Sunday-start week (rare — only when the report spec explicitly demands Sunday).
> -- Trino has NO native Sunday-start option, so shift the input forward 1 day, truncate to Monday, then shift back.
> SELECT date_trunc('week', event_ts + INTERVAL '1' DAY) - INTERVAL '1' DAY AS week_start_sunday,
>        COUNT(*) AS weekly_events
> FROM iceberg.analytics.user_events
> GROUP BY date_trunc('week', event_ts + INTERVAL '1' DAY) - INTERVAL '1' DAY
> ORDER BY week_start_sunday;
> ```
> If the spec says "weekly report" without specifying day, **default to MONDAY** (ISO-8601 / Trino native) — that is what the bare `date_trunc('week', ts)` gives you, and matches Trino's `day_of_week` numbering and the `week(ts)` ISO-week function.

### LEADING CANONICAL — `now()` / `current_timestamp` / `current_date` in Trino (+ Iceberg `timestamptz` is UTC-normalized on storage)

> **Keyword anchors (read this section FIRST if your question contains any of these — GENERIC, NOT Oracle-specific):** is `now()` a Trino function · does Trino have `now` · Trino `now()` · `now()` vs `current_timestamp` · Trino current timestamp function · Trino time functions · `current_date` Trino · `current_time` Trino · `localtimestamp` Trino · session time zone Trino · what time zone does Trino store · Iceberg timestamp storage · `timestamp with time zone` UTC Iceberg · UTC-normalized · stored as UTC · wall-clock timestamp · `AT TIME ZONE` Trino · `timestamp` vs `timestamptz` · timezone aware vs naive Iceberg · **group daily activity by local timezone · group by user's local day · convert UTC to local day for GROUP BY · daily count in US/Eastern · GROUP BY local timezone · bucket events by local day · GROUP BY date_trunc AT TIME ZONE · events stored UTC group by local day · America/New_York daily rollup · daily activity per local day · convert event_ts to local day**.

**Fact 1 — Trino HAS `now()`; it is an ALIAS for `current_timestamp`.** Verified verbatim at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): *"`now() → timestamp(3) with time zone` — This is an alias for `current_timestamp`."* Both return **`TIMESTAMP(3) WITH TIME ZONE`** as of the **start of the query** (every reference inside one query yields the identical value), tied to the **session time zone**. Pick whichever reads better. Companion forms (all session-TZ-aware):
- `current_date` → `DATE` (no time component).
- `current_time` → `TIME WITH TIME ZONE`.
- `localtimestamp` → `TIMESTAMP` (no TZ; session-local wall clock).
- **Syntax pin:** `current_timestamp` / `current_date` / `current_time` / `localtimestamp` take **NO parentheses** (SQL-standard special-form syntax); `now()` takes empty parens. Writing `current_timestamp()` is a parse error.

**Fact 2 — Iceberg STORAGE: `timestamp with time zone` (timestamptz) is UTC-NORMALIZED on disk; bare `timestamp` is wall-clock with NO normalization.** Per the [Iceberg spec](https://iceberg.apache.org/spec/) — verbatim: *"values are stored as UTC and do not retain a source time zone (2017-11-16 17:10:34 PST is stored/retrieved as 2017-11-17 01:10:34 UTC and these values are considered identical)."* A `timestamp(6) with time zone` column stores **microseconds from epoch UTC** — the original session/source zone is **NOT preserved per value**; the value is an INSTANT. A `timestamp(6)` column (WITHOUT time zone) stores wall-clock microseconds with **no UTC normalization** — what you wrote is what comes back. `AT TIME ZONE 'UTC'` / `AT TIME ZONE 'America/New_York'` on a `timestamptz` value **re-labels** the same UTC instant in the target zone — it does NOT change the stored bytes (display re-render only).

**Fact 3 — `GROUP BY` daily activity in a USER'S LOCAL timezone when events are stored as UTC `timestamptz`.** *(iter581 PIN — landing point for "events store UTC, group daily by user's local timezone US/Eastern".)* The canonical Trino 467 idiom is **`date_trunc('day', event_ts AT TIME ZONE 'America/New_York')`** — applied uniformly in both the SELECT list and the GROUP BY. The `AT TIME ZONE 'America/New_York'` re-renders each UTC instant in NYC wall-clock; `date_trunc('day', ...)` then floors to the start of that NYC wall-clock day. Both pieces are verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): the operator example *"`SELECT timestamp '2012-10-31 01:00 UTC' AT TIME ZONE 'America/Los_Angeles'; -- 2012-10-30 18:00:00.000 America/Los_Angeles`"* (same instant, different wall-clock label) and `date_trunc(unit, x) → [same as input]` (so the result of date_trunc on a `timestamp(p) with time zone` is itself `timestamp(p) with time zone` floored to the unit boundary in the local wall-clock). Worked example — daily signup count in US/Eastern over a UTC-stored events table:

```sql
-- Events table: created_at TIMESTAMP(6) WITH TIME ZONE (UTC-normalized on Iceberg disk).
-- Want: count of signups per LOCAL US/Eastern day for the last 30 ET days.
SELECT date_trunc('day', created_at AT TIME ZONE 'America/New_York') AS local_day_et,
       COUNT(*) AS signups
FROM iceberg.analytics.events
WHERE created_at >= date_trunc('day', current_timestamp AT TIME ZONE 'America/New_York') - INTERVAL '30' DAY
GROUP BY date_trunc('day', created_at AT TIME ZONE 'America/New_York')
ORDER BY local_day_et;
```

Notes: (a) **repeat the full expression in `GROUP BY`** — Trino does NOT allow referencing a SELECT-list alias from `GROUP BY` (Trino issue [#16533](https://github.com/trinodb/trino/issues/16533)); (b) IANA zone names (`'America/New_York'`, `'US/Eastern'`, `'Europe/London'`, `'Asia/Tokyo'`) are correct — `'US/Eastern'` is the legacy alias for `'America/New_York'`, both work, prefer the `'America/...'` form for clarity and DST-rule freshness; (c) wrapping the column in `AT TIME ZONE` inside the `GROUP BY` **defeats partition pruning** the same way it does in WHERE (see resource 27 §4.2B caveat + [Trino #12729](https://github.com/trinodb/trino/issues/12729)) — that's why the WHERE clause uses the boundary-literal form on the raw UTC column, while the GROUP BY pays the per-row conversion cost only on the filtered subset; (d) for **the local DATE as a `DATE` value** (not a `timestamp with time zone`), wrap: `CAST(created_at AT TIME ZONE 'America/New_York' AS DATE)` — both `date_trunc('day', ... AT TIME ZONE ...)` and `CAST(... AT TIME ZONE ... AS DATE)` give the same local-day buckets, but the cast returns `DATE` (cleaner for output) while `date_trunc` returns `timestamp with time zone` at midnight ET.

**Gotcha — `AT TIME ZONE` on a BARE `timestamp` (without time zone) ATTACHES the zone, it does NOT convert.** If your column is bare `TIMESTAMP(6)` (no time zone) and you write `event_ts AT TIME ZONE 'America/New_York'`, Trino does NOT subtract 4-5 hours from the wall-clock — it just stamps the existing wall-clock value with the NYC zone label. The Trino docs example illustrates this for `timestamp '2012-10-31 01:00 UTC' AT TIME ZONE 'America/Los_Angeles'` (CONVERT — the input already has UTC); for a BARE timestamp without zone, the SAME wall-clock numbers come out, just tagged with the target zone. So if the table stores UTC-intent in a bare `timestamp` column, you must FIRST attach UTC (`event_ts AT TIME ZONE 'UTC'` — which on a bare timestamp ATTACHES UTC, making it timestamptz at the SAME wall-clock) THEN convert (`AT TIME ZONE 'America/New_York'` — which on a timestamptz CONVERTS): `event_ts AT TIME ZONE 'UTC' AT TIME ZONE 'America/New_York'`. (Or fix the schema to store `TIMESTAMP WITH TIME ZONE` — that's the canonical Iceberg type for instants; see resource 09 §SCD2 default cols and resource 13 §timestamp-type-mapping for the column-type recommendation.) The two-step `AT TIME ZONE 'UTC' AT TIME ZONE '<local>'` chain is the only safe form when the source column is bare `TIMESTAMP` but the values are UTC-intent.

**DO-NOT-WRITE (the load-bearing fab claims to ban):**
- *"Trino has no `now()` function / `now()` is a parse error / function-not-found in Trino."* **FALSE.** `now()` is a documented Trino alias for `current_timestamp`; both work; both return the same value and type.
- *"Iceberg / Trino never normalizes timestamps to UTC on storage — you get back exactly what you stored."* **FALSE for `timestamp with time zone` (timestamptz)** — those values ARE UTC-normalized on disk per the Iceberg spec. The "no normalization" rule applies ONLY to bare `timestamp` (without time zone).
- *"`current_timestamp` and `now()` return different types / different values."* **FALSE.** Identical type (`TIMESTAMP(3) WITH TIME ZONE`), identical value (both pinned to query-start time, session TZ).
- *"`current_date` returns a timestamp."* **FALSE.** It returns `DATE` — no time component. Use `current_timestamp` (or `now()`) when you need hours/minutes/seconds.
- *"`bare_ts AT TIME ZONE 'America/New_York'` converts a UTC-intent bare `timestamp` to NYC local time."* **FALSE.** On a `timestamp` value (no time zone), `AT TIME ZONE` **attaches** the zone label without changing the wall-clock numbers — it does NOT subtract 4-5 hours. To convert UTC-intent bare timestamps to NYC local, chain `bare_ts AT TIME ZONE 'UTC' AT TIME ZONE 'America/New_York'` (first attaches UTC, then converts). Convert applies only when the input is already `timestamp with time zone`.
- *"To `GROUP BY` daily activity in a user's local timezone, write `GROUP BY DATE(event_ts)` or `GROUP BY CAST(event_ts AS DATE)` on a UTC-stored `timestamptz` column."* **FALSE — that gives the UTC day, not the local day.** A user with a 23:30 UTC signup that is actually 18:30 (or 19:30, depending on DST) NYC time lands in the WRONG day. Use `date_trunc('day', event_ts AT TIME ZONE 'America/New_York')` (or `CAST(event_ts AT TIME ZONE 'America/New_York' AS DATE)`) — convert FIRST in the local zone, THEN truncate/cast.

**Cross-references:** Resource 27 §4.2-NOW (the Oracle-migration angle — same two facts, SYSDATE-replacement framing — keep both consistent). Resource 27 §4.2A (the dedicated `SET TIME ZONE` command + `sql.forced-session-time-zone` server property — how to change what zone `current_timestamp` / `now()` use). Resource 27 §4.2B (filtering a `timestamp with time zone` column by a local-date range — boundary-literal form; DO-NOT-WRITE for `AT TIME ZONE >= DATE` and BETWEEN on bare VARCHAR). Resource 13 §timestamp-type-mapping (Postgres `timestamptz` → Iceberg `TIMESTAMP(6) WITH TIME ZONE`). Resource 13 §`from_unixtime` (epoch-seconds-to-timestamp; returns `timestamp(3) with time zone`).

### LEADING CANONICAL — `date_add('unit', n, ts)` for VARIABLE offsets (INTERVAL needs a LITERAL; `date_add` takes a column/expression n)

> **Keyword anchors (read this section FIRST when your question contains any of these — GENERIC, NOT Oracle-specific):** Trino `date_add`, add N days variable Trino, add days from a column Trino, variable date offset Trino, INTERVAL column not literal, INTERVAL with a variable, `INTERVAL n DAY` parse error, `INTERVAL retention_days DAY`, add N hours/months from a column, `date_add('day', col, ts)`, dynamic date offset, parametrized interval, per-row interval offset, can I use a column inside INTERVAL, Trino interval expression.

**The fact in one sentence.** A Trino `INTERVAL` literal **requires a string LITERAL** — `INTERVAL '7' DAY` works, but `INTERVAL n DAY` where `n` is a **column or expression** is a **parse error** (`mismatched input ... expecting <integer literal>`). When the offset comes from a column / variable / Jinja var / parameter, use the function form **`date_add(unit, value, timestamp)`** — the `value` argument accepts any BIGINT expression, including a column reference.

**Signature (verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)):** `date_add(unit, value, timestamp) → [same type as input]`. The docs state: *"Adds an `interval value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value."* Valid `unit` values: `'millisecond'`, `'second'`, `'minute'`, `'hour'`, `'day'`, `'week'`, `'month'`, `'quarter'`, `'year'`. The `value` is BIGINT — pass any integer column or arithmetic expression.

**Worked example — variable retention window per tenant** (the `retention_days` column varies per row, so `INTERVAL` won't compile):

```sql
-- Each tenant has its own retention period stored in tenants.retention_days (INTEGER).
-- "Compute the cutoff timestamp PER TENANT" — the offset is a COLUMN, NOT a literal.
SELECT
  t.tenant_id,
  t.retention_days,
  date_add('day', t.retention_days, t.signup_ts) AS retention_cutoff_ts  -- column n is fine
FROM iceberg.analytics.tenants t;
```

**Contrast — when INTERVAL works and when it doesn't.**

| Form | Compiles? | When to use |
|---|---|---|
| `event_ts + INTERVAL '7' DAY` (literal `'7'`) | YES | The offset is a **constant** known at query-write time. Idiomatic and reads naturally. |
| `event_ts + INTERVAL '30' DAY` (literal `'30'`) | YES | Same — constant. |
| `event_ts + INTERVAL n DAY` (where `n` is a **COLUMN**) | **NO — parse error** | INTERVAL requires the value to be a LITERAL. Switch to `date_add('day', n, event_ts)`. |
| `event_ts + INTERVAL retention_days DAY` (column `retention_days`) | **NO — parse error** | Same as above. |
| `date_add('day', 7, event_ts)` (literal `7`) | YES | Function form; works with both literal and variable n. Equivalent to `INTERVAL '7' DAY`. |
| `date_add('day', n_col, event_ts)` (column `n_col`) | YES | **The canonical form for a variable offset.** |
| `date_add('day', -retention_days, event_ts)` (negate the column for subtraction) | YES | Docs state subtraction is performed by passing a negative value. |
| `date_add('day', {{ var('lookback_days', 30) }}, current_date)` (dbt Jinja var rendered to a literal) | YES | Jinja renders the var BEFORE Trino sees the SQL, so by query time it IS a literal — but `date_add` still works and is the more general form. |

**Why the INTERVAL-literal restriction exists.** Trino's INTERVAL type is parsed at SQL-compile time from a string literal (per the [Trino interval-literal grammar](https://trino.io/docs/current/language/types.html#interval-year-to-month)); there is no syntax for an interval whose magnitude is bound from a column at execution time. The function `date_add` exists exactly to bridge that gap — it accepts the magnitude as a runtime BIGINT.

**DO-NOT-WRITE — banned forms:**

- *"`INTERVAL n DAY` works when `n` is a column."* **FALSE — parse error.** Use `date_add('day', n, ts)` instead.
- *"Trino doesn't support variable date offsets — you have to materialize a separate column per offset value."* **FALSE.** `date_add(unit, value, ts)` accepts any BIGINT expression for `value`, including column references and arithmetic.
- *"`INTERVAL CAST(retention_days AS VARCHAR) DAY`" (string-cast workaround) compiles.* **FALSE.** The INTERVAL grammar wants a STRING LITERAL token at parse time, not a runtime CAST. No string-build trick recovers an interval-from-column — switch to `date_add`.
- *"`date_add` returns a TIMESTAMP regardless of input type."* **FALSE.** The return type matches the input: pass a `DATE`, get `DATE` back; pass `TIMESTAMP WITH TIME ZONE`, get `TIMESTAMP WITH TIME ZONE` back. The signature is `[same type as input]`.

**Cross-references:** Resource 23 §3.x (the date-arithmetic / date_diff family). Resource 27 § ADD_MONTHS-Oracle-migration (Oracle `ADD_MONTHS` → Trino `date_add('month', n, dt)` with the last-day clamp wrapper). Resource 07 § Pattern B2 FORM A YoY (the `date_add('month', -12, cur.month)` pattern for self-join calendar arithmetic). Resource 07 § `sequence()` (the canonical date-spine generator — pair `date_add` with `sequence` when generating per-row offsets in calendar-spine joins).

---

## 5. Window functions (running totals, ranks, lag/lead)

**The SaaS question family:** "Running total of revenue per tenant by day." "Each customer's day-over-day change in MRR." "Top 10 highest-value orders per tenant."

Window functions compute an aggregate or rank **per row** while still returning every input row — unlike `GROUP BY`, which collapses rows. Trino supports the full ANSI SQL window function syntax (documented at https://trino.io/docs/current/functions/window.html).

The general shape:

```sql
<window_function>(<args>) OVER (
  PARTITION BY <columns>     -- buckets the window (per-tenant is typical for SaaS)
  ORDER BY <columns>         -- ordering within each bucket
  [<frame_clause>]           -- which rows in the bucket count for THIS row's result
)
```

### Pattern A: Running total (cumulative sum)

"Cumulative revenue per tenant over time."

```sql
SELECT
  day,
  tenant_id,
  amount,
  SUM(amount) OVER (
    PARTITION BY tenant_id
    ORDER BY day
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_revenue
FROM iceberg.analytics.daily_revenue
WHERE day >= DATE '2026-01-01'
  AND tenant_id = 'acme'
ORDER BY day;
```

Why each piece matters:
- `PARTITION BY tenant_id` — every tenant gets its own running total. Without this, the cumulative sum would mix all tenants together. **Always partition by `tenant_id` for multi-tenant SaaS** so a tenant's window can't see another tenant's data.
- `ORDER BY day` — defines the order in which "previous rows" accumulate.
- `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — the frame clause. "Sum every row from the start of the partition through this row." This is the canonical **positional** running-total frame.
- The `WHERE` clause executes BEFORE the window function, so partition pruning on `day` and `tenant_id` still works on the base scan. Window functions are not a barrier to file skipping — only to the final aggregation phase.

> **The default frame when ORDER BY is present (and you OMIT the frame clause) is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`.** This is value-based and **groups rows with the same ORDER BY value (peers/ties) into the SAME frame** — they all see the same cumulative sum. Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) (ANSI SQL default). If the running total above had two rows with `day = 2026-05-01` for `acme`, writing `SUM(amount) OVER (PARTITION BY tenant_id ORDER BY day)` with NO explicit frame would give BOTH rows the same cumulative value (the sum through end-of-May-1). The explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` form differs: each tied row gets its own positional frame, so the two May-1 rows would show different cumulative values depending on physical row order — which is **non-deterministic** when ORDER BY is non-unique. See the next callout for how to handle ties cleanly.

#### ROWS vs RANGE on tied ORDER BY values — pick the right tool, avoid INTERVAL '0' DAY

`ROWS` and `RANGE` differ in how they handle rows that share the same `ORDER BY` value ("peers"). Get this wrong on a non-unique ORDER BY (e.g., two events on the same day) and the same query returns different numbers on different runs because Trino is free to order tied rows arbitrarily.

| Frame form | Peer semantics | Determinism on non-unique ORDER BY |
|---|---|---|
| `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (positional) | Each tied row gets its OWN frame — the running total visibly increments across peers. | **Non-deterministic** order-among-peers. Tied row that "sorts first" gets the smaller value; the other gets the larger. The choice is arbitrary unless you add a tiebreaker. |
| `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (value-based, **also the default when ORDER BY is present and no frame is specified**) | All tied rows share ONE frame — they all see the same cumulative value (sum through the end of the peer group). | **Deterministic** by definition — the answer doesn't depend on intra-peer ordering. |
| `RANGE BETWEEN INTERVAL '0' DAY PRECEDING AND CURRENT ROW` | Same as the default RANGE — peers share one frame. | Deterministic, but **REDUNDANT** — Trino's default RANGE frame already includes peers; spelling it out as `INTERVAL '0' DAY PRECEDING` adds no semantic information. **Avoid this idiom.** |

> **GUARDRAIL — do NOT write `RANGE BETWEEN INTERVAL '0' DAY PRECEDING AND CURRENT ROW` as a tie-handling fix.** It is syntactically valid in Trino (`RANGE` value-based frames support `INTERVAL` offsets since Trino release 346, per the [March 2021 window-features blog](https://trino.io/blog/2021/03/10/introducing-new-window-features.html)) but semantically REDUNDANT — it produces the SAME result as the default RANGE frame (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`). The cleaner patterns are below.

**Two CORRECT patterns for deterministic running totals — pick one based on intent:**

**Pattern 1 (preferred when peer semantics are what you want): rely on the default RANGE frame.** Omit the frame clause entirely and Trino applies `RANGE UNBOUNDED PRECEDING TO CURRENT ROW` — peers share a single value, no determinism question to answer.

```sql
-- Two events on 2026-05-01 → both rows show the SAME cumulative value through end of May 1.
-- No frame clause → default RANGE, deterministic across ties, peer-correct.
SELECT
  day,
  tenant_id,
  amount,
  SUM(amount) OVER (
    PARTITION BY tenant_id
    ORDER BY day
    -- no frame → default RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_revenue
FROM iceberg.analytics.daily_revenue
WHERE day >= DATE '2026-01-01' AND tenant_id = 'acme'
ORDER BY day;
```

**Pattern 2 (preferred when you need positional row-by-row accumulation): add a UNIQUE tiebreaker to ORDER BY and keep `ROWS`.** Pick a column guaranteed to be distinct within the partition (`event_id`, a UUID, a serial, or a `(day, event_id)` tuple). Now `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is deterministic because there are no peers to tie.

```sql
-- Tiebreaker `event_id` makes the ORDER BY unique → ROWS frame is deterministic.
-- Each row gets its own cumulative value even when multiple rows share `day`.
SELECT
  day,
  event_id,
  tenant_id,
  amount,
  SUM(amount) OVER (
    PARTITION BY tenant_id
    ORDER BY day, event_id            -- unique tuple eliminates peers
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_revenue
FROM iceberg.analytics.revenue_events
WHERE day >= DATE '2026-01-01' AND tenant_id = 'acme'
ORDER BY day, event_id;
```

**Decision rule:**
- "Two events on the same day should report the same cumulative value" → **Pattern 1 (default RANGE)** — peer semantics are exactly what you want.
- "Each event needs its own cumulative value even on tied days" → **Pattern 2 (unique tiebreaker + ROWS)** — make ORDER BY unique, keep ROWS.
- **Never** reach for `RANGE BETWEEN INTERVAL '0' DAY PRECEDING AND CURRENT ROW` — it expresses Pattern 1's semantics with more syntax and no benefit; either omit the frame or use the unique-tiebreaker form.

This is distinct from Pattern D below (`RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW`) — there the non-zero `INTERVAL '6' DAY` actually does work (it defines a calendar-aware sliding window). The redundancy only applies to the **zero-width** `INTERVAL '0' DAY` case, which collapses to the default RANGE frame.

#### ROWS vs RANGE — worked numeric example (transcribe this table)

Same query shape: `SUM(amt) OVER (ORDER BY order_date <FRAME>)`. Four rows with a deliberate **gap on Jan-03** and **tied peers on Jan-01** so both axes show. Verified at [trino.io/blog/2021/03/10/introducing-new-window-features.html](https://trino.io/blog/2021/03/10/introducing-new-window-features.html): *"When using CURRENT ROW in a RANGE frame, it includes all rows where values of the sort key are the same as in the current row, which are called a peer group."*

| # | order_date | amt | `ROWS BETWEEN 1 PRECEDING AND CURRENT ROW` | `RANGE BETWEEN INTERVAL '1' DAY PRECEDING AND CURRENT ROW` |
|---|---|---|---|---|
| 1 | 2024-01-01 | 100 | **100** (only row1) | **200** (row1+row2 — Jan-01 peers) |
| 2 | 2024-01-01 | 100 | **200** (row1+row2 physical) | **200** (same peer group as row1) |
| 3 | 2024-01-02 | 50  | **150** (row2+row3 physical) | **250** (row1+row2+row3 — Jan-01 within 1 day of Jan-02) |
| 4 | 2024-01-04 | 70  | **120** (row3+row4 physical) | **70** (Jan-03 absent; window [Jan-03, Jan-04] catches only row4) |

**The teaching contrast — row3: ROWS=150 vs RANGE=250.** RANGE pulls in BOTH Jan-01 rows because their dates are within 1 day of Jan-02; ROWS only reaches **one physical row back** (row2), no matter how many rows share that physical-neighbor's date. The row4 case shows the **gap effect**: RANGE is calendar-aware and doesn't care that Jan-03 has zero rows, while ROWS just walks the physical predecessor (which happens to be row3 on Jan-02).

> **Guard caption (if your ROWS and RANGE columns are equal on row3, you've miscounted):** RANGE includes ALL rows whose value is within the window, not a fixed count of rows. Row3's RANGE window spans dates `[Jan-01, Jan-02]` and **all three rows** (the two Jan-01 peers plus row3) fall in it → 100+100+50 = 250. The ROWS=150 answer ignores row1 entirely because the physical-1-back frame can only reach row2.

> **Bonus default-frame surprise — SYMPTOM → CAUSE → FIX (iter587 PIN + iter667 broaden, read FIRST).**
>
> **Keyword anchors (so questions about this bug route HERE):** *running total wrong on tied dates, same-date rows show same running total, running total not accumulating one at a time, default frame RANGE lumps peers, ROWS vs RANGE running total, why are my cumulative values all the same on the same day, two events same day same cumulative value, running total stuck at end-of-day value, ROWS frame physical row vs RANGE frame peer group, per-day running total multiple orders per day, daily running total from row-grain orders, pre-aggregate before window, cumulative revenue per day with many orders per day, ROWS BETWEEN UNBOUNDED PRECEDING physical row, RANGE BETWEEN UNBOUNDED PRECEDING peer.*
>
> **SYMPTOM.** A running total where rows sharing the same `ORDER BY` value (e.g. the same date) **ALL show the SAME total** (the end-of-that-date cumulative), instead of accumulating one at a time. On the four-row sample above, the user expected 100, 200, 250, 320 — but got **200, 200, 250, 320** (both Jan-01 rows show 200, the peer-group end).
>
> **CAUSE.** With `ORDER BY date` and **NO explicit frame**, the DEFAULT frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. `RANGE` is value-based and **includes ALL PEER rows tied on the `ORDER BY` value** — so all same-date rows share one frame, and therefore share one cumulative value (the sum through the end of the peer group). This is **NOT a bug in Trino** — it is the ANSI-SQL-defined default and matches the docs. Verified verbatim at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): *"If the frame is not specified, it defaults to `RANGE UNBOUNDED PRECEDING`, which is the same as `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`"*, and the same docs note this frame *"contains all rows from the start of the partition up to the last peer of the current row"* — i.e. tied peers are lumped.
>
> **FIX.** Add **both** of the following — they fix the symptom together; either one alone is incomplete:
> 1. An **explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`** frame clause (row-by-row, not value-based — each row gets its own per-row frame, no peer lumping).
> 2. A **unique tiebreaker** in `ORDER BY` (e.g. `ORDER BY date, id` or `ORDER BY date, event_id`) so the row order among tied dates is deterministic.
>
> ```sql
> SUM(amount) OVER (
>   PARTITION BY tenant_id
>   ORDER BY day, event_id                       -- unique tiebreaker → no peers
>   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW   -- explicit ROWS → no peer lumping
> ) AS running_total
> ```
>
> **ANTI-FIX — DO-NOT-RECOMMEND (inoculate against the iter586 backwards-fix class).** Do **NOT** "fix" this symptom by **relying on the default frame** or **switching to `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`** — the default RANGE frame **IS THE CAUSE** of the symptom (it lumps tied peers into one frame). Recommending it gives the user **MORE of the bug they reported**, not less. If a question reads "same-date rows all show the same cumulative value, how do I make them accumulate one at a time?" the answer is **NEVER** "just use the default frame" / "switch to RANGE" / "omit the frame clause" — that is the bug. The answer is **always** the explicit-ROWS + unique-tiebreaker pair above.
>
> **When the default RANGE is actually what you want.** If two events on the same day SHOULD report the **same** cumulative value (peer semantics — e.g. end-of-day cumulative reporting), then the default RANGE is correct and Pattern 1 above (omit the frame clause) is the right recommendation. The default-RANGE-as-fix recommendation is ONLY correct when the question's INTENT is "tied peers should share a value". The symptom above describes the OPPOSITE intent — the user wants per-row accumulation — so the explicit-ROWS + tiebreaker is the only correct fix.
>
> **Worked numbers on the sample data.** `SUM(amt) OVER (ORDER BY order_date)` with NO explicit frame gives 200, 200, 250, 320 — both Jan-01 peers see 200 (the peer-group end), Jan-02 sees 250, Jan-04 sees the full running total. Switching to `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` with `ORDER BY order_date, id` gives 100, 200, 250, 320 — per-row accumulation, deterministic. That is the difference the user is reporting; the fix is **always** Pattern 2 (explicit ROWS + unique tiebreaker).
>
> **iter667 BROADEN — per-DAY running total when the SOURCE table has MULTIPLE rows per day (the "daily cumulative revenue from row-grain orders" SaaS shape).** When the question is *"give me the cumulative revenue **per day** through each day"* and the source table (`orders`) has many rows per day, you do NOT want either Pattern 1 (peer semantics — gives every order on the same day the same end-of-day value but keeps every order row) or Pattern 2 (positional per-row — gives each order its own incrementing value within the day, but you wanted ONE row per day). You want **one row per day** with the day's cumulative-through-end-of-day. The clean recipe is **pre-aggregate to one-row-per-day FIRST in a CTE, then run the window over THAT result**:
>
> ```sql
> WITH daily AS (
>   SELECT order_date,
>          SUM(amount) AS daily_total           -- collapse to ONE row per day
>   FROM iceberg.analytics.orders
>   WHERE order_date >= DATE '2026-01-01'
>   GROUP BY order_date
> )
> SELECT order_date,
>        daily_total,
>        SUM(daily_total) OVER (
>          ORDER BY order_date
>          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
>        ) AS cumulative_total
> FROM daily
> ORDER BY order_date;
> ```
>
> Why this is the right shape: after the CTE collapses to one row per day, `order_date` is **unique** in the input to the window — so `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is unambiguous (each row IS a single day; no peer ties to resolve) and `RANGE` would give the identical answer too (peer groups are singletons). Pre-aggregating eliminates the ROWS-vs-RANGE question altogether and is the simplest correct form for the per-day-from-row-grain shape. Add `PARTITION BY tenant_id` if multi-tenant; add `GROUP BY tenant_id, order_date` in the CTE for the same reason. **Do NOT** try to fix this by writing `SUM(amount) OVER (ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` directly on the row-grain `orders` table — you'd either get one row per order with per-order accumulation (not per-day), or, with the default RANGE, one row per order all showing the end-of-day total (still not the per-day shape you wanted). Pre-aggregate, then window — that is the canonical pattern.

### LEADING CANONICAL — Trino named WINDOW clause (define a window once, reference by name)

> **Keyword anchors:** Trino named window, WINDOW clause, define window once, reuse OVER clause, `WINDOW w AS`, named window specification, avoid repeating PARTITION BY. Verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): *"The `WINDOW` clause is used to define named window specifications. The defined named window specifications can be referred to in the `SELECT` and `ORDER BY` clauses of the enclosing query."* Supported in Trino since v352.

```sql
SELECT
  tenant_id, day, amount,
  SUM(amount) OVER w AS running_total,
  AVG(amount) OVER w AS running_avg,
  MAX(amount) OVER w AS running_max
FROM iceberg.analytics.daily_revenue
WINDOW w AS (PARTITION BY tenant_id ORDER BY day
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);
```

Define the window spec ONCE in a trailing `WINDOW name AS (...)` clause (positioned **after `HAVING`**, **before `ORDER BY`**), then reference it via `OVER w` in any number of window functions in the same SELECT. You can also **extend** a named window: `WINDOW w2 AS (w ORDER BY ts)` inherits `w`'s `PARTITION BY` and adds an `ORDER BY`. **DO-NOT-WRITE:** don't claim "Trino has no named WINDOW clause" — it is supported (v352+). Don't place the `WINDOW` clause at the very end after `ORDER BY` — the correct slot is between `HAVING` and `ORDER BY`.

### Pattern A2: Bucketed running total — `GROUP BY` + window-over-aggregate (CANONICAL CARD)

**The SaaS question family:** "Per tenant, show monthly event counts AND a running cumulative total of events through the end of each month." Same family: weekly active users with running totals, daily revenue with month-to-date, signups per week with cumulative YTD.

The shape is **`GROUP BY` to bucket + aggregate, then a window function over the aggregate** (`SUM(COUNT(*)) OVER (...)`, `SUM(SUM(amount)) OVER (...)`). The window-over-aggregate trick is supported in Trino per [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) ("All Aggregate functions can be used as window functions by adding the OVER clause") — the aggregate is computed first (one row per group), then the window function runs over those grouped rows.

This pattern is where engineers from MySQL/PostgreSQL/Snowflake backgrounds most often write Trino-invalid SQL. Read the **GROUP BY rules anchor** below FIRST, then copy the canonical form.

#### Trino GROUP BY rules (anchor — apply to EVERY GROUP BY query)

Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) + [trinodb/trino #16533](https://github.com/trinodb/trino/issues/16533):

1. **GROUP BY accepts EXPRESSIONS or ORDINAL NUMBERS only.** Per the Trino SELECT doc verbatim: *"A simple `GROUP BY` clause may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position (starting at one)."*
2. **NO `AS alias` definition syntax inside GROUP BY.** Defining an alias is a SELECT-list operation. `GROUP BY DATE_TRUNC('month', event_date) AS event_month` is a **parse error in every SQL dialect** — the GROUP BY grammar does not include the `AS <name>` production.
3. **Trino does NOT support referencing a SELECT-list alias by NAME in GROUP BY** (issue [trinodb/trino #16533](https://github.com/trinodb/trino/issues/16533), still open). You must repeat the original expression OR use an ordinal `GROUP BY 1, 2`. Note: PostgreSQL and MySQL allow alias-reference in GROUP BY, which is the most common source of cross-dialect spillover. Trino does not.
4. **A SELECT alias may be referenced in `ORDER BY`** (the outer final-sort ORDER BY, after projection) but **NOT in `GROUP BY` / `WHERE` / `HAVING`** (all evaluated before or during projection).
5. **A window-clause's inline `ORDER BY` (inside `OVER (...)`) references the PRE-PROJECTION expression**, not the SELECT alias. Use `ORDER BY DATE_TRUNC('month', event_date)` inside `OVER (...)`, not `ORDER BY event_month`.

#### Canonical worked example — per-tenant monthly events + cumulative running total

```sql
-- CORRECT — bucket by month with DATE_TRUNC, COUNT per bucket, then SUM(COUNT(*)) OVER for the running total.
SELECT
  tenant_id,
  DATE_TRUNC('month', event_date) AS event_month,    -- alias DEFINED in SELECT
  COUNT(*) AS events_this_month,                      -- aggregate over the GROUP BY
  SUM(COUNT(*)) OVER (
    PARTITION BY tenant_id
    ORDER BY DATE_TRUNC('month', event_date)          -- window ORDER BY uses the EXPRESSION, not the alias
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_events
FROM iceberg.analytics.events
WHERE event_date >= DATE '2026-01-01'
GROUP BY tenant_id, DATE_TRUNC('month', event_date)   -- GROUP BY REPEATS the EXPRESSION
ORDER BY tenant_id, event_month;                       -- outer ORDER BY CAN use the SELECT alias
```

Equivalent form using ordinals (some teams prefer this — fewer characters, but less grep-friendly):

```sql
GROUP BY 1, 2          -- ordinal positions of tenant_id and DATE_TRUNC(...)
ORDER BY 1, 2;
```

**Why each piece is the way it is:**
- `DATE_TRUNC('month', event_date) AS event_month` — alias **defined** in SELECT. The alias name `event_month` only exists *after* projection. Anywhere the alias appears before projection (GROUP BY, WHERE, HAVING, OVER's ORDER BY), use the **expression** instead.
- `GROUP BY tenant_id, DATE_TRUNC('month', event_date)` — repeats the expression. NEVER write `GROUP BY ... AS event_month` (rule 2) and NEVER write `GROUP BY event_month` (rule 3 — Trino-grammar gap #16533).
- `SUM(COUNT(*)) OVER (...)` — the window-over-aggregate. After the GROUP BY collapses to one row per `(tenant_id, month)`, the window function runs over those rows. The `COUNT(*)` is what would be each row's `events_this_month`; `SUM(COUNT(*)) OVER (...)` sums them across the partition.
- `ORDER BY DATE_TRUNC('month', event_date)` *inside* `OVER (...)` — must be the expression, not the alias. The window clause is evaluated alongside the projection, not after it.
- `ORDER BY tenant_id, event_month` *outside* (final sort) — the alias is fine here. Final sort runs **after** projection, so the alias exists.

#### DO-NOT-WRITE matrix (every line below is a Trino parse error or analysis error)

| DO NOT WRITE | Why it breaks | Correct form |
|---|---|---|
| `GROUP BY tenant_id, DATE_TRUNC('month', event_date) AS event_month` | **Parse error.** Alias-definition syntax (`expr AS name`) is a SELECT-list-only production. The GROUP BY grammar does not include `AS`. Fails in EVERY SQL dialect, not just Trino. | `GROUP BY tenant_id, DATE_TRUNC('month', event_date)` — repeat the expression. |
| `GROUP BY tenant_id, event_month` (alias referenced by name) | **Trino-grammar gap** — issue [trinodb/trino #16533](https://github.com/trinodb/trino/issues/16533) (still open). Trino's analyzer errors with `Column 'event_month' cannot be resolved`. PostgreSQL/MySQL allow this; Trino does NOT. | `GROUP BY tenant_id, DATE_TRUNC('month', event_date)` — OR `GROUP BY 1, 2` (ordinals). |
| `SELECT tenant_id, event_month, COUNT(*) ... FROM events GROUP BY tenant_id, DATE_TRUNC('month', event_date)` (bare `event_month` in SELECT with no defining `AS event_month`) | **Analysis error — `Column 'event_month' cannot be resolved`.** The SELECT list references an undefined name. An alias must be **defined** by `<expr> AS event_month` somewhere in the SELECT list (or the table must have a real `event_month` column). | Add `DATE_TRUNC('month', event_date) AS event_month` to the SELECT list. |
| `SUM(COUNT(*)) OVER (PARTITION BY tenant_id ORDER BY event_month ...)` (alias inside `OVER`'s ORDER BY) | **Analysis error.** The window clause is evaluated with pre-projection scope; the alias `event_month` is not yet visible. Same root cause as GROUP-BY-by-alias. | `ORDER BY DATE_TRUNC('month', event_date)` inside `OVER (...)`. |
| `WHERE DATE_TRUNC('month', event_date) AS event_month >= DATE '2026-01-01'` | **Parse error.** WHERE accepts predicates, not alias-definitions. | Move the alias definition to the SELECT list; in WHERE, predicate on `event_date >= DATE '2026-01-01'` directly (better — preserves partition pruning). |
| `HAVING event_month >= DATE '2026-01-01'` (alias in HAVING) | **Same as GROUP-BY-by-alias** — Trino does not resolve SELECT aliases in HAVING. | `HAVING DATE_TRUNC('month', event_date) >= DATE '2026-01-01'` — repeat the expression. (Better: push the filter to WHERE for partition pruning.) |

#### When to use `GROUP BY` + window-over-aggregate vs raw window function

| Need | Pick |
|---|---|
| Per-row running total over raw events (each event keeps its own row, running total computed across them) | Pattern A (raw window, no GROUP BY) |
| Per-bucket aggregate + running total across buckets (one row per `(tenant, month)` showing both monthly count and cumulative count) | **Pattern A2 (this card)** — GROUP BY + `SUM(COUNT(*)) OVER (...)` |
| Top-N per group with a bucketed metric | Pattern A2 followed by an outer `WHERE rank <= N` filter on a `RANK() OVER (PARTITION BY tenant_id ORDER BY events_this_month DESC)` column |

### Pattern B: Lag / Lead (compare to previous or next row)

"Day-over-day change in revenue per tenant."

```sql
SELECT
  day,
  tenant_id,
  revenue,
  LAG(revenue, 1) OVER (PARTITION BY tenant_id ORDER BY day) AS prev_day_revenue,
  revenue - LAG(revenue, 1) OVER (PARTITION BY tenant_id ORDER BY day) AS day_over_day_change
FROM iceberg.analytics.daily_revenue
WHERE day >= DATE '2026-01-01';
```

- `LAG(col, n)` returns the value of `col` from `n` rows back within the partition (default 1). Returns NULL when there is no prior row.
- `LEAD(col, n)` is the mirror — `n` rows forward.
- No frame clause needed — `LAG`/`LEAD` operate on a specific row offset, not a frame.

### Pattern B2: LEADING CANONICAL — Period-over-period: YoY vs MoM with window functions (year over year / same month last year / month over month / compare to last year / LAG 12 months / growth vs last year / period over period)

> **Read this BEFORE writing any "year-over-year", "YoY", "same month last year", "month over month", "MoM", "compare to last year", "growth vs last year", or "period over period" SQL on Trino + Iceberg.** `LAG` is the right tool, but the **offset** matters and silently produces the wrong metric if you pick the default.

> **DECIDE-FIRST SIGNPOST (iter640 FIX-A — pick the right shape BEFORE writing).** Two questions look similar in English but want different SQL:
>
> | The question is really asking... | Shape | Where to land |
> |---|---|---|
> | Compare **EACH month** to the **same month a year earlier** — produce a per-month series (`one row per (entity, month)` with `same_month_last_year` next to `current_month`). E.g. "monthly trend with YoY column." | LAG(12) over a gap-filled monthly series, OR self-join `cur.month = prev.month + INTERVAL '12' MONTH` | **FORM A / FORM B below** (this canonical, lines 1737-1850). |
> | Compare **this period's TOTAL vs last period's TOTAL** as ONE ratio per entity (one row per entity — e.g. "this YEAR's total revenue / last YEAR's total revenue per product", "this QUARTER's total vs last QUARTER's total per region"). The output is **one row per entity, NOT a per-month time series**. | **Conditional-SUM-by-period in ONE `GROUP BY` pass** — `SUM(amount) FILTER (WHERE year(d) = year(current_date)) / NULLIF(SUM(amount) FILTER (WHERE year(d) = year(current_date) - 1), 0)` | **Period-total ratio canonical** immediately below Pattern B2 (added iter640 — see "Sub-canonical: PERIOD-TOTAL YoY / this-period-vs-last-period ratio"). |
>
> If you write a per-month LAG(12) series and then filter to the current month, you are answering a DIFFERENT question (a single month's value vs same month last year — not the full year's total vs last year's total). Use the period-total form below for "TOTAL ÷ TOTAL" ratio questions.

**Core fact (verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html)):** `lag(x[, offset[, default_value]])` "Returns the value at `offset` rows before the current row in the window partition." **The default offset is `1`** — one row back, NOT one year back, NOT one month back. The offset is **rows**, not calendar periods, so the right number depends on (a) what your bucket granularity is and (b) whether the series is gap-filled per partition key.

#### LAG offset mapping — pick the offset by intent AND bucket grain

| Comparison intent | Bucket grain (one row per ...) | LAG offset | Requirement |
|---|---|---|---|
| Previous row (day-over-day, if rows are daily) | one row per `(partition_key, day)` | `LAG(metric, 1)` | Contiguous daily rows per partition key — every day present |
| **Month-over-month (MoM)** | one row per `(partition_key, month)` | **`LAG(metric, 1)`** | Contiguous monthly rows per partition key — every month present |
| **Year-over-year (YoY) — same month last year** | one row per `(partition_key, month)` | **`LAG(metric, 12)`** | **13+ months of CONTIGUOUS monthly rows per partition key — every month present** |
| Quarter-over-quarter (QoQ) — same quarter last year | one row per `(partition_key, quarter)` | `LAG(metric, 4)` | Contiguous quarterly rows per partition key — every quarter present |
| Same week last year | one row per `(partition_key, iso_week)` | `LAG(metric, 52)` | Contiguous weekly rows — every ISO week present (warning: a few ISO years have 53 weeks; self-join is safer than LAG(52) for weekly YoY) |

**Memorize the load-bearing pair:** `LAG(metric, 1)` over a monthly series = **MoM (previous month)**. `LAG(metric, 12)` over the same monthly series = **YoY (same month last year)**. These are **different metrics** and labeling one as the other is a silent-wrong bug — there is no error message.

#### The GAP-FILL CAVEAT (the crux — this is where most YoY queries break)

`LAG(metric, N)` counts **rows**, not calendar periods. If a customer's monthly series has a missing month, `LAG(metric, 12)` silently points at the **wrong calendar month** — typically 11 months back, not 12. Concrete worst case: customer A has rows for every month except 2025-07. On their 2026-06 row, `LAG(usage, 12) OVER (... ORDER BY month)` returns the **2025-08** value (because there are only 11 rows between 2026-06 and 2025-08 in their partition), not the 2025-06 value the engineer expects. **No error, no warning — just wrong numbers.**

The same trap exists for MoM with `LAG(metric, 1)`: if customer A has rows for 2026-01 and 2026-03 but not 2026-02, then on the 2026-03 row `LAG(usage, 1)` returns the **2026-01** value (a 2-month-back comparison), not the 2026-02 value (which doesn't exist).

**There are exactly two safe forms.** Pick consciously.

#### FORM A (preferred for YoY — gap-safe by construction): SELF-JOIN on calendar arithmetic

The self-join matches `(customer_id, month)` to `(customer_id, month - INTERVAL '12' MONTH)` directly — so an unmatched row produces NULL (not a shifted offset). This form **does not require gap-filling**. It is the recommended pattern for any production YoY metric.

```sql
-- CANONICAL YoY (year-over-year) — self-join, gap-safe, one row per (customer_id, current_month)
WITH monthly AS (
  SELECT
    customer_id,
    date_trunc('month', occurred_at) AS month,
    COUNT(*) AS usage_count
  FROM iceberg.analytics.events
  WHERE occurred_at >= date_add('month', -25, date_trunc('month', current_date))
  GROUP BY customer_id, date_trunc('month', occurred_at)  -- REPEAT the expression; do NOT use the alias (Trino #16533)
)
SELECT
  cur.customer_id,
  cur.month                          AS current_month,
  cur.usage_count                    AS current_month_usage,
  prev.usage_count                   AS same_month_last_year,
  (cur.usage_count - prev.usage_count) * 1.0
    / NULLIF(prev.usage_count, 0) * 100  AS yoy_growth_pct
FROM monthly cur
LEFT JOIN monthly prev
  ON  prev.customer_id = cur.customer_id
  AND prev.month       = date_add('month', -12, cur.month)
WHERE cur.month = date_trunc('month', current_date)
ORDER BY cur.customer_id;
-- prev.usage_count is NULL when there is no row exactly 12 months prior — the LEFT JOIN handles gaps cleanly.
-- yoy_growth_pct is NULL when prev.usage_count is 0 or NULL (NULLIF guards divide-by-zero AND missing baseline).
```

Substitute `date_add('month', -1, cur.month)` for MoM. Substitute `date_add('quarter', -1, cur.month)` for same-quarter-last-year against a monthly grain, or use a quarterly grain with `date_add('quarter', -4, ...)` for QoQ over a quarterly series. The pattern is the same; only the unit and the offset change.

> **`date_add` confirmed at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html):** `date_add(unit, value, timestamp)` "Adds an `interval value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value." The equivalent `cur.month - INTERVAL '12' MONTH` form is also valid Trino — both compile to the same plan. Prefer `date_add` for readability when the offset is a variable.

#### FORM B (LAG(12) over a GAP-FILLED contiguous monthly series)

Use this form when you need ranks/running totals over the same window as the YoY column — `LAG` keeps you on a single window pass. **You MUST gap-fill first** or LAG will silently shift the offset on sparse customers (see the caveat above). The gap-fill recipe: generate a complete `(customer_id, month)` spine for the lookback window, LEFT JOIN actual counts, COALESCE missing values to 0.

```sql
-- CANONICAL YoY (year-over-year) — LAG(12) over an EXPLICITLY GAP-FILLED contiguous monthly series
WITH monthly_actuals AS (
  SELECT
    customer_id,
    date_trunc('month', occurred_at) AS month,
    COUNT(*) AS usage_count
  FROM iceberg.analytics.events
  WHERE occurred_at >= date_add('month', -25, date_trunc('month', current_date))
  GROUP BY customer_id, date_trunc('month', occurred_at)
),
month_spine AS (
  -- Sequence of all 26 month starts in the window: -25 ... 0
  SELECT m AS month
  FROM UNNEST(sequence(
    date_add('month', -25, date_trunc('month', current_date)),
    date_trunc('month', current_date),
    INTERVAL '1' MONTH
  )) AS t(m)
),
customers AS (
  SELECT DISTINCT customer_id FROM monthly_actuals
),
gap_filled AS (
  -- One row per (customer, month) for every customer that appeared anywhere in the window
  SELECT
    c.customer_id,
    s.month,
    COALESCE(a.usage_count, 0) AS usage_count
  FROM customers c
  CROSS JOIN month_spine s
  LEFT JOIN monthly_actuals a
    ON a.customer_id = c.customer_id
   AND a.month       = s.month
)
SELECT
  customer_id,
  month                              AS current_month,
  usage_count                        AS current_month_usage,
  LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month)
                                     AS same_month_last_year,
  (usage_count - LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month)) * 1.0
    / NULLIF(LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month), 0) * 100
                                     AS yoy_growth_pct
FROM gap_filled
WHERE month = date_trunc('month', current_date)
ORDER BY customer_id;
```

**Why this works:** the `gap_filled` CTE guarantees every `(customer_id, month)` combination is present for all 26 months in the window. With contiguous rows, `LAG(usage_count, 12)` reliably returns the value from exactly 12 calendar months prior. Without the gap-fill step, the LAG offset becomes a function of how sparse each customer's series is — silently wrong, per-customer-different.

#### Picking FORM A vs FORM B

| Need | Pick |
|---|---|
| Single YoY column, one row per current month per customer | **FORM A (self-join)** — simpler, no spine CTE, gap-safe by construction |
| YoY AND a running total / ranking over the SAME monthly window in ONE query | FORM B (LAG over gap-filled) — single window pass, no extra join |
| You're not sure whether your series has gaps | **FORM A (self-join)** — defaults to the safe option |
| Sparse data is the norm (e.g., per-customer feature usage where most months are zero) | **FORM A (self-join)** — or FORM B with the COALESCE-to-0 gap-fill |

#### DO-NOT-WRITE — banned YoY forms (each will produce the WRONG metric or fail to parse)

| DO NOT WRITE | Why it is wrong | Correct form |
|---|---|---|
| `LAG(usage_count) OVER (PARTITION BY customer_id ORDER BY month) AS usage_last_year` (default offset 1, labeled as YoY) | **SILENT-WRONG — this is MoM, not YoY.** `LAG(x)` with no offset = `LAG(x, 1)` = previous row = previous month on a monthly series. Labeling this as "last year" / "YoY" is internally inconsistent and answers a different question than the user asked. | `LAG(usage_count, 12) OVER (... ORDER BY month)` over a **gap-filled** monthly series, OR the self-join form (FORM A). |
| `LAG(usage_count) OVER (... ORDER BY month) AS usage_last_month` then `(current - usage_last_month) / usage_last_month AS yoy_growth_pct` | **INTERNAL INCONSISTENCY.** The intermediate column name ("last month") and the final metric name ("YoY") describe different metrics. Either rename the metric to `mom_growth_pct` (it is MoM) or fix the LAG offset to 12 and the intermediate column to `same_month_last_year` (it is YoY). One or the other — not both. | Pick ONE: `LAG(metric, 1)` + `mom_growth_pct` + `prev_month_usage`, OR `LAG(metric, 12)` + `yoy_growth_pct` + `same_month_last_year`. |
| `LAG(usage_count, 12) OVER (... ORDER BY month)` on a sparse monthly series with NO gap-fill | **SILENT-WRONG on customers with missing months** — the offset counts rows, not calendar months, so a missing month silently shifts the comparison to the wrong calendar period (typically 11 months back). | Either (a) gap-fill the series first (FORM B's `gap_filled` CTE) before applying LAG(12), or (b) use the self-join form (FORM A) which is gap-safe by construction. |
| `LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY event_month)` where `event_month` is a **SELECT alias** | **Analysis error — alias not visible in `OVER`'s ORDER BY.** Window-clause ORDER BY uses pre-projection scope, so the alias `event_month` is not yet defined. Same Trino-grammar rule that bans alias references in GROUP BY (see §5 Pattern A2 GROUP BY rules anchor, rule 5). | Repeat the expression: `ORDER BY date_trunc('month', occurred_at)`. |
| `JOIN monthly prev ON prev.month = cur.month - 12` (bare integer subtraction on a TIMESTAMP/DATE) | **Type error** — `TIMESTAMP - INTEGER` is not a defined operation in Trino. | `prev.month = date_add('month', -12, cur.month)` OR `prev.month = cur.month - INTERVAL '12' MONTH`. |

#### Keyword anchor (so this canonical lands when you search for the right thing)

The phrases you would type into a search bar for this pattern: **year over year**, **YoY**, **same month last year**, **year-over-year growth**, **compare to last year**, **growth vs last year**, **monthly trend year ago**, **month over month**, **MoM**, **previous month**, **period over period**, **period-over-period growth**, **LAG window function**, **LAG 12 months**, **LAG offset 12**, **same period last year**, **same period prior year**, **prior year comparison**, **prior-year-over-year**.

> **Cross-reference:** for the broader "monthly bucketed running total + GROUP BY rules anchor" pattern (which the YoY queries above also obey), see §5 Pattern A2 — Bucketed running total. The GROUP BY rule "**REPEAT the expression, do NOT use the alias**" applies here too. For YoY in a dbt incremental model (where YoY is computed inside `{% if is_incremental() %}` and the gap-fill spine is generated relative to a watermark), see [resource 27](27-oracle-plsql-to-dbt-trino.md) and [resource 28](28-complex-sql-performance-trino-dbt.md).

#### Sub-canonical — PERIOD-TOTAL YoY / this-period-vs-last-period RATIO (one ratio per entity from two period totals — NOT a per-month series) (iter640 FIX-A)

> **Keyword anchors (READ THIS FIRST if your question contains any of these):** this year's total revenue divided by last year's, year-over-year ratio per product, annual total vs last year total, this period vs last period total, this quarter's total divided by last quarter's, YoY growth ratio of totals, compare two years' totals side by side, ratio of this year's total to last year's total, total revenue this year over last year per product, full-year total YoY, period-total ratio per entity, two-period total ratio in one pass.

> **The fact in one sentence.** When the question is "**this YEAR's TOTAL `X` / last YEAR's TOTAL `X` per `entity`**" (or this-quarter-vs-last-quarter total, or any two explicit period **totals** compared) — i.e. ONE row per `entity` with ONE ratio, NOT a per-month time series — write it as a **single-pass conditional-aggregation with `FILTER (WHERE ...)`** in ONE `GROUP BY entity`. Compute the **two period totals as parallel aggregates** in the same `SELECT`, then divide. No LAG, no self-join, no gap-fill needed — the period boundaries are explicit predicates inside the `FILTER` clauses. Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) (`year(x) -> bigint`, `quarter(x) -> bigint` ranges 1..4) + [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) (`FILTER (WHERE ...)` supported on every aggregate) + [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) (`NULLIF(a, b)` returns NULL when `a = b`).

> **PREFERRED CANONICAL — annual total ÷ total per product (single-pass conditional SUM with `FILTER`, zero-guarded):**
>
> ```sql
> -- "What is this year's total revenue divided by last year's total revenue, per product?"
> -- ONE row per product. ONE ratio. No per-month series, no LAG, no self-join.
> SELECT
>   product_id,
>   SUM(amount) FILTER (WHERE year(order_date) = year(current_date))     AS revenue_this_year,
>   SUM(amount) FILTER (WHERE year(order_date) = year(current_date) - 1) AS revenue_last_year,
>   SUM(amount) FILTER (WHERE year(order_date) = year(current_date)) * 1.0
>     / NULLIF(SUM(amount) FILTER (WHERE year(order_date) = year(current_date) - 1), 0)
>     AS yoy_ratio
> FROM iceberg.analytics.orders
> GROUP BY product_id;
> ```
>
> **Why each piece is load-bearing:**
> - **`year(order_date) = year(current_date)`** picks rows whose `order_date` falls in the current calendar year; `year(current_date) - 1` picks last year. `year(date)` returns `bigint` per the Trino datetime docs — integer arithmetic on `year(current_date) - 1` is well-defined. The two `FILTER` predicates are **mutually exclusive** (a row cannot be in both years), so each row contributes to AT MOST one of the two sums — no double-counting risk.
> - **`SUM(...) FILTER (WHERE ...)`** computes the period total in ONE pass over the same row set as the bare `SUM` — both totals share the scan, share the `GROUP BY product_id`. Multiple `FILTER`-ed aggregates over the same row set is the docs-canonical conditional-aggregation pattern (see [Trino aggregate-functions FILTER docs](https://trino.io/docs/467/functions/aggregate.html) verbatim: *"The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause."*).
> - **`* 1.0`** forces decimal division. Without it, `SUM(amount) / NULLIF(SUM(amount), 0)` on two integer/bigint values does **integer division** and the ratio truncates to 0 unless this year's total happens to exceed last year's. Multiply the numerator by the DECIMAL literal `1.0` (or `CAST(... AS double)`) so the division is floating-point.
> - **`NULLIF(SUM(...) FILTER (WHERE ...), 0)`** is the divide-by-zero guard. If a product had NO revenue last year, the denominator is `0`; dividing by `0` raises a Trino runtime error. `NULLIF(x, 0)` returns `NULL` when `x = 0`, and any number divided by `NULL` is `NULL` — so products with no last-year revenue emit `yoy_ratio = NULL` instead of erroring out. (Note: `FILTER` already returns `NULL` for an empty group on its own, but a product that **had** last-year rows summing to `0` would still trigger divide-by-zero without `NULLIF` — keep the guard for both cases.)
>
> **Equivalent `CASE WHEN` form (works on every dialect, slightly more verbose):**
>
> ```sql
> SELECT
>   product_id,
>   SUM(CASE WHEN year(order_date) = year(current_date)     THEN amount ELSE 0 END) AS revenue_this_year,
>   SUM(CASE WHEN year(order_date) = year(current_date) - 1 THEN amount ELSE 0 END) AS revenue_last_year,
>   SUM(CASE WHEN year(order_date) = year(current_date)     THEN amount ELSE 0 END) * 1.0
>     / NULLIF(SUM(CASE WHEN year(order_date) = year(current_date) - 1 THEN amount ELSE 0 END), 0)
>     AS yoy_ratio
> FROM iceberg.analytics.orders
> GROUP BY product_id;
> ```
>
> **`FILTER` vs `CASE WHEN ... ELSE 0 END` — subtle but important denominator difference.** Both forms produce identical numeric answers on the canonical above (`NULLIF(..., 0)` covers both cases), but they reach `0` via different paths. `SUM(CASE WHEN cond THEN amount ELSE 0 END)` on a group with NO matching rows returns `0` (the `ELSE 0` branch contributes `0` per row); `SUM(amount) FILTER (WHERE cond)` on a group with NO matching rows returns `NULL` (the aggregate sees zero input rows, and per the Trino docs aggregate-functions general rule, `SUM`/`AVG`/etc. return `NULL` for no input rows). For the **denominator**, the `FILTER` form's `NULL` propagates naturally to the ratio without `NULLIF` — but a group that DID have last-year rows summing to actual `0` still needs the `NULLIF` guard. **Bottom line:** always wrap the denominator in `NULLIF(..., 0)` regardless of which form you pick — it covers both no-rows AND rows-summing-to-zero.

> **GENERALIZE — same shape, different period unit:**
>
> | Comparison | Numerator predicate | Denominator predicate |
> |---|---|---|
> | **Year vs prior year (YoY total)** | `year(order_date) = year(current_date)` | `year(order_date) = year(current_date) - 1` |
> | **Quarter vs prior quarter (QoQ total)** *(within the same year)* | `year(order_date) = year(current_date) AND quarter(order_date) = quarter(current_date)` | `year(order_date) = year(current_date) AND quarter(order_date) = quarter(current_date) - 1` |
> | **This year's Q1 vs last year's Q1 (same-quarter YoY)** | `year(order_date) = year(current_date) AND quarter(order_date) = quarter(current_date)` | `year(order_date) = year(current_date) - 1 AND quarter(order_date) = quarter(current_date)` |
> | **Two explicit date windows** (e.g. "May 2026 total vs May 2025 total") | `order_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'` | `order_date BETWEEN DATE '2025-05-01' AND DATE '2025-05-31'` |
>
> Same shape every time: two `SUM(amount) FILTER (WHERE <period-predicate>)` aggregates in ONE `SELECT`, divide with `* 1.0 / NULLIF(..., 0)`. The period unit changes; the recipe doesn't.
>
> Note: for a **quarter-vs-prior-quarter** comparison that crosses a year boundary (Q1 2026 vs Q4 2025), the simple `quarter(...) - 1` won't work (Q1 of 2026 has `quarter=1`, and `1 - 1 = 0` which is not a valid quarter). For that case, either subtract a quarter from `current_date` using `date_add('quarter', -1, current_date)` and read `year(...)` + `quarter(...)` of that, or scope by explicit date windows (the BETWEEN row above).

> **DO-NOT-WRITE — period-total ratio specific (iter640 FIX-A — the iter639 Q2 responder miss):**
>
> | DO NOT write | Why it's wrong / silently-wrong | Correct form |
> |---|---|---|
> | **A per-month `LAG(12)` series (FORM A or FORM B above) filtered to just the current month, labeled as "this year's total vs last year's total."** | **WRONG — answers a DIFFERENT question.** A LAG(12) over a monthly series compares **ONE MONTH** (the current month) to the **same month last year** — that is a single-month YoY, NOT a full-period total YoY. The user asked for **this YEAR's TOTAL / last YEAR's TOTAL** (12 months on top of 12 months) per product; the LAG(12) answer is one month's value on top of one month's value. Numerically different, semantically a different metric. This is the exact iter639 Q2 miss. | The single-pass `SUM(amount) FILTER (WHERE year(order_date) = year(current_date)) / NULLIF(SUM(amount) FILTER (WHERE year(order_date) = year(current_date) - 1), 0)` canonical above — one row per product, two period **TOTALS** compared in ONE pass. |
> | Omitting the `* 1.0` (or a CAST) on integer/bigint amounts | **SILENT-WRONG — integer division truncates to 0** unless this year's total ≥ last year's total. A product with `revenue_this_year = 500`, `revenue_last_year = 1000` would emit `yoy_ratio = 0` (not `0.5`). | Multiply the numerator by `1.0` (decimal) or `CAST(SUM(...) AS double)` to force floating-point division. |
> | Omitting `NULLIF(SUM(...), 0)` on the denominator | **Runtime error: `Division by zero`** the first time a product has no last-year rows summing to a non-zero amount. The CASE-WHEN `ELSE 0` form makes this even more likely (every no-row group becomes literal 0). | Always wrap the denominator: `... / NULLIF(SUM(...) FILTER (WHERE ...), 0)` — emits `NULL` for divide-by-zero instead of erroring. |
> | `WHERE year(order_date) = year(current_date)` in the OUTER `WHERE` clause (filtering the table to one year, then trying to compute YoY) | **WRONG — only this year's rows reach the aggregate.** The `WHERE` clause runs BEFORE aggregation, so it filters last year's rows out entirely. The denominator becomes 0/NULL for every product. The period predicates **belong inside `FILTER`**, NOT in the outer `WHERE`. | Leave the outer `WHERE` open to BOTH years (`WHERE order_date >= DATE '2025-01-01'` to scope the scan, OR no `WHERE` at all if the partition pruning is acceptable), and put the year selection inside each `FILTER (WHERE ...)` predicate. |
> | `... / SUM(amount) FILTER (WHERE year(order_date) = year(current_date) - 1)` as the divisor with NO `* 1.0` numerator (relying on Trino's "if either operand is decimal/double, the result is decimal/double") when `amount` is `bigint` | If `amount` is stored as `bigint` (the typical case for cents), both operands are `bigint` and the division truncates. The `* 1.0` is what introduces the decimal type. | Explicit `* 1.0` (or `CAST(numerator AS double)`) so the division promotes to floating-point. |
> | Using `EXTRACT(YEAR FROM order_date)` instead of `year(order_date)` | Both are valid Trino — `EXTRACT(YEAR FROM x)` and `year(x)` return the same value (`bigint`). Either works. This row is here only to confirm `EXTRACT` is NOT a parse error; pick whichever your team reads better. | No fix needed — both are valid. |

> **KEYWORD-LANDING repeat (so the responder routes here on the right English phrasing):** *this year's total revenue divided by last year's, year-over-year ratio per product, annual total vs last year total, this period vs last period total, this quarter's total divided by last quarter's, YoY growth ratio of totals, compare two years' totals side by side, full-year total YoY, period-total ratio per entity, total ÷ total ratio in one pass.*

> **Cross-references.** [FORM A / FORM B above](#pattern-b2-leading-canonical--period-over-period-yoy-vs-mom-with-window-functions-year-over-year--same-month-last-year--month-over-month--compare-to-last-year--lag-12-months--growth-vs-last-year--period-over-period) — when the question is a per-month series (not a one-ratio-per-entity period total). [Share of grand total — § share-of-grand-total card](#) earlier in this file for the related "subset SUM ÷ grand-total SUM in ONE pass" final-assembly pattern (same conditional-aggregation idiom, different ratio). [Resource 23 § 11 — duplicate-subquery collapse + `FILTER (WHERE ...)`](23-sql-best-practices-olap.md#11-use-ctes-or-subqueries--dont-re-run-the-same-expensive-query-twice) for the broader "compute multiple metrics in one scan via `FILTER`" pattern.

#### Sub-canonical — ACTIVE in EVERY one of the last N FULL calendar months (BOTH-BOUNDS window + `HAVING COUNT(DISTINCT date_trunc('month', d)) = N`) (iter640 FIX-B)

> **Keyword anchors (READ THIS FIRST if your question contains any of these):** customers active in every one of the last N months, ordered every month for N months straight, bought every month for the last 3 months, present in all N periods, active all N consecutive months, customers who placed an order in each of the last 3 months, users active every single month for 6 months, retained every month, no-skip retention, full-period active, every-month customers.

> **The fact in one sentence.** To find entities that were **active in every one of the last N FULL calendar months** — NOT today's partial month, NOT some-month-in-the-window — `GROUP BY` the entity and require `COUNT(DISTINCT date_trunc('month', activity_date)) = N` over a window that has **BOTH a lower AND an upper bound**: lower bound = `date_add('month', -N, date_trunc('month', current_date))`, upper bound = `date_trunc('month', current_date)` (the start of the CURRENT month, exclusive). The upper bound is the load-bearing piece — without it, the **current partial month** leaks in and can count as a fully-active month after just one order today, inflating retention.

> **CANONICAL — customers who placed an order in EVERY one of the last 3 FULL calendar months:**
>
> ```sql
> -- N = 3 (the last 3 FULL calendar months — excludes the current, in-progress month)
> SELECT customer_id
> FROM iceberg.analytics.orders
> WHERE order_date >= date_add('month', -3, date_trunc('month', current_date))   -- lower bound: 3 months ago, 1st of the month
>   AND order_date <  date_trunc('month', current_date)                          -- upper bound: 1st of CURRENT month (EXCLUSIVE — drops the partial month)
> GROUP BY customer_id
> HAVING COUNT(DISTINCT date_trunc('month', order_date)) = 3;                    -- distinct calendar months touched == N
> ```
>
> **Why each piece is load-bearing:**
> - **`date_trunc('month', current_date)`** as the **upper bound** is what excludes the current in-progress month. If today is `2026-06-07`, `date_trunc('month', current_date)` = `DATE '2026-06-01'`. With `order_date < DATE '2026-06-01'`, every June-2026 row is dropped — only the three full months `2026-03`, `2026-04`, `2026-05` enter the aggregate. WITHOUT this upper bound, a customer who ordered once in March, once in April, and once in early June (and skipped May) would silently satisfy `COUNT(DISTINCT date_trunc('month', order_date)) = 3` even though they SKIPPED a month — that is a wrong answer.
> - **`date_add('month', -3, date_trunc('month', current_date))`** as the **lower bound** is the start of the Nth-most-recent FULL month. If today is `2026-06-07`, this evaluates to `DATE '2026-03-01'` — March 1, three months back from the start of the current month. Combined with the upper bound, the window is `[2026-03-01, 2026-06-01)` — exactly the last 3 full months, no off-by-one.
> - **`COUNT(DISTINCT date_trunc('month', order_date)) = N`** counts how many DISTINCT calendar months the customer was active in. A customer who placed 10 orders in March and zero in April + May has `COUNT(DISTINCT date_trunc('month', order_date)) = 1`, not 3 — so they are correctly excluded. A customer with one order in each of March, April, May has `= 3` and passes.

> **DO-NOT-WRITE — period-coverage specific:**
>
> | DO NOT write | Why it's wrong / silently-wrong | Correct form |
> |---|---|---|
> | **Lower bound ONLY** (`WHERE order_date >= date_add('month', -3, current_date)`) — no upper bound, AND using bare `current_date` not `date_trunc('month', current_date)` as the lower anchor | The current in-progress month leaks in. A customer who ordered in March, April, and then placed any order in early June (skipping May entirely) would emit `COUNT(DISTINCT date_trunc('month', order_date)) = 3` and pass — **but they SKIPPED May**, so they were not active every month. Silent-wrong retention number. | Add the upper bound `AND order_date < date_trunc('month', current_date)` AND anchor the lower bound to `date_trunc('month', current_date)` (not bare `current_date`). |
> | `WHERE order_date >= current_date - INTERVAL '3' MONTH` then `HAVING COUNT(DISTINCT date_trunc('month', order_date)) >= 3` (no upper bound, `>=` not `=`) | Same leak as above + the `>=` allows N+1 months (4 months of activity passes when you asked for "every one of the last 3"). The `=` is what enforces "every one — not more, not fewer." | Both bounds + `HAVING COUNT(DISTINCT date_trunc('month', order_date)) = N`. |
> | `HAVING COUNT(*) = N` instead of `HAVING COUNT(DISTINCT date_trunc('month', order_date)) = N` | `COUNT(*) = N` requires exactly N **rows** (one per month). A customer who placed 2 orders in March and 1 each in April + May has 4 rows, not 3 — they would FAIL the filter even though they were active every month. | `COUNT(DISTINCT date_trunc('month', order_date)) = N` — counts distinct **months touched**, not row count. |

> **Cross-references.** Same DISTINCT-over-period idiom but counting DISTINCT user_ids in [§3 cohort retention](#3-cohort-analysis-retention-over-time) above. The half-open window pattern `[lo, hi)` is the same `[start, end)` half-open convention used for [interval-overlap range joins](#leading-canonical--count-activeopen-intervals-on-each-day-interval-overlap-range-join--not-forward-fill-not-a-current_date-snapshot) — both rely on the upper bound being EXCLUSIVE to avoid boundary double-count / partial-month leak.

### Pattern B3: LEADING CANONICAL — `first_value` / `last_value` / `nth_value` (the default-frame footgun)

> **Keyword anchors so the responder lands here:** first_value last_value Trino, last value per group, last value per session, last value per partition, nth_value window function, last_value returns current row not last, window frame default RANGE UNBOUNDED PRECEDING CURRENT ROW, first event per session, first row per group window function, unbounded following frame, value window function. Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) (Value functions + Window frames sections).

`first_value(x)`, `last_value(x)`, and `nth_value(x, n)` are **value window functions** — they return a value of `x` from a specific row inside the window **FRAME** (not the full partition). The frame default is the load-bearing footgun.

**The default frame when `ORDER BY` is present and no frame is specified is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`** (same default that catches running totals — see Pattern A above). The frame **ends at the current row's peer group**, NOT at the end of the partition.

| Function | Default-frame behavior | Get the "obvious" answer with |
|---|---|---|
| `first_value(x) OVER (PARTITION BY p ORDER BY o)` | Returns the first row's value in the partition. **Safe with the default frame** — the frame starts at `UNBOUNDED PRECEDING`, so the first row is always in-frame. | (use default frame — works) |
| `last_value(x) OVER (PARTITION BY p ORDER BY o)` | **Returns the CURRENT row's value** (or the last peer when ORDER BY has ties) — NOT the partition's last value. The frame ENDS at current row, so the "last in frame" is the current row. | **You MUST set the frame explicitly:** `last_value(x) OVER (PARTITION BY p ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)`. |
| `nth_value(x, n) OVER (PARTITION BY p ORDER BY o)` | Returns NULL once `n` exceeds the current frame size (which only spans up through the current row by default) — typically silently NULL for `n > 1` on early rows. | For "nth across the whole partition", same explicit fix: `... ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. |

**Worked example — first event and last event per session:**

```sql
-- first_value with the default frame is SAFE (frame starts at UNBOUNDED PRECEDING).
-- last_value REQUIRES the explicit UNBOUNDED-FOLLOWING frame.
SELECT
  session_id,
  event_time,
  event_type,
  first_value(event_type) OVER (
    PARTITION BY session_id ORDER BY event_time
  ) AS first_event,                              -- default frame is fine
  last_value(event_type) OVER (
    PARTITION BY session_id ORDER BY event_time
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
  ) AS last_event                                -- explicit frame REQUIRED
FROM iceberg.analytics.events;
```

**Cleaner alternative when you need the WHOLE first/last row (not just one column):** a `ROW_NUMBER()` filter is usually clearer than chaining a `first_value` / `last_value` per column:

```sql
-- First row per session — all columns, no per-column window calls.
SELECT * FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY event_time ASC) AS rn
  FROM iceberg.analytics.events
) WHERE rn = 1;
-- For "last row per session": ORDER BY event_time DESC, same rn = 1 filter.
```

**DO-NOT-WRITE — banned patterns (these silently return the wrong value, NO error message):**

| DO NOT write | Why it's wrong / silently-wrong |
|---|---|
| `last_value(x) OVER (PARTITION BY p ORDER BY o)` expecting the partition's LAST value | **SILENT-WRONG.** Default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — frame ENDS at the current row's peer group, so `last_value` returns the current row's value (or the last peer on ties), NOT the partition's true last value. **Fix:** add `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. |
| Omitting the explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame on `last_value` / `nth_value` when you want the true partition-wide answer | Same as above — without the explicit frame, every row sees a different (current-row-bounded) frame, and `last_value` / `nth_value(.., n > 1)` produce per-row values that are NOT the partition's last / nth. |
| `last_value(x) OVER (PARTITION BY p ORDER BY o RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` (with `RANGE`, not `ROWS`) | Syntactically valid but verbose / atypical; the canonical idiom in Trino docs and the rest of the OLAP world is the `ROWS` form. Stick with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. |
| Reaching for `last_value` when the goal is "the row with MAX(timestamp) per group" with all columns | Use the `ROW_NUMBER() OVER (... ORDER BY timestamp DESC) = 1` subquery pattern shown above — far cleaner than a separate `last_value(col, ROWS ... UNBOUNDED FOLLOWING)` per column. |

**Cross-reference to the same frame default.** This is the SAME default-frame rule that affects running totals — see Pattern A's RANGE-vs-ROWS callout (around the `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` discussion) and Pattern D's rolling-average frame discussion. The frame default is one concept; it lands as a footgun in three places: running totals (default RANGE groups peers), rolling averages (default doesn't slide), and `last_value` / `nth_value` (default ends at current row, not partition end).

> **DECISION INOCULATION — "ONE ROW per group showing the FIRST and LAST value of a column" → use the AGGREGATE form `min_by` / `max_by` with `GROUP BY`, NOT `first_value` / `last_value` window functions mixed with `GROUP BY` (iter658 PIN — landing-point lock).** *Keyword anchors so the responder lands here on every shape:* first and last value per group, first and latest status per user, earliest and most recent status per entity, first_value last_value with GROUP BY, one row per entity first and last, first and current value per id, first and last STATE per ID, opening and closing value per entity, status of first login and status of last login per user, first and current plan tier per subscriber, first and latest reading per sensor, opening and closing reading per device, earliest and latest STATE per group in one row, first and last status per ticket, earliest and most recent value per group, first AND latest login status per user. When the question is *"give me the **FIRST** and **LAST** value of a column (e.g. `status`) per entity (e.g. `user_id`), in **ONE ROW per entity**"* — reach **DIRECTLY** for the AGGREGATE form documented at [resource 23 §3.1D — `max_by` / `min_by`](23-sql-best-practices-olap.md#max_byx-y--min_byx-y--deterministic-pick-of-x-by-the-ordering-column-y) **(see the iter656 DECISION block at r23:636 / line 652)**: `min_by(status, ts) AS first_status, max_by(status, ts) AS last_status ... GROUP BY entity_id`. **`min_by` / `max_by` are aggregate functions** (verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — *"Returns the value of `x` associated with the maximum value of `y` over all input values."*) — they collapse to **ONE row per GROUP BY group**, which is exactly the shape the question asks for. **`first_value` / `last_value` are WINDOW functions** (verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) — Value functions section, above) — they return one value **per input row**, not per group, and **cannot be mixed with `GROUP BY` on a column that is not in the GROUP BY and not wrapped in an aggregate**.
>
> **DO NOT WRITE — `first_value` / `last_value` window functions mixed with `GROUP BY entity_id`:**
>
> ```sql
> -- ❌ INVALID Trino 467 — window functions reference `status` and `ts`,
> --    neither of which is in `GROUP BY id` nor wrapped in an aggregate.
> --    Analyzer rejects: "must be an aggregate expression or appear in GROUP BY clause".
> SELECT id,
>        first_value(status) OVER (PARTITION BY id ORDER BY ts) AS first_status,
>        last_value(status)  OVER (PARTITION BY id ORDER BY ts
>                                  ROWS BETWEEN UNBOUNDED PRECEDING
>                                           AND UNBOUNDED FOLLOWING) AS last_status
> FROM iceberg.analytics.events
> GROUP BY id;   -- ❌ window funcs reference status/ts — neither in GROUP BY id nor aggregated
> ```
>
> **Two correct fixes:**
>
> 1. **PREFERRED ✅ — `min_by` + `max_by` AGGREGATES with `GROUP BY` (one pass, one row per id, no DISTINCT cost):**
>    ```sql
>    SELECT id,
>           min_by(status, ts) AS first_status,
>           max_by(status, ts) AS last_status
>    FROM iceberg.analytics.events
>    GROUP BY id;
>    ```
>    This is the canonical idiom for "one row per entity, first and last value of a column" — see [resource 23 §3.1D DECISION block at line 652](23-sql-best-practices-olap.md#31d-arbitrary--any_value-pick-one-value-per-group-and-max_by--min_by-deterministic-representative-value-pick) for the full DECISION lock with worked example.
>
> 2. **Window form WITHOUT `GROUP BY` + `SELECT DISTINCT` to collapse to one row per entity** (strictly worse — extra `DISTINCT` cost, but valid):
>    ```sql
>    SELECT DISTINCT id,
>           first_value(status) OVER (PARTITION BY id ORDER BY ts) AS first_status,
>           last_value(status)  OVER (PARTITION BY id ORDER BY ts
>                                     ROWS BETWEEN UNBOUNDED PRECEDING
>                                              AND UNBOUNDED FOLLOWING) AS last_status
>    FROM iceberg.analytics.events;
>    -- The window form yields one row per INPUT ROW (per event); SELECT DISTINCT
>    -- collapses to one-per-id. Cheaper to just use min_by/max_by aggregates above.
>    ```
>
> **Mnemonic:** **"one row per entity, FIRST and LAST value of a column" = TWO aggregates (`min_by` + `max_by`) with ONE `GROUP BY entity_id`.** Reserve `first_value` / `last_value` window functions for the case where you want to KEEP every detail row and annotate each with its partition's first/last value (no `GROUP BY` collapse) — that is the shape Pattern B3 above is built for (default-frame footgun lock). If the answer must collapse to one-row-per-entity, the aggregate form is the right tool. Cross-link: [resource 23 §3.1D iter656 DECISION block at line 652](23-sql-best-practices-olap.md#31d-arbitrary--any_value-pick-one-value-per-group-and-max_by--min_by-deterministic-representative-value-pick) + the [Trino GROUP BY rules anchor in §3.1G / r23 line ~1521](23-sql-best-practices-olap.md#trino-group-by-rules-anchor--apply-to-every-group-by-query).

### Pattern C: Rank (top-N per group)

"Top 10 highest-value orders per tenant."

```sql
SELECT *
FROM (
  SELECT
    tenant_id,
    order_id,
    amount,
    RANK() OVER (PARTITION BY tenant_id ORDER BY amount DESC) AS revenue_rank
  FROM iceberg.analytics.orders
  WHERE order_date >= DATE '2026-01-01'
)
WHERE revenue_rank <= 10;
```

Rank function variants:
- `ROW_NUMBER()` — assigns a strictly increasing integer (1, 2, 3, 4) within the partition. Ties break arbitrarily.
- `RANK()` — ties get the same rank, then the next rank skips (1, 2, 2, 4).
- `DENSE_RANK()` — ties get the same rank, no gap (1, 2, 2, 3).
- `PERCENT_RANK()` — relative position as a fraction in `[0.0, 1.0]`. Formula: `(rank - 1) / (n - 1)` where `n` is partition row count. **The FIRST row in the `ORDER BY` gets `0.0`; the LAST row gets `1.0`** — so "top" and "bottom" depend on sort direction (see the **PERCENT_RANK / NTILE direction guardrail** sub-section below — the iter634 silent-wrong bug was inverting the threshold for `ORDER BY metric DESC`). **Returns NULL when the partition has only one row** (divide-by-zero). Useful for "what percentile is this tenant in?" without computing a histogram.
- `NTILE(n)` — divides the partition into `n` roughly-equal buckets (quartiles=4, deciles=10, percentiles=100), returning the bucket number `1..n` for each row. **Remainder rows go to the EARLIEST buckets**: e.g., 10 rows with `NTILE(3)` → buckets are size 4/3/3, not 3/3/4. **The frame clause MUST be omitted** (Trino errors if you specify `ROWS BETWEEN ...` with `NTILE`).

Pick `ROW_NUMBER()` if you literally need "exactly 10 rows per tenant"; pick `RANK()`/`DENSE_RANK()` if you want to include all ties at rank 10.

### Pattern C2: `PERCENT_RANK` — "what percentile is this tenant in?"

"For each tenant, compute their relative position in the revenue distribution across the SaaS customer base."

```sql
SELECT
  tenant_id,
  total_revenue,
  PERCENT_RANK() OVER (ORDER BY total_revenue) AS revenue_percentile
FROM (
  SELECT tenant_id, SUM(amount) AS total_revenue
  FROM iceberg.analytics.orders
  WHERE order_date >= CURRENT_DATE - INTERVAL '90' DAY
  GROUP BY tenant_id
);
-- Returns one row per tenant with their percentile in [0.0, 1.0].
-- tenant with the lowest revenue: 0.0
-- tenant with the highest revenue: 1.0
-- median tenant: ~0.5
```

**When to pick `PERCENT_RANK` over computing percentiles directly:**
- You want a percentile **per row** (not just a few summary percentiles for the whole table). `PERCENT_RANK` returns the percentile of each individual row's value; `approx_percentile` returns only the value at a specified percentile.
- You're building a "your tenant is in the top X%" widget for a SaaS dashboard — one query, no second pass.
- The data set fits in a window-sort (a few million rows or fewer). For 500M+ rows where you only need summary percentiles (p50, p95, p99), use `approx_percentile` instead — sorting that many rows in a window is expensive.

**Edge case — single-row partition.** `PERCENT_RANK` returns NULL (the formula divides by `n - 1` which is 0). Guard with `COALESCE(PERCENT_RANK() OVER (...), 0.0)` if your downstream consumer can't handle NULLs.

**Sibling: `CUME_DIST` (cumulative distribution).** Trino also supports `CUME_DIST()` which returns `count_of_peers_or_lower / n` — slightly different math (the top row is `1.0`, not `(n-1)/n`). Use `PERCENT_RANK` for "fraction of rows STRICTLY below this one" and `CUME_DIST` for "fraction of rows AT OR BELOW this one." Like `PERCENT_RANK`, `CUME_DIST` is **sort-direction dependent**: under `ORDER BY x DESC`, the row with the LARGEST `x` is the first row and gets `cume_dist = 1/n` (small), the row with the smallest `x` gets `1.0` — see the guardrail immediately below.

#### LEADING CANONICAL — PERCENT_RANK / NTILE direction guardrail (iter635 — "top X% by metric" inversion trap)

> **READ THIS FIRST if your question contains:** `top 10% of customers by spend`, `share of revenue from the top decile`, `highest-spending 10%`, `top N percent by a metric`, `what percent of revenue comes from the top X%`, `bottom decile by revenue`, `customers in the top quartile by ARR`, `PERCENT_RANK >= 0.9 vs <= 0.1`, `which side of percent_rank is the top`, `NTILE bucket 1 vs bucket 10`. Verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) on 2026-06-07.

**The one fact you must keep straight.** `PERCENT_RANK()` assigns **`0.0` to the FIRST row in the `ORDER BY`** and `1.0` to the LAST row. What "the top of your metric" means therefore depends on the sort direction. The iter634 silent-wrong bug was writing `PERCENT_RANK() OVER (ORDER BY total_revenue DESC) >= 0.9` for "top 10% by spend" — which selects the **BOTTOM 10%** (lowest spenders), because under `DESC` the highest spender is the FIRST row and gets `percent_rank = 0.0`, while the lowest spender is the LAST row and gets `percent_rank = 1.0`. The threshold `>= 0.9` therefore catches the bottom decile, not the top.

**Decision table — use this verbatim. Each row gives the exact direction + threshold pair that picks the TOP 10% (or BOTTOM 10%) of a metric.**

| Question | `ORDER BY` direction | Threshold | Which rows it returns | Why |
|---|---|---|---|---|
| Top 10% of customers by `spend` | `ORDER BY spend DESC` | `PERCENT_RANK() <= 0.10` | Highest-spend 10% | Highest spender = first row = `percent_rank = 0.0`; top decile clusters near `0.0`. |
| Top 10% of customers by `spend` (sorted ASC) | `ORDER BY spend ASC` | `PERCENT_RANK() >= 0.90` | Highest-spend 10% | Highest spender = last row = `percent_rank = 1.0`; top decile clusters near `1.0`. |
| Bottom 10% by `spend` (sorted DESC) | `ORDER BY spend DESC` | `PERCENT_RANK() >= 0.90` | Lowest-spend 10% | Lowest spender = last row = `1.0`. |
| Bottom 10% by `spend` (sorted ASC) | `ORDER BY spend ASC` | `PERCENT_RANK() <= 0.10` | Lowest-spend 10% | Lowest spender = first row = `0.0`. |
| Top decile by spend, **count-based, exact bucket** | `ORDER BY spend DESC` | `NTILE(10) = 1` | Top decile (highest 10%) | `NTILE` numbers buckets `1..n` in `ORDER BY` order; under `DESC`, bucket `1` is the highest-spend group. |
| Top decile by spend, **count-based**, sorted ASC | `ORDER BY spend ASC` | `NTILE(10) = 10` | Top decile (highest 10%) | Under `ASC`, bucket `10` is the last bucket = highest values. |

**Mnemonic.** `percent_rank = 0.0` = **FIRST row in the sort**. Pick the threshold for the side of the sort where your target rows land — never assume `>= 0.9` means "the top."

> **DO NOT WRITE — the exact iter634 silent-wrong inversion.**
>
> ```sql
> -- WRONG: this selects the BOTTOM 10% (lowest spenders), not the top.
> -- Under ORDER BY ... DESC, the highest spender is the FIRST row and gets percent_rank 0.0,
> -- so the top decile is percent_rank <= 0.1, NOT >= 0.9.
> SELECT customer_id, total_revenue
> FROM (
>   SELECT customer_id, total_revenue,
>          PERCENT_RANK() OVER (ORDER BY total_revenue DESC) AS pr
>   FROM customer_revenue
> )
> WHERE pr >= 0.9;             -- ❌ bottom decile, not top
>
> -- RIGHT (option 1 — keep DESC sort, flip the threshold):
> SELECT customer_id, total_revenue
> FROM (
>   SELECT customer_id, total_revenue,
>          PERCENT_RANK() OVER (ORDER BY total_revenue DESC) AS pr
>   FROM customer_revenue
> )
> WHERE pr <= 0.10;            -- ✅ top decile under DESC
>
> -- RIGHT (option 2 — keep the >= 0.9 threshold, flip the sort):
> SELECT customer_id, total_revenue
> FROM (
>   SELECT customer_id, total_revenue,
>          PERCENT_RANK() OVER (ORDER BY total_revenue ASC) AS pr
>   FROM customer_revenue
> )
> WHERE pr >= 0.90;            -- ✅ top decile under ASC
>
> -- RIGHT (option 3 — count-based exact decile, sort-direction-friendly):
> SELECT customer_id, total_revenue
> FROM (
>   SELECT customer_id, total_revenue,
>          NTILE(10) OVER (ORDER BY total_revenue DESC) AS decile
>   FROM customer_revenue
> )
> WHERE decile = 1;            -- ✅ bucket 1 under DESC = highest-spend decile
> ```
>
> **DO NOT WRITE — the inverted prose explanation.** "`PERCENT_RANK = 0.0` means the bottom, `1.0` means the top" is **WRONG in general** — it is true only under `ORDER BY metric ASC`. Under `ORDER BY metric DESC`, `0.0` is the TOP (highest value) and `1.0` is the BOTTOM. Always pair the percent_rank threshold with the sort direction you actually wrote.

**PERCENT_RANK vs NTILE for "top X%" — pick the right tool.**

| Need | Use |
|---|---|
| "Top X% by metric" where X is a fraction (e.g. top 5%, top 1%) AND you want a fractional cutoff (some rows may tie at the boundary and all get included) | `PERCENT_RANK()` with the threshold from the decision table above. |
| "Top decile / top quartile / top percentile by metric" as **exact equal-size count-based buckets** (e.g. exactly 10 deciles labeled 1..10) | `NTILE(N)` with `= 1` under `DESC` (or `= N` under `ASC`). Count-based: each bucket has roughly `total_rows / N` rows; ties between two rows on the metric may land on opposite sides of a bucket boundary. |
| "Share of revenue from the top 10% of customers" (compose top-decile filter + share-of-grand-total) | `NTILE(10)` (or `PERCENT_RANK <=/>= 0.10/0.90`) in an inner query, then `SUM(revenue) FILTER (WHERE decile = 1) / SUM(revenue) OVER ()` in the outer — see the share-of-grand-total canonical earlier in this resource (`100.0 * x / SUM(x) OVER ()`). |

**Cross-references.** [§ Pattern C2 `PERCENT_RANK`](#pattern-c2-percent_rank--what-percentile-is-this-tenant-in) above for the per-row percentile use case. [§ Pattern C3 `NTILE`](#pattern-c3-ntile--bucket-rows-into-equal-size-groups-quartiles-deciles-percentile-buckets) below for the count-based equal-size-bucket recipe and the remainder rule. [§ share-of-grand-total `SUM(x) OVER ()`](#) earlier in this file for composing top-decile + share-of-revenue. [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) for the verbatim `percent_rank` and `ntile` definitions.

### Pattern C3: `NTILE` — bucket rows into equal-size groups (quartiles, deciles, percentile buckets)

"Bucket each tenant into one of 10 deciles based on monthly active users so a dashboard can show 'top decile' / 'bottom decile' segments."

```sql
SELECT
  tenant_id,
  monthly_active_users,
  NTILE(10) OVER (ORDER BY monthly_active_users) AS mau_decile
FROM (
  SELECT tenant_id, COUNT(DISTINCT user_id) AS monthly_active_users
  FROM iceberg.analytics.feature_usage
  WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY
  GROUP BY tenant_id
);
-- Each tenant assigned a bucket 1..10.
-- Bucket 1 = lowest MAU tenants, Bucket 10 = highest MAU tenants.
```

> **ANTI-PATTERN — DO NOT filter a window-function result (`NTILE` / `ROW_NUMBER` / `RANK` / `DENSE_RANK` / `PERCENT_RANK` / etc.) in the SAME-level `WHERE`.** `WHERE` runs BEFORE the window function is computed (per the [Trino window docs](https://trino.io/docs/current/functions/window.html), window functions run *after* `HAVING` but *before* `ORDER BY`; they are only allowed in the `SELECT` and `ORDER BY` clauses), so the window result is NOT referenceable in `WHERE` and the query fails to plan. Wrap the windowed query in an OUTER `SELECT` and filter there. **Trino 467 has NO `QUALIFY` keyword** — use the outer-wrapper subquery filter.
>
> ```sql
> -- WRONG — `tier` is a window-function output; WHERE cannot see it (and runs before it is computed).
> SELECT tenant_id, NTILE(4) OVER (ORDER BY revenue) AS tier
> FROM t
> WHERE tier = 1;          -- ERROR: column 'tier' cannot be resolved / window result not allowed in WHERE
>
> -- RIGHT — compute the window in an inner query, filter the alias in the OUTER SELECT.
> SELECT *
> FROM (
>   SELECT tenant_id, NTILE(4) OVER (ORDER BY revenue) AS tier
>   FROM t
> )
> WHERE tier = 1;          -- top-quartile-only: filter lives one query level out
> ```
>
> Note the difference from the `WHERE monthly_revenue IS NOT NULL` filter shown later in this pattern: that filters a **base column** (`monthly_revenue`), which is fine and is evaluated normally before the window runs. The ban is specifically on filtering a window-function *output alias* (`tier`, `rn`, `decile`, …) at the same level.

**The remainder rule (this trips up engineers — read carefully).** `NTILE(n)` divides `rows_in_partition` by `n` and distributes the remainder `r` to the **first `r` buckets**, each of which gets one extra row.

| Rows in partition | `NTILE(4)` bucket sizes |
|---|---|
| 12 (12 ÷ 4 = 3, no remainder) | `3, 3, 3, 3` |
| 13 (13 ÷ 4 = 3 remainder 1) | `4, 3, 3, 3` — bucket 1 gets the extra row |
| 14 (14 ÷ 4 = 3 remainder 2) | `4, 4, 3, 3` — buckets 1 and 2 each get an extra |
| 15 (15 ÷ 4 = 3 remainder 3) | `4, 4, 4, 3` — buckets 1, 2, 3 each get an extra |

**This matters for SaaS metrics.** If you have 9,997 tenants and you compute `NTILE(10)` for "decile of revenue", the deciles are NOT all 999.7 rows each — they are `1000, 1000, 1000, 1000, 1000, 1000, 1000, 999, 999, 999` (first 7 buckets get the rounding-up). If a dashboard says "top decile = top 1000 tenants" and the real answer is "top decile = 999 tenants on this distribution", an audit may flag the off-by-one. State the rule explicitly in dashboard documentation, or use the `PERCENT_RANK` exact-cutoff form **with the direction-correct threshold from the [PERCENT_RANK / NTILE direction guardrail](#leading-canonical--percent_rank--ntile-direction-guardrail-iter635--top-x-by-metric-inversion-trap) above** — `PERCENT_RANK() OVER (ORDER BY revenue DESC) <= 0.10` for the top decile under `DESC`, or `PERCENT_RANK() OVER (ORDER BY revenue ASC) >= 0.90` under `ASC`. Do NOT write the direction-naive `PERCENT_RANK() >= 0.9` without checking the sort direction (under `DESC`, `>= 0.9` selects the BOTTOM decile).

**The no-frame restriction.** Per the [Trino window functions docs](https://trino.io/docs/current/functions/window.html), `NTILE` **must not** be invoked with a window frame:

```sql
-- WRONG — Trino errors with "ntile cannot be used with a window frame".
SELECT NTILE(10) OVER (
  ORDER BY revenue
  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW   -- ILLEGAL with NTILE
) FROM customers;

-- CORRECT — omit the frame clause entirely.
SELECT NTILE(10) OVER (ORDER BY revenue) FROM customers;
```

This restriction applies to all the **ranking functions** in Trino (`ROW_NUMBER`, `RANK`, `DENSE_RANK`, `PERCENT_RANK`, `CUME_DIST`, `NTILE`) — frames are only meaningful for value-aggregating window functions like `SUM` / `AVG` / `LAG` / `LEAD`. Ranking functions operate over the entire partition by definition.

**When to pick `NTILE` over `PERCENT_RANK` or manual `CASE` bucketing:**

| Need | Use |
|---|---|
| Bucket every row into one of `N` named groups (deciles, quartiles, percentile bands) | `NTILE(N)` — concise, single window pass |
| Continuous percentile score per row (`0.0–1.0`) | `PERCENT_RANK()` — gives you the fraction, you decide the bucket boundaries |
| Custom (non-equal-size) buckets like "0-1k MAU", "1k-10k MAU", "10k+ MAU" | `CASE WHEN ... THEN ... END` over the column directly — `NTILE` only does equal-size bucketing |
| Exact "top 10% of tenants" — guaranteed cutoff regardless of count | `PERCENT_RANK()` filter **with the direction-correct threshold** (see [direction guardrail](#leading-canonical--percent_rank--ntile-direction-guardrail-iter635--top-x-by-metric-inversion-trap) above): `<= 0.10` under `ORDER BY metric DESC` or `>= 0.90` under `ORDER BY metric ASC` — avoids the `NTILE` remainder-row off-by-one |

**NULL handling — filter NULLs out BEFORE the NTILE.** When the column you're bucketing on contains NULL values, NTILE doesn't skip them — it sorts them and assigns them to a bucket like any other value. Trino's **default NULL ordering is `NULLS LAST`** (regardless of `ASC` or `DESC`), per the [Trino SELECT docs](https://trino.io/docs/current/sql/select.html). So in `NTILE(10) OVER (ORDER BY revenue)` with some NULL revenues, the NULL rows land in the **highest deciles** (buckets 9 and 10) — which is almost certainly wrong for a "top decile = highest revenue" interpretation. Always filter NULLs explicitly:

```sql
-- WRONG — NULLs sort to the end (NULLS LAST default), landing in the top deciles.
SELECT
  tenant_id,
  monthly_revenue,
  NTILE(10) OVER (ORDER BY monthly_revenue) AS revenue_decile
FROM iceberg.analytics.tenant_revenue;
-- Result: tenants with NULL revenue get assigned to decile 9 or 10, polluting your "top 10%" answer.

-- CORRECT — pre-filter NULLs before the window function.
SELECT
  tenant_id,
  monthly_revenue,
  NTILE(10) OVER (ORDER BY monthly_revenue) AS revenue_decile
FROM iceberg.analytics.tenant_revenue
WHERE monthly_revenue IS NOT NULL;          -- explicit NULL filter
-- Alternative: keep NULLs in the result set but exclude them from the windowing.
-- The cleanest pattern is the WHERE filter above; Trino does NOT support `NTILE(...) OVER (... NULLS EXCLUDE)`.
```

If you can't drop the NULL rows (e.g., the result set needs all tenants present), bucket only the non-NULL rows via a subquery and `LEFT JOIN` the NULL rows back with `revenue_decile = NULL`. Do not rely on `NULLS FIRST` to "hide" them in bucket 1 — that just moves the bug.

### Pattern C4: `width_bucket` — bucket a numeric value into a histogram (equal-width OR custom/uneven bins) WITHOUT a long CASE WHEN ladder

**Keyword anchors:** Trino width_bucket, bucket numeric range, histogram bins Trino, uneven/custom buckets, session duration buckets, bin a continuous value, histogram without CASE WHEN, score buckets, latency buckets, price tier buckets. Verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html).

> **READ THIS FIRST — "fixed-width bands" / "count rows per band" phrasing routes HERE (width_bucket), not just CASE WHEN.** If the question says any of: *"fixed-width bands"*, *"100ms-wide bands"*, *"100ms buckets"*, *"fixed $25-wide bands"*, *"count requests per band"*, *"fixed dollar ranges like 0-50 / 50-100 / 100-150"*, *"a catch-all / overflow top band"*, *"everything over X in its own bucket"*, *"assign each row to a fixed-width numeric band"* — consider `width_bucket` FIRST. It assigns each row to a band in ONE function call (no long ladder), and it gives you a free overflow bucket for the "everything over X" catch-all.
>
> **width_bucket vs CASE WHEN — a decision, NOT a ban (pick by what you need):**
>
> | What you need | Use | Why |
> |---|---|---|
> | Many EQUAL-WIDTH bins; you just want a **numeric bucket id** to GROUP BY; fewer typos | **`width_bucket`** | one call, returns a `bigint` band id, no 8-line ladder to mistype |
> | A **human-readable string label** per band (`'0-100ms'`, `'1s+'`) attached in the SELECT | **`CASE WHEN`** | CASE lets you write the label text directly; width_bucket returns a number |
>
> To get labels FROM width_bucket you can map the returned bucket id (e.g. `CASE width_bucket(...) WHEN 1 THEN '0-100ms' ... END`), but if labels are the whole point, a plain `CASE WHEN` is simpler. Net: **numeric id / many equal bins → `width_bucket`; custom string labels → `CASE WHEN`.** (The iter601 engineer wanted readable band labels — `CASE WHEN` is correct there; an engineer who just wants a band-id count per band wants `width_bucket`.)
>
> **Worked — "fixed 100ms-wide latency bands + an over-1-second catch-all" → `width_bucket(x, ARRAY[...])`:**
> ```sql
> -- Bands: 0-100, 100-200, 200-300, 300-400, 400-500, 500-1000, and 1000+ (the over-1s catch-all).
> -- A 6-element bounds array makes 7 buckets (0..6). Bucket 6 = >= 1000 = the "over 1 second" top band.
> SELECT width_bucket(response_time_ms, ARRAY[100.0, 200.0, 300.0, 400.0, 500.0, 1000.0]) AS latency_band,
>        COUNT(*) AS requests
> FROM iceberg.analytics.requests
> GROUP BY 1 ORDER BY 1;
> ```
> The catch-all "everything >= 1000ms" lands in bucket **`N` = `6`** (the array has 6 = `cardinality(bins)` elements), the overflow bin — see the "top bin is bucket `N`, NOT `N-1`" trap below. If you instead want pretty labels, wrap that exact `width_bucket(...)` in `CASE ... WHEN 6 THEN '1s+' WHEN 0 THEN '0-100ms' ... END`, or skip width_bucket and write a plain `CASE WHEN response_time_ms < 100 THEN '0-100ms' ... WHEN response_time_ms >= 1000 THEN '1s+' END`.

Trino has `width_bucket` (BOTH overloads) — use it instead of a long `CASE WHEN x < 30 THEN 0 WHEN x < 60 THEN 1 ...` ladder when bucketing a continuous value:

- **Equal-width overload — `width_bucket(x, bound1, bound2, n) -> bigint`**: divides the range `[bound1, bound2]` into `n` equal-width buckets. Returns **`1..n`** for an in-range `x` (1-based), **`0`** if `x < bound1`, **`n+1`** if `x >= bound2`.
  ```sql
  -- 10 equal-width score buckets over [0, 1000] (each bucket width = 100).
  -- score=0->1, 99->1, 100->2, 999->10, 1000->11 (overflow), -5->0 (underflow).
  SELECT width_bucket(score, 0, 1000, 10) AS score_bucket, COUNT(*)
  FROM iceberg.analytics.lead_scores GROUP BY 1 ORDER BY 1;
  ```
- **Custom-bins (uneven) overload — `width_bucket(x, bins) -> bigint`** where `bins` is an **ASCENDING `ARRAY` of DOUBLE bounds**: returns the **0-based** number of bounds that `x` is `>=` (equivalently, the bin index). Returns `0` if `x < bins[0]`, `cardinality(bins)` if `x >= bins[last]`.
  ```sql
  -- Uneven session-duration buckets: 0-30 / 30-60 / 60-120 / 120+ seconds.
  -- session_duration_seconds=10->0, 45->1, 90->2, 300->3.
  SELECT width_bucket(session_duration_seconds, ARRAY[30.0, 60.0, 120.0]) AS dur_bucket,
         COUNT(*) AS sessions
  FROM iceberg.analytics.sessions
  GROUP BY 1 ORDER BY 1;
  ```
  Wrap the integer bucket index in a `CASE` ONLY if you want pretty labels (`'0-30s'`, `'30-60s'`, ...); the bucketing itself is one function call.

  **`0..N` numbering (the array overload) — the off-by-one rule.** For an `N`-element bounds array (`N = cardinality(bins)`), `width_bucket(x, bins)` returns a value in **`0..N`** — that is **`N + 1` distinct buckets**, NOT `N`:
  - **bucket `0`** = `x` is **below the first bound** (`x < bins[1]`) — the underflow bin.
  - **bucket `k`** (for `1 <= k < N`) = `x` is **between bound `k` and bound `k+1`** (`bins[k] <= x < bins[k+1]`).
  - **bucket `N`** = `x` is **at or above the LAST bound** (`x >= bins[N]`) — the overflow / **top** bin.

  **TRAP — the top bin is bucket `N`, NOT `N-1`.** The "`$500+`" / "`120s+`" open-ended top tier is bucket `N` (= `cardinality(bins)`), the overflow value. So a 10-element bounds array `ARRAY[50,100,150,...,500]` yields buckets `0..10` — **11 buckets** — and bucket `10` (= `width_bucket(x, bins) = 10`) is the `>= 500` `"$500+"` top bin. An N-element bounds array makes N+1 buckets; do not write `CASE width_bucket(...) WHEN N-1 THEN '$500+'` (off by one) — the top bin is `N`. (Verified against the Trino source `io.trino.operator.scalar.MathFunctions.widthBucket`: the array overload returns `numberOfBins` — i.e. `cardinality(bins)` — when the value is `>=` the last bin bound.)

**DO NOT WRITE** *"Trino has no `width_bucket` — it is Postgres-only"* (FALSE — Trino 467 has BOTH overloads, documented at `functions/math.html`); **DO NOT WRITE** a long `CASE WHEN ... THEN ... WHEN ... THEN ... END` ladder for numeric histogram bucketing when `width_bucket(x, ARRAY[...])` does uneven bins directly in one call. Update the Pattern C3 comparison table mental model: "Custom (non-equal-size) buckets" → `width_bucket(x, ARRAY[...])` is the **preferred Trino-native one-liner**; the CASE WHEN ladder is the fallback only when you need non-numeric bucketing (e.g., string-key bucketing) or per-bucket pretty labels mid-aggregation.

### Pattern C4a: Fixed-width $N histogram (every bucket the same width, open-ended top) — integer-division floor (iter650 FIX-A — the EXACT iter649 Q4 assembly bug fix)

> **READ THIS FIRST if your question contains any of these keywords:** `fixed-width $50 buckets`, `histogram of order amounts`, `bucket into 50-dollar bins`, `count orders per amount range`, `bin a numeric column into equal-width ranges`, `histogram without hardcoding buckets`, `session-duration buckets`, `age buckets 10 years wide`, `5-dollar bands`, `bin sales by dollar range`, `bucket into N-dollar groups`, `floor to nearest 50`, `round down to nearest bucket width`, `equal-width bins no fixed upper bound`. Verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) + [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) on 2026-06-08.

**DECIDE-FIRST — fixed-width $N bins vs explicit/custom bin edges.** Two shapes, two different idioms — pick by the question:

| Your bins are... | Use | Why |
|---|---|---|
| **Every bucket the same `$N` wide, open-ended top** ("$50 bins", "10-year age buckets", "5-minute session buckets", no upper bound spelled out) | **`floor(x/N)*N`** (or `CAST(x/N AS integer)*N` for non-negative values) as the `bucket_floor` — group by the floor expression | Simplest. No bounds array to maintain. The bucket label is the bucket's lower edge, and the top bin is automatically open-ended — bucket `1000` holds `[$1000, $1050)`, `1050` holds `[$1050, $1100)`, etc., for as far as the data goes. |
| **Explicit / non-uniform bin EDGES** (`[0, 50, 100, 200, 500]`, custom tiers, a fixed `$500+` catch-all top tier) | **`width_bucket(x, ARRAY[...])`** computed in a SUBQUERY/CTE, label and count in the outer query (Pattern C4 above) | Custom bin edges are exactly what `width_bucket(x, ARRAY[...])` is for. The Pattern C4 lock above covers the off-by-one rules. |

**The one-fact lead.** For **fixed-width $N bins** the simplest, docs-correct Trino idiom is **integer-division floor** — `floor(amount/N)*N` — used **both** in the `SELECT` (as the output bucket label) **and** repeated **verbatim** in the `GROUP BY`. There is no bounds array to maintain, no off-by-one to mishandle, and the top bin is automatically open-ended (whatever the data's max happens to be becomes the highest bucket on its own).

#### LEADING CANONICAL — count orders per fixed $50 amount range (the iter649 Q4 shape, FIXED)

```sql
-- CORRECT — fixed-width $50 histogram of order amounts.
-- floor(amount/50)*50 gives the bucket's LOWER edge ($0, $50, $100, $150, ...).
-- The GROUP BY REPEATS the expression verbatim (you cannot reference the SELECT-list
-- alias `bucket_floor` inside GROUP BY or inside another SELECT expression — see the
-- alias-visibility rule below). Trino's `floor(x)` returns the largest integer <= x;
-- multiplying by 50 maps each row to its $50 bucket's lower edge.
SELECT floor(order_amount / 50) * 50           AS bucket_floor,        -- $0, $50, $100, $150, ...
       COUNT(*)                                AS order_count
FROM iceberg.sales.orders
GROUP BY floor(order_amount / 50) * 50         -- REPEAT the expression — do NOT use `GROUP BY bucket_floor`
ORDER BY bucket_floor;
```

**Equivalent `CAST(... AS integer)` form** (works identically for non-negative `order_amount`; for negative values prefer `floor()` because `CAST(x AS integer)` truncates **toward zero**, not toward negative infinity, per [Trino math docs](https://trino.io/docs/current/functions/math.html)):

```sql
SELECT CAST(order_amount / 50 AS integer) * 50 AS bucket_floor,
       COUNT(*)                                AS order_count
FROM iceberg.sales.orders
GROUP BY CAST(order_amount / 50 AS integer) * 50
ORDER BY bucket_floor;
```

#### Adding a human-readable label — compute the bucket floor in an INNER CTE FIRST, then format() in the OUTER SELECT

You **cannot** use the `bucket_floor` alias inside another expression in the **same** SELECT list (`format('$%d-$%d', bucket_floor, bucket_floor + 50)` next to `floor(order_amount/50)*50 AS bucket_floor` is **invalid** — SELECT-list aliases are NOT visible to sibling SELECT-list expressions). Push the floor down into a CTE so `bucket_floor` becomes a **real column** in the outer query:

```sql
-- CORRECT — bucket_floor computed in the CTE; the outer SELECT formats a label from it.
WITH bucketed AS (
  SELECT floor(order_amount / 50) * 50 AS bucket_floor
  FROM iceberg.sales.orders
)
SELECT format('$%d-$%d', CAST(bucket_floor AS integer), CAST(bucket_floor + 50 AS integer)) AS amount_range,
       COUNT(*) AS order_count
FROM bucketed
GROUP BY bucket_floor                          -- real column from CTE; alias-by-name works here too via column ref
ORDER BY bucket_floor;
```

(See **resource 23 §3.1A concat/format coercion guardrail** for why `format('%d', x)` needs `CAST(x AS integer)` when `x` is `double` — `floor` returns the input's numeric type, often `double`.)

#### Secondary canonical — `width_bucket` with EXPLICIT/CUSTOM bin edges: compute bucket in a CTE, label and count in the OUTER query

When the bin edges are **explicit / non-uniform** (e.g. `[50, 100, 150, 200]`, a fixed `$200+` catch-all), use `width_bucket` — but compute the bucket number in an INNER CTE first, then label/count over the outer query (NEVER reference the `width_bucket` result alias inside a sibling SELECT expression — see the DO-NOT-WRITE rows below):

```sql
-- CORRECT — custom bin edges via width_bucket, computed in a CTE first.
-- 4-element bounds array -> buckets 0..4 (5 buckets total): bucket 0 = below $50,
-- bucket 4 = >= $200 (the open-ended top tier).
WITH bucketed AS (
  SELECT width_bucket(order_amount, ARRAY[50.0, 100.0, 150.0, 200.0]) AS bucket_num
  FROM iceberg.sales.orders
)
SELECT bucket_num,
       COUNT(*) AS order_count
FROM bucketed
GROUP BY bucket_num
ORDER BY bucket_num;
```

To attach a label, wrap once more — `bucket_num` is a real column in the outer query and can be referenced by name inside a `CASE` expression there:

```sql
WITH bucketed AS (
  SELECT width_bucket(order_amount, ARRAY[50.0, 100.0, 150.0, 200.0]) AS bucket_num
  FROM iceberg.sales.orders
)
SELECT CASE bucket_num
         WHEN 0 THEN '$0-$50'
         WHEN 1 THEN '$50-$100'
         WHEN 2 THEN '$100-$150'
         WHEN 3 THEN '$150-$200'
         WHEN 4 THEN '$200+'
       END AS amount_range,
       COUNT(*) AS order_count
FROM bucketed
GROUP BY bucket_num
ORDER BY bucket_num;
```

#### DO NOT WRITE — the EXACT iter649 Q4 assembly bugs

**(1) Referencing a SELECT-list alias inside a SIBLING SELECT-list expression — INVALID in Trino.**

```sql
-- WRONG ❌ — `bucket_num` is a SELECT-list alias; Trino does NOT resolve a SELECT
-- alias inside a sibling SELECT expression (output column aliases are visible ONLY
-- in ORDER BY, NOT inside other SELECT expressions, NOT in WHERE, NOT in GROUP BY,
-- NOT in HAVING — see resource 27 §4.2 alias-in-WHERE guard + resource 23 §8 line
-- 1521-1528 Trino GROUP BY rules anchor; the same scoping rule that bans
-- referencing a SELECT alias in WHERE also bans referencing it in a sibling SELECT
-- expression — both are evaluated in pre-projection scope).
SELECT width_bucket(order_amount, ARRAY[50, 100, 150, 200]) AS bucket_num,
       CASE WHEN bucket_num = 0 THEN '$0-$50'                     -- ❌ bucket_num is an alias, not a column here
            WHEN bucket_num = 4 THEN '$200+'
            ELSE 'mid'
       END AS amount_range,
       COUNT(*) AS order_count
FROM iceberg.sales.orders
GROUP BY width_bucket(order_amount, ARRAY[50, 100, 150, 200])      -- (the GROUP BY repeat is fine; the CASE reference is the bug)
ORDER BY bucket_num;
```

**Fix:** either **repeat the `width_bucket(...)` expression** inside the CASE (verbose but works), **or** push `width_bucket(...)` down into a CTE so `bucket_num` becomes a real column in the outer query (the **preferred** form — see the canonical above). The same rule covers any "label a bucket I just computed" shape: the bucket expression must either be **repeated** in every sibling reference, or **promoted to a column** via a CTE / subquery.

**(2) `ARRAY_AGG(DISTINCT ...) OVER (...)` — DISTINCT is NOT supported in window aggregates.**

```sql
-- WRONG ❌ — Trino does NOT support DISTINCT inside a window aggregate. The query
-- errors with "DISTINCT in window function parameters not yet supported"
-- (trinodb/trino #7885, still open as of 2026-06).
SELECT ARRAY_AGG(DISTINCT order_status) OVER () AS all_statuses    -- ❌ DISTINCT + OVER is unsupported
FROM iceberg.sales.orders;
```

**Fix:** if you need the distinct set, compute it in a SUBQUERY / CTE with a plain `GROUP BY` or `array_agg(DISTINCT ...)` **without** `OVER`, then cross-join the single-row result back. For a histogram, you do **not** need a window at all — `GROUP BY bucket_floor` (or `GROUP BY bucket_num` over a width_bucket CTE) produces one row per bucket directly.

**(3) `element_at(arr, 0)` — Trino arrays are 1-based; index 0 is invalid.**

```sql
-- WRONG ❌ — Trino arrays are 1-based ([trino.io/docs/current/functions/array.html]
-- verbatim: "The [] operator is used to access an element of an array and is indexed
-- starting from one"). Index 0 is invalid; depending on the access form it returns
-- NULL or raises "SQL array indices start at 1". `width_bucket` CAN return 0 (the
-- underflow bin), so if you are building a labelled array indexed by bucket number,
-- DO NOT index it by the raw width_bucket result — guard the 0-bucket case
-- separately or use width_bucket(x, ARRAY[...]) + 1 only after a +1 adjustment.
SELECT element_at(ARRAY['$0-$50','$50-$100','$100-$150','$150+'],
                  width_bucket(order_amount, ARRAY[50,100,150])) AS amount_range  -- ❌ width_bucket can return 0
FROM iceberg.sales.orders;
```

**Fix:** index with `width_bucket(...) + 1` (so the underflow bucket 0 maps to array position 1) — OR use a `CASE` expression keyed on the bucket number (cleaner; see the labelled secondary canonical above) — OR use the integer-division floor form which has no underflow bin to worry about.

**Cross-links.** The alias-visibility rule that powers bug (1) is the same rule pinned at **[resource 27 §4.2 alias-in-WHERE guard (line 720)](27-oracle-plsql-to-dbt-trino.md)** ("`WHERE` is evaluated BEFORE the `SELECT` projection ... output column aliases do not exist yet when WHERE runs") and at **[resource 23 §8 Trino GROUP BY rules anchor (lines 1521-1528)](23-sql-best-practices-olap.md)** ("Trino does NOT support referencing a SELECT-list alias by name in GROUP BY ... A SELECT alias may be used in the outer ORDER BY ... but NOT in GROUP BY / WHERE / HAVING"). The same pre-projection scoping rule **also covers sibling SELECT-list expressions** — a SELECT alias is visible **ONLY** in the outer `ORDER BY`, not in any other clause and not in any other SELECT-list expression. The **width_bucket bin numbering + off-by-one trap** is locked at **Pattern C4 above (lines 2250-2303)**; the **CASE-WHEN searched-bucket ladder** alternative (when you want pretty string labels per band, no width_bucket) is the **CASE-vs-width_bucket decision table at line 2256-2263**.

### Pattern D: Sliding window (last 7 days rolling)

> **DECIDE-FIRST — SOURCE GRAIN: is your input one-row-per-day, or one-row-per-event? (iter649 FIX-A PIN — the EXACT iter648 Q2 grain bug.)** "N-day moving average of DAILY `<metric>`" means **one rolling value per CALENDAR DAY computed over the last N daily totals** — so the window MUST run over rows that are **ALREADY one-row-per-day**. The most common bug is windowing the **raw per-event / per-order table directly**, which produces a 7-ROW average of individual event amounts, NOT a 7-DAY average of daily totals. Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) + [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) on 2026-06-08: `ROWS BETWEEN N PRECEDING AND CURRENT ROW` is a **physical-row positional offset** — it counts ROWS, not calendar days. If a day has 50 orders, `ROWS BETWEEN 6 PRECEDING` over the raw `orders` table covers **6 ORDERS back**, which is typically a few hours of the same day — not 7 days.
>
> | Your SOURCE is... | First step | Then window |
> |---|---|---|
> | **Raw per-event / per-order rows** (multiple rows per day — `orders`, `events`, `clicks`, `sessions` fact table) | **Pre-aggregate to ONE ROW PER DAY** in a CTE with `SUM(amount) GROUP BY order_date` (or `COUNT(*) GROUP BY day`, `COUNT(DISTINCT user_id) GROUP BY day`, etc.). | Run `AVG(daily_metric) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` over the daily CTE. |
> | **Already one row per day** (a daily rollup table — `daily_revenue`, `daily_dau`, `daily_signups`) | None — the source is already at the right grain. | Window it directly (the `daily_dau` worked example below). |
>
> **Mnemonic:** the noun in "**daily** revenue" / "**daily** signups" / "**daily** active users" is a SIGNAL that the window operand must be a daily series. If your `FROM` is `orders` and not `daily_orders`, you owe the reader a `WITH daily AS (... GROUP BY order_date)` CTE before the window.

#### LEADING CANONICAL — 7-day moving average of DAILY REVENUE from a raw `orders` table (the iter648 Q2 shape, FIXED)

```sql
-- CORRECT — pre-aggregate per-order rows to ONE ROW PER DAY first, THEN window.
WITH daily AS (
  SELECT order_date,
         SUM(amount) AS daily_revenue            -- one row per calendar day, total revenue that day
  FROM iceberg.sales.orders
  WHERE order_date >= DATE '2026-01-01'          -- partition-prune BEFORE the rollup
  GROUP BY order_date
)
SELECT
  order_date,
  daily_revenue,
  AVG(daily_revenue) OVER (
    ORDER BY order_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW     -- 7 rows = 7 days (since daily is one-row-per-day)
  ) AS moving_avg_7day_revenue
FROM daily
ORDER BY order_date;
```

The CTE collapses many orders/day down to a single `(order_date, daily_revenue)` row. **After that collapse**, `ROWS BETWEEN 6 PRECEDING` covers exactly 7 daily rows = 7 calendar days, and `AVG(daily_revenue)` averages 7 daily totals — which is what "7-day moving average of daily revenue" means. The same shape works for **30-day rolling average of daily signups** (swap `SUM(amount)` for `COUNT(*)`, `ROWS BETWEEN 29 PRECEDING`), **trailing 7-day average of daily DAU** (swap `SUM(amount)` for `COUNT(DISTINCT user_id)`, keep `ROWS BETWEEN 6 PRECEDING`), and any "smooth daily `<metric>`" or "moving average from an orders table" question shape.

**DO NOT WRITE — the EXACT iter648 Q2 bug (windowing raw per-order rows without pre-aggregation):**

```sql
-- WRONG ❌ — windowing the raw per-order rows directly. NOT a 7-day moving average.
-- ROWS BETWEEN 6 PRECEDING counts PHYSICAL ROWS, not days. If there are 50 orders/day,
-- this frame covers ~6 ORDERS back (a sliver of a single day), and averages
-- individual per-order amounts — NOT daily totals. The output is also one row per
-- order (not one row per day), so the dashboard tile labelled "7-day moving average
-- of daily revenue" silently reports a per-order trailing-6-orders mean.
SELECT
  order_date,
  amount,
  AVG(amount) OVER (
    ORDER BY order_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW   -- ❌ 6 ORDERS back, NOT 6 days back
  ) AS bogus_moving_avg
FROM iceberg.sales.orders;
```

**Two independent things are wrong here, NOT one:** (1) the FRAME counts rows not days (per-order grain, not per-day grain), AND (2) the AVERAGE is over individual order `amount` values, not over daily `SUM(amount)` totals — even if you "fixed" the frame to count 7 distinct days, averaging per-order amounts is still not a daily-revenue average. **Both bugs are fixed by the SAME edit:** pre-aggregate to one row per day with `SUM(amount) GROUP BY order_date` in a CTE FIRST, then window the daily series.

**Gap-day caveat (secondary).** The daily-CTE form above is **calendar-exact ONLY if every day in the date range has at least one order** (so every day produces a row in the CTE). If days can be missing (no orders on Sundays, holiday shutdowns, ingestion gaps), `ROWS BETWEEN 6 PRECEDING` over the daily CTE still counts 7 ROWS — which spans **more than 7 calendar days** when the missing-day rows are absent from the CTE. **Two fixes**, in order of preference:

1. **Use `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` on the daily CTE** — value-based frame on the `order_date` column, calendar-exact regardless of missing days (the `daily_dau` worked example below uses this form). Missing days simply contribute zero rows to the frame; the value-based boundary is unchanged.
2. **Densify with a date spine BEFORE the window** — `LEFT JOIN` a `SEQUENCE(DATE '...', DATE '...', INTERVAL '1' DAY)`-generated calendar dim onto the daily CTE, `COALESCE(daily_revenue, 0)` for the missing-day rows. Then `ROWS BETWEEN 6 PRECEDING` over the densified series is correct again (positions align with calendar days), and gap days contribute zero values to the rolling average — see the "LEFT JOIN calendar-dim densification recipe" lower in this section.

For most daily-revenue / daily-signups tables every active day has at least one row, so the simple daily-CTE-then-ROWS form is the primary answer; reach for RANGE-with-INTERVAL or date-spine densification only when missing-day gaps are real. See the **RANGE vs ROWS gap-day semantics rule** lower in this section for the full decision table, and the **`date_trunc('month', event_date) + COUNT(DISTINCT user_id) GROUP BY`** monthly-rollup pattern at [r07 § Pattern A2 — Canonical worked example](#canonical-worked-example--per-tenant-monthly-events--cumulative-running-total) (lines 1640-1668) + [r23 § extract-then-count GROUP-BY-rule guardrail](23-sql-best-practices-olap.md) (line 1530) for the per-period-rollup routing — the rollup-then-window pattern is the same shape at month or week grain.

---

#### Worked example — already one-row-per-day SOURCE (the `daily_dau` rollup table)

"7-day rolling average of daily active users per tenant."

```sql
SELECT
  day,
  tenant_id,
  dau,
  AVG(dau) OVER (
    PARTITION BY tenant_id
    ORDER BY day
    RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW
  ) AS rolling_7d_avg_dau
FROM iceberg.analytics.daily_dau;
```

- `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` — a **value-based** frame: include all rows whose `day` is within 6 days before this row. **Gap-day correct** — if a tenant has no events on `day = 2026-05-25` but has events on `2026-05-24` and `2026-05-26`, the frame for the `2026-05-26` row correctly includes the 5 days from `2026-05-20` through `2026-05-25` AND the 1 row from `2026-05-26`, even though `2026-05-25` is absent.
- `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` is the row-count alternative — **strict last 7 rows by position**. Use this only when you know there are no day gaps; if `2026-05-25` is missing, this frame at `2026-05-26` instead includes the 7 PHYSICAL ROWS ending at `2026-05-26`, which may span 8+ calendar days because of the gap. **This is the most common cause of "my 7-day rolling average looks wrong on holidays / weekends with no data" bugs.**

> **RANGE vs ROWS gap-day semantics — the rule.** For time-series rolling windows on dense daily data with **no missing days**, `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` and `ROWS BETWEEN 6 PRECEDING` produce identical results. The instant any day is missing (a tenant with no events on Sundays, a holiday with zero traffic, a maintenance window) the two diverge:
>
> - **`RANGE` is calendar-aware** — `INTERVAL '6' DAY PRECEDING` always means "any row whose ORDER BY value (the `day` column) is between `current_day - INTERVAL '6' DAY` and `current_day`, inclusive." Missing days simply contribute zero rows to the frame; the value-based boundary is unchanged.
> - **`ROWS` is position-aware** — `6 PRECEDING` means "the 6 input rows immediately preceding this one in ORDER BY order." A gap shifts the frame backward by the count of the gap in physical rows.
>
> For SaaS analytics on DAU / MAU / revenue rollups where you frequently have missing days (holidays, idle tenants, ingestion blackouts), **default to `RANGE BETWEEN INTERVAL` over `ROWS BETWEEN N PRECEDING`**. The `RANGE` form requires the `ORDER BY` column to be one of: a numeric type (INTEGER, BIGINT, DOUBLE), a `DATE`, a `TIMESTAMP`, or a `TIMESTAMP WITH TIME ZONE`. The offset must be the matching `INTERVAL` type. Verified against [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) — Trino supports `RANGE` value-based frames since the [March 2021 window-features release](https://trino.io/blog/2021/03/10/introducing-new-window-features.html).
>
> **Empty-frame edge case.** A `RANGE` frame can produce ZERO rows if the ORDER BY values around the current row don't fall inside the offset window. Window aggregates over an empty frame return: `COUNT()` -> 0, `SUM/AVG/MIN/MAX` -> NULL, `array_agg` -> NULL. Downstream consumers must handle NULL — `COALESCE(rolling_7d_avg_dau, 0)` is the standard guard. A `ROWS` frame **cannot** produce an empty frame at non-edge rows (it always has `N+1` rows), which is one reason engineers reach for it — but the cost is incorrect calendar semantics on sparse data.

> **CRITICAL — "fallback choices change metric semantics" callout.** When a rolling-window aggregate returns NULL on a gap day, **the choice of fallback is a semantic decision, not a syntactic detail**. Each fallback expresses a different definition of the metric. **Always flag the semantic change to your stakeholders before shipping** — engineers who reach for `COALESCE(rolling_avg, current_value)` because it "fills the gap" frequently ship a metric that no longer means "7-day rolling average."

| Fallback pattern | What the gap-day value becomes | Semantic effect — read carefully before using |
|---|---|---|
| `COALESCE(rolling_avg, 0)` | Zero on gap days. | **Skews downward.** A genuine "no activity → zero engagement" interpretation. Correct when zero is the right business meaning for "no events that day." Wrong when the metric is supposed to represent *prior activity even if today is missing*. |
| `COALESCE(rolling_avg, current_value)` | Today's raw `session_count` (or `dau`, etc.) on gap days. | **Defeats the rolling intent.** On a gap day the metric reports today's single-row value, NOT a rolling average. Two days later the same value smooths in. Dashboards labelled "7-day rolling average" silently report point values on gap days. **Almost always wrong** for a rolling-average use case. |
| `COALESCE(rolling_avg, LAG(rolling_avg, 1) OVER (...))` (carry-forward) | Yesterday's rolling-avg value. | **"Persistence" semantic.** Treats a missing day as "no new information" — preserves the last known average. Correct when you want a stable trend line across gaps; incorrect when zero or true-NULL is the meaningful signal. |
| Switch to `UNBOUNDED PRECEDING` (cumulative average instead of rolling) | A running average from earliest history to today. | **Different metric.** This is NOT a 7-day rolling average. It is a cumulative all-time mean. Don't relabel a "7d rolling" dashboard tile with this — change the label too. |
| Switch frame to `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` (already calendar-aware) | Still NULL when ZERO rows fall in the calendar window. | **No fallback** — RANGE just removes the gap-shifting bug. The empty-frame NULL is still possible if the entire 7-day window has zero rows. You still need one of the choices above on top of RANGE if you must fill the NULL. |
| **LEFT JOIN a calendar dimension + densify with zero-fill BEFORE the window** | Gap days get a zero `dau`/`session_count` row injected before the window runs; the rolling avg then includes that zero as a real data point. | **The only semantically-clean fix** when you want a true 7-day rolling average that doesn't return NULL on gap days. The denominator stays at 7 (or the actual number of calendar days in the window), gap days contribute zero values to the numerator, and the dashboard label "7-day rolling average" stays accurate. Recipe below. |

**LEFT JOIN calendar-dim densification recipe (the semantically-clean fix):**

```sql
-- Step 1: build a calendar spine for the date range you care about.
WITH calendar AS (
  SELECT day, tenant_id
  FROM UNNEST(SEQUENCE(DATE '2026-01-01', DATE '2026-12-31', INTERVAL '1' DAY)) AS t(day)
  CROSS JOIN (SELECT DISTINCT tenant_id FROM iceberg.analytics.daily_dau) AS t
),
-- Step 2: LEFT JOIN raw activity onto the calendar; missing days surface as NULL.
densified AS (
  SELECT
    c.day,
    c.tenant_id,
    COALESCE(d.dau, 0) AS dau  -- gap day -> 0, NOT NULL
  FROM calendar c
  LEFT JOIN iceberg.analytics.daily_dau d
    ON d.day = c.day AND d.tenant_id = c.tenant_id
)
-- Step 3: run the rolling window over the densified series.
SELECT
  day,
  tenant_id,
  dau,
  AVG(dau) OVER (
    PARTITION BY tenant_id
    ORDER BY day
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS rolling_7d_avg_dau
FROM densified;
```

After densification, ROWS-based windows are correct again (because positions and calendar days now align), and the rolling-average value on a gap day genuinely is "average over the last 7 days, where the gap day counted as zero" — which is what most SaaS dashboards mean by "7-day rolling average on a holiday."

> **Decision rule:** ask your stakeholder, "What should this dashboard show on a day with no activity?" The four typical answers — "show zero," "show yesterday's value," "show today's raw value," "show a true rolling average treating the gap as zero" — map directly to four different SQL patterns above. Picking the SQL pattern without asking the semantic question is how dashboards silently change meaning during code review.

### Performance: when window functions get expensive

Window functions force Trino to **sort the probe data** by `(PARTITION BY columns, ORDER BY columns)` before computing the window. This sort happens after `WHERE` filtering but before producing output. For large input sets the sort can spill to disk or OOM the worker.

Symptoms of a window-function memory problem:
- Trino UI shows the `Window` operator as the blocked stage with high memory usage.
- `EXPLAIN ANALYZE` shows large `Spilled` bytes on the Window operator (Trino uses ORC spill for window operators when enabled).
- The query passes a small test but times out on a year of data.

Mitigations, in order of preference:
1. **Tighten `WHERE`** to reduce the probe set before the window. A window over 30 days is fine; over 2 years probably is not. Always partition-prune on `day` / `occurred_at` first.
2. **Push to a pre-aggregated rollup table.** Rather than running a window over the raw fact table on every dashboard load, materialize a daily `agg_daily_revenue_by_tenant` table (one row per tenant per day) and run the window over the rollup. For a SaaS with 10k tenants × 365 days = 3.6M rows in the rollup vs 500M raw events, this is the difference between a 30-second query and a 0.5-second query.
3. **Narrow `PARTITION BY`.** Each unique partition key requires its own sort-and-window pass. `PARTITION BY tenant_id, user_id` on a high-cardinality table is far more expensive than `PARTITION BY tenant_id` alone.
4. **Enable Trino spill-to-disk** (`spill_enabled = true`, `query_max_total_memory_per_node` tuned) if you must run the window over the raw data. Spill trades latency for not OOMing.

### When to use a window function vs `GROUP BY`

| Need | Use |
|---|---|
| One row per group with an aggregate (total revenue per tenant) | `GROUP BY` |
| Every row PLUS an aggregate context (each order's amount AND tenant running total) | Window function |
| Top-N per group | Window function (`ROW_NUMBER`/`RANK`) + outer `WHERE` |
| Compare each row to the previous row in a group | `LAG` / `LEAD` |
| Aggregate over a moving window (last 7 days, last N rows) | Window function with frame clause |

If you can answer the question with `GROUP BY`, prefer it — `GROUP BY` collapses rows early and runs cheaper than a window function on the same data.

---

## Why each pattern stresses OLAP differently

| Pattern | Bottleneck | What helps |
|---|---|---|
| Aggregation | Wide scans | Columnar storage, partition pruning |
| Funnel | Multi-pass over same table | Caching, MATCH_RECOGNIZE, pre-aggregated funnel tables |
| Cohort | High-cardinality DISTINCT | `approx_distinct`, pre-built cohort tables |
| Time-series | Gap-filling logic | Calendar tables, dashboard-side fill |
| Window functions | Sort + memory on PARTITION BY / ORDER BY data | Tight `WHERE`, pre-aggregated rollup tables, narrower PARTITION BY |

Knowing which bottleneck you're hitting tells you where to optimize.
