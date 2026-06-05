# Judge Feedback — Iter 488

**Phase**: extended (end-of-iteration feedback only)
**Overall**: 4.344 PASS (~0.844 above 3.5 floor; -0.39 below iter487's 4.7344 STRONG PASS)
**Federation**: NOT probed this iter — 4.49944/310 row HELD per iter472-488+ directive

---

## Headline

**Q3 dbt test severity/store_failures failed with two confirmed fabrications.** Q1, Q2, and Q4 are all STRONG PASS with zero fabs. The Q3 drag (2.75 avg) pulled the overall from what would have been a 4.875 STRONG PASS down to a thin 4.344 PASS.

Both suspicions from the task prompt are CONFIRMED by WebSearch + WebFetch:
- SUSPICION A CONFIRMED: `dbt_utils.expression_is_true` is row-level only. Using it with an aggregate expression (`COUNT(*) FILTER (WHERE ...) / COUNT(*) < 0.05`) generates `SELECT ... FROM model WHERE NOT (COUNT(*) FILTER (WHERE ...) / COUNT(*) < 0.05)` — a SQL error at runtime because aggregate functions cannot appear in WHERE clauses without GROUP BY + HAVING.
- SUSPICION B CONFIRMED: The responder cited `dbt_internal.<model>_<test>` as the failure schema — this is fabricated. The correct default is `<target_schema>_dbt_test__audit` per docs.getdbt.com/reference/resource-configs/store_failures. `dbt_internal` does not exist in dbt's store_failures implementation.

---

## Per-question breakdown

### Q1 — OLAP vs OLTP / Postgres slow for analytics (4.875 STRONG PASS)
- **Accuracy 5.0** — row-oriented reads-all-columns tax (10-50x) correct characterization; WAL lag + OLTP contention on analytics-on-replica correct; tuning checklist all valid: partial indexes, materialized views, EXPLAIN ANALYZE Seq Scan, pg_partman (CONFIRMED real: github.com/pgpartman/pg_partman — active PostgreSQL extension for partition management), PgBouncer. Move to Trino+Iceberg only when checklist is exhausted — operationally sound.
- **Clarity 4.75** — zero assumed OLAP knowledge; Seq Scan, WAL lag explained in engineer-friendly terms.
- **Actionability 5.0** — specific ordered checklist: try these first, measure, then escalate to Trino+Iceberg. Engineer knows exactly what to do next.
- **Completeness 4.75** — covers row-oriented cost, operational interference, tuning-first discipline, and migration trigger threshold.
- **Fab status**: ZERO fabs.

### Q2 — NOT IN with NULLs → zero rows (4.875 STRONG PASS)
- **Accuracy 5.0** — three-valued logic (UNKNOWN propagation from NULL in NOT IN list → WHERE filters all rows) textbook correct; NOT EXISTS fix (TRUE/FALSE only, NULLs ignored, Trino optimizes to anti-join) correct; LEFT JOIN ... IS NULL correct; "never use NOT IN on a nullable subquery column" is the right rule.
- **Clarity 4.75** — three-valued logic explained without assumed SQL-internals knowledge; example walkthrough makes the NULL → UNKNOWN → zero-rows chain concrete.
- **Actionability 5.0** — two concrete alternative patterns given; engineer can paste and run.
- **Completeness 4.75** — covers why zero rows, two fix patterns, and the governing rule.
- **Fab status**: ZERO fabs.

### Q3 — dbt test severity:warn + store_failures:true (2.75 FAIL)
- **Accuracy 2.0** — two confirmed fabrications/misuses drag accuracy to 2.0 despite correct identification of `severity: warn` and `store_failures: true` as real configs:
  - FAB-A (aggregate-in-row-level-test MISUSE): `dbt_utils.expression_is_true: expression: "COUNT(*) FILTER (WHERE discount_pct IS NULL)/COUNT(*) < 0.05"` is a SQL error at runtime. Confirmed via WebFetch of github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/expression_is_true.sql — the macro generates `SELECT ... FROM model WHERE NOT (expression)`. COUNT is an aggregate function; placing it in a WHERE clause without GROUP BY + HAVING is invalid SQL. The correct purpose-built macro for this use case is `dbt_utils.not_null_proportion: at_least: 0.95`, which computes `sum(case when col is null then 0 else 1 end) / count(*)` at the aggregate level. Confirmed real via github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/not_null_proportion.sql.
  - FAB-B (fabricated schema name): `dbt_internal.<model>_<test>` — `dbt_internal` does not exist in dbt's store_failures implementation. Confirmed via WebFetch of docs.getdbt.com/reference/resource-configs/store_failures: default schema is `<target_schema>_dbt_test__audit` (e.g., `dev_username_dbt_test__audit`). Configurable via `+schema:` in `dbt_project.yml` under `data_tests:`.
- **Clarity 3.5** — the conceptual explanation of severity:warn and store_failures:true is clear, but the example code would confuse any engineer who tries to run it.
- **Actionability 2.0** — paste-and-fail on two counts: (1) aggregate expression_is_true → SQL execution error; (2) `dbt_internal` schema doesn't exist → engineer looks in wrong place for failure rows.
- **Completeness 3.5** — covers severity:warn, store_failures:true configs (real); purpose (log+continue, persist failure rows) correct conceptually. Missing: correct macro (`not_null_proportion`) and correct schema name (`_dbt_test__audit`).
- **Fab status**: TWO confirmed fabrications — expression_is_true aggregate misuse (class: wrong-test-type / aggregate-in-row-level-test) + fabricated-schema-name (`dbt_internal`).

### Q4 — Subtotals + grand total one query: GROUPING SETS / ROLLUP / GROUPING() (4.875 STRONG PASS)
- **Accuracy 5.0** — `GROUP BY GROUPING SETS ((region,product_line),(region),())` valid Trino SQL, CONFIRMED via WebFetch trino.io/docs/current/sql/select.html; `ROLLUP(region,product_line)` = those exact 3 grouping sets CONFIRMED correct (Trino doc: "ROLLUP(a,b) is equivalent to GROUPING SETS ((a,b),(a),())"); GROUPING() function for level-detection (returns bit-set decimal; 0 if column included in grouping, 1 if excluded) CONFIRMED real Trino feature; NULL-in-subtotal-column meaning "this is an aggregate row" correct.
- **Clarity 4.75** — explains GROUPING SETS without assumed knowledge; ROLLUP as shorthand is explained clearly; GROUPING() level detection is concrete.
- **Actionability 5.0** — paste-and-run SQL for the exact use case; ROLLUP shorthand reduces YAML line count.
- **Completeness 4.75** — covers GROUPING SETS, ROLLUP shorthand, GROUPING() level detection, NULL semantics for subtotals.
- **Fab status**: ZERO fabs.

---

## Overall score

| Q | Topic | Acc | Clarity | Action | Complete | Avg |
|---|---|---|---|---|---|---|
| Q1 | OLAP vs OLTP / Postgres slow | 5.0 | 4.75 | 5.0 | 4.75 | 4.875 |
| Q2 | NOT IN + NULLs anti-join | 5.0 | 4.75 | 5.0 | 4.75 | 4.875 |
| Q3 | dbt test severity + store_failures | 2.0 | 3.5 | 2.0 | 3.5 | 2.75 |
| Q4 | GROUPING SETS / ROLLUP / GROUPING() | 5.0 | 4.75 | 5.0 | 4.75 | 4.875 |
| **Overall** | | **4.25** | **4.4375** | **4.25** | **4.4375** | **4.344** |

**PASS** (4.344 > 3.5, margin +0.844)

---

## Fabrications / misuses inventory (iter488)

| # | Q | Class | Severity | Correct fact | Source |
|---|---|---|---|---|---|
| 1 | Q3 | aggregate-in-row-level-test (MISUSE) | LOAD-BEARING — SQL error at runtime | `expression_is_true` generates `WHERE NOT (expression)` — aggregate functions illegal in WHERE; use `dbt_utils.not_null_proportion: at_least: 0.95` for null-proportion threshold | github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/expression_is_true.sql + not_null_proportion.sql |
| 2 | Q3 | fabricated-schema-name | LOAD-BEARING — engineer looks in wrong schema | Default store_failures schema is `<target_schema>_dbt_test__audit` (suffix `_dbt_test__audit`); no `dbt_internal` schema in dbt | docs.getdbt.com/reference/resource-configs/store_failures |

Q1, Q2, Q4: ZERO fabrications.

---

## Topic average updates

| Topic | Before | After | Delta |
|---|---|---|---|
| When to add an OLAP layer vs staying on the transactional DB (Q1) | 4.458/14 | **4.4858/15** | +0.0278 |
| SQL query best practices for OLAP (Q2 NOT IN trap + Q3 dbt test misuse) | 4.5556/51 | **4.5275/53** | -0.0281 |
| Analytical query patterns on Iceberg+Trino (Q4 GROUPING SETS / ROLLUP) | 4.4872/14 | **4.5131/15** | +0.0259 |
| Trino federation / cross-source connectors | 4.49944/310 | **4.49944/310 UNCHANGED** | NOT PROBED |

---

## Teacher actions for iter489

### PRIMARY — SURGICAL FIX in dbt testing resource (wherever dbt test configs are documented, likely r27 or a dedicated dbt testing card)

**Fix 1: expression_is_true vs not_null_proportion disambiguation**

Install a LEADING CANONICAL card with:
- Clear statement: "`dbt_utils.expression_is_true` is a ROW-LEVEL test. It generates `SELECT 1 FROM model WHERE NOT (your_expression)`. You CANNOT use aggregate functions (COUNT, SUM, AVG) in the expression — that is a SQL error."
- The correct macro for null-proportion threshold: `dbt_utils.not_null_proportion: at_least: 0.95` (column-level test; computes `COUNT(non-null) / COUNT(*) >= 0.95` at the aggregate level).
- DO-NOT-WRITE rows:
  - `dbt_utils.expression_is_true: expression: "COUNT(*) FILTER (WHERE col IS NULL)/COUNT(*) < 0.05"` — WRONG, aggregate in row-level WHERE clause = SQL error.
  - `dbt_utils.expression_is_true: expression: "AVG(amount) > 0"` — WRONG, same class.
- Working example of the correct pattern: `- dbt_utils.not_null_proportion: at_least: 0.95` on a column config.
- Citation: github.com/dbt-labs/dbt-utils README section on `not_null_proportion`.

**Fix 2: store_failures schema name**

Install explicit LEADING CANONICAL statement:
- "When `store_failures: true`, dbt writes failure rows to `<your_target_schema>_dbt_test__audit`. For example, if your target schema is `analytics`, failures go to `analytics_dbt_test__audit`."
- DO-NOT-WRITE: `dbt_internal` is NOT a dbt schema — this name does not exist in dbt's store_failures implementation.
- Configure a custom suffix via `+schema: my_custom_suffix` under `data_tests:` in `dbt_project.yml`.
- Citation: docs.getdbt.com/reference/resource-configs/store_failures.

### SECONDARY — breadth design for iter489 (NO dedicated federation probe)

- Federation 4.49944/310 row HELD per iter472-488+ directive. DO NOT count any iter489 probe as a federation probe.
- Low-count topics worth additional datapoints:
  - dbt sources / source freshness (3, 4.219) — re-probe loaded_at_field + warn_after/error_after blocking semantics
  - dbt model contracts (3, 4.1146) — re-probe contract.enforced + not_null runtime-enforced via Iceberg
  - Storage tiering on Trino+Iceberg+MinIO (2, 4.25) — re-probe MinIO lifecycle `mc ilm tier add` recipe
  - dbt snapshots SCD2 (2, 4.5625) — re-probe dbt_valid_from/dbt_valid_to + check vs timestamp strategy
  - complex-SQL-perf-on-Trino-with-dbt (5, 4.785) — continue probing dbt materialization tuning
- Consider a re-probe on Q3 NOT IN + NULLs from a 2nd angle (e.g., LEFT JOIN IS NULL vs NOT EXISTS performance on Trino, or IN with NULLs symmetric behavior) to lock 2+ confirmations.

### Schedule note

5-min cadence — `delaySeconds=300`.

---

## Streak / margin status

- **87th consecutive overall PASS in extended phase.**
- Margin at 4.344 (THIN PASS) — +0.844 above 3.5 floor; -0.39 below iter487's 4.7344 STRONG PASS.
- Q3 2.75 FAIL dragged overall from what would have been a 4.875 STRONG PASS.
- **Two new fab classes logged**: expression_is_true-aggregate-misuse + fabricated-schema-name (`dbt_internal`).
- **Citation-hygiene status**: Q1, Q2, Q4 ZERO fab. Q3 two load-bearing fabs; neither is new in type (aggregate-misuse and name-fabrication are recurring patterns), but this is the first time they appeared on dbt test configs specifically.
- **Federation**: 4.49944/310 — 24th+ consecutive iteration with the row HELD per iter472-488+ directive. DO NOT probe federation in iter489.
