# Oracle PL/SQL Procedure -> dbt + Trino SQL Migration

> You inherited (or are being asked to migrate) a stack of Oracle PL/SQL stored procedures that do nightly rollups, dimension loads, and slowly-changing-dimension merges into a warehouse. The new home is **Trino 467 + Iceberg 1.5.2 + MinIO + Hive Metastore**, with **dbt** as the transformation framework. This guide tells you how to think about that translation, gives you a two-column SQL dialect translation table, and walks one full Oracle procedure -> dbt incremental model end-to-end.
>
> **Production stack assumed**: Trino 467 OSS, Iceberg 1.5.2 with Hive Metastore, MinIO via S3, on-prem Kubernetes, dbt-trino adapter. No Starburst Enterprise features.

---

## TL;DR (read these 7 sentences first)

1. **Trino has NO stored procedures.** There is no `CREATE PROCEDURE`, no `BEGIN ... END`, no PL/SQL, no `EXECUTE IMMEDIATE`, no cursor declarations, no exception handlers. The closest equivalent in this stack is **a dbt model** (a `.sql` file) that emits a single SET-based SQL statement and is orchestrated by `dbt run`.
2. **The mindset shift is procedural -> declarative.** Oracle PL/SQL iterates row-by-row inside a `CURSOR FOR` loop, accumulates into temp tables, branches with `IF/THEN`, and finishes with `MERGE`. dbt on Trino expresses the SAME logic as a **single SQL SELECT** that joins, aggregates, and windows all rows at once; dbt then materializes the result as a table or merges it incrementally.
3. **One Oracle procedure typically becomes 1-to-N dbt models**, chained via `ref()`. Each `IF/THEN` branch usually becomes a `CASE` expression or a `WHERE` predicate. Each temp table becomes either a CTE, an ephemeral dbt model, or (for big intermediates) a materialized intermediate table.
4. **MERGE is the load-bearing translation.** Oracle's `MERGE INTO target USING source ON (...) WHEN MATCHED THEN UPDATE WHEN NOT MATCHED THEN INSERT` maps directly to **dbt incremental with `incremental_strategy='merge'` and `unique_key='...'`** — dbt-trino generates the Trino `MERGE INTO` SQL for you. This is the canonical SCD-1 / upsert pattern on Iceberg.
5. **Oracle SQL dialect != Trino SQL dialect.** `NVL`, `DECODE`, `SYSDATE`, `TO_DATE`, `(+)` outer joins, `CONNECT BY`, `ROWNUM`, sequences, `DUAL`, `MINUS`, Oracle's empty-string-is-NULL behavior, and `NUMBER` types ALL require rewrites. See the translation table in section 4.
6. **Trino is strict about types**: no implicit varchar<->number coercion, `''` is NOT NULL (Oracle treats `''` as NULL — this WILL silently change WHERE-clause results), and date arithmetic uses `INTERVAL` not `+ 1`. Plan to add explicit `CAST(...)` everywhere your Oracle SQL relied on implicit coercion.
7. **Choose the dbt materialization deliberately**: `view` for cheap pass-through transforms; `table` for full-refresh nightly rebuilds; `incremental` (with `merge` strategy + `unique_key`) for daily appends/upserts onto big fact tables; `ephemeral` for small CTE-like intermediates. See section 5.

---

## Common myths about migrating Oracle PL/SQL to dbt + Trino — read FIRST

These are the absolutes most often stated incorrectly when an engineer with Oracle PL/SQL muscle memory writes their first dbt-on-Trino model. Each TRUTH below has been verified against the official Trino docs, the dbt-trino adapter docs, and Apache Iceberg docs. **Lead with the TRUTH; state the nuance.**

| MYTH (commonly said wrong) | TRUTH (correct framing) | Authoritative pointer |
|---|---|---|
| "Trino 467 supports `CREATE PROCEDURE` / PL/SQL blocks / `BEGIN ... END` — I just need to translate the syntax." | **FALSE — there is no procedural language in Trino.** Trino 467 has NO stored procedures, NO PL/SQL, NO `BEGIN ... END`, NO loops, NO local variables, NO cursors. The only "procedures" Trino exposes are **table maintenance procedures** invoked via `ALTER TABLE ... EXECUTE` (e.g., `optimize`, `expire_snapshots`, `remove_orphan_files`) — those are not user-definable. **The replacement for an Oracle procedure is a dbt model (a `.sql` file)** that emits ONE SET-based SQL statement; dbt run orchestrates the chain via `ref()`. **DO NOT write `CREATE OR REPLACE PROCEDURE` in a dbt model — it will fail to parse.** | [Trino SQL statement support](https://trino.io/docs/current/language/sql-support.html); [dbt-trino configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) |
| "`QUALIFY ROW_NUMBER() OVER (...) = 1` works on Trino — it's standard SQL." | **FALSE on Trino 467 — parse error.** `QUALIFY` is a Snowflake / BigQuery / Databricks / Teradata extension, not in the SQL standard, NOT in Trino. The Trino-compatible rewrite is the canonical `ROW_NUMBER()` subquery + outer `WHERE rn = 1` (or `WHERE rn <= N` for top-N-per-group). **DO NOT WRITE `QUALIFY ...` in a dbt model targeting Trino — it will fail at compile time.** See resource 23 § Trino 467 SQL-dialect anti-patterns for the canonical rewrite. | [resource 23](23-sql-best-practices-olap.md) |
| "Trino has `sequence.NEXTVAL` for surrogate keys — I'll port my Oracle sequences directly." | **FALSE — Trino has NO sequences, NO `NEXTVAL`, NO `CURRVAL`.** There is a `sequence()` table function and a `sequence` array generator, but those are different (range generators, not persistent counters). For surrogate keys on Iceberg, use one of: (a) **hash-based surrogate key** — `md5(concat(natural_key_col1, natural_key_col2, ...))` (idempotent, the dbt convention); (b) **`row_number() OVER (ORDER BY ...)`** (only safe inside a single CTAS, not stable across runs); (c) **identity column** — Iceberg V2 supports identity-style surrogate generation but it requires Spark-side DDL. **DO NOT WRITE `my_seq.NEXTVAL` in a dbt model — it will fail.** The dbt-trino best practice is hash-based surrogate keys via `dbt_utils.generate_surrogate_key([...])`. | [Trino SELECT docs](https://trino.io/docs/current/sql/select.html); [dbt_utils](https://github.com/dbt-labs/dbt-utils) |
| "Trino has `ROWNUM` — I can use it for top-N just like Oracle." | **FALSE on Trino 467 — `ROWNUM` is an Oracle-only pseudocolumn, not in Trino.** The Trino-equivalent patterns are: (a) **`LIMIT N`** (for "first N rows" — Trino's order-preserving LIMIT after ORDER BY); (b) **`row_number() OVER (PARTITION BY ... ORDER BY ...)`** (for top-N-per-group, accessed via outer `WHERE rn <= N`). Oracle's `WHERE ROWNUM <= N` translates to `... ORDER BY ... LIMIT N`. **DO NOT WRITE `WHERE ROWNUM <= 10` in Trino — parse error.** | [Trino SELECT - LIMIT](https://trino.io/docs/current/sql/select.html) |
| "Oracle's `''` = NULL behavior carries over to Trino — I don't need to change my WHERE clauses." | **FALSE — and this is the silent-bug champion of the migration.** Oracle treats the empty string `''` as NULL (a long-standing quirk: `'' IS NULL` returns TRUE in Oracle). **Trino treats `''` as a normal zero-length string distinct from NULL: `'' IS NULL` returns FALSE in Trino.** Real-world consequence: an Oracle query `WHERE name IS NOT NULL` that historically filtered out both NULL names AND empty-string names will, after migration, **silently start including empty-string names**, often changing aggregate counts and breaking downstream joins. **The fix:** audit every `IS NULL` / `IS NOT NULL` / `NVL(col, ...)` in the source procedures and, where the original logic depended on the Oracle quirk, rewrite to explicit `col IS NULL OR col = ''` (or the inverse). | [Oracle SQL Language Reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Nulls.html) — "Oracle Database currently treats a character value with a length of zero as null" |
| "Trino's `MERGE INTO` doesn't work on Iceberg / requires a special connector flag." | **FALSE — MERGE on Iceberg is supported in Trino 467 by default, no flag.** MERGE is the canonical Trino-side upsert form for Iceberg tables. dbt-trino's `incremental_strategy='merge'` is built on top of it and is the recommended SCD-1 pattern. (What MAY require flags is MERGE on JDBC connectors like PostgreSQL/MySQL — see [resource 22](22-trino-federation-postgresql.md). On the Iceberg connector it's on out of the box.) | [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html); [dbt-trino merge strategy](https://docs.getdbt.com/reference/resource-configs/trino-configs#the-merge-strategy) |
| "Oracle's `CONNECT BY PRIOR ... START WITH ...` hierarchical syntax works in Trino — it's a common SQL extension." | **FALSE — Trino has NO `CONNECT BY`.** The replacement is **`WITH RECURSIVE`** (ANSI SQL standard, supported in Trino since release 343). A recursive CTE must be shaped as `WITH RECURSIVE t(cols) AS (base_query UNION ALL recursive_step) SELECT ...`. **Caveat:** Trino's recursive CTE has a default `max-recursion-depth = 10` session-tunable limit and is not as performant as Oracle's CONNECT BY for deep hierarchies — for very deep org charts or BOMs, consider materializing the closure table as a pre-computed dbt model instead of computing recursively at read time. **DO NOT WRITE `CONNECT BY PRIOR` in a dbt model — parse error.** | [Trino SELECT - WITH RECURSIVE](https://trino.io/docs/current/sql/select.html); [PR #4250](https://github.com/trinodb/trino/pull/4250) |
| "Oracle `(+)` outer-join syntax is also valid in Trino." | **FALSE — `(+)` is Oracle-proprietary, parse error in Trino.** Rewrite to ANSI `LEFT JOIN` / `RIGHT JOIN` syntax. (Modern Oracle docs also recommend ANSI joins over `(+)`.) | [Trino SELECT - JOIN](https://trino.io/docs/current/sql/select.html#join-clause) |
| "Oracle implicit `varchar` -> `number` coercion (`WHERE int_col = '42'`) works in Trino." | **FALSE — Trino is strict about types.** Comparing `int_col = '42'` (`bigint = varchar`) raises `TYPE_MISMATCH`. You must `CAST(int_col AS varchar) = '42'` or `int_col = CAST('42' AS bigint)`. Most Oracle PL/SQL written before ~2015 relies heavily on implicit coercion; expect to add explicit `CAST` calls everywhere. | [Trino types](https://trino.io/docs/current/language/types.html) |
| "I should port my Oracle exception handlers (`EXCEPTION WHEN NO_DATA_FOUND THEN ...`) to dbt." | **FALSE — there is no exception block in dbt or Trino SQL.** The replacement is **dbt tests** (`not_null`, `unique`, `accepted_values`, `relationships`, plus custom singular tests) which run after the model builds and fail the run if violated. For "soft" guards inside a transformation (e.g., "if dim is missing, default to UNKNOWN"), use `COALESCE`, `CASE WHEN`, or `LEFT JOIN` with a NULL fallback. **DO NOT WRITE `EXCEPTION WHEN ...` in a dbt model.** | [dbt tests](https://docs.getdbt.com/docs/build/data-tests) |

> **Why these specific myths matter.** Each is a load-bearing translation that an engineer with Oracle muscle memory will write reflexively on day one — and each will either fail to parse (visible failure, easy to fix) OR silently change query results (invisible failure, hard to detect). The empty-string-is-NULL myth and the implicit-coercion myth are the two most dangerous because they don't produce a parse error: the migrated model runs, but the numbers no longer match the Oracle source. **Always diff a representative sample of rows between Oracle and Trino during cutover.**

---

## 1. The mindset shift: procedural -> declarative

The single largest barrier to a productive Oracle -> Trino migration is the procedural-vs-set-based mental model. An experienced Oracle developer reaches for a loop the way a Trino/dbt engineer reaches for a join. They're often equivalent. The Trino version is faster, more parallelizable, and easier to test — but only if you can SEE the equivalence.

### 1.1 The mental model in one paragraph

Oracle PL/SQL says "**for each row in the source, decide what to do**." Trino + dbt says "**describe the entire output set as a SELECT; the engine figures out how to compute every row in parallel.**" The PL/SQL programmer thinks in terms of state (cursors, counters, accumulators, `v_total := v_total + ...`); the Trino engineer thinks in terms of relations (the input is a set of rows, the output is a set of rows, the transformation is a SELECT that connects them). Every loop in PL/SQL has a corresponding SET-BASED expression in Trino — usually a `JOIN`, a `GROUP BY`, or a window function.

### 1.2 The full procedural-construct -> set-based-equivalent map

| Oracle PL/SQL construct | dbt + Trino equivalent | Why |
|---|---|---|
| `CURSOR FOR rec IN (SELECT ...) LOOP ... END LOOP;` (row-by-row processing) | **A `SELECT` with a `JOIN` and/or `GROUP BY`** — the loop body becomes the SELECT list / WHERE / aggregation. | The cursor exists to iterate; set-based SQL processes all rows at once in parallel. |
| `LOOP ... v_total := v_total + col; END LOOP;` (loop accumulation) | **`SUM(col)` with `GROUP BY`**, or `SUM(col) OVER (PARTITION BY ... ORDER BY ...)` for running totals. | Accumulation is aggregation; running totals are window functions. |
| `IF cond THEN ... ELSIF ... ELSE ... END IF;` (branching) | **`CASE WHEN cond THEN ... WHEN ... ELSE ... END`** in the SELECT list, or a `WHERE` predicate, or (for whole-pipeline branches) a dbt `{% if var('mode') == 'X' %} ... {% endif %}` Jinja conditional. | Inline CASE handles per-row branching; Jinja handles "build this differently in dev vs prod." |
| Temp table (`CREATE GLOBAL TEMPORARY TABLE`) for staging | **A CTE (`WITH ...`)**, or an **ephemeral dbt model** (no DDL — inlined as a CTE when referenced), or a **materialized intermediate dbt model** (`materialized='table'`) when the intermediate is big enough to reuse across multiple downstream models. | Trino has no persistent temp tables; the dbt `ref()` graph is the replacement. (Trino HAS session-temporary tables via `CREATE TABLE <catalog>.<schema>.tmp_xxx AS SELECT ...` but those are full Iceberg tables — not the right replacement.) |
| `MERGE INTO target USING source ON (...) WHEN MATCHED THEN UPDATE WHEN NOT MATCHED THEN INSERT;` | **dbt incremental model with `incremental_strategy='merge'` and `unique_key='...'`** — dbt-trino generates the Trino `MERGE INTO` SQL automatically. | The canonical SCD-1 / upsert pattern on Iceberg; see section 6 worked example. |
| `INSERT INTO target SELECT ... ; COMMIT;` (full reload) | **dbt `materialized='table'`** — dbt rebuilds the table on every `dbt run`. | Trino+Iceberg CTAS is atomic; you don't need to manage your own COMMIT. |
| `my_seq.NEXTVAL` (sequence-based surrogate key) | **`{{ dbt_utils.generate_surrogate_key(['col1', 'col2']) }}`** (hash-based, idempotent) — OR `row_number() OVER (ORDER BY <stable_ordering>)` inside a single CTAS. | Trino has no persistent sequences. Hash-based keys are reproducible across runs and clusters; ROW_NUMBER is only stable within one run. |
| `EXCEPTION WHEN NO_DATA_FOUND THEN ...` / `WHEN OTHERS THEN ...` | **dbt tests** (post-build) — `not_null`, `unique`, `accepted_values`, `relationships`, custom singular tests; PLUS in-query guards via `COALESCE(col, default)`, `LEFT JOIN ... ON ... = ...` with a fallback row, and `CASE WHEN col IS NULL THEN ... END`. | The "exception" in dbt-world is a failed test that breaks the run; the "guard" is an in-query default. |
| `RAISE_APPLICATION_ERROR(-20001, 'msg')` (explicit error) | **dbt singular test** that returns rows-violating-the-rule (any returned row fails the test) OR Jinja-side `{% if ... %}{{ exceptions.raise_compiler_error('...') }}{% endif %}`. | Errors are caught at the run level, not inside the SQL. |
| `DBMS_OUTPUT.PUT_LINE('debug')` | **dbt logging** (`{{ log(...) }}` in Jinja) or `SELECT` the intermediate to a debug model with `materialized='view'`. | No print-statement equivalent in SQL itself; dbt's macros print at compile time. |
| `EXECUTE IMMEDIATE 'dynamic SQL'` | **dbt Jinja macros** that compose SQL at compile time. | Dynamic SQL is replaced by Jinja templating BEFORE the SQL reaches Trino. |
| `COMMIT` / `ROLLBACK` (explicit transaction control) | **N/A — dbt + Trino + Iceberg is implicitly atomic per statement.** A successful CTAS or MERGE commits one new Iceberg snapshot; a failure leaves the previous snapshot intact. | Iceberg's snapshot-based atomicity replaces explicit transaction control. |
| `PRAGMA AUTONOMOUS_TRANSACTION` (independent transaction for audit logging) | **A separate dbt model** for audit rows, or a dbt `on-run-end` hook, or an external audit table written by your orchestrator. | dbt models are independent statements; chain them via `ref()`. |
| `BULK COLLECT INTO ... FORALL` (PL/SQL array-based bulk DML) | **A single SET-based `INSERT ... SELECT` or `MERGE`** — this is exactly what Trino does natively at full parallelism. | The PL/SQL bulk-DML idiom exists to recover from the row-by-row default; in Trino, set-based IS the default. |

---

## 2. Where each Oracle procedure becomes 1-to-N dbt models

A 500-line Oracle procedure doesn't become one 500-line dbt model. It typically becomes a small dbt DAG. Here's the decomposition pattern.

### 2.1 The decomposition recipe

Take your Oracle procedure and slice it into logical phases. Each phase becomes one dbt model. The phases are usually:

1. **Source-extract phase** (`stg_*` staging models): one model per source table. Cast types, rename columns to your warehouse convention, apply minimal cleaning. `materialized='view'` is the dbt-trino default and almost always correct here.
2. **Intermediate phase** (`int_*` models): joins, aggregations, business-rule application. These correspond to the temp-table-stage in your Oracle procedure. `materialized='ephemeral'` for small ones (inlined as a CTE); `materialized='table'` for big intermediates referenced multiple times.
3. **Final-mart phase** (`fct_*` / `dim_*` models): the target fact/dimension tables. These are the equivalent of the final `MERGE INTO target` in your procedure. `materialized='incremental'` with `incremental_strategy='merge'` is the standard choice.

### 2.2 The mapping in a picture

```text
ORACLE PROCEDURE                     dbt DAG ON TRINO

  CREATE OR REPLACE PROCEDURE          stg_app_orders.sql      (view)
  load_orders_daily AS                 stg_app_customers.sql   (view)
  BEGIN                                stg_currency_fx.sql     (view)
    -- step 1: extract                 -- equivalent of CURSOR FOR
    OPEN c_orders;                     -- the cursor body is the SELECT
    LOOP                                       |
      -- step 2: enrich                        v
      ...                              int_orders_enriched.sql (ephemeral)
      -- step 3: stage                          -- joins, type cleaning,
      INSERT INTO tmp_enriched ...              business rule application
    END LOOP;                                   |
                                                v
    -- step 4: merge                   fct_orders.sql          (incremental,
    MERGE INTO fct_orders                                       merge strategy,
    USING tmp_enriched ...                                      unique_key='order_id')
    COMMIT;                            (dbt run commits implicitly per model)
  END;
```

Three things to note:

- **The cursor body becomes the SELECT inside `int_orders_enriched`** — same logic, expressed as a relation instead of a loop.
- **The temp table becomes either a CTE in `fct_orders` or a separate `int_*` model with `ref()`** — you pick based on whether the intermediate is reused.
- **The MERGE becomes a dbt incremental config**, not hand-written SQL — dbt-trino emits the Trino MERGE statement.

---

## 3. dbt-trino: the materialization-strategy choice for migrated procedures

The single most important decision per migrated model is which `materialized=` to use. Get this right and the pipeline is fast and idempotent. Get it wrong and you'll either rebuild terabytes every night (`table` where `incremental` was needed) or re-run an expensive 8-join query on every downstream read (`view` where `table` was needed).

### 3.1 The four materializations supported by dbt-trino

Verified against [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) and [docs.getdbt.com/docs/build/materializations](https://docs.getdbt.com/docs/build/materializations).

| Materialization | What dbt does on each `dbt run` | When to use it | When NOT to use it |
|---|---|---|---|
| **`view`** | `CREATE OR REPLACE VIEW ... AS <SELECT>` — no data movement, just stores the SELECT. Reads always re-execute the SELECT. | Cheap pass-through transforms; `stg_*` models where the underlying source is small or already partitioned well; when freshness must be real-time and the cost of re-execution is acceptable. | Expensive multi-join queries that downstream models will hit repeatedly — every downstream read pays the join cost again. |
| **`table`** | `CREATE OR REPLACE TABLE ... AS SELECT ...` — a full CTAS each run. Iceberg snapshot replaces prior data atomically. | Big intermediates referenced by 3+ downstream models; daily full-refresh facts that aren't too large; dim tables that fully reload. The dbt-trino default for `on_table_exists` is `'rename'` (creates intermediate, swaps, drops old) — that's the safe atomic-replace pattern. | Multi-terabyte tables where most rows don't change — you'd rebuild the entire table every night for a small delta. Use `incremental` instead. |
| **`incremental`** | First run: CTAS. Subsequent runs: only process new rows (per the `is_incremental()` filter) and apply via the chosen `incremental_strategy`. | The high-volume daily-append / daily-upsert case — fact tables, event tables, anything where the delta is small relative to the whole table. **This is the standard target for any Oracle procedure that did a nightly MERGE.** | Models small enough that the cost of merge overhead exceeds the cost of full rebuild (~under 10M rows on this stack — measure on your data). |
| **`ephemeral`** | NOT built into the database. dbt inlines the SELECT as a CTE everywhere `ref()` references it. | Small reusable intermediates referenced by 1-2 downstream models that should NOT cost a CTAS to build. The dbt-equivalent of "this would be a CTE if I were writing one big query." | Anything referenced by many downstreams (the SELECT gets inlined many times, recomputing the same logic). Anything large enough to benefit from materialization. |

### 3.2 The `incremental_strategy` choice (for `materialized='incremental'` only)

dbt-trino supports four incremental strategies. Verified against [docs.getdbt.com - The merge strategy](https://docs.getdbt.com/reference/resource-configs/trino-configs#the-merge-strategy).

| Strategy | What it does | Use it when | Trino SQL it emits |
|---|---|---|---|
| **`append`** | INSERTs the delta into the target. No deduplication. | The delta has no overlap with existing rows (e.g., append-only event log with a strictly-increasing event_id). | `INSERT INTO target SELECT ... FROM (your_select) WHERE is_incremental_filter` |
| **`merge`** (THE DEFAULT TARGET FOR ORACLE MERGE PROCEDURES) | UPSERTs on `unique_key` — updates rows that match, inserts rows that don't. SCD-1 semantics. | Your Oracle procedure ended in `MERGE INTO ... WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT`. | `MERGE INTO target USING (select) ON target.<unique_key> = source.<unique_key> WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT ...` |
| **`delete+insert`** | DELETEs matching rows in target by `unique_key`, then INSERTs the new rows. | Connector doesn't support MERGE, OR `unique_key` is not actually unique in the source. The Iceberg connector supports MERGE so this is rarely needed in this stack. | `DELETE FROM target WHERE <unique_key> IN (SELECT <unique_key> FROM source) ; INSERT INTO target SELECT ... FROM source` |
| **`microbatch`** | Newer strategy — splits the incremental run into time-bucketed batches for very-large deltas. | Late-arriving data + huge windows; replay use cases. | Implementation-dependent. Check current dbt-trino docs. |

### 3.3 The minimum-viable dbt config for a migrated MERGE procedure

```jinja
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='order_id',
    on_schema_change='append_new_columns',
    properties={
      'format': 'PARQUET',
      'partitioning': "ARRAY['order_date']",
      'sorted_by': "ARRAY['tenant_id']",
      'format_version': 2
    }
) }}

SELECT ...
FROM {{ ref('int_orders_enriched') }}
{% if is_incremental() %}
  WHERE order_date >= (SELECT COALESCE(MAX(order_date), DATE '1970-01-01') FROM {{ this }})
{% endif %}
```

Notes:
- `properties` is the dbt-trino-specific block that maps directly to Iceberg `WITH (...)` table properties. **Partition the migrated table by the same column the Oracle table was partitioned on (or whatever the dominant filter is — see [resource 10](10-lakehouse-partitioning.md)).**
- `is_incremental()` is dbt's compile-time check; on first run it's FALSE (no WHERE filter, full CTAS); on subsequent runs it's TRUE (filter applied, MERGE on the delta).
- `on_schema_change='append_new_columns'` adds new source columns automatically on incremental runs (the safe default). Other options: `'ignore'` (don't add), `'fail'`, `'sync_all_columns'` (also drops removed columns — dangerous).

---

## 4. Oracle SQL -> Trino SQL: the two-column translation table

These are the per-expression rewrites you'll do on almost every migrated SELECT. Verified against [Trino functions docs](https://trino.io/docs/current/functions.html), [Trino types](https://trino.io/docs/current/language/types.html), and the [Oracle SQL Language Reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/).

### 4.1 Null handling and conditional expressions

| Oracle | Trino | Notes |
|---|---|---|
| `NVL(col, default)` | `COALESCE(col, default)` | `COALESCE` accepts N args; `NVL` only 2. Always prefer `COALESCE` going forward. |
| `NVL2(col, val_if_not_null, val_if_null)` | `CASE WHEN col IS NOT NULL THEN val_if_not_null ELSE val_if_null END` | No direct Trino built-in; `IF(condition, val_if_true, val_if_false)` also works for the boolean form. |
| `NULLIF(a, b)` | `NULLIF(a, b)` | Identical. |
| `DECODE(col, 'A', 1, 'B', 2, 0)` | `CASE col WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END` (or chained `CASE WHEN`s) | Trino has NO `DECODE`. CASE is more readable anyway. |
| `'' IS NULL` -> TRUE (Oracle quirk) | `'' IS NULL` -> **FALSE** in Trino | The single most dangerous silent-result-change in the migration. See myths box. |
| `nvl(col, '')` (sentinel "no value" Oracle idiom) | `COALESCE(col, '')` BUT this now produces a row where `col` is `''` (not null) — downstream `WHERE col IS NULL` checks BREAK. Audit and rewrite. | Oracle's quirk made this idiom round-trip cleanly; Trino's strictness breaks it. |

### 4.2 Date/time functions

| Oracle | Trino | Notes |
|---|---|---|
| `SYSDATE` (current date + time, server time zone) | `current_timestamp` (timestamp with time zone, session TZ) OR `localtimestamp` (no TZ) | Beware: `SYSDATE` returns DATE-with-time in Oracle; `CURRENT_DATE` in Trino is just DATE (no time). Use `current_timestamp` for "now()" semantics. |
| `SYSTIMESTAMP` | `current_timestamp` | Identical semantics. |
| `TRUNC(dt)` (truncate to day) | `date_trunc('day', dt)` | Also `'week'`, `'month'`, `'quarter'`, `'year'`, `'hour'`, `'minute'`, `'second'`. |
| `TO_DATE('2026-05-30', 'YYYY-MM-DD')` | `date_parse('2026-05-30', '%Y-%m-%d')` returning timestamp, OR `CAST('2026-05-30' AS DATE)` for ISO-8601 dates. | Trino's format strings use `%Y %m %d %H %i %s` (MySQL-style), NOT Oracle's `YYYY MM DD HH24 MI SS`. |
| `TO_CHAR(dt, 'YYYY-MM-DD')` | `format_datetime(dt, 'yyyy-MM-dd')` returning varchar (Joda-time format), OR `CAST(dt AS varchar)`. | Trino's `format_datetime` uses Joda-style `yyyy MM dd HH mm ss`. |
| `TO_NUMBER('123')` | `CAST('123' AS bigint)` or `CAST('1.5' AS double)` | Trino has no `TO_NUMBER`; use `CAST`. |
| `EXTRACT(YEAR FROM dt)` | `EXTRACT(YEAR FROM dt)` OR `year(dt)` | Identical syntax + convenience functions. |
| `dt + 1` (add one day) | `dt + INTERVAL '1' DAY` | Trino requires explicit INTERVAL — no implicit day-arithmetic on dates. |
| `dt - SYSDATE` (interval) | `date_diff('day', current_timestamp, dt)` returns bigint | Trino doesn't subtract timestamps to get a bare number; use `date_diff`. |
| `ADD_MONTHS(dt, 3)` | `dt + INTERVAL '3' MONTH` OR `date_add('month', 3, dt)` | Both work. |
| `MONTHS_BETWEEN(d1, d2)` | `date_diff('month', d2, d1)` | Trino's date_diff returns bigint, not the Oracle-style fractional. |
| `LAST_DAY(dt)` | `last_day_of_month(dt)` | Trino has it; just renamed. |

### 4.3 String functions

| Oracle | Trino | Notes |
|---|---|---|
| `SUBSTR(s, start, len)` | `substr(s, start, len)` OR `substring(s FROM start FOR len)` | Both 1-indexed; same as Oracle. |
| `INSTR(s, sub)` | `strpos(s, sub)` | Returns position (1-indexed); `0` if not found, same as Oracle. |
| `INSTR(s, sub, start, n)` (find n-th occurrence) | No single-call equivalent; chain `strpos` + `substr` or use `regexp_extract_all`. | The 4-argument INSTR form is Oracle-only. |
| `LENGTH(s)` | `length(s)` | Identical. |
| `LPAD(s, n, pad)` / `RPAD(s, n, pad)` | `lpad(s, n, pad)` / `rpad(s, n, pad)` | Identical. |
| `LTRIM(s)` / `RTRIM(s)` / `TRIM(s)` | `ltrim(s)` / `rtrim(s)` / `trim(s)` | Identical. |
| ``a || b`` (concatenation) | `a \|\| b` OR `concat(a, b)` | Same operator. **BUT** Oracle treats `NULL \|\| 'x'` as `'x'` (quirk); Trino returns `NULL` (standard). Wrap in `COALESCE`. |
| `UPPER(s)` / `LOWER(s)` / `INITCAP(s)` | `upper(s)` / `lower(s)` / no direct INITCAP — use `regexp_replace` or `array_join(transform(...))`. | INITCAP needs a workaround. |
| `REPLACE(s, from, to)` | `replace(s, from, to)` | Identical. |
| `REGEXP_LIKE(s, pattern)` | `regexp_like(s, pattern)` | Identical. |
| `REGEXP_SUBSTR(s, pattern)` | `regexp_extract(s, pattern)` | Slightly renamed; same idea. |
| `REGEXP_REPLACE(s, pattern, repl)` | `regexp_replace(s, pattern, repl)` | Identical. |

### 4.4 Numeric, type, and casting

| Oracle | Trino | Notes |
|---|---|---|
| `NUMBER` (variable precision) | `decimal(p, s)` for fixed-precision; `bigint` / `integer` / `smallint` for whole numbers; `double` / `real` for approximate. | Trino has NO single "number" type. Pick based on use: money -> `decimal(18,2)`; counters -> `bigint`; scientific -> `double`. |
| `NUMBER(10,0)` | `bigint` or `integer` | Same semantics. |
| `NUMBER(18,2)` | `decimal(18,2)` | Same semantics. |
| `VARCHAR2(n)` | `varchar(n)` OR just `varchar` (unbounded) | Trino's `varchar` is unbounded by default; you can specify length but it's not enforced at write time. |
| `CHAR(n)` | `char(n)` | Identical (but fixed-width padding rarely matters in analytics). |
| `RAW(n)` / `BLOB` | `varbinary` | Identical concept. |
| `CLOB` | `varchar` | Trino has no separate large-object type. |
| `DATE` (Oracle: date + time) | `timestamp` (date + time without TZ) OR `date` (just date). | **CRITICAL: Oracle DATE includes time-of-day; Trino DATE does not.** If your Oracle column has hours/minutes/seconds, migrate it as `timestamp`, NOT `date`. |
| `TIMESTAMP WITH TIME ZONE` | `timestamp(p) with time zone` | Trino's TZ-aware timestamp is fine; Iceberg connector has some precision caveats — verify your model output. |
| `WHERE int_col = '42'` (implicit coerce) | `WHERE int_col = 42` (explicit) OR `WHERE int_col = CAST('42' AS bigint)` | Trino is strict; no implicit varchar<->bigint coercion. |

### 4.5 Query-shape and pseudo-column constructs

| Oracle | Trino | Notes |
|---|---|---|
| `SELECT my_seq.NEXTVAL FROM DUAL` | NO equivalent — sequences don't exist in Trino. Use hash-based surrogate key: `md5(concat_ws('\|\|', col1, col2))` or `dbt_utils.generate_surrogate_key(['col1', 'col2'])`. | Hash-based is the dbt convention. |
| `SELECT 1 FROM DUAL` | `SELECT 1` (no FROM needed) OR `SELECT 1 FROM (VALUES (1)) AS t(x)`. | Trino doesn't need a one-row dummy table. |
| `WHERE ROWNUM <= 10` | `LIMIT 10` (after ORDER BY) OR `WHERE rn <= 10` after a `row_number() OVER (ORDER BY ...)` subquery. | `LIMIT` without `ORDER BY` is nondeterministic — usually combine. |
| `WHERE ROWNUM = 1` (first row) | `LIMIT 1` (after ORDER BY) | Same idea. |
| `ROWNUM` as a column reference | `row_number() OVER (ORDER BY ...)` in a subquery, then reference in outer. | Trino has no implicit row pseudocolumn. |
| `CONNECT BY PRIOR parent_id = id START WITH id = 1` | `WITH RECURSIVE t(...) AS (base_query UNION ALL recursive_step) SELECT * FROM t` | See myths box for the depth caveat. |
| `SELECT ... FROM a, b WHERE a.id = b.id(+)` (Oracle outer-join) | `SELECT ... FROM a LEFT JOIN b ON a.id = b.id` | ANSI JOIN syntax; Oracle `(+)` is parse error in Trino. |
| `MINUS` (set difference) | `EXCEPT` (or `EXCEPT ALL` for multiset semantics) | Trino uses the ANSI standard name. |
| `INTERSECT` | `INTERSECT` | Identical. |
| `UNION` / `UNION ALL` | `UNION` / `UNION ALL` | Identical. |
| `WHERE col IN (subquery)` | Same; Trino's optimizer converts to a SemiJoin. | See [resource 22 §13.6](22-trino-federation-postgresql.md). |
| `WHERE EXISTS (correlated subquery)` | Same; Trino tries to decorrelate to a SemiJoin. If decorrelation fails, you get a `CorrelatedJoin` operator in EXPLAIN — expensive. See [resource 28](28-complex-sql-performance-trino-dbt.md) for rewrites. | Decorrelation is the optimizer's job, not always automatic. |

### 4.6 DML and procedural constructs

| Oracle | Trino + dbt | Notes |
|---|---|---|
| `MERGE INTO ... USING ... ON ... WHEN MATCHED THEN UPDATE WHEN NOT MATCHED THEN INSERT` | **dbt incremental model with `incremental_strategy='merge'`, `unique_key='...'`**. dbt-trino generates the Trino `MERGE INTO` SQL. | The flagship translation. |
| `INSERT INTO t SELECT ...` (full reload) | **dbt `materialized='table'`** | dbt does CTAS atomically. |
| `INSERT INTO t SELECT ... WHERE delta_filter` (incremental append) | **dbt `materialized='incremental'`, `incremental_strategy='append'`** | dbt manages the delta filter via `is_incremental()`. |
| `UPDATE t SET col = ... WHERE ...` | `UPDATE t SET col = ... WHERE ...` (supported on Iceberg) OR a dbt `incremental` model that rebuilds the matching rows. | Trino UPDATE on Iceberg works but is slow for big tables — usually wrap in dbt incremental + merge. |
| `DELETE FROM t WHERE ...` | `DELETE FROM t WHERE ...` (supported on Iceberg, with predicate-pushdown caveats) | Trino DELETE on Iceberg works. For TB-scale deletes, consider Spark + `rewrite_data_files` after. |
| `TRUNCATE TABLE t` | `DELETE FROM t WHERE TRUE` — but for full-refresh, `materialized='table'` is cleaner (atomic replace via Iceberg snapshot). | Trino does NOT have `TRUNCATE` for Iceberg tables. |
| `BEGIN ... END` / `LOOP` / `IF` / `EXCEPTION` / `RAISE` / `COMMIT` | N/A — restructure as a dbt DAG. See section 2 decomposition recipe. | See myths and section 1.2 mapping. |
| `EXECUTE IMMEDIATE 'dynamic sql'` | dbt Jinja templating composes the SQL at compile time; no runtime EXECUTE IMMEDIATE in Trino. | Move dynamic logic to Jinja. |

---

## 5. dbt materialization choice — a decision flowchart

```text
Is the model a simple type-clean + rename of a source table?
   YES -> view (stg_* convention)
   NO  -> continue

Is the model an intermediate reused by 3+ downstream models?
   YES -> table (or incremental if the source is huge)
   NO  -> continue

Is the model the final fact/dim that downstream dashboards query?
   YES -> Is the source delta small compared to the table size?
           YES -> incremental with merge strategy + unique_key
           NO  -> table (full daily rebuild)
   NO  -> continue

Is the model a small reusable intermediate referenced 1-2 times?
   YES -> ephemeral
   NO  -> default to view, revisit when performance issues surface
```

---

## 6. Worked end-to-end example: a nightly rollup procedure

This is the canonical migration: an Oracle procedure that uses a cursor loop, a temp table, and a final MERGE — the most common shape in legacy Oracle warehouses.

### 6.1 The Oracle source

```sql
-- ORACLE: nightly rollup of orders per (tenant, day)
-- Walks every order from yesterday, enriches with customer + currency,
-- accumulates into a temp table, then merges into the daily rollup fact.

CREATE OR REPLACE PROCEDURE load_orders_daily AS
  CURSOR c_orders IS
    SELECT o.order_id, o.tenant_id, o.customer_id, o.order_ts,
           o.amount_native, o.currency
    FROM orders o
    WHERE o.order_ts >= TRUNC(SYSDATE) - 1
      AND o.order_ts <  TRUNC(SYSDATE);

  v_order      c_orders%ROWTYPE;
  v_fx_rate    NUMBER;
  v_amount_usd NUMBER;
  v_status     VARCHAR2(20);
BEGIN
  -- step 1: stage to temp table
  EXECUTE IMMEDIATE 'TRUNCATE TABLE tmp_orders_enriched';

  OPEN c_orders;
  LOOP
    FETCH c_orders INTO v_order;
    EXIT WHEN c_orders%NOTFOUND;

    -- enrich: lookup fx rate
    SELECT NVL(rate, 1)
      INTO v_fx_rate
      FROM currency_fx
     WHERE currency = v_order.currency
       AND fx_date  = TRUNC(v_order.order_ts);

    v_amount_usd := v_order.amount_native * v_fx_rate;

    -- branch: status by amount
    IF v_amount_usd >= 10000 THEN
      v_status := 'LARGE';
    ELSIF v_amount_usd >= 100 THEN
      v_status := 'NORMAL';
    ELSE
      v_status := 'SMALL';
    END IF;

    INSERT INTO tmp_orders_enriched
      (order_id, tenant_id, customer_id, order_date,
       amount_native, currency, amount_usd, status)
    VALUES
      (v_order.order_id, v_order.tenant_id, v_order.customer_id,
       TRUNC(v_order.order_ts),
       v_order.amount_native, v_order.currency, v_amount_usd, v_status);
  END LOOP;
  CLOSE c_orders;

  -- step 2: merge into rollup fact
  MERGE INTO fct_orders_daily t
    USING (
      SELECT tenant_id, order_date,
             COUNT(*) AS order_count,
             SUM(amount_usd) AS total_usd,
             SUM(CASE WHEN status = 'LARGE' THEN 1 ELSE 0 END) AS large_count
      FROM tmp_orders_enriched
      GROUP BY tenant_id, order_date
    ) s
    ON (t.tenant_id = s.tenant_id AND t.order_date = s.order_date)
    WHEN MATCHED THEN UPDATE SET
      t.order_count = s.order_count,
      t.total_usd   = s.total_usd,
      t.large_count = s.large_count
    WHEN NOT MATCHED THEN INSERT
      (tenant_id, order_date, order_count, total_usd, large_count)
    VALUES
      (s.tenant_id, s.order_date, s.order_count, s.total_usd, s.large_count);

  COMMIT;
END load_orders_daily;
```

### 6.2 The dbt + Trino translation — the DAG

We replace the procedure with **three dbt models**:

```text
stg_orders        (view)         -- type-clean source
stg_currency_fx   (view)         -- type-clean source
fct_orders_daily  (incremental,  -- final rollup
                   merge,
                   unique_key=
                   tenant_id+order_date)
```

The cursor, temp table, IF/THEN branching, and MERGE all collapse into ONE SET-BASED SELECT inside `fct_orders_daily`.

### 6.3 `stg_orders.sql`

```sql
{{ config(materialized='view') }}

SELECT
  order_id,
  tenant_id,
  customer_id,
  order_ts,
  CAST(order_ts AS DATE) AS order_date,         -- Trino DATE, was Oracle TRUNC(order_ts)
  amount_native,
  currency
FROM {{ source('app', 'orders') }}
```

### 6.4 `stg_currency_fx.sql`

```sql
{{ config(materialized='view') }}

SELECT
  currency,
  fx_date,
  rate
FROM {{ source('app', 'currency_fx') }}
```

### 6.5 `fct_orders_daily.sql` — THE incremental rollup

```jinja
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key=['tenant_id', 'order_date'],
    on_schema_change='append_new_columns',
    properties={
      'format': 'PARQUET',
      'partitioning': "ARRAY['order_date']",
      'sorted_by': "ARRAY['tenant_id']",
      'format_version': 2
    }
) }}

WITH enriched AS (
  SELECT
    o.order_id,
    o.tenant_id,
    o.customer_id,
    o.order_date,
    o.amount_native,
    o.currency,
    o.amount_native * COALESCE(fx.rate, 1)                      AS amount_usd,    -- NVL -> COALESCE
    CASE
      WHEN o.amount_native * COALESCE(fx.rate, 1) >= 10000 THEN 'LARGE'           -- IF/THEN -> CASE
      WHEN o.amount_native * COALESCE(fx.rate, 1) >= 100   THEN 'NORMAL'
      ELSE 'SMALL'
    END                                                          AS status
  FROM {{ ref('stg_orders') }} o
  LEFT JOIN {{ ref('stg_currency_fx') }} fx                      -- cursor SELECT INTO -> LEFT JOIN
    ON fx.currency = o.currency
   AND fx.fx_date  = o.order_date
  WHERE o.order_date >= CURRENT_DATE - INTERVAL '1' DAY          -- SYSDATE-1 -> CURRENT_DATE - INTERVAL
    AND o.order_date <  CURRENT_DATE
  {% if is_incremental() %}
    AND o.order_date > (SELECT COALESCE(MAX(order_date), DATE '1970-01-01') FROM {{ this }})
  {% endif %}
)
SELECT
  tenant_id,
  order_date,
  COUNT(*)                                                    AS order_count,
  SUM(amount_usd)                                             AS total_usd,
  SUM(CASE WHEN status = 'LARGE' THEN 1 ELSE 0 END)           AS large_count
FROM enriched
GROUP BY tenant_id, order_date
```

### 6.6 What changed and why

| Oracle construct | Trino + dbt expression | Why |
|---|---|---|
| `CURSOR c_orders ... LOOP ... END LOOP` | `WITH enriched AS (SELECT ... FROM orders LEFT JOIN currency_fx ...)` | The cursor body is now a relational SELECT. All rows processed in parallel. |
| `SELECT NVL(rate, 1) INTO v_fx_rate FROM currency_fx WHERE ...` | `LEFT JOIN currency_fx ... ; COALESCE(fx.rate, 1)` | Per-row lookup -> join. NULL fallback via COALESCE. |
| `IF v_amount_usd >= 10000 THEN ... ELSIF ...` | `CASE WHEN amount_usd >= 10000 THEN ... WHEN ... ELSE ... END` | Branching -> CASE. |
| `tmp_orders_enriched` temp table | `enriched` CTE | The intermediate stage lives inside the same SELECT. |
| `MERGE INTO fct_orders_daily USING (...) ON ... WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT` | dbt config `materialized='incremental', incremental_strategy='merge', unique_key=['tenant_id', 'order_date']` | dbt-trino generates the Trino MERGE statement for you. |
| `TRUNCATE tmp_orders_enriched; ...; COMMIT;` | implicit — Iceberg commits one new snapshot atomically per dbt model run | No manual transaction control. |
| `SYSDATE`, `TRUNC(order_ts)` | `CURRENT_DATE`, `CAST(order_ts AS DATE)` | Trino dialect. |
| `NVL(...)` | `COALESCE(...)` | Trino dialect. |
| Cursor `c_orders%ROWTYPE` local var | (gone — no local vars needed) | SQL is set-based; no scalar accumulators. |

### 6.7 dbt tests to add (replacing Oracle EXCEPTION handlers)

```yaml
# models/marts/fct_orders_daily.yml
version: 2
models:
  - name: fct_orders_daily
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns: [tenant_id, order_date]
    columns:
      - name: tenant_id
        tests: [not_null]
      - name: order_date
        tests: [not_null]
      - name: total_usd
        tests:
          - dbt_utils.expression_is_true:
              expression: ">= 0"
```

These tests run after `dbt run`. A failure breaks the pipeline — same semantic role as `EXCEPTION WHEN ...` in the Oracle procedure, except cleaner because the test condition is declarative.

---

## 7. Cutover checklist (the non-obvious gotchas)

Once your models compile and run, before you turn off Oracle:

1. **Empty-string vs NULL audit.** Search every Oracle source SQL for `IS NULL` / `IS NOT NULL` / `NVL(x, '...')` and decide per-occurrence whether the Oracle quirk was load-bearing. Common fixes: `COALESCE(NULLIF(col, ''), default)`.
2. **Date precision.** Oracle `DATE` = date+time; Trino `DATE` = date only. If you migrated a time-bearing Oracle DATE column to a Trino `DATE`, you silently lost the time component. Audit and rewrite to `TIMESTAMP` where needed.
3. **Implicit coercion audit.** Search WHERE clauses for `<integer_col> = '<string>'`-style comparisons. Trino will fail to parse these. Add explicit `CAST(...)`.
4. **Number precision.** Oracle `NUMBER` is variable-precision; Trino requires you to pick `decimal(p,s)` / `bigint` / `double`. Picking `double` for money introduces rounding errors. **Always `decimal(p,s)` for currency.**
5. **Surrogate key stability.** If your Oracle pipeline relied on `seq.NEXTVAL` for surrogate keys, downstream foreign keys reference those values. The hash-based replacement (`md5(natural_keys)`) is stable across re-runs but will NOT match the Oracle-generated values. You need either a one-time migration table mapping old-key -> new-key OR a re-keying pass on all dependent tables.
6. **Row diff against Oracle.** Pick 3-5 representative rollup rows, compute them in Oracle and in Trino on the same source data, and diff. Don't trust column-level aggregate sums alone — they can match even when row-level results differ.
7. **EXPLAIN the migrated SELECTs.** Look for `CorrelatedJoin` in the EXPLAIN — it's a sign decorrelation failed (your cursor-loop translated naively). See [resource 28 §3](28-complex-sql-performance-trino-dbt.md) for rewrites.
8. **Partition the migrated table to match the dominant filter.** Oracle table partitioning hints don't carry over — set `partitioning=ARRAY['<column>']` in the dbt `properties` block. See [resource 10](10-lakehouse-partitioning.md).
9. **Schedule the dbt run.** Oracle's `DBMS_SCHEDULER.CREATE_JOB` has no dbt equivalent — schedule `dbt run --select fct_orders_daily+` from cron, k8s CronJob, or Airflow.
10. **Maintenance.** Iceberg tables need `ALTER TABLE ... EXECUTE optimize` and `expire_snapshots` regularly — see [resource 17](17-iceberg-table-maintenance.md). Oracle's auto-segment-management has no direct equivalent; you schedule the maintenance.

---

## 8. Cross-references

- **Performance of migrated queries:** [resource 28 — Improving complex SQL performance on Trino with dbt](28-complex-sql-performance-trino-dbt.md) — addresses correlated subqueries, deep CTE chains, OR-heavy predicates, EXPLAIN-driven optimization. **READ THIS NEXT** if your migrated dbt models are slow.
- **SQL best practices on Trino:** [resource 23](23-sql-best-practices-olap.md) — partition filters, approximate functions, SELECT * avoidance.
- **Partitioning the target Iceberg table:** [resource 10](10-lakehouse-partitioning.md) — partition transform choice, hidden partitioning.
- **Maintenance for the Iceberg-backed dbt output:** [resource 17](17-iceberg-table-maintenance.md) — `optimize`, `expire_snapshots`, `remove_orphan_files`.
- **Federation if Oracle stays alive during cutover:** [resource 22](22-trino-federation-postgresql.md) — predicate pushdown, dynamic filtering, when to ingest vs federate. (Trino has an Oracle connector with similar properties.)
- **Materialized views for rollups instead of dbt incremental:** [resource 25](25-trino-materialized-views-iceberg.md) — Iceberg-backed Trino MVs for dashboard aggregations.
- **Iceberg + Hive Metastore basics:** [resource 21](21-hive-metastore-iceberg.md).
- **Ingestion patterns:** [resource 13 — Postgres-to-Iceberg ingestion](13-postgres-to-iceberg-ingestion.md) — full refresh, incremental, CDC, JSONB handling.

---

## 9. Reference URLs verified for this resource

- Trino SQL statement support: https://trino.io/docs/current/language/sql-support.html
- Trino SELECT (WITH RECURSIVE, LIMIT, JOIN): https://trino.io/docs/current/sql/select.html
- Trino Iceberg connector: https://trino.io/docs/current/connector/iceberg.html
- Trino types: https://trino.io/docs/current/language/types.html
- Trino functions and operators: https://trino.io/docs/current/functions.html
- dbt-trino configurations: https://docs.getdbt.com/reference/resource-configs/trino-configs
- dbt materializations: https://docs.getdbt.com/docs/build/materializations
- dbt incremental strategies: https://docs.getdbt.com/docs/build/incremental-strategy
- Apache Iceberg docs: https://iceberg.apache.org/docs/latest/
- Oracle SQL Language Reference (NULLs): https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Nulls.html
