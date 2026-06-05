# Iter 504 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.0938 PASS — FEDERATION NOT PROBED

- Q1 UNNEST NULL/empty array re-probe: **5.000 STRONG PASS** — ITER503 §1a FIX LANDED.
- Q2 Trino dynamic filtering on by default?: **3.875 PASS** — load-bearing nuance overstatement on stats dependency.
- Q3 Iceberg partition evolution metadata-only: **4.875 STRONG PASS** — Trino-vs-Spark rewrite split nailed.
- Q4 dbt unit tests (mock input / expected output): **2.625 FAIL** — content gap; responder PUNTED HONESTLY without fabricating, but engineer leaves empty-handed.

**OVERALL AVG = (5.000 + 3.875 + 4.875 + 2.625) / 4 = 16.375 / 4 = 4.0938** (PASS, +0.5938 above 3.5 floor; Q4 FAIL drags ~0.7, but Q1 STRONG PASS + Q3 STRONG PASS keep iter comfortably above floor.) 103rd consecutive overall PASS in extended phase.

---

## Q1 — UNNEST keeps users with NULL/empty `tags`: **5.000 STRONG PASS**

**Dimensions**: Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 5.0.

**ITER503 §1a FIX EXPLICITLY LANDED.** The iter504 teacher's NEW canonical Section 1a in `resources/07-analytical-query-patterns.md` (inserted between §1 and §2 with the FORM-1-CROSS / FORM-2-LEFT contrast + "ON TRUE is the only supported condition" note + keyword-anchor coverage on "explode array Trino / LEFT JOIN UNNEST / preserve NULL array rows / keep empty array rows") ROUTED THE RESPONDER CORRECTLY ON FIRST TRY.

Verified against trino.io/docs/current/sql/select.html UNNEST section:

- `CROSS JOIN UNNEST(arr) AS t(elem)` semantically an inner join → drops parent rows whose array is NULL/empty. CONFIRMED.
- `LEFT JOIN UNNEST(arr) AS t(elem) ON TRUE` preserves parent + emits NULL elem when array is NULL/empty. CONFIRMED verbatim: "LEFT JOIN is preferable in order to avoid losing the row containing the array/map field in question when referenced columns from relations on the left side of the join can be empty or have NULL values."
- "ON TRUE is the only supported LEFT JOIN UNNEST condition" CONFIRMED verbatim from docs: "When using LEFT JOIN, the only condition supported by the current implementation is ON TRUE."

Responder also gave the correct rule-of-thumb routing: LEFT for "including untagged users," CROSS for "only tagged." Zero fabs, zero ambiguity. **This is the 12th leading-canonical bulletproofing instance in extended phase, and the 5th findability/canonical addition fix to land cleanly on its re-probe.**

---

## Q2 — Trino dynamic filtering automatic or configured?: **3.875 PASS**

**Dimensions**: Accuracy 3.0, Clarity 4.5, Actionability 4.0, Completeness 4.0.

**Correct parts (verified at trino.io/docs/current/admin/dynamic-filtering.html):**

- Dynamic filtering ON by default in Trino 467 (`enable-dynamic-filtering`/`dynamic_filtering` session both default true). CONFIRMED.
- EXPLAIN shows `dynamicFilter(...)` annotation on the probe-side scan. CONFIRMED.
- Helps fact–dim joins where the dim is filtered by WHERE; reduces Iceberg files opened (partition pruning + file-skipping via DF predicate). CONFIRMED.
- Bare `ANALYZE iceberg.db.users` form (no TABLE keyword) is the correct Trino dialect. CONFIRMED (Spark/Hive use `ANALYZE TABLE`; Trino does not).

**LOAD-BEARING NUANCE OVERSTATEMENT (-1.0 Accuracy, -0.5 Completeness):**

> "If it's not showing up in EXPLAIN: ensure the small table has statistics... The optimizer won't use dynamic filtering without cardinality estimates."

This is **overstated and partially wrong**. Per trino.io/docs/current/admin/dynamic-filtering.html and PR #2793:

- Dynamic filtering is **fundamentally a runtime mechanism**: the build side collects join-key values during execution and pushes them as a predicate to the probe-side scan. It works for broadcast joins **regardless of whether ANALYZE has been run**.
- Statistics influence the COST-BASED OPTIMIZER's join-distribution and join-order decisions (whether the build side is the smaller table at all). Stats can therefore affect HOW EFFECTIVE DF is (a backwards build/probe ordering produces useless filters).
- But stats are **NOT a precondition for `dynamicFilter(...)` to appear in EXPLAIN** — the planner inserts the DF node based on join shape, not on the presence of NDV/row-count statistics. The Trino docs phrase it as "it is recommended to keep table statistics up to date and rely on the CBO to correctly choose the smaller table on the build side" — RECOMMENDED, not REQUIRED for DF itself.

**Correct phrasing for the canonical**: "If `dynamicFilter(...)` isn't appearing in EXPLAIN, common causes are: (a) the join distribution is PARTITIONED rather than BROADCAST and DF coverage is narrower; (b) the join type/condition isn't DF-eligible (inner / right / semi with equi-predicates supported; left outer / non-equi much more limited); (c) the connector hasn't pushed DF down. Running ANALYZE helps the CBO put the SMALL table on the build side, which is what makes DF actually selective — but ANALYZE is not a precondition for DF nodes to appear." The responder's phrasing conflates "DF is on but ineffective" with "DF is not on."

This is a load-bearing nuance because an engineer following the responder's advice would (a) run ANALYZE (harmless), then (b) be confused when EXPLAIN still shows no `dynamicFilter` annotation despite stats existing (often because of join-distribution / non-eligible-join-shape reasons that ANALYZE doesn't address).

---

## Q3 — Iceberg partition evolution add account_id (metadata-only): **4.875 STRONG PASS**

**Dimensions**: Accuracy 5.0, Clarity 4.75, Actionability 5.0, Completeness 4.75.

Verified against trino.io/docs/current/connector/iceberg.html + iceberg.apache.org:

- `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'bucket(account_id, 64)']` is the correct Trino 467 syntax and is metadata-only (instant). CONFIRMED.
- Old files retain their previous spec_id; queries read across both specs transparently. CONFIRMED via Iceberg spec evolution semantics + Trino docs ("can still query data created before the partitioning change").
- Old files do NOT get new pruning until rewritten under the new spec. CONFIRMED.
- **Trino 467 has NO `rewrite_data_files` procedure** — only Spark has `CALL system.rewrite_data_files(...)`. CONFIRMED at trino.io/docs/current/connector/iceberg.html — supported procedures are `register_table`, `unregister_table`, `migrate`, `add_files_from_table`, `add_files` (NOT `rewrite_data_files`).
- **`ALTER TABLE ... EXECUTE optimize` compacts files but does NOT re-stamp the partition spec.** CONFIRMED verbatim from Trino docs: "is used for rewriting the content of the specified table so that it is merged into fewer but larger files... acts separately on each partition." The optimize command does file-level compaction, not partition-spec migration — files compacted by optimize keep their original spec_id. **The responder correctly flagged this as a Trino-vs-Spark capability gap** and routed the engineer to Spark for the rewrite step. This is exactly the kind of dialect/engine boundary the SaaS engineer needs to know about up front.
- `"events$files"` metadata table exposes `spec_id` for verification GROUP BY. CONFIRMED.
- `expire_snapshots` cleanup mentioned as appropriate next step. CONFIRMED relevant.

**Minor -0.25 Completeness**: did not mention that Spark and Trino must share the same Hive Metastore + MinIO bucket for the Spark `rewrite_data_files` step to be visible to subsequent Trino queries (a prod-environment gotcha given on-prem k8s + HMS + MinIO stack). Non-load-bearing.

---

## Q4 — dbt unit tests with mock input data: **2.625 FAIL**

**Dimensions**: Accuracy 4.0, Clarity 3.0, Actionability 1.5, Completeness 2.0.

**Honest punt; ZERO fabrication.** Responder explicitly said "I don't have enough information in the resources," correctly distinguished dbt data tests (post-materialization assertions like `not_null`/`unique`/`relationships`/`expression_is_true`) from dbt UNIT TESTS (compile-time mock input + expected output verification of model SQL logic), and pointed the engineer at official docs. This honest-not-fabricated behavior is CORRECT — per the iter497-class scoring guidance, an honest punt is far better than a confident fab, and warrants partial Accuracy credit.

**BUT** the engineer asked a real question and walked away empty-handed. Completeness and Actionability legitimately low.

**GREP-CONFIRMED CONTENT GAP** (`grep -rni 'unit_tests\|unit tests' resources/` → ZERO matches). The dbt unit-test mechanic is genuinely absent from resources/.

**Verified ground truth from docs.getdbt.com/docs/build/unit-tests + /reference/resource-properties/unit-tests:**

- Available from dbt 1.8+ (or "Latest" release track).
- YAML schema lives in a `models/.../schema.yml` (or dedicated `unit_tests.yml`) file with top-level `unit_tests:` key.
- Per-test fields: `name`, `description` (optional), `model` (the target model under test), `given:` (list of input mock rows per `ref()` or `source()`), `expect:` (expected output rows).
- Each `given` entry: `input: ref('upstream_model')`, `format: dict | csv | sql` (dict default), `rows:` (list of dict literals) OR `fixture: filename` pointing to `tests/fixtures/*.{csv,sql}`.
- `expect:` follows the same `format` / `rows` / `fixture` shape.
- You only specify the COLUMNS RELEVANT TO THE TEST — unspecified columns default to NULL in the mock input.
- Triggered at build time by `dbt test --select test_type:unit` or `dbt build`; runs against a SAMPLE in the warehouse (CTE-substitution), NOT against real upstream tables.
- DISTINCT from dbt data tests (which run AFTER materialization and assert properties of the warehouse output).

### Iter505 teacher action — ADD a dbt-unit-tests canonical (HIGH PRIORITY)

Add a new canonical section, likely in `resources/27-oracle-plsql-to-dbt-trino.md` §6.8 or as a new `resources/09-lakehouse-schema-design.md` dbt-testing subsection (whichever has the strongest dbt-test keyword neighborhood — leans toward r27 §6.7-area where existing dbt-test content lives). Content needs:

1. **Findability anchor** at top with keywords: "dbt unit test / unit_tests YAML / given expect mock rows / mock input dbt / dbt 1.8 unit test / verify dbt model logic with sample data / dbt fixture file / dbt test transformation logic / dbt unit_tests vs data tests."
2. **Worked YAML example** (`unit_tests:` block with `name`, `model`, `given` with two inputs using `format: dict` + inline `rows:`, `expect` with `format: dict` + inline `rows:`) on a realistic SaaS-engineer model (e.g., revenue allocation by tenant).
3. **DO-NOT-CONFUSE callout** explicitly contrasting:
   - **Unit tests** (compile-time, mock input + expected output, verify SQL LOGIC, no warehouse data dependency).
   - **Data tests** (`not_null`/`unique`/`relationships`/custom singular tests + generic tests, post-materialization, assert properties of WAREHOUSE OUTPUT).
4. **Run command**: `dbt test --select test_type:unit`, `dbt build` (which runs unit tests + data tests), `dbt-trino` adapter compatibility note (unit tests are dbt-core-level, work with dbt-trino as long as >=1.8).
5. **Fixture file option** for larger mock inputs: `tests/fixtures/upstream_seed.csv` referenced via `fixture: upstream_seed`.
6. **Cite docs.getdbt.com/docs/build/unit-tests** for primary doc reference.

This is a NEW canonical (not a reconcile-in-place — there's no existing dbt-unit-test block to fix). Risk: keep it tight (<=30 lines) and avoid bleeding into data-test content (which already has multiple canonicals in r09/r13/r27).

---

## ITER505 PROBE TARGETS (in priority order)

1. **HIGH — dbt unit tests re-probe**: e.g., "I have a model that joins orders to refunds and computes net_revenue; I want to verify the join logic against three input rows. Does dbt support that, and where do I put the YAML?" — verifies the new canonical lands.
2. **HIGH — Dynamic filtering 2nd angle**: e.g., "EXPLAIN shows no dynamicFilter on my fact-dim join even though I ran ANALYZE on both tables; why?" — tests whether the Q2 nuance reconcile (stats-recommended-not-required + join-distribution + join-shape eligibility) routes correctly. This catches whether the teacher will fix the Q2 overstatement.
3. **MEDIUM — Iceberg partition evolution 2nd angle on Spark `rewrite_data_files`**: e.g., "What `rewrite-mode` / `where` filter do I pass to `rewrite_data_files` to only re-stamp partitions touched by today's writes?" — verifies the Spark-vs-Trino gap canonical holds and the responder defers to Spark not Trino.
4. **MEDIUM — UNNEST + ORDINALITY 3rd angle**: e.g., "I want the position of each tag in the original array preserved alongside the user_id" — tests `WITH ORDINALITY` clause coverage in the new §1a (this may need a teacher one-liner if it's missing).
5. **LOW — dbt unit tests fixture-file form**: 4th probe after #1 lands; tests `format: csv` + `fixture:` file reference.
6. **NOT THIS ITER** — federation row stays UNPROBED per iter472-504 directive + the iter504 task explicit constraint. 4.49944/310 row UNCHANGED.

---

## NO-OP / GUARDRAILS

- **DO NOT touch r22 §13.x federation guardrails** (66 §13.x refs preserved). Federation rubric row stays 4.49944/310.
- **DO NOT regress r07 §1a UNNEST canonical** (just landed iter504, do not add duplicate or contradict). Reconcile-in-place rule applies.
- **DO NOT regress r07 §5 Pattern B2 / §4 Time-series locked canonicals** (the iter504 §1a cross-ref note correctly clarifies they don't need preserve-rows fix because sequence() never returns NULL/empty).
- **DO NOT regress iter500 r09 dbt-snapshot Findability anchor / iter502 r27 §6.7D dbt-build-runs-seeds / iter503 r13 on_schema_change Findability + r27 §4.5A md5/surrogate-key reconcile.**

---

## TOPIC AVG UPDATES

- **Common analytical query patterns** (Q1 UNNEST array-explode canonical maps to r07 §1a → r07 is "Common analytical query patterns" topic): 4.645/10 → (4.645*10 + 5.0)/11 = 51.45/11 = **4.6773/11** (+0.0323).
- **Improving complex SQL performance on Trino with dbt** (Q2 dynamic filtering = Trino perf lever): 4.6158/15 → (4.6158*15 + 3.875)/16 = 73.112/16 = **4.5695/16** (-0.0463 — Q2 nuance overstatement drags but still PASS).
- **Iceberg partition design for SaaS: strategies, small-files, compaction** (Q3 partition evolution maps here): 4.4947/36 → (4.4947*36 + 4.875)/37 = 166.6842/37 = **4.5050/37** (+0.0103).
- **Improving complex SQL performance on Trino with dbt** (Q4 dbt unit tests also maps to dbt-testing perf-validation topic): already-updated row (4.5695/16) → (4.5695*16 + 2.625)/17 = 75.737/17 = **4.4551/17** (-0.1144 — Q4 FAIL drags noticeably but stays above 3.5 floor).
- **Federation**: NOT PROBED — **4.49944/310 row UNCHANGED.**

---

## SCORE LINE (appended to rubric.md score history)

```
### Iter 504 — 2026-06-06 (EXTENDED PHASE) — 4.0938 PASS overall — FEDERATION NOT PROBED — Q1 UNNEST §1a FIX LANDED + Q4 dbt-unit-tests CONTENT GAP confirmed.
```

Full long-form score line appended to training/rubric.md score history below.
