# Judge Feedback — iter990 (EXTENDED PHASE breadth sweep)

**OVERALL 4.8125 — STRONG PASS** (Q1 4.8125 / Q2 4.84375 / Q3 4.8125 / Q4 4.78125 = 19.25/4 = 4.8125; margin +1.3125; OVERALL AVERAGE governs, no per-Q veto.)

All 4 dialect/SQL-semantics/logic claims VERIFIED BOTH DIRECTIONS against trino.io/docs/467 (NOT resources/). Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in.

---

## Per-question scores

### Q1 — Users in BOTH Jan AND Feb cohorts; UNION just combines everything — 4.8125 CLEAN
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75

INTERSECT is the correct answer and the lead is fully verified:
- sql/select.html: "INTERSECT returns only the rows that are in the result sets of both the first and the second queries." — set intersection, exactly the ask.
- Default DISTINCT (dedups): "If neither [ALL nor DISTINCT] is specified, the behavior defaults to DISTINCT." — responder's "auto-dedups" CONFIRMED.
- ★ PRECEDENCE CLAIM VERIFIED CORRECT: "Additionally, INTERSECT binds more tightly than EXCEPT and UNION." — responder's "INTERSECT binds tighter than UNION; parenthesize when mixing" is CONFIRMED, not a fabrication. Good proactive nuance.
- Correctly diagnosed why the user's UNION combined everything (UNION = union of sets, not intersection).
NO INTERSECT-mislabel tic.

### Q2 — cancelled_at NULL sorting to TOP with ORDER BY ... DESC — 4.84375 CLEAN ★ KEY CHECK
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.875

★ NULLS-LAST-REGARDLESS VERIFIED CORRECT (independently re-confirmed this iter): sql/select.html exact text "The default null ordering is NULLS LAST, regardless of the ordering direction." So Trino 467 default = NULLS LAST for BOTH ASC and DESC; `ORDER BY cancelled_at DESC` puts NULLs at the BOTTOM. The USER'S PREMISE ("NULLs end up at the TOP with DESC") is FACTUALLY WRONG.

★ The responder did the RIGHT thing: it stated the verified-correct default (NULLS LAST regardless of direction), DID NOT blindly accept the false premise, and correctly flagged the observation as inconsistent ("your data might not have NULLs where you expect, or another column sorts first") while still handing over the actionable explicit-NULLS-LAST / NULLS-FIRST fix. This is exactly the desired behavior — challenging a false premise with the verified-correct fact is correct, NOT a "contradicting the user" defect. The Oracle/PostgreSQL contrast (those engines flip default NULL placement by ASC/DESC; Trino is consistent both directions) is also accurate. NO NULL-ordering-default-error tic — this is the inverse: a correct one. Slight comp edge for the proactive "explicit NULLS FIRST/LAST always" hygiene advice.

### Q3 — simple CASE returns NULL for NULL plan_tier — 4.8125 CLEAN
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75

Diagnosis VERIFIED: functions/conditional.html — simple CASE "searches each value expression from left to right until it finds one that equals expression" (equality semantics); NULL never equals a value via `=` (NULL='starter' is UNKNOWN, not TRUE), so a NULL plan_tier matches NO WHEN; "If no match is found, the result from the ELSE clause is returned if it exists, otherwise null is returned." → NULL output. Responder's 3VL explanation is precisely right.
Both fixes correct: (Option 1) searched CASE with `WHEN plan_tier IS NULL THEN 'Unknown'` placed FIRST + an ELSE; (Option 2) `CASE COALESCE(plan_tier,'unknown') WHEN ...`. The "IS NULL is the only predicate that returns TRUE for NULL; never write WHEN col = NULL" guidance is accurate and good teaching.

### Q4 — starts_with real & better than LIKE? ends_with? — 4.78125 CLEAN
Acc 5.0 / Clar 4.75 / App 4.625 / Comp 4.75

★ starts_with IS REAL (NOT a fabrication): functions/string.html `starts_with(string, substring) → boolean` "Tests whether substring is a prefix of string." Equivalent to `LIKE '/app/%'`; "clearer intent" is a fair characterization (and avoids LIKE wildcard-escaping concerns).
★ ends_with CORRECTLY FLAGGED ABSENT: full-page search confirms ZERO occurrences of "ends_with" in Trino 467 (Spark/Snowflake have it; Trino does not). Responder did NOT invent it.
★ SUBSTR negative-start fallback VALID: "A negative starting position is interpreted as being relative to the end of the string" → `SUBSTR(filename, -4)='.csv'` returns the last 4 chars, correct for suffix matching; LIKE '%.csv' alternative also correct. NO fabricated-function tic; this is the exact-correct starts_with/ends_with disposition.

---

## Tic scan — ALL CLEAN
No QUALIFY-misuse / no false-mechanism-semi-join-mislabel / no MAX(varchar) / no percent_rank-inversion / no fabricated-fn-or-rule (starts_with REAL + verified; ends_with correctly ABSENT; INTERSECT real; simple-CASE equality real) / no PARTITIONED-BY-foreign-DDL / no aggregate-in-GROUP-BY / no broken-secondary-false-justification / no DISTINCT-vs-GROUP-BY-perf-folklore (the iter989 slip did NOT recur — no dedup/perf Q this iter) / no NULL-ordering-default-error (Q2 is the CORRECT inverse) / no INTERSECT-mislabel / no mid-churn / no missing-CTE-col / no JOIN-fan-out / no ts-minus-ts / no column-scope / no ILIKE-conflation.

## Scope notes
- Q1: INTERSECT = set intersection + default DISTINCT dedup CONFIRMED; INTERSECT-binds-tighter-than-UNION/EXCEPT precedence CONFIRMED (parenthesize-when-mixing nuance is correct, not invented).
- Q2 (KEY CHECK): NULLS-LAST-regardless-of-direction VERIFIED CORRECT; responder correctly CHALLENGED the user's false premise ("NULLs at the top with DESC") instead of accepting it, AND gave the explicit-NULLS-LAST/FIRST fix + correct Oracle/PG contrast. Score HIGH; this is the desired premise-challenge behavior, not a defect.
- Q3: simple-CASE uses `=`, NULL falls through to NULL (no ELSE), 3VL diagnosis + searched-CASE-IS-NULL-first / COALESCE-wrap fixes all CORRECT.
- Q4: starts_with REAL (functions/string.html, prefix test, ~ LIKE 'prefix%'); ends_with ABSENT (0 page hits) correctly stated; SUBSTR(s,-4) negative-from-end VALID.

## Recommendation — DEFAULT NO-OP
Margin +1.3125, all 4 leads correct and verified both directions, zero tics, no findable resource/findability gap, no 2-in-2 recurrence outstanding. iter989 DISTINCT-vs-GROUP-BY folklore did not have an opportunity to recur (no dedup-vs-aggregate Q) — keep it on the re-probe watchlist.
Re-probe next sweep: (a) another set-operation Q (INTERSECT/EXCEPT) — confirm precedence/dedup lead stays + watch for INTERSECT/EXCEPT-mislabel; (b) another NULL-ordering Q (ASC direction this time) — confirm NULLS-LAST-regardless holds for ASC too and the premise-challenge instinct persists; (c) another prefix/suffix-string Q — confirm starts_with-REAL / ends_with-ABSENT / SUBSTR-negative disposition holds; (d) still owed: another DISTINCT-vs-GROUP-BY / dedup-vs-aggregate Q to settle whether the iter989 perf folklore is a pure one-off (2-in-2 → trace to resource root cause before treating as responder slip).

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). NO resource edits. DID NOT bump training/state.json (already 990; passed=true preserved; final_iterations_remaining 0).
