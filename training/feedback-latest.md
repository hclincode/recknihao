# Judge Feedback — iter753

DEFAULT durability-breadth, 4 fresh picks. All dialect claims VERIFIED against trino.io/docs/467 (regexp/json/aggregate .html + sql/select.html) on 2026-06-09.

## Q1 — Reformat 10-digit phone "5551234567" -> "(555) 123-4567" (REARRANGE captured pieces into a new pattern)

Answer: `CONCAT('(', SUBSTRING(phone,1,3), ') ', SUBSTRING(phone,4,3), '-', SUBSTRING(phone,7,4))`. Explained 1-based substring + concat/|| stitching. Did NOT mention `regexp_replace` with `$1/$2` backreferences AT ALL.

DOCS-VERIFIED:
- The substring+concat answer is ACCURATE valid Trino 467 — `substring(s,start,len)` is 1-based, `concat`/`||` stitch correctly, and it produces exactly "(555) 123-4567" for a fixed 10-digit input. Not a wrong answer.
- The form the question explicitly asked for ("the replacement reuses pieces of what was matched — the captured groups") is `regexp_replace(phone, '(\d{3})(\d{3})(\d{4})', '($1) $2-$3')`. Confirmed at trino.io/docs/467/functions/regexp.html: "Capturing groups can be referenced in `replacement` using `$g` for a numbered group" — Trino uses `$1/$2`, NOT `\1`. The responder never surfaced this idiom.

RESOURCE STATE (grep-confirmed): The regexp_replace-backreference canonical EXISTS — r27 nuance #3 (r27:1058) has the worked `regexp_replace(phone, '(\d{3})(\d{4})', '$1-$2')` -> `555-1234` example, and the DO-NOT-WRITE row (r27:1136) correctly marks `\1` WRONG vs `$1` RIGHT. So the `$1`-not-`\1` PIN is intact and consistent. BUT this content lives in an Oracle-MIGRATION table ("the four migration nuances"), NOT in a phone-reformat LEADING CANONICAL with findable keyword anchors. The ONLY LEADING CANONICAL carrying phone-number keywords (r27:1105) is the STRIP-non-digits idiom ("clean a phone number", "remove punctuation/dashes") — which routes a "reformat phone" question to substring/strip content, NOT to the rearrange-with-capture-groups backreference form. This is a LANDING-POINT / FINDABILITY MISS: the right canonical exists but the phone-reformat + "rearrange captured pieces" keywords do not route there.

- Accuracy 4 (substring+concat is correct and runs; only missing the more-idiomatic form) / Completeness 3 (omitted the regex-backreference approach the question explicitly described) / Clarity 4 (clear, but a beginner who asked for "reuse the matched pieces" gets no regex path) / Actionability 3 (works for fixed 10-digit, but brittle vs variable input; engineer not pointed at the general capture-group tool) — **avg 3.50**

## Q2 — User IDs present in BOTH row-sets (logins ∩ purchases) as rows

Answer: `SELECT user_id FROM logins_this_week INTERSECT SELECT user_id FROM purchases_this_week`. Explained INTERSECT = rows in both, semi-join, dedupes by default.

DOCS-VERIFIED (trino.io/docs/467/sql/select.html): "INTERSECT returns only the rows that are in the result sets of both"; defaults to DISTINCT when neither DISTINCT/ALL specified. Native row-set operator. Correctly distinct from array_intersect (array function). Responder fully correct.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q3 — One JSON object per row from columns (order_id, status, total_amount) for a webhook

Answer: PRIMARY `json_format(CAST(MAP(ARRAY[...keys], ARRAY[...values]) AS JSON))`; ALTERNATIVE `json_format(CAST(CAST(ROW(...) AS ROW(order_id BIGINT, status VARCHAR, total_amount DECIMAL)) AS JSON))`. Explained json_format converts JSON->varchar, engine handles escaping.

DOCS-VERIFIED (trino.io/docs/467/functions/json.html):
- `CAST(MAP(...) AS JSON)` produces a JSON OBJECT keyed by map keys — docs example `CAST(MAP(ARRAY['k1','k2','k3'], ARRAY[1,23,456]) AS JSON)` -> `{"k1":1,"k2":23,"k3":456}`. MAP approach is CORRECT for the object shape.
- IMPORTANT correction to the run-prompt caution: in Trino 467 `CAST(<named ROW> AS JSON)` produces a JSON OBJECT WITH FIELD NAMES, not a bare array. Docs example verbatim: `CAST(CAST(ROW(123,'abc',true) AS ROW(v1 BIGINT, v2 VARCHAR, v3 BOOLEAN)) AS JSON)` -> `{"v1":123,"v2":"abc","v3":true}`. Because the responder cast to a NAMED row type (order_id/status/total_amount), the ROW alternative ALSO yields the desired `{"order_id":123,...}` object. No defect — the ROW claim is accurate for named-row casts. (The array-output behavior only applies to anonymous/unnamed ROW.)
- `json_format` correctly serializes JSON->varchar. Both approaches valid and idiomatic.
- Minor completeness note: Trino 467 ALSO has native SQL-standard `json_object()` / `json_array()` constructors (one-call). Not required, but the cleanest single-call alternative; absence is a minor incompleteness, not an error.

- Accuracy 5 / Completeness 4 (correct; could mention native json_object() one-call form) / Clarity 5 / Actionability 5 — **avg 4.75**

## Q4 — Per customer, product name from EARLIEST order (min order_date), aggregate, no window/self-join

Answer: `min_by(product_name, order_date) AS first_product ... GROUP BY customer_id`. Explained min_by(x,y) returns x at min-y row, one pass; noted ROW_NUMBER for multi-column needs.

DOCS-VERIFIED (trino.io/docs/467/functions/aggregate.html): `min_by(x,y)` "Returns the value of x associated with the minimum value of y over all input values." Native aggregate, works with GROUP BY, single pass, no window/self-join. Responder fully correct, and the ROW_NUMBER caveat for multi-column is a useful honest boundary.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## OVERALL

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 phone-reformat (capture groups) | 4 | 3 | 4 | 3 | 3.50 |
| Q2 INTERSECT | 5 | 5 | 5 | 5 | 5.00 |
| Q3 JSON object per row | 5 | 4 | 5 | 5 | 4.75 |
| Q4 min_by earliest | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (3.50 + 5.00 + 4.75 + 5.00) / 4 = 4.5625 -> 4.56 — PASS** (overall average governs; no single-Q veto, and Q1's 3.50 itself meets threshold).

## iter754 designation: FIX-A (Q1 phone-reformat findability)

Q1 is the only soft spot and it is a genuine LANDING-POINT / FINDABILITY miss, not a dialect error. The regexp_replace-backreference canonical + worked phone `$1-$2` example exist (r27:1058) and the `$1`-not-`\1` PIN is intact, but they sit inside an Oracle-MIGRATION nuance table with no phone-reformat keyword anchors, while the phone-keyworded LEADING CANONICAL (r27:1105) is the STRIP-non-digits idiom. A "reformat phone into (NNN) NNN-NNNN" question routes to strip/substring, not to rearrange-with-capture-groups.

FIX-A specifics for the teacher:
- Add a LEADING CANONICAL (or co-located sub-section) for "REARRANGE / reformat a string by reusing the matched pieces (capture-group backreferences)" with keyword anchors: `reformat a phone number`, `(NNN) NNN-NNNN`, `(555) 123-4567`, `rearrange captured pieces`, `reuse the matched groups in the replacement`, `put the captured groups into a new pattern`, `restructure a string with regex`, `backreference $1 $2`.
- COPY form: `regexp_replace('5551234567', '(\d{3})(\d{3})(\d{4})', '($1) $2-$3')` -> `(555) 123-4567`. Use `$1/$2/$3` (Trino) NOT `\1` (Oracle) — reuse the existing `$1`-not-`\1` defang.
- Place it adjacent to the existing r27 strip-non-digits canonical (r27:1103+) and/or add a co-located cross-ref from the r23/r07 string-function area, so BOTH "clean a phone" (strip) and "reformat a phone" (rearrange) routes are disambiguated and findable.
- ALSO show the substring+concat form as a valid fixed-length alternative (it is correct) but lead with the regex-backreference form for the general "rearrange the pieces" ask.

Q3 secondary: no FIX needed — the run-prompt's CAST(ROW AS JSON)-yields-array worry does NOT apply to NAMED row casts in 467 (verified object output). The existing r09 CAST-AS-JSON canonical is docs-correct. Optionally note native json_object()/json_array() as a one-call constructor, but this is enhancement, not a gap.

All standing pins (regexp_replace-$1-not-\1, INTERSECT-vs-array_intersect, json_format+CAST-AS-JSON, min_by/max_by) verified CONSISTENT and INTACT.
