# Judge Feedback — iter852 (EXTENDED PHASE)

**Mode:** DEFAULT NO-OP durability sweep + two re-probes of iter851 responder-slips (teacher made ZERO resource edits).
**Overall: 4.84 STRONG PASS** (per-Q 4.375 / 5.00 / 5.00 / 5.00 = 19.375 / 4 = 4.84375; margin +1.34 above the 3.5 floor; overall average governs, no per-Q veto).
**Federation NOT probed** — the 4.49944 / 310 row is UNCHANGED and stays FAIL.

All four dialect claims verified against trino.io/docs/467 this session (aggregate.html, string.html, map.html) + standard interval-overlap logic. PIN Trino 467. No prod-env conflict (pure SQL; on-prem Trino 467 + Iceberg + MinIO unaffected).

---

## Per-question scores

### Q1 — single most common category (mode), no per-category count, ideally without ORDER BY...LIMIT 1 — **4.375 PASS**
Accuracy 4 / Completeness 5 / Clarity 4 / Actionability 4.5

- **Recommended form EX2 is CORRECT and is the one the responder labeled "cleanest":**
  `SELECT max_by(category, cnt) FROM (SELECT category, COUNT(*) AS cnt FROM support_tickets GROUP BY category)`.
  VERIFIED aggregate.html: `max_by(x, y)` "Returns the value of x associated with the maximum value of y" → returns the single mode as ONE scalar row, no full sort, no LIMIT. Trino 467 has **NO `mode()` aggregate** (confirmed — not in the function list). This is exactly the asked-for shape.
- **The muddled GROUP BY 1 / max_by anti-pattern from iter851 did NOT recur.** The iter851 Q3-mode slip is a CONFIRMED ONE-OFF — clean on re-probe.
- **DING (Accuracy 4, Clarity 4):** the leading EX1 example is a real wart —
  `SELECT category, COUNT(*) FROM (SELECT category, element_at(histogram(category), category) AS cnt FROM support_tickets) GROUP BY category ORDER BY cnt DESC LIMIT 1`
  is convoluted-to-broken: the inner query mixes a bare `category` column with a global `histogram(category)` aggregate and no GROUP BY (ill-formed), and it still ends in the ORDER BY...LIMIT 1 the engineer asked to AVOID. It is clutter that contradicts the question's own constraint. Because the responder explicitly steered to EX2 as "cleanest," this is a presentation/precision ding, not an accuracy FAIL.

### Q2 — numeric code of a char ('A'=65) + reverse (integer→char), both directions — **5.00 STRONG PASS**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

- **`codepoint('A') -> 65` is CORRECT.** VERIFIED string.html: codepoint "Returns the Unicode code point of the only character of string." **The iter851 Q4 `'A' -> 85` typo did NOT recur — that slip is a CONFIRMED ONE-OFF.**
- `chr(65) -> 'A'` CORRECT (chr "Returns the Unicode code point n as a single character string").
- Single-char requirement surfaced correctly: codepoint takes "the only character," so slice first with `substr(country_code, 1, 1)` (1-indexed, VERIFIED).
- `WHERE codepoint(substr(country_code,1,1)) BETWEEN 65 AND 90` for A–Z is correct; Oracle `ASCII()` / Python `ord()` analogy is apt for the beginner audience.

### Q3 — flag rows where two date ranges overlap at all, without gnarly CASE — **5.00 STRONG PASS**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

- Predicate `WHERE contract_start <= support_window_end AND support_window_start <= contract_end` is the textbook interval-overlap test: ranges `[s1,e1]`, `[s2,e2]` overlap iff `s1 <= e2 AND s2 <= e1`. CORRECT.
- Correctly notes there is no single overlap function; two plain inequalities (valid Trino 467 comparisons) replace any CASE.
- Boundary-touch nuance handled: `<=` includes touching endpoints; switch to `<` to exclude end==start. Complete.

### Q4 — transform every VALUE of a map (trim/uppercase), keep keys, no UNNEST+regroup — **5.00 STRONG PASS**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

- `transform_values(metadata, (k,v) -> trim(v))` / `upper(v)` CORRECT. VERIFIED map.html: `transform_values(map(K,V1), function(K,V1,V2)) -> map(K,V2)` returns a new map, SAME keys, transformed values, no UNNEST. One row in, one out.
- Family correct: `map_filter(m,(k,v)->bool)`, `transform_keys(m,(k,v)->newkey)`, `map_keys`, `map_values` — all verified present and correctly described.

---

## Verdict on the two re-probes

- **iter851 Q3 mode slip (muddled GROUP BY 1 / max_by): CONFIRMED ONE-OFF.** Re-probe Q1 led with the correct scalar `max_by(category, COUNT(*))` over a GROUP BY subquery and stated no `mode()` exists. No findability anchor needed.
- **iter851 Q4 codepoint slip (`'A' -> 85`): CONFIRMED ONE-OFF.** Re-probe Q2 returned `codepoint('A') -> 65` and `chr(65) -> 'A'` cleanly. No findability anchor needed.

Both iter851 slips were synthesis slips against already-correct, already-findable resource content (iter744 r23 L454-472 codepoint/chr single-char PIN; max_by canonical / aggregate family). No resource defect; reconcile-don't-churn says do NOT edit.

## Defect / gap flag

- **One minor wart, not a defect:** Q1 EX1's convoluted/ill-formed `element_at(histogram(...), category)` example. It is a responder-synthesis artifact, not copied from a resource, and the recommended EX2 is correct. Does NOT justify an edit on its own. If a 2nd "most common / mode value" probe again volunteers a malformed histogram form, escalate to a LIGHT FIX-A: add a keyword-anchored "single most common value (mode)" canonical leading with `max_by(category, COUNT(*))` over a GROUP BY subquery (+ note: no `mode()` in Trino 467) and inline-defang the histogram-in-subquery hack un-copyable. Do NOT pre-churn now.

## iter853 directive

**iter853 = DEFAULT NO-OP / durability sweep** (all clean; both re-probed slips confirmed one-offs; no open defect).
- Re-probe mode/most-common value ONCE more from a fresh angle (e.g. `max_by(x, COUNT(*))` vs top-1 vs `histogram` map inspection) to watch for an EX1-style malformed histogram recurrence; if it recurs → escalate to the LIGHT FIX-A above.
- Suggested fresh adjacent probes: `min_by(x,y)` / `max_by(x,y,n)` top-N, `map_filter` keep-by-value, `transform_keys` upper-the-keys, `arrays_overlap` vs date-range overlap, `codepoint` over a multi-char string error case.
- **PRESERVE all locks:** iter744 codepoint/chr single-char PIN (r23 L454-472), iter744 combine-DATE+TIME (r13), max_by/min_by aggregate family, transform_values/map HOF family (r09/r07), iter845/837 string→DATE MySQL-vs-Joda, iter843 approx_percentile accuracy, iter842 value-vs-rank, iter840 weighted-avg §3.1B-WA, iter836 lpad/format, iter831 month-name, r27 §4.4H float-state, default-NULLS-LAST, + full iter534-851 inventory.
- **NO federation edits** (r22 §13.x ZERO edits; federation row stays 4.49944 / 310, still FAIL).
- DO NOT bump training/state.json (already 852).
