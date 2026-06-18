# Judge Feedback — iter1044

**Overall: 4.015625 → PASS** (threshold 3.5; margin +0.515625)

Verified BOTH directions against RAW git-tag 467 source (array.md, json.md, datetime.md, window.md) + WebSearch/#16533 — NOT resources/. RAW git-tag source dispositive. Production stack confirmed Trino 467 + Iceberg on-prem k8s/MinIO (prod_info.md); all four answers are pure-SQL, stack-appropriate. NO federation probe (hard-locked).

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 5.0 | 4.5 | 5.0 | 4.875 |
| Q2 | 2.5 | 2.5 | 4.5 | 3.5 | 3.25 |
| Q3 | 2.5 | 3.0 | 4.0 | 3.0 | 3.125 |
| Q4 | 5.0 | 4.75 | 4.5 | 5.0 | 4.8125 |

Overall = (4.875 + 3.25 + 3.125 + 4.8125) / 4 = **4.015625 PASS**

---

## Q1 — array discount via transform — 4.875 (CLEAN)

`transform(line_items, price -> price * 0.9) AS discounted_items`

VERIFIED vs array.md (RAW 467): `transform(array(T), function(T,U)) -> array(U)` — "Returns an array that is the result of applying `function` to each element of `array`." The lambda multiplies each element by 0.9 and returns a NEW array, no UNNEST / no re-aggregate — exactly the constraint. Sound.

Note (not a defect): `0.9` is a DOUBLE literal; result type follows Trino numeric coercion. If `line_items` is `decimal`, the product is coerced; for exact money the engineer could `price * CAST(0.9 AS decimal(...))`, but the question did not request exact-decimal preservation. Minor clarity-only shading (-0.5) for not flagging the literal type.

## Q2 — % cancelled within 30 days, div-zero-safe — 3.25 (DENOMINATOR-SCOPE SEMANTIC ERROR; technique correct)

```sql
SELECT COUNT(*) FILTER (WHERE date_diff('day', started_at, cancelled_at) <= 30) * 100.0
       / NULLIF(COUNT(*), 0) AS pct_cancelled_within_30_days
FROM subscriptions
WHERE cancelled_at IS NOT NULL;
```

VERIFIED technique is all correct:
- `date_diff('day', ts1, ts2) -> bigint` (datetime.md RAW 467: "Returns `timestamp2 - timestamp1` expressed in terms of `unit`").
- `COUNT(*) FILTER (WHERE ...)` conditional aggregate — valid.
- `* 100.0` forces DOUBLE division (no integer truncation), `NULLIF(COUNT(*),0)` guards divide-by-zero on an empty/all-active table — both correct.

**DEFECT — wrong denominator scope.** The question asks for the percentage of **subscriptions** (the natural population = ALL subscriptions, active + cancelled) cancelled within 30 days. The trailing `WHERE cancelled_at IS NOT NULL` restricts the WHOLE query — both numerator and denominator — to cancelled rows only. So `NULLIF(COUNT(*),0)` counts ONLY cancelled subscriptions, and the result computes "% of CANCELLED subscriptions that cancelled within 30 days," NOT "% of ALL subscriptions." For a mostly-active table this OVERSTATES the metric substantially.

**FIX — remove `WHERE cancelled_at IS NOT NULL`.** Active subscriptions have `cancelled_at` NULL → `date_diff('day', started_at, NULL)` → NULL → `NULL <= 30` is not TRUE → correctly EXCLUDED from the FILTER numerator, while still counted in the `COUNT(*)` denominator. The div-zero guard still protects the empty-table case. Correct form:
```sql
SELECT COUNT(*) FILTER (WHERE date_diff('day', started_at, cancelled_at) <= 30) * 100.0
       / NULLIF(COUNT(*), 0) AS pct_cancelled_within_30_days
FROM subscriptions;   -- no WHERE
```
Accuracy/Completeness scored down for the wrong denominator scope; technique credited (clarity high; actionability partial — the engineer gets a runnable-but-wrong-answer query).

## Q3 — nested JSON properties.geo.country, GROUP BY country — 3.125 (BROKEN ON TWO COUNTS; core json correct)

```sql
SELECT event_id, json_extract_scalar(properties, '$.geo.country') AS country
FROM events GROUP BY country;
```

VERIFIED core guidance correct: `json_extract_scalar(json, json_path)` returns the value as a plain string (json.md RAW 467: "returns the result value as a string"), and nested dot-path `$.geo.country` is supported (doc example `$.store.book[0].author`). The extraction technique is right.

**DEFECT 1 — GROUP BY references a SELECT ALIAS.** `GROUP BY country` references the SELECT-list alias `country`, which Trino does NOT allow (analysis error; trinodb/trino **#16533** — "Using alias in group by is not supported by Trino," confirmed dispositive from the issue itself + SELECT doc: GROUP BY accepts expressions or ordinals only, no alias). Fix: repeat the expression `GROUP BY json_extract_scalar(properties, '$.geo.country')` or use the ordinal `GROUP BY 1`.

**DEFECT 2 — `event_id` is neither grouped nor aggregated** → second analysis error. The query would not run even after fixing the alias. For the stated intent ("GROUP BY country"), the correct shape is a per-country aggregation:
```sql
SELECT json_extract_scalar(properties, '$.geo.country') AS country, COUNT(*) AS n
FROM events
GROUP BY 1;
```

**RECURRENCE — 2nd occurrence, same shape as iter1039 Q3** (nested-JSON-extract-then-GROUP-BY-the-alias + ungrouped passthrough column). See recommendation.

## Q4 — quartile bucketing by total spend — 4.8125 (CLEAN; NTILE-over-aggregate VALID)

```sql
WITH ranked_customers AS (
  SELECT customer_id, SUM(amount) AS total_spend,
         NTILE(4) OVER (ORDER BY SUM(amount) DESC) AS spend_tier
  FROM orders GROUP BY customer_id)
SELECT customer_id, total_spend,
       CASE spend_tier WHEN 1 THEN 'Top 25%' ... END AS tier_label
FROM ranked_customers;
```

VERIFIED vs window.md (RAW 467): `NTILE(n)` "Divides the rows for each window partition into `n` buckets ranging from `1` to at most `n`. Bucket values will differ by at most `1`," remainder distributed from the first bucket (e.g. 6 rows / 4 → 1 1 2 2 3 4). NTILE(4) → quartiles, `ORDER BY ... DESC` → bucket 1 = top spenders. Correct.

**KEY VALIDITY CONFIRMATION — this is NOT the iter1038/1040 invalid bare-SUM-OVER case.** Here `SUM(amount)` inside `OVER (ORDER BY SUM(amount) DESC)` is an AGGREGATE in a `GROUP BY customer_id` query; window functions run AFTER GROUP BY, and ordering a window by an aggregate of a grouped query is VALID (the iter1038/1040 error was a BARE non-grouping column `revenue` inside OVER — that does NOT apply here because `amount` is wrapped in SUM). Window-not-in-WHERE → correctly wrapped in a CTE. CASE-on-spend_tier labelling is clean. -0.25 completeness shading only (does not note NTILE distributes any remainder to the earliest buckets for non-divisible customer counts).

---

## Recommendation

**(1) Q2 denominator-scope error — PER-INSTANCE SLIP, no resource gap.** The technique (COUNT(*) FILTER, NULLIF div-zero guard, 100.0 float division, date_diff->bigint) is all taught correctly and rendered correctly — this is a one-off reading error where the responder over-restricted the population with a `WHERE cancelled_at IS NOT NULL` that should have been omitted (active subs are correctly excluded by the NULL-propagating FILTER predicate alone, while remaining in the denominator). This is a NULL-aware-denominator reasoning miss, not a missing card. Classify as RESPONDER SLIP (watch, low-expectation); re-probe a "% of total population conditioned on a nullable timestamp" question next sweep. NO resource edit for this one.

**(2) Q3 GROUP-BY-alias — RECURRENCE (2nd occurrence, iter1039 Q3 shape) → LIGHT FIX-A warranted (FINDABILITY GAP at the JSON card).** GREP findings:
- The #16533 "GROUP BY the expression/ordinal, NOT the alias" caveat IS well-anchored generically in r07 (L2000, L2051 worked-GROUP-BY notes; L2777 "Trino GROUP BY rules" anchor) and r23.
- BUT the primary JSON-extraction card (r13 §"store as VARCHAR", L3363-3369) shows `GROUP BY 1` (the SAFE ordinal form) WITHOUT a co-located inline caveat that `GROUP BY <alias>` is an error. A Haiku responder pulling `json_extract_scalar` from the JSON context lands at the r13 card, mirrors the SELECT-list alias into GROUP BY, and never traverses ~700+ lines into the r07 GROUP-BY-rules anchor.

Same buried-guard findability pattern as iter1040 Q1 (running-total). Two occurrences of the JSON-extract-then-group-by-alias shape (iter1039 Q3 + iter1044 Q3) satisfy the 2-in-2 bar for a LIGHT, ADDITIVE FIX-A:

> **Teacher LIGHT FIX-A (additive, no reconcile — existing content is correct):** At the r13 json_extract_scalar GROUP BY example (~L3366), add a one-line inline caveat co-located with the card:
> `-- GROUP BY 1 (ordinal) or repeat json_extract_scalar(properties,'$.geo.country') — Trino does NOT allow GROUP BY <select alias> (#16533).`
> Do the same for any other json_extract_scalar example immediately followed by a GROUP BY. Keep it inline at the copy-attractive card so keyword→resource matching surfaces it together with the extraction recipe. Do NOT touch the r07/r23 anchors (intact).

The `event_id` ungrouped passthrough is part of the same responder synthesis miss; the existing per-country `SELECT expr, COUNT(*) ... GROUP BY 1` pattern at r13 L3366 already models the correct full shape — no extra card needed for the passthrough.

**Overall:** PASS at 4.0156. Single additive FIX-A recommended (Q3 JSON-card GROUP-BY caveat). No reconcile, no lock edits, federation untouched. MUST NOT bump state.json (already 1044).
