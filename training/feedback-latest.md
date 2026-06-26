# Iter 1126 — Judge Feedback

**Iter average: 4.5000 PASS (margin +1.0000).** Q1/Q3/Q4 clean; **Q2 (3.125) is a real correctness defect — `GROUP BY customer_id` on a population-wide percentile question gives degenerate per-customer percentiles, defeating the "ACROSS ALL customers" intent.** Defect classification: **responder one-off, NOT resource-sourced** (r23 §247-§262 has the correct bare-population canonical AND the per-group variant clearly distinguished). **RECOMMENDATION = NO-OP + WATCH STREAM** (re-probe within 2-3 iters with sharper "one set of three numbers, the population-wide thresholds" framing; if RECURS, LIGHT FIX-A in r23 §253 area with explicit "POPULATION vs PER-GROUP percentile" disambiguator above the per-store example).

---

## Per-question scoring

### Q1 — Oracle `TO_CHAR(revenue, 'FM999,990.00')` → Trino comma+2dp; SQL vs app-layer — **4.875**

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | `format('%,.2f', revenue)` is the canonical Trino 467 form for comma-thousands + 2dp. Verified against trino.io/docs/current/functions/conversion.html — official doc example reads `SELECT format('%,.2f', 1234567.89); -- '1,234,567.89'` essentially verbatim. Java-Formatter semantics correctly recalled: `%,` = locale grouping separator, `.2f` = 2 decimals, `%%` = literal percent sign. Companion patterns (`%d`, `%05d`, `%.1f%%`) all correct. "TO_CHAR for numbers does NOT exist in Trino" correct — Trino's `to_char` is timestamp-formatting only per the iter954 pin `reference_trino_to_char_exists`. |
| Beginner clarity | 5.0 | Three-tier explanation: pattern → meaning → companion forms. The `%%` escape note is a real footgun preempted. The Oracle `FM` flag (suppress leading zero / blank) correctly understood to be already covered by `%,.2f` (no leading-zero padding by default). |
| Practical applicability | 5.0 | Engineer can copy `format('%,.2f', revenue)` directly into a Trino query OR push to the app layer per the displayed/SQL guidance. Both correct framings offered. |
| Completeness | 4.5 | Minor shave: does NOT explicitly note that for `DECIMAL` revenue columns the format `%f` specifier typically works via Trino's auto-coercion to double, but a strict-typing concern *could* require `CAST(revenue AS double)` if Trino fails to coerce. The official doc example uses a double literal `1234567.89` — the question's "revenue" column type (decimal vs double vs bigint) is unspecified. A one-line "for a `DECIMAL` revenue column, `format('%,.2f', CAST(revenue AS double))` is the safe form" would have closed this completeness gap. Per-instance, NOT a resource gap. |

### Q2 — population p25/p50/p75 of revenue ACROSS ALL customers for a given month — **3.125** ⚠ REAL DEFECT

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 2.5 | **Right function (`approx_percentile`), right multi-percentile array form (`ARRAY[0.25, 0.5, 0.75]`), right "no PERCENTILE_CONT / no MEDIAN in Trino 467" inoculation — BUT `GROUP BY customer_id` on BOTH variants is WRONG for the question's intent.** The question explicitly asks for THE THRESHOLD VALUES of revenue across the customer population for the month (one set of three numbers describing the customer-distribution-wide cutoffs). With `GROUP BY customer_id`, Trino computes the percentile PER customer; if `monthly_revenue` has one row per customer per month (the natural shape for that table name), each group has a SINGLE value, so `approx_percentile` returns that customer's own revenue three times — degenerate and meaningless. Even on a many-row-per-customer-per-month table, the result is each customer's PRIVATE p25/p50/p75 of their own purchase distribution, not the population cutoffs across the customer base. The CORRECT query is **no GROUP BY** (or `GROUP BY month` only when scanning multiple months): `SELECT approx_percentile(revenue, ARRAY[0.25, 0.5, 0.75]) FROM monthly_revenue WHERE month='2026-06';` — returns one array of three numbers, the population thresholds. |
| Beginner clarity | 4.5 | The mechanism explanation (multi-percentile array form, T-Digest sketch, no PERCENTILE_CONT trap) is clear. The "across all customers" misframing reduces clarity for the actual question asked — an engineer would copy the query and get the wrong shape of output. |
| Practical applicability | 2.5 | An engineer copying either variant gets meaningless output for the stated question — single percentiles of single-row groups (single-row repeat) or per-customer distributions (not the population cutoffs). Both miss the "THRESHOLD VALUES, not bucket numbers" intent. |
| Completeness | 3.0 | Function family identified, array form identified, PERCENTILE_CONT/MEDIAN absence noted — but the actual population-wide query the question asks for is NEVER produced. Missing the core deliverable. |

**Defect classification: RESPONDER ONE-OFF, NOT resource-sourced.** Verify-first against r23 §247-§262 (`approx_percentile` canonical section):
- §249-§251 has the correct **bare population form**: `SELECT approx_percentile(latency_ms, 0.99) AS p99 FROM api_logs;` and `SELECT approx_percentile(latency_ms, ARRAY[0.5, 0.95, 0.99]) AS percentiles FROM api_logs;` — NO GROUP BY.
- §253-§256 has the explicitly labeled **PER GROUP** form: `SELECT store_id, approx_percentile(order_amount, 0.90) AS p90_order_amount FROM orders GROUP BY store_id;` with the heading "Percentile PER GROUP (e.g. p90 order amount per store) — just add GROUP BY".
- §258-§262 has the **ARRAY form per group**: `SELECT store_id, approx_percentile(order_amount, ARRAY[0.5, 0.9, 0.99]) AS p50_p90_p99 FROM orders GROUP BY store_id;`.

The resource correctly distinguishes population-wide vs per-group; both canonical forms are present and labeled. The responder pulled the per-group shape (with the entity-keyword "customer" mapping to the example's "store") onto a population question. **Likely root cause = `feedback_new_card_over_attracts_adjacent` adjacency-attraction**: the §253-§262 "per store" example has high keyword affinity with the question's "per customer" framing (entity-keyword similarity), pulling GROUP BY into the answer even though the question literally says "ACROSS ALL customers". This is a findability/disambiguation slip, not a missing canonical.

Additional contrasting reference: r07 §3911-§3914 explicitly addresses "PERCENT_RANK over computing percentiles directly" and frames percentiles for the whole table vs per-row — but does NOT have an inline disambiguator for the population-vs-per-group GROUP BY decision. The §247-§262 dual examples in r23 are the load-bearing disambiguator, and they ARE correctly labeled, so the responder slip is a synthesis/keyword-match miss not a content gap.

**Recommendation on this defect: NO-OP + WATCH STREAM** (first-instance discipline matching iter1116 ts-minus-ts / iter1120 ADD-COLUMN / iter1123 partition-column-COUNT handling). Re-probe in next 2-3 iters with explicit population-framing variants:
- "What are the p25/p50/p75 of `total_purchases` across ALL users in 2026-06 (one set of three numbers)?" (force "ALL users" + "one set of three numbers")
- "Give me the median + IQR of order_amount across the whole orders table for last month" (force "across the whole table")
- "What revenue dollar values mark the top-quartile cutoff across my customer base?" (force "customer BASE" not "per customer")

If RECURS → **LIGHT FIX-A** at r23 §247-§253 boundary: insert a one-paragraph disambiguator above the "PER GROUP" example with INLINE-WRONG defang per `feedback_defang_donotwrite_snippets`:

> **POPULATION-wide vs PER-GROUP percentile — pick the right shape.** When the question asks for THE p25/p50/p75 values across an entire population (e.g. "across all customers", "across the customer base", "the threshold values for the month"), the answer is the BARE form with **NO GROUP BY on the entity**: `SELECT approx_percentile(revenue, ARRAY[0.25, 0.5, 0.75]) FROM monthly_revenue WHERE month='2026-06';` — returns one row, one array of three numbers, the population cutoffs. **DO NOT** `GROUP BY customer_id` here — that would compute each customer's PRIVATE p25/p50/p75 (single-value-repeat if one row per customer per month), defeating the across-population intent. Add `GROUP BY <entity>` ONLY when the question explicitly asks for a percentile PER entity (e.g. "p90 order amount per store").
>
> ```sql
> -- ❌ DO NOT WRITE — population threshold question, do NOT add GROUP BY on the entity
> SELECT approx_percentile(revenue, ARRAY[0.25, 0.5, 0.75])
> FROM monthly_revenue WHERE month='2026-06'
> GROUP BY customer_id;   -- WRONG: returns per-customer triples, not population thresholds
> ```

Do NOT preemptively edit on first-instance per the established NO-OP-then-re-probe playbook.

### Q3 — `array(double)` of response times in ms → divide every element by 1000 to seconds, same shape, no `unnest` — **5.0**

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | `transform(response_times, ms -> ms / 1000.0)` is exactly correct Trino 467. Verified against trino.io/docs/current/functions/array.html: `transform(array(T), function(T, U)) → array(U)` applies the lambda element-wise. Lambda syntax `ms -> ms / 1000.0` correct (`->` lambda operator). Division by `1000.0` (double literal) ensures `double / double → double` so the result type is `array(double)`, preserving the input shape exactly. No NULL-shape concerns (transform preserves NULL elements as NULL in the output). |
| Beginner clarity | 5.0 | Clean signature explanation; the `1000.0` (vs `1000`) note implicit but the type-preservation works either way for a `double` input. |
| Practical applicability | 5.0 | Direct copyable single-expression solution. |
| Completeness | 5.0 | Defanged the `UNNEST + array_agg` round-trip anti-pattern (which would multiply rows, then re-aggregate — wrong tool, expensive). The "no unnest" framing in the question is directly addressed. |

### Q4 — `CROSS JOIN UNNEST(tags) AS t(tag)` drops accounts with empty/NULL tags; want them with NULL tag — **5.0**

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | `LEFT JOIN UNNEST(tags) AS t(tag) ON TRUE` is the correct Trino 467 form to preserve parent rows when the array is empty or NULL. Verified against trino.io/docs/current/sql/select.html (UNNEST clause semantics) and community guides: `CROSS JOIN UNNEST` is inner-join semantics — zero array elements → zero rows for that parent → parent dropped. `LEFT JOIN UNNEST(...) ON TRUE` keeps every parent and pads the unnested column with NULL when the array yields no elements. Both NULL-array and empty-array cases are handled identically by LEFT JOIN UNNEST ON TRUE. |
| Beginner clarity | 5.0 | The "CROSS JOIN UNNEST is semantically INNER" insight is the precise mental model that explains the surprise. |
| Practical applicability | 5.0 | One-line drop-in replacement (swap `CROSS JOIN` for `LEFT JOIN ... ON TRUE`) — the engineer knows exactly what to change. |
| Completeness | 5.0 | Both the empty-array and NULL-array cases addressed; the `ON TRUE` clause (required since LEFT JOIN syntax requires a join condition) explicitly called out. |

---

## Score table

| Q | Topic touched | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 | Oracle PL/SQL → dbt+Trino migration (TO_CHAR numeric formatting) | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |
| Q2 | Analytical query patterns on Iceberg+Trino (population vs per-group percentile) | 2.5 | 4.5 | 2.5 | 3.0 | **3.125** ⚠ |
| Q3 | SQL best practices for OLAP (array `transform` higher-order function) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q4 | SQL best practices for OLAP (UNNEST inner vs LEFT semantics) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |

**Iter average = (4.875 + 3.125 + 5.0 + 5.0) / 4 = 4.5000 PASS** (margin to 3.5 = **+1.0000**).

---

## Source-verified defects

| Defect | Source | Verification | Classification | Action |
|---|---|---|---|---|
| Q2 `GROUP BY customer_id` on population p25/p50/p75 across customers — gives degenerate per-customer percentiles | trino.io/docs/current/functions/aggregate.html — `approx_percentile(x, percentages) → array<[same as x]>` "for all input values of x" with no GROUP BY = bare-population semantics; r23 §249-§251 has CORRECT bare-population canonical + §253-§262 has explicitly-labeled per-group variant | RESPONDER ONE-OFF — resource is correct (both shapes labeled); responder pulled the per-store-shape per-entity pattern onto a question whose "ACROSS ALL customers" wording requires the bare form. Likely entity-keyword adjacency attraction per `feedback_new_card_over_attracts_adjacent` | **NO-OP + WATCH STREAM**; re-probe in 2-3 iters with explicit "one set of 3 numbers across ALL users" framing; if RECURS → LIGHT FIX-A r23 §247-§253 with population-vs-per-group inline disambiguator + INLINE-WRONG defang per `feedback_defang_donotwrite_snippets` |

---

## Recurring-defect surface check

No recurrence of: `::` cast / `QUALIFY` / false-semi-join / fabricated function / regex backslash / `INTERVAL` quarter-week / `OFFSET` before `LIMIT` / `CAST(... AS integer)` truncate folklore / `ALTER TABLE EXECUTE rollback_to_snapshot` on 467 / Spark-Oracle dialect spillover / imported-prior single-arg `COUNT(DISTINCT)` / `GREATEST/LEAST` Postgres-NULL / `array_sum` / `->`/`->>` JSON / `DATEDIFF` dialect import / multi-arg `COUNT(DISTINCT)` / `ts - ts` subtraction / over-warning folklore / multi-clause `ADD COLUMN` / `contains_sequence` `array_position` arithmetic / partition-column-COUNT data-file folklore (iter1124 FIX-A REACHED iter1125, REMAINS CLOSED).

**NEW WATCH STREAM (Q2):** Population-wide percentile question + entity GROUP BY adjacency-attraction. First instance, re-probe 2-3 iters from sharper "ACROSS ALL X" framings.

---

## Topic updates (PASS → updated values)

| Topic | Before | Q | Q score | Updated | Δ | Status |
|---|---|---|---|---|---|---|
| Oracle PL/SQL → dbt+Trino migration | 4.4724/108 | Q1 | 4.875 | (483.0192 + 4.875)/109 = **4.4761/109** | +0.0037 | PASSED |
| Analytical query patterns on Iceberg+Trino | 4.4879/80 | Q2 | 3.125 | (359.032 + 3.125)/81 = **4.4711/81** | −0.0168 | PASSED (margin +0.9711 preserved) |
| SQL best practices for OLAP | 4.5304/182 | Q3+Q4 | 5.0 + 5.0 | (824.5328 + 10.0)/184 = **4.5355/184** | +0.0051 | PASSED |

ALL required topics REMAIN PASSED. Q2's 3.125 drags the analytical-query-patterns row by −0.0168 but the row's margin to 3.5 (+0.9711) is comfortable; no PASS status change risk.

---

## Thinnest-margin order after iter1126 (unchanged ordering)

1. storage-tiering 3.9219/8 (+0.4219, thinnest required-topic)
2. dbt-snapshots SCD2 4.1526/16 (+0.6526)
3. query-perf-basics 4.1771/23 (+0.6771)
4. cost-considerations 4.2504/21 (+0.7504)
5. query-perf-regression-diagnosis 4.3108/20 (+0.8108)

Federation 4.5024/312 untouched (fragile-PASS preserved). CBO/ANALYZE 4.5920/21 untouched.

---

## Teacher guidance

**RECOMMENDATION = NO-OP + WATCH STREAM** (commit rubric+feedback only; do not edit resources/ this iter).

**Why NO-OP on first instance:** Q2 wrong claim is NOT in resources — r23 §247-§262 has the correct dual canonical (bare population + per-group, both labeled). The slip is responder-side disambiguation, not resource-side absence. Matches iter1116/iter1120/iter1123 first-instance handling discipline.

**WATCH STREAM probe queue:**
1. Population-percentile re-probe (PRIORITY 1, NEW): explicit "one set of three numbers across ALL users" framing — e.g. "Give me the p25/p50/p75 of total_purchases for last month, ONE row with three numbers, the population thresholds across all users." If responder still adds GROUP BY on the entity, RECURRENCE confirmed → LIGHT FIX-A.
2. storage-tiering 9th angle (still thinnest required-topic row at +0.4219).
3. dbt-snapshots-SCD2 17th angle.
4. cost-considerations 22nd angle.

**If Q2 RECURS in next 2-3 iters → LIGHT FIX-A in r23 §247-§253:** insert one paragraph + INLINE-WRONG defang above the "PER GROUP" example (see Q2 section above for the exact paragraph + DO-NOT-WRITE block). Reconcile-in-place per `feedback_reconcile_dont_append`; keep the existing per-group example, just front it with the disambiguator.

**Do NOT preemptively edit.** The corpus already has the correct content; one-instance slip on adjacent-keyword attraction is not enough signal to justify a defang — re-probe first.

---

## Pattern observation

10-iter sustainment band shape continues: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125 with LIGHT FIX-A iters 1091/1116/1124 reaching cleanly between; iter1126 4.5000 PASS is the lowest of the recent band, driven entirely by a single Q2 wrong-shape synthesis miss on a population-vs-per-group disambiguation. No content-lineage erosion; no recurring defect class; one new watch stream opened. Continue verify-first against trino.io 467 RAW source + grep resources/ before classifying any slip as resource-sourced.

Q1's correct `format('%,.2f')` shape demonstrates the iter954 `reference_trino_to_char_exists` pin (numeric `to_char` does not exist; numeric formatting goes through `format()`) reaching cleanly. Q3's `transform` + lambda shape demonstrates higher-order array function discipline durable. Q4's CROSS JOIN UNNEST inner-vs-LEFT semantic correctly inoculated.

Q2's adjacency-attraction signature: the resource has the right answer in the right section, but the per-group example's "store_id" entity keyword has pulled the per-entity GROUP BY shape onto a population question whose entity is "customer" (high keyword affinity, lexically similar role). This is the EXACT mechanism `feedback_new_card_over_attracts_adjacent` describes — a magnetic adjacent canonical capturing an entity-keyword-similar but semantically-different question. The defang (if needed after re-probe) belongs at the boundary between the two canonicals, not inside either one.
