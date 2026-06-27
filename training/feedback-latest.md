# Iter1193 Judge Feedback

**Overall: 4.92 / 5.0 — STRONG PASS, NO-OP.** All 4 answers technically sound and production-stack-aligned. Q1 has one mild secondary-framing slip on Trino-optimize-vs-Spark-rewrite_data_files routing but the core partition-evolution canonical is pin-perfect and the Spark routing the responder lands on is correct and prod-stack-aligned. Q2 / Q3 / Q4 clean ≥4.9. WATCHES from iter1192 (`delete+insert-on-non-ACID-Hive defang`) and iter1191 (`dbt-contract two-phase mechanism`) NOT exercised this iter — both carry forward.

---

## Q1 — Iceberg ALTER TABLE partition spec evolution (month→day), what happens to existing data

**Score: 5.0 / 5.0 / 4.0 / 5.0 = 4.75 (PASS)**

Core partition-evolution canonical is pin-perfect. One secondary-routing imprecision on the Trino-optimize-vs-Spark-rewrite_data_files framing — engineer arrives at the correct action (Spark for historical re-layout) so practical impact is bounded.

### Verified correct (load-bearing primary axis):

1. **DDL form `ALTER TABLE iceberg.<schema>.<table> SET PROPERTIES partitioning = ARRAY['day(signed_up_at)']`** — VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim:
   > "ALTER TABLE table_name SET PROPERTIES partitioning = ARRAY[<existing partition columns>, 'my_new_partition_column'];"

   The `'day(signed_up_at)'` transform notation is the documented Iceberg/Trino transform syntax (alongside `month(...)`, `year(...)`, `hour(...)`, `bucket(col, N)`, `truncate(col, L)`). Responder's exact form is copy-pasteable.

2. **NO drop-and-recreate needed** — VERIFIED. Trino docs verbatim: *"Partitioning can also be changed and the connector can still query data created before the partitioning change."* Plus the Dremio future-proof-partitioning blog: *"Partition evolution lets you change how a table is partitioned, from monthly to daily granularity, from one column to multiple columns, or from no partition to a fully partitioned layout, without rewriting a single data file."*

3. **Old files KEEP old (month) partition spec, NEW writes use new (day) spec** — VERIFIED. This is the foundational Iceberg partition-evolution semantic: each data file records the partition-spec-ID it was written under, and the planner uses the per-file recorded spec for pruning. Old files pruned at month granularity, new files at day granularity, all under one logical table. Responder's framing exact.

4. **No automatic rewrite, no auto-repartitioning** — VERIFIED. Per Iceberg spec, partition evolution is a metadata-layer schema change; data files are NOT touched. Engineer's specific question ("auto-repartitioned, or old files keep old layout while new writes use new") answered correctly: the second branch.

5. **Partition pruning on old files still works (at month granularity)** — VERIFIED. The planner uses per-file partition-spec-ID for pruning; old files still get correctly pruned at month-level. New queries crossing the cutover boundary scan a mix of old-spec and new-spec files transparently.

### Imprecision — Trino-EXECUTE-optimize-vs-Spark-rewrite_data_files routing (Acc 5.0, App 4.0):

Responder framed historical re-layout as: *"For historical files under the new spec, use SPARK to rewrite them (Trino's EXECUTE optimize has limitations on evolved partition columns per resource 17): CALL iceberg.system.rewrite_data_files(table => 'schema.users')."*

Two sub-points to verify:

**(a) Does Trino 467 have a native `rewrite_data_files` procedure?** — VERIFIED **NO**. Trino 467 docs list these `iceberg.system.*` procedures: `register_table`, `unregister_table`, `migrate`, `add_files_from_table`, `add_files`, `rollback_to_snapshot`. NO `rewrite_data_files`. So routing the engineer to Spark's `CALL <catalog>.system.rewrite_data_files(...)` is the **correct routing** — the responder is right that this is Spark-side. Spark Iceberg's `rewrite_data_files` procedure DOES exist per [Iceberg Spark procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/#rewrite_data_files). Production-stack-aligned per `prod_info.md` (Spark is the ingestion engine).

**(b) Does Trino's `EXECUTE optimize` actually FAIL TO rewrite files into the new partition spec?** — PARTIALLY. The precise behavior per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): *"If the table is partitioned, the data compaction acts separately on each partition selected for optimization."* Per [trinodb/trino #25279](https://github.com/trinodb/trino/issues/25279) "Add support to optimize iceberg table on newly added partition predicate": the documented limitation is that the **newly-added partition column cannot be used in a predicate during optimize**. The unrestricted `ALTER TABLE ... EXECUTE optimize` (no WHERE) without a new-partition-column predicate CAN rewrite files into the new spec — partition compaction acts per partition under the current spec. Per Dremio's "Future-Proof Partitioning" blog: *"if you compact old data to the new partition spec, you temporarily double storage until old snapshots are expired"* — confirming Trino's optimize CAN rewrite to new spec in the unrestricted case.

So the responder's claim "Trino's EXECUTE optimize has limitations on evolved partition columns" is **technically true but over-warned** — the limitation is narrow (predicate-only, on the new partition column), NOT a blanket inability to rewrite. The engineer who reads this verbatim is routed to Spark (which works on this stack), but is denied the in-place Trino option (`ALTER TABLE iceberg.<schema>.users EXECUTE optimize(file_size_threshold => '512MB')` without a new-day-column predicate) that ALSO works.

Per `feedback_responder_broken_secondary_alternative.md` and `feedback_responder_overwarning_folklore.md` families — this is a mild over-warning on a secondary alternative, not a load-bearing error. Core answer is right; engineer arrives at a working action; the omitted Trino-side path is a recall ceiling. **NO RESOURCE FIX** per directive: "if responder OVER-stated Trino optimize's limitation, flag as minor secondary imprecision, don't tank score since core answer is right."

### Production stack fit:

Recommendation routes correctly — Spark Iceberg procedures fit `prod_info.md` (Spark is the ingestion engine). No imported-prior slip on procedure existence (responder correctly identifies `rewrite_data_files` as Spark-side, not making the iter1168-style mistake of assuming a procedure is Spark-only when it's actually Trino-native). 

---

## Q2 — CROSS JOIN UNNEST array element + position (1st/2nd/5th) in same query, no self-join

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (STRONG PASS)**

Pin-perfect `UNNEST WITH ORDINALITY` canonical. All load-bearing facts VERIFIED at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html):

1. **Syntax `CROSS JOIN UNNEST(viewed_skus) WITH ORDINALITY AS t(sku, position)`** — VERIFIED verbatim: *"UNNEST can optionally have a WITH ORDINALITY clause, in which case an additional ordinality column is added to the end"*; example *"UNNEST (ARRAY[2, 5], ARRAY[7, 8, 9]) WITH ORDINALITY AS t(a, b, rownumber)"*. Responder's exact shape.

2. **Ordinality column appended LAST, 1-based bigint** — VERIFIED. Docs example output shows `rownumber` values 1, 2, 3 sequential. Engineer's literal "1st/2nd/5th" maps directly.

3. **Two-alias `AS t(sku, position)` names element + ordinality** — VERIFIED via the docs example `AS t(a, b, rownumber)` (two element columns plus ordinality alias).

4. **Duplicates get distinct ordinals** — Responder's example `ARRAY['a','b','a']` → `(a,1), (b,2), (a,3)` is correct: ordinality is by POSITION not by value, so duplicate values get distinct ordinals. Pin-perfect demonstration.

5. **`LEFT JOIN UNNEST(...) WITH ORDINALITY AS t(...) ON TRUE` preserves rows with NULL/empty arrays** — VERIFIED verbatim: *"LEFT JOIN is preferable in order to avoid losing the row containing the array/map field in question when referenced columns from relations on the left side of the join can be empty or have NULL values"* + *"in case of using LEFT JOIN the only condition supported by the current implementation is ON TRUE"*. Responder's exact form.

Matches r07 §156-186 (iter720 PIN — FIX-A) LEADING CANONICAL doing its job. Same canonical reached cleanly at iter1176 Q2 + iter1177 Q4 + now iter1193 Q2 (3 of last 3 UNNEST-WITH-ORDINALITY angles passed clean 5.0). No imported-prior slip, no broken-secondary-alternative slip.

---

## Q3 — dbt seed for ~250-row ISO-country→region lookup CSV

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (STRONG PASS)**

Pin-perfect dbt-seed canonical. All load-bearing facts VERIFIED:

1. **`seeds/country_regions.csv` directory layout** — VERIFIED at [docs.getdbt.com/docs/build/seeds](https://docs.getdbt.com/docs/build/seeds) verbatim: *"Seeds are CSV files in your dbt project (typically in your seeds directory), that dbt can load into your data warehouse using the dbt seed command."*

2. **`+column_types` in `dbt_project.yml` (optional)** — Correct, matches dbt config pattern for explicit column-type declaration (otherwise dbt infers from CSV content, which can mis-type ISO codes as e.g. integer).

3. **`dbt seed` / `dbt seed --select country_regions`** — VERIFIED at dbt docs as the loader command. The `--select` flag for single-seed targeting is the standard dbt selector pattern.

4. **Creates a real table in the warehouse (Iceberg on this stack)** — VERIFIED. dbt-trino materializes seeds as regular tables in the target catalog/schema; on a Trino + Iceberg stack, this lands as an Iceberg table. Engineer can `SELECT * FROM iceberg.<schema>.country_regions` after `dbt seed`.

5. **`dbt build` runs seeds automatically, `dbt run` does NOT** — VERIFIED at [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build) verbatim: *"The dbt build command will: run models, test tests, snapshot snapshots, seed seeds, build user-defined functions ... In DAG order, for selected resources or an entire project."* `dbt run` is a separate command restricted to models. Critical distinction the engineer needs.

6. **`ref('country_regions')` to join from a model** — VERIFIED at the dbt seeds page verbatim: *"Seeds can be referenced in downstream models the same way as referencing models — by using the ref function."* Example: `SELECT * FROM {{ ref('country_regions') }}`.

7. **Editing CSV + re-running `dbt seed` TRUNCATES and fully reloads** — VERIFIED at dbt seeds FAQ verbatim: *"When you typically run dbt seed, dbt truncates the existing table and reinserts the data."* — Responder's "no special sync" framing is accurate. Caveat the responder didn't name (recall ceiling, not load-bearing): if CSV columns are added/renamed, `dbt seed --full-refresh` is required to drop-and-rebuild (truncate-and-reinsert doesn't update the table SCHEMA). For the engineer's stated workflow (quarterly value updates to a fixed 2-column ISO→region mapping), truncate+reinsert is exactly the right semantic.

Use-case fit confirmed: ~250-row lookup updated quarterly is the textbook dbt-seed scenario per docs verbatim ("country code mappings ... Good use-cases"). Production-stack-aligned (no external infra needed — runs entirely through dbt-trino + Iceberg + HMS).

No broken-secondary-alternative slip, no over-warning, no fabrication. Clean canonical reach.

---

## Q4 — Oracle ADD_MONTHS → Trino date_add('month', n, ts/date)

**Score: 5.0 / 5.0 / 5.0 / 4.75 = 4.9375 (STRONG PASS)**

Pin-perfect Oracle-to-Trino direct port with month-end-clamp semantic contrast. All load-bearing facts VERIFIED.

1. **`date_add('month', 12, subscription_start_date) AS renewal_date`** — VERIFIED at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): `date_add(unit, value, timestamp) → [same as input]`. The `'month'` unit is documented (full list includes year/quarter/month/week/day/hour/minute/second/millisecond). Responder's exact form.

2. **Works on both DATE and TIMESTAMP, return type matches input** — VERIFIED per docs return-type annotation `[same as input]`. Trino's `date_add` is signature-polymorphic over DATE / TIMESTAMP / TIMESTAMP WITH TIME ZONE inputs (per pinned `reference_trino_from_unixtime_tz.md` and standard datetime fn pattern). DATE input + 'month' unit returns DATE; TIMESTAMP input returns TIMESTAMP. Responder's "return type matches input" framing exact.

3. **No native Oracle `ADD_MONTHS` in Trino** — VERIFIED. Not in [functions list](https://trino.io/docs/467/functions/list.html) for datetime. Function-not-found is the expected error. Per pinned imported-prior-self-error family (`reference_trino_starts_with_ends_with.md`, `reference_trino_listagg_native.md`, `reference_trino_to_char_exists.md`) — `ADD_MONTHS` is one of the legitimate Oracle-only fns that does NOT have a Trino native equivalent (unlike LISTAGG / to_char / starts_with which surprised the prior).

4. **Oracle ADD_MONTHS month-end clamp behavior** — VERIFIED against [Oracle ADD_MONTHS docs](https://docs.oracle.com/cd/B19306_01/server.102/b14200/functions004.htm) verbatim: *"If date is the last day of the month or if the resulting month has fewer days than the day component of date, then the result is the last day of the resulting month."* Responder's framing exact: input month-end → output month-end.

5. **Worked example `ADD_MONTHS(DATE '2026-02-28', 1)`** — VERIFIED. 2026 is non-leap (2026/4 = 506.5), so Feb 2026 has 28 days, so Feb 28 IS the last day of Feb 2026. Per Oracle rule → result clamps to last day of March → `2026-03-31`. Trino `date_add('month', 1, DATE '2026-02-28')` does NOT clamp (no Oracle-special-rule) → preserves day-of-month → `2026-03-28`. Exact 3-day divergence is the load-bearing demonstration.

6. **CASE wrapper for Oracle-compatible clamp** — VERIFIED sound:
   ```sql
   CASE WHEN d = last_day_of_month(d)
        THEN last_day_of_month(date_add('month',12,d))
        ELSE date_add('month',12,d) END
   ```
   `last_day_of_month(x) → date` exists in Trino 467 per docs verbatim. The CASE detects "is input the month-end?" and if so forces output to last-day-of-result-month; otherwise standard `date_add`. This is the canonical Oracle-compat shape and works on both DATE and TIMESTAMP inputs.

7. **`col + INTERVAL '12' MONTH` equivalent** (not explicitly named by responder but worth verifying) — VERIFIED at docs: `timestamp '2012-10-31 01:00' + interval '1' month` returns `2012-11-30 01:00:00.000` (clamps when target month has fewer days). Equivalent to `date_add` semantic for the no-overflow case; both forms behave identically. Recall ceiling, not a defect.

### Minor recall ceiling (Compl -1.0 weighted into 4.75 on that dim):

Responder's claim "Trino date_add preserves the day number" is precise FOR THE SPECIFIC EXAMPLE (Feb 28 → Mar 28, target month has day 28). It's slightly oversimplified for the edge case where target month has FEWER days than input day (e.g., `date_add('month', 1, DATE '2026-01-31')` → 2026-02-28 in non-leap year; the day is NOT preserved, it clamps to last day of Feb because Feb has only 28 days). This is the same auto-clamp Postgres and most engines do, but the responder's "preserves the day number" phrasing might mislead an engineer who tests Jan 31 + 1 month and is surprised by Feb 28.

Practical impact bounded — engineer's actual use-case is renewal-date addition of 12 months which typically preserves day cleanly (e.g., 2025-03-15 + 12 months = 2026-03-15); the edge case only matters for Jan-29/30/31 inputs +1 month etc. Not load-bearing for the renewal-date use case. NO RESOURCE FIX.

No imported-prior slip (didn't fabricate ADD_MONTHS as existing in Trino — correctly identifies as Oracle-only). No broken-secondary-alternative slip. No over-warning per `feedback_responder_overwarning_folklore.md`.

---

## Watches carried forward (NOT exercised this iter):

1. **`iter1192 dbt delete+insert-on-non-ACID-Hive defang`** — r27 §3.2 LIGHT FIX-A added Hive-connector capability-gate card. Re-probe in 4-7 iters with framing like "we tried delete+insert on Hive after merge failed, also fails" / "non-ACID Hive table fallback for upsert". CARRY.

2. **`iter1191 dbt-contract two-phase mechanism phrasing`** — re-probe with "do model contracts need a live Trino connection / can they be validated in CI without warehouse access" framing. CARRY.

Both watches carry forward at iter1193; no resource change recommended this iter.

---

## Summary scoring breakdown

| Q | Tech | Clarity | Practical | Compl | Avg |
|---|------|---------|-----------|-------|-----|
| Q1 partition evolution | 5.0 | 5.0 | 4.0 | 5.0 | **4.75** |
| Q2 UNNEST WITH ORDINALITY | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q3 dbt seed mechanics | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q4 date_add month + ADD_MONTHS | 5.0 | 5.0 | 5.0 | 4.75 | **4.9375** |

**Iter1193 overall = (4.75 + 5.00 + 5.00 + 4.9375) / 4 = 4.92 — STRONG PASS, NO-OP.**

No resource fix recommended. Q1 secondary-routing imprecision is a recall ceiling on a peripheral alternative; engineer arrives at correct action via Spark routing which fits production stack. Q2/Q3/Q4 clean canonical reaches.
