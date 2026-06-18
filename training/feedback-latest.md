# Judge Feedback — iter1068 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions vs RAW git-tag 467 source (types.md, string.md, aggregate.md, window.md, sql/select.md) + WebSearch (issue #16533, PR #1796).

**Overall average: 4.05 — PASS** (overall average governs; no per-question veto). Two genuine LEAD-query defects (Q1 + Q3) absorbed by two clean answers (Q2 + Q4).

---

## Q1 — bundle order_id/status/total_amount into one value, read status back (avg 3.375)

Answer: `SELECT order_id, CAST(ROW(order_id, status, total_amount) AS ROW(id BIGINT, status VARCHAR, amount DECIMAL)) AS order_bundle, order_bundle.status AS extracted_status FROM orders`

- **Accuracy 2.5 / Completeness 4.0 / Clarity 4.5 / Actionability 2.5**
- **(a) CAST-to-named-ROW + dot-access idiom is CORRECT** — this resolves the iter1067 anonymous-ROW concern. RAW types.md confirms: "By default, row fields are not named, but names can be assigned"; `CAST(ROW(1, 2.0) AS ROW(x BIGINT, y DOUBLE)).x` is the documented named-field dot-access form. The positional-`[1]` note for bare anonymous `ROW(...)` is also correct (subscript 1-based, constant). The CONSTRUCTION is right.
- **(b) CRITICAL DEFECT — same-level SELECT-alias reference is INVALID.** The lead query references the SELECT-list alias `order_bundle` (`order_bundle.status`) inside a *sibling* expression of the *same* SELECT list. **Trino follows the SQL-standard scope rule: SELECT-list aliases are NOT visible to other expressions in the same SELECT list** (only ORDER BY can reference output aliases by name; SELECT / WHERE / GROUP BY / HAVING cannot). As written this raises `Column 'order_bundle' cannot be resolved`. The field access must be done in an OUTER query/subquery over the bundle:
  ```sql
  SELECT order_id, order_bundle, order_bundle.status AS extracted_status
  FROM (
    SELECT order_id,
           CAST(ROW(order_id, status, total_amount) AS ROW(id BIGINT, status VARCHAR, amount DECIMAL)) AS order_bundle
    FROM orders
  )
  ```
  This is a genuine lead-query accuracy defect (copy-paste fails to plan), not padding. VERDICT: the same-level `order_bundle.status` reference is INVALID.

## Q2 — collect ticket_id per assignee_id into a list (avg 4.875)

Answer: `SELECT assignee_id, array_agg(ticket_id ORDER BY ticket_id) AS assigned_tickets FROM support_tickets GROUP BY assignee_id`

- **Accuracy 5.0 / Completeness 4.75 / Clarity 4.75 / Actionability 5.0**
- VERIFIED: `array_agg(x ORDER BY ...)` with ORDER BY inside the aggregate is valid 467 (aggregate.md shows `array_agg(x ORDER BY y DESC)`), yields one array per group. Correctly answers "list of values per key". `array_join(array_agg(...), ', ')` comma-string secondary is valid (both functions exist). `multimap_agg(assignee_id, ticket_id)` is another valid one-row-map option (not required). Clean.

## Q3 — extract first word of device_model to group by brand (avg 3.125)

Answer: `SELECT device_model, split_part(device_model, ' ', 1) AS device_brand FROM events GROUP BY device_brand`

- **Accuracy 2.5 / Completeness 3.5 / Clarity 4.0 / Actionability 2.5**
- **(a) split_part extraction is CORRECT.** RAW string.md: "Splits `string` on `delimiter` and returns the field `index`. Field indexes start with `1`." So `split_part(device_model, ' ', 1)` returns the substring before the first space ('Samsung'), 1-indexed. Correct.
- **(b) CRITICAL DEFECT — the GROUP BY clause is INVALID for TWO reasons:**
  1. **GROUP BY references the SELECT alias `device_brand`** — Trino does NOT allow GROUP BY to reference a SELECT-list alias (issue #16533, by-design SQL-standard scoping). Must repeat the expression or use the ordinal.
  2. **`device_model` is in the SELECT but is neither grouped nor aggregated** — illegal with a GROUP BY ("must be an aggregate expression or appear in GROUP BY clause").
  Correct grouping:
  ```sql
  SELECT split_part(device_model, ' ', 1) AS device_brand, COUNT(*)
  FROM events
  GROUP BY split_part(device_model, ' ', 1)   -- or GROUP BY 1
  ```
  VERDICT: `GROUP BY device_brand` (SELECT alias) + ungrouped `device_model` is INVALID. This is the recurring #16533 trap (r13 FIX-A) plus an ungrouped-column slip — the lead query fails to plan.

## Q4 — day-over-day active-user change, first day 0 not null (avg 4.8125)

Answer: `... LAG(COUNT(DISTINCT session_id), 1) OVER (ORDER BY day) ... COALESCE(COUNT(DISTINCT session_id) - LAG(...), 0) AS day_over_day_change ... GROUP BY day`

- **Accuracy 4.875 / Completeness 4.75 / Clarity 4.75 / Actionability 4.875**
- VERIFIED: LAG over an aggregate in a GROUP BY query is valid (window functions evaluated after aggregation). `lag(x[, offset[, default_value]])` returns NULL for the first row when no default is given (window.md: "the `default_value` is returned, or if it is not specified `null`"). `COALESCE(..., 0)` gives 0 for the first day; the change column is correct. Minor: `LAG(expr, 1, 0)` third-arg default is the more direct "default 0" form, but the COALESCE-on-difference approach is equally valid. Essentially correct.

---

## Source-verified dialect notes

- SELECT-list aliases are NOT visible to sibling SELECT-list expressions, nor WHERE/GROUP BY/HAVING; only ORDER BY may reference output aliases by name. (Q1 verdict: same-level `order_bundle.status` INVALID — wrap in subquery.)
- GROUP BY cannot reference a SELECT-list alias — issue #16533, by-design. (Q3 verdict: `GROUP BY device_brand` INVALID — repeat expression or `GROUP BY 1`.)
- CAST(ROW(...) AS ROW(name type, ...)).name is the correct named-field dot-access idiom; bare ROW(...) fields are anonymous (positional `[1]`). RAW types.md. (Q1 construction is correct.)
- split_part index is 1-based; out-of-range returns NULL. RAW string.md.
- array_agg supports inner ORDER BY. RAW aggregate.md.
- lag(x[, offset[, default_value]]) → NULL on missing offset row if no default. RAW window.md.

Sources checked:
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/language/types.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/string.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md
- https://github.com/trinodb/trino/issues/16533

## Recommendation

Two LEAD-query defects this sweep (Q1 same-level SELECT-alias reference; Q3 GROUP-BY-alias #16533 + ungrouped column). Both are genuine accuracy defects, not responder padding. The #16533 GROUP-BY-alias trap RECURRED in the lead despite r13 FIX-A — teacher should verify the GROUP-BY-alias canonical is findable from "first word / split_part / group by brand" phrasings and that the device-brand-style first-word extraction example repeats the expression (or `GROUP BY 1`), never a SELECT alias, and never carries an ungrouped sibling column. For Q1, add a findable "wrap the bundle in a subquery before dot-accessing it" canonical — the named-ROW construction is already right; only the inline same-level alias reference is the gap. Re-probe both Q1 (subquery-wrapped field access) and Q3 (first-word GROUP BY) from a 2nd angle next sweep. MUST NOT bump state.json (already 1068).
