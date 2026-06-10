# Judge Feedback — iter933

**Overall: 5.00 STRONG PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 20.00/4; OVERALL AVERAGE governs, no per-Q veto)

**Verdict on iter933 LIGHT FIX-A: LANDED.** The responder explicitly stated the 6-qualifier rule (YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only — no QUARTER/WEEK) AND offered both correct add-a-quarter forms (`date_add('quarter', 1, current_date)` AND `date_trunc('quarter', current_date) + INTERVAL '3' MONTH`). No instance of the invalid `INTERVAL '1' QUARTER` appeared anywhere in the answer. The exact iter932 Q4 findable gap is closed.

**Card-correctness verdict on the new ADD-A-QUARTER/ADD-A-WEEK card (r07 ~L3481–3500): CORRECT.** All dialect claims in the new card verified against trino.io/docs/467/functions/datetime.html + git-tag 467 grammar discussion (Trino issue #17357 confirms WEEK is not a valid INTERVAL qualifier; no QUARTER qualifier either). The TWO-SURFACES trap paragraph correctly distinguishes interval-literal grammar (excludes QUARTER/WEEK) from date_add/date_diff/date_trunc UNIT strings (include 'quarter' and 'week'). Adjacent WHICH-QUARTER/WEEK-OF-YEAR card at L3469–3479 reads unchanged and uncorrupted by the new neighbor — no New-Card-Over-Attracts-Adjacent regression detected.

## Verification (multi-source, Trino 467 PINNED)

All dialect claims verified 2026-06-10 via WebFetch trino.io/docs/467/functions/{datetime,aggregate,window}.html + WebSearch GitHub issue #17357 (WEEK interval support request, still open) + git-tag context:

- INTERVAL qualifiers Trino 467 = YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only (no QUARTER, no WEEK).
- date_add('quarter', n, x) / date_trunc('quarter', x) / date_diff('quarter', a, b) all VALID — 'quarter' and 'week' are valid UNIT strings for those functions.
- date_diff(unit, ts1, ts2) → bigint (NOT an INTERVAL) — comparing to a plain integer is correct; comparing to INTERVAL would type-error.
- ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...) standard 467 window fn; rn=1 idiom is the canonical per-group-top-1 (DISTINCT ON does not exist in Trino — confirmed Trino Discussion #17261; ROW_NUMBER() filter is the documented workaround).
- FILTER (WHERE ...) clause: "supported for all aggregate functions" in 467 (functions/aggregate.html).
- 100.0 * SUM(...) / COUNT(*) — 100.0 is a decimal literal, promotes the integer SUM result to decimal/double avoiding integer-division truncation. Standard idiom.

## Per-question

**Q1 — INTERVAL '1' QUARTER / next quarter renewals (FIX-A re-probe).** **5.00 CLEAN — FIX-A LANDED.** Responder correctly: (1) identified parse error cause (Trino 467 supports only 6 interval qualifiers — YEAR/MONTH/DAY/HOUR/MINUTE/SECOND); (2) gave BOTH correct add-a-quarter forms (`date_add('quarter', 1, current_date)` AND `date_trunc('quarter', current_date) + INTERVAL '3' MONTH`); (3) wrote a fully correct half-open next-quarter range:
```
WHERE renewed_at >= date_add('quarter', 1, date_trunc('quarter', current_date))
  AND renewed_at <  date_add('quarter', 2, date_trunc('quarter', current_date))
```
which is exactly `[start-of-next-quarter, start-of-quarter-after-that)` — semantically correct and partition-prunable; (4) noted negatives work for prior-quarter shifts. The exact iter932 findable gap is closed and the new card landed without corruption.

**Q2 — Highest-paid per department.** **5.00 CLEAN.** ROW_NUMBER() OVER (PARTITION BY department_id ORDER BY salary DESC) + outer `WHERE rn=1` is the canonical Trino 467 per-group-top-1 idiom (verified window.html). Correctly noted DISTINCT ON is absent in Trino (verified Trino Discussion #17261). Tie-handling guidance (add secondary ORDER BY) appropriate. `max_by(name, salary)` is a valid alternative but ROW_NUMBER form is fully correct and clearer for multi-column projection.

**Q3 — SLA compliance percentage.** **5.00 CLEAN.** `ROUND(100.0 * SUM(CASE WHEN resolved_at <= sla_deadline THEN 1 ELSE 0 END) / COUNT(*), 2)` is correct — 100.0 promotes integer division to decimal (avoiding the silent-zero trap). FILTER alternative `COUNT(*) FILTER (WHERE resolved_at <= sla_deadline) / COUNT(*)` is dialect-valid (aggregate.html FILTER supported for all aggregate functions). resolved_at <= sla_deadline timestamp comparison valid. Note: the FILTER alt as written has integer/integer division so it would also need `* 1.0` or `* 100.0` to avoid truncation — the responder didn't explicitly note this on the alt form (tiny clarity-only nit, not a defect since the lead is correct and the alt is presented as a sketch).

**Q4 — Average session duration by platform.** **5.00 CLEAN.** `AVG(date_diff('minute', started_at, ended_at)) GROUP BY platform` correct shape. Units list correct (second/minute/hour/day/week/month/quarter/year all valid date_diff units — directly consistent with Q1's two-surfaces rule that QUARTER/WEEK ARE valid UNIT strings even though they are NOT INTERVAL qualifiers). bigint return type is accurate (verified datetime.html date_diff signature → bigint). The "don't compare date_diff result to INTERVAL" warning is correct and useful — date_diff returns bigint, so `WHERE date_diff('minute', a, b) > INTERVAL '60' MINUTE` would type-error (compare to plain integer 60 instead).

## Defect scoping

NO DEFECT. No fabrication, no wrong signature, no crossed-family confusion, no findability slip, no GROUP-BY-muddle, no prod-env conflict. iter932 Q4 findable gap CLOSED by iter933 FIX-A; pure SQL on-prem Trino 467+Iceberg+MinIO+HMS+JWT/OPA unaffected. Verify-in-both-directions discipline held — checked the suspect "INTERVAL '1' QUARTER invalid" claim against grammar and the "'quarter' valid as date_diff unit" claim against datetime.html; both confirmed.

## Carry-forward for next sweep

- iter934 = DEFAULT NO-OP / durability-breadth. The interval-qualifier vs date_add-unit two-surfaces rule was just bolted in with a fresh canonical; cool-down on QUARTER/WEEK family for a couple of sweeps before re-probing.
- Optional fresh adjacents that exercise the new card without churning it: `INTERVAL '1' WEEK` direct probe (mirror sibling of the QUARTER question — same fix shape `INTERVAL '7' DAY` / `date_add('week', ...)`); `date_diff('quarter', a, b)` unit string probe; mixed `date_add('quarter', 1, date_trunc('quarter', ...))` next-Q range probe. Each tests the two-surfaces trap from a different angle.
- Federation row still 4.49944 / 310 (thinnest passing row, long un-retested) — CONSIDER probing federation in iter934 or 935; federation card-set still hard-locked, only retest with bulletproofed angles per the standing constraint.
- PRESERVE full iter534-932 pin inventory.
- DO NOT bump training/state.json (already 933; passed=true preserved).
