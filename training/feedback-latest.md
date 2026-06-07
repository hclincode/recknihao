# Judge Feedback — iter620 (EXTENDED PHASE)

**Overall: 4.4375 PASS** (margin +0.9375 above the 3.5 floor) — Trino pinned to 467. FEDERATION NOT PROBED (4.49944/310 row UNCHANGED).

**HEADLINE: FIX A only PARTIALLY took. Q1 (the hand-picked GROUPING SETS re-probe) is STILL WRONG.** The responder DID switch from `CUBE` to the `GROUPING SETS` keyword — the construct choice is now right — but it botched the LIST COMPOSITION: it wrote `GROUP BY GROUPING SETS ((salesperson, month), (month), (salesperson), ())`, which INCLUDES the `(salesperson, month)` detail tuple. Per Trino 467 docs this list is **identical to `CUBE(salesperson, month)`** — so the responder reproduced the exact iter619 over-production, just spelled out as explicit grouping sets. The SQL emits one row per salesperson-month combination = the detail the user EXPLICITLY excluded. The `CASE WHEN 0 THEN 'Detail'` and the prose "without the hundreds of detail rows" are an internal contradiction: the SQL produces the very detail rows the prose claims it won't. Q2 / Q3 / Q4 are all correct and clean.

---

## Per-question scores

### Q1 — Hand-picked GROUPING SETS: per-salesperson total + per-month total + grand total, NOT the salesperson-month detail
**Accuracy 2 / Completeness 3 / Clarity 4 / Actionability 3 → avg 3.00 — DEFECT (FIX A partial; list still includes the excluded detail tuple)**

Responder used:
```sql
GROUP BY GROUPING SETS ((salesperson, month), (month), (salesperson), ())
```
with a `CASE ... WHEN 0 THEN 'Detail' ...` row-type label and prose claiming "without the hundreds of detail rows."

**This is STILL WRONG.** VERIFIED trino.io/docs/467/sql/select.html, which states verbatim that
> `CUBE (origin_state, destination_state)` is equivalent to: `GROUPING SETS ((origin_state, destination_state), (origin_state), (destination_state), ())`

and
> "The `CUBE` operator generates all possible grouping sets (i.e. a power set) for a given set of columns."

So `GROUPING SETS ((salesperson, month), (salesperson), (month), ())` IS `CUBE(salesperson, month)` — the full power set. The `(salesperson, month)` sublist computes **one row per salesperson-month combination** = the cross-tab DETAIL the user said "EXPLICITLY NOT." The docs also confirm a GROUPING SETS list computes exactly the listed sets ("Grouping sets allow users to specify multiple lists of columns to group on...The columns not part of a given sublist of grouping columns are set to NULL") — which is precisely why including the `(a,b)` tuple emits the detail.

**Correct answer** — OMIT the `(salesperson, month)` detail tuple:
```sql
GROUP BY GROUPING SETS ((salesperson), (month), ())
```
This emits EXACTLY the three requested levels: per-salesperson subtotal, per-month subtotal, grand total — and NO detail row.

**Internal contradiction:** the responder's own `WHEN 0 THEN 'Detail'` branch and the prose "without the detail rows" directly conflict with the SQL it wrote (which DOES emit GROUPING bitmask-0 detail rows). Accuracy floored to 2: the answer produces the rows the user explicitly excluded, which is the entire point of the question. Clarity/Actionability salvaged somewhat because the row-type labeling scaffold and GROUPING() machinery are otherwise sound — but an engineer who pastes this gets the over-produced cross-tab.

**Diagnosis: routed-but-mis-applied / copy-paste-incompleteness.** FIX A's intent (steer hand-picked-subtotals away from CUBE toward GROUPING SETS) PARTIALLY landed: the responder reached for the GROUPING SETS keyword, but copied a list shape that happens to BE CUBE. It got the construct, botched the list — the r28 worked WRONG/RIGHT pair from FIX A apparently did not make the responder internalize that the `(a,b)` tuple itself is what reintroduces the detail.

---

### Q2 — File extension = part after the LAST dot (multi-dot filenames, e.g. 'report.final.pdf' -> 'pdf')
**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → avg 5.00 STRONG PASS**

```sql
element_at(split(filename, '.'), -1) AS file_extension
```
VERIFIED trino.io/docs/467/functions/string.html: `split(string, delimiter)` "Splits `string` on `delimiter` and returns an array" — returns ALL segments. VERIFIED trino.io/docs/467/functions/array.html: `element_at` "If `index` < 0, `element_at` accesses elements from the last to the first" — so `-1` returns the LAST segment = the text after the final dot. `'report.final.pdf'` → `['report','final','pdf']` → `'pdf'` CORRECT. The noted `'tar.gz' -> 'gz'` caveat (last segment only) is honest and correct — `element_at(-1)` returns exactly the last segment, so a double-extension yields only `gz`. Zero defects.

---

### Q3 — Number of WHOLE months between subscription start and cancel date (churn duration)
**Accuracy 4.5 / Completeness 4.5 / Clarity 5 / Actionability 5 → avg 4.75 PASS**

```sql
date_diff('month', subscription_start_date, subscription_cancel_date) AS months_subscribed
```
VERIFIED trino.io/docs/467/functions/datetime.html: `date_diff(unit, timestamp1, timestamp2) → bigint` "Returns `timestamp2 - timestamp1` expressed in terms of `unit`." For `'month'` this is the month-boundary/field difference (analogous to the year case in iter617) — it counts month boundaries crossed, NOT whether the day-of-month has been reached. This is the conventional answer to "whole months between two dates" and is acceptable. Minor un-dinged nuance: if the user wanted "completed months" in the strict anniversary sense (only count a month once the day-of-month is reached), a day-of-month CASE adjustment would be needed — same family as the iter618 completed-age fix. Valid and reasonable; small accuracy/completeness shave for not flagging that day-of-month subtlety.

---

### Q4 — One row per product = the FULL row with the highest quoted_price (keep all columns)
**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → avg 5.00 STRONG PASS**

Form A:
```sql
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY quoted_price DESC) AS price_rank
  FROM quotes
) WHERE price_rank = 1
```
VERIFIED trino.io/docs/467/functions/window.html: `row_number()` "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition"; window functions "run after the HAVING clause but before the ORDER BY clause" — they cannot appear in WHERE, so the outer-query wrapper filtering `price_rank = 1` is the CORRECT idiom (NOT a same-level WHERE-on-window-alias, which would be a resolution error). PARTITION BY product_id + ORDER BY quoted_price DESC + rank=1 = the full highest-price row per product, all columns retained. CORRECT.

Form B:
```sql
SELECT product_id,
       max_by(quote_date, quoted_price),
       MAX(quoted_price),
       max_by(quote_currency, quoted_price),
       max_by(rep_name, quoted_price)
FROM quotes GROUP BY product_id
```
VERIFIED trino.io/docs/467/functions/aggregate.html: `max_by(x, y)` "Returns the value of `x` associated with the maximum value of `y` over all input values." Each `max_by(col, quoted_price)` returns that column from the max-price row; `MAX(quoted_price)` returns the price itself. Reconstructs the highest-price row per product. CORRECT. Both forms valid Trino 467. Minor (un-dinged, correctly noted): on price ties ROW_NUMBER picks one arbitrarily and max_by is similarly tie-unstable.

---

## Overall average + label

Dim-avg method:
- Accuracy: (2 + 5 + 4.5 + 5)/4 = 4.125
- Completeness: (3 + 5 + 4.5 + 5)/4 = 4.375
- Clarity: (4 + 5 + 5 + 5)/4 = 4.75
- Actionability: (3 + 5 + 5 + 5)/4 = 4.50
- **Overall = (4.125 + 4.375 + 4.75 + 4.50)/4 = 4.4375**

Per-Q-avg cross-check: (3.00 + 5.00 + 4.75 + 5.00)/4 = **4.4375** — methods agree.

**OVERALL = 4.4375 PASS** (margin +0.9375 above the 3.5 floor). The overall average GOVERNS the label = PASS. Q1's 3.00 is flagged as a quality concern + content directive, NOT a per-question gate or label override.

---

## Q1 verdict (CRITICAL) — did FIX A take?

**PARTIAL — and the answer is STILL WRONG.** The construct migrated correctly (CUBE → GROUPING SETS keyword), but the LIST COMPOSITION includes the `(salesperson, month)` detail tuple, which is exactly `CUBE(salesperson, month)` (docs-confirmed equivalence) — so it STILL emits the per-salesperson-per-month detail rows the user explicitly excluded. The prose "without the detail rows" + `WHEN 0 THEN 'Detail'` contradicts the SQL.

**Class: routed-but-mis-applied / copy-paste-incompleteness** — got the construct, botched the list.

### Precise iter621 directive (r28, hand-picked WRONG/RIGHT pair)

At the r28 DECIDE-FIRST hand-picked → GROUPING SETS branch and its WRONG/RIGHT SQL pair, ADD (additive / reconcile-in-place; do NOT rewrite the iter609 signpost, iter610 four-value label-mapping, the GROUPING() bitmask lock, or the ROLLUP/CUBE worked examples):

1. **State the equivalence explicitly at the WRONG/RIGHT pair:** `GROUPING SETS ((a,b),(a),(b),())` IS `CUBE(a,b)` — it STILL includes the `(a,b)` detail row (GROUPING bitmask 0). Switching from the `CUBE` keyword to a spelled-out GROUPING SETS list does NOT remove the detail if you keep the `(a,b)` tuple in the list.
2. **The RIGHT hand-picked form OMITS the `(a,b)` tuple:** `GROUP BY GROUPING SETS ((a), (b), ())` → emits EXACTLY by-a (bitmask 1) + by-b (bitmask 2) + grand total (bitmask 3), NO `(a,b)` detail (bitmask 0).
3. **Add a crisp "do NOT list the (a,b) detail tuple" note:** "When you want ONLY the subtotals (by X AND by Y but NOT the X-Y cross-tab detail), do NOT include the `(salesperson, month)` / `(a,b)` tuple in the GROUPING SETS list. Including it = CUBE = the detail rows come back. List only the single-column sets and `()`."
4. **Keyword anchors** to route the failing phrasing: "just those three levels of summary", "explicitly not a row for every combination", "not the cross-tab detail", "per-salesperson total AND per-month total but not per-salesperson-per-month".

This is the same root cause as iter619 (CUBE over-production), surfacing one level deeper: the responder now reaches for GROUPING SETS but does not understand that the `(a,b)` tuple is itself what reintroduces the detail. The fix must make the `(a,b)`-tuple = detail-row equation un-missable AT the WRONG/RIGHT pair.

---

## Other slips / fabrications

None beyond Q1. Q2 `split`/`element_at(-1)`, Q3 `date_diff('month',...)`, Q4 `ROW_NUMBER`-outer-WHERE + `max_by` are all real Trino 467, correctly used. No `::`-cast, no QUALIFY, no PERCENTILE_CONT/fabricated function, no invalid-clause-placement, no off-by-one, no type-mismatch, no wrong-function-choice. Q3's day-of-month-completed-month subtlety is a minor un-flagged nuance, not a defect.

**Federation NOT probed — 4.49944/310 row UNCHANGED.**

WebFetched/verified today: trino.io/docs/467/sql/select.html (CUBE(a,b) ≡ GROUPING SETS ((a,b),(a),(b),()) verbatim + "all possible grouping sets (power set)" + GROUPING SETS computes exactly the listed sets — Q1), functions/string.html (`split` "returns an array" — Q2), functions/array.html (`element_at` index<0 "from the last to the first" — Q2), functions/datetime.html (`date_diff(unit,ts1,ts2)` "timestamp2 - timestamp1 expressed in terms of unit" — Q3), functions/window.html (`row_number()` "starting with one" + window fns "run after HAVING before ORDER BY" so not in WHERE — Q4), functions/aggregate.html (`max_by(x,y)` "value of x associated with the maximum value of y" — Q4).
