# Iter1167 — Judge Feedback

## Verdict: STRONG PASS NO-OP — Average 5.0 / 5.0

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 JSON safe-extract (json_extract_scalar + JSON_VALUE) | SQL query best practices for OLAP | 5.0000 | pin-perfect, both forms correct |
| Q2 relational division via COUNT(DISTINCT date_trunc) | Analytical query patterns on Iceberg+Trino | 5.0000 | canonical, COUNT(*) defang sound |
| Q3 Iceberg INTEGER -> BIGINT widening | Iceberg table maintenance | 5.0000 | exact ALTER syntax + spec-correct promotion matrix |
| Q4 current_timestamp / now() / SYSDATE | Oracle PL/SQL -> dbt+Trino migration | 5.0000 | all aliasing/paren/pin-at-start facts verified |

Iter average = (5.0 + 5.0 + 5.0 + 5.0) / 4 = **5.0 STRONG PASS NO-OP**.

No open watches triggered, no FIX-A spec issued, no resource churn recommended.

---

## Per-question detail

### Q1 — JSON safe-extract pattern (5.0)

**Responder's answer:** `json_extract_scalar(metadata, '$.referral_source')` returns NULL for missing keys AND malformed JSON (no error). For stricter control: `JSON_VALUE(metadata, '$.referral_source' RETURNING varchar NULL ON EMPTY NULL ON ERROR)`. Recommends json_extract_scalar for simplicity, JSON_VALUE for explicit edge-case control.

**Verification:**
- `json_extract_scalar` documented at [trino.io/docs/467/functions/json.html](https://trino.io/docs/467/functions/json.html) — returns NULL for paths that don't resolve to a value (standard well-known behavior, also confirmed in search results). Does NOT error on missing keys.
- `JSON_VALUE` SQL/JSON syntax in 467 confirmed verbatim per same doc:
  ```
  JSON_VALUE(
      json_input [ FORMAT JSON [ ENCODING { UTF8 | UTF16 | UTF32 } ] ],
      json_path
      [ PASSING json_argument [...] ]
      [ RETURNING type ]
      [ { ERROR | NULL | DEFAULT expression } ON EMPTY ]
      [ { ERROR | NULL | DEFAULT expression } ON ERROR ]
  )
  ```
  Responder's `RETURNING varchar NULL ON EMPTY NULL ON ERROR` matches the grammar exactly. Defaults are `NULL ON EMPTY` and `NULL ON ERROR` when omitted, but writing them explicitly (as the responder does) is legal and self-documenting.
- Two-tier recommendation (simple vs explicit) is correct framing for the engineer's actual question: how to extract safely when keys are sometimes absent.

**Score breakdown:** Accuracy 5 / Clarity 5 / Applicability 5 / Completeness 5.

### Q2 — "Entity present in every quarter" via relational division (5.0)

**Responder's answer:**
```sql
SELECT customer_id
FROM orders
WHERE order_date >= DATE '2025-01-01' AND order_date < DATE '2026-01-01'
GROUP BY customer_id
HAVING COUNT(DISTINCT date_trunc('quarter', order_date)) = 4
```
Plus correct defang: `HAVING COUNT(*) = 4` would count ROWS not QUARTERS (a customer with 4 orders all in Q1 would falsely pass).

**Verification:**
- `date_trunc('quarter', timestamp)` confirmed valid Trino 467 unit per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) — full unit list includes `year, quarter, month, week, day, hour, minute, second, millisecond`.
- `COUNT(DISTINCT expr) = N` is the canonical relational-division pattern for "appears in all N buckets" (after pre-filtering rows to the universe of N buckets via the WHERE date range).
- COUNT(*) defang reasoning is sound: `COUNT(*) = 4` is a row count not a bucket count; a customer with 4 orders all in Q1 would falsely pass; the responder's correction is essential and correctly explained.
- Date-range half-open interval `>= '2025-01-01' AND < '2026-01-01'` is the right form to avoid timestamp boundary inclusion ambiguity.

**Score breakdown:** Accuracy 5 / Clarity 5 / Applicability 5 / Completeness 5.

### Q3 — Iceberg INTEGER -> BIGINT widening (5.0)

**Responder's answer:** YES native in Trino 467, metadata-only, no rewrite. Syntax `ALTER TABLE iceberg.analytics.customers ALTER COLUMN customer_id SET DATA TYPE BIGINT`. Old Parquet INT32 files keep physical type; reader promotes on read. Promotion matrix: INTEGER->BIGINT, REAL->DOUBLE, DECIMAL(p,s)->DECIMAL(p',s) where p'>p, same scale. Narrowing (BIGINT->INTEGER) rejected at commit; needs add-new-col + backfill CAST + drop + rename.

**Verification:**
- ALTER TABLE syntax — confirmed verbatim at [trino.io/docs/467/sql/alter-table.html](https://trino.io/docs/467/sql/alter-table.html):
  > `ALTER TABLE [ IF EXISTS ] name ALTER COLUMN column_name SET DATA TYPE new_type`
- Iceberg connector support for the type change — confirmed at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) under "Iceberg supports updating column types only for widening operations":
  > `INTEGER` to `BIGINT`, `REAL` to `DOUBLE`, `DECIMAL(p,s)` to `DECIMAL(p2,s)` when `p2 > p`
- Iceberg spec promotion matrix — confirmed at [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) (and [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/)): exactly the three allowed promotions the responder lists. Date->timestamp is v3+ (out of scope for a SaaS-typical v2 production table). Decimal scale is fixed; precision can only widen.
- Metadata-only / no file rewrite — confirmed: when Iceberg reads an old data file in the original type (INT), it promotes the value to the newer type (LONG) at read time; no rewrite needed.
- Narrowing rejected — confirmed: only widening is allowed, so BIGINT->INTEGER would be rejected at commit time.
- The add/backfill/drop/rename workaround for narrowing is exactly the right shape for the rare case the engineer might need it (e.g., over-provisioned bigint they want to narrow).

**Score breakdown:** Accuracy 5 / Clarity 5 / Applicability 5 / Completeness 5.

### Q4 — current_timestamp / now() / SYSDATE (5.0)

**Responder's answer:** current_timestamp and now() are IDENTICAL/interchangeable aliases; both return TIMESTAMP(3) WITH TIME ZONE; both pinned to query START — every reference in one query yields the same value; a 5-min query does NOT tick forward row-by-row. SYSDATE -> current_timestamp (no parens) or now() (empty parens OK); current_timestamp() WITH parens is a parse error. Both respect session time zone (verify sql.forced-session-time-zone).

**Verification (per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html)):**
- `now()` is defined as: "This is an alias for `current_timestamp`." Confirmed verbatim.
- Both return `timestamp(3) with time zone` (default precision; `current_timestamp(p)` precision override exists but is a footnote, not load-bearing for SYSDATE migration).
- Both evaluated "as of the start of the query" and remain constant throughout query execution. The 5-min dbt model concern (does it tick forward?) is correctly answered: NO. Every reference returns the same instant.
- `current_timestamp` listed among SQL-standard functions that "do not use parenthesis" (alongside `current_date`, `current_time`, `localtime`, `localtimestamp`). Writing `current_timestamp()` with empty parens is a parse error — responder's defang is correct.
- `now()` is a true function and DOES require parens — correct.
- Oracle SYSDATE -> Trino current_timestamp / now() is the right mapping. (One pedantic aside: SYSDATE in Oracle returns a `DATE` without TZ in server local time, whereas Trino current_timestamp returns `timestamp(3) with time zone`; the responder's mention of session time zone covers this implicitly. Not a defect — the practical drop-in replacement IS current_timestamp/now() for any "current moment" semantic, and most migration playbooks accept the TZ-aware return as the correct evolution.)

**Score breakdown:** Accuracy 5 / Clarity 5 / Applicability 5 / Completeness 5.

---

## Source classification

- All four — pin-perfect canonical reaches; no resource gap; no defect; no FIX-A.
- No open watches opened, no open watches closed (no recent open watches active).
- This iter is the cleanest sweep in the recent cadence (iter1163-1167): four 5.0s with zero shaves. Falls in the "STRONG PASS NO-OP" band consistent with the breadth-sweep phase.

## Rubric updates

- "SQL query best practices for OLAP" 4.5841/236 -> 4.5859/237 (+0.0018).
- "Analytical query patterns on Iceberg+Trino" 4.5253/118 -> 4.5293/119 (+0.0040).
- "Iceberg table maintenance" 4.4533/192 -> 4.4561/193 (+0.0028).
- "Oracle PL/SQL -> dbt+Trino" 4.4636/135 -> 4.4675/136 (+0.0039).

All four topics remain comfortably above pass threshold. No row near threshold or trending down.

## Recommendation

NO-OP this iteration. Continue breadth-first probing of less-recently-touched topics in iter1168. No teacher action needed. Iter1167 confirms r13 (JSON funcs), r07/r10 (analytical patterns), r17 (Iceberg connector schema evolution), and r27 (Oracle migration date-time) are all production-grade canonical reaches.
