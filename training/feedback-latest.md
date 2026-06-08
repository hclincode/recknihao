# Judge Feedback — iter743 (EXTENDED PHASE)

**Overall: 3.875 PASS** (dim-avg across 4 Q = 15.5/4 = 3.875; margin +0.375 above 3.5 floor). Federation NOT probed — row UNCHANGED. state.json NOT bumped.

All claims verified against trino.io/docs/467 via WebFetch/WebSearch on 2026-06-09 (map.html, array.html, window.html, string.html, datetime.html) — NOT against resources/. Production stack Trino 467 + Iceberg on-prem; none of these answers touch auth/authz, so no prod-fit concerns. ONE real dialect defect this iteration (Q3, both forms).

---

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | map key existence regardless of value | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | first_value / last_value window | 5 | 5 | 4.5 | 5 | **4.875** |
| Q3 | combine DATE + TIME → TIMESTAMP | 1.5 | 3 | 4 | 1.5 | **2.50** |
| Q4 | codepoint of a character (declined) | 4 | 2 | 4 | 2.5 | **3.125** |

**Overall average: 3.875 → PASS**

---

## Q1 verdict — map-key-existence additive CLOSED ✅

DOCS-VERIFIED (map.html + array.html):
- `map_keys(x(K,V)) → array(K)` "Returns all the keys in the map x" — a present-with-NULL-value key still appears in the keys array.
- `contains(array, element) → boolean` "Returns true if the array x contains the element."
- Therefore `contains(map_keys(settings),'beta_opt_in')` is TRUE iff the key is present REGARDLESS of value. CORRECT.
- `element_at(map(K,V), key) → V` "Returns value for given key, or NULL if the key is not contained in the map" — returns the VALUE V, itself NULL when a present key maps to NULL, so `element_at(...) IS NOT NULL` cannot distinguish absent-key from present-key-with-NULL (false-negatives present-with-null). The responder explicitly named this false-negative. CORRECT.

The iter742 reconcile-in-place fix (r09 Existence-check subsection — demote-`element_at-always` → name BOTH forms, contains() = exact-existence, element_at IS NOT NULL = quick value-present check that false-negatives) WORKED. Answer is bulletproof, sourced to r09:650-655. **Map-key-existence additive CLOSED.** No further action.

## Q2 verdict — first_value/last_value CORRECT ✅

DOCS-VERIFIED (window.html): `first_value(x)` "Returns the first value of the window"; `last_value(x)` "Returns the last value of the window." With the SQL-standard default frame (RANGE UNBOUNDED PRECEDING .. CURRENT ROW), FIRST_VALUE correctly returns the partition's first row, but LAST_VALUE only sees up to the current row — so the explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` is required to reach the true last row. The responder applied the frame to LAST_VALUE only (correct — FIRST_VALUE needs none) and explained the default-frame gotcha. Single-pass, both columns. Minor clarity nit only: did not state WHY FIRST_VALUE is safe without the frame (default frame already includes row 1), but the gotcha that matters was nailed. No defect.

## Q3 verdict — BOTH FORMS DEFECTIVE ❌ (drives the score down; fix for iter744)

DOCS-VERIFIED (datetime.html operators table + string.html || + GitHub trinodb/trino #20424):

- **Form (a)** `CAST(session_date AS TIMESTAMP) + (session_start_time - TIME '00:00:00')` — **DEFECT.** Trino 467's date/time operator table lists `date ± interval`, `timestamp ± interval`, `interval ± interval` — but **NO `TIME - TIME` operation**. `TIME - TIME` is not a supported operator in Trino 467, so `(session_start_time - TIME '00:00:00')` does not yield an INTERVAL and the expression fails. Unsupported arithmetic.
- **Form (b)** `CAST(session_date || ' ' || session_start_time AS TIMESTAMP)` — **DEFECT (type error as written).** `||` is the string-concatenation operator (same as `concat()`, character/VARCHAR operands only). Concatenating a DATE and a TIME directly with `||` is a TYPE ERROR; both operands must be CAST to varchar first.

**Canonical for iter744** (verified — there is NO dedicated combine-date-time function in Trino 467; feature request #20424 is still open):
```sql
CAST(CAST(session_date AS varchar) || ' ' || CAST(session_start_time AS varchar) AS TIMESTAMP)
```
i.e. cast each part to varchar, concat to an ISO `'YYYY-MM-DD HH:MM:SS'` string, cast the whole to TIMESTAMP. (Form (a)'s INTENT — add time-of-day as a duration to midnight — could be salvaged only with explicit interval extraction, e.g. building an `INTERVAL` from `hour()/minute()/second()`, which is clunky; the cast-to-varchar-concat-cast is the canonical idiom.) Optionally mention `from_iso8601_timestamp(...)` for ISO-8601 strings.

**TEACHER ACTION (iter744 FIX-A):** Add a combine-DATE+TIME→TIMESTAMP canonical (likely r13 datetime / r27 §4.2 datetime area where the responder sourced r13:5671-5677). Pin the correct CAST-to-varchar-concat-cast form. Inline-defang BOTH wrong forms (iter693 un-copyable style): ❌ `date || ' ' || time` without inner CASTs = type error (|| is varchar-only); ❌ `time_a - time_b` = unsupported (NO TIME-TIME operator in Trino 467). Keyword anchors: combine a date and a time into a timestamp / construct a timestamp from a date and time-of-day / merge DATE column and TIME column / build a timestamp from separate date and time. The bad r13:5671-5677 content the responder cited must be RECONCILED-IN-PLACE (reconcile-don't-append), not just supplemented — the responder pulled both defective forms straight from it.

## Q4 verdict — honest decline; FINDABLE-BUT-MISSING gap (flag for iter744)

DOCS-VERIFIED (string.html): Trino 467 HAS `codepoint(string) → integer` "Returns the Unicode code point of the only character of string" and the inverse `chr(n) → varchar` "Returns the Unicode code point n as a single character string." `codepoint` requires a SINGLE-character input — for the first char of a multi-char string use `codepoint(substr(s,1,1))` (the exact shape the user needs: `codepoint(substr(country_code,1,1))`).

The responder did NOT fabricate (correctly scored on honesty — Accuracy 4) and correctly routed to trino.io/docs/467/functions/string.html, but this is a genuine **findable-but-missing** gap: the function exists and the answer is a clean one-liner. Incomplete (2) and low actionability (2.5) drag the score.

**TEACHER ACTION (iter744 FIX-A):** Add `codepoint`/`chr` to r23 string-functions (alongside the iter739 strpos / ASCII-equivalent content — Oracle `ASCII()`/`ord()` migrants land here). Pin: `codepoint(varchar) → integer` (SINGLE char only); first-char-of-string idiom `codepoint(substr(s,1,1))`; inverse `chr(bigint) → varchar`. Keyword anchors: numeric code point of a character / Unicode code point / ASCII value of a character / Oracle ASCII / ord() equivalent / integer value of a character / char to code point. Worked example for the user's case: `codepoint(substr(country_code,1,1))` → 85 for 'U'.

---

## Summary for teacher (iter744 = FIX-A, two adds)

1. **Q3 (priority):** combine-DATE+TIME→TIMESTAMP — reconcile r13:5671-5677 IN PLACE; canonical = `CAST(CAST(d AS varchar) || ' ' || CAST(t AS varchar) AS TIMESTAMP)`; defang both `||`-without-casts (type error) and `TIME - TIME` (unsupported op). This is a real defect that the responder copied verbatim from the resource.
2. **Q4:** add `codepoint(varchar)→integer` / `chr(bigint)→varchar` + `codepoint(substr(s,1,1))` first-char idiom to r23.

Standing pins (Q1 contains(map_keys), Q2 FIRST/LAST_VALUE-frame) HELD and verified. Federation row (FAIL 4.49944, threshold 4.5) NOT probed — unchanged. No prod-fit (auth/authz) concerns this iteration.
