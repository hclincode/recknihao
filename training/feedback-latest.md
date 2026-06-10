# iter945 Judge Feedback — RE-PROBE sweep (teacher ZERO edits)

**Phase**: extended | **Mode**: end-of-iteration (final-style) | **State**: passed=true preserved
**Overall**: **4.625 PASS** (per-Q 5.00 / 3.5 / 5.00 / 5.00 = 18.5 / 4; margin +1.125; OVERALL AVERAGE GOVERNS, no per-Q veto)
**Federation**: NOT PROBED (4.49944 / 310 row UNCHANGED)
**Dialect verified** against trino.io/docs/467 (connector/iceberg.html, functions/aggregate.html, functions/datetime.html, functions/window.html, language/types.html) + WebFetch 2026-06-10 — NOT against resources/; iter882 verify-BOTH-directions discipline.

---

## ★ ★ ★ Q1 RE-PROBE VERDICT = DISTINCT-vs-ROWS READING SLIP ONE-OFF / SLIP CLOSED ★ ★ ★

**iter944 Q4 distinct-vs-rows reading-comprehension slip DID NOT RECUR.** The iter944 Q4 defect was: user said "more than 5 DISTINCT items / different things", responder Approach-B used `HAVING COUNT(*) > 5` (counts rows, not distinct products) — the canonical lead given the "DISTINCT" cue should have been `HAVING COUNT(DISTINCT product_id) > 5`. iter945 Q1 explicitly re-probed with "more than 3 DIFFERENT products" + schema framing "same product can repeat across rows".

**Responder verdict**: LED with `HAVING COUNT(DISTINCT product_id) > 3` (CORRECT — de-dups same-product-multiple-rows per the schema cue). Explicitly explained the de-dup: same product repeated across rows still counts as 1 different product. This is the EXACT pinned `reference_trino_count_distinct_single_arg.md` idiom: "distinct/different things per group" → `COUNT(DISTINCT x) > N` (NOT `COUNT(*)`). HAVING + COUNT(DISTINCT col) > N valid 467 (aggregate.html `count(x)` with DISTINCT; HAVING after aggregation per select.html). Multiple COUNT(DISTINCT) in one SELECT is valid 467 (responder accurately noted this).

**Bonus accuracy**: The 2.3% standard error figure was attached to **`approx_distinct(product_id)`** — verified aggregate.html quote "This function should produce a standard error of 2.3%" appears in the **approx_distinct** block (HLL figure). UNLIKE iter943 Q2 where 2.3% was wrongly attached to approx_percentile, here it is on the CORRECT function. Pinned `reference_trino_approx_percentile_error.md` honored.

**Escalation-counter**: distinct-vs-rows-HAVING family SLIP CLOSED / ONE-OFF CONFIRMED. The standing decision (iter944 RE-PROBE-DON'T-CHURN, NO dedicated "distinct vs rows" router card) is VALIDATED. **NO FIX-A required**, NO new router card. Threshold for dedicated card remains at 2+ further recurrences without intervening clean answer.

Score Q1: Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

---

## ★ ★ ★ Q2 DIALECT VERDICT = PARTITIONED-BY-vs-WITH(partitioning) FOREIGN DDL SLIP CONFIRMED ★ ★ ★

The responder wrote: `PARTITIONED BY (day(occurred_at), bucket(region, 16))` as a partition-spec suggestion in the Q2 triage list.

**VERIFICATION (BOTH DIRECTIONS) against trino.io/docs/467/connector/iceberg.html, 2026-06-10:**
- Trino 467 Iceberg CREATE TABLE uses table-property `WITH (partitioning = ARRAY['transform(col)', ...])` syntax.
- Documented example verbatim: `CREATE TABLE example.testdb.customer_orders (...) WITH (partitioning = ARRAY['month(order_date)', 'bucket(account_number, 10)', 'country'])`.
- `PARTITIONED BY (...)` is Hive/Spark DDL — NOT valid Trino Iceberg CREATE TABLE syntax. A reader copying the responder's snippet into a Trino CREATE TABLE statement gets a **parse error**.

**SCOPE = RESPONDER DIALECT SLIP (foreign Hive/Spark DDL form imported into Trino)** — 1st-instance one-off (no prior iter has flagged this exact slip in recent history). Not a findable resource gap: resources teach the canonical `WITH (partitioning = ARRAY[...])` form (`r09` lakehouse DDL canonical, `r28` complex-SQL perf with dbt cards). The `bucket(region, 16)` transform itself is **correct column-first arg order** per pinned `reference_trino_bucket_arg_order.md` (Trino is bucket(col, N), Spark is bucket(N, col)) and verified against the docs example `bucket(account_number, 10)`.

**Scoped defect**: Acc -2.0 (parse error if copied — load-bearing DDL form is wrong, even though the partition concept and the bucket arg order are correct); Comp 4.0 (other triage items — EXPLAIN, bare-column predicate, ANALYZE — are sound); Clar 4.0 (clear staged checklist, easy to follow); Act 3.0 (DDL slip means engineer can't ship without fixing the wrapper).

Score Q2: Acc 3.0 / Comp 4.0 / Clar 4.0 / Act 3.0 = **3.5**.

**Conceptual partitioning advice + bucket arg-order are correct — the defect is the DDL wrapper only.** The rest of Q2 (EXPLAIN (TYPE DISTRIBUTED), bare-column predicate pushdown — `WHERE occurred_at >= current_date - INTERVAL '30' DAY` with no `date()`/`CAST()` wrapping, ANALYZE for stats, columnar + partition-pruning rationale, 400M rows not inherently slow framing, small-files fragmentation note) is sound and matches pinned `reference_trino_unwrap_temporal_predicates.md` + r07 partition-spec guidance.

---

## ★ Q3 5.00 — LAG + date_diff + AVG GROUP BY

`SELECT user_id, ROUND(AVG(gap_days), 2) FROM (SELECT user_id, date_diff('day', LAG(logged_in_at) OVER (PARTITION BY user_id ORDER BY logged_in_at), logged_in_at) AS gap_days FROM user_logins) WHERE gap_days IS NOT NULL GROUP BY user_id` — VERIFIED VALID 467:
- LAG(col) OVER (PARTITION BY x ORDER BY y) valid per window.html (default offset=1; first row returns NULL when no prior row).
- date_diff('day', LAG-prev, current) valid per datetime.html (date_diff(unit, x1, x2) → bigint, returns x2 - x1).
- LAG first-row → NULL ⇒ date_diff(NULL, …) → NULL ⇒ WHERE gap_days IS NOT NULL correctly excludes the first-login row per user.
- AVG ignores NULL natively (avg() does not include null values per aggregate.html); the WHERE filter is redundant-but-not-wrong.
- AVG GROUP BY user_id over subquery (window-fn wrapped in subquery because no QUALIFY in 467) — canonical pattern.

Score Q3: Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

---

## ★ Q4 5.00 — date_diff('day', expires_at, renewed_at) > 30 + no-ts-minus-ts pedagogy

`SELECT ... date_diff('day', expires_at, renewed_at) AS days_late FROM subscriptions WHERE date_diff('day', expires_at, renewed_at) > 30` — VERIFIED VALID 467:
- date_diff('day', earlier, later) → positive bigint per datetime.html (returns timestamp2 - timestamp1).
- **No timestamp-minus-timestamp operator in 467**: the responder's claim that `renewed_at - expires_at` is a parse error and `renewed_at - expires_at > INTERVAL '30' DAY` is also invalid is dialect-accurate. Trino exposes interval arithmetic on timestamps (TIMESTAMP + INTERVAL → TIMESTAMP) but does NOT expose TIMESTAMP - TIMESTAMP → INTERVAL. This is the Postgres-import trap the responder correctly headed off.
- INTERVAL '30' DAY DAY qualifier valid per `reference_trino_interval_qualifiers.md` (YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only).
- NULL semantics correct: date_diff(NULL, x) → NULL → NULL > 30 → UNKNOWN → filtered out in WHERE.
- Modulo variant date_diff('hour', expires_at, renewed_at) % 24 valid (% modulo operator valid 467).

Score Q4: Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

---

## SCOPE & TEACHER GUIDANCE

**Q1 RE-PROBE VERDICT**: distinct-vs-rows reading-comprehension slip ONE-OFF / SLIP CLOSED. iter944 Q4 defect did NOT recur. NO FIX-A needed. NO new "distinct vs rows in HAVING" router card. Escalation counter REMAINS at 2+ further recurrences without intervening clean answer.

**Q2 PARTITIONED-BY-vs-WITH(partitioning) VERDICT**: RESPONDER DIALECT SLIP (foreign Hive/Spark DDL form imported into Trino) — 1st-instance one-off. Bucket arg-order (column-first) is correct; conceptual partitioning advice is sound; only the DDL wrapper form is wrong. NOT a findable resource gap (resources teach `WITH (partitioning = ARRAY[...])` canonical at r09/r28). RE-PROBE-DON'T-CHURN discipline: do NOT add a dedicated "PARTITIONED BY is Hive/Spark not Trino" defang card on a 1st-instance — risks New-Card over-attracts-adjacent (Hive-vs-Iceberg DDL family + partition-transform neighbors) + defang-DO-NOT-WRITE backfire (literal-PARTITIONED-BY-text surface area in resources). Escalation threshold for dedicated FIX-A card: 2+ further recurrences without intervening clean answer.

**Q3 / Q4**: Clean textbook, NO defect.

**TEACHER ACTION = DEFAULT NO-OP, ZERO EDITS.** Re-probe Q2 next sweep via fresh "partition spec / CREATE TABLE for Iceberg" question — verify responder leads with `WITH (partitioning = ARRAY[...])` not `PARTITIONED BY`. Escalate to dedicated FIX-A router card ONLY if PARTITIONED-BY DDL slip recurs across 2+ further sweeps without intervening clean answer.

**PINS REINFORCED**:
- "distinct/different things per group" prompt cue → `HAVING COUNT(DISTINCT product_id) > N` idiom (NOT `COUNT(*)`); iter944→945 RE-PROBE closed the reading-comprehension slip.
- approx_distinct ~2.3% standard error (THIS is approx_distinct's HLL figure, correctly attached this iter); approx_percentile has NO published figure.
- **NEW emphasis (Q2 slip)**: Trino Iceberg CREATE TABLE partitioning uses `WITH (partitioning = ARRAY['transform(col)', ...])`, NOT `PARTITIONED BY (...)` (Hive/Spark form). Verified verbatim against trino.io/docs/467/connector/iceberg.html.
- Trino Iceberg bucket transform is COLUMN-FIRST `bucket(col, N)` (Spark is count-first `bucket(N, col)`).
- date_diff(unit, earlier, later) → bigint, day-aware, positive when later > earlier.
- NO timestamp-minus-timestamp operator in 467 (no `ts - ts`; no `ts - ts > INTERVAL`); interval arithmetic on timestamps exists (`ts + INTERVAL '30' DAY`) but ts-ts subtraction NOT exposed.
- INTERVAL qualifiers YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only (no QUARTER/WEEK; per `reference_trino_interval_qualifiers.md`).
- LAG(col) OVER (PARTITION BY x ORDER BY y): first-row → NULL; AVG ignores NULL natively.
- HAVING after aggregation; HAVING COUNT(DISTINCT x) > N valid; multiple COUNT(DISTINCT) in one SELECT valid; COUNT(DISTINCT x) single-arg.
- Window fn wrapped in subquery (no QUALIFY in 467); modulo % valid.

**Federation (4.49944 / 310)** only un-passed row — bulletproofed angles only. PRESERVE full iter534-944 pin inventory; NO federation edits, NO percentile-card edits, NO distinct-vs-rows-HAVING router card, NO PARTITIONED-BY defang card.

**State.json**: Orchestrator manages; do NOT bump here. Current state: iteration=945, passed=true preserved, overall 4.625 PASS holds.
