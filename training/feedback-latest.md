# Judge Feedback — Iter 819 (EXTENDED PHASE)

**Mode:** DEFAULT NO-OP durability sweep (teacher made ZERO resource edits). Federation NOT probed.
**Overall: 4.9375 STRONG PASS** (per-Q 5.00 / 4.75 / 5.00 / 5.00 = 19.75/4; margin +1.4375; overall avg governs, no per-Q veto)

All four answers docs-verified against trino.io/docs/467 (aggregate.html FILTER, array.html contains/array_min, datetime.html format_datetime/date_format) on 2026-06-09. ZERO dialect defects. Production stack = on-prem Trino 467 Iceberg/Hive; all 4 answers fit it.

---

## Per-Question Scores

### Q1 — per-region total + escalated side by side (COUNT FILTER) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5
- `COUNT(*) FILTER (WHERE status='escalated')` VERIFIED: Trino 467 supports the SQL-standard aggregate FILTER modifier for ALL aggregate functions (aggregate.html: "FILTER ... evaluated for each row before it is used in the aggregation ... supported for all aggregate functions").
- Functionally equivalent to `COUNT(CASE WHEN status='escalated' THEN 1 END)` — responder correctly noted both work, FILTER more concise.
- One scan, one row per region, NO join — exactly answers the "no separate query+join" constraint. GROUP BY region + ORDER BY region correct.

### Q2 — array contains a value (contains) — 4.75
Acc 5 / Comp 4 / Clar 5 / Act 5
- `contains(tags, 'onboarding') -> boolean` VERIFIED (array.html: "Returns true if the array x contains the element"). No UNNEST needed — directly answers "UNNEST feels heavy."
- Exact + case-sensitive correctly stated; case-insensitive workaround `contains(transform(tags, x -> lower(x)), lower('onboarding'))` VERIFIED valid (transform(array(T),T->U)->array(U)).
- MINOR completeness ding (Comp 4): did NOT flag the three-valued-logic edge case — `contains` returns NULL (not false) when the target is absent AND the array contains a NULL element (same family as arrays_overlap NULL semantics). Harmless for the asked example ('onboarding' present -> true), so Accuracy stays 5; only a nuance omission.

### Q3 — smallest amount per order (array_min) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5
- `array_min(line_items)` VERIFIED (array.html "Returns the minimum value of input array"); per-row, no explosion — answers "without exploding the array into rows."
- NULL semantics "empty OR contains any NULL -> NULL" CONFIRMED correct (established Trino three-valued semantics; array comparison short-circuits to NULL on any NULL element). Responder surfaced this proactively — good completeness.
- Correctly steered away from CROSS JOIN UNNEST + MIN + GROUP BY as unnecessary explosion.

### Q4 — format timestamp as 'YYYY-MM' (format_datetime / date_format) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5
- `format_datetime(created_at, 'yyyy-MM')` VERIFIED (datetime.html, JodaTime pattern). The GOTCHA — lowercase `yyyy`=year, uppercase `MM`=month, lowercase `mm`=MINUTE so `'yyyy-mm'` silently yields year-MINUTE — is CORRECT and high-value (classic footgun).
- `date_format(created_at, '%Y-%m')` VERIFIED equivalent (MySQL-style %Y=4-digit year, %m=zero-padded month). Both functions take a TIMESTAMP (confirmed).
- DATE vs TIMESTAMP routing is a strong bonus: `substr(CAST(created_at AS varchar),1,7)` for a DATE column is valid (DATE casts to 'YYYY-MM-DD', chars 1-7 = 'YYYY-MM') and cleanly sidesteps the timestamp-only signature. Engineer knows exactly what to do for either column type.

---

## iter820 Directive: DEFAULT NO-OP / durability-breadth sweep

No defect surfaced; all four canonicals docs-correct and copy-attractive. **iter820 = DEFAULT NO-OP** (NOT FIX-A).

- Do NOT churn any card: COUNT FILTER (conditional-aggregation), contains/transform (array membership), array_min NULL semantics, format_datetime/date_format yyyy-vs-mm gotcha + substr-date trick.
- OPTIONAL low-pri inoculation ONLY if a future probe under-scores: a one-line `contains` three-valued-NULL note (returns NULL not false when target absent AND array has a NULL) co-located with the contains card. Do NOT pre-churn — single minor omission, not a recurring pattern.
- Suggest fresh adjacent picks for breadth: `element_at(array,-n)` negative-index last element / `array_position` / `date_trunc('month', ts)` timestamp vs the string-label forms here / `arrays_overlap`.
- HOLD all iter534-818 locks. Federation r22 untouched (4.49944/310, below raised 4.5 bar — known terminal state, do not probe unless bulletproofed angle).

DO NOT bump training/state.json (already 819).
