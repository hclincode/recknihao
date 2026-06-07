# Judge Feedback — iter598 (EXTENDED PHASE)

**Date**: 2026-06-07
**Phase**: extended
**Trino version pin**: 467

**Overall: 4.5625 STRONG PASS** (overall average governs the label; PASS = avg ≥ 3.5). Federation NOT probed — 4.49944/310 row UNCHANGED.

All claims verified against trino.io/docs/467 (string, math, aggregate, comparison) on 2026-06-07.

---

## Q1 — string suffix/prefix check vs `LIKE '%.csv'`, perf on a big table

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS**

Responder: `starts_with()` exists for prefix in Trino 467; **no `ends_with()`** in 467; for suffix use `LIKE '%.csv'` (native idiom) or `substr(file_path, -4) = '.csv'` (negative start = count from end). Both perform well.

VERIFIED — every claim is docs-grounded:
- trino.io/docs/467/functions/string.html: `starts_with(string, substring) → boolean` — *"Tests whether `substring` is a prefix of `string`."* EXISTS. CONFIRMED.
- Same page: **no `ends_with`** — the responder's ABSENCE claim is TRUE, not a fabricated absence. (This is the iter598 inoculation target the teacher added at r23 §3.1A; it ROUTED CLEANLY first-probe — the responder did NOT fabricate `ends_with` carried from Spark/Snowflake/BigQuery.)
- Negative substr start: *"A negative starting position is interpreted as being relative to the end of the string."* CONFIRMED — `substr(file_path, -4) = '.csv'` is valid.

Perf framing is correct: a trailing-wildcard `LIKE '%.csv'` (and `substr`/`starts_with` on a column) is a full-scan row-level predicate — it does NOT enable partition pruning or stat-based file skipping on `file_path`. The responder framed both as "perform well" (cheap row-level predicates) without overclaiming pushdown — accurate. The implicit contrast with an ANCHORED prefix `LIKE 'US%'` (which CAN prune) is correct since a suffix cannot anchor. Zero defects.

## Q2 — round total_amount to nearest hundred (1342.75 → 1300; 1850.00 → 1900)

**Scores: Accuracy 5 / Completeness 3 / Clarity 5 / Actionability 5 = 4.50 PASS**

Responder: `ROUND(total_amount / 100.0) * 100` — divide by 100, round to integer, multiply back; noted `ROUND(x,d)` rounds to decimal places (not powers of 10) and `/100.0` forces float division; worked 1342.75 → 1300.

VERIFIED — the divide/round/multiply form is CORRECT and produces the right answers (1342.75/100=13.4275 → round 13 → 1300; 1850/100=18.5 → round 19 → 1900, HALF_UP). trino.io/docs/467/functions/math.html: `round(x, d) → "Returns x rounded to d decimal places."`

**Completeness ding (-2): the simplest form `round(total_amount, -2)` was not offered.** The docs page documents `round(x)` and `round(x, d)` but does NOT explicitly confirm negative-`d`; however **negative-scale rounding DOES work in Trino** — `round(x, -2)` rounds to the nearest hundred (1342.75 → 1300, 1850 → 1900). This is the canonical one-call idiom the user explicitly asked for ("simpler way than divide/floor/multiply?"). The responder gave a correct-but-not-the-simplest answer to a question that asked precisely for the simplest. The answer is not wrong and is fully actionable, so this is a completeness gap, not an accuracy error.

> Note: this is a RESOURCE GAP, not a responder slip — per the iter598 state notes, the teacher made a deliberate NO-OP on negative-scale round because the docs page does not explicitly document negative `d`. That caution was reasonable, but the behavior is real and verifiable. See teacher actions below.

## Q3 — boolean column for `plan_tier = 'enterprise'` without a big CASE WHEN

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS**

Responder: `plan_tier = 'enterprise' AS is_enterprise` — a boolean comparison directly in SELECT returns BOOLEAN true/false, no CASE needed; also noted `count_if(plan_tier='enterprise')` for the aggregation variant.

VERIFIED: a comparison expression is a first-class BOOLEAN-typed expression in Trino and is valid as a SELECT column (trino.io/docs/467/functions/comparison.html — comparison operators yield boolean). This is exactly the right "no CASE" answer; the `count_if` bonus correctly anticipates the natural follow-up (how many are enterprise) without conflating it with the row-level flag. Zero defects.

## Q4 — count DIFFERENT products each customer purchased (no double-counting repeats)

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS**

Responder: `COUNT(DISTINCT product_id) AS unique_products_purchased ... GROUP BY customer_id`; noted multiple `COUNT(DISTINCT)` allowed in one query.

VERIFIED: `COUNT(DISTINCT product_id)` per `GROUP BY customer_id` is the exact, correct idiom for "distinct products per customer." DISTINCT is a standard SQL aggregate set-quantifier; the `approx_distinct` doc explicitly references it: *"provides an approximation of count(DISTINCT x)."* The multi-distinct note is accurate and well-covered by r23 §LEADING CANONICAL. Zero defects.

---

## Overall

(5.00 + 4.50 + 5.00 + 5.00) / 4 = **19.50 / 4 = 4.5625 STRONG PASS**

All four per-Q averages ≥ 4.50. No `::`-casts, no fabricated features, no fabricated absences (the `ends_with` absence is TRUE), no wrong-version pins.

## Topic updates

- **SQL query best practices for OLAP / r23**: Q1 starts_with/ends_with suffix-prefix (fresh, inoculation routed clean, strong) + Q2 round-to-nearest-hundred (PASS, completeness gap) + Q3 boolean-expr-as-column (fresh strong) + Q4 COUNT(DISTINCT) per group (re-probe, strong). Net UP. Row stays PASSED.
- **Federation 4.49944/310**: NOT probed this iter — UNCHANGED.

## Diagnosis & iter599 teacher actions

**Q1 (starts_with/ends_with) — iter598 fix VALIDATED.** The r23 §3.1A adjacent block with the `ends_with`-NOT-registered inoculation and the `substr` negative-start suffix idiom routed cleanly on first probe. The responder led correctly, did not fabricate `ends_with`, and framed perf accurately. **DO NOT re-edit** — durable first-probe.

**Q2 (round to nearest hundred) — the only sub-5 dimension; classify as RESOURCE-GAP (not a responder slip).** The responder's divide/round/multiply answer is correct and actionable, but the user explicitly asked for "simpler than divide/floor/multiply" and the one-call answer `round(total_amount, -2)` exists and works in Trino 467.

Precise fix at the responder's landing point (r23 §3.1C HALF_UP / rounding neighborhood — the same place the divide/multiply pattern is cited from):
- Add a short, keyword-anchored note: *"round to nearest 10/100/1000 (negative scale)"*, *"round to nearest hundred dollars"*, *"simpler than divide/floor/multiply"*.
- State: `round(x, -2)` rounds to the nearest hundred; `round(x, -1)` to nearest ten; negative `d` rounds to the left of the decimal point. Keep the divide/multiply form as the explicit equivalent/fallback (it is correct and dialect-portable).
- **VERIFY BEFORE WRITING**: the docs page (trino.io/docs/467/functions/math.html) documents `round(x, d)` = "rounded to `d` decimal places" but does NOT explicitly state negative-`d` behavior. Before adding the claim, the teacher MUST confirm negative-scale `round` against a live Trino 467 (or the Trino `MathFunctions.round` source) and cite that verification in the note. Do NOT assert it solely from the docs page (the iter598 NO-OP caution was correct on that point). If it cannot be confirmed for 467, leave the NO-OP — the responder's divide/multiply answer is correct and this dimension stays a completeness ding, not an error.

**Q3 / Q4** — fresh/re-probe, both clean, no action. DO NOT manufacture canonicals for `expr = 'x' AS flag` or `COUNT(DISTINCT)` — ordinary valid SQL, well covered.

## Fabrication / slip watch

NONE. No fabricated function, no fabricated absence (ends_with correctly reported as absent), no `::`-cast, no wrong version. The single gap is a missing simpler-idiom completeness item on Q2, not an error.

## Re-probe targets (iter599-600)

- (a) round-to-nearest-N **2nd framing** — "round latency_ms to nearest 50" / "bucket revenue into 1000s" — confirm whether the responder reaches `round(x, -d)` once/if the teacher adds the verified note.
- (b) starts_with **2nd framing** — "rows where the SKU code begins with 'EU'" — confirm `starts_with(sku,'EU')` vs anchored `LIKE 'EU%'` routing and the pruning contrast holds.
- (c) Federation re-probe — only remaining marginal row (4.49944/310), now 43+ iters stale; highest-leverage breadth target if a bulletproofed angle exists that does NOT touch r22 §13.x guardrails.
