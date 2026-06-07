# iter595 Judge Feedback

**Date**: 2026-06-07
**Phase**: extended
**Overall**: 5.00 / 5.00 / 5.00 / 5.00 — STRONG PASS — iter594 + iter595 inoculations BOTH DURABLE on 3rd framings

---

## Per-Question Scores

### Q1 — split_part 3rd-framing (after the LAST dot, variable # of dots)
**Question**: "files like 'invoice_2026_Q2.pdf' / 'report.final.v3.xlsx'; want the extension = part after the LAST dot; clean way when there are multiple dots?"

**Answer summary**: `element_at(split(filename, '.'), -1) AS extension` → 'pdf' / 'xlsx' / 'gz' for 'data.backup.tar.gz'. Explicit guardrail: "Don't use split_part() for the last piece — split_part() doesn't accept negative indices and always requires you to know the exact position."

**Verification (Trino 467 docs)**:
- `split(string, delimiter)` returns an array (trino.io/docs/current/functions/string.html → references conversion.html for format).
- `element_at(array, index)` — quoting docs: "Returns an element of an array at a given index. If the index is negative, it accesses elements from the last to the first." (trino.io/docs/current/functions/array.html). Confirms negative index `-1` returns last array element.
- Concretely: `element_at(split('report.final.v3.xlsx', '.'), -1)` = `'xlsx'`. CORRECT.
- `split_part` cannot do "after the last" — positional integer index, no negatives. Responder's guardrail is accurate.

**Scores**: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 → **Q1 avg = 5.00**

DURABILITY: iter594 split_part after-LAST-delimiter anchor + `element_at(split,-1)` idiom HELD on 3rd framing (file-extension variant). CONFIRMED DURABLE.

---

### Q2 — CTAS 3rd-framing (save JOIN result as new permanent table; complete statement + clean 3-part name)
**Question**: "join orders to customers (enrich), save as new permanent table 'enriched_orders' in analytics schema; full SQL to copy and run?"

**Answer summary**: COMPLETE
```sql
CREATE TABLE iceberg.analytics.enriched_orders AS
SELECT o.order_id, ..., c.name, c.email
FROM iceberg.app.orders o
JOIN iceberg.app.customers c ON c.customer_id = o.customer_id;
```
Noted `CREATE OR REPLACE TABLE` for refresh; scheduled-job note included.

**Verification (Trino 467 docs)**:
- CTAS syntax (trino.io/docs/current/sql/create-table-as.html):
  > "CREATE TABLE [ IF NOT EXISTS ] table_name [ ( column_alias, ... ) ] [ COMMENT table_comment ] [ WITH ( property_name = expression [, ...] ) ] AS query [ WITH [ NO ] DATA ]"
- CREATE OR REPLACE TABLE supported:
  > "The optional OR REPLACE clause causes an existing table with the specified name to be replaced with the new table definition."
- 3-part name `iceberg.analytics.enriched_orders` is the standard `catalog.schema.table` form. NO 4-segment placeholder regression. iter595 3-part-vs-4-segment inoculation HELD.

**Scores**: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 → **Q2 avg = 5.00**

DURABILITY: iter594 CTAS complete-canonical + iter595 3-part-name inoculation HELD on 3rd framing (enrich-JOIN variant). CONFIRMED DURABLE.

**MINOR NOTE (citation-routing oddity, NOT an answer defect)**: Responder cited `resources/25-trino-materialized-views-iceberg.md` and `resources/21-hive-metastore-iceberg.md`. The CTAS canonical actually lives in r23 (§3.1A) + r09 (guardrail). The cited sources are tangential. The ANSWER is correct, so this is purely a sourcing-attribution quirk and does not warrant a code change for iter596. Mark as clean; flag for awareness only.

---

### Q3 — zero-pad number to 6-char string (FRESH)
**Question**: "invoice numbers 42/1337 → '000042'/'001337' (6-char leading zeros) for a legacy export."

**Answer summary**: `format('%06d', invoice_number)` → '000042' / '001337'. Printf-style noted.

**Verification (Trino 467 docs)**:
- `format(format, args...) → varchar` (conversion.html, referenced from string.html). Uses Java `Formatter` syntax which supports printf-style `%0Nd`.
- Concrete docs example: `SELECT format('%03d', 8); -- '008'`. By extension `format('%06d', 42)` = `'000042'` and `format('%06d', 1337)` = `'001337'`. CORRECT.
- Note: `lpad(CAST(n AS VARCHAR), 6, '0')` is an equivalent alternative — responder chose format, no penalty.

**Scores**: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 → **Q3 avg = 5.00**

---

### Q4 — CASE code-to-label (FRESH)
**Question**: "status column has integer codes 1/2/3; map to labels 'Pending'/'Shipped'/'Cancelled' in a report."

**Answer summary**:
```sql
CASE status_code
  WHEN 1 THEN 'Pending'
  WHEN 2 THEN 'Shipped'
  WHEN 3 THEN 'Cancelled'
  ELSE 'Unknown'
END AS status_label
```

**Verification (Trino 467 docs)**:
- Simple-CASE form `CASE expr WHEN val THEN ... END` is standard SQL and valid in Trino 467 (CASE Expressions in conditional-expressions documentation).
- ELSE-for-unknown is a good practice (defends against new codes added later) — responder's `ELSE 'Unknown'` is exactly right.

**Scores**: Accuracy 5, Completeness 5, Clarity 5, Actionability 5 → **Q4 avg = 5.00**

---

## Overall

| Q | Topic | Avg |
|---|---|---|
| Q1 | split (after LAST delimiter, file extension) | 5.00 |
| Q2 | CTAS 3-part name (JOIN enrich) | 5.00 |
| Q3 | format(`%06d`, n) zero-pad | 5.00 |
| Q4 | simple CASE code→label | 5.00 |

**Overall average = 5.00 / 5** → **STRONG PASS** (threshold 3.5).

---

## Durability Summary

- **split_part / after-LAST-delimiter idiom** (iter594 lock): DURABLE on 3rd framing (file-extension, multi-dot). `element_at(split(...), -1)` chosen correctly; explicit anti-pattern callout on `split_part` for "last piece."
- **CTAS complete-canonical** (iter594 lock) + **3-part name inoculation** (iter595 lock): DURABLE on 3rd framing (JOIN enrich variant). Complete `CREATE TABLE iceberg.analytics.enriched_orders AS SELECT ... JOIN ...` produced; clean `catalog.schema.table` form; NO 4-segment placeholder regression.

---

## Next-teacher actions for iter596 — NO-OP recommended

iter595 produced a clean 5.00 / 5.00 / 5.00 / 5.00 sweep:
- Q1 split-after-LAST durability confirmed (3rd framing — file-extension variant)
- Q2 CTAS complete + 3-part name durability confirmed (3rd framing — JOIN enrich variant)
- Q3 format(%06d) and Q4 simple CASE both fresh-and-correct on first probe

**RECOMMENDATION FOR iter596**: **NO-OP** on resources. iter594 + iter595 inoculations have held across 3 distinct framings each. Push iter596 toward FRESH BREADTH probes (untested fresh-framing questions) rather than touching r23. Specifically:
- Do not re-edit r23 CTAS canonical or split-family canonical. Both held.
- The Q2 r25/r21 citation oddity is purely an attribution quirk, NOT worth touching. The answer was complete and correct. Adding a citation anchor would risk reconcile drift for ~0 benefit.
- Federation row (4.49944) remains untouched. Do not probe federation unless a bulletproofed angle is available.

**Iter596 directive**: NO-OP iter595 resources; orchestrate fresh-breadth probes only.
