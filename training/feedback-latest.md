# Judge Feedback — Iter 839 (EXTENDED PHASE)

**Mode:** DEFAULT NO-OP durability sweep. Teacher made ZERO resource edits. 4 SQL-fundamentals probes (seconds->'H:MM:SS' format + IS NOT DISTINCT FROM null-safe equality + DENSE_RANK nth-distinct + weighted average). All dialect claims verified against trino.io/docs/467 (string/conversion/comparison/math/window .html) on 2026-06-09. PIN Trino 467.

**Overall: 4.59 PASS** (per-Q 5.00 / 5.00 / 5.00 / 3.38 = 18.38 / 4; margin +1.09 above 3.5 floor; overall avg governs, no per-Q veto).

---

## Per-Q scores

### Q1 — total seconds (integer) -> 'H:MM:SS' like '1:23:45' — **5.00 CLEAN**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.
- Canonical `format('%d:%02d:%02d', duration_seconds/3600, (duration_seconds%3600)/60, duration_seconds%60)`.
- VERIFIED vs conversion.html: `format()` uses java.util.Formatter; `%d` = decimal integer, `%0Nd` zero-pads to width N (doc example `format('%03d', 8)` -> `'008'`), so `%02d` zero-pads to width 2 (e.g. minute 5 -> '05'). Accepts numeric/bigint args.
- VERIFIED vs math.html: integer `/` truncates (integer division), `%` is modulus/remainder. Arithmetic decomposition is correct: hours = `s/3600`; minutes = `(s%3600)/60`; seconds = `s%60`. 4925s -> 1:22:05 checks out (1*3600 + 22*60 + 5 = 4925).
- Correctly chose SQL over app code AND correctly noted `format()` is cleaner than `||` which would need `CAST AS varchar` on each piece. No leading zero-pad on the hours field (matches the asked '1:23:45' single-digit-hour shape, not a defect).

### Q2 — null-safe equality (NULL = NULL must be true) — **5.00 CLEAN**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.
- Canonical `a.region_override IS NOT DISTINCT FROM b.region_override`.
- VERIFIED vs comparison.html: `IS NOT DISTINCT FROM` is the SQL-standard null-safe equality — treats NULL as a known value, guarantees a true/false outcome; `NULL IS NOT DISTINCT FROM NULL` -> true, `1 IS NOT DISTINCT FROM NULL` -> false. Exactly fixes the asked silent-drop on plain `=` (which yields NULL/UNKNOWN when either side is NULL). Correctly explains why plain `=` drops the NULL/NULL match.

### Q3 — 2nd/3rd highest DISTINCT value (ties for 1st collapse) — **5.00 CLEAN**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.
- Canonical CTE `SELECT DISTINCT revenue, DENSE_RANK() OVER (ORDER BY revenue DESC) AS rank FROM accounts`, outer `WHERE rank IN (2,3) ORDER BY rank`.
- VERIFIED vs window.html: DENSE_RANK gives ties the same rank with NO gaps (1,2,2,3); RANK leaves gaps (1,2,2,4); ROW_NUMBER is strictly sequential. The DENSE_RANK + SELECT DISTINCT combo correctly yields the nth-DISTINCT value: with three accounts tied at the top, all get rank 1, and the next-lower distinct revenue is rank 2 = the 2nd-distinct value the engineer asked for. (The SELECT DISTINCT is belt-and-suspenders given DENSE_RANK already collapses ties, but it is correct and harmless.) Correct ROW_NUMBER-vs-DENSE_RANK characterization.

### Q4 — weighted average `SUM(score*weight)/SUM(weight)` — **3.38** (Accuracy 3.5 / Completeness 3 / Clarity 4 / Actionability 3)
- The FORMULA is structurally correct: weighted mean = sum(value*weight) / sum(weight), grouped per `customer_segment`. Numerator/denominator decomposition described correctly.
- **DEFECT (completeness + accuracy ding): the integer-division-truncation pitfall was NOT flagged.** VERIFIED vs math.html: integer `/` truncates. If `score` AND `weight` are both INTEGER/BIGINT (a very common survey schema — scores 1-5, integer weights), then `SUM(score*weight)` and `SUM(weight)` are both BIGINT and `BIGINT / BIGINT` is INTEGER DIVISION, truncating toward zero: e.g. 17/4 -> 4, not 4.25 — a silently wrong AVERAGE. This is directly analogous to the percent-of-total `* 100.0` fix and to the iter808/809 cast-less arithmetic dings. The fix the responder should have included: `SUM(score * weight) * 1.0 / SUM(weight)` (or `CAST(SUM(score*weight) AS DOUBLE) / SUM(weight)`, or `/ NULLIF(SUM(weight), 0)` to also guard zero-weight groups).
- **Q4 INTEGER-DIVISION VERDICT: YES — the bare `SUM(x*w)/SUM(w)` IS a completeness ding (bordering accuracy) for not flagging integer-division truncation when both operands are integer types.** An average that silently returns 4 instead of 4.25 is a real silent-wrong-result hazard, exactly the failure mode an engineer asking for a *weighted average* cares about. The score is held at 3.38 (not lower) because the algebraic formula itself is correct and works as-is when either operand is decimal/double; it is not a fabrication or parse error. But for a metric whose entire point is a fractional mean, omitting the `*1.0`/CAST caveat is a substantive gap.
- **Responder-slip, NOT a content gap.** r23 §3.1B troubleshooting checklist item 5 (line 827) already documents this exactly: "`SELECT SUM(a / b)` where `a` and `b` are `BIGINT` does INTEGER division per row (truncates) ... Cast at least one operand: `SUM(CAST(a AS DOUBLE) / b)`." The hazard content exists and is accurate; the responder landing on "weighted average" did not surface it. Findability miss: that checklist is anchored under "SUM looks too small / numbers are truncated," not under average/weighted-average/mean keywords.

---

## Patterns / notes
- 3 of 4 clean at 5.00; all dialect facts (format %02d zero-pad, IS NOT DISTINCT FROM null-safe semantics, DENSE_RANK no-gap, integer `/` truncation) docs-verified vs trino.io/docs/467.
- No fabrications, no parse errors, no prod-env conflict (all pure Trino SQL — fits the on-prem Trino 467 / Iceberg / MinIO stack; no auth/authz scope touched).
- The only defect is the recurring **cast-less integer-arithmetic / integer-division omission** — same family as iter808 (`format('%.2f%%', x*100)`) and the percent-of-total `100.0` fixes. The hazard is documented (r23 §3.1B item 5) but not keyword-surfaced where an average/weighted-mean question lands.

## iter840 directive — LIGHT FINDABILITY FIX-A
A defect surfaced (Q4 integer-division-for-average), so iter840 is **FIX-A (light, findability)**, not a NO-OP:
1. At the resource location where "average / weighted average / mean / AVG" questions land (r07 analytical patterns and/or r23 best-practices), add a short keyword-anchored AVERAGE/WEIGHTED-AVERAGE card. Lead with the copy-attractive canonical `SUM(score * weight) * 1.0 / SUM(weight)` (or `CAST(... AS DOUBLE)`), with `/ NULLIF(SUM(weight), 0)` zero-weight guard mentioned.
2. State the one fact prominently: if BOTH operands are INTEGER/BIGINT, `SUM(x*w)/SUM(w)` is INTEGER DIVISION and TRUNCATES (17/4 -> 4 not 4.25) — silently wrong for an average. Inline-defang the bare `SUM(score*weight)/SUM(weight)` on its own un-copyable line (mark WRONG-when-integer), keep the `*1.0` form copy-attractive.
3. Keyword anchors: weighted average, weighted mean, SUM(value*weight)/SUM(weight), average truncates to integer, integer division average wrong, plain AVG ignores weights, true decimal average.
4. Cross-link to the existing r23 §3.1B item-5 integer-division-truncation checklist (content there is CORRECT — do not churn it).
- PRESERVE all iter827 boolean-aggregate-NULL, iter836 lpad/rpad TRUNCATE + format('%06d'/'%08d'), iter837 string->DATE MySQL-vs-Joda disambiguator, iter831 month-label grouping, iter824/823 split_part/GROUP-BY-alias/repeat-char, trim char-set, default-NULLS-LAST, and full iter534-838 lock inventory.
- NO federation edits (r22 §13.x ZERO edits; federation row stays 4.49944/310).

**DO NOT bump training/state.json (already 839).**
