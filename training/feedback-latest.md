# Judge Feedback — iter771

**Mode**: DEFAULT NO-OP / durability-breadth sweep (teacher made ZERO resource edits). Q1 re-probes first-of-next-month at the YEAR BOUNDARY (Dec 12 2026 → Jan 1 2027) to bulletproof it; Q2–Q4 fresh adjacent topics. All four answers docs-verified against trino.io/docs/467 (datetime/string/math .html) on 2026-06-09.

---

## Per-question scores

### Q1 — First-of-next-month, YEAR BOUNDARY (Dec 12 2026 → Jan 1 2027)
Answer: `SELECT date_trunc('month', date_add('month', 1, signup_date)) AS renewal_date`

- **Accuracy: 5** — Verified vs datetime.html. The responder used **trunc-AFTER-add** (`date_trunc('month', date_add('month',1,x))`), which differs from the taught canonical **trunc-BEFORE-add** (`date_add('month',1,date_trunc('month',x))`) but is **mathematically equivalent** for first-of-next-month:
  - trunc-before-add: Dec 12 → Dec 1 → +1mo → **Jan 1 2027**
  - trunc-after-add: Dec 12 → +1mo → Jan 12 2027 → trunc → **Jan 1 2027**
  - Both yield `2027-01-01` with correct year rollover. `date_add('month',1,date)` and `date_trunc('month',x)` are both valid Trino 467 and roll Dec→Jan automatically. CRITICALLY, the responder did **NOT** use the minus form (the iter769 synthesis-slip) and produced the correct year rollover.
- **Completeness: 5** — Explicitly walks the year-rollover step (Dec 2026 + 1 month = Jan 2027, then truncate).
- **Clarity: 5** — "add one month then truncate to month start" is clear, zero assumed knowledge, with a worked Dec→Jan example.
- **Actionability: 5** — Copy-paste ready single expression.
- **Q1 avg: 5.00**

### Q2 — Duration between two dates (days + whole months active)
Answer: `date_diff('day', signup_date, current_date)`, `date_diff('month', signup_date, current_date)`; fractional months via `date_diff('day', signup_date, current_date) / 31.0`

- **Accuracy: 4** — Core verified vs datetime.html: `date_diff(unit, ts1, ts2) → bigint` = (ts2 − ts1) in unit, counting boundaries crossed. `date_diff('day', signup, today)` = whole days; `date_diff('month', signup, today)` = whole months. Both correct, including the boundary-count semantics note. **MINOR IMPRECISION**: the `/ 31.0` fractional-months suggestion systematically UNDER-estimates (avg month ≈ 30.44 days; dividing by 31 makes a true 14 months read as ~13.8), and the responder framed it as "more precise" when it is actually a cruder estimate. Not a dialect/compile error — a rough approximation mildly mislabeled.
- **Completeness: 4** — Answers both required outputs (days + whole months); the fractional add-on is a bonus that is slightly self-undermining.
- **Clarity: 5** — Boundary-crossing explanation is clear and accurate.
- **Actionability: 5** — Both main expressions are copy-ready and correct.
- **Q2 avg: 4.50**

### Q3 — Extract email domain (part after '@')
Answer: `split_part(email, '@', 2) AS email_domain`; alt `substr(email, strpos(email, '@') + 1)`

- **Accuracy: 5** — Verified vs string.html: `split_part(string, delimiter, index) → varchar`, 1-indexed, returns NULL if index > number of parts; `split_part(email,'@',2)` = domain. `strpos(string, substring) → bigint`, 1-indexed, 0 if not found; `substr(string, start) → varchar`. Both forms correct, NULL/0-not-found edges accurate.
- **Completeness: 5** — Primary + alternative, both with edge-case notes.
- **Clarity: 5** — Clear, beginner-friendly.
- **Actionability: 5** — Copy-ready.
- **Q3 avg: 5.00**

### Q4 — Floor integer age to nearest 10 (demographic bands)
Answer: `(age - age % 10) AS age_band` OR `floor(age / 10) * 10 AS age_band`

- **Accuracy: 5** — Verified vs math.html: `%` modulo operator valid; `age - age % 10` = exact floor-to-10 for non-negative ints. `floor(age/10)*10` — integer/integer division truncates in Trino (docs: "integer division performs truncation"), so 25/10=2 → 2*10=20; `floor()` is technically redundant on already-truncated integer division but is harmless and gives the correct result. Both forms give 25→20, 34→30, 39→30 for non-negative ages.
- **Completeness: 5** — Two forms + worked examples.
- **Clarity: 5** — Clear demographic-band framing.
- **Actionability: 5** — Copy-ready.
- **Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 4 | 4 | 5 | 5 | 4.50 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg: 4.875 — PASS** (threshold 3.5)

---

## Teacher feedback / required answers

**(a) Is first-of-next-month BULLETPROOFED?** YES. This is the **2nd consecutive clean datapoint** after iter770 (1st post-fix clean). iter770 hit it at a mid-year boundary (June 20 → July 1); iter771 hits it at the harder **year boundary** (Dec 12 2026 → Jan 1 2027) and the responder produced the correct year rollover, used a valid (alternate-but-equivalent) operation order, and did NOT reproduce the iter769 minus-form synthesis-slip. The iter770 inoculation at r07:3084–3095 (next-month canonical + minus-form same-line defang + sign rule) is holding across phrasings AND across the year boundary. **First-of-next-month = BULLETPROOFED.**

Note on the operation order: the responder used trunc-AFTER-add rather than the taught trunc-BEFORE-add. Both are correct and equivalent for this task — do NOT treat this as drift or penalize it. If anything, it shows the responder understands the operations rather than pattern-matching a single string.

**(b) Q2 `/31.0` verdict:** **MINOR IMPRECISION, not flag-worthy as a blocking defect.** It is a rough approximation (not a dialect/compile error), and the core `date_diff('day'/'month')` answer is correct and well-actioned. The only real issue is the self-undermining "more precise" framing on a cruder estimate. This does NOT drag the overall below threshold (4.875) and does not require an urgent FIX. RECOMMENDATION for a future low-priority polish (not iter772-blocking): if/when the fractional-months topic is touched again, the resource could add a sharper canonical — either `date_diff('day', signup, today) / 30.44` (avg-month-days) or, more correctly, a `date_diff('month', signup, today) + day-fraction` composite — and drop the "/31 = more precise" framing. Hold this as a watch-item, not an open defect.

**(c) iter772 designation:** **DEFAULT NO-OP / durability-breadth sweep.** No open defect surfaced. Q1/Q3/Q4 are clean 5.00s; Q2 is a 4.50 with only a minor, non-blocking imprecision that does not warrant a resource edit. Teacher should make ZERO edits and probe 4 fresh adjacent topics. OPTIONAL (low value): one probe could re-test fractional months / "average months active as a decimal" to see whether the `/31.0` framing recurs — if it recurs in a second datapoint, it graduates from watch-item to a candidate FIX-A. Cross-card: keep the next-month canonical (r07:3084–3095) reconciled with the previous-month block (r07:3078–3082) via the sign rule.

---

## Watch-items for iter772
- Q2 fractional-months `/31.0` "more precise" framing — minor imprecision, NOT an open defect. Re-probe once; promote to FIX-A only if it recurs.
- first-of-next-month — BULLETPROOFED; no further probing required unless a regression appears.
