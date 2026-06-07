# Judge Feedback — iter599 (EXTENDED PHASE)

**Overall: 4.50 PASS** (margin +1.00 above 3.5 floor). Overall-average governs the label (PASS = overall avg ≥ 3.5; no per-question quality-gate override). **Federation NOT probed — 4.49944/310 row UNCHANGED.**

Per-directive: PIN Trino 467. All four technical surfaces independently WebSearch/WebFetch-verified against trino.io/docs today (2026-06-07). One genuine in-the-answer defect found in Q4 (invalid WHERE-on-window-alias clause placement) — flagged as a quality concern, NOT a label override.

---

## Q1 — `@` position + slice domain (strpos / split_part) — 5/5/5/5 = 5.00 STRONG PASS — FRESH

Responder: `strpos(email, '@')` 1-indexed, returns 0 if not found; `substr(email, strpos(email,'@')+1)` to slice everything after; ALSO recommended `split_part(email, '@', 2)` as the cleaner direct idiom.

**VERIFICATION (CONFIRMED):**
- trino.io/docs/current/functions/string.html — `strpos(string, substring) → bigint`: *"Returns the starting position of the first instance of substring in string. Positions start with 1. If not found, 0 is returned."* — responder's 1-indexed + 0-if-not-found claim VERBATIM correct.
- string.html — `split_part(string, delimiter, index) → varchar`: *"Splits string on delimiter and returns the field index. Field indexes start with 1."* — `split_part(email, '@', 2)` returns the domain (everything after the single `@`). Correct.

Both forms are valid Trino 467. The strpos+substr composition correctly slices after the delimiter (start = position+1, no length arg = to end of string, valid per substr docs). Recommending split_part as the cleaner idiom is exactly the right teaching move. Zero `::`-casts, zero fabrication. Zero defects.

---

## Q2 — zero-pad order ID to 8 chars (`format('%08d', n)`) — 5/5/5/5 = 5.00 STRONG PASS — FRESH

Responder: `format('%08d', order_id)` = 8-wide zero-padded decimal; extra examples `format('%05d',42)='00042'`, `format('%,d', ...)` thousands separators.

**VERIFICATION (CONFIRMED):**
- trino.io/docs/current/functions/string.html — `format(format, args...)` is Java `String.format`/printf-style. Docs show the exact zero-pad example `format('%08d', 8)` producing a zero-padded decimal. `%0Nd` printf zero-pad is valid.
- `%d` accepts an integral argument — `order_id` is numeric (BIGINT/INTEGER), so it is passed directly with NO CAST needed. Correct that no CAST is required here.
- `%,d` thousands-separator grouping is valid Java format syntax — correct bonus example.

The `'00004217'` target shape is produced exactly by `format('%08d', 4217)`. Beginner-clear (showed the 5-wide variant to make the width-digit explicit). Zero defects.

---

## Q3 — p95 latency at scale (approx_percentile) — 5/5/5/5 = 5.00 STRONG PASS — FRESH

Responder: `approx_percentile(latency_ms, 0.95)` for p95; array form `approx_percentile(latency_ms, ARRAY[0.5,0.95,0.99])` for multiple percentiles; noted Trino does NOT support `PERCENTILE_CONT(...) WITHIN GROUP (ORDER BY ...)`; T-Digest internally, fast at scale.

**VERIFICATION (CONFIRMED — including the absence claim is TRUE, not fabricated):**
- trino.io/docs/current/functions/aggregate.html — `approx_percentile(x, percentage) → [same as x]`: *"Returns the approximate percentile for all input values of x at the given percentage."* Single-arg form VERIFIED.
- aggregate.html — `approx_percentile(x, percentages) → array<[same as x]>`: *"Returns the approximate percentile ... at each of the specified percentages."* Array-of-percentages overload VERIFIED.
- **FABRICATED-ABSENCE CHECK — the "no PERCENTILE_CONT WITHIN GROUP" claim is TRUE.** The aggregate-functions page contains NO `PERCENTILE_CONT` and NO `WITHIN GROUP (ORDER BY ...)` for percentiles; `WITHIN GROUP` exists in Trino ONLY for `listagg()`. So the responder correctly stated an ABSENCE that is real — this is NOT a fabricated absence.
- T-Digest: aggregate.html references `tdigest_agg` / `merge(tdigest)` and the T-Digest functions page — approx_percentile is T-Digest-backed and single-pass / scales well. Claim correct.

This is the exact production-correct answer (matches the r05:2232 CRITICAL FOOTGUN lock). Zero defects.

---

## Q4 — 4 equal spending tiers (NTILE) — 2/4/4/2 = 3.00 FAIL (per-Q below 3.5) — IN-THE-ANSWER CLAUSE-PLACEMENT SLIP

Responder: `NTILE(4) OVER (ORDER BY total_spend DESC)` over a GROUP BY subquery; noted remainder rows go to the FIRST buckets; the outer query wrote `WHERE spending_tier IS NOT NULL` referencing the NTILE output alias; ALSO offered a `PERCENT_RANK() OVER (...) < 0.25 ... CASE` alternative.

**What is CORRECT (verified):**
- NTILE is a valid Trino 467 window function. trino.io/docs/current/functions/window.html documents `ntile(n)` — divides rows into `n` buckets.
- **Remainder semantics VERIFIED correct.** window.html verbatim: *"If the number of rows in the partition does not divide evenly into the number of buckets, then the remainder values are distributed one per bucket, starting with the first bucket."* The responder's "remainder rows go to the FIRST buckets" is exactly right (earlier buckets are the larger ones). Good detail.
- The `PERCENT_RANK() OVER (...) < 0.25` + CASE alternative is a valid second idiom.

**The DEFECT — `WHERE spending_tier IS NOT NULL` on the SAME SELECT level as the NTILE output is INVALID Trino 467.** The LED example is shaped:
```
SELECT ..., NTILE(4) OVER (ORDER BY total_spend DESC) AS spending_tier
FROM (...grouped subquery...)
WHERE spending_tier IS NOT NULL
```
This errors at plan time for **two independent reasons**, both verified:
1. **WHERE cannot reference a SELECT output alias.** trino.io/docs/current/sql/select.html — logical clause order is FROM → WHERE → GROUP BY → HAVING → SELECT → window → ORDER BY → LIMIT. WHERE is evaluated *before* the SELECT list (and its aliases) are computed, so `spending_tier` does not exist yet in WHERE. → `Column 'spending_tier' cannot be resolved` / column-not-found.
2. **Window-function results cannot be referenced in WHERE at all.** Window functions run after HAVING and before ORDER BY (window.html: window functions "run after the HAVING clause but before the ORDER BY clause"), so a window result is never available to a same-level WHERE. github.com/trinodb/trino issue #6447 documents the engine rejecting a window function used as a scalar in WHERE. To filter on a window output you MUST wrap it in a subquery/CTE and filter in the *outer* query.

**Superfluous-predicate note (secondary):** even if it parsed, `WHERE spending_tier IS NOT NULL` is dead weight — `ntile(n)` never returns NULL for any row of a non-empty partition (every row gets a bucket 1..n). The filter removes nothing.

**Net effect:** the responder's primary worked example does not run on Trino 467 as written — a beginner SaaS engineer would paste it and hit a planner error. The NTILE concept, the OVER clause, the remainder rule, and the PERCENT_RANK alternative are all correct, which is why this scores 3.00 (a real but bounded slip) rather than lower: drop the WHERE line entirely and the answer is fully correct.

**Scoring rationale:** Accuracy 2 (LED example errors at plan time — two-reason invalid clause placement); Completeness 4 (concept, remainder rule, and alternative all present and correct); Clarity 4 (well explained, but the broken example would confuse on execution); Actionability 2 (engineer's copy-paste fails). = 3.00.

---

## Overall

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | strpos/split_part domain extraction | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | format('%08d') zero-pad | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | approx_percentile p95 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | NTILE quartiles | 2 | 4 | 4 | 2 | 3.00 |

**OVERALL = (5.00 + 5.00 + 5.00 + 3.00) / 4 = 18.00 / 4 = 4.50 PASS.** Overall-average governs the label. Q4 per-Q below 3.5 flagged as a quality concern + content-fix directive, NOT a label override.

---

## Diagnosis + iter600 teacher directive

**Q4 WHERE-on-window-alias = ROUTED-BUT-MIS-APPLIED (resource-defect candidate at the NTILE landing point), NOT a content gap.** The NTILE canonical exists and routes correctly — r07 Pattern C3 (`resources/07-analytical-query-patterns.md` ~line 1701) is the NTILE LEADING CANONICAL (quartiles/deciles, remainder-to-earliest-buckets, no-frame restriction, worked tenant example). The responder reached it and got the concept + remainder rule right. The slip is in the example's clause placement: a window-function output alias filtered in a same-level WHERE.

This is the same class as the iter586/587 "un-confusable-in-the-example signal" interventions and the r07/r23 nested-window-ban lock — the canonical needs the example to be drop-in-valid, with an explicit WHERE-on-window-result anti-pattern callout right at the NTILE worked example.

**PRIMARY iter600 action — inspect the NTILE example at r07 Pattern C3 (~line 1701) and verify it does NOT show `WHERE <ntile_alias> ...` (or any window-output alias) at the same SELECT level.**
- If the resource's NTILE example contains a same-level `WHERE spending_tier ...`: **REPLACE in-place (reconcile-don't-append).** Either (a) remove the WHERE entirely (NTILE buckets every row — no filter needed to "divide into 4 tiers"), or (b) if a filter on the bucket is genuinely wanted, push it to an OUTER wrapper:
  ```sql
  SELECT customer_id, total_spend, spending_tier
  FROM (
    SELECT customer_id, SUM(amount) AS total_spend,
           NTILE(4) OVER (ORDER BY SUM(amount) DESC) AS spending_tier
    FROM orders
    GROUP BY customer_id
  ) t
  WHERE spending_tier = 1   -- top quartile only, IF filtering is wanted
  ```
- **ADD a one-line anti-pattern callout at the NTILE example** (mirrors the existing nested-window-ban / window-not-in-WHERE locks): *"Do NOT write `WHERE spending_tier IS NOT NULL` (or any filter on the NTILE output) at the same query level — window-function results and SELECT aliases are not visible to WHERE; wrap in a subquery and filter in the outer query. Also: `ntile(n)` never returns NULL for a non-empty partition, so an IS NOT NULL filter is dead weight."* Cite trino.io/docs/467/sql/select.html (clause order FROM→WHERE→…→SELECT→window) + the existing window-functions evaluation-order note.
- **VERIFY before writing** that the resource currently lacks this callout (grep the r07 NTILE block for `WHERE` near the example). If r07's example is already clean and valid, this was a responder composition slip under window-output-filter pressure rather than a resource defect — in that case ADD the anti-pattern callout to the NTILE example anyway (it's the un-confusable-signal inoculation that lands the fix on re-probe), and DO NOT rewrite the rest of Pattern C3.

**RE-PROBE (iter600-602):** re-ask quartiles/tiers with a filter-the-bucket framing (e.g., "give me only the top-spending quartile of customers") to confirm the responder produces the outer-wrapper form, not a same-level WHERE on the NTILE alias.

**DO NOT:** touch r22 §13.x federation guardrails without a fresh failure probe (4.49944/310 stays); add `::`-casts (iter571 PIN); rewrite the r07 NTILE Pattern C3 body, the remainder-to-earliest-buckets rule, or the no-frame note (all correct — additive callout only); touch the iter534-599 locks (r23 §3.1A starts_with/ends_with + format zero-pad + count_if + bool_or/bool_and; r05 approx_percentile-vs-PERCENTILE_CONT footgun [Q3 confirmed durable]; r27 strpos/position/split_part [Q1 confirmed durable]).

**No new fabrication.** Zero `::`-casts, zero wrong-version pins, zero fabricated functions across all four answers. The Q3 PERCENTILE_CONT absence claim is a TRUE absence (verified), not a fabrication. The single defect is a clause-placement slip in the Q4 LED example.

**WebSearch/WebFetch verified verbatim today (2026-06-07):**
- trino.io/docs/current/functions/string.html — strpos 1-indexed, 0-if-not-found (Q1); split_part field index starts at 1 (Q1); format('%08d', 8) zero-pad printf example (Q2).
- trino.io/docs/current/functions/aggregate.html — approx_percentile(x, percentage) + approx_percentile(x, percentages array) overloads (Q3); NO PERCENTILE_CONT / WITHIN GROUP except listagg (Q3 absence TRUE); T-Digest references (Q3).
- trino.io/docs/current/functions/window.html — ntile(n) remainder "distributed one per bucket, starting with the first bucket" (Q4 remainder correct); window functions run after HAVING before ORDER BY → not available in WHERE (Q4 defect).
- trino.io/docs/current/sql/select.html — clause order FROM→WHERE→GROUP BY→HAVING→SELECT→window→ORDER BY→LIMIT; WHERE cannot reference SELECT-list aliases (Q4 defect, reason 1).
- github.com/trinodb/trino issue #6447 — window function used as scalar in WHERE is rejected (Q4 defect, reason 2).

**Meta:** iter599 = NO resource edits (full NO-OP per state.json). iter600 = single targeted in-place fix/inoculation at the r07 NTILE Pattern C3 example (WHERE-on-window-output anti-pattern callout + ensure example is drop-in valid), reconcile-don't-append; federation row stays 4.49944/310; all locks held.

**OVERALL: 4.50 PASS — Q1 strpos/split_part + Q2 format zero-pad + Q3 approx_percentile all docs-verbatim correct and zero-defect; Q4 NTILE concept/remainder/PERCENT_RANK correct but LED example filters a window-output alias in a same-level WHERE (invalid Trino 467 for two independent reasons) — flagged as quality concern + iter600 in-place inoculation at r07 Pattern C3; no fabrication; Q3 PERCENTILE_CONT absence is a TRUE absence.**
