# Judge Feedback — iter894 (EXTENDED PHASE, NO-OP durability sweep)

**Overall: 4.94 / 5.00 — STRONG PASS** (per-Q 5.00 / 4.875 / 5.00 / 4.875 = 19.75 / 4 = 4.9375; margin +1.44 over the 3.5 threshold; the OVERALL AVERAGE governs — no per-question override).

**Federation NOT probed this iter** — the Trino-federation row (4.49944 / 310, FAIL) is UNCHANGED.

**iter894 was a NO-OP durability sweep** — week-of-year re-probe (iter893 slip recurrence test) + 3 fresh adjacents. All 4 answers dialect-clean. **The iter893 Q4 ISO-week-1 slip did NOT recur** (see Q1 below) → week-of-year topic CONFIRMED CLEAN.

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | week-number-of-year (1-53) to compare week 12 across years | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q2 | split full_name into first/last (split_part) | 5.0 | 4.5 | 5.0 | 5.0 | **4.875** |
| Q3 | collapse runs of spaces to a single space (regexp_replace) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q4 | day-of-month with highest average purchase value | 5.0 | 4.5 | 5.0 | 5.0 | **4.875** |

---

## Q1 — WEEK-OF-YEAR SLIP RECURRENCE VERDICT: **ONE-OFF — CLEAN — slip did NOT recur**

The iter893 Q4 answer carried an INACCURATE ISO-8601 rationale ("week 1 = first week containing a Monday"). The iter894 Q1 re-probe of the SAME concept gave the **CORRECT** rationale:

> "Week 1 is the week containing the **FIRST THURSDAY** of the year, weeks 1-53, week always starts Monday."

This is the **textbook-correct ISO-8601 week-date definition**. VERIFIED (WebSearch Wikipedia *ISO week date* + *ISO 8601*, 2026-06-10): ISO week 1 = the week containing the year's first Thursday (equivalently the week containing January 4, equivalently the earliest week with ≥4 January days); weeks start Monday. The responder's "first Thursday" framing is exactly right.

**Therefore the iter893 "first Monday" framing was a RESPONDER SYNTHESIS SLIP / ONE-OFF, NOT a content defect.** Week-of-year is CONFIRMED CLEAN. **NO FIX-A needed; iter894 = NO-OP** (scope check is moot — the responder produced the correct rationale unaided, so there is no "first Monday" card to hunt; do NOT add a "wrong" card, do NOT churn the week_of_year/EXTRACT(WEEK) SQL or the Monday-week-start fact).

Q1 Accuracy = **5.0** (per the run-prompt directive: first-Thursday framing correct → Acc 5.0).

---

## Verification (all vs trino.io/docs/467, WebFetch/WebSearch 2026-06-10)

**Q1 — 5.00 — CORRECT.** `week_of_year(order_date)` (alias `week()`) or `EXTRACT(WEEK FROM order_date)`; ISO-8601, week 1 = week containing the first Thursday, weeks 1-53, weeks start Monday.
- VERIFIED functions/datetime.html: `week(x)` "Returns the **ISO week** of the year from x. The value ranges from 1 to 53." `week_of_year(x)` "This is an alias for week()." `EXTRACT(WEEK FROM x)` returns the ISO week (same 1-53 range). Function names, EXTRACT equivalence, and the 1-53 range all CONFIRMED.
- VERIFIED ISO-8601 week-1 characterization (WebSearch): "first Thursday" = "containing Jan 4" = "earliest week with ≥4 January days"; Monday week-start. Responder's framing is the standard definition — fully accurate, no slip.

**Q2 — 4.875 — CORRECT.** `split_part(full_name,' ',1) AS first_name, split_part(full_name,' ',2) AS last_name`, with the honest caveat that multi-word last names ("Robert De Niro" → "De") need app/dbt logic.
- VERIFIED functions/string.html: `split_part(string, delimiter, index)` "Splits string on delimiter and returns the field index. Field indexes start with **1**. If the index is larger than the number of fields, then **null** is returned." So `split_part(...,1)` / `split_part(...,2)` are valid and 1-based.
- The honest "Robert De Niro → De is wrong; SQL alone can't parse arbitrary names" caveat is **APPROPRIATE, not a defect** — it is exactly the right scoping for the engineer (parsing arbitrary human names is genuinely out of reach for a single delimiter split). Good judgment.
- Minor completeness nit only (−0.5 Comp): docs say out-of-range index returns **NULL** (not empty string). A single-word `full_name` (no space) makes `split_part(...,2)` return NULL — worth a one-line "single-word names → last_name is NULL" note. The responder did NOT incorrectly claim it returns '' (the run-prompt's "returns ''" premise is wrong, but the responder's actual answer doesn't assert it), so there is NO accuracy defect. Optional micro-anchor only.

**Q3 — 5.00 — CORRECT.** `regexp_replace(user_input,'\s+',' ')` to collapse whitespace runs; `trim(regexp_replace(...))` to also strip the ends.
- VERIFIED functions/regexp.html: `regexp_replace(string, pattern, replacement) → varchar` 3-arg form exists, "Replaces every instance of the substring matched by the regular expression pattern in string with replacement." "All of the regular expression functions use the **Java pattern** syntax" — so `\s` is the Java whitespace class and `\s+` matches one-or-more whitespace.
- The single-quoted literal `'\s+'` correctly passes the literal backslash-s to the regex engine: Trino standard string literals do NOT interpret backslash escapes (backslash is an ordinary character), so `'\s+'` reaches the Java regex engine intact as the whitespace-class pattern. CONFIRMED correct. Wrapping in `trim(...)` to also strip leading/trailing whitespace is the right finishing touch.

**Q4 — 4.875 — CORRECT.** `SELECT EXTRACT(DAY FROM order_date) AS day_of_month, AVG(order_value) AS avg_value FROM ... GROUP BY EXTRACT(DAY FROM order_date) ORDER BY avg_value DESC LIMIT 1`.
- VERIFIED functions/datetime.html: `day(x)` "Returns the **day of the month** from x"; `day_of_month(x)` is an alias for `day()`; `EXTRACT(DAY FROM x)` maps to `day()` and returns day-of-month (1-31). The grouping/aggregate/order/limit pattern is idiomatic Trino 467. `AVG(order_value)` over the per-day groups + `ORDER BY avg_value DESC LIMIT 1` correctly returns the single highest-average day.
- Minor completeness nit only (−0.5 Comp): on an exact tie (two calendar days with identical average), `LIMIT 1` returns an **arbitrary** one with no deterministic tiebreaker. A one-line "ties → arbitrary pick; add a tiebreaker or use RANK() to surface all tied days" note would bulletproof it. Minor only — not an accuracy defect.

---

## Verdict & directive for iter895

- **PASS — overall 4.94, margin +1.44.** All 4 dialect-clean against trino.io/docs/467.
- **Q1 week-of-year slip = ONE-OFF; week-of-year CONFIRMED CLEAN.** The iter893 "first Monday" rationale did NOT recur; the responder gave the correct first-Thursday/ISO-8601 framing unaided.
- **NO genuine findable-but-missing gap and NO dialect defect surfaced.** **iter895 = DEFAULT NO-OP.** Teacher: ZERO edits.
- Optional findability micro-anchors only (skip if they churn any pin): (Q2) "single-word name → split_part(...,2) returns NULL" near a split_part card; (Q4) "ties → LIMIT 1 arbitrary; use RANK() to surface all" near a top-N card. Neither is required.
- Per the iter882 lesson: did NOT flag any correct claim as a defect — every fact was verified vs trino.io/docs/467 (datetime / string / regexp .html) + WebSearch ISO-8601 first. Do NOT add any "wrong" card for Q1-Q4. Do NOT touch any iter534-893 pin. PIN Trino 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed).
