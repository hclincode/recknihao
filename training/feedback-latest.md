# Iter566 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Verdict: 4.875 STRONG PASS — iter565 Q1 forward-fill SEMANTIC ERROR FIXED on first re-probe

**Overall average = (4.875 + 5.00 + 4.875 + 4.75) / 4 = 19.50 / 4 = 4.875**
**Margin: +1.375 above 3.5 floor; +0.46875 swing from iter565's 4.40625.**
PASS by overall-average rule. Federation not probed — rubric row 4.49944/310 unchanged.

---

## Per-question scores

### Q1 — Forward-fill last known price across daily rows (iter566 PRIMARY WIN CHECK)
**Accuracy 5.0 / Completeness 4.5 / Clarity 5.0 / Actionability 5.0 = 4.875 STRONG PASS — iter565 SEMANTIC ERROR FIXED on first re-probe**

Responder answered:
```sql
COALESCE(price,
  LAST_VALUE(price) IGNORE NULLS OVER (
    ORDER BY date_column
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  )
)
```
- Uses native `IGNORE NULLS` (the idiom that iter565 missed entirely).
- Uses the look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (NOT the iter565 fab `UNBOUNDED FOLLOWING`).
- Explicitly WARNED that `UNBOUNDED FOLLOWING` produces future-fill (rows before first observation get the partition's last non-null) — exactly the iter565 trap, now diagnosed as an anti-pattern.
- Did NOT reach for the broken split-partition `PARTITION BY id, CASE WHEN x IS NOT NULL THEN 1 ELSE 0 END` trick (iter565 offered this — it's gone now).
- Noted `COALESCE` is optional (IGNORE NULLS already produces a value for every row); correct subtle point.

**Verified at trino.io/docs/467/functions/window.html VERBATIM**: `"By default, null values are respected. If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation. If IGNORE NULLS is specified and x is null for all rows, the default_value is returned, or if it is not specified, null is returned."` Maps 1:1 to responder's mechanism explanation.

**Completeness -0.5** (NOT accuracy): Question says "a daily table" with one price column — single series, omitting `PARTITION BY` is fitting for the question as posed. A brief mention of "add `PARTITION BY id` when carrying forward per-entity (e.g. per-product)" would have been a nice safety net for the engineer who extends this pattern to multi-series tables. Not penalized as accuracy; the answer's frame is correct for the question's framing.

iter566 FIX A (r07 new H3 LEADING CANONICAL for forward-fill with look-BACK frame + IGNORE NULLS + DO-NOT-WRITE bans on UNBOUNDED FOLLOWING + split-partition trick) **VALIDATED at 4.875 on first re-probe** — responder's lead sentence + frame + IGNORE NULLS + anti-pattern warning all mirror the canonical. Resource routing is clean.

### Q2 — LAG IGNORE NULLS for previous non-null + subtract for change
**Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 = 5.00 STRONG PASS**

Responder:
- `LAG(price) IGNORE NULLS OVER (ORDER BY date_column)` → previous non-null prior to current row.
- `price - LAG(price) IGNORE NULLS OVER (ORDER BY date_column)` → day-over-non-null change.
- Distinguished from plain `LAG(price)` which returns previous row's value even if NULL (forcing NULL into the subtraction → NULL change, the engineer's stated frustration).

Verified at trino.io/docs/467/functions/window.html: `lag()` returns the value at `offset` rows before the current row in the window partition + IGNORE NULLS applies to value functions (first_value/last_value/nth_value/lead/lag). The mechanism is exactly the Trino 467 native behavior; no workaround/CASE-trick needed. iter566 teacher state.json note that LAG IGNORE NULLS is mentioned in the new r07 H3 cross-reference paragraph paid off — the responder routed cleanly.

### Q3 — UNION vs UNION ALL (default DISTINCT)
**Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 4.5 = 4.875 STRONG PASS**

Responder:
- `UNION ALL` = concatenate, no dedup, cheaper, the operational default for "I just want all rows from both."
- Bare `UNION` = implicit global DISTINCT over combined result, expensive (full sort/hash-aggregate).
- Diagnosed the engineer's symptom ("fewer rows / duplicates disappear") as bare UNION silently deduping.
- Routes use case: UNION ALL when sources non-overlapping or duplicates are wanted; bare UNION only when explicit dedup needed.

**Verified at trino.io/docs/467/sql/select.html VERBATIM**: `"If neither is specified, the behavior defaults to DISTINCT."` Matches responder's "bare UNION = implicit DISTINCT" claim 1:1.

**Actionability -0.5**: Did not explicitly call out the most useful production followup — that `SELECT DISTINCT ... FROM (a UNION ALL b)` is what you actually want when you do want dedup but with a narrower projection. Polish-only; mechanism + use-routing is fully correct.

### Q4 — Iceberg comma-separated tag list, find rows containing 'web'
**Accuracy 5.0 / Completeness 5.0 / Clarity 4.5 / Actionability 4.5 = 4.75 STRONG PASS**

Responder gave two valid options:
- Option A (UNNEST explode): `CROSS JOIN UNNEST(split(t.tags, ',')) AS tag_col(tag) WHERE TRIM(tag) = 'web'` — explodes for GROUP BY / JOIN.
- Option B (row-level filter): `WHERE contains(split(tags, ','), 'web')` — single-row test, no row explosion.
- Explained `split()` returns ARRAY, `contains()` membership, UNNEST explodes to rows.
- Warned about whitespace (`TRIM(tag)`) when source data has spaces after commas like `'mobile, web, api'`.

**Verified against Trino 467 docs**:
- `split(string, delimiter)` returns an array (trino.io/docs/467/functions/string.html VERBATIM: `"Splits string on delimiter and returns an array."`).
- `contains(x, element)` returns true if the array `x` contains the `element` (trino.io/docs/467/functions/array.html VERBATIM).
- `CROSS JOIN UNNEST(arr) AS t(col)` valid 467 syntax (trino.io/docs/467/sql/select.html — example `CROSS JOIN UNNEST(scores) AS t(score)`).

**Clarity -0.5, Actionability -0.5**: Option B `contains(split(tags, ','), 'web')` does NOT cover the whitespace case the responder warned about in Option A — if the source has `'mobile, web, api'`, Option B searches for literal `'web'` but the array contains `' web'` (leading space). For symmetry the responder should have suggested either `contains(transform(split(tags, ','), x -> trim(x)), 'web')` or noted that Option B requires upstream-cleaned data. Mechanism is right but the whitespace caveat is asymmetric across the two options. Production engineer needs both options to be whitespace-safe.

---

## Topic average updates

- **Analytical query patterns on Iceberg+Trino** (Q1 forward-fill r07 new H3 + Q2 LAG IGNORE NULLS):
  4.3401/23 → (4.3401·23 + 4.875)/24 = 104.70/24 = **4.3625/24** (+0.0224) → (4.3625·24 + 5.00)/25 = 109.70/25 = **4.3880/25** (+0.0255).
  Net +0.0479 over iter565 — Q1 fab fix closed AND Q2 LAG IGNORE NULLS routes cleanly.
- **SQL query best practices for OLAP** (Q3 UNION default DISTINCT + Q4 split/contains/UNNEST):
  4.4771/151 → (4.4771·151 + 4.875)/152 = 680.92/152 = **4.4798/152** (+0.0027) → (4.4798·152 + 4.75)/153 = 685.67/153 = **4.4815/153** (+0.0017).
  Net +0.0044 — both Q3/Q4 above topic avg.
- Federation NOT probed — **4.49944/310 row UNCHANGED**.

---

## PRIMARY WINS

1. **Q1 — iter566 r07 new H3 LEADING CANONICAL for forward-fill VALIDATED on first re-probe at 4.875.** iter565 semantic error (UNBOUNDED FOLLOWING future-fill + missed IGNORE NULLS + broken split-partition trick) ALL THREE fixed:
   - Responder uses the look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`.
   - Responder uses native `IGNORE NULLS` (no CASE-WHEN workaround).
   - Responder explicitly DIAGNOSES the UNBOUNDED FOLLOWING failure mode (future-fill, rows before first observation get partition's last non-null) as an anti-pattern.
   - Responder does NOT offer the broken split-partition trick.
   The new H3's DO-NOT-WRITE rows + look-back-frame-pin + IGNORE NULLS-verbatim-quote did exactly the work they were designed to do.
2. **Q2 — LAG IGNORE NULLS for previous non-null** durable at 5.00. Cross-reference paragraph in the new r07 H3 paid off — responder routed cleanly without needing a dedicated LAG H3.
3. **Q3 — UNION default DISTINCT** strong at 4.875; mechanism + symptom-diagnosis ("fewer rows = silent dedup") + cost framing all correct.
4. **Q4 — split/contains/UNNEST/TRIM** strong at 4.75; both row-level filter + UNNEST explode patterns offered; cited the production whitespace gotcha.

## MINOR FINDINGS (do not over-correct)

1. **Q1 — `PARTITION BY id` mention for multi-series extension.** Single-series question framed it correctly, but a one-line "add `PARTITION BY id` if you have per-entity series (per product, per user)" would have made the answer durable for engineers extending the pattern. Polish-only; not an accuracy hit.
2. **Q4 — whitespace caveat asymmetry.** Option A (UNNEST) was TRIM-safe; Option B (`contains(split(...), 'web')`) was not. The responder mentioned TRIM in Option A but not the equivalent gotcha for Option B (`contains` does exact-match against array elements, so unTRIMmed `' web'` ≠ `'web'`). Either route Option B through `transform(split(tags, ','), x -> trim(x))` or call out that B requires clean upstream data.
3. **Q3 — `SELECT DISTINCT ... FROM (a UNION ALL b)` framing.** Did not call out the most-used production alternative when you DO want dedup with control over the projection. Polish-only.

## NEW iter567 FIX TARGETS

### Fix 1 — LOW PRIORITY — durability 2nd-angle re-probes for iter566 wins
- **Q1 2nd-angle**: "I have per-product price observations sparse across days, need each product-day to show last known price" — should route to same r07 H3 canonical AND trigger PARTITION BY id mention.
- **Q2 2nd-angle**: `nth_value(... IGNORE NULLS)` for 2nd-most-recent non-null OR `FIRST_VALUE(... IGNORE NULLS)` for first-observed value, same r07 H3.
- **Q3 2nd-angle**: `INTERSECT` vs `INTERSECT ALL` and `EXCEPT` vs `EXCEPT ALL` (Trino 467 supports both — same default DISTINCT rule applies).
- **Q4 2nd-angle**: JSON-array column variant — `cast(json_col AS array(varchar))` then contains; routes to r09 element_at/JSON canonicals.

### Fix 2 — LOW PRIORITY — Q4 whitespace symmetry tighten
In whichever resource hosts the split/UNNEST/contains canonical (r07 or r09):
- Add a one-line callout that `contains(split(s, ','), 'x')` is NOT whitespace-safe (exact array-element match) — engineers must either pre-TRIM upstream or wrap in `transform(split(s, ','), x -> trim(x))` before `contains`.
- Add a one-line cross-reference: "for the UNNEST/CROSS JOIN form, TRIM the unnested column in WHERE."
- DO NOT churn — append as a single bullet under the existing canonical; don't rewrite.

### Fix 3 — LOW PRIORITY — Q1 multi-series extension callout
In the new r07 H3 forward-fill canonical:
- Add ONE bullet: "for per-entity carry-forward (per product, per user, per tenant), include `PARTITION BY entity_id` in the OVER clause — the look-back frame restarts per partition."
- DO NOT remove or rewrite the existing canonical; this is a single-line additive bullet.

### Fix 4 — DO NOT TOUCH
- Federation row stays 4.49944/310; no edits to resources/22 §13.x.
- r07 §1a-§1a.5 + §1b CTE + Pattern C4 + approx + date_trunc + week-Monday + now() + named-WINDOW + date_add + multiple-COUNT-DISTINCT + §5 B2/B3 [default-frame footgun] + FILTER + ROWS-vs-RANGE + array_join/array_position + sequence + **NEW iter566 H3 forward-fill** — ALL DURABLE.
- r23 §3.1A-H + greatest/least + EXTRACT-EPOCH + format + approx_percentile + HALF_UP + arbitrary/max_by + §4 EXPLAIN-skew + multiple-COUNT-DISTINCT — UNTOUCHED.
- r27/r28/r17/r10/r24/r13/r09/r18 — UNTOUCHED.

---

## Meta-rule observation

WebSearched four primary sources:
1. trino.io/docs/467/functions/window.html — IGNORE NULLS semantics + LAG/LAST_VALUE behavior + function-list coverage (Q1 + Q2 verified VERBATIM).
2. trino.io/docs/467/sql/select.html — UNION default DISTINCT + UNNEST/CROSS JOIN UNNEST valid syntax (Q3 + Q4 verified VERBATIM).
3. trino.io/docs/467/functions/array.html — `contains(x, element)` semantics on arrays (Q4 verified VERBATIM).
4. trino.io/docs/467/functions/string.html — `split(string, delimiter)` returns array (Q4 verified VERBATIM).

Every responder claim cross-verified against primary source. The iter565 → iter566 fix loop is the cleanest first-re-probe close in the recent run — iter566 directive's "PIN TRINO 467 + verify own corrections + watch for WRONG-FRAME/SEMANTIC errors" was load-bearing; without WebSearching window.html for IGNORE NULLS semantics, the look-back-frame fix could have been let slide as merely "different from iter565" rather than verified as semantically correct.

28th consecutive iter (iter537-566) where meta-rule discipline materially affected the verdict.

---

## NOTES
- Did NOT bump training/state.json (teacher already set iteration=566).
- Federation rubric row 4.49944/310 UNCHANGED.
- Did NOT touch any resource files.
- Did NOT touch resources/22 §13.x.

---

## OVERALL: 4.875 STRONG PASS — iter565 Q1 forward-fill SEMANTIC ERROR FIXED on first re-probe via new r07 H3 LEADING CANONICAL (look-back frame + IGNORE NULLS + DO-NOT-WRITE anti-patterns). Q2/Q3/Q4 strong. iter567 = polish + 2nd-angle durability re-probes + Q4 whitespace symmetry + Q1 multi-series PARTITION BY one-line additive bullet. NO CHURN on the new iter566 r07 H3.
