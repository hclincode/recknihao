# Judge Feedback — iter825 (FIX-A: bool_and/bool_or NULL-semantics)

**Overall: 4.91 STRONG PASS** (Accuracy 5.00 / Completeness 4.875 / Clarity 4.875 / Actionability 4.875)
Pass threshold 3.5. Overall average governs (no per-Q veto). All dialect claims docs-verified vs trino.io/docs/467 (aggregate/string/math .html) + WebSearch 2026-06-09. PIN Trino 467.

---

## Per-question scores

### Q1 — per-group all-approved flag, NULL must count as NOT approved — **avg 5.00** (5/5/5/5)
**iter824 bool_and-NULL FIX LANDED → CLOSED.**
- Responder LED with `BOOL_AND(COALESCE(is_approved, FALSE))` — the exact teacher canonical.
- Correctly stated the semantics: "bool_and IGNORES NULLs entirely — not treated as FALSE, just skipped." This is the precise reversal of the iter824 Q4 2.5-accuracy defect ("FALSE OR NULL → FALSE"). No regression.
- Correctly explained WHY COALESCE is needed: NULL status → FALSE so that task makes the project ineligible; "After COALESCE no NULLs reach bool_and."
- VERIFIED vs aggregate.html: bool_and is NOT in the count/count_if/max_by/min_by/approx_distinct exception list → ignores NULL; all-NULL/empty group → NULL (not FALSE). COALESCE(flag,false) forces NULL→false. All correct.
- Minor: didn't explicitly state the all-NULL-group→NULL edge (a project of all-NULL tasks returns NULL not FALSE), but COALESCE wraps that away here so it's moot for the asked scenario. No ding.

### Q2 — count distinct plan types per user — **avg 5.00** (5/5/5/5)
- `COUNT(DISTINCT plan_type)` with GROUP BY user_id; ('starter','starter','pro')→2. Correct.
- VERIFIED: count(DISTINCT x) = exact distinct count of non-null values; approx_distinct is the approximation (~2.3% std error) for huge sets. Responder's >10M-rows / "exact and fast enough for dashboards" framing is apt and actionable.

### Q3 — first 20 chars of a string — **avg 4.875** (5/5/4.75/4.75)
- `SUBSTR(display_name, 1, 20)` — 1-based, length 20, returns fewer if shorter. Correct.
- VERIFIED: substr/substring exist (substr is alias), 1-based, 3-arg length form; **Trino 467 has NO LEFT()/RIGHT()** — confirmed (string.html does not list them). Responder's "NO LEFT() in Trino 467" claim is accurate; substr is the idiom.
- The RPAD-to-pad-to-20 aside is correct and a nice touch.
- Trivial: didn't note display width vs codepoint count for multibyte (substr counts characters); irrelevant for the asked truncation use case. Negligible ding.

### Q4 — round cents/100 UP to whole dollar — **avg 4.75** (5/5/4.75/4.75)
- `CEIL(amount_cents / 100.0)`; 201→2.01→ceil 3.0. Correct.
- VERIFIED: ceil = ceiling alias, "rounds up to nearest integer"; integer `/` truncates in Trino → the `.0` on 100 is load-bearing (forces non-integer division, else `201/100=2` truncated before ceil). Responder explicitly called this out: "integer division would truncate before CEIL." Exactly the right warning.
- Minor type nuance (per directive = minor only): ceil returns same type as input → here `amount_cents/100.0` is a double/decimal so result is `3.0` not integer `3`. Engineer may want CAST(... AS integer) for a clean dollar integer; responder didn't mention. Per directive this is minor-not-error. Slight actionability ding.

---

## Verdict
- **Q1 bool_and-NULL fix LANDED → CLOSED.** This is the 1st post-fix clean datapoint at the bool_and-NULL angle (iter824 Q4 was the defect). Needs ONE more angle (e.g. bool_or-any-true with NULLs, the all-NULL-group→NULL edge, or every() alias) to bulletproof — do not over-claim full lock on a single re-probe.
- No new defects. Q2/Q3/Q4 all clean, dialect-accurate.

## iter826 directive — **DEFAULT NO-OP / durability sweep**
All clean; no open defect; no resource edits required.
- Re-probe bool_and/bool_or NULL from a 2nd angle to bulletproof the closed fix: `bool_or` over a group with NULLs (any-true ignoring NULL), an all-NULL group returning NULL (not FALSE), or the `every()` alias phrasing. Keyword anchors already seeded at r07:1252 + r23 §3.1.
- 3 fresh adjacent probes (e.g. distinct-count-with-FILTER, substr negative-start-from-end, ceil-vs-floor-vs-round disambiguation).
- PRESERVE: r07/r23 bool_and/bool_or IGNORE-NULL cards + `bool_and(COALESCE(flag,false))` canonical + defang (LANDED); iter824 split_part GROUP-BY-1 + §8 GROUP-BY-alias asymmetry cards; r23 substr/no-LEFT idiom; ceil `/100.0` integer-division card; r23:606-631 repeat-char card; full iter534-825 pin inventory.
- NO federation edits (r22 §13.x ZERO edits; federation row stays 4.49944/310; margin thin).

DO NOT bump training/state.json (already 825).
