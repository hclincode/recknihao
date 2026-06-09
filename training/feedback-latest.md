# Judge Feedback — iter805 (LIGHT INOCULATION FIX-A verification)

**Verified against trino.io/docs/467** (datetime, string, regexp, window, aggregate) on 2026-06-09. All five dialect facts confirmed.

## Per-question scores

### Q1 — QUARTER re-probe: `quarter(invoice_date)` / `EXTRACT(QUARTER FROM invoice_date)`
- Verified: `quarter(x)` returns the quarter of the year, value range **1–4**. `EXTRACT(QUARTER FROM x)` maps to `quarter()`. **No `quarter_of_year` function exists** — confirmed.
- The responder used `quarter()` (the canonical), offered `EXTRACT(QUARTER FROM ...)` as the SQL-standard equivalent, cited the new r07:3077-3087 card, AND explicitly warned against the non-existent `quarter_of_year` alias.
- **The iter804 fabrication did NOT recur.** Clean re-probe.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.0** |

### Q2 — VALUE-AFTER-LABEL re-probe: token after `'ref: '` up to next space
PRIMARY (lead answer) — `split_part(split_part(notes, 'ref: ', 2), ' ', 1)`:
- Verified: `split_part(string, delimiter, index)`, 1-based, multi-char delimiter allowed. Inner `split_part(notes, 'ref: ', 2)` = `'ORD-77 paid in full'`; outer `split_part(..., ' ', 1)` = `'ORD-77'`. **CORRECT.** With `WHERE notes LIKE '%ref: %'` guard. The user gets a working answer.

ALTERNATIVE (regex) — `regexp_extract(notes, 'ref: (\S+)')` claimed to "capture just the token part in group 1":
- Verified: the **2-arg** `regexp_extract(string, pattern)` returns the **WHOLE match** `'ref: ORD-77'`, NOT the capture group. The "captures group 1" claim is **FALSE**. The correct form is the 3-arg `regexp_extract(notes, 'ref: (\S+)', 1)`.
- This is the **exact iter804 2-arg defect** that FIX-A's r23 card (lines 2809-2814) was meant to inoculate. The card is correct and even has a same-line `❌` 2-arg defang at 2814 — yet the responder still emitted the 2-arg form with the wrong group claim in the alternative path.

Verdict: split_part lead is correct and authoritative, so the user is not misled on the main path. But the regex alternative is a copy-able wrong snippet with a false semantic claim → dock.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 3 | 4 | 3 | 3 | **3.25** |

### Q3 — NEXT ROW VALUE: `LEAD(page) OVER (PARTITION BY user_id ORDER BY event_time)`
- Verified: `lead(x)` default offset **1**, returns next row's value; past the last row returns `default_value` or **NULL** if unspecified. Partition reset per user is correct. Cited r07 Pattern B.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.0** |

### Q4 — STDDEV of `latency_ms`
- Verified: `stddev(x)` is an alias for `stddev_samp(x)` (sample, n-1); `stddev_pop(x)` (population, n); `variance`/`var_samp` and `var_pop` analogous. The sample-vs-population distinction is correct. AVG + stddev_samp combined query is a good practical add. Cited r05.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.0** |

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.0 |
| Q2 | 3.25 |
| Q3 | 5.0 |
| Q4 | 5.0 |

**Overall avg = (5.0 + 3.25 + 5.0 + 5.0) / 4 = 4.5625 → PASS** (overall average governs; no single-Q veto).

## Closure verdicts

- **(a) quarter-date-part: CLOSED.** First post-fix datapoint clean — responder used `quarter()` + `EXTRACT(QUARTER FROM ...)`, cited the new card, and warned off `quarter_of_year`. The iter804 fabrication did not recur. Fix worked.

- **(b) regexp_extract-capture-group: NOT FULLY CLOSED.** The split_part PRIMARY is correct (user gets a working answer), but the regex ALTERNATIVE still emitted the bare **2-arg** `regexp_extract(notes, 'ref: (\S+)')` with a FALSE "captures group 1" claim — the precise iter804 defect FIX-A targeted. The r23 card content is technically correct and already has a defang, but the responder still reached for the 2-arg form. The inoculation did not fully take.

- **(c) iter806 designation: FIX-A (stronger regexp_extract 3-arg inoculation).** The 2-arg bug recurred on the regex path despite the iter805 card. Recommended adjustments to the r23 regexp_extract card (around 2804-2814):
  1. Make the **3-arg `, 1` form the only copy-attractive fenced "value after a label" snippet** — the value-after-label / between-markers use case is exactly where the responder reaches for 2-arg, so the 3-arg must be the dominant, top-positioned canonical for that intent.
  2. **Sharpen the 2-arg-with-capture-group defang**: the current `❌` line at 2814 sits below two valid examples; hoist the WRONG-vs-RIGHT contrast directly adjacent to the value-after-label canonical and state the literal output difference (`'ref: ORD-77'` vs `'ORD-77'`) inline so the responder cannot pattern-match the 2-arg shape.
  3. Add a one-line rule near the top: "extracting a value/token after a label ALWAYS uses the 3-arg form with `, 1` — the 2-arg form returns the label too." Keyword-anchor it to "value after a label", "token after", "text between markers".

## Teacher action
- iter806 = FIX-A: stronger regexp_extract 3-arg inoculation per (c). Re-probe value-after-label again next sweep to confirm the 2-arg form is gone.
- quarter-date-part and the standing LEAD / stddev pins are solid — no edits needed there.
