# Judge Feedback — iter898 (NO-OP durability sweep)

**Overall: 5.00 STRONG PASS** (per-Q 5.00/5.00/5.00/5.00 = 20.00/4 = 5.00; margin +1.50; overall average governs, no per-Q veto). FEDERATION NOT PROBED (4.49944/310 row UNCHANGED). All 4 answers dialect-clean against Trino 467. **iter899 = DEFAULT NO-OP — zero edits, teacher ZERO edits.**

All facts VERIFIED vs trino.io/docs/467 (datetime/window .html) + trino git-tag 467 source (AtTimeZone.java) via WebFetch/WebSearch 2026-06-10. PIN 467.

---

## Q1 — rep deal size vs regional average as +/- delta on every row, no lookup join — 5.0
**A:** `AVG(deal_size) OVER (PARTITION BY region) AS region_avg_deal_size, deal_size - AVG(deal_size) OVER (PARTITION BY region) AS diff_from_regional_avg`. Window AVG, no GROUP BY.

CORRECT. VERIFIED window.html: "All Aggregate functions can be used as window functions by adding the OVER clause" — so `AVG(...) OVER (PARTITION BY region)` returns the partition average on every row WITHOUT a GROUP BY. The window expression is a value, so the inline subtraction `deal_size - AVG(deal_size) OVER (...)` is valid Trino arithmetic and yields the correct +/- delta per row. The "no lookup join" framing is right — the window broadcasts the regional average alongside the raw row in one scan. Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

## Q2 — find email values appearing more than once — 5.0
**A:** `SELECT email, COUNT(*) AS occurrence_count FROM users GROUP BY email HAVING COUNT(*) > 1 ORDER BY occurrence_count DESC`.

CORRECT. Textbook-valid Trino 467: `GROUP BY email HAVING COUNT(*) > 1` returns exactly the email values occurring more than once; HAVING filters post-aggregation on the group COUNT (valid to reference an aggregate in HAVING). `ORDER BY occurrence_count` on the SELECT alias is legal (ORDER BY can reference output aliases). Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

## Q3 — convert UTC timestamp to named timezone (America/Chicago) for display — 5.0 (VERIFIED CAREFULLY)
**A:** `at_timezone(order_timestamp_utc, 'America/Chicago')`; per-row column `at_timezone(o.ts, c.customer_timezone)`; plain TIMESTAMP (no zone) wrap first: `at_timezone(with_timezone(order_timestamp, 'UTC'), 'America/Chicago')`. "Works on timestamps already stored with timezone info."

CORRECT on all four sub-claims — each verified:
- **(a) at_timezone requires TIMESTAMP WITH TIME ZONE.** VERIFIED datetime.html: input/output both typed `timestamp(p) with time zone`; it shifts the actual instant to the target zone. A plain `TIMESTAMP` (no zone) would be a type error — the responder's "works on timestamps already stored with timezone info" caveat is accurate.
- **(b) The plain-TIMESTAMP fix is correct.** `with_timezone(order_timestamp, 'UTC')` tags the wall-clock value AS UTC (producing a TIMESTAMP WITH TIME ZONE), then `at_timezone(..., 'America/Chicago')` converts it. Correct two-step.
- **(c) at_timezone accepts BOTH a literal zone AND a per-row zone column.** The doc only shows literals, so VERIFIED vs trino git-tag 467 source `AtTimeZone.java`: `atTimeZone(@SqlType("timestamp(p) with time zone") long, @SqlType("varchar(x)") Slice zoneId)` — the `zoneId` arg is a plain evaluated `varchar` parameter with NO constant/literal-only annotation, so a per-row `varchar` column (e.g. `c.customer_timezone`) is a valid argument. Aligns with the iter857 at_timezone per-row-column-zone card. (The WebSearch snippet that hedged "docs don't mention per-row" is inconclusive — the SOURCE settles it: column-zone is supported.)
- **(d) with_timezone interprets the wall-clock AS being in that zone (does NOT shift).** VERIFIED datetime.html: input `timestamp(p)` → output `timestamp(p) with time zone`, same clock time preserved, labeled with the given zone (no instant shift). Correct.

All four sub-claims doc/source-correct ⇒ Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.0**.

## Q4 — days since each customer's last order — 5.0
**A:** `WITH latest_orders AS (SELECT customer_id, customer_name, MAX(order_date) AS last_order_date FROM orders GROUP BY customer_id, customer_name) SELECT customer_name, last_order_date, date_diff('day', last_order_date, current_date) AS days_since_last_order FROM latest_orders ORDER BY days_since_last_order DESC`.

CORRECT. VERIFIED datetime.html: `date_diff(unit, timestamp1, timestamp2) → timestamp2 - timestamp1` in the unit; doc example confirms earlier→later is POSITIVE, so `date_diff('day', last_order_date, current_date)` is a positive count of days since a past order (and DESC surfaces longest-dormant customers first). `MAX(order_date) ... GROUP BY customer_id, customer_name` is valid (both non-aggregated columns are in GROUP BY). date_diff on DATE args is valid; for whole-DATE args the day count is exact (no fractional-unit / day-aware caveat applies). Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

---

## Verdict & teacher directive
**NO-OP — declared.** No dialect defect, no findable-but-missing gap surfaced. The Q3 at_timezone/with_timezone signatures were scrutinized per the run-prompt and are fully correct (incl. the per-row zone-column claim, settled against git-tag 467 AtTimeZone.java source). Applied iter882 verify-first: the only suspicious claim (per-row zone column) was VERIFIED correct before judgment — not flagged.

- Do NOT add any "wrong" card for Q1–Q4.
- Do NOT churn the iter857 at_timezone per-row-column-zone card or any with_timezone/at_timezone content — confirmed correct in practice this sweep.
- Re-probe fresh adjacents next sweep. Federation (4.49944/310) remains the only un-passed row — probe only bulletproofed angles.
- Do NOT touch any iter534–897 pin. PIN 467. NO federation edits.
- DO NOT bump training/state.json (already passed; overall 5.00 PASS holds).
