# Judge Feedback — iter1020

**OVERALL: 4.65625 (74.5/16) — PASS** (threshold 3.5; margin +1.15625; OVERALL AVERAGE governs, no per-Q veto).

Verified BOTH directions vs trino.io/docs/467 (functions/regexp.html lambda+capture-groups, functions/string.html no-initcap, functions/datetime.html date_trunc) + WebSearch (regexp_extract first-match semantics, initcap absence). NOT against resources/. Production stack (Trino 467 + Iceberg + MinIO on-prem) — all 4 questions fit; no federation/auth angle (r22 §13.x hard-locked, NOT probed; federation row stays 4.49944/310).

---

## Per-question scores

### Q1 — date_trunc monthly buckets — 4.8125 CLEAN
`date_trunc('month', created_at) AS month_bucket ... GROUP BY date_trunc('month', created_at)`.
- VERIFIED (datetime.html): `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00')` → `2022-10-01 00:00:00.000`. Responder's `2025-03-14 09:32:17 → 2025-03-01 00:00:00` is exactly right.
- Correctly notes the result is a **timestamp** (month-start at midnight), not a date/string — useful for downstream join/sort.
- GROUP BY repeats the full expression (alias not resolvable in GROUP BY) — correct.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

### Q2 (KEY) — case normalization / title case — 4.8125 CLEAN
`upper()`/`lower()` for consistent case; for title case correctly states **Trino has no built-in `initcap()`** and offers `regexp_replace(lower(country_name), '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))`.
- VERIFIED (a) **no initcap** in Trino 467 — absent from string.html / list.html; users build workarounds. CONFIRMED.
- VERIFIED (b) 3-arg lambda `regexp_replace(string, pattern, function)` EXISTS; lambda receives capture groups as a 1-indexed array (x[1]=group 1, x[2]=group 2); no group for whole match. The docs even ship the near-identical example `regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` → `'New York'`. CONFIRMED.
- VERIFIED (c) **single backslash** `\w` in the SQL string literal is correct (engine-level single backslash per the regex pin; backslash is literal in SQL string literals, no escape processing). CONFIRMED — NOT the doubled form.
- VERDICT: **fully correct, no fabrication.** The no-initcap statement is right AND the lambda-regexp_replace title-case idiom is valid Trino 467 and matches the official docs example.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

### Q3 (KEY) — money-string → DECIMAL — 4.40625 (BROKEN-SECONDARY DEFECT)
- PRIMARY `CAST(replace(replace(total_amount,'$',''),',','') AS DECIMAL(10,2))`: `'$1,234.50'` → strip `$` → `'1,234.50'` → strip `,` → `'1234.50'` → CAST → `1234.50`. **CORRECT** (the ask, answered correctly).
- SECONDARY ("alternative if messy") `CAST(regexp_extract(total_amount, '[0-9]+\.[0-9]+') AS DECIMAL(10,2))`: **BUGGY for comma-thousands.** `regexp_extract` returns the FIRST match (verified regexp.html: `regexp_extract('1a 2b 14m', '\d+')` → `'1'`). Against raw `'$1,234.50'`, the comma breaks the digit run, so `[0-9]+\.[0-9]+` (needs contiguous digits-dot-digits) first matches **`234.50`**, NOT `1234.50` → silently drops the thousands part → wrong value (234.50 instead of 1234.50).
- CORRECT regex approach = `CAST(regexp_replace(total_amount, '[^0-9.]', '') AS DECIMAL(10,2))` (strip ALL non-digit/non-dot, then CAST) → `1234.50`.
- Acc 3.75 / Comp 4.5 / Clar 4.5 / App 4.5
- **Classification: broken-secondary one-off, NOT a findable resource gap.** The PRIMARY (the actual ask) is correct; the defect is in an appended "alternative if messy" example — same responder-padding family as iter936/943/948/950/954/1013/1019 (correct primary + invalid "for completeness" variant). No single resource fix for responder padding. Per-instance; do NOT churn.

### Q4 — CASE price bucketing — 4.75 CLEAN
`CASE WHEN monthly_price<10 THEN 'budget' WHEN monthly_price>=10 AND monthly_price<=50 THEN 'standard' WHEN monthly_price>50 THEN 'premium' ELSE 'unknown' END AS price_tier`.
- Boundaries correct and non-overlapping: <10 budget, [10,50] standard, >50 premium, ELSE unknown (catches NULL / negative). Matches the budget(<$10)/standard($10-$50)/premium(>$50) spec.
- Correctly notes **GROUP BY must repeat the full CASE expression** — the SELECT alias `price_tier` is NOT resolvable in GROUP BY in Trino; suggests a CTE to avoid duplication. VERIFIED correct (GROUP BY does not see output aliases; pre-compute in a CTE/subquery is the idiom).
- Acc 5 / Comp 4.5 / Clar 4.75 / App 4.75

---

## TICS scan
`::` shorthand ABSENT all 4 (good). No QUALIFY, no false semi-join, no fabricated functions (initcap correctly flagged ABSENT; regexp_replace-lambda/replace/date_trunc/regexp_extract all real & verified), no regex-double-backslash (single `\w`/`\.` correct), no INTERVAL quarter/week, no OFFSET-before-LIMIT, no generate_subscripts. ONE TIC = Q3 broken-secondary (regexp_extract comma bug).

## Recommendation = DEFAULT NO-OP
Margin +1.15625; 3/4 clean incl BOTH KEY checks (Q2 no-initcap+lambda fully correct; Q3 primary correct). Q3 defect is FIRST-occurrence broken-secondary in an appended alternative — per-instance responder padding, NOT a findable resource gap, NOT 2-in-2. NO resource edit; NO FIX-A; NO git commit.

Re-probe (monitor only):
- (a) money/string→DECIMAL cleaning — watch the regexp_extract-on-comma-thousands relapse; if it recurs 2-in-2 → LIGHT findability nudge (canonical = `regexp_replace(s,'[^0-9.]','')` then CAST; regexp_extract returns FIRST contiguous match and DROPS thousands across a comma).
- (b) title-case — no-initcap + lambda regexp_replace `(\w)(\w*)` idiom holds.
- (c) date_trunc month-bucket returns month-start timestamp.
- (d) CASE bucketing + GROUP-BY-must-repeat-CASE-expr (alias not resolvable).

Federation r22 §13.x hard-locked NOT probed (4.49944/310). MUST NOT bump state.json (already 1020; orchestrator commits).
