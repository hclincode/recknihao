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

> **DO NOT WRITE.** (1) `array_agg(x)` without `ORDER BY` and expect chronological / insertion / file order — **non-deterministic**; will silently break the next time partitioning changes. (2) Outer `SELECT ... ORDER BY occurred_at` to "order the array" — that orders the OUTER ROWS, not the array's elements. ORDER BY must be **inside** the aggregate. (3) `array_agg(x ORDER BY y) OVER (PARTITION BY k)` — Trino does NOT support inline `ORDER BY` combined with `OVER (...)` in the same `array_agg`; see [resource 27 § 7A.2A](27-oracle-plsql-to-dbt-trino.md) for the pre-sorted CTE workaround. (4) `array_agg` for string-joining when you really want a delimited STRING — use `listagg(col, ',') WITHIN GROUP (ORDER BY col)` (one row per group) OR `array_join(array_agg(col ORDER BY col), ',')` (when you need windowed/array form); see [resource 27 § 7A.2A / § 7A.2B](27-oracle-plsql-to-dbt-trino.md) — do not rewrite that family here.

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

### COMBINED CANONICAL — composing the date-spine + forward-fill correctly (ORDERING MATTERS — iter570 PIN)

> **Keyword anchors (read this section FIRST if your question contains any of these):** forward-fill plus date spine, gap-fill dates AND forward-fill values, dense minute grid + LOCF, device heartbeat forward-fill, IoT minute-bucket forward-fill, sensor status carry-forward minute spine, fill missing minutes with last reported status, every minute per device last known status, combine sequence and LAST_VALUE IGNORE NULLS, date-spine forward-fill order of operations.

**The fact in one sentence.** When you need BOTH the dense `(entity, time)` grid AND the carry-forward fill, the window MUST be applied **AFTER** the LEFT JOIN to the spine — over the **post-join dense rows** where gap minutes are NULL. If you compute `LAST_VALUE(...) IGNORE NULLS` in a CTE over the **raw sparse facts FIRST** and then LEFT JOIN the spine, gap rows the join creates were never seen by that earlier window → they stay NULL → `COALESCE` over two NULLs returns NULL → **gaps NOT filled**.

**Ordering recipe — four numbered steps (copy this mental order):**

1. **Build the dense grid.** `CROSS JOIN UNNEST(sequence(min_ts, max_ts, INTERVAL '1' MINUTE))` × distinct entities (devices / users / tenants / products). The grid CTE contains every `(entity, ts)` pair you want in the output, with NO measure column yet.
2. **Step 2a — collapse the sparse facts to ONE row per `(entity, bucket)` FIRST (fanout-safe).** If the raw fact table can have MULTIPLE events per `(entity, bucket)` (multiple heartbeats per minute, many status updates per hour, several writes per day per row), the LEFT JOIN in Step 2b will FAN OUT — the grid row matches every fact row, multiplying the output. Pre-aggregate to **one row per `(entity, bucket)`** first using `max_by` to keep the LATEST reading within the bucket: `SELECT entity_id, date_trunc('hour', ts) AS bucket, max_by(metric, ts) AS metric FROM facts GROUP BY entity_id, date_trunc('hour', ts)`. **Keyword anchor:** fanout from multiple events per bucket, dedupe/aggregate per hour before forward-fill, one row per entity per time bucket, many updates per day collapse to last per day, multiple heartbeats per minute, `max_by` per bucket.
3. **Step 2b — LEFT JOIN that one-row-per-bucket result to the dense grid.** Gap-row entries (entity/bucket pairs with no real fact) now have NULL metric. This is where the NULLs you want to fill actually appear in the row stream — and there is NO row-multiplication risk because Step 2a guarantees at most one fact row per `(entity, bucket)`.
4. **Step 3 — THEN apply the window AFTER the join, over the post-join dense rows.** `COALESCE(metric, LAST_VALUE(metric) IGNORE NULLS OVER (PARTITION BY entity_id ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))` — the window now sees the NULL-padded dense rows, so `IGNORE NULLS` skips the gap rows and the look-BACK frame returns the most recent non-null value at or before each gap.

**Compact correct end-to-end query (device-heartbeat / minute-spine forward-fill — copy-paste this):**

```sql
-- Step 1: dense (device_id, ts) grid — one row per device per minute in the lookback window.
WITH bounds AS (
  SELECT min(reported_at) AS lo, max(reported_at) AS hi
  FROM iceberg.iot.device_heartbeats
  WHERE reported_at >= current_timestamp - INTERVAL '1' DAY
),
minute_spine AS (
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
-- Step 2: LEFT JOIN sparse facts to the dense grid. Gap minutes => status IS NULL.
joined AS (
  SELECT g.device_id,
         g.ts,
         h.status                                  -- NULL on gap minutes (post-join)
  FROM grid g
  LEFT JOIN iceberg.iot.device_heartbeats h
    ON h.device_id = g.device_id
   AND date_trunc('minute', h.reported_at) = g.ts
)
-- Step 3: apply the window AFTER the join, over the dense rows. NULLs are now visible to IGNORE NULLS.
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

**Why this works.** Step 2's LEFT JOIN is what **manufactures the NULL rows that need filling**. Step 3's `LAST_VALUE(status) IGNORE NULLS` runs over the `joined` CTE — which contains both the non-NULL "real" reports and the NULL gap minutes. `IGNORE NULLS` skips the gap rows and the look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` returns the most recent non-NULL `status` at or before each gap minute, per device.

**DO-NOT-WRITE (load-bearing — iter570 forward-fill + spine composition fab class):**

- **`LAST_VALUE(status IGNORE NULLS) OVER (...)` — `IGNORE NULLS` placed INSIDE the function-args paren is a PARSE ERROR.** The Trino 467 grammar (verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) + [SqlBase.g4 grammar referenced in PR #1244](https://github.com/trinodb/trino/pull/1244)) places the **null-treatment clause AFTER the closing paren of the function arguments and BEFORE `OVER`**: `functionCall: name '(' args ... ')' nullTreatment? filter? over?`. **CORRECT:** `LAST_VALUE(status) IGNORE NULLS OVER (PARTITION BY device_id ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. **WRONG (parse error):** `LAST_VALUE(status IGNORE NULLS) OVER (...)`. Same rule for `FIRST_VALUE`, `NTH_VALUE`, `LAG`, `LEAD`: the `IGNORE NULLS` / `RESPECT NULLS` keyword pair sits BETWEEN `)` and `OVER`, never inside the function-args paren.
- **Computing `LAST_VALUE(...) IGNORE NULLS` in a CTE over the RAW sparse facts FIRST and THEN LEFT JOIN-ing the spine — gaps NOT filled.** Every raw sparse-fact row already has a non-NULL `status` (the table only stores actual reports), so `IGNORE NULLS` skips nothing — the window is a no-op. The LEFT JOIN that comes AFTER then introduces gap rows with `h.status = NULL` AND `h.last_known_status = NULL` (the no-op output is also NULL on the gap side), so `COALESCE(NULL, NULL) = NULL` and the gaps stay empty. **The window MUST run on the POST-JOIN dense rows.** Build the spine, LEFT JOIN, THEN window — the three-step order above is the only correct composition.
- **Equivalent variant — replacing `COALESCE(status, LAST_VALUE(status) IGNORE NULLS OVER ...)` with bare `LAST_VALUE(status) IGNORE NULLS OVER (...)`** is also correct (the look-BACK frame already returns the current row's value when `status` is non-NULL on that row, per the standalone canonical above). Either form is fine; the `COALESCE` wrapper just makes intent explicit. **DO NOT** wrap with `COALESCE(status, last_known_status)` referencing a CTE column from a pre-join LAST_VALUE attempt — see the previous bullet.
- **DO NOT compute ANY `LAST_VALUE` / forward-fill window in a PRE-JOIN CTE over the raw facts — and ESPECIALLY NOT with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` (iter571 PIN).** A full-frame `LAST_VALUE(metric) OVER (PARTITION BY entity_id ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` collapses to the **PARTITION-GLOBAL-LAST value** (a single constant per entity) — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): `LAST_VALUE` returns the last value of the window frame, and `UNBOUNDED FOLLOWING` extends the frame to the partition's final row, so every row in the partition sees the SAME last value. If you compute that constant in a pre-join CTE and THEN LEFT JOIN the dense spine, EVERY gap row inherits the entity's globally-latest reading — NOT the as-of-bucket value the question actually asks for. **WRONG (pre-join CTE with full-frame `LAST_VALUE`, then LEFT JOIN):** `WITH sparse_logs AS (SELECT server_id, logged_at, cpu_percent, LAST_VALUE(cpu_percent) OVER (PARTITION BY server_id ORDER BY logged_at ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS latest_cpu FROM raw_facts) SELECT g.server_id, g.bucket, COALESCE(s.cpu_percent, s.latest_cpu) AS cpu FROM grid g LEFT JOIN sparse_logs s ON s.server_id = g.server_id AND date_trunc('hour', s.logged_at) = g.bucket` — produces the partition-global-last value for every gap, and ALSO fans out if `sparse_logs` has multiple rows per `(server_id, hour)`. **RIGHT (no pre-join window — collapse to one-row-per-bucket via `max_by`, LEFT JOIN, then forward-fill in the FINAL select over the post-join dense rows):** Steps 2a → 2b → 3 in the recipe above (`max_by(cpu_percent, logged_at) GROUP BY server_id, date_trunc('hour', logged_at)` first → LEFT JOIN onto the spine → final `LAST_VALUE(...) IGNORE NULLS OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` in the outer SELECT). The forward-fill window belongs **ONLY** in the final SELECT over the POST-JOIN dense rows — never in a pre-join CTE. The standalone forward-fill canonical above also bans `UNBOUNDED FOLLOWING` for forward-fill (it would be **future-fill**, not forward-fill); the recipe here additionally bans **any** window over raw sparse facts before the spine join, full-frame or otherwise.

`date_trunc('day' | 'week' | 'month', col)` is the Trino function you'll use constantly. It rounds a timestamp down to the start of a bucket. **Return type — same as input** (per [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): `date_trunc(unit, x) -> [same as input]`): `timestamp -> timestamp`, `timestamp(p) with time zone -> timestamp(p) with time zone`, `date -> date`, `time -> time`. It does **NOT** convert to DATE — `date_trunc('day', some_timestamp)` returns a `timestamp` at midnight, not a `date`. If you need the result as a DATE, wrap in `CAST(... AS DATE)` explicitly.

#### `date_trunc('week', ts)` ALWAYS starts the week on MONDAY (ISO-8601) — Trino canonical (iter536 PIN)

> **Keyword anchors for this block**: date_trunc week Monday, Trino week start day, weekly report week start, ISO week Trino, day_of_week Monday, Sunday vs Monday week, first day of week Trino, beginning of week Trino, European Monday week start, US Sunday week start.

> **TRUTH (verified against [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)):** Trino's `date_trunc('week', ts)` **always** starts the week on **MONDAY** (ISO-8601). There is **NO Sunday-start option**, **NO locale setting**, and **NO `first_day_of_week` configuration** in Trino. The companion function `day_of_week(ts)` returns **`1` = Monday .. `7` = Sunday** (also ISO-8601). A European Monday-start weekly-report requirement is therefore met by the **bare** `date_trunc('week', ts)` function with **NO workaround at all**.

> **Worked example.** `DATE '2020-01-01'` is a **Wednesday**. `date_trunc('week', DATE '2020-01-01')` returns `2019-12-30`, which is the **Monday** of that week. `day_of_week(DATE '2019-12-30')` returns `1` (Monday). `day_of_week(DATE '2020-01-01')` returns `3` (Wednesday). `day_of_week(DATE '2020-01-05')` returns `7` (Sunday — end of the ISO week).

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

> **Keyword anchors (read this section FIRST if your question contains any of these — GENERIC, NOT Oracle-specific):** is `now()` a Trino function · does Trino have `now` · Trino `now()` · `now()` vs `current_timestamp` · Trino current timestamp function · Trino time functions · `current_date` Trino · `current_time` Trino · `localtimestamp` Trino · session time zone Trino · what time zone does Trino store · Iceberg timestamp storage · `timestamp with time zone` UTC Iceberg · UTC-normalized · stored as UTC · wall-clock timestamp · `AT TIME ZONE` Trino · `timestamp` vs `timestamptz` · timezone aware vs naive Iceberg.

**Fact 1 — Trino HAS `now()`; it is an ALIAS for `current_timestamp`.** Verified verbatim at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): *"`now() → timestamp(3) with time zone` — This is an alias for `current_timestamp`."* Both return **`TIMESTAMP(3) WITH TIME ZONE`** as of the **start of the query** (every reference inside one query yields the identical value), tied to the **session time zone**. Pick whichever reads better. Companion forms (all session-TZ-aware):
- `current_date` → `DATE` (no time component).
- `current_time` → `TIME WITH TIME ZONE`.
- `localtimestamp` → `TIMESTAMP` (no TZ; session-local wall clock).
- **Syntax pin:** `current_timestamp` / `current_date` / `current_time` / `localtimestamp` take **NO parentheses** (SQL-standard special-form syntax); `now()` takes empty parens. Writing `current_timestamp()` is a parse error.

**Fact 2 — Iceberg STORAGE: `timestamp with time zone` (timestamptz) is UTC-NORMALIZED on disk; bare `timestamp` is wall-clock with NO normalization.** Per the [Iceberg spec](https://iceberg.apache.org/spec/) — verbatim: *"values are stored as UTC and do not retain a source time zone (2017-11-16 17:10:34 PST is stored/retrieved as 2017-11-17 01:10:34 UTC and these values are considered identical)."* A `timestamp(6) with time zone` column stores **microseconds from epoch UTC** — the original session/source zone is **NOT preserved per value**; the value is an INSTANT. A `timestamp(6)` column (WITHOUT time zone) stores wall-clock microseconds with **no UTC normalization** — what you wrote is what comes back. `AT TIME ZONE 'UTC'` / `AT TIME ZONE 'America/New_York'` on a `timestamptz` value **re-labels** the same UTC instant in the target zone — it does NOT change the stored bytes (display re-render only).

**DO-NOT-WRITE (the load-bearing fab claims to ban):**
- *"Trino has no `now()` function / `now()` is a parse error / function-not-found in Trino."* **FALSE.** `now()` is a documented Trino alias for `current_timestamp`; both work; both return the same value and type.
- *"Iceberg / Trino never normalizes timestamps to UTC on storage — you get back exactly what you stored."* **FALSE for `timestamp with time zone` (timestamptz)** — those values ARE UTC-normalized on disk per the Iceberg spec. The "no normalization" rule applies ONLY to bare `timestamp` (without time zone).
- *"`current_timestamp` and `now()` return different types / different values."* **FALSE.** Identical type (`TIMESTAMP(3) WITH TIME ZONE`), identical value (both pinned to query-start time, session TZ).
- *"`current_date` returns a timestamp."* **FALSE.** It returns `DATE` — no time component. Use `current_timestamp` (or `now()`) when you need hours/minutes/seconds.

**Cross-references:** Resource 27 §4.2-NOW (the Oracle-migration angle — same two facts, SYSDATE-replacement framing — keep both consistent). Resource 27 §4.2A (the dedicated `SET TIME ZONE` command + `sql.forced-session-time-zone` server property — how to change what zone `current_timestamp` / `now()` use). Resource 27 §4.2B (filtering a `timestamp with time zone` column by a local-date range — boundary-literal form). Resource 13 §timestamp-type-mapping (Postgres `timestamptz` → Iceberg `TIMESTAMP(6) WITH TIME ZONE`). Resource 13 §`from_unixtime` (epoch-seconds-to-timestamp; returns `timestamp(3) with time zone`).

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

> **Bonus default-frame surprise.** `SUM(amt) OVER (ORDER BY order_date)` with **NO explicit frame** defaults to `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (per Trino's window-functions docs). On the data above the cumulative values would be 200, 200, 250, 320 — both Jan-01 peers see 200 (the peer-group end), Jan-02 sees 250, Jan-04 sees the full running total. If you expected a per-row running total of 100, 200, 250, 320, you'd be surprised: the default frame treats peers as a group. Use Pattern 2 (unique tiebreaker + explicit ROWS) when you want per-row accumulation.

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
- `PERCENT_RANK()` — relative position as a fraction in `[0.0, 1.0]`. Formula: `(rank - 1) / (n - 1)` where `n` is partition row count. The top row gets `0.0`, the bottom row gets `1.0`. **Returns NULL when the partition has only one row** (divide-by-zero). Useful for "what percentile is this tenant in?" without computing a histogram.
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

**Sibling: `CUME_DIST` (cumulative distribution).** Trino also supports `CUME_DIST()` which returns `count_of_peers_or_lower / n` — slightly different math (the top row is `1.0`, not `(n-1)/n`). Use `PERCENT_RANK` for "fraction of rows STRICTLY below this one" and `CUME_DIST` for "fraction of rows AT OR BELOW this one."

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

**The remainder rule (this trips up engineers — read carefully).** `NTILE(n)` divides `rows_in_partition` by `n` and distributes the remainder `r` to the **first `r` buckets**, each of which gets one extra row.

| Rows in partition | `NTILE(4)` bucket sizes |
|---|---|
| 12 (12 ÷ 4 = 3, no remainder) | `3, 3, 3, 3` |
| 13 (13 ÷ 4 = 3 remainder 1) | `4, 3, 3, 3` — bucket 1 gets the extra row |
| 14 (14 ÷ 4 = 3 remainder 2) | `4, 4, 3, 3` — buckets 1 and 2 each get an extra |
| 15 (15 ÷ 4 = 3 remainder 3) | `4, 4, 4, 3` — buckets 1, 2, 3 each get an extra |

**This matters for SaaS metrics.** If you have 9,997 tenants and you compute `NTILE(10)` for "decile of revenue", the deciles are NOT all 999.7 rows each — they are `1000, 1000, 1000, 1000, 1000, 1000, 1000, 999, 999, 999` (first 7 buckets get the rounding-up). If a dashboard says "top decile = top 1000 tenants" and the real answer is "top decile = 999 tenants on this distribution", an audit may flag the off-by-one. State the rule explicitly in dashboard documentation, or use `PERCENT_RANK() >= 0.9` instead for an exact-cutoff threshold.

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
| Exact "top 10% of tenants" — guaranteed cutoff regardless of count | `PERCENT_RANK() >= 0.9` filter — avoids the `NTILE` remainder-row off-by-one |

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

**DO NOT WRITE** *"Trino has no `width_bucket` — it is Postgres-only"* (FALSE — Trino 467 has BOTH overloads, documented at `functions/math.html`); **DO NOT WRITE** a long `CASE WHEN ... THEN ... WHEN ... THEN ... END` ladder for numeric histogram bucketing when `width_bucket(x, ARRAY[...])` does uneven bins directly in one call. Update the Pattern C3 comparison table mental model: "Custom (non-equal-size) buckets" → `width_bucket(x, ARRAY[...])` is the **preferred Trino-native one-liner**; the CASE WHEN ladder is the fallback only when you need non-numeric bucketing (e.g., string-key bucketing) or per-bucket pretty labels mid-aggregation.

### Pattern D: Sliding window (last 7 days rolling)

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
