# Judge Feedback — iter1012

**OVERALL: 4.75 (76.0/16) — PASS** (threshold ≥ 3.5; margin +1.25). OVERALL AVERAGE governs — no per-Q veto.

All four answers verified BOTH directions against trino.io/docs/467 (functions/array.html, functions/window.html, sql/select.html) + WebSearch on EXCEPT vs NOT-IN NULL semantics — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt) — all 4 fit. No federation/auth angle this sweep.

## Per-question scores

| Q | Topic | Acc | Comp | Clar | App | Avg |
|---|---|---|---|---|---|---|
| Q1 | window SUM OVER PARTITION, no row collapse | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q2 | ORDER BY CAST(varchar AS integer) numeric sort | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q3 | trial-not-converted anti-join (EXCEPT / LEFT JOIN IS NULL) | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q4 | contains(array, element) array membership | 4.75 | 4.5 | 4.75 | 4.5 | 4.625 |

Sub-score sum = 76.0 / 16 = **4.75**.

## Resolved verdicts (with citations)

1. **Q4 `contains(feature_flags, 'dark_mode')` — CORRECT.** trino.io/docs/467/functions/array.html: `contains(x, element) → boolean`, "Returns true if the array `x` contains the `element`." Argument order is (array, element) exactly as responder used. Recommending `contains()` over EXISTS+UNNEST for a simple membership test is the idiomatic call; UNNEST is correctly reserved for exploding-to-rows. Mild ding: didn't mention NULL-element edge, but not required for the question.

2. **Q3 EXCEPT NULL-safety + anti-join — CORRECT.** sql/select.html: EXCEPT exists, "If neither is specified, the behavior defaults to DISTINCT." Set operations are defined in terms of *distinctness* (NULL is NOT distinct from NULL → treated as equal), so EXCEPT does NOT inherit the NOT-IN three-valued-logic trap — verified via SQL-spec/Postgres-list discussion of EXCEPT-vs-NOT-IN. Responder's NOT-IN-breaks-on-NULL warning is accurate, and the `LEFT JOIN conversions c ON ... WHERE c.user_id IS NULL` anti-join is the standard equivalent. Both forms correct.

3. **Q1 `SUM(mrr) OVER (PARTITION BY plan_name)` — CORRECT.** functions/window.html: window functions "run after the HAVING clause but before the ORDER BY clause" (i.e. after WHERE) and return one output per input row (do NOT collapse like GROUP BY). `SUM(...) OVER ()` for grand total correct; "no join needed" is the right idiom for detail+total in one pass.

4. **Q2 `ORDER BY CAST(version_code AS integer)` — CORRECT.** CAST(varchar→integer) works for '9'/'10'/'11' and yields numeric ordering (9,10,11) rather than lexicographic ('10','11','9'); ORDER BY on an expression does not change the stored column type. `TRY_CAST` for non-numeric rows is the right guard.

## Defects / notes

- **Zero parse-error defects. Zero dialect tics.** No `::` cast anywhere (ban double-locked r23 §3.1C + r27 §4.4A — not exercised). No QUALIFY / false-semi-join / MAX-varchar / GREATEST-LEAST-NULL / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / broken-secondary-alternative.
- Q4 is the lowest only on completeness/applicability for not noting array-NULL edge cases — a nicety, not an error.

## Recommendation: DEFAULT NO-OP

Margin +1.25; all 4 answers correct and verified both directions; no findable resource gap, no resource defect, no 2-in-2 recurrence. NO resource edit; NO FIX-A; do NOT bump state.json (orchestrator commits).

**Re-probe next sweep:** (a) another window-aggregate-vs-GROUP-BY Q (watch frame-default trap on FIRST_VALUE/LAST_VALUE); (b) another varchar→numeric CAST/sort Q (watch TRY_CAST necessity messaging); (c) another anti-join Q — confirm EXCEPT NULL-safe + NOT-IN-3VL warning durable; (d) another array-membership Q — confirm contains(array, element) order + UNNEST reserved for explode. Federation r22 §13.x hard-locked, NOT probed (stays 4.49944/310).
