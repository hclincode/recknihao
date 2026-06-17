# iter985 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.46875 PASS** (Q1 4.6875 / Q2 4.4375 / Q3 4.75 / Q4 4.0 = 17.875/4 = 4.46875; margin +0.969; OVERALL AVERAGE governs, no per-Q veto).

All 4 Qs verified BOTH directions vs trino.io/docs/467 (sql/select.html UNION defaults to DISTINCT / UNION ALL keeps dups + GROUP BY "all output expressions must be aggregate functions or columns present in GROUP BY" / aggregate NOT allowed in GROUP BY; functions/aggregate.html bool_or=TRUE if any input TRUE, bool_and, ignore NULLs, return NULL for no-rows/all-NULL, count_if exists; functions/datetime.html date_format %M=full-month-name / %b=abbreviated / %Y=4-digit-year, format_datetime Joda MMMM=full-month/yyyy=4-digit) — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — answers fit.

---

## Q1 — UNION vs UNION ALL (active+churned subscriptions); bare UNION slower — 4.6875 CLEAN

Acc 4.75 / Clar 4.75 / App 4.625 / Comp 4.625.

VERIFIED CORRECT both directions. Bare `UNION` defaults to DISTINCT (select.html: "If neither is specified, the behavior defaults to DISTINCT") → global dedup via sort/hash-aggregate = the slowdown the engineer observed. `UNION ALL` keeps all rows, cheap (no dedup pass). Guidance "use UNION ALL by default; bare UNION only when you need dedup AND inputs can overlap; if disjoint it's a silent perf killer" is accurate and exactly the right framing — active vs churned subscriptions are disjoint sets, so UNION ALL is correct. LEAD `SELECT * FROM active_subscriptions UNION ALL SELECT * FROM churned_subscriptions` correct. CLEAN.

## Q2 ★ — spend-tier bucket (high>10k/med 2k-10k/low<2k) by TOTAL spend then COUNT per tier — 4.4375 — KEY CHECK: aggregate-in-GROUP-BY DID NOT RECUR

Acc 4.5 / Clar 4.5 / App 4.5 / Comp 4.25.

THE KEY CHECK — VERIFIED CLEAN. Two-level CTE:
- inner `per_account`: GROUP BY **account_id (raw key)** + `SUM(amount) AS total_spend` — legal.
- `labeled`: `CASE WHEN total_spend>10000 THEN 'high' WHEN total_spend>=2000 THEN 'medium' ELSE 'low' END` operates on the **ALREADY-AGGREGATED total_spend column** (NOT CASE-on-SUM-inside-GROUP-BY) — legal.
- outer: `GROUP BY spend_tier COUNT(*)` — legal.

VERIFIED LEGAL Trino 467. The iter983 illegal CASE-on-SUM-INSIDE-GROUP-BY did **NOT recur**. The responder's stated rule **"GROUP BY expressions cannot contain aggregates / Trino errors"** is **CORRECT this iter** (select.html + WebFetch confirm aggregates not allowed in GROUP BY) — contrast iter984's muddled false "can't aggregate in SELECT and group by different columns"; this iter's explanation is RIGHT. Boundary trace: 10000 → not >10000 → >=2000 → **medium** ✓; 1999 → **low** ✓; >10000 → **high** ✓ — matches the Q tiers.

★ **DISPOSITION: iter983 aggregate-in-GROUP-BY slip CONFIRMED a ONE-OFF over 2 consecutive clean re-probes (iter984 + iter985). NO FIX-A, NO resource edit. The explanation rule is now correct 2 iters running.** (Minor comp, not a defect: did not surface that exact-boundary ties are deterministic — immaterial.)

## Q3 — at-least-one 'payment_failed' per workspace (bool_or / at-least-one-match) — 4.75 CLEAN

Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

VERIFIED CLEAN. `bool_or(event_type='payment_failed')` is a valid Trino 467 aggregate (aggregate.html: returns TRUE if any input TRUE, else FALSE; bool_and also exists). bool_or ignores NULLs and returns NULL for no-rows / all-NULL input — so `COALESCE(bool_or(...), false)` edge-case handling is sound and well-reasoned. `GROUP BY workspace_id` correct for per-workspace true/false. Alternative `count_if(event_type='payment_failed')>0` valid (count_if exists in 467). Directly answers "does Trino have bool_or" (yes) and "at-least-one-match without counting" (bool_or). CLEAN.

## Q4 ★ — format DATE as "June 2026" (Postgres TO_CHAR equivalent) — 4.0 — LEAD correct, %B broken-secondary (2nd CONSECUTIVE)

Acc 3.75 / Clar 4.25 / App 4.0 / Comp 4.0.

LEAD `format_datetime(CAST(due_date AS timestamp), 'MMMM yyyy')` → 'June 2026' VERIFIED CORRECT (Joda MMMM=full month name 'June', yyyy=4-digit year; MMM=abbrev, MM=zero-padded number, lowercase mm=MINUTE — the mm gotcha is correctly called out; CAST optional, DATE→TIMESTAMP(0) coerces — fine). The deliverable is correct.

★ **BROKEN-SECONDARY DEFECT (2-in-2 recurrence):** ALTERNATIVE `date_format(due_date, '%B %Y')` claims "%B = full month name." **VERIFIED WRONG against Trino 467 functions/datetime.html: full month name is `%M`; `%b` = abbreviated month name; `%Y` = 4-digit year. `%B` is a C/strftime code and is NOT a listed Trino/MySQL date_format specifier.** Correct form is `date_format(CAST(due_date AS timestamp), '%M %Y')`. Additional sub-issue: `date_format` is documented as `date_format(timestamp, format)` — passing a bare DATE may need a CAST to timestamp (the LEAD casts; the alternative does not). Claiming both forms have "identical output" is FALSE — the %B alternative would not emit 'June'.

NOTE on whether %B errors or mis-outputs: I could NOT find in the docs an explicit statement of behavior for an unrecognized specifier (throw "Invalid format" vs pass-through literally). The specifier table lists %M and %b (and %Y), NOT %B — so the %M-vs-%B distinction is supported by the table's presence/absence, not by an explicit contrast note. **This is the 2nd CONSECUTIVE instance of the %B-for-full-month error (iter984 Q4 + iter985 Q4).**

★ **DISPOSITION DEFERRED TO ORCHESTRATOR PHASE 6:** I verified the dialect fact only (%M = full month name CORRECT; %B = WRONG / not a valid Trino specifier; %b = abbreviated). The orchestrator MUST grep resources/ to classify:
- (a) a resource CONTAINS `%B` for month-name → **RESOURCE DEFECT** (fix in place);
- (b) a resource teaches `%M` correctly + findably → **RESPONDER slip** (synthesis broken-secondary padding, maybe no fix);
- (c) NO resource covers date_format month-name codes → **findability gap** (candidate for a LIGHT additive note %M=full-month / %b=abbrev / %B=NOT-a-Trino-code).
Given this is now 2-in-2, a LIGHT defang is warranted IF (b) or (c); do NOT prescribe beyond verifying the fact.

---

## Scope notes

- ★ **Q2 aggregate-in-GROUP-BY did NOT recur** — LEAD + explanation rule both CORRECT and LEGAL 467; **iter983 aggregate-in-GROUP-BY slip CONFIRMED a ONE-OFF over 2 consecutive clean re-probes (iter984 + iter985)**.
- ★ **Q4 LEAD format_datetime correct; date_format `%B` should be `%M` — 2nd CONSECUTIVE broken-secondary recurrence (iter984 Q4 + iter985 Q4)**; classification (resource defect vs responder slip vs findability gap) **DEFERRED to orchestrator PHASE 6 resource grep**.
- Q1 / Q3 CLEAN.
- ALL OTHER TICS CLEAN: no QUALIFY-misuse / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn-or-rule (bool_or, count_if, format_datetime, date_format all real 467) / PARTITIONED-BY-foreign-DDL / mid-churn / missing-CTE-col (Q2 all cols projected+referenced) / JOIN-fan-out / ts-minus-ts / column-scope.

## Recommendation = DEFAULT NO-OP pending PHASE-6 grep on Q4 %M/%B

Margin +0.969 PASS; iter983 aggregate-in-GROUP-BY confirmed one-off. ONLY actionable item is the Q4 %B 2-in-2 broken-secondary — orchestrator grep resources/ to classify; if a resource teaches %M correctly+findably it's a responder synthesis-padding slip (re-probe-don't-churn); if no resource covers date_format month-name codes, a LIGHT additive note (%M=full-month / %b=abbrev / %B=NOT-a-Trino-code, cast DATE→timestamp for date_format) is the candidate fix. Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). NO resource edits this iteration. DO NOT bump training/state.json (already 985; passed=true preserved; final_iterations_remaining 0).
