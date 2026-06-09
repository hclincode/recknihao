# iter785 Judge Feedback — DEFAULT NO-OP / durability-breadth sweep (teacher ZERO edits)

**Overall: 4.875 PASS** (threshold 3.5). Q1 Iceberg summary-key re-probe + 3 fresh adjacent topics (CTE / format-thousands / IN-subquery). All four docs-verified vs trino.io/docs/467 + iceberg.apache.org 2026-06-09.

## Per-question scores

### Q1 — Iceberg metadata: current row count + total size from running summary — **avg 5.00**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `summary['total-records']`, `summary['total-data-files']` from `"orders$snapshots"` ORDER BY committed_at DESC LIMIT 1.
- **KEY-NAME VERDICT: hyphenated keys CORRECT.** Verified vs iceberg.apache.org / spec: snapshot summary map keys are hyphenated — `total-records`, `total-data-files`, `added-records`, `total-files-size`, etc. Responder used the correct `total-records` / `total-data-files`. **The iter784 underscore-key slip ('added_rows') did NOT recur → confirmed one-off, NO iter786 FIX-A needed.**
- `$snapshots.summary` is `map(varchar,varchar)`; bracket access `summary['total-records']` is valid (errors only on a MISSING key — `total-records` always exists in a snapshot summary, so safe; `element_at` is the NULL-safe equivalent, optional note not penalized).
- `$files` alternative verified: `content` column (0=data, 1=position deletes, 2=equality deletes) and `file_size_in_bytes` both exist; `SUM(file_size_in_bytes) WHERE content=0` is a valid total-data-bytes query. Confirmed against Trino Iceberg connector $files schema.
- Minor (not penalized): summary values are varchar → CAST to bigint for capacity math.

### Q2 — CTE / WITH: name per-customer monthly spend, reference downstream — **avg 5.00**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `WITH customer_monthly_spend AS (... GROUP BY ...) SELECT ..., RANK() OVER (PARTITION BY month ORDER BY total_spend DESC) ... WHERE total_spend > 1000`. Valid Trino 467 syntax; RANK() window valid; WHERE filters the CTE's plain aggregate alias (not window-over-window), correct.
- **CRITICAL caveat VERIFIED ACCURATE:** "Trino CTEs are INLINED at planning, not materialized, so a CTE referenced twice runs twice." Confirmed — Trino has no `MATERIALIZED`/`NOT MATERIALIZED` keyword for WITH (GH issue trinodb/trino#28085 "Does trino support CTE Materialization?" still open); multiply-referenced CTEs are re-evaluated. Materialize-to-table/dbt-model advice is the right escape hatch and fits the on-prem dbt stack.

### Q3 — Format thousands: 1234567.5 → "1,234,567.50" — **avg 5.00**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `format('%,.2f', 1234567.5)` → '1,234,567.50'. VERIFIED vs trino.io/docs/467 conversion.html: format() uses java.util.Formatter; docs give the near-identical example `format('%,.2f', 1234567.89)` → '1,234,567.89'. `%,d` integer grouping and `%.1f%%` percent-with-literal-% extras correct.
- Minor (not penalized): grouping char is locale-dependent, defaults to comma (US locale).

### Q4 — IN-subquery filter: orders whose customer_id in a VIP set, no customer columns — **avg 5.00**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `SELECT * FROM orders WHERE customer_id IN (SELECT customer_id FROM customers WHERE is_vip = true)`. Valid Trino 467; optimizer plans as SemiJoin (visible in EXPLAIN); no join overhead, no row duplication; returns no customer columns. CORRECT.
- NULL note "IN (SELECT...) is NULL-safe for matching, unlike NOT IN" is accurate — NULLs in the subquery don't drop valid matches in the IN (matching) form; the dangerous case is NOT IN with NULLs. Aligns with the standing SemiJoin / NOT-IN-NULL pin.

## Verdicts
- **(a) Iceberg key-name slip: did NOT recur.** Correct hyphenated `total-records` / `total-data-files`. Confirmed one-off (iter784). **NO iter786 FIX-A.**
- **(b) iter786 designation: DEFAULT NO-OP / durability-breadth sweep** (expected — all four clean, no open defect, no new imprecision, teacher ZERO edits).

## Teacher guidance for iter786
- No edits required. PRESERVE the cards that drove these clean answers (churn risk): r17/r18 Iceberg `$snapshots.summary` map-access (hyphenated keys + element_at-vs-subscript) and `$files` content/file_size_in_bytes; r07 §1b CTE-inlined-not-materialized caveat; r23 format() printf canonical; r23 §10 IN-subquery→SemiJoin + NOT-IN-NULL note.
- Suggested fresh probes (bulletproof adjacent angles): EXISTS vs IN-subquery (correlated), CTE referenced twice → cost of re-evaluation / when to materialize to a temp table, `element_at(summary,'total-records')` NULL-safe form re-probe, format() with explicit Locale / negative-number grouping.
