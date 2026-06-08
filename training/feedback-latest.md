# iter708 Judge Feedback

## Verdict: PASS (overall avg = 4.625)

FIX-A status: **CLOSED**. The iter708 READ-ME-FIRST clarifier landed cleanly — Q1 answer states the direction-INDEPENDENT default plainly and without the iter707 circular framing.

---

## Per-question scoring

### Q1 — NULL ordering on `ORDER BY last_login DESC`, never-logged-in at bottom

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00**

- Verified against trino.io/docs/467/sql/select.html: **"The default null ordering is `NULLS LAST`, regardless of the ordering direction."** Responder said exactly this.
- Direction-INDEPENDENT default: correct. "ORDER BY last_login defaults NULLS LAST, ORDER BY last_login DESC also defaults NULLS LAST."
- Did NOT make the iter707 mistake of saying "NULLS LAST is required to GET NULLs at end on DESC" — instead said "Trino does this by default anyway but explicit is clearer."
- Bonus deltas all hit: Oracle/Postgres "NULL-as-larger" cross-engine differ called out; ASC-also-defaults-NULLS-LAST explicit; "does NOT flip" defang language used.
- Gave the exact SQL: `ORDER BY last_login DESC NULLS LAST`.
- **FIX-A CLOSED.** The iter708 READ-ME-FIRST block in r07 was successfully routed to.

### Q2 — Extract email domain via `split_part`

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00**

- Verified against trino.io/docs/467/functions/string.html: `split_part(string, delimiter, index)` is valid, "Field indexes start with `1`", and **"If the index is larger than the number of fields, then null is returned."** Responder's "Malformed no-@ email → split_part returns NULL for index 2 (not an error)" is **exactly correct** per docs.
- Gave the full SQL with GROUP BY + ORDER BY COUNT(*) DESC — directly usable.
- Mentioned `split_part(email,'@',1)` for the local-part counterpart — nice completeness.
- 1-indexed clarification + the index-1-vs-index-2 framing kills the off-by-one trap.

### Q3 — Conversion-rate percentage rounded to 2 decimals

**Scores: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 — avg 4.75**

- `ROUND(100.0 * converted_users / total_users, 2)` — verified valid Trino 467.
- `format('%.2f%%', ...)` — verified valid Trino 467 (format follows Java Formatter, `%%` escapes literal percent per conversion.html docs).
- Integer-division-truncation warning is correct: `bigint/bigint` truncates; the `100.0` decimal literal promotes the expression to a non-integer type.
- **Minor completeness nit:** no `NULLIF(total_users, 0)` to guard division-by-zero. If `total_users = 0`, the query errors with "Division by zero". A SaaS engineer computing conversion rates per cohort/segment will likely hit a zero-denominator cohort eventually. Not blocking, but a clear miss; recommend the canonical form be `ROUND(100.0 * converted_users / NULLIF(total_users, 0), 2)` in a future iter. **NOT a new gap to fix in iter709** unless the same probe recurs — flag as watch-list.
- Clarity and actionability are still excellent — engineer can paste this and ship.

### Q4 — Iceberg `sorted_by` clustering for customer-scoped queries

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00**

CRITICAL VERIFY findings:
- **`sorted_by` IS a valid Trino 467 Iceberg table property** — confirmed via trino.io/docs/467/connector/iceberg.html: "The sort order to be applied during writes to the content of each file written to the table."
- **`sorted_by = ARRAY['customer_id ASC']` direction modifier IS valid Trino 467** — confirmed via WebSearch. The Trino docs example shows bare column names `ARRAY['order_date']` / `ARRAY['c1','c2']` but the connector ALSO accepts explicit direction + null-ordering elements per Tabular cheat-sheet and multiple Trino issue references: `ARRAY['order_date DESC NULLS FIRST', 'order_id ASC NULLS LAST']` is a documented form. Responder's `'customer_id ASC'` parses correctly.
- **`ALTER TABLE ... SET PROPERTIES sorted_by`** — valid. Docs explicitly list sorted_by as one of the post-create-updatable properties (alongside format, format_version, partitioning, object_store_layout_enabled, data_location).
- **`EXECUTE optimize(file_size_threshold => '512MB')`** — valid. Docs example: `ALTER TABLE test_table EXECUTE optimize(file_size_threshold => '128MB')`. DataSize string with unit accepted.
- **sorted_by → within-file sort → min/max metadata file-skipping explanation** — accurate.
- **sorted_by-vs-partitioning distinction** — correct: lexicographic clustering inside files vs separate physical partition directories.
- **Multi-col sorted_by** — `ARRAY['customer_id ASC','event_ts ASC']` correct shape.
- **"EXECUTE optimize required to physically rewrite existing data"** — correct; setting sorted_by alone affects only future writes.
- All clauses land — engineer can paste this DDL into Trino 467 against the Iceberg connector and it will work.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 4 | 5 | 5 | 4.75 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall: 74/80 = 4.625 — PASS (>= 3.5)**

---

## Teacher feedback for iter709

1. **FIX-A CLOSED.** The READ-ME-FIRST block in r07 worked — it intercepted the leaderboard/NULL-ordering question and produced a clean, defang-stable, docs-quote-anchored answer with no circular framing. No further work needed on NULL ordering. Add to the HELD-LOCK list.
2. **Q3 minor gap — `NULLIF` for divide-by-zero in percentage formulas.** Not blocking this iter (overall 4.625 PASS), but the SaaS-natural shape "conversion rate per segment/cohort" will eventually hit a zero-denominator segment. Recommend a small additive clarifier in resources/23 (or wherever ROUND/format examples live) showing the canonical defensive form `100.0 * converted / NULLIF(total, 0)` with a one-line "why" (division-by-zero errors in Trino). Treat as watch-list — promote to FIX-A only if the same probe scores < 4.5 again.
3. **Q4 `sorted_by` direction modifier — NO gap.** Both bare-column `ARRAY['customer_id']` and direction-explicit `ARRAY['customer_id ASC']` / full `ARRAY['customer_id ASC NULLS FIRST']` forms are valid Trino 467. The responder used the explicit form and was correct. If resources currently only show one form, consider adding a brief "both forms valid" note to defang any future "I only see bare-column in docs" worry — but this is polish, not a fix.
4. **No new gaps that block PASS.** Continue probing held locks; iter709 should probe a fresh angle (e.g., conditional aggregation FILTER vs CASE WHEN, or a federation pushdown shape) rather than re-probe FIX-A.

NULL-ordering FIX-A: **CLOSED.**
