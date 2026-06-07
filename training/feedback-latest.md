# Judge Feedback — iter588 (2026-06-07, EXTENDED PHASE)

**Verdict**: PASS (overall avg **4.25**) — Q3 ROW/struct dot-access flagged as quality concern (per-Q 2.00, below 3.5). Overall-average rule governs the label; no per-question gate override applied.

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | Self-join employees↔managers (LEFT JOIN aliases) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | Above own-category average (window AVG OVER PARTITION BY) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | ROW/struct dot-access (`address.city`) — MISSED | 1 | 3 | 2 | 2 | 2.00 |
| Q4 | cardinality(array) + NULL-array handling | 5 | 5 | 5 | 5 | 5.00 |

**OVERALL AVG = (5.00 + 5.00 + 2.00 + 5.00) / 4 = 17.00 / 4 = 4.25 PASS**

---

## Verifications against trino.io/docs/467/ (verbatim quotes)

### Q1 — self-join LEFT JOIN (trino.io/docs/current/sql/select.html)

Standard SQL self-join via table aliasing; LEFT JOIN preserves left rows when right side absent. Responder's `m.employee_id = e.manager_id` pairing is correct; the CEO row (e.manager_id IS NULL) keeps `manager_name = NULL` under LEFT JOIN — that is the documented LEFT JOIN semantic in Trino 467. Zero defects.

### Q2 — window AVG OVER PARTITION BY (trino.io/docs/current/functions/window.html, trino.io/docs/current/sql/select.html)

- `AVG(price) OVER (PARTITION BY category)` is a valid aggregate-as-window function producing the per-category average on every row.
- Responder's claim "you can't use a window function in WHERE" is correct: Trino evaluates window functions AFTER WHERE/GROUP BY/HAVING, so the canonical pattern is wrap-in-subquery + filter-in-outer-query.
- The alternative correlated subquery `WHERE price > (SELECT AVG(price) FROM products p2 WHERE p2.category = p.category)` is also valid. Both forms answer the question; the window form is the recommended canonical for OLAP because it's a single scan with no re-aggregation per outer row.
- Zero defects.

### Q3 — ROW/struct field access (trino.io/docs/current/language/types.html) — **RESPONDER MISSED**

Verbatim from trino.io/docs/current/language/types.html (ROW section):

> "A structure made up of fields that allows mixed types. The fields may be of any SQL type."
> "Named row fields are accessed with field reference operator (`.`)."
> Example: `CAST(ROW(1, 2.0) AS ROW(x BIGINT, y DOUBLE)).x`

The question explicitly states: *"address column that's a NESTED STRUCTURE — street, city, state, zip fields packed inside one column"* — that is the textbook description of a Trino/Iceberg `ROW(street VARCHAR, city VARCHAR, state VARCHAR, zip VARCHAR)` column. **The correct answer is dot notation:**

```sql
SELECT address.city
FROM customers
WHERE address.state = 'CA';
```

The responder gave NEITHER this form. Instead it offered:

(a) `element_at(address, 'city')` — Per trino.io/docs/current/functions/map.html: *"element_at(map(K, V), key) → V — Returns value for given key, or NULL if the key is not contained in the map."* The only signatures are `element_at(map(K,V), key) → V` and `element_at(array(T), bigint) → T`. **There is NO `element_at(row(...), VARCHAR)` signature in Trino 467.** On a native ROW column, `element_at(address, 'city')` is a plan-time type error: `function 'element_at' not registered for argument types (row(street varchar, city varchar, state varchar, zip varchar), varchar)`.

(b) `json_extract_scalar(address, '$.city')` — Per trino.io/docs/current/functions/json.html, `json_extract_scalar` requires VARCHAR or JSON input. On a ROW column this is also a type error: `cannot apply json_extract_scalar to row(...)`. No implicit ROW → JSON cast happens at function-argument resolution.

Both forms ERROR at plan time on a native ROW column. The answer for the stated type is absent. The correct answer is the documented dot notation.

### Q4 — cardinality(array) (trino.io/docs/current/functions/array.html)

Verbatim from trino.io/docs/current/functions/array.html:

> "cardinality(x) → bigint — Returns the cardinality (size) of the array x."

- `cardinality(tags) AS tag_count` is correct Trino 467.
- For NULL-array handling: `cardinality(NULL) = NULL` (standard SQL strict-NULL propagation). The responder's `WHERE cardinality(tags) = 0 OR tags IS NULL` is correct because `cardinality(NULL) = 0` evaluates to `NULL`, not TRUE, so the explicit `IS NULL` arm is required to capture NULL-array rows.
- "Trino uses `cardinality`, not `array_length`" — correct. There is no `array_length` function in Trino 467.
- Zero defects.

---

## Q3 FINDABILITY DIAGNOSIS (PRIMARY iter588 finding)

**This is a FINDABILITY miss, not a content gap.** The native ROW dot-access content exists in r09 (lines 757-806, LEADING CANONICAL — `CAST(json_parse(s) AS ROW(...))` with `user_record.user_id` / `user_record.email` dot-access examples). The problem is that this canonical's keyword anchors and framing are entirely about **JSON parsing into a typed ROW**, not about **getting a field out of an existing native ROW column**.

Grep confirms: the keyword strings "nested structure", "native struct", "native ROW", "struct column", and "address.city" appear in ZERO resources outside of r13 (ingestion) and r22 (federation) — neither of those is the landing point for a "give me a field out of a struct column" question. The r09 ROW dot-access canonical itself does NOT surface on any of the question's keyword routes:

- "nested structure" → no anchor
- "struct column" → no anchor
- "field of a struct" → no anchor
- "address.city" → no anchor

What IS findable at the question's keyword route:

- MAP `element_at` content (r09 lines 525-700) — keyed-lookup framing matches "field of an address column" superficially.
- JSON `json_extract_scalar` content (r09 lines 552, 605, 802) — string-path framing matches "extract city from address" superficially.

Both are the WRONG TYPE for a native struct column. The responder's answer perfectly demonstrates the failure mode: it landed on MAP and JSON paths because the ROW canonical's findable surface is locked behind "JSON → ROW CAST" framing.

---

## iter589 directive (PRIMARY — teacher action)

### A. r09 — add a findable "native ROW/struct COLUMN → dot-access" LEADING CANONICAL at the keyword landing point (reconcile-don't-append)

Add a NEW canonical section in r09, distinct from the existing JSON → ROW CAST canonical at lines 757-806. Title must surface for the question's keywords. Suggested form:

```
### LEADING CANONICAL — Native Iceberg ROW/struct COLUMN — get a field with dot notation (NO CAST needed)

**Keyword anchors so the responder lands here:** nested structure column, struct column field access, get a field out of a struct, row type field access, address.city, dot notation Trino, named field access, native ROW column, Iceberg struct column field, struct field extract, struct field projection, nested fields packed in one column.

When your column is ALREADY typed as `ROW(field1 T1, field2 T2, ...)` — for example an Iceberg column declared as `address ROW(street VARCHAR, city VARCHAR, state VARCHAR, zip VARCHAR)` — you access fields with the dot operator. NO CAST. NO json_parse. NO element_at.

-- CORRECT
SELECT
  customer_id,
  address.city  AS city,
  address.state AS state
FROM customers
WHERE address.state = 'CA';

Verbatim from trino.io/docs/current/language/types.html: "Named row fields are accessed with field reference operator (.)."
```

#### DO-NOT-WRITE — patterns that ERROR on a native ROW column

| Wrong | Why it errors | Right |
|---|---|---|
| `element_at(address, 'city')` | `element_at` is registered ONLY for `map(K,V)` and `array(T)` per trino.io/docs/current/functions/map.html + functions/array.html. NO row(...) signature. Plan-time type error. | `address.city` |
| `json_extract_scalar(address, '$.city')` | Requires VARCHAR or JSON input. On `row(...)` it is a type error; no implicit ROW → JSON cast at function-arg resolution. | `address.city` |
| `address['city']` (string key subscript) | The `[]` subscript on ROW takes a BIGINT position only (`address[2]`), NOT a field name string. | `address.city` (named) or `address[2]` (positional, 1-based) |
| `CAST(json_parse(address) AS ROW(...))` | The column is ALREADY a ROW — there is no JSON string to parse. Type error. | `address.city` |

Then add a forward-reference at the top of the existing JSON → ROW CAST canonical (line 757) pointing back to this new native-ROW canonical, with a one-sentence disambiguator: *"If your column is already typed as `ROW(...)`, skip this section — use dot notation directly. This section is for the JSON-STRING-to-typed-ROW promotion path only."*

### B. r09 element_at + json_extract_scalar sections — add a DO-NOT-WRITE pointer

At both the MAP `element_at` and the JSON `json_extract_scalar` landing points, add a one-line DO-NOT-WRITE callout:

> **DO NOT use `element_at` / `json_extract_scalar` on a native ROW/struct column** — these functions are registered for MAP/ARRAY (element_at) and VARCHAR/JSON (json_extract_scalar) only; on a ROW they are plan-time type errors. For a native ROW column, use dot notation `col.field` — see the "Native Iceberg ROW/struct COLUMN — get a field with dot notation" canonical above.

This DO-NOT-WRITE addresses the recognition failure: when the responder lands on the MAP or JSON content via keyword match, it sees an immediate signal that ROW columns route elsewhere.

### C. DO NOT

- Do NOT rewrite the existing `CAST(json_parse(s) AS ROW(...))` canonical at lines 757-806 — it is correct for the JSON-string-input case. Only ADD a forward-disambiguator pointer at its top.
- Do NOT touch r22 §13.x federation guardrails — not probed this iter.
- Do NOT touch any iter534-587 locks listed in state.json — preserve in full.
- Do NOT add `::`-cast anywhere; keep `CAST(x AS T)`.

### D. Optional probe for iter590-591

Re-probe ROW/struct dot-access from a DIFFERENT phrasing to confirm the new canonical routes:

- "I have an Iceberg table where the `geo` column is a struct with `lat` and `lon` — how do I select `lat`?"
- "My events table has a `device` column typed as `ROW(make VARCHAR, model VARCHAR)` — how do I filter on `make = 'Apple'`?"

Either phrasing should land on the new native-ROW canonical via the dot-notation keyword anchors, not on element_at or json_extract_scalar.

---

## Notes

- iter588 PRIMARY = Q3 ROW dot-access findability miss; iter587 STRONG PASS (4.9375) durability holds for Q1/Q2/Q4 forms.
- WebSearched + verified verbatim today: trino.io/docs/current/language/types.html (ROW field reference operator `.`), trino.io/docs/current/functions/map.html (element_at MAP signature only), trino.io/docs/current/functions/array.html (cardinality(x) → bigint; element_at ARRAY signature only), trino.io/docs/current/functions/window.html (window functions evaluated after WHERE).
- Did NOT bump training/state.json (teacher already set iteration=588, phase=extended).
- Federation rubric row 4.49944/310 UNCHANGED — not probed.
- Q1 (self-join), Q2 (window AVG), Q4 (cardinality) all zero-defect docs-verbatim correct.
- Meta-rule observation: iter588 demonstrates that "findability by keyword match" beats "content correctness at the wrong landing point" — the ROW dot-access content exists in r09 but its keyword surface routes ONLY off "JSON parsing" framing, so a question about a native struct column gets routed to MAP/JSON paths that error on the stated type. The fix is a SECOND canonical with the question's actual keyword surface, not a rewrite of the existing one.

**OVERALL: 4.25 PASS (overall avg >= 3.5) — Q3 ROW/struct dot-access findability miss flagged as quality concern; iter589 = add native-ROW dot-access LEADING CANONICAL at the "nested structure / struct column / get a field out of a struct" keyword landing point in r09, distinct from the existing JSON-to-ROW CAST canonical, with DO-NOT-WRITE callouts at the MAP element_at and JSON json_extract_scalar landing points pointing back to the new ROW canonical. Q1 + Q2 + Q4 all zero-defect; federation row unchanged.**
