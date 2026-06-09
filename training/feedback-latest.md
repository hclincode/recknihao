# Judge Feedback — iter870 (EXTENDED PHASE)

**Overall: 4.86 / 5 — STRONG PASS** (per-Q 4.50 / 5.00 / 4.97 / 4.97 = 19.44/4 = 4.859; margin +1.36 over 3.5; overall average governs, NO per-Q veto)

Federation NOT probed this iteration — the 4.49944/310 federation row is UNCHANGED (still FAIL).

All dialect facts verified against trino.io/docs/467 (functions/string.html, sql/select.html, functions/window.html, functions/datetime.html) + the official Trino "Just the right time date predicates with Iceberg" blog + WebSearch, 2026-06-10. PIN Trino 467.

---

## Q1 — sargable date filter for partition pruning (the iter870 sargable-date FIX re-probe)

**Sub-scores: Accuracy 4 / Completeness 4.5 / Clarity 5 / Actionability 4.5 = 4.50**

**FIX LANDED.** The responder led with the bare-column half-open range
`WHERE occurred_at >= current_date - INTERVAL '30' DAY AND occurred_at < current_date`
and explained Iceberg partition pruning (predicate compared to partition boundaries, whole files skipped at the metadata layer). This is the correct, robust, always-works best-practice form and exactly the iter870 fix. It did NOT regress.

**Dialect verification:**
- Bare-column half-open range enables Iceberg partition pruning — CORRECT (verified vs the date-predicates blog + pushdown docs: constant/constant-range comparisons push to Iceberg and prune on metadata).
- `current_date - INTERVAL '30' DAY` is valid — CORRECT (datetime.html: `current_date` = current date at start of query; `date - interval` arithmetic documented, e.g. `date '2012-08-08' - interval '2' day → 2012-08-06`).

**EXPLAIN "constraint on [occurred_at]" hint — ACCURATE, NOT fabricated.** Verified via WebSearch against Trino EXPLAIN output: pushed-down predicates appear in the `TableScan` node as `constraint on [<column>]` (real example form: `TableScan[... constraint on [acctbal] ...]`). So telling the engineer to look for `constraint on [occurred_at]` in the EXPLAIN plan as evidence of successful pushdown is a real, correct description of Trino 467 EXPLAIN output. This is the question I was asked to settle explicitly: **the hint is accurate.**

**ONE REAL ACCURACY DING (the -0.5 on Accuracy).** The responder presented three forms as anti-patterns that "defeat pruning → full scan":
- `EXTRACT(YEAR FROM occurred_at) = 2026`
- `date_trunc('day', occurred_at) = DATE '...'`
- `CAST(occurred_at AS DATE) = ...`

Per the OFFICIAL Trino date-predicates blog and the temporal-unwrapping / unwrap-cast optimizations (enabled by DEFAULT in Trino), Trino 467 AUTOMATICALLY rewrites all of these into equivalent bare-column timestamp range filters that DO push down and DO enable partition pruning:
- `CAST(ts AS date) = DATE'...'` → unwrapped to a constant timestamp range (PR #11170).
- `date_trunc('day', ts) = ...` → replaced with a constant timestamp range.
- `year(ts) = 2026` AND `EXTRACT(year FROM ts) = 2026` → rewritten to a BETWEEN spanning the whole year (WebSearch confirmed EXTRACT is unwrapped too).

So labeling these specific common temporal forms as full-scan anti-patterns is INACCURATE for Trino 467 — they produce correct results AND prune. The TRUE anti-pattern is wrapping the column in an expression Trino CANNOT unwrap (arbitrary/opaque functions, non-temporal transforms), where pruning is genuinely lost. The bare-column half-open range is still the right thing to TEACH (always safe, no reliance on optimizer rules, most readable for ranges, and the only clean form for "last 30 days"), but the framing "year()/date_trunc()/CAST defeat pruning" overstates the harm for the equality cases.

Completeness/Clarity/Actionability stay high: the lead is right, the EXPLAIN verification step is genuinely useful and correctly worded, and the engineer knows exactly what to write.

---

## Q2 — concat_ws(' ', first_name, last_name) to avoid 'Jane null' / trailing space

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00**

`concat_ws(' ', first_name, last_name) AS full_name` is exactly right. The "skips NULLs" claim is CORRECT and verified vs string.html: *"Any null values provided in the arguments after the separator are skipped"* — so `'Jane' + NULL → 'Jane'` with no trailing separator/space. The "returns NULL only if all args NULL" nuance is slightly loose vs the docs' precise rule (the documented null-return trigger is the SEPARATOR being null — *"If string0 is null, then the return value is null"*; with a non-null separator and all-null value args you get an empty string `''`, not NULL). This is a hair-splitting edge that does not affect the asked scenario (non-null space separator, names) and the practical outcome (no 'Jane null', no trailing space) is fully correct, so no ding. The CASE fallback is a reasonable belt-and-suspenders extra.

---

## Q3 — ROLLUP + GROUPING() for subtotals + grand total

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.875 = 4.97**

`GROUP BY ROLLUP(region, customer_id)` with `SUM(revenue)` and a `CASE` on `GROUPING(region, customer_id)` is correct and replaces the UNION cleanly.

**Bitmask mapping VERIFIED CORRECT vs sql/select.html.** GROUPING returns a bit set as decimal; *"bits are assigned to the argument columns with the rightmost column being the least significant bit ... a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise."* For `ROLLUP(region, customer_id)` the docs' own ROLLUP example yields exactly the responder's mapping:
- `0` = both included = Detail
- `1` = only region included (customer_id rolled up) = Region Total
- `3` = neither included (both rolled up) = Grand Total

Leftmost arg = high-order bit — CORRECT as stated. ROLLUP/CUBE/GROUPING SETS all supported — CORRECT. The CUBE values 0/1/2/3 and the GROUPING SETS `((region),(product),())` aside are accurate (CUBE produces the extra value 2 = only the second column included). Tiny Actionability nit only: no runnable end-to-end SELECT with ORDER BY GROUPING(...) for clean subtotal placement — cosmetic, not an error.

---

## Q4 — flag single highest-value order per customer as TRUE/FALSE

**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.875 = 4.97**

`ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY amount DESC)` in a CTE, then `(rn = 1) AS is_top_order` is correct. Comparison `rn = 1` yields a boolean (TRUE/FALSE) — correct. The ties nuance is VERIFIED vs window.html: `row_number()` returns *"a unique, sequential number for each row"* so on ties it picks ONE arbitrarily; `rank()` *"tie values in the ordering will produce gaps in the sequence"* so `(rank = 1)` flags ALL tied top orders. Responder's "ROW_NUMBER = one arbitrary winner, RANK = all tied winners" is exactly right and the most important nuance for this question. Inline no-CTE form acceptable (window fn projected then filtered/compared, not placed in WHERE — correct, no QUALIFY in 467). Tiny Actionability nit: did not explicitly note window functions can't go in WHERE/no QUALIFY when giving the inline form, but the CTE form already encodes the correct shape.

---

## iter871 recommendation — LIGHT FIX-A (small Q1 precision correction; NOT a full defect)

The Q1 lead answer, the `current_date - INTERVAL` validity, and the EXPLAIN "constraint on [occurred_at]" hint are all CORRECT — do NOT touch those. The single correction needed is the overstated anti-pattern framing:

- At the iter870 sargable date-filter card (r07 §1, with cross-refs in r23 §6 and r28 §4), KEEP the bare-column half-open range as the LEADING/canonical recommendation (always safe, no optimizer dependency, the only clean form for "last N days").
- ADD/RECONCILE one precision note: Trino 467's temporal-unwrapping / unwrap-cast optimizations (ON by default) AUTOMATICALLY rewrite `CAST(ts AS date) = DATE'...'`, `date_trunc('day', ts) = ...`, `year(ts) = N`, and `EXTRACT(year FROM ts) = N` into equivalent bare-column ranges that DO push down and DO prune — they are NOT full-scan anti-patterns. Cite the official date-predicates blog (trino.io/blog/2023/04/11/date-predicates.html).
- RE-AIM the "function-on-column defeats pruning" warning at the cases Trino CANNOT unwrap (opaque/non-temporal expression-wrapped columns), where pruning is genuinely lost. If the iter870 card currently ⚠-marks `year(col)=year(current_date)` as "correct-results-but-no-pruning / full scan", soften/correct that to "Trino auto-unwraps this form (prunes); still prefer the explicit half-open range for clarity and to never depend on optimizer rules."
- Verify against trino.io/docs/467 + the date-predicates blog before writing; FENCE any pipe-bearing content; do NOT churn the EXPLAIN-hint wording (it is accurate). NO federation edits.

If the teacher judges the existing iter870 card is already neutral enough on this point (does not assert the equality forms cause a full scan), then iter871 = DEFAULT NO-OP and just re-probe the unwrap nuance from a 2nd angle.

HOLD all iter534–869 locks. PIN 467. DO NOT bump training/state.json.

---

### Topic coverage touched this iter (all already PASSED; re-probe datapoints, no status change)
- *SQL query best practices for OLAP (partition column in WHERE, EXPLAIN verification, pushdown-breaking patterns)* — Q1 (sargable date / pruning / EXPLAIN). Strong on the lead + EXPLAIN; minor unwrap-framing precision gap noted.
- *Analytical query patterns on Iceberg+Trino* / *Common analytical query patterns* — Q2 (concat_ws), Q3 (ROLLUP/GROUPING), Q4 (ROW_NUMBER/RANK flag). All clean.
