# Judge Feedback — iter750 (FIX-A verification: flatten re-probe + map-merge-sum / LIKE-ESCAPE / LAG-delta)

**Overall: 4.094 — PASS** (threshold 3.5; overall average governs, no single-Q veto)

All dialect claims verified against trino.io/docs/467 (functions/array.html, functions/aggregate.html, functions/string.html, functions/comparison.html) on 2026-06-09.

---

## Q1 — FLATTEN RE-PROBE (survey: array-of-arrays of answer IDs → one flat list per response, no explosion)

Answer: `flatten(question_group_answers) AS all_answer_ids`; explained `flatten(array(array(T)))->array(T)` concatenates inner arrays into one flat array per row, no row explosion, single call. Confident, clean, cited the new r07 §1a.4 canonical.

- **Accuracy 5** — DOCS-VERIFIED (array.html verbatim): `flatten(x)` "Flattens an `array(array(T))` to an `array(T)` by concatenating the contained arrays." `flatten(question_group_answers)` is exactly right: per-row, one level, single array, NO explosion. Matches the question's "no row explosion" constraint precisely.
- **Completeness 5** — fully answered; one call, no detour.
- **Clarity 5** — confident, no hedge (contrast iter749 audible hedge), correctly stated the per-row/no-explosion guarantee.
- **Actionability 5** — copy-paste ready.
- **Q1 avg = 5.00**

**FLATTEN IS NOW CLOSED. FIX-A (iter750) WORKED.** iter749 Q2 flatten scored 2.875 (findable-but-missing — responder hedged then fell back to the explode-then-reaggregate UNNEST+array_agg detour). The new r07 §1a.4 `flatten()` LEADING CANONICAL produced a clean, confident, docs-correct native answer on the very next probe. This is **1 clean post-FIX-A datapoint** → re-probe flatten ONCE MORE in iter751 (different phrasing) to reach BULLETPROOFED, then stop touching it (iter693 churn-risk).

---

## Q2 — MAP-MERGE-SUM ACROSS ROWS (each row has a MAP column feature→count; want ONE combined map per customer that SUMS counts across all the customer's rows)

Answer: `map_agg(feature_name, SUM(usage_count)) ... GROUP BY customer_id`; explained map_agg builds one map per group from key/value columns and SUM adds counts per feature.

- **Accuracy 3** — the map_agg+SUM *strategy* is the right Trino idiom, BUT the SQL as written **will not run against the described schema**. The question states each row holds a MAP column (e.g. `{"feature_x":3}`). The responder's SQL references scalar columns `feature_name` and `usage_count` that **do not exist** — those columns only come into being after you explode the map. The missing step is `CROSS JOIN UNNEST(feature_map) AS t(feature_name, usage_count)` BEFORE the `map_agg(feature_name, SUM(usage_count)) GROUP BY customer_id`. Without it, the query fails with column-not-found. Docs-confirmed there is no shortcut: Trino 467 has **NO `map_union_sum`**, and `map_union(x)` does NOT sum on key collision — aggregate.html verbatim "If a key is found in multiple input maps, that key's value in the resulting map comes from an arbitrary input map." So UNNEST-then-`map_agg(k, SUM(v))` is the ONLY correct path, and it was the half that got dropped.
- **Completeness 2.5** — skipped the load-bearing UNNEST step; gave the back half of a two-part idiom.
- **Clarity 3.5** — clear explanation of map_agg/SUM, but silently assumed a schema the question did not describe.
- **Actionability 3** — an engineer copying this hits a column-not-found error and has to discover UNNEST themselves.
- **Q2 avg = 3.0**

**GENUINE GAP → this is the iter751 FIX-A.** The "merge/sum a MAP column across rows" idiom is not landed as a findable canonical. iter720 added the MAP-explode-to-rows canonical (UNNEST(map) AS t(k,v), 2 aliases) at r07 §1a, and iter747 has the `map_agg(k, value)` aggregate at r07:180-200 — but the **composition** (UNNEST the map → `map_agg(k, SUM(v))` GROUP BY) for the specific question "sum/combine map columns across all of a customer's rows" is not co-located or keyword-anchored, so the responder reached for map_agg without the UNNEST prerequisite.

**Teacher action for iter751:**
- ADD a LEADING CANONICAL at r07 §1a (adjacent to the iter720 MAP-explode card, which already documents `CROSS JOIN UNNEST(map_col) AS t(k,v)`): "**Sum / merge a MAP column across rows (one combined map per group)**".
- COPY-THIS form:
  ```sql
  SELECT customer_id,
         map_agg(feature_name, total) AS combined_usage
  FROM (
    SELECT customer_id, feature_name, SUM(usage_count) AS total
    FROM events
    CROSS JOIN UNNEST(feature_map) AS t(feature_name, usage_count)
    GROUP BY customer_id, feature_name
  )
  GROUP BY customer_id;
  ```
  (or the single-level `map_agg(feature_name, SUM(usage_count))` with the UNNEST in the same FROM and `GROUP BY customer_id, feature_name`).
- Keyword anchors: sum map values across rows / merge map columns / combine maps per group / aggregate a map column / map_union does not sum / total counts per key across rows / per-customer combined feature map.
- INLINE-DEFANG (un-copyable, iter693): `map_union(feature_map)` — does NOT sum, picks an arbitrary value on key collision (docs-verified); and `map_union_sum` — does NOT exist in Trino 467 (Presto-only). Both must be marked WRONG so the responder doesn't grab them.
- Cross-ref the iter720 UNNEST(map) 2-alias card and the iter747 map_agg aggregate card.

---

## Q3 — LITERAL `%` (or `_`) IN A LIKE SEARCH (match the wildcard char as data)

Answer: HEDGED ("resources do not contain explicit documentation on LIKE ESCAPE for Trino 467"). Gave `WHERE product_code LIKE '%\%%' ESCAPE '\'` (backslash escapes the % so it's literal). ALSO offered `contains(product_code, '%')` as a simpler alternative. Added a "verify at trino.io docs" caveat.

- **Accuracy 3** — the PRIMARY answer is correct: Trino 467 supports `LIKE pattern ESCAPE 'char'` (SQL standard; comparison.html confirms the ESCAPE clause, e.g. `'South_America' LIKE 'South\_America' ESCAPE '\'`), and `'%\%%' ESCAPE '\'` correctly matches a string containing a literal `%`. BUT the alternative is a **DEFECT**: `contains()` in Trino 467 is **array-only** — array.html verbatim `contains(x, element) -> boolean` "Returns true if the array x contains the element." There is NO string/varchar `contains()` (confirmed absent from string.html). `contains(product_code, '%')` on a varchar **will not compile** (function-not-found / signature mismatch). The correct literal-substring test on a string is `strpos(product_code, '%') > 0` (or the LIKE ESCAPE form itself). Offering a non-compiling alternative is a real accuracy hit, even though the primary answer is right.
- **Completeness 3.5** — covered the literal-% case and the underscore by analogy; the hedge ("resources don't document LIKE ESCAPE") signals a minor findability gap.
- **Clarity 4** — explanation of the escape mechanism was clear.
- **Actionability 3** — primary form works; the contains() alternative sends the engineer into a compile error.
- **Q3 avg = 3.375**

**TWO issues for the teacher (secondary FIX, lower priority than Q2):**
1. **Findability gap (minor):** `LIKE ... ESCAPE` for matching a literal `%`/`_` is correct but the responder couldn't find it (audible hedge). ADD a short canonical near the LIKE/regexp material (r23 LIKE/pattern section): "**Match a literal `%` or `_` in LIKE — use `ESCAPE`**" → COPY `WHERE col LIKE '%\%%' ESCAPE '\'` (literal percent) and `LIKE '%\_%' ESCAPE '\'` (literal underscore). Anchors: match a literal percent sign / escape wildcard in LIKE / search for a percent character / literal underscore in LIKE.
2. **DEFANG `contains()` on a string:** add an inline un-copyable note that `contains()` in Trino 467 is the ARRAY membership function `contains(array, element)` ONLY — it does NOT work on a varchar. For literal-substring-in-string membership use `strpos(s, sub) > 0` (or `LIKE '%...%' ESCAPE` for wildcard-bearing literals). This prevents the responder repeating the `contains(varchar, ...)` slip. Cross-ref the existing strpos canonical (r23 strpos / r27 §4.3).

---

## Q4 — ROW-TO-ROW DELTA (daily cumulative signups per channel → new signups that day = this row − previous day's, same channel)

Answer: `cumulative_signups - LAG(cumulative_signups, 1) OVER (PARTITION BY channel ORDER BY date) AS new_signups_today`; explained LAG fetches prior row's value within the channel partition ordered by date, subtraction gives the daily delta, first day per channel is NULL.

- **Accuracy 5** — standard and correct (window.html: `lag(x, offset)` returns the value at the given offset prior to the current row within the partition). `value - LAG(value,1) OVER (PARTITION BY channel ORDER BY date)` is the canonical row-to-row delta. Offset 1 = previous row; correct given one row per channel per day.
- **Completeness 5** — correctly flagged that the first day per channel yields NULL (no prior row); offset semantics correct.
- **Clarity 5** — clear, no hedge.
- **Actionability 5** — copy-paste ready.
- **Q4 avg = 5.00**

(Standing pin reminder, not penalized here: LAG offset is a ROW COUNT, not a time interval — the answer correctly relies on one-row-per-channel-per-day, which the question's "cumulative daily" framing guarantees. If gaps in dates existed, the delta would still be vs the previous *present* row, not the previous calendar day. Not exercised here.)

---

## Score summary

| Q | Topic | Acc | Comp | Clar | Act | Q-avg |
|---|---|---|---|---|---|---|
| Q1 | flatten array-of-arrays (RE-PROBE) | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | merge/sum MAP column across rows | 3 | 2.5 | 3.5 | 3 | **3.0** |
| Q3 | literal `%`/`_` in LIKE (ESCAPE) | 3 | 3.5 | 4 | 3 | **3.375** |
| Q4 | row-to-row delta via LAG | 5 | 5 | 5 | 5 | **5.00** |

**Overall average = (5.00 + 3.0 + 3.375 + 5.00) / 4 = 4.094 — PASS**

---

## iter751 designation

**iter751 = FIX-A (Q2): map-merge-sum-across-rows canonical** — highest-priority gap. Add the UNNEST(map)→`map_agg(k, SUM(v))` GROUP BY composition canonical at r07 §1a adjacent to the iter720 MAP-explode card, with `map_union`-does-not-sum / no-`map_union_sum` defang (both docs-verified). Specifics above.

**Secondary (fold into the same iteration if low-risk): Q3** — (a) add the `LIKE ... ESCAPE` literal-wildcard canonical (findability), and (b) defang `contains()` on a varchar (array-only) pointing to `strpos(s,sub)>0`. The contains-on-varchar slip is a defect worth inoculating even though the primary LIKE answer was correct.

**Q1 flatten = CLOSED (FIX-A iter750 worked); 1 clean datapoint → re-probe ONCE in iter751 for BULLETPROOFED, then stop.** Do NOT re-edit the flatten/array_remove cards (churn-risk).

**Q4 = perfect, no action.**

Production-fit note: all forms are valid Trino 467 + Iceberg-connector dialect and fit the on-prem Trino-467/Spark/MinIO stack in prod_info.md. No auth/authz scope concerns this iteration. NEW LOCK candidates to record after iter751 lands: `map_union`-arbitrary-value-NOT-sum / no-`map_union_sum`-in-467 / `contains()`-is-ARRAY-only-NOT-varchar / `LIKE ... ESCAPE`-for-literal-wildcard.
