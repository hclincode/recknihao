# Judge Feedback — iter901 (NO-OP durability sweep)

**Phase**: extended. **Overall**: 5.00 STRONG PASS (per-Q 5.00 / 5.00 / 5.00 / 5.00 = 20.00/4 = 5.00; margin +1.50; overall average governs, no per-Q veto). **Verdict: DEFAULT NO-OP — all 4 dialect-clean, ZERO teacher edits.** Federation NOT probed (4.49944/310 row UNCHANGED). DO NOT bump state.json.

All dialect facts VERIFIED vs trino.io/docs/467 (conversion/window/math/datetime/reserved .html) + git-tag 467 source (DoubleOperators.java) via WebFetch/WebSearch 2026-06-10. iter882 verify-first applied to the one structurally-suspicious claim (Q1 CAST-rounds) — VERIFIED CORRECT before judgment, NOT flagged.

---

## Q1 — flag whole-dollar `order_total` (50.00, no cents) — 5.00

**A1**: `WHERE order_total = CAST(order_total AS INTEGER)` [noted CAST rounds half-up: 50.50→51, 50.00→50] OR `WHERE order_total = FLOOR(order_total)`.

CORRECT on both the rounding claim and the logic.

- **CAST-rounds claim VERIFIED CORRECT (the critical check).** trino.io/docs/467 conversion.html does NOT document the rounding mode, and a stray web blog claimed "truncate" — but the git-tag 467 source is dispositive: `io/trino/type/DoubleOperators.java` `castToInteger` returns `toIntExact((long) MathFunctions.round(value))` (likewise castToSmallint/castToTinyint use `MathFunctions.round`). `MathFunctions.round` = round-half-up. So `CAST(50.50 AS INTEGER)=51`, `CAST(47.89 AS INTEGER)=48`, `CAST(50.00 AS INTEGER)=50`. Truncation-toward-zero is `truncate(x)` (math.html: "rounded to integer by dropping digits after decimal point"), a different function. The responder's claim is right; the blog prose was wrong. (Consistent with the pinned reference_trino_cast_to_integer_rounds memory — git-tag source settles dialect disputes, not blog prose.)
- **LOGIC holds REGARDLESS of round-vs-truncate.** `order_total = CAST(order_total AS INTEGER)` is TRUE iff order_total is a whole number: a decimal with a nonzero fractional part can never equal ANY integer (50.50 ≠ 51 and 50.50 ≠ 50), so the equality is only satisfied when the fraction is zero. The test is correct whether CAST rounds or truncates.
- **FLOOR form unambiguously correct**: `order_total = FLOOR(order_total)` is TRUE iff fractional part is zero. Clean, mode-independent, the more defensively obvious form.

NO defect. Q1 = 5.0 exactly as the run-prompt anticipated.

## Q2 — average order value per category EXCLUDING the single most expensive per category — 5.00

**A2**: CTE with `ROW_NUMBER() OVER (PARTITION BY category ORDER BY order_total DESC) AS rank`, then `SELECT category, ROUND(AVG(order_total),2) FROM ranked WHERE rank > 1 GROUP BY category`.

CORRECT.

- ROW_NUMBER (window.html) is "a unique, sequential number for each row… starting with one" — it assigns distinct numbers even on ties, so `rank = 1` picks exactly ONE row (the single most-expensive; on a tie one is chosen arbitrarily but still exactly one), and `WHERE rank > 1` excludes exactly that one per category. Matches "EXCLUDING the single most expensive order."
- `WHERE rank > 1` filters a REAL materialized CTE column (legal) — NOT a same-level SELECT-alias-in-WHERE (correctly avoids that trap). Window function correctly projected in the CTE first (can't go in WHERE / no QUALIFY in 467).
- `rank` as a bare unquoted column alias is VALID: RANK is NOT in the Trino 467 reserved-keywords list (reserved.html) — an unquoted `rank` identifier is fine.
- `ROUND(AVG(order_total),2)` + `GROUP BY category` over the surviving rows = correct average of the rest.

NO defect. Q2 = 5.0.

## Q3 — yes/no whether `signup_date` and `first_order_date` are in the same calendar month — 5.00

**A3**: `CASE WHEN date_trunc('month', signup_date) = date_trunc('month', first_order_date) THEN 'yes' ELSE 'no' END`; plus the `EXTRACT(YEAR)=… AND EXTRACT(MONTH)=…` equivalent.

CORRECT — both forms.

- date_trunc('month', date) (datetime.html) truncates to the first day of that month; two dates in the same calendar month truncate to the SAME value, so equality returns 'yes'. Crucially year-aware (Jan-2025 ≠ Jan-2026), as a true same-calendar-month test requires.
- EXTRACT(YEAR FROM …) and EXTRACT(MONTH FROM …) are valid for DATE types (datetime.html: extract fields "support all date and time types"), and comparing both year AND month equal is the correct decomposed equivalent.

NO defect. Q3 = 5.0.

## Q4 — count orders sharing a `created_timestamp` with ≥1 other order (collision) — 5.00

**A4**: CTE `tc AS (SELECT order_id, created_timestamp, COUNT(*) OVER (PARTITION BY created_timestamp) AS collision_count FROM orders)`, then `SELECT COUNT(*) FROM tc WHERE collision_count > 1`.

CORRECT.

- `COUNT(*) OVER (PARTITION BY created_timestamp)` (all aggregates usable as window fns via OVER, window.html) broadcasts the per-timestamp row count onto every row. A row whose timestamp is unique gets `collision_count = 1`; a row sharing its timestamp with ≥1 other gets `> 1`.
- Filtering `collision_count > 1` in the OUTER query is legal — it is a REAL CTE column (window fns can't go in WHERE; correctly projected first).
- `COUNT(*)` over the surviving rows = the number of orders that are part of a same-timestamp collision (each such order counted once). Matches "≥1 other order at the same timestamp." Valid in 467.

NO defect. Q4 = 5.0.

---

## Findability / defect scan — NONE

No findable-but-missing gap and no dialect defect surfaced. The single structurally-suspicious claim (Q1 CAST rounds half-up) was VERIFIED CORRECT against git-tag 467 DoubleOperators.java BEFORE judgment — NOT flagged (iter882 lesson honored; the contrary web-blog "truncate" claim was the wrong source).

**iter902 directive: DEFAULT NO-OP. ZERO teacher edits.**
- Do NOT add any "wrong" card for Q1–Q4.
- Do NOT mark the Q1 `order_total = CAST(order_total AS INTEGER)` whole-number test wrong — it is correct, AND the responder's "CAST rounds half-up (50.50→51)" claim is correct (git-tag 467 source). Do NOT churn the CAST-rounds / FLOOR whole-dollar content.
- Do NOT churn the ROW_NUMBER-exclude-top-N (rank>1 in CTE), date_trunc/EXTRACT same-calendar-month, or COUNT(*) OVER collision-detection cards.
- `rank` as a bare alias is valid (not reserved) — do NOT add a defang.
- Re-probe fresh adjacents next sweep. Federation (4.49944/310) is the only un-passed row — bulletproofed angles only.
- Do NOT touch any iter534–900 pin. PIN Trino 467. NO federation edits.
- DO NOT bump training/state.json (already passed; overall 5.00 PASS holds).
