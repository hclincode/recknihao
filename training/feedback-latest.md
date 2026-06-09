# Judge Feedback — iter875 (EXTENDED PHASE)

**Overall: 4.06 PASS** (per-Q 5.00 / 5.00 / 1.81 / 4.44 = 16.25/4 = 4.0625; margin +0.56; overall avg governs, no per-Q veto)
**Federation NOT probed** (4.49944/310 row UNCHANGED).
**Verdict drivers:** (a) iter875 Q2 reconciliation FIX-A **LANDED** — Q1 now leads with FULL OUTER JOIN, not an unparenthesized EXCEPT/UNION chain. (c) Trino **DOES NOT** allow a window function nested inside another window function's PARTITION BY — Q3's final query is **INVALID Trino** (NESTED_WINDOW), and the first draft has a double-GROUP-BY syntax error. **iter876 = FIX-A (Q3 gaps-and-islands / streak).**

All dialect facts VERIFIED vs trino.io/docs/467 (functions/window.html, sql/select.html, functions/aggregate.html) + **git-tag 467 source** (sql/analyzer/ExpressionAnalyzer.java) + WebSearch, 2026-06-10. Trino 467 PINNED.

---

## Q1 — Reconcile two tables, list invoices in one but not the other + WHICH side missing — 5.00

Responder answer:
```
SELECT COALESCE(b.invoice_id, p.invoice_id) AS invoice_id,
       CASE WHEN b.invoice_id IS NOT NULL AND p.invoice_id IS NULL THEN 'Missing in payments'
            WHEN b.invoice_id IS NULL AND p.invoice_id IS NOT NULL THEN 'Missing in billing' END AS mismatch_type
FROM billing_records b
FULL OUTER JOIN payments_received p ON b.invoice_id = p.invoice_id
WHERE b.invoice_id IS NULL OR p.invoice_id IS NULL
```

- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00**
- **iter875 FIX-A LANDED.** iter874 Q2 used an unparenthesized `A EXCEPT B UNION ALL C EXCEPT D` chain that mis-grouped. The responder now LEADS with the one-pass `FULL OUTER JOIN ... WHERE a.key IS NULL OR b.key IS NULL` canonical + COALESCE key + CASE side-label — exactly the form the iter875 r23 §3.1F card added. **NO regression to the unparenthesized chain. No iter876 escalation on this axis.**
- Correctness: FULL OUTER JOIN keeps both unmatched sides; the WHERE filters to anti-join rows (present in only one side); COALESCE surfaces whichever key exists; CASE correctly labels the missing side. VERIFIED vs trino.io/docs/467 sql/select.html (FULL JOIN semantics; set-op precedence re-confirmed: "INTERSECT binds more tightly than EXCEPT and UNION", "processed left to right").

## Q2 — Top 3 best-selling products per category (single query) — 5.00

```
SELECT category, product_name, total_sales
FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY category ORDER BY total_sales DESC) AS rank_in_category FROM products)
WHERE rank_in_category <= 3
ORDER BY category, rank_in_category
```

- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00**
- Canonical top-N-per-group: ROW_NUMBER() in a subquery + outer `WHERE rank <= N`. Correct — window functions cannot go in WHERE and Trino 467 has no QUALIFY, so the subquery/CTE layer is required. VERIFIED vs trino.io/docs/467 functions/window.html (row_number "unique sequential number for each row starting with one"). Tie nuance (ROW_NUMBER one arbitrary winner vs RANK keeps ties) = completeness nuance, not dinged.

## Q3 — Each user's longest unbroken streak of consecutive active days (gaps-and-islands) — 1.81 **DEFECT**

FIRST draft ended in a query with **TWO `GROUP BY` clauses** (`... GROUP BY user_id, streak_id GROUP BY user_id`); responder said "Wait, let me simplify," then a SECOND "simplified" version:
```
streaks AS (
  SELECT user_id,
         SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY active_date) AS streak_id,
         COUNT(*) OVER (PARTITION BY user_id, SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY active_date)) AS streak_length
  FROM events_with_gap)
SELECT user_id, MAX(streak_length) AS longest_streak_days FROM streaks GROUP BY user_id;
```

- **Accuracy 1.5 / Completeness 2.5 / Clarity 1.75 / Actionability 1.5 = 1.8125**
- **(a) First draft = SYNTAX ERROR.** Two `GROUP BY` clauses on one query body is invalid SQL — Trino's parser rejects it. Shipping a parse-error draft (even with a "let me simplify" retraction) is a correctness failure; a beginner may copy it.
- **(b) Final "simplified" query = INVALID Trino (NESTED_WINDOW).** It nests a window function `SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY active_date)` **inside another window function's PARTITION BY**: `COUNT(*) OVER (PARTITION BY user_id, SUM(...) OVER (...))`. **Trino does NOT allow this.**
  - **DISPOSITIVE SOURCE (git-tag 467):** `core/trino-main/.../sql/analyzer/ExpressionAnalyzer.java` throws in `analyzeWindow` when `extractWindowExpressions` finds nested window expressions in PARTITION BY / ORDER BY / frame, with the exact message **"Cannot nest window functions or row pattern measures inside window specification"** (NESTED_WINDOW). Confirmed via WebSearch + the analyzer source at tag 467. trino.io/docs/467/functions/window.html is silent on the restriction, so the source is authoritative.
- **APPROACH correct, SQL not.** The gaps-and-islands recipe (LAG gap-flag → running-SUM island id → count per island → MAX per user) is the right idea, but the correct Trino form needs **THREE separate layers**: (1) gap flag via LAG; (2) `streak_id = SUM(flag) OVER (PARTITION BY user_id ORDER BY active_date)` computed in its OWN CTE/subquery; (3) a LATER layer doing `GROUP BY user_id, streak_id` to COUNT each island, then `MAX(...) GROUP BY user_id`. You cannot fuse layers (2) and (3) by putting the running-SUM window inside a COUNT-window PARTITION BY.
- **DIAGNOSIS: resource gap (no correct streak / gaps-and-islands card), compounded by a synthesis slip (double-GROUP-BY draft).** A structural multi-layer pattern the responder cannot reliably synthesize without a leading canonical. iter876 must ADD a correct 3-layer streak card.

## Q4 — Category revenue + its % of grand total (no per-row subquery) — 4.44

```
SUM(amount) AS total_revenue,
ROUND(100.0 * SUM(amount) / SUM(SUM(amount)) OVER (), 2) AS pct_of_grand_total
... GROUP BY category
```
plus a detail-row variant `100.0 * amount / SUM(amount) OVER ()`.

- **Accuracy 5 / Completeness 4 / Clarity 4.75 / Actionability 4 = 4.4375**
- `SUM(SUM(amount)) OVER ()` is valid Trino: inner SUM aggregates per category (GROUP BY), the empty-OVER window sums across all grouped rows = grand total. This is NOT a nested window function (the inner SUM is a plain aggregate, not a window fn), so it does NOT hit NESTED_WINDOW. `100.0 *` forces float division. VERIFIED vs trino.io/docs/467 sql/select.html + aggregate.html (aggregates usable as window fns via OVER) + prior iter868/872 verification. **Redundant with iter868/872 percent-of-total — not a defect.** Minor completeness/clarity ding: no one-line note on WHY the doubled SUM is legal (a contrast with Q3's illegal window-in-window would be instructive).

---

## iter876 RECOMMENDATION — **FIX-A (Q3 ONLY)**

Add / verify a correct **3-layer gaps-and-islands streak** card ("longest run of consecutive active days per user"), placed where streak/consecutive-days keywords land (r07 analytical-query-patterns, near the LAG/sessionization cards):
1. **Layer 1 (CTE):** gap flag — `CASE WHEN LAG(active_date) OVER (PARTITION BY user_id ORDER BY active_date) IS NULL OR date_diff('day', LAG(active_date) OVER (PARTITION BY user_id ORDER BY active_date), active_date) > 1 THEN 1 ELSE 0 END AS is_new_streak`.
2. **Layer 2 (CTE):** `SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY active_date) AS streak_id` — **in its OWN layer**, from layer 1's flag column (a plain column, NOT window-in-window).
3. **Layer 3:** `SELECT user_id, MAX(streak_len) FROM (SELECT user_id, streak_id, COUNT(*) AS streak_len FROM layer2 GROUP BY user_id, streak_id) GROUP BY user_id`.

**DEFANG (own un-copyable FENCED line, pipe-escape-safe):** the nested-window form `COUNT(*) OVER (PARTITION BY user_id, SUM(...) OVER (...))` — throws Trino NESTED_WINDOW "Cannot nest window functions ... inside window specification"; AND the double-`GROUP BY` single-query form (syntax error). State the RULE: a window function CANNOT appear inside another window function's OVER/PARTITION BY/ORDER BY — compute each window in a separate prior CTE/subquery layer, then aggregate. Keyword anchors: longest streak, consecutive active days, gaps and islands, unbroken run, streak length, consecutive-day run, island id, sessionization by date gap.

**HOLD all iter534-874 locks.** Do NOT touch the iter875 reconciliation card (Q1 LANDED clean), iter872 DATE-coercion cards, or the percent-of-total/`SUM(SUM()) OVER ()` cards (Q2/Q4 correct). PIN 467. **NO federation edits.** **DO NOT bump training/state.json** (judge must not bump).
