# Judge Feedback — iter770 (INOCULATION-LIGHT FIX-A verification)

**Mode:** final/extended phase. FIX-A: iter769 surfaced a Q2 synthesis-slip where the responder mislabeled `date_trunc('month',x) - INTERVAL '1' MONTH` as "equivalent" to first-of-next-month. iter770 added a copy-attractive NEXT-month canonical + `INTERVAL '1' MONTH` at r07:3084-3095 with a same-line defang of the minus form. Q1 re-probes it; Q2–Q4 fresh.

All four answers docs-verified against trino.io/docs/467 (datetime / aggregate / conversion / conditional / string .html) on 2026-06-09. Resource fix confirmed in place at resources/07-analytical-query-patterns.md:3084-3095.

---

## Q1 — First of NEXT month (FIX-A re-probe): contract activates June 20 → renewal July 1

Answer: `date_add('month', 1, date_trunc('month', activation_date)) AS renewal_date`. Worked example 2026-06-20 → date_trunc → 2026-06-01 → +1 month → 2026-07-01. Did NOT present the minus form.

**Docs verification (datetime.html):** `date_add(unit, value, timestamp)` verbatim "Adds an `interval value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value." `date_trunc('month', x)` verbatim "Returns `x` truncated to `unit`" — the reference table truncates `2001-08-22` → `2001-08-01 00:00:00`. So `date_add('month', 1, date_trunc('month', 2026-06-20))` = `date_add('month', 1, 2026-06-01)` = `2026-07-01`. CORRECT.

**FIX-A VERDICT: WORKED.** The responder routed straight to the additive form (`date_add(+1, date_trunc('month', x))`), produced the right worked example (June 20 → July 1), and crucially did NOT reproduce the iter769 slip — it never presented `- INTERVAL '1' MONTH` as next-month. The added canonical + same-line minus-form defang + sign rule (r07:3095) steered cleanly.

- Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 → **avg 5.00**

## Q2 — Pivot / conditional aggregation: one row per customer, pending/shipped/cancelled count columns

Answer: Form 1 `SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) AS pending_count` (+ shipped/cancelled) `GROUP BY customer_id`. Form 2 `COUNT(*) FILTER (WHERE status='pending') AS pending_count` (+ others) `GROUP BY customer_id`. Note: FILTER is Trino-native/cleaner; "conditional aggregation is the correct term, not pivot."

**Docs verification (aggregate.html):** FILTER clause confirmed verbatim — "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause"; syntax `aggregate_function(...) FILTER (WHERE <condition>)`. `count(*)` = "Returns the number of input rows." SUM(CASE…) is standard valid Trino. Both forms produce per-customer status columns. The "no PIVOT keyword in Trino, conditional aggregation is the correct term" note is correct. CORRECT.

- Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 → **avg 5.00**

## Q3 — Zero-pad: integer invoice number → fixed 6-digit leading-zero string (42 → '000042')

Answer: `format('%06d', invoice_id)` → '000042'/'001234'; width adjust `%05d`/`%08d`; `format('INV-%06d', invoice_id)` → 'INV-000042'.

**Docs verification (conversion.html):** `format(format, args...)` verbatim "Returns a formatted string using the specified format string and arguments" — links to the Java Formatter syntax (printf-style). Docs example `SELECT format('%03d', 8)` → `'008'` confirms the zero-pad width mechanism; `%06d` applies width 6 the same way → 42 → '000042', 1234 → '001234'. `%d` takes integer types (incl. BIGINT). The `'INV-%06d'` composite-string example is also valid. CORRECT.

- Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 → **avg 5.00**

## Q4 — NULL handling: replace NULL referral_source with 'direct'; count real-value rows vs not

Answer: `COALESCE(referral_source, 'direct')` for the default; `COUNT(*)` counts all rows, `COUNT(referral_source)` counts only non-NULL; `GROUP BY COALESCE(...)`; also `COUNT(*) - COUNT(referral_source) AS users_without_source`.

**Docs verification (conditional.html + aggregate.html):** COALESCE verbatim "Returns the first non-null `value` in the argument list." `count(x)` verbatim "Returns the number of non-null input values"; `count(*)` "Returns the number of input rows." So `COUNT(referral_source)` = rows with a real value, `COUNT(*) - COUNT(referral_source)` = NULL rows. All correct and Trino-valid. CORRECT.

- Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 → **avg 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 first-of-next-month (re-probe) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 conditional aggregation | 5 | 5 | 5 | 5 | 5.00 |
| Q3 zero-pad format('%06d') | 5 | 5 | 5 | 5 | 5.00 |
| Q4 COALESCE + COUNT(col)-vs-COUNT(*) | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 5.00 → PASS** (threshold 3.5; overall average governs, no single-Q veto).

### (a) Is first-of-next-month CLOSED?
**YES — CLOSED (1st clean post-fix datapoint).** The iter770 FIX-A worked: the responder used the additive form, produced the correct June 20 → July 1 worked example, and did NOT reproduce the iter769 minus-form synthesis-slip. **Needs 1 more clean re-probe (from a different phrasing) to BULLETPROOF** — same trajectory as range/spread (iter767 CLOSED → iter768 BULLETPROOFED). Recommend one more first-of-next-month angle at iter771 or iter772 before retiring the pin.

### (b) iter771 designation
**DEFAULT NO-OP / durability-breadth sweep.** No new defect, no new imprecision surfaced across all four answers; all four docs-clean. Teacher = ZERO edits at iter771. Probe 4 fresh adjacent topics. Strongly recommend ONE of the four be a fresh first-of-next-month phrasing (e.g. "next billing cycle starts the 1st of the month after sign-up", or a year-boundary case Dec 20 → Jan 1) to convert CLOSED → BULLETPROOFED. Cross-card check: ensure the new next-month canonical (r07:3084-3095) stays reconciled with the previous-month boundary block immediately above it (r07:3078-3082) — both correct, sign rule at r07:3095 is the disambiguator; no churn.

### Standing pins held
first-of-next-month = `+ INTERVAL '1' MONTH` / `date_add('month', +1, …)` NOT minus (now CLOSED, 1 datapoint) · conditional-aggregation = SUM(CASE) or COUNT(*) FILTER, no PIVOT keyword · format('%06d') zero-pad via Java Formatter · COALESCE + COUNT(col)-vs-COUNT(*) · full iter534–769 inventory intact.
