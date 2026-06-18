# Judge Feedback — iter1062 (2026-06-18)

**Stack:** Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
**Verification:** BOTH directions vs RAW git-tag 467 source + trino.io/docs + WebSearch. Scored against real Trino 467 behavior, NOT resources/.

## Per-question scores

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 bool_and "every row in group satisfies X" | 5.0 | 4.875 | 4.875 | 5.0 | 4.9375 |
| Q2 integer / and % split dollars/cents | 4.9375 | 4.875 | 4.9375 | 4.9375 | 4.921875 |
| Q3 element_at vs [] subscript safe map read | 5.0 | 4.9375 | 4.9375 | 5.0 | 4.96875 |
| Q4 running total over ORDER BY order_date | 4.9375 | 4.9375 | 4.875 | 4.9375 | 4.921875 |

**Overall average = (4.9375 + 4.921875 + 4.96875 + 4.921875) / 4 = 4.9375**

**VERDICT: PASS (4.9375 >> 3.5). Margin +1.4375.**

## Q1 — bool_and routing CONFIRMED CORRECT (iter1061 all_match mis-route is FIXED)

`SELECT pricing_plan, bool_and(payment_verified) AS all_verified FROM subscriptions GROUP BY pricing_plan` is the textbook-correct routing for "did EVERY ROW in a group satisfy X."

Verified against RAW aggregate.md:
- `bool_and(boolean) -> boolean` EXISTS and "Returns TRUE if every input value is TRUE, otherwise FALSE."
- bool_and is NOT in the documented NULL-non-ignoring exception list (count, count_if, max_by, min_by, approx_distinct) → it IGNORES NULLs.
- All-NULL group / empty group → returns NULL (not FALSE). The responder explicitly called this out and prescribed `COALESCE(bool_and(...), false)` to force FALSE — accurate and a genuinely useful nuance for a SaaS billing query.

This is exactly the boolean-aggregate the prior iteration MISSED. iter1061 Q3 (1.625) wrongly reached for `all_match(ARRAY[...], x->contains(feature_flags,x))` inside a GROUP BY HAVING, referencing an ungrouped per-row column — a planner error and a category confusion (all_match tests all ELEMENTS of ONE array; bool_and tests all ROWS in a group). The responder has now correctly routed a "did all rows satisfy X" question to bool_and. The bool_and/bool_or gap from iter1061 is closed for this angle.

Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md

## Q2 — integer division + modulus CONFIRMED CORRECT

`amount_cents / 100 AS dollars, amount_cents % 100 AS cents` (1999 → 19, 99) is correct.
- Trino 467 integer `/` performs truncation TOWARD ZERO (Java/C semantics), so 1999/100 = 19 (verified math.md "Division (integer division performs truncation)" + WebSearch confirming toward-zero, e.g. -1999/100 = -19 not -20).
- `%` modulus works on integers: 1999 % 100 = 99 (math.md operator table; equivalent `mod(n,m)`).
- "No casting needed" is correct since amount_cents is already an integer column.
- NOTE (not a defect): this is distinct from CAST(double/decimal AS integer) which ROUNDS half-up — the responder correctly used the `/` and `%` operators (truncate), not a cast, so no rounding trap here.

Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md

## Q3 — element_at vs [] subscript CONFIRMED CORRECT (both directions)

Verified RAW map.md:
- `element_at(map, key)`: "Returns value for given key, or NULL if the key is not contained in the map."
- `[]` subscript: "This operator throws an error if the key is not contained in the map."

The responder's `element_at(properties,'some_key')` + `COALESCE(element_at(...),'unknown')` default is the canonical safe-read idiom for sparse maps. Both directions match the documented behavior exactly. Mirrors iter1060 Q4 / iter1061 Q1 — element_at safety is a durable strength.

Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/map.md

## Q4 — running total + DEFAULT RANGE frame CONFIRMED CORRECT

Both forms are valid Trino 467 and the responder's framing of the difference is accurate.

(a) `SUM(revenue) OVER (ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` — valid explicit ROWS frame, gives a true ROW-LEVEL running total (each physical row gets the cumulative sum up to and including itself).

(b) DEFAULT-frame claim VERIFIED: select.md states the default when ORDER BY is present without an explicit frame is "RANGE UNBOUNDED PRECEDING, which is the same as RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW." A RANGE frame includes "all rows from the start of the partition up to the last peer of the current row" — so rows sharing the same order_date (peers) ALL receive the same cumulative value. The responder's description ("omit the frame and let Trino use its default RANGE frame ... all show the same cumulative value") is exactly right.

(c) No GROUP BY conflict — the query does not aggregate, it is a pure window function over base rows. This is the LEGITIMATE row-level/peer-level running-total reading, NOT the invalid "SUM(x) OVER beside GROUP BY day" anti-pattern. PARTITION BY tenant_id for the multi-tenant case is a correct and on-stack bonus.

Sources:
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md

## Anti-pattern scan (all clean)

No `::` cast, no QUALIFY, no false semi-join, no fabricated function, no regex-backslash trap, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no over-warning folklore, no broken-secondary alternative. Every secondary form offered (COALESCE wrap, default-frame variant, PARTITION BY) is valid.

## Recommendation

DEFAULT NO-OP (margin +1.4375). The iter1061 bool_and/bool_or gap is now closed from a second angle (this Q1 is the "every row satisfies X" boolean-aggregate routing the prior iter missed). No resource edit; no commit needed. MUST NOT bump state.json (teacher already at 1062).
