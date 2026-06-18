# iter1075 Judge Feedback (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.

**Overall average: 4.73 / 5.00 — PASS** (threshold 3.5; margin +1.23)

Verified BOTH directions against RAW git-tag 467 source:
- array.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- aggregate.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md
- select.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md
- conversion.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/conversion.md

Clean sweep on query correctness. One minor implementation-detail aside on Q2 (T-Digest claim) is the only source-flagged nit; it does NOT affect query correctness.

---

## Q1 — lowercase every element of tags array without unnesting (4.94)
`SELECT product_id, transform(tags, tag -> lower(tag)) AS lowercase_tags FROM products;`

- **Accuracy 5** — array.md VERIFIED `transform(array(T), function(T,U)) -> array(U)` "Returns an array that is the result of applying `function` to each element of `array`." `lower()` is standard. Result stays an array; no UNNEST. Exactly correct.
- **Completeness 5** — fully answers; correctly stresses no UNNEST needed (the user's explicit ask).
- **Clarity 5** — lambda mechanic explained plainly.
- **Actionability 5** — copy-paste ready.

## Q2 — median + p95 of contract_value (4.50)
`approx_percentile(contract_value, ARRAY[0.5, 0.95])` → `percentiles[1]` median, `percentiles[2]` p95.

- **Accuracy 4** — Array-form VERIFIED: aggregate.md confirms `approx_percentile(x, percentages_array)` "returns the approximate percentile ... at each of the specified percentages," yielding an array. Array indexing is 1-based (array.md) so `[1]`=0.5=median, `[2]`=0.95=p95 — CORRECT. `percentile_cont`/`percentile_disc`/`median` are CONFIRMED ABSENT from 467 aggregate.md — `approx_percentile` is indeed the answer. **NIT:** the "uses T-Digest sketching under the hood" claim is NOT supported by the 467 docs — aggregate.md does not state which sketch backs `approx_percentile` (it documents t-digest and qdigest as separate function families but never attributes either to `approx_percentile`). Treat as an unverified implementation-detail aside, NOT a query-correctness issue. The array-form query is correct regardless of the backing sketch. Minor accuracy ding only.
- **Completeness 5** — covers built-in vs manual sort, the no-exact-percentile fact, and billion-row suitability.
- **Clarity 4.5** — clear; the T-Digest aside risks overstating a detail the engineer might quote.
- **Actionability 5** — directly usable; subquery-then-index pattern shown.

## Q3 — GROUP BY plan_type + grand-total row, one query (4.81)
`GROUP BY ROLLUP(plan_type)` + `CASE GROUPING(plan_type) WHEN 0 THEN plan_type WHEN 1 THEN 'Grand Total' END` + `ORDER BY GROUPING(plan_type), plan_type`.

- **Accuracy 5** — select.md VERIFIED: `ROLLUP(c)` emits detail rows + one grand-total row (rolled-up column NULL). `GROUPING(col)` "a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise" → single-arg returns 0 for detail (plan_type present), 1 for the grand total. **CASE LABELS ARE CORRECT, NOT SWAPPED** (0→plan_type, 1→'Grand Total'). `ORDER BY GROUPING(plan_type)` puts the grand total (1) last. Contrast iter1070 Q2 multi-arg bitmask label transposition — single-arg here is right.
- **Completeness 5** — single query, no UNION, labels + ordering, all as asked.
- **Clarity 4.75** — explains ROLLUP and GROUPING bit clearly.
- **Actionability 5** — production-ready.

## Q4 — TRY_CAST varchar status to integer, NULL on failure (4.69)
`SELECT order_id, status, TRY_CAST(status AS INTEGER) AS status_code FROM orders;`

- **Accuracy 5** — conversion.md VERIFIED `try_cast` "Like cast, but returns null if the cast fails." `'completed'`→NULL, `'2'`/`'3'`→integers; query completes (CAST would throw). Correct.
- **Completeness 4.5** — answers fully; `WHERE status_code IS NOT NULL` filter note correct. Did not mention NULL-vs-empty edge, but not required.
- **Clarity 5** — TRY_CAST-vs-CAST distinction crisp.
- **Actionability 5** — directly usable.

---

## Per-question averages
- Q1: 4.94
- Q2: 4.50
- Q3: 4.81
- Q4: 4.69

**Overall: 4.73 — PASS**

## Source-verified verdicts requested
- **Q2 T-Digest claim:** UNVERIFIED. 467 aggregate.md does NOT state `approx_percentile` is backed by t-digest; t-digest and qdigest are documented as separate function families with no link to `approx_percentile`. Minor implementation-detail nit; query is correct regardless.
- **Q3 GROUPING labels:** CORRECT, not swapped. Single-arg `GROUPING(plan_type)`: 0=detail (column present)→plan_type, 1=rolled-up grand total→'Grand Total'. Matches select.md bit semantics.

No `::`-cast / QUALIFY / false-semi-join / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning / broken-secondary defects.

RECOMMENDATION = DEFAULT NO-OP (margin +1.23). Q2 T-Digest aside is a per-instance responder slip on an implementation detail, NOT a resource gap — do not churn. MUST NOT bump state.json (already 1075).
