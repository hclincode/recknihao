# Judge Feedback — iter890 (EXTENDED PHASE)

**Overall: 4.75 / 5 — PASS** (per-Q 5.00 / 5.00 / 4.00 / 5.00 = 19.00 / 4 = 4.75; margin +1.25; overall average governs, no per-Q veto).
**Verdict: PASS.** Federation NOT probed this iteration (the 4.49944/310 row is UNCHANGED).
**iter891 recommendation: LIGHT FIX-A** (one additive findability card for `json_exists` — Q3 is a genuine findable-but-missing canonical gap, NOT a defect; the given answers are not wrong).

All dialect facts verified against trino.io/docs/467 (functions/json.html, functions/regexp.html, functions/string.html, functions/array.html) + WebSearch on trino.io, on 2026-06-10. PIN Trino 467.

---

## Q1 — Bucket age into named ranges (18-24 / 25-34 / 35-44 / 45-54 / 55+) — 5.00

Responder: `CASE WHEN age>=18 AND age<25 THEN '18-24' ... WHEN age>=55 THEN '55+' ELSE 'unknown' END AS age_bucket`.

- **Accuracy 5** — half-open bands (`>=lo AND <hi`) are contiguous with NO gaps and NO overlaps: 25 lands only in 25-34 (excluded from 18-24 by `<25`), and so on up to the open-ended `>=55 -> '55+'`. Valid Trino 467 searched-CASE syntax.
- **Completeness 5** — `ELSE 'unknown'` correctly catches both out-of-domain ages (<18) and NULL (NULL fails every WHEN, falls to ELSE). Nothing missing.
- **Clarity 5** — readable, self-documenting labels.
- **Actionability 5** — drop-in, runs as-is.

**(a) CONFIRMED:** the CASE age-bands are correct — contiguous half-open bands, no gaps/overlaps, NULL/out-of-range handled by ELSE. VERIFIED CASE searched-form is valid Trino 467.

---

## Q2 — Average days between consecutive purchases per customer — 5.00

Responder: `LAG(purchase_date) OVER (PARTITION BY customer_id ORDER BY purchase_date) AS prev`; `DATE_DIFF('day', prev, purchase_date) AS days_since_last`; `WHERE prev IS NOT NULL`; `AVG(days_since_last) GROUP BY customer_id`.

- **Accuracy 5** — canonical consecutive-gap-average. LAG pulls the previous purchase per customer in date order; `date_diff('day', prev, current)` returns (current − prev) in whole days (bigint); the first row per customer has NULL prev (excluded by `WHERE prev IS NOT NULL`, so it does not pollute the average); `AVG ... GROUP BY customer_id` is the per-customer mean gap.
- **Completeness 5** — null-first-row handling explicit; window must be projected in an inner query before the WHERE/AVG (responder did this correctly via the CTE/subquery shape — a window result can't be filtered in the same level's WHERE in 467, no QUALIFY).
- **Clarity 5** — clear naming.
- **Actionability 5** — runnable.

**(b) CONFIRMED:** LAG + `date_diff('day',prev,current)` + `AVG ... GROUP BY customer_id` is the correct per-customer average consecutive-gap. VERIFIED `date_diff(unit, ts1, ts2)` returns ts2−ts1 as bigint.

---

## Q3 — Check whether a JSON KEY EXISTS in a metadata JSON string (presence, not non-null value) — 4.00

Responder (PRIMARY): `json_extract_scalar(metadata,'$.device_type') IS NOT NULL` — **with the honest admission** that it cannot distinguish key-absent from key-present-with-null. (SECONDARY): `contains(map_keys(map_col),'key')` **if** metadata is first converted to a MAP.

- **Accuracy 4** — both given answers are technically VALID and not wrong: for the common non-null case, `json_extract_scalar(...) IS NOT NULL` correctly flags presence, and the responder honestly flagged its own limitation. The map_keys/contains approach is also valid *once you have a MAP*. No false claim was made. The single point off is that the question asked specifically for **key presence, not value** — and the cleaner canonical that answers exactly that was omitted (see below).
- **Completeness 3.5** — **FINDABLE-BUT-MISSING GAP.** Trino 467 ships the SQL/JSON function **`json_exists(json_input, json_path)`** built for exactly this. It works directly on a JSON **string** (no MAP conversion) and distinguishes present-with-null from absent. The responder surfaced neither the function nor that it removes the admitted limitation. The map approach also imposes an unstated cost (you must parse the JSON string into a MAP first), which the responder didn't surface.
- **Clarity 4.5** — clearly explained; the self-admitted limitation is good practice.
- **Actionability 4** — the engineer can act, but is left with a tool whose limitation the responder itself flagged, when a one-call solution exists.

### json_exists verification (CRITICAL)

**(c) CONFIRMED: `json_exists` EXISTS in Trino 467.** Verified on trino.io/docs/467/functions/json.html. Signature (verbatim):

```
JSON_EXISTS(
    json_input [ FORMAT JSON [ ENCODING { UTF8 | UTF16 | UTF32 } ] ],
    json_path
    [ PASSING json_argument [, ...] ]
    [ { TRUE | FALSE | UNKNOWN | ERROR } ON ERROR ]
)
```

Semantics (doc): "determines whether a JSON value satisfies a JSON path specification" — returns `true` if the path evaluates to a non-empty sequence, `false` if empty; default `ON ERROR` value is `FALSE`.

**Key-present-with-null vs key-absent distinction:** with a **strict** path, `json_exists(metadata, 'strict $.device_type')` returns `true` when the key exists (even if its value is JSON null — the path still resolves to a non-empty sequence), and an absent key is a structural error in strict mode that returns the `ON ERROR` default (`FALSE`). So json_exists **does** distinguish present-with-null (true) from absent (false) — exactly what Q3 asked for and exactly what `json_extract_scalar(...) IS NOT NULL` cannot do (it returns NULL for both). This confirms json_exists is the cleaner canonical for "does the key exist".

**VERDICT on Q3:** findable-but-missing GAP worth an iter891 **FIX-A** (additive). The given answers are NOT wrong — do NOT defect-mark or remove them. Add a `json_exists` card so the purpose-built key-existence function is surfaced for this exact question.

---

## Q4 — Normalize product_name to title case ('blue widget' -> 'Blue Widget') — 5.00

Responder: "Trino has NO built-in `initcap`" (honest decline) + `regexp_replace(lower(product_name), '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` + alternative `array_join(transform(split(lower(s), ' '), w -> upper(substr(w,1,1)) || substr(w,2)), ' ')`.

- **Accuracy 5** — every claim verified correct (details below). The primary regexp_replace form matches the **official Trino doc example almost verbatim** (the docs show `regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` -> 'New York').
- **Completeness 5** — gives the no-initcap fact AND two valid workarounds covering both the regex and the split/transform mental models.
- **Clarity 5** — clear.
- **Actionability 5** — both runnable.

**(d) CONFIRMED, all three sub-claims:**
1. **No `initcap`** — VERIFIED absent from functions/string.html (no initcap, no title-case built-in). Honest decline is CORRECT.
2. **`regexp_replace(string, pattern, function)` 3-arg LAMBDA with capture-group array `x[1]`/`x[2]` (1-based)** — VERIFIED VALID on functions/regexp.html. Doc verbatim: "The lambda expression `function` is invoked for each match with the capturing groups passed as an array." Doc example verbatim: `regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` -> 'New York'. 1-based indexing confirmed. The responder's answer is the doc-canonical form.
3. **`array_join(transform(split(...), ...), ' ')` alternative** — VERIFIED VALID: `split(string, delimiter)` -> array, `transform(array(T), function(T,U))` -> array(U), `array_join(x, delimiter)` -> varchar, `substr(string, start[, length])`, `upper`/`lower` all present and correctly composed. (Edge note, completeness nuance only, not a defect: a literal `' '` split won't title-case after hyphens/tabs — irrelevant to the asked 'blue widget' case.)

---

## iter891 RECOMMENDATION — LIGHT FIX-A (additive json_exists card; do NOT defect-mark Q1/Q2/Q3/Q4 answers)

**Single action:** add ONE keyword-anchored, additive `json_exists` card (likely the r07/r23 JSON section — wherever the existing `json_extract_scalar` key-presence content lives, so the responder's keyword landing reaches it).

- LEAD canonical: `json_exists(metadata, 'strict $.device_type')` — returns true if the KEY exists (even when its value is JSON null), false if absent; works directly on a JSON **string**, no MAP conversion.
- State the RULE: `json_exists` answers "does the key exist?" (presence) and DISTINGUISHES present-with-null from absent; `json_extract_scalar(...) IS NOT NULL` answers "is there a non-null value?" and CONFLATES absent with present-null (returns NULL for both); `contains(map_keys(m),'k')` requires the JSON to already be a MAP.
- Doc evidence to cite in the card: trino.io/docs/467/functions/json.html — JSON_EXISTS "determines whether a JSON value satisfies a JSON path specification", returns true for non-empty / false for empty sequence, default `FALSE ON ERROR`; strict-mode absent-key = structural error -> ON ERROR default = false.
- Keyword anchors: does the JSON key exist / check key presence in JSON / json_exists / key present vs null value / does metadata have field / JSON path exists / key existence not value.
- KEEP the existing `json_extract_scalar IS NOT NULL` and `map_keys`/`contains` content (both valid) — cross-link them to the new card; do NOT remove or defect-mark them (iter882 lesson: the given answers are correct, just not the cleanest canonical).
- All SQL FENCED (markdown pipe-escape trap — the JSON path `$.device_type` and any `||` belong in fenced blocks, not table cells).
- NO federation edits (r22 §13.x ZERO — federation row stays 4.49944/310). Do NOT touch any iter534–889 pin. PIN 467. Do NOT bump training/state.json.

**Do NOT add any "wrong" card for Q1/Q2/Q4** — all three are dialect-clean and correct. The Q4 regexp_replace-lambda and array_join/transform forms are the doc-canonical answers; do NOT defang or alter them.

---

### Explicit answers to the run-prompt's two required confirmations

- **(c) Does `json_exists` exist in Trino 467?** YES — verified on functions/json.html. `JSON_EXISTS(json_input, json_path ...)` returns whether the path resolves to a non-empty sequence; with a strict path it distinguishes key-present-with-null (true) from key-absent (false). It is the missed canonical for "does the key exist" and warrants an additive FIX-A card.
- **(d) Is `regexp_replace` with a lambda using `x[1]`/`x[2]` capture indexing valid in Trino 467?** YES — verified on functions/regexp.html. The 3-arg `regexp_replace(string, pattern, function)` invokes the lambda per match with capturing groups passed as a 1-based array; the doc's own example is `regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` -> 'New York', which is exactly the responder's form. No-`initcap` claim is also correct (absent from string.html).
