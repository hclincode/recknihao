# Judge Feedback — iter806

Stack (prod_info.md): on-prem Trino 467 + Iceberg connector, Hive Metastore, MinIO/S3, Spark ingestion, dbt. All dialect claims verified against trino.io/docs/467.

## Per-question scores

### Q1 — Extract Chrome version after 'Chrome/' (capture group) — FIX RE-CHECK
Answer: `regexp_extract(user_agent, 'Chrome/([0-9.]+)', 1) AS chrome_version` -> `'118.0.5993.88'`. Explicitly states the 3-arg form is required and that the 2-arg form returns the WHOLE match. Cites r23.

VERIFIED (trino.io/docs/467/functions/regexp.html): 3-arg `regexp_extract(string, pattern, group)` returns the capture group; doc example `regexp_extract('1a 2b 14m', '(\d+)([a-z]+)', 2)` = `'a'`. `[0-9.]+` matches digits and dots. The 2-arg form returns the first whole match. The answer is correct AND the responder USED the 3-arg form with the group index (did NOT emit the bare 2-arg this time) and correctly explained the whole-match rule.

- Accuracy: 5
- Completeness: 5
- Clarity: 5
- Actionability: 5
- **Q1 avg: 5.0**

**regexp_extract-capture-group is CLOSED.** The iter806 stronger inoculation (top-of-card group-index RULE + 3-arg-only copy-attractive value-after-label form + sharpened 2-arg WRONG-OUTPUT defang at r23:2820-2821) WORKED. No recurrence of the iter805 2-arg slip.

### Q2 — Count items in a JSON array STRING column (no explode) — DEFECT
Answer (messy): first `cardinality(CAST(order_items_json AS JSON) -> order_items_json)` (GARBLED — the `->` with a column name is nonsense), then "simpler" `cardinality(CAST(order_items_json AS ARRAY(JSON))) AS item_count`. Did NOT mention `json_array_length`. Cites r07 §1a.3.

VERIFIED (trino.io/docs/467/functions/json.html): Trino has `json_array_length(json) -> bigint` — "Returns the array length of `json` (a string containing a JSON array)." `json_array_length('[1, 2, 3]')` = `3`. This is the DIRECT one-function answer: `json_array_length(order_items_json)` = 3 (accepts a varchar holding a JSON array, no parse/explode).

Also VERIFIED: a bare `CAST(varchar AS ARRAY(JSON))` is NOT correct. Per the docs, `CAST(string AS JSON)` treats the input as a plain string (wraps in quotes) rather than parsing it — you must `json_parse()` first. Correct fallback: `cardinality(CAST(json_parse(order_items_json) AS ARRAY(JSON)))`.

So the responder (i) MISSED the direct `json_array_length`, (ii) emitted a garbled `-> order_items_json` expression, and (iii) gave a `CAST(... AS ARRAY(JSON))` that is likely-invalid without `json_parse`. DEFECT.

- Accuracy: 1 (garbled expr + invalid cast; missed the correct function)
- Completeness: 2 (count intent addressed but with broken SQL)
- Clarity: 2 (two competing attempts, one garbled)
- Actionability: 1 (an engineer copying either form gets a parse/type error)
- **Q2 avg: 1.5**

**Q2 verdict — content/findability gap.** `json_array_length` DOES exist in resources but NOT where the count question lands:
- `resources/13-postgres-to-iceberg-ingestion.md:3389, 3417, 3419-3420, 3424, 3427, 3438` (JSON extraction family card)
- `resources/22-trino-federation-postgresql.md:7277` (federation context)

r07 (`07-analytical-query-patterns.md`), which the responder cited, has NO `json_array_length`. Its §1a.3 (line 551+) defines `cardinality(array)` for NATIVE arrays only (`cardinality(array) -> bigint`, line 560), and its JSON-array section (lines 72-101) covers EXPLODE via `CAST(json_parse(col) AS ARRAY(VARCHAR))` — nothing about COUNTING without exploding. The responder mashed cardinality + the json_parse/CAST-array pattern together and produced the garbled/invalid form. This is primarily a FINDABILITY MISS (right content, wrong location) compounded by a CONTENT GAP (no canonical json_array_length COUNT card at the r07 keyword path).

### Q3 — Running max (high-water mark) — CLEAN
Answer: `MAX(account_balance) OVER (PARTITION BY account_id ORDER BY event_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS peak_balance_to_date`. Cites r07.

VERIFIED: `MAX(x) OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is the standard running maximum (high-water mark up to and including the current row). Correct frame, correct partition/order.

- Accuracy: 5
- Completeness: 5
- Clarity: 5
- Actionability: 5
- **Q3 avg: 5.0**

### Q4 — Correlation coefficient between ad_spend and revenue — HONEST DECLINE, native answer existed
Answer: declined — "resources mention corr()/covar_samp() only via PostgreSQL federation; cannot confirm native Trino support for local Iceberg tables; check trino.io/docs/467 or compute by hand." Cites r22 (federation).

VERIFIED (trino.io/docs/467/functions/aggregate.html): Trino has NATIVE `corr(y, x) -> double` ("Returns correlation coefficient of input values"), `covar_pop(y, x)`, `covar_samp(y, x)`, `regr_slope(y, x)`, `regr_intercept(y, x)`. These are native statistical aggregate functions, NOT federation-only. The direct answer is `corr(ad_spend, revenue)` (works on local Iceberg tables).

The honest decline is correct no-hallucinate behavior (no penalty vs fabricating), but a real, simple native answer existed, so completeness/actionability are low.

- Accuracy: 3 (declined rather than asserting anything wrong — no fabrication; but the implied "maybe not native" framing is technically off)
- Completeness: 2 (the native answer existed and was not given)
- Clarity: 4 (clear about the limitation and where to look)
- Actionability: 3 (pointed to the right doc and to compute-by-hand, but did not hand over the one-liner)
- **Q4 avg: 3.0**

**Q4 verdict — coverage/findability gap.** corr/covar/regr ARE native Trino aggregates but appear in resources ONLY in the r22 FEDERATION pushdown context:
- `resources/22-trino-federation-postgresql.md:8555` (pushdown 16-function list)
- `resources/22-trino-federation-postgresql.md:8686` ("Supported aggregate functions … `covar_pop()`, `covar_samp()`, `corr()`, `regr_intercept()`, `regr_slope()`")
- `resources/22-trino-federation-postgresql.md:9176` (connector aggregate summary)

There is NO native-Trino aggregate-stats card outside federation. The standing native-stats inventory covers variance/stddev but the correlation/covariance/regression family is surfaced only as a connector-pushdown list. So the responder reasonably concluded it might be federation-only. Gap confirmed.

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.0 |
| Q2 | 1.5 |
| Q3 | 5.0 |
| Q4 | 3.0 |

**Overall avg = (5.0 + 1.5 + 5.0 + 3.0) / 4 = 3.625**

**RESULT: PASS** (overall avg 3.625 >= 3.5; overall average governs, no single-Q veto).

## iter807 designation — FIX-A (two specific additive fixes)

1. **json_array_length canonical for JSON-array COUNT (HIGH priority).** Add a fenced, copy-attractive card at the r07 keyword path (`07-analytical-query-patterns.md`, in/near the JSON-array-string section lines 72-101 and §1a.3 cardinality line 551+) for "count items in a JSON array string column / how many elements / array length without exploding":
   - Canonical: `json_array_length(order_items_json)` -> `3` (accepts a varchar holding a JSON array; NO parse, NO explode, NO path).
   - Disambiguate from EXPLODE (UNNEST) which is already there.
   - Fallback for ARRAY(JSON) work: `cardinality(CAST(json_parse(order_items_json) AS ARRAY(JSON)))`.
   - DEFANG (inline-marked WRONG, un-copyable): bare `CAST(varchar AS ARRAY(JSON))` without `json_parse` (wraps the string as a quoted JSON scalar — does NOT parse the array); and any `cardinality(CAST(col AS JSON) -> col)` `->`-with-column-name garble. Make json_array_length the only copy-attractive value-after-label form. Add a cross-ref from §1a.3 (which is native-array-only) pointing JSON-string counts to the json_array_length card.

2. **Native corr/covar/regr aggregate-stats card OUTSIDE federation (HIGH priority).** Add a native-Trino statistical-aggregates card (likely r07, alongside the variance/stddev inventory) listing `corr(y, x)`, `covar_samp(y, x)`, `covar_pop(y, x)`, `regr_slope(y, x)`, `regr_intercept(y, x)` as NATIVE Trino aggregates that work on local Iceberg tables (not federation-only).
   - Canonical: `corr(ad_spend, revenue)` for the correlation coefficient across campaigns.
   - Make explicit these are native (the federation list in r22:8686 is a SUBSET that happens to push down — not the source of truth for availability).
   - Cross-ref r22 so the federation list points back to the native card to avoid the "federation-only" misread.

Both are additive findability/coverage fixes — no contradictory content to reconcile beyond adding the native-vs-federation note in r22.
