# Judge Feedback — iter601 (EXTENDED PHASE)

**Date:** 2026-06-07 · **Phase:** extended · Trino 467 pinned · Docs verified against trino.io/docs/467.

**Overall: 4.3125 PASS** (margin +0.8125 above 3.5 floor). Federation NOT probed — 4.49944/310 row UNCHANGED.

All four answers verified against trino.io/docs/467 (TABLESAMPLE wording cross-checked on the SELECT page; GROUP BY/ORDER BY alias rule confirmed). Zero `::`-casts, zero wrong-version pins, zero fabricated functions. Two real defects: Q1 landing-point miss (CASE instead of width_bucket — the iter601 FIX A re-probe did NOT exercise width_bucket) and Q4 WRONG-FUNCTION-CHOICE for the stated goal (led with BERNOULLI for a "don't scan everything" ask, when SYSTEM is the I/O-reducing sampler). The responder correctly stated BERNOULLI doesn't save I/O, which keeps Q4 out of accuracy-failure, but it still recommended the wrong sampler for the goal.

---

## Q1 — Fixed-width 100ms latency bands + catch-all top bin (>1s)

**Scores: Accuracy 5 / Completeness 3 / Clarity 5 / Actionability 4 = 4.25**

Responder used a `CASE WHEN response_time_ms < 100 THEN '0-100ms' ... WHEN < 1000 THEN '500ms-1s' ELSE '1s+' END AS response_bucket, COUNT(*) ... GROUP BY response_bucket ORDER BY CASE response_bucket WHEN ... END`. The `ELSE` arm is the overflow catch-all for everything >= 1s.

VERIFIED:
- The CASE-chain answer is **correct and runnable in Trino 467**. GROUP BY and ORDER BY can both reference the SELECT output alias `response_bucket`. trino.io/docs/467/sql/select.html: ORDER BY "Each expression may be composed of output columns, or it may be an ordinal number selecting an output column by position"; the docs' own example uses a SELECT alias in ORDER BY (`... AS spend ... ORDER BY spend`). Boundary logic is correct: contiguous `< 100 / < 200 / ...` ranges with a single open-ended `ELSE` overflow bin. No off-by-one — each band's lower edge is the previous band's upper edge, and the ELSE captures the slow tail cleanly.

LANDING-POINT MISS (the FIX A re-probe did NOT fire):
- The question literally asks for FIXED-width bands plus an overflow catch-all — the textbook `width_bucket(x, ARRAY[100,200,...,1000])` use case, which the iter601 teacher clarified at r07 Pattern C4 (0..N numbering + the "top bin is bucket N" off-by-one trap). The responder routed to CASE instead, so the iter601 FIX A clarifier was NOT exercised. This is NOT an accuracy hit (CASE is correct), but it is a completeness/findability gap: for many bands, `width_bucket` is far more concise and less error-prone than a 10-arm CASE, and the engineer's keywords ("fixed 100ms-wide bands", "count per band", "catch-all top band") should surface it. Completeness -2, Actionability -1.

iter602 teacher fix (PRIMARY): at r07 Pattern C4, add a short CASE-vs-width_bucket SIGNPOST + keyword anchors so "fixed-width bands"/"100ms-wide bands"/"count per band"/"overflow/catch-all top band" route to `width_bucket`. Show the equivalent width_bucket form for THIS shape, e.g. `width_bucket(response_time_ms, ARRAY[100.0,200.0,300.0,400.0,500.0,600.0,700.0,800.0,900.0,1000.0])` → bucket 0 = <100, bucket k = [100k, 100(k+1)), bucket 10 = >=1000 (the >1s overflow = bucket N, not N-1 — reuse the FIX A trap). Keep CASE shown as the explicit, label-friendly equivalent: CASE is the natural choice when you want human-readable band LABELS ('0-100ms'), which is exactly what this engineer asked for — so do NOT demote CASE, just add the width_bucket route for the "many uniform bins, integer index is fine" case. Diagnosis: LANDING-POINT MISS (content exists at C4, keyword surface didn't route the "fixed-width bands + overflow" phrasing there).

---

## Q2 — Extract numeric part from "ORDER-4821-US" via pattern match

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00**

Responder gave `regexp_extract(reference, '\d+') AS order_number` (first digit-run) and the more precise `regexp_extract(reference, '-(\d+)-', 1)` (dash-delimited middle group; 3rd arg 1 = capture group 1).

VERIFIED at trino.io/docs/467/functions/regexp.html:
- `regexp_extract(string, pattern) → varchar` — "Returns the first substring matched by the regular expression `pattern` in `string`". `regexp_extract(reference, '\d+')` returns the first digit run ('4821', '00293'). Correct.
- `regexp_extract(string, pattern, group) → varchar` — "Finds the first occurrence of the regular expression `pattern` in `string` and returns the capturing group number `group`". Group 1 = first parenthesized group, so `'-(\d+)-'` with group 1 returns the middle numeric block. Correct.
- `'\d+'` is valid: Trino string literals do NOT treat backslash as an escape, so `'\d+'` reaches the regex engine intact as backslash-d-plus = one-or-more digits. Correct.

Two complementary forms (loose first-digit-run vs. anchored capture-group), correct semantics, directly addresses "pattern match, not manual dash-splitting." Zero defects. (Leading-zero forms return varchar '00293'; an int would need a CAST, not asked — no ding.)

---

## Q3 — Collapse array of tags into comma-separated string for CSV

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00**

Responder gave `array_join(product_tags, ',') AS tags_csv`.

VERIFIED at trino.io/docs/467/functions/array.html:
- `array_join(x, delimiter) → varchar` — "Concatenates the elements of the given array using the delimiter. Null elements are omitted in the result." `array_join(ARRAY['billing','enterprise','trial'], ',')` → `'billing,enterprise,trial'`. Exactly the requested CSV collapse. Correct, idiomatic, purpose-built. Zero defects. (The `array_join(x, delimiter, null_replacement)` 3-arg overload exists if explicit null handling is later needed — not required here.)

---

## Q4 — Sample a random handful from a 100M+ row table without scanning everything

**Scores: Accuracy 4 / Completeness 4 / Clarity 5 / Actionability 4 = 4.25**

Responder gave `SELECT * FROM events TABLESAMPLE BERNOULLI (5) WHERE event_date >= CURRENT_DATE - INTERVAL '7' DAY LIMIT 100` and explained that BERNOULLI reads blocks then randomly drops rows — the speedup comes from the partition filter + fewer rows aggregated, NOT from less I/O; LIMIT caps the output.

VERIFIED at trino.io/docs/467/sql/select.html (TABLESAMPLE section):
- Syntax `TABLESAMPLE BERNOULLI (percentage)` is valid (docs example `SELECT * FROM users TABLESAMPLE BERNOULLI (50);`). Correct.
- BERNOULLI: "all physical blocks of the table are scanned and certain rows are skipped" and **"does not reduce the time required to read the sampled table from disk."** The responder's I/O claim is therefore ACCURATE — this is the part that keeps Q4 out of accuracy-failure territory.
- SYSTEM: "divides the table into logical segments of data and samples the table at this granularity ... either selects all the rows from a particular segment of data or skips it." This is the sampler that actually skips data = reduces I/O.

WRONG-FUNCTION-CHOICE for the stated goal:
- The engineer's explicit goal is "without scanning everything / SELECT * LIMIT 100 is too slow" = an I/O-reduction ask. The I/O-reducing sampler is **TABLESAMPLE SYSTEM (n)**, which skips whole splits/segments. The responder LED with BERNOULLI, which by its own (correct) admission does NOT reduce I/O — so the headline recommendation does not serve the headline goal. The real work here is being done by the `event_date` partition filter (genuine pruning on the production Iceberg table) + LIMIT, with BERNOULLI adding row-level randomization but no scan reduction. That's a defensible composite, but the responder should have LED with SYSTEM for the "don't read everything" framing and offered BERNOULLI only as the more-statistically-uniform option when uniformity matters more than I/O. Accuracy -1 (right facts, recommended primary tool mismatched to goal), Completeness -1 (SYSTEM never mentioned), Actionability -1 (engineer steered to the non-I/O-reducing sampler for an I/O problem).

Diagnosis: ROUTED-BUT-MIS-APPLIED with a partial resource gap. state.json notes the TABLESAMPLE content lives at r23 ~lines 1092-1104 and DOES correctly state "BERNOULLI(N) after partition filter does NOT reduce I/O vs SYSTEM(N) skips whole splits/reduces I/O." So the content is present and correct — but the responder absorbed the "BERNOULLI doesn't reduce I/O" fact yet still LED with BERNOULLI for an I/O-reduction question instead of flipping to SYSTEM. The landing point states the contrast but does not give an explicit DECISION RULE mapping the goal to the sampler.

iter602 teacher fix (PRIMARY): at r23 ~line 1092 TABLESAMPLE neighborhood, add a tight DECISION-RULE / keyword-anchored signpost:
- "Goal = sample without reading everything / avoid full scan / sample a huge table fast" → **lead with TABLESAMPLE SYSTEM (n)** (skips whole splits/segments = less I/O). Anchors: "without scanning everything", "too slow to scan", "quick sample of a huge table", "don't read all 100M rows".
- "Goal = statistically uniform / unbiased per-row sample (clustering won't bias it)" → TABLESAMPLE BERNOULLI (n), BUT note it scans all blocks = no I/O saving; pair with a partition filter to bound the scan.
- Keep the existing (correct) BERNOULLI-vs-SYSTEM I/O contrast; this fix only adds the explicit goal→sampler mapping so the responder LEADS with the right one. Verify the SYSTEM "skips it" segment wording stays verbatim from trino.io/docs/467/sql/select.html. Reconcile-in-place; do not append a contradictory block.

---

## FIX A re-probe verdict (EXPLICIT)

Did the iter601 FIX A width_bucket re-probe actually exercise width_bucket? **NO.** The responder answered Q1 with a CASE WHEN chain, never reaching `width_bucket`. The CASE answer is CORRECT and runnable (alias-in-GROUP BY/ORDER BY confirmed valid in Trino 467), so this is a LANDING-POINT MISS, not an accuracy regression. The FIX A C4 clarifier (0..N numbering + top-bin-is-N trap) remains UNVERIFIED-IN-PRACTICE because the probe didn't route there. iter602 must add the CASE-vs-width_bucket signpost (above) and RE-PROBE width_bucket from the "fixed-width bands + overflow bin" angle to confirm the clarifier surfaces.

## New fabrication / slip flags

- No fabricated features or absences. No `::`-casts. No invalid clause placement. No wrong-version pins. All four queries parse-valid in Trino 467.
- Only real defect of substance: Q4 led with BERNOULLI for an I/O-reduction goal (wrong-function-choice, softened by the correct "no I/O saving" caveat). Q1 is a findability/completeness miss only.

## iter602 directives (summary)

1. PRIMARY: r23 ~line 1092 TABLESAMPLE — add explicit goal→sampler DECISION RULE (SYSTEM for "don't scan everything"/I/O-reduction; BERNOULLI for statistical uniformity, with the no-I/O caveat). Keyword-anchor the "sample a huge table without scanning everything" framing to SYSTEM.
2. PRIMARY: r07 Pattern C4 — add CASE-vs-width_bucket signpost + keyword anchors ("fixed-width bands", "100ms-wide bands", "count per band", "catch-all/overflow top band") so the fixed-width-histogram framing routes to width_bucket; show the equivalent width_bucket ARRAY form for the latency-bands shape, reusing the FIX A "top bin = bucket N" trap. Keep CASE as the label-friendly equivalent.
3. RE-PROBE (iter602-603): (a) width_bucket from "bucket values into fixed-width bins + overflow" angle to confirm FIX A clarifier surfaces; (b) TABLESAMPLE from a 2nd "fast sample of a giant table" framing to confirm responder LEADS with SYSTEM post-fix; (c) Federation re-probe — only marginal row at 4.49944/310, stale, highest-leverage breadth if a bulletproofed non-§13.x angle exists.
4. DO NOT: touch r22 §13.x federation guardrails (thin 4.49944/310, ZERO probe iter601); add `::`-casts (iter571 PIN); re-edit the verified-clean regexp_extract / array_join canonicals (both routed first-probe clean); bump training/state.json (already at 601).

WebFetched + verified verbatim today (2026-06-07): trino.io/docs/467/sql/select.html (TABLESAMPLE BERNOULLI "all physical blocks scanned...does not reduce the time required to read...from disk" + SYSTEM "skips it" segment-granularity — Q4; ORDER BY/GROUP BY output-alias references — Q1), trino.io/docs/467/functions/regexp.html (regexp_extract 2-arg + 3-arg group semantics — Q2), trino.io/docs/467/functions/array.html (array_join(x, delimiter) "Null elements are omitted" — Q3).

**OVERALL: 4.3125 PASS** — Q2 (regexp_extract) + Q3 (array_join) clean 5.00 first-probe; Q1 CASE correct but missed width_bucket (FIX A re-probe did NOT fire — landing-point miss, completeness ding); Q4 BERNOULLI is wrong-function-choice for an I/O-reduction goal (softened by correct no-I/O caveat — should have led with SYSTEM); iter602 = TABLESAMPLE goal→sampler decision rule at r23 + CASE-vs-width_bucket signpost at r07 C4; federation row stays 4.49944/310.
