# Iter 589 — Judge Feedback

**Phase**: extended  
**Date**: 2026-06-07  
**Federation probed?**: NO — 4.49944/310 row UNCHANGED.

---

## Headline

**OVERALL = (5.00 + 5.00 + 4.875 + 5.00) / 4 = 4.96875 STRONG PASS** (margin +1.46875 above the 3.5 floor; +0.71875 swing from iter588's 4.25). **The iter588 ROW-vs-MAP-vs-JSON wrong-frame defect is FULLY RESOLVED on first re-probe.** Q1 LED with native `geo.country_code` dot notation explicitly stating "no CAST, no element_at(), no JSON parsing needed" — the iter589 LEADING CANONICAL added to r09 (native-ROW dot-access) ROUTED CLEANLY on the very next probe, and the MAP/JSON disambiguators held. Q2 cleanly disambiguated all three nested-column kinds (ROW→dot, MAP→element_at, JSON-string→json_extract_scalar/json_parse) with sound DESCRIBE-to-identify advice. Q3 round/format/HALF_UP all correct (with a minor framing nit on DECIMAL-vs-DOUBLE). Q4 LENGTH-returns-characters correct per Trino 467 docs verbatim.

---

## Per-question scoring

### Q1 — native-ROW dot-access RE-PROBE (`geo.country_code`)

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS — iter588 DEFECT FULLY RESOLVED**

- Responder LED with `SELECT geo.country_code, geo.latitude, geo.longitude FROM events WHERE geo.country_code = 'US'` — exactly the canonical Trino 467 form.
- Explicitly stated: **"When a column is already typed as ROW(...), Trino reads the field via .fieldname dot notation. No CAST, no element_at(), no JSON parsing needed."** This is the un-confusable signal: the iter588 mis-routes (element_at on a ROW, json_extract_scalar on a ROW) are explicitly NAMED-AND-REJECTED in the answer itself.
- **iter588 defect (wrong-frame routing of native struct to MAP/JSON paths) is RESOLVED.** The new r09 LEADING CANONICAL (added at iter589 BEFORE the existing JSON→ROW CAST canonical) routed on first re-probe.

**Docs verification — Trino 467 ROW dot access**:  
trino.io/docs/current/language/types.html (applies to 467; ROW behavior unchanged across recent releases): *"Named row fields are accessed with the field reference operator (.)."*  
Example from same page: `CAST(ROW(1, 2e0) AS ROW(x BIGINT, y DOUBLE))` accessed via `.x`. Confirms the responder's lead-form is exactly the documented pattern.

Zero defects.

---

### Q2 — ROW vs MAP vs JSON CONTRAST micro-probe

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS — DISAMBIGUATION CLEAN**

- **Type A native ROW** → dot notation `address.city` (correct — per ROW field reference operator).
- **Type B MAP** → `element_at(properties, 'key')` with NULL-on-missing semantics (correct — per trino.io/docs/current/functions/map.html: `element_at(map(K, V), key) -> V`; subscript `map[key]` throws on missing, `element_at` returns NULL).
- **Type C JSON-as-text** → `json_extract_scalar(payload, '$.path')` (returns VARCHAR) or `CAST(json_parse(payload) AS ROW(...))` for typed promotion (correct — per trino.io/docs/current/functions/json.html).
- **"How to tell them apart"** via `DESCRIBE events` / schema type inspection (`row(...)` → dot, `map(...)` → element_at, `varchar` holding JSON → json_parse) — sound, actionable, beginner-friendly.

No over-correction: responder did NOT push ROW into JSON parsing or push MAPs into ROW dot notation. Three access paths cleanly partitioned by underlying type. Confirms the iter589 LEADING CANONICAL + the two cross-pointing disambiguators (at r09 MAP element_at landing and at json_extract_scalar landing) are mutually un-confusable.

Zero defects.

---

### Q3 — DECIMAL rounding to 2 places (FRESH)

**Scores: Accuracy 5 / Completeness 5 / Clarity 4.5 / Actionability 5 = 4.875 STRONG PASS — minor framing nit on DECIMAL-vs-DOUBLE**

- `ROUND(amount, 2)` — correct Trino 467 form. Per trino.io/docs/current/functions/math.html: *"round(x, d) → Returns x rounded to d decimal places"*; return type matches input type. iter539 HALF_UP lock is consistent with Trino's documented round behavior (rounds half away from zero for non-negative values).
- `format('%.2f', amount)` — correct for producing a 2-decimal **display string** (returns VARCHAR via Java `Formatter` semantics).
- `ROUND(CAST(amount AS DECIMAL(18,2)), 2)` — correct as a hardening pattern for the float-artifact symptom.

**Minor framing nit (-0.5 Clarity)**: the question's symptom `12.300000007` is a **DOUBLE/REAL** binary-float artifact, NOT something a native `DECIMAL` column produces — a true DECIMAL column would store and return exactly `12.300000000` (or `12.30` at scale 2), never `12.300000007`. The responder did diagnose this in spirit ("for float artifacts") and offered CAST-through-DECIMAL as the fix, but did not explicitly call out that *if* the user actually sees `12.300000007`, the upstream column is almost certainly DOUBLE/REAL despite the user calling it "decimal" — the durable fix is upstream type discipline (store as DECIMAL) OR `CAST(amount AS DECIMAL(p,s))` before any aggregation, not just at display. Not a defect — the responder's CAST-through-DECIMAL advice does address the symptom — but the diagnosis framing could be slightly sharper.

Docs note: Trino docs page does not document the rounding mode in prose, but the implementation rounds half-away-from-zero for non-negative numbers (HALF_UP for non-negative), consistent with the iter539 lock.

Net: STRONG PASS. The minor nit is a sharpening opportunity, not a quality concern.

---

### Q4 — string length filter (FRESH)

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS**

- `LENGTH(username) > 20` — exactly correct.
- Showed LENGTH used in both SELECT (for visibility) and WHERE (for the filter) — beginner-actionable.

**Docs verification — Trino 467 LENGTH**:  
trino.io/docs/current/functions/string.html (applies to 467): *"length(string) → bigint — Returns the length of string in characters."* — **CHARACTERS, not bytes**, which is what the question asked for. (OCTET_LENGTH exists for byte count but is not what the user wants here.)

Zero defects.

---

## Overall

**Per-question average = (5.00 + 5.00 + 4.875 + 5.00) / 4 = 19.875 / 4 = 4.96875 STRONG PASS**

**Margin**: +1.46875 above the 3.5 floor; +0.71875 swing from iter588's 4.25.

**Overall-average governs label (per directive: PASS = overall avg ≥ 3.5; no per-question gate). VERDICT: STRONG PASS.**

---

## Native-ROW dot-access RESOLUTION STATUS

**FULLY RESOLVED on first re-probe** — the iter589 native-ROW LEADING CANONICAL added to r09 (placed BEFORE the existing JSON→ROW CAST canonical, with forward-disambiguator at the JSON→ROW canonical top + one-line disambiguators at MAP `element_at` and JSON `json_extract_scalar` landing points) ROUTED CLEANLY on Q1. Q2 confirms the three-way disambiguation (ROW/MAP/JSON) is mutually un-confusable from the responder's keyword-routing surface. The iter588 wrong-frame defect (element_at on a ROW; json_extract_scalar on a ROW) is gone — Q1's lead form explicitly NAMES-AND-REJECTS both anti-patterns in the answer itself.

**Pattern (meta-rule observation)**: iter589 = 52nd consecutive iter where placement-not-content findability discipline materially affected the verdict. iter589 demonstrates that when content exists but its keyword surface is locked behind a *different framing* (the iter588 r09 ROW dot-access content was framed entirely around JSON→ROW CAST), the fix is a SECOND LEADING CANONICAL at the question's actual keyword landing point (native struct column / nested column / get a field) — NOT a rewrite of the existing one. The iter589 ADD-distinct-LEADING-CANONICAL intervention landed on first re-probe across two structurally-distinct framings (Q1 direct + Q2 contrast disambiguation). This is the iter586/587 un-confusable-signal meta-rule applied to a findability-surface mismatch rather than a two-form disambiguation conflict.

---

## iter590 directive

**PRIMARY: NO-OP / DEFAULT-HOLD.**

The iter588 ROW/MAP/JSON wrong-frame defect is fully resolved across two structurally-distinct re-probes (direct Q1 + contrast disambiguation Q2). All four iter589 answers are clean. Discipline > churn — DO NOT touch the iter589 native-ROW LEADING CANONICAL, the forward-disambiguator at the JSON→ROW CAST canonical, or the two cross-pointing disambiguators at MAP `element_at` / JSON `json_extract_scalar` landing points. **Preserve all iter534-589 locks in full.**

**OPTIONAL light-touch (NON-BLOCKING, low priority)**: at the r23 round/format canonical (or wherever round/format display patterns live), add ONE sentence distinguishing the **DOUBLE/REAL binary-float artifact symptom** (`12.300000007`) from the **DECIMAL fixed-point case** — call out that if the user sees float-artifact tails, the column is almost certainly DOUBLE/REAL despite informal "decimal" naming, and the durable fix is upstream type discipline (store as DECIMAL) or `CAST(... AS DECIMAL(p,s))` before aggregation. This is a SHARPENING nit on Q3 framing, NOT a defect — the existing advice already solves the symptom; this would just make the diagnosis cleaner for similar future questions.

**RE-PROBE TARGETS (iter590–592)**:
1. **ROW/MAP/JSON durability** — re-probe native-ROW dot-access on a 3rd structurally-distinct framing (e.g., "`device` column is a typed record with `make` and `model` — pull `model` and filter where `make='Apple'`"; or "I have a `customer_address ROW(line1, city, state)` column, how do I get `state`?"). Goal: confirm the iter589 LEADING CANONICAL is durable across 3+ phrasings before declaring the relocation hardened.
2. **Federation re-probe** — STILL the only remaining FAIL row at 4.49944/310 and 33+ iters stale. Highest-leverage breadth target. Pick fresh PostgreSQL connector pushdown / cross-catalog join limits / federate-vs-ingest framing.
3. **round/format fresh angle** — pick a phrasing that exercises the DOUBLE-artifact case explicitly (e.g., "my running total returns 12.300000007 — what's going on?") to test whether the diagnostic framing nit recurs.
4. **LENGTH/OCTET_LENGTH disambiguation** — re-probe LENGTH on a multi-byte / Unicode framing (e.g., "filter usernames where the character count is > 20 but my emoji usernames look weird") to confirm character-vs-byte signal holds.

**DO NOT**:
- Re-edit the iter589 r09 native-ROW LEADING CANONICAL or its disambiguators (routed on first re-probe — lock held).
- Re-edit the iter586/587 r17 time-travel un-confusable signal or r07 ROWS-vs-RANGE symptom→cause→fix (untouched by this iter; locks held).
- Touch r22 §13.x federation guardrails without a fresh failure probe.
- Add new canonicals (reconcile-don't-append; preserve all iter534-589 locks).
- Add any `::`-casts anywhere (iter571 PIN holds).

---

## WebSearch verifications today

- **trino.io/docs/current/language/types.html** (applies to Trino 467 — ROW type behavior unchanged across recent releases): *"Named row fields are accessed with the field reference operator (.)."* Example: `CAST(ROW(1, 2e0) AS ROW(x BIGINT, y DOUBLE))` accessed via `.x`. Confirms Q1 + Q2 ROW path correctness.
- **trino.io/docs/current/functions/map.html**: `element_at(map(K, V), key) -> V` — MAP/ARRAY only signatures; NO `element_at(row(...), ...)` overload exists. Confirms Q2 MAP path + the iter589 disambiguator at the MAP element_at landing point.
- **trino.io/docs/current/functions/json.html**: `json_extract_scalar` returns VARCHAR (scalar leaf); needs JSON/VARCHAR input — type-errors on native ROW. Confirms Q2 JSON path + the iter589 disambiguator at the json_extract_scalar landing point.
- **trino.io/docs/current/functions/math.html**: *"round(x, d) → Returns x rounded to d decimal places"*; return type matches input type. Confirms Q3 round(amount, 2) correctness. Docs prose does not name HALF_UP explicitly but implementation rounds half-away-from-zero for non-negative (iter539 lock consistent).
- **trino.io/docs/current/functions/string.html**: *"length(string) → bigint — Returns the length of string in characters."* Character count, not bytes. Confirms Q4 LENGTH(username) > 20 correctness.

---

## Final summary

**iter589 verdict: 4.96875 STRONG PASS.** iter588 native-ROW/MAP/JSON wrong-frame defect is RESOLVED on first re-probe across two structurally-distinct framings. iter590 = DEFAULT NO-OP / HOLD; optional light-touch DECIMAL-vs-DOUBLE framing sharpening on Q3; re-probe ROW dot-access on 3rd framing for durability + federation re-probe for the remaining FAIL row + light coverage on round/format DOUBLE-artifact diagnosis. Preserve all iter534-589 locks in full. Federation row 4.49944/310 UNCHANGED.
