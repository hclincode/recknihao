# iter995 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.75 STRONG PASS** (Q1 4.8125 / Q2 4.4375 / Q3 4.875 / Q4 4.875 = 19.0/4 = 4.75; margin +1.25; OVERALL AVERAGE governs, no per-Q veto).

All 4 questions verified BOTH directions against trino.io/docs/467 (sql/select.html, functions/conditional.html, functions/datetime.html, language/types.html, functions/comparison.html) — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in.

---

## Q1 — UNION vs UNION ALL (active + trial subscriptions, got slower) — 4.8125 CLEAN

**VERIFIED:** Bare UNION applies an implicit global DISTINCT. select.html: "If neither [DISTINCT nor ALL] is specified, the behavior defaults to DISTINCT" / "UNION ALL ... all rows are included even if the rows are identical." Responder's mechanism description (UNION = UNION ALL + global dedup via sort/hash-aggregate; UNION ALL just stacks rows) is the LEGIT UNION/UNION ALL distinction — CONFIRMED CORRECT.

★ WATCH CLEARED: This is NOT DISTINCT-vs-GROUP-BY perf-folklore. The responder correctly framed it as the genuine "extra dedup work" cost of bare UNION, not a fabricated "GROUP BY faster than DISTINCT" mechanism. The "disjoint inputs → bare UNION is a silent perf killer" point is accurate and practically valuable (active vs trial subscriptions rarely overlap, so dedup is pure waste). Recommendation to prefer UNION ALL unless dedup is genuinely needed AND inputs can overlap is exactly right. `SELECT ... UNION ALL SELECT ...` lead is the runnable fix.

Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — CASE returns NULL when nothing matches; guarantee fallback / ELSE on every CASE — 4.4375 CLEAN (minor completeness)

**VERIFIED:** conditional.html: "If no conditions are true, the result from the ELSE clause is returned if it exists, otherwise null is returned." Responder's claims CONFIRMED: a searched CASE with no matching WHEN and no ELSE returns NULL (implicit default); you don't NEED ELSE on every CASE, but add `ELSE <default>` to guarantee a fallback. `ELSE 'Unknown Status'` example is correct and directly answers the ask.

MINOR completeness (not a defect): the answer is correct and actionable but lighter than Q1/Q3/Q4 — it could have noted COALESCE-wrapping the CASE as an equivalent fallback idiom, or that the ELSE result type must be compatible with the WHEN result types (type-coercion). These are nuances, not gaps in the core answer. No tic.

Acc 4.75 / Clar 4.5 / App 4.25 / Comp 4.25.

## Q3 (KEY CHECK) — `WHERE event_ts >= current_date - 7` Postgres-ism — 4.875 CLEAN / STRONG CATCH

★★ **current_date - 7 REJECTION = CORRECT.** VERIFIED both directions against functions/datetime.html + language/types.html:
- (a) DATE minus a bare INTEGER (`current_date - 7`) is NOT supported in Trino 467 — the operators table shows no integer subtraction from a date; there is no implicit "integer = days" coercion. This is a genuine **Postgres-ism** (Postgres treats date-minus-integer as day subtraction; Trino does not). Responder correctly rejected it. CONFIRMED.
- (b) `date_add('day', -7, current_date)` VALID — datetime.html: "Subtraction can be performed by using a negative value," ex `date_add('day', -1, TIMESTAMP ...)`. CONFIRMED.
- (b) `current_timestamp - INTERVAL '7' DAY` VALID — operators section documents `-` with interval, ex `date '2012-08-08' - interval '2' day`. CONFIRMED.

★ **INTERVAL SYNTAX VERDICT CONFIRMED:** `INTERVAL '7' DAY` (number in quotes, unit keyword OUTSIDE quotes, uppercase) is the correct Trino form. `INTERVAL '7 days'` (number AND plural unit both INSIDE the quotes) is a PARSE ERROR — the literal value goes in quotes and the qualifier keyword (DAY, singular) is a separate token. Matches the documented `INTERVAL '2' DAY` form and the known INTERVAL-qualifier constraint (only YEAR/MONTH/DAY/HOUR/MINUTE/SECOND qualifiers; no plural-in-quote form). CONFIRMED CORRECT.

Strong catch of the Postgres-ism with both correct alternatives and the right INTERVAL-singular guidance. The note also fits the prod stack (Trino 467) precisely.

Acc 5.0 / Clar 4.75 / App 5.0 / Comp 4.75.

## Q4 — role NULL silently dropped by `WHERE role <> 'admin'`; null-safe comparison vs OR role IS NULL — 4.875 CLEAN

**VERIFIED:** comparison.html confirms three-valued logic. `NULL <> 'admin'` evaluates to NULL/UNKNOWN → WHERE keeps only TRUE rows, so NULL-role legacy rows are silently dropped. CONFIRMED (matches the symptom).

★ **IS DISTINCT FROM CONFIRMED null-safe & real (NOT a fabrication):** comparison.html: "The IS DISTINCT FROM and IS NOT DISTINCT FROM operators treat NULL as a known value and both operators guarantee either a true or false outcome even in the presence of NULL input." So `role IS DISTINCT FROM 'admin'` returns TRUE when the values differ OR exactly one side is NULL → NULL-role rows are KEPT. CONFIRMED CORRECT, and it is the cleaner single-operator form the user asked for.

Option A `role <> 'admin' OR role IS NULL` is the equivalent explicit form — also CORRECT. Recommending IS DISTINCT FROM as the cleaner option is sound. Both alternatives are runnable and the 3VL explanation is accurate.

Acc 5.0 / Clar 4.75 / App 4.875 / Comp 4.875.

---

## SCOPE NOTES (per-Q verdicts)

- **Q1 — UNION-implicit-DISTINCT:** bare UNION = UNION ALL + global dedup (extra work); UNION ALL stacks cheaply; prefer UNION ALL unless dedup needed AND inputs overlap; disjoint-inputs caveat correct. CLEAN. NOT DISTINCT-vs-GROUP-BY folklore — the legit UNION distinction.
- **Q2 — CASE-no-ELSE-NULL:** no matching WHEN + no ELSE → NULL (implicit default); ELSE provides fallback; not required on every CASE. CLEAN; minor completeness (COALESCE-wrap / ELSE type-compat unmentioned).
- **Q3 (KEY) — current_date-7-rejected-CORRECT [Postgres-ism]:** DATE − bare INTEGER NOT valid in Trino (no integer=days coercion); fix = `date_add('day', -7, current_date)` OR `current_timestamp - INTERVAL '7' DAY`. INTERVAL verdict: `INTERVAL '7' DAY` correct, `INTERVAL '7 days'` parse error. ALL CONFIRMED. STRONG catch.
- **Q4 — IS DISTINCT FROM null-safe:** `NULL <> 'admin'` = UNKNOWN → WHERE drops it (3VL); `role IS DISTINCT FROM 'admin'` null-safe (TRUE when differ OR one side NULL) → keeps NULL rows; `role <> 'admin' OR role IS NULL` equivalent. CLEAN.

## TICS — ALL CLEAN
No QUALIFY / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn (date_add, IS DISTINCT FROM, INTERVAL, UNION ALL ALL real & verified) / regex-backslash / GREATEST-LEAST-NULL / DISTINCT-vs-GROUP-BY-perf-folklore (Q1 = legit UNION distinction, NOT folklore) / date-minus-integer-Postgres-ism (Q3 = responder CORRECTLY REJECTED it) / window-in-WHERE / broken-secondary-false-justification / mid-churn / column-scope / INTERVAL-quarter-week (Q3 used valid DAY qualifier) / ILIKE-conflation.

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.25; all 4 leads correct & verified both directions; zero tics; no findable resource/findability gap; no 2-in-2 recurrence. Q3 (the key check) is a clean, strong catch of the Postgres date-minus-integer idiom with both correct Trino alternatives and the right INTERVAL-singular syntax. Q2's minor completeness lightness is not a defect and not a recurring pattern — re-probe-don't-churn.

Re-probe next sweep:
- (a) another date-arithmetic Q (esp. interval/period offset) — confirm `current_date - N`-rejection + `date_add`/INTERVAL-singular lead stays; watch INTERVAL-quarter/week qualifier trap.
- (b) another NULL-comparison / 3VL Q (NOT IN with NULLs, anti-join NULL trap) — confirm IS DISTINCT FROM / IS NULL-guard lead.
- (c) another UNION / set-op Q — confirm UNION-vs-UNION-ALL dedup distinction stays framed as the legit cost (NOT GROUP-BY-vs-DISTINCT folklore).

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 995; passed=true preserved; final_iterations_remaining 0).
