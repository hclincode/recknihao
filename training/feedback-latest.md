# Iter 544 Judge Feedback — 3.6563 PASS (THIN margin +0.1563)

## Overall

**OVERALL AVG = (4.6875 + 2.625 + 2.625 + 4.6875) / 4 = 14.625 / 4 = 3.6563 PASS** (margin +0.1563 above 3.5 floor — THIN; two sub-3.5 questions did NOT flip the iteration per the established overall-average protocol, iter530-543 precedent). 139th consecutive overall PASS in extended phase. Federation NOT probed — row stays 4.49944/310.

**HEADLINE WIN — Q1 ROWS-vs-RANGE arithmetic slip CLOSED on first re-probe.** iter543 Q4 had row3 RANGE=150 (wrong — that's the ROWS answer). iter544 teacher inserted a worked-numeric table at r07 L752-767 with row3 RANGE=**250** (rows 1+2+3 = 100+100+50). iter544 responder transcribed correctly: row1 ROWS=100/RANGE=200, row2 ROWS=200/RANGE=200, row3 ROWS=150/RANGE=250, row4 ROWS=120/RANGE=70. Slip is fixed.

**HEADLINE GAPS — two small function canonicals missing.** Q2 `map_concat` and Q3 `arbitrary()`/`any_value()` are both honest declines ("resources don't have this section") — no fabrication, no harm, but Completeness/Actionability tank. Both are real, well-documented Trino functions with high SaaS utility. Iter545 PRIMARY ACTION: add both canonicals.

---

## Per-question scores

### Q1 — ROWS vs RANGE running total with concrete numeric example (ties + gaps) → 4.6875 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Transcribed table matches r07 L756-761 exactly AND independently re-derived correct. row3 RANGE window = `[Jan-01, Jan-02]` (Jan-02 minus `INTERVAL '1' DAY` = Jan-01; CURRENT ROW includes peers per Trino docs); rows in window = row1+row2+row3 = 100+100+50 = **250** ✓. row4 RANGE window = `[Jan-03, Jan-04]`; rows in window = only row4 (Jan-03 absent; Jan-02 outside) = **70** ✓. ROWS column also correct (row3 ROWS=150 = row2+row3 physical-1-back; row4 ROWS=120 = row3+row4 physical-1-back). Quote-verified at [trino.io/blog/2021/03/10/introducing-new-window-features.html](https://trino.io/blog/2021/03/10/introducing-new-window-features.html): *"When using CURRENT ROW in a RANGE frame, it includes all rows where values of the sort key are the same as in the current row, which are called a peer group."* iter543 SLIP FIXED. |
| Completeness | 4.5 | Covered both axes (ROWS=physical-count vs RANGE=value-window-incl-peers), explicit tie effect (row3 RANGE pulls Jan-01 peers), explicit gap effect (row4 RANGE catches only row4 because Jan-03 is absent), Pattern1 (omit-frame default RANGE = deterministic on peers), Pattern2 (unique tiebreaker + explicit ROWS for per-row accumulation), non-deterministic-on-ties warning. Did NOT separately mention the bonus default-frame surprise (200,200,250,320 cumulative — present at r07 L767), but the directive only asked for ties + gaps which are both present. |
| Clarity | 4.5 | Transcribed table is readable; row3 callout ("ROWS=150 vs RANGE=250") makes the load-bearing contrast explicit; row4 callout ("[Jan-03, Jan-04] catches only row4") makes the gap-effect explicit. No jargon left unexplained. |
| Actionability | 4.75 | Engineer can copy the table verbatim, knows when to use Pattern1 (deterministic peer-group end) vs Pattern2 (unique tiebreaker + ROWS for per-row running total), knows the non-determinism trap. |

**WIN CHECK CONFIRMED.** The regenerative arithmetic slip from iter543 is gone. r07's new transcribable table at L752-767 anchors the answer; responder lifted it instead of regenerating.

---

### Q2 — map_concat in Trino — what is it, when does a SaaS product use it? → 2.625 PER-Q FAIL (honest content-gap decline)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.0 | Honest decline — no fabrication. Correctly notes resources cover MAP types and `MAP_AGG` but no `map_concat` section. Zero harm (Trino-dialect-accuracy memory: wrong dialect = parse error = FAIL; honest decline avoids that failure mode entirely). |
| Completeness | 1.5 | Did not deliver the answer. `map_concat` is a real, well-documented Trino function and the engineer's question is fully answerable from public docs. |
| Clarity | 3.5 | "I don't have enough information" framing is clear; explicit about what IS in resources (MAP type, MAP_AGG) so engineer can re-route the query. |
| Actionability | 1.5 | Engineer learns to ask elsewhere; no concrete next step inside this repo. |

**Verified correct answer** (for iter545 teacher canonical) — [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html):
- Signature: `map_concat(map1(K, V), map2(K, V), ..., mapN(K, V)) -> map(K, V)`
- Semantics: *"Returns the union of all the given maps. If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps."* — **rightmost map wins on key collision**.
- **SaaS use case** (canonical): merge a base/default settings map with a per-tenant override map — `map_concat(default_settings, tenant_settings)` so per-tenant keys override defaults. Other examples: merging feature-flag maps, merging request-context maps, combining default + per-row enrichment maps in a SELECT projection.
- Edge: behavior when same key appears with NULL value in the later map — the later NULL wins (not skipped). Worth a one-line callout.

---

### Q3 — arbitrary()/any_value() aggregate — what problem, practical example? → 2.625 PER-Q FAIL (honest content-gap decline)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.0 | Honest decline — no fabrication. Correctly identifies which aggregates ARE covered in resources (`try()`, `COUNT(DISTINCT)`, `approx_distinct`, `array_agg`) and which are NOT (`arbitrary`, `any_value`). |
| Completeness | 1.5 | Did not deliver the answer. Both functions are real and standard. |
| Clarity | 3.5 | Same shape as Q2 — clear about what's missing. |
| Actionability | 1.5 | No concrete next step inside this repo. |

**Verified correct answer** (for iter545 teacher canonical) — [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html):
- `arbitrary(x)` — returns an arbitrary non-null value of `x`, if one exists. `any_value(x)` is the SQL-standard alias (identical behavior).
- **Problem it solves**: When you `GROUP BY` a key and need a representative value from a column that is **functionally dependent** on the group key (e.g., `user_name` is constant per `user_id`), Trino still requires every non-aggregated SELECT column to be in the GROUP BY OR wrapped in an aggregate. Adding `user_name` to GROUP BY is semantically wrong (it inflates the apparent grouping intent) and writing `MIN(user_name)` / `MAX(user_name)` does pointless string work just to satisfy the SQL rule. `arbitrary(user_name)` / `any_value(user_name)` signals "I don't care which row's value, they're all the same" — cheaper than MIN/MAX (no comparison cost) and reads as documentation.
- **Canonical SaaS example**:
  ```sql
  -- Per user_id, count of orders + a representative name.
  SELECT
    user_id,
    any_value(user_name) AS user_name,    -- functionally dependent on user_id
    COUNT(*) AS order_count,
    SUM(amount) AS total_spend
  FROM orders
  GROUP BY user_id;
  ```
- Versus the alternatives: `MIN(user_name)` works but pays comparison cost; adding `user_name` to GROUP BY can subtly change the grouping if `user_name` ever drifts (e.g., a rename row).
- **Watch-out** to include in canonical: result is non-deterministic across runs (any non-null value is valid) — DO NOT use when caller needs a specific row's value.

---

### Q4 — dbt incremental + new source column → 4.6875 STRONG PASS

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | All four `on_schema_change` values correct and matched to canonical r13 L5446-5459. Default = `ignore` ✓ (verified [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models): "ignore (default)... If you add a column to your incremental model, and execute a dbt run, this column will not appear in your target table"). `append_new_columns` = ALTER ADD COLUMN then run ✓. `sync_all_columns` = adds + drops (destructive) ✓. `fail` = errors out on schema mismatch ✓. First-run-ignores-it behavior correct (r13 L5393: "On the first run, `is_incremental()` returns `false` and dbt runs the full SELECT to build the target table from scratch" — table is built fresh from the current SELECT shape, no schema-change logic runs because there's no prior schema to compare to). |
| Completeness | 4.5 | Covered all four values + default + first-run behavior + recommendation (`append_new_columns` for SaaS pipelines because auto-propagates + never drops). Could marginally mention the `--full-refresh` escape hatch as the safety net when in doubt, but not required for the question. |
| Clarity | 4.5 | "Silently drops" framing for the `ignore` default makes the silent-data-loss risk vivid. Engineer understands why `append_new_columns` is the recommended default. |
| Actionability | 4.75 | Engineer knows exactly what to add to their config block: `on_schema_change='append_new_columns'`. Knows it issues `ALTER TABLE ... ADD COLUMN` automatically, knows `sync_all_columns` is destructive. |

No slip. Solid.

---

## Iter545 PRIMARY teacher actions

Two small function canonicals — consider doing them as a PAIR in a single iter545 edit (one map-function addition + one aggregate-function addition; both are small, both came up in the same iteration, both belong adjacent to existing canonicals).

### FIX A (PRIMARY — Q2 `map_concat` canonical)

**Target location**: r07 §map family (if it exists), OR r09 element_at / map-HOF section, OR a fresh `### map_concat` subsection inside whichever resource already documents MAP types and MAP_AGG. Reconcile-don't-append: cross-link from the MAP_AGG section so route by keyword (`merge maps`, `map override`, `combine maps`, `map union`, `tenant settings override`, `default + override map`, `map_concat`) reaches it.

**Body** (minimum):
- Signature line, doc-verbatim quote:
  > *"Returns the union of all the given maps. If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps."* — [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html)
- Signature: `map_concat(map1(K, V), map2(K, V), ..., mapN(K, V)) -> map(K, V)`
- **SaaS canonical use** (the load-bearing example):
  ```sql
  -- Merge default settings with per-tenant overrides; tenant wins on key collision.
  SELECT
    tenant_id,
    map_concat(default_settings, tenant_settings) AS effective_settings
  FROM tenants
  JOIN settings_defaults ON TRUE;
  ```
- One-line rightmost-wins callout (load-bearing for the engineer who doesn't read the quote).
- NULL-value edge: if the rightmost map has the key with NULL, the result has NULL for that key (not the leftmost's non-null) — call this out because it surprises engineers who assume NULL is "absent".
- Keyword anchors: `merge maps Trino`, `map override`, `map union`, `combine maps`, `tenant override default settings`, `feature flag maps merge`, `map_concat`.

### FIX B (PRIMARY — Q3 `arbitrary()` / `any_value()` canonical)

**Target location**: the aggregate-functions section that already documents `array_agg` / `approx_distinct` — add adjacent canonical so keyword-routing (`representative value`, `functional dependency GROUP BY`, `MIN to satisfy GROUP BY`, `any non-null value aggregate`, `arbitrary`, `any_value`) reaches it.

**Body** (minimum):
- Signature: `arbitrary(x)` returns an arbitrary non-null value of `x`, if any. `any_value(x)` is the SQL-standard alias (identical behavior — recommend `any_value` for readability/portability).
- **The problem it solves**: SQL requires every non-aggregated SELECT column be in GROUP BY or wrapped in an aggregate. When the column is **functionally dependent** on the GROUP BY key (per-key constant), engineers reach for `MIN(col)` / `MAX(col)` which pays comparison cost for no semantic gain. `any_value(col)` says "any one is fine, they're all equal" — cheaper and self-documenting.
- **SaaS canonical use** (load-bearing example):
  ```sql
  -- Per user_id, total spend + a representative user_name (constant per user_id).
  SELECT
    user_id,
    any_value(user_name) AS user_name,
    COUNT(*)             AS order_count,
    SUM(amount)          AS total_spend
  FROM orders
  GROUP BY user_id;
  ```
- One-line warning: non-deterministic — any non-null value is valid; DO NOT use when caller needs a specific row's value (e.g., latest-by-timestamp — use `MAX_BY(col, ts)` instead). Cross-link to a `MAX_BY` / `MIN_BY` mention if one exists.
- Keyword anchors: `representative value GROUP BY`, `functional dependency aggregate`, `any value Trino`, `arbitrary Trino aggregate`, `MIN to satisfy GROUP BY alternative`, `non-aggregated column SELECT GROUP BY`, `any_value`, `arbitrary`.

### NO Q1 or Q4 fixes needed

Q1 PRIMARY WIN — hold the line on r07 L752-767 (new worked-numeric table); RECONCILE-DON'T-APPEND only if a future failure surfaces.
Q4 STRONG PASS — hold the line on r13 L5446-5459 (`on_schema_change` canonical); already covers all four values, default, first-run, recommendation.

---

## Iter545 probe targets

| Priority | Question shape | Verifies |
|---|---|---|
| HIGH | `map_concat` 2nd angle (verifies FIX A landing) — "in Trino, how do I merge two MAP columns where the second one's values should win on collision?" OR "is there a function to combine multiple MAP values into one?" | Must answer `map_concat(map1, map2, ...)` + rightmost-wins; must NOT decline. |
| HIGH | `any_value` / `arbitrary` 2nd angle (verifies FIX B landing) — "I have GROUP BY user_id but I need to also show user_name (constant per user_id) — what's the cleanest way in Trino?" OR "is there an aggregate that just returns any row's value?" | Must answer `any_value(user_name)` or `arbitrary(user_name)`; must NOT decline. |
| MEDIUM | ROWS-vs-RANGE 3rd angle (durability on iter544 win) — "If I add a UNIQUE tiebreaker to my ORDER BY, do I still need to think about ROWS vs RANGE?" | Must answer no peer-group ambiguity once ORDER BY is unique; both Pattern1 and Pattern2 then converge for per-row running total. |
| MEDIUM | `on_schema_change` 2nd angle (durability check on Q4 PASS) — "What happens to my downstream model if the upstream incremental table gains a column?" OR "if I set on_schema_change='sync_all_columns' and someone removes a column from the model, what happens to the data?" | Must answer destructive DROP COLUMN on sync_all_columns; must answer downstream sees the new column once upstream propagates (with append_new_columns). |
| LOW | Federation stays UNPROBED — row stays 4.49944/310 per directive. | — |

---

## Meta-rule observation

Directive's "verify YOUR OWN corrections before asserting" was DECISIVE again — independently re-derived row3 RANGE arithmetic (window `[Jan-01, Jan-02]` + CURRENT ROW pulls Jan-01 peers = 100+100+50 = 250 ✓) and row4 RANGE arithmetic (window `[Jan-03, Jan-04]`; only row4 in window because Jan-03 is absent and Jan-02 is outside = 70 ✓) BEFORE confirming the WIN. Also WebSearch-verified `map_concat` signature + rightmost-wins quote and `arbitrary`/`any_value` alias-identity at official trino.io docs BEFORE writing the canonical-fix instructions for the teacher. 8th consecutive iter where the meta-rule prevented false-positive correction in either direction.

## Topic average updates

- **Analytical query patterns on Iceberg+Trino (Q1 ROWS-vs-RANGE 2nd angle, r07 hosts canonical)**: 4.3723/20 → (4.3723·20 + 4.6875)/21 = 92.1335/21 = **4.3873/21** (+0.0150 — Q1 above topic avg lifts slightly; arithmetic-slip closure stabilizes).
- **SQL query best practices for OLAP (Q2 map_concat — function-family question; routes to SQL best practices because no dedicated "Trino built-in functions catalog" row exists)**: 4.5362/109 → (4.5362·109 + 2.625)/110 = 496.8708/110 = **4.5170/110** (-0.0192 — Q2 well-below topic avg drags; honest-decline penalty applies).
- **SQL query best practices for OLAP (Q3 arbitrary/any_value — also aggregate-family, same row)**: 4.5170/110 → (4.5170·110 + 2.625)/111 = 499.495/111 = **4.4999/111** (-0.0171 — Q3 same drag profile).
- **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling (Q4 on_schema_change — r13 hosts canonical)**: 4.4968/170 → (4.4968·170 + 4.6875)/171 = 769.1435/171 = **4.4979/171** (+0.0011 — Q4 marginally above topic avg).

Federation 4.49944/310 row UNCHANGED per directive.

## Sources

- [Trino window functions blog (peer group quote)](https://trino.io/blog/2021/03/10/introducing-new-window-features.html)
- [Trino SELECT docs (default RANGE frame)](https://trino.io/docs/current/sql/select.html)
- [Trino map functions docs (map_concat signature + rightmost-wins quote)](https://trino.io/docs/current/functions/map.html)
- [Trino aggregate functions docs (arbitrary / any_value)](https://trino.io/docs/current/functions/aggregate.html)
- [dbt incremental models docs (on_schema_change default = ignore)](https://docs.getdbt.com/docs/build/incremental-models)
