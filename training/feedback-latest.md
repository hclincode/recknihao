# Judge Feedback — iter1069 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source (dispositive over rendered HTML).

## Source URLs checked
- format(): https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/conversion.md
- from_unixtime: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- GREATEST/LEAST: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/comparison.md
- approx_distinct: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md

---

## Q1 — readable currency label via format()
Query: `format('%s %,.2f — %s', currency, amount_cents / 100.0, status)`

VERIFIED: `format(format, args...) -> varchar` follows Java Formatter (printf) syntax. The
conversion.md doc's OWN example `SELECT format('%,.2f', 1234567.89)` → `'1,234,567.89'`
confirms `%,.2f` = comma-grouping + 2-decimal precision, exactly as used. `%s` consumes the
varchar `currency`/`status`. `amount_cents / 100.0` — `100.0` is a DECIMAL literal (types.md:
exact-numeric, not DOUBLE), so this is exact DECIMAL division cents→dollars; `%,.2f` formats a
DECIMAL fine. Produced string matches the requested `'USD 29.99 — completed'`. concat_ws / ||
are valid alternatives but format() is the cleanest correct answer.
- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

## Q2 — epoch seconds → date-filterable timestamp
Query: `from_unixtime(occurred_at)`, WHERE `from_unixtime(occurred_at) >= current_timestamp - INTERVAL '7' DAY`

VERIFIED: all from_unixtime overloads return `timestamp(3) with time zone`; the function
"is the number of seconds since 1970-01-01 00:00:00 UTC" → expects SECONDS (correct). The WHERE
compares two `timestamp with time zone` values (from_unixtime result vs current_timestamp) →
valid, same type family. `occurred_at / 1e3` for milliseconds: `1e3` is a DOUBLE literal
(sci-notation), so the division yields a double, and from_unixtime accepts double — valid.
Minor completeness nit: filtering on from_unixtime(occurred_at) in WHERE is correct and readable
but is not partition-prunable on a raw integer column; a range on the raw integer prunes better.
Not penalized heavily — the timestamp comparison itself is fully correct.
- Accuracy 5 | Completeness 4.5 | Clarity 5 | Actionability 5

## Q3 — largest of three columns per row (GREATEST vs CASE)
Query: `GREATEST(mrr_usd, setup_fee_usd, annual_discount_usd)`, with NULL caveat.

VERIFIED + EXPLICITLY CONFIRMED: GREATEST/LEAST exist in 467 (comparison.md) and pick the
max across the row's arguments. CRITICAL NULL semantics — comparison.md states verbatim:
"Like most other functions in Trino, they return null if any argument is null." The doc even
calls out that this DIFFERS from PostgreSQL (which only returns null when ALL args are null).
The responder's caveat — "if any argument is NULL, GREATEST returns NULL — use COALESCE(col,0)"
— is EXACTLY correct and is the documented Trino behavior. Strong answer; chooses the function
over a verbose CASE as asked, and pre-empts the most common footgun.
- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

## Q4 — approximate distinct users per event type over ~800M rows
Query: `approx_distinct(user_id) ... GROUP BY event_type`, WHERE 30-day window, ~2.3% std error.

VERIFIED: approx_distinct exists; aggregate.md states "This function should produce a standard
error of 2.3%, which is the standard deviation of the (approximately normal) error distribution
over all possible sets." → the ~2.3% figure is the documented default for approx_distinct (NOT
approx_percentile — that conflation is avoided here). approx_distinct is HLL-backed (sibling
approx_set -> HyperLogLog). The "~100x less memory / 10-50x faster" are informal but
directionally reasonable HLL characterizations — not penalized. Correctly recommends exact
COUNT(DISTINCT) for billing-grade metrics.
- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

---

## Scores
| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = 79.5 / 16 = 4.97 — PASS** (threshold 3.5; margin +1.47)

## Defects found
None. All four headline queries are valid Trino 467 and correct. No `::`/QUALIFY/false
semi-join/fabricated-function/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/
over-warning/broken-secondary patterns. No broken "for completeness" appendix in any answer.

## Recommendation
DEFAULT NO-OP. Strong sweep across format()/from_unixtime/GREATEST-NULL/approx_distinct, all
source-confirmed. The recurring imported-prior risk families (GREATEST NULL, approx_distinct
2.3%, from_unixtime tz, 100.0-DECIMAL) all answered correctly. No resource edit; no commit.
MUST NOT bump state.json (already 1069).
