# iter997 Judge Feedback (EXTENDED PHASE breadth sweep)

**OVERALL 4.40625 PASS** (Q1 4.8125 / Q2 3.625 / Q3 4.8125 / Q4 4.8125 = 17.625/4 = 4.40625; margin +0.906; OVERALL AVERAGE governs, no per-Q veto).

All 4 Qs verified BOTH directions vs trino.io/docs/467 + WebSearch of official issues/source — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in.

---

## Q1 — extract JSON scalar (Postgres `metadata->>'plan'` → Trino) — **4.8125 CLEAN**

VERIFIED vs functions/json.html:
- `json_extract_scalar(json, json_path) → varchar` REAL — doc: "Like json_extract(), but returns the result value as a string." Correct Trino equivalent of Postgres `->>` (Trino has NO `->>` operator; the function is the answer).
- `JSON_VALUE(json_input, json_path [RETURNING type] [... ON EMPTY] [... ON ERROR])` REAL SQL/JSON syntax — full signature confirmed; `RETURNING varchar`, `NULL ON EMPTY`, `NULL ON ERROR` all valid for distinguishing absent-key vs malformed-JSON.
- `CAST(json_extract_scalar(metadata,'$.price') AS DECIMAL)` correct for typed extraction (json_extract_scalar always returns varchar).
- "Use json_extract_scalar for everyday, json_value for absent-vs-malformed distinction" — accurate steering.
- NO fabricated-fn tic (both functions real). Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — BETWEEN inclusive on both endpoints? — **3.625 (BETWEEN-inclusive lead CORRECT + UNFLAGGED varchar-vs-DATE coercion trap)**

★ THE KEY CHECK. Two-part verdict:

**Part A — BETWEEN inclusivity: CORRECT.** VERIFIED vs functions/comparison.html: "value BETWEEN min AND max"; "3 BETWEEN 2 AND 6 is equivalent to 3 >= 2 AND 3 <= 6" — inclusive on BOTH endpoints. The responder's lead is right. The TIMESTAMP half-open gotcha (`>= '2025-01-01' AND < '2025-02-01'` to avoid sub-second fencepost loss) is also a genuinely good, correct nuance.

**Part B — ★ VERIFIED COERCION VERDICT: Trino 467 THROWS on DATE/TIMESTAMP-column vs bare-VARCHAR-literal. The responder MISSED flagging the DATE-literal requirement.**
- functions/comparison.html EXPLICITLY: "the value, min, and max parameters to BETWEEN and NOT BETWEEN must be the same type" + "Trino will error if you attempt to compare operands of different types."
- Confirmed in the wild: AWS re:Post documents `TYPE_MISMATCH: Cannot apply operator: date < varchar(10)`; Trino does NOT implicitly convert VARCHAR→DATE/TIMESTAMP (consistent with iter989 #7334 timestamp-vs-varchar finding). Fix is `DATE '2025-01-01'` / `CAST('2025-01-01' AS DATE)` / `from_iso8601_date(...)`.
- IMPACT: the responder's example queries use BARE varchar literals `due_date BETWEEN '2025-01-01' AND '2025-01-31'`. If `due_date` is a DATE or TIMESTAMP column (the overwhelmingly likely case for a column literally named `due_date`), those queries ERROR. They only run if `due_date` is a VARCHAR column storing ISO date strings (where lexicographic = chronological order makes the comparison coincidentally correct).
- CONTRAST: iter989 Q3 correctly CAUGHT the timestamp-vs-varchar trap. Here the responder did NOT flag that a DATE/TIMESTAMP `due_date` needs `DATE` literals — a real accuracy/completeness gap on the exact column the user is asking about.

Classification: **RESPONDER slip (incomplete answer), NOT a resource defect** — this is the iter989-confirmed VARCHAR-vs-DATE-coercion tic recurring as an OMISSION rather than a wrong claim. The BETWEEN-inclusive lead is fully correct, so the answer is not wrong, just incomplete on the load-bearing column-type caveat. Score down for the unflagged coercion trap. Acc 3.5 / Clar 4.0 / App 3.5 / Comp 3.5.

NOTE: this is the SECOND surfacing (iter989 caught it, iter997 missed it) of date/timestamp-vs-bare-varchar. NOT 2-in-2 in the same direction (989 = caught, 997 = missed), so re-probe-don't-churn — but flag for next sweep: if a third date/timestamp-column-vs-string-literal Q also omits the DATE-literal flag, trace whether a resource needs an additive "compare DATE/TIMESTAMP columns with typed literals (DATE '...'), never bare varchar — Trino throws TYPE_MISMATCH, no implicit coercion" note co-located with BETWEEN / date-filter keywords.

## Q3 — IN vs EXISTS, real difference in results/speed (last-30-days, non-correlated)? — **4.8125 CLEAN**

VERIFIED:
- For a NON-CORRELATED positive-membership subquery, IN and EXISTS are semantically EQUIVALENT and Trino lowers BOTH to a SemiJoin — confirmed via `TransformUncorrelatedInPredicateSubqueryToSemiJoin` (Trino's documented decorrelation rule; SemiJoin operator yields one TRUE/FALSE per outer row, dedups the build side). NO "EXISTS is faster" folklore. This is a CORRECT SemiJoin attribution, NOT a false-mechanism semi-join mislabel.
- Correlated NOT EXISTS → LeftJoin + Aggregation slow path (#21859) is REAL and CORRECTLY scoped as NOT applicable to this non-correlated positive case.
- `WHERE user_id IN (SELECT user_id FROM orders WHERE created_at >= current_date - INTERVAL '30' DAY)` — `current_date - INTERVAL '30' DAY` is VALID Trino (date − interval; `INTERVAL '30' DAY` matches the doc `INTERVAL '2' DAY` singular-unit-keyword form). NOT the date−bare-integer Postgres-ism (`current_date - 30`) — responder used INTERVAL correctly.
- "Run EXPLAIN, look for SemiJoin" — correct, actionable verification advice.
- Recommending IN is fine (plan-equivalent to EXISTS here). NO DISTINCT-vs-GROUP-BY perf folklore. Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q4 — best-available label (display_name else username else email) — **4.8125 CLEAN**

VERIFIED vs functions/conditional.html:
- `COALESCE(display_name, username, email)` — "Returns the first non-null value in the argument list"; N-arg; short-circuits like CASE. Returns first non-NULL left-to-right exactly as described. Cleaner than nested IF/CASE — correct.
- "NVL is Oracle 2-arg, COALESCE is N-arg idiomatic Trino" — CORRECT. NVL is NOT in Trino docs (Oracle-only); COALESCE is the idiomatic Trino form. Good Oracle-migration-aware framing.
- Since email is always set, the COALESCE chain is guaranteed non-NULL — implicitly correct (no need for a trailing sentinel). Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.875.

---

## Tic audit (RESOURCE-defect vs RESPONDER-slip)

- QUALIFY: ABSENT (none used). CLEAN.
- false-mechanism semi-join mislabel: Q3 IN/EXISTS→SemiJoin is CORRECT (verified rule name), NOT a mislabel. CLEAN.
- MAX(varchar): N/A. percent_rank inversion: N/A.
- fabricated functions: json_extract_scalar / json_value / COALESCE ALL REAL & verified; NVL correctly identified as Oracle-only. CLEAN.
- regex-backslash / GREATEST-LEAST-NULL: N/A.
- **VARCHAR-vs-DATE-coercion [Q2 — KEY]: TRAP PRESENT, responder MISSED flagging it.** Verified Trino 467 THROWS TYPE_MISMATCH on DATE/TIMESTAMP-column vs bare-varchar-literal. RESPONDER omission (incomplete), not a resource defect. Down-scored Q2.
- date-minus-integer: Q3 used `INTERVAL '30' DAY` correctly (NOT bare integer). CLEAN.
- EXISTS-vs-IN folklore: Q3 correctly states plan-equivalent for non-correlated positive case. CLEAN.
- broken-secondary / mid-churn / column-scope / ILIKE-conflation / INTERVAL-quarter-week: none. CLEAN.

## Recommendation = DEFAULT NO-OP (margin +0.906)

All 4 LEADS correct & verified both directions. The sole ding is Q2's unflagged varchar-vs-DATE coercion caveat — a RESPONDER completeness omission on a load-bearing column-type point, NOT a wrong claim and NOT a findable resource gap (the BETWEEN-inclusive answer itself is correct). NOT 2-in-2 in the same direction (iter989 CAUGHT the same coercion trap; iter997 MISSED it).

Re-probe next sweep:
- (a) ★ another date/timestamp-COLUMN vs string-LITERAL filter Q (BETWEEN, `>=`, `=`) — confirm whether responder flags the DATE-literal requirement / TYPE_MISMATCH. If a third such Q ALSO omits it (making it 2-in-2 as an omission), trace to resource root cause: an additive co-located note "compare DATE/TIMESTAMP columns with typed literals DATE '...' / TIMESTAMP '...', never bare varchar — Trino throws TYPE_MISMATCH, no implicit coercion" near BETWEEN/date-filter keywords.
- (b) another IN-vs-EXISTS / subquery-membership Q — confirm SemiJoin-equivalence lead stays + #21859 correlated-NOT-EXISTS scoping + INTERVAL-not-integer.
- (c) another JSON-extraction Q — confirm json_extract_scalar / json_value lead.
- (d) another COALESCE/NVL fallback Q — confirm N-arg COALESCE + NVL-is-Oracle framing.

Federation r22 §13.x hard-locked, NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 997; passed=true preserved; final_iterations_remaining 0).
