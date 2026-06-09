# Judge Feedback — Iter 838 (EXTENDED PHASE)

**Mode:** DEFAULT NO-OP durability sweep. Teacher made ZERO resource edits. 4 SQL-fundamentals probes (date_trunc('week') Monday re-probe + CASE/IF NULL + ceil-round-up-to-5 + INTERSECT). All dialect claims verified against trino.io/docs/467 on 2026-06-09.

**Overall: 5.00 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 5.00 = 20.00 / 4; margin +1.50 above 3.5 floor; overall avg governs, no per-Q veto).

Federation NOT probed this iter — row stays 4.49944 / 310 (still FAIL, untouched).

---

## Per-question scores

### Q1 — weekly signup totals, weeks Monday–Sunday, one row per week — 5.00
- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5**
- `date_trunc('week', signup_timestamp)` + `GROUP BY date_trunc('week', signup_timestamp)` ORDER BY week_start — clean, no manual date math.
- VERIFIED trino.io/docs/467/functions/datetime.html: `date_trunc('week', ts)` ALWAYS returns the **Monday** of the ISO-8601 week, deterministic. Doc example `date_trunc('week', 2001-08-22 [Wed]) -> 2001-08-20 [Mon]` confirms. Responder's own worked example `DATE '2020-01-01' [Wed] -> 2019-12-30 [Mon]` is correct. No locale / no first_day_of_week / no Sunday-start option.
- **CRITICAL RE-PROBE RESULT — HEDGE DID NOT RECUR.** Responder led cleanly with `date_trunc('week',...)` and stated "ALWAYS returns the MONDAY of that ISO week" with NO Sunday/locale/"depends on system week start" hedge. The iter837 Q2 hedge ("depends on system week start Sun/Mon") is **CONFIRMED a one-off responder slip, NOT a content gap.** The r07:2079-2103 week-anchor card (TRUTH 1: always Monday, no Sunday option, no locale, no first_day_of_week) is doing its job. No edit warranted.

### Q2 — CASE returning no value (NULL) for some rows — 5.00
- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5**
- "Yes — CASE returns NULL." Searched CASE with no ELSE -> NULL for unmatched rows; 2-arg `IF(cond, x)` -> NULL when false.
- VERIFIED trino.io/docs/467/functions/conditional.html: CASE with no matching condition and no ELSE returns NULL; `IF(condition, true_value)` returns NULL and does not evaluate true_value when the condition is false. BOTH claims correct.
- Correctly told the engineer NULL in the result set is valid and needs no app-layer handling. Cited resource 23.

### Q3 — round price-in-cents UP to nearest 5 cents (103->105, 100->100) — 5.00
- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5**
- `CAST(ceil(price_cents / 5.0) * 5 AS integer)`. Worked: 103 -> ceil(20.6)*5 = 21*5 = 105; 100 -> 20*5 = 100. Correct.
- VERIFIED trino.io/docs/467/functions/math.html: `ceil(x)/ceiling(x)` rounds toward +infinity; `floor(x)` -inf; `truncate(x)` toward zero. The `/ 5.0` is **load-bearing** — it forces non-integer (float/decimal) division so `103/5.0 = 20.6` survives to ceil; integer `103/5` would truncate to 20 BEFORE ceil and silently break the round-up. Responder correctly used `5.0` and explained ceil/floor/truncate distinction.

### Q4 — users active in BOTH months (set intersection) — 5.00
- **Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5**
- `SELECT user_id FROM last_month_active_users INTERSECT SELECT user_id FROM this_month_active_users` + equivalent INNER JOIN + DISTINCT alt.
- VERIFIED trino.io/docs/467/sql/select.html: INTERSECT defaults to INTERSECT DISTINCT — returns DISTINCT rows present in BOTH queries, dedups automatically. NULL-safe vs IN-subquery (correct framing). INNER JOIN + DISTINCT equivalence is correct (DISTINCT collapses the join's duplicate matches to one row per user_id). Cited resource 23.

---

## Dimension cross-check
Acc 5.00 / Comp 5.00 / Clar 5.00 / Appl 5.00 = 5.00. Agrees with per-Q average. **GOVERNING LABEL = PASS.**

## Defects / gaps
NONE. Zero dialect errors, zero hedges, zero findability misses. All four critical verification targets PASSED.

## iter839 directive — DEFAULT NO-OP / durability sweep
No open defect; no FIX-A. Do NOT pre-churn. The Q1 date_trunc('week')-Monday re-probe came back **CLEAN** — the iter837 Sunday/locale hedge is a confirmed one-off slip, so the narrow week-anchor exception remains satisfied with ZERO edits.

**DO NOT:** touch r22 §13.x federation (4.49944/310 thin, ZERO probe iter838); re-edit the r07:2079-2103 week-anchor card or iter837 string->DATE / MySQL-vs-Joda disambiguator; churn the CASE/IF NULL, ceil-round-up-to-5 (`/5.0` load-bearing), INTERSECT/EXCEPT set-op, iter836 lpad/format pad+truncate, iter831 month-name, iter823 repeat-char, iter825/827 bool NULL cards; add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), DISTINCT ON (iter634 ban); fabricate dayname()/initcap; touch iter534-837 locks; bump training/state.json (already 838); git commit/push beyond appending the rubric score-history line.

Suggested fresh adjacent picks for iter839 if probing: `UNION ALL` vs `UNION` dedup cost, multi-branch searched CASE, `floor(x/N)*N` round-DOWN-to-N (FLOOR sibling of the ceil card), `least`/`greatest` row-wise NULL-poison.
