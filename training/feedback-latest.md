# Judge Feedback — iter774 (DEFAULT NO-OP / durability-breadth sweep)

**Teacher made ZERO resource edits this iteration.** 4 fresh adjacent probes. All dialect claims verified against trino.io/docs/467 (window / regexp / string / comparison / math .html) on 2026-06-09. resources/ NOT treated as ground truth.

## Overall verdict

**Overall avg = 4.375 — PASS** (threshold 3.5; overall average governs, no single-Q veto).

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Per-Q avg |
|---|---|---|---|---|---|---|
| Q1 | LAG by N / value 12 rows back (explicit "WITHOUT self-join") | 3 | 2 | 4 | 2 | **2.75** |
| Q2 | title-case / no-initcap | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | histogram / equal-width $50 buckets | 5 | 4 | 5 | 5 | **4.75** |
| Q4 | null-safe equality (IS NOT DISTINCT FROM) | 5 | 5 | 5 | 5 | **5.00** |

Overall = (2.75 + 5.00 + 4.75 + 5.00) / 4 = **4.375 PASS**.

Q1 is the sole weak answer and the key issue of this sweep. Q2/Q3/Q4 are strong and clean.

---

## Per-question detail

### Q1 — LAG-by-N / value 12 rows back — **2.75 (the defect)**

**The ask (verbatim intent):** monthly_revenue is "one row per month" (dense, gapless). User EXPLICITLY asked for "a cleaner way than a self-join — grab a value from the row that's 12 positions back in an ordered sequence, WITHOUT joining the table to itself." This is the textbook definition of `LAG(revenue_total, 12) OVER (ORDER BY month)`.

**What the responder did:** REFUSED LAG. Said "Use a self-join on calendar arithmetic, NOT LAG — it's cleaner and more reliable," gave a `LEFT JOIN monthly_revenue prev ON ... prev.month = date_add('month', -12, cur.month)` self-join, and justified withholding LAG with the gaps-in-months caveat. Did **not** show the `LAG(revenue_total, 12) OVER (ORDER BY month)` form at all.

**Docs verification (trino.io/docs/467/functions/window.html):** `lag(x[, offset[, default_value]]) -> "Returns the value at offset rows before the current row in the window partition."` Default offset 1; out-of-bounds returns default_value or NULL; ORDER BY required. So `LAG(revenue_total, 12) OVER (ORDER BY month)` returns the value exactly 12 rows back — **the exact clean, non-self-join answer the user asked for.**

**Verdict:**
- The self-join query the responder produced is **valid Trino and returns correct numbers**, and the gaps caveat is **factually true** (LAG counts rows, not calendar months — confirmed). So Accuracy is not zero.
- BUT the blanket "NOT LAG — it's unreliable" is **OVERSTATED to the point of being wrong for this question**. The user stated the precondition that makes LAG safe and canonical: **one row per month = dense/gapless**. On a dense monthly series, `LAG(revenue_total, 12) OVER (ORDER BY month)` is correct, canonical, and is precisely the "value N rows back without a self-join" the user requested. The gaps caveat is a real *edge* nuance, not a reason to withhold the correct primary.
- This is a **SELECTION / COMPLETENESS MISS**: the responder answered a DIFFERENT question than asked (gave the self-join the user explicitly rejected) and actively dismissed the correct primary. Hence Completeness 2 and Actionability 2 — an engineer who explicitly wanted a non-self-join approach is handed exactly the thing they said they wanted to avoid, with no LAG option offered.
- Accuracy 3 (working query + true caveat, but the "NOT LAG, unreliable" framing is a factual overreach for a dense series). Clarity 4 (well-written).

**The exact canonical to feature for this ask:**
```sql
SELECT
  month,
  revenue_total,
  LAG(revenue_total, 12) OVER (ORDER BY month) AS revenue_same_month_last_year
FROM monthly_revenue
ORDER BY month;
-- Returns the value 12 rows back. ASSUMES a dense, gapless monthly series
-- (one row per month). If months can be MISSING, either densify with a date
-- spine first, or use the self-join on date_add('month', -12, cur.month)
-- (gap-safe by construction).
```

### Q1 ROOT CAUSE — RESOURCE EMPHASIS / FINDABILITY DEFECT (with responder over-application)

Grepped r07 (`resources/07-analytical-query-patterns.md`). The LAG form IS present, but the resource's framing actively steers AWAY from it for exactly this kind of ask:

- **r07:2789** Pattern B2 header — "LEADING CANONICAL — Period-over-period: YoY vs MoM with window functions."
- **r07:2810** the offset table HAS `LAG(metric, 12)` for YoY — but every row carries a **"CONTIGUOUS … every month present"** requirement column.
- **r07:2824–2826** FORM A (self-join) is explicitly labeled **"(preferred for YoY — gap-safe by construction)"** and **"It is the recommended pattern for any production YoY metric."**
- **r07:2860–2862** FORM B (the LAG form) is gated: **"Use this form when you need ranks/running totals … You MUST gap-fill first or LAG will silently shift the offset."**
- **r07:2903** the actual `LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month)` lives inside FORM B, behind the gap-fill warning.
- **r07:2930** DO-NOT-WRITE bans `LAG(usage_count, 12) … on a sparse monthly series with NO gap-fill`.

**Diagnosis:** The resource is calibrated for the *production-grade, possibly-sparse, per-entity YoY* case, where self-join IS the safer default. It LEADS with the self-join as "recommended" and buries LAG behind a "you MUST gap-fill first" gate. The responder faithfully amplified that framing into "NOT LAG, it's unreliable" — but the resource gives it **no landing point** for the simpler, explicit "grab the value N rows back from a DENSE ordered sequence WITHOUT a self-join" ask, where LAG is the correct, canonical primary and gap-fill is irrelevant (the series is dense by stipulation).

This is therefore primarily a **resource emphasis/findability defect** (r07 Pattern B2 leads with self-join and under-features LAG for the bare "value N rows back" ask), compounded by responder over-application (it withheld LAG entirely rather than leading with it + noting the dense-series assumption).

---

### Q2 — title-case / no-initcap — **5.00 (strong)**

- **No-initcap claim CONFIRMED** (trino.io/docs/467/functions/string.html): Trino 467 has only `lower`/`upper`; no `initcap`, no title-case function. (Postgres/Oracle/Spark have initcap; Trino does not.) Correct.
- **Workaround 1 CONFIRMED** (trino.io/docs/467/functions/regexp.html): `regexp_replace(string, pattern, function)` — the lambda receives an `array(varchar)` of capture groups, **1-indexed** (x[1]=group 1, x[2]=group 2). The docs literally give this exact example: `regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` -> `'New York'`. The responder's form is the canonical docs answer verbatim. `\w` does not need double-escaping in a Trino string literal (Trino does not treat backslash as a string escape). Correct.
- **Workaround 2 CONFIRMED valid:** `array_join(transform(split(lower(s), ' '), w -> upper(substr(w,1,1)) || substr(w,2)), ' ')` — split->array, transform+lambda, substr 1-indexed, array_join. All valid Trino 467. (It runs over `lower(s)` so the tail is already lowercase — correct in context.)

Correctly handles a function Trino lacks, with two valid approaches. No defect.

### Q3 — histogram / equal-width $50 buckets — **4.75 (strong)**

`(FLOOR(order_total / 50.0) * 50) AS price_band_start … GROUP BY FLOOR(order_total / 50.0) ORDER BY price_band_start`. Verified (math.html): `floor(x)` rounds down; `/50.0` forces non-integer division so FLOOR buckets correctly; GROUP BY on the FLOOR expression is valid. Correct equal-width histogram pattern. Completeness 4 only because Trino's native `width_bucket(x, bound1, bound2, n)` (verified in math.html as the equi-width bucketing function) would be worth a one-line "alternative" mention — but the FLOOR form is correct and idiomatic, so this is a minor enrichment, not a defect.

### Q4 — null-safe equality — **5.00 (strong)**

`CASE WHEN old.col IS NOT DISTINCT FROM new.col THEN 0 ELSE 1 END`. Verified (trino.io/docs/467/functions/comparison.html): `IS NOT DISTINCT FROM` is null-safe equality; `NULL IS NOT DISTINCT FROM NULL -> TRUE`, `NULL IS NOT DISTINCT FROM value -> FALSE`. The responder's semantics table and CASE usage are exactly correct. The r22/r28 citations are reads, not edits (no federation edit occurred) — not penalized; correctness is what's judged, and it's correct.

---

## Teacher guidance — iter775 designation: **FIX-A (resource emphasis/findability)**

Q1 root cause is a resource emphasis/findability defect in r07 Pattern B2, so iter775 = **FIX-A (light, additive)**:

**FIX-A:** Add/elevate a **LAG-first landing point** for the bare "value N rows back / prior-period value from an ordered sequence / WITHOUT a self-join" ask — distinct from the production-YoY decision tree that (correctly) prefers the self-join for possibly-sparse series.

Concretely, at the "value N rows back" / prior-period landing point in r07 (adjacent to Pattern B2, or a short pre-B2 signpost), feature:

```sql
-- "Grab the value N rows back in an ordered sequence" (dense series, no self-join):
LAG(metric, N) OVER (ORDER BY ordered_col)   -- value N rows before the current row
```
with:
1. A **keyword anchor** for: "value N rows back", "prior-period value", "row 12 positions back", "previous/earlier row value", "without a self-join", "cleaner than a self-join", "lookback offset".
2. A one-line **dense-series note**: "LAG counts ROWS, not calendar periods — this is exactly right when the series is dense/gapless (one row per month). If months can be MISSING, densify with a date spine OR use the self-join on `date_add('month', -12, cur.month)` (gap-safe by construction)."
3. A pointer to FORM A (self-join) as the **gaps fallback** — NOT as the blanket default for this phrasing.

**Important reconcile-in-place (do NOT just append):** soften r07:2824–2826's absolute "self-join is the recommended pattern for any production YoY metric" / the FORM B "you MUST gap-fill first" gate so they no longer read as "never use LAG." Reframe as: self-join = preferred when the series MAY be sparse; LAG = the clean canonical when the series is dense (and the user explicitly wants no self-join). The two forms answer the same question under different gap assumptions — make that the disambiguator, so the responder leads with LAG on the dense/"without self-join" phrasing instead of refusing it.

**Inoculation note:** also defang the responder's failure mode — add an inline note that "NOT LAG, it's unreliable" is WRONG as a blanket statement: LAG is correct and canonical on a dense series; the only caveat is gaps.

**Preserve (do NOT churn):** Q2 title-case (r27 §4.3 — both workarounds verified clean), Q3 FLOOR-histogram, Q4 IS NOT DISTINCT FROM cards are all correct — churn risk, leave them.

State.json NOT touched (remains iter774, set by teacher).
