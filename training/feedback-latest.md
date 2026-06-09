# Judge Feedback — iter779 (LIGHT ADDITIVE FIX-A verification)

**Topic focus:** replace-fixed-char FIX-A re-probe (Q1) + 3 fresh adjacent string/date/math probes (Q2-Q4).
**Verification:** every dialect claim verified against trino.io/docs/467 (string.html, math.html, datetime.html) on 2026-06-09. resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — Replace fixed char (literal `_`→`-`, explicitly no regex) — THE FIX CHECK
Answer: `replace(product_code, '_', '-')` → `'ABC-123-XYZ'`. LED with plain 3-arg `replace()`, called it the simplest character substitution, did NOT reach for `regexp_replace`. Cites r27.
- Verified vs string.html: `replace(string, search, replace) -> varchar` "Replaces all instances of `search` with `replace` in `string`." Non-regex, literal. `replace('ABC_123_XYZ','_','-')` = `'ABC-123-XYZ'`. EXACT.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**
- **The iter779 FIX-A WORKED.** The responder LED with plain `replace()` for the fixed-char substitution and did NOT default to `regexp_replace` (the iter778 Q2 gap). 1st post-fix datapoint clean.

### Q2 — Concat skipping NULLs (comma-delimited full_address)
Answer: `concat_ws(', ', street, city, state, zip) AS full_address` — automatically SKIPS NULL fields; NULL city → `'456 Oak Ave, CA, 90210'` (no double comma). Notes plain `concat()`/`||` propagate NULL (any NULL → whole result NULL). Cites r27.
- Verified vs string.html: `concat_ws(string0, string1, ..., stringN)` "Any null values provided in the arguments after the separator are skipped." → NULL city dropped, no `", ,"`. CORRECT.
- NULL-propagation note CORRECT: `||` returns NULL if any operand is NULL; `concat()` shares "the same functionality as the SQL-standard concatenation operator (||)" → also NULL-propagating. The contrast (use `concat_ws` for optional fields) is the right guidance.
- Accuracy 5 / Completeness 4.75 / Clarity 5 / Actionability 5 — **avg 4.9375**
- Minor un-penalized nuance: `concat_ws` skips NULL but does NOT skip empty-string `''` (an `''` field still yields a separator). Question was about NULL, so on-target; worth a one-line note next phrasing.

### Q3 — Rolling 30-day date filter (no hardcoded date)
Answer: `order_date >= current_date - INTERVAL '30' DAY` (rolling, re-evaluates each run); alt `date_add('day', -30, current_date)`. Notes bare `current_date - 30` is a parse error in Trino. Cites r07.
- Verified vs datetime.html: `current_date` valid (start-of-query date); `-` with `INTERVAL '30' DAY` valid date arithmetic; bare-integer subtraction NOT supported (INTERVAL required) → the parse-error warning is CORRECT. `date_add('day', -30, current_date)` equivalent valid.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

### Q4 — Round computed average to 2 dp (47.8333→47.83)
Answer: `round(avg(amount), 2)` → `47.83`. Cites r23 + r07.
- Verified vs math.html: `round(x, d)` "Returns `x` rounded to `d` decimal places." `round(47.8333..., 2)` = `47.83`. CORRECT.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.00 |
| Q2 | 4.9375 |
| Q3 | 5.00 |
| Q4 | 5.00 |
| **Overall** | **4.984** |

**Result: PASS** (overall 4.984 >= 3.5; no single-Q veto).

---

## Teacher feedback

**(a) Is replace-fixed-char CLOSED?** YES — **CLOSED (1st clean post-fix datapoint).** The iter779 FIX-A (plain-replace card + replace-vs-regexp_replace disambiguator at r27:1143-1174) worked: on the fixed-char-substitution re-probe the responder LED with `replace(col,'_','-')` and did NOT reach for `regexp_replace`. The iter778 Q2 findability nick (regexp_replace surfacing ahead of plain replace) did NOT recur. Needs one more clean datapoint from a different phrasing (e.g. strip-all-spaces via 2-arg `replace(s,' ')`, or remove-dashes) to move CLOSED → BULLETPROOFED.

**(b) iter780 designation: DEFAULT NO-OP / durability-breadth sweep.** No open defect surfaced; no new imprecision. Teacher should make ZERO edits.
- Suggested probes: one fresh `replace`-family phrasing to convert replace-fixed-char CLOSED→BULLETPROOFED (e.g. 2-arg `replace(s,' ')` strip-spaces, or remove a literal `-`), plus fresh adjacent topics — `concat_ws`-with-empty-string-vs-NULL distinction, `date_diff`/age-in-days, `truncate(x,d)`-vs-`round(x,d)` (to confirm responder distinguishes round vs truncate).
- **PRESERVE** the new plain-replace card + replace-vs-regexp_replace disambiguator at r27:1143-1174 (load-bearing, just confirmed working — churn risk), plus the r07/r23/r27 cards backing Q2-Q4 (all verified clean).
