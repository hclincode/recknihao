# iter944 Judge Feedback — 2026-06-10 (EXTENDED PHASE, RE-PROBE sweep)

## Overall Verdict: **4.5625 PASS** (margin +1.0625)

Per-Q breakdown (Accuracy / Completeness / Clarity / Actionability):
- **Q1** (median deal size; exact PERCENTILE_CONT? approx published error?) — Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**
- **Q2** (AVG hours open→first_reply with NULL first_reply_at) — Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**
- **Q3** (suppliers with most products ranked) — Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**
- **Q4** (orders with MORE THAN 5 **DISTINCT** items) — Acc 3.0 / Comp 2.5 / Clar 4.0 / Act 3.0 = **3.125**

Sum 18.25 / 4 = **4.5625 PASS** (per-Q veto deactivated per run-prompt — overall avg governs; Q4 floor 3.125 does not veto).

Federation NOT probed (4.49944/310 row UNCHANGED).
All dialect claims verified vs trino.io/docs/467 (functions/aggregate.html, functions/datetime.html, sql/select.html) on 2026-06-10 per iter882 verify-BOTH-directions discipline — NOT against resources/.

---

## Q1 RE-PROBE VERDICT — FABRICATION ONE-OFF / SLIP CLOSED + BONUS PEDAGOGY

The iter943 Q2 fabrication (PERCENTILE_CONT WITHIN GROUP + 2.3% misattribution) **DID NOT RECUR**. Responder cleanly:

1. **LED with approx_percentile(amount, 0.5)** as THE percentile function — VERIFIED against aggregate.html which lists ONLY four `approx_percentile` overloads and NO `percentile_cont`/`percentile_disc`/`median`/`WITHIN GROUP`-for-percentile (WITHIN GROUP exists in 467 ONLY for `listagg`).
2. **Explicitly stated "no PERCENTILE_CONT()"** and **"no MEDIAN() function"** — DIALECT-ACCURATE per WebFetch 2026-06-10 (function-not-found family; both are foreign-dialect imports from Postgres/Snowflake/Oracle/SQL-Server).
3. **Refused to attach a standard-error figure to approx_percentile** — "Trino's official docs do NOT publish a standard-error figure for approx_percentile()" matches aggregate.html verbatim (no figure listed; tunable accuracy parameter, no closed-form guarantee).
4. **BONUS PEDAGOGY — explicit CORRECTION of the 2.3% misattribution**: "The 2.3% standard error you may have seen — that belongs to a different function (approx_distinct() for counting unique values), not approx_percentile()." This is the EXACT canonical disambiguation r23 percentile-inoculation L306/L312-313/L325-328 + glossary L3455-3456 teaches, and r05 CRITICAL SQL FOOTGUN card L2234-2266 reinforces. Responder didn't just AVOID the iter943 slip — it pre-emptively HEADED OFF the user's misconception. This is the durable application of the percentile pin family.
5. Array form `approx_percentile(amount, ARRAY[0.5,0.95,0.99])` VALID per signature #2 (`approx_percentile(x, percentages) → array<same type>`).
6. "Backed by quantile-digest / T-digest" — qdigest_agg/tdigest_agg EXIST as separate digest builders in 467; approx_percentile internally uses a digest-based sketch. Not a defect either way (general/architecturally accurate).

**Q1 SCOPE = CLEAN, NO DEFECT, BONUS PEDAGOGY.** The iter943 Q2 fabrication is now CONFIRMED ONE-OFF. The percentile-family pins (r05 L2234 / r23 L267-293 / r23 L2240) are findable, copy-magnetic, and being applied correctly with the disambiguation surfacing unprompted. **Escalation threshold for a dedicated "percentile router = approx_percentile ONLY" FIX-A card REMAINS at 2+ further recurrences without intervening clean answer** — iter944 RESETS the counter.

---

## Q2 — AVG NULL-skip + date_diff = CLEAN (5.00)

- `date_diff('hour', opened_at, first_reply_at)` — VERIFIED against datetime.html (`date_diff(unit, timestamp1, timestamp2) → bigint`; 'hour' supported with explicit example returning 24); arg-order `(earlier, later) → positive`, exactly as responder explained.
- `AVG` ignores NULL — VERIFIED verbatim ("avg() does not include null values in the count"). `date_diff(...)` returns NULL when `first_reply_at` is NULL (NULL propagation through scalar fn) → AVG correctly skips those tickets.
- "No timestamp-minus-timestamp operator" — CORRECT per WebFetch (interval arithmetic on timestamps exists, but timestamp-to-timestamp subtraction is NOT exposed; date_diff is the documented path).
- `COUNT(*) FILTER (WHERE first_reply_at IS NOT NULL)` / `IS NULL` variant — VALID per aggregate.html (FILTER supported for all aggregates).
- Optional WHERE redundancy `WHERE date_diff(...) IS NOT NULL` — equivalent to `WHERE first_reply_at IS NOT NULL`, slightly verbose but not wrong; AVG would have skipped anyway. Not a defect.

---

## Q3 — COUNT GROUP BY + ranking variants = CLEAN (5.00)

- `SELECT supplier_id, COUNT(*) AS product_count FROM products GROUP BY supplier_id ORDER BY product_count DESC` — VALID; ORDER BY can reference the SELECT alias `product_count` per select.html ("ORDER BY evaluated after any GROUP BY/HAVING").
- `ROW_NUMBER() OVER (ORDER BY product_count DESC)` global ranking — VALID per window.html.
- RANK() tie semantics 1,2,2,4 vs ROW_NUMBER 1,2,3 — CORRECT.
- Default NULLS LAST honored implicitly; no explicit NULLS-LAST claim that could trip the iter941 direction-dependence pin.

---

## Q4 — DISTINCT-vs-ROWS interpretation slip (3.125)

User EXPLICITLY emphasized "more than 5 **DISTINCT** items" / "more than 5 different things." Responder's Approach B uses `HAVING COUNT(*) > 5` over `order_line_items`, which counts **ROWS** not DISTINCT product_id.

**The DIALECT is fine — both `COUNT(*) > 5` and `COUNT(DISTINCT product_id) > 5` are valid Trino 467 HAVING expressions** (aggregate.html `count(x)` with DISTINCT allowed; HAVING after aggregation per select.html). The defect is **interpretation/completeness**:

- IF `order_line_items` is one-row-per-product-per-order (common schema), `COUNT(*) = COUNT(DISTINCT product_id)` and the two are equivalent.
- IF `order_line_items` allows duplicate product_id rows (e.g., separate line entries for the same SKU added twice, OR a per-fulfillment line table), `COUNT(*) > 5` OVER-COUNTS vs "5 different things" — an order with 6 rows of the same product_id would qualify under COUNT(*) but NOT under "more than 5 distinct items."

Given the user's explicit "DISTINCT" / "different" framing, the canonical lead should have been `HAVING COUNT(DISTINCT product_id) > 5`, OR responder should have flagged the rows-vs-distinct distinction. Neither happened. Approach A's `WHERE line_items > 5` over a pre-aggregated `line_items` count column is fine if that column already means "distinct products" — also not flagged.

- **Acc 3.0**: Query runs, valid Trino 467 dialect, correct in the common schema; wrong-result risk only when product_id can repeat across rows. Not a parse error, but reads the question imprecisely.
- **Comp 2.5**: Missed the explicit "DISTINCT" cue; no `COUNT(DISTINCT product_id)` variant offered; no rows-vs-distinct trap call-out.
- **Clar 4.0**: Two approaches A/B are clearly separated; HAVING-after-GROUP-BY pedagogy clean.
- **Act 3.0**: An engineer with a one-row-per-line schema with possible duplicates would ship Approach B as-is and silently over-count.

**SCOPE = RESPONDER INTERPRETATION SLIP**, NOT a findable resource gap and NOT a dialect defect. Resources teach `COUNT(DISTINCT x)` as the canonical for "distinct things" (reference_trino_count_distinct_single_arg.md pin + r05/r23 distinct-count cards); pinned fact "COUNT(DISTINCT x) single-arg, COUNT(DISTINCT *) invalid" is durable. Responder applied `COUNT(DISTINCT)` correctly on Q1-style probes in iter938/940 (LEFT JOIN fan-out de-dup) and Q3 of iter939 (`COUNT(DISTINCT visitor_id)`). This is a one-off READING-COMPREHENSION miss on the word "DISTINCT" in the prompt, not a missing card.

**iter945 = DEFAULT NO-OP / RE-PROBE-DON'T-CHURN.** Do NOT add a "distinct vs rows in HAVING" FIX-A card on a single occurrence — risks New-Card-over-attracts-adjacent (the per-bucket-count, anti-join, and refund-rate neighbors all use COUNT(*) and COUNT(DISTINCT x) at different layers; defang risks confusion) + defang-DO-NOT-WRITE backfire. **RE-PROBE Q4 next sweep** via a fresh "orders with more than N distinct products" question where the schema is explicit about duplicate line entries — verify responder leads with `COUNT(DISTINCT product_id)` when "distinct" is in the prompt. Escalate to a dedicated "distinct-vs-rows HAVING router" card ONLY if slip recurs across 2+ further sweeps without intervening clean answer.

---

## Pin status (all confirmed intact against 2026-06-10 docs)

- Trino 467 percentile = `approx_percentile(x, p)` ONLY (4 overloads); NO `percentile_cont` / `percentile_disc` / `median()`; WITHIN GROUP exists ONLY for `listagg` ✓
- `approx_percentile` has NO published std-error figure (tunable accuracy param) ✓
- 2.3% = `approx_distinct` ONLY (HyperLogLog standard error verbatim quote) ✓
- `approx_percentile(x, ARRAY[...])` array form VALID ✓
- AVG ignores NULL ✓
- `date_diff(unit, a, b) → bigint` day/hour-aware ✓; NO `TIMESTAMP - TIMESTAMP` operator ✓
- `COUNT(*) FILTER (WHERE)` VALID for all aggregates ✓
- COUNT GROUP BY + ORDER BY alias (ORDER BY after GROUP BY/HAVING) ✓
- ROW_NUMBER 1,2,3 / RANK 1,2,2,4 semantics ✓
- HAVING after aggregation; both `COUNT(*) > N` and `COUNT(DISTINCT x) > N` VALID ✓
- COUNT(DISTINCT x) single-arg; COUNT(DISTINCT *) invalid ✓
- "distinct items" → `COUNT(DISTINCT product_id)` (NEW emphasis: prompt-cue → idiom mapping)
- Default NULLS LAST regardless of direction ✓
- No QUALIFY ✓

---

## Verdict & next actions

**iter944 = DEFAULT NO-OP, RE-PROBE-DON'T-CHURN.** Teacher should make ZERO resource edits.

- Q1 RE-PROBE PASSED CLEANLY with BONUS pedagogy (explicit 2.3% misattribution correction surfaced unprompted) — iter943 fabrication CONFIRMED ONE-OFF.
- Q4 distinct-vs-rows interpretation slip is a 1st-instance responder reading-comprehension miss, NOT a findable resource gap and NOT a dialect defect. Resources already teach `COUNT(DISTINCT)` as canonical for "distinct" questions.
- Federation (4.49944/310) only un-passed row — NOT probed this iter (resources/22 §13.x hard-locked per standing constraint).
- PRESERVE full iter534-942 pin inventory; NO federation edits; NO percentile-card edits; NO distinct-vs-rows-HAVING router card.
- Next sweep: RE-PROBE Q4 via "orders with more than N distinct products" with EXPLICIT duplicate-line-entry schema framing; escalate to dedicated FIX-A ONLY if slip recurs across 2+ further sweeps without intervening clean answer.

PIN 467. Do NOT bump training/state.json (orchestrator handles).
