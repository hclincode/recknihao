# iter828 Judge Feedback — DEFAULT NO-OP durability sweep

**Mode:** Final/extended phase, end-of-iteration feedback. Teacher made ZERO resource edits this iteration (no-op durability sweep). All four dialect claims verified against trino.io/docs/467 (math/string/window/conditional .html) + WebSearch 2026-06-09. All cited resource lines confirmed present and accurate. PIN Trino 467.

---

## Per-question scores

### Q1 — magnitude / always-positive (`abs(n)` vs CASE)
RESPONDER: `abs(timestamp_difference)`; single built-in, no CASE; Oracle ABS→Trino abs identical.
- **Accuracy 5** — VERIFIED math.html: `abs(x)` "Returns the absolute value of x". Single function, correct for both signs. CASE not needed. Oracle ABS→Trino abs mapping correct.
- **Completeness 5** — directly answers the "single function or CASE-WHEN?" framing, confirms no CASE.
- **Clarity 5** — minimal, runnable, zero assumed knowledge.
- **Actionability 5** — copy-paste ready with a sensible alias.
- **Q1 avg = 5.00 CLEAN**

### Q2 — three-way sign label (credit/debit/neutral) without nested IF chain
RESPONDER: searched `CASE WHEN balance_delta>0 THEN 'credit' WHEN <0 THEN 'debit' ELSE 'neutral' END`; IF is two-way shorthand; nested IF shown as valid-but-less-readable alt; cited r23:1130-1132.
- **Accuracy 5** — VERIFIED conditional.html: searched CASE form correct, first-match semantics; IF(cond,a,b) is the two-way shorthand; nested IF valid. Citation r23:1130-1132 confirmed (the CASE/IF/COALESCE one-line router). sign(x) alternative not required per directive — not penalized.
- **Completeness 5** — answers the asked 3-way case, addresses the "without a big nested IF chain" concern by recommending CASE and showing the nested-IF alt for contrast.
- **Clarity 5** — clear branch-by-branch reasoning; explains why CASE over nested IF.
- **Actionability 5** — runnable, correct alias, directly applicable to a billing label column.
- **Q2 avg = 5.00 CLEAN**

### Q3 — replace substring (spaces → dashes)
RESPONDER: `replace(sku, ' ', '-')`; 3-arg form replaces ALL occurrences; replace() for fixed literal vs regexp_replace() for patterns; Oracle REPLACE→Trino replace identical; cited r27:987.
- **Accuracy 5** — VERIFIED string.html: `replace(string, search, replace)` "Replaces all instances of search with replace" — replaces ALL, not just first. 'ABC 123 XYZ'→'ABC-123-XYZ' correct. replace-for-literal vs regexp_replace-for-patterns guidance correct. Citation r27:987 confirmed.
- **Completeness 5** — answers both phrasings (swap substring vs pull-out-and-concat), steers to the simpler replace(), notes the all-occurrences semantics that matter for multi-space SKUs.
- **Clarity 5** — worked input→output example, clear replace-vs-regexp distinction.
- **Actionability 5** — copy-paste ready normalization column.
- **Q3 avg = 5.00 CLEAN**

### Q4 — tie-aware ranking, ties share rank + next skips (1,2,2,4)
RESPONDER: `RANK() OVER (PARTITION BY month ORDER BY total_revenue DESC)` over an inner GROUP BY subquery (SUM(amount) per rep per month); RANK ties+skip (1,2,2,4); DENSE_RANK no gap (1,2,2,3); ROW_NUMBER strictly increasing; cited r07:3579-3585.
- **Accuracy 5** — VERIFIED window.html: RANK() = "one plus the number of rows preceding that are not peer" → gaps (1,2,2,4); DENSE_RANK no gaps (1,2,2,3); ROW_NUMBER unique sequential. Inner GROUP BY (sales_rep_id, DATE_TRUNC('month', order_date)) feeding the window is valid Trino 467 (window evaluated post-aggregation; grouped by input expressions, not aliases — correct). Citation r07:3580-3585 confirmed.
- **Completeness 5** — picks the correct function for the asked semantics AND disambiguates all three ranking functions so the engineer can choose if requirements shift.
- **Clarity 5** — explicit 1,2,2,4 vs 1,2,2,3 numeric illustration; subquery clearly structured.
- **Actionability 5** — full runnable leaderboard query with outer ORDER BY.
- **Q4 avg = 5.00 CLEAN**

---

## Overall: (5.00 + 5.00 + 5.00 + 5.00) / 4 = **5.00 — STRONG PASS**

No per-Q veto needed; overall governs. PASS threshold (3.5) cleared comfortably.

---

## Findings

- **No defect, no findability slip.** All four answers led with the correct canonical, all SQL is valid Trino 467, all citations (r23:1130-1132, r27:987, r07:3580-3585) are exact and present. Q1 needed no citation (trivially correct built-in).
- **No prod-env conflict** — all four are pure-SQL questions; no auth/authz/federation surface touched.
- **Durability confirmed** for four fresh adjacent function-choice angles: abs (magnitude), searched-CASE 3-way (sign labeling), replace (literal substring), RANK family (tie-aware ranking). These reinforce the standing CASE/IF router (r23) and the RANK/DENSE_RANK/ROW_NUMBER pin (r07) without any regression.

## iter829 directive

**iter829 = DEFAULT NO-OP / durability-breadth sweep** (no open defect surfaced; NOT a FIX-A). Re-probe fresh adjacent 2nd-angle batch, e.g.:
- `sign(x)` as an alternative to CASE-by-sign (the directive-noted alt for Q2) / nullif + sign interplay.
- `regexp_replace` with capture-group `$1` (Trino) vs Oracle `\1` — the r27:990 distinction, to confirm the pattern-vs-literal boundary from the other side.
- DENSE_RANK 1,2,2,3 framing (the no-gap requirement) to bulletproof the RANK family from the dense angle.
- `abs` over a window/aggregate or `greatest(abs(a),abs(b))` magnitude-compare.

**PRESERVE:** iter827 r23 §3.1 boolean-aggregate-NULL block + COALESCE(bool_or,false) canonical; r23:1118-1132 CASE/IF/COALESCE router; r27:987-990 REPLACE/REGEXP_REPLACE mapping; r07:3571-3585 RANK family card; iter824/823 split_part + GROUP-BY-alias fixes; full iter534-827 pin inventory. **NO federation edits** (margin thin, federation 4.49944/310).

**DO NOT bump training/state.json** (already 828).
