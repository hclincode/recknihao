# Judge Feedback — iter780

**Mode**: Final phase (extended) — DEFAULT NO-OP / durability-breadth sweep. Teacher made ZERO resource edits. Q1 re-probes replace-fixed-char (2nd consecutive datapoint) to bulletproof; Q2–Q4 fresh adjacent topics. All dialect claims verified against trino.io/docs/467 (string.html, math.html, aggregate.html, conversion/types) on 2026-06-09. resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — strip every space from a SKU ("AB 12 CD" → "AB12CD"), literal space, no pattern
Answer: `replace(sku_column, ' ', '') AS sku_normalized` → "AB12CD". LED with plain `replace()` (regex-free, "reach for it for a fixed literal char"); noted nest `replace(replace(...))` for multiple chars. Did NOT use regexp_replace. Cites r27:1141-1160.

- **Verification**: trino.io/docs/467/functions/string.html — `replace(string, search, replace)` "Replaces all instances of search with replace in string" (non-regex); `replace(sku, ' ', '')` removes all spaces → "AB12CD". CORRECT. (2-arg `replace(sku, ' ')` "Removes all instances" is equivalent; responder's 3-arg-with-'' form is also correct.)
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**
- This is the **2nd consecutive clean replace-fixed-char datapoint** (after iter779 Q1), now with a fresh phrasing (remove-spaces vs iter779's underscore→dash). Responder LED with plain replace(), did NOT reach for regexp_replace. The iter778 regexp-over-replace findability nick did NOT recur. The nest-for-multiple-chars note is accurate and useful.

### Q2 — drop decimals of 47.89 → 47 (NOT rounded to 48); user worried CAST-to-int rounds
Answer: `truncate(price_column)` → 47 (toward zero), NOT `CAST(x AS integer)` which ROUNDS half-up (47.89→48, -47.89→-48). floor() = toward -inf, ceil() = toward +inf. Explicitly flags "CAST(x AS integer) drops/truncates" as WRONG — Trino CAST ROUNDS half-up. Cites r07:3920-3944.

- **Verification**: math.html — `truncate(x)` "Returns x rounded to integer by dropping digits after decimal point" (toward zero). Official Trino docs (types/CAST + WebSearch confirmation) — narrowing CAST double→integer ROUNDS, does NOT truncate. floor() rounds down, ceil() rounds up. ALL CORRECT.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**
- Strong, fully on-pin answer. Directly addresses the user's explicit worry (CAST might round) and gives the correct alternative `truncate()`. CAST-rounds-not-truncates pin RE-CONFIRMED. truncate-toward-zero / floor-toward-(-inf) / ceil-toward-(+inf) all correctly distinguished.

### Q3 — per customer, count orders with status='cancelled' in same GROUP BY
Answer: `count_if(status = 'cancelled') AS cancelled_count`; also `COUNT(*) FILTER (WHERE status='cancelled')`; both avoid subquery/JOIN. `SUM(CASE WHEN ...)` works but more verbose. Cites r23.

- **Verification**: aggregate.html — `count_if(x)` "Returns the number of TRUE input values" (= count(CASE WHEN x THEN 1 END)). FILTER clause "supported for all aggregate functions". Both correct, both avoid subqueries. SUM(CASE WHEN) equivalent. ALL CORRECT.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**
- count_if + FILTER conditional-count pin held. Offering both the Trino-idiomatic (count_if) and the ANSI-portable (FILTER) forms, plus the verbose-but-valid SUM(CASE) fallback, is exactly the right coverage.

### Q4 — case-insensitive email match in lookup/JOIN
Answer: `LOWER(u.email) = LOWER(a.email)` in the JOIN; or store lowercased at ingest and compare directly. Cites r23.

- **Verification**: string.html — `lower(varchar) -> varchar`. LOWER both sides is the standard case-insensitive comparison. CORRECT. The store-lowercased-at-ingest note is sound and reflects the production ingestion stack.
- Accuracy 5 / Completeness 5 / Clarity 4.75 / Actionability 5 → **avg 4.9375**
- Correct and portable. Minor (un-penalized to near-zero) nuance not raised: applying LOWER() to a join key can defeat some predicate pushdown / stats optimization on Trino+Iceberg, which is precisely why the store-lowercased-at-ingest advice is the better long-term move — the responder did surface that ingest option, so the gap is cosmetic, not a defect. Slight Clarity trim only because the performance rationale behind the ingest suggestion was left implicit.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 4.75 | 5 | 4.9375 |

**Overall avg = 4.984** → **PASS** (threshold 3.5; overall average governs, no single-Q veto).

---

## Standing-pin status

- **replace-fixed-char-vs-regexp_replace**: **BULLETPROOFED.** Q1 is the 2nd consecutive clean datapoint (iter779 underscore→dash, iter780 strip-spaces), both LED with plain `replace()` with no reach for regexp_replace. The new plain-replace card + disambiguator (r27:1143-1174) is doing its job across two distinct phrasings. CLOSED → **BULLETPROOFED.**
- **truncate-toward-zero-vs-CAST-rounds-half-up / floor-vs-ceil**: RE-CONFIRMED on-pin (Q2). CAST-rounds-not-truncates pin held; responder proactively flagged the common CAST-truncates misconception as wrong.
- **count_if-or-FILTER-conditional-count**: held (Q3).
- **LOWER-both-sides-case-insensitive**: held (Q4); ingest-lowercase fallback surfaced.

No drift across the iter534–779 inventory.

---

## Teacher feedback

(a) **Is replace-fixed-char BULLETPROOFED?** YES. Two consecutive clean datapoints (iter779 + iter780) on distinct phrasings, responder leading with plain `replace()` and never misrouting to regexp_replace. PRESERVE the plain-replace card + replace-vs-regexp_replace disambiguator at r27:1143-1174 — load-bearing, churn risk.

(b) **iter781 designation**: **DEFAULT NO-OP / durability-breadth sweep.** No open defect surfaced this iteration; no new imprecision. Recommend ZERO edits. Suggested fresh adjacent probes for iter781: explicit `truncate(x, n)` to n decimals (vs round(x,n)); case-insensitive LIKE via `lower(col) LIKE lower(pattern)` (extends Q4); conditional-count with a DISTINCT twist (`count(DISTINCT customer_id) FILTER (WHERE …)`); and one confirmatory replace-family phrasing only if cheap (e.g. 2-arg `replace(s, '-')` remove-dash). PRESERVE r07 truncate/floor/ceil + CAST-rounds card, r23 count_if/FILTER + LOWER cards, and the r27 replace cards — all verified clean, churn risk.
