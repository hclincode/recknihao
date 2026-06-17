# Judge Feedback — iter1009

**OVERALL: 4.71875 (75.5/16) — PASS** (margin +1.21875; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions against trino.io/docs/467 (functions/datetime.html, aggregate.html, comparison.html, conditional.html) + WebSearch — NOT resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt) — all 4 fit; no federation/auth angle.

---

## Per-question scores

### Q1 — bool_or per-campaign "did ANY user convert" — 4.75 CLEAN
`bool_or(is_converted) AS any_converted ... GROUP BY campaign_id` VERIFIED CORRECT.
- aggregate.html: `bool_or(boolean) → boolean` "Returns TRUE if any input value is TRUE, otherwise FALSE."
- Edge case VERIFIED: bool_or is NOT in the count/count_if/max_by/min_by/approx_distinct exception list, so it follows the general rule "ignore null values and return null for no input rows or when all values are null" → all-NULL group / empty group → **NULL not FALSE**. Responder's `COALESCE(bool_or(is_converted), false)` to force FALSE is exactly right.
- Correctly steers away from verbose `SUM(CASE WHEN ... THEN 1 END) > 0`.
- **Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75**

### Q2 — COALESCE phone fallback chain — 4.625 CLEAN
`COALESCE(phone, mobile_phone, work_phone) AS contact_number` VERIFIED CORRECT.
- conditional.html: "Returns the first non-null value in the argument list. Like a CASE expression, arguments are only evaluated if necessary." → first non-NULL, left-to-right.
- Good caveat: COALESCE is null-fallback only, not a general conditional — use CASE/IF for value comparisons. Accurate, not a broken-secondary.
- Minor: simple Q, answer appropriately concise.
- **Acc 5 / Comp 4.5 / Clar 4.75 / App 4.5**

### Q3 (KEY) — `created_at >= current_date - 7` "lucky?" — 4.75 CLEAN
Responder verdict VERIFIED CORRECT: `current_date - 7` (DATE minus a bare integer) is NOT valid Trino.
- datetime.html: the `+`/`-` operators on date/timestamp work **exclusively with INTERVAL types** (doc example: `date '2012-08-08' - interval '2' day` → `2012-08-06`). A plain integer operand is not accepted — this is a PostgreSQL-ism (Postgres allows date−int; Trino does not).
- Both responder-offered correct forms VERIFIED:
  - `current_date - INTERVAL '7' DAY` (canonical, clearest)
  - `date_add('day', -7, current_date)` (signature `date_add(unit, value, timestamp)`; negative value subtracts)
- Bonus correct: the INTERVAL form is recognized by the optimizer for partition pruning (consistent with 467 UnwrapCast/temporal-predicate behavior).
- The engineer "am I getting lucky?" framing answered decisively and correctly: not lucky — it does NOT work; use INTERVAL or date_add.
- **Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75**

### Q4 — `account_tier = NULL` returns zero rows, why — 4.625 CLEAN
VERIFIED CORRECT.
- comparison.html: "any comparison involving a NULL will produce NULL"; WHERE keeps only rows where the predicate is TRUE, so a NULL/UNKNOWN predicate row is excluded.
- Correct fix: `account_tier IS NULL` / `IS NOT NULL` (work for all data types).
- Minor imprecision (sole nit): responder says UNKNOWN is "treated like FALSE." Strictly, UNKNOWN is its own truth value; it is *not-TRUE* so the row is filtered — functionally identical in a WHERE clause, a common and harmless simplification. Light Acc deduct only; no defect. (Could optionally have mentioned IS [NOT] DISTINCT FROM for null-safe equality, but not required by the Q.)
- **Acc 4.75 / Comp 4.5 / Clar 4.75 / App 4.5**

---

## Sub-score table

| Q | Acc | Comp | Clar | App | Sum |
|---|---|---|---|---|---|
| Q1 bool_or | 5.0 | 4.75 | 4.75 | 4.75 | 19.00 |
| Q2 COALESCE | 5.0 | 4.5 | 4.75 | 4.5 | 18.75 |
| Q3 date−7 | 5.0 | 4.75 | 4.75 | 4.75 | 19.25 |
| Q4 = NULL | 4.75 | 4.5 | 4.75 | 4.5 | 18.50 |
| **Total** | | | | | **75.50** |

**Overall = 75.50 / 16 = 4.71875 → PASS** (≥ 3.5).

---

## Defects / notes
- ZERO parse-error defects. All 4 queries are valid Trino 467 as written.
- `::` PostgreSQL cast ABSENT all 4 (ban double-locked r23 §3.1C + r27 §4.4A; iter1003 one-off did not recur).
- OFFSET/LIMIT clause-order TIC (iter1006 Q4 + iter1007 Q1, FIXED iter1008) NOT exercised this iter — no pagination Q. Fix remains held; monitor only.
- TICS all clean: no QUALIFY / false-semi-join / MAX-varchar / GREATEST-LEAST-NULL-inversion / fabricated-fn (bool_or/coalesce/date_add all real & verified) / regex-backslash / INTERVAL-quarter-week / broken-secondary (Q2 COALESCE caveat + Q4 IS NULL fix both accurate).
- Sole nit = Q4 "UNKNOWN treated like FALSE" simplification — harmless, functionally correct in WHERE; light Acc deduct only, NOT a defect.
- Q3 (KEY date-minus-integer) is a textbook imported-PostgreSQL-prior trap and the responder handled it PERFECTLY — verdict correct + both valid rewrites + pruning bonus.

## Recommendation
**DEFAULT NO-OP.** Margin +1.21875; all 4 correct & verified both directions; zero parse-error defects; zero tics. No source-verified findable gap, no resource defect, no 2-in-2 recurrence. NO resource edit; NO FIX-A.

Re-probe next sweep (no churn): (a) another date-arithmetic Q — confirm date−bare-integer rejection + INTERVAL/date_add canonical recurs clean; (b) another bool_or/boolean-rollup Q — confirm all-NULL→NULL + COALESCE-to-false; (c) another NULL-comparison Q — `=NULL`→0 rows + IS NULL, optionally watch IS [NOT] DISTINCT FROM; (d) COALESCE fallback-chain. Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1009; orchestrator commits).
