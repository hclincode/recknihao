# iter766 Judge Feedback — DEFAULT durability-breadth (4 fresh picks)

**Verification basis:** All dialect claims verified against trino.io/docs/467 (sql/select.html, functions/datetime.html, language/types.html) via WebFetch/WebSearch on 2026-06-09. resources/ NOT treated as ground truth.

---

## Q1 — Per-product price RANGE/SPREAD (highest minus lowest = one number per group)

**Verdict: REAL ACCURACY DEFECT. First form is a COMPILE ERROR; the simple aggregate was MISSED.**

The expected, idiomatic, textbook answer is a plain GROUP BY aggregate — NO window functions:
```sql
SELECT product_id, MAX(sale_price) - MIN(sale_price) AS price_range
FROM sales
GROUP BY product_id;
```
This is the canonical "max minus min per group" form. The responder did NOT offer it.

Instead the responder produced two window-based forms:

- **FIRST form (the LEAD answer) DOES NOT COMPILE.** It puts a window-function expression inside GROUP BY:
  `... GROUP BY product_id, MAX(sale_price) OVER (PARTITION BY product_id) - MIN(sale_price) OVER (...)`.
  **Verified against trino.io/docs/467/sql/select.html:** a GROUP BY clause may only contain "aggregate functions or columns present in the GROUP BY clause" — window functions are NOT permitted in GROUP BY. Trino fails analysis with "GROUP BY clause cannot contain aggregations, window functions or grouping operations". So the lead form is INVALID / non-compiling. This is the form a copy-paste reader reaches for first → real harm.

- **SECOND form (CTE with MAX OVER / MIN OVER, then SELECT DISTINCT)** COMPILES and returns the correct answer, but is badly over-engineered: it computes a window over every row then DISTINCT-dedupes, far heavier than the one-line GROUP BY aggregate. The misleading alias `price_volatility` (the question asked for range/spread) is a minor clarity ding.

**Synthesis-slip vs findability gap:** Per the iter766 integrity-sweep (state.json notes_766 STEP 2(a)) and the standing pins, the simple `MAX(x) - MIN(x)` GROUP BY aggregate range/spread form IS documented and distinguished from row-wise greatest/least at r07/r23/r27 (r23:1552, r27:1662/1675: "MAX(col) is an aggregate DOWN ROWS (one value per group)"). So the canonical exists. The question is whether it's FINDABLE under the question's keywords. The responder routed to window functions instead of the documented aggregate, which points to a **routing/findability weakness**: the documented MAX(col)-aggregate material is framed as a MAX-vs-greatest disambiguation, NOT as a copy-attractive "price RANGE / SPREAD / highest minus lowest / max minus min per group" canonical with those keyword anchors. The responder's keyword→resource match for "range/spread/highest minus lowest/volatility" did not land on the simple aggregate.

**iter767 designation for Q1: FIX-A (findability).** Add a small COPY-ATTRACTIVE "price range / spread per group" canonical near the MAX/MIN aggregate material with explicit keyword anchors: **"price range", "spread", "highest minus lowest", "max minus min per group", "volatility", "one value per group"** →
```sql
SELECT product_id, MAX(sale_price) - MIN(sale_price) AS price_range
FROM sales GROUP BY product_id;
```
Plus an iter693-style INLINE un-copyable defang at the window-function material: `-- window functions are NOT allowed in GROUP BY (analysis error); for max-minus-min-per-group use a plain GROUP BY aggregate -- DO NOT COPY`. Do NOT churn the existing MAX-vs-greatest disambiguation (correct, keep verbatim); add the range/spread aggregate canonical adjacent.

| Axis | Score | Note |
|---|---|---|
| Accuracy | 2 | Lead form is a compile error (window fn in GROUP BY); simple aggregate missed. 2nd form correct but heavy. |
| Completeness | 3 | A working form (2nd) is present, but the canonical/expected aggregate is absent. |
| Clarity | 3 | Window-function explanation is coherent; misleading `price_volatility` alias; over-complex path obscures the simple answer. |
| Actionability | 3 | An engineer who copies the FIRST (lead) form gets an error; only the 2nd form works. |
| **Q1 avg** | **2.75** | |

---

## Q2 — Unix epoch SECONDS (1749480000) → timestamp

**Verdict: CLEAN.** `from_unixtime(event_time_seconds)` is correct — verified `from_unixtime(unixtime)` takes SECONDS since epoch and returns timestamp(3) with time zone (datetime.html). The millis-needs-`/1e3` note (`from_unixtime(event_time_ms / 1e3)`) is correct and a valuable disambiguation. The `>= CURRENT_TIMESTAMP - INTERVAL '7' DAY` filter is valid Trino.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q2 avg** | **5.00** |

---

## Q3 — Frequency table per event_type (count as rows, most-common first)

**Verdict: CLEAN.** `SELECT event_type, COUNT(*) AS event_count FROM events GROUP BY event_type ORDER BY event_count DESC` is the correct frequency-as-rows idiom (verified select.html). HAVING-after-grouping note accurate (HAVING filters post-aggregation; WHERE filters pre-grouping). The HAVING `COUNT(*) > 10` variant is a nice touch.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q3 avg** | **5.00** |

---

## Q4 — Comma-separated tags → multiple rows (one row per tag + product_id)

**Verdict: CLEAN.** `CROSS JOIN UNNEST(split(tags, ',')) AS t(tag)` is the correct string→rows explode in Trino 467 (split → array, CROSS JOIN UNNEST → one row per element). `trim(tag)` correctly handles whitespace from `"sale, new"`-style input. The CROSS-JOIN-drops-empty vs `LEFT JOIN UNNEST(...) ON TRUE`-keeps-tag-less-rows distinction is accurate and a strong completeness signal. The COUNT(DISTINCT product_id) GROUP BY trim(tag) variant is appropriate.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q4 avg** | **5.00** |

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 2.75 |
| Q2 | 5.00 |
| Q3 | 5.00 |
| Q4 | 5.00 |
| **Overall** | **4.44** |

**Overall avg 4.44 ≥ 3.5 → PASS** (overall-average governs; no single-Q veto). Q2/Q3/Q4 are bulletproof-clean; Q1 carries a genuine defect (non-compiling lead form + missed simple aggregate) that drags the average but does not sink it.

**iter767 designation: FIX-A (Q1 range/spread findability).** Add a copy-attractive `MAX(x) - MIN(x)` GROUP BY price-range/spread canonical with keyword anchors (price range / spread / highest minus lowest / max minus min per group / volatility) + an inline window-fn-not-allowed-in-GROUP-BY defang. Preserve the existing MAX-vs-greatest disambiguation, from_unixtime, value-frequency, and string-to-rows cards (all verified clean — churn risk).
