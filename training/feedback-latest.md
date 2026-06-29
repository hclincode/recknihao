# Iteration 1254 — Judge Feedback

## Verdict

**Overall: 3.8125 PASS — Q3 INDIVIDUAL FAIL (load-bearing contradiction + missed canonical) AND Q1 INDIVIDUAL FAIL (over-broad "469+ only / cannot on 467" claim missing the Trino-467-native CTAS path). Both flagged sub-bugs are RESOURCE-SOURCED, not pure responder slips. TWO LIGHT FIX-A warranted: (1) r03 §474 lever 4 + r18 §1251-§1259-§1351 — distinguish Trino-467 CREATE TABLE WITH (parquet_bloom_filter_columns=ARRAY[...]) from 469+ ALTER SET PROPERTIES form; (2) r27 §6.7F — add tag-DEFINITION-locations table + tag:X-selects-ONLY-tagged + +tag:X-for-upstream-parents canonical with DO-NOT-WRITE row defanging the "tag:X pulls the full DAG" myth.**

Per-Q scores: Q1=3.5, Q2=4.125, Q3=2.75, Q4=4.875. Average (3.5 + 4.125 + 2.75 + 4.875) / 4 = **3.8125**.

Pattern this iter: TWO resource-sourced findability/correctness gaps surfaced on the same iter, both flagged correctly by the teacher's pre-grep. The Q1 issue is the iter1173 `reference_trino_parquet_bloom_filter_469.md` CREATE-vs-ALTER nuance that the resources never fully reconciled into the load-bearing canonical (r03 §474 / r18 §1251); the responder lifted r18 §1259's over-broad "469+ ONLY / fails on 467" verbatim. The Q3 issue is a genuine content gap — r27 has selection-OPERATOR docs (§3855-§3867) but NOT tag-DEFINITION-locations or the tag:X-selects-only-tagged-no-deps fact.

---

## Per-question scoring

### Q1 — Iceberg transactions table ~800M rows; frequent `WHERE customer_id = 'uuid'` point-lookup scans forever; what are bloom filters, can I enable on customer_id in Trino 467, exact syntax, equality-lookup payoff, existing table on 467 vs new table / different engine?

**Acc: 3.0 / Clar: 4.0 / Prac: 3.5 / Compl: 3.5 → 3.5 (INDIVIDUAL FAIL on accuracy, scrapes PASS at average)**

What was correct:
- Bloom filter MECHANISM: per-row-group probabilistic structure, microsecond skip on equality lookups, pays off on HIGH-cardinality columns, wasteful on low-cardinality (status / country_code).
- Trino 467 READ side: `parquet.use-bloom-filter=true` default ON, Trino 467 reads bloom filters automatically with no Trino-side enable needed.
- Spark write-side form: `ALTER TABLE ... SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.customer_id'='true')` + Spark `CALL rewrite_data_files(..., options => map('rewrite-all','true'))` is valid and production-stack-aligned (prod_info.md ingestion is Spark).
- Equality-only payoff (not ranges) correctly stated.

What was wrong — LOAD-BEARING:
- **CLAIMED**: *"On Trino 467 with an EXISTING table you CANNOT enable bloom filters directly. `parquet_bloom_filter_columns` is Trino 469+ ONLY (Jan 2025); on 467 it fails with 'unknown table property'."*
- **VERIFIED via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)** this iter: the Trino 467 Iceberg CREATE TABLE WITH (...) allow-list is exactly `format` / `partitioning` / `sorted_by` / `location` / `format_version` / `orc_bloom_filter_columns` / `orc_bloom_filter_fpp` / **`parquet_bloom_filter_columns`** / `object_store_layout_enabled` / `data_location` / `extra_properties`. **`parquet_bloom_filter_columns` IS in the 467 CREATE TABLE allow-list** (a NEW table or CTAS rebuild on Trino 467 CAN set `WITH (parquet_bloom_filter_columns = ARRAY['customer_id'])` Trino-native, no Spark hop needed).
- **VERIFIED via WebFetch of [trinodb/trino PR #24573](https://github.com/trinodb/trino/pull/24573)** this iter: the PR explicitly adds the `ALTER TABLE SET PROPERTIES parquet_bloom_filter_columns = ARRAY[...]` form ("Allow configuring `parquet_bloom_filter_columns` with `SET PROPERTIES` in Iceberg"), milestone Trino 469. Only the **ALTER on EXISTING table** form is 469+; the CREATE TABLE WITH form predates this and works on 467.
- Matches pinned `reference_trino_parquet_bloom_filter_469.md`: "parquet_bloom_filter_columns IS a valid Trino 467 CREATE TABLE WITH(...) property (docs list it, used at scan for =/IN); only the ALTER TABLE SET PROPERTIES form (add to existing table) is 469+ (PR #24573)."

What was missed:
- The Trino-467-NATIVE CTAS-rebuild path for the engineer's actual scenario (EXISTING 800M-row table on Trino 467, no Spark hop available or preferred). Correct sequence:
  ```sql
  -- Trino 467 NATIVE — no Spark hop required:
  CREATE TABLE iceberg.analytics.transactions_v2
  WITH (
    partitioning = ARRAY['day(occurred_at)'],         -- keep prior partition spec
    parquet_bloom_filter_columns = ARRAY['customer_id']
  )
  AS SELECT * FROM iceberg.analytics.transactions;
  -- Then swap names atomically; drop old after verifying.
  ALTER TABLE iceberg.analytics.transactions RENAME TO transactions_old;
  ALTER TABLE iceberg.analytics.transactions_v2 RENAME TO transactions;
  ```
- This is the lighter-weight production path for the engineer's "Trino is primary engine + existing table" framing. Spark route stays valid as an alternative when the team prefers in-place rewrite without a CTAS swap.

**RESOURCE-SOURCE CHECK — DEFECT CONFIRMED**:

- `r03 §474` lever 4 (CREATE-INDEX-redirect leading canonical → 4-lever filter-speed table) — the bloom-filter "DDL / Trino syntax" column shows ONLY `ALTER TABLE ... SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.<col>'='true')` (Spark form). It does NOT show the Trino-467-native `CREATE TABLE ... WITH (parquet_bloom_filter_columns = ARRAY['<col>'])` form. An engineer reading r03 §474 reaches "bloom = Spark only" mental model — exactly the responder's failure mode.
- `r03 §491-§501` worked-example block — same shape, Spark TBLPROPERTIES + Spark rewrite_data_files only. No Trino-native path.
- `r18 §1251` 5th row of fix-matrix — says "`parquet_bloom_filter_columns` ... **NO — Trino 469+ only.** This property was added in [Trino 469 ... via PR #24573]. On Trino 467 setting it fails with 'unknown table property: parquet_bloom_filter_columns'." This conflates the ALTER form (469+) with the CREATE form (467 OK).
- `r18 §1256-§1259` callout — says "Write-side configuration via `parquet_bloom_filter_columns` table property (TRINO 469+) ... On Trino 467, setting this table property fails with 'unknown table property.'" Same conflation.
- `r18 §1351` DO-NOT-RECOMMEND row — specifically bans `ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns = ARRAY['plan_type']` on 467 (correct ban), but the prose around it implies the entire property is 469+ (wrong).

**FIX-A RECOMMENDATION (LIGHT, ~25 lines across 2 files)**:

1. **r03 §474 lever 4 row "DDL / Trino syntax" column** — split into the canonical 467 surfaces:
   - **NEW table on Trino 467 NATIVE**: `CREATE TABLE ... WITH (parquet_bloom_filter_columns = ARRAY['customer_id'], parquet_bloom_filter_fpp = 0.01)` — works on 467.
   - **EXISTING table on Trino 467**: TWO paths — (a) Trino-native CTAS rebuild + rename swap (no Spark hop), (b) Spark `SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.<col>'='true')` + Spark `rewrite_data_files`. Engineer picks based on tolerance for atomic rename vs in-place rewrite.
   - **EXISTING table on Trino 469+**: also gets `ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns = ARRAY['<col>']` + `EXECUTE optimize(file_size_threshold => '512MB')` (NOT 467).

2. **r18 §1251 5th row** — re-scope the "NO — Trino 469+ only" verdict to ONLY the `ALTER TABLE ... SET PROPERTIES` form. Add a row above it for the CREATE TABLE form: "**`parquet_bloom_filter_columns` at CREATE TABLE** | **YES on 467** | `CREATE TABLE iceberg.x.y (...) WITH (parquet_bloom_filter_columns = ARRAY['col'])` — use CTAS to migrate existing 467 table to new table with bloom filter, then atomic rename swap." Keep the §1351 DO-NOT-RECOMMEND row but re-scope its prose to "the SET PROPERTIES form" not "the property."

3. **Keyword anchors** to add at r18 §1251 leading callout: "Trino 467 bloom filter CTAS rebuild" / "CREATE TABLE parquet_bloom_filter_columns on 467" / "Trino-native bloom filter no Spark" / "EXISTING 467 table bloom filter migration" so the engineer's question keywords route here, not to the §1259 over-broad ban.

This is the iter1173-pinned nuance that never landed in the load-bearing canonicals. The fix is additive + reconciling existing rows (not a new file, not a new card).

Watch label: `iter1254 Q1 parquet_bloom_filter_columns CREATE-on-467-vs-ALTER-on-469 r03 §474 + r18 §1251 reconcile FIX-A` — re-probe in 4-8 iters under "Trino 467 bloom filter on existing table" / "enable bloom filter without Spark" / "CTAS rebuild with bloom filter" framings to verify the new canonical surfaces.

Engineer impact: with the current responder answer, an engineer who has Trino-only and no Spark workflow gives up on the Trino-native path and accepts the Spark detour as forced. The actual 467-native CTAS path exists and is the lighter recipe for many production-stack shapes.

---

### Q2 — Per calendar month YoY % change: total revenue that month, same month previous year, % change. Cleaner Trino than self-join or LAG-12?

**Acc: 4.0 / Clar: 4.5 / Prac: 4.0 / Compl: 4.0 → 4.125 (PASS)**

What was correct:
- Self-join + `date_add('month', -12, cur.month)` pattern correct on Trino 467 (verified valid at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) — `date_add(unit, value, timestamp)` supports 'month' unit).
- `NULLIF(prev, 0)` guard against div-by-zero correct.
- `(cur - prev) * 100.0 / NULLIF(prev, 0)` ratio shape correct.
- `LAG(revenue, 12) OVER (PARTITION BY customer_id ORDER BY month)` alternative correct Trino window-function syntax.
- Two-form presentation (self-join + LAG-12) addresses the engineer's "self-join or LAG-12 — cleaner?" question structurally.

What was wrong — granularity over-spec:
- Engineer asked for **per-MONTH TOTAL revenue (all customers)** YoY: "total revenue that month, same month previous year, % change." Three columns, ~24 rows for 2 years of monthly data.
- Responder's CTE: `GROUP BY customer_id, date_trunc('month', sale_date)` — adds per-customer breakdown the engineer did not ask for. Output becomes ~24 × N_customers rows.
- The `PARTITION BY customer_id` on the LAG-12 alternative also assumes per-customer YoY, not total YoY.
- Engineer must edit both forms: drop `customer_id` from GROUP BY in the self-join form, drop `PARTITION BY customer_id` from the LAG-12 form.
- This is per-instance question-misread (cohort vs total) not resource defect — adjacent to the iter1238 broadcast-vs-partitioned hedge family (mechanics right, framing slightly off).

What was missed:
- The lighter single-pass variant the engineer's "cleaner Trino" hint pointed at: conditional aggregation `SUM(amount) FILTER (WHERE year(sale_date)=2025)` paired with `SUM(amount) FILTER (WHERE year(sale_date)=2024)` GROUP BY `month(sale_date)` (single table scan + FILTER aggregates instead of self-join + LAG). iter1210 Q2 reached this canonical cleanly; this iter missed it as a third option.

**NO RESOURCE FIX** — granularity misread is per-instance and the self-join + LAG-12 + NULLIF forms are individually correct. The single-scan-FILTER alternative IS covered in r07 / r28 conditional-aggregation canonical. Recall ceiling. Soft watch only.

Watch label: `iter1254 Q2 YoY per-customer-vs-per-month-total granularity misread + single-scan-FILTER alternative not surfaced` — re-probe under "month-level total YoY (no customer dimension)" framings 4-8 iters.

---

### Q3 — dbt tags for scheduling: ~10 "critical" models hourly, rest nightly. Where to put the tag (config() in .sql, schema.yml, both)? Does `dbt build --select tag:critical` run ONLY tagged models or pull deps / run whole DAG?

**Acc: 2.5 / Clar: 3.0 / Prac: 2.5 / Compl: 3.0 → 2.75 (INDIVIDUAL FAIL)**

What was correct:
- Tag DEFINITION location 1: `{{ config(tags=["critical","hourly"]) }}` in the .sql file — correct per [docs.getdbt.com/reference/resource-configs/tags](https://docs.getdbt.com/reference/resource-configs/tags) (verified verbatim this iter: *"To apply tags to a model in your SQL file, you would add the following: `{{ config(tags=["finance"]) }}`"*).
- Tag DEFINITION location 2: `tags: [critical, hourly]` in schema.yml — correct (verified verbatim: *"To apply tags to a model in your `models/` directory YAML property file, you would add the following using the `config` property: `models: - name: stg_customers config: tags: ['santi']`"*).
- The engineer's "both?" question implicitly answered (responder said either-or; both is legal, list-concatenation semantics).

What was wrong — LOAD-BEARING CONTRADICTION:
- **FIRST statement** (correct): *"`dbt build --select tag:critical` runs ONLY models tagged critical (plus deps if you add leading `+`)."*
- **SECOND statement, later in same answer** (WRONG): *"`dbt build --select tag:critical` pulls in upstream `ref()` dependencies and runs the full DAG needed for those models."*
- **VERIFIED via WebFetch of [docs.getdbt.com/reference/node-selection/syntax](https://docs.getdbt.com/reference/node-selection/syntax)** this iter: *"By default, `dbt run` executes _all_ of the models in the dependency graph; ... The `--select` flag is used to specify a subset of nodes to execute."* Selection is RESTRICTIVE by default; tag-selected nodes are NOT joined to their upstream parents automatically. To include parents: `+tag:critical` (the `+` is the upstream-ancestors graph operator).
- **VERIFIED via WebFetch of [docs.getdbt.com/reference/resource-configs/tags](https://docs.getdbt.com/reference/resource-configs/tags)**: *"`dbt build --select tag:my_tag` selects only nodes with that tag — it does not automatically include their dependencies."*
- The second statement is FACTUALLY WRONG, contradicts the responder's own first statement, AND directly answers the engineer's exact worry the WRONG WAY. The engineer's concern was specifically "if I tag the 10 critical models, does the hourly run also pull in their upstream nightly parents and effectively re-run the whole DAG hourly?" Correct answer: NO, tag:critical selects only the 10 tagged nodes, deps are NOT pulled. The responder's contradictory second sentence implies YES — which would push the engineer toward a wrong architectural decision (e.g., abandoning tag-based scheduling, splitting hourly/nightly into separate projects).

What was missed:
- Tag DEFINITION location 3: `dbt_project.yml` `models: <project>: +tags: critical` — folder-scoped tag application (verified at [docs.getdbt.com/reference/resource-configs/tags](https://docs.getdbt.com/reference/resource-configs/tags)). Engineer with 10 critical models in one folder can do this once instead of per-model. Useful for the engineer's "critical vs nightly" partition: tag whole folder.
- Tag SELECTION graph-operators: `+tag:critical` for upstream parents, `tag:critical+` for downstream children, `@tag:critical` for both. The `+` prefix/suffix asymmetry matters when the engineer wants to "run the critical models AND their upstream dependencies first" (`+tag:critical`) vs "run the critical models AND everything they feed" (`tag:critical+`).
- The responder's own honest admission earlier in the answer — *"Tag DEFINITION syntax is NOT documented in resources"* — surfaces a real findability gap that the teacher's pre-grep also confirmed.

**RESOURCE-SOURCE CHECK — GAP CONFIRMED**:

- `r27 §3855-§3867` covers SELECTION operators table (comma=AND, space=OR) + DO-NOT-WRITE row defanging "comma=OR" / "space=AND" myths. This is the tag-selector-syntax canonical.
- `r27 §3849` keyword anchors row mentions "dbt graph operators +model model+" but does NOT defang the "tag:X pulls full DAG" myth, does NOT show a "tag:X selects only tagged nodes" leading sentence.
- `r27 §3175` / §3285 are tagged with tags but the surrounding context is dbt_test_select discussions, not tag-definition canonical.
- Grep across resources: ZERO instances of `config\(tags=` documenting tag DEFINITION location; ZERO leading canonical for "where do tags live" (config / schema.yml / dbt_project.yml); ZERO DO-NOT-WRITE row defanging "tag:X auto-pulls upstream parents" myth.

**FIX-A RECOMMENDATION (LIGHT, ~20 lines, in r27 §6.7F)**:

Add a leading canonical at r27 §6.7F (BEFORE the existing §3855-§3867 selector-operators table) titled "Where dbt tags are DEFINED and what `tag:X` actually selects":

1. **Tag DEFINITION — 3 locations** (table):
   - `{{ config(tags=["critical","hourly"]) }}` in .sql file — per-model.
   - `models: - name: <model> config: tags: ['critical','hourly']` in schema.yml — per-model in properties YAML.
   - `models: <project_name>: <folder>: +tags: ['critical']` in dbt_project.yml — folder-scoped, leading `+tags:` syntax.
   - All three are additive (list-concatenated, deduped). Engineer's `~10 critical models` use case fits folder-scoped dbt_project.yml `+tags:` if all 10 live in one folder; otherwise per-model config in .sql or schema.yml.

2. **Tag SELECTION — what `--select tag:X` actually does** (sentence + DO-NOT-WRITE row):
   - Leading sentence: *"`dbt build --select tag:critical` selects ONLY nodes tagged `critical`. Upstream parents are NOT auto-pulled. To include upstream parents (so dbt rebuilds dependencies first): `+tag:critical`. To include downstream children: `tag:critical+`. To include both: `@tag:critical`."*
   - DO-NOT-WRITE row: *"`dbt build --select tag:critical` rebuilds the whole DAG of upstream dependencies."* — **FALSE.** Selection is restrictive by default; only the 10 tagged nodes run. Use `+tag:critical` if you DO want upstream-first ordering.

3. **Keyword anchors**: "dbt tag scheduling critical hourly", "dbt build --select tag does it run deps", "dbt tag:X selects only tagged", "+tag prefix upstream parents", "dbt_project.yml +tags folder-scoped", "config(tags=[]) in .sql".

Cross-link to existing §3855-§3867 selector-operators table.

Watch label: `iter1254 Q3 tag:X-doesn't-pull-deps + tag-DEFINITION-locations r27 §6.7F LIGHT FIX-A` — re-probe in 4-8 iters under "dbt tags hourly vs nightly scheduling" / "tag:X selects deps or only tagged" / "where do I put dbt tags" framings to verify the new canonical surfaces and the "pulls full DAG" myth stays defanged.

Engineer impact: the contradictory answer leaves the engineer uncertain about the fundamental tradeoff of tag-based scheduling. They might either (a) abandon tag-based scheduling and split the project, or (b) accept "pulls full DAG" and write a complex post-hoc filter — both bad outcomes. The correct answer (tag:X is restrictive, +tag:X for parents) is the most common SaaS dbt-scheduling pattern.

---

### Q4 — Oracle `NVL2(some_column, 'active', 'inactive')` errors in Trino. Equivalent or rewrite to CASE? Shorter form?

**Acc: 5.0 / Clar: 5.0 / Prac: 5.0 / Compl: 4.5 → 4.875 (STRONG PASS)**

What was correct:
- No NVL2 in Trino — VERIFIED at [trino.io/docs/467/functions/list.html](https://trino.io/docs/467/functions/list.html) (no NVL2 in the function index; only `coalesce`, `nullif`, `if`, `case`).
- `CASE WHEN some_column IS NOT NULL THEN 'active' ELSE 'inactive' END` — canonical NULL-safe two-branch conditional, valid Trino 467.
- `IF(some_column IS NOT NULL, 'active', 'inactive')` — shorter form, verified valid Trino 467 at [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) (*"`if(condition, value)` / `if(condition, value, else_value)`"*). Both compile identically (Trino lowers IF to CASE internally).
- Engineer can pick either form based on team style preference; both are NULL-safe (NULL-typed input correctly routes to ELSE branch).

What was missed (minor compl shave):
- COALESCE-based alternative `COALESCE(CAST(some_column AS VARCHAR), NULL)` is NOT the right tool here (COALESCE returns first non-NULL ARG VALUE, not a binary label); the responder correctly didn't recommend it.
- Could mention that Oracle's NVL2 has a TYPE-CHECKING quirk (both branches must be implicit-coercible) that Trino's CASE/IF handles cleanly via standard SQL coercion — not load-bearing.
- Didn't explicitly contrast NVL2 (2-branch conditional on NULL-ness) with NVL (default-substitution; → Trino `COALESCE(col, default)`) since engineer's question was scoped to NVL2 only.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Clean Oracle→Trino dialect canonical reach. Cites r27 / r23.

---

## Topic-checklist scoring updates

| Topic | Question | Old avg/count | New avg/count | Δ | Verdict |
|---|---|---|---|---|---|
| **Query performance basics** (partitioning, indexing strategy for analytics) | Q1 (bloom filter file-skipping for point lookup) | 4.2040/33 | 4.1833/34 | −0.0207 | PASSED (margin +0.6833, stays thinnest required-topic) |
| **Analytical query patterns on Iceberg+Trino** (funnels, cohorts, time-series SQL) | Q2 (YoY monthly %) | 4.5215/182 | 4.5193/183 | −0.0022 | PASSED (margin +1.0193) |
| **Improving complex SQL performance on Trino with dbt** (rewriting / incremental tuning / etc.) | Q3 (dbt tags for scheduling) | 4.4875/69 | 4.4627/70 | −0.0248 | PASSED (margin +0.9627) |
| **Oracle PL/SQL → dbt + Trino SQL migration** | Q4 (NVL2 → CASE / IF) | 4.4776/222 | 4.4785/223 | +0.0009 | PASSED (margin +0.9785) |

All required topics REMAIN PASSED. **Query-perf-basics remains thinnest at 4.1833/34**, takes the Q1 hit but stays comfortably above the 3.5 threshold (margin +0.68).

---

## Recommendation: 2 LIGHT FIX-A + soft watches

**LIGHT FIX-A 1 (Q1 bloom filter CREATE-vs-ALTER reconcile)**:
- **r03 §474 lever 4 row**: split "DDL / Trino syntax" column into NEW-table-on-467-NATIVE (CREATE TABLE WITH parquet_bloom_filter_columns), EXISTING-table-on-467 (Trino CTAS rebuild + rename swap OR Spark TBLPROPERTIES + rewrite), EXISTING-table-on-469+ (ALTER SET PROPERTIES + EXECUTE optimize).
- **r03 §491-§501** worked example: add Trino-native CTAS form alongside the existing Spark form.
- **r18 §1251 5th row**: split into two rows — CREATE TABLE form (YES on 467) vs ALTER SET PROPERTIES form (NO on 467, 469+ only).
- **r18 §1259 callout prose**: re-scope "Write-side configuration via `parquet_bloom_filter_columns` table property (TRINO 469+)" → "Write-side ALTER SET PROPERTIES form (TRINO 469+)" — keep the CREATE-TABLE-WITH form for 467 NATIVE.
- **r18 §1351 DO-NOT-RECOMMEND row**: keep the ban on ALTER SET PROPERTIES on 467 (correct), but reword so it does NOT imply the entire property is 469+.

**LIGHT FIX-A 2 (Q3 dbt tags definition + selection clarity)**:
- **r27 §6.7F** (BEFORE existing §3855-§3867 selector-operators table): new leading canonical "Where dbt tags are DEFINED and what `tag:X` actually selects" — 3-location DEFINITION table (config(tags=[]) in .sql, schema.yml config: tags:, dbt_project.yml +tags:) + leading sentence "`tag:X` selects ONLY tagged nodes; `+tag:X` adds upstream parents, `tag:X+` adds downstream children, `@tag:X` adds both" + DO-NOT-WRITE row defanging the "tag:X pulls full DAG" myth.
- Cross-link to §3855-§3867 (selector OPERATORS) so engineer reaches both tag-definition and selector-operators from the same neighborhood.

**Soft watches new this iter**:
- `iter1254 Q1 parquet_bloom_filter_columns CREATE-on-467-vs-ALTER-on-469 r03 §474 + r18 §1251 reconcile FIX-A` (re-probe 4-8 iters under "Trino 467 bloom filter on existing table" / "enable bloom filter without Spark" framings).
- `iter1254 Q3 tag:X-doesn't-pull-deps + tag-DEFINITION-locations r27 §6.7F LIGHT FIX-A` (re-probe 4-8 iters under "dbt tags hourly vs nightly scheduling" / "tag:X selects only or with deps" framings).
- `iter1254 Q2 YoY per-customer-vs-per-month-total granularity misread + single-scan-FILTER alternative not surfaced` (re-probe under "month-level total YoY no customer dimension" framings 4-8 iters; recall-ceiling, NO FIX-A).

**Watches closing**:
- (none directly closed this iter; iter1253 Q4 regexp_extract recall-variance still soft-watched, did not recur this iter as no regex question asked.)

**Open watches carry-forward**:
- iter1253 Q4 regexp_extract-2arg-whole-match misrecall (no re-probe this iter).
- iter1253 Q2 first-order-cohort same-day-tie (no re-probe this iter; Q2 this iter is YoY not first-order cohort).
- iter1249 dbt-snapshot recall-variance — CLOSED iter1253 (still holding).
- iter1248 opener-coherence + MATCH_RECOGNIZE-adjacency; iter1241 concat-auto-coerces; iter1239 DF-wait-timeout; iter1238 broadcast-hedge; iter1236 rn=1-within-batch; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING; iter1229 @v1-Spark; iter1223 packages.yml + Oracle-matches-Trino-GREATEST-NULL; iter1222 CAST-DECIMAL-money + TRY_CAST-dirty-staging; iter1219 CoW-MoR + format-%08d; iter1221 quarterly-window-vs-transform; iter1210 r27 §663 :: cast operator slip; iter1208 dbt exposures selector direction.

---

## Pattern observation

After a long sustainment band (iter1247-1253 averaging ~4.5+ with mostly NO-OP or 1st-re-probe-CLOSE), this iter surfaces TWO resource-sourced defects on the same cycle. Both fit the teacher's pre-grep flags exactly. Neither is a responder synthesis ceiling per `feedback_synthesis_ceiling_stop_churning.md` — the responder reached the closest existing canonical and lifted its over-broad framing (Q1 r18 §1259) or its incomplete coverage (Q3 r27 §6.7F has selector-operators but not definitions or no-auto-deps fact).

The Q1 issue is a recurrence of the `reference_trino_parquet_bloom_filter_469.md` iter1173 nuance that never made it from the pin into the load-bearing canonical: the pin says "CREATE on 467 OK, only ALTER is 469+" but r03 §474 and r18 §1251-§1259 still teach the over-broad "469+ only" version. This is the 2nd time (after iter1173 itself) this exact direction has surfaced — reconcile-in-place across both files now warranted.

The Q3 issue is a genuine content gap: r27 covers tag-SELECTOR-OPERATORS (comma vs space) thoroughly but never defines (a) where tags LIVE or (b) the no-auto-deps fact. Engineer's exact "does tag:critical pull the full DAG?" worry is exactly the gap.

Q2 is a per-instance question-misread (cohort vs total granularity); no resource fix.

Q4 is clean.

Training in closing window — deadline 2026-06-30 23:59 CST (~30 hours remaining at iter1254 timestamp). The two LIGHT FIX-A are surgical reconciles, both fit comfortably within the closing window and address real resource defects rather than discretionary additive churn. Recommend teacher proceed with both FIX-A. After fixes land, re-probe both directions in next 2-3 iters to confirm closure.

Iter average 3.8125 = MARGIN +0.3125 over 3.5 threshold. This is the THINNEST iter since iter1156 (3.656) and iter1176 (3.71875). The thinness is concentrated in Q3 (2.75 — load-bearing contradiction) + Q1 (3.5 — over-broad version cutoff); Q2 + Q4 are clean. Watch the next iter for whether the Q1+Q3 FIX-A closes both directions on first re-probe (the historical 1st-re-probe-CLOSE pattern has held 27 consecutive iters as of iter1252).
