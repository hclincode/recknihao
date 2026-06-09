# Judge Feedback — Iter 856 (EXTENDED PHASE)

**Mode:** DEFAULT NO-OP durability sweep + 2 bulletproofing re-probes (Q1 geometric_mean, Q2 array-subset). Teacher made ZERO resource edits this iteration.

**Overall: 4.34 PASS** (per-Q 5.00 / 5.00 / 2.375 / 5.00 = 17.375 / 4 = 4.34375; margin +0.84 above the 3.5 floor; overall avg governs, no per-Q veto).

Federation NOT probed this iter — r22 §13.x row UNCHANGED at 4.49944/310 (still FAIL).

All dialect claims verified against trino.io/docs/467 (aggregate.html, array.html, datetime.html, list.html, conditional.html) + WebSearch, 2026-06-10. Trino 467 pinned.

---

## Per-question scores

### Q1 — geometric mean for compounding growth (2nd-angle re-probe) — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
Responder LED with the built-in: `SELECT geometric_mean(growth_multiplier) AS average_compound_growth`, and correctly framed `EXP(AVG(LN(x)))` as a fallback for older engines / deliberate non-positive exclusion. VERIFIED vs aggregate.html: `geometric_mean(x) -> double` IS a built-in Trino 467 aggregate ("Returns the geometric mean of all input values"); list.html G-section indexes it. The arithmetic-overstates-compounding framing is sound (geometric mean is the correct compounding average). CLEAN.

### Q2 — array contains ALL required scopes (2nd-angle re-probe) — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
Responder gave both one-liners with no UNNEST/CROSS-JOIN loop:
- `WHERE cardinality(array_except(ARRAY['read','write','delete'], granted_scopes)) = 0`
- `WHERE all_match(ARRAY['read','write','delete'], x -> contains(granted_scopes, x))`
VERIFIED vs array.html: `array_except(x,y)` returns elements in x but not in y (so empty => all required present => subset test); `all_match(array(T), function(T,boolean))` true iff all elements match (empty => true); `contains(x,element)` true iff array x contains element. Both forms correct; "cardinality(array_except)=0 usually shorter" is a fair tiebreak. CLEAN.

### Q3 — convert UTC timestamp using a timezone NAME stored in a COLUMN — 2.375 (Acc 1 / Comp 3 / Clar 3.5 / Act 2) — DEFECT
**Responder claim is WRONG.** It asserted: "Trino's AT TIME ZONE operator and with_timezone() accept hardcoded string LITERALS ONLY, not column values — you cannot write `ts AT TIME ZONE current_timezone_col` directly," and prescribed a CASE-per-timezone workaround.

**Verified truth (trino.io/docs/467 datetime.html + list.html, multi-source):** `at_timezone(timestamp(p) with time zone, zone) -> timestamp(p) with time zone` is a **regular scalar function**. Its `zone` is a plain varchar argument evaluated **per row** — there is NO documented constant-literal restriction. A COLUMN works:
```
SELECT at_timezone(with_timezone(occurred_at, 'UTC'), current_timezone) FROM session_events
```
(or `at_timezone(occurred_at_tz, current_timezone)` if the column is already timestamptz). This is exactly the user's ask — dynamic per-row zone from a column — and it is fully supported. The responder denied a real, simple capability and replaced it with an unmaintainable CASE-per-zone hack that breaks the moment a new timezone string appears in the data.

Nuance the responder got partly right: the bare `AT TIME ZONE` *operator/clause* and `with_timezone()` are typically used with literals, and the operator grammar is where the "constant" intuition comes from. But the `at_timezone()` *function* is precisely the dynamic-column path — and the responder never even mentioned `at_timezone()` as a function. That omission is the root miss.

Acc held to 1: the load-bearing claim ("you cannot do this, must hardcode/CASE") is false and would actively misdirect the engineer. The schema-normalize / TIMESTAMP WITH TIME ZONE side-note is harmless but doesn't redeem the false denial.

### Q4 — sentinel -1 -> NULL inline without CASE — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
`NULLIF(raw_value, -1)` returns NULL when `raw_value = -1`, else the value; SUM/AVG/COUNT skip NULLs automatically; cleaner than the CASE equivalent. VERIFIED vs conditional.html: `nullif(value1, value2)` returns null if value1 equals value2, otherwise value1. Aggregate NULL-skipping is standard. CLEAN.

---

## Bulletproofing verdicts

- **Q1 geometric_mean — BULLETPROOFED.** 2nd clean datapoint after iter855 (led with built-in `geometric_mean(x)` + EXP(AVG(LN(x))) fallback note, both correct). Arc closed.
- **Q2 array-subset — BULLETPROOFED.** 2nd clean datapoint after iter855 (both `cardinality(array_except(B,A))=0` and `all_match(B, x->contains(A,x))`, no loop). Arc closed.

## Q3 at_timezone-with-column-zone VERDICT
- **Does at_timezone() accept a COLUMN zone? YES.** It is a scalar function; the varchar `zone` is evaluated per row, so `at_timezone(ts, tz_column)` works. Verified multi-source (datetime.html signature + description, list.html index, WebSearch corroboration).
- **Responder: WRONG** — over-restrictive denial of an existing capability; recommended an unnecessary CASE-per-timezone workaround; never mentioned the `at_timezone()` function at all.
- **Resource coverage (grep finding):** resources document ONLY literal-zone forms — `AT TIME ZONE 'America/New_York'` and `with_timezone(ts, 'UTC')` (r07 timezone cards ~L2356-2394, r27 §4.x ~L812-970, r22 §13.x ~L2184-2201), plus a single `at_timezone(ts, 'UTC')` literal mention at r23:3083. NONE document the dynamic `at_timezone(ts, tz_column)` column-zone form. The responder had **no findable card** for the column-zone case. This is a **coverage/findability GAP**, not merely a responder slip.

---

## iter857 directive — LIGHT FIX-A (Q3 dynamic-timezone gap)

Q3 is a real defect AND the resource lacks the dynamic form, so escalate from DEFAULT NO-OP:

**LIGHT FIX-A:** Add a keyword-anchored "convert a UTC timestamp using a timezone NAME stored in a COLUMN" card (best home: r07 timezone section near L2356-2394, or r27 §4.x timezone block) that:
1. LEADS with the canonical dynamic form: `at_timezone(with_timezone(occurred_at, 'UTC'), current_timezone)` (and `at_timezone(occurred_at_tz, current_timezone)` when the column is already timestamptz) — emphasize the `zone` arg is a per-row varchar, so a COLUMN works.
2. States explicitly that `at_timezone()` is the dynamic/column path; the bare `AT TIME ZONE 'literal'` operator and `with_timezone(ts, 'literal')` are the literal-zone forms.
3. FENCED inline-DEFANG on its own un-copyable line of the misconception "you must hardcode the zone / must CASE per timezone -- WRONG" and of the CASE-per-zone workaround.
4. Keyword anchors: convert timezone from column, timezone name in a column, per-row timezone, dynamic timezone, at_timezone column, user local time from stored zone.
5. PIN Trino 467; all pipe-bearing content FENCED (pipe-escape trap).

Do NOT churn the existing literal-zone timezone cards (r07/r27/r22 are correct for their literal use case) — cross-link, don't rewrite. Do NOT touch the iter855 geometric_mean §3.1B-GM card or the array-subset §1a.3-SUBSET card (both bulletproofed). HOLD all iter534-855 locks. NO federation edits (4.49944/310 stays FAIL). DO NOT bump training/state.json (already 856).

## Flags
- DEFECT: Q3 — false denial of `at_timezone(ts, tz_column)` dynamic-column capability + unnecessary CASE workaround.
- GAP: resources document only literal-zone timezone conversion; missing the dynamic column-zone `at_timezone()` card -> iter857 LIGHT FIX-A above.
