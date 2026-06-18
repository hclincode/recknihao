# Judge Feedback — iter1045

**Verification basis:** All dialect facts checked BOTH directions against RAW git-tag 467 source
(raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/{array,json,datetime,aggregate}.md)
+ WebSearch/#16533, NOT against resources/. RAW git-tag source is dispositive. Production stack confirmed
Trino 467 + Iceberg on-prem k8s/MinIO (prod_info.md); all four answers are pure-SQL and stack-appropriate.
NO federation probe (hard-locked).

---

## Q1 — nested JSON extract + count per OS  → **4.875**

Answer:
```sql
SELECT json_extract_scalar(properties, '$.device.os') AS operating_system, COUNT(*) AS event_count
FROM events
GROUP BY json_extract_scalar(properties, '$.device.os')
ORDER BY event_count DESC;
```

**THE KEY ITEM — GROUP-BY-alias defect DID NOT RECUR.** This is a re-probe of the 2x-relapsed
shape (iter1039 Q3, iter1044 Q3). The responder **repeated the full expression**
`GROUP BY json_extract_scalar(properties, '$.device.os')` rather than referencing the SELECT alias
`operating_system`. This is valid Trino — the #16533 alias-in-GROUP-BY prohibition applies only when
GROUP BY names a SELECT alias; a repeated expression (or an ordinal) is allowed. The `ORDER BY event_count`
DOES reference the alias, which is valid because ORDER BY can resolve SELECT aliases (GROUP BY/WHERE cannot).

- `json_extract_scalar(varchar/json, jsonpath) -> varchar` confirmed (json.md); nested `$.device.os`
  path supported (json.md shows nested `$.store.book[0].author` examples). Scalar (string) value — correct fn choice.
- `COUNT(*)` per group → one row per OS. Mentions `WHERE ... IS NOT NULL` to drop events missing the path — good completeness touch (json_extract_scalar returns NULL for absent paths).
- No ungrouped/unaggregated column (contrast iter1039/1044 which also dragged an ungrouped `event_id`). Clean.

Acc 5 / Clar 4.75 / App 5 / Comp 4.75. **The iter1039+iter1044 GROUP-BY-alias error is ABSENT.**

## Q2 — sum an array of prices per order  → **4.625**

```sql
reduce(line_items, 0.0, (accumulator, price) -> accumulator + price, x -> x) AS total_value
```

- There is **no `array_sum` built-in** in Trino 467 (array.md — absence verified). `reduce` is the idiomatic
  array-sum. 4-arg signature `reduce(array(T), initialState S, inputFunction(S,T,S), outputFunction(S,R)) -> R`
  matches exactly: init `0.0` (DOUBLE, matches the `12.99`-style decimals), accumulate `acc+price`, identity output `x->x`.
- The question asked "built-in or manual?" — the honest answer is **no built-in array_sum; reduce is the manual idiom.**
  The responder produced the correct reduce form but did **not explicitly say "there's no array_sum built-in"**, which
  is the literal framing the question solicited. Minor completeness ding only; the SQL is fully correct and runnable.

Acc 5 / Clar 4.5 / App 4.75 / Comp 4.25.

## Q3 — active in EVERY week of last month  → **4.75**

```sql
SELECT customer_id FROM customer_weekly_activity
WHERE week_date >= date_add('week', -4, date_trunc('week', current_date))
  AND week_date <  date_trunc('week', current_date)
GROUP BY customer_id
HAVING COUNT(DISTINCT week_date) = 4;
```

- `date_add('week', n, x)` valid — 'week' is a documented unit for date_add/date_trunc (datetime.md unit list:
  millisecond/second/minute/hour/day/**week**/month/quarter/year). `date_trunc('week', current_date)` valid.
- **"all weeks meet condition" via COUNT(DISTINCT week_date) = N** is the sound set-based idiom: each customer who
  has a row in all 4 distinct weeks passes; missing any week → count < 4 → excluded. No self-join, no manual per-week
  counting. Directly satisfies "without many JOINs/manual counting."
- Half-open window `[start, current-week-start)` correctly excludes the current partial week, so "4 complete weeks."
  `bool_and` is a valid alternative but COUNT(DISTINCT)=N is fully correct.
- Tiny nuance: "last month" ≈ 4 ISO weeks is a reasonable operational reading; only worth a hair of completeness shading.

Acc 5 / Clar 4.75 / App 4.75 / Comp 4.5.

## Q4 — this month vs last month revenue, side by side  → **4.8125**

```sql
SELECT
  SUM(amount) FILTER (WHERE month(order_date)=month(current_date) AND year(order_date)=year(current_date)) AS this_month_revenue,
  SUM(amount) FILTER (WHERE ... year-1) AS last_year_same_month_revenue,
  SUM(amount) FILTER (WHERE order_date >= date_trunc('month',current_date) - INTERVAL '1' MONTH
                        AND order_date <  date_trunc('month',current_date)) AS last_month_revenue
FROM orders;
```

- `FILTER (WHERE ...)` is "supported for all aggregate functions" (aggregate.md) — SUM-with-FILTER over multiple
  periods in ONE pass is valid and is exactly the no-app-side-math, two-columns-side-by-side answer requested.
- `month()`/`year()` both exist (datetime.md). `date_trunc('month', current_date) - INTERVAL '1' MONTH` half-open
  range is the robust last-month idiom; `INTERVAL '1' MONTH` is a valid literal (datetime.md operators table).
- NULLIF div-zero guard for the growth-% note is sound.
- Over-delivery: a 3rd `last_year_same_month_revenue` column beyond the 2 asked — harmless; **both requested columns
  (this_month, last_month) are present and correct.** Slight extra-column noise relative to the literal ask = tiny clarity ding.

Acc 5 / Clar 4.625 / App 5 / Comp 4.75.

---

## Overall

| Q | Score |
|---|---|
| Q1 | 4.875 |
| Q2 | 4.625 |
| Q3 | 4.75 |
| Q4 | 4.8125 |

**Overall average = 4.765625 → PASS** (well above 3.5; no per-question veto).

TICS clean across all four: no `::`, no QUALIFY, no false semi-join, no fabricated function, no regex-backslash
trap, no INTERVAL quarter/week qualifier (note: 'week' here is a date_add UNIT string, NOT an interval qualifier — correct),
no OFFSET-before-LIMIT, no over-warning folklore, no broken "for completeness" secondary form.

## Recommendation — Q1 FIX-A CONFIRMATION

The iter1044 LIGHT FIX-A (the inline r13 ~L3366 GROUP-BY-alias caveat co-located with the JSON
json_extract_scalar+COUNT(*) card) **reached the responder.** On this fresh nested-JSON group-and-count probe,
Q1 correctly **GROUP BY the repeated expression** (not the alias) and carried no ungrouped column — the
iter1039/iter1044 GROUP-BY-alias error did **NOT** recur. The FIX-A is confirmed by behavior on a novel
domain (`device.os` vs prior `geo.country`/`context.os`).

**Action: DEFAULT NO-OP this iter (margin +1.27). DOWNGRADE the JSON GROUP-BY-alias watch (r) → passive monitor
(FIX-A confirmed).** Re-probe the GROUP-BY-alias shape once more from a different angle (e.g. a non-JSON computed
GROUP BY expression with a SELECT alias) next sweep to certify durability before closing the watch entirely.
Q2 "no array_sum built-in" explicit framing = per-instance completeness monitor, not a resource gap. NO resource
edit; NO commit. MUST NOT bump state.json (already 1045).
