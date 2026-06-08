# Judge Feedback — iter740 (EXTENDED PHASE)

**Overall: 4.50 / 5 — PASS** (margin +1.00 over 3.5 threshold; overall avg governs, no per-Q override)

Verified against trino.io/docs/467 (math.html, bitwise.html, datetime.html, binary.html, conversion.html) — NOT against resources/. Production stack: Trino 467 + Iceberg, on-prem; none of these answers touch auth/authz, so no prod-fit concerns. state.json NOT bumped.

| Q | Topic | Acc | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | float-state (is_finite/is_infinite/is_nan) | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | bitwise (bitwise_and / left_shift / bit_count 2-arg) | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | date_format / format_datetime custom display | 2 | 4 | 2 | 4 | **3.00** |
| Q4 | hash/checksum (to_hex(md5(to_utf8(...)))) | 5 | 5 | 5 | 5 | **5.00** |

Overall avg = (5.00 + 5.00 + 3.00 + 5.00) / 4 = **4.50 → PASS**

---

## Q1 — float-state-detection FIX-A: **CLOSED**

Docs-verified (math.html, VERBATIM): `is_finite(x)->boolean`, `is_infinite(x)->boolean`, `is_nan(x)->boolean` all exist. `WHERE NOT is_finite(engagement_ratio)` correctly captures BOTH ±Infinity and NaN (the only finite-failure states), and the `CASE WHEN is_finite(...) THEN ... ELSE NULL` inline-null form is correct. The type nuance is accurate: DOUBLE/REAL are IEEE-754 so div-by-zero yields Inf/NaN (succeeds with garbage -> detect AFTER), whereas INTEGER and DECIMAL div-by-zero ERROR (must guard BEFORE via `NULLIF(sessions,0)` / `try()`). The iter740 r27 §4.4H canonical did its job. **FIX-A CLOSED.** Recommend one 2nd-angle re-probe (e.g. "filter out infinite values" / `0e0/0e0`->NaN phrasing) to bulletproof, then lock.

## Q2 — bitwise FIX-A: **CLOSED**

Docs-verified (bitwise.html, VERBATIM): `bitwise_and(x,y)->bigint`, `bitwise_left_shift(value,shift)`, `bit_count(x,bits)->bigint`. CONFIRMED `bit_count` REQUIRES exactly 2 args; there is NO 1-arg `bit_count` and NO `popcount`; Trino has NO `<<`/`>>` shift operator (function forms only). The responder nailed all of it: literal power-of-two mask `bitwise_and(features,8)<>0` (bit 3 = 8), the dynamic `bitwise_and(features, bitwise_left_shift(1,3))<>0`, `bit_count(features,64)=3`, and the explicit "no `<<`/`>>` operator — use the functions" note. The iter740 r27 §4.4G canonical (incl. the 2-arg/no-popcount defang) did its job. **FIX-A CLOSED.** Recommend one 2nd-angle re-probe before locking.

## Q3 — date_format: **TWO CONFIRMED DEFECTS** (the iter741 flag)

The `format_datetime` (Joda) branch is fully correct (EEEE weekday, `MMM dd, yyyy`, MM=month vs mm=minute all valid). The mapping table is correct. BUT the inline `date_format` examples — exactly the user's headline ask ("weekday 'Monday'") — are broken:

1. **`%A` is INVALID.** Docs-verified (datetime.html): Trino's MySQL-style specifiers are `%a` (abbreviated weekday), `%W` (full weekday name "Sunday".."Saturday"), `%b`/`%M` for month. `%A` is NOT documented and is NOT in the supported set (nor even in the explicit unsupported list `%D %U %u %V %w %X`). `date_format(report_date, '%A')` will NOT produce "Monday" — it renders the literal `A`. The responder's OWN table correctly says `%W`, so the inline SQL contradicts its own table. An engineer who copies the inline SQL gets the wrong weekday output.
2. **DATE vs TIMESTAMP argument.** Docs-verified signature is `date_format(timestamp, format)->varchar`. The example passes `report_date` (a DATE per the column name and the user's "dates" framing) — Trino does not document DATE coercion here; a DATE column generally raises a function-resolution error. Should be `date_format(CAST(report_date AS timestamp), ...)`.

**Q3 verdict: defect confirmed on both counts.** Scored Acc 2 / Applicability 2 because the primary copy-path is wrong, partially rescued by the correct `format_datetime` branch and the (contradictory but correct) mapping table.

### iter741 FIX-A directive (Q3)
Add/repair the `date_format` canonical (wherever the "custom date display / format a date as a string / weekday name" keywords land — likely r27 datetime or r07):
- **PIN the weekday specifier as `%W` (full) / `%a` (abbreviated); explicitly DEFANG `%A` as un-copyable / invalid** (`%A` -> renders literal "A", NOT a weekday). The defang must be inline-marked WRONG and un-copyable (iter693 lesson) so the responder cannot lift it.
- **PIN that `date_format` takes a TIMESTAMP**: a DATE column must be `CAST(d AS timestamp)` (or use `format_datetime` after a cast); make the copy-attractive example use a timestamp column or an explicit CAST.
- Co-locate the MySQL-style <-> Joda mapping (it's already correct) so the table and the inline SQL agree — the current self-contradiction is the tell that the responder synthesized `%A` rather than reading the table.

## Q4 — hash/checksum: correct

Docs-verified (binary.html + conversion.html): `to_utf8(varchar)->varbinary`, `md5(varbinary)->varbinary`, `sha256(varbinary)->varbinary`, `to_hex(varbinary)->varchar`. The `to_hex(md5(to_utf8(col)))` chain is the correct hex-digest idiom; the `concat_ws('||', CAST(... AS VARCHAR), ...)` multi-column fingerprint is sound (concat_ws skips NULLs — fine for fingerprinting); sha256 offered as higher-collision-resistance alternative; deterministic note correct. No defect.

---

## Summary for teacher
- iter740's two pure-addition canonicals (float-state §4.4H, bitwise §4.4G) **both landed and CLOSED** — clean, docs-accurate, copy-ready. Lock candidates after a 2nd-angle re-probe each.
- **Only genuine new gap: Q3 `date_format`** — `%A` invalid (use `%W`) and DATE-needs-CAST-to-timestamp. This is a defect-fix (in-place reconcile), not a pure addition: the responder's own table is right but its inline SQL is wrong, so the resource must make the table and the canonical inline example agree, defang `%A`, and pin the timestamp-input requirement.
- Honesty/accuracy discipline holding; no fabrication observed.
- DO NOT bump training/state.json (judge does not edit state).
