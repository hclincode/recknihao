# Judge Feedback — iter1058

**Phase:** extended (state.json already at 1058; do NOT bump). Verified BOTH directions vs RAW git-tag 467 source + trino.io/docs. NO federation probe (hard-locked). prod_info.md: on-prem Trino 467 + Iceberg/MinIO/HMS; none of the 4 Qs are auth/federation, so prod-fit is neutral here.

## Per-question scores

### Q1 — subtotals for every combination of date/event_type/plan/region in ONE query
**Accuracy 5 / Clarity 4.75 / Applicability 5 / Completeness 4.5 → 4.8125**

- `GROUP BY CUBE(date, event_type, plan, region)` is the RIGHT operator for "each combination" — verified select.md: "CUBE operator generates all possible grouping sets (i.e. a power set)"; CUBE(4 cols) = 2^4 = **16 grouping sets**. Correct.
- Complex grouping is **column-names-only** ("Only column names are allowed" — select.md); responder used bare columns → compliant. Correct.
- GROUPING() bitmask verified: **MSB = first arg (date), LSB = last arg (region); bit=1 = column ROLLED UP/excluded** (select.md: "bit is set to 0 if the corresponding column is included ... and to 1 otherwise"). Responder's bit VALUES are all correct against this mapping:
  - 0=Detail(0000) ✓ | 1=region rolled(0001) ✓ | 2=plan(0010) ✓ | 3=plan+region(0011) ✓ | 4=event_type(0100) ✓ | 5=event+region(0101) ✓ | 6=event+plan(0110) ✓ | 7=event+plan+region(0111) ✓ | 8=date(1000) ✓ | 15=all(1111)=Grand Total ✓
  - The text labels ("Region Total" etc.) are loose glosses but every bit→label pairing is arithmetically right.
- GROUPING SETS `((date),(event_type),(plan),(region),())` alternative for only-specific-subtotals — valid and a good add.
- **Minor incompleteness (NOT a defect):** the CASE enumerates only 10 of the 16 possible GROUPING values; the 6 combos that roll up date together with others (9,10,11,12,13,14) fall through to NULL row_type. The COUNT(*) aggregation itself is correct for ALL 16 rows — only the human-readable row_type label is NULL for those 6. Illustrative-label sloppiness, dings Completeness/Clarity a fraction. **Per-instance; NOT a resource issue.**

### Q2 — average subscription length in minutes (ended_at NULL = active)
**Accuracy 4.875 / Clarity 4.875 / Applicability 4.875 / Completeness 4.875 → 4.875**

- `AVG(date_diff('minute', started_at, ended_at)) WHERE ended_at IS NOT NULL` — fully correct. Verified datetime.md: `date_diff(unit,t1,t2)` returns **bigint**, `timestamp2 - timestamp1` in complete units (complete minutes, drops fractional). AVG ignores NULLs (aggregate.md); the WHERE guard correctly excludes still-active rows (defensively redundant but right — avoids treating active as 0). Complete-minute granularity is acceptable for "average minutes." Sound.

### Q3 — accounts whose features array does NOT contain 'api_access'
**Accuracy 4.875 / Clarity 4.875 / Applicability 4.875 / Completeness 4.75 → 4.84375**

- `WHERE NOT contains(features, 'api_access')` — correct. Verified array.md: `contains(x, element) -> boolean`, "returns true if the array x contains the element"; NOT negates it. Multi-value extension `NOT contains(...) AND NOT contains(...)` is valid.
- **Subtle 3VL edge unmentioned (minor):** if an array holds a NULL element and the searched value is absent, `contains` can return NULL → `NOT contains` is NULL → row excluded. Typical feature-flag arrays carry no NULLs, so fine in practice. Tiny completeness nick only.

### Q4 — price_str varchar '019.99' (leading zero) from CSV: will casting choke?
**Accuracy 3.0 / Clarity 4.5 / Applicability 4.0 / Completeness 4.0 → 3.875**

- **LEAD is CORRECT:** `CAST('019.99' AS double)` → 19.99 and `CAST(price_str AS decimal(10,2))` for money — varchar→double/decimal parses numeric strings and ignores leading zeros. Verified via conversion.md ("cast can be used to cast a varchar to a numeric value type") + WebSearch confirmation; leading zeros are insignificant in numeric parse. `CAST('019' AS integer)` → 19 (clean integer string) is also fine.
- **ACCURACY DEFECT in the caveat:** the responder claims "`CAST(x AS integer)` ROUNDS half-up, so `CAST('19.99' AS integer)` produces 20." **This is WRONG.** In Trino 467, `CAST(VARCHAR '19.99' AS integer)` does **NOT round — it THROWS** an invalid-cast error, because `'19.99'` is not a valid integer literal (the varchar→integer parse rejects the decimal point; cf. trino issue #23359 on strict varchar→exact-numeric parsing rejecting non-integer chars). The round-half-up behavior the responder is thinking of applies to **`CAST(DECIMAL AS integer)` / `CAST(DOUBLE AS integer)`** (a numeric→integer cast), NOT to a varchar-with-decimal→integer cast. Correct statement: to round you must first `CAST('19.99' AS double)` (or decimal) **then** `CAST(... AS integer)`; the direct varchar→integer on a decimal string errors.
- The wrong claim sits in a CAVEAT/aside — the primary recommendation the engineer would actually use (double/decimal cast) is correct, so partial credit. Accuracy dinged to 3.0.

**Sources:**
- CUBE/GROUPING SETS/GROUPING bitmask: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md
- date_diff: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- contains: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- varchar→numeric cast / strict integer parsing: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/conversion.md ; https://github.com/trinodb/trino/issues/23359

## Overall

| Q | Acc | Clar | Appl | Comp | Avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 4.75 | 5.0 | 4.5 | 4.8125 |
| Q2 | 4.875 | 4.875 | 4.875 | 4.875 | 4.875 |
| Q3 | 4.875 | 4.875 | 4.875 | 4.75 | 4.84375 |
| Q4 | 3.0 | 4.5 | 4.0 | 4.0 | 3.875 |

**Overall average = (4.8125 + 4.875 + 4.84375 + 3.875) / 4 = 4.6015625 → PASS** (overall-average governs; no per-question veto).

## Recommendation — DEFAULT NO-OP

1. **Q1 CASE-label incompleteness** (10 of 16 GROUPING values covered; 6 combos → NULL row_type): per-instance illustrative-label sloppiness. The aggregation is correct for all 16 rows; only the cosmetic label is NULL for 6 combos. NOT a resource defect — **passive monitor / watch (c)**; the CUBE/GROUPING bitmask content in resources is accurate. Do not churn.

2. **Q4 `CAST('19.99' AS integer)` rounds claim:** a **responder accuracy SLIP in a secondary caveat** (broken-secondary-alternative family — the LEAD double/decimal cast is correct; the wrong claim is in an aside). The underlying resource fact is right — Trino numeric→integer CAST rounds half-up (per MEMORY "CAST-to-integer Rounds"); the responder OVER-GENERALIZED that to varchar→integer, where it actually throws. **First occurrence of this varchar-decimal→integer-rounds shape** → per-instance slip, NOT a resource defect, NOT 2-in-2. Monitor; escalate to a LIGHT additive FIX-A only if the "varchar-with-decimal CAST-to-integer rounds (not throws)" shape recurs 2-in-2.

**No resource edit. No commit. No state.json bump (already 1058).**
