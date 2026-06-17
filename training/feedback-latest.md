# Judge Feedback — iter1000

**Phase**: extended | **Mode**: end-of-iteration (no per-Q mid-cycle, state.json passed=true, final_iterations_remaining=0)
**Verification**: all claims checked BOTH directions vs trino.io/docs/467 + RAW git-tag 467 source + official GitHub issue. PINNED Trino 467. NOT verified against resources/.
**Prod fit**: Trino 467 / Iceberg + Hive Metastore / on-prem MinIO / Spark ingest / dbt. All 4 Qs are pure SQL-semantics, environment-neutral. NO federation drag-in; no auth angle. prod_info.md serving-env section still unfilled (noted, immaterial here).

---

## OVERALL: 4.797 — STRONG PASS

(Q1 4.8125 / Q2 4.8125 / Q3 4.8125 / Q4 4.75 = 19.1875 / 4 = **4.7969**; margin +1.297 over 3.5 threshold. OVERALL AVERAGE governs, no per-Q veto.)

---

## Per-question scores

### Q1 — split_part for email-domain extraction (Postgres → Trino?) — 4.8125 CLEAN
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75
- **VERIFIED (functions/string.html):** `split_part(string, delimiter, index) → varchar` EXISTS in Trino 467; "Field indexes start with 1" → 1-based. `split_part('alice@example.com','@',2)` = `'example.com'`, `split_part(...,'@',1)` = local-part. All correct.
- split_part is NOT a fabricated function (real & verified). "Cleaner than substr(strpos(...))" framing apt.
- Direct lift from Postgres works identically — exactly what the engineer needs.

### Q2 — TEXT order totals to DECIMAL, NULL on bad rows — 4.8125 CLEAN
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75
- **VERIFIED:** `TRY_CAST(expr AS type)` returns NULL on cast failure (vs CAST throws + aborts) — valid Trino 467, query completes. Correct lead.
- ★ **WHITESPACE-TRIM VERDICT (verified BOTH ways, settled at raw source + official issue #23359):** Trino 467 does **NOT** trim leading/trailing whitespace when casting VARCHAR to **DECIMAL** (an EXACT numeric type) — `CAST('  49.99 ' AS DECIMAL)` **FAILS**, so `TRY_CAST('  49.99 ' AS DECIMAL(10,2))` → **NULL**. The responder's "whitespace not trimmed → NULL" claim is **FULLY CORRECT, not an over-statement**. (Trap: real/double DO tolerate surrounding whitespace per #23359, but DECIMAL does not — exact-vs-float inconsistency. The WebFetch "BigDecimal accepts whitespace" reading was WRONG; Java BigDecimal(String) throws on surrounding spaces.)
- ★ **TRIM recommendation CORRECT:** `TRY_CAST(TRIM(total) AS DECIMAL(10,2))` → 49.99 for `'  49.99 '`, still NULL for `'N/A'`. This is the right, safe, complete deliverable. Nails the dirty-data SaaS use case.
- TRY_CAST not fabricated (real & verified).

### Q3 — workspaces where ALL active users logged in within 30 days — 4.8125 CLEAN
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75
- **VERIFIED (functions/aggregate.html):** `bool_and(boolean)` returns TRUE iff every input value is TRUE, FALSE if any is FALSE; ignores NULL and returns NULL on empty/all-NULL group (general aggregate rule) → `COALESCE(...,false)` guard correct. `bool_or` for "at least one" correct.
- ★ **The KEY distinction is correct and load-bearing:** `WHERE` removes non-matching rows (so a count is misleading — the user's exact symptom), whereas `HAVING bool_and(predicate)` tests that ALL remaining rows satisfy the condition. `WHERE status='active'` correctly SCOPES to active users (the population), then bool_and asks "is every one of them current." Textbook "every row in a group satisfies a condition" pattern.
- ★ **INTERVAL form correct (NOT date-minus-integer):** `current_date - INTERVAL '30' DAY` is valid Trino (date − interval, singular DAY qualifier) — NOT the Postgres `current_date - 30` bare-integer-ism, NOT a quarter/week qualifier trap. Clean.
- bool_and not fabricated (real & verified).

### Q4 — round invoice UP; CEIL vs CEILING same? — 4.75 CLEAN
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.5
- **VERIFIED (functions/math.html):** `ceil(x)` is documented as an ALIAS for `ceiling(x)` — identical functions, both "round x up to the nearest integer" (toward +infinity, true ceiling). Responder's "identical synonyms, pick either, documented as equivalent at math.html" is CORRECT (minor direction nuance: docs phrase it as ceil-alias-of-ceiling, not ceiling-alias-of-ceil — immaterial, they are the same function).
- CEIL(14.10)=15, CEIL(14.00)=14, CEIL(14.99)=15 — all CORRECT, no rounding surprise for positive amounts (the invoice case). Resolves the teammate disagreement cleanly.
- ROUND(amount,0) for round-half noted as the contrast (correct — round-half-up vs always-up).
- Slight completeness ding only: did not explicitly note ceil of a DECIMAL(10,2) returns a decimal-typed value (15.00 not int 15) — purely cosmetic, the engineer's display-as-whole-dollars goal is met either way.

---

## Tics scan — ALL CLEAN
No QUALIFY / no false-mechanism semi-join mislabel / no MAX(varchar) / no percent_rank inversion / NO fabricated functions (split_part, try_cast, bool_and, bool_or, ceil, ceiling, trim, round ALL real & verified) / no regex-backslash prose slip / no GREATEST-LEAST-NULL / no date-minus-integer (Q3 used INTERVAL correctly) / no temporal-vs-varchar-literal / no broken-secondary or false-justification / no mid-churn / no column-scope error / no ILIKE-conflation / no INTERVAL quarter/week trap.

Notably: the iter998/999 regex-backslash PROSE slip (2-in-2) did NOT appear here — no regex question this sweep, so no read on whether it recurs; remains an open re-probe item.

---

## Scope notes (explicit)
- **Q1**: split_part EXISTS, 1-based index, `split_part(email,'@',2)`='example.com'. CLEAN.
- **Q2**: TRY_CAST returns NULL-on-failure (CAST throws). ★ VERIFIED whitespace verdict: Trino 467 does NOT trim whitespace casting VARCHAR→DECIMAL (exact type) — `'  49.99 '`→NULL is CORRECT (not an over-statement); real/double would tolerate it but DECIMAL does not (#23359). TRIM recommendation `TRY_CAST(TRIM(total) AS DECIMAL(10,2))` CORRECT & complete.
- **Q3**: bool_and = all-rows-satisfy (TRUE iff every TRUE, COALESCE-guard all-NULL); WHERE status='active' correctly SCOPES the population; HAVING tests all; INTERVAL '30' DAY (NOT bare integer). CLEAN.
- **Q4**: CEIL = CEILING aliases (same function), true ceiling toward +inf, no rounding surprise for positive invoice amounts; ROUND(,0) is the round-half contrast. CLEAN.

---

## RECOMMENDATION = DEFAULT NO-OP on resources
Margin +1.297; all 4 deliverables correct & verified both directions against trino.io/docs/467 + raw 467 source + official issue #23359. Zero tics, zero fabricated functions, no findable resource gap, no findability gap, no 2-in-2 recurrence. This is a strong, clean breadth iteration.

Re-probe next sweep (no resource action now):
- (a) another string-split/extraction Q — confirm split_part 1-based lead holds.
- (b) another dirty-TEXT→numeric cast Q — confirm TRY_CAST + TRIM lead; watch whether responder keeps the (correct) "DECIMAL doesn't trim" framing vs over-generalizing to real/double.
- (c) another "all/every row in group satisfies" Q — confirm bool_and + WHERE-scopes-vs-HAVING-tests distinction holds; bool_or for "at least one".
- (d) another rounding Q (FLOOR/ROUND/ceil/truncate) — confirm alias + toward-±inf + round-half distinctions.
- (e) STILL OPEN from iter998/999: regex-backslash PROSE direction (2-in-2 prior) — no regex Q this iter; if a regex Q appears and prose double-backslash recurs (would be 3-in-3), orchestrator grep resources for findability-vs-recall-ceiling disposition.

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).
NO resource edits. MUST NOT bump training/state.json (already 1000; passed=true preserved; final_iterations_remaining 0).
