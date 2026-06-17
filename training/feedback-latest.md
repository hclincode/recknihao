# iter1022 Judge Feedback

**OVERALL: 4.75 (76.0/16) — PASS** (margin +1.25; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions vs trino.io/docs/467 (functions/string.html starts_with/no-ends_with, functions/window.html rank/dense_rank, sql/select.html FETCH WITH TIES + multi-col GROUP BY) + WebSearch (DIVISION_BY_ZERO + NULLIF guard) — NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO + HMS) all 4 fit; no federation/auth angle.

---

## Per-question scores

### Q1 — percent change avg revenue starter→pro, guard zero denominator — 4.8125 CLEAN
`(pro_avg - starter_avg) * 100.0 / NULLIF(starter_avg, 0)`; per-plan averages pivoted via `MAX(CASE WHEN plan_type='pro'/'starter' THEN avg_rev END)` over a per-plan AVG subquery; `*100.0` forces decimal; NULLIF→NULL = undefined ratio not an error.
- VERIFIED: INTEGER/DECIMAL division-by-zero THROWS DIVISION_BY_ZERO in Trino 467 (WebSearch trinodb #19491 zero-safe-div = open feature request NOT implemented; drdroid runtime error) so the guard IS needed. NULLIF(x,0)→NULL propagates through `/` → NULL result, not error (correct). `*100.0` decimal-literal multiply forces DECIMAL output (correct). MAX(CASE...) pivot over AVG subquery is a valid one-row-per-plan→single-row layout.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

### Q2 — distinct users per event_type per country — 4.8125 CLEAN
`COUNT(DISTINCT user_id) ... GROUP BY event_type, country`; one row per (event_type, country) pair; distinct users within each group; de-bunks "needs subqueries."
- VERIFIED: multi-column GROUP BY documented (select.html, e.g. group by mktsegment, nationkey). COUNT(DISTINCT user_id) is standard single-arg distinct aggregation evaluated per group — works directly, one row per group. The responder's de-bunking ("not a limitation needing subqueries") is CORRECT, not an over-claim. No COUNT(DISTINCT a,b) multi-arg trap here (single arg).
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

### Q3 — leaderboard rank, ties share rank, NO gaps after — 4.71875 CLEAN
`DENSE_RANK() OVER (ORDER BY tickets_closed DESC)` → ties same rank, no gaps (1,1,2); contrasts RANK() gaps (1,1,3); aside `FETCH FIRST N ROWS WITH TIES`.
- VERIFIED window.html verbatim: rank() = "tie values in the ordering will produce gaps in the sequence"; dense_rank() = "tie values do not produce gaps in the sequence." DENSE_RANK is the correct choice for the ask. FETCH FIRST N ROWS WITH TIES is a REAL Trino clause (select.html: "result set consists of the same set of leading rows and all of the rows in the same peer group as the last of them ('ties')"; requires ORDER BY) — the aside is accurate.
- Acc 5 / Comp 4.75 / Clar 4.625 / App 4.75

### Q4 (KEY) — filter paths starting with '/blog/': built-in or LIKE — 4.8125 CLEAN
`starts_with(path, '/blog/')` → boolean (HAS it; cleaner than `LIKE '/blog/%'`); Trino does NOT have `ends_with` (use `LIKE '%.csv'` for suffixes); '/blogroll' does NOT match '/blog/'.
- VERIFIED BOTH DIRECTIONS vs functions/string.html:
  - (a) starts_with EXISTS — verbatim signature `starts_with(string, substring) → boolean`, "Tests whether substring is a prefix of string." Matches the responder's signature exactly.
  - (b) ends_with ABSENT — not present on string.html function list; LIKE '%suffix' is the correct suffix workaround.
- The "function existence goes both ways" check resolves fully in the responder's favor. Confirms the starts_with/ends_with memory card (foreign-looking funcs ARE in Trino while a paired sibling may genuinely be absent). No imported-prior error.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

---

## TICS scan
`::` ABSENT all 4. Clean: no QUALIFY / no false-semi-join / no fabricated fn (starts_with/DENSE_RANK/RANK/COUNT-DISTINCT/NULLIF all real & verified; ends_with correctly flagged ABSENT, right direction) / no regex-backslash / no INTERVAL-quarter-week / no OFFSET-before-LIMIT / no generate_subscripts / no broken-secondary / no COUNT(DISTINCT a,b) multi-arg.

## Defects / notes
NONE. All four answers fully correct and verified both directions. No parse-error defects, no semantic slips, no broken-secondary appended alternative this iter.

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.25; all 4 clean & verified both directions; KEY Q4 starts_with-EXISTS + ends_with-ABSENT resolved in responder's favor; no findable gap, no resource defect, no 2-in-2 recurrence. NO resource edit; NO FIX-A; NO git commit.

Re-probe (monitor only): (a) prefix/suffix match — starts_with-exists + ends_with-absent (LIKE '%x') durable; (b) ranking — DENSE_RANK no-gaps vs RANK gaps + FETCH WITH TIES; (c) percent-change with NULLIF-guarded denominator (INTEGER/DECIMAL div-by-zero THROWS); (d) COUNT(DISTINCT col) + multi-col GROUP BY directly (watch COUNT(DISTINCT a,b) multi-arg parse-error trap if combinations asked). Federation r22 §13.x hard-locked NOT probed (4.49944/310). MUST NOT bump state.json (already 1022; orchestrator commits).
