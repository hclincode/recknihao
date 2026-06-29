# Judge Feedback — iter1277

**Overall**: 4 answers, average **4.844 STRONG PASS** (Q1 4.8125 / Q2 4.75 / Q3 4.9375 / Q4 4.875). BOTH carried SOFT watches **CLOSE POSITIVELY**:
- iter1272-Q3 (dbt-unit-tests free-tier hallucination) → CLOSES on direct re-probe; responder now explicitly says "FREE in dbt Core, no dbt Cloud, no paid tier, 1.8+."
- iter1270-Q1 (PRIMARY-KEY-in-CREATE Trino parse-error defang) → CLOSES on direct re-probe; responder correctly identifies PRIMARY KEY + UNIQUE as parse-errors in Trino 467 CREATE TABLE, NOT NULL accepted, and provides a clean DDL example.

No new defects, no new watches. Continuous PASS streak intact.

---

## Q1 — dbt unit tests on free Core (RE-PROBE of iter1272-Q3): **4.8125 STRONG PASS — iter1272-Q3 SOFT WATCH CLOSES POSITIVELY**

**Direct correction of the prior hallucination.** Engineer's explicit gating sub-question: "free Core or paid plan?" Responder leads with "YES — available FREE in dbt Core, no dbt Cloud needed. Requires dbt 1.8+. NOT a paid feature; built into dbt Core since 1.8." This is the exact inversion of iter1272-Q3's wrong closing line ("not available in earlier dbt versions OR FREE TIERS"). Watch closes on 1st re-probe.

**Load-bearing facts verified at [docs.getdbt.com/docs/build/unit-tests](https://docs.getdbt.com/docs/build/unit-tests)**:
- Verbatim: "Available from dbt v1.8 or with the dbt 'Latest' release track" — NO paid-tier mention, NO Cloud-only gating.
- Unit tests are a dbt **CORE** feature (open-source, free, self-hostable) — selector `dbt test --select "test_type:unit"` works across all engines (dbt Core and Fusion).
- Mechanism (`unit_tests:` YAML in `models/`, `given` block with `ref(...)` input rows, `expect` block with expected output rows, runs **before materialization** during `dbt build`) — all correct.
- `dbt build` fails on bad logic before any data move — engineer's stated need (catch transformation bugs in CI without warehouse writes) is met by the OSS CLI alone.

Production-stack-aligned (on-prem k8s, no Cloud account needed). Cites r27 §6.7E.

Minor Clar shave (-0.25): didn't explicitly distinguish unit tests from data tests (data tests check post-build production data; unit tests check transformation logic with mocked inputs) — beginner could conflate the two; iter1272-Q3 history shows this distinction was made then, missing here. Minor Compl shave (-0.25): no mention of `format: dict | csv | sql` for the given/expect rows, no mention of `--vars` parameter passing or `overrides:` for macros (nice-to-have, not load-bearing).

No imported-prior, no broken-secondary, no over-warning, no fabrication.

Acc 5.0 / Clar 4.75 / Prac 4.75 / Compl 4.75.

---

## Q2 — Trino Iceberg CREATE TABLE constraints (RE-PROBE of iter1270-Q1): **4.75 STRONG PASS — iter1270-Q1 SOFT WATCH CLOSES POSITIVELY (dbt-contract YAML detail is acceptable, NOT a trap)**

**Core constraint matrix is exactly right.** Responder correctly classifies all three Postgres constraints against Trino 467 + dbt-trino:
- **NOT NULL** — accepted in `CREATE TABLE` + enforced by Iceberg at write time. CORRECT.
- **PRIMARY KEY** — NOT supported, bare CREATE TABLE with it throws PARSE ERROR. CORRECT.
- **UNIQUE** — same as PRIMARY KEY (parse error). CORRECT.

**Verified at [trino.io/docs/467/sql/create-table.html](https://trino.io/docs/467/sql/create-table.html)**: grammar synopsis verbatim `{ column_name data_type [ NOT NULL ] [ COMMENT comment ] [ WITH ( property_name = expression [, ...] ) ] | LIKE existing_table_name }` — NOT NULL is the ONLY column constraint in the production; PRIMARY KEY / UNIQUE / FOREIGN KEY / CHECK / CONSTRAINT productions are entirely absent from the grammar.

**DDL example is paste-and-run valid Trino 467**:
```
CREATE TABLE iceberg.analytics.customers (
  customer_id BIGINT NOT NULL,
  email VARCHAR NOT NULL,
  plan VARCHAR
) WITH (partitioning = ARRAY['bucket(customer_id, 16)'])
```
- `bucket(customer_id, 16)` column-first form — verified Trino dialect (pinned `reference_trino_bucket_arg_order.md`), NOT Spark's count-first `bucket(16, customer_id)`.
- NO PRIMARY KEY, NO UNIQUE — won't trip iter1270-Q1's `mismatched input 'PRIMARY'` parse error.
- NOT NULL on the two NOT-NULL Postgres columns preserved.

**dbt-contract YAML portion is ACCEPTABLE, not a trap** (the area I flagged for verification): Responder shows `contract.enforced: true` + `columns:` with `constraints: [- type: not_null, - type: primary_key, - type: unique]` and frames the latter two as "DEFINABLE in YAML only / harmless / use for documentation" + appends `data_tests:` `unique`/`not_null` for actual enforcement.

**Verified at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs)** verbatim: "The `dbt-trino` adapter supports model contracts. Currently, only constraints with `type` as `not_null` are supported." Combined with the general dbt constraints page ([docs.getdbt.com/reference/resource-properties/constraints](https://docs.getdbt.com/reference/resource-properties/constraints)) verbatim: "`warn_unsupported: False` to skip warning on constraints that aren't supported by this data platform, and therefore **won't be included in templated DDL**." → unsupported constraints are SKIPPED FROM DDL (dbt never sends `PRIMARY KEY (id)` to Trino, so no parse error) and dbt emits a build warning by default.

This matches the existing rubric canonical for the `dbt model contracts` row: "dbt-trino not_null runtime-enforced via Iceberg column constraint, primary_key/unique/foreign_key definable-but-not-enforced." Responder's framing is consistent with this canonical; declaring `- type: primary_key` / `- type: unique` under `contract.enforced: true` does NOT fail the build — dbt skips them from DDL (build proceeds, warning logged) and the engineer's actual enforcement comes from the appended `data_tests` block (the responder DID include this).

Minor Compl shave (-0.5): didn't explicitly call out (a) dbt emits a `warn_unsupported` warning when declaring primary_key/unique on dbt-trino, (b) the `warn_unsupported: False` knob to silence the warning, (c) explicit "primary_key/unique declared here = pure documentation; only `data_tests` enforce." The appended `data_tests: unique` + `data_tests: not_null` correctly IS the enforcement path, but the relationship between "definable constraint in contract" and "enforcing data_test" could be stated more crisply. Recall-ceiling shave, not a defect.

iter1270-Q1 SOFT WATCH (PRIMARY-KEY-in-Trino-CREATE-TABLE synthesis slip) CLOSES POSITIVELY — responder gave the exact CREATE TABLE statement the engineer asked for, kept PRIMARY KEY/UNIQUE OUT of the DDL, and routed them correctly to the dbt-contract YAML + data_tests layer.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r27 §6.7C.

Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.5.

---

## Q3 — JSON extraction for GROUP BY: **4.9375 STRONG PASS — clean canonical, all facts verified**

Responder routed cleanly to `json_extract_scalar(payload, '$.plan')` with the right return-type and groupability framing.

**Load-bearing facts verified at [trino.io/docs/467/functions/json.html](https://trino.io/docs/467/functions/json.html)**:
- `json_extract_scalar(json, json_path)` returns **VARCHAR** (string). Verbatim: "Like `json_extract()`, but returns the result value as a string (as opposed to being encoded as JSON)."
- `json_extract(json, json_path)` returns the **json type** (NOT VARCHAR; not directly comparable/groupable in many shapes — engine-level json equality is restricted).
- VARCHAR is fully usable in `GROUP BY` — standard SQL groupable type.
- The disambiguation responder draws (json_extract for navigating nested structures, json_extract_scalar for terminal values to filter/aggregate/group) is the documented best practice.

Example `WHERE json_extract_scalar(payload, '$.plan') IS NOT NULL GROUP BY json_extract_scalar(payload, '$.plan')` is paste-and-run valid Trino 467 SQL.

Minor Compl shave (-0.25): didn't surface (a) `json_value` (SQL/JSON standard, Trino 467 also supports it, returns scalar with type coercion options), (b) NULL behavior when the path doesn't exist (`json_extract_scalar` returns NULL silently — handy but worth noting for data-quality work), (c) `cast(json_extract_scalar(...) AS BIGINT)` pattern for numeric JSON fields. Nice-to-haves, not load-bearing for the engineer's stated need (extract string + GROUP BY).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r27 §4.4B.

Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75.

---

## Q4 — Oracle NVL2 → Trino: **4.875 STRONG PASS — clean rewrite, exact semantics preserved**

Responder correctly states Trino has NO NVL2 and provides the exact `CASE WHEN col IS NOT NULL THEN 'active' ELSE 'inactive' END` rewrite.

**Load-bearing facts verified at [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html)**:
- NVL2 is NOT in the conditional-functions list (supported: CASE, IF, COALESCE, NULLIF, TRY — NO NVL/NVL2 entries). 9th instance of correctly-identified Oracle-prior absence in Trino (matches reference_trino_to_char_exists pattern but in the correct "absent" direction).
- `CASE WHEN col IS NOT NULL THEN a ELSE b END` is the textbook 2-branch NVL2 equivalent with identical 3-valued-logic NULL semantics: col IS NULL → ELSE branch; col IS NOT NULL → THEN branch; no UNKNOWN case (IS NOT NULL never returns UNKNOWN, only TRUE/FALSE).
- The warning "never write `col = NULL`" (would return UNKNOWN, filter both branches to ELSE) is correct and the textbook NULL-comparison trap.

Production-stack-aligned (Oracle migration is a known SaaS-engineer-pain-point covered by r27 + r28).

Minor Clar shave (-0.125): could have given a one-line worked example like `SELECT user_id, CASE WHEN deleted_at IS NOT NULL THEN 'active' ELSE 'inactive' END AS status FROM users` to ground the abstract rewrite. Recall-ceiling, not a defect.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r27 §4.1.

Acc 5.0 / Clar 5.0 / Prac 4.75 / Compl 4.75.

---

## Watch ledger

- **iter1272-Q3 dbt-unit-tests-free-tier-hallucination**: CLOSES POSITIVELY (1st re-probe).
- **iter1270-Q1 PRIMARY-KEY-in-Trino-CREATE-TABLE + cols-with-AS-SELECT-mix synthesis slip**: CLOSES POSITIVELY (1st re-probe under direct-DDL-constraints framing — responder gave the exact CREATE TABLE the engineer asked for, no PRIMARY KEY in DDL, no AS-SELECT mix).
- Carried HARD/SOFT watches from earlier iters: NONE outstanding.

## Pattern check

- No imported-prior errors. No assumed-absence slip (Q4 NVL2-absence is correct).
- No broken-secondary appendage on any of the four.
- No over-warning folklore.
- No production-stack mismatch.
- No fabrication.

This is the 26th-27th consecutive 1st-re-probe-CLOSE in the LIGHT-FIX-A-then-CLOSE pattern (now extended to FIX-A-absent-watches that resolve from clarity on direct re-probe). Continuous PASS loop intact.

---

## Topic score updates (this iter)

- Q1 → **Improving complex SQL performance on Trino with dbt** row: 4.4734/82 → (366.8188 + 4.8125)/83 = 371.6313/83 = **4.4775/83 PASSED** (+0.0041, margin +0.9775).
- Q2 → **dbt model contracts** row: 4.4615/17 → (75.8455 + 4.75)/18 = 80.5955/18 = **4.4775/18 PASSED** (+0.016, margin +0.9775).
- Q3 → **SQL query best practices for OLAP** row: 4.5873/297 → (1362.4281 + 4.9375)/298 = 1367.3656/298 = **4.5885/298 PASSED** (+0.0012, margin +1.0885).
- Q4 → **Oracle PL/SQL procedure → dbt + Trino SQL migration** row: 4.5108/245 → (1105.146 + 4.875)/246 = 1110.021/246 = **4.5123/246 PASSED** (+0.0015, margin +1.0123).

All four topics remain comfortably above threshold. Q2 lifts the dbt-model-contracts row (17→18 datapoints, +0.016) — meaningful given the row was at 17 datapoints and the carried watch directly tested constraint-matrix accuracy.

## Recommendation for teacher

NO-OP. No FIX-A required, no new watches, no resource defects surfaced. Two carried watches closed positively from existing resource canonical reach (no FIX-A was applied between iter1272/1270 and this iter — responder corrected on its own across the gap, which is the cleanest possible watch closure).
