# Judge Feedback — iter1070 (2026-06-18)

**Stack:** Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA
**Verification:** RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/), both directions.

## Overall: 4.69 — PASS (threshold 3.5, margin +1.19)

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (safe map read) | 5.0 | 4.875 | 5.0 | 5.0 | 4.969 |
| Q2 (GROUPING SETS) | 4.25 | 4.875 | 4.5 | 4.75 | 4.594 |
| Q3 (weekday name) | 5.0 | 4.75 | 5.0 | 5.0 | 4.938 |
| Q4 (spread/stddev) | 4.75 | 4.5 | 4.875 | 4.875 | 4.75 |

**Overall average = (4.969 + 4.594 + 4.938 + 4.75) / 4 = 4.69 → PASS**

---

## Q1 — safe map read when key may be missing (4.969)

VERIFIED both directions against RAW `functions/map.md`:
- `element_at(map, key)` — "Returns value for given `key`, or `NULL` if the key is not contained in the map." Correct.
- Subscript `map[key]` — "This operator throws an error if the key is not contained in the map." Correct.

Responder's diagnosis is exactly right: `metadata['shipping_country']` throws "Key not present in map" on rows missing the key; `element_at(metadata,'shipping_country') = 'US'` returns NULL on missing keys and WHERE drops NULL rows (not an error). The `COALESCE(element_at(...),'Unknown')` default is a correct, useful addition. Clean, no defects.

## Q2 — GROUPING SETS for per-plan, per-region, overall (4.594)

VERIFIED against RAW `sql/select.md`:
- GROUPING SETS syntax valid 467. The four sets `((plan_type,region),(plan_type),(region),())` are syntactically valid and produce: detail, per-plan-type subtotal, per-region subtotal, grand total. (NOTE: the ask was three levels — by plan_type alone, by region alone, overall — the responder ALSO included the detail `(plan_type,region)` set; harmless superset, and the responder offered the trimmed `((plan_type),(region),())` form too. Minor completeness nuance, not penalized hard.)
- GROUPING bitmask: doc verbatim — "bits are assigned to the argument columns with the rightmost column being the least significant bit" and "a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise." So for `GROUPING(plan_type, region)`: plan_type=MSB(2), region=LSB(1); bit=1 means rolled up.
- The bitmask VALUES that occur (0,1,2,3) are CORRECT, and the revenue numbers are correct.

**CRITICAL VERDICT — the CASE label strings for bitmask 1 and 2 ARE SWAPPED:**
- Bitmask **1** = binary `01` = region rolled up (LSB=1), grouped BY plan_type → this is a **per-plan-type subtotal** → should read **'Plan Type Total'**. Responder wrote `1 THEN 'Region Total'`. WRONG.
- Bitmask **2** = binary `10` = plan_type rolled up (MSB=1), grouped BY region → this is a **per-region subtotal** → should read **'Region Total'**. Responder wrote `2 THEN 'Plan Type Total'`. WRONG.

The responder's OWN explanation bullets below the query ("1 = plan_type only (region rolled up)", "2 = region only (plan_type rolled up)") are CORRECT and directly contradict its CASE label strings — confirming this is a copy/label transposition, not a conceptual error.

This is a COSMETIC label-swap only: query mechanics, the grouping sets, the bitmask values, and the revenue figures are all correct; only the two human-readable `summary_level` strings are mislabeled. Scored as a minor accuracy deduction (Accuracy 4.25), NOT a query-correctness failure. Bitmask 0 ('Detail') and 3 ('Grand Total') are correctly labeled.

## Q3 — weekday name from started_at (4.938)

VERIFIED against RAW `functions/datetime.md`:
- `format_datetime(timestamp, format) -> varchar` exists and uses JodaTime DateTimeFormat patterns ("compatible with JodaTime's DateTimeFormat pattern format"). Joda `EEEE` yields the full text weekday name ('Monday'). Correct.
- `day_of_week(x)` returns ISO 1 (Monday) .. 7 (Sunday) — a number, not a name. Correct.
- No `dayname()` function in 467. Correct.

`format_datetime(CAST(started_at AS timestamp), 'EEEE')` is the right idiom. `date_format(ts,'%W')` is a valid alternative (MySQL-style strftime, also yields full weekday name) but `format_datetime 'EEEE'` is correct as given. Clean.

## Q4 — spread of monthly_revenue (4.75)

VERIFIED against RAW `functions/aggregate.md`: `stddev_samp`/`stddev` (sample), `stddev_pop` (population), `var_samp`/`variance` (sample), `var_pop` (population) all exist. Sample variants use N-1 (Bessel's correction), population variants use N. Std dev is in the same units as the data (variance is squared units). All correct. Minor completeness ding: did not mention percentile-based spread (IQR via approx_percentile / min-max range) as alternatives for skewed distributions, but the question asked specifically about spread and stddev/variance fully answers it.

---

## Source-verified dialect notes (RAW 467 URLs checked)
- map.md: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/map.md — element_at→NULL on missing; `[]` subscript throws.
- datetime.md: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md — format_datetime Joda; day_of_week 1=Mon..7=Sun; no dayname().
- select.md: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md — GROUPING bitmask: rightmost arg = LSB, bit=1 = column rolled up (absent from grouping).
- aggregate.md: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md — stddev_samp/pop + var_samp/pop exist; sample=N-1, population=N.

## Recommendation
DEFAULT NO-OP (margin +1.19). The only defect is the Q2 cosmetic CASE-label swap (1↔2). The responder's own bitmask-explanation bullets are correct, so this is a label-transposition slip in the LEAD, not a resource gap and not a query-correctness failure — scope it as a per-instance re-probe (re-ask a GROUPING-label question to confirm), do NOT churn resources. No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary across any answer. MUST NOT bump state.json (already 1070).
