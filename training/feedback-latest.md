# iter831 Judge Feedback — LIGHT FIX-A verification (iter830 Q2 grouping-granularity)

**Overall: 4.97 STRONG PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 4.875)

PASS threshold = overall avg >= 3.5 (overall governs, no per-Q veto). All dialect claims docs-verified vs trino.io/docs/467 datetime.html / select.html / string.html + WebSearch 2026-06-09. PIN Trino 467.

## Per-question scores

### Q1 — monthly revenue report, ONE row per month, 'June 2026' label, SUM amount — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
**FIX LANDED.** Responder now groups to exactly ONE row per month via `GROUP BY date_trunc('month', order_date)` (NOT the iter830 raw-DATE per-day mistake), with correct label `format_datetime(CAST(date_trunc('month', order_date) AS timestamp), 'MMMM yyyy')` and `ORDER BY date_trunc('month', order_date)`. Verified: `date_trunc('month', x)` preserves input type (DATE->DATE) and returns first-of-month; `format_datetime` requires a timestamp so the DATE arg MUST be CAST (responder did this and explained why); `'MMMM yyyy'` = full month name + 4-digit year; GROUP BY accepts expression/ordinal but NOT a SELECT alias (responder explicitly said "GROUP BY the expression itself (not the formatted label)"). The iter830 Q2 grouping-granularity FIX LANDED / CLOSED — needs 1 more angle (e.g. GROUP BY 1 ordinal phrasing, or month+year-number variant) to bulletproof.

### Q2 — control NULL placement in ORDER BY — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
CLEAN. Verified select.html exact wording: "The default null ordering is NULLS LAST, regardless of the ordering direction." Responder correctly stated default = NULLS LAST irrespective of ASC/DESC, gave the explicit override `NULLS FIRST`, and added a genuinely useful Postgres-contrast (Postgres orders NULLs by "largest end" per direction) plus the "always specify explicitly" predictability advice. Syntax `ORDER BY expr [ASC|DESC] [NULLS {FIRST|LAST}]` confirmed.

### Q3 — filter NULL / empty string / whitespace-only — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
CLEAN. `WHERE notes IS NOT NULL AND notes <> '' AND trim(notes) <> ''` is correct and complete. Verified string.html: `trim(string)` 1-arg removes leading/trailing whitespace; NO 2-arg `ltrim/rtrim(s,chars)` (whitespace-only single-arg) — responder's note is correct; `trim(LEADING 'chars' FROM s)` strips a character SET (doc example `trim(TRAILING 'ER' FROM upper('worker'))` -> 'WORK' confirms set-strip); responder's `trim(LEADING '0' FROM '000042')` leading-zero example is valid. All known dialect facts stated correctly.

### Q4 — top 10 by spend — 4.875 (Acc 5 / Comp 5 / Clar 4.5 / Act 5)
CLEAN. `ORDER BY total_spend DESC LIMIT 10` correct; verified LIMIT evaluated after ORDER BY (trims final sorted result). The Iceberg scan-cost caveat is accurate (LIMIT after a global sort does not reduce partition reads). ROW_NUMBER() alt is a valid more-control option. Negligible clarity ding only: the "(top 10 users plus their orders)" parenthetical is slightly tangential to a simple top-10 ask — not wrong, just a touch of extra scope.

## Verdict
All 4 verified accurate vs Trino 467. No defect, no fabrication, no dialect error, no prod-env conflict (pure SQL). Q1 confirms the iter830 grouping-granularity FIX LANDED.

## iter832 directive
**DEFAULT NO-OP / durability sweep** (teacher ZERO resource edits) — all clean, no defect surfaced.
- Re-probe the month-label grouping fix from a 2nd angle to bulletproof: `GROUP BY 1` ordinal phrasing, or a `MMM yyyy` / `MM-yyyy` variant, or month-name with a HAVING/total filter.
- 3 fresh adjacent durability angles: NULLS FIRST/LAST combined with multi-column ORDER BY; empty-string-vs-NULL with COALESCE in SELECT; LIMIT + OFFSET pagination (verify OFFSET-then-LIMIT eval order).
- PRESERVE: iter831 month-label grouping-granularity card (date_trunc('month',x)->one-row-per-month + CAST-to-timestamp + 'MMMM yyyy'/'MMM'/'MM' + Joda lowercase-mm=MINUTE gotcha); iter827 boolean-aggregate-NULL READ-THIS-FIRST block + COALESCE(bool_or,false) canonical; iter824/823 split_part GROUP-BY-1 + §8 GROUP-BY-alias asymmetry; trim/ltrim/rtrim whitespace-only + trim(LEADING/TRAILING 'chars' FROM s) character-set card; default-NULLS-LAST-regardless-of-direction; full iter534-830 pin inventory.
- NO federation edits (r22 §13.x ZERO edits, federation row stays 4.49944/310).
- iter832 is NOT a FIX-A (no defect).

DO NOT bump training/state.json (already 831).
