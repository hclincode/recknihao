# Judge Feedback — iter1015

**Phase:** extended (passed=true). DEFAULT NO-OP sweep. OVERALL AVERAGE governs — no per-Q veto.
**Verification:** BOTH directions vs trino.io/docs/467 (sql/select.html, functions/string.html, functions/conditional.html, functions/math.html) + WebSearch (DIVISION_BY_ZERO, NULLIF, decimal-literal division). NOT resources/.
**Prod fit:** On-prem Trino 467 + Iceberg/Hive Metastore. All 4 are plain analytics SQL — no federation/auth/permission angle. All 4 fit the stack.

## Per-question scores

### Q1 — at least 10 distinct events: WHERE or HAVING? — **4.8125**
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- VERDICT CORRECT. HAVING (filters groups after GROUP BY + aggregates computed) vs WHERE (filters rows pre-aggregation) — verified select.html ("HAVING filters groups after groups and aggregates are computed"). `COUNT(DISTINCT event_type) >= 10` is right for "at least 10" (>= includes the boundary). Clean explanation of the pre/post-aggregation distinction — the exact conceptual gotcha. No defect.

### Q2 — strip stray spaces so plan_name='pro' matches — **4.75**
- Acc 5 / Comp 4.5 / Clar 4.75 / App 4.75
- VERDICT CORRECT. Single-arg `TRIM(plan_name)` removes leading+trailing whitespace from both ends — verified string.html ("Removes leading and trailing whitespace from string"). Correctly notes LEADING/TRAILING modes exist for one-sided trims and that no two-arg LTRIM/RTRIM(string,chars) is needed here (consistent with the trim char-set pin). Sole nit (not a defect): could note `TRIM(plan_name) = 'pro'` on a column forces per-row eval / breaks pushdown, immaterial for a small dimension column. No defect.

### Q3 (KEY) — divide cents by 100, guard divide-by-zero — **4.8125**
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- VERDICT CORRECT, and notably well-handled given the garbled premise. Confirmed:
  - (a) Trino 467 THROWS DIVISION_BY_ZERO for INTEGER and DECIMAL division by zero (WebSearch: drdroid stack-diagnosis; trinodb #19491 zero-safe-division feature request — i.e. NOT implemented, it errors).
  - (b) `total_cents / 100.0` is decimal division by a NONZERO literal → result is DECIMAL, 0/100.0 = 0.0, can NEVER divide-by-zero. Responder correctly identified the user's literal-/100 premise can't actually trigger the error.
  - (c) `NULLIF(denominator, 0)` makes a zero denominator NULL → result NULL instead of throwing — verified conditional.html ("NULLIF returns null if value1 equals value2"). Correctly scoped NULLIF to the VARIABLE-denominator case, not the literal one.
  - Helpful disambiguation of a confused question rather than blindly bolting NULLIF onto a literal. (Optional polish: could mention `TRY(...)` as an alternative, but NULLIF is the idiomatic guard — not a gap.)

### Q4 — sort priority ASC, tie-break created_at DESC: mixed directions? — **4.8125**
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- VERDICT CORRECT. `ORDER BY priority ASC, created_at DESC` — each ORDER BY expression carries its own [ASC|DESC] [NULLS FIRST|LAST] independently — verified select.html synopsis `ORDER BY expression [ASC|DESC] [NULLS {FIRST|LAST}] [, ...]`. Standard SQL, works in Trino 467. priority ASC puts 1 (highest) first; created_at DESC puts newest first within a priority. No defect.

## Overall

| Q | Acc | Comp | Clar | App | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q2 | 5 | 4.5 | 4.75 | 4.75 | 4.75 |
| Q3 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q4 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |

**Sum of 16 sub-scores = 76.5 / 16 = 4.78125**
**OVERALL = 4.78125 — PASS** (threshold 3.5; margin +1.28125)

## Defects / TICs
- NONE. Zero parse-error defects. `::` shorthand ABSENT all 4. No broken-secondary alternative this iter. No QUALIFY / false-semi-join / MAX-varchar / GREATEST-LEAST-NULL / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / generate_subscripts slips.
- Two watch-items resolved in responder's favor: count-threshold `>=` boundary (Q1) handled correctly; case/whitespace-match TRIM (Q2) correct.

## Recommendation: DEFAULT NO-OP
Margin +1.28; all 4 correct and verified both directions; KEY Q3 divide-by-zero (incl. decimal-literal-safe + NULLIF-for-variable-denominator) resolved in responder's favor. No findable gap, no resource defect, no 2-in-2 recurrence. NO resource edit; NO FIX-A.

Re-probe next sweep (monitor only, don't churn):
- (a) another count-threshold Q — watch `>` vs `>=` boundary phrasing.
- (b) another whitespace/case normalization Q — TRIM both-side + LOWER()=LOWER() for case.
- (c) another arithmetic-safety Q — INTEGER/DECIMAL div-by-zero THROWS, decimal-literal-safe, NULLIF for variable denom, TRY alt.
- (d) another multi-key ORDER BY Q — per-column ASC/DESC + NULLS FIRST/LAST placement.

Federation r22 §13.x hard-locked NOT probed (stays 4.49944 / 310). MUST NOT bump state.json (already 1015; orchestrator commits).
