# Judge Feedback — Iter 471 (Extended Phase, End-of-Iteration)

**Date**: 2026-06-05
**Phase**: Extended (end-of-iteration feedback only)
**Overall**: **3.703125 THIN PASS** (70th consecutive extended-phase PASS — second-thinnest margin in months, only 0.015 above iter470)

**Verdict**: PASS, but only because Q2 (4.625) carried the iter. Two distinct load-bearing fabrications (Q1 `SET PARTITION SPEC`, Q3 `parse_date`) plus a Q4 content gap. Citation-hygiene streak BROKEN again — different fab classes than iter470 but still two confident-but-wrong load-bearing claims in one iter.

**Streak statuses**:
- **DROP COLUMN capability-fix streak: CONFIRMED HELD** (Q1 correctly says native on Trino 467, no Spark, metadata-only, 3-step reclamation; no `column_order` fab) — iter470 Q3 hard-fail correctly bandaged by the new r17 LEADING schema-evolution canonical.
- **$refs metadata-table fix streak: CONFIRMED HELD** (Q2 correctly uses `"orders$refs"` quoting, column `name` NOT `ref_name`, type='BRANCH', snapshot_id) — iter470 Q1 fab correctly bandaged by the new r17 LEADING $refs-vs-$snapshots canonical.

Both targeted fixes from iter471 teacher cycle landed cleanly. But two NEW fab classes surfaced.

---

## Per-question scores

| Q | Topic | Acc | Compl | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Iceberg DROP COLUMN + partition-evolution edge case | 3.5 | 4.0 | 4.25 | 3.25 | **3.75** | PASS |
| Q2 | $refs branch-snapshot lookup | 4.75 | 4.5 | 4.5 | 4.75 | **4.625** | STRONG PASS |
| Q3 | Oracle NVL / INSTR / TO_DATE → Trino | 3.0 | 4.0 | 4.25 | 2.75 | **3.5** | BORDERLINE PASS |
| Q4 | dbt model contracts (content gap) | 4.0 | 2.0 | 3.75 | 2.0 | **2.9375** | FAIL (content gap) |

**Overall avg**: (3.75 + 4.625 + 3.5 + 2.9375) / 4 = **3.703125** → PASS (≥3.5), barely.

---

## Per-question justification (1-2 lines each)

**Q1 — 3.75 PASS**: DROP COLUMN core CORRECT — native on Trino 467, no Spark required, metadata-only, 3-step reclamation (EXECUTE optimize → expire_snapshots → remove_orphan_files) all valid. `column_order` was NOT invented (capability-fix streak held). BUT the partition-key edge case `ALTER TABLE ... SET PARTITION SPEC (...)` is a **fabricated syntax** — that is Spark-dialect spillover. Trino 467 evolves Iceberg partitioning via `ALTER TABLE t SET PROPERTIES partitioning = ARRAY[...]`. Engineer running `SET PARTITION SPEC` gets parse error.

**Q2 — 4.625 STRONG PASS**: `"orders$refs"` whole-name-in-one-quote-pair quoting CORRECT. Column `name` (NOT `ref_name`, NOT `branch_name`) CORRECT. `type='BRANCH'` filter CORRECT. `snapshot_id` BIGINT CORRECT. List-all-branches helper query CORRECT. Substance directly answers the question; capability-fix from iter471 r17 LEADING $refs-vs-$snapshots canonical landed cleanly with no leaks.

**Q3 — 3.5 BORDERLINE PASS**: NVL→COALESCE, NVL2→CASE WHEN, INSTR→STRPOS (1-based, 0 if not found), TO_CHAR→date_format/format_datetime, empty-string-is-NULL Oracle quirk all CORRECT. `CAST(str AS DATE)` for ISO-formatted strings CORRECT. BUT **`parse_date(str, 'yyyy-MM-dd')` is a fabricated Trino function** — does not exist. Trino has `date_parse(string, format)` (MySQL specifiers like `%Y-%m-%d`, returns timestamp(3)) and `parse_datetime(string, format)` (Joda-style like `yyyy-MM-dd`, returns timestamp with time zone). For a DATE result the canonical forms are `CAST(date_parse(str, '%Y-%m-%d') AS DATE)` or `from_iso8601_date(str)` for ISO 8601 strings. Saved from hard-fail only by the larger set of correct mappings.

**Q4 — 2.9375 FAIL (content gap, NOT fabrication)**: Honest "I don't have enough information to answer this well." Per directive, treated as incompleteness, not as fabrication — and credited on accuracy because the responder declined to make things up. BUT this means we have an unmet question; completeness and actionability both fail. The dbt-sources topic is PASSED at 4.219/3 in the rubric but dbt **model contracts** is a distinct sub-feature (config: contract: {enforced: true} + columns: with name + data_type, fails the build on output column/type mismatch) and resources/ genuinely lacks coverage. NEW REQUIRED MICRO-TOPIC.

---

## Fabrications — full list with correct facts + source URLs

### Fab 1 (Q1) — `ALTER TABLE ... SET PARTITION SPEC (...)` is NOT valid Trino syntax

- **What the responder wrote**: `ALTER TABLE iceberg.analytics.events SET PARTITION SPEC (day(event_time))` (or similar) for the partition-key edge case.
- **Why it's wrong**: Trino's `ALTER TABLE` reference (trino.io/docs/current/sql/alter-table.html) does NOT list a `SET PARTITION SPEC` clause. The Iceberg connector docs (trino.io/docs/current/connector/iceberg.html) explicitly document partition evolution via `ALTER TABLE table_name SET PROPERTIES partitioning = ARRAY[<existing partition columns>, 'my_new_partition_column'];`. `SET PARTITION SPEC` is a Spark/other-dialect form (Spark Iceberg supports `ALTER TABLE ... REPLACE PARTITION FIELD` and `ADD PARTITION FIELD` instead).
- **Class**: cross-dialect spillover (Spark Iceberg DDL leaking into Trino answer).
- **Correct form**:
  ```sql
  ALTER TABLE iceberg.analytics.events
    SET PROPERTIES partitioning = ARRAY['day(event_time)'];
  ```
- **Source**: https://trino.io/docs/current/connector/iceberg.html (Schema and partition evolution section); https://trino.io/docs/current/sql/alter-table.html.

### Fab 2 (Q3) — `parse_date(string, format)` is NOT a Trino function

- **What the responder wrote**: `parse_date(str, 'yyyy-MM-dd')` as a Trino replacement for Oracle `TO_DATE(str, 'YYYY-MM-DD')`.
- **Why it's wrong**: Trino has NO function named `parse_date`. Verified at trino.io/docs/current/functions/datetime.html. The real Trino parsing functions are:
  - `date_parse(string, format) → timestamp(3)` — MySQL-style specifiers (`%Y-%m-%d`, `%H:%i:%s`).
  - `parse_datetime(string, format) → timestamp with time zone` — Joda-style specifiers (`yyyy-MM-dd`, `HH:mm:ss`).
  - `from_iso8601_date(string) → date` — direct ISO 8601 string to DATE.
- **Class**: fabricated function name (most likely Snowflake `TO_DATE`/BigQuery `PARSE_DATE` cross-dialect spillover into Trino).
- **Correct forms** for `TO_DATE('2026-06-05','YYYY-MM-DD')`:
  ```sql
  -- Cleanest for ISO 8601:
  SELECT from_iso8601_date('2026-06-05');                       -- DATE

  -- MySQL-style specifiers (returns timestamp; cast for DATE):
  SELECT CAST(date_parse('2026-06-05', '%Y-%m-%d') AS DATE);    -- DATE

  -- Joda-style specifiers (returns timestamp with TZ; cast for DATE):
  SELECT CAST(parse_datetime('2026-06-05', 'yyyy-MM-dd') AS DATE);
  ```
- **Source**: https://trino.io/docs/current/functions/datetime.html.

### Q4 content gap (NOT a fabrication)

- The responder honestly stated resources/ lacks dbt model contracts content and deferred to dbt docs.
- Per directive, this is classified as **incompleteness / content-gap**, not as fabrication. No accuracy penalty for declining to invent; completeness and actionability take the hit instead.
- **Correct facts (for teacher to encode)** per docs.getdbt.com/reference/resource-configs/contract:
  - A model contract is declared in the model's YAML via `config: contract: {enforced: true}` plus a `columns:` list with `name` and `data_type` (and optional constraints `not_null`, `unique`, `primary_key`, `foreign_key`, `check`).
  - When enforced, dbt builds the model with an explicit column list and **fails the build at parse/compile time if the model's actual output columns/types do not match the declared schema**.
  - Constraints come in two flavors: **model-level** (warehouse-enforced where supported, advisory elsewhere) and **column-level**. Trino does not natively enforce most constraints — dbt-trino issues them as informational metadata; the column/type mismatch check is the load-bearing build-failure trigger that works regardless of platform.
  - Use case: lock the public-facing schema of a model so a downstream change (renaming a column, dropping a column, type narrowing) breaks the build instead of silently breaking dashboards.
- **Source**: https://docs.getdbt.com/reference/resource-configs/contract.

---

## Teacher actions for iter472 — PRIORITIZED

### PRIMARY (P0) — Add dbt model contracts content (Q4 content gap)

- **Where**: extend `resources/26-dbt-on-trino.md` (or wherever dbt model-level config / yaml schema lives), or create a dedicated mini-section in the dbt sources/freshness file under a new "dbt model contracts" §heading.
- **What to write**:
  1. One-paragraph "what is a model contract" intro (a schema lock declared in the model's YAML; dbt fails the build at compile time if actual output columns or types diverge from declared ones).
  2. **One copy-paste worked example** showing the yaml config + a matching model SQL. Use a production-stack table like `iceberg.analytics.fct_orders` so the example transfers. Example skeleton:
     ```yaml
     # models/marts/fct_orders.yml
     models:
       - name: fct_orders
         config:
           contract:
             enforced: true
         columns:
           - name: order_id
             data_type: bigint
             constraints:
               - type: not_null
           - name: customer_id
             data_type: bigint
           - name: order_date
             data_type: date
           - name: amount_usd
             data_type: decimal(18,2)
     ```
  3. **Failure mode demo**: show what `dbt build` prints when (a) a column is missing, (b) a type is wrong (e.g. model returns `bigint` but contract declares `int`), (c) extra columns appear. Frame as "good — the build failed BEFORE production data got corrupted".
  4. **Constraints clarification on Trino**: model-level `primary_key`/`foreign_key`/`check` are advisory on most warehouses; on Trino+Iceberg via dbt-trino they are recorded as metadata but not runtime-enforced. The hard guarantee is the **column-list + data_type build-time check** — that's enforced unconditionally regardless of warehouse capability.
  5. **When to use**: public/contractual datasets (BI dashboards, downstream model dependencies, exposed to other teams). Skip for staging or scratch models where churn is high.
  6. Cross-ref to dbt sources freshness (already in rubric) — contracts are the OUTPUT-side schema lock; freshness is the INPUT-side liveness check; the two work together.
- **DO-NOT-WRITE matrix entries** (for citation hygiene):
  - DO NOT write that contracts are Trino-specific — they are a dbt-core feature available on any adapter.
  - DO NOT invent constraint types like `regex` or `length` — the documented set is `not_null`, `unique`, `primary_key`, `foreign_key`, `check`.
  - DO NOT claim Trino enforces foreign keys at write time — it does not; the constraint is metadata only on dbt-trino + Iceberg.

### SECONDARY (P1) — Fix `SET PARTITION SPEC` cross-dialect spillover (Q1 fab)

- **Where**: r17 LEADING schema-evolution canonical (added iter471) — extend to cover **partition** evolution, not just **schema** evolution.
- **What to write**:
  1. Add a new sub-section "Evolving the partition spec on Trino 467" right after the schema-evolution sub-section.
  2. **The canonical form** for both adding and replacing partition columns:
     ```sql
     -- Add a new partition column (alongside existing partitioning):
     ALTER TABLE iceberg.analytics.events
       SET PROPERTIES partitioning = ARRAY['day(event_time)', 'tenant_id'];

     -- Replace partitioning entirely (drop old partition column):
     ALTER TABLE iceberg.analytics.events
       SET PROPERTIES partitioning = ARRAY['day(event_time)'];

     -- Unpartition entirely:
     ALTER TABLE iceberg.analytics.events
       SET PROPERTIES partitioning = ARRAY[];
     ```
  3. **Existing-data behavior**: explicitly state Iceberg keeps old partition spec for already-written files (queries that scan old data still benefit from old partition pruning); new writes use new spec.
  4. **DO-NOT-WRITE matrix entry**:
     - `ALTER TABLE ... SET PARTITION SPEC (...)` — **FABRICATED SYNTAX on Trino 467** (Spark Iceberg dialect form; will not parse on Trino). Correct: `SET PROPERTIES partitioning = ARRAY[...]`.
     - `ALTER TABLE ... ADD PARTITION FIELD ...` — **FABRICATED SYNTAX on Trino 467** (Spark Iceberg only).
     - `ALTER TABLE ... REPLACE PARTITION FIELD ... WITH ...` — **FABRICATED SYNTAX on Trino 467** (Spark Iceberg only).
  5. Cite trino.io/docs/current/connector/iceberg.html § "Schema and partition evolution".

### SECONDARY (P2) — Fix `parse_date` fab (Q3)

- **Where**: r27 Oracle PL/SQL → dbt/Trino migration resource, the Oracle date/time function translation table.
- **What to write**:
  1. In the existing `TO_DATE` translation row, ensure the Trino-side gives **all three correct alternatives** (not the fab `parse_date`):
     | Oracle | Trino equivalent | Returns | Notes |
     |---|---|---|---|
     | `TO_DATE('2026-06-05','YYYY-MM-DD')` | `CAST(date_parse('2026-06-05','%Y-%m-%d') AS DATE)` | DATE | MySQL-style specifiers; `date_parse` returns timestamp(3), wrap in CAST AS DATE |
     | `TO_DATE('2026-06-05','YYYY-MM-DD')` | `from_iso8601_date('2026-06-05')` | DATE | Cleanest when input is already ISO 8601 |
     | `TO_DATE('05-JUN-2026','DD-MON-YYYY')` | `CAST(date_parse('05-JUN-2026','%d-%b-%Y') AS DATE)` | DATE | `%b` = abbreviated month name |
  2. **DO-NOT-WRITE matrix entry**:
     - `parse_date(string, format)` — **FABRICATED TRINO FUNCTION** (Snowflake/BigQuery name). Does not exist in Trino 467. Use `date_parse` (MySQL specifiers) or `parse_datetime` (Joda specifiers) or `from_iso8601_date` (ISO 8601 only).
  3. Cite trino.io/docs/current/functions/datetime.html and link both the `date_parse` row and the `parse_datetime` row from the canonical list-of-functions page so future answers don't conflate them.
  4. **Pin the MySQL-vs-Joda specifier distinction** explicitly with a 4-row table: `%Y` vs `yyyy`, `%m` vs `MM`, `%d` vs `dd`, `%H:%i:%s` vs `HH:mm:ss`. This is a known fab-magnet — the wrong specifier in the right function silently returns NULL or wrong date.

### NO DEDICATED FEDERATION PROBE (P3)

- Federation row sits at 4.49944/310, 0.0006 below 4.5 raised threshold. Do NOT design a dedicated federation probe — the row passed mathematical break-even months ago but is gated by the elevated threshold. Let count grow naturally through breadth probes.

---

## Breadth design recommendations for iter472

- Mix 1 question on dbt model contracts (test the NEW resource), 1 on Trino DDL (re-probe `SET PARTITION SPEC` fix), 1 on Oracle migration with a date function (re-probe `parse_date` fix), 1 broader topic NOT touched recently (suggest: Iceberg storage sizing OR cost considerations OR Trino CBO ANALYZE).
- Avoid stacking 3+ Iceberg-internals probes in one iter — last 3 iters have been Iceberg-heavy and we need breadth variance to keep Multi-tenant analytics (4.4582/153), Lakehouse schema design (4.5052/12), and the Oracle migration topic (4.5826/44) from being under-tested.

---

## Citation hygiene observations

- The two targeted fixes from iter471 teacher cycle (DROP COLUMN capability + $refs vs $snapshots) landed clean. The new r17 LEADING canonicals are working as intended for Q1's DROP COLUMN core and Q2's full $refs lookup.
- The fab class **moved** to adjacent territory: the partition-evolution edge case in the SAME ALTER TABLE family (Q1) and the date-parsing function family in Oracle migration (Q3). Pattern: when the teacher closes a fab via a LEADING canonical, the next iter often surfaces the same fab class one neighbor over. **Suggestion**: when adding a LEADING canonical, also add a DO-NOT-WRITE matrix that explicitly enumerates 5-10 cross-dialect equivalents the responder might confuse with the canonical form — this is the cheapest fab-class containment we have.
- Fab-watch flags for iter472: (a) cross-dialect spillover — Spark Iceberg DDL (`SET PARTITION SPEC`, `ADD PARTITION FIELD`) leaking into Trino answers; (b) Snowflake/BigQuery function names (`parse_date`, `to_date`, `dateadd`) leaking into Trino Oracle-migration answers; (c) content-gap dbt sub-features (model contracts NOW; unit tests, exposures, semantic-layer next).
