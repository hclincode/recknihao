# Judge Feedback — iter879

**Verdict: PASS** — overall average **4.31** (>= 3.5). Per-Q averages: Q1 5.00, Q2 3.25, Q3 5.00, Q4 4.00.

All dialect facts verified against trino.io/docs/467 (PINNED 467). No state.json bump.

---

## Q1 — Format integer seconds as H:MM:SS; do numbers need conversion before `||`?

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → avg 5.00**

VERIFIED (trino.io/docs/467):
- functions/conversion.html — CAST "can be used to cast a varchar to a numeric value type and vice versa" → `CAST(integer AS varchar)` yields a VARCHAR.
- functions/string.html — "The `||` operator performs concatenation" (VARCHAR operands), "equivalent to `concat()`".
- functions/conversion.html — `format('%03d', 8)` → `'008'`; Java Formatter syntax, so `%02d`/`%d` zero-pad correctly.

The responder correctly states explicit conversion is required (no implicit number→string coercion), and presents **CAST(s/3600 AS varchar) || ':' || ... as a VALID Approach 2**, alongside `format('%d:%02d:%02d', ...)` as the terser preferred form. Zero-padding caveat (wrap in `lpad(...,2,'0')`) is correct. Takeaway "Always CAST(number AS varchar) explicitly before ||" is right; Trino rejects ONLY a bare `int || ':'` (implicit coercion).

**(a) CAST+|| INOCULATION TOOK.** The responder now presents CAST+|| as VALID — it no longer claims it throws a type error. The iter878 Q4 regression is corrected. No escalation to iter880 on this axis.

---

## Q2 — Unpack a ROW column `properties` (fields plan/region/account_tier) into separate columns WITHOUT listing every field

**Sub-scores: Accuracy 3 / Completeness 3 / Clarity 4 / Actionability 3 → avg 3.25 (DEFECT)**

VERIFIED (trino.io/docs/467):
- language/types.html — "Named row fields are accessed with field reference operator (.)." Example `CAST(ROW(1, 2.0) AS ROW(x BIGINT, y DOUBLE)).x`. So `properties.plan` dot access is CORRECT. NULL-row dot access returning NULL and COALESCE fallback are reasonable.
- **sql/select.html — Trino 467 DOES support `row_expression.*` expansion**: verbatim "In the case of `row_expression.* [ AS ( column_alias [, ...] ) ]`, the `row_expression` is an arbitrary expression of type `ROW`. All fields of the row define output columns to be included in the result set." Example: `SELECT (CAST(ROW(1, true) AS ROW(field1 bigint, field2 boolean))).*;`. This is the ACTUAL answer to "expand all fields without listing each" — `SELECT (properties).* FROM events` (parentheses required around the row expression).
- **sql/select.html — UNNEST expands ARRAY or MAP into a relation** (arrays → one column, maps → key/value columns). The docs do NOT support UNNEST taking a single ROW and expanding its fields to columns.

**Two problems:**
1. **WRONG claim (Accuracy hit):** The responder's "you could use CROSS JOIN UNNEST on the ROW's fields" is incorrect. UNNEST operates on ARRAY/MAP, not on a bare ROW's fields. Recommending it (even as a hedged "more verbose") is misleading and would produce a parse/type error if attempted.
2. **MISSED the real answer (Completeness hit):** The engineer EXPLICITLY asked to unpack all fields WITHOUT listing each. The correct Trino 467 mechanism is `(properties).*` row-wildcard expansion. The responder never mentioned it — it led with per-field dot notation (fine, but still requires listing each) and then offered the wrong UNNEST alternative instead of the actual `row.*` answer.

The dot-notation lead is correct and useful, which keeps this from being a hard fail, but the question's specific ask was missed and a wrong alternative was given.

**(b) ANSWERS TO THE TWO VERIFICATION QUESTIONS:**
- **Can UNNEST expand a ROW's fields to columns? NO.** UNNEST expands ARRAY or MAP into rows; it does not expand a single ROW's fields into columns. The responder's CROSS-JOIN-UNNEST-on-a-ROW suggestion is WRONG.
- **Is `properties.*` row-expansion supported in Trino 467? YES.** `SELECT (properties).* FROM events` (parens around the row expression, optional `AS (alias, ...)`) is the documented unpack-all mechanism the responder missed.

---

## Q3 — Year-over-year: this month's revenue beside same month last year

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → avg 5.00**

VERIFIED (trino.io/docs/467):
- functions/window.html — lag: "Returns the value at `offset` rows before the current row in the window partition." So `LAG(revenue, 12) OVER (ORDER BY month)` returns the value 12 rows back — correct for a contiguous monthly series.
- functions/datetime.html — interval arithmetic confirmed: `date '2012-08-08' - interval '2' day`, `timestamp + interval '1' month`. So `cur.month - INTERVAL '1' YEAR` self-join is valid.

The responder's contiguity caveat (LAG(,12) miscounts if months are missing) is CORRECT and important, and the robust self-join on `prev.month = cur.month - INTERVAL '1' YEAR` is the right fallback for sparse data. `NULLIF` guard + `100.0` for the growth_pct (float division) is correct. Excellent, complete answer.

---

## Q4 — Pad short strings to fixed width OR truncate long strings with '...'

**Sub-scores: Accuracy 4 / Completeness 4 / Clarity 4 / Actionability 4 → avg 4.00**

VERIFIED (trino.io/docs/467):
- functions/string.html — lpad/rpad: "If `size` is less than the length of `string`, the result is truncated to `size` characters." Confirms the standing lpad/rpad pad-OR-truncate fact. The responder's note that `rpad(s,50,' ')` on a 100-char string keeps only the first 50 is CORRECT.
- functions/string.html — `length()` "Returns the length of `string` in characters." Correct.
- functions/string.html — `substr` positions start at 1; `||` concatenation. So `CASE WHEN length(s) > 50 THEN substr(s,1,47) || '...' ELSE s END` is correct (47 + 3 = 50).

All correct. Held just under a 5 because the answer doesn't flag that `rpad(s,50,' ')` and the ellipsis-truncate produce different results for over-width input (rpad silently truncates with no ellipsis), and the combined form's interaction (truncate-then-pad is a no-op for over-width) is left implicit — minor completeness/clarity polish, not a defect.

---

## Overall

Overall average **4.31 → PASS**. The standout is the Q2 defect: a WRONG UNNEST-on-a-ROW suggestion plus a MISSED `(properties).*` row-expansion answer (the literal thing the engineer asked for). Q1 confirms the CAST+|| inoculation held. Q3 and Q4 are clean.

### iter880 recommendation: **FIX-A (Q2)**

Q2 has a real, verifiable defect. Recommended LIGHT FIX-A (additive + one inline-defang), no churn to correct cards:
- **ADD** a leading canonical for ROW unpack-all: `SELECT (properties).* FROM events` (parens around the row expression required) with optional `AS (plan, region, account_tier)` column aliases — verified verbatim from sql/select.html `row_expression.*`. Keyword anchors: "unpack all ROW fields", "expand row into columns without listing each", "row.* / row dereference all", "flatten a ROW column", "select all struct fields".
- **KEEP** the per-field dot-notation card (`properties.plan`) as the correct access-what-you-need path; cross-link it to the new unpack-all card.
- **INLINE-DEFANG** (own un-copyable FENCED line) the "CROSS JOIN UNNEST on a ROW's fields" suggestion: UNNEST expands ARRAY/MAP into ROWS, it does NOT expand a single ROW's fields into columns — DO NOT COPY. Route ROW-fields-to-columns to `(row).*`.
- All SQL FENCED (pipe-escape trap). PIN Trino 467. No federation edits.

If the teacher disagrees the UNNEST line + missing row.* rise to a defect, the floor is the missing `(properties).*` card (a genuine completeness gap on the exact asked question) — so at minimum the additive card is warranted.
