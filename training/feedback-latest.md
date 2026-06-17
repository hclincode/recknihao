# iter984 Judge Feedback

**OVERALL 4.40625 STRONG PASS** (Q1 4.6875 / Q2 4.0625 / Q3 4.75 / Q4 4.125 = 17.625/4 = 4.40625; margin +0.906; OVERALL AVERAGE governs, no per-Q veto)

EXTENDED PHASE breadth sweep. All 4 Qs verified BOTH directions vs trino.io/docs/467 (NOT resources/):
- sql/select.html GROUP BY: "all output expressions must be either aggregate functions or columns present in the GROUP BY clause"; GROUP BY accepts input columns / ordinal, NOT output aliases; DISTINCT ON (Postgres) absent.
- functions/string.html: one-arg `trim(string)` "Removes leading and trailing whitespace" (general whitespace incl. tabs, not space-only); `lower()` standard.
- functions/datetime.html: `format_datetime` uses Joda patterns (MMMM=full month name, yyyy=4-digit year → 'June 2026'); `date_format` MySQL specifiers — **%M = full month name, %b = abbreviated, %Y = 4-digit year; %B is NOT a listed specifier**; to_char exists (Teradata-compat) lowercase numeric-only, cannot emit month names.
- WebSearch 2026-06-17 confirmed CASE-on-aggregate IS a legal aggregate expression in the SELECT list of a GROUP BY query.

Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all answers fit.

---

## Q1 — clean messy product names, LOWER(TRIM(name)) — 4.6875 CLEAN
`SELECT LOWER(TRIM(product_name)) AS clean_name FROM events`. VERIFIED: both `lower()` and one-arg `trim()` are valid Trino 467 and behave like Postgres for this use. The "TRIM removes both spaces and tabs" claim is CORRECT — Trino's one-arg `trim()` strips general leading/trailing whitespace (space, tab, newline), not just the space character. Example trace "  Premium Plan  " → "premium plan" correct. No dialect ding.
Acc 4.75 / Clar 4.75 / App 4.625 / Comp 4.625.

## Q2 ★ — spend-tier bucket then COUNT per tier — 4.0625 (LEAD correct; secondary false-justification ding)
**THE KEY CHECK — verdict on the two sub-items:**

**(a) aggregate-in-GROUP-BY did NOT recur — LEAD CORRECT + LEGAL.** The two-level CTE: inner `account_spending` groups by `account_id` (raw key) with `SUM(amount)` and the `CASE WHEN SUM(amount)>10000 ... END AS spend_tier` in the SELECT (a legal aggregate expression); outer query `GROUP BY spend_tier` with `COUNT(*)`. VERIFIED LEGAL Trino 467 — the iter983 illegal pattern (CASE-on-SUM placed INSIDE the GROUP BY clause, #25984) did NOT recur. Boundary trace: 10000 → not >10000 → BETWEEN 2000 AND 10000 → 'medium'; 1999 → 'low'; matches the question's tiers. **iter983 aggregate-in-GROUP-BY slip CONFIRMED ONE-OFF (not 2-in-2) — no resource fix, no FIX-A.**

**(b) SECONDARY = FALSE JUSTIFICATION (responder slip).** The responder claims the single-query form `SELECT CASE WHEN SUM(amount)>10000 THEN 'high' ... END AS spend_tier, COUNT(*) FROM invoices GROUP BY account_id` "won't work — you can't aggregate in the SELECT and group by different columns." VERIFIED FALSE: that query IS LEGAL Trino 467. A CASE-on-SUM(amount) is itself an aggregate expression (reduces to one value per group), and COUNT(*) is an aggregate — both satisfy the GROUP BY rule. It COMPILES and runs; it just produces ONE ROW PER ACCOUNT (a per-account label + count), answering a DIFFERENT question, NOT the per-tier count the engineer wants. The responder's "won't work / can't aggregate in SELECT and group by different columns" mis-states legality as the reason. Additionally the "CASE is evaluated at row level not group level" explanation is MUDDLED — you CAN group by a row-level CASE on raw columns; the real reason you cannot group by THIS bucket is that it resolves to an aggregate (CASE-on-SUM), not a row-level expression.

**RESOURCE-vs-SLIP = RESPONDER slip (broken-secondary / false-justification family).** The DELIVERABLE (lead) is correct and legal; the ding is for the inaccurate justification appended to rule out the alternative. No resource defect — r07 §A2 GROUP BY anchor correctly shows GROUP-BY-raw-keys + CASE-on-aggregate-in-SELECT. Re-probe-don't-churn.
Acc 3.75 / Clar 4.25 / App 4.25 / Comp 4.0.

## Q3 — one row per user/day, DISTINCT ON equivalent — 4.75 CLEAN
`SELECT ... FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY user_id, event_date ORDER BY event_time DESC) AS rn FROM user_events) WHERE rn=1`. VERIFIED: DISTINCT ON (Postgres) is genuinely ABSENT in Trino 467; ROW_NUMBER()=1 subquery is the correct equivalent (row_number starts at 1; DESC → rn=1 = latest). Tiebreaker advice (ORDER BY event_time DESC, event_id DESC) sound for duplicate timestamps. NO QUALIFY misuse — subquery-wrap used correctly (QUALIFY is absent in 467). Projects all needed columns (no missing-CTE-col).
Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q4 ★ — format DATE as "June 2026", TO_CHAR equivalent — 4.125 (LEAD correct; broken-secondary %B ding)
**LEAD CORRECT:** `format_datetime(CAST(due_date AS timestamp), 'MMMM yyyy')` → 'June 2026'. VERIFIED 467 functions/datetime.html — format_datetime uses Joda patterns; MMMM = full text month name, yyyy = 4-digit year; MMM = abbreviated; MM = numeric. CAST(date AS timestamp) is fine/explicit (format_datetime takes a timestamp). The pattern-letter gloss is accurate.

**ALTERNATIVE = BROKEN SECONDARY (dialect error, responder slip):** `date_format(CAST(due_date AS timestamp), '%B %Y')` claiming "%B = full month name". VERIFIED FALSE against 467 date_format MySQL specifiers — the full-month-name code is **%M**, abbreviated is **%b**; **%B is NOT a valid Trino/MySQL date_format specifier** (it is a C/strftime code). The alternative should be `'%M %Y'`. As written `'%B %Y'` is a dialect error. Broken-secondary-alternative tic — lead correct, appended alternative broken.

**NOTE (do not over-ding):** "TO_CHAR doesn't have a direct Trino equivalent" is slightly imprecise — Trino 467 DOES have `to_char` (Teradata-compat) but with lowercase NUMERIC-only codes (dd/mm/yyyy etc.), NO month names — so to_char genuinely CANNOT produce 'June 2026', and format_datetime IS the right tool. The practical guidance is correct; the lead answers the question.

**RESOURCE-vs-SLIP = RESPONDER slip (broken-secondary family).** Lead correct, no resource fix.
Acc 4.0 / Clar 4.25 / App 4.25 / Comp 4.0.

---

## SCOPE NOTES
- **Q2 KEY-CHECK verdict: aggregate-in-GROUP-BY did NOT recur — LEAD CORRECT + LEGAL — iter983 slip CONFIRMED ONE-OFF.** No FIX-A, no resource edit.
- **Q2 single-query "won't work" = FALSE-JUSTIFICATION responder slip** — the query is LEGAL (per-account rows, different question), not illegal. Broken-secondary/false-justification family. No resource fix.
- **Q4 `%B` should be `%M` = broken-secondary responder slip** — lead (format_datetime 'MMMM yyyy') correct. No resource fix.
- **Q1 / Q3 CLEAN.**
- TICS otherwise CLEAN: no QUALIFY-misuse (Q3 subquery-wrap, correctly absent) / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn-or-rule / PARTITIONED-BY-foreign-DDL / mid-churn / missing-CTE-col (Q3 projects all) / JOIN-fan-out / ts-minus-ts. The two slips (Q2 false-justification, Q4 %B) are both RESPONDER broken-secondary/false-justification slips against correct resources, NOT resource defects.

## RECOMMENDATION = DEFAULT NO-OP
Margin +0.906 STRONG PASS; both dings are responder broken-secondary/false-justification slips with correct leads, no resource/findability gap. The iter983 aggregate-in-GROUP-BY slip is confirmed one-off (lead clean this iter).
Re-probe next sweep:
(a) another "compute a bucket/category from an aggregate then group/count" Q — confirm aggregate-in-GROUP-BY stays absent AND watch whether the responder keeps appending a false "single-query won't work" justification (recurrence → LIGHT additive note distinguishing legal-but-different-grain from illegal);
(b) another Postgres-TO_CHAR / month-name-formatting Q — watch the `%B`/`%M` broken-secondary recur (2-in-2 → LIGHT defang: in any date_format card, mark %M=full-month / %B=NOT-a-Trino-code).
Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).
NO resource edits. DO NOT bump training/state.json (already 984; passed=true preserved; final_iterations_remaining 0).
