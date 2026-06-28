# Iteration 1239 — Judge Feedback

## Verdict

**Overall: 4.73 — STRONG PASS, NO FIX-A.** The thin-topic probe (Q1 dynamic filtering) lands correctly on the most load-bearing actionable claim — the `dynamicFilterSplitsProcessed` runtime check metric is REAL, verified verbatim against [trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html) ("records the number of splits processed after a dynamic filter is pushed down"). Engineer arrives at the right grep target. Q2 NTILE quartile pattern is canonical-perfect. Q3 dbt persist_docs answer correctly identifies that dbt-trino DOES support it (the official dbt docs page lists Postgres/Redshift/Snowflake/BigQuery/Databricks/Spark and does NOT mention Trino, but the dbt-trino adapter implements `trino__alter_relation_comment` + `trino__alter_column_comment` macros, verified at [github.com/starburstdata/dbt-trino dbt/include/trino/macros/adapters.sql](https://github.com/starburstdata/dbt-trino/blob/master/dbt/include/trino/macros/adapters.sql)). Q4 MONTHS_BETWEEN → date_diff('month') is dialect-pin-perfect (day-aware/complete-units, matches `reference_trino_datediff_dayaware.md`).

| Q | Score | Topic | Notes |
|---|---|---|---|
| Q1 | 4.25 | Query performance basics (dynamic filtering) | CHECK metric `dynamicFilterSplitsProcessed` VERIFIED REAL; mechanics correct; minor imprecision on "partitioned join loses DF advantage" (DF works on PARTITIONED joins per resources/28 §1475, just less dramatic); biggest miss = `dynamic-filtering.wait-timeout` not surfaced (the textbook real-world DF-zero failure mode in resources/22 §5.4) |
| Q2 | 5.0 | Analytical query patterns on Iceberg+Trino | Pin-perfect: NTILE(n) "bucket values will differ by at most 1" + "remainder values are distributed one per bucket, starting with the first bucket" + "the window frame must not be specified" all match trino.io/docs/467/functions/window.html verbatim; 1001-user worked example (251/250/250/250) correct |
| Q3 | 4.875 | Improving complex SQL performance on Trino with dbt (persist_docs) | persist_docs works on dbt-trino + Iceberg; per-model `config(persist_docs={"relation": true, "columns": true})` + global `dbt_project.yml +persist_docs:` shapes correct; verification via `SHOW COLUMNS` and `information_schema.columns.comment` correct; distinct-from-`dbt docs generate` disambiguation good |
| Q4 | 4.8125 | Oracle PL/SQL → dbt+Trino migration | Day-aware/complete-units semantics correct (matches `reference_trino_datediff_dayaware.md` pin); Jan-31→Feb-14=0 worked example correct; ">=N complete months" replacement pattern correct; small Compl shave on the `/31.0` fractional-approximation hack (Oracle MONTHS_BETWEEN uses a more nuanced rule for whole vs partial months) |

---

## Per-question detail

### Q1 — Dynamic filtering for star join: is it real, how to CHECK, what STOPS it → 4.25 (Query performance basics — THIN-MARGIN TOPIC)

**THE LOAD-BEARING ACTIONABLE CLAIM IS CORRECT.** Responder said: run `EXPLAIN ANALYZE` and search for `dynamicFilterSplitsProcessed` on the `fct_events` TableScan — if > 0, DF fired.

**Verification**: [trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html) (WebFetch this iter) verbatim: `"dynamicFilterSplitsProcessed" records the number of splits processed after a dynamic filter is pushed down to the table scan.` Metric name VERIFIED REAL — NOT a fabrication. Engineer can grep this exact string in EXPLAIN ANALYZE (typically with VERBOSE) output and read DF firing status. Resources are CONSISTENT on this — resources/28 §18 + §750 + §1194 + §1475 + resources/03 §483 + resources/22 §3214/§3282/§4438+ all teach `dynamicFilterSplitsProcessed` as THE runtime DF-fired check metric, cross-referenced to the same official docs URL.

**Additional plan-time check correctly named**: responder mentions `dynamicFilters` annotation on the TableScan — matches docs' "EXPLAIN plans show `dynamicFilterAssignments` in join nodes and `dynamicFilters` predicates in `ScanFilterProject` operators" verbatim. `physicalInputDataSize` callout also correct (the bytes-actually-read sanity-check).

**What STOPS it — three claims, scored individually:**

1. **Missing stats → run ANALYZE (bare, no TABLE keyword)** — INDIRECTLY correct. ANALYZE doesn't directly disable DF, but it feeds the CBO so AUTOMATIC join distribution picks BROADCAST when accurate (which is when DF works best). The bare-ANALYZE-no-TABLE-keyword form matches the pinned ANALYZE syntax. Acceptable framing.

2. **Dim > ~100MB → join becomes partitioned → DF loses advantage** — PARTIALLY CORRECT, mild imprecision. The 100MB `join_max_broadcast_table_size` default IS real (verified via WebSearch — [trinodb/trino#2527](https://github.com/trinodb/trino/pull/2527) introduced the 100MB default in Trino 0.213; also documented in resources/24 §61 + resources/22 §4896). **BUT** the claim "if dim huge the join becomes partitioned and dynamic filtering loses advantage" is mildly outdated — DF DOES fire on PARTITIONED joins in modern Trino (resources/28 §1475 verbatim: *"For each PARTITIONED join, is dynamic filtering firing? `EXPLAIN ANALYZE VERBOSE` and look for `dynamicFilterSplitsProcessed` on the probe-side `TableScan`"*), it just produces smaller pruning effect. Not a critical wrong-direction error; the practical advice (broadcast preferred for small dims) is right.

3. **Partition-column mismatch (fct partitioned by event_date, filter on account_id)** — CORRECT, with the right nuance ("dynamic filtering still works at file level via Parquet min/max stats, less aggressive"). This is the right mental model: partition-pruning at the directory level is separate from DF-driven file-level pruning via min/max + DF IN-list.

**THE BIGGEST MISS: `dynamic-filtering.wait-timeout` not mentioned.** Resources/22 §5.4 + §4438 (the "EXPLAIN shows `dynamicFilters={...}` but EXPLAIN ANALYZE shows `dynamicFilterSplitsProcessed=0`" diagnostic card) cover the most common real-world DF-zero failure: the probe-side scan starts before the build side completes, so it scans without the DF. Default timeouts (1s Iceberg, 20s JDBC) often fire under load and silently degrade DF. The responder's three-cause taxonomy misses this. Minor Completeness ding (–1.0 Compl), not Accuracy.

**Other smaller misses**: doesn't mention JOIN type limitations (DF only fires for inner/right with `=`, `<`, `<=`, `>`, `>=`, `IS NOT DISTINCT FROM` plus semi-IN per [dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html)), unorderable type limitations, doesn't mention the `"Dynamic filters:"` subsection in EXPLAIN ANALYZE plan stats. Recall ceiling.

**FIX-A decision: NO FIX-A.** The CHECK metric is correct and resource-consistent, and the responder's three "what stops it" claims are all defensible. The wait-timeout omission is a recall ceiling on a peripheral lever — resources/22 §5.4 already covers it canonically, the responder just didn't surface it under the "star join scans huge chunk" framing. Per `feedback_new_card_over_attracts_adjacent.md`, adding another DF-stop-conditions card risks over-attracting adjacent partition-pruning questions. WATCH only.

- Scores: Acc 4.5 / Clar 4.5 / Prac 4.5 / Compl 3.5 → **4.25**
- Topic: Query performance basics (THIN-MARGIN, currently 4.2026/32)

### Q2 — NTILE quartile per month → 5.0 (Analytical query patterns)

Pin-perfect against [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) (WebFetch this iter):
- "Bucket values will differ by at most 1" ✓ (responder: "each bucket floor(N/4) or ceil(N/4), differ by ≤1")
- "remainder values are distributed one per bucket, starting with the first bucket" ✓ (responder: "remainder rows go to EARLIEST buckets")
- "For the `ntile()` function, the window frame must not be specified" ✓ (responder: "DO NOT add a frame clause (ROWS BETWEEN...) — Trino errors with NTILE")

Worked example 1001 users → 251/250/250/250 correct (1001/4 = 250 r1; first bucket gets the +1). PARTITION BY month pattern correct. ASC sort gives bucket 1 = lowest activity (good explicit framing for the engineer who needs to label "low/med-low/med-high/heavy users").

- Scores: 5/5/5/5 → **5.0**
- Topic: Analytical query patterns on Iceberg+Trino

### Q3 — dbt persist_docs for Iceberg column comments visible in Trino → 4.875

The official [docs.getdbt.com/reference/resource-configs/persist_docs](https://docs.getdbt.com/reference/resource-configs/persist_docs) page lists Postgres/Redshift/Snowflake/BigQuery/Databricks/Spark — does NOT mention dbt-trino. So a strict-docs-only reading would say "Trino not supported." BUT the dbt-trino adapter source code at [github.com/starburstdata/dbt-trino dbt/include/trino/macros/adapters.sql](https://github.com/starburstdata/dbt-trino/blob/master/dbt/include/trino/macros/adapters.sql) (WebFetched this iter) implements BOTH `trino__alter_relation_comment` (`comment on {{ relation.type }} {{ relation }} is '...'`) and `trino__alter_column_comment` macros — so persist_docs DOES work on dbt-trino in practice.

Responder correctly affirmed: persist_docs pushes schema.yml descriptions as `COMMENT ON TABLE` / `COMMENT ON COLUMN` into Iceberg metadata during dbt run/build. Config shapes both correct:
- Per-model: `{{ config(persist_docs={"relation": true, "columns": true}) }}` ✓
- Global: `models: +persist_docs: {relation: true, columns: true}` ✓

Verification path correct: `SHOW COLUMNS FROM <table>` (Comment column) or `information_schema.columns.comment`.

Disambiguation from `dbt docs generate` (which produces a static documentation site, not database metadata) is helpful — the engineer's actual ask is "comments visible when analysts query in Trino," which is the persist_docs path NOT the docs-site path.

Minor completeness shave: doesn't explicitly say "verified working on dbt-trino + Iceberg connector" (the official dbt docs page is silent on dbt-trino so an engineer reading just that page might think it's unsupported and need to verify the adapter macro). Could add a one-liner pointing at the dbt-trino macro implementation.

- Scores: Acc 5 / Clar 5 / Prac 5 / Compl 4.5 → **4.875**
- Topic: Improving complex SQL performance on Trino with dbt

### Q4 — Oracle MONTHS_BETWEEN → Trino date_diff('month'), day-aware semantics → 4.8125

**Matches pinned `reference_trino_datediff_dayaware.md`** verbatim: "Trino 467 date_diff('month'/'year'/etc) is DAY-AWARE / complete-units (drops fractional); date_diff('month','2024-01-15','2024-02-14')=0, Feb-15=1. NOT month-field/boundary diff."

Responder's worked example: Jan 31 created, Feb 14 today → 0 ("one complete month from Jan31 is Feb28/29, Feb14 < that → 0"). The arithmetic-of-anniversaries framing is the most intuitive explanation. Correct.

`WHERE date_diff('month', created_at, current_timestamp) >= 12` for "≥12 months old" — exactly right idiomatic replacement for Oracle's `MONTHS_BETWEEN(SYSDATE, created_at) >= 12`. The MONTHS_BETWEEN-as-integer-complete-months semantic equivalence is the load-bearing migration pattern.

"How date_diff counts months: how many times you can add 1 month to a before exceeding b" — accurate intuition pump.

Small Compl ding (–0.5): The fractional-approximation hack `date_diff('day',a,b)/31.0` is presented as an Oracle MONTHS_BETWEEN substitute, but Oracle's MONTHS_BETWEEN uses 31 only for partial-month components (whole months go boundary-to-boundary), so this isn't a faithful drop-in. The more conventional approximation is `date_diff('day',a,b)/30.0` for ballpark or a proper case-based reconstruction with `date_diff('month')` + day-of-month residual / 31. For most migration use cases the integer date_diff('month') comparison is the right pattern and fractional rarely matters, so this is a minor recall ding not a load-bearing slip.

- Scores: Acc 4.75 / Clar 5 / Prac 5 / Compl 4.5 → **4.8125**
- Topic: Oracle PL/SQL → dbt+Trino migration

---

## Aggregate

Overall: (4.25 + 5.0 + 4.875 + 4.8125) / 4 = **4.7344 STRONG PASS**

## FIX-A status

**NO FIX-A this iteration.** All four questions land the load-bearing canonical correctly. The thin-margin probe (Q1 dynamic filtering) verifies that the most-actionable claim — the runtime check metric `dynamicFilterSplitsProcessed` — IS REAL per [trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html) and is consistently taught across resources/22, /28, /03. The "what stops it" answers are correct (with minor imprecision on "partitioned join loses DF advantage" — DF works on PARTITIONED joins, just less dramatically), and the biggest miss (wait-timeout as the most common real-world DF-zero failure mode) is already canonical in resources/22 §5.4 + §4438 — recall ceiling, not resource defect.

## Soft watches

- **iter1239 Q1 dynamic-filtering-stops-it WAIT-TIMEOUT recall ceiling** — re-probe under different DF-debugging framings (e.g. "EXPLAIN shows dynamicFilters but EXPLAIN ANALYZE shows 0", "DF doesn't help small accounts table") in 4-8 iters to see if wait-timeout / `dynamic-filtering.wait-timeout` surfaces. If recurs → consider light additive defang at the existing resources/28 DF-stops-it card. If one-off → leave canonicals untouched.
- **iter1239 Q4 MONTHS_BETWEEN fractional /31.0 approximation imprecision** — soft, very low priority. The integer ">=N complete months" pattern is the load-bearing migration answer; fractional MONTHS_BETWEEN is a niche corner that rarely matters in SaaS-style customer-tenure / churn-window queries.

## Carry-forward open watches (unchanged)

- iter1238 Q3 broadcast-vs-partitioned-lead-rec-hedge (soft; small dim joining large fact OOM framings)
- iter1236 rn=1-within-batch-pairing (soft)
- iter1234 ROLLUP-date_trunc-expr (soft)
- iter1233 IGNORE-NULLS-framing
- iter1231 NEXT_DAY-note
- iter1230 EXISTS-overwarning / ::cast
- iter1215 strpos-3-arg CEILING
- iter1213 session_properties / (+)
- iter1229 @v1-Spark
- iter1208 width_bucket

## Topic-row updates

| Topic | Before | This iter | After |
|---|---|---|---|
| Query performance basics | 4.2026/32 | Q1: 4.25 | (134.4832 + 4.25)/33 = **4.2040/33 PASSED** (+0.0014, margin +0.7040, REMAINS THINNEST) |
| Analytical query patterns on Iceberg+Trino | 4.5401/171 | Q2: 5.0 | (776.3571 + 5.0)/172 = **4.5428/172 PASSED** (+0.0027, margin +1.0428) |
| Improving complex SQL perf on Trino with dbt | 4.4874/57 | Q3: 4.875 | (255.7818 + 4.875)/58 = **4.4941/58 PASSED** (+0.0067, margin +0.9941) |
| Oracle PL/SQL → dbt+Trino migration | 4.4670/204 | Q4: 4.8125 | (911.268 + 4.8125)/205 = **4.4687/205 PASSED** (+0.0017, margin +0.9687) |

All required topics REMAIN PASSED. Query performance basics REMAINS thinnest at 4.2040 (margin +0.704). Streak of 1st-re-probe-closure + STRONG PASS continues.
