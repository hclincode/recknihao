# Judge Feedback — iter1066 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source + WebSearch. Scored against real
Trino 467 behavior, not resources/.

## Overall: 4.13 PASS (threshold 3.5; overall average governs, no per-question veto)

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 NTILE(4) quartiles | 5.0 | 4.75 | 4.75 | 5.0 | 4.875 |
| Q2 filter + starts_with | 5.0 | 4.75 | 5.0 | 5.0 | 4.9375 |
| Q3 histogram on map column | 1.5 | 1.5 | 2.5 | 1.5 | 1.75 |
| Q4 ROW_NUMBER first session | 5.0 | 4.75 | 5.0 | 5.0 | 4.9375 |

Overall = (4.875 + 4.9375 + 1.75 + 4.9375) / 4 = **4.125** → **4.13 PASS**.

(Per-dimension overall: Acc 4.125, Comp 3.9375, Clar 4.3125, Act 4.125 — all ≥3.5.)

---

## Q1 — split customers into 4 equal spend groups (NTILE) — 4.875 CORRECT

`NTILE(4) OVER (ORDER BY SUM(amount) DESC)` inside a CTE that does
`GROUP BY customer_id, plan_type, country`.

VERIFIED vs RAW window.md (467): ntile(n) "Divides the rows for each window partition into
`n` buckets ranging from 1 to at most n. Bucket values will differ by at most 1." Remainder:
"distributed one per bucket, starting with the first bucket" — responder's "remainders go to
earliest buckets" claim is exactly right. With `ORDER BY total_spend DESC`, bucket 1 = top
spenders (top 25%) — correct. GROUP BY including plan_type/country alongside customer_id is
acceptable (one row per customer assuming stable plan/country). Minor completeness ding only:
NTILE makes equal-COUNT not equal-SUM groups (quartiles by customer count) — fine for the asked
"top 25% of customers" reading but worth a one-liner.

## Q2 — filter array to elements starting with literal 'premium_' — 4.9375 CORRECT (best answer)

`filter(feature_list, f -> starts_with(f, 'premium_'))`.

VERIFIED vs RAW array.md: `filter(array(T), function(T,boolean)) -> array(T)` exists.
VERIFIED vs RAW string.md: `starts_with(string, substring)` exists, tests prefix, returns boolean.
CRITICAL trap correctly avoided: responder did NOT use bare `LIKE 'premium_%'` (the literal `_`
is a LIKE single-char wildcard, which would over-match `premiumX...`). starts_with treats
`premium_` as a literal prefix — the right tool. One-row-in/one-row-out (no UNNEST) as asked.
Clean, no broken secondary. The persistent broken-LIKE-secondary watch stays CLOSED here.

## Q3 — per-key frequency map across all events — 1.75 WRONG (lead errors; accuracy defect)

Responder gave: `SELECT histogram(properties) AS property_frequency FROM events`.

**VERDICT: histogram(map_column) does NOT produce per-key counts. The answer is WRONG.**

1. SEMANTICS: VERIFIED vs RAW aggregate.md (467): `histogram(x) -> map<K,bigint>` "creates a
   map containing the count of the number of times each input VALUE occurs." Passing the whole
   `properties` MAP as `x` treats each entire map as a single value, so it would count distinct
   ENTIRE maps — never the per-key frequency the question asks for ({'click':452,'view':1200}).

2. TYPE ERROR: `histogram` builds `map<K,bigint>` keyed on the input values, so the input type
   must be usable as a MAP KEY, i.e. comparable. MAP is NOT a comparable/orderable type in
   Trino — it cannot be a GROUP BY key or a map key (confirmed via WebSearch of Trino docs/issue
   history; the engine raises a type-not-comparable / cannot-use-map-as-key error). So
   `histogram(properties)` should actually FAIL to plan, not silently return a wrong map.

Either way the answer does not answer the question, and the "add GROUP BY user_id" suffix would
make it worse (GROUP BY on a map column also fails on the same non-comparability).

**CORRECT approach — extract keys per row, then count:**

```sql
-- one row, key -> frequency across all events
SELECT histogram(k) AS property_frequency
FROM events
CROSS JOIN UNNEST(map_keys(properties)) AS t(k);

-- equivalent via explicit group + map_agg
SELECT map_agg(k, cnt) AS property_frequency
FROM (
  SELECT k, COUNT(*) AS cnt
  FROM events
  CROSS JOIN UNNEST(map_keys(properties)) AS t(k)
  GROUP BY k
);
```

VERIFIED building blocks (RAW map.md / array.md / aggregate.md, 467):
- `map_keys(x(K,V)) -> array(K)` — returns the keys array.
- `UNNEST(array)` expands the array to rows; the input to histogram/COUNT is the scalar key `k`
  (a varchar), which IS comparable, so histogram/map_agg are legal.
- `map_agg(key, value) -> map<K,V>` assembles the final {key: count} map.

GAP TO ADDRESS: a findable canonical for "count occurrences of each KEY in a map(...) column"
must route to map_keys + UNNEST + histogram/map_agg, and explicitly warn that
`histogram(map_column)` / GROUP BY on a map column is a non-comparable type error, NOT a per-key
counter. Re-probe Q3 from a 2nd angle (e.g. per-key DISTINCT-value counts, or top-N keys) next
sweep before treating it closed.

## Q4 — first session per user (earliest started_at) — 4.9375 CORRECT

`ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY started_at ASC) = 1` in a subquery, with a
`MIN(started_at) GROUP BY user_id` alternative for the timestamp-only case.

VERIFIED: row_number() top-1-per-partition is the canonical first/last-per-group pattern, valid
467 (window functions evaluate after WHERE/GROUP BY/HAVING, so the rn=1 filter must live in an
outer query — responder wrapped correctly). The MIN alternative is correctly scoped: it returns
only the earliest timestamp and LOSES session_id/platform — responder flagged exactly that.
Note (not required): `min_by(session_id, started_at)` is another valid single-pass option that
keeps the wanted columns without a window — could be mentioned but its absence is not a defect.

---

## Source-verified dialect notes (RAW 467 URLs checked)

- window.md — ntile(n): buckets 1..n differ by ≤1, remainder one-per-bucket from the first.
  https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md
- array.md — filter(array(T), function(T,boolean)) -> array(T) exists.
  https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- string.md — starts_with(string, substring) exists, returns boolean, prefix test.
  https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/string.md
- aggregate.md — histogram(x) -> map<K,bigint> counts occurrences of each input VALUE;
  map_agg(key,value) -> map<K,V>.
  https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md
- map.md — map_keys(x(K,V)) -> array(K).
  https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/map.md
- MAP non-comparability (cannot be GROUP BY key / map key) confirmed via Trino docs + issue
  history (WebSearch): https://trino.io/docs/current/functions/aggregate.html

## No other defects

No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/
OFFSET-before-LIMIT/over-warning/broken-secondary in Q1/Q2/Q4. Q3 is a genuine LEAD-answer
accuracy defect (not responder padding), absorbed by the overall average (4.13 PASS), but the
map-key-frequency routing gap is the actionable item for the teacher.
