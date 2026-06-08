# Judge Feedback — iter742 (EXTENDED PHASE)

**Overall: 4.875 STRONG PASS** (per-Q avg 19.5/4; dim-avg 4.875; margin +1.375 above 3.5 floor). Federation NOT probed — row UNCHANGED.

All four answers verified against trino.io/docs/467 (datetime / aggregate / regexp / map / array) via WebFetch on 2026-06-09 — NOT against resources/. Production stack: Trino 467 + Iceberg, on-prem; none of these answers touch auth/authz, so no prod-fit concerns. ZERO dialect defects this iteration. state.json NOT bumped.

## Per-question scores

### Q1 — 12-hour AM/PM time (date_format 2nd-angle re-probe) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5.
- VERIFIED datetime.html: `%l` = hour 1-12 (no leading zero), `%i` = minute 00-59, `%p` = AM/PM — all VERBATIM correct → `'%l:%i %p'` → `'2:05 PM'`. CONFIRMED there is NO `%A` specifier (none used; clean).
- `date_format(timestamp, format)` signature: column `event_timestamp` is already a TIMESTAMP, so NO CAST needed — correct. (Contrast iter740 defect where a bare DATE was passed without CAST — not repeated here.)
- Joda equivalent `format_datetime(event_timestamp, 'h:mm a')` is the documented MySQL→Joda mapping (`h`=clockhour-of-halfday 1-12, `mm`=minute, `a`=halfday AM/PM). Correct.
- **date_format VERDICT: STAYS CLOSED → BULLETPROOFED.** 2nd consecutive clean datapoint after the iter741 FIX-A (r27 §4.2 weekday `%W`/`%a` + `%A`-defang + DATE-needs-CAST PIN). The friendly-12-hour-time phrasing is a distinct angle from the weekday-name phrasing that drove iter741, and the responder nailed both the MySQL and Joda branches with no invalid specifier and no spurious CAST. Add r27 §4.2 date_format canonical to the lock inventory.

### Q2 — variance / stddev (fresh) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5.
- VERIFIED aggregate.html: `variance(x)` = alias of `var_samp(x)` (sample, n-1); `stddev(x)` = alias of `stddev_samp(x)` (sample); `var_pop(x)`/`stddev_pop(x)` = population (n). All exist, all → double.
- Responder correctly led with `VARIANCE()`/`STDDEV()` for the spread question, explained stddev = sqrt(variance) in the same units, gave the ~68%-within-±1σ intuition (beginner clarity), and correctly named `STDDEV_POP`/`VAR_POP` for the full-population case. The sample-vs-population distinction is exactly right.

### Q3 — strip non-digits (regexp_replace, fresh) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5.
- VERIFIED regexp.html: `regexp_replace(string, pattern, replacement)` replaces EVERY match (not just first); functions use Java pattern syntax, so the negated char class `[^0-9]` + empty replacement strips all non-digits → `'(415) 867-5309'` → `'4158675309'`. Exactly correct and the cleanest idiom.

### Q4 — map key existence (fresh) — 4.50
Acc 5 / Comp 3 / Clar 5 / Act 5.
- VERIFIED map.html: `element_at(map, key)` returns NULL when the key is absent — so `element_at(m,k) IS NOT NULL` is a valid existence test FOR THE ASKED SCENARIO (map values are non-null literals like `'dark'`/`'off'`). The `CASE WHEN ... IS NOT NULL THEN true ELSE false` and the WHERE-filter forms both work and run clean. The "do NOT write `cardinality(element_at(...))`" defang is correct (element_at returns a scalar value here, not a collection — type error).
- **EDGE-CASE NUANCE (the only ding):** docs confirm `element_at` ALSO returns NULL when the key is PRESENT but its VALUE is NULL. So `element_at(m,k) IS NOT NULL` reports a present-with-null-value key as ABSENT — a false negative. The exact key-existence test that distinguishes this is `contains(map_keys(m), k)` (VERIFIED array.html `contains(x, element) → boolean`; map_keys → array(K), so `contains(map_keys(user_preferences), 'theme')` is the precise form). The responder did not mention this. It is NOT a defect for the asked example (non-null string values), so Acc stays 5; it is a Completeness gap only → Comp 3.

## iter743 flag (additive note, LOW priority — NOT a defect)
**FLAG worth an additive note:** In the map key-existence canonical (r09 / r07 §1a wherever `element_at` NULL-safe lookup lives), add a short note that `element_at(m,k) IS NOT NULL` is the common-case existence test BUT is a false-negative when a key maps to a NULL value, and that `contains(map_keys(m), k)` is the exact present-vs-absent test (distinguishes present-with-null-value). Keep it as a co-located one-liner/PIN next to the existing element_at content — do NOT churn the bulletproofed map(keys,values) canonical. This is additive findability/completeness, not a correction; the current answer is correct for the scenario asked.

## Summary
4 answers, 0 dialect defects, all VERIFIED against trino.io/docs/467. date_format is now BULLETPROOFED (2nd clean datapoint, distinct angle). variance/stddev and regexp_replace strip-non-digits are clean fresh datapoints. The only forward item is the additive `contains(map_keys(m),k)` exact-existence note for the present-with-null-value edge case. Honesty/accuracy discipline holding. Federation untouched (4.49944 vs 4.5 thin). DO NOT bump training/state.json.
