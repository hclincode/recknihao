# Judge Feedback — iter865 (EXTENDED PHASE)

**Overall: 4.375 PASS** (per-Q 5.00 / 5.00 / 2.50 / 5.00 = 17.50 / 4 = 4.375; margin +0.875 over 3.5 threshold; overall average governs, NO per-Q veto). One REAL accuracy DEFECT at Q3 (per-row vs per-group misframe), three clean.

Federation NOT probed this iter (4.49944/310 row UNCHANGED, still FAIL).

PIN Trino 467. All dialect facts verified against trino.io/docs/467 (array/comparison/aggregate/string/conversion .html) + WebFetch 2026-06-10.

---

## Q1 — grab the LAST element of an array column

**Answer:** `element_at(tags, -1) AS most_recent_tag`; negative indexing (-1 last, -2 second-to-last); element_at NULL-safe (NULL on empty/out-of-range) UNLIKE `array[n]` subscript which errors.

**VERIFIED (array.html):**
- "If `index` < 0, `element_at` accesses elements from the last to the first." → negative indexing CORRECT, -1 = last.
- element_at "returns `NULL` when accessing an `index` larger than array length"; the `[]` subscript "would fail in such a case." → NULL-safe vs subscript-throws CONTRAST CORRECT.

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**. Clean. The element_at-vs-subscript NULL-safety distinction is exactly the trap engineers hit; fully correct and well-explained.

---

## Q2 — NULL-safe join (match rows where BOTH sides NULL on the key)

**Answer:** `JOIN ... ON a.account_id IS NOT DISTINCT FROM b.account_id`; explained null-safe equality (NULL IS NOT DISTINCT FROM NULL = true); works in INNER/LEFT/RIGHT/FULL.

**VERIFIED (comparison.html):** "The `IS DISTINCT FROM` and `IS NOT DISTINCT FROM` operators treat `NULL` as a known value and both operators guarantee either a true or false outcome even in the presence of `NULL` input." `NULL IS NOT DISTINCT FROM NULL` = **true**. Valid as a join condition (boolean predicate). CORRECT.

Citation note (per run-prompt): responder cited a federation resource file, but the operator is general-purpose SQL and the SQL itself is correct — citation provenance is NOT scored as a defect here. The answer is dialect-correct and directly solves the asked join.

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**. Clean.

---

## Q3 — count how many of ~8 boolean flag columns are TRUE FOR EACH CUSTOMER ROW — **DEFECT (misframe)**

**Question shape:** PER-ROW (row-wise) count of how many flag COLUMNS are TRUE in a single customer row. The engineer literally asked to "add a COLUMN to my query that shows a count of how many flags are turned on for each customer," explicitly without a massive CASE. This is a **row-wise expression**, NOT an aggregation.

**Correct answer (NO GROUP BY, NO aggregate):**
```sql
SELECT customer_id,
       CAST(has_sso        AS integer)
     + CAST(has_api_access AS integer)
     + CAST(has_audit_log  AS integer)
     + ... AS flags_on
FROM customers;
```
(Equivalently a `reduce`/array approach over `ARRAY[has_sso, has_api_access, ...]`.) Booleans CAST to integer give 1/0; their row-wise sum is the per-row count of TRUE columns. No grouping, no aggregate.

**What the responder gave:** TWO AGGREGATE forms —
1. `SUM(CAST(has_sso AS INTEGER) + CAST(...) + ...) ... GROUP BY customer_id`, and
2. `count_if(has_sso) + count_if(has_api_access) + ... GROUP BY customer_id` — and called the count_if form "cleaner / more idiomatic."

**Why this is WRONG (VERIFIED aggregate.html):** `count_if(x)` "Returns the number of `TRUE` input values. This function is equivalent to `count(CASE WHEN x THEN 1 END)`." It is an **AGGREGATE** that counts ROWS where its argument is TRUE across the GROUP — the wrong tool for a per-row count of how many COLUMNS are true in a single row. `count_if(has_sso)` counts how many customer ROWS have has_sso = true within the group, not whether THIS row's has_sso column is true. The form only coincidentally returns a plausible number when there is exactly one row per customer; with multiple rows per customer it is flatly wrong. The `SUM(...) GROUP BY` form likewise aggregates across rows the question never asked to collapse — it changes the query's grain and is structurally wrong for a per-row column-count. The responder MISFRAMED a per-row problem as an aggregation, and even ranked the most-wrong form ("count_if … cleaner/more idiomatic") first.

**Diagnosis — RESOURCE-DEFECT contributor (not a pure synthesis slip).** GREP of resources/ confirms:
- r23 § 3.1E and § 11 present `count_if(bool)` as the **LEADING / CO-CANONICAL** idiom for "count of X where boolean is true PER GROUP" / "how many flagged per region/customer/group" — heavily keyword-magnetic on "count … flags … per customer." Those cards are CORRECT for the per-GROUP question, but the responder pattern-matched the keywords ("count how many flags … for each customer") straight onto them and inherited the aggregate framing.
- r07 § 11.x mirrors the same count_if-leads cross-ref.
- The ONLY "count how many flags are enabled" worked example (r27 ~L1375) is `bit_count(flags, 64)` for a **single bit-packed integer column** — a different physical model (one packed bigint, not N separate boolean columns), so it does not serve this question either.
- There is **NO card** anywhere teaching the row-wise `CAST(flag AS integer) + CAST(...) + ...` (or `reduce` over `ARRAY[flags]`) pattern for "how many of these boolean COLUMNS are true in a single ROW."

So the gap is real: every findable "count flags true" anchor leads to an AGGREGATE, and nothing disambiguates the PER-ROW column-count shape. That is a findability/coverage gap, not just a one-off synthesis slip.

**Scores:** Accuracy 1 (structurally wrong tool; misframes grain) / Completeness 3 (lists forms but never gives the correct no-GROUP-BY answer the question needs) / Clarity 4 (clearly written, but confidently wrong) / Actionability 2 (an engineer following the "idiomatic" count_if advice ships a query that breaks the moment a customer has >1 row) → **avg 2.50**.

---

## Q4 — zero-pad integer invoice_id to exactly 8 digits (42 -> '00000042')

**Answer:** `format('%08d', invoice_id) AS invoice_id_padded`; never truncates wider numbers (width = minimum); `lpad(CAST(invoice_id AS VARCHAR), 8, '0')` also works but lpad TRUNCATES to 8 chars if the ID exceeds 8 digits.

**VERIFIED:**
- conversion.html: `format(format, args...)` uses Java Formatter (printf) syntax; example `format('%03d', 8)` → `'008'`. `%08d` = zero-pad to minimum width 8; field width is a MINIMUM with no truncation of wider numbers. CORRECT.
- string.html: `lpad(string, size, padstring)` — "If `size` is less than the length of `string`, the result is truncated to `size` characters." → lpad-truncates-when-input-longer CORRECT (the key trap: a 9-digit invoice silently loses a digit under lpad, while format keeps all digits).

The format-no-truncate vs lpad-truncates distinction is precisely the production-relevant gotcha (invoice IDs that grow past 8 digits). Mild overlap with iter836 lpad/format coverage; redundancy is not a defect and the answer is correct.

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**. Clean.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 element_at(-1) negative/NULL-safe | 5 | 5 | 5 | 5 | 5.00 |
| Q2 IS NOT DISTINCT FROM in join | 5 | 5 | 5 | 5 | 5.00 |
| Q3 per-row flag-count (MISFRAME) | 1 | 3 | 4 | 2 | 2.50 |
| Q4 format/lpad zero-pad | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = (5.00 + 5.00 + 2.50 + 5.00) / 4 = 4.375 → PASS** (margin +0.875; overall average governs, no per-Q veto).

---

## iter866 RECOMMENDATION — **FIX-A (Q3 real defect: per-ROW column-count vs per-GROUP count_if AGGREGATE)**

Add a keyword-anchored card disambiguating the two question shapes. Place it where the question's keywords lead — adjacent to r23 § 3.1E / § 11 (the count_if cards the responder mis-pattern-matched), and cross-ref from r07 § 11.x.

**Card content:**
- LEADING CANONICAL for "**how many of these flag/boolean COLUMNS are true in a single ROW**" (per-row, NO GROUP BY):
  ```sql
  -- Trino 467 — per-row count of how many flag COLUMNS are true in THIS row (no GROUP BY, no aggregate)
  SELECT customer_id,
         CAST(has_sso AS integer) + CAST(has_api_access AS integer)
       + CAST(has_audit_log AS integer) + ... AS flags_on
  FROM customers;
  ```
  Optional array form for many flags: `reduce(ARRAY[has_sso, has_api_access, ...], 0, (acc,x) -> acc + IF(x,1,0), acc -> acc)` (VERIFY reduce signature against array.html before writing).
- A SHAPE-ROUTER / DISAMBIGUATOR table:
  - "count how many COLUMNS are true in a single ROW" → **row-wise `CAST(flag AS integer) + ...` sum, NO GROUP BY**.
  - "count how many ROWS have flag = true PER GROUP" → **`count_if(flag)` AGGREGATE + GROUP BY** (existing § 3.1E / § 11 card).
- FENCED inline DEFANG on its own un-copyable line: `count_if(has_sso) + count_if(has_api_access) + ... GROUP BY customer_id  -- WRONG for a per-ROW column count: count_if is an AGGREGATE that counts ROWS per group, not columns in a row; only coincidentally right with exactly one row per customer.` Use a FENCED code block (NOT a table cell) so pipes/raw markdown copy cleanly.
- Keyword anchors: "how many flags are turned on for each customer", "count of true columns in a row", "count how many flag columns are true", "per-row flag count", "how many booleans are set in a row", "add a column showing count of flags on", "count_if vs row-wise sum".

Do NOT churn the existing count_if § 3.1E / § 11 per-GROUP cards (they are CORRECT for their shape) — only ADD the per-ROW canonical + the router + the defang, and cross-link. Distinguish clearly from the r27 `bit_count(flags, 64)` card (that is for a single bit-packed integer column, a different physical model).

HOLD all iter534-864 locks. PIN 467. NO federation edits (federation 4.49944/310, still FAIL). Do NOT bump training/state.json (already passed; this is extended-phase probing).
