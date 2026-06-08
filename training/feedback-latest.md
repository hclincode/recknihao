# Judge Feedback — iter757

DEFAULT durability-breadth + mode re-probe + mode bulletproofing. All four dialect claims verified against trino.io/docs/467 (window.html, aggregate.html, string.html) on 2026-06-09. Resources are NOT treated as ground truth.

---

## Q1 — Most common status per ticket (MODE RE-PROBE)

Answer: `max_by(status, cnt)` over a `(SELECT ticket_id, status, COUNT(*) AS cnt ... GROUP BY ticket_id, status)` subquery, outer `GROUP BY ticket_id`.

**Docs verification:** aggregate.html confirms `max_by(x, y) -> [same as x]` = "the value of x associated with the maximum value of y". Over a per-(group,value) COUNT(*) subquery this returns the single most-frequent value per group = the mode. There is NO native `mode()` aggregate in Trino 467; this is the correct idiom. The responder correctly returned a scalar value (NOT a MAP) and explained the mechanism cleanly — the exact opposite of the iter755 approx_most_frequent-as-scalar defect.

- Accuracy: 5
- Completeness: 5
- Clarity: 5
- Actionability: 5
- **Q1 avg: 5.00**

This is the **2nd consecutive clean mode datapoint** (iter756 Q1 = 5.00 was the 1st post-fix). **MODE IS NOW BULLETPROOFED.**

---

## Q2 — Percentile rank: fraction of all salespeople with revenue AT OR BELOW theirs (top=1.0)

Answer: `PERCENT_RANK() OVER (ORDER BY total_revenue) AS fraction_at_or_below`, with explanation "0.0 = lowest revenue (nobody is at or below), 1.0 = highest, 0.5 = median".

**Docs verification (window.html) — HIGHEST-RISK CHECK, the responder is WRONG:**
- `cume_dist()` = "number of rows preceding or peer with the row ... divided by total rows" = count of rows with value <= current / N. For the LOWEST row this is ~ 1/N (NOT 0, because the row is at-or-below itself); for the highest = 1.0; median ~ 0.5. **This is exactly "fraction of rows at or below".**
- `percent_rank()` = `(rank - 1) / (n - 1)`. For the LOWEST row this = 0.0; it is a relative-rank-*position*, NOT "fraction at or below".

The question explicitly asked for "the fraction of rows AT OR BELOW this row's value, top row = 1.0" — that wording IS the definition of `cume_dist`. The responder:
1. Picked the **wrong window function** (`percent_rank` instead of `cume_dist`).
2. Gave a **factually wrong boundary characterization**: "0.0 = lowest (nobody is at or below)" is false — the lowest-revenue salesperson IS at-or-below their own value, so the true fraction is >= 1/N, which `cume_dist` returns. percent_rank's 0.0 does not mean "fraction at or below".

Both endpoints (top=1.0) happen to coincide, but the semantics and every interior/lowest value diverge. This is an **accuracy defect**, not a stylistic miss.

This is a **FINDABILITY/SELECTION miss**, not a resource defect: per the iter757 sweep, `cume_dist` already exists in resources (r07:3275) explicitly distinguished from percent_rank as "fraction of rows AT OR BELOW this one (includes ties, top=1.0)". The responder landed on percent_rank instead of routing to the cume_dist canonical.

- Accuracy: 2 (wrong function for the asked semantics + wrong boundary claim)
- Completeness: 3 (returns a per-row 0..1 value, top=1.0 correct, but interior/lowest values wrong vs ask)
- Clarity: 4 (clear prose, but the clarity reinforces a wrong claim)
- Actionability: 3 (runnable SQL, but produces semantically-wrong column for the question)
- **Q2 avg: 3.00**

---

## Q3 — Running/cumulative PRODUCT over an ordered window (per fund, $1 grown by multiplying monthly multipliers)

Answer: **HONEST DECLINE** — "the resources do not cover the pattern for multiplying values together in a running window. The general approach EXP(SUM(LN(x))) exists in many SQL systems but I cannot find it documented in the Trino 467 resources, so this is a gap." Suggested checking docs / app-code / data team.

**Docs verification (aggregate.html):** Confirmed Trino 467 has **NO native `product()` aggregate** and no cumulative-product window function. The correct idiom is:
```
exp(sum(ln(growth_multiplier)) OVER (PARTITION BY fund ORDER BY month ROWS UNBOUNDED PRECEDING))
```
with the caveat that `ln(x)` requires `x > 0` (monthly growth multipliers are positive, so this is fine; zero or negatives would break it). (`reduce_agg` is a non-windowed alternative but does not give the running/cumulative-over-window shape.)

**Judgment:** The responder even named the correct general technique (EXP(SUM(LN(x)))) and honestly flagged it as a resource gap rather than fabricating a fake `product()` function or guessing wrong syntax. This is **good behavior — no hallucination penalty**; an honest decline of a genuinely-uncovered capability is NOT a fabrication. But it IS a real, useful, findable-but-missing capability, so completeness and actionability are necessarily low (no working answer was delivered). The teacher's sweep confirms zero `exp(sum(ln`/`exp(avg(ln`/running-product/cumulative-product hits in resources — genuinely absent.

- Accuracy: 4 (no false claim; correctly identified the technique and the gap; not penalized for declining vs fabricating)
- Completeness: 2 (no answer delivered)
- Clarity: 4 (clear, honest about the gap, named the real technique)
- Actionability: 2 (engineer is told to look elsewhere; no runnable SQL)
- **Q3 avg: 3.00**

---

## Q4 — Reorder a multi-segment delimited string "ERR:404:page_not_found" -> "page_not_found (404)"

Answer: `CONCAT(split_part(event_tag, ':', 3), ' (', split_part(event_tag, ':', 2), ')')` -> "page_not_found (404)". Noted split_part is 1-indexed, returns NULL (not empty) out of range, use COALESCE.

**Docs verification (string.html):** `split_part(string, delimiter, index) -> varchar`, "Field indexes start with 1", "If the index is larger than the number of fields, then null is returned"; `concat(string1, ..., stringN)` native. The answer grabs the 3rd then 2nd segment and reassembles correctly producing "page_not_found (404)". The NULL-out-of-range + COALESCE note is accurate. split_part is a valid tool for a fixed-arity delimited string (regexp_replace `$N` would also work but is not required). CLEAN.

- Accuracy: 5
- Completeness: 5 (correct output + NULL-edge guidance)
- Clarity: 5
- Actionability: 5
- **Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 2 | 3 | 4 | 3 | 3.00 |
| Q3 | 4 | 2 | 4 | 2 | 3.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (5.00 + 3.00 + 3.00 + 5.00) / 4 = 4.00 — PASS** (>= 3.5; overall average governs, no single-Q veto).

**MODE: BULLETPROOFED** (2nd consecutive clean datapoint, iter756 + iter757).

---

## iter758 designation — DUAL FIX-A (running-product PRIMARY, cume_dist SECONDARY)

Two legitimate gaps surfaced. Recommend doing **both in one iteration** — they are small, non-overlapping pure-additions in different sections, and both are real/useful capabilities.

### FIX-A (PRIMARY) — running-product canonical (Q3, genuine net-new missing canonical)
- ADD a LEADING CANONICAL for running/cumulative product. COPY:
  `exp(sum(ln(growth_multiplier)) OVER (PARTITION BY fund ORDER BY month ROWS UNBOUNDED PRECEDING))`
- Keyword anchors: running product / cumulative product / multiply values together over a window / compound growth / $1 grown by multiplying multipliers / product of a column / cumulative multiplication / running multiply.
- CAVEAT: `ln(x)` requires `x > 0` (positive multipliers fine; zero/negative breaks it — note this explicitly).
- Cross-ref the transcendental-math family (r27 section 4.4F ln/exp/log) and the cumulative-SUM-OVER window pattern; note there is NO native `product()` aggregate and `reduce_agg` is the non-windowed alternative.
- Also cross-ref the geometric-mean idiom `exp(avg(ln(x)))` (iter754 Q2) as the sibling/aggregate form of the same log-trick — these belong next to each other.

### FIX-A (SECONDARY) — cume_dist findability/selection + disambiguation router (Q2)
- The cume_dist canonical EXISTS (r07:3275) but the question routed to percent_rank. ADD keyword anchors at the cume_dist canonical: "fraction of rows at or below / what fraction of values are at or below this one / what percentile does this value sit at / cumulative distribution / at-or-below fraction / top row = 1.0".
- ADD a one-line cume_dist-vs-percent_rank DISAMBIGUATION ROUTER: **"at-or-below fraction (lowest ~ 1/N, top = 1.0, includes the row itself) = cume_dist; relative rank position (lowest = 0.0, top = 1.0, strictly-below) = percent_rank".**
- Optionally INLINE-DEFANG the "percent_rank = fraction at or below" misreading at the cume_dist landing point (un-copyable WRONG marker per iter693).

**Priority rationale:** running-product is a cleaner net-new canonical (capability genuinely absent); cume_dist is a findability/disambiguation fix on existing content. Both are cheap and independent — do both in iter758, lead with running-product.

**Do NOT re-edit** (churn-risk, clean/perfect): r23 section 3.1D mode canonical (BULLETPROOFED), r23 section 3.1E IF, r27 section 4.2 to_iso8601, r27 section 4.3A reformat, split_part content, r07 cume_dist core definition (only ADD anchors/router, do not rewrite the definition).
