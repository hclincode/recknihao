# iter998 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.6172 STRONG PASS** (Q1 4.0 / Q2 4.8125 / Q3 4.84375 / Q4 4.8125 = 18.46875/4 = 4.6172; margin +1.117; OVERALL AVERAGE governs, no per-Q veto).

All 4 Qs verified BOTH directions vs trino.io/docs/467 + RAW git-tag 467 source — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in.

---

## Q1 — clean product names: trim + collapse internal spaces (Postgres trim+regexp_replace → Trino?) — 4.0

**SQL CORRECT, PROSE BACKSLASH CLAIM WRONG (the ding).**

- `regexp_replace(trim(product_name), '\s+', ' ')` — the deliverable SQL is CORRECT working Trino 467:
  - trim() removes general leading/trailing whitespace — VERIFIED.
  - regexp_replace 3-arg (string, pattern, replacement) — VERIFIED valid.
  - ★ SINGLE-backslash `'\s+'` is CORRECT. Verified via RAW git-tag source
    (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/regexp.md):
    examples use single backslash `'\d+'`, `'(\w)'`. Trino does NOT process backslash
    escapes in standard '...' VARCHAR literals, so `'\s'` reaches the Java regex engine as
    the whitespace class = WORKS. DOUBLE backslash `'\\s+'` would reach the engine as
    escaped-backslash+s (matches a literal backslash then 's') = BROKEN. (The RENDERED
    trino.io HTML shows `\\s` — a Sphinx doubling artifact; the RAW source shows single `\s`.
    iter991 lesson re-confirmed.)
- ★★ **PROSE DEFECT (responder slip):** the prose asserts "Trino regex uses DOUBLE BACKSLASH
  for character classes, so it's '\s+' not '\s+' in some dialects" — this is (a) the WRONG
  backslash convention (Trino canonical is SINGLE backslash, raw-source verified), and
  (b) internally garbled/self-contradictory (it contradicts the responder's own correct
  single-backslash SQL). If a user FOLLOWED the prose and wrote `'\\s+'`, the query would
  BREAK. The deliverable SQL is correct, so a user who copies the code block is fine — but
  the explanation is actively wrong on a load-bearing dialect point.
- CLASSIFY: **RESPONDER prose/false-claim slip, NOT a resource defect.** Resources use
  single-backslash / backslash-free char-classes per iter991 (r23 canonical uses `[0-9]{8}`).
  regex-backslash tic family (prose direction). Re-probe-don't-churn.
- Acc 3.5 / Clar 3.75 / App 4.25 / Comp 4.5.

**ORCHESTRATOR ACTION (PHASE 6):** grep resources/ to CONFIRM no resource asserts a
double-backslash convention (expected: none — iter991 already verified single-backslash /
backslash-free char-classes are canonical). If grep is clean, this is purely a responder
slip with no resource fix needed.

## Q2 — pull "seats" out of metadata JSON as a NUMBER for math — 4.8125 CLEAN

- `CAST(json_extract_scalar(metadata, '$.seats') AS INTEGER)` then SUM — VERIFIED.
  json_extract_scalar(json, json_path) → varchar (functions/json.html) = correct; CAST to
  INTEGER for arithmetic is the right typed-extraction; SUM aggregates. CORRECT.
- Alternative `JSON_VALUE(metadata, '$.seats' RETURNING INTEGER NULL ON EMPTY NULL ON ERROR)`
  — VERIFIED real Trino 467 SQL/JSON syntax (RETURNING type + ON EMPTY/ON ERROR clauses
  documented). Both valid.
- No fabricated functions. Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q3 — `WHERE refund_amount != NULL` returns zero rows — 4.84375 CLEAN

- Diagnosis CORRECT: `!= NULL` / `= NULL` always evaluate to NULL/UNKNOWN under 3VL
  (any comparison involving NULL produces NULL — functions/comparison.html); WHERE keeps
  only TRUE rows, drops UNKNOWN → zero rows. Matches symptom exactly.
- Fix CORRECT: `WHERE refund_amount IS NOT NULL` (IS NULL/IS NOT NULL always return boolean);
  SELECT DISTINCT order_id variant for "every order with ≥1 refunded line item" is apt.
- "Never use = NULL / != NULL" guidance sound. Acc 5.0 / Clar 4.875 / App 4.75 / Comp 4.75.

## Q4 — "this month" filter; `WHERE recorded_at >= '2026-06-01'` on a TIMESTAMP — 4.8125 CLEAN

- Correctly flags hardcoded '2026-06-01' breaks on month rollover.
- Recommended dynamic half-open filter VERIFIED CORRECT:
  `WHERE recorded_at >= date_trunc('month', current_date)
     AND recorded_at < date_trunc('month', current_date) + INTERVAL '1' MONTH`
  - date_trunc('month', current_date) → first of month (returns DATE, matches input type);
    comparing TIMESTAMP recorded_at to a DATE → DATE coerces to TIMESTAMP (valid).
  - `+ INTERVAL '1' MONTH` on the truncated value is valid (`+` interval operator); next-month
    first. Half-open `>= AND <` is the correct fencepost (no double-count, no boundary gap).
  - Auto-updates each month; date_trunc-on-column partition-prunes (Trino unwraps
    date_trunc in comparison — UnwrapDateTruncInComparison).
- ★ **#7334 SIDESTEPPED — NOT a 2-in-2 recurrence:** the responder did NOT explicitly flag
  that the user's ORIGINAL bare-varchar '2026-06-01' vs a TIMESTAMP column would throw
  TYPE_MISMATCH (no implicit varchar→timestamp coercion). This is a MINOR completeness point,
  NOT a defect — the recommended query uses date_trunc and contains NO bare varchar literal,
  so it avoids the trap entirely. CONTRAST iter997 Q2 which MISSED flagging the DATE-literal
  requirement on queries that DID use bare varchar literals (those would error). Here the
  recommended form is correct and self-protecting, so the omission is immaterial. The
  varchar-vs-DATE/TS-literal omission did NOT recur in a load-bearing way → NOT 2-in-2.
- Acc 5.0 / Clar 4.75 / App 4.875 / Comp 4.625.

---

## SCOPE NOTES

- **Q1**: SQL single-backslash `'\s+'` CORRECT (raw-source verified single is canonical;
  double-backslash would break) + trim + 3-arg regexp_replace valid; PROSE double-backslash
  claim WRONG + internally garbled = RESPONDER prose slip (deliverable SQL correct).
  Orchestrator: grep resources/ to confirm no resource asserts double-backslash.
- **Q2**: json_extract_scalar(json,path)→varchar + CAST AS INTEGER then SUM; JSON_VALUE
  RETURNING INTEGER ON EMPTY/ON ERROR real — CLEAN.
- **Q3**: `!=NULL`/`=NULL`→UNKNOWN (3VL), WHERE drops UNKNOWN; IS NOT NULL is the fix — CLEAN.
- **Q4**: date_trunc('month', current_date) … `< … + INTERVAL '1' MONTH` half-open this-month
  filter CORRECT; #7334 bare-varchar omission SIDESTEPPED via date_trunc, NOT 2-in-2.

## TICS — all CLEAN except Q1 regex-backslash PROSE slip
no QUALIFY / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion /
fabricated-fn (trim / regexp_replace / json_extract_scalar / JSON_VALUE / date_trunc ALL real
& verified) / GREATEST-LEAST-NULL / date-minus-integer (Q4 INTERVAL '1' MONTH correct) /
temporal-vs-varchar-literal (Q4 sidestepped via date_trunc, NOT a recurrence) / broken-secondary /
mid-churn / column-scope / ILIKE-conflation / INTERVAL-quarter-week.
**Sole blemish: Q1 prose double-backslash claim (responder slip; SQL correct).**

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.117; all 4 deliverable SQL/diagnoses correct & verified both directions; sole ding
is Q1's WRONG prose backslash claim — a RESPONDER explanation slip (SQL it ships is correct,
raw-source-verified), NOT a findable resource gap and NOT 2-in-2 (iter991 the responder got
the backslash RIGHT in both SQL and reasoning; this is a fresh prose-direction slip). Resources
already canonicalize single-backslash / backslash-free char-classes per iter991.

Re-probe next sweep:
(a) ★ another regex Q with backslash char-classes (`\d`/`\s`/`\w`) — confirm SQL stays single-
    backslash AND watch whether the PROSE again asserts double-backslash; if a SECOND prose
    double-backslash claim appears (2-in-2 prose direction) → trace to resource root cause
    (grep resources for any double-backslash assertion; if none, accept as recurring responder
    padding — but a LIGHT additive defang clarifying "Trino single-quoted literals do NOT
    escape backslash; '\s' reaches the regex engine as-is; '\\s' would be broken" near
    regexp keywords would help the responder's explanation track its own correct SQL).
(b) another JSON-extraction Q — confirm json_extract_scalar/JSON_VALUE leads stay.
(c) another NULL-comparison/3VL Q — confirm `!=NULL`→IS NOT NULL lead.
(d) another this-month/date-range filter Q — confirm date_trunc half-open lead + watch whether
    responder flags the bare-varchar-vs-TIMESTAMP TYPE_MISMATCH when the user's query uses one.

Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits.
DO NOT bump training/state.json (already 998; passed=true preserved; final_iterations_remaining 0).
