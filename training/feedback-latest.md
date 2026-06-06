# Iter567 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Verdict: 4.90625 STRONG PASS — per-product forward-fill durability 2nd-angle HOLDS; all four answers clean

**Overall average = (4.9375 + 4.875 + 4.875 + 4.9375) / 4 = 19.625 / 4 = 4.90625**
**Margin: +1.40625 above 3.5 floor; +0.03125 swing from iter566's 4.875.**
PASS by overall-average rule. Federation not probed — rubric row 4.49944/310 unchanged.

---

## Per-question scores

### Q1 — Per-product forward-fill (durability 2nd-angle re-probe)
**Accuracy 5.0 / Completeness 5.0 / Clarity 4.75 / Actionability 5.0 = 4.9375 STRONG PASS**

Responder answered: date spine via `UNNEST(sequence(...)) CROSS JOIN products`, LEFT JOIN prices, then
`COALESCE(price, LAST_VALUE(price) IGNORE NULLS OVER (PARTITION BY product_id ORDER BY calendar_day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))`.

Key checkpoints:
- `PARTITION BY product_id` included explicitly — this is the critical multi-series requirement that Q1 in iter566 left as a note. The iter567 teacher FIX A (additive bullet on `PARTITION BY entity_id` in DO-NOT-WRITE list) LANDED: responder now leads with per-entity partitioning.
- Look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — CORRECT. Does NOT use UNBOUNDED FOLLOWING.
- `IGNORE NULLS` used natively — CORRECT per Trino 467 docs.
- Warned that without look-back frame you grab future prices — the anti-pattern is named and diagnosed.

**Verified at trino.io/docs/467/functions/window.html VERBATIM**: `"By default, null values are respected. If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation."` Maps 1:1 to responder mechanism.

**Completeness 5.0** (full marks this iteration): the iter566 gap — omission of explicit `PARTITION BY id` for multi-entity carry-forward — is closed. Responder leads with `PARTITION BY product_id`, explicitly ties date spine to per-product coverage, and notes the "all products show every day" guarantee from the cross join. No remaining gap.

**Clarity -0.25**: The date spine construction using `UNNEST(sequence(...)) CROSS JOIN products` is correct but unexplained in steps — a junior engineer unfamiliar with generating date spines might struggle to assemble the three-part recipe (generate, cross-join, left-join) without labels on each step. Minor polish only.

This is a durability re-probe of iter566's forward-fill. iter567 FIX A (additive `PARTITION BY entity_id` bullet) confirmed validated. STRONG PASS — regression angle closed.

---

### Q2 — Native array membership with real ARRAY column
**Accuracy 5.0 / Completeness 4.5 / Clarity 5.0 / Actionability 5.0 = 4.875 STRONG PASS**

Responder: `WHERE contains(categories, 'web')`. No UNNEST needed.

**Verified at trino.io/docs/467/functions/array.html VERBATIM**: `"contains(x, element) → boolean — Returns true if the array x contains the element."` Matches responder's claim 1:1.

The answer is factually correct and actionable. Because the question says "Real array column" (not a varchar column split at runtime), the whitespace caveat from r23's DO-NOT-WRITE (applicable when splitting a comma-separated VARCHAR like `'mobile, web, api'` into an array via `split()`) does NOT apply here. The array already contains clean string elements. Responder correctly skips UNNEST — no explosion, no join, single function call.

**Completeness -0.5**: A brief mention that `contains` is case-sensitive (exact match — `'Web'` is not found if the array holds `'web'`) would help an engineer whose data might have mixed-case origins. Not an accuracy error but a practical gotcha omitted. The answer is correct and complete for the clean-data case as stated.

---

### Q3 — Latest-row-per-key dedup via ROW_NUMBER
**Accuracy 5.0 / Completeness 4.5 / Clarity 5.0 / Actionability 5.0 = 4.875 STRONG PASS**

Responder: `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY session_timestamp DESC) AS rn FROM sessions) WHERE rn = 1`.

Checkpoints:
- ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ... DESC) + subquery + WHERE rn = 1 — fully valid Trino 467. No QUALIFY attempted (correct — QUALIFY is not part of the Trino 467 SQL dialect).
- `SELECT *` in the outer query pulls all columns — solves the stated problem ("GROUP BY can't pull other columns").
- rn = 1 keeps newest by descending timestamp — correct semantics.

No fabricated syntax, no cross-engine slips (no Snowflake QUALIFY, no BigQuery, no Spark variant). Clean Trino 467 standard SQL subquery form.

**Completeness -0.5**: Tie non-determinism not mentioned. If two sessions for the same user_id share the exact same session_timestamp, ROW_NUMBER assigns 1 and 2 arbitrarily — the "latest" row picked is not guaranteed to be consistent across executions. A one-line note — "if timestamps can tie, add a secondary tiebreaker like `ORDER BY session_timestamp DESC, session_id DESC`" — would close this gap and prevent production confusion on datasets where event timestamps are rounded to the second. Not an accuracy error; the stated mechanism is correct. Omission of the tie-break note is the only completeness gap.

---

### Q4 — NULL ordering in Trino (default + control)
**Accuracy 5.0 / Completeness 4.75 / Clarity 5.0 / Actionability 5.0 = 4.9375 STRONG PASS**

Responder claimed: "In Trino, NULLs sort to the BOTTOM by default — regardless of ASC or DESC." Then showed `NULLS FIRST` / `NULLS LAST` syntax. Said it applies inside window ORDER BY too. Recommended always writing explicit NULLS FIRST/LAST.

**Verified at trino.io/docs/467/sql/select.html VERBATIM**: `"The default null ordering is NULLS LAST, regardless of the ordering direction."` The responder's claim is CORRECT and direction-independent — NULLs last on both ASC and DESC in Trino.

**Oracle contrast verified**: Oracle ASC = NULLS LAST; Oracle DESC = NULLS FIRST (Oracle docs: "if the null ordering is not specified, the handling is NULLS LAST if the sort is ASC, NULLS FIRST if the sort is DESC"). Responder's Oracle contrast is accurate — Oracle does reverse default on DESC, Trino does not.

**Completeness -0.25**: The window ORDER BY application is mentioned but the responder could have provided a concrete example showing `ORDER BY event_time DESC NULLS LAST` in a window frame — engineers hitting this in analytics context (e.g., `LAG() OVER (ORDER BY ts)`) benefit from seeing the syntax in-context. Very minor polish gap only; the mechanism is fully explained.

The Q4 answer is the highest-accuracy answer in this iteration. The responder correctly stated a Trino behavior that frequently surprises engineers coming from Oracle, correctly identified the Oracle reversal (DESC triggers NULLS FIRST in Oracle, not Trino), and gave actionable guidance to always write explicit NULLS FIRST/LAST. No fabrications, no cross-engine slips.

---

## Verification summary

All four answers cross-verified against Trino 467 primary sources:

1. **trino.io/docs/467/functions/window.html** — `LAST_VALUE(x) [IGNORE NULLS]` syntax + semantics confirmed. Quote: `"By default, null values are respected. If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation."` (Q1 verified CORRECT)
2. **trino.io/docs/467/functions/array.html** — `contains(x, element) → boolean` confirmed. Quote: `"Returns true if the array x contains the element."` (Q2 verified CORRECT)
3. **trino.io/docs/467/sql/select.html** — ROW_NUMBER subquery dedup valid Trino 467 SQL. QUALIFY not in 467 dialect. (Q3 verified CORRECT)
4. **trino.io/docs/467/sql/select.html** — NULL ordering default confirmed. Quote: `"The default null ordering is NULLS LAST, regardless of the ordering direction."` (Q4 verified CORRECT — responder's "bottom by default regardless of ASC or DESC" maps 1:1)

No fabricated features, no cross-engine slips, no wrong-frame/semantic errors in any of the four answers.

---

## Topic average updates

- **Analytical query patterns on Iceberg+Trino** (Q1 forward-fill re-probe + Q3 dedup pattern):
  Prior: 4.3880/25
  Q1 4.9375 → (4.3880·25 + 4.9375)/26 = 114.66/26 = **4.4100/26** (+0.0220)
  Q3 4.875 → (4.4100·26 + 4.875)/27 = 119.54/27 = **4.4274/27** (+0.0174)
  Net +0.0394 over iter566. Two above-avg adds.

- **SQL query best practices for OLAP** (Q2 array contains + Q4 NULL ordering):
  Prior: 4.4815/153
  Q2 4.875 → (4.4815·153 + 4.875)/154 = 690.47/154 = **4.4836/154** (+0.0021)
  Q4 4.9375 → (4.4836·154 + 4.9375)/155 = 695.17/155 = **4.4850/155** (+0.0014)
  Net +0.0035 — both above topic avg.

- Federation NOT probed — **4.49944/310 row UNCHANGED**.

---

## PRIMARY WINS

1. **Q1 — iter567 FIX A (additive `PARTITION BY entity_id` bullet) VALIDATED.** The multi-series extension gap from iter566 is closed. Responder leads with `PARTITION BY product_id`, date-spine recipe is complete, look-back frame correct, IGNORE NULLS correct, anti-pattern diagnosed.
2. **Q4 — NULL ordering correctly stated.** "NULLS LAST regardless of ASC or DESC" is exactly what Trino 467 docs say. Oracle contrast (DESC → NULLS FIRST in Oracle) is accurate. This is a frequent gotcha for Oracle-migrating engineers and the answer is clean.
3. **Q2 — contains(array, element) clean path.** No UNNEST, no split(), no over-engineering. Single function call on real array column — factually correct, actionable.
4. **Q3 — ROW_NUMBER dedup clean.** No QUALIFY fabrication, valid subquery pattern, correct column propagation via SELECT *.

## MINOR FINDINGS (do not over-correct)

1. **Q2 — case sensitivity not mentioned.** `contains(categories, 'web')` does exact-match — `'Web'` != `'web'`. For production data that may have mixed-case entries, a note to normalize with `lower()` (`contains(transform(categories, x -> lower(x)), 'web')`) would be prudent. Not a common gotcha for clean data but real for user-input arrays.
2. **Q3 — tie-break non-determinism not mentioned.** If two rows share the same session_timestamp, ROW_NUMBER=1 is assigned arbitrarily. Recommend: add tiebreaker `ORDER BY session_timestamp DESC, session_id DESC` as a one-liner note.
3. **Q1 — date spine steps not labeled.** The three-step recipe (generate spine, CROSS JOIN entities, LEFT JOIN facts) would benefit from step labels for engineers new to date spines. Current format is mechanically correct but dense.
4. **Q4 — no in-window example shown.** Responder mentioned NULLS FIRST/LAST works inside window ORDER BY but gave no concrete window example. A one-liner showing `ROW_NUMBER() OVER (PARTITION BY x ORDER BY ts DESC NULLS LAST)` would anchor it.

## iter568 DIRECTIVES

All four answers are STRONG PASS. The resource changes from iter567 (FIX A + FIX B, NO-OP C) are validated. No urgent fixes needed.

### Priority 1 — LOW: ROW_NUMBER tie-break anchor
In whichever resource covers the ROW_NUMBER dedup pattern (r07 or r23):
- Add ONE line: "If `session_timestamp` can tie across rows for the same user, add a secondary tiebreaker: `ORDER BY session_timestamp DESC, session_id DESC` to guarantee deterministic row selection."
- DO NOT rewrite the existing dedup pattern. Additive one-liner only.

### Priority 2 — LOW: Q2 case-sensitivity note
In the resource covering `contains(array, element)` (r07 or r23 §3.1A):
- Add ONE line: "`contains` does exact case-sensitive match — if array values may be mixed case, normalize first: `contains(transform(categories, x -> lower(x)), lower('web'))`."
- DO NOT churn. One additive bullet under the existing canonical.

### Priority 3 — DO NOT TOUCH
- Federation row stays 4.49944/310; ZERO edits to resources/22 §13.x.
- r07 forward-fill H3 (iter566) + additive `PARTITION BY entity_id` bullet (iter567 FIX A) — DO NOT REWRITE.
- r23 §3.1A contains/split/UNNEST + whitespace safety bullet (iter567 FIX B) — DO NOT REWRITE.
- All other locked resources (r27/r28/r17/r10/r24/r13/r09/r18) — UNTOUCHED.
- state.json iteration = 567, phase = `extended` — DO NOT BUMP.

### PROBING GUIDANCE for iter568
Probe these angles not yet covered in extended phase:
1. **Q1 3rd-angle**: "I have a sensor_readings table with hourly readings but gaps — I need to forward-fill the last reading into the gaps." Tests routing to the r07 H3 from a non-price/non-product framing.
2. **Q3 2nd-angle**: "I need the 2nd-most-recent session per user, not the most recent." Tests whether responder can adapt ROW_NUMBER = 2 correctly, and whether nth_value/IGNORE NULLS knowledge is distinct.
3. **Q4 2nd-angle**: "I'm using ORDER BY in a window function and the first/last row keeps being NULL — how do I fix it?" Tests NULLS FIRST/LAST in window ORDER BY context specifically (vs plain ORDER BY).
4. **Q2 2nd-angle**: "My categories column sometimes has `['Mobile','Web','API']` with capital letters, and `contains(categories, 'web')` returns false. Why?" Tests case-sensitivity knowledge and `transform(arr, x -> lower(x))` routing.

---

## NOTES
- Did NOT bump training/state.json.
- Federation rubric row 4.49944/310 UNCHANGED.
- Did NOT touch any resource files.
- WebSearched: trino.io/docs/467/functions/window.html, trino.io/docs/467/functions/array.html, trino.io/docs/467/sql/select.html (Q1/Q2/Q3/Q4 all primary-source verified).

---

## OVERALL: 4.90625 STRONG PASS — All four answers technically accurate, actionable, and beginner-clear. iter567 FIX A (PARTITION BY entity_id multi-series extension) validated on first re-probe at Q1. Q4 NULL ordering correctly stated against Trino 467 docs (NULLS LAST regardless of direction). No fabrications, no cross-engine slips, no wrong-frame errors. iter568 = low-churn polish (tie-break note + case-sensitivity note). Probe new angles for forward-fill, dedup, NULL-in-window, and array case.
