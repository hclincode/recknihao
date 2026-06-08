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
| "Trino has `sequence.NEXTVAL` for surrogate keys — I'll port my Oracle sequences directly." | **FALSE — Trino has NO sequences, NO `NEXTVAL`, NO `CURRVAL`.** There is a `sequence()` table function and a `sequence` array generator, but those are different (range generators, not persistent counters). For surrogate keys on Iceberg, use one of: (a) **PRIMARY — `dbt_utils.generate_surrogate_key([col_list])`** (MD5 hash, idempotent across runs/clusters, returns VARCHAR — not numeric); (b) **FALLBACK — `row_number() OVER (ORDER BY ...)`** (only stable within a single full-refresh run; the mapping changes on rebuild — do NOT use for stable cross-run keys). **Iceberg does NOT have user-facing identity / auto-increment columns** — the [apache/iceberg #12297](https://github.com/apache/iceberg/issues/12297) feature request was **CLOSED AS NOT PLANNED** (Aug 2025); the feature is NOT in the V2 spec, NOT in V3, and is NOT on the roadmap. See §4.5A ICEBERG-IDENTITY-COLUMN-NEGATION GUARDRAIL for the canonical fix. **DO NOT WRITE `my_seq.NEXTVAL` in a dbt model — it will fail.** | [Trino SELECT docs](https://trino.io/docs/current/sql/select.html); [dbt_utils](https://github.com/dbt-labs/dbt-utils); [apache/iceberg #12297 (closed as not planned)](https://github.com/apache/iceberg/issues/12297) |
| "Trino has `ROWNUM` — I can use it for top-N just like Oracle." | **FALSE on Trino 467 — `ROWNUM` is an Oracle-only pseudocolumn, not in Trino.** The Trino-equivalent patterns are: (a) **`LIMIT N`** (for "first N rows" — Trino's order-preserving LIMIT after ORDER BY); (b) **`row_number() OVER (PARTITION BY ... ORDER BY ...)`** (for top-N-per-group, accessed via outer `WHERE rn <= N`). Oracle's `WHERE ROWNUM <= N` translates to `... ORDER BY ... LIMIT N`. **DO NOT WRITE `WHERE ROWNUM <= 10` in Trino — parse error.** | [Trino SELECT - LIMIT](https://trino.io/docs/current/sql/select.html) |
| "Oracle's `''` = NULL behavior carries over to Trino — I don't need to change my WHERE clauses." | **FALSE — and this is the silent-bug champion of the migration.** Oracle treats the empty string `''` as NULL (a long-standing quirk: `'' IS NULL` returns TRUE in Oracle). **Trino treats `''` as a normal zero-length string distinct from NULL: `'' IS NULL` returns FALSE in Trino.** Real-world consequence: an Oracle query `WHERE name IS NOT NULL` that historically filtered out both NULL names AND empty-string names will, after migration, **silently start including empty-string names**, often changing aggregate counts and breaking downstream joins. **The fix:** audit every `IS NULL` / `IS NOT NULL` / `NVL(col, ...)` in the source procedures and, where the original logic depended on the Oracle quirk, rewrite to explicit `col IS NULL OR col = ''` (or the inverse). | [Oracle SQL Language Reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Nulls.html) — "Oracle Database currently treats a character value with a length of zero as null" |
| "Trino's `MERGE INTO` doesn't work on Iceberg / requires a special connector flag." | **FALSE — MERGE on Iceberg is supported in Trino 467 by default, no flag.** MERGE is the canonical Trino-side upsert form for Iceberg tables. dbt-trino's `incremental_strategy='merge'` is built on top of it and is the recommended SCD-1 pattern. (What MAY require flags is MERGE on JDBC connectors like PostgreSQL/MySQL — see [resource 22](22-trino-federation-postgresql.md). On the Iceberg connector it's on out of the box.) | [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html); [dbt-trino merge strategy](https://docs.getdbt.com/reference/resource-configs/trino-configs#the-merge-strategy) |
| "Oracle's `CONNECT BY PRIOR ... START WITH ...` hierarchical syntax works in Trino — it's a common SQL extension." | **FALSE — Trino has NO `CONNECT BY`.** The replacement is **`WITH RECURSIVE`** (ANSI SQL standard, supported since **Trino 340 (8 Aug 2020)** per [PR #4250](https://github.com/trinodb/trino/pull/4250) and [release-340.html](https://trino.io/docs/current/release/release-340.html) — well before Trino 467, so always available on this stack). A recursive CTE must be shaped as `WITH RECURSIVE t(cols) AS (base_query UNION ALL recursive_step) SELECT ...`. **Caveats:** (1) The Trino docs at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) flag `WITH RECURSIVE` as **experimental**: "This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload." (2) **Default `max_recursion_depth = 10`** — a small integer, NOT 100, NOT 1000. The Trino docs verbatim: *"recursion depth is fixed, defaults to `10`, and doesn't depend on the actual query results"* (trino.io/docs/current/sql/select.html). Session-tunable via `SET SESSION max_recursion_depth = N`. **Exceeding the cap RAISES AN ERROR — `NOT_SUPPORTED: Recursion depth limit exceeded (10). Use 'max_recursion_depth'` — it does NOT silently truncate.** To walk a tree 15 / 20 / 50 levels deep, you MUST `SET SESSION max_recursion_depth = <N>` (raise it to at least the expected depth) BEFORE running the recursive query. A `WHERE t.depth < 20` guard inside the recursive term does NOT bypass the engine cap — the guard's bound must be `<=` the cap, or you must raise the cap first. (3) The query-plan growth is **quadratic with recursion depth** — Trino docs verbatim: *"the size of the query plan growth is quadratic with the recursion depth"* (trino.io/docs/current/sql/select.html). Doubling depth roughly quadruples plan size and planning time. Don't set `max_recursion_depth` absurdly high (e.g., 10,000) — set it to your data's known max depth + a small margin. For very deep org charts or BOMs, materialize a closure table as a pre-computed dbt model instead of computing recursively at read time. See §7A.1 caveat #3 for the full pattern. **DO NOT WRITE `CONNECT BY PRIOR` in a dbt model — parse error.** **DO NOT WRITE** "`max_recursion_depth` defaults to 1000", "default 100", "default 1000", "defaults to 1000 session property" — all wrong; the real default is **10**. **DO NOT WRITE** "exceeding `max_recursion_depth` silently truncates the result" — wrong; it raises `NOT_SUPPORTED`. Worked shape: `SET SESSION max_recursion_depth = 50;` then run the `WITH RECURSIVE org_tree(...) AS (base UNION ALL recursive_step) SELECT * FROM org_tree;` query. | [Trino SELECT - WITH RECURSIVE](https://trino.io/docs/current/sql/select.html); [PR #4250](https://github.com/trinodb/trino/pull/4250); [release-340.html](https://trino.io/docs/current/release/release-340.html) |
| "Oracle `(+)` outer-join syntax is also valid in Trino." | **FALSE — `(+)` is Oracle-proprietary, parse error in Trino.** Rewrite to ANSI `LEFT JOIN` / `RIGHT JOIN` syntax. (Modern Oracle docs also recommend ANSI joins over `(+)`.) | [Trino SELECT - JOIN](https://trino.io/docs/current/sql/select.html#join-clause) |
| "Oracle implicit `varchar` -> `number` coercion (`WHERE int_col = '42'`) works in Trino." | **FALSE — Trino is strict about types.** Comparing `int_col = '42'` (`bigint = varchar`) raises `TYPE_MISMATCH`. You must `CAST(int_col AS varchar) = '42'` or `int_col = CAST('42' AS bigint)`. Most Oracle PL/SQL written before ~2015 relies heavily on implicit coercion; expect to add explicit `CAST` calls everywhere. | [Trino types](https://trino.io/docs/current/language/types.html) |
| "I should port my Oracle exception handlers (`EXCEPTION WHEN NO_DATA_FOUND THEN ...`) to dbt." | **FALSE — there is no exception block in dbt or Trino SQL.** The replacement is **dbt tests** (`not_null`, `unique`, `accepted_values`, `relationships`, plus custom singular tests) which run after the model builds and fail the run if violated. For "soft" guards inside a transformation (e.g., "if dim is missing, default to UNKNOWN"), use `COALESCE`, `CASE WHEN`, or `LEFT JOIN` with a NULL fallback. **DO NOT WRITE `EXCEPTION WHEN ...` in a dbt model.** | [dbt tests](https://docs.getdbt.com/docs/build/data-tests) |
| "I can change Trino's session timezone with `SET SESSION time_zone = 'America/New_York'` (like PostgreSQL / MySQL)." | **FALSE — there is NO `time_zone` session property in Trino.** Running `SET SESSION time_zone = '...'` errors with "Session property time_zone does not exist". The valid forms are: (a) the dedicated **`SET TIME ZONE 'America/New_York'`** COMMAND (a separate statement form, NOT a `SET SESSION property = value` assignment); (b) `SET TIME ZONE LOCAL` / `SET TIME ZONE INTERVAL '-08:00' HOUR TO MINUTE`; (c) `sql.forced-session-time-zone` SERVER CONFIG property (cluster-level, overrides session); (d) `expr AT TIME ZONE 'zone'` per-expression. See **§4.2A TRINO-SESSION-TIMEZONE GUARDRAIL** for the worked SYSDATE/ET example. **DO NOT WRITE `SET SESSION time_zone = '...'` or `SET SESSION timezone = '...'` — both are invented syntax.** | [Trino SET TIME ZONE](https://trino.io/docs/current/sql/set-time-zone.html); [Trino datetime functions](https://trino.io/docs/current/functions/datetime.html) |
| "Trino's NULLS-default ordering matches Oracle's — `ORDER BY ts DESC` puts NULLs at the top in both engines." | **FALSE — Trino and Oracle disagree on the NULLS default, and it is the silent-wrong row-ordering champion of the migration.** Per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) verbatim: "The default null ordering is `NULLS LAST`, regardless of the ordering direction." Trino defaults `NULLS LAST` for **both** `ASC` and `DESC`. Oracle defaults `NULLS LAST` for `ASC` and `NULLS FIRST` for `DESC`. So `ORDER BY ts DESC` puts NULLs at the **top** in Oracle but at the **bottom** in Trino — same query, different row order, **no error message**. See **§ LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY** immediately below. **Always write explicit `NULLS FIRST` / `NULLS LAST` when migrating Oracle `ORDER BY ... DESC` queries (and inside window-function `OVER (... ORDER BY ...)`).** | [Trino SELECT — ORDER BY](https://trino.io/docs/current/sql/select.html); [Oracle SQL Language Reference — ORDER BY](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/SELECT.html) |

> **Why these specific myths matter.** Each is a load-bearing translation that an engineer with Oracle muscle memory will write reflexively on day one — and each will either fail to parse (visible failure, easy to fix) OR silently change query results (invisible failure, hard to detect). The empty-string-is-NULL myth, the implicit-coercion myth, and the **NULLS-default myth (Trino defaults `NULLS LAST` regardless of direction, while Oracle defaults `NULLS FIRST` for `DESC`)** are the three most dangerous because none of them produce a parse error: the migrated model runs, but the numbers — or the row ordering — no longer match the Oracle source. **Always diff a representative sample of rows between Oracle and Trino during cutover.**

---

## LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY (read this BEFORE migrating any `ORDER BY ... DESC` query)

> **Read this section every time you migrate an Oracle `ORDER BY` clause.** This is the third confirmed cross-dialect-spillover variant (after `/*+ hints */` and `::` cast — see §4.4B). It is the most subtle because the failure mode is **silent-wrong row ordering with no error message**.

### The two facts, side by side (WebSearch-verified at trino.io/docs/current/sql/select.html and docs.oracle.com)

| Engine | Default `NULLS` placement for `ORDER BY col ASC` | Default `NULLS` placement for `ORDER BY col DESC` | Authoritative pointer |
|---|---|---|---|
| **Trino 467** | **`NULLS LAST`** (NULLs at the bottom) | **`NULLS LAST`** (NULLs at the bottom — **regardless of direction**) | [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) — verbatim: "The default null ordering is `NULLS LAST`, regardless of the ordering direction." |
| **Oracle 11g/12c/19c/23c** | **`NULLS LAST`** (NULLs at the bottom) | **`NULLS FIRST`** (NULLs at the **top**) | [Oracle SQL Language Reference — ORDER BY](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/SELECT.html) — "if the null ordering is not specified, then the handling of the null values is `NULLS LAST` if the sort is `ASC`, `NULLS FIRST` if the sort is `DESC`." |

**The one-sentence summary.** `ORDER BY col DESC` puts NULLs at the **top** in Oracle but at the **bottom** in Trino — and there is no parse error, no warning, no `EXPLAIN` annotation telling you the ordering differs. Reports and downstream consumers that depended on Oracle's "NULLs-first-for-DESC" default will silently produce different output on Trino.

### The silent-wrong worked example — same data, same query, different row order

Source table `tasks` on both engines:

| id | priority | description |
|---|---|---|
| 1 | 5 | urgent fix |
| 2 | NULL | unassigned |
| 3 | 3 | review docs |
| 4 | NULL | triage backlog |
| 5 | 1 | nice-to-have |

The migrated query (same SQL text on both engines):

```sql
SELECT id, priority, description
FROM tasks
ORDER BY priority DESC;
```

**On Oracle** (NULLS FIRST is the DESC default):

| id | priority | description |
|---|---|---|
| 2 | NULL | unassigned |
| 4 | NULL | triage backlog |
| 1 | 5 | urgent fix |
| 3 | 3 | review docs |
| 5 | 1 | nice-to-have |

**On Trino 467** (NULLS LAST is the default for BOTH directions):

| id | priority | description |
|---|---|---|
| 1 | 5 | urgent fix |
| 3 | 3 | review docs |
| 5 | 1 | nice-to-have |
| 2 | NULL | unassigned |
| 4 | NULL | triage backlog |

**Same data, same SQL, no errors — but rows 2 and 4 moved from the top to the bottom of the result set.** Any consumer that read the first row, the top-N rows, or assumed NULLs would be visually grouped at the top will silently break.

### The defensive rule — ALWAYS write explicit `NULLS FIRST` / `NULLS LAST` on migration

When migrating Oracle `ORDER BY` to Trino, **never rely on either engine's default**. Always specify `NULLS FIRST` or `NULLS LAST` explicitly. This eliminates the ambiguity and makes the migration grep-able for review.

Preserving Oracle behavior (NULLs at the top on DESC):

```sql
-- Trino target — preserves Oracle's NULLs-at-top DESC ordering:
SELECT id, priority, description
FROM tasks
ORDER BY priority DESC NULLS FIRST;
```

Preserving Trino's default (NULLs at the bottom on DESC) — explicit so reviewers see the intent:

```sql
-- Trino target — explicit Trino default, NULLs at the bottom:
SELECT id, priority, description
FROM tasks
ORDER BY priority DESC NULLS LAST;
```

### Window functions inside `OVER (... ORDER BY ...)` — same rule applies

The NULLS-default disagreement also affects `ROW_NUMBER()`, `RANK()`, `LAG()`, `LEAD()`, `FIRST_VALUE()`, `LAST_VALUE()`, and every other window function whose `OVER` clause has an `ORDER BY`. The "latest per group" pattern is the canonical victim:

```sql
-- Oracle source — RELIED on Oracle's DESC default (NULLs at the top, so NULL ts rows
-- get rn = 1 and would be picked as the "latest"):
SELECT *
FROM (
    SELECT customer_id, order_date, amount,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) AS rn
    FROM   orders
)
WHERE rn = 1;

-- Trino target — by default NULLs go LAST in DESC, so a row with NULL order_date
-- gets the HIGHEST rn (not 1), and a NON-NULL row is picked as rn = 1. This is
-- usually what the engineer ACTUALLY wanted, but it DIFFERS from Oracle behavior.
-- If you need to preserve Oracle behavior verbatim, add NULLS FIRST:
SELECT *
FROM (
    SELECT customer_id, order_date, amount,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC NULLS FIRST) AS rn
    FROM   {{ ref('stg_orders') }}
)
WHERE rn = 1;
```

The defensive discipline is identical to the top-level `ORDER BY` rule: **always write `NULLS FIRST` or `NULLS LAST` inside `OVER (... ORDER BY ...)` when migrating Oracle window-function code**. Do not assume the Trino default matches Oracle's.

### Migration checklist — Oracle `ORDER BY ... DESC` audit

When auditing legacy Oracle source for migration:

1. **Grep the source Oracle code for `ORDER BY ... DESC`** (both top-level and inside `OVER (... ORDER BY ... DESC)`).
2. **For each hit, decide whether Oracle's NULLS-FIRST-for-DESC default was load-bearing for downstream consumers.** Common signals: the consumer is a report that displays NULLs as "Unassigned" at the top; a dashboard that fetches the first row; a top-N feed; a `WHERE ROWNUM <= N` wrapper that depended on the NULL rows being in the top-N.
3. **Rewrite the Trino target with explicit NULLS placement:**
   - If Oracle's NULLs-at-top behavior must be preserved → `ORDER BY col DESC NULLS FIRST`.
   - If downstream is robust to NULL placement (or NULLs were never in the column) → `ORDER BY col DESC NULLS LAST` (explicit, matches Trino default, but spelled out for grep-ability).
4. **Diff a representative sample of rows between Oracle and Trino during cutover** — for any query whose first-row identity matters, run the same SQL on both engines, compare the top-K rows, and confirm the row order matches.

### DO-NOT-WRITE — banned claims about Trino's NULLS-default behavior

> | Banned claim | Why it is wrong | Correct claim |
> |---|---|---|
> | "Trino defaults `NULLS FIRST` for `DESC`." | That is **Oracle's** default rule, NOT Trino's. Trino's docs say verbatim: "The default null ordering is `NULLS LAST`, regardless of the ordering direction." | Trino defaults `NULLS LAST` for `DESC` (and for `ASC`). |
> | "Trino defaults `NULLS LAST` for `ASC` and `NULLS FIRST` for `DESC`." | That is Oracle's rule projected onto Trino — the exact cross-dialect-spillover fab class iter456 / iter459 flagged. | Trino defaults `NULLS LAST` for both `ASC` and `DESC`. |
> | "Trino's NULLS-default behavior matches Oracle's." | It does NOT. Oracle's default depends on direction; Trino's default does not. | The two engines disagree on `DESC` (Oracle puts NULLs first, Trino puts NULLs last). |
> | "Trino follows ANSI SQL's default for NULLS ordering." | ANSI SQL leaves the NULLS-default **implementation-defined**. Trino chose `NULLS LAST` regardless of direction; Oracle chose a direction-dependent rule. Neither is "the ANSI default." | Trino's NULLS default is its own design choice (`NULLS LAST` for both directions); cite the Trino docs directly. |
> | **"Trino (and standard SQL) defaults to `NULLS LAST`."** / **"Trino and standard SQL both default `NULLS LAST`."** | **The exact iter460 imprecision.** ANSI SQL is **silent / implementation-defined** on the NULLS default — only Trino is bound to `NULLS LAST`. Welding the words "Trino" and "standard SQL" together as if they share a default is wrong: each implementation picks its own. PostgreSQL defaults `NULLS LAST` for `ASC` / `NULLS FIRST` for `DESC` (same as Oracle); SQL Server treats NULLs as the lowest value (NULLs first on `ASC`, last on `DESC`) and does NOT support the `NULLS FIRST`/`LAST` syntax; Snowflake's default is **configurable** via `DEFAULT_NULL_ORDERING` (not a fixed engine constant). "Standard SQL" picks none of them. | "**Trino** defaults `NULLS LAST` regardless of direction **per the [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) docs**" — bind the claim to the Trino docs, NOT to "standard SQL." |
> | "You don't need `NULLS FIRST` / `NULLS LAST` because Trino does the right thing by default." | Trino has a default, but "the right thing" is consumer-specific. A migration that relied on Oracle's `NULLS FIRST` DESC default will silently break unless the Trino target explicitly preserves it. | Always specify `NULLS FIRST` / `NULLS LAST` explicitly when migrating Oracle `ORDER BY`. |

### Named callout — ANSI SQL does NOT pin a default for NULLS ordering

> **CRITICAL — read before binding "Trino" and "standard SQL" together in the same sentence.**
>
> The SQL:2016 standard (ISO/IEC 9075) **does not specify** a default for NULLS placement in `ORDER BY`. The standard introduces the optional `NULLS FIRST` / `NULLS LAST` clause but leaves the default *implementation-defined*. This means:
>
> - **Trino's default = `NULLS LAST` regardless of direction** (per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) verbatim).
> - **Oracle's default = `NULLS LAST` for `ASC`, `NULLS FIRST` for `DESC`** (per docs.oracle.com — Oracle SQL Language Reference).
> - **PostgreSQL's default = `NULLS LAST` for `ASC`, `NULLS FIRST` for `DESC`** (same shape as Oracle, per postgresql.org/docs/current/queries-order.html — verbatim: "By default, null values sort as if larger than any non-null value; that is, NULLS FIRST is the default for DESC order, and NULLS LAST otherwise.").
> - **SQL Server's default = NULLs treated as lowest value** (so NULLs appear first on `ASC`, last on `DESC`); SQL Server does **NOT support the `NULLS FIRST` / `NULLS LAST` syntax** — workaround is `ORDER BY CASE WHEN col IS NULL THEN 0 ELSE 1 END, col` (per learn.microsoft.com).
> - **Snowflake's default is configurable** via the `DEFAULT_NULL_ORDERING` parameter (default `FIRST`: NULLs first on `ASC`, last on `DESC`); the default itself can be changed at the account/session level — so even within Snowflake the "default" is not a fixed engine constant (per docs.snowflake.com/en/sql-reference/constructs/order-by).
>
> **There is no "ANSI default" or "standard SQL default" to fall back on.** When you cite a NULLS-ordering default, **you must name the specific engine** (Trino) and **point to its docs** — never write "Trino and standard SQL both default to NULLS LAST" or "Trino follows the SQL standard's NULLS default." Both phrasings are factually wrong.
>
> **Allowed phrasings (copy these):**
> - "Trino defaults to `NULLS LAST` regardless of direction (per the Trino docs)."
> - "Trino's NULLS default — defined by Trino, not by ANSI SQL — is `NULLS LAST` for both `ASC` and `DESC`."
> - "Per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html), Trino's default NULLS ordering is `NULLS LAST` regardless of the ordering direction."
>
> **Banned phrasings (do NOT write these):**
> - "Trino (and standard SQL) defaults to `NULLS LAST`."
> - "Trino and standard SQL both default `NULLS LAST`."
> - "Trino follows the ANSI/SQL-standard NULLS default."
> - "Per the SQL standard, NULLs go last by default."

### Cross-reference — this is the 3rd confirmed cross-dialect-spillover variant

This NULLS-default fab is the **third** confirmed variant of the same cross-dialect-spillover failure class flagged in §4.4B:

| Variant # | Iteration | Spillover form | Why it is wrong on Trino 467 |
|---|---|---|---|
| 1 | iter456 Q2 | `/*+ USE_HASH_JOIN */` Oracle/Spark query-hint | Trino has no hint mechanism — the comment is parsed and ignored, silent no-op |
| 2 | iter456 Q4 | `expr::type` PostgreSQL cast operator | Trino has no `::` operator — parse error |
| 3 | **iter459 Q4** | **Oracle NULLS-FIRST-for-DESC default semantics** | **Trino defaults `NULLS LAST` regardless of direction — silent-wrong row ordering** |

**The meta-rule (memorize and apply EVERY time you state a Trino default or semantic):** whenever you cite a Trino behavior that "matches" another engine's behavior, **WebSearch trino.io/docs to confirm** — do NOT trust muscle memory from Oracle, PostgreSQL, Spark, or Snowflake. The default rules differ in subtle, silently-wrong ways that a parse error will never catch. Cross-ref **§4.4B CROSS-DIALECT-SPILLOVER GUARDRAIL** for the consolidated table of every confirmed spillover form.

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

> **Cross-ref — dbt snapshots / SCD2 / timestamp vs check strategy / check_cols / dbt_valid_from / dbt_valid_to / dbt_scd_id / dbt_is_deleted:** see **[resource 09 § Slowly Changing Dimensions — Option 1 dbt snapshot (§1a `strategy='timestamp'`, §1b `strategy='check'`)](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd)** — the SINGLE source of truth on this stack. The Oracle SCD-2 procedure typically becomes a dbt **snapshot** (Option 1) rather than a `materialized='incremental'` model. Snapshot mechanics are NOT duplicated here.

### 3.1 The four materializations supported by dbt-trino

Verified against [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) and [docs.getdbt.com/docs/build/materializations](https://docs.getdbt.com/docs/build/materializations).

| Materialization | DB object created | Stores row data? | Storage cost | What dbt emits on `dbt run` | When to use | When NOT to use |
|---|---|---|---|---|---|---|
| **`view`** | A **VIEW** (a stored SELECT definition — just the query text) | **NO — only the SQL** | **Negligible** (~bytes of catalog text) | `CREATE OR REPLACE VIEW ... AS <SELECT>` — re-executes the SELECT on every read | Cheap pass-through transforms; `stg_*` models where source is small or already well-partitioned; when freshness-on-read matters and re-execution cost is acceptable | Expensive multi-join queries downstream models hit repeatedly — every downstream read re-pays the join cost |
| **`table`** | A **TABLE** (Parquet files in MinIO + Iceberg manifests) | **YES — every row** | **Full** (sum of Parquet files) | `CREATE OR REPLACE TABLE ... AS SELECT ...` — full CTAS each run; Iceberg snapshot replaces prior data atomically | Big intermediates referenced by 3+ downstream models; daily full-refresh facts that aren't too large; dim tables that fully reload | Multi-terabyte tables where most rows don't change — use `incremental` instead |
| **`incremental`** | A **TABLE**, delta-built | **YES — every row** | **Full** (like `table`) | First run: CTAS. Later runs: process delta via `is_incremental()` + `incremental_strategy` (`append` / `merge` / `delete+insert` / `microbatch`) | The high-volume daily-append/upsert case — fact tables, event tables, anything where the delta is small relative to the whole. **The standard target for an Oracle procedure that ended in nightly MERGE.** | Models small enough that merge overhead exceeds the cost of full rebuild (~under 10M rows on this stack) |
| **`ephemeral`** | **NONE — no warehouse object at all** | N/A (no object) | **Zero** (nothing in warehouse) | No DDL emitted for the ephemeral itself; dbt **inlines its SELECT as a CTE** at compile time into every downstream that `ref()`s it | Small reusable intermediates referenced by 1-2 downstream models where keeping the warehouse clean matters and the SELECT is short (under ~30 lines) | Anything referenced by 3+ downstreams (compile-time SQL bloat — same SELECT inlined N times → planner stress + no debuggable object); anything large enough to benefit from real materialization |

> **DO-NOT-WRITE — banned framings (these mis-teach the cost model):**
>
> | WRONG | WHY it's wrong |
> |---|---|
> | "A `view` creates a persistent table." | A view is **not** a table. `CREATE VIEW` stores a SELECT definition, not row data. |
> | "A `view` takes up storage / costs storage." | A view stores only the SELECT text. Row data is **not** persisted. Storage = negligible (~kilobytes of catalog text). |
> | "A `view` is queryable stored data." | The view's RESULT is queryable, but it is NOT stored data — the SELECT re-executes against underlying tables on every query. |
> | "A `view` can be indexed in Trino" / "add an index on the view column to speed it up." | Trino has **NO user-creatable secondary indexes** on any object — view OR table. The Iceberg connector exposes NO `CREATE INDEX` statement. See **[resource 03 § Iceberg mitigations when you DO need point lookups](03-columnar-storage.md#iceberg-mitigations-when-you-do-need-point-lookups-on-a-fact-table)** for the canonical "how to make Trino + Iceberg filter fast" — partition transforms, `sorted_by` + `EXECUTE optimize`, `ANALYZE` → Puffin NDV, Parquet bloom filters. |
| "Ephemeral takes up storage when referenced by many downstreams." | Ephemeral has **zero** warehouse storage no matter the downstream count. The bloat is in **compiled SQL text** (dbt side, at compile time), not in MinIO bytes. See **[resource 28 § 3.3A — the REAL ephemeral-at-scale failure mode](28-complex-sql-performance-trino-dbt.md#33a-the-real-ephemeral-at-scale-failure-mode--compile-time-sql-bloat)** for the load-bearing compile-time-SQL-bloat canonical. |

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
      'format': "'PARQUET'",
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
- `properties` is the dbt-trino-specific block. **Inside this dict, the partitioning key for an Iceberg-catalog model is `partitioning`** (matching the bare-Trino DDL key for the Iceberg connector). dbt-trino's `properties()` macro passes dict keys verbatim into the `WITH (...)` clause; the Iceberg connector defines its partition-spec property as `partitioning` per [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). The Hive connector's analogous property IS `partitioned_by` — but the production stack here uses the Iceberg connector, so `partitioning` is the right key. See [resource 28 § LEADING CANONICAL — dbt-trino partition key for Iceberg vs Hive](28-complex-sql-performance-trino-dbt.md) for the full three-surface DO-WRITE / DO-NOT-WRITE contrast block. **Partition the migrated table by the same column the Oracle table was partitioned on (or whatever the dominant filter is — see [resource 10](10-lakehouse-partitioning.md)).**
- `{% if is_incremental() %}` is the CANONICAL incremental delta-filter guard. It is True ONLY when (a) the target table already exists, (b) the run is NOT `--full-refresh`, and (c) the model is configured as incremental. On first run it's FALSE (no WHERE filter, full CTAS); on subsequent runs it's TRUE (filter applied, MERGE on the delta). **NOTE: do NOT use `{% if execute %}` here — `execute` is True during both `dbt compile` and `dbt run` and does NOT gate first-build / `--full-refresh` vs incremental.** See [docs.getdbt.com/reference/dbt-jinja-functions/execute](https://docs.getdbt.com/reference/dbt-jinja-functions/execute) and [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models).
- `on_schema_change='append_new_columns'` adds new source columns automatically on incremental runs (the safe default). Other options: `'ignore'` (don't add — **this is the dbt default, and is what causes "I added a column to my incremental model and the new column is silently missing from the output" — fix = set `'append_new_columns'`**), `'fail'`, `'sync_all_columns'` (also drops removed columns — dangerous). **DO-NOT-CONFUSE with dbt contracts (§6.7C): `on_schema_change` controls incremental-merge column handling on the TARGET; contracts are a build-time declared-vs-actual preflight. The silent-new-column-missing question is `on_schema_change`, NOT contracts.** Canonical detail: [resource 13 § `on_schema_change` — the FOUR options and the correct default](13-postgres-to-iceberg-ingestion.md).

---

## 4. Oracle SQL -> Trino SQL: the two-column translation table

These are the per-expression rewrites you'll do on almost every migrated SELECT. Verified against [Trino functions docs](https://trino.io/docs/current/functions.html), [Trino types](https://trino.io/docs/current/language/types.html), and the [Oracle SQL Language Reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/).

### 4.1 Null handling and conditional expressions

| Oracle | Trino | Notes |
|---|---|---|
| `NVL(col, default)` | `COALESCE(col, default)` | `COALESCE` accepts N args; `NVL` only 2. Always prefer `COALESCE` going forward. |
| `NVL2(col, val_if_not_null, val_if_null)` | `CASE WHEN col IS NOT NULL THEN val_if_not_null ELSE val_if_null END` | No direct Trino built-in; `IF(condition, val_if_true, val_if_false)` also works for the boolean form. |
| `NULLIF(a, b)` | `NULLIF(a, b)` | Identical. |
| `DECODE(col, 'A', 1, 'B', 2, 0)` | `CASE col WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END` (or chained `CASE WHEN`s) | Trino has NO `DECODE`. CASE is more readable anyway. **CRITICAL NULL-MATCHING NUANCE: see §4.1A below — DECODE treats NULL=NULL as a match; simple CASE does NOT, so NULL-bearing columns silently change result on migration.** |
| `'' IS NULL` -> TRUE (Oracle quirk) | `'' IS NULL` -> **FALSE** in Trino | The single most dangerous silent-result-change in the migration. See myths box. |
| `nvl(col, '')` (sentinel "no value" Oracle idiom) | `COALESCE(col, '')` BUT this now produces a row where `col` is `''` (not null) — downstream `WHERE col IS NULL` checks BREAK. Audit and rewrite. | Oracle's quirk made this idiom round-trip cleanly; Trino's strictness breaks it. |

### 4.1A Oracle DECODE → Trino CASE — the silent NULL-matching nuance

> ### LEADING CANONICAL — `DECODE` with NULL as a search value → searched `CASE WHEN col IS NULL`
>
> **Question shape this answers**: "how do I migrate `DECODE(status, NULL, 'Missing', 'A', 'Active', 'Unknown')` to Trino", "Trino equivalent of Oracle DECODE that matches NULL", "DECODE with NULL as the first search argument", "rewrite Oracle DECODE NULL branch in Trino".
>
> **The exact mechanical rewrite — side by side.** When the Oracle `DECODE` lists `NULL` as a SEARCH VALUE (i.e., one of the `value_to_compare` positions, not just inside the result), translate to **searched** `CASE` with an explicit `WHEN col IS NULL` branch FIRST. Do NOT write `WHEN col = NULL` — `col = NULL` is UNKNOWN in Trino three-valued logic and never matches.
>
> ```sql
> -- ORACLE source — DECODE matches NULL=NULL as TRUE (Oracle quirk).
> -- The 4 positional args after the column are: search_1, result_1, search_2,
> -- result_2; the trailing single arg 'Unknown' is the DECODE default.
> SELECT
>   order_id,
>   DECODE(status, NULL, 'Missing', 'A', 'Active', 'Unknown') AS status_label
> FROM orders;
>
> -- TRINO TRANSLATION — searched CASE with explicit IS NULL branch FIRST.
> -- The order matters: the IS NULL branch MUST come before the value-equality
> -- branches because once you write `WHEN status = 'A'` the comparison evaluates
> -- to UNKNOWN for NULL rows and they would otherwise fall to ELSE.
> SELECT
>   order_id,
>   CASE
>     WHEN status IS NULL THEN 'Missing'
>     WHEN status = 'A'   THEN 'Active'
>     ELSE 'Unknown'
>   END AS status_label
> FROM iceberg.analytics.orders;
> ```
>
> **The DECODE → searched-CASE positional mapping (memorize this).**
>
> | Oracle DECODE position | Trino searched CASE branch |
> |---|---|
> | `DECODE(col, NULL, X, ...)` (NULL as search value) | `WHEN col IS NULL THEN X` (FIRST branch) |
> | `DECODE(col, 'A', Y, ...)` (literal search value) | `WHEN col = 'A' THEN Y` |
> | `DECODE(col, ..., Z)` (trailing single arg = default) | `ELSE Z` |
> | `DECODE(col, ...)` no trailing default | (omit ELSE — Trino returns NULL when no WHEN matches, which matches Oracle's "no default" behavior) |
>
> **DO-NOT-WRITE — banned forms when rewriting `DECODE(col, NULL, ...)`:**
>
> ```sql
> -- WRONG (1) — `WHEN status = NULL` in either simple OR searched CASE.
> -- `status = NULL` evaluates to UNKNOWN (not TRUE) under Trino three-valued
> -- logic, so this branch NEVER matches. Rows with status=NULL silently fall
> -- to ELSE 'Unknown' instead of returning 'Missing'. Trino emits NO warning.
> SELECT order_id,
>   CASE
>     WHEN status = NULL THEN 'Missing'   -- NEVER MATCHES
>     WHEN status = 'A'  THEN 'Active'
>     ELSE 'Unknown'
>   END AS status_label
> FROM iceberg.analytics.orders;
>
> -- WRONG (2) — simple CASE with `WHEN NULL`. Same trap: simple CASE
> -- compares with `=`, and `NULL = NULL` is UNKNOWN. NEVER fires.
> SELECT order_id,
>   CASE status
>     WHEN NULL THEN 'Missing'             -- NEVER MATCHES
>     WHEN 'A'  THEN 'Active'
>     ELSE 'Unknown'
>   END AS status_label
> FROM iceberg.analytics.orders;
>
> -- WRONG (3) — relying on the `ELSE 'Unknown'` branch to also catch NULLs.
> -- ELSE is hit when no WHEN matched (which IS true for NULL inputs), BUT
> -- the original Oracle DECODE distinguishes NULL ('Missing') from "any other
> -- non-A value" ('Unknown'). Collapsing them into one ELSE silently changes
> -- the result for legitimately-unknown statuses like 'Z'.
> SELECT order_id,
>   CASE
>     WHEN status = 'A' THEN 'Active'
>     ELSE 'Unknown'                       -- NULL rows now get 'Unknown', not 'Missing'
>   END AS status_label
> FROM iceberg.analytics.orders;
> ```
>
> **The one-rule memorize**: any Oracle `DECODE(col, NULL, ...)` MUST become a Trino **searched CASE** whose **first branch is `WHEN col IS NULL THEN ...`**. There is no other correct mechanical rewrite. The `IS NULL` predicate is the ONLY Trino construct that returns TRUE when `col` is NULL.
>
> Verified against [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html) (CASE semantics) and Oracle 19c [`DECODE` docs](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/DECODE.html) — *"DECODE considers two nulls to be equivalent."*
>
> See the deeper trap explanation, alternative COALESCE-sentinel pattern, and bulk-migration audit hint immediately below.
>
> ---
>
> **The trap.** Oracle `DECODE(col, val, result, ...)` treats **NULL = NULL as a match**: `DECODE(NULL, NULL, 'is_null', 'other')` returns `'is_null'`. Trino's **simple** CASE form `CASE col WHEN val THEN result END` uses **`=` semantics** where `NULL = NULL` is UNKNOWN — so `CASE NULL WHEN NULL THEN 'is_null' ELSE 'other' END` returns `'other'` (the ELSE branch). When you mechanically translate `DECODE` to simple `CASE col WHEN ...`, rows where `col` is NULL **silently change result**: in Oracle they hit the NULL branch; in Trino they fall through to the ELSE.
>
> Sources: Oracle 19c [`DECODE` docs](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/DECODE.html) — *"DECODE considers two nulls to be equivalent. If expr is null, then Oracle returns the result of the first search that is also null."* Trino [conditional expressions docs](https://trino.io/docs/current/functions/conditional.html) document the simple CASE form as searching by equality; standard SQL equality (`=`) returns UNKNOWN when either side is NULL, so a simple `WHEN` value of NULL never matches.
>
> **The correct migration form on NULL-bearing inputs — use SEARCHED CASE** (an explicit `WHEN col IS NULL` branch BEFORE the value-comparison branches):
>
> ```sql
> -- Oracle (DECODE matches NULL=NULL as TRUE)
> SELECT
>   order_id,
>   DECODE(status, NULL, 'unknown', 'A', 'active', 'C', 'cancelled', 'other') AS status_label
> FROM orders;
>
> -- WRONG Trino translation — simple CASE on a NULL-bearing column.
> -- Rows where status IS NULL fall through to ELSE 'other', NOT to 'unknown'.
> SELECT
>   order_id,
>   CASE status
>     WHEN NULL THEN 'unknown'                  -- NEVER MATCHES (status=NULL is UNKNOWN)
>     WHEN 'A'  THEN 'active'
>     WHEN 'C'  THEN 'cancelled'
>     ELSE 'other'
>   END AS status_label
> FROM iceberg.analytics.orders;
>
> -- CORRECT Trino translation — searched CASE with an explicit IS NULL branch.
> SELECT
>   order_id,
>   CASE
>     WHEN status IS NULL THEN 'unknown'         -- explicit NULL match
>     WHEN status = 'A'   THEN 'active'
>     WHEN status = 'C'   THEN 'cancelled'
>     ELSE 'other'
>   END AS status_label
> FROM iceberg.analytics.orders;
> ```
>
> **Alternative: COALESCE-wrap with a sentinel** when the rewrite must stay in the simple-CASE shape (e.g., a code generator emits simple CASE). Replace NULL with a sentinel string the simple CASE can match on:
>
> ```sql
> -- Wrap with COALESCE so NULL becomes the sentinel '__NULL__'; the simple
> -- CASE then has a real value to match. Works only when no legitimate column
> -- value collides with the sentinel.
> SELECT
>   order_id,
>   CASE COALESCE(status, '__NULL__')
>     WHEN '__NULL__' THEN 'unknown'
>     WHEN 'A'        THEN 'active'
>     WHEN 'C'        THEN 'cancelled'
>     ELSE 'other'
>   END AS status_label
> FROM iceberg.analytics.orders;
> ```
>
> **DO-NOT-WRITE block — banned patterns when translating Oracle DECODE on NULL-bearing inputs:**
>
> ```sql
> -- WRONG (a) — simple CASE with WHEN NULL. The branch is unreachable; the
> -- expression NULL = NULL evaluates to UNKNOWN, not TRUE, so WHEN NULL never
> -- fires. Trino does NOT emit a warning; the result silently differs from
> -- Oracle DECODE.
> CASE col WHEN NULL THEN 'is_null' WHEN 'A' THEN 'a' ELSE 'other' END
>
> -- WRONG (b) — relying on the order of WHEN branches to "catch" NULL in a
> -- simple CASE. Order is irrelevant; every WHEN clause uses `=` and NULL
> -- never equals anything (including itself).
> CASE col
>   WHEN 'A'  THEN 'a'
>   WHEN NULL THEN 'is_null'   -- still never matches
>   ELSE 'other'
> END
>
> -- WRONG (c) — adding ELSE 'unknown' as a stand-in for the NULL branch.
> -- ELSE catches ALL non-matching values, NOT just NULLs. Any future value
> -- not in the explicit WHEN list is incorrectly labeled 'unknown'.
> CASE col WHEN 'A' THEN 'a' WHEN 'C' THEN 'c' ELSE 'unknown' END
> ```
>
> **When the input is guaranteed NOT NULL**, simple `CASE col WHEN ...` is a clean drop-in for `DECODE` — the NULL-matching divergence does not apply. The rule: **before translating `DECODE` → simple CASE, check whether the column is NULL-bearing**. If yes, use searched `CASE WHEN col IS NULL THEN ...` (the safe default). If no (column is `NOT NULL` constrained), simple CASE is fine.
>
> **Audit hint for a bulk migration.** Grep the Oracle source for every `DECODE(<col>, NULL, ...)` literal — those calls SPECIFICALLY exploit Oracle's NULL=NULL semantics, so they MUST be translated to searched CASE with `WHEN col IS NULL`. Calls like `DECODE(<col>, 'A', ..., 'B', ...)` without an explicit NULL branch are safe to translate to simple CASE only if `<col>` is `NOT NULL`-constrained. When in doubt, default to searched CASE — it is always correct.

### 4.2 Date/time functions

> ### LEADING CANONICAL — Oracle `TO_CHAR(date, fmt)` → Trino
>
> **Question shape this answers**: "what's the Trino equivalent of Oracle `TO_CHAR(order_ts, 'YYYY-MM-DD')`", "how do I format a timestamp as a string in Trino", "how do I migrate `TO_CHAR(dt, 'YYYY-MM-DD HH24:MI:SS')` from Oracle to Trino".
>
> **The two canonical Trino 467 functions** — both verified against [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html):
>
> - **`date_format(timestamp, format)`** — MySQL-style format specifiers (capital `%Y`, lowercase `%m`, etc.). **FIRST-CHOICE** for general TO_CHAR migration when the format string is anything other than plain ISO.
> - **`format_datetime(timestamp, pattern)`** — Joda DateTime pattern (lowercase `yyyy`, `MM`, `dd`, etc.). Equivalent capability, different pattern grammar. Use whichever pattern grammar you're already comfortable with.
>
> **Trino has NO `TO_CHAR` function** — copy-pasting `TO_CHAR(dt, 'YYYY-MM-DD')` from Oracle into a Trino query or a dbt-Trino model produces `Function 'to_char' not registered` (function-resolution error).
>
> **Three-line worked example:**
>
> ```sql
> -- Oracle:
> SELECT TO_CHAR(order_ts, 'YYYY-MM-DD') AS order_date_str FROM orders;
>
> -- Trino (FIRST-CHOICE, MySQL-style):
> SELECT date_format(order_ts, '%Y-%m-%d') AS order_date_str FROM orders;
>
> -- Trino (Joda-style — equivalent, pick one consistent style across your codebase):
> SELECT format_datetime(order_ts, 'yyyy-MM-dd') AS order_date_str FROM orders;
> ```
>
> **For plain ISO output ONLY (DATE column → `'YYYY-MM-DD'` string)**, a bare `CAST(d AS VARCHAR)` works:
>
> ```sql
> -- DATE column, default ISO 'YYYY-MM-DD' rendering:
> SELECT CAST(order_date AS VARCHAR) FROM orders;        -- produces '2026-05-30'
> -- TIMESTAMP column, default ISO render is 'YYYY-MM-DD HH:MM:SS.fff':
> SELECT CAST(order_ts AS VARCHAR) FROM orders;          -- produces '2026-05-30 14:30:00.000'
> ```
>
> **CAST is restricted to the engine's default formatting.** For any non-ISO format (slashes, month abbreviation, custom layout, etc.), use `date_format` or `format_datetime`.
>
> **Oracle TO_CHAR ↔ Trino format-string mapping** (the patterns engineers migrate most often):
>
> | Oracle `TO_CHAR(dt, ...)` mask | Trino `date_format(ts, ...)` (MySQL) | Trino `format_datetime(ts, ...)` (Joda) |
> |---|---|---|
> | `'YYYY-MM-DD'` | `'%Y-%m-%d'` | `'yyyy-MM-dd'` |
> | `'YYYY-MM-DD HH24:MI:SS'` | `'%Y-%m-%d %H:%i:%s'` | `'yyyy-MM-dd HH:mm:ss'` |
> | `'DD/MM/YYYY'` | `'%d/%m/%Y'` | `'dd/MM/yyyy'` |
> | `'MM/DD/YYYY'` | `'%m/%d/%Y'` | `'MM/dd/yyyy'` |
> | `'Mon DD, YYYY'` | `'%b %d, %Y'` | `'MMM dd, yyyy'` |
> | `'Month DD, YYYY'` | `'%M %d, %Y'` | `'MMMM dd, yyyy'` |
> | `'HH24:MI'` | `'%H:%i'` | `'HH:mm'` |
> | `'HH24:MI:SS'` | `'%H:%i:%s'` | `'HH:mm:ss'` |
> | `'YYYY'` (year only) | `'%Y'` | `'yyyy'` |
> | `'MM'` (month-of-year, zero-padded) | `'%m'` | `'MM'` |
> | `'DD'` (day-of-month, zero-padded) | `'%d'` | `'dd'` |
> | `'D'` (day-of-week 1-7) | `'%w'` (0-6, Sun=0) | `'e'` (1-7, Mon=1) |
> | `'WW'` (week-of-year) | `'%U'` (Sun-start) / `'%v'` (Mon-start, ISO) | `'ww'` (ISO week-of-weekyear) |
> | `'Q'` (quarter 1-4) | no single specifier — use `quarter(ts)` then format separately | no single specifier — use `quarter(ts)` |
>
> **Pattern-grammar pitfalls to remember:**
>
> - **MySQL `%Y` = 4-digit year**; lowercase `%y` = 2-digit year. **Joda `yyyy` = 4-digit year**; `yy` = 2-digit year.
> - **MySQL `%m` (lowercase) = month 01-12**. **Joda `MM` (uppercase) = month 01-12**; Joda lowercase `mm` = MINUTE not month. This trips engineers most often — `format_datetime(ts, 'yyyy-mm-dd')` (lowercase `mm`) silently renders the minute-of-hour where you expected month-of-year.
> - **MySQL `%i` = minute** (`%M` is month NAME). **Joda `mm` = minute** (`MM` is month). The two grammars disagree about the case of the minute-of-hour specifier.
> - **Hour 24-clock**: MySQL `%H`, Joda `HH`. **Hour 12-clock**: MySQL `%h`, Joda `hh` (also need `%p` / `a` for AM/PM).
>
> **For niche needs only** — `format('%1$td/%1$tm/%1$tY', ts)` Java Formatter syntax IS a real Trino function but a niche choice. Use it only when you need Java Formatter-specific features (positional args, indexed reuse). For ordinary TO_CHAR migration, `date_format` / `format_datetime` are the canonical answers.
>
> ### DO-NOT-WRITE matrix — Trino has NO `::` cast operator and NO `TO_CHAR` function
>
> | Forbidden form | Where it comes from | What it does in Trino 467 | Trino-correct equivalent |
> |---|---|---|---|
> | `TO_CHAR(order_ts, 'YYYY-MM-DD')` | Oracle | `Function 'to_char' not registered` (function-resolution error) | `date_format(order_ts, '%Y-%m-%d')` or `format_datetime(order_ts, 'yyyy-MM-dd')` |
> | `CAST(order_ts AS DATE)::VARCHAR` | PostgreSQL / Snowflake / DuckDB `::` cast operator | `mismatched input '::'` parse error (Trino has no `::` operator per [trinodb/trino #23795](https://github.com/trinodb/trino/issues/23795), open feature request, NOT in 467 / 481) | `CAST(CAST(order_ts AS DATE) AS VARCHAR)` (chained ANSI cast) or `date_format(order_ts, '%Y-%m-%d')` |
> | `order_ts::VARCHAR` / `col::INT` / any `expr::type` | PostgreSQL / Snowflake / DuckDB | `mismatched input '::'` parse error | `CAST(expr AS type)` (or `TRY_CAST(...)` if NULL-on-failure is desired) |
> | Calling `::` "syntactic sugar for CAST" | misconception | It's another dialect's syntax, not a Trino spelling | Always use `CAST(expr AS type)` ANSI form |
> | `STR_TO_DATE('2026-05-30', '%Y-%m-%d')` | MySQL | `Function 'str_to_date' not registered` | `date_parse('2026-05-30', '%Y-%m-%d')` (MySQL-style) or `parse_datetime('2026-05-30', 'yyyy-MM-dd')` (Joda) |
> | `CONVERT(VARCHAR, order_ts, 23)` | SQL Server style-coded conversion | Trino's `CONVERT` does not take SQL-Server style codes | `date_format(order_ts, '%Y-%m-%d')` |
>
> **Meta-rule**: in Trino, use Trino's dialect — Oracle / PostgreSQL / Snowflake / Spark / SQL-Server function names and operators that look idiomatic in other engines parse-error or function-not-registered against Trino 467.

> ### LEADING CANONICAL — Oracle `ADD_MONTHS(dt, n)` → Trino (END-OF-MONTH CLAMP SEMANTICS DIFFER)
>
> **Question shape this answers**: "what's the Trino equivalent of Oracle `ADD_MONTHS(dt, 3)`", "how do I add months to a date in Trino", "is `date_add('month', n, dt)` the same as Oracle `ADD_MONTHS`".
>
> **Short answer**: a naive translation works for non-month-end inputs but is **silently wrong** for month-end inputs. Oracle `ADD_MONTHS` applies a special END-OF-MONTH CLAMP rule; Trino `date_add('month', n, dt)` and `dt + INTERVAL 'n' MONTH` do NOT.
>
> **Trino month arithmetic — the two equivalent forms** (verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)):
>
> - `date_add('month', n, ts)` — function form. Signature: `date_add(unit, value, timestamp)`; `'month'` is a valid unit; negative `n` subtracts.
> - `ts + INTERVAL 'n' MONTH` — interval-literal form. Equivalent result.
>
> **SEMANTIC DIFFERENCE — Oracle ADD_MONTHS has TWO month-end rules Trino does not replicate** (verified at [docs.oracle.com — ADD_MONTHS](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/ADD_MONTHS.html)):
>
> 1. **Last-day-in → last-day-out (CLAMP UP)**: if the input is the last day of its month, the result is FORCED to the last day of the target month — even when the target month has more days. Examples:
>    - Oracle: `ADD_MONTHS(DATE '2026-02-28', 1)` → `DATE '2026-03-31'` (Feb 28 is last-of-Feb in a non-leap year, so the result is clamped to last-of-Mar, NOT Mar 28).
>    - Oracle: `ADD_MONTHS(DATE '2024-02-29', 1)` → `DATE '2024-03-31'` (Feb 29 is last-of-Feb in a leap year, so clamped to Mar 31).
> 2. **Overflow → last-day (CLAMP DOWN)**: if the target month has fewer days than the input's day-number, the result is the last day of the target month. Example:
>    - Oracle: `ADD_MONTHS(DATE '2026-01-31', 1)` → `DATE '2026-02-28'` (Jan 31 + 1 month overflows Feb, clamps to Feb 28).
>
> **Trino does NOT detect last-of-month** — it preserves the day-number for the in-range case and only handles overflow by its own normalization. The Trino result diverges from Oracle whenever the input falls on the last day of a month whose target month has more days:
>
> - Trino: `date_add('month', 1, DATE '2026-02-28')` → `DATE '2026-03-28'` (NOT Oracle's `2026-03-31`).
> - Trino: `DATE '2026-02-28' + INTERVAL '1' MONTH` → `DATE '2026-03-28'` (same — INTERVAL form is identical in semantics).
> - For the overflow case, both engines land on Feb 28 (`ADD_MONTHS(DATE '2026-01-31', 1)` = Trino `date_add('month', 1, DATE '2026-01-31')` = `2026-02-28`), so the overflow case is NOT where the silent divergence shows up — only the last-day-in → last-day-out case is.
>
> **REPLICATION PATTERN — portable Trino-467 wrapper that matches Oracle ADD_MONTHS semantics** (uses `last_day_of_month(x) → date`, verified to exist in Trino 467 at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)):
>
> ```sql
> -- Replicates Oracle ADD_MONTHS(input, n) including end-of-month CLAMP UP.
> -- Read: "if input is the last day of its month, force the result to the last day
> --        of the target month; otherwise, plain date_add('month', n, input)."
> CASE
>   WHEN input = last_day_of_month(input)
>     THEN last_day_of_month(date_add('month', n, input))
>   ELSE date_add('month', n, input)
> END
> ```
>
> Apply it as a dbt macro / SQL UDF to keep the call sites readable:
>
> ```sql
> -- Inline at call site (most common):
> SELECT
>   order_id,
>   CASE
>     WHEN order_date = last_day_of_month(order_date)
>       THEN last_day_of_month(date_add('month', 3, order_date))
>     ELSE date_add('month', 3, order_date)
>   END AS due_date_oracle_compat
> FROM orders;
> ```
>
> **Walk-through to confirm the wrapper matches Oracle's two rules**:
> - `input = DATE '2026-02-28'`, `n = 1`. `last_day_of_month(input) = 2026-02-28` → input equals last-of-month → return `last_day_of_month(date_add('month', 1, 2026-02-28))` = `last_day_of_month(2026-03-28)` = `2026-03-31`. Matches Oracle.
> - `input = DATE '2026-01-31'`, `n = 1`. `last_day_of_month(input) = 2026-01-31` → input equals last-of-month → return `last_day_of_month(date_add('month', 1, 2026-01-31))` = `last_day_of_month(2026-02-28)` = `2026-02-28`. Matches Oracle.
> - `input = DATE '2026-01-15'`, `n = 1`. `last_day_of_month(input) = 2026-01-31` ≠ input → return `date_add('month', 1, 2026-01-15)` = `2026-02-15`. Matches Oracle's "preserve day-number when not last-of-month".
>
> **DO-NOT-WRITE matrix — Oracle ADD_MONTHS migration**:
>
> | Forbidden claim / form | Why it's wrong | Trino-correct equivalent |
> |---|---|---|
> | "Oracle `ADD_MONTHS(dt, n)` maps directly to `date_add('month', n, dt)` with identical semantics." | FALSE at month-end. Oracle clamps last-day-in to last-day-out (`ADD_MONTHS(DATE '2026-02-28', 1)` = `2026-03-31`); Trino preserves day-number (`date_add('month', 1, DATE '2026-02-28')` = `2026-03-28`). Migration-correctness defect on any month-end-tagged data (period-close, billing cycles, statement dates). | Use the `CASE WHEN input = last_day_of_month(input) THEN last_day_of_month(date_add('month', n, input)) ELSE date_add('month', n, input) END` wrapper shown above. |
> | "`dt + INTERVAL 'n' MONTH` IS the drop-in Trino replacement for `ADD_MONTHS(dt, n)`." | Same defect — INTERVAL MONTH and `date_add('month', ...)` are equivalent in Trino; neither implements Oracle's last-day-in → last-day-out clamp. | Same wrapper. |
> | "Trino normalizes month-end the same way Oracle does." | Misconception. Trino's normalization handles target-month-overflow (Jan 31 + 1 month → Feb 28) — which matches Oracle in that one case — but does NOT detect last-day-of-month for the CLAMP UP rule. | Use the wrapper to make both rules portable. |
> | Using Oracle `LAST_DAY(dt)` directly in Trino | Trino has no `LAST_DAY` function — only `last_day_of_month(dt)`. Bare `LAST_DAY(dt)` → `Function 'last_day' not registered`. | Replace `LAST_DAY(dt)` with `last_day_of_month(dt)`. |
> | Writing `end_of_month(dt)` ANYWHERE in the ADD_MONTHS wrapper (or anywhere else) | **Trino 467 has NO `end_of_month` function** — verified absent at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html). The name comes from Spark SQL / BigQuery / Snowflake-style dialects; pasting `end_of_month(start_date)` into a Trino query produces **`Function 'end_of_month' not registered`** at analyze time. This is the single most common fabricated function name for the Oracle ADD_MONTHS month-end wrapper. | The ONLY Trino month-end function is **`last_day_of_month(dt) -> date`**. Use it in **BOTH positions** of the wrapper: `CASE WHEN last_day_of_month(start_date) = start_date THEN last_day_of_month(date_add('month', n, start_date)) ELSE date_add('month', n, start_date) END`. |
> | Claiming `MONTHS_BETWEEN(a, b)` maps to a fractional Trino function (e.g., `months_between(...)`, `fractional_months_between(...)`) | No such function exists in Trino 467. `date_diff('month', b, a)` returns a **bigint INTEGER** count of month boundaries — never a fractional value. | For integer parity (the common case) use `date_diff('month', b, a)`. For Oracle-style fractional approximation use `date_diff('day', b, a) / 31.0` (Oracle's 31-day-month convention) — only when downstream actually needs the fractional residual. |
>
> **Keyword anchors for this section**: ADD_MONTHS Trino, MONTHS_BETWEEN Trino, last day of month Trino, month-end Trino, add months keep month-end, end_of_month Trino (DOES NOT EXIST — use `last_day_of_month`), months between Trino integer vs fractional, Oracle month arithmetic migration, ADD_MONTHS end-of-month clamp wrapper, last_day_of_month signature, NEXT_DAY Trino, no next_day function Trino, next Monday/weekday after date Trino, day_of_week date_add next weekday.
>
> **MONTHS_BETWEEN — fractional vs integer** (verified at [docs.oracle.com — MONTHS_BETWEEN](https://docs.oracle.com/en/database/oracle/oracle-database/21/sqlrf/MONTHS_BETWEEN.html) and [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)):
>
> - Oracle `MONTHS_BETWEEN(d1, d2)` returns a **FRACTIONAL** number — when `d1` and `d2` are on different days-of-month (and not both last-of-month), Oracle computes the fractional portion treating the residual as 31-day-month thirty-firsts. Example: `MONTHS_BETWEEN(DATE '2026-03-15', DATE '2026-01-31')` returns a non-integer.
> - Trino `date_diff('month', d2, d1)` returns an **INTEGER (bigint) count of month boundaries crossed**. No fractional part is produced. Example: `date_diff('month', DATE '2026-01-31', DATE '2026-03-15')` = `2`.
> - **Migration implication**: if downstream logic depended on the fractional component (e.g., proration, accrual, billing-day arithmetic), `date_diff('month', ...)` will silently drop it. For exact Oracle-style fractional behavior, compute it yourself with `date_diff('day', d2, d1)` divided by 31 (Oracle's convention) — but only do this when the downstream consumer actually requires the fractional behavior; the integer count is what most reporting workloads want.
>
> **LAST_DAY → last_day_of_month** (verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)): Oracle `LAST_DAY(dt)` returns the last day of the month containing `dt`. Trino's equivalent is `last_day_of_month(dt) → date`. Function name is different — `LAST_DAY(dt)` in Trino produces `Function 'last_day' not registered`. Use `last_day_of_month(dt)`.
>
> **NEXT_DAY → compute via `day_of_week` + `date_add`** (verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)). **Keyword anchor:** Oracle NEXT_DAY Trino, next Monday/weekday after date Trino, day_of_week date_add next weekday, no next_day function Trino. **Trino has NO `next_day` function** — `next_day(dt, 'MONDAY')` produces `Function 'next_day' not registered`. Oracle `NEXT_DAY(dt, weekday)` returns the date of the next occurrence of `weekday` **strictly AFTER** `dt` (Oracle never returns `dt` even when `dt` already IS that weekday). Replicate it in Trino with `day_of_week` (returns **ISO 1=Monday .. 7=Sunday**) + `date_add`:
>
> ```sql
> -- Oracle:  NEXT_DAY(dt, 'MONDAY')   -> the next Monday STRICTLY AFTER dt.
> -- Trino:  bind target_dow in 1..7  (1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat, 7=Sun).
> SELECT date_add('day', ((<target_dow> - day_of_week(dt) + 6) % 7) + 1, dt) AS next_weekday;
> ```
>
> The `((target_dow - day_of_week(dt) + 6) % 7) + 1` expression always yields **1..7** so the result is **always strictly after** `dt` — matching Oracle's "never returns `dt` itself" semantic. Worked example: next **Monday** (`target_dow = 1`) after **Wednesday 2026-06-03** (`day_of_week('2026-06-03') = 3`): `((1 - 3 + 6) % 7) + 1 = (4 % 7) + 1 = 4 + 1 = 5` → `date_add('day', 5, DATE '2026-06-03')` = `DATE '2026-06-08'` (a Monday). Same-weekday edge case: next Monday after Monday 2026-06-08: `((1 - 1 + 6) % 7) + 1 = 6 + 1 = 7` → `2026-06-15` (one week later, never the same day). **DO NOT WRITE:** claiming a Trino `next_day()` function exists (it does NOT — compute via `day_of_week` + `date_add` as above).

| Oracle | Trino | Notes |
|---|---|---|
| `SYSDATE` (current date + time, server time zone) | `current_timestamp` (timestamp with time zone, session TZ) OR `localtimestamp` (no TZ) | Beware: `SYSDATE` returns DATE-with-time in Oracle; `CURRENT_DATE` in Trino is just DATE (no time). Use `current_timestamp` for "now()" semantics. **NOTE: `current_date` drops the time component — do NOT use it as a SYSDATE replacement when you need hours/minutes/seconds.** See §4.2A for how to change the session time zone (it is NOT a `SET SESSION` property — it is a dedicated `SET TIME ZONE` command). |
| `SYSTIMESTAMP` | `current_timestamp` | Identical semantics (both TZ-aware). Oracle `SYSTIMESTAMP` is `TIMESTAMP WITH TIME ZONE`; Trino `current_timestamp` is `timestamp with time zone` keyed on the session time zone. |
| `TRUNC(dt)` (truncate to day) | `date_trunc('day', dt)` | Also `'week'`, `'month'`, `'quarter'`, `'year'`, `'hour'`, `'minute'`, `'second'`. |
| `TO_DATE('2026-05-30', 'YYYY-MM-DD')` (ISO) | THREE canonical Trino-correct forms (pick by input shape): (1) `from_iso8601_date('2026-05-30')` returning DATE — CLEANEST for ISO 8601 input; (2) `CAST(date_parse('2026-05-30', '%Y-%m-%d') AS DATE)` returning DATE — MySQL-style specifiers; `date_parse` returns `timestamp(3)`, wrap in `CAST AS DATE`; (3) `CAST('2026-05-30' AS DATE)` for raw ISO-8601 string only. **`parse_date(str, fmt)` is NOT a Trino function** — that is Snowflake/BigQuery. | Trino's `date_parse` uses MySQL specifiers (`%Y %m %d %H %i %s`); `parse_datetime` uses Joda (`yyyy MM dd HH mm ss`). NEITHER is named `parse_date`. See §4.4B cross-dialect guardrail row for the explicit `parse_date` ban. |
| `TO_DATE('30/05/2026', 'DD/MM/YYYY')` (slash, day-first) | `CAST(date_parse('30/05/2026', '%d/%m/%Y') AS DATE)` returning DATE. | `%d` = day, `%m` = month, `%Y` = 4-digit year. MySQL specifiers throughout. |
| `TO_DATE('05-JUN-2026', 'DD-MON-YYYY')` (abbreviated month name) | `CAST(date_parse('05-JUN-2026', '%d-%b-%Y') AS DATE)` returning DATE. | `%b` = abbreviated month name (`Jan`, `Feb`, ...). Case sensitivity: `date_parse` is case-insensitive on month names in 467; verify locale-sensitive months separately. |
| `TO_CHAR(dt, 'YYYY-MM-DD')` | `date_format(dt, '%Y-%m-%d')` (MySQL-style, FIRST-CHOICE) OR `format_datetime(dt, 'yyyy-MM-dd')` (Joda) OR `CAST(dt AS VARCHAR)` for ISO of a DATE column only. | See the LEADING CANONICAL block at the top of this section for the full Oracle TO_CHAR ↔ Trino format-string mapping table and DO-NOT-WRITE matrix. `TO_CHAR` itself is NOT a Trino function. |
| `TO_NUMBER('123')` | `CAST('123' AS bigint)` or `CAST('1.5' AS double)` | Trino has no `TO_NUMBER`; use `CAST`. |
| `EXTRACT(YEAR FROM dt)` | `EXTRACT(YEAR FROM dt)` OR `year(dt)` | Identical syntax + convenience functions. |
| `dt + 1` (add one day) | `dt + INTERVAL '1' DAY` | Trino requires explicit INTERVAL — no implicit day-arithmetic on dates. |
| `dt - SYSDATE` (interval) | `date_diff('day', current_timestamp, dt)` returns bigint | Trino doesn't subtract timestamps to get a bare number; use `date_diff`. |
| `ADD_MONTHS(dt, 3)` | `date_add('month', 3, dt)` OR `dt + INTERVAL '3' MONTH` for the non-month-end case ONLY; for full Oracle-compatible semantics use the `CASE WHEN dt = last_day_of_month(dt) THEN last_day_of_month(date_add('month', 3, dt)) ELSE date_add('month', 3, dt) END` wrapper. | **Naive translation is silently wrong for month-end inputs** — Oracle clamps last-day-in to last-day-out (`ADD_MONTHS(DATE '2026-02-28', 1)` = `2026-03-31`); Trino preserves day-number (`date_add('month', 1, DATE '2026-02-28')` = `2026-03-28`). See the LEADING CANONICAL block above for the portable wrapper, the worked walk-through, and the DO-NOT-WRITE matrix. |
| `MONTHS_BETWEEN(d1, d2)` | `date_diff('month', d2, d1)` (integer count of month boundaries) | Oracle's `MONTHS_BETWEEN` returns a **FRACTIONAL** number; Trino's `date_diff('month', ...)` returns an **INTEGER bigint**. If downstream depended on the fractional residual (proration, accrual), compute it yourself with `date_diff('day', d2, d1) / 31.0`. See the LEADING CANONICAL block above. |
| `LAST_DAY(dt)` | `last_day_of_month(dt)` | Same purpose, different function name. Bare `LAST_DAY(dt)` produces `Function 'last_day' not registered` in Trino 467. |
| `NEXT_DAY(dt, 'MONDAY')` (next occurrence of `weekday` STRICTLY AFTER `dt`) | `date_add('day', ((<target_dow> - day_of_week(dt) + 6) % 7) + 1, dt)` where `target_dow` is `1=Mon..7=Sun` (ISO). | **Trino has NO `next_day` function** — `next_day(dt, 'MONDAY')` produces `Function 'next_day' not registered`. The `((... + 6) % 7) + 1` arithmetic returns `1..7` so the result is ALWAYS strictly after `dt`, matching Oracle's "never returns `dt` itself" semantic. See the LEADING CANONICAL block above for the worked example and the day_of_week ISO numbering check. |

**GOTCHA — filtering on a parsed timestamp (do NOT reference the SELECT output alias in WHERE).** `WHERE` is evaluated **BEFORE** the `SELECT` projection (verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — the SELECT output is computed after WHERE; output column aliases do not exist yet when WHERE runs), so this **FAILS** with `Column 'occurred_at' cannot be resolved`:

```sql
-- WRONG — references the SELECT output alias `occurred_at` in WHERE:
SELECT event_id, parse_datetime(ts_text, 'yyyy-MM-dd HH:mm:ss') AS occurred_at
FROM events
WHERE occurred_at > current_timestamp - INTERVAL '7' DAY;   -- ERROR: cannot be resolved
```

Either **wrap the parse in a CTE/subquery and filter the OUTER query** (clearest), or **repeat the parse expression in WHERE**:

```sql
-- CORRECT (CTE form — preferred):
WITH parsed AS (
  SELECT event_id, date_parse(ts_text, '%Y-%m-%d %H:%i:%S') AS occurred_at
  FROM events
)
SELECT * FROM parsed WHERE occurred_at > TIMESTAMP '2026-06-01 00:00:00';

-- CORRECT (repeat-expression form):
SELECT event_id, date_parse(ts_text, '%Y-%m-%d %H:%i:%S') AS occurred_at
FROM events
WHERE date_parse(ts_text, '%Y-%m-%d %H:%i:%S') > TIMESTAMP '2026-06-01 00:00:00';
```

This is the **general SELECT-clause-evaluation-order rule**, not a parsing-specific quirk: you cannot reference ANY `SELECT` output alias — nor a window-function result — in `WHERE`. (Window functions are also computed after WHERE; filter them in an outer query / CTE too.)

**See also (the "rows equal to a per-group window aggregate" specialization).** For the canonical fix to "rows where a column equals its `MAX/MIN/AVG OVER (PARTITION BY ...)`" — including the three exact-wrong forms `WHERE amount = MAX(amount) OVER (...)` (window in WHERE), `SUM(CASE WHEN amount = MAX(amount) OVER (...) THEN 1 ELSE 0 END) OVER (...)` (nested window), and `COUNT(*) FILTER (WHERE amount = MAX(amount) OVER (...))` (window inside aggregate FILTER), all rejected by Trino 467 — see **[resource 23 §3.1G LEADING CANONICAL — MAX-PER-GROUP-COMPARE: wrap the window in a CTE, then compare at the outer level](23-sql-best-practices-olap.md#leading-canonical--max-per-group-compare-rows-equal-to-each-groups-max--compare-to-a-partition-aggregate--wrap-the-window-in-a-cte-then-compare-at-the-outer-level-iter637-pin--fix-a-window-in-where--nested-window--window-in-filter-regression)**. The wrap-the-window-then-compare pattern (`WITH ranked AS (SELECT ..., MAX(amount) OVER (...) AS cust_max FROM t) SELECT ... FROM ranked WHERE amount = cust_max` — or with `FILTER (WHERE amount = cust_max)` for counting) is the docs-correct fix.

**Return-type note (pick the function whose return type matches your comparison literal).** Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): `parse_datetime(str, fmt)` (Joda format `yyyy-MM-dd HH:mm:ss`) returns **`timestamp with time zone`**; `date_parse(str, fmt)` (MySQL format `%Y-%m-%d %H:%i:%S`) returns **`timestamp(3)` WITHOUT zone**. Don't compare a with-tz value to a without-tz literal without aligning types — `date_parse(...)` pairs naturally with a `TIMESTAMP '...'` literal (no zone); `parse_datetime(...)` pairs with a `current_timestamp` / `timestamp with time zone` comparand. Align the two sides (e.g. wrap one in `CAST(... AS timestamp)` or `AT TIME ZONE`) before comparing.

### 4.2-NOW LEADING CANONICAL — `now()` / `current_timestamp` / `current_date` + Iceberg `timestamptz` is UTC-NORMALIZED on storage

> **Keyword anchors (read this section FIRST if your question contains any of these):** Trino `now()` · `now() Trino` · does Trino have `now` · `now()` vs `current_timestamp` · `current_timestamp` Trino · `current_date` Trino · `current_time` Trino · `localtimestamp` Trino · session time zone Trino · what time zone does Trino store · Iceberg timestamp storage · Iceberg `timestamptz` storage · `timestamp with time zone` UTC · `TIMESTAMP WITH TIME ZONE` Iceberg · UTC-normalized · stored as UTC · wall-clock timestamp · `AT TIME ZONE` Trino · timezone aware vs naive Iceberg · `timestamp` vs `timestamptz`.

**The two load-bearing facts (memorize both before answering any "now() / current_timestamp / timestamptz" question).**

1. **Trino HAS `now()` — it is an ALIAS for `current_timestamp`.** Verified verbatim at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): *"`now()` → timestamp with time zone — This is an alias for `current_timestamp`."* Both return **`TIMESTAMP(3) WITH TIME ZONE`** as of the **start of the query** (not call time — every reference inside one query yields the identical value), tied to the **session time zone**. The two are interchangeable; pick whichever reads better. Companion forms:
   - `current_date` → `DATE` — session-TZ-aware day boundary.
   - `current_time` → `TIME WITH TIME ZONE` — session-TZ-aware.
   - `localtimestamp` → `TIMESTAMP` (no TZ) — session-local wall clock.
   - **Syntax pin:** `current_timestamp` / `current_date` / `current_time` / `localtimestamp` take **NO parentheses** (SQL-standard form); `now()` takes empty parens. Writing `current_timestamp()` is a parse error.

2. **Iceberg STORAGE — `timestamp with time zone` (timestamptz) is UTC-NORMALIZED on disk; bare `timestamp` is wall-clock with NO normalization.** Per the [Iceberg spec](https://iceberg.apache.org/spec/) — verbatim: *"values are stored as UTC and do not retain a source time zone"*. A `timestamp(6) with time zone` column on Iceberg stores **microseconds from epoch UTC** — the original session/source zone is **NOT preserved per value**; the value is an INSTANT. A `timestamp(6)` column (WITHOUT time zone) stores wall-clock microseconds with **no UTC normalization** — what you wrote is what comes back. The two semantics are NOT interchangeable; pick `timestamptz` for "an instant in time," pick `timestamp` for "calendar wall clock that should never shift" (rare).

   `AT TIME ZONE 'UTC'` / `AT TIME ZONE 'America/New_York'` on a `timestamptz` value **re-labels** the same UTC instant in the target zone — it does NOT change the underlying stored bytes (cross-ref §4.2B core semantic). Writing `event_ts AT TIME ZONE 'UTC'` on a column already stored as `timestamptz` is a no-op on storage, only a display re-render.

**DO-NOT-WRITE (these are the load-bearing fab claims to ban):**
- *"Trino has no `now()` function — use `current_timestamp` instead."* **FALSE.** `now()` is a documented Trino alias for `current_timestamp`. Both work; both return the same value.
- *"`now()` is a parse error / function-not-found in Trino."* **FALSE.** Both `now()` and `current_timestamp` resolve; both return `TIMESTAMP(3) WITH TIME ZONE`.
- *"Iceberg / Trino never normalizes timestamps to UTC on storage — you get back exactly what you stored."* **FALSE for `timestamp with time zone` (timestamptz)** — those values ARE UTC-normalized on disk per the Iceberg spec. The "no normalization" rule applies ONLY to bare `timestamp` (without time zone).
- *"`current_timestamp` and `now()` return different types / different values."* **FALSE.** Identical type (`TIMESTAMP(3) WITH TIME ZONE`), identical value (both pinned to query-start time, session TZ).
- *"`current_date` returns a timestamp."* **FALSE.** It returns `DATE` — no time component. Use `current_timestamp` (or `now()`) when you need hours/minutes/seconds.

**Cross-references:** **Resource 07 §LEADING CANONICAL — `now()` / `current_timestamp` / `current_date` in Trino (+ Iceberg `timestamptz` is UTC-normalized on storage)** (the generic Trino-time-function angle of the SAME two facts — for non-Oracle questions about `now()` / `current_timestamp` / Iceberg `timestamptz`; the r07 canonical and this section state identical facts and must be kept consistent). §4.2A (the SET TIME ZONE command + `sql.forced-session-time-zone` server property — how to change what zone `current_timestamp` / `now()` use). §4.2B (filtering a `timestamp with time zone` column by a local-date range — boundary-literal form). Resource 13 §timestamp-type-mapping (Postgres `timestamptz` → Iceberg `TIMESTAMP(6) WITH TIME ZONE`). Resource 13 §`from_unixtime` (epoch-seconds-to-timestamp; returns `timestamp(3) with time zone`).

### 4.2A TRINO-SESSION-TIMEZONE GUARDRAIL — `SET TIME ZONE` is a DEDICATED COMMAND, not a session-property assignment

**Why this section exists.** When migrating Oracle SYSDATE / TRUNC(SYSDATE) / SYSTIMESTAMP code, engineers reflexively reach for a session-property-style toggle to "set the timezone for the session" — the same way they would in PostgreSQL (`SET timezone='America/New_York'`) or MySQL (`SET SESSION time_zone='+00:00'`). **Trino does NOT have a `time_zone` session property.** Writing `SET SESSION time_zone='America/New_York'` will fail at runtime with **"Session property time_zone does not exist"** (or "Unknown session property"). This is the #1 silent failure when porting SYSDATE-heavy Oracle procedures.

**The three valid mechanisms in Trino — verified against [trino.io/docs/current/sql/set-time-zone.html](https://trino.io/docs/current/sql/set-time-zone.html) and [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html):**

1. **`SET TIME ZONE 'zone'` — a DEDICATED STATEMENT** (NOT a session-property assignment). Examples:
   - `SET TIME ZONE 'America/New_York'` — region-based identifier
   - `SET TIME ZONE 'America/Los_Angeles'`
   - `SET TIME ZONE '-08:00'` — UTC offset string
   - `SET TIME ZONE LOCAL` — reset to the session's initial time zone
   - `SET TIME ZONE INTERVAL '10' HOUR` — interval-based UTC offset (range −14 to +14 hours)
   - `SET TIME ZONE INTERVAL -'08:00' HOUR TO MINUTE`
   - `SET TIME ZONE concat_ws('/', 'America', 'Los_Angeles')` — dynamic expression returning a zone string
   This affects subsequent `current_timestamp` and `localtimestamp` calls inside that session.

2. **`sql.forced-session-time-zone` — a SERVER CONFIG PROPERTY** (cluster-level, in `etc/config.properties`, NOT a per-session toggle). When this is set on the server, the per-session `SET TIME ZONE` command has **no effect** — the cluster forces the time zone. This is typically used in production to enforce UTC across all queries regardless of client locale.

3. **`expr AT TIME ZONE 'zone'` — per-expression conversion** for one specific timestamp without changing session state. Example: `current_timestamp AT TIME ZONE 'America/New_York'`, or `order_ts AT TIME ZONE 'UTC'`. Most production migrations prefer this over session-level toggling because it makes the conversion explicit at the call site.

**Functions affected by the session time zone:**
- `current_timestamp` — session-TZ-aware; returns `timestamp with time zone`
- `localtimestamp` — session-local wall clock, **no TZ attached** (returns `timestamp` without TZ); precision 3 by default
- `current_date` — session-TZ-aware day boundary
- `current_time` — session-TZ-aware time-of-day

**DO-NOT-WRITE callout (load-bearing):**

> **There is NO `time_zone` session property in Trino — never write `SET SESSION time_zone = '...'`.** Use the `SET TIME ZONE 'zone'` command, the `sql.forced-session-time-zone` server property, or `AT TIME ZONE` per-expression. The phrasing `SET SESSION timezone = '...'` is also invalid (no such property either). PostgreSQL and MySQL muscle memory is the trap — Trino takes the dedicated-statement form instead.

**Q-pattern matcher.** If the question is "how do I change Trino's session timezone" (or equivalently "Trino equivalent of PostgreSQL `SET timezone`" / "how do I get SYSDATE to use Eastern time"), the answer is the command **`SET TIME ZONE 'America/New_York'`** — NOT a `SET SESSION property = value` form. If the deployment forces a cluster-wide time zone, mention `sql.forced-session-time-zone`. If only one expression needs conversion, mention `AT TIME ZONE 'zone'`.

**Worked example — porting Oracle SYSDATE to Trino with Eastern time semantics:**

```sql
-- Oracle (server has been deployed in ET; SYSDATE returns ET wall clock)
SELECT TRUNC(SYSDATE) AS today_et FROM dual;

-- Trino — three valid translations depending on cluster posture:

-- (1) If the cluster time zone is already ET (or forced via sql.forced-session-time-zone='America/New_York'):
SELECT date_trunc('day', current_timestamp) AS today_et;

-- (2) If the cluster is UTC and you want ET for this session only:
SET TIME ZONE 'America/New_York';   -- dedicated statement, NOT SET SESSION property=value
SELECT date_trunc('day', current_timestamp) AS today_et;

-- (3) Per-expression conversion (most explicit, recommended for dbt models):
SELECT date_trunc('day', current_timestamp AT TIME ZONE 'America/New_York') AS today_et;
```

**Why option (3) is preferred for dbt models.** A dbt model that depends on session state (via `SET TIME ZONE` in a `pre_hook`) is fragile: different runners, different ad-hoc query tools, and the Trino UI may inject different defaults. Embedding `AT TIME ZONE 'America/New_York'` in the SELECT itself makes the conversion explicit, idempotent, and reviewable.

**Cross-reference.** The on-prem-vs-cloud server-TZ audit discipline (Oracle SYSDATE returns OS server local time with no TZ attached; Trino is session-TZ-aware) is covered alongside this guardrail because the two reflexes — "set my session timezone" and "trust the server's clock" — co-occur in SYSDATE-heavy procedures.

### 4.2B FILTERING `TIMESTAMP WITH TIME ZONE` BY A LOCAL-DATE RANGE — the canonical Trino 467 form, with DO-NOT-WRITE for the two off-by-hours traps

> **Keyword anchors (read these so the responder lands here):** filter by date · filter by date range · filter by last N days · filter by timezone · filter by local date · TIMESTAMP WITH TIME ZONE filtering · timestamptz filtering · `AT TIME ZONE` predicate · off by hours · off by one day · wrong rows by timezone · timezone-aware WHERE clause · daily report local time · America/New_York filter · ET filter · UTC filter · BETWEEN on timestamptz · BETWEEN '2026-...' · `WHERE created_at BETWEEN`.

**Why this section exists.** When a column is `TIMESTAMP WITH TIME ZONE` (Postgres `timestamptz`, Iceberg `TIMESTAMP(6) WITH TIME ZONE` — see resource 13 type-mapping table) and you want to filter "rows whose **local** wall-clock date falls in a given range in `America/New_York`," the obvious reflexes from PostgreSQL or MySQL produce one of three failures in Trino 467: (i) a type error at analysis time, (ii) silently-wrong rows offset by the local UTC offset (4 or 5 hours for ET), or (iii) zero rows. The two correct forms are below; the three wrong forms (verified against [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) and [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html)) follow as DO-NOT-WRITE.

**Core semantic to memorize.** `expr AT TIME ZONE 'zone'` **does NOT change the underlying instant** — it re-renders the same UTC moment with a different zone label attached. The Trino docs example: `timestamp '2012-10-31 01:00 UTC' AT TIME ZONE 'America/Los_Angeles'` → `2012-10-30 18:00:00.000 America/Los_Angeles`. Same instant in time, different wall-clock label. Therefore comparing `current_timestamp AT TIME ZONE 'X'` to `current_timestamp` is comparing **the same value**.

#### PREFERRED — zone-aware boundary-literal half-open range (sargable, partition-prunes)

```sql
-- "Rows whose local NYC wall clock falls on/after 2026-06-01 and before 2026-07-01."
SELECT *
FROM iceberg.analytics.events
WHERE created_at >= TIMESTAMP '2026-06-01 00:00:00 America/New_York'
  AND created_at <  TIMESTAMP '2026-07-01 00:00:00 America/New_York';
```

Why this is the recommended form:

- **Sargable.** The column `created_at` appears un-wrapped on the left of the predicate. Trino's predicate pushdown can convert these literal bounds into manifest-level partition filters when the Iceberg table is partitioned by `day(created_at)` or `month(created_at)` — only the matching data files are read. (See resource 10 for Iceberg partition pruning.)
- **Half-open `>= ... AND < ...`** is the standard idiom for date ranges. It avoids the classic BETWEEN-with-`23:59:59.999999`-fencepost mistake (BETWEEN is inclusive on both ends, which collides with sub-second resolution).
- **The literal `TIMESTAMP 'YYYY-MM-DD HH:MM:SS America/New_York'`** is a valid `TIMESTAMP WITH TIME ZONE` literal in Trino — IANA zone names are accepted, as are numeric offsets like `-04:00` and UTC aliases (`UTC`, `Z`, `GMT`). Verified at [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html).

#### ALSO CORRECT — `CAST(... AT TIME ZONE 'zone' AS date)` for ad-hoc / non-pruning scans

```sql
-- Wrap the column for the comparison; OK for small scans, NOT for production partition-pruned queries.
SELECT *
FROM iceberg.analytics.events
WHERE CAST(created_at AT TIME ZONE 'America/New_York' AS date) >= DATE '2026-06-01'
  AND CAST(created_at AT TIME ZONE 'America/New_York' AS date) <  DATE '2026-07-01';
```

When to use this form: ad-hoc exploration, small lookup tables, or when you genuinely need the **local date** as a derived value (e.g., to `GROUP BY` it). `AT TIME ZONE 'America/New_York'` re-renders each timestamp in NYC time, then `CAST(... AS date)` truncates to the NYC local date — this **is** the correct way to derive the local date for comparison.

**Caveat — wrapping the column defeats partition pruning.** The Trino CBO cannot push down a predicate on `CAST(col AT TIME ZONE ... AS date)` into Iceberg's partition filter the same way it pushes down `col >= TIMESTAMP '...'`. For large partitioned tables, prefer the PREFERRED form above. There is an open optimizer issue ([github.com/trinodb/trino/issues/12729](https://github.com/trinodb/trino/issues/12729)) to "unwrap cast of timestamp with normalized zone to date in comparison" — until that lands, the boundary-literal form is what you write for production.

#### DO NOT WRITE (i) — BETWEEN with bare VARCHAR strings against a TIMESTAMP WITH TIME ZONE column

```sql
-- TYPE ERROR at analysis time. Trino rejects the query.
WHERE created_at BETWEEN '2026-06-01' AND '2026-06-30';

-- Same trap even with AT TIME ZONE wrapping:
WHERE created_at AT TIME ZONE 'America/New_York' BETWEEN '2026-06-01' AND '2026-06-30';
```

**Why it fails.** Bare-quoted `'2026-06-01'` is a `VARCHAR` literal. **Trino has NO implicit `VARCHAR` → `TIMESTAMP WITH TIME ZONE` coercion.** The query fails at analysis time with a type-mismatch error like `Cannot apply operator: timestamp(6) with time zone >= varchar(10)`. The fix is to write explicit `TIMESTAMP '...'` literals (or `DATE '...'` literals where appropriate) — never rely on string→timestamp inference. Verified at [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html).

#### DO NOT WRITE (ii) — `AT TIME ZONE 'X' >= DATE '...'` for "filter by local date >= X"

```sql
-- SEMANTICALLY MISLEADING — returns wrong rows (off by hours).
WHERE created_at AT TIME ZONE 'America/New_York' >= DATE '2026-06-02';
```

**Why it produces wrong rows.** `created_at AT TIME ZONE 'America/New_York'` returns `timestamp(p) with time zone` (a TZ-bearing timestamp, NOT a date). Comparing a TZ-bearing timestamp to a `DATE` literal triggers implicit coercion of the `DATE` to a timestamp at midnight — and the engineer's mental model "midnight on 2026-06-02 in NYC time" is **not** what the coercion produces. The result does **not** filter by "local NYC date on/after June 2" as intended; it filters by an instant that is offset by hours from what you want. Engineers seeing this in production typically report "my report is off by 4 hours" or "I'm missing the first 4-5 hours of June 2." See [github.com/trinodb/trino/issues/12729](https://github.com/trinodb/trino/issues/12729) for the related round-trip optimization gap.

**Correct fix:** use either the PREFERRED form (boundary-literal zone-aware `TIMESTAMP`) or the ALSO-CORRECT form with the explicit `CAST(... AT TIME ZONE 'zone' AS date)` on the LEFT — both make the local-date intent unambiguous.

#### DO NOT WRITE (iii) — `current_timestamp AT TIME ZONE 'X'` as a historical lower bound

```sql
-- ZERO ROWS — current_timestamp AT TIME ZONE 'X' is the SAME instant as current_timestamp.
WHERE created_at >= current_timestamp AT TIME ZONE 'America/New_York';
```

**Why it returns zero rows.** As stated in the core semantic above, `AT TIME ZONE` does **not** subtract or add hours from the value; it just re-labels the same instant in a different zone. So `current_timestamp AT TIME ZONE 'America/New_York'` is exactly **now**, not "midnight NYC today" or "today's start in NYC." Using it as a lower bound on a historical column returns rows whose `created_at` is in the future — i.e., none, for backward-looking data.

**Correct forms for "last N days in NYC local time":**

```sql
-- Last 7 days, anchored to NYC midnight, half-open.
WHERE created_at >= date_trunc('day', current_timestamp AT TIME ZONE 'America/New_York') - INTERVAL '7' DAY;

-- Equivalent: rolling 7 * 24-hour window ending now (NOT tied to local midnight).
WHERE created_at >= current_timestamp - INTERVAL '7' DAY;
```

The first form anchors to **midnight NYC today** then subtracts 7 days — what most "daily report covering the last 7 NYC days" intents actually want. The second form is a rolling instant-based window; pick consciously based on what your report needs.

#### Summary cheat-sheet (post this in the dbt model PR review checklist)

| Intent | CORRECT (use this) | WRONG (do NOT write) |
|---|---|---|
| Rows in a given local-date range (NYC, June 2026) | `created_at >= TIMESTAMP '2026-06-01 00:00:00 America/New_York' AND created_at < TIMESTAMP '2026-07-01 00:00:00 America/New_York'` | `created_at BETWEEN '2026-06-01' AND '2026-06-30'` (type error); `created_at AT TIME ZONE 'America/New_York' BETWEEN '2026-06-01' AND '2026-06-30'` (type error) |
| Rows on/after a given local NYC date | `created_at >= TIMESTAMP '2026-06-02 00:00:00 America/New_York'` | `created_at AT TIME ZONE 'America/New_York' >= DATE '2026-06-02'` (off-by-hours, wrong rows) |
| Rows in a date range on a **plain `TIMESTAMP` (no TZ) column** — Q1 2026 example | `ts >= DATE '2026-01-01' AND ts < DATE '2026-04-01'` (half-open: bump upper bound by one day, use `<`) | `ts BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'` — BETWEEN is **inclusive on both bounds** (per [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html): *"value BETWEEN min AND max ... equivalent to ... value >= min AND value <= max"*) AND a bare DATE literal promotes to TIMESTAMP at **midnight** (`2026-03-31 00:00:00` — per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): *"The time defaults to `00:00:00.000`"*). Net effect: you SILENTLY MISS almost all of March 31 (everything after midnight) — only rows at exactly `2026-03-31 00:00:00.000000` (and earlier) pass. No error; the result count just looks "a day short" and the bug hides on inspection because Mar 31 IS in the table. Fix = half-open `< DATE '2026-04-01'` (the day AFTER the inclusive end). Same trap on `TIMESTAMP(6)` / `TIMESTAMP(3)` columns — the column's sub-second precision is irrelevant; what matters is the DATE literal coerces to midnight on the LEFT edge of the upper-bound day. |
| Rows in last 7 NYC local days | `created_at >= date_trunc('day', current_timestamp AT TIME ZONE 'America/New_York') - INTERVAL '7' DAY` | `created_at >= current_timestamp AT TIME ZONE 'America/New_York'` (returns zero rows — same instant as `current_timestamp`) |
| Derive local NYC date for GROUP BY | `CAST(created_at AT TIME ZONE 'America/New_York' AS date)` (correct local-date extraction) | `CAST(created_at AS date)` (gives UTC date, not NYC date) |

**One more reflex to unlearn.** Tweaking the Trino worker's JVM `-Duser.timezone` is NOT the lever for this problem. The JVM TZ flag affects how naive timestamps are interpreted at the JVM layer and can vary between workers; the **reliable** levers are SQL-level (`SET TIME ZONE`, `sql.forced-session-time-zone`, or `AT TIME ZONE` per expression). Resource 22 §13.x guardrail covers the SQL-vs-JVM rule in more depth for the federation case.

Sources (verified June 2026): [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) (AT TIME ZONE worked example, at_timezone function signature); [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) (TIMESTAMP WITH TIME ZONE literal forms — IANA zone names, numeric offsets, UTC aliases); [trino.io/docs/current/sql/set-time-zone.html](https://trino.io/docs/current/sql/set-time-zone.html) (session-TZ command).

### 4.3 String functions

| Oracle | Trino | Notes |
|---|---|---|
| `SUBSTR(s, start, len)` | `substr(s, start, len)` OR `substring(s FROM start FOR len)` | Both 1-indexed; same as Oracle. **NEGATIVE START SUPPORTED.** Per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html), Trino `substr(string, start[, length])` supports a NEGATIVE `start` that counts from the END: `substr('Quadratically', -5)` -> `'cally'` (last 5 chars). Oracle `SUBSTR(s, -n)` ports DIRECTLY to Trino `substr(s, -n)` — no rewrite needed. **NO `right()` / `left()` IN TRINO.** Trino has NO `right(s, n)` or `left(s, n)` function — calling either produces `Function 'right' not registered`. Use `substr(s, -n)` for the LAST n chars; `substr(s, 1, n)` for the FIRST n chars. Keyword anchors: substr negative index Trino, last N characters Trino, right left function Trino does not exist, SUBSTR from end. |
| `INSTR(s, sub)` | `strpos(s, sub)` | Returns position (1-indexed); `0` if not found, same as Oracle. |
| `INSTR(s, sub, 1, n)` (position of the **n-th occurrence**) | `strpos(s, sub, n)` — the **3-arg form** | **Trino `strpos` HAS a 3-arg form: `strpos(string, substring, instance) -> bigint`** returns the position (1-indexed) of the **N-th `instance`** of `substring`; `0` if there are fewer than `n` occurrences. Verbatim per [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html): *"Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`."* So `strpos('a.b.c.d', '.', 2)` → `4` (the 2nd dot); a **negative** instance counts from the end: `strpos('a.b.c.d', '.', -1)` → `6` (the LAST dot). **DO NOT WRITE** "Trino strpos is 2-arg only / has no n-th-occurrence form" — that is a **base-training myth**; the 3-arg form exists. Keyword anchors: position of the second occurrence, nth occurrence of a character Trino, find the 2nd/3rd instance, position of last occurrence, find n-th delimiter position. (`regexp_position(string, pattern)` also exists for regex-based positions — see §4.3-STR-FAMILY / the regexp set at the inoculation block below.) Oracle's optional `start` offset has no direct 3-arg analog; if you need both a start offset AND an occurrence count, use `strpos` on a `substr(s, start)` slice (and add `start - 1` back). |
| split a delimited string and grab the N-th piece (e.g. subdomain from `acme.ourapp.com`) | `split_part(s, delimiter, n)` — `split_part(url, '.', 1)` → `'acme'` | 1-indexed; signature `split_part(string, delimiter, index)`. **Verified nuance: if `index` is out of range, Trino returns `NULL` — NOT an empty string** (trino.io string-functions; Trino #14460). Do NOT write "returns empty string if the index is missing" — that's a base-training myth. For full URLs (`https://acme.ourapp.com/x`) use `regexp_extract(url, '([a-z0-9-]+)\.ourapp\.com', 1)` instead. |
| `LENGTH(s)` | `length(s)` | Identical. |
| `LPAD(s, n, pad)` / `RPAD(s, n, pad)` | `lpad(s, n, pad)` / `rpad(s, n, pad)` | **Trino signature is `lpad(varchar, bigint, varchar) -> varchar`** (verbatim per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html)) — the first argument MUST be a VARCHAR. **UNLIKE Oracle `LPAD`, Trino does NOT implicitly coerce a NUMBER to a string.** For a numeric column (BIGINT / INTEGER / DECIMAL), you MUST `CAST` first: `lpad(CAST(account_id AS VARCHAR), 10, '0')` — same root cause as the `\|\|` / `CONCAT` no-numeric-coercion rule one row below (see also §7A.3.1). **DO-NOT-WRITE:** `lpad(<numeric_col>, n, '0')` directly on a BIGINT/INTEGER/DECIMAL column raises `Unexpected parameters (bigint, integer, varchar(1)) for function lpad. Expected: lpad(varchar, bigint, varchar)`. Keyword anchors: zero-pad number Trino, lpad numeric column, pad account number, lpad cast varchar, rpad numeric. |
| `LTRIM(s)` / `RTRIM(s)` / `TRIM(s)` | `ltrim(s)` / `rtrim(s)` / `trim(s)` | Identical for the **whitespace** form. **Trino `trim` ALSO has a char-set form** — `trim([LEADING\|TRAILING\|BOTH] [chars] FROM source)` — for stripping a SPECIFIC character (e.g. leading zeros `'00042'`->`'42'`), not just whitespace. See the **§4.3-STRIP-ZEROS — strip leading/trailing characters (not whitespace)** block immediately below the table. |
| ``a || b`` (concatenation) | `a \|\| b` OR `concat(a, b)` | Same operator. **BUT two big differences**: (1) Oracle treats `NULL \|\| 'x'` as `'x'` (quirk); Trino returns `NULL` (standard) — wrap in `COALESCE`. (2) **Oracle implicitly coerces numbers/dates to strings inside `\|\|`; Trino does NOT** — `CONCAT` and `\|\|` both require all-VARCHAR args, so `CAST(year_int AS VARCHAR)` or use `format('FQ-%d', year_int)`. See §7A.3.1 for the canonical fix. |
| `UPPER(s)` / `LOWER(s)` / `INITCAP(s)` | `upper(s)` / `lower(s)` / **NO `initcap` in Trino 467** — use the `regexp_replace` lambda idiom below. | `upper`/`lower` port 1:1. **Trino has NO `initcap` / title-case / proper-case built-in** (unlike Oracle/Postgres). See the **§4.3-STR-FAMILY INITCAP / title-case** block immediately below for the verified one-call idiom. |
| `REPLACE(s, from, to)` | `replace(s, from, to)` | Identical. |
| `TRANSLATE(s, from, to)` (Oracle: positional char-by-char substitution — replace each char in `from` with the char at the same index in `to`; chars not in `from` are copied unchanged; if `from` is longer than `to`, chars whose match index exceeds `to`'s length are DROPPED) | `translate(source, from, to) -> varchar` — **EXACT 1:1 PORT.** Same name (lowercase), same arg order, same positional-char-substitution semantics. Per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html): "Replaces characters found in the `from` string with corresponding characters in the `to` string." Oracle `TRANSLATE(phone, '0123456789', '##########')` → Trino `translate(phone, '0123456789', '##########')` — verbatim, no rewrite. See §4.3-STR-FAMILY immediately below for the full string-family canonical (translate / reverse / position / levenshtein_distance / concat_ws). |
| `REGEXP_SUBSTR(s, pattern)` | `regexp_extract(s, pattern)` | Renamed. Both 1-indexed group access via 3rd arg. See §4.3A for flavor diffs. |
| `REGEXP_REPLACE(s, pattern, repl)` | `regexp_replace(s, pattern, repl)` | Same signature. **BUT capture-group reference syntax differs** — Oracle `\1`, Trino `$1`. See §4.3A. |

### 4.3-STRIP-ZEROS — LEADING CANONICAL: strip leading zeros / remove a padding character (the `trim([LEADING|TRAILING|BOTH] chars FROM s)` char-set form)

**Keyword anchors (READ THIS FIRST if your question contains any of these):** strip leading zeros, remove leading zeros, trim a specific character, remove padding zeros, strip leading/trailing characters (not whitespace), remove a padding char from a code, trim a character that is not whitespace, unpad a zero-padded code, drop leading zeros from a product code / SKU / account number.

**The one fact.** `trim(LEADING '0' FROM code)` removes leading `'0'` characters and **PRESERVES the string** — it is **alphanumeric-safe** (does NOT reinterpret the identifier as a number). Trino 467's `trim` is NOT whitespace-only: it supports `trim([LEADING | TRAILING | BOTH] [chars] FROM source)`, so you can strip ANY specific character, not just spaces. Verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html) on 2026-06-07.

**Docs quote (verbatim).** The Trino string-functions doc lists two forms of `trim`:
- `trim(string) → varchar` — "Removes leading and trailing whitespace from `string`."
- `trim([ [ specification ] [ string ] FROM ] source) → varchar` — "Removes any leading and/or trailing characters as specified up to and including `string` from `source`." (`specification` = `LEADING` / `TRAILING` / `BOTH`.) Docs examples: `trim('!' FROM '!foo!')` → `'foo'`; `trim(BOTH '$' FROM '$var$')` → `'var'`.

**Worked examples.**

```sql
SELECT trim(LEADING '0' FROM '00042');    -- '42'   (strip leading zeros)
SELECT trim(LEADING '0' FROM '00042A');   -- '42A'  (alphanumeric-safe: trailing 'A' kept, NOT reinterpreted as a number)
SELECT trim(TRAILING '#' FROM 'ABC###');  -- 'ABC'  (strip a trailing padding char)
SELECT trim(BOTH '0' FROM '00420');       -- '42'   (strip both ends)
```

**Fragility note — do NOT use the integer-cast trick on a STRING identifier.** `CAST(CAST(code AS integer) AS varchar)` strips leading zeros for **purely-numeric** codes (`'00042'` -> `'42'`) BUT is FRAGILE: it **errors** on alphanumeric codes (`'00042A'`, `'SKU-042'` → cast error `Cannot cast '00042A' to integer`) and it **reinterprets the identifier as a number** (`'00000'` -> `'0'`, not the empty string `''`). For a string identifier — product code, SKU, account number — prefer `trim(LEADING '0' FROM code)`, which never errors and never re-types your identifier.

**DO-NOT-WRITE.**

| DO NOT write | Why it's wrong | Correct |
|---|---|---|
| `CAST(CAST(product_code AS integer) AS varchar)` to strip leading zeros from a string identifier that may contain non-numeric chars | **Cast error** on alphanumeric codes (`'00042A'` → `Cannot cast '00042A' to integer`); also reinterprets the value as a number (`'00000'` collapses to `'0'`, not `''`). | `trim(LEADING '0' FROM product_code)` — string-preserving, alphanumeric-safe, never errors. |
| "Trino `trim` only removes whitespace; there's no way to strip a specific char without `regexp_replace`" | **FALSE.** `trim([LEADING\|TRAILING\|BOTH] '0' FROM s)` strips a specific character set directly. Reach for `regexp_replace(s, '^0+', '')` only if you need a multi-char pattern or anchoring beyond a fixed char set. | `trim(LEADING '0' FROM s)`. |

### 4.3-STR-FAMILY — LEADING CANONICAL: Trino string-function family that gets fabricated as "missing" (translate / reverse / position / levenshtein_distance / concat_ws)

**Keyword anchors (read this section if your question contains any of these):** Oracle TRANSLATE Trino, Trino translate function, translate char substitution, mask digits translate, char-by-char substitution Trino, reverse string Trino, Trino reverse function, position INSTR Trino, Trino position function, levenshtein fuzzy match, edit distance Trino, levenshtein_distance signature, concat_ws Trino, Trino concat_ws exists, join strings with separator Trino, Trino string functions, Trino string-function family.

**Why this section exists.** Engineers porting Oracle PL/SQL or Postgres SQL frequently get TOLD by base-trained AI models that Trino LACKS one of `translate`, `reverse`, `position`, `levenshtein_distance`, or `concat_ws` — and gets routed to a clunky `regexp_replace` / nested `replace()` workaround. **All five DO exist in Trino 467**, verified against [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html). This canonical pins the signatures so the workaround advice does not propagate.

| Function | Exact Trino 467 signature (verbatim from docs) | Behavior | One-line worked example |
|---|---|---|---|
| **`translate(source, from, to) -> varchar`** | `translate(source, from, to) -> varchar` | Positional char-by-char substitution: each character in `source` that appears at index `i` in `from` is replaced with the character at index `i` in `to`. Chars in `source` not in `from` are copied unchanged. **If the match index `i` exceeds `to`'s length, the char is OMITTED** (drop, not preserve). **EXACT 1:1 OF ORACLE TRANSLATE** — same name, same arg order, same semantics. | Mask all digits in a phone number: `translate('555-1234', '0123456789', '##########')` → `'###-####'`. Strip vowels: `translate('hello', 'aeiou', '')` → `'hll'`. |
| **`reverse(string) -> varchar`** | `reverse(string) -> varchar` | Returns the input string with characters in reverse order. | `reverse('hello')` → `'olleh'`. Check if a string is a palindrome: `WHERE col = reverse(col)`. |
| **`position(substring IN string) -> bigint`** | `position(substring IN string) -> bigint` | 1-indexed position of the FIRST occurrence of `substring` in `string`; returns `0` if not found. **Identical to Oracle 2-arg `INSTR(string, substring)`.** Note the SQL-standard `IN` keyword inside the parens — this is one of the few Trino built-ins that uses an SQL-keyword arg syntax instead of comma-separated args. The function-call form **`strpos(string, substring) -> bigint`** is the canonical comma-separated equivalent — same return semantics, same 1-indexed, same `0`-if-not-found — and is what the §4.3 INSTR row maps to. Use either; `strpos` is more readable in subqueries / CTEs. | `position('@' IN 'a@b.com')` → `2`. `strpos('a@b.com', '@')` → `2`. Both equal Oracle `INSTR('a@b.com', '@')` → `2`. |
| **`levenshtein_distance(string1, string2) -> bigint`** | `levenshtein_distance(string1, string2) -> bigint` | Minimum number of single-character edits (insert, delete, substitute) needed to transform `string1` into `string2`. Classic fuzzy-match / typo-tolerance primitive. | `levenshtein_distance('kitten', 'sitting')` → `3`. Fuzzy join: `WHERE levenshtein_distance(lower(a.name), lower(b.name)) <= 2`. |
| **`concat_ws(separator, string1, ..., stringN) -> varchar`** | `concat_ws(separator, string1, ..., stringN) -> varchar` | Joins the N input strings using `separator`. **Skips NULL string arguments** (NULL values after the separator are NOT included in the output — UNLIKE plain `concat()` which propagates NULL). If the separator itself is NULL, the result is NULL. **`concat_ws` DOES exist in Trino 467** — earlier resource passes incorrectly claimed it was Postgres/Spark-only. That claim is FALSE. Verified at [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html). | `concat_ws('-', 'a', 'b', 'c')` → `'a-b-c'`. With NULL: `concat_ws('-', 'a', NULL, 'c')` → `'a-c'` (NULL skipped). Compare with `concat('a', NULL, 'c')` → `NULL` (NULL propagates). |

**Cross-references inside r27.**
- `strpos` is the canonical Oracle-INSTR-mapping row in §4.3 (line 875) and the same function as `position(substring IN string)` — pick whichever reads better in your model.
- The hand-rolled surrogate-key fallback in §4.5A can now use `to_hex(md5(to_utf8(concat_ws('||', CAST(a AS VARCHAR), CAST(b AS VARCHAR)))))` — the `concat_ws` form compiles on Trino 467 and is often more readable than nested `concat()`.

**DO-NOT-WRITE — claims about these five functions that are FALSE on Trino 467 (each has produced a confirmed fabricated answer in past iterations):**

| DO NOT write | Why it's wrong | Correct claim |
|---|---|---|
| "Trino has no `TRANSLATE` / no direct equivalent to Oracle TRANSLATE — use nested `replace()` or `regexp_replace` for char substitution" | **FABRICATED.** Trino 467 has `translate(source, from, to) -> varchar` — the EXACT 1:1 port of Oracle TRANSLATE with the same name, arg order, and positional-char-substitution semantics. Downgrading to `regexp_replace` or nested `replace()` is unnecessary, slower (regex engine startup per row), and silently-wrong for the `from`-longer-than-`to` drop case. | Port Oracle `TRANSLATE(s, from, to)` to Trino `translate(s, from, to)` — verbatim, no rewrite. |
| "Trino has no `reverse` function for strings" | **FABRICATED.** Trino has `reverse(string) -> varchar` (the docs also define `reverse(array)` — same name, different overload). | `reverse('hello')` → `'olleh'`. |
| "Trino has no `position` function — use `strpos` instead" | **HALF-WRONG.** Trino has BOTH `position(substring IN string)` (SQL-standard form) and `strpos(string, substring)` (function-call form) — same return semantics, both 1-indexed. Pick either; do not assert that `position` is missing. | Both work; `strpos` is the comma-arg form, `position(... IN ...)` is the SQL-standard form. |
| "Trino has no `levenshtein_distance` / no edit-distance function" | **FABRICATED.** `levenshtein_distance(string1, string2) -> bigint` is a built-in. | Use directly: `WHERE levenshtein_distance(a, b) <= 2` for fuzzy match. |
| "Trino has no `concat_ws` — it's Postgres/Spark/MySQL only" | **FABRICATED (reconciled in iter531).** Trino 467 has `concat_ws(separator, string1, ..., stringN) -> varchar` per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html). Skips NULL strings (UNLIKE plain `concat()`). Earlier passes of this resource incorrectly banned `concat_ws` as missing; that ban is rescinded. The ONLY constraint on `md5(concat_ws(...))` is the `md5(varbinary)` type wrap — wrap the varchar in `to_utf8(...)` before `md5`. | Use `concat_ws('-', a, b, c)` directly; for surrogate-key hashing wrap in `to_utf8` first: `to_hex(md5(to_utf8(concat_ws('||', CAST(a AS VARCHAR), CAST(b AS VARCHAR)))))`. |

#### 4.3-STR-FAMILY — INITCAP / title-case / proper-case: Trino has NO `initcap` (use the `regexp_replace` lambda idiom)

**Keyword anchors (read this if your question contains any of these):** initcap Trino, title case Trino, capitalize first letter of each word, proper case, capitalize each word, Oracle INITCAP equivalent Trino, Postgres initcap Trino, make first letter uppercase, name casing, capitalize names, sentence case vs title case.

**The one fact.** **Trino 467 has NO `initcap` function** (verified against [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html) — the string-function list contains `chr`, `concat`, `concat_ws`, `length`, `lower`, `lpad`, `ltrim`, `position`, `replace`, `reverse`, `rpad`, `rtrim`, `split`, `split_part`, `strpos`, `substr`, `substring`, `translate`, `trim`, `upper` — **no `initcap`**). Oracle and Postgres both have `INITCAP`; calling `initcap(...)` in Trino raises `Function 'initcap' not registered`. **DO NOT WRITE** "use Trino's `initcap`" — it does not exist.

**The verified one-call idiom (title-case each word).** Use the `regexp_replace` **lambda** replacement form — verbatim from the Trino regexp docs ([trino.io/docs/467/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html)):

```sql
-- Capitalize the first letter of EACH word (title case / proper case):
SELECT regexp_replace(lower(full_name), '(\w)(\w*)', x -> upper(x[1]) || lower(x[2])) AS title_cased;
-- 'jane DOE' -> 'Jane Doe'   ;   'new york' -> 'New York'
```

The lambda receives the capture groups as an array `x` (1-indexed; there is no group 0): `x[1]` is the first letter of each word, `x[2]` is the rest. Wrapping the input in `lower(...)` first normalizes ALL-CAPS or mixed input so only the leading letter ends up uppercase. This is the **exact Trino-docs example** (`regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` -> `'New York'`).

**Per-word alternative (no regex):** if you prefer no regex, split → transform → re-join: `array_join(transform(split(lower(s), ' '), w -> upper(substr(w, 1, 1)) || substr(w, 2)), ' ')`. Both compile on Trino 467; the `regexp_replace` lambda form is shorter and handles arbitrary whitespace/word boundaries via `\w`.

### 4.3A REGEX-FLAVOR GUARDRAIL — Trino regex is Java/JONI, Oracle regex is POSIX-extended (the four migration nuances that bite)

**Why this section exists.** The §4.3 string-function table's "Identical" gloss for `REGEXP_LIKE` / `REGEXP_SUBSTR` / `REGEXP_REPLACE` is **misleading on three counts** that produce *silently-wrong* (not parse-error) results — the function name maps cleanly, but the semantics of the same pattern differ. Engineers migrating Oracle regexes literally (s/REGEXP_LIKE/regexp_like/) get correct results on ~80% of patterns and silent wrong-row counts on the remaining ~20%. The four nuances below are the verified differences.

**The four migration nuances (read all four before lifting any Oracle regex to Trino).**

| # | Nuance | Oracle behavior | Trino 467 behavior | Migration recipe |
|---|---|---|---|---|
| **1** | **CONTAINS vs FULL-MATCH semantics for `LIKE`-style match** | `REGEXP_LIKE(s, '[0-9]+')` returns true if the string CONTAINS any digit run (and Oracle is also contains-by-default for `REGEXP_LIKE` — anchors required for full-match). | `regexp_like(s, '[0-9]+')` returns true if the string CONTAINS any digit run. **Per [trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html): "the pattern only needs to be contained within string, rather than needing to match all of it." Anchor with `^...$` to require full-string match in either dialect.** | The semantics are aligned here, but the misconception that "Oracle anchors implicitly" trips migrators. If your Oracle pattern lacked anchors and produced contains-style matches, the Trino translation behaves the same. Both dialects need `^...$` for full-match. |
| **2** | **Regex engine flavor — POSIX extended (Oracle) vs Java/JONI (Trino)** | POSIX Extended Regular Expressions (ERE) + Oracle's added backreference `\1`...`\9`. Documented at [docs.oracle.com/...REGEXP_LIKE](https://docs.oracle.com/cd/B12037_01/server.101/b10759/conditions018.htm). | Java pattern syntax via the JONI engine by default (RE2J optionally enabled via the `regex-library` catalog property — see [trino.io/docs/current/admin/properties-regexp-function.html](https://trino.io/docs/current/admin/properties-regexp-function.html)). Per [trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html): "Trino uses Java pattern syntax, with a few notable exceptions." | Differences that bite in practice: (a) **lookaround** (`(?=...)`, `(?<=...)`, `(?!...)`) is fully supported in Java/JONI; Oracle POSIX ERE does NOT support lookaround. Patterns lifted to Trino with lookaround work; the reverse does not. (b) **`\d`, `\w`, `\s` shorthand** works in Trino (Java) but is NOT in POSIX ERE — Oracle requires `[[:digit:]]` / `[[:alpha:]]` / `[[:space:]]` POSIX bracket-classes. When you see `[[:digit:]]` in Oracle source, **rewrite as `\d` for Trino** (Java syntax) or leave the POSIX bracket form — Java pattern actually accepts both. (c) **POSIX `[[:alpha:]]` works in BOTH** (Java pattern includes POSIX class aliases) — verify before rewriting. |
| **3** | **Capture-group reference syntax in `regexp_replace` replacement** | `\1`, `\2`, ... `\9` (backslash + digit) in the replacement string. Example: `REGEXP_REPLACE(phone, '(\d{3})(\d{4})', '\1-\2')` produces `555-1234`. | **`$1`, `$2`, ...** (dollar + digit) in the replacement string. Example: `regexp_replace(phone, '(\d{3})(\d{4})', '$1-$2')` produces `555-1234`. Verified at [trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html). | **This is the most common silent-wrong slip.** Lifted `\1` to Trino emits a LITERAL backslash-1 in the output, not the captured group. ALWAYS rewrite `\<digit>` → `$<digit>` in every `regexp_replace` replacement string during migration. Audit checklist: `grep -E 'regexp_replace.*\\\\[0-9]'` on the Trino-side dbt SQL — any hit is a migration bug. |
| **4** | **Group access in `regexp_extract` — Trino has a 3rd `group` arg; Oracle uses a separate function/arg position** | Oracle `REGEXP_SUBSTR(s, pattern, position, occurrence, match_param, subexpression)` — the 6th argument selects the capture group. Underused; most migration sources just have `REGEXP_SUBSTR(s, pattern)`. | `regexp_extract(string, pattern)` returns the full match. `regexp_extract(string, pattern, group)` returns the N-th capture group (1-indexed; `0` returns full match). | When the Oracle source uses the 6th-arg form, port to Trino's 3rd-arg form: `REGEXP_SUBSTR(phone, '(\d{3})(\d{4})', 1, 1, NULL, 2)` → `regexp_extract(phone, '(\d{3})(\d{4})', 2)`. |

#### LEADING CANONICAL — flag rows whose text contains ANY of several keywords (multi-keyword text search with `regexp_like(col, 'a|b|c')`)

> **READ THIS FIRST if your question contains any of these keywords:** `contains any of several keywords`, `multi-keyword text search`, `mentions any of`, `matches any of these words`, `body contains one of`, `flag rows containing any of a list of terms`, `text contains any keyword`, `column contains one of several words`, `search for multiple terms`, `match any of these strings`. Verified at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) on 2026-06-07.

**The one-fact summary.** `regexp_like(col, 'a|b|c')` returns **TRUE if `col` CONTAINS any of the alternatives `a`, `b`, or `c`** — `regexp_like` is a **CONTAINS operation** (no `^...$` anchors needed; per the docs *"the pattern only needs to be contained within `string`, rather than needing to match all of it"* — it *"performs a `contains` operation rather than a `match` operation"*). The `|` is **regex alternation** ("or"). Use this single call **instead of chaining many `OR LIKE` conditions**.

```sql
-- Flag any ticket whose body contains ANY of the three words (case-sensitive)
SELECT * FROM tickets
WHERE regexp_like(body, 'refund|cancel|chargeback');

-- Case-insensitive variant — inline (?i) flag applies to the whole alternation
SELECT * FROM tickets
WHERE regexp_like(body, '(?i)refund|cancel|chargeback');
```

**Equivalent multiple-`LIKE`-`OR` form** (valid Trino, but verbose — gets unwieldy past 2–3 terms):

```sql
SELECT * FROM tickets
WHERE body LIKE '%refund%' OR body LIKE '%cancel%' OR body LIKE '%chargeback%';
```

The `regexp_like(body, 'refund|cancel|chargeback')` form is the concise idiom; add terms by extending the `|`-list. (For case-insensitive multi-LIKE you would need `LOWER(body) LIKE '%refund%' OR ...` on every branch — another reason the `(?i)` regex form is cleaner.)

> **INOCULATION — there is NO `RLIKE` in Trino 467.** Trino 467 has **no `RLIKE` function or operator** — `RLIKE` is **Hive / Spark / MySQL**, NOT Trino. Writing `RLIKE(col, pattern)` (or `col RLIKE pattern`) is a **function-not-registered / parse error** on Trino. The Trino regex-match function is **`regexp_like(col, pattern)`** (returns `boolean`). The complete Trino 467 regex function set is exactly: `regexp_count`, `regexp_extract_all`, `regexp_extract`, `regexp_like`, `regexp_position`, `regexp_replace`, `regexp_split` — **`RLIKE` is ABSENT** from this list ([trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html), verified 2026-06-07). **Do NOT write `RLIKE`.**

| Banned form | Why wrong | Correct Trino 467 form |
|---|---|---|
| `RLIKE(body, 'refund\|cancel\|chargeback')` | `RLIKE` is **not a Trino function** (it is Hive/Spark/MySQL) — `Function 'rlike' not registered`. | `regexp_like(body, 'refund\|cancel\|chargeback')` — the Trino regex-match function, returns `boolean`. |
| `body RLIKE 'refund\|cancel\|chargeback'` (infix operator) | Trino has no `RLIKE` infix operator — parse error. | `regexp_like(body, 'refund\|cancel\|chargeback')`. |

**A bonus Trino-only capability — lambda replacement in `regexp_replace`.** Trino's `regexp_replace(string, pattern, function)` accepts a lambda for the third argument, giving per-match transformation logic that Oracle has no single-statement equivalent for:

```sql
-- Trino-only: lowercase every captured word, prefix with '<' '>'
SELECT regexp_replace('Foo BAR baz', '(\w+)', x -> '<' || lower(x[1]) || '>');
-- result: '<foo> <bar> <baz>'
```

The `x[1]` is the 1st capture group of the current match. This is *not* a portable construct; it's a Trino-only convenience worth knowing when re-implementing complex string transforms that Oracle did with PL/SQL loops.

#### LEADING CANONICAL — strip / remove characters matching a pattern (remove all non-digits, keep only digits, delete a pattern)

> **READ THIS FIRST if your question contains any of these keywords:** `remove all non-digits`, `strip non-numeric characters`, `keep only digits Trino`, `clean a phone number`, `remove punctuation / dashes / spaces`, `strip a pattern`, `delete matches Trino`, `regexp_replace remove`, `regexp_replace empty string`, `2-argument regexp_replace`, `regexp_replace no replacement`, `remove everything except letters`, `sanitize string Trino`. Verified at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) on 2026-06-07.

**The one-fact summary.** To DELETE every match of a pattern (rather than replace it with capture groups), you have two equivalent forms in Trino 467:

1. **The 2-argument form** `regexp_replace(string, pattern) -> varchar` — Trino docs verbatim: *"Removes every instance of the substring matched by the regular expression `pattern` from `string`."* No replacement argument at all.
2. **The 3-argument form with an EMPTY-STRING replacement** `regexp_replace(string, pattern, '')` — same result, the replacement is the empty literal `''`.

Both are valid; the 2-arg form is the most concise. **Remove all non-digits (the canonical phone-number cleanup):**

```sql
-- Keep ONLY the digits — strip dashes, spaces, parentheses, '+' etc.
-- '[^0-9]' = "any character that is NOT a digit"; \D is the Java shorthand and also works.
SELECT regexp_replace('+1 (555) 123-4567', '[^0-9]')       AS digits_2arg;   -- '15551234567'
SELECT regexp_replace('+1 (555) 123-4567', '[^0-9]', '')   AS digits_3arg;   -- '15551234567'  (identical)
SELECT regexp_replace('+1 (555) 123-4567', '\D')           AS digits_shorthand; -- '15551234567'
```

**Other common strip idioms (same 2-arg form, just swap the character class):**

```sql
SELECT regexp_replace('a1b2 c3!', '[^a-zA-Z]')   AS letters_only;   -- 'abc'      (remove everything except letters)
SELECT regexp_replace('  hello   world  ', '\s+', ' ') AS collapsed; -- ' hello world ' (collapse runs of whitespace to one space)
SELECT regexp_replace('PRICE: $1,234.56', '[^0-9.]') AS numeric_only; -- '1234.56'  (keep digits + decimal point)
```

> **DO NOT WRITE.** (1) **Do NOT reach for `translate(...)` or nested `replace(replace(replace(...)))` to strip "all non-digits"** — `translate`/`replace` can only remove a FIXED, enumerated set of characters you list explicitly; they cannot express "any character that is not a digit." For an open-ended character CLASS (non-digit, non-letter, non-alphanumeric), `regexp_replace(s, '[^0-9]')` is the correct, single-call idiom. Use `translate`/`replace` only when the set of characters to drop is small and known (e.g. strip exactly `-` and ` `: `replace(replace(s, '-', ''), ' ', '')`). (2) **Do NOT confuse the strip form with the capture-group reform form** — `regexp_replace(s, '(\d{3})(\d{4})', '$1-$2')` REFORMATS (keeps groups, inserts `-`); `regexp_replace(s, '[^0-9]')` DELETES. Different tasks. The `$1`/`$2` capture-group rules in nuance #3 above apply only to the reform form. (3) **`\D` and `\d`, not `[[:^digit:]]` muscle-memory from Postgres** — Trino uses Java pattern syntax; `\D` (non-digit) and `\d` (digit) both work directly.

**DO-NOT-WRITE matrix — banned regex forms when porting Oracle → Trino (each row has produced a confirmed silent-wrong result in past migrations).**

| Banned form (post-migration Trino SQL) | Why wrong | Correct form |
|---|---|---|
| `regexp_replace(s, '(\d+)', '\1')` | `\1` is literal "backslash-1" in Trino's Java/JONI replacement — emits two characters, NOT the captured group. | `regexp_replace(s, '(\d+)', '$1')` — `$1` is the capture-group reference in Java syntax. |
| `regexp_substr(s, pattern)` | **NO `regexp_substr` function exists on Trino 467** — parse error `Function 'regexp_substr' not registered`. | `regexp_extract(s, pattern)` — the rename. |
| `regexp_like(s, pattern, 'i')` (3-arg form with match-param flag) | Trino's `regexp_like` takes only 2 args. The flag-arg form is Oracle-only. | Embed the flag inline in the pattern with Java embedded flags: `regexp_like(s, '(?i)pattern')` for case-insensitive. Verified at [trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html). |
| `regexp_replace(s, pattern, repl, 1, 1, 'i')` (Oracle's 6-arg form) | Trino's `regexp_replace` takes 3 args (or 3 args with a lambda for the 3rd). Position / occurrence / match-param flags are Oracle-only. | Use `(?i)` inline flag for case-insensitive. For position/occurrence, combine with `substr` or `regexp_extract_all`. |
| `regexp_like(s, '[[:digit:]]+')` (assumed Oracle-only POSIX class) | **Actually works on Trino** — Java pattern supports POSIX character class aliases. Not banned, but the bias to rewrite all POSIX classes as `\d` is wasted effort. | Leave POSIX classes as-is if porting verbatim; rewrite only if you want shorter / more idiomatic Java syntax. |

**Audit script (drop-in shell command).** Run this against your migrated dbt models to catch the most common silent-wrong porting bug:

```bash
# Find any backslash-digit capture-group reference in Trino-targeted regexp_replace
# calls — these are silent-wrong porting bugs that emit literal text instead of
# the captured group.
grep -RnE "regexp_replace[^)]*'[^']*\\\\[0-9]" models/

# Find any regexp_substr call (Oracle-only; will parse-error on Trino).
grep -RnE "regexp_substr\(" models/
```

Both should produce ZERO matches on a clean migration.

**Cross-reference.** §4.4B (cross-dialect-spillover guardrail) covers the broader class of "Oracle/Postgres/Snowflake syntax that LOOKS valid on Trino but is not"; this §4.3A focuses on the regex sub-class because the function names ARE valid Trino but the semantics differ.

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
| `TRUNC(n, d)` (numeric truncation to `d` decimal places — Oracle) | `truncate(n * power(10, d)) / power(10, d)` — **lowercase 1-arg** `truncate`. For 2 decimals: `truncate(n*100)/100`. **If HALF_UP rounding is acceptable, `round(n, d)` is simpler** (but `round` is rounding, NOT truncation — they differ at the half-way mark and for negative numbers). | See §4.4C immediately below for the full numeric-TRUNC guardrail + DO-NOT-WRITE matrix. Verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) — Trino's `truncate(x)` is **1-arg only**; **no 2-arg `truncate(x, d)`** exists; `TRUNC` (uppercase Oracle name) is **not registered** in Trino. |
| `TRUNC(n)` (1-arg integer truncation toward zero — Oracle) | `truncate(n)` — **lowercase, 1-arg**. Returns same type as input with digits after the decimal point dropped. | `TRUNC(-3.7)` Oracle returns `-3`; Trino `truncate(-3.7)` returns `-3.0` (same toward-zero semantic; trailing `.0` from same-as-input type). |
| `ROUND(n, d)` (Oracle, HALF_UP rounding to d places) | `round(n, d)` — same name, same signature, same HALF_UP semantics. | Direct 1:1. |
| `MOD(a, b)` | `mod(a, b)` or `a % b` | Identical. |
| `ABS(n)` / `CEIL(n)` / `FLOOR(n)` / `SIGN(n)` | `abs(n)` / `ceil(n)` (or `ceiling(n)`) / `floor(n)` / `sign(n)` | All lowercase in Trino; identical semantics. |

### 4.4A TRINO-CAST-SYNTAX GUARDRAIL — Trino has NO `expr::type` cast operator; ALWAYS write `CAST(expr AS type)`

**Why this section exists.** Engineers migrating from Oracle frequently also have PostgreSQL muscle memory (or Snowflake / DuckDB muscle memory) and reflexively reach for the Postgres double-colon cast operator (`value::type`, e.g., `NULL::TIMESTAMP`, `id::int`, `'2026-05-30'::DATE`, `account_uuid::text`) in Trino SQL or dbt models targeting Trino. **Trino does NOT support the `::` cast operator.** Running such SQL through Trino produces an immediate parse error:

```
mismatched input '::'. Expecting: ...
```

Verified against [trino.io/docs/current/functions/conversion.html](https://trino.io/docs/current/functions/conversion.html): the **only** cast forms in Trino are:

| Form | Behavior | Use when |
|---|---|---|
| `CAST(expr AS type)` | Throws on failure (query error) | You want strict typing and any cast failure should fail the query. |
| `TRY_CAST(expr AS type)` | Returns `NULL` on failure | You want soft typing — bad input becomes NULL instead of failing the query. |

The Postgres-style `expr::type` operator is tracked as an **OPEN feature request** at [trinodb/trino #23795](https://github.com/trinodb/trino/issues/23795) — **NOT implemented as of Trino 467** (the production version on this stack) and **NOT implemented as of Trino 481** (the latest documented release). Treat `::` as permanently unavailable in Trino SQL; do not wait for it.

**DO-NOT-WRITE callout (load-bearing — copy this into your code-review checklist):**

> **Never write the Postgres-style `expr::type` cast operator in Trino SQL or in any dbt model that compiles to Trino.** Specifically banned forms:
> - `NULL::TIMESTAMP` — Trino parse error. Write `CAST(NULL AS TIMESTAMP)`.
> - `col::INT` / `col::INTEGER` / `col::BIGINT` — Trino parse error. Write `CAST(col AS INTEGER)` (or `BIGINT`).
> - `'2026-05-30'::DATE` — Trino parse error. Write `CAST('2026-05-30' AS DATE)` or `DATE '2026-05-30'`.
> - `'2026-05-30 12:00:00'::TIMESTAMP` — Trino parse error. Write `CAST('2026-05-30 12:00:00' AS TIMESTAMP)` or `TIMESTAMP '2026-05-30 12:00:00'`.
> - `col::VARCHAR` / `col::TEXT` — Trino parse error. Write `CAST(col AS VARCHAR)`.
> - `col::UUID` / `'a1b2c3d4-...'::uuid` — Trino parse error. Write `CAST(col AS UUID)` or the `UUID 'a1b2c3d4-...'` typed-literal.
> - `col::DECIMAL(18,2)` — Trino parse error. Write `CAST(col AS DECIMAL(18,2))`.
> - Any other `expression::type` form. The `::` token is unsupported anywhere in Trino's grammar.

**Worked Postgres → Trino translation table.** These are the most common `::` patterns and their Trino-compatible rewrites:

| Postgres (uses `::`) | Trino (use `CAST` or `TRY_CAST`) | Notes |
|---|---|---|
| `NULL::TIMESTAMP` | `CAST(NULL AS TIMESTAMP)` | Typed-null pattern (common in dbt incremental MERGE soft-delete models, see §4.6 soft-delete). |
| `NULL::TIMESTAMP(6) WITH TIME ZONE` | `CAST(NULL AS TIMESTAMP(6) WITH TIME ZONE)` | Always wrap typed nulls when the destination column requires explicit type info (e.g., MERGE target). |
| `'42'::INTEGER` | `CAST('42' AS INTEGER)` | For literals, prefer the explicit literal: `42` (no cast needed). |
| `col::BIGINT` | `CAST(col AS BIGINT)` | For nullable conversions where bad rows should become NULL: `TRY_CAST(col AS BIGINT)`. |
| `'2026-05-30'::DATE` | `DATE '2026-05-30'` (typed-literal, preferred) OR `CAST('2026-05-30' AS DATE)` | Trino's typed-literal `DATE '...'` is the most idiomatic. |
| `'2026-05-30 12:00:00'::TIMESTAMP` | `TIMESTAMP '2026-05-30 12:00:00'` (typed-literal) OR `CAST('...' AS TIMESTAMP)` | Same — prefer the typed-literal form. |
| `col::VARCHAR` | `CAST(col AS VARCHAR)` | For numeric → string in `\|\|` concatenation, see §7A.3.1 — Trino does NOT implicitly coerce numbers to strings inside `\|\|`. |
| `col::TEXT` | `CAST(col AS VARCHAR)` | Trino has no `TEXT` type; the analog is `VARCHAR`. |
| `'a1b2c3d4-...'::UUID` | `UUID 'a1b2c3d4-...'` (typed-literal) OR `CAST('a1b2c3d4-...' AS UUID)` | UUID typed-literal is concise and pushes down cleanly across the JDBC layer (verified for the Postgres connector — see resource 22 §3.2). |
| `col::DECIMAL(18,2)` | `CAST(col AS DECIMAL(18,2))` | No shortcut — precision and scale must be in the `AS` clause. |
| `col::JSON` | `CAST(col AS JSON)` | Trino has `JSON` type; `CAST` works. For JSON parsing from VARCHAR, also see `json_parse(varchar)`. |
| `col::INET` / `col::CIDR` / `col::HSTORE` | NO Trino equivalent. | These are Postgres-only types. Either use `system.query()` passthrough to Postgres (see resource 22 §3.4) or materialize as `VARCHAR` / structured `MAP` during ingestion. |

**Q-pattern matcher.** If you see ANY of these patterns in a code-review of Trino-targeted SQL, REJECT and rewrite:

| You see in the code | Rewrite |
|---|---|
| `something::type` (Postgres-style cast) | `CAST(something AS type)` (or `TRY_CAST(...)` if a NULL fallback is desired) |
| Any chained cast `a::type1::type2` | `CAST(CAST(a AS type1) AS type2)` — same precedence, ANSI form |
| A dbt model with `{{ var('start_date') }}::DATE` | `CAST({{ var('start_date') }} AS DATE)` or `DATE '{{ var("start_date") }}'` |
| A Postgres-style typed-null in a UNION/MERGE branch (`NULL::TIMESTAMP`) | `CAST(NULL AS TIMESTAMP)` (the most common typed-null trap — see §4.6 soft-delete pattern) |

**Two-engine note.** The `::` cast operator is **Postgres-specific** (and DuckDB-specific — DuckDB inherits the Postgres parser). It is **NOT** in Spark SQL either (Spark uses `CAST(... AS ...)` like Trino) and **NOT** in Snowflake's primary cast syntax (Snowflake supports `::` as an extension but its canonical form is also `CAST`). The bottom line for this stack: **only Postgres SQL itself accepts `::`. Trino SQL, Spark SQL, and dbt models targeting Trino MUST use `CAST(... AS ...)` or `TRY_CAST(... AS ...)`.**

The one place a `::` cast is legitimate in a Trino-stack codebase is **inside the query string passed to `system.query('...')` passthrough on the Postgres connector** — that string is forwarded verbatim to Postgres and runs in Postgres's parser, not Trino's. Outside passthrough, treat `::` as a banned token.

**Worked dbt example — typed NULL in a MERGE soft-delete (the iter435 failure case).** A common pattern in incremental MERGE models is to insert a typed `NULL` for a `deleted_at TIMESTAMP` column on the upsert branch. The Postgres-style `NULL::TIMESTAMP` is wrong:

```sql
-- WRONG — Postgres syntax; Trino parse error "mismatched input '::'"
SELECT
  id,
  email,
  updated_at,
  NULL::TIMESTAMP AS deleted_at   -- INVALID in Trino
FROM {{ ref('stg_users') }}
```

```sql
-- CORRECT — Trino-compatible
SELECT
  id,
  email,
  updated_at,
  CAST(NULL AS TIMESTAMP) AS deleted_at   -- works in Trino 467
FROM {{ ref('stg_users') }}
```

**Cross-references.**
- Resource 23 §"Trino 467 SQL-dialect anti-patterns" lists `::cast` syntax alongside `QUALIFY`, `DISTINCT ON`, `LIMIT N BY` as Trino-incompatible.
- Resource 13 §"Postgres → Trino translation table" lists `ts::DATE` → `CAST(ts AS DATE)`. Inside the Postgres-side ingestion examples in resource 13 (Spark JDBC `dbtable` subqueries, pg_attribute lookups, gen_random_uuid()), the `::` cast IS valid because that SQL runs in Postgres, not Trino.
- Resource 22 §3.2 (Postgres connector pushdown table) — the UUID typed-literal example `WHERE tenant_id = UUID 'a1b2c3d4-...'` is the Trino-compatible form for the equivalent Postgres `tenant_id = 'a1b2c3d4-...'::uuid` filter.

### 4.4E TRINO `try(expression)` CANONICAL — wrap an arbitrary expression and return NULL on error (the general-purpose error-suppressor; `TRY_CAST` is the cast-only sibling)

**Keyword anchors (for findability — keep all of these in this section verbatim):** Trino `try` function, wrap expression return null on error, `try` vs `try_cast`, catch divide by zero invalid cast Trino, `try` + `COALESCE` default value, error handling Trino expression, suppress error return null Trino, general-purpose error-wrapping Trino, "Trino has no try function" is FALSE.

**The one-sentence definition.** `try(expression)` evaluates `expression` and returns `NULL` if evaluation hits one of a **specific** set of runtime errors instead of failing the whole query. Verified at [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html) on 2026-06-06.

**Worked example — divide-by-zero suppression.**

```sql
-- Without try() — the query FAILS the moment any row has commission_rate = 0:
SELECT amount / commission_rate FROM orders;
-- ERROR: Division by zero

-- With try() — the offending row evaluates to NULL; the query SUCCEEDS:
SELECT try(amount / commission_rate) FROM orders;

-- For a DEFAULT value (e.g., 0) instead of NULL, wrap with COALESCE:
SELECT COALESCE(try(amount / commission_rate), 0) AS rate_per_dollar FROM orders;
```

**ERRORS `try()` CATCHES** (per the official Trino conditional-expressions doc):

1. **Division by zero.**
2. **Invalid cast or invalid function argument** (e.g., `CAST('abc' AS INTEGER)` buried inside a larger expression).
3. **Numeric value out of range** (e.g., overflow in `BIGINT` arithmetic).
4. **Invalid JSON literal.**
5. **JSON input or output conversion errors.**
6. **JSON path evaluation errors.**
7. **JSON value function result errors.**

**ERRORS `try()` does NOT catch** (load-bearing — do not promise blanket exception handling):
- User-raised errors via `fail('...')`.
- Query timeouts, memory-limit exceeded (OOM), worker crashes.
- Syntax errors, analysis-time errors, unresolved column names, permission denials.
- Connector / catalog errors at plan time (e.g., table not found).

**`try()` vs `try_cast(expr AS type)` — pick by scope.**

| Form | Scope | Use when |
|---|---|---|
| `try_cast(x AS type)` | **Cast only.** Returns `NULL` if the type conversion fails; throws on any other error. | You just need a soft-cast — bad input becomes `NULL`. |
| `try(<arbitrary expression>)` | **Any expression** — an arithmetic op, a function call, a `CAST` nested inside a bigger expression, a JSON path lookup, etc. | You need to wrap something **other** than a bare cast (e.g., `amount / denom`, `json_extract_scalar(payload, '$.user.id')`, `from_iso8601_timestamp(raw_ts)`). |

**For divide-by-zero specifically**, both `NULLIF(denom, 0)` and `try(numer / denom)` work — `NULLIF` is the older pattern, `try()` is the direct general tool. For an **invalid cast buried inside a larger expression** (e.g., `try(CAST(SUBSTR(raw_id, 5, 8) AS INTEGER) + 1)`), `try_cast` would only wrap the cast itself, while `try()` covers the whole sub-expression.

**DO-NOT-WRITE callout (load-bearing — copy this into your code-review checklist):**

> 1. **NEVER write "Trino has no general-purpose error-wrapping function" or "Trino has no `try()` function" or "to return NULL on error in Trino, use `NULLIF` / `CASE WHEN` only".** All three statements are **FALSE.** Trino HAS `try(expression)` — it is the general-purpose error-suppressor and lives in the `conditional` function family alongside `COALESCE` and `NULLIF`.
> 2. **NEVER reach only for `NULLIF` / `CASE WHEN` for "wrap an arbitrary expression and return NULL on error".** Those work for the specific divide-by-zero / specific-value-to-NULL cases, but the direct general tool is `try(expression)`. `try()` covers divide-by-zero AND invalid-cast AND numeric-overflow AND JSON errors in a single wrapper.
> 3. **NEVER assume `try()` catches `fail(...)`, OOM, timeouts, or syntax errors.** The catch list is exactly the 7 classes above (division by zero, invalid cast / invalid function argument, numeric out of range, plus 4 JSON error classes). For user-thrown `fail('...')`, the error propagates regardless of `try()`.
> 4. **NEVER assume `try()` and `try_cast()` are interchangeable.** `try_cast(x AS type)` is **cast-only**; `try(<expr>)` is **any expression**. If you need to wrap a non-cast computation (e.g., division, arithmetic overflow, JSON path lookup), `try()` is correct and `try_cast` will not compile against a non-cast expression.

**Cross-references.**
- §4.4A above — `TRY_CAST(expr AS type)` is documented in the cast forms table (line 959). `try()` is the **general-purpose** sibling for **non-cast** expressions; `try_cast` remains the right tool when the failure mode is specifically a bad cast.
- Resource 7 (`07-analytical-query-patterns.md`) §YoY-growth — uses `NULLIF(prev.usage_count, 0)` as the divide-by-zero guard inline. `try(...)` is an equivalent alternative when the numerator/denominator structure is more complex than a single ratio.
- Resource 23 §"SQL best practices" — when the expression that might fail is buried inside a larger computation (`SUM(try(amount / commission_rate))`), `try()` is the right wrapper because `NULLIF` only handles the equal-to-zero case at the leaf, while `try()` catches all 7 error classes including invalid casts inside the nested expression.

### 4.4C ORACLE `TRUNC` ↔ TRINO `truncate` GUARDRAIL — three distinct mappings, one lowercase 1-arg function, NO `TRUNC` keyword in Trino

**Why this section exists (iter476 cross-dialect-spillover fix).** Oracle's `TRUNC` is one function name overloaded across **three distinct semantics** (numeric truncation, integer truncation, date truncation). Trino splits these across **three different function names**, none of which is spelled `TRUNC`. The iter476 responder wrote `CAST(TRUNC(12.3456 * 100) / 100 AS DECIMAL(10,2))` in a Trino rewrite — that produces `Function 'trunc' not registered` at runtime. This subsection installs the authoritative mapping + DO-NOT-WRITE.

**The canonical mapping — memorize this 3-row table.** Verified against [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) and [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) on 2026-06-05.

| Oracle source | What Oracle does | Trino canonical form | Notes |
|---|---|---|---|
| `TRUNC(n, d)` where `n` is numeric, `d` is decimal places | Truncates `n` to `d` decimal places (drops digits beyond position `d`, toward zero) | `truncate(n * power(10, d)) / power(10, d)` — **lowercase, 1-arg `truncate`**. Literal form for 2 dp: `truncate(n * 100) / 100`. | Trino's `truncate` is **1-arg only**; the 2-arg `truncate(n, d)` form **does NOT exist** in Trino 467. |
| `TRUNC(n)` 1-arg numeric (integer truncation toward zero) | Drops the fractional portion, returning integer-valued number | `truncate(n)` — lowercase, 1-arg. Return type is `same as input` (per Trino math-functions docs). | `TRUNC(-3.7)` Oracle = `-3`; Trino `truncate(-3.7)` = `-3.0`. Both truncate toward zero. |
| `TRUNC(d, 'fmt')` where `d` is a date and `'fmt'` is `'MM'` / `'YY'` / `'DD'` etc. | Truncates `d` to the start of the named unit (month, year, day, ...) | `date_trunc('month', d)` / `date_trunc('year', d)` / `date_trunc('day', d)` — **different function name** (`date_trunc`, not `truncate`). | The `fmt` codes: Oracle `'MM'` / `'MON'` → Trino `'month'`; Oracle `'YY'` / `'YEAR'` → Trino `'year'`; Oracle `'DD'` → Trino `'day'`; Oracle `'IW'` → Trino `'week'`. |

**Canonical worked example — Oracle numeric `TRUNC(n, d)` to Trino, the three forms an engineer reaches for:**

```sql
-- Oracle source:
SELECT TRUNC(price * 1.0875, 2) AS price_with_tax FROM orders;
-- TRUNC truncates to 2 decimal places (drops anything beyond the hundredths).

-- Trino — CANONICAL form (exact truncate semantics, lowercase 1-arg truncate):
SELECT truncate(price * 1.0875 * 100) / 100 AS price_with_tax FROM orders;
-- Or the general form for arbitrary d decimal places:
SELECT truncate(price * 1.0875 * power(10, 2)) / power(10, 2) AS price_with_tax FROM orders;

-- Trino — SIMPLER form IF HALF_UP rounding is acceptable (NOT the same as truncation):
SELECT round(price * 1.0875, 2) AS price_with_tax FROM orders;
-- round() is HALF_UP rounding semantics. For most billing/accounting, truncation
-- is the legally specified behavior — verify with the downstream consumer before
-- substituting round() for truncate(x*100)/100.
```

**DO-NOT-WRITE callout (load-bearing — copy this into your code-review checklist):**

> **Never write any of the following in Trino SQL or in any dbt model targeting Trino:**
>
> 1. **`TRUNC(...)` used as a function name in a Trino rewrite** — `TRUNC` (uppercase or any case) is the **Oracle** name. Trino's math function is **lowercase `truncate(x)`** only. Writing `TRUNC(12.34, 2)` in Trino produces `Function 'trunc' not registered` (`trunc` is not in Trino's function registry — only `truncate` is, and only the 1-arg form). The lowercase form `trunc(...)` also fails for the same reason — the function is spelled `truncate`, not `trunc`. **Error-message attribution (precise):** the exact text `Function 'trunc' not registered` is produced by the **name miss** (`TRUNC` / `trunc` not being a registered function name at all) — it is NOT the error produced by passing 2 args to lowercase `truncate(...)`. See entry 2 immediately below for the different error wording that the 2-arg form produces.
>
> 2. **`truncate(n, d)` — the 2-arg numeric truncation form** — **does NOT exist on Trino.** Trino's `truncate` is **1-arg ONLY**, returning the integer part toward zero. Writing `truncate(12.3456, 2)` produces a **wrong-arity / function-resolution** error of the form `Unexpected parameters (decimal(6,4), integer) for function truncate. Expected: truncate(<numeric type>)` — note this is a DIFFERENT error wording from entry 1's `Function 'trunc' not registered`: the function name `truncate` IS registered (so the name-lookup succeeds), but no overload accepts 2 args (so arity resolution fails). The two errors share the same outcome (the query fails) but the error text is different — `not registered` is the name-miss text, `Unexpected parameters` (with the expected signature listed) is the wrong-arity text. To truncate to `d` decimals, use `truncate(n * power(10, d)) / power(10, d)`, or the literal `truncate(n * 100) / 100` for 2 dp. Verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) — the documented signature is `truncate(x) → [same as input]`; no 2-arg overload is documented.
>
> 3. **`TRUNCATE(...)` used as a math function** — Trino has `truncate(x)` (lowercase math function, 1-arg). **Uppercase `TRUNCATE` collides with the `TRUNCATE TABLE` DDL statement in other dialects** — but `TRUNCATE TABLE` is **also NOT a Trino-side statement for Iceberg tables** (see §4.6 row "TRUNCATE TABLE t" — Trino uses `DELETE FROM t WHERE TRUE` or `materialized='table'` instead). Never write `TRUNCATE(x)` thinking it's the math function; it isn't. Write lowercase `truncate(x)`.
>
> 4. **`TRUNC(dt)` / `TRUNC(dt, 'MM')` used in a Trino rewrite** — these are Oracle date forms. The Trino equivalent is a **different function**: `date_trunc('day', dt)` / `date_trunc('month', dt)`. Never write `TRUNC(dt)` or `truncate(dt)` for date truncation in Trino — `truncate` is a math function and does not accept a date argument; calling it on a `date` or `timestamp` produces a function-resolution error.
>
> 5. **`round(n, d)` substituted for `TRUNC(n, d)` without verifying rounding-vs-truncation is acceptable** — `round` is HALF_UP rounding, `truncate` drops digits toward zero. They differ at the halfway mark (`round(1.235, 2)` = `1.24`; `truncate(1.235 * 100) / 100` = `1.23`) and for negative numbers (`round(-1.235, 2)` = `-1.24`; `truncate(-1.235 * 100) / 100` = `-1.23`). For billing, accounting, and tax computations, truncation may be the legally specified behavior — do not silently swap.

**Keyword-trap phrase (memorize):** *"Anyone who writes `TRUNC(x, 2)` for Trino is using Oracle syntax — Trino has lowercase `truncate(x)` 1-arg only; to truncate to 2 decimals use `truncate(x*100)/100` or (if HALF_UP is OK) `round(x, 2)`."*

**Cross-reference.** The date-side mapping `TRUNC(dt) → date_trunc('day', dt)` is also documented in the §4.2 Date/time functions table (row 596). The §4.4B cross-dialect-spillover table includes a consolidated row for `TRUNC` (see immediately below). The two-arg-truncate non-existence in Trino is a specific instance of the broader cross-dialect-spillover fab class — Oracle's overloaded `TRUNC` keyword being silently transcribed into Trino syntax without translation.

### 4.4B CROSS-DIALECT-SPILLOVER GUARDRAIL — syntax that looks valid but is NOT Trino 467

**Why this section exists (consolidated meta-canonical).** Across iter402–iter456 the most-repeated failure mode in Trino-context answers has been **cross-dialect syntax spillover** — recommending Oracle / PostgreSQL / Snowflake / Spark / native-Iceberg syntax as if it were Trino's. The forms look idiomatic (because they ARE idiomatic in those other engines) but they either parse-error or, worse, **silently no-op** in Trino 467. This table consolidates every recurring spillover so a single grep on this section catches all of them.

> **The cross-dialect-spillover table — when you see any of these in Trino-context SQL, fix it.**
>
> | Concept | Forbidden form (other dialect) | Where it comes from | What it does in Trino 467 | Trino-correct form (verified) |
> |---|---|---|---|---|
> | Cast operator | `expr::type` | PostgreSQL, Snowflake, DuckDB | Parse error: `mismatched input '::'` (open FR [#23795](https://github.com/trinodb/trino/issues/23795), not implemented in 467/481) | `CAST(expr AS type)` (or `TRY_CAST(...)` for NULL-on-failure) |
> | Query hint (any) | `SELECT /*+ ANY_HINT(...) */ ...` | Oracle, Spark, Hive | **SILENTLY IGNORED** — treated as a block comment (open FR [#9498](https://github.com/trinodb/trino/issues/9498), not implemented). Failure mode is silent-wrong, not an error. | `SET SESSION <property> = <value>;` BEFORE the query (e.g., `SET SESSION join_distribution_type = 'PARTITIONED';`) |
> | Top-N-per-group / dedup | `QUALIFY ROW_NUMBER() OVER (...) = 1` | Snowflake, BigQuery, Databricks, Teradata | Parse error | `ROW_NUMBER()` subquery + outer `WHERE rn = 1` (see [resource 23](23-sql-best-practices-olap.md)) |
> | Stats DDL | `ANALYZE TABLE schema.table` | Spark, Hive, MySQL | Parse error | `ANALYZE schema.table` — bare, no `TABLE` keyword |
> | Date → string | `TO_CHAR(dt, 'YYYY-MM-DD')` | Oracle | `Function 'to_char' not registered` | `date_format(dt, '%Y-%m-%d')` (MySQL) or `format_datetime(dt, 'yyyy-MM-dd')` (Joda) |
> | String → date | `STR_TO_DATE('2026-05-30', '%Y-%m-%d')` | MySQL | `Function 'str_to_date' not registered` | `CAST(date_parse('2026-05-30', '%Y-%m-%d') AS DATE)` (MySQL specifiers; `date_parse` returns timestamp(3), wrap in CAST AS DATE) or `from_iso8601_date('2026-05-30')` (ISO 8601 only, returns DATE directly) |
> | String → date | `parse_date('2026-05-30', 'yyyy-MM-dd')` | Snowflake / BigQuery | `Function 'parse_date' not registered` — **NOT a Trino function** | Same Trino-correct triple as the row above: `CAST(date_parse(s, '%Y-%m-%d') AS DATE)`, OR `from_iso8601_date(s)` for ISO 8601, OR `CAST(parse_datetime(s, 'yyyy-MM-dd') AS DATE)` for Joda specifiers (returns `timestamp with time zone` — CAST drops TZ to land on DATE). **Verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): the documented date/timestamp parsing functions are `date_parse`, `parse_datetime`, and `from_iso8601_date` — there is NO `parse_date`.** |
> | String → date | `to_date('2026-05-30', 'YYYY-MM-DD')` (Oracle lowercase) or `TO_DATE(...)` | Oracle / Snowflake | `Function 'to_date' not registered` — **NOT a Trino function** | Same Trino-correct triple as above. `to_date` exists in Oracle, Snowflake, Spark SQL — NOT in Trino 467. |
> | MySQL-vs-Joda format specifier confusion | `date_parse('2026-05-30', 'yyyy-MM-dd')` (Joda spec in MySQL function) or `parse_datetime('2026-05-30', '%Y-%m-%d')` (MySQL spec in Joda function) | Cross-dialect muscle memory | Silently returns NULL or wrong date (no parse error — the function accepts the format string verbatim, but the specifier characters do not match) | **Pin the distinction:** `date_parse` ALWAYS uses MySQL specifiers (`%Y` `%m` `%d` `%H` `%i` `%s`); `parse_datetime` ALWAYS uses Joda (`yyyy` `MM` `dd` `HH` `mm` `ss`). Mnemonic: percent-sign → MySQL → `date_parse`; no percent sign → Joda → `parse_datetime`. |
> | Conditional null | `NVL(a, b)` | Oracle | Parse / resolution error | `COALESCE(a, b)` |
> | Conditional zero | `NVL2(a, b, c)` | Oracle | `Function 'nvl2' not registered` | `CASE WHEN a IS NOT NULL THEN b ELSE c END` |
> | Decode-with-NULL semantics | `DECODE(col, NULL, 'x', ...)` | Oracle | Parse / resolution error | Searched `CASE WHEN col IS NULL THEN 'x' WHEN col = ... END` (see §4.1A) |
> | Row limit | `WHERE ROWNUM <= 100` | Oracle 11g | Parse error (no `ROWNUM` pseudocolumn) | `LIMIT 100` (with `ORDER BY` for determinism) |
> | Iceberg table property: compression | `WITH (..., "write.parquet.compression-codec" = 'zstd')` | native Iceberg property key | Parse error — that key is the native Iceberg name, not a Trino WITH property | `WITH (..., compression_codec = 'ZSTD')` — flat name=value, Trino name |
> | Iceberg WITH-clause shape | `WITH (..., properties = map('k','v'))` | native Iceberg / Spark API style | Parse / property error | `WITH (key1 = 'v1', key2 = 'v2')` — flat name=value pairs |
> | Spark TBLPROPERTIES | `ALTER TABLE t SET TBLPROPERTIES ('k' = 'v')` | Spark SQL | Parse error | `ALTER TABLE t SET PROPERTIES key = 'v'` — bare identifier LHS, string-literal RHS |
> | Iceberg snapshot timestamp | `WHERE timestamp_ms = ...` on `$snapshots` | Iceberg Java API field name | Column does not exist | `WHERE committed_at = TIMESTAMP '...'` — the Trino metadata-table column |
> | NULLS-default ordering in `ORDER BY ... DESC` | Assuming `ORDER BY ts DESC` puts NULLs at the top (Oracle's default) | Oracle's documented default | **SILENT-WRONG row ordering** — Trino puts NULLs at the BOTTOM on `DESC` (default `NULLS LAST` regardless of direction); no error, just different row order than Oracle | Always write `ORDER BY ts DESC NULLS FIRST` (preserve Oracle behavior) or `ORDER BY ts DESC NULLS LAST` (explicit Trino default). See **§ LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY** at the top of this resource. |
> | Numeric truncation 2-arg | `TRUNC(n, d)` (also `TRUNC(n)`) | Oracle | `Function 'trunc' not registered` — `TRUNC` (uppercase Oracle name) does NOT exist in Trino's function registry; the lowercase math function is `truncate(x)` and is **1-arg only** (no 2-arg `truncate(x, d)` overload) | `truncate(n * power(10, d)) / power(10, d)` (exact truncation to `d` decimals) OR `round(n, d)` (if HALF_UP rounding is acceptable, NOT the same as truncation). See §4.4C for the full 3-row mapping + DO-NOT-WRITE matrix. |
> | Date truncation function name | `TRUNC(dt, 'MM')` / `TRUNC(dt)` | Oracle | `Function 'trunc' not registered` — Trino has no `TRUNC` keyword; the date-truncation function is **`date_trunc('month', dt)`** (different function name) | `date_trunc('month', dt)` / `date_trunc('day', dt)` / `date_trunc('year', dt)` / etc. **DIFFERENT function from the math `truncate(x)`** — `date_trunc` for dates/timestamps, `truncate` for numbers. Never mix the two. |
> | MERGE star shorthand | `WHEN MATCHED THEN UPDATE SET *` / `WHEN NOT MATCHED THEN INSERT *` | Spark / Delta Lake / Databricks (also Snowflake's `UPDATE * WHEN NOT MATCHED THEN INSERT *`) | Parse error: `mismatched input '*'` — Trino MERGE grammar requires **explicit column lists** on both UPDATE SET and INSERT VALUES. There is no `*` shorthand on either branch in Trino 467. | `WHEN MATCHED THEN UPDATE SET col1 = s.col1, col2 = s.col2, ...` and `WHEN NOT MATCHED THEN INSERT (col1, col2, ...) VALUES (s.col1, s.col2, ...)`. See §4.6B for the full MERGE-star-shorthand guardrail. Verified at [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html). |
>
> **Meta-rule (memorize)**: when unsure, **prefer ANSI / standard SQL forms (`CAST(... AS ...)`, `COALESCE`, `CASE WHEN`) and SESSION properties (`SET SESSION ...`)**; do **not** paste PostgreSQL / Oracle / Snowflake / Spark / native-Iceberg idioms into Trino. If the form parses-and-runs without error but the optimizer behavior didn't change, suspect a silent-no-op hint or wrong session property — Trino has no hint mechanism, so the answer is always a SESSION property.
>
> **Cross-reference chain.**
> - Resource 23 anti-patterns table — extends this with QUALIFY, DISTINCT ON, LIMIT N BY, TOP N, EXTRACT(EPOCH FROM ...), TIMESTAMPDIFF, STRING_AGG, RETURNING.
> - Resource 24 § LEADING CANONICAL — How do I influence Trino's join distribution — the canonical replacement for any `/*+ hint */` form.
> - Resource 11 § Trino dialect ↔ native-Iceberg name translation — the canonical replacement for any `write.*-codec` / `TBLPROPERTIES` / `properties = map(...)` form.
> - Resource 17 § LEADING CANONICAL — `$snapshots` column list — the canonical column names (`committed_at`, NOT `timestamp_ms`).
> - **§ LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY (top of this resource) — the canonical Oracle-to-Trino NULLS-default migration pattern.**

### 4.4D LEADING CANONICAL — `greatest(v1, ..., vN)` / `least(v1, ..., vN)` row-wise max/min across columns + NULL-propagation differs from PostgreSQL/Oracle

**Keyword anchors:** greatest least Trino, max of several columns, highest value across columns in a row, row-wise max vs MAX aggregate, greatest null behavior Trino, least null behavior Trino, max across columns Trino, greatest ignores nulls.

**The rule (verified at [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html)).** `greatest(v1, v2, ..., vN)` returns the LARGEST and `least(v1, v2, ..., vN)` returns the SMALLEST of the listed VALUES/COLUMNS — **ROW-WISE** (across columns in one row), **NOT** an aggregate. Contrast: `max(col)` / `min(col)` are AGGREGATES down rows (one value per group); `greatest` / `least` are scalar across columns in the same row. Args must be mutually comparable / coercible to a common type (supported: DOUBLE, BIGINT, VARCHAR, TIMESTAMP, TIMESTAMP WITH TIME ZONE, DATE).

**LOAD-BEARING NULL behavior — Trino DIFFERS from PostgreSQL and Oracle.** Trino's `greatest` / `least` return **NULL if ANY argument is NULL**. Per trino.io: *"Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."* Oracle's `GREATEST` / `LEAST` also return NULL if any arg is NULL (Oracle matches Trino here, but engineers coming from Postgres muscle memory get bitten). To ignore NULLs in Trino, `COALESCE` each arg first:

```sql
-- Row-wise max across three currency price columns, NULL-safe.
SELECT greatest(coalesce(price_usd, 0), coalesce(price_eur, 0), coalesce(price_gbp, 0)) AS highest_price FROM products;

-- Plain form (returns NULL if ANY of the three columns is NULL — usually NOT what you want).
SELECT greatest(price_usd, price_eur, price_gbp) AS highest_price FROM products;
```

**DO-NOT-WRITE:**
1. **Using `MAX(col)` to get the row-wise max across columns.** `MAX(col)` is an aggregate down rows (one value per group); for row-wise max across columns in the SAME row use `greatest(c1, c2, c3)`. Writing `SELECT MAX(price_usd, price_eur, price_gbp)` is a parse error — `MAX` is unary.
2. **Assuming `greatest()` / `least()` skip NULLs.** Trino returns NULL if any arg is NULL (matches Oracle; differs from PostgreSQL). Always `COALESCE` each arg if you want to ignore NULLs.

### 4.5 Query-shape and pseudo-column constructs

| Oracle | Trino | Notes |
|---|---|---|
| `SELECT my_seq.NEXTVAL FROM DUAL` | NO equivalent — sequences don't exist in Trino. **PRIMARY (canonical):** `{{ dbt_utils.generate_surrogate_key(['col1', 'col2']) }}` (hash-based, idempotent, VARCHAR output). **Hand-rolled fallback (only if you cannot use dbt_utils):** `to_hex(md5(to_utf8(concat(CAST(col1 AS VARCHAR), '\|\|', CAST(col2 AS VARCHAR)))))`. **DO NOT write `md5(concat_ws(...))` directly** — not because `concat_ws` is missing (Trino 467 DOES have `concat_ws(separator, string1, ..., stringN) -> varchar` per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html)) but because **`md5(varbinary) -> varbinary`** per [trino.io/docs/current/functions/binary.html](https://trino.io/docs/current/functions/binary.html) — md5 requires varbinary input, so the outer wrap must be `to_hex(md5(to_utf8(concat_ws('\|', col1, col2))))` if you want to use `concat_ws`. **And do NOT write bare `md5(<varchar>)`** — same varbinary-vs-varchar type mismatch. | Hash-based is the dbt convention. Prefer `generate_surrogate_key`. See §4.5A for the canonical block. |
| `SELECT 1 FROM DUAL` | `SELECT 1` (no FROM needed) OR `SELECT 1 FROM (VALUES (1)) AS t(x)`. | Trino doesn't need a one-row dummy table. |
| `WHERE ROWNUM <= 10` | `LIMIT 10` (after ORDER BY) OR `WHERE rn <= 10` after a `row_number() OVER (ORDER BY ...)` subquery. | `LIMIT` without `ORDER BY` is nondeterministic — usually combine. |
| `WHERE ROWNUM = 1` (first row) | `LIMIT 1` (after ORDER BY) | Same idea. |
| `ROWNUM` as a column reference | `row_number() OVER (ORDER BY ...)` in a subquery, then reference in outer. | Trino has no implicit row pseudocolumn. |
| `CONNECT BY PRIOR parent_id = id START WITH id = 1` | `WITH RECURSIVE t(...) AS (base_query UNION ALL recursive_step) SELECT * FROM t` | See myths box for the depth caveat. |
| `SELECT ... FROM a, b WHERE a.id = b.id(+)` (Oracle outer-join) | `SELECT ... FROM a LEFT JOIN b ON a.id = b.id` | ANSI JOIN syntax; Oracle `(+)` is parse error in Trino. |
| `MINUS` (set difference) | `EXCEPT` (or `EXCEPT ALL` for multiset semantics) | Trino uses the ANSI standard name. **Physical plan: ANTI-JOIN semantics** — `EXCEPT` returns rows in LEFT not in RIGHT, equivalent to `WHERE NOT EXISTS (SELECT 1 FROM right WHERE right.k = left.k)`. NULL-safe (unlike `NOT IN`). `EXCEPT` dedups by default (set semantics); `EXCEPT ALL` keeps multiset. Trino plans `INTERSECT`/`EXCEPT` via `SemiJoin`-style operators per [trinodb/trino PR #5981](https://github.com/trinodb/trino/pull/5981) — seeing a `SemiJoin` node in `EXPLAIN` of an `EXCEPT` is EXPECTED. |
| `INTERSECT` | `INTERSECT` (or `INTERSECT ALL` for multiset semantics) | Identical syntax. **Physical plan: SEMI-JOIN semantics — NOT anti-join.** `INTERSECT` returns rows present in BOTH inputs, equivalent to `WHERE EXISTS (SELECT 1 FROM right WHERE right.k = left.k)` or `WHERE col IN (SELECT col FROM right)`. `INTERSECT` dedups by default; `INTERSECT ALL` keeps multiset. **DO-NOT-WRITE: "`INTERSECT` is implemented as an anti-join"** — that is the inverse of what it does. Anti-join is `EXCEPT` / `NOT EXISTS` / `NOT IN` (LEFT minus RIGHT). Trino plans `INTERSECT` via a `SemiJoin`-style operator (PR #5981) — an `EXPLAIN` of `a INTERSECT b` showing a `SemiJoin` node is CORRECT, not a bug. See [resource 23 §10 jargon gloss](23-sql-best-practices-olap.md) for the semi-join vs anti-join distinction. |
| `UNION` / `UNION ALL` | `UNION` / `UNION ALL` | Identical syntax. **Semantics differ:** `UNION` dedups (sort or hash to remove duplicates — extra CPU + shuffle); `UNION ALL` keeps all rows including duplicates (cheaper — no dedup step). **Prefer `UNION ALL` when inputs are known-disjoint or duplicates are acceptable** (e.g., partition-pruned recent + archive split, per-tenant shard union). Use plain `UNION` only when you actually need deduplication and the result set is small enough that the dedup cost is bearable. |
| `WHERE col IN (subquery)` | Same; Trino's optimizer converts to a SemiJoin. | See [resource 22 §13.6](22-trino-federation-postgresql.md). |
| `WHERE EXISTS (correlated subquery)` | Same; Trino tries to decorrelate to a SemiJoin. If decorrelation fails, you get a `CorrelatedJoin` operator in EXPLAIN — expensive. See [resource 28](28-complex-sql-performance-trino-dbt.md) for rewrites. | Decorrelation is the optimizer's job, not always automatic. |

> **EXPLAIN-rendering sub-note (iter513 — applies to any SemiJoin node in EXPLAIN, whether from `INTERSECT`, `EXCEPT`, `IN`, `EXISTS`, `NOT IN`, or `NOT EXISTS`):** Trino renders a semi-join as `SemiJoin[<joinkey> = <joinkey>]` producing a boolean output symbol (typically named `semijoinoutput:boolean`). Anti-semantics (`EXCEPT` / `NOT EXISTS` / `NOT IN`) appear as a **downstream `Filter[NOT semijoinoutput]`** node that keeps the rows where the boolean is FALSE — NOT as a flag on the SemiJoin node itself. **DO-NOT-WRITE: `SemiJoin[..., FilterMode = ANTI]`** — there is no `FilterMode = ANTI` token in Trino EXPLAIN output; that string is a fabrication. Look for the `Filter[NOT semijoinoutput]` downstream of the SemiJoin to identify anti-semantics. See [resource 23 §10 jargon gloss](23-sql-best-practices-olap.md) for the full plan-text walkthrough.

### 4.5A ICEBERG-IDENTITY-COLUMN-NEGATION GUARDRAIL — Iceberg has NO user-facing identity / auto-increment columns; use `dbt_utils.generate_surrogate_key` instead

> **Findability anchor (read first if your question contains any of these keywords):** "NEXTVAL", "sequence", "Trino sequence", "Trino CREATE SEQUENCE", "Iceberg identity column", "Iceberg auto-increment", "surrogate key", "surrogate key Trino", "surrogate key Iceberg", "hash surrogate key", "md5 surrogate key", "generate_surrogate_key", "dbt surrogate key", "md5 concat varchar Trino", "concat_ws Trino", "md5 of varchar Trino". **PRIMARY canonical replacement: `{{ dbt_utils.generate_surrogate_key(['col1', 'col2']) }}`** (idempotent, VARCHAR MD5 hex output, stable across runs and clusters). **DO NOT write bare `md5(<varchar>)` or naked `md5(concat_ws(...))`** — Trino's `md5(varbinary) -> varbinary` per [trino.io/docs/current/functions/binary.html](https://trino.io/docs/current/functions/binary.html); the type mismatch is the bug, NOT the inner function. **`concat_ws` itself DOES exist in Trino 467** as `concat_ws(separator, string1, ..., stringN) -> varchar` per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html) — see §4.3 string-family canonical for the full signature. Hand-rolled fallback that compiles: `to_hex(md5(to_utf8(concat_ws('||', CAST(a AS VARCHAR), CAST(b AS VARCHAR)))))` OR `to_hex(md5(to_utf8(concat(CAST(a AS VARCHAR), '||', CAST(b AS VARCHAR)))))`. See the DO-NOT-WRITE table below for the full ban.

**Why this section exists (iter437 fabrication fix).** An engineer migrating an Oracle table with `id NUMBER GENERATED ALWAYS AS IDENTITY` (or `id NUMBER DEFAULT my_seq.NEXTVAL`) to Iceberg via Spark will reflexively ask: "what's the equivalent Iceberg DDL for an identity column?" The reflexive — and WRONG — answer is "Iceberg V2 supports identity-style auto-increment columns, just generate them via Spark DDL". **That claim is FABRICATED.** This subsection installs the authoritative negation.

**The canonical truth (memorize this paragraph):**

> **Iceberg does NOT have user-facing identity columns or auto-increment columns.** The "sequence number" that appears in the Iceberg V2 spec is an **INTERNAL metadata mechanism** (a monotonically-increasing integer assigned per snapshot and per data/delete file, used to **scope delete files** to the data files they apply to and to **order concurrent writes**). It is **NOT** a row-level auto-increment column, is **NOT** queryable as a regular column, and is **NOT** exposed in any user-facing DDL. **Delta Lake DOES have user-facing identity columns** (`GENERATED ALWAYS AS IDENTITY`, since Delta 2.x). **Iceberg does NOT.** Identity-column support in Iceberg was tracked as feature request **[apache/iceberg #12297](https://github.com/apache/iceberg/issues/12297)** ("Support for Identity Columns in Apache Iceberg"), which was **CLOSED AS NOT PLANNED** (Aug 2025). The feature is **NOT implemented in Iceberg 1.5.2 (the production version on this stack), NOT in the V2 spec, NOT in the V3 spec, and NOT on the project's roadmap.** Plan permanently for the dbt-utils hash-key path; do not wait for an Iceberg identity-column feature that has been declined.

Verified against [iceberg.apache.org/spec](https://iceberg.apache.org/spec/) — the V2 sequence-number fields (`sequence_number`, `file_sequence_number`) are metadata-table fields used by the snapshot/manifest layer for delete-file scoping, NOT row-level column DDL. Verified against [apache/iceberg #12297](https://github.com/apache/iceberg/issues/12297) — the issue was **closed as not planned in August 2025**; identity columns are NOT in V2 or V3 spec and are NOT being added.

**DO-NOT-WRITE callout (load-bearing — copy this into your code-review checklist):**

> **Never write, suggest, or imply any of the following in resources, code reviews, or migration guides targeting this stack:**
> - **"Iceberg has identity columns"** — FALSE. Iceberg has NO user-facing identity columns.
> - **"Iceberg has auto-increment columns"** — FALSE. Iceberg has NO user-facing auto-increment columns.
> - **"Iceberg V2 supports identity-style auto-increment columns"** — FABRICATED. The V2 spec's "sequence number" is INTERNAL metadata for delete-file scoping, NOT a user-facing column.
> - **"Iceberg V2 sequence numbers are user-facing surrogate keys"** — FABRICATED. They are not exposed as row-level columns at all.
> - **"Use an Iceberg identity column instead of a sequence"** — FABRICATED advice. There is no such feature to use.
> - **"`CREATE TABLE ... (id BIGINT GENERATED ALWAYS AS IDENTITY, ...)` works on an Iceberg table via Spark DDL"** — FALSE. The Spark parser/analyzer rejects this against an Iceberg catalog; it is a Delta-Lake-only DDL form.
> - Any other phrasing that ascribes user-facing identity-column / auto-increment / `GENERATED ALWAYS AS IDENTITY` semantics to Iceberg.

**The canonical Oracle `seq.NEXTVAL` replacement on THIS stack (Iceberg 1.5.2 + Trino 467 + dbt-trino):**

| Priority | Replacement | Output type | Stability across runs | When to use |
|---|---|---|---|---|
| **PRIMARY** | `{{ dbt_utils.generate_surrogate_key([col_list]) }}` | **VARCHAR** (MD5 hex string, ~32 chars) | **Idempotent across runs AND clusters** — same input cols always produce same key | Default for surrogate keys on dimensions / facts. The dbt-trino canonical pattern. Keys are strings not numbers; joins/filters still work. |
| **FALLBACK** | `ROW_NUMBER() OVER (ORDER BY <stable_ordering>)` | **BIGINT** | **Only stable within a single full-refresh run.** A second `dbt run --full-refresh` typically produces a different surrogate-key → business-key mapping because the source row order may shift. | Use ONLY for ephemeral / single-run scratch keys. **DO NOT use** for stable cross-run keys that downstream models or external systems reference. |
| **BANNED** | Iceberg identity column / `GENERATED ALWAYS AS IDENTITY` | N/A | N/A | **Does not exist.** Writing this DDL against an Iceberg catalog via Spark fails at parse/analyze time. |
| **BANNED** | Trino `CREATE SEQUENCE my_seq` / `my_seq.NEXTVAL` | N/A | N/A | **Does not exist in Trino.** `CREATE SEQUENCE` fails the Trino parser; there is no sequence DDL in Trino 467 or any released version. |

**Worked replacement example.** Migrating `customers.customer_id NUMBER GENERATED ALWAYS AS IDENTITY` from Oracle to Iceberg via dbt:

```sql
-- WRONG (Oracle DDL ported as-is) — Spark+Iceberg rejects this; Iceberg has no identity columns:
-- CREATE TABLE iceberg.dw.customers (
--   customer_id BIGINT GENERATED ALWAYS AS IDENTITY,
--   email VARCHAR,
--   ...
-- );

-- WRONG (Trino sequence DDL) — Trino has no sequences; parser error:
-- CREATE SEQUENCE iceberg.dw.customer_id_seq START WITH 1;
-- INSERT INTO iceberg.dw.customers VALUES (customer_id_seq.NEXTVAL, ...);

-- CORRECT — dbt model materializes the customers dimension with a hash-based surrogate key:
-- models/dw/dim_customers.sql
{{ config(materialized='table') }}

SELECT
  {{ dbt_utils.generate_surrogate_key(['email', 'signup_source']) }} AS customer_id,  -- VARCHAR MD5
  email,
  signup_source,
  created_at
FROM {{ ref('stg_customers') }}
```

The `customer_id` here is a 32-character MD5 hex VARCHAR (e.g., `'7d3f...e2a1'`). It is **idempotent** — re-running `dbt run` produces the same `customer_id` for the same `(email, signup_source)` natural key — and **stable across clusters**, so downstream joins, foreign-key references, and external system lookups work consistently.

#### LEADING CANONICAL — surrogate-key + incremental together (the framing iter489 Q4 surfaced)

> **READ THIS BLOCK FIRST when an engineer asks for a dbt model that migrates an Oracle "sequence-keyed nightly MERGE" — i.e., the migration combines (a) `seq.NEXTVAL` → `dbt_utils.generate_surrogate_key` AND (b) Oracle nightly MERGE → dbt `materialized='incremental'`.** The two pieces have to work together correctly: the surrogate key is computed in the SELECT; the incremental delta filter is computed in the `WHERE` clause under a `{% if is_incremental() %}` guard. **The guard is `is_incremental()` — never `{% if execute %}`** (see DO-NOT-WRITE row below).

```sql
-- models/dw/fct_orders.sql
-- Oracle source pattern this replaces:
--   MERGE INTO dw.fct_orders t
--   USING (SELECT order_seq.NEXTVAL AS order_pk, ... FROM stg_orders WHERE load_date > <last_run>) s
--   ON (t.order_pk = s.order_pk)
--   WHEN MATCHED THEN UPDATE SET ...
--   WHEN NOT MATCHED THEN INSERT ...;
--
-- dbt-trino translation: incremental MERGE + hash-based surrogate key.
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='order_pk',
    on_schema_change='append_new_columns',
    properties={
      'format': "'PARQUET'",
      'partitioning': "ARRAY['order_date']",
      'sorted_by': "ARRAY['tenant_id']",
      'format_version': 2
    }
) }}

SELECT
  -- Surrogate key — computed in SELECT, NOT from a sequence.
  -- Idempotent across runs/clusters: same (tenant_id, natural_order_id) -> same MD5 -> same order_pk.
  {{ dbt_utils.generate_surrogate_key(['tenant_id', 'natural_order_id']) }} AS order_pk,
  tenant_id,
  natural_order_id,
  order_date,
  status,
  total_amount,
  updated_at
FROM {{ ref('stg_orders') }}

{% if is_incremental() %}
  -- Delta filter — applied ONLY on incremental runs (not first build, not --full-refresh).
  -- The watermark MAX(...) MUST be wrapped in a SELECT subquery; Trino rejects bare aggregates in WHERE.
  WHERE updated_at >= (
    SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01 00:00:00 UTC')
    FROM {{ this }}
  )
{% endif %}
```

**Why this shape (every line is load-bearing):**

1. **`{{ dbt_utils.generate_surrogate_key(['tenant_id', 'natural_order_id']) }}`** is the surrogate-key replacement for Oracle's `order_seq.NEXTVAL`. It's a MACRO that emits `md5(cast(coalesce(cast(tenant_id as varchar), '_dbt_utils_surrogate_key_null_') || '-' || coalesce(cast(natural_order_id as varchar), '_dbt_utils_surrogate_key_null_') as varchar))` in the compiled SQL. Same natural keys -> same MD5 hash -> same `order_pk`, every run, every cluster.

2. **`unique_key='order_pk'`** tells dbt-trino which column to MERGE on. Because `order_pk` is deterministic from the natural keys, the same source row always lands on the same target row — UPSERT semantics work cleanly.

3. **`{% if is_incremental() %}`** is the CANONICAL incremental-run guard. It returns `True` ONLY when **all three** conditions hold:
   - The target table already exists in the database, AND
   - The current run is NOT `--full-refresh`, AND
   - The model is configured with `materialized='incremental'`.

   On the very first build (no table yet) AND on every `--full-refresh` run, `is_incremental()` returns `False`, the WHERE clause is skipped, and dbt does a full CTAS. On every subsequent normal run, it returns `True`, the watermark filter applies, and dbt-trino emits a MERGE on the delta. Verified against [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) and [docs.getdbt.com/reference/dbt-jinja-functions/is_incremental](https://docs.getdbt.com/reference/dbt-jinja-functions/is_incremental).

4. **`(SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01 ...') FROM {{ this }})`** is the watermark expression. The `COALESCE` to a safe sentinel is belt-and-suspenders in case the table exists but is empty (`MAX` returns NULL on an empty table, which would make the `>=` comparison return UNKNOWN for every row and drop everything). The subquery wrapper is REQUIRED — Trino rejects bare aggregates in `WHERE` (`MAX(...)` must be inside a `SELECT`).

#### DO-NOT-WRITE — surrogate-key + incremental anti-patterns (iter489 Q4 fab class)

| DO NOT write | Why it's wrong | Correct form |
|---|---|---|
| `{% if execute %} WHERE updated_at >= ... {% endif %}` (using `execute` as the incremental guard) | **WRONG GUARD — `execute` is NOT an incremental gate.** The dbt Jinja variable `execute` is `True` during `dbt compile`, `dbt run`, `dbt build`, AND `dbt docs generate` — it does NOT distinguish first-build from incremental-run from `--full-refresh`. Using it as the delta-filter guard would wrongly apply the WHERE on the very first build (when `{{ this }}` is empty / doesn't exist yet) AND on `--full-refresh` runs (when the entire table should be rebuilt unfiltered). Verified against [docs.getdbt.com/reference/dbt-jinja-functions/execute](https://docs.getdbt.com/reference/dbt-jinja-functions/execute). | `{% if is_incremental() %} WHERE updated_at >= ... {% endif %}` — the ONLY correct guard for an incremental delta filter. |
| `{% if 'order_pk' in adapter.get_columns_in_relation(this) %} WHERE ... {% endif %}` (using column-existence as the incremental guard) | **WRONG GUARD — same class as `{% if execute %}`.** Column-existence checks tell you about the target schema, not about the run mode. They don't distinguish `--full-refresh` from a normal incremental run. They also fail on the very first build (when `this` doesn't exist yet and `get_columns_in_relation` errors). | `{% if is_incremental() %}` — the canonical guard. |
| `WHERE updated_at >= MAX(updated_at) FROM {{ this }}` (bare aggregate in WHERE) | **TRINO PARSE ERROR** — aggregates are not allowed in a bare `WHERE`. Must be wrapped in a SELECT subquery. | `WHERE updated_at >= (SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01 00:00:00 UTC') FROM {{ this }})`. |
| `SELECT order_seq.NEXTVAL AS order_pk, ...` (Oracle sequence pasted into Trino) | **TRINO PARSE ERROR** — Trino has no sequences, no `NEXTVAL`. | `{{ dbt_utils.generate_surrogate_key(['tenant_id', 'natural_order_id']) }} AS order_pk`. |
| `ROW_NUMBER() OVER (ORDER BY natural_order_id) AS order_pk` as a stable cross-run key | **NOT STABLE ACROSS RUNS.** `ROW_NUMBER()` produces a BIGINT that depends on the input row order at the time of the SELECT. A second `dbt run --full-refresh` can produce a DIFFERENT mapping for the same natural keys because the source ordering may shift. Downstream foreign keys break silently. | `{{ dbt_utils.generate_surrogate_key([...]) }}` — MD5 of the natural keys is bit-for-bit identical across every run. Use `ROW_NUMBER()` only for single-run scratch keys (e.g., within one CTAS that never re-runs incrementally). |
| `md5(concat_ws('\|\|', col1, col2))` or bare `md5(col1)` / `md5(CAST(col AS VARCHAR))` as a hand-rolled Trino surrogate key | **TRINO TYPE ERROR — `md5` requires VARBINARY, NOT VARCHAR.** Per [trino.io/docs/current/functions/binary.html](https://trino.io/docs/current/functions/binary.html), Trino's signature is **`md5(varbinary) -> varbinary`** (binary in, binary out). Passing a varchar fails with `Unexpected parameters (varchar) for function md5. Expected: md5(varbinary)`. Wrap the inner varchar with `to_utf8(...)` to get varbinary, then `md5(...)`, then `to_hex(...)` for the printable hex string. **Note (iter531 reconcile):** the inner `concat_ws` is NOT the bug — Trino 467 DOES have `concat_ws(separator, string1, ..., stringN) -> varchar` per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html). Earlier resource passes incorrectly banned `concat_ws` as Postgres/Spark-only; that ban is rescinded. The bug is purely the missing `to_utf8(...)` wrap around the varchar before `md5`. | **PRIMARY (canonical, always prefer):** `{{ dbt_utils.generate_surrogate_key(['col1', 'col2']) }}` — emits the correct compiled SQL automatically. **FALLBACK (hand-rolled, only when dbt_utils is unavailable):** `to_hex(md5(to_utf8(concat_ws('\|\|', CAST(col1 AS VARCHAR), CAST(col2 AS VARCHAR)))))` OR `to_hex(md5(to_utf8(concat(CAST(col1 AS VARCHAR), '\|\|', CAST(col2 AS VARCHAR)))))`. Both compile on Trino 467. |
| `properties={'partitioned_by': "ARRAY['order_date']"}` inside a dbt-trino model whose target catalog is **Iceberg** (the production stack) | The Iceberg connector defines its partition-spec property as **`partitioning`** (not `partitioned_by`) — see [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). dbt-trino's `properties()` macro passes the dict keys verbatim into the `WITH (...)` clause, so writing `'partitioned_by'` against an Iceberg catalog either errors at apply time or is silently dropped. `partitioned_by` IS the Hive connector's key, but Hive is a different connector — on this stack (Iceberg), use `partitioning`. | `properties={'partitioning': "ARRAY['order_date']"}` for an Iceberg model. See [resource 28 § LEADING CANONICAL — dbt-trino partition key for Iceberg vs Hive](28-complex-sql-performance-trino-dbt.md) for the full three-surface contrast block. |

#### Cross-references

- **Above:** [§ 3.3 minimum-viable dbt config for a migrated MERGE procedure](#33-the-minimum-viable-dbt-config-for-a-migrated-merge-procedure) — the canonical `is_incremental()` recipe in the materialization section, with the same `{% if execute %}` DO-NOT-WRITE callout.
- **Below:** [§ 4.5B ROWNUM CANONICAL FORMS](#45b-rownum-canonical-forms--oracle-row-limiting-and-pagination-read-this-when-auditing-legacy-oracle-top-n--pagination-code) — the Oracle ROWNUM → Trino LIMIT translations engineers will hit alongside this surrogate-key migration.
- **Resource 28:** [§ LEADING CANONICAL WORKED EXAMPLE — the canonical dbt-trino + Iceberg incremental block](28-complex-sql-performance-trino-dbt.md) — the single-source-of-truth recipe for the dbt-incremental shape, with the full DO-NOT-WRITE matrix (`{% if execute %}` guard, `partitioning` vs `partitioned_by` connector-key distinction, bare-aggregate-in-WHERE, etc.).

**Two-engine note.** This guardrail is specifically about the **Iceberg** spec / catalog, NOT about Delta Lake. Delta Lake has had user-facing identity columns since Delta 2.x (`CREATE TABLE ... (id BIGINT GENERATED ALWAYS AS IDENTITY, ...)` works on Delta). If you read a blog post about "lakehouse identity columns" and it shows Delta DDL, that DDL does NOT port to Iceberg. The two table formats have different feature sets here.

**Cross-references.**
- §1.2 procedural-construct map: `my_seq.NEXTVAL` row already points to `dbt_utils.generate_surrogate_key` as the PRIMARY replacement.
- §4.5 query-shape table: `SELECT my_seq.NEXTVAL FROM DUAL` row says "NO equivalent — sequences don't exist in Trino. Use hash-based surrogate key."
- §7 cutover checklist item 5 (line 888): surrogate-key stability — hash-based keys are stable across re-runs but will NOT match the Oracle-generated values; plan a one-time mapping table or re-keying pass.

### 4.5B ROWNUM CANONICAL FORMS — Oracle row-limiting and pagination (READ THIS when auditing legacy Oracle top-N / pagination code)

**Why this section exists.** The §4.5 one-liner `WHERE ROWNUM <= 10 → LIMIT 10 (after ORDER BY)` is correct as a destination, but the Oracle SOURCE-side examples engineers paste into migration audits frequently use INVALID Oracle syntax. The most common mistake is `SELECT ... FROM t ORDER BY col WHERE ROWNUM <= N` — that is a parse error in Oracle (and ANSI: `ORDER BY` must come AFTER `WHERE`). The slightly subtler mistake is `SELECT ... FROM t WHERE ROWNUM <= N ORDER BY col` — syntactically valid in Oracle, but **semantically wrong**: Oracle assigns `ROWNUM` **BEFORE** `ORDER BY`, so you get an unspecified set of N rows that are THEN sorted. **Neither form is "Oracle top-N".** This section establishes the canonical Oracle forms so engineers can recognize them in legacy code and translate correctly.

**The non-negotiable Oracle ROWNUM evaluation order (verified against [docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/ROWNUM-Pseudocolumn.html](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/ROWNUM-Pseudocolumn.html) and Tom Kyte's canonical post at [asktom.oracle.com/Misc/oramag/on-rownum-and-limiting-results.html](https://asktom.oracle.com/Misc/oramag/on-rownum-and-limiting-results.html)):**

> Oracle assigns `ROWNUM` to each row **AS IT IS RETRIEVED**, BEFORE `ORDER BY` is applied. This means `WHERE ROWNUM <= N` on the same query level as `ORDER BY` picks an UNSPECIFIED N rows from the underlying table and then sorts them. **To get the TOP-N-by-order, you MUST sort first in an inline view and apply `ROWNUM` in the outer query.**

#### Canonical Oracle row-limiting forms — read this table, audit your legacy SQL against it

| Oracle source form | Valid Oracle? | What it actually does | Canonical Trino 467 translation |
|---|---|---|---|
| `SELECT * FROM events ORDER BY event_id DESC WHERE ROWNUM <= 100` | **INVALID** — `ORDER BY` cannot appear before `WHERE`. Parse error: `ORA-00933: SQL command not properly ended`. | Nothing — query never runs. | n/a — fix the Oracle source first. If the engineer's intent is "top 100 by event_id DESC", translate to `SELECT * FROM events ORDER BY event_id DESC LIMIT 100`. |
| `SELECT * FROM events WHERE ROWNUM <= 100 ORDER BY event_id DESC` | Valid syntax | **SEMANTICALLY WRONG for top-N.** Picks 100 unspecified rows (full-table-scan order), then sorts THOSE 100 by `event_id DESC`. Does NOT return the top 100 from the whole table. | If the intent was top-N: `SELECT * FROM events ORDER BY event_id DESC LIMIT 100`. If the intent was "any 100 rows, sorted for display" (rare), use `SELECT * FROM (SELECT * FROM events LIMIT 100) ORDER BY event_id DESC`. |
| `SELECT * FROM (SELECT * FROM events ORDER BY event_id DESC) WHERE ROWNUM <= 100` | Valid syntax | **CANONICAL Oracle 11g top-N pattern.** Inner inline view sorts the full table; outer `WHERE ROWNUM <= 100` takes the first 100 from the sorted stream. This is what migration audits SHOULD find. | `SELECT * FROM events ORDER BY event_id DESC LIMIT 100` |
| `SELECT * FROM events ORDER BY event_id DESC FETCH FIRST 100 ROWS ONLY` | Valid syntax (Oracle 12c+) | **CANONICAL Oracle 12c+ ANSI row-limiting clause.** Equivalent to the inline-view wrap, much cleaner. | `SELECT * FROM events ORDER BY event_id DESC LIMIT 100` |
| `SELECT * FROM (SELECT a.*, ROWNUM rnum FROM (SELECT * FROM events ORDER BY event_id DESC) a WHERE ROWNUM <= 100) WHERE rnum >= 51` | Valid syntax | **CANONICAL Oracle 11g pagination pattern.** Two-level inline view: inner sorts, middle assigns ROWNUM and caps at upper bound, outer filters to lower bound. Returns rows 51-100 in sorted order. | `SELECT * FROM events ORDER BY event_id DESC OFFSET 50 LIMIT 50` (or `LIMIT 50 OFFSET 50`). |
| `SELECT * FROM events ORDER BY event_id DESC OFFSET 50 ROWS FETCH NEXT 50 ROWS ONLY` | Valid syntax (Oracle 12c+) | Canonical Oracle 12c+ pagination via the ANSI clause. | `SELECT * FROM events ORDER BY event_id DESC OFFSET 50 LIMIT 50` |
| Keyset pagination: `SELECT * FROM events WHERE event_id < :cursor ORDER BY event_id DESC FETCH FIRST 50 ROWS ONLY` | Valid syntax (Oracle 12c+) | The right pattern for deep pagination — uses an index seek rather than offset-scan. | `SELECT * FROM events WHERE event_id < :cursor ORDER BY event_id DESC LIMIT 50` — identical structure, just `LIMIT` instead of `FETCH FIRST`. |

#### DO-NOT-WRITE — banned Oracle source-dialect examples in migration audits

> | DO NOT show this Oracle source | What is wrong | What to show instead |
> |---|---|---|
> | `SELECT * FROM events ORDER BY event_id DESC WHERE ROWNUM <= 100` | INVALID Oracle SQL — parse error. Engineers reading a migration guide should never see invalid Oracle labeled as Oracle. | The canonical Oracle 11g `SELECT * FROM (SELECT * FROM events ORDER BY event_id DESC) WHERE ROWNUM <= 100` OR the Oracle 12c+ `SELECT * FROM events ORDER BY event_id DESC FETCH FIRST 100 ROWS ONLY`. |
> | `SELECT * FROM events WHERE ROWNUM <= 100 ORDER BY event_id DESC` labeled as "Oracle top-N" | Valid Oracle SQL but **NOT top-N** — picks 100 unspecified rows then sorts them. If a legacy Oracle program has this, it is almost certainly a bug — engineers planning migration should FLAG it, not translate it as if it were top-N. | Audit hint: when you grep Oracle source for `WHERE ROWNUM`, flag any line where `ORDER BY` appears on the SAME query level (not inside an inner subquery) — that program likely had a top-N bug in Oracle that the migration is a good opportunity to fix. |
> | `SELECT TOP 100 * FROM events ORDER BY event_id DESC` as Oracle | `TOP N` is SQL Server / Sybase syntax, NOT Oracle. Oracle's row-limiting is ROWNUM (11g) or FETCH FIRST (12c+). | Use the canonical Oracle forms in the table above. |
> | `ROWNUM = N` for N > 1 (e.g., `WHERE ROWNUM = 5` to get "the 5th row") | This NEVER returns a row in Oracle. Oracle assigns ROWNUM incrementally as rows pass the WHERE filter, so the first row that survives WHERE always gets ROWNUM=1; the test `ROWNUM = 5` fails for that row, the row is discarded, and ROWNUM stays at 1 for the next row tested. Only `ROWNUM = 1` works on the bare table; for "the Nth row", use a `row_number() OVER (...)` analytic function. | Trino: `SELECT * FROM (SELECT *, row_number() OVER (ORDER BY event_id DESC) AS rn FROM events) WHERE rn = 5;` |

#### Trino-side canonical forms (the destination)

| Intent | Trino 467 form |
|---|---|
| First N by order | `SELECT * FROM events ORDER BY event_id DESC LIMIT 100` |
| Page M through M+N | `SELECT * FROM events ORDER BY event_id DESC OFFSET 50 LIMIT 50` (`OFFSET` clause goes BEFORE `LIMIT`, per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html)) |
| Keyset pagination (recommended for deep pages) | `SELECT * FROM events WHERE event_id < :cursor ORDER BY event_id DESC LIMIT 50` |
| Top-N-per-group | `SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY tenant_id ORDER BY event_id DESC) AS rn FROM events) WHERE rn <= 10` (Trino 467 has NO `QUALIFY` — see resource 23) |
| The Nth row exactly | `SELECT * FROM (SELECT *, row_number() OVER (ORDER BY event_id DESC) AS rn FROM events) WHERE rn = 5` |

> **Why `LIMIT` is safe in Trino while `ROWNUM` was deterministic-only-with-inline-view in Oracle.** Trino's `LIMIT` clause is defined to apply AFTER `ORDER BY` (per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) — "LIMIT count [OFFSET start]" appears after ORDER BY in the canonical clause order). There is no Oracle-style "ROWNUM is assigned before ORDER BY" trap; `ORDER BY ... LIMIT N` in Trino does exactly what an engineer reading it expects.

**Cross-references.**
- §4.5 query-shape table — the one-liner translation for `WHERE ROWNUM <= 10`.
- Resource 23 §"Trino 467 SQL-dialect anti-patterns" — `QUALIFY` is NOT in Trino 467; use the outer-`WHERE rn <= N` pattern for top-N-per-group.
- Resource 28 §"Pagination patterns" — keyset pagination on big Iceberg tables, plus the row_number-vs-LIMIT distinction in dbt incremental models.

### 4.5C LEADING CANONICAL — Oracle `ROWID`-based dedup → Trino (no ROWID; READ-dedup vs IN-PLACE-dedup are different patterns)

> **Keyword anchors:** Trino ROWID dedup, ROWID Trino, $row_id Trino, deduplicate rows no unique key, keep first row per group, delete duplicate rows Iceberg, Oracle ROWID delete migration, row_number rn = 1, QUALIFY dedup Trino. **The fix is in two distinct shapes — pick by whether you're reading or rewriting the table.**

**The one fact.** Trino has **NO `ROWID` pseudocolumn** and no user-visible stable physical row id — verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) (no ROWID in the column-reference grammar) and Trino doesn't expose Iceberg's internal `_pos`/`_file` either. So the Oracle `DELETE FROM t WHERE ROWID NOT IN (SELECT MIN(ROWID) FROM t GROUP BY k)` dedup idiom has **no direct rewrite** on Trino 467.

> **Clarification — Iceberg v2 DOES support `DELETE FROM <table> WHERE <predicate>` (row-level deletes).** The Trino Iceberg connector supports `DELETE`, `UPDATE`, `MERGE`, and `TRUNCATE` on format-v2 tables ([trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — *"Tables using v2 of the Iceberg specification support deletion of individual rows by writing position delete files."*). What you **cannot** do is express "delete duplicates keeping the most recent" in a single predicate — that requires a row-by-row decision (`ROW_NUMBER() > 1`) that no boolean `WHERE` predicate can encode on its own. **Do NOT write "Iceberg has no DELETE" or "Trino has no row-level delete on Iceberg" — both are FALSE.** The correct framing is: row-level DELETE works fine for `WHERE user_id = 'gdpr-subject-42'` or `WHERE event_date < DATE '2025-01-01'`; it does NOT work for "keep first per group" dedup — use Pattern A (READ-dedup subquery) for SELECT-time dedup, or Pattern B1 (CTAS-rebuild + rename) / B2 (MERGE-with-DELETE on a ROW_NUMBER subquery) for in-place dedup.

**(A) READ-dedup (most common — "keep first per group" inside a SELECT or dbt model):** subquery form, NOT `QUALIFY` (Trino 467 has no `QUALIFY` — see §7A.2 and resource 23):

```sql
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at) AS rn
  FROM   t
) WHERE rn = 1;     -- =1 for dedup; <=N for top-N-per-group
```

**(B) IN-PLACE dedup of an existing Iceberg table — REBUILD pattern (no clean rowid-free DELETE).** Without ROWID, you cannot write a single DELETE that keeps one row per group. The two canonical patterns are CTAS + swap, or MERGE-with-DELETE:

```sql
-- Pattern B1 — CTAS + atomic rename (preferred for full-table dedup):
CREATE TABLE iceberg.analytics.t_dedup AS
SELECT customer_id, created_at, amount  -- EXPLICIT column list — Iceberg has no SELECT * rename safety
FROM (
  SELECT customer_id, created_at, amount,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at) AS rn
  FROM   iceberg.analytics.t
) WHERE rn = 1;
DROP TABLE iceberg.analytics.t;
ALTER TABLE iceberg.analytics.t_dedup RENAME TO iceberg.analytics.t;
-- (Or: INSERT OVERWRITE the original from the dedupped projection; preserves table identity / grants.)

-- Pattern B2 — MERGE whose MATCHED branch DELETEs the dupes (when partial dedup, not full rebuild):
MERGE INTO iceberg.analytics.t AS tgt
USING (
  SELECT customer_id, created_at FROM (
    SELECT customer_id, created_at,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at) AS rn
    FROM iceberg.analytics.t
  ) WHERE rn > 1                                -- the rows to delete
) AS dup ON tgt.customer_id = dup.customer_id AND tgt.created_at = dup.created_at
WHEN MATCHED THEN DELETE;
```

**DO NOT WRITE:**

| Wrong shape | Why it's wrong |
|---|---|
| `DELETE FROM t WHERE ROWID NOT IN (SELECT MIN(ROWID) FROM t GROUP BY k)` on Trino | **No `ROWID` pseudocolumn on Trino 467.** Parse error: `Column 'rowid' cannot be resolved`. This is the Oracle dedup idiom — there is no in-place rewrite; use Pattern B1 (CTAS + rename) or B2 (MERGE + DELETE) above. |
| `DELETE FROM t WHERE row_id NOT IN (...)` / `$row_id` / `_pos` | **None exists as a user-visible column in Trino 467's Iceberg connector.** Iceberg's internal position/file refs are connector-internal and not exposed in user SELECTs. |
| `DELETE FROM t WHERE ROW_NUMBER() OVER (PARTITION BY k ORDER BY ts) > 1` | **Window functions are NOT allowed in `WHERE` in ANY SQL dialect, including Trino.** Wrap in a subquery (Pattern A) or push to a MERGE-USING subquery (Pattern B2). |
| `SELECT ... FROM t QUALIFY ROW_NUMBER() OVER (PARTITION BY k ORDER BY ts) = 1` | **`QUALIFY` is NOT supported in Trino 467** — Snowflake/BigQuery/Databricks/Teradata only. Parse error. Use the subquery form in Pattern A. See §7A.2 QUALIFY landmine + resource 23 §dialect anti-patterns. |
| `DELETE FROM t a WHERE EXISTS (SELECT 1 FROM t b WHERE b.k = a.k AND b.created_at < a.created_at)` "to keep the earliest per group" | Works conceptually but is a **correlated NOT-EXISTS pattern that Trino plans poorly** (LeftJoin + Aggregation, no SemiJoin short-circuit — see resource 23 §10 and trinodb/trino #21859). On a wide table with many duplicates the plan explodes. Prefer the explicit `ROW_NUMBER` rewrite (Pattern A/B1/B2) — it's both faster and clearer. |

**Cross-references.** Pattern A's `ROW_NUMBER` subquery form is the same canonical "top-N-per-group" template from §7A.2 (Oracle analytic → Trino) and resource 23 §"`QUALIFY` rewrite". Pattern B1's CTAS-then-RENAME swap relies on Iceberg's atomic `ALTER TABLE ... RENAME TO` (see resource 17 §"Iceberg RENAME / DROP / table-identity" coverage). For Pattern B2 MERGE syntax constraints (no `UPDATE SET *`, explicit column lists required), see §4.6B Trino MERGE star-shorthand guardrail.

### 4.5D LEADING CANONICAL — Trino `uuid()` is RANDOM (RFC-4122 v4); SAFE for one-shot random ids, UNSAFE as a dbt incremental surrogate / `unique_key`

> **Keyword anchors (read this block FIRST if your question contains any of these):** Trino uuid function, Trino uuid(), generate unique id Trino, Trino random uuid, RFC-4122 v4 Trino, gen_random_uuid Trino, gen_random_uuid Trino equivalent, Postgres gen_random_uuid translate, uuid vs generate_surrogate_key, random vs deterministic key, dbt incremental surrogate uuid, unique_key uuid dbt, idempotent dbt key, Iceberg primary key not enforced, Iceberg unique constraint not enforced, unique id per row Trino, event_id request_id mint.

**The two facts (load-bearing — verified [trino.io/docs/current/functions/uuid.html](https://trino.io/docs/current/functions/uuid.html) and the Iceberg connector docs at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html)):**

1. **Trino HAS `uuid()`** — returns a **pseudo-randomly generated RFC-4122 type-4 (v4) UUID**, return type `UUID` (16-byte type). For a 36-char string form, write `CAST(uuid() AS VARCHAR)`. Postgres `gen_random_uuid()` → Trino `uuid()` (there is **NO `gen_random_uuid` function in Trino** — that name is Postgres-only; writing it in Trino is a parse error `Function 'gen_random_uuid' not registered`).
2. **`uuid()` is NON-deterministic** — every invocation returns a different value. A `dbt run` that materializes `uuid()` as a column produces DIFFERENT values for the SAME logical row on each re-run, which **breaks idempotency**. If you use `uuid()` as a dbt incremental model's `unique_key`/surrogate, the MERGE never matches an existing row (the source key is fresh each run) → the model writes duplicates instead of upserting, and `dbt test --select unique:my_key` will silently pass on each run while the table grows linearly with re-runs.

**The discipline (the one rule).** `uuid()` is appropriate **ONLY for a truly-new-each-insert random id** that is minted once at first insert and never re-derived from upstream columns — e.g., an `event_id` / `request_id` / `correlation_id` for a brand-new row a streaming or append-only pipeline is writing for the first time. For a **STABLE, reproducible surrogate key** that survives `dbt run --full-refresh` and incremental re-runs, use **`{{ dbt_utils.generate_surrogate_key(['col1', 'col2']) }}`** (deterministic MD5 hash of the inputs — same inputs always produce the same key; see [§4.5A](#45a-iceberg-identity-column-negation-guardrail--iceberg-has-no-user-facing-identity--auto-increment-columns-use-dbt_utilsgenerate_surrogate_key-instead) for the canonical block). The choice is sharp: **deterministic → `generate_surrogate_key`**, **random one-shot → `uuid()`**.

**Iceberg constraints — the second load-bearing fact (two layers, NOT one).** (1) **Trino-DDL grammar layer:** Trino 467 CREATE TABLE has NO `PRIMARY KEY` / `FOREIGN KEY` / `UNIQUE` / `CHECK` constraint syntax at all (verified [trino.io/docs/467/sql/create-table.html](https://trino.io/docs/467/sql/create-table.html) — the grammar only accepts `[NOT NULL] [COMMENT ...] [WITH (...)]` after a column data type). Writing `(order_id UUID PRIMARY KEY, ...)` fails at PARSE TIME with `mismatched input 'PRIMARY'` — the SQL never reaches the connector, so the keyword is NOT parsed-and-ignored and is NOT stored as metadata. To express a logical key in Trino DDL, use `NOT NULL` + `COMMENT 'logical primary key'`. (2) **Iceberg-spec layer (the deeper conceptual rule):** Even at the dbt YAML / Iceberg metadata layer (where a `primary_key` constraint CAN be declared in dbt YAML — see § 6 contracts table below), the Iceberg spec and the Trino Iceberg connector do NOT enforce PRIMARY KEY / UNIQUE at write time — declared PKs are advisory only; duplicate inserts land silently. Uniqueness, dedup, and idempotency are **your pipeline's responsibility**, enforced via the dbt MERGE `unique_key` config (`incremental_strategy='merge'`), via `generate_surrogate_key` for stable keys, or via a post-write `dbt test --select unique` assertion that FAILs the build if duplicates land. This rule holds REGARDLESS of how you generate the id — using `uuid()` does not magically make your table unique, because Iceberg won't reject the duplicate. Cross-ref the iter402 Iceberg-PK-not-enforced rule and the [resource 23 § Trino 467 CREATE TABLE](../resources/23-sql-best-practices-olap.md#trino-467-create-table-what-is-vs-is-not-supported--no-primary-key--foreign-key--unique--check--default) DDL-grammar canonical.

```sql
-- CORRECT use 1 — one-shot random id minted at insert, never re-derived:
INSERT INTO iceberg.analytics.events (event_id, occurred_at, payload)
SELECT uuid(),                                  -- RANDOM v4 UUID per row, minted ONCE here
       occurred_at,
       payload
FROM   staging.raw_events;

-- CORRECT use 2 — 36-char VARCHAR for systems that expect string UUIDs:
SELECT CAST(uuid() AS VARCHAR) AS request_id    -- '550e8400-e29b-41d4-a716-446655440000'-shape
FROM   ...;

-- CORRECT use 3 — Postgres gen_random_uuid() in a query you're porting to Trino:
-- Postgres: SELECT gen_random_uuid();
-- Trino   : SELECT uuid();                     -- exact replacement
```

```sql
-- WRONG — uuid() as a dbt incremental surrogate / unique_key (NON-DETERMINISTIC):
{{ config(materialized='incremental', incremental_strategy='merge', unique_key='order_pk') }}
SELECT uuid()         AS order_pk,              -- BUG — fresh value EVERY RUN for the same logical order
       tenant_id,
       natural_order_id,
       ...
FROM   {{ ref('stg_orders') }}
-- Outcome: MERGE never matches because s.order_pk is always new → row is INSERTed every run → duplicates.

-- CORRECT — deterministic surrogate via generate_surrogate_key:
{{ config(materialized='incremental', incremental_strategy='merge', unique_key='order_pk') }}
SELECT {{ dbt_utils.generate_surrogate_key(['tenant_id', 'natural_order_id']) }} AS order_pk,
       tenant_id,
       natural_order_id,
       ...
FROM   {{ ref('stg_orders') }}
-- Outcome: same (tenant_id, natural_order_id) → same MD5 hex → MERGE matches → upsert works.
```

#### DO-NOT-WRITE — `uuid()` and Iceberg-PK fabrications

| Wrong shape | Why it's wrong | What to write instead |
|---|---|---|
| `unique_key = 'id', SELECT uuid() AS id, ...` inside a dbt `materialized='incremental', incremental_strategy='merge'` model | **NON-DETERMINISTIC.** `uuid()` returns a different value every call — the MERGE ON clause never matches an existing row, so every incremental run INSERTs duplicates instead of upserting. `dbt test --select unique:id` will PASS each individual run (each run's batch is internally unique) while the table accumulates a fresh copy of every logical row on every re-run. | `unique_key = 'id', SELECT {{ dbt_utils.generate_surrogate_key(['col1', 'col2']) }} AS id, ...` — deterministic MD5 hash of the natural keys; same inputs always produce the same id, so the MERGE matches and upserts correctly. See §4.5A. |
| `SELECT gen_random_uuid() FROM ...` in Trino SQL or a dbt-trino model | **`gen_random_uuid` is a Postgres function, NOT a Trino function** — Trino parse error `Function 'gen_random_uuid' not registered`. | `SELECT uuid() FROM ...` — Trino's RFC-4122 v4 generator. For a 36-char string: `CAST(uuid() AS VARCHAR)`. |
| `CREATE TABLE iceberg.analytics.orders (order_id UUID PRIMARY KEY, ...)` and assuming Iceberg will REJECT duplicate inserts on `order_id` | **Two-layer wrong.** (1) **GRAMMAR layer (the immediate failure):** Trino 467 CREATE TABLE has NO `PRIMARY KEY` / `FOREIGN KEY` / `UNIQUE` / `CHECK` constraint syntax — the statement fails at PARSE TIME with `mismatched input 'PRIMARY'. Expecting: ')', ',', 'COMMENT', 'NOT', 'WITH'`. The connector does NOT parse-and-ignore the keyword and does NOT store it as metadata. (2) **SPEC layer (the conceptual myth):** Even if Trino accepted the syntax, Iceberg does NOT enforce PRIMARY KEY / UNIQUE at write time — duplicate inserts would land silently. Uniqueness is YOUR pipeline's responsibility. See [resource 23 § "Trino 467 CREATE TABLE: what IS vs IS NOT supported"](../resources/23-sql-best-practices-olap.md#trino-467-create-table-what-is-vs-is-not-supported--no-primary-key--foreign-key--unique--check--default) for the full DDL-grammar matrix. | (a) Drop the `PRIMARY KEY` keyword from the DDL — use `order_id UUID NOT NULL COMMENT 'logical primary key'` instead (NOT NULL + COMMENT ARE supported). (b) Enforce uniqueness in the pipeline: `{{ config(materialized='incremental', incremental_strategy='merge', unique_key='order_id') }}` PLUS a schema YAML `tests: [unique, not_null]` on `order_id` so the build FAILs if duplicates land. |
| `uuid()` used as the Iceberg partition/sort key (`partitioning = ARRAY['uuid_col']` or sorted by uuid) | **Random UUIDs defeat min/max pruning and bucket locality** — every file's UUID range covers the full UUID space; no file-skipping is possible on a UUID filter. See resource 09 §"Don't use UUIDs as your only sort key" for the schema-design version of this rule. | Sort/partition by `day(occurred_at)` or low-cardinality tenant/category columns; keep `uuid()` as the row-key column only. |
| `CAST(uuid() AS BIGINT)` to get a "numeric surrogate key" | **Type error** — UUID is 128-bit, BIGINT is 64-bit signed; the cast fails. UUIDs are not numeric and cannot be coerced to BIGINT in Trino. | If you need a BIGINT surrogate, use `ROW_NUMBER() OVER (ORDER BY ...)` (only stable within a single run — see §4.5A FALLBACK) or pre-allocate the BIGINT in the source system. For stable string surrogates, use `generate_surrogate_key`. |

#### Cross-references

- **Above:** [§ 4.5A ICEBERG-IDENTITY-COLUMN-NEGATION GUARDRAIL](#45a-iceberg-identity-column-negation-guardrail--iceberg-has-no-user-facing-identity--auto-increment-columns-use-dbt_utilsgenerate_surrogate_key-instead) — the canonical `dbt_utils.generate_surrogate_key` (PRIMARY) / `ROW_NUMBER()` (FALLBACK) shape for **stable, deterministic** surrogate keys. This §4.5D is the sibling rule for the **random one-shot** case — pick by determinism requirement, not by syntax preference.
- **Resource 09:** §"Don't use UUIDs as your only sort key" + the UUID-PK-bucket-key myth row — the schema-design implications of UUID as a row key (fine) vs sort/partition key (defeats pruning).
- **Resource 13:** the `gen_random_uuid()` references at lines 1029, 2490, 3846 are all **Postgres-side** SQL (inside Spark JDBC `dbtable` subqueries that execute IN Postgres, not Trino) — that is the correct usage. Inside Trino-side SQL or dbt-trino models, the function is `uuid()`.
- **iter402 Iceberg-PK-not-enforced rule:** the Iceberg connector and Iceberg spec do not enforce PRIMARY KEY / UNIQUE at write time. Enforce in the pipeline (dbt MERGE `unique_key` + `dbt test --select unique`), never assume the table format will reject duplicates. **AND (the deeper iter681 fix):** Trino 467 CREATE TABLE does not even accept `PRIMARY KEY` / `FOREIGN KEY` / `UNIQUE` / `CHECK` syntax — it parse-errors with `mismatched input 'PRIMARY'`. The dbt YAML `primary_key:` constraint (see § 6 dbt-trino contracts table) is a separate layer (YAML metadata only; recorded but not enforced). See [resource 23 § "Trino 467 CREATE TABLE: what IS vs IS NOT supported"](../resources/23-sql-best-practices-olap.md#trino-467-create-table-what-is-vs-is-not-supported--no-primary-key--foreign-key--unique--check--default) for the full DDL-grammar canonical.

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

### 4.6B TRINO MERGE STAR-SHORTHAND GUARDRAIL — Trino MERGE requires EXPLICIT column lists, NO `UPDATE SET *` / `INSERT *`

**Why this section exists (iter476 cross-dialect-spillover fix).** Spark, Delta Lake, Databricks, and Snowflake MERGE all support a star-shorthand form — `WHEN MATCHED THEN UPDATE SET *` and `WHEN NOT MATCHED THEN INSERT *` — which auto-expands to "every column matched by name". **Trino MERGE does NOT.** Trino's grammar requires **explicit column lists** on both branches: every UPDATE SET assignment must be written `col = expression`, and every INSERT VALUES must list both the target columns and the source expressions. The iter476 responder copy-pasted `WHEN MATCHED THEN UPDATE SET *` / `WHEN NOT MATCHED THEN INSERT *` into a Trino-context "production CDC" example — that produces a parse error `mismatched input '*'`.

**The canonical Trino MERGE grammar — verified at [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html) on 2026-06-05:**

```
MERGE INTO target_table [ [ AS ] target_alias ]
USING { source_table | query } [ [ AS ] source_alias ]
ON search_condition
when_clause [...]

where when_clause is one of:

  WHEN MATCHED [ AND condition ]
      THEN DELETE

  WHEN MATCHED [ AND condition ]
      THEN UPDATE SET ( column = expression [, ...] )

  WHEN NOT MATCHED [ AND condition ]
      THEN INSERT [ column_list ] VALUES (expression, ...)
```

There is **no `*` shorthand** on either UPDATE SET or INSERT. The column list and the expression list must both be explicit and (for INSERT) length-matched.

**Canonical CDC MERGE example — explicit columns, three-branch (DELETE / UPDATE / INSERT) pattern, Trino-correct:**

```sql
-- Trino 467 + Iceberg 1.5.2 — verified syntax
MERGE INTO iceberg.analytics.fct_orders t
USING (
    SELECT id, op, customer_id, amount, status, updated_at
    FROM {{ ref('stg_orders_cdc_delta') }}
) s
ON t.id = s.id
-- Branch 1: hard-delete rows whose op='d'. MUST come first when DELETE and UPDATE
-- conditions could both match (first-match-wins). See §4.6A.1 first-match-wins note.
WHEN MATCHED AND s.op = 'd' THEN DELETE
-- Branch 2: update existing rows for inserts / updates / re-snapshot reads. EXPLICIT
-- column-by-column assignment — no `UPDATE SET *` shorthand on Trino.
WHEN MATCHED AND s.op IN ('u', 'c', 'r') THEN UPDATE SET
    customer_id = s.customer_id,
    amount      = s.amount,
    status      = s.status,
    updated_at  = s.updated_at
-- Branch 3: insert rows that don't yet exist in target. EXPLICIT (col_list) VALUES (expr_list).
-- Defensively include 'u' to handle initial-snapshot races.
WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT (id, customer_id, amount, status, updated_at)
    VALUES (s.id, s.customer_id, s.amount, s.status, s.updated_at);
```

**Correct claims preserved (do NOT regress these — they are all Trino-valid):**

1. **Multiple `WHEN MATCHED [AND condition]` branches are supported.** Per the Trino MERGE docs: *"MERGE supports an arbitrary number of WHEN clauses."* You can have two `WHEN MATCHED AND ...` branches with different conditions, plus a `WHEN NOT MATCHED AND ...` branch, in the same MERGE.
2. **First-match-wins ordering.** Per the Trino MERGE docs: *"For each source row, the WHEN clauses are processed in order. Only the first matching WHEN clause is executed."* The branch order in the SQL text determines precedence.
3. **`THEN DELETE` is a valid `WHEN MATCHED` action.** A WHEN MATCHED branch can resolve to `DELETE` (no SET clause) instead of `UPDATE SET`.
4. **Put DELETE first when DELETE and UPDATE conditions could both match.** This is a logical consequence of first-match-wins — if the `WHEN MATCHED AND s.op = 'd' THEN DELETE` branch appears AFTER `WHEN MATCHED AND s.op IN ('u','d') THEN UPDATE SET ...`, the UPDATE branch wins, the DELETE never fires, and the deleted row gets its columns silently overwritten (the classic "null-out the deleted row" CDC bug — see also r13 §2886 CRITICAL BUG callout).
5. **Boolean conditions in `AND` clauses can use any expression** — `s.op = 'd'`, `s.op IN ('u', 'c', 'r')`, `s.source_lsn > t.source_lsn`, etc. The `AND condition` is full SQL.

**DO-NOT-WRITE callout (load-bearing — copy this into your code-review checklist):**

> **Never write any of the following in Trino MERGE statements or in any dbt model targeting Trino:**
>
> 1. **`WHEN MATCHED THEN UPDATE SET *`** — Spark / Delta Lake / Databricks / Snowflake star shorthand. Trino parse error: `mismatched input '*'`. **Use explicit `UPDATE SET col1 = s.col1, col2 = s.col2, ...`.**
>
> 2. **`WHEN NOT MATCHED THEN INSERT *`** — Spark / Delta Lake / Databricks / Snowflake star shorthand. Trino parse error: `mismatched input '*'`. **Use explicit `INSERT (col1, col2, ...) VALUES (s.col1, s.col2, ...)`.**
>
> 3. **`WHEN NOT MATCHED THEN INSERT VALUES *`** / **`WHEN NOT MATCHED THEN INSERT VALUES (*)`** — Spark-ism. Trino does not accept `*` anywhere in the INSERT VALUES expression list.
>
> 4. **`WHEN NOT MATCHED THEN INSERT VALUES s.*`** / **`INSERT VALUES (s.*)`** — Spark / Snowflake style for "expand all source columns". Trino does not support `<alias>.*` in expression position inside MERGE VALUES (or in any expression position outside `SELECT *`).
>
> 5. **`WHEN MATCHED THEN UPDATE`** with no `SET` clause — the `SET` clause is **required** if the action is UPDATE. (`WHEN MATCHED THEN DELETE` has no SET clause; that one is fine.)
>
> 6. **`WHEN NOT MATCHED BY SOURCE`** — Oracle 12c+ and SQL Server syntax for "rows in target missing from source". **Trino does NOT support `WHEN NOT MATCHED BY SOURCE`** (only `WHEN MATCHED` and `WHEN NOT MATCHED`). See §4.6A for the two-model decomposition pattern that replaces this Oracle MERGE shape.
>
> 7. **Asymmetric column lists** in INSERT — the number of columns in the `INSERT (col1, col2, ...)` clause must exactly match the number of expressions in the `VALUES (expr1, expr2, ...)` clause. Mismatched counts produce a parse error.

**Keyword-trap phrase (memorize):** *"Anyone who writes `UPDATE SET *` or `INSERT *` in a Trino MERGE is using Spark / Delta Lake / Databricks / Snowflake syntax — Trino MERGE requires explicit column lists for every UPDATE SET assignment AND every INSERT VALUES clause. There is NO `*` shorthand on either branch."*

**For wide tables — auto-generate the column list, do NOT reach for star shorthand.** If you have 50+ columns and don't want to maintain the list by hand, generate it with a dbt macro that queries `INFORMATION_SCHEMA.COLUMNS`:

```jinja
{%- set cols = adapter.get_columns_in_relation(ref('stg_wide_table')) -%}
{%- set col_names = cols | map(attribute='name') | list -%}

MERGE INTO {{ this }} t
USING {{ ref('stg_wide_table') }} s
ON t.id = s.id
WHEN MATCHED THEN UPDATE SET
    {% for c in col_names if c != 'id' -%}
    {{ c }} = s.{{ c }}{% if not loop.last %},{% endif %}
    {% endfor %}
WHEN NOT MATCHED THEN INSERT ({{ col_names | join(', ') }})
    VALUES ({% for c in col_names %}s.{{ c }}{% if not loop.last %}, {% endif %}{% endfor %})
```

This compiles to a fully-expanded MERGE with every column listed — same correctness as a hand-written column list, no Spark-style shorthand needed. The macro adds a few lines of Jinja but the compiled SQL is Trino-valid.

**dbt-trino's `incremental_strategy='merge'` compiled output uses explicit columns automatically.** When you set `incremental_strategy='merge'` on a dbt-trino incremental model, the adapter compiles a MERGE statement with **explicit column lists** on both UPDATE SET and INSERT VALUES — it does **NOT** emit `UPDATE SET *` / `INSERT *`. The compiled output looks like:

```sql
-- dbt-trino compiles incremental_strategy='merge' to:
MERGE INTO {{ this }} AS DBT_INTERNAL_DEST
USING (...) AS DBT_INTERNAL_SOURCE
ON DBT_INTERNAL_SOURCE.<unique_key> = DBT_INTERNAL_DEST.<unique_key>
WHEN MATCHED THEN UPDATE SET
    col1 = DBT_INTERNAL_SOURCE.col1,
    col2 = DBT_INTERNAL_SOURCE.col2,
    ...
WHEN NOT MATCHED THEN INSERT (col1, col2, ...)
VALUES (DBT_INTERNAL_SOURCE.col1, DBT_INTERNAL_SOURCE.col2, ...);
```

The columns are pulled from your model's SELECT projection — that's why getting the SELECT right is load-bearing. If you write `SELECT *` in your dbt model and the source columns change, the next compile picks up the new column automatically (subject to `on_schema_change` settings — see [resource 13 § `on_schema_change`](13-postgres-to-iceberg-ingestion.md)).

**Cross-references.**
- §4.6A — Oracle `WHEN NOT MATCHED BY SOURCE` two-model decomposition (Trino has no `BY SOURCE` clause; see DO-NOT-WRITE #6 above).
- §4.4B cross-dialect-spillover guardrail row "MERGE star shorthand" — consolidated entry for the star-shorthand ban.
- Resource 13 §2886 — Spark/Iceberg MERGE star-shorthand IS valid in `spark.sql("...")` blocks (Spark/Delta-Lake/Iceberg accept it); the Trino ban is specific to Trino-context MERGE statements (in dbt-trino models, in Trino CLI / JDBC). The same SQL works in one engine and parse-errors in the other.

### 4.6A Oracle `MERGE ... WHEN NOT MATCHED BY SOURCE` soft-delete migration — TWO-MODEL DECOMPOSITION IS THE DEFAULT

**Why this section exists.** Oracle 12c+ supports `MERGE ... WHEN NOT MATCHED BY SOURCE THEN UPDATE SET deleted_at = SYSDATE` — the "rows that exist in target but no longer in source get soft-deleted" branch — in a single MERGE statement. **Trino's MERGE statement has NO `WHEN NOT MATCHED BY SOURCE` clause.** Per [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html), Trino's MERGE supports only:

- `WHEN MATCHED [AND condition]` THEN `UPDATE SET ...` | `DELETE`
- `WHEN NOT MATCHED [AND condition]` THEN `INSERT ...`

There is no `WHEN NOT MATCHED BY SOURCE` variant. (Verified against the Trino 481 grammar; the feature has not landed.) When migrating an Oracle MERGE that uses `WHEN NOT MATCHED BY SOURCE` for soft-deletes, you cannot lift-and-shift the single statement.

#### 4.6A.1 The DEFAULT recommended pattern — TWO-MODEL DECOMPOSITION

Split the Oracle MERGE into **two separate dbt models**, each owning one branch of the original Oracle statement. This is the canonical pattern. It is the simplest, the most diff-readable, the most testable, and the one a code reviewer can verify at a glance.

**Model 1 — `fct_customers__upsert` (the incremental MERGE handling matched + not-matched-in-target):**

```sql
-- models/marts/fct_customers__upsert.sql
{{ config(
    materialized = 'incremental',
    incremental_strategy = 'merge',
    unique_key = 'customer_id'
) }}

SELECT
    customer_id,
    email,
    plan,
    updated_at,
    CAST(NULL AS TIMESTAMP) AS deleted_at   -- typed-NULL, see §4.4A — never write NULL::TIMESTAMP
FROM {{ ref('stg_customers') }}

{% if is_incremental() %}
WHERE updated_at > (SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01') FROM {{ this }})
{% endif %}
```

This model owns the `WHEN MATCHED THEN UPDATE` and `WHEN NOT MATCHED THEN INSERT` halves of the Oracle MERGE. It does NOT touch `deleted_at` on the soft-delete side. The dbt-trino adapter compiles this to a Trino `MERGE INTO ... WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT` statement that uses the `unique_key` for the ON clause.

**Model 2 — `fct_customers__soft_delete` (the standalone MERGE handling the missing-in-source soft-delete):**

```sql
-- models/marts/fct_customers__soft_delete.sql
{{ config(
    materialized = 'incremental',
    incremental_strategy = 'merge',
    unique_key = 'customer_id'
) }}

-- The "source" CTE is the set of customer_ids that are still live in the staging table.
-- The MERGE finds target rows whose customer_id is NOT in that live set
-- and stamps deleted_at on them.
WITH live_in_source AS (
    SELECT DISTINCT customer_id
    FROM {{ ref('stg_customers') }}
),
to_soft_delete AS (
    SELECT
        t.customer_id,
        t.email,
        t.plan,
        t.updated_at,
        CURRENT_TIMESTAMP AS deleted_at
    FROM {{ this }} t
    WHERE t.deleted_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM live_in_source s WHERE s.customer_id = t.customer_id
      )
)
SELECT * FROM to_soft_delete
```

Notes on Model 2:
- **`NOT EXISTS` (not `NOT IN`)** — see §4.6A.3 for the three-valued-logic footgun on `NOT IN`. Always use `NOT EXISTS` when the subquery could return NULL.
- **`WHERE t.deleted_at IS NULL`** — only soft-delete rows that are not already soft-deleted; this makes the model idempotent (re-running it does not bump `deleted_at` forward for already-soft-deleted rows).
- **Reads from `{{ this }}`** — Model 2 explicitly reads the current state of the target fact table. dbt allows `{{ this }}` references in incremental models.
- **DAG ordering:** Model 2 must run **after** Model 1. Use `{{ ref('fct_customers__upsert') }}` somewhere in Model 2 (e.g., as a no-op `WHERE EXISTS` against the upsert model) to express the dependency, OR rely on dbt's `tags` + a `+` selector in the production schedule.
- **Model 2's body is a SELECT — that is the only dbt model body shape that exists.** Per [docs.getdbt.com/docs/build/models](https://docs.getdbt.com/docs/build/models), every dbt model body is a SELECT statement; dbt's `materialized='incremental'` + `incremental_strategy='merge'` config wraps it as a Trino `MERGE INTO target USING (<this SELECT>) ON ... WHEN MATCHED THEN UPDATE`. **You DO NOT write a raw `UPDATE` or `DELETE` statement as a model body** — that violates dbt's contract and the compile step fails. If you genuinely need a raw `UPDATE ...` or `DELETE FROM ...` (not wrappable as a MERGE — e.g., the hard-delete row in §4.6A.4 below), put the DML in a **`post_hook`** on Model 1, a **`dbt run-operation`** macro, or a dedicated **operation file** in `macros/` — NOT in a model body. See §4.6A.4 row 4 + the dbt-framing note immediately below it for the canonical hard-delete recipe.

**Why this is the default:**
- **Two distinct MERGEs compile to two distinct Trino statements** — each owns exactly one of Oracle's three branches (MATCHED, NOT MATCHED, NOT MATCHED BY SOURCE), making the migration auditable branch-by-branch.
- **Idempotent and reviewable** — a code reviewer can read Model 1 ("upsert from source") and Model 2 ("soft-delete the missing") independently. The intent of each model is one sentence.
- **Testable independently** — `dbt test` can verify each model's contract: Model 1 has zero rows with `deleted_at IS NOT NULL`; Model 2 only writes to rows where the customer_id is missing from the source. Each test is one selector.
- **No correlated-subquery decorrelation risk** — Model 2 uses `NOT EXISTS` against a CTE, which Trino's optimizer reliably decorrelates into a SemiJoin (see resource 22 §13.6 and resource 28).
- **No three-valued-logic footgun** — `NOT EXISTS` is NULL-safe by construction (see §4.6A.3).

#### 4.6A.2 The FALLBACK (single-model UNION-ALL) pattern — use only with the caveats below

A single-model alternative exists: write one incremental model whose SELECT is `UNION ALL` of (a) the upserted source rows and (b) a soft-delete branch that finds target rows missing from source. This **CAN** work, but it is a FALLBACK — only choose it if there is a concrete reason the two-model decomposition is unacceptable (e.g., strict DAG-node-count limits, an existing audit framework that expects one model per fact table, or a materialization-cost analysis that shows the second model is prohibitive). The caveats below are not optional.

```sql
-- models/marts/fct_customers__single_model.sql
-- FALLBACK pattern — see caveats in §4.6A.2 before using.
{{ config(
    materialized = 'incremental',
    incremental_strategy = 'merge',
    unique_key = 'customer_id'
) }}

WITH live_in_source AS (
    SELECT DISTINCT customer_id, email, plan, updated_at
    FROM {{ ref('stg_customers') }}
)
-- Branch A: upsert from source (the WHEN MATCHED / WHEN NOT MATCHED halves)
SELECT
    customer_id,
    email,
    plan,
    updated_at,
    CAST(NULL AS TIMESTAMP) AS deleted_at     -- typed NULL — §4.4A
FROM live_in_source

UNION ALL

-- Branch B: stamp deleted_at on target rows missing from source.
-- Re-emits the row with deleted_at filled so the MERGE on unique_key=customer_id
-- updates the target row's deleted_at.
SELECT
    t.customer_id,
    t.email,
    t.plan,
    t.updated_at,
    CURRENT_TIMESTAMP AS deleted_at
FROM {{ this }} t
WHERE t.deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM live_in_source s WHERE s.customer_id = t.customer_id
  )
```

**FALLBACK caveats — read these BEFORE choosing this pattern:**

1. **Use `NOT EXISTS`, NEVER `NOT IN`.** The "missing in source" predicate MUST be `NOT EXISTS (SELECT 1 FROM live_in_source s WHERE s.customer_id = t.customer_id)`. If you write `WHERE t.customer_id NOT IN (SELECT customer_id FROM live_in_source)` and `live_in_source.customer_id` contains a single NULL, **`NOT IN` returns UNKNOWN for every row in the target, which is filtered out the same as FALSE — so the soft-delete branch emits ZERO rows and silently no-ops**. See §4.6A.3 for the full three-valued-logic walkthrough. This is the most common copy-paste failure in this pattern.

2. **Correlated-subquery decorrelation risk.** Branch B references `{{ this }}` and uses a correlated `NOT EXISTS` against `live_in_source`. Trino's optimizer attempts to decorrelate the correlation into a SemiJoin (the `RelationalExpressionDecorrelation` rule). **Decorrelation can fail on Iceberg-backed sources** when the correlated subquery has side conditions or when the source CTE has type mismatches — you then get a `CorrelatedJoin` operator in EXPLAIN, which executes per-target-row and is catastrophically slow. **Always EXPLAIN this branch before shipping**; if you see `CorrelatedJoin`, fall back to the two-model decomposition in §4.6A.1.

3. **One MERGE statement, two semantic branches** — code reviews are harder. The single `UNION ALL` SELECT mixes "upsert from source" and "stamp deleted_at on missing" into one model, but they're two distinct intents. A future maintainer changing branch A's filters risks accidentally narrowing the missing-in-source set in branch B.

4. **Materialization cost is comparable, not lower.** Both patterns scan the source once and the target once. The two-model pattern compiles to two MERGE statements; the single-model pattern compiles to one MERGE whose SELECT contains a UNION ALL. **There is no Trino-side performance advantage to the single-model form** in the common case — the only theoretical saving is avoiding writing the intermediate result twice, which Iceberg snapshot semantics make negligible (each MERGE is its own atomic snapshot; coalescing them does not reduce I/O).

5. **DO NOT use a `WHERE customer_id NOT IN (subquery)` filter against the live source on an Iceberg-backed source if you've ever seen NULLs in customer_id.** This is a special case of (1) but applies even when the column is "supposed to be" NOT NULL — bad ingestion data is exactly when soft-delete logic matters most, and a single bad NULL converts the soft-delete branch into a silent no-op for the entire run.

#### 4.6A.3 Why `NOT EXISTS` over `NOT IN` — the three-valued-logic footgun

**The rule:** when the subquery in the `NOT (...)` predicate could contain NULL, **`NOT IN` returns UNKNOWN for every outer row, which a `WHERE` clause filters out the same as FALSE — and your "missing in source" set silently becomes empty.**

```sql
-- WRONG — three-valued-logic footgun on NOT IN
-- If live_in_source.customer_id contains even one NULL,
-- the entire branch returns zero rows. Soft-delete silently no-ops.
SELECT *
FROM fct_customers t
WHERE t.customer_id NOT IN (
    SELECT customer_id FROM stg_customers
);
```

Mechanics: `NOT IN (..., NULL, ...)` is equivalent to `customer_id <> v1 AND customer_id <> v2 AND ... AND customer_id <> NULL`. The final `customer_id <> NULL` clause evaluates to UNKNOWN; the AND-chain short-circuits to UNKNOWN; the `WHERE` clause excludes the row. **Every** outer row is excluded — not just the one with the NULL. The soft-delete branch becomes a silent no-op.

```sql
-- CORRECT — NOT EXISTS is NULL-safe by construction
SELECT *
FROM fct_customers t
WHERE NOT EXISTS (
    SELECT 1 FROM stg_customers s WHERE s.customer_id = t.customer_id
);
```

Mechanics: `NOT EXISTS` is binary (the subquery either has a matching row or it does not). NULL columns in the subquery cannot trigger UNKNOWN — they just don't match the correlation predicate `s.customer_id = t.customer_id` (which is itself UNKNOWN, treated as no-match). Trino decorrelates this into a SemiJoin reliably (`LeftSemiHashJoin` in EXPLAIN). Alternative equivalent forms:

```sql
-- Equally NULL-safe — anti-join via LEFT JOIN + IS NULL on the right side
SELECT t.*
FROM fct_customers t
LEFT JOIN stg_customers s ON s.customer_id = t.customer_id
WHERE s.customer_id IS NULL;
```

Both `NOT EXISTS` and `LEFT JOIN ... WHERE rhs IS NULL` are the recommended Trino forms. **Never write `NOT IN` against a subquery in a Trino-targeted dbt model** unless you have a strict `NOT NULL` constraint on the inner column AND a dbt test enforcing it — and even then, prefer `NOT EXISTS` for code-review clarity.

#### 4.6A.4 Summary — the migration decision table

| Oracle source | Trino + dbt translation | Notes |
|---|---|---|
| `MERGE ... USING src ON t.id = s.id WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT ...` (no soft-delete branch) | **Single dbt incremental model**, `incremental_strategy='merge'`, `unique_key='id'`. | Vanilla MERGE — covered in §4.6 row 1. |
| `MERGE ... WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT ... WHEN NOT MATCHED BY SOURCE THEN UPDATE SET deleted_at = SYSDATE` | **TWO dbt models** (§4.6A.1, DEFAULT). Model 1 = the upsert MERGE. Model 2 = the soft-delete MERGE using `NOT EXISTS` against the live source set. | Trino has NO `WHEN NOT MATCHED BY SOURCE` — verified [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html). |
| Same Oracle source, but DAG-node-count or audit-framework constraints preclude two models | **Single-model UNION ALL** (§4.6A.2, FALLBACK). MUST use `NOT EXISTS`. MUST EXPLAIN-check for `CorrelatedJoin`. | Caveats are not optional — see §4.6A.2 list of 5 caveats. |
| `MERGE ... WHEN NOT MATCHED BY SOURCE THEN DELETE` (hard delete instead of soft) | **Model 1 = upsert (incremental MERGE dbt model, as above). Model 2 = the raw `DELETE FROM fct_customers WHERE NOT EXISTS (SELECT 1 FROM stg_customers s WHERE s.customer_id = fct_customers.customer_id)` runs as a `post_hook` on Model 1, or as a `dbt run-operation` macro, or as a dedicated operation file — NOT as a dbt model body.** See the dbt-framing note below this table for the literal recipe. | Hard-delete via DELETE has no `deleted_at` to fill, but it CANNOT be a dbt model body because dbt model bodies are SELECT-only — DML belongs in a hook / operation. |

> **dbt-framing note for raw UPDATE / DELETE DML (read this before writing any soft-delete or hard-delete Model 2).** Per [docs.getdbt.com/docs/build/models](https://docs.getdbt.com/docs/build/models), **every dbt model body is a SELECT statement** — dbt's materialization config wraps that SELECT as a `CREATE TABLE AS`, `CREATE OR REPLACE TABLE`, `INSERT INTO`, or `MERGE INTO` (depending on `materialized` + `incremental_strategy`). You do NOT write a literal `UPDATE` or `DELETE` as a model body — dbt's compile step does not produce raw DML. The three correct places for raw `UPDATE` / `DELETE` DML in dbt:
>
> 1. **`post_hook` on a model** — runs AFTER the model's MERGE/CTAS commits. Best when the DML is logically coupled to the model's success.
>    ```sql
>    -- models/marts/fct_customers__upsert.sql (Model 1 with hard-delete post_hook)
>    {{ config(
>        materialized = 'incremental',
>        incremental_strategy = 'merge',
>        unique_key = 'customer_id',
>        post_hook = [
>          "DELETE FROM {{ this }} WHERE NOT EXISTS (SELECT 1 FROM {{ ref('stg_customers') }} s WHERE s.customer_id = {{ this }}.customer_id)"
>        ]
>    ) }}
>    SELECT customer_id, email, plan, updated_at FROM {{ ref('stg_customers') }}
>    {% if is_incremental() %} WHERE updated_at > (SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01') FROM {{ this }}) {% endif %}
>    ```
>
> 2. **`dbt run-operation` macro** — runs ad-hoc or on-schedule independent of the DAG. Best when the DML is a periodic maintenance step (e.g., nightly purge) decoupled from any specific model.
>    ```jinja
>    -- macros/hard_delete_missing_customers.sql
>    {% macro hard_delete_missing_customers() %}
>      {% set sql %}
>        DELETE FROM {{ ref('fct_customers__upsert') }} t
>        WHERE NOT EXISTS (
>          SELECT 1 FROM {{ ref('stg_customers') }} s
>          WHERE s.customer_id = t.customer_id
>        )
>      {% endset %}
>      {% do run_query(sql) %}
>    {% endmacro %}
>    ```
>    Invoke from the schedule with `dbt run-operation hard_delete_missing_customers`.
>
> 3. **Dedicated operation file** referenced via `on-run-end` in `dbt_project.yml` — runs at the end of every `dbt run`. Same shape as the macro above; the difference is invocation cadence.
>
> **What you DO NOT do.** A file named `models/fct_customers__hard_delete.sql` containing only `DELETE FROM fct_customers WHERE NOT EXISTS (...)` will fail at dbt compile time with a parser error (dbt expects a SELECT, finds DELETE). This is the load-bearing framing slip the responder must avoid when migrating an Oracle hard-delete-via-MERGE pattern. The soft-delete pattern in §4.6A.1 Model 2 is NOT affected because soft-delete is an UPDATE-on-MERGE that dbt's `incremental_strategy='merge'` produces correctly from a SELECT body — only the **hard-delete via raw DELETE** needs the hook / operation framing.

**Cross-references.**
- §4.4A — typed NULL syntax (`CAST(NULL AS TIMESTAMP)`, NOT `NULL::TIMESTAMP`) — used in every soft-delete model above.
- Resource 22 §13.6 — Trino SemiJoin decorrelation of `IN` and `EXISTS`.
- Resource 28 — correlated-subquery rewrite patterns when EXPLAIN shows `CorrelatedJoin`.
- [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html) — official Trino MERGE grammar (only `WHEN MATCHED` and `WHEN NOT MATCHED` clauses; no `BY SOURCE` variant).

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

## dbt connection & secrets — profiles.yml, env_var(), DBT_ENV_SECRET_ (store the Trino password as a shell env var, NOT plaintext)

> **READ THIS FIRST if your question contains ANY of these phrases:** `dbt profiles.yml`, `profiles.yml password`, `dbt password`, `dbt database password`, `dbt connection`, `dbt connection credentials`, `dbt credentials`, `store dbt password safely`, `hide dbt password`, `keep dbt password out of logs`, `dbt secrets`, `dbt secret`, `dbt environment variable`, `read shell env var into dbt`, `dbt env var`, `env_var profiles.yml`, `env_var Trino`, `DBT_ENV_SECRET`, `DBT_ENV_SECRET_ prefix`, `scrub secret from dbt logs`, `mask password in dbt logs`. This is a **dbt OPS** topic and the canonical lives in this file even though the file title says "Oracle migration" — the dbt-trino connection setup is the same for ALL dbt-trino projects on this stack, migration or not.

### LEADING CANONICAL — dbt profiles.yml + env_var() — read the Trino password from a shell env var (not plaintext)

> **Keyword anchors:** dbt env_var, env_var profiles.yml, dbt password profiles.yml, store dbt password safely, dbt connection credentials, dbt database password, read shell env var dbt, dbt environment variable, dbt secrets, hide dbt password, keep dbt password out of logs, profiles.yml Trino target, dbt connect to Trino. Verified at [docs.getdbt.com/reference/dbt-jinja-functions/env_var](https://docs.getdbt.com/reference/dbt-jinja-functions/env_var) and [docs.getdbt.com/docs/build/environment-variables](https://docs.getdbt.com/docs/build/environment-variables).

**The one-fact summary.** `env_var('DBT_XYZ')` reads SHELL env var `DBT_XYZ` at **parse time**; `env_var('DBT_XYZ', 'default')` returns the fallback if unset. **Without a default, an unset var ERRORS the parse — fail-fast** (good for required credentials). Works in `dbt_project.yml`, **`profiles.yml`** (the canonical home for warehouse credentials), `sources.yml`, `schema.yml`, and model SQL.

**Secrets pattern.** Keep secrets in shell env vars (or a CI/CD secret store, or a k8s Secret mounted as env) and read via `env_var()` — **NEVER hardcode the password in the repo**. Canonical `profiles.yml` (Trino target):

```yaml
my_project:
  target: prod
  outputs:
    prod:
      type: trino
      host: trino.internal
      user: "{{ env_var('TRINO_USER') }}"
      password: "{{ env_var('DBT_ENV_SECRET_TRINO_PASSWORD') }}"
      catalog: iceberg
      schema: analytics
```

Then in the shell / CI runner / k8s pod, export the secret BEFORE running dbt:
```bash
export DBT_ENV_SECRET_TRINO_PASSWORD='real-password-here'
dbt run --profiles-dir ~/.dbt
```

### DBT_ENV_SECRET_ — auto-scrub secrets from dbt logs

**`DBT_ENV_SECRET_` prefix convention** (verbatim from docs): *"Any env var named with the prefix `DBT_ENV_SECRET` will be: Available for use in `profiles.yml` + `packages.yml`, via the same `env_var()` function; Disallowed everywhere else, including `dbt_project.yml` and model SQL, to prevent accidentally writing these secret values to the data warehouse or metadata artifacts; **Scrubbed from dbt logs and replaced with `*****`, any time its value appears in those logs** (even if the env var was not called directly)."*

What this means in practice:
- A var named `DBT_ENV_SECRET_TRINO_PASSWORD` can be read in `profiles.yml` and `packages.yml` ONLY.
- The literal password value is **automatically masked as `*****`** anywhere it appears in dbt logs / error messages — even if a downstream library accidentally prints it.
- Trying to read a `DBT_ENV_SECRET_*` var from `dbt_project.yml` or a model `.sql` file raises a dbt error — by design, to prevent leaking the value into compiled SQL artifacts (`target/compiled/**`) or warehouse metadata (object comments, query history).
- **You cannot compose secrets**: dbt allows only one `DBT_ENV_SECRET_*` per configuration value, and you cannot pass a secret through Jinja filters (`as_number`, `as_bool`, etc.) or as a macro argument.

**`env_var()` vs `var()` — read this carefully (cross-ref §6.7G):**

| Function | Source | Use it for |
|---|---|---|
| **`var('name', default)`** | dbt's **per-run** config (CLI `--vars` + `dbt_project.yml` `vars:`) | Per-run tunable knobs (lookback days, mode flags, backfill window). |
| **`env_var('NAME', 'default')`** | **SHELL environment** (process env, CI/CD secret store, k8s Secret mounted as env) | Secrets (passwords, tokens) AND env-specific connection params (host, catalog, schema per dev/staging/prod). |

**DO-NOT-WRITE — banned patterns:**

| DO NOT write | Why it's wrong |
|---|---|
| `dbt run --vars '{api_key: "'$SECRET'"}'` (shell substitution to inject a secret) | **LEAKS the secret** — the expanded value appears in `ps`, shell history, and CI logs. Use `env_var('DBT_ENV_SECRET_API_KEY')` in the model/profile instead so the literal never reaches `argv`. |
| `password: "supers3cret"` hardcoded in `profiles.yml` or `dbt_project.yml` | Committed-secret antipattern. Use `password: "{{ env_var('DBT_ENV_SECRET_TRINO_PASSWORD') }}"`. |
| `password: "{{ env_var('PASSWORD') }}"` inside a **model `.sql` file** to read a `DBT_ENV_SECRET_*` var | dbt **disallows** `DBT_ENV_SECRET_*` outside `profiles.yml` / `packages.yml` — that's by design (prevents leakage into compiled artifacts). |
| `env_var('TRINO_PASSWORD', 'changeme')` — supplying a fake default for a REQUIRED credential | Silently lets dbt run with a wrong cred. **For required secrets, OMIT the default** so dbt parse-errors fast on a missing env var. |
| Reading a `DBT_ENV_SECRET_*` var and passing it through `\| as_number` / `\| as_bool` / a macro arg | dbt disallows transforming or composing secrets. Use the secret directly in a single configuration value. |

**Cross-references.** §6.7G (`var()` for per-run knobs — the sibling mechanism). §6.7H (dbt-docs site — note: `env_var()` values are read at parse time, so the *expanded* host/schema show up in docs unless they are `DBT_ENV_SECRET_*`). §6.7 routing anchor (full Q-keyword → canonical map for dbt-OPS questions).

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
      'format': "'PARQUET'",
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

> **ROUTING ANCHOR — dbt OPS / CONFIG / CONNECTION / SECRETS questions land in this §6.7 cluster (even though this file is titled "Oracle PL/SQL → dbt+Trino migration"). If your question contains ANY of these phrases, jump to the listed sub-canonical:**
>
> | Question keywords | Canonical |
> |---|---|
> | `dbt profiles.yml`, `profiles.yml password`, `dbt password`, `dbt connection`, `dbt connection credentials`, `dbt database password`, `store dbt password safely`, `hide dbt password`, `keep dbt password out of logs`, `read shell env var into dbt`, `dbt environment variable`, `env_var`, `DBT_ENV_SECRET`, `dbt secrets`, `scrub secret from dbt logs`, `dbt credentials` | **"dbt connection & secrets" section ABOVE §6** (a dedicated H2, just before §6 "Worked end-to-end example") — `env_var()` + `DBT_ENV_SECRET_` + canonical `profiles.yml` Trino target |
> | `dbt var`, `dbt --vars`, `dbt run --vars`, `parameterize dbt model`, `dbt variable`, `var vs set dbt`, `tunable knob dbt`, `dbt_project.yml vars:` | **§6.7G** (`var()` per-run configurable values) |
> | `dbt test severity`, `severity: warn`, `store_failures`, `_dbt_test__audit`, `expression_is_true`, `not_null_proportion` | **§6.7A** (dbt test severity + store_failures) |
> | `dbt ref()`, `dbt source()`, `ref vs source`, `DAG edge`, `compile to fully-qualified name`, `manifest.json` | **§6.7A2** (`ref()` vs `source()`) |
> | `dbt source freshness`, `sources.yml loaded_at_field`, `dbt source freshness command` | **§6.7B** + **§6.7K** (source freshness + freshness commands) |
> | `dbt model contract`, `contract: enforced`, `dbt column data_type` | **§6.7C** (model contracts) |
> | `dbt seed`, `seeds/ CSV`, `dbt seed command` | **§6.7D** (seeds) |
> | `dbt unit test`, `dbt unit_tests:`, `given:` `expect:` | **§6.7E** (unit tests 1.8+) |
> | `dbt --select`, `dbt graph operators`, `+` `@` `:` selectors | **§6.7F** (select set-operators + graph-operators) |
> | `dbt docs generate`, `dbt docs serve`, `description: schema YAML`, `{% docs %}` blocks | **§6.7H** (dbt documentation site) |
> | `dbt grants:`, `dbt post_hook GRANT`, `dbt-trino roles bug` | **§6.7I** (dbt grants) |
> | `dbt persist_docs`, `COMMENT ON TABLE from dbt` | **§6.7J** (persist_docs) |
> | `dbt materialization`, `incremental`, `unique_key`, `is_incremental()` | **§6.8** (`is_incremental()` WHERE-clause pattern) + **§3.1** (materializations) |
>
> A "how do I configure dbt to connect to Trino?" or "where do I put my dbt password safely?" question is a **dbt OPS** question — answered in the **"dbt connection & secrets — profiles.yml, env_var(), DBT_ENV_SECRET_"** section that sits ABOVE §6 in this file (search for the H2 header `dbt connection & secrets`). The fact that this resource file is titled "Oracle migration" does NOT mean the dbt-ops canonicals here are migration-only; they apply to ALL dbt-trino setups on this stack.

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

### 6.7A LEADING CANONICAL — dbt test severity, store_failures, expression_is_true vs not_null_proportion

> **READ THIS FIRST if your question contains any of these keywords: `severity`, `severity: warn`, `store_failures`, `store_failures_as`, `_dbt_test__audit`, `expression_is_true`, `not_null_proportion`, `at_least`, `null proportion threshold`, `warn on test failure`, `dbt test schema`, `where do failed rows go`, `dbt test warning`, `aggregate test`.** This block is the canonical reference for dbt test severity and failure-storage configuration on this stack. All claims below are verified at [docs.getdbt.com/reference/resource-configs/severity](https://docs.getdbt.com/reference/resource-configs/severity), [docs.getdbt.com/reference/resource-configs/store_failures](https://docs.getdbt.com/reference/resource-configs/store_failures), [github.com/dbt-labs/dbt-utils — expression_is_true.sql](https://github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/expression_is_true.sql), and [github.com/dbt-labs/dbt-utils — not_null_proportion.sql](https://github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/not_null_proportion.sql).

**Q-PATTERN MATCHER.** Use this table to route to the right answer paragraph below.

| If the question is... | Answer in one line | Detail in this section |
|---|---|---|
| "How do I make a test warn instead of fail?" | Add `config: severity: warn` to the test. The pipeline continues; dbt prints a WARNING instead of erroring out. | § severity: warn vs error |
| "Where does dbt store failing rows when I use store_failures?" | In a schema named `<your_target_schema>_dbt_test__audit` (e.g. `analytics_dbt_test__audit`). NOT `dbt_internal`. | § store_failures schema location |
| "How do I test that less than 5% of rows are null in a column?" | Use `dbt_utils.not_null_proportion: at_least: 0.95`. Do NOT use `expression_is_true` with COUNT — that is a SQL error at runtime. | § null-proportion threshold: not_null_proportion |
| "What can I put in expression_is_true's expression?" | Only a **per-row boolean**: `>= 0`, `!= ''`, `IN ('A','B','C')`, `IS NOT NULL`. Never an aggregate function (COUNT, SUM, AVG) — that generates invalid SQL. | § expression_is_true is row-level only |
| "How do I test my model's TRANSFORMATION LOGIC on MOCK input rows (given/expect)?" | That's a dbt **UNIT TEST** (different mechanism from data tests). See §6.7E for the `unit_tests:` / `given:` / `expect:` YAML schema. DO-NOT-CONFUSE: data tests (this §6.7A) = assertions on REAL warehouse output; unit tests (§6.7E) = assertions on MOCK input. | See [§6.7E LEADING CANONICAL — dbt UNIT TESTS](#67e-leading-canonical--dbt-unit-tests-18--testing-model-logic-on-mock-input-unit_tests-with-given--expect) |

#### severity: warn vs error

`severity` is a test config key that controls what happens when the test finds failures:

- **`severity: error`** (default) — test failure exits `dbt test` / `dbt build` non-zero; the pipeline halts. Use for hard data-quality guarantees.
- **`severity: warn`** — test failure emits a WARNING and the pipeline **continues**. Use for soft thresholds: you want visibility into bad data without blocking the build.

Per-test YAML:

```yaml
# models/marts/fct_orders.yml
models:
  - name: fct_orders
    columns:
      - name: discount_pct
        data_tests:
          - not_null:
              config:
                severity: warn       # warns if any NULL; build continues
```

Project-wide default (every test in this project warns instead of errors):

```yaml
# dbt_project.yml
data_tests:
  +severity: warn
```

**How dbt evaluates test result mechanics — read this BEFORE writing `warn_if` / `error_if`.** A dbt generic/data test compiles to a SELECT that returns the **failing rows** (e.g. `not_null` compiles to `SELECT * FROM <model> WHERE <col> IS NULL`; `unique` to a `GROUP BY <col> HAVING COUNT(*) > 1` shape). **The test PASSES if zero failing rows are returned; it FAILS if any row comes back.** dbt then takes the **count of failing rows** in that result set and compares it against the `warn_if` / `error_if` thresholds. Verbatim from [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests): *"If the data test returns zero failing rows, it passes, and your assertion has been validated."* Verbatim from [docs.getdbt.com/reference/resource-configs/severity](https://docs.getdbt.com/reference/resource-configs/severity): *"Tests return a number of failures—most often, this is the count of rows returned by the test query."* This is **NOT** a `SELECT 1 ... LIMIT 1` existence check — if it were, thresholds like `error_if: ">100"` would be meaningless. The threshold expression is an integer comparison against the failing-row count, which is why `error_if: ">100"` / `warn_if: ">0"` works.

Fine-grained `warn_if` + `error_if` (warn on 1-99 bad rows, error on 100+):

```yaml
- unique:
    config:
      severity: error
      error_if: ">100"
      warn_if: ">0"
```

The condition uses standard comparison operators (`>N`, `>=N`, `=N`, `!=N`, `between N and M`) — any SQL-supported integer-comparison form against the failing-row count. Default for both `warn_if` and `error_if` is `!=0` (which means: warn or error if ANY failing row is returned). With `severity: error`, dbt checks `error_if` first; if it matches → ERROR. If it doesn't match, dbt checks `warn_if`; if it matches → WARN. If neither matches → PASS. With `severity: warn`, dbt skips `error_if` entirely.

#### store_failures schema location

When `store_failures: true`, dbt materializes the failing rows into a table (or view) in a separate schema so you can query them directly after a test run.

**Default schema name: `<target_schema>_dbt_test__audit`**

If your `profiles.yml` target schema is `analytics`, dbt writes failure rows to `analytics_dbt_test__audit`. If your target schema is `dev_alice`, failures go to `dev_alice_dbt_test__audit`. The suffix `_dbt_test__audit` is always appended to the target schema name.

```yaml
models:
  - name: fct_orders
    columns:
      - name: discount_pct
        data_tests:
          - dbt_utils.expression_is_true:
              expression: ">= 0"
              config:
                store_failures: true     # failing rows saved to analytics_dbt_test__audit
                severity: warn           # warn but continue; can combine with store_failures
```

After running `dbt test`, query the failures:

```sql
-- in Trino/SQL client: replace with your actual target schema
SELECT * FROM analytics_dbt_test__audit.fct_orders_expression_is_true_discount_pct_____0;
```

**Configuring `store_failures_as`** — controls whether failures land as a `table` (persists across runs) or `view` (recalculated each query):

```yaml
- not_null:
    config:
      store_failures_as: table   # or 'view' or 'ephemeral' (default = ephemeral = not stored)
```

`store_failures_as` takes precedence over the older `store_failures: true` boolean when both are present.

**Configure the schema suffix** via `+schema:` under `data_tests:` in `dbt_project.yml` if you want a custom name:

```yaml
# dbt_project.yml
data_tests:
  +store_failures: true
  +schema: test_audit_custom    # results in <target_schema>_test_audit_custom
```

#### null-proportion threshold: not_null_proportion

**"Warn if more than 5% of values in `email` are NULL"** is a THRESHOLD test — it compares an AGGREGATE proportion against a boundary. The correct tool is `dbt_utils.not_null_proportion`.

`dbt_utils.not_null_proportion` computes `SUM(CASE WHEN col IS NULL THEN 0 ELSE 1 END) / COUNT(*)` at the aggregate level and compares it to `at_least`. It is purpose-built for this use case.

```yaml
# models/marts/fct_orders.yml
models:
  - name: fct_orders
    columns:
      - name: email
        data_tests:
          - dbt_utils.not_null_proportion:
              at_least: 0.95          # at least 95% of rows must be non-null
              config:
                severity: warn        # warn if proportion drops below 0.95; build continues
      - name: customer_id
        data_tests:
          - dbt_utils.not_null_proportion:
              at_least: 1.0           # zero NULLs tolerated (equivalent to not_null but with proportion semantics)
```

Optional `at_most` (default `1.0`) caps an upper bound — rarely needed.

#### expression_is_true is row-level only

`dbt_utils.expression_is_true` generates this SQL at runtime:

```sql
SELECT 1 FROM {{ model }}
WHERE NOT ( {{ column_name }} {{ expression }} )
```

The `WHERE NOT (...)` clause is evaluated **per row**. It is a row-filter, not an aggregate. This means:

- **VALID expressions**: `>= 0`, `<= 100`, `!= ''`, `IN ('active', 'inactive')`, `IS NOT NULL`, `BETWEEN 0 AND 1`
- **INVALID expressions (SQL error at runtime)**: `COUNT(*) FILTER (WHERE ...) / COUNT(*) < 0.05`, `AVG(amount) > 0`, `SUM(amount) >= 0` — aggregate functions cannot appear in a `WHERE` clause without a `GROUP BY + HAVING`. Running this generates a SQL execution error against Trino.

Correct use — per-row business-rule assertion:

```yaml
# models/marts/fct_orders.yml
models:
  - name: fct_orders
    columns:
      - name: discount_pct
        data_tests:
          - dbt_utils.expression_is_true:
              expression: ">= 0"           # per-row: every row's discount_pct must be >= 0
              config:
                severity: warn
      - name: status
        data_tests:
          - dbt_utils.expression_is_true:
              expression: "IN ('pending', 'confirmed', 'shipped', 'cancelled')"
```

Wrong — aggregate in row-level expression (SQL error):

```yaml
# DO NOT write this — generates WHERE NOT (COUNT(*) FILTER ... / COUNT(*) < 0.05) = SQL error
- dbt_utils.expression_is_true:
    expression: "COUNT(*) FILTER (WHERE discount_pct IS NULL)/COUNT(*) < 0.05"
# DO NOT write this either — AVG is an aggregate, invalid in WHERE clause
- dbt_utils.expression_is_true:
    expression: "AVG(amount) > 0"
```

For aggregate-level thresholds, use `dbt_utils.not_null_proportion` (see above).

#### accepted_values — compiled SQL and the `quote: false` gotcha for numeric/boolean columns

`accepted_values` compiles to roughly `SELECT <col> FROM <model> WHERE <col> NOT IN ('v1', 'v2', ...) [AND <col> IS NOT NULL]` — **rows returned = failures; zero rows = pass** (same pass/fail convention as every other dbt generic test). The values list is single-quoted by default. Verbatim from [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests): *"The `accepted_values` test supports an optional `quote` parameter which, by default, will single-quote the list of accepted values in the test query. To test non-strings (like integers or boolean values) explicitly set the `quote` config to `false`."* So for numeric or boolean columns, omitting `quote: false` makes dbt emit `WHERE status_id NOT IN ('1', '2', '3', '4')` — Trino will silently or noisily mis-compare depending on type-coercion rules, and the test result is unreliable. The fix is one line:

```yaml
- name: status_id   # INTEGER column
  data_tests:
    - accepted_values:
        values: [1, 2, 3, 4]
        quote: false        # emit NOT IN (1, 2, 3, 4) — no quotes around integers
```

#### DO-NOT-WRITE — banned dbt-test claims (cite-or-omit)

| DO NOT write | Why it's wrong |
|---|---|
| `expression: "COUNT(*) FILTER (WHERE col IS NULL)/COUNT(*) < 0.05"` inside `expression_is_true` | **SQL ERROR at runtime.** `expression_is_true` generates `WHERE NOT (...)` — a row-level filter. COUNT is an aggregate; it cannot appear in a WHERE clause. Use `dbt_utils.not_null_proportion: at_least: 0.95` instead. Confirmed via [github.com/dbt-labs/dbt-utils expression_is_true.sql](https://github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/expression_is_true.sql). |
| `expression: "AVG(amount) > 0"` inside `expression_is_true` | **Same class — aggregate in row-level WHERE clause = SQL error.** AVG, SUM, MIN, MAX, COUNT are all illegal here. |
| `dbt_internal.<model>_<test>` as the store_failures schema | **FABRICATED schema name.** `dbt_internal` does not exist in dbt's store_failures implementation. The correct default is `<target_schema>_dbt_test__audit`. Confirmed via [docs.getdbt.com/reference/resource-configs/store_failures](https://docs.getdbt.com/reference/resource-configs/store_failures). |
| "store_failures writes to `dbt_tests` schema" | **WRONG.** The schema is `<target_schema>_dbt_test__audit`. There is no `dbt_tests` schema in dbt's implementation. |
| `severity: 'warning'` or `severity: 'fail'` | **Wrong values.** The only valid values are `severity: warn` and `severity: error`. No quotes needed in YAML; `warning` and `fail` are not valid. |
| `store_failures_as: 'permanent'` | **FABRICATED option.** Valid options are `table`, `view`, `ephemeral`. |

#### Cross-references

- For the dbt tests that pair with model contracts (§6.7C): uniqueness tests + `expression_is_true` on business rules supplement the NOT NULL contract enforcement that dbt-trino supports natively.
- For `dbt_utils.unique_combination_of_columns` (used in §6.7): a model-level test for composite-key uniqueness, distinct from the column-level tests described here.
- Official docs: [docs.getdbt.com/reference/resource-configs/severity](https://docs.getdbt.com/reference/resource-configs/severity), [docs.getdbt.com/reference/resource-configs/store_failures](https://docs.getdbt.com/reference/resource-configs/store_failures), [github.com/dbt-labs/dbt-utils README](https://github.com/dbt-labs/dbt-utils?tab=readme-ov-file#not_null_proportion-source).

---

### 6.7A2 LEADING CANONICAL — dbt `ref()` vs `source()` — the DAG-edge behavioral difference (NOT just a naming convention)

> **READ THIS FIRST if your question contains any of these keywords: `dbt ref vs source`, `ref source difference`, `dbt DAG edge`, `source freshness entry point`, `when to use ref source`, `dbt dependency graph`, `dbt model vs source`, `stg_ FROM source`, `raw table dbt`, `hardcode table name dbt`.** Verified at [docs.getdbt.com/reference/dbt-jinja-functions/ref](https://docs.getdbt.com/reference/dbt-jinja-functions/ref) and [docs.getdbt.com/reference/dbt-jinja-functions/source](https://docs.getdbt.com/reference/dbt-jinja-functions/source) on 2026-06-06.

**The one-fact summary.** `ref()` references **another dbt MODEL** (a `.sql` file dbt builds) — it creates a DAG edge so dbt builds the upstream model first AND resolves the deployed relation name per target/schema. `source()` references a **RAW EXTERNAL input** declared in a `sources:` YAML — dbt does NOT build it (it's the graph's entry point), and `source()` unlocks `dbt source freshness` checks (see §6.7B / §6.7K) plus lineage. **This is a behavioral difference, NOT a naming convention.**

| Jinja call | Refers to | Built by dbt? | Creates DAG edge? | Enables `dbt source freshness`? |
|---|---|---|---|---|
| `{{ ref('model_name') }}` | Another dbt **MODEL** (a `.sql` file in `models/`) | **Yes** — dbt builds upstream model first | **Yes** — model-to-model dependency | No |
| `{{ source('source_name', 'table_name') }}` | A raw external **TABLE** declared in a `sources:` YAML | **No** — source is the graph's entry point | **Yes** — source-to-model dependency | **Yes** — required for the `freshness:` block |

**The standard project rule.** Staging models (`models/staging/stg_*.sql`) select `FROM {{ source('app', 'orders') }}` — they are the ONLY layer that touches raw landing tables. Everything downstream (intermediate, marts) uses `{{ ref('stg_orders') }}` / `{{ ref('int_*') }}` / `{{ ref('dim_*') }}` / `{{ ref('fct_*') }}` — never another raw table name. This keeps the DAG accurate and gives you a single chokepoint (the `stg_` layer) where the raw-input shape is named.

**Worked example.** Given `models/_sources.yml`:

```yaml
sources:
  - name: app
    database: postgresql           # the Trino catalog name on this stack
    schema:   public
    tables:
      - name: orders
        loaded_at_field: ingested_at
```

```sql
-- models/staging/stg_orders.sql -- raw layer reads from source()
SELECT order_id, customer_id, amount, ingested_at
FROM {{ source('app', 'orders') }}                   -- DAG entry-point; freshness-checkable

-- models/marts/fct_orders.sql -- downstream reads from ref()
SELECT * FROM {{ ref('stg_orders') }}                -- DAG edge: fct_orders depends on stg_orders
```

**The Jinja docs verbatim.** `ref()` *"creates dependencies between the referenced node and the current model"* AND *"is using these references between models to automatically build the dependency graph. This will enable dbt to deploy models in the correct order when using `dbt run`."* `source()` *"creates dependencies between a source and the current model, which is useful for documentation and node selection"* (and is the only way to unlock `dbt source freshness`).

> **DO NOT WRITE.**
> 1. **`{{ ref('raw_orders_landing_table') }}`** when the target is a RAW external table (not a dbt model) — `ref()` requires the argument to resolve to a dbt-managed `.sql` model file. Use `{{ source('app', 'orders') }}` for raw inputs.
> 2. **`{{ source('jaffle_shop', 'stg_orders') }}`** for a dbt MODEL — sources are by definition NOT built by dbt; pointing `source()` at a dbt model breaks lineage and disables freshness checks. Use `{{ ref('stg_orders') }}`.
> 3. **Hardcode `FROM iceberg.analytics.stg_orders` or `FROM postgresql.public.orders`** anywhere in a dbt model — breaks the DAG (dbt can't see the dependency, won't build upstream first, won't reorder on schema changes) AND breaks env portability (`iceberg.analytics` vs `iceberg.analytics_dev` differs per target). ALWAYS use `{{ ref(...) }}` for models and `{{ source(...) }}` for raw inputs.
> 4. **`FROM "stg_orders"`** (bare relation name with no Jinja) — same defect as #3; no DAG edge, no per-target schema interpolation. Wrap in `{{ ref('stg_orders') }}`.

**Cross-references.** §6.7B (full `sources.yml` / `loaded_at_field` / `warn_after` / `error_after` canonical — requires `source()` to function). §6.7K (the `dbt source freshness` + `dbt build --select source_status:fresher+` CLI canonical — also requires `source()`). §6.7D (`dbt seeds` referenced via `{{ ref('seed_name') }}` — seeds use `ref()`, NOT `source()`, because dbt does build the seed via `dbt seed`). §6.7E (unit tests' `input: ref(...)` / `input: source(...)` — same distinction applies). For the full `stg_` / `int_` / `dim_` / `fct_` layered model pattern see [docs.getdbt.com/best-practices/how-we-structure/1-guide-overview](https://docs.getdbt.com/best-practices/how-we-structure/1-guide-overview).

---

### 6.7B LEADING CANONICAL — dbt source freshness (`sources.yml`, `loaded_at_field`, `dbt source freshness` command)

> **READ THIS FIRST if your question contains any of these keywords: `source freshness`, `freshness`, `loaded_at_field`, `loaded_at`, `warn_after`, `error_after`, `dbt source freshness` command, `sources.yml`, `stale source`, `does freshness block downstream`, `freshness CI`.** This block is the canonical reference for declaring and checking source staleness in dbt-trino on this stack. All claims below are verified at [docs.getdbt.com/reference/resource-properties/freshness](https://docs.getdbt.com/reference/resource-properties/freshness), [docs.getdbt.com/reference/commands/source](https://docs.getdbt.com/reference/commands/source), and [docs.getdbt.com/docs/deploy/source-freshness](https://docs.getdbt.com/docs/deploy/source-freshness) (WebFetched 2026-06-05).

**Q-PATTERN MATCHER.** Use this table to route to the right answer paragraph below.

| If the question is... | Answer in one line | Detail in this section |
|---|---|---|
| "How do I declare source freshness in dbt?" | A `freshness:` block under `config:` on a `source:` (or per `table:`) with `warn_after`/`error_after`, plus `loaded_at_field:` naming a timestamp column. | § Declaring freshness on a source |
| "What command runs the freshness check?" | `dbt source freshness` — a SEPARATE command, NOT part of `dbt run`. | § The `dbt source freshness` command |
| "Does a stale source fail my `dbt run` / `dbt build`?" | NO. A freshness failure does NOT block downstream models in ordinary `dbt run` or `dbt build`. Freshness is a SEPARATE command/step; you gate a pipeline on it by running `dbt source freshness` as its own CI stage. | § Does freshness block downstream? |
| "What's the worked example for an Iceberg source on dbt-trino?" | `loaded_at_field: ingested_at` + `warn_after: {count: 12, period: hour}` + `error_after: {count: 24, period: hour}`. | § Worked example — dbt-trino + Iceberg |

#### Declaring freshness on a source

`freshness` is a property of a **source**, not a model. It lives in your `sources.yml` (or any `_sources.yml` file under `models/`). **In dbt 1.10+, BOTH `loaded_at_field:` AND `freshness:` are nested under `config:` as siblings on the source (and on each `table:` for per-table overrides)** — verified at [docs.getdbt.com/reference/resource-properties/freshness](https://docs.getdbt.com/reference/resource-properties/freshness): both keys appear under `config:` in the canonical YAML shape. (The keys moved under `config:` in dbt v1.10; the older top-level / sibling-of-`config:` form still parses but emits a `PropertyMovedToConfigDeprecation` warning — prefer the `config:`-nested form in new code.) Two ingredients:

1. **`loaded_at_field:`** — the name of a timestamp column on the source table that reliably advances every time new data lands (for example `ingested_at`, `_loaded_at`, `batch_loaded_at`). On dbt-trino / Iceberg you MUST provide this field explicitly — the warehouse-metadata fallback (no `loaded_at_field`) is supported only on Snowflake, Redshift, BigQuery 1.7.3+, and Databricks Fusion (verified at [docs.getdbt.com/reference/resource-properties/freshness](https://docs.getdbt.com/reference/resource-properties/freshness)), and dbt-trino is NOT in that list. The column may be a simple identifier or a SQL expression (`"CAST(completed_date AS TIMESTAMP)"`).
2. **`freshness:` block** with `warn_after: {count: N, period: minute|hour|day}` and `error_after: {count: N, period: minute|hour|day}`. At least one of `warn_after` or `error_after` must be present. `period` is `minute`, `hour`, or `day` only.

Optional knob: a `filter:` key inside `freshness:` adds a `WHERE` clause to the freshness query — useful to scope the `MAX(loaded_at_field)` scan to a recent partition so the freshness check itself stays cheap on a large Iceberg table.

Hierarchy: `freshness:` declared at the source level applies to every table under it; a per-`table:` `freshness:` overrides the source-level one; setting `freshness: null` on a table opts that table out.

#### The `dbt source freshness` command

The freshness check is invoked by the dedicated CLI command:

```bash
dbt source freshness
# or scoped to a single source / source table:
dbt source freshness --select "source:app"
dbt source freshness --select "source:app.orders"
```

Under the hood the dbt-trino adapter runs roughly `SELECT MAX({{ loaded_at_field }}) FROM {{ source_table }} [WHERE {{ filter }}]` against Trino, computes the age between that timestamp and the current time, and emits one of four states per source: `pass`, `warn`, `error`, or `runtime error` (the last when the query itself fails). The result is written to `target/sources.json` for tooling and for the `source_status` state selector.

**Crucially: `dbt source freshness` is its own command.** It is NOT run automatically by `dbt run`, and per [docs.getdbt.com/reference/commands/source](https://docs.getdbt.com/reference/commands/source) it is NOT included in `dbt build` either. If you want freshness checked in a pipeline, you have to invoke `dbt source freshness` as its own step.

#### Does freshness block downstream models?

**No — a freshness failure does NOT block downstream models in an ordinary `dbt run` or `dbt build`.** Freshness is a separate command/build step; it is NOT a model-dependency gate. The dbt graph runs sources -> models based on `{{ source(...) }}` and `{{ ref(...) }}` references; freshness state is not consulted by that traversal.

The way you gate a pipeline on freshness is **operationally**, by running `dbt source freshness` as its own CI stage:

```bash
# CI pipeline pseudo-steps (the dbt project root)
dbt deps
dbt source freshness          # <-- if any source is in 'error' state, this exits non-zero
dbt build                     # only reached if the freshness step passed
```

Whether a non-zero exit from `dbt source freshness` actually halts the pipeline is a property of your CI runner (`set -e` in a shell script, or GitLab CI / GitHub Actions / Argo Workflows / k8s Job failure semantics) — NOT a dbt internal dependency gate.

There is also a dbt state selector named `source_status:fresher+` that selects models downstream of sources that became fresher since a previous `sources.json` artifact. It exists for incremental-build patterns, but its detailed selector semantics are out of scope for this canonical block — consult [docs.getdbt.com/reference/node-selection/methods](https://docs.getdbt.com/reference/node-selection/methods) directly when adopting it.

#### Worked example — dbt-trino + Iceberg source

Suppose your ingestion (Spark) stamps every row with an `ingested_at` Iceberg column. You want a WARN at 12 hours stale, an ERROR at 24 hours stale.

```yaml
# models/staging/_sources.yml
version: 2

sources:
  - name: app
    description: "App-side Iceberg ingest tables (Hive Metastore-backed)."
    schema: app                              # Iceberg schema in the HMS-backed catalog
    config:
      freshness:
        warn_after:  {count: 12, period: hour}
        error_after: {count: 24, period: hour}
      loaded_at_field: ingested_at           # Iceberg column written by the Spark ingest job
    tables:
      - name: orders
      - name: payments
        config:
          freshness:                         # tighter per-table override
            warn_after:  {count: 1, period: hour}
            error_after: {count: 4, period: hour}
      - name: currency_fx
        config:
          freshness: null                    # opt out — this is a slowly-changing dim
```

The CLI:

```bash
$ dbt source freshness
17:02:11  Running with dbt=1.9.x
17:02:14  1 of 2 START freshness of app.orders ......................... [RUN]
17:02:15  1 of 2 PASS  freshness of app.orders ......................... [PASS in 1.18s]
17:02:15  2 of 2 START freshness of app.payments ....................... [RUN]
17:02:16  2 of 2 WARN  freshness of app.payments ....................... [WARN in 1.06s]
17:02:16  Done.
```

A `pass`/`warn`/`error` line per source is written; the full state lands in `target/sources.json` for `source_status:fresher+` re-use.

#### DO-NOT-WRITE — banned freshness claims (cite-or-omit)

| DO NOT write | Why it's wrong |
|---|---|
| "Use the `freshness()` jinja function in your model." | **FABRICATED.** dbt has NO `freshness()` jinja function. Freshness is YAML-declared, not Jinja-expressed. |
| "`dbt run` will skip downstream models when their source is stale." | **WRONG.** `dbt run` does not consult freshness state. The dbt DAG runs sources -> models based on `{{ source(...) }}` and `{{ ref(...) }}` references only. Gate freshness operationally with a separate `dbt source freshness` CI step. |
| "`dbt build` runs source freshness as part of the build." | **WRONG per [docs.getdbt.com/reference/commands/source](https://docs.getdbt.com/reference/commands/source).** `dbt build` runs models + tests + snapshots + seeds, but NOT `dbt source freshness`. Invoke `dbt source freshness` as its own step. |
| "Use `dbt run --check-freshness` (or `dbt build --check-freshness` / `--skip-stale-sources`) to gate the build on freshness." | **FABRICATED FLAG — these CLI flags do NOT exist.** `dbt run` and `dbt build` have NO `--check-freshness`, no `--skip-stale-sources`, no `--freshness` flag of any kind. The ONLY way to make a CI pipeline halt on stale sources is the two-step shape: (1) `dbt source freshness` as its OWN CI stage (non-zero exit on `error_after`), with `set -e` / runner failure semantics halting the next stage; (2) optionally `dbt build --select source_status:fresher+` to limit downstream rebuilds to models whose upstream sources became fresher since the previous `target/sources.json`. Verified — no such flag in [docs.getdbt.com/reference/commands/run](https://docs.getdbt.com/reference/commands/run) or [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build). |
| "Add a `stale_after:` or `max_age:` key to the freshness block." | **FABRICATED.** The only valid threshold keys are `warn_after` and `error_after`, each taking `{count: N, period: minute\|hour\|day}`. No `stale_after`, no `max_age`, no `min_age`. |
| "`period:` can be `second`, `week`, or `month`." | **WRONG.** Valid values are exactly `minute`, `hour`, `day` per [docs.getdbt.com/reference/resource-properties/freshness](https://docs.getdbt.com/reference/resource-properties/freshness). No second, week, month, year. |
| "Write a custom dbt test or macro to assert source freshness." | **UNNECESSARY and WRONG-LAYER.** dbt has built-in source freshness — declare a `freshness:` block on the source and run `dbt source freshness`. A custom test/macro re-implements existing functionality and won't write to `target/sources.json`, so `source_status:fresher+` selectors will not work. |
| "On dbt-trino you can omit `loaded_at_field` and dbt will use warehouse metadata." | **WRONG on this stack.** The warehouse-metadata fallback is supported only on Snowflake, Redshift, BigQuery 1.7.3+, and Databricks Fusion. dbt-trino is NOT in that list — you must provide `loaded_at_field` explicitly. |
| "Put `freshness:` at the top level of the source (not under `config:`)." | **DEPRECATED in dbt 1.9+.** The canonical placement is under `config:` (both source-level and per-table). The pre-1.9 top-level form still parses but emits a `PropertyMovedToConfigDeprecation` warning — prefer `config:` in new code. |
| "Freshness state is stored in `manifest.json`." | **WRONG.** The freshness state file is `target/sources.json`, written by `dbt source freshness`. `manifest.json` carries graph state, not freshness state. |

#### Cross-references

- For the dbt `source()` / `ref()` macros and where `sources.yml` files live: see [§ 6.3-6.4](#63-stg_orderssql) — the worked example uses `{{ source('app', 'orders') }}`, which resolves to the `app.orders` source declared above.
- For the dbt model dependency graph (what `dbt run` and `dbt build` actually traverse): see [docs.getdbt.com/docs/build/sources](https://docs.getdbt.com/docs/build/sources).
- For the broader CI-pipeline picture (how `dbt source freshness` slots in alongside `dbt build`): see [§ 7. Cutover checklist](#7-cutover-checklist-the-non-obvious-gotchas) item 9 (schedule the dbt run).

---

### 6.7C LEADING CANONICAL — dbt model contracts (`config: contract: enforced: true`, `columns:` with `name` + `data_type`)

> **READ THIS FIRST if your question contains any of these keywords: `model contract`, `contract enforced`, `dbt contract`, `enforced: true`, `data_type:`, `dbt column contract`, `schema lock`, `dbt build fails on column mismatch`, `dbt schema enforcement`, `dbt model contract example`, `dbt-trino contract`, `contract constraints`.** This block is the canonical reference for declaring model contracts in dbt on this stack. All claims below are verified at [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract) and [docs.getdbt.com/docs/collaborate/govern/model-contracts](https://docs.getdbt.com/docs/collaborate/govern/model-contracts) (WebFetched 2026-06-05), with dbt-trino constraint enforcement verified via the dbt-trino adapter docs.

> **DO-NOT-CONFUSE: dbt CONTRACTS vs `on_schema_change` — different features for different problems.** dbt **CONTRACTS** (this section) = build-time schema/type preflight (fails the build on declared-vs-actual column-name / `data_type:` mismatch). **`on_schema_change`** = incremental-merge column handling (what happens to the TARGET Iceberg table when the model SELECT gains/loses a column on an incremental run). **If your question is "I added a column to my incremental dbt model and the new column is silently missing from the output table after `dbt build` succeeded", the answer is `on_schema_change` (default = `ignore` = silent drop; fix = `'append_new_columns'`), NOT contracts.** See [resource 13 § `on_schema_change` — the FOUR options and the correct default](13-postgres-to-iceberg-ingestion.md) for the canonical answer to that question.

**Q-PATTERN MATCHER.** Use this table to route to the right answer paragraph below.

| If the question is... | Answer in one line | Detail in this section |
|---|---|---|
| "What is a dbt model contract?" | A schema lock declared in the model's YAML; dbt fails the BUILD if the model's actual output columns or types diverge from the declared ones. | § What a contract is and when it fires |
| "How do I declare a contract?" | Add `config: contract: {enforced: true}` to the model's YAML entry, PLUS a `columns:` list where every column has `name` + `data_type` (the warehouse-specific type — on dbt-trino use Trino types: VARCHAR, BIGINT, TIMESTAMP(6), DATE, DECIMAL(p,s)). | § Worked example — dbt-trino + Iceberg |
| "Does it fail at build time or query time?" | **Build time** (during `dbt run` / `dbt build`'s preflight check), NOT query time. The Trino engine itself does NOT enforce the contract — dbt does, before materialization. | § What a contract is and when it fires |
| "Do constraints (not_null, primary_key, etc.) get enforced on dbt-trino?" | **Only `not_null` is enforced** on dbt-trino + Iceberg (Trino translates it to an Iceberg NOT NULL column constraint). `primary_key`, `foreign_key`, `unique`, `check` are **definable in YAML but NOT runtime-enforced** by Trino — they are recorded as metadata only. The HARD guarantee is the column-name + data_type build-time check, which fires regardless of platform. | § Constraints on dbt-trino — what's enforced vs definable |
| "What does the build print when the model violates the contract?" | A `Compilation Error` / preflight error showing column-name / data_type mismatch BEFORE the model is materialized. Production data is never corrupted because the build halts first. | § Failure mode — what `dbt build` prints |

#### What a contract is and when it fires

A model contract is a **schema lock** declared in the model's YAML (the `.yml` file next to the model `.sql` file under `models/`). When `contract.enforced: true`, dbt's compilation step runs a **"preflight" check** before materializing the model:

1. It compiles the model's SELECT body.
2. It compares the SELECT's output column names + data types against the YAML-declared `columns:` list.
3. If ANY column is missing, extra, or has the wrong type, **dbt errors and refuses to build the model** — the SQL is never executed against Trino.

This is a **build-time check** (during `dbt run` / `dbt build`), NOT a query-time check. The Trino engine does not enforce model contracts — dbt does, via the dbt-trino adapter. The contract is a dbt-core feature available on every adapter (Snowflake, BigQuery, Postgres, Spark, Databricks, dbt-trino, etc.), not a Trino-specific mechanism.

> **Contract vs `not_null` DATA rejection — two different mechanisms, both can fail the build.** A dbt **CONTRACT** is a STRUCTURAL preflight check at COMPILE time: it compares the SELECT's projected column **names + `data_type:` + declared constraint DDL** against the YAML, and errors before any SQL is sent to Trino — it does **NOT scan data values**. The **NOT-NULL DATA rejection** (a NULL row hitting a `not_null`-constrained column) is a separate event that fires at **INSERT/MERGE time** inside Trino, because dbt-trino translated the `not_null` constraint into an Iceberg `NOT NULL` column DDL — Iceberg rejects the offending row at commit (verified at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs): *"only constraints with `type` as `not_null` are supported"*; `primary_key` / `unique` are metadata-only / not enforced on dbt-trino). Same `dbt build` can fail either way, but the layer is different — STRUCTURAL (contract preflight, no data scan) vs DATA (Iceberg NOT NULL write-side rejection).

**Why it matters on this stack.** A downstream BI dashboard or another dbt model depends on the schema of `fct_orders` (column names + types). Without a contract, a rename of `customer_id` to `cust_id` in the model body would silently propagate, breaking the dashboard at the next refresh. With a contract, the rename is caught at `dbt build` BEFORE the model gets re-materialized — the dashboard is never broken because the broken build never lands.

#### Required YAML keys (the canonical schema)

```yaml
# models/marts/fct_orders.yml
version: 2

models:
  - name: fct_orders
    config:
      contract:
        enforced: true                  # turns the contract on; without this it's purely documentation
    columns:
      - name: order_id                  # required: every column the model outputs must be listed
        data_type: bigint               # required: warehouse type — on dbt-trino use Trino types
        constraints:
          - type: not_null              # ENFORCED on dbt-trino (translates to Iceberg NOT NULL)
      - name: customer_id
        data_type: bigint
        constraints:
          - type: not_null
      - name: order_date
        data_type: date
      - name: amount_usd
        data_type: decimal(18,2)        # decimal precision + scale in standard Trino form
      - name: status
        data_type: varchar              # VARCHAR (no length) is the production-default Trino type
      - name: created_at
        data_type: timestamp(6)         # Trino timestamp precision-6; matches Iceberg's default precision
```

**Key rules verified at [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract):**

- The `config:` block holds `contract: {enforced: true}` — the canonical 1.9+ placement (pre-1.9 the top-level `contract:` placement still parses but emits a deprecation warning).
- `enforced: true` is the trigger; `enforced: false` (or omitting the contract block entirely) means there is no schema lock.
- Every column the model outputs MUST appear in the `columns:` list when `enforced: true`. Missing a column → build error. Listing a column the model doesn't output → build error. Wrong order → NOT an error (column order is positional in the contract check, not declarative).
- `data_type:` is the **warehouse-specific type** — for dbt-trino, use Trino types (`VARCHAR`, `BIGINT`, `INTEGER`, `DATE`, `TIMESTAMP(6)`, `TIMESTAMP(6) WITH TIME ZONE`, `DECIMAL(p, s)`, `DOUBLE`, `BOOLEAN`, `VARBINARY`, etc.). Do NOT write generic types like `string`, `int`, `numeric` — dbt-trino will not normalize them.
- Optional `constraints:` list under each column; constraint enforcement is adapter-dependent (see next sub-section).

#### Constraints on dbt-trino — what's enforced vs definable

Per the dbt-core constraints reference (verified via [docs.getdbt.com/reference/resource-properties/constraints](https://docs.getdbt.com/reference/resource-properties/constraints)) and the dbt-trino adapter docs, constraint behavior on dbt-trino + Iceberg is:

| Constraint type | dbt-trino + Iceberg behavior | Notes |
|---|---|---|
| `not_null` | **DEFINABLE and ENFORCED** at write time | dbt-trino issues `NOT NULL` on the Iceberg column definition; Iceberg rejects NULL inserts on that column at commit time. |
| `primary_key` | **DEFINABLE but NOT ENFORCED** at write time | Recorded as YAML/metadata, but Trino + Iceberg do NOT enforce uniqueness at insert/merge time. Use a dbt test (`unique`) for the runtime check. |
| `foreign_key` | **DEFINABLE but NOT ENFORCED** at write time | Same as primary_key — metadata only on dbt-trino + Iceberg. |
| `unique` | **DEFINABLE but NOT ENFORCED** at write time | Metadata only. Pair with dbt's built-in `unique` test for an actual runtime check. |
| `check` | **DEFINABLE but NOT ENFORCED** at write time | Metadata only. Pair with `dbt_utils.expression_is_true` for an actual runtime check. |

**The load-bearing guarantee is the column-list + data_type build-time check.** That check is enforced unconditionally on every adapter that supports contracts (which includes dbt-trino). Only the constraint enforcement is adapter-dependent. If you are migrating from Oracle where `NOT NULL` was strictly enforced and `PRIMARY KEY` was uniqueness-enforced at write time, you keep `not_null` semantics under dbt-trino + Iceberg, but you must replace `primary_key` enforcement with the dbt `unique` test (which runs as a post-build assertion via `dbt test`).

> **Defer to dbt-trino docs for any constraint specifics beyond `not_null`.** The verified statement is: dbt-trino enforces `not_null` at the Iceberg-column level; other constraints (`primary_key`, `foreign_key`, `unique`, `check`) are definable in YAML but not runtime-enforced. For the exact list of constraint types accepted by dbt-trino, the precise message dbt-trino emits when a constraint is rejected, and any version-pin caveats, consult [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — do NOT fabricate additional constraint-enforcement claims beyond the `not_null` enforcement explicitly verified above.

#### Failure mode — what `dbt build` prints

When the model SELECT body and the contract diverge, `dbt build` prints a structured preflight error and refuses to materialize the model. Example: the contract declares `customer_id` as `bigint` but the model's actual SELECT projects `customer_id` as `varchar`:

```text
$ dbt build --select fct_orders

Compilation Error in model fct_orders (models/marts/fct_orders.sql)
  This model has an enforced contract that failed.
  Please ensure the name, data_type, and number of columns in your contract match the columns in your model's definition.

  | column_name  | definition_type | contract_type | mismatch_reason    |
  | ------------ | --------------- | ------------- | ------------------ |
  | customer_id  | varchar         | bigint        | data type mismatch |

  Error encountered before the model could be built. No changes were applied to the warehouse.
```

**Three flavors of failure** the preflight check catches:

| What changed in the model | What `dbt build` prints | Why this is the desired behavior |
|---|---|---|
| (a) A column was dropped from the SELECT (e.g., `status` removed) | `missing in definition: status` (or similar) — build fails | Downstream dashboards depending on `status` would silently start returning NULLs; the contract fails the build BEFORE that happens. |
| (b) A column's type changed (e.g., `customer_id` returns VARCHAR instead of BIGINT) | `data type mismatch` row in the table above — build fails | Downstream models JOINing on `customer_id = customers.id` (BIGINT) would silently fail their JOIN; build halts before that ships. |
| (c) An extra column was added to the SELECT not in the contract | `extra in definition: <col_name>` — build fails | The contract is a forward-compatibility lock: when you ADD a column on purpose, you update both the SELECT and the contract in the same PR. |

**Crucially: no production data is written when the contract fails.** The preflight runs BEFORE Trino executes the model SQL. The contract is a build-time gate, not a runtime gate, and the gate fires before any `INSERT INTO ...` or `MERGE INTO ...` reaches Trino. This is the load-bearing operational guarantee.

#### Worked example — dbt-trino + Iceberg model with a contract

Putting it all together: a contract-protected fact table for orders.

```yaml
# models/marts/fct_orders.yml
version: 2

models:
  - name: fct_orders
    description: "Order grain fact (one row per order). Public contract for downstream BI."
    config:
      materialized: table
      contract:
        enforced: true
    columns:
      - name: order_id
        description: "Surrogate key — `dbt_utils.generate_surrogate_key`."
        data_type: varchar
        constraints:
          - type: not_null
      - name: tenant_id
        description: "Tenant scope for multi-tenant isolation."
        data_type: bigint
        constraints:
          - type: not_null
      - name: customer_id
        data_type: bigint
        constraints:
          - type: not_null
      - name: order_date
        data_type: date
        constraints:
          - type: not_null
      - name: status
        data_type: varchar
      - name: total_usd
        data_type: decimal(18,2)
        constraints:
          - type: not_null
      - name: created_at
        data_type: timestamp(6)
        constraints:
          - type: not_null
    tests:
      # Constraints above are definable in YAML; only `not_null` is ENFORCED on
      # dbt-trino + Iceberg at write time. Pair with these dbt tests for the
      # runtime uniqueness check that Trino does NOT do natively:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns: [tenant_id, order_id]
    columns:
      - name: total_usd
        tests:
          - dbt_utils.expression_is_true:
              expression: ">= 0"
```

The matching model SELECT (skeleton):

```sql
-- models/marts/fct_orders.sql
{{ config(
    materialized='table',
    properties={
      'partitioning': "ARRAY['month(order_date)', 'bucket(tenant_id, 16)']"
    }
) }}
{#- Iceberg connector's table-property name is `partitioning` (per trino.io/docs/current/connector/iceberg.html).
    dbt-trino's properties() macro passes dict keys verbatim into the WITH (...) clause,
    so the dbt-config key for an Iceberg-catalog model is also `partitioning`.
    Do NOT use `partitioned_by` here — that's the HIVE connector's key (a different connector
    with different property names). The production stack on this repo is Iceberg.
    See resource 28 § LEADING CANONICAL — dbt-trino partition key for Iceberg vs Hive. -#}

SELECT
  {{ dbt_utils.generate_surrogate_key(['tenant_id', 'natural_order_id']) }} AS order_id,
  tenant_id,
  customer_id,
  order_date,
  status,
  total_usd,
  created_at
FROM {{ ref('stg_orders') }}
```

If a future PR changes the SELECT to project `total_usd` as `double` (instead of `decimal(18,2)`), `dbt build` will error at the preflight check — the build fails BEFORE the table is rewritten, the existing `fct_orders` table is untouched, and the dashboard built on top of it keeps working until the contract is updated explicitly.

#### When to use contracts (and when to skip them)

| Use a contract | Skip a contract |
|---|---|
| Public-facing fact / dim tables exposed to downstream BI dashboards | Staging models (`stg_*`) where columns churn rapidly during development |
| Models exposed as dbt **exposures** to other teams | Scratch / intermediate models that nothing outside the immediate model graph references |
| Models depended on by another dbt model's `{{ ref(...) }}` in a multi-team monorepo | One-off ad-hoc analyses or `models/scratch/` work |
| Models with `materialized='table'` or `materialized='incremental'` (contracts ARE supported here) | Views (limited contract support — no constraints), Python models, ephemeral models, materialized views (NOT supported per dbt docs) |

**Pair contracts with source freshness (§6.7B).** Contracts lock the OUTPUT-side schema of your models; source freshness checks the INPUT-side liveness of your raw sources. Together they form a complete dbt-side data-quality boundary: stale input is caught by `dbt source freshness`; broken output schema is caught by `dbt build` with `contract.enforced: true`.

#### DO-NOT-WRITE — banned model-contract claims (cite-or-omit)

> **The following claims are FORBIDDEN in any dbt-trino model-contract context. Each row was WebSearch-verified.**

| DO NOT write | Why it's wrong |
|---|---|
| `@contract` (Python-style decorator on the model) | **FABRICATED.** dbt has no `@contract` decorator — contracts are declared exclusively in YAML via `config: contract: {enforced: true}` + `columns:`. |
| `CONTRACT` as a SQL keyword (e.g., `CREATE TABLE ... WITH CONTRACT (...)`) | **FABRICATED.** There is no `CONTRACT` SQL keyword in Trino or in dbt's compiled SQL. The contract check is done by dbt during compilation, BEFORE any SQL is sent to Trino. |
| "The contract is enforced at query time by Trino" | **WRONG.** The contract is enforced at dbt BUILD time during compilation, not at Trino query time. Trino does not know the contract exists. The check fires inside dbt-core's preflight step before the model SQL is submitted to the Trino engine. |
| "Contracts are a Trino-specific feature" | **WRONG.** Contracts are a dbt-CORE feature available on every adapter that supports them (Snowflake, BigQuery, Postgres, Spark, Databricks, dbt-trino, ...). Constraint enforcement varies by adapter; the column-name + data_type check is universal. |
| "On dbt-trino, `primary_key` is enforced at write time" | **WRONG.** Only `not_null` is enforced at write time on dbt-trino + Iceberg. `primary_key`, `foreign_key`, `unique`, `check` are definable in YAML but NOT runtime-enforced — use the corresponding dbt tests (`unique`, `dbt_utils.expression_is_true`) for actual runtime checks. |
| "Set the contract via a `dbt run --enforce-contract` CLI flag" | **FABRICATED FLAG.** No such CLI flag exists. The contract is YAML-declared via `config: contract: {enforced: true}`. The CLI flags `dbt run` and `dbt build` accept do NOT include any contract toggle — contracts are always enforced when `enforced: true` is set in YAML, regardless of CLI invocation. |
| `data_type: string` / `data_type: int` / `data_type: numeric` on dbt-trino | **WRONG WAREHOUSE TYPE.** dbt-trino requires Trino types in `data_type`: `VARCHAR` (not `string`), `BIGINT` or `INTEGER` (not `int`), `DECIMAL(p, s)` (not `numeric`), `DATE`, `TIMESTAMP(6)`, `TIMESTAMP(6) WITH TIME ZONE`, `DOUBLE`, `BOOLEAN`, `VARBINARY`. Generic types do not normalize and the contract will fail to validate. |
| Invented config keys like `contract.strict: true`, `contract.mode: 'strict'`, `contract.check_types: true`, `contract.allow_extra_columns: true` | **FABRICATED.** The ONLY documented sub-keys under `contract:` are `enforced: true|false` and `alias_types: true|false`. Do NOT invent other keys. |
| "Contracts work on materialized views" | **WRONG per [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract).** Contracts are supported on `table`, `view` (limited — no constraints), and `incremental` (requires `on_schema_change: append_new_columns` or `fail`). NOT supported on materialized views, Python models, ephemeral models, or custom materializations. |
| Constraint types like `regex`, `length`, `min`, `max`, `range`, `enum` under a column's `constraints:` list | **FABRICATED.** The documented constraint types are `not_null`, `primary_key`, `foreign_key`, `unique`, `check`. Do NOT invent regex / length / range / enum constraints. For business-rule validation, use a dbt test (`dbt_utils.expression_is_true`) — NOT an invented constraint type. |

#### Cross-references

- For dbt source freshness (the INPUT-side liveness check that pairs with contracts as the OUTPUT-side schema lock): see [§ 6.7B](#67b-leading-canonical--dbt-source-freshness-sourcesyml-loaded_at_field-dbt-source-freshness-command).
- For dbt tests that supplement contracts (uniqueness, business-rule assertions): see [§ 6.7](#67-dbt-tests-to-add-replacing-oracle-exception-handlers).
- For the canonical dbt model body shape (SELECT-only, NOT raw DML): see [§ 4.6A.1](#461-the-default-recommended-pattern--two-model-decomposition) and the dbt-framing recipe in [§ 4.6A.4](#464-summary--the-migration-decision-table).
- For dbt-trino specific config knobs (the `properties` block, the Iceberg-connector key `partitioning` inside it, `incremental_strategy`): see [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) for the dbt side and [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) for the Iceberg connector's property names. See also [resource 28 § LEADING CANONICAL — dbt-trino partition key for Iceberg vs Hive](28-complex-sql-performance-trino-dbt.md).
- Official dbt docs source-of-truth: [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract) and [docs.getdbt.com/docs/collaborate/govern/model-contracts](https://docs.getdbt.com/docs/collaborate/govern/model-contracts).

---

### 6.7D LEADING CANONICAL — dbt seeds (small static CSVs as lookup tables: `seeds/`, `dbt seed`, `{{ ref(...) }}`)

> **READ THIS FIRST if your question contains any of these keywords: `dbt seed`, `seeds/`, `seed-paths`, `static lookup`, `plan codes CSV`, `reference table CSV`, `dbt seed command`, `small CSV table`, `lookup CSV`, `seed directory`, `data/ CSV`, `seeds directory`.** This block is the canonical reference for loading small static CSVs as dbt-managed lookup tables. Verified against [docs.getdbt.com/reference/project-configs/seed-paths](https://docs.getdbt.com/reference/project-configs/seed-paths) and [docs.getdbt.com/docs/build/seeds](https://docs.getdbt.com/docs/build/seeds).

**What a dbt seed is.** A dbt seed is a small static CSV file that dbt loads into a table in the data warehouse (on this stack: an Iceberg table in the Trino catalog). Seeds are for lookup/reference data that changes infrequently and is small enough to live in version control alongside your dbt models — plan codes, country codes, feature-flag mappings, product tiers. They are NOT for large or frequently-changing datasets (use a dbt source + ingestion job for those).

#### Default seed directory — `seeds/` (since dbt 1.0, Dec 2021)

**The default seed directory is `seeds/`, NOT `data/`.** Place CSV files at `dbt_project_root/seeds/<name>.csv`. This default has been `seeds/` since dbt 1.0 (released December 2021). The pre-1.0 default was `data/` — that is **stale and deprecated**. A new project placing CSVs in `data/` will fail `dbt seed` with "No seed files found" unless `seed-paths: ["data"]` is explicitly configured in `dbt_project.yml`.

| | Correct (dbt 1.0+) | Wrong (pre-1.0 / stale) |
|---|---|---|
| File location | `dbt_project_root/seeds/plans.csv` | `dbt_project_root/data/plans.csv` |
| Config in dbt_project.yml | Default — no config needed, OR `seed-paths: ["seeds"]` | Requires `seed-paths: ["data"]` (not needed; don't use) |

To override the default: add `seed-paths: ["custom_dir"]` to `dbt_project.yml`. For any new project, leave it at the default — no config needed.

#### Canonical recipe — plan-code lookup

**Step 1.** Create the CSV at `seeds/plans.csv` (default location, no config change needed):

```csv
plan_code,plan_name,max_seats,is_enterprise
free,Free,5,false
pro,Pro,25,false
business,Business,100,false
enterprise,Enterprise,10000,true
```

**Step 2.** (Optional) Configure column types in `dbt_project.yml` to prevent implicit type coercion:

```yaml
seeds:
  your_project_name:
    plans:
      +column_types:
        plan_code: varchar
        plan_name: varchar
        max_seats: integer
        is_enterprise: boolean
```

Without `+column_types`, dbt infers types from CSV content — usually fine for string columns, but `max_seats` might land as VARCHAR if not declared.

**Step 3.** Load the seed:

```bash
dbt seed
# Or load only this one seed:
dbt seed --select plans
```

`dbt seed` creates (or replaces) the `plans` table in the Iceberg catalog. It runs a `CREATE TABLE AS SELECT` from the CSV content.

**Step 4.** Reference the seed from any dbt model:

```sql
-- models/marts/fct_subscriptions.sql
SELECT
    s.subscription_id,
    s.plan_code,
    p.plan_name,
    p.max_seats,
    p.is_enterprise
FROM {{ ref('stg_subscriptions') }} s
LEFT JOIN {{ ref('plans') }} p ON s.plan_code = p.plan_code
```

`{{ ref('plans') }}` resolves to the Iceberg table created by `dbt seed`. The argument is the CSV basename without extension (`plans`, not `plans.csv`).

**Step 5.** Pick the right command. Per [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build), `dbt build` runs **seeds + models + snapshots + tests together in DAG order** — so a plain `dbt build` (no `--select`) already loads every seed in `seeds/` as part of the build. `dbt run`, by contrast, runs **models only** and does NOT load seeds — if you use `dbt run`, you must pre-seed with `dbt seed` first.

```bash
dbt build                  # RECOMMENDED — runs seeds + models + snapshots + tests in DAG order
dbt seed && dbt run        # equivalent for the run-only path (no snapshots, no tests)
dbt seed                   # load seeds only (or: dbt seed --select plans)
```

#### When to use seeds vs. other patterns

| Situation | Use |
|---|---|
| Small static lookup (< ~1 MB CSV, changes rarely) | `dbt seed` — put in `seeds/`, version in git |
| Lookup table managed by application (e.g., Postgres `plans` table) | `dbt source` — declare in `sources.yml`, use `{{ source(...) }}` |
| Large reference table (millions of rows) | Ingest via Spark/Debezium → dbt source |
| Frequently-changing data (updated daily) | Ingest job + dbt model, not seed (dbt seed truncates and reloads the full CSV every time) |

#### DO-NOT-WRITE — banned seed claims

| DO NOT write | Why it's wrong |
|---|---|
| `dbt_project_root/data/plans.csv` (without `seed-paths: ["data"]` config) | **Stale pre-dbt-1.0 default path.** Default since dbt 1.0 (Dec 2021) is `seeds/`. Placing CSV in `data/` makes `dbt seed` report "No seed files found" unless `seed-paths: ["data"]` is explicitly set. |
| `{{ ref('plans.csv') }}` (with `.csv` extension) | **Wrong.** `{{ ref() }}` takes the basename without extension: `{{ ref('plans') }}`. |
| "Run `dbt run --select plans` to load the seed." | **Wrong command.** `dbt run` does not load seeds — it materializes SQL models. Load seeds with `dbt seed` (or `dbt seed --select plans`). |
| "`dbt build` does NOT run seeds — you have to pass `--select seeds+`." | **Wrong per [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build).** Plain `dbt build` (no `--select`) runs **seeds + models + snapshots + tests together in DAG order** across the whole project — seeds are loaded automatically. The half-truth is `dbt run`: `dbt run` alone runs models only and does NOT load seeds, so the `dbt seed && dbt run` two-step is required only on the run-only path. |
| "`seed-paths: [\"data\"]` is the recommended default." | **Wrong.** The default is `seeds/`. Use `data/` only if you have a legacy project already using that path and cannot migrate. |

Citation: [docs.getdbt.com/reference/project-configs/seed-paths](https://docs.getdbt.com/reference/project-configs/seed-paths) — "By default, dbt expects seeds to be located in the `seeds` directory."

---

### 6.8 DBT-IS-INCREMENTAL-WHERE CANONICAL-PATTERN GUARDRAIL — the WHERE clause inside `{% if is_incremental() %}`

**Why this section exists.** When porting an Oracle `MERGE INTO target USING source ON ...` procedure to a dbt incremental model, the part that has NO direct Oracle analog is the **delta filter** — the WHERE clause inside the `{% if is_incremental() %}` block that selects only the rows the MERGE should process. The single most common AI-generated mistake here is to put a **bare aggregate** directly in the predicate (e.g., `WHERE order_date >= MAX(order_date)`), which Trino rejects with **"aggregate function not allowed in WHERE clause."** Verified against [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) (aggregate functions reference: aggregates appear in `SELECT`/`HAVING`/subqueries, NOT in `WHERE`) and [docs.getdbt.com — Incremental models](https://docs.getdbt.com/docs/build/incremental-models).

**The CANONICAL delta filter (append/merge):**

```jinja
{% if is_incremental() %}
  WHERE order_date >= (
    SELECT COALESCE(MAX(order_date), DATE '1970-01-01')
    FROM {{ this }}
  )
{% endif %}
```

The `MAX(order_date)` **MUST be wrapped in a subquery** — `(SELECT MAX(...) FROM {{ this }})`. The subquery is what makes the aggregate legal inside `WHERE`. The `COALESCE(..., DATE '1970-01-01')` handles the edge case of an empty `{{ this }}` (first run, or after a manual TRUNCATE) so the predicate evaluates to "everything" rather than `NULL` (which filters to zero rows).

**The CANONICAL late-arriving-data LOOKBACK variant** (pair with `incremental_strategy='merge'` + `unique_key` for idempotence):

```jinja
{% if is_incremental() %}
  WHERE order_date >= (
    SELECT date_add('day', -3, COALESCE(MAX(order_date), DATE '1970-01-01'))
    FROM {{ this }}
  )
{% endif %}
```

Subtract a fixed lookback window (here 3 days) so late-arriving rows still get caught. `incremental_strategy='merge'` + `unique_key` guarantees idempotence: matched rows update in place, unmatched insert — re-running the same lookback window produces no duplicates.

**DO-NOT-WRITE callout (load-bearing — both bullets are invalid SQL or anti-patterns):**

> **(i) NEVER write a bare aggregate directly in a `WHERE` clause** — for example `WHERE order_date >= MAX(order_date)`, `WHERE x > MIN(x)`, `WHERE cnt < COUNT(*)`. Aggregate functions are not allowed in `WHERE` in Trino (or any ANSI-SQL engine). They MUST be wrapped in a subquery: `WHERE order_date >= (SELECT MAX(order_date) FROM {{ this }})`. **(ii) NEVER write the convoluted full-history re-scan `WHERE id IN (SELECT id FROM {{ this }} WHERE load_date < CURRENT_DATE) OR load_date >= ...` as a delta filter.** That clause forces the model to re-read every historic row from the target on every run, defeating the entire purpose of `materialized='incremental'`. The canonical delta filter is a single subquery-wrapped `MAX(...)` comparison, not an IN-against-the-target.

**Q-pattern matcher.** If the question is "what does my dbt `is_incremental()` WHERE clause look like" — or any equivalent phrasing ("dbt watermark predicate", "scan only new rows in dbt", "is_incremental delta filter") — the answer is `WHERE <watermark_col> >= (SELECT COALESCE(MAX(<watermark_col>), <safe_default>) FROM {{ this }})` with the subquery wrapper. NOT a bare `MAX(...)` in WHERE. NOT an `IN (SELECT ... FROM {{ this }} ...)` against the target.

For the deeper lookback-window discussion (failure modes, partition_by pairing, EXPLAIN ANALYZE validation), see [resource 28 § 8A.3](28-complex-sql-performance-trino-dbt.md#8a3-incremental-model-late-arriving-data-and-lookback-windows).

---

### 6.7E LEADING CANONICAL — dbt UNIT TESTS (1.8+) — testing model logic on MOCK input (`unit_tests:` with `given:` / `expect:`)

> **READ THIS FIRST if your question contains any of these keywords: `dbt unit test`, `dbt unit tests`, `test model logic`, `test transformation logic`, `mock input rows`, `given expect`, `given/expect`, `unit_tests:` YAML, `format: dict`, `format: csv`, `format: sql`, `test_type:unit`, `dbt 1.8 unit tests`, `assert output for specific input`, `fixture`, `unit test fixture`, `does my model transform correctly`, `unit test a dbt model`.** This block is the canonical reference for the dbt 1.8+ `unit_tests:` property. All claims below are verified at [docs.getdbt.com/docs/build/unit-tests](https://docs.getdbt.com/docs/build/unit-tests), [docs.getdbt.com/reference/resource-properties/unit-tests](https://docs.getdbt.com/reference/resource-properties/unit-tests), and [docs.getdbt.com/reference/resource-properties/data-formats](https://docs.getdbt.com/reference/resource-properties/data-formats) (WebFetched 2026-06-06).

**ONE-SENTENCE MENTAL MODEL.** A **unit test** in dbt is a YAML-declared assertion that says "when this model receives THIS exact set of input rows (`given:`), it must produce THIS exact set of output rows (`expect:`)" — it tests the model's **SQL transformation logic on MOCK input data**, NOT the post-build warehouse output. Available **dbt 1.8+** (originally previewed in dbt-labs releases; GA in 1.8).

#### DO-NOT-CONFUSE — unit tests vs data tests (the single most common dbt-1.8 confusion)

| | **dbt UNIT tests** (`unit_tests:`, this section §6.7E) | **dbt DATA tests** (`data_tests:` / column-level `tests:`, §6.7A above) |
|---|---|---|
| What it tests | The **TRANSFORMATION LOGIC** of one model | The **OUTPUT DATA** after the model materializes |
| Input | **MOCK rows** you supply inline in YAML (`given:`) | **REAL warehouse rows** the model produced |
| When it runs | At `dbt build` (before/alongside materialization, on the mock input — does NOT scan warehouse data) | At `dbt test` (after the model materializes — runs SQL against the warehouse output) |
| YAML top-level key | `unit_tests:` | `data_tests:` (model/column-level under `models:`) |
| Examples of test bodies | `given:` rows + `expect:` rows | `not_null`, `unique`, `accepted_values`, `relationships`, `dbt_utils.expression_is_true` |
| Selector | `dbt test --select test_type:unit` | `dbt test --select test_type:data` |
| Question shape | "Does my `coalesce(first, last)` logic produce `'Ada Lovelace'`?" | "Are there any NULL `customer_id` rows after the build?" |

> **DO-NOT-CONFUSE callout:** unit-test `given:` / `expect:` rows **DO NOT** go under `data_tests:`. Likewise, `not_null` / `unique` / `accepted_values` **DO NOT** go under `unit_tests:`. They are two different YAML blocks with two different purposes. Putting `not_null` under `unit_tests:` will fail YAML schema validation; putting `given:` / `expect:` under `data_tests:` will be silently ignored as unrecognized config.

#### YAML schema — exact keys (verbatim from docs.getdbt.com)

```yaml
# Lives under models/<your_subdir>/_unit_tests.yml (or any .yml under model-paths)
# NOT under tests/ — unit tests MUST live in model-paths, per docs.getdbt.com.
unit_tests:
  - name: <test-name>                          # REQUIRED — unique identifier
    model: <model-name>                        # REQUIRED — the model under test
    given:                                     # REQUIRED — list of mock inputs
      - input: ref('<upstream_model>')         # ref(...) OR source('<src>','<tbl>')
        format: dict                           # OPTIONAL — dict (default) | csv | sql
        rows:                                  # inline mock rows (or use fixture: <name>)
          - {col_a: <value>, col_b: <value>}
          - {col_a: <value>, col_b: <value>}
      - input: source('app', 'lookup_tbl')     # additional inputs as needed
        format: csv
        rows: |                                # CSV-as-string when format: csv
          col_x,col_y
          1,foo
          2,bar
    expect:                                    # REQUIRED — expected OUTPUT rows
      format: dict                             # OPTIONAL — dict (default) | csv | sql
      rows:
        - {out_col_1: <value>, out_col_2: <value>}
```

**Three accepted `format:` values** (verified at [docs.getdbt.com/reference/resource-properties/data-formats](https://docs.getdbt.com/reference/resource-properties/data-formats)):

- `dict` (DEFAULT — used when `format:` is omitted) — `rows:` is a YAML list of dictionaries (`- {col: val, ...}`).
- `csv` — `rows:` is either an inline CSV string (with header row) or `fixture: <name>` pointing to a CSV file under `tests/fixtures/`.
- `sql` — `rows:` is a SQL `SELECT` statement that returns the mock rows (use sparingly; defeats the point of mock data).

Either `rows:` OR `fixture:` (NOT both) — `fixture: my_csv_name` references a file in `tests/fixtures/my_csv_name.csv` or `.sql`.

#### Concrete worked example — a `full_name` derivation model

Suppose your model `models/marts/dim_customers.sql` derives `full_name` from `first_name` and `last_name`:

```sql
-- models/marts/dim_customers.sql
SELECT
  customer_id,
  COALESCE(first_name, '') || ' ' || COALESCE(last_name, '') AS full_name,
  CASE
    WHEN total_amount >= 1000 THEN 'high'
    WHEN total_amount >= 100  THEN 'mid'
    ELSE 'low'
  END AS amount_tier
FROM {{ ref('stg_customers') }}
```

The unit test that asserts the logic:

```yaml
# models/marts/_unit_tests.yml
unit_tests:
  - name: test_dim_customers_full_name_and_tier
    model: dim_customers
    given:
      - input: ref('stg_customers')
        rows:
          - {customer_id: 1, first_name: 'Ada',  last_name: 'Lovelace', total_amount: 1500}
          - {customer_id: 2, first_name: 'Linus', last_name: NULL,      total_amount: 250}
          - {customer_id: 3, first_name: NULL,  last_name: 'Hopper',    total_amount: 50}
    expect:
      rows:
        - {customer_id: 1, full_name: 'Ada Lovelace', amount_tier: 'high'}
        - {customer_id: 2, full_name: 'Linus ',       amount_tier: 'mid'}
        - {customer_id: 3, full_name: ' Hopper',      amount_tier: 'low'}
```

**What this asserts at build time**: given exactly three mock rows from `stg_customers`, the model's SELECT logic must produce exactly the three `expect` rows. If your COALESCE handles NULLs wrong, the test fails BEFORE the model writes anything to the warehouse — you catch a logic bug at PR-review time, not on next-day ops.

#### Running unit tests — the commands

```bash
# Run ONLY unit tests (no data tests, no models):
dbt test --select test_type:unit

# Run unit tests for ONE model:
dbt test --select dim_customers,test_type:unit

# dbt build runs unit tests as part of the model build pipeline.
# For each model, the order is: unit tests -> materialization -> data tests -> downstream.
# A failing unit test FAILS THE BUILD before the model writes to the warehouse.
dbt build
```

Per [docs.getdbt.com/docs/build/unit-tests](https://docs.getdbt.com/docs/build/unit-tests): "unit tests are run by both `dbt test` and `dbt build` commands."

#### DO-NOT-WRITE — banned unit-test claims (cite-or-omit)

| DO NOT write | Why it's wrong |
|---|---|
| `data_tests:` with `given:` / `expect:` underneath | **WRONG top-level key.** Unit tests live under `unit_tests:` (NOT `data_tests:` and NOT under a column's `tests:` list). Putting `given:` / `expect:` under `data_tests:` is silently treated as unrecognized config and never runs. |
| `unit_tests:` with `not_null:` or `unique:` underneath | **CATEGORY ERROR.** `not_null` / `unique` / `accepted_values` are **data tests**, not unit tests. They go under `data_tests:` (model/column level), NOT `unit_tests:`. |
| `given:` with `data:` (instead of `rows:`) | **FABRICATED key.** The mock-rows key is `rows:`, NOT `data:`. |
| `expect:` with `result:` or `output:` (instead of `rows:`) | **FABRICATED key.** The expected-rows key is `rows:`, NOT `result:` / `output:`. |
| `format: yaml` or `format: json` | **FABRICATED values.** The three accepted `format:` values are `dict`, `csv`, `sql`. Default is `dict` when omitted. |
| "Unit tests query the warehouse output" | **WRONG.** Unit tests run on MOCK input rows defined inline; they do NOT scan warehouse data. That's what data tests do (§6.7A). |
| "Unit tests are dbt 1.6+" or "dbt 1.7+" | **WRONG version.** Unit tests are **dbt 1.8+** (GA in 1.8). Earlier versions do not parse `unit_tests:`. |
| Putting the `unit_tests:` file under `tests/` | **WRONG directory.** Unit test YAML files MUST live under your `model-paths` (e.g., `models/`), NOT under `tests/`. Per [docs.getdbt.com/reference/resource-properties/unit-tests](https://docs.getdbt.com/reference/resource-properties/unit-tests). |
| `dbt test --select test_type:unit_test` (with the `_test` suffix) | **WRONG selector value.** The selector is `test_type:unit` (no `_test` suffix). The matching data-test selector is `test_type:data`. |

#### Cross-references

- **§6.7A** (immediately above) — dbt **DATA tests** (severity, store_failures, expression_is_true vs not_null_proportion). DO-NOT-CONFUSE: data tests = assertions on REAL warehouse output; unit tests (this §6.7E) = assertions on MOCK input.
- **§6.7D** (above) — dbt seeds (small static CSVs as lookup tables). Seeds can be referenced from unit tests via `input: ref('seed_name')` for cases where the mock input is a stable reference table.
- Official docs: [docs.getdbt.com/docs/build/unit-tests](https://docs.getdbt.com/docs/build/unit-tests), [docs.getdbt.com/reference/resource-properties/unit-tests](https://docs.getdbt.com/reference/resource-properties/unit-tests), [docs.getdbt.com/reference/resource-properties/data-formats](https://docs.getdbt.com/reference/resource-properties/data-formats), [docs.getdbt.com/blog/announcing-unit-testing](https://docs.getdbt.com/blog/announcing-unit-testing).

### 6.7F LEADING CANONICAL — dbt `--select` set-operators + graph-operators (comma = AND/intersection, space = OR/union)

> **Keyword anchors:** dbt select comma vs space, dbt tag AND OR, dbt intersection union selector, dbt build multiple tags BOTH, dbt --select set operators, dbt graph operators +model model+. Verified at [docs.getdbt.com/reference/node-selection/set-operators](https://docs.getdbt.com/reference/node-selection/set-operators) and [docs.getdbt.com/reference/node-selection/graph-operators](https://docs.getdbt.com/reference/node-selection/graph-operators).

**The single rule you MUST memorize — comma vs space have OPPOSITE semantics:**

| Form | Operator | Semantics | Example | Selects |
|---|---|---|---|---|
| `--select "tag:a tag:b"` (SPACE between) | **UNION (OR)** | Nodes matching **EITHER** selector | `dbt build --select "tag:nightly tag:hourly"` | nodes tagged `nightly` OR `hourly` |
| `--select "tag:a,tag:b"` (COMMA, no space) | **INTERSECTION (AND)** | Nodes matching **BOTH** selectors at once | `dbt build --select "tag:nightly,config.materialized:incremental"` | nodes that are BOTH tagged `nightly` AND materialized as `incremental` |

**Graph operators combine with set operators inside each argument:** `+model_name` = the model and all its upstream parents; `model_name+` = the model and all its downstream children; `+model_name+` = both directions; `1+model_name` / `model_name+2` = bounded-depth variants. Other selector methods: `path:models/marts/finance`, `config.materialized:incremental`, `state:modified` (with `--state target/`), `source_status:fresher+`, `result:error+`.

**Combining unions + intersections in one command** (each space-separated argument is evaluated independently, then unioned): `dbt build --select "tag:nightly,config.materialized:incremental tag:hourly,config.materialized:view"` = (nightly AND incremental) OR (hourly AND view). The comma binds tighter than the space.

**DO-NOT-WRITE — banned set-operator claims (the comma/space rule trips everyone the first time):**

| DO NOT write | Why it's wrong |
|---|---|
| "`--select tag:a,tag:b` means tag a OR tag b" | **FALSE — comma is AND / intersection, not OR.** It runs ONLY nodes that have BOTH tag a AND tag b. The OR form is space-separated: `--select "tag:a tag:b"`. |
| "`--select "tag:a tag:b"` means tag a AND tag b" | **FALSE — space is OR / union, not AND.** It runs nodes that have EITHER tag a OR tag b. The AND form is comma-separated with no space: `--select tag:a,tag:b`. |
| "Commas and spaces are interchangeable in `--select`" | **FALSE — they have opposite semantics** (intersection vs union). Mixing them changes which nodes run. |
| "`+model` means downstream children" | **FALSE — leading `+` is UPSTREAM parents** (ancestors / dependencies). `model+` (trailing `+`) is downstream children. `+model+` is both directions. |

---

### 6.7G LEADING CANONICAL — dbt `var()` for per-run configurable values (NOT `{% set %}`)

> **Keyword anchors:** dbt var configurable, dbt vars block dbt_project.yml, dbt run --vars override, parameterize dbt model lookback days, var vs set dbt, var default value, dbt variable from CLI, change dbt model parameter without code change. Verified at [docs.getdbt.com/reference/dbt-jinja-functions/var](https://docs.getdbt.com/reference/dbt-jinja-functions/var) and [docs.getdbt.com/docs/build/project-variables](https://docs.getdbt.com/docs/build/project-variables).

**The three-piece pattern — use ALL three together for a tunable knob:**

1. **In the model** — read the variable with a fallback default:
   ```sql
   SELECT *
   FROM {{ ref('stg_events') }}
   WHERE occurred_at >= date_add('day', -{{ var('lookback_days', 30) }}, current_date)
   ```
   `var('name', default)` reads a project variable; the `default` fires ONLY if the var isn't defined anywhere (project file or CLI).

2. **In `dbt_project.yml`** — define defaults under a TOP-LEVEL `vars:` block (a sibling of `models:`, NOT nested inside it):
   ```yaml
   vars:
     lookback_days: 30
     event_type: signup
   ```

3. **At run time** — override without changing committed code, using the **`--vars` flag (plural, taking a YAML dict)**:
   ```bash
   dbt run --select stg_events --vars '{lookback_days: 7}'
   # Multiple vars: dbt run --vars '{lookback_days: 7, event_type: purchase}'
   ```
   Precedence: CLI `--vars` > `dbt_project.yml` `vars:` > the `default` second-arg to `var(...)`.

**Contrast — when to pick `var()` vs `{% set %}`:**

| Need | Use | Why |
|---|---|---|
| A value you want **configurable per dbt run** (tunable knob, environment-specific, backfill override) | **`var('name', default)`** + `vars:` block + `--vars` CLI | The only mechanism dbt exposes at run time without a code change. |
| A true compile-time constant inside one model file (e.g., a list of statuses Jinja-loops over to build SQL) | `{% set statuses = ['paid', 'refunded'] %}` | Jinja LOCAL variable — hardcoded at compile time, scoped to the file, NOT overridable. Fine for genuine constants. |

**DO-NOT-WRITE — banned patterns:**

| DO NOT write | Why it's wrong |
|---|---|
| `{% set lookback_days = 30 %}` for a value you want to tweak per run | **WRONG TOOL.** `{% set %}` is a Jinja LOCAL — hardcoded at compile time, not configurable via CLI. Use `var('lookback_days', 30)` + a `vars:` block + `--vars` instead. |
| `dbt run --var 'lookback_days: 7'` (singular `--var`) | **FLAG NAME WRONG.** The flag is **`--vars`** (plural), and it takes a YAML dict: `--vars '{lookback_days: 7}'`. Singular `--var` is not a dbt CLI flag and will error. |
| `dbt run --vars lookback_days=7` (key=value, no YAML) | **WRONG FORMAT.** `--vars` expects a YAML dict as a string: `--vars '{lookback_days: 7}'`. The `key=value` form is from other tools. |
| Placing `vars:` nested INSIDE the `models:` block in `dbt_project.yml` | **WRONG SCOPE.** Project-level `vars:` is a TOP-LEVEL key in `dbt_project.yml` (a sibling of `models:`). Nesting it inside `models:` makes it a model-config that dbt ignores as a variable. |
| `var('lookback_days')` with NO default, when the var might not be set in any environment | **Runtime error** — `var()` without a default raises if the variable isn't defined anywhere. Always provide a sensible default for non-critical knobs: `var('lookback_days', 30)`. |

---

### 6.7G2 — dbt `env_var()` / profiles.yml secrets — MOVED to the dedicated top-level "dbt connection & secrets" section (above §6)

> **The canonical for `env_var()`, `DBT_ENV_SECRET_`, and the profiles.yml Trino-password pattern is now in the standalone section titled "dbt connection & secrets — profiles.yml, env_var(), DBT_ENV_SECRET_" placed just BEFORE §6 "Worked end-to-end example."** It was promoted out of the "dbt tests to add" cluster because connection/secrets is a separate dbt-OPS concern from tests. The full content (one-fact summary, profiles.yml Trino target template, DBT_ENV_SECRET_ scrub behavior, env_var() vs var() comparison, DO-NOT-WRITE table) lives there. The §6.7 routing anchor at the top of this section still points reliably to it.

---

### 6.7H LEADING CANONICAL — dbt documentation (`description:` in schema YAML, `{% docs %}` blocks, `dbt docs generate` + `serve`)

> **Keyword anchors:** dbt docs generate serve, dbt model description, dbt column description, where to write dbt descriptions, dbt doc blocks {% docs %}, dbt documentation site, catalog.json manifest.json, reuse dbt description across models. Verified at [docs.getdbt.com/docs/build/documentation](https://docs.getdbt.com/docs/build/documentation) and [docs.getdbt.com/reference/commands/cmd-docs](https://docs.getdbt.com/reference/commands/cmd-docs).

**Where descriptions live:** in a **schema YAML file** (e.g. `models/_models.yml` or `models/marts/_schema.yml`) — a `description:` key on each model AND on each column under `columns:`. Same `description:` key also works on `sources:`, `seeds:`, `snapshots:`, `macros:`. **Descriptions do NOT go inline in the model `.sql` file** — only in the YAML.

**Long-form / reusable doc blocks:** define `{% docs my_block %} ... markdown ... {% enddocs %}` in any `.md` file under a configured model path, then reference it from the YAML with `description: "{{ doc('my_block') }}"`. Lets you reuse one description across many models/columns and write richer markdown (headers, links, lists) than a YAML one-liner.

**Generate + serve:** `dbt docs generate` builds two artifacts under `target/` — `manifest.json` (full project graph + node metadata) and `catalog.json` (column types and stats, populated by querying the warehouse `information_schema`). Then `dbt docs serve` serves a browsable HTML site locally (default port 8080). On a k8s/on-prem setup you can instead host the generated static files behind nginx.

**Worked example — `models/marts/_schema.yml`:**
```yaml
version: 2
models:
  - name: fct_orders
    description: "One row per order. Public contract for downstream BI."
    columns:
      - name: order_id
        description: "Surrogate key. Stable across re-runs via md5(natural_keys)."
      - name: order_total_cents
        description: "{{ doc('order_total_cents') }}"   # pulls from a {% docs %} block
```

**DO-NOT-WRITE — banned patterns:**

| DO NOT write | Why it's wrong |
|---|---|
| Put `-- description: ...` comments INLINE in the model `.sql` file expecting them to appear in the docs site | **WRONG LOCATION.** dbt scrapes descriptions ONLY from schema YAML (`description:` keys) and `{% docs %}` blocks. SQL comments are never harvested into `manifest.json` or the docs site. |
| "`dbt docs generate` runs / materializes the models" | **WRONG.** `dbt docs generate` only compiles metadata into `manifest.json` and queries the warehouse `information_schema` to populate `catalog.json`. It does NOT execute model SQL or materialize tables — that's `dbt run` / `dbt build`. |
| Confuse `dbt docs` with `dbt source freshness` (§6.7B) or model contracts (§6.7C) | Different mechanisms. Docs = human-readable descriptions + lineage site. Source freshness = staleness check on raw inputs (`target/sources.json`). Contracts = build-time declared-vs-actual schema enforcement on outputs. |
| `{% docs %}` block placed in a `.sql` file | **WRONG FILE TYPE.** Docs blocks must live in `.md` files under a configured resource path. dbt only scans `.md` files for `{% docs %}` blocks. |

---

### 6.7H2 LEADING CANONICAL — dbt EXPOSURES are the NATIVE first-class feature for declaring downstream/external consumers (BI dashboards, ML pipelines, reverse-ETL)

> **Keyword anchors (route the question here):** dbt exposures, exposures.yml, register a downstream consumer in dbt, external dashboard depends on dbt model, Looker/Tableau dashboard in dbt lineage, track what consumes a dbt model, lineage for external consumers, mark a dbt model as exposed, downstream BI / ML / reverse-ETL in dbt DAG, declare a downstream user of a dbt model, document who consumes a dbt model, dbt depends_on type exposure. Verified at [docs.getdbt.com/docs/build/exposures](https://docs.getdbt.com/docs/build/exposures) and [docs.getdbt.com/reference/exposure-properties](https://docs.getdbt.com/reference/exposure-properties).

**Exposures ARE the native dbt feature for this** — NOT a workaround, NOT an open-source plugin, NOT something you have to bolt on with `post_hook` / external metadata. An `exposures.yml` resource is a first-class dbt node type (alongside `models`, `sources`, `seeds`, `snapshots`, `tests`, `metrics`, `macros`) that registers a downstream/external consumer (a BI dashboard, an ML pipeline, a reverse-ETL sync, a notebook, an application) in the dbt DAG, with explicit `depends_on: [ref('model_name')]` edges pointing UP into the dbt models it consumes. `dbt docs generate` renders the exposure as a downstream-leaf node in the lineage graph; `dbt build --select +exposure:my_dashboard` builds every upstream model the exposure depends on; `dbt test --select +exposure:my_dashboard` runs every upstream test.

**Minimal `exposures.yml` (placed in `models/` next to schema YAMLs, OR in a dedicated `exposures/` subdirectory — dbt picks up any `*.yml` under configured model paths):**

```yaml
version: 2
exposures:
  - name: revenue_dashboard          # snake_case, unique within the project
    label: "Revenue Dashboard"       # human-readable name for the docs site
    type: dashboard                  # one of: dashboard | notebook | analysis | ml | application
    maturity: high                   # high | medium | low (optional; communicates trust level)
    url: https://looker.example.com/dashboards/123
    description: "Top-line ARR + MRR rollup, refreshed daily; exec review Monday 9am."
    owner:
      name: "Revenue Analytics"
      email: revenue@example.com
    depends_on:
      - ref('fct_orders')            # upstream dbt model
      - ref('dim_customers')         # upstream dbt model
      - source('billing', 'invoices')  # upstream raw source also allowed
```

**What it gives you (all native, no extra tooling):**
- **Lineage visibility** — `dbt docs generate` puts the exposure as a downstream node on the lineage DAG in the docs site, so anyone can see "this dashboard depends on `fct_orders`" without leaving dbt-docs.
- **Selective build/test** — `dbt build --select +exposure:revenue_dashboard` runs every upstream model + test the dashboard transitively depends on (the `+` is the dbt graph operator for "all ancestors"); pair with CI so a PR that breaks `fct_orders` flags the affected dashboards.
- **Impact analysis** — `dbt ls --select +model:fct_orders --resource-type exposure` lists every exposure (dashboard/ML pipeline) downstream of `fct_orders`, so you know who to notify before a breaking change.
- **Manifest API** — exposures appear in `manifest.json` as `exposure.<project>.<name>` nodes; downstream metadata tools (DataHub, Atlan, OpenMetadata) can ingest them via the manifest.

**The five `type:` values and when to pick each:** `dashboard` (Looker, Tableau, Mode, Metabase, Superset, Power BI panels); `notebook` (Jupyter, Hex, Databricks notebooks that read dbt models); `analysis` (one-off SQL analyses or reports); `ml` (training pipelines, feature stores, inference jobs that consume dbt-curated data); `application` (production services, reverse-ETL syncs like Hightouch/Census, customer-facing app queries). Pick the value that best describes the downstream consumer — dbt does not enforce semantics beyond rendering the right node icon, but downstream tools (DataHub, Atlan) use the type to categorize lineage destinations.

**Pair exposures with model contracts (§6.7C).** Exposures declare WHO consumes a model; contracts (§6.7C) lock the SCHEMA the consumer can rely on. The full pattern: (a) every public model has `config: contract: {enforced: true}` + a column list; (b) every consumer is registered as an exposure with `depends_on: [ref('that_model')]`. Together this gives end-to-end "if you change this column type, here is exactly which dashboards/ML jobs break" coverage from `dbt build` + `dbt ls --resource-type exposure`.

**DO-NOT-WRITE — exposure framing that misleads engineers:**

| DO NOT write | Why it's wrong |
|---|---|
| "dbt has no native way to track external/downstream dependencies; you have to work around it" / "the closest dbt offers is a workaround" | **WRONG framing.** Exposures ARE the native, documented, first-class dbt resource for exactly this. They are not a workaround — they are the feature. State them as the native answer; do not open with "dbt doesn't natively support this." |
| "Exposures are an external plugin / dbt package you have to install" | **WRONG.** Exposures are built into dbt-core (the `exposures` node type has been part of dbt-core since v0.18). No `dbt deps`, no `packages.yml` entry, no extension needed — just an `exposures.yml` file. |
| "Use `post_hook` to register a downstream dashboard" / "Use a custom macro to track external consumers" | **WRONG mechanism.** Both still work as escape hatches for unrelated needs, but the canonical mechanism for "register a downstream consumer in the dbt lineage DAG" is exposures. Post-hooks emit SQL at the warehouse, not metadata to the manifest. |
| `depends_on: [fct_orders]` (bare model name, no `ref()`) | **WRONG syntax.** The `depends_on:` list elements MUST be `ref('model_name')` (for dbt models) or `source('source_name', 'table_name')` (for raw sources) — same `ref()`/`source()` Jinja functions used in model SQL. Bare names do not resolve. |
| "Exposures execute SQL / materialize a table / write data to the warehouse" | **WRONG.** Exposures are metadata-only — they declare a dependency edge in the DAG and appear in the docs site. They do NOT run SQL, do NOT write to the warehouse, do NOT have a `materialized:` config. `dbt run` does nothing to exposures; `dbt docs generate` is what surfaces them. |
| "Set `materialized: exposure` in `dbt_project.yml`" | **FABRICATED.** There is no `materialized: exposure`. Exposures are a separate resource type declared in `exposures.yml`, not a materialization. |

**Cross-references:**
- For dbt documentation generation + lineage site (the surface that renders the exposure): see [§6.7H](#67h-leading-canonical--dbt-documentation-description-in-schema-yaml--docs--blocks-dbt-docs-generate--serve).
- For dbt model contracts (the OUTPUT-side schema lock that pairs with exposures): see [§6.7C](#67c-leading-canonical--dbt-model-contracts-declared-vs-actual-schema-check-at-build-time-not-runtime).
- For dbt source freshness (the INPUT-side liveness check): see [§6.7B](#67b-leading-canonical--dbt-source-freshness-sourcesyml-loaded_at_field-dbt-source-freshness-command).
- Official dbt docs source-of-truth: [docs.getdbt.com/docs/build/exposures](https://docs.getdbt.com/docs/build/exposures) and [docs.getdbt.com/reference/exposure-properties](https://docs.getdbt.com/reference/exposure-properties).

---

### 6.7I LEADING CANONICAL — dbt GRANTS: native `grants:` config vs `post_hook` GRANT (+ the dbt-trino roles bug #12862)

> **Keyword anchors:** dbt grants config, dbt auto grant select on build, dbt grants vs post_hook, GRANT TO ROLE Trino, dbt-trino grants role bug 12862, idempotent grants dbt, dbt +grants merge, dbt grants replace, dbt-trino TO ROLE workaround, dbt post_hook GRANT SELECT.

**Two ways to ship GRANTs from dbt.** Native [`grants:` config](https://docs.getdbt.com/reference/resource-configs/grants) (the canonical, idempotent way — dbt re-applies after every run so the live object's grants EXACTLY match the config, fixing drift), and `post_hook` (a raw SQL escape hatch). Three native forms:

```jinja
-- In-model Jinja
{{ config(materialized='table', grants={'select': ['analyst_role']}) }}
```
```yaml
# Schema YAML (models/schema.yml)
models:
  - name: my_model
    config:
      grants:
        select: ['analyst_role']
```
```yaml
# Project-level (dbt_project.yml)
models:
  +grants:
    select: ['analyst_role']
```

**REPLACE vs MERGE.** By DEFAULT `grants:` REPLACES existing grants on the object (clobbers anything not in the config). To ADD to (merge with) the less-specific / inherited grants instead of clobbering, prefix the privilege with `+`: `{'+select': ['analyst_role']}`. Each privilege controls its own merge/replace independently — verified at [docs.getdbt.com/reference/resource-configs/grants](https://docs.getdbt.com/reference/resource-configs/grants).

**LOAD-BEARING CAVEAT — dbt-trino's `grants:` config + Trino roles (this stack):** dbt-trino currently emits `GRANT <priv> ON <obj> TO <name>` (bare-name / USER form), NOT `TO ROLE <name>` — tracked at [dbt-labs/dbt-core #12862](https://github.com/dbt-labs/dbt-core/issues/12862) (open). On a Trino + OPA + ROLE-based principal model (this stack), a bare name is interpreted as a USER, not a ROLE — so the `grants:` config grants to the wrong principal type. **Robust workaround for ROLE grantees: use `post_hook` with the explicit `TO ROLE` keyword:**

```jinja
{{ config(
    materialized='table',
    post_hook="GRANT SELECT ON {{ this }} TO ROLE analyst_role"
) }}
```

Trino's GRANT syntax is `GRANT <priv> ON <obj> TO ( user | USER user | ROLE role )` ([trino.io/docs/current/sql/grant.html](https://trino.io/docs/current/sql/grant.html)) — **omit the `ROLE` keyword and the bare name resolves to a USER**, so for a role grantee write `TO ROLE <role>` explicitly. (`post_hook` is not idempotent the way `grants:` is — re-running won't REVOKE stale grants — but it is the correct shape for ROLE grantees today, until #12862 lands.)

**OPA caveat (this stack).** Production authorization is **Open Policy Agent**. The engine-level GRANT is issued and persisted, but **enforcement depends on the OPA policy bundle** — engine GRANTs and OPA policy are separate authorization layers. Coordinate role names + privilege effects with the external governance policy (see `prod_info.md`).

**DO-NOT-WRITE — banned patterns:**

| DO NOT write | Why it's wrong |
|---|---|
| Assume the dbt-trino `grants:` config emits `GRANT ... TO ROLE <name>` for role grantees | **WRONG.** Per [#12862](https://github.com/dbt-labs/dbt-core/issues/12862), dbt-trino emits the bare-name / USER form `GRANT ... TO <name>` — which Trino resolves as a USER, not a ROLE. For ROLE grantees today, use `post_hook` with explicit `TO ROLE`. |
| `post_hook="GRANT SELECT ON {{ this }} TO analyst_role"` (bare name, no `ROLE` keyword) when the grantee IS a Trino role | Trino interprets the bare name as a **USER**. The grant succeeds syntactically but binds to the wrong principal type — analysts in `analyst_role` won't get access. Write `TO ROLE analyst_role` explicitly. |
| Issue grants from an Oracle-style ad-hoc DBA session (`GRANT SELECT ON sch.tbl TO analyst_role;` in a one-off Trino client) | **Not idempotent + not version-controlled.** Drift returns on the next rebuild (`CREATE OR REPLACE TABLE` re-creates the object without the grant). Put it in `grants:` (or `post_hook` for ROLE) so it's reapplied on every build. |
| Use `pre_hook` to GRANT (instead of `post_hook`) | **WRONG ORDER.** `pre_hook` runs BEFORE the model materializes. If the model uses `materialized='table'`, the prior table is DROPPED and re-CREATED — your pre-hook GRANT either errors (object doesn't exist yet on first build) or grants on the about-to-be-dropped object. GRANT belongs in `post_hook` (after the new object exists) or in native `grants:`. |
| Expect `grants:` to revoke privileges that pre-existed before dbt managed the object (without re-running) | dbt only reconciles at run time. If you add `grants:` to a model that already has external grants, dbt syncs on the NEXT build of that model. Force it via `dbt build --select my_model` (see §6.7F). |

**Cross-references (dbt-CLI / config cluster):** §6.7F (`--select` graph-operators), §6.7H (dbt docs site). For the broader dbt-trino model + Trino RBAC concepts, see also §6.7A (tests / severity) and the OPA authorization layer in [resource 22 §2.8.1](22-trino-federation-postgresql.md).

---

### 6.7J LEADING CANONICAL — dbt `persist_docs` (push schema.yml `description:` into ENGINE comments via `COMMENT ON TABLE` / `COMMENT ON COLUMN`)

> **Keyword anchors:** dbt persist_docs, schema.yml description not showing, push column descriptions to table, COMMENT ON COLUMN dbt, Iceberg column comments, SHOW COLUMNS comment, dbt docs vs table metadata, persist_docs relation columns, my dbt descriptions are not in Trino.

**The fact (verified at [docs.getdbt.com/reference/resource-configs/persist_docs](https://docs.getdbt.com/reference/resource-configs/persist_docs)):** `persist_docs` "Optionally persist [resource descriptions] as column and relation comments in the database." When enabled, dbt emits `COMMENT ON TABLE ... IS '...'` and per-column `COMMENT ON COLUMN ... IS '...'` against the engine — so your schema.yml `description:` lands as actual table/column comments stored in Trino's Iceberg metadata. Supported by dbt-trino.

**The two config shapes — both valid:**
```jinja
-- A. Model-level inline (overrides project default for this model only)
{{ config(persist_docs={"relation": true, "columns": true}) }}
```
```yaml
# B. Project-level default in dbt_project.yml (applies to every model under the path)
models:
  my_project:
    +persist_docs:
      relation: true
      columns: true
```
Two boolean keys: `relation` (table comment) and `columns` (per-column comments) — flip either independently.

**How to SEE the comments in Trino after `dbt build`:** `SHOW COLUMNS FROM iceberg.analytics.fct_orders;` — output has columns `Column | Type | Extra | Comment` ([trino.io/docs/current/sql/show-columns.html](https://trino.io/docs/current/sql/show-columns.html)); the `Comment` column shows the persisted description. Manual / non-dbt equivalents: `COMMENT ON TABLE iceberg.analytics.fct_orders IS '...'` and `COMMENT ON COLUMN iceberg.analytics.fct_orders.order_id IS '...'` ([trino.io/docs/current/sql/comment.html](https://trino.io/docs/current/sql/comment.html)).

**Explicit DISTINCTION from §6.7H — two DIFFERENT mechanisms, you usually want BOTH:**

| | §6.7H `dbt docs generate / serve` | §6.7J `persist_docs` (this section) |
|---|---|---|
| Where descriptions LAND | dbt DOCS SITE (`target/catalog.json` + HTML) | ENGINE metadata (`COMMENT ON TABLE` / `COMMENT ON COLUMN` issued against Trino) |
| Who sees them | Anyone browsing the dbt docs site | Anyone running `SHOW COLUMNS` in Trino, or any BI tool reading column comments via JDBC |
| Triggered by | `dbt docs generate` | `dbt run` / `dbt build` (on each model materialization) |
| Required for BI tool catalogs (Tableau, Superset, dbeaver) to see column descriptions | No | **Yes** — they read comments from the engine, not from dbt's site |

If your schema.yml `description:` doesn't show up under `SHOW COLUMNS` or in the BI tool's column hover, the cause is almost always: `persist_docs` is not set. `dbt docs generate` does NOT push to engine metadata.

> **Cross-references:** §6.7H (dbt docs site / `{% docs %}` blocks — the YAML `description:` keys feed BOTH §6.7H and §6.7J). §6.7C (model contracts — separate mechanism, enforces declared-vs-actual schema, not comments).

---

### 6.7K LEADING CANONICAL — dbt source freshness COMMANDS quick-card (`dbt source freshness`, `dbt build --select source_status:fresher+`) — DO NOT use `state:new`

> **READ THIS FIRST if your question contains `dbt source freshness` command, `source_status:fresher+`, `fail build on stale source`, `stale ingestion`, `gate downstream on freshness`, `which dbt command checks freshness`, or `state:new` and freshness in the same sentence.** This is the **command-level companion** to §6.7B (which is the YAML/`loaded_at_field`/threshold canonical). Verified at [docs.getdbt.com/docs/build/sources](https://docs.getdbt.com/docs/build/sources), [docs.getdbt.com/reference/commands/source](https://docs.getdbt.com/reference/commands/source), and [docs.getdbt.com/reference/node-selection/methods](https://docs.getdbt.com/reference/node-selection/methods) (WebFetched 2026-06-06).

**The two commands — and only these two — concern freshness:**

| Command | What it does |
|---|---|
| `dbt source freshness` | Runs `SELECT MAX({{ loaded_at_field }}) FROM ...` per source, compares to `now()` against `warn_after` / `error_after` thresholds, writes per-source state (`pass` / `warn` / `error` / `runtime error`) to `target/sources.json`. An `error_after` breach returns a **non-zero exit code** — that is how CI fails loudly on stale ingestion. |
| `dbt build --select source_status:fresher+` | Only builds models DOWNSTREAM of sources that became fresher since the previous `target/sources.json` (the `source_status:fresher+` graph-state selector — quoted verbatim from docs.getdbt.com/docs/build/sources: *"Use the `dbt build --select source_status:fresher+` command to build and test models downstream of fresher sources."*). Skips rebuilds of sub-graphs whose inputs haven't moved. |

**The CI two-stage pattern that actually fails downstream builds on stale sources:**
```bash
dbt source freshness                              # stage 1 — exits non-zero on error_after breach (with `set -e`, halts CI)
dbt build --select source_status:fresher+         # stage 2 — only rebuild what got fresher
```

**IN-LINE SIGNAL (corrective comment for any responder copying these lines):**
```bash
# CORRECT: dbt source freshness validates loaded_at_field thresholds (warn_after / error_after).
# CORRECT: dbt build --select source_status:fresher+   # fail/limit downstream builds based on freshness state.
# WRONG  : dbt test --select state:new                 # state:new is a slim-CI NODE selector, NOT freshness.
```

> **DO-NOT-WRITE — banned freshness-command claims:**
> | Wrong claim | Why it's wrong |
> |---|---|
> | "`dbt test --select state:new` checks source freshness." | **FALSE.** `state:new` is the dbt **slim-CI node selector** that picks nodes whose definition is NEW vs a `--state target/` manifest — it is GRAPH-state, not freshness-state. Freshness is `dbt source freshness` and `source_status:fresher+`. They are different mechanisms, different artifacts (`manifest.json` for `state:*` vs `target/sources.json` for `source_status:*`). |
> | "`dbt run --check-freshness`" or "`dbt build --check-freshness`" | **FABRICATED FLAG** (also banned in §6.7B). No such CLI flag exists; gate freshness with the two-stage CI pattern above. |
> | "`dbt source freshness` blocks `dbt run` automatically." | **FALSE.** It is a separate command; the CI runner's exit-code handling (e.g., `set -e`) is what halts the next stage. |

**dbt-trino note (one line):** `loaded_at_field` must be a Trino-queryable timestamp column on the source (e.g. an Iceberg `ingested_at` / `_loaded_at` / `updated_at`) — the warehouse-metadata fallback is NOT supported on dbt-trino (see §6.7B for the supported-adapter list); setting `freshness: null` opts a table out.

> **Cross-references:** **§6.7B** is the full YAML / `loaded_at_field` / `warn_after` / `error_after` canonical — read that first for declaring freshness. §6.7F (the `--select` selector grammar). For ingestion-side `_loaded_at` / watermark-column patterns see [resource 13 § watermark column patterns](13-postgres-to-iceberg-ingestion.md).

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
8. **Partition the migrated table to match the dominant filter.** Oracle table partitioning hints don't carry over — set `'partitioning': "ARRAY['<column>']"` inside the dbt `properties` block for an incremental Iceberg model. The Iceberg connector's table-property name is `partitioning` (per [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html)), and dbt-trino passes the dict key verbatim into Trino's `CREATE TABLE ... WITH (...)` clause. `partitioned_by` is the HIVE connector's key — do NOT use it here, the production stack is Iceberg. See [resource 28 § LEADING CANONICAL — dbt-trino partition key for Iceberg vs Hive](28-complex-sql-performance-trino-dbt.md), [resource 10](10-lakehouse-partitioning.md), and [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs).
9. **Schedule the dbt run.** Oracle's `DBMS_SCHEDULER.CREATE_JOB` has no dbt equivalent — schedule `dbt run --select fct_orders_daily+` from cron, k8s CronJob, or Airflow.
10. **Maintenance.** Iceberg tables need `ALTER TABLE ... EXECUTE optimize` and `expire_snapshots` regularly — see [resource 17](17-iceberg-table-maintenance.md). Oracle's auto-segment-management has no direct equivalent; you schedule the maintenance.

---

## 7A. Deep-dive: the 2nd-angle Oracle constructs (added iter424)

> **Scope.** Section 4 covered the canonical 1-line translations (DECODE, NVL, SYSDATE, etc.). This section bulletproofs the **deeper** Oracle constructs that frequently break a migration but that section 4 only mentions briefly. Treat this as the answer template for any "how do I migrate Oracle X to dbt+Trino" question that goes beyond simple function rewrites.

### 7A.1 `CONNECT BY` hierarchical query → `WITH RECURSIVE` (with the experimental + depth + quadratic-plan caveats)

**The single canonical rewrite.** Oracle's `SELECT id, parent_id, name, LEVEL FROM employees START WITH manager_id IS NULL CONNECT BY PRIOR id = manager_id` becomes:

```sql
WITH RECURSIVE org_tree(id, manager_id, name, level) AS (
    -- Base case (Oracle's START WITH):
    SELECT id, manager_id, name, 1 AS level
    FROM   {{ ref('stg_employees') }}
    WHERE  manager_id IS NULL
  UNION ALL
    -- Recursive step (Oracle's CONNECT BY PRIOR id = manager_id):
    SELECT e.id, e.manager_id, e.name, t.level + 1
    FROM   {{ ref('stg_employees') }} e
    JOIN   org_tree t ON e.manager_id = t.id
)
SELECT * FROM org_tree;
```

**The three caveats that matter for production:**

1. **Experimental flag.** Trino docs explicitly mark `WITH RECURSIVE` as experimental: *"This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload."* (trino.io/docs/current/sql/select.html). This has not been promoted to GA as of Trino 467. For mission-critical hierarchical traversals in production, prefer **materialized closure-table dbt models** (next bullet).
2. **`max_recursion_depth` default = 10** — a small integer, **NOT 100, NOT 1000**. The Trino docs verbatim: *"recursion depth is fixed, defaults to `10`, and doesn't depend on the actual query results"* (trino.io/docs/current/sql/select.html). **Exceeding the cap RAISES AN ERROR, NOT silent truncation.** The error message is `NOT_SUPPORTED: Recursion depth limit exceeded (10). Use 'max_recursion_depth'`. So a tree 15 levels deep run with the default cap of 10 will FAIL with that error — it will NOT silently return a truncated 10-level result. Tune via `SET SESSION max_recursion_depth = 50;` (or whatever bound your tree has, plus a small safety margin) BEFORE running the query. In a dbt model, set the session property via a pre-hook: `pre_hook="SET SESSION max_recursion_depth = 50"`. **A `WHERE t.depth < 20` predicate inside the recursive term does NOT bypass the engine cap** — the predicate's bound must be `<=` the current `max_recursion_depth` value, or you must raise the cap first; the engine evaluates its depth counter independently of any user predicate. **Do not set this unboundedly high** — see the quadratic-plan-growth warning in caveat #3 (a 200-deep recursion is roughly 400× the plan size of a 10-deep one) and runaway recursion will OOM a worker. **Worked shape:**
   ```sql
   -- BEFORE the recursive query: raise the cap (in a separate statement, or via dbt pre-hook).
   SET SESSION max_recursion_depth = 50;

   -- THEN run the recursive query. The predicate t.level < 50 is now within the cap.
   WITH RECURSIVE org_tree(id, manager_id, name, level) AS (
       SELECT id, manager_id, name, 1 AS level
       FROM   {{ ref('stg_employees') }}
       WHERE  manager_id IS NULL
     UNION ALL
       SELECT e.id, e.manager_id, e.name, t.level + 1
       FROM   {{ ref('stg_employees') }} e
       JOIN   org_tree t ON e.manager_id = t.id
       WHERE  t.level < 50    -- guard is <= the cap, safe
   )
   SELECT * FROM org_tree;
   ```
   **DO NOT WRITE** "`max_recursion_depth` defaults to 1000" / "default 100" / "default 1000" / "defaults to 1000 session property" — all wrong; the real default is **10**. **DO NOT WRITE** "exceeding `max_recursion_depth` silently truncates" — wrong; the engine raises `NOT_SUPPORTED: Recursion depth limit exceeded (N)`. **DO NOT WRITE** "a `WHERE depth < 20` predicate bypasses the cap" — wrong; you must raise the session property first.
3. **Quadratic query-plan growth** with recursion depth. Verbatim from the Trino docs (trino.io/docs/current/sql/select.html): *"the size of the query plan growth is quadratic with the recursion depth."* Each iteration of the recursive CTE is planned as a separate logical operator and the planner accumulates work proportional to the **square** of `max_recursion_depth`; doubling depth roughly quadruples plan size and planning time. For a tree 50 levels deep, the planner builds a 50-stage pipeline whose plan-size cost is on the order of 50^2 = 2500 plan-node units — well into worker-OOM territory on large input tables. For deep org charts or BOMs (bill-of-materials), the canonical Trino-friendly pattern is a **closure table**: precompute every (ancestor, descendant, distance) triple in a dbt incremental model, then JOIN against it at read time. The dbt model can use a loop in Jinja (`{% for i in range(max_depth) %}...{% endfor %}`) to build the closure deterministically without depending on `WITH RECURSIVE` — sidestepping the quadratic-plan-growth penalty entirely.

**The dbt-recommended shape — the closure table:**

```sql
-- models/intermediate/int_org_closure.sql
{{ config(materialized='table') }}

WITH base AS (
    SELECT id, manager_id FROM {{ ref('stg_employees') }}
)
{% for depth in range(1, 11) %}
    {% if depth == 1 %}
        SELECT id AS ancestor, id AS descendant, 0 AS distance FROM base
        UNION ALL
        SELECT manager_id AS ancestor, id AS descendant, 1 AS distance FROM base WHERE manager_id IS NOT NULL
    {% else %}
        UNION ALL
        SELECT a.ancestor, b.descendant, a.distance + 1 AS distance
        FROM int_org_closure_d{{ depth - 1 }} a
        JOIN base b ON a.descendant = b.manager_id
    {% endif %}
{% endfor %}
```

(The pattern above is illustrative — production closure-table builds typically use a single recursive CTE with a small `max_recursion_depth` AND materialize the result as a regular `table` model so downstream queries don't pay the recursion cost.)

**DO NOT WRITE:** `CONNECT BY PRIOR ... START WITH ...` in any dbt model targeting Trino — it is a parse error on Trino 467.

**DO NOT WRITE:** an unbounded `WITH RECURSIVE` query without verifying recursion depth — set `max_recursion_depth` explicitly and validate against the data's known max depth.

---

### 7A.2 Oracle analytic functions → Trino window functions (mostly portable) — and the QUALIFY landmine

**Most Oracle analytic functions migrate as-is.** The window-function syntax in Oracle and Trino is virtually identical — `LAG`, `LEAD`, `RANK`, `DENSE_RANK`, `ROW_NUMBER`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE`, `NTILE`, plus all the aggregate-as-window forms (`SUM(...) OVER (...)`, `AVG(...) OVER (...)`). The OVER clause syntax (`PARTITION BY ... ORDER BY ... ROWS BETWEEN ...`) is identical.

> **THE NULLS-DEFAULT LANDMINE — read the LEADING CANONICAL block at the top of this resource BEFORE migrating any window function whose `OVER` clause uses `ORDER BY ... DESC`.** The window-function syntax is portable, but the NULLS-default behavior is NOT. Oracle defaults `NULLS FIRST` for `DESC`; Trino defaults `NULLS LAST` for `DESC`. A `ROW_NUMBER() OVER (PARTITION BY x ORDER BY ts DESC)` migrated verbatim from Oracle will assign `rn = 1` to a different row on Trino if there are NULLs in `ts`. **Always write `OVER (... ORDER BY ts DESC NULLS FIRST)` (preserve Oracle) or `... DESC NULLS LAST` (explicit Trino default).** See **§ LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY** at the top.

| Oracle analytic | Trino window | Notes |
|---|---|---|
| `LAG(col, 1, default) OVER (PARTITION BY p ORDER BY o)` | Same — identical | Portable. |
| `LEAD(col, 1, default) OVER (PARTITION BY p ORDER BY o)` | Same — identical | Portable. |
| `RANK() OVER (ORDER BY x DESC)` | Same — identical | Portable. |
| `DENSE_RANK() OVER (ORDER BY x DESC)` | Same — identical | Portable. |
| `ROW_NUMBER() OVER (PARTITION BY p ORDER BY o)` | Same — identical | Portable. |
| `FIRST_VALUE(col) OVER (PARTITION BY p ORDER BY o)` | Same — identical | Portable. |
| `LAST_VALUE(col) OVER (PARTITION BY p ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` | Same — identical (but the unbounded-following clause IS required in both, easy footgun) | Portable. |
| `SUM(amount) OVER (PARTITION BY customer_id ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` | Same — identical (rolling 7-row sum) | Portable. |
| `NTILE(4) OVER (ORDER BY revenue)` | Same — identical | Portable. |
| `LISTAGG(col, ',') WITHIN GROUP (ORDER BY col)` (aggregate, one row per group) | `listagg(col, ',') WITHIN GROUP (ORDER BY col)` (Trino 396+; **AGGREGATE-ONLY** — requires `GROUP BY`) **OR** `array_join(array_agg(col ORDER BY col), ',')` | LISTAGG was added to Trino in PR #6418 (release 396). Trino `listagg` is an **aggregate function only — it has NO window form** (see §7A.2A immediately below). For older Trino, use `array_join(array_agg(...))`. See the ON OVERFLOW mapping callout below — Trino supports `ON OVERFLOW ERROR \| TRUNCATE` natively and direct 1:1 to Oracle. |
| `LISTAGG(col, ',') WITHIN GROUP (ORDER BY col) OVER (PARTITION BY k)` (Oracle's **WINDOWED** form — value repeated on every row of the partition) | **NO direct Trino equivalent.** Use `array_join(array_agg(col) OVER (PARTITION BY k), ',')` with a pre-sorted CTE — see **§7A.2A LEADING CANONICAL** immediately below for the full canonical card + DO-NOT-WRITE. | Oracle's windowed LISTAGG has NO direct rewrite. **`listagg(...) OVER (...)` is FABRICATED** — Trino docs verbatim: "The current implementation of listagg function does not support window frames" ([trino.io/docs/current/functions/aggregate.html#listagg](https://trino.io/docs/current/functions/aggregate.html#listagg)). See §7A.2A. |
| `KEEP (DENSE_RANK FIRST/LAST ORDER BY ...)` clause | NO direct equivalent — rewrite as window function + filter | Oracle-specific. |

#### LISTAGG `ON OVERFLOW` — direct 1:1 Oracle-to-Trino mapping (NOT a gap)

> **One-sentence summary.** Trino `listagg(expr, separator [ON OVERFLOW ERROR | ON OVERFLOW TRUNCATE '<filler>' WITH COUNT | WITHOUT COUNT]) WITHIN GROUP (ORDER BY ...)` supports **the same `ON OVERFLOW` syntax as Oracle** — `ON OVERFLOW ERROR` is the default (raises when the concatenated result exceeds 1,048,576 bytes ≈ 1 MiB), and `ON OVERFLOW TRUNCATE '<filler>' WITH COUNT | WITHOUT COUNT` mirrors Oracle exactly. **Verified per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html).**

| Oracle source | Trino target | Mapping notes |
|---|---|---|
| `LISTAGG(product_name, ', ') WITHIN GROUP (ORDER BY product_name)` | `listagg(product_name, ', ') WITHIN GROUP (ORDER BY product_name)` | Identical. Implicitly `ON OVERFLOW ERROR` on both sides. |
| `LISTAGG(product_name, ', ' ON OVERFLOW ERROR) WITHIN GROUP (ORDER BY product_name)` | `listagg(product_name, ', ' ON OVERFLOW ERROR) WITHIN GROUP (ORDER BY product_name)` | **Direct 1:1** — same keywords, same default behavior. Errors when the concatenated string exceeds the limit (Oracle: 4000 bytes VARCHAR2 / 32767 bytes if `MAX_STRING_SIZE=EXTENDED`; Trino: 1,048,576 bytes ≈ 1 MiB). |
| `LISTAGG(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITH COUNT) WITHIN GROUP (ORDER BY product_name)` | `listagg(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITH COUNT) WITHIN GROUP (ORDER BY product_name)` | **Direct 1:1.** Same keywords, same semantics: when the result would exceed the limit, truncate, append the filler string `'...'`, then append a count of the omitted (non-null) values. |
| `LISTAGG(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) WITHIN GROUP (ORDER BY product_name)` | `listagg(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) WITHIN GROUP (ORDER BY product_name)` | **Direct 1:1.** Same keywords, same semantics: truncate + filler, no count of omitted values appended. |
| `LISTAGG(product_name, ', ' ON OVERFLOW TRUNCATE WITHOUT COUNT) WITHIN GROUP (ORDER BY product_name)` (filler defaulted) | `listagg(product_name, ', ' ON OVERFLOW TRUNCATE WITHOUT COUNT) WITHIN GROUP (ORDER BY product_name)` | **Direct 1:1.** Both Oracle and Trino accept the omitted-filler form; both default the filler to `'...'`. |

**Default overflow behavior on both engines.** When `ON OVERFLOW` is omitted, both Oracle and Trino default to `ON OVERFLOW ERROR` — overflowing the per-result limit raises an error rather than silently truncating. This is the conservative default; choose it when correctness matters (a truncated revenue report is worse than a failed report). Choose `ON OVERFLOW TRUNCATE '...' WITH COUNT` when the read-ability of the partial result plus an "and N more" marker is more valuable than failing the query.

**Trino size limit (different from Oracle but the SYNTAX is identical).** Trino's `listagg` errors out (or truncates, depending on the clause) at the documented **1,048,576-byte** (1 MiB) per-row result limit. Oracle's `LISTAGG` limit depends on the database `MAX_STRING_SIZE` setting (4000 bytes for VARCHAR2 standard, 32767 bytes when set to EXTENDED). The numeric threshold differs; the `ON OVERFLOW` syntax to handle the threshold does **not** differ.

> **DO-NOT-WRITE — anti-claims on Trino LISTAGG ON OVERFLOW.**
>
> 1. **DO NOT WRITE: "Trino `listagg` has no `ON OVERFLOW` equivalent."** That claim is **WRONG.** Trino supports `ON OVERFLOW ERROR` and `ON OVERFLOW TRUNCATE '<filler>' WITH | WITHOUT COUNT` with the same keywords as Oracle.
> 2. **DO NOT WRITE: "Oracle's `ON OVERFLOW TRUNCATE` clause has no Trino equivalent — you need a CASE WHEN length() workaround."** That claim is **WRONG.** Use the direct Trino syntax `listagg(x, ',' ON OVERFLOW TRUNCATE '...' WITH COUNT) WITHIN GROUP (ORDER BY ...)`. Workaround code such as `CASE WHEN length(array_join(array_agg(x), ',')) > N THEN substr(...) || ' (truncated, ' || cast(count(*) AS varchar) || ' more)' END` is unnecessary and harder to read — use the native `ON OVERFLOW TRUNCATE` clause instead.
> 3. **DO NOT WRITE: "Only the WITHIN GROUP (ORDER BY ...) part migrates; the ON OVERFLOW clause must be hand-rewritten."** That claim is **WRONG.** Both the `WITHIN GROUP (ORDER BY ...)` part AND the `ON OVERFLOW ERROR | TRUNCATE '<filler>' WITH | WITHOUT COUNT` part migrate **directly, keyword-for-keyword**, to Trino — they are the same SQL:2016 LISTAGG grammar that Oracle implements.

**Worked example — migrating a `LISTAGG` with `ON OVERFLOW TRUNCATE` to Trino dbt.**

```sql
-- Oracle source (PL/SQL or analytical view):
SELECT customer_id,
       LISTAGG(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITH COUNT)
           WITHIN GROUP (ORDER BY order_date DESC) AS recent_products
FROM   orders
GROUP BY customer_id;

-- Trino dbt model (same keywords, same semantics; Trino 396+):
{{ config(materialized='table') }}
SELECT customer_id,
       listagg(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITH COUNT)
           WITHIN GROUP (ORDER BY order_date DESC) AS recent_products
FROM   {{ ref('stg_orders') }}
GROUP BY customer_id;
```

The migration is a **keyword-for-keyword copy** — no rewrite, no workaround, no CASE expression. The only difference an engineer needs to remember is the byte threshold (1 MiB on Trino) and the NULL-handling behavior (Oracle and Trino both skip NULLs in `listagg` — the `array_join(array_agg(...))` alternative does NOT skip NULLs unless you add `FILTER (WHERE x IS NOT NULL)`).

**When to choose `array_join(array_agg(...))` instead.** If you're on a Trino release older than 396 (rare in 2026 — the production stack is Trino 467), or if you specifically need to control NULL handling differently, fall back to `array_join(array_agg(col ORDER BY col) FILTER (WHERE col IS NOT NULL), ',')`. Note that `array_join` and `array_agg` have NO `ON OVERFLOW` clause — if the joined string exceeds Trino's 1 MiB row limit you must handle it with explicit `substr` + length checks. For Trino 467, the production stack, prefer the native `listagg(... ON OVERFLOW TRUNCATE ...)` form.

**THE QUALIFY LANDMINE.** Oracle does NOT have `QUALIFY` (it's a Snowflake / BigQuery / Databricks / Teradata extension), but engineers migrating Oracle code who have ALSO worked in Snowflake/BigQuery often accidentally write `QUALIFY ROW_NUMBER() OVER (...) = 1` in their Trino dbt models. **`QUALIFY` is a PARSE ERROR on Trino 467.** The canonical Trino rewrite is the subquery + outer WHERE:

```sql
-- Oracle / Snowflake / BigQuery (FAILS on Trino):
SELECT customer_id, order_date, amount
FROM orders
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) = 1;

-- Trino-compatible rewrite (the canonical "latest-per-group" pattern):
SELECT customer_id, order_date, amount
FROM (
    SELECT customer_id, order_date, amount,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) AS rn
    FROM   orders
) t
WHERE rn = 1;
```

**Open feature request:** [trinodb/trino #20687](https://github.com/trinodb/trino/issues/20687) — `QUALIFY` not yet implemented as of Trino 467.

---

### 7A.2A LEADING CANONICAL — Oracle WINDOWED `LISTAGG ... OVER (PARTITION BY ...)` → Trino (NO direct equivalent; listagg has NO window form)

> **Keyword anchors so the responder lands here:** windowed listagg, listagg OVER, listagg PARTITION BY, listagg analytic, listagg every row, listagg repeated on every row, listagg WITHIN GROUP OVER, Oracle LISTAGG to Trino, LISTAGG keep value on every row, listagg as window function, listagg window frame.

**The one rule.** Trino's `listagg(expr, sep) WITHIN GROUP (ORDER BY ...)` is an **AGGREGATE function ONLY**. It **requires `GROUP BY`** in the outer query and produces **ONE row per group**. It **does NOT support `OVER (...)` window frames**. Per [trino.io/docs/current/functions/aggregate.html#listagg](https://trino.io/docs/current/functions/aggregate.html#listagg) **verbatim**:

> "The current implementation of `listagg` function does not support window frames."

`listagg` also does NOT appear on Trino's window-function list ([trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) lists only `cume_dist`, `dense_rank`, `ntile`, `percent_rank`, `rank`, `row_number`, `first_value`, `last_value`, `nth_value`, `lead`, `lag` — plus generic aggregate-as-window — `listagg` is **explicitly excluded**).

**The Oracle source you're migrating:**

```sql
-- Oracle: windowed LISTAGG (value repeated on EVERY row of the partition)
SELECT order_id,
       product_name,
       LISTAGG(product_name, ', ') WITHIN GROUP (ORDER BY product_name)
           OVER (PARTITION BY order_id) AS products_in_order
FROM   order_items;
```

There is **NO keyword-for-keyword Trino rewrite** of this Oracle windowed form. You must choose between **two canonical rewrites** depending on whether you actually need the repeated-on-every-row shape.

---

#### Case A — AGGREGATE form (ONE row per group): the typical case

Most analytical workloads that use Oracle's windowed LISTAGG don't actually need the value on every row — they just want the concatenated list, one row per group. **Always prefer this form when possible** — it's simpler, deterministic, and uses only the documented `listagg` surface.

```sql
-- Trino: aggregate listagg with GROUP BY (one row per order_id, concatenated products)
SELECT order_id,
       listagg(product_name, ', ') WITHIN GROUP (ORDER BY product_name) AS products_in_order
FROM   order_items
GROUP BY order_id;
```

Why this is the preferred rewrite:
- Native `listagg` aggregate — documented surface, no caveats.
- `WITHIN GROUP (ORDER BY product_name)` gives deterministic ordering of the concatenated values.
- One row per group — the result shape almost everyone actually wants.
- Supports `ON OVERFLOW ERROR | TRUNCATE` natively (see §7A.2 immediately above).

---

#### Case B — WINDOWED form (value REPEATED on every row): only if you actually need denormalized output

If the downstream consumer truly needs the concatenated list **repeated on every row** of the partition (denormalized output, often used in BI tools that can't pivot), you must rewrite to `array_join(array_agg(...) OVER (...))`.

**The naive rewrite (UNSAFE — order is undefined):**

```sql
-- WORKS but the array contents are in UNDEFINED ORDER (per trinodb/trino #16984)
SELECT order_id,
       product_name,
       array_join(array_agg(product_name) OVER (PARTITION BY order_id), ', ') AS products_in_order
FROM   order_items;
```

**The CAVEAT.** Trino does **NOT support `array_agg(expr ORDER BY y) OVER (...)`** — combining the aggregate's inline `ORDER BY` with a window `OVER (...)` clause raises `"must be an aggregate expression or appear in GROUP BY clause"` (per [trinodb/trino #16984](https://github.com/trinodb/trino/issues/16984)). So you cannot write `array_agg(product_name ORDER BY product_name) OVER (PARTITION BY order_id)` to get deterministic ordering inside the windowed array.

**The deterministic-ordering rewrite (PRE-SORT in a CTE):**

```sql
-- For deterministic ordering inside the windowed array, pre-sort in a CTE first
WITH sorted_items AS (
    SELECT order_id, product_name
    FROM   order_items
    ORDER BY order_id, product_name           -- pre-sort source rows
)
SELECT order_id,
       product_name,
       array_join(array_agg(product_name) OVER (PARTITION BY order_id), ', ') AS products_in_order
FROM   sorted_items;
```

**Caveat on the caveat.** Even pre-sorting in a CTE is not strictly guaranteed across optimizer passes — Trino's optimizer may reorder rows between the CTE and the window. The **truly safe** pattern is **Case A** (aggregate form + `GROUP BY`); accept the one-row-per-key shape and pivot/join later if you need the denormalized shape downstream.

---

#### DO-NOT-WRITE — banned listagg-OVER patterns

> Every row below has produced a confirmed FAIL in past migrations or a documented Trino parse / analysis error. Memorize and never copy-paste.

| Banned pattern (DO NOT WRITE) | Why it fails | What to write instead |
|---|---|---|
| `listagg(col, sep) WITHIN GROUP (ORDER BY col) OVER (PARTITION BY k)` | **FABRICATED.** `listagg` has NO window form on Trino. Trino docs verbatim: "The current implementation of listagg function does not support window frames." Fails at analysis. | **Case A** (aggregate + `GROUP BY`) for the typical one-row-per-group result, **or Case B** (`array_join(array_agg(col) OVER (PARTITION BY k), sep)`) if you truly need the value repeated on every row. |
| `listagg(col, sep) OVER (PARTITION BY k)` (without `WITHIN GROUP`) | **FABRICATED.** Same root cause — listagg has no window form, with or without `WITHIN GROUP`. | Same as above. |
| Diagnosis: "the listagg-OVER error is a `NULLS`-default / quoting issue — add `NULLS FIRST` or change quote style and it'll work" | **WRONG DIAGNOSIS.** The error is fundamental — `listagg` simply has NO window form on Trino. No NULL-handling change, no quote-style change, no separator change, no `WITHIN GROUP` reordering will make `listagg ... OVER (...)` work. The function does not accept `OVER` at all. | Stop debugging quoting/NULLS. Switch to Case A or Case B. |
| `array_agg(col ORDER BY y) OVER (PARTITION BY k)` (inline `ORDER BY` + `OVER`) | **FABRICATED COMBINATION.** Trino's `array_agg` supports either `ORDER BY` inside the aggregate (without `OVER`) OR `OVER (...)` as a window (without inline `ORDER BY`), but **NOT BOTH AT ONCE** — per [trinodb/trino #16984](https://github.com/trinodb/trino/issues/16984), the parser raises "must be an aggregate expression or appear in GROUP BY clause." | Pre-sort source rows in a CTE/subquery, then `array_agg(col) OVER (PARTITION BY k)` on the pre-sorted source. Or prefer Case A (`listagg` aggregate + `GROUP BY`) and pivot downstream. |
| "Trino added `listagg` as a window function in release 467 (or any other release)" | **FABRICATED.** `listagg` was added to Trino as an **aggregate function** in release 396 (PR #6418) and has remained aggregate-only through Trino 467 / current 481. No release ever made it a window function. | Cite §7A.2 — `listagg` (Trino 396+, **aggregate only**). |
| "`listagg` supports `OVER (...)` if you use the SQL:2016 ordered-set form" | **FABRICATED.** SQL:2016 specifies `LISTAGG` only as an ordered-set aggregate (the `WITHIN GROUP (ORDER BY ...)` form). Adding `OVER (...)` is NOT in SQL:2016 — Oracle's windowed-LISTAGG is an Oracle vendor extension. Trino implements the standard aggregate form only. | Case A or Case B per the choice rule below. |

---

#### The choice rule — which case do I pick?

1. **Do you actually need the value on every row?** If you can pivot/join downstream, **always pick Case A** (aggregate + `GROUP BY`). Simpler, deterministic, native `listagg` with full `ON OVERFLOW` support.
2. **If you genuinely need denormalized output** (value repeated on every row of the partition — e.g., the BI tool can't pivot), use **Case B** with a pre-sort CTE. Accept that the deterministic-ordering guarantee is weaker than `listagg`'s `WITHIN GROUP`.
3. **Never write `listagg(...) OVER (...)`** in any form. It is not implemented on Trino.

#### Cross-references

- §7A.2 immediately above — the aggregate (one-row-per-group) form, plus the `ON OVERFLOW ERROR | TRUNCATE` mapping.
- [resource 23 § anti-patterns row — `STRING_AGG(col, sep ORDER BY ...)`](23-sql-best-practices-olap.md) — the PostgreSQL→Trino `STRING_AGG` mapping (same `listagg` aggregate, same aggregate-only restriction).
- [trino.io/docs/current/functions/aggregate.html#listagg](https://trino.io/docs/current/functions/aggregate.html#listagg) — the verbatim "does not support window frames" sentence.
- [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) — the canonical Trino window-function list (`listagg` is NOT in it).
- [trinodb/trino #16984](https://github.com/trinodb/trino/issues/16984) — the open issue documenting that `array_agg(x ORDER BY y) OVER (...)` is not supported.

---

### 7A.2B Trino string aggregation — `string_agg` and `group_concat` do NOT exist; use `listagg` or `array_join(array_agg(...))`

> **Keyword anchors so the responder lands here:** Trino string_agg does not exist, string_agg not registered, Function 'string_agg' not registered, group_concat Trino, MySQL group_concat in Trino, PostgreSQL string_agg in Trino, concatenate rows into one string, concatenate values across rows Trino, listagg vs array_join, Trino string concatenation aggregate, comma-separated list from column, build JSON from rows fab, what is Trino's STRING_AGG, replace string_agg with listagg, distinct comma-separated list, dedupe roll-up, unique values in one cell, listagg distinct, listagg with DISTINCT, one row per X comma-separated distinct Y, distinct values rolled up sorted, no duplicate values in the list.

**The one rule.** Trino 467 has **NO `string_agg` (PostgreSQL/SQL Server) and NO `group_concat` (MySQL).** Either one fails at analysis with `Function 'string_agg' not registered` (or the same shape for `group_concat`). Per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html), Trino's string-aggregation surface is exactly two forms:

1. **`listagg(expr, sep) WITHIN GROUP (ORDER BY ...)`** — ANSI ordered-set aggregate. **AGGREGATE-ONLY** (no `OVER (...)` window form — per the locked §7A.2A canonical above). Requires `GROUP BY` in the outer query; produces ONE row per group. Supports `ON OVERFLOW ERROR | TRUNCATE '<filler>' WITH | WITHOUT COUNT` (see §7A.2).
2. **`array_join(array_agg(expr [ORDER BY ...] [FILTER (WHERE ...)]), sep)`** — array-based equivalent. Use when you need the window form (`array_agg(expr) OVER (PARTITION BY k)` over a pre-sorted CTE — see §7A.2A Case B). Note: `array_agg` does NOT skip NULLs by default — add `FILTER (WHERE expr IS NOT NULL)` if you want `listagg`-style NULL-skipping.

```sql
-- CORRECT — aggregate one row per group with listagg.
SELECT customer_id,
       listagg(invoice_id, ', ') WITHIN GROUP (ORDER BY invoice_id) AS invoices
FROM iceberg.fin.invoices
GROUP BY customer_id;

-- CORRECT — array_join + array_agg alternative (same shape; no ON OVERFLOW support).
SELECT customer_id,
       array_join(array_agg(invoice_id ORDER BY invoice_id), ', ') AS invoices
FROM iceberg.fin.invoices
GROUP BY customer_id;

-- DO NOT WRITE — string_agg is PostgreSQL/SQL Server, NOT a Trino function:
--   SELECT customer_id, string_agg(invoice_id, ', ' ORDER BY invoice_id) FROM ...
-- Fails with: Function 'string_agg' not registered.

-- DO NOT WRITE — group_concat is MySQL, NOT a Trino function:
--   SELECT customer_id, group_concat(invoice_id ORDER BY invoice_id SEPARATOR ', ') FROM ...
-- Fails with: Function 'group_concat' not registered (and MySQL's SEPARATOR keyword is also not parsed).
```

#### DISTINCT sub-case — distinct / deduped comma-separated roll-up (use `array_join(array_agg(DISTINCT ...))`, NOT `listagg(DISTINCT ...)`)

> **Keyword anchors so the responder lands HERE:** distinct comma-separated list, dedupe roll-up, unique values in one cell, listagg distinct, listagg with DISTINCT, one row per X comma-separated distinct Y, distinct values rolled up sorted, no duplicate values in the list, deduplicate before string aggregation, unique tags per user comma-separated.

**The one rule.** For a **distinct / deduped comma-separated roll-up** — "one row per user, the distinct page names they visited, sorted, comma-separated" — write `array_join(array_agg(DISTINCT x ORDER BY x), ', ')`. **DO NOT write `listagg(DISTINCT x, ',') WITHIN GROUP (ORDER BY x)`** — Trino 467's `listagg` has **NO `DISTINCT` slot in its signature** and will fail at analysis.

**Verbatim Trino 467 `listagg` signature** (per [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html)):

```
LISTAGG( expression [, separator] [ON OVERFLOW overflow_behaviour])
    WITHIN GROUP (ORDER BY sort_item, ...) [FILTER (WHERE condition)]
```

There is **no `DISTINCT` slot** anywhere in that signature — not before `expression`, not after `separator`, not inside `WITHIN GROUP`. Writing `listagg(DISTINCT x, ',')` (or `listagg(DISTINCT x, ',') WITHIN GROUP (ORDER BY x)`) **fails at analysis**. For a distinct roll-up use `array_join(array_agg(DISTINCT x ORDER BY x), sep)` — `array_agg`'s inline `DISTINCT` dedupes BEFORE collection, the inline `ORDER BY` makes the order deterministic, and `array_join(..., sep)` concatenates.

**Worked example — one row per user, the distinct page names they visited (sorted), comma-separated:**

```sql
-- CORRECT — distinct deduped comma-separated roll-up.
SELECT user_id,
       array_join(array_agg(DISTINCT page_name ORDER BY page_name), ', ')
           AS distinct_pages_visited
FROM iceberg.analytics.page_views
GROUP BY user_id;

-- DO NOT WRITE — listagg has NO DISTINCT slot in its WITHIN GROUP signature:
--   SELECT user_id,
--          listagg(DISTINCT page_name, ', ') WITHIN GROUP (ORDER BY page_name)
--              AS distinct_pages_visited
--   FROM iceberg.analytics.page_views
--   GROUP BY user_id;
-- Fails at analysis — the Trino 467 listagg grammar accepts no DISTINCT keyword.
```

**Release-467 caveat — DISTINCT was added to WINDOWED aggregates only, NOT to `WITHIN GROUP` listagg.** Per the [Trino release-467 notes](https://trino.io/docs/current/release/release-467.html) (December 6, 2024) verbatim:

> "Allow using `LISTAGG` as a windowed aggregate function."

and (same release) DISTINCT support was added for **windowed aggregate functions** specifically. **That DISTINCT-in-windowed-aggregates change applies to the `OVER (...)` windowed form of aggregate functions — it does NOT add a DISTINCT slot to the non-windowed `WITHIN GROUP` listagg form documented above**, which still has no DISTINCT keyword in its signature. The §7A.2A canonical above already covers the windowed-listagg path; the non-windowed `WITHIN GROUP (ORDER BY ...)` form covered HERE has NO DISTINCT slot, period.

**DO-NOT-WRITE — banned listagg-DISTINCT pattern (keyword-grepable).**

| Banned writing | Why it's wrong | Correct form |
|---|---|---|
| `listagg(DISTINCT x, ',') WITHIN GROUP (ORDER BY x)` | **PARSE ERROR.** Trino 467 `listagg` has NO `DISTINCT` slot in its `WITHIN GROUP` signature — the documented grammar is `LISTAGG( expression [, separator] [ON OVERFLOW ...]) WITHIN GROUP (ORDER BY ...) [FILTER (WHERE ...)]`. Writing `listagg(DISTINCT x, sep)` fails at analysis. Release 467 added DISTINCT to **windowed** aggregates only — not to the `WITHIN GROUP` listagg form. | `array_join(array_agg(DISTINCT x ORDER BY x), ', ')` — `array_agg`'s inline `DISTINCT` dedupes BEFORE collection, then `array_join(..., ', ')` concatenates with the separator. |
| `LISTAGG(DISTINCT col, ',') WITHIN GROUP (ORDER BY col)` (Oracle 19c+ extension) | Migrating Oracle's `LISTAGG(DISTINCT ...)` 1:1 to Trino does NOT work — Trino's `listagg` does not implement the Oracle DISTINCT extension. | Same as above: `array_join(array_agg(DISTINCT col ORDER BY col), ',')`. Semantically identical to Oracle's `LISTAGG(DISTINCT col, ',') WITHIN GROUP (ORDER BY col)`, with the caveat that `array_join`'s 2-arg form skips NULLs (matching `listagg` NULL-skip behavior) and has no `ON OVERFLOW` clause. |

**One-shot translation table.**

| Source dialect | Source syntax | Trino 467 equivalent |
|---|---|---|
| PostgreSQL / SQL Server | `string_agg(col, ', ' ORDER BY col)` | `listagg(col, ', ') WITHIN GROUP (ORDER BY col)` (aggregate-only) OR `array_join(array_agg(col ORDER BY col), ', ')` |
| MySQL | `group_concat(col ORDER BY col SEPARATOR ', ')` | `listagg(col, ', ') WITHIN GROUP (ORDER BY col)` (aggregate-only) OR `array_join(array_agg(col ORDER BY col), ', ')` |
| Oracle (aggregate) | `LISTAGG(col, ', ') WITHIN GROUP (ORDER BY col)` | Same — `listagg(col, ', ') WITHIN GROUP (ORDER BY col)` (direct 1:1, see §7A.2). |
| Oracle (windowed) | `LISTAGG(col, ', ') WITHIN GROUP (ORDER BY col) OVER (PARTITION BY k)` | NO direct equivalent. Use Case B: `array_join(array_agg(col) OVER (PARTITION BY k), ', ')` over a pre-sorted CTE — see §7A.2A. |

**DO-NOT-WRITE — banned string-aggregation fabrications.**

| Banned writing | Why it's wrong | Correct form |
|---|---|---|
| `string_agg(col, sep)` or `STRING_AGG(col, sep ORDER BY col)` | **FABRICATED.** PostgreSQL/SQL Server function — NOT in Trino's aggregate function list. Fails at analysis: `Function 'string_agg' not registered`. | `listagg(col, sep) WITHIN GROUP (ORDER BY col)` OR `array_join(array_agg(col ORDER BY col), sep)`. |
| `group_concat(col SEPARATOR sep)` | **FABRICATED.** MySQL function — NOT in Trino. Also `SEPARATOR` is a MySQL keyword Trino does not parse. | Same as above. |
| "Use `string_agg` and add it to the pushdown allow-list to make Trino call PostgreSQL's `string_agg`" | **WRONG.** Pushdown ≠ vocabulary. You can use PostgreSQL's `string_agg` via `system.query(...)` on the federated catalog (see [resource 22 § passthrough](22-trino-federation-postgresql.md)) — but you cannot make `string_agg` appear in the Trino dialect itself. The function name resolution happens before any pushdown decision. | If you genuinely need Postgres-side `string_agg`, wrap it in `SELECT ... FROM TABLE(postgresql.system.query(query => 'SELECT string_agg(...) FROM ...'))`. Otherwise use `listagg` or `array_join(array_agg(...))`. |
| `listagg(col, sep) OVER (PARTITION BY k)` (assuming listagg has a window form) | **FABRICATED.** Same root cause as the `string_agg` claim — Trino's listagg has NO window form (per §7A.2A). | Case A (`listagg` aggregate + `GROUP BY`) OR Case B (`array_join(array_agg(col) OVER (PARTITION BY k), sep)` with a pre-sort CTE). See §7A.2A. |
| Hand-rolling JSON via `string_agg(key \|\| ':' \|\| value, ',')` to build a JSON object | **DOUBLY WRONG.** (1) `string_agg` does not exist in Trino. (2) String concatenation does not safely escape JSON — use `CAST(MAP(...) AS JSON)` or `CAST(ROW(...) AS JSON)` then `json_format(...)` instead. See [resource 09 § LEADING CANONICAL — `CAST(map / array / row AS JSON)`](09-lakehouse-schema-design.md). | `json_format(CAST(MAP(key_array, value_array) AS JSON))`. |

**Cross-references.**

- §7A.2A immediately above — the locked LEADING CANONICAL for Oracle WINDOWED LISTAGG → Trino (Case A vs Case B choice rule + the `array_agg(col ORDER BY y) OVER (...)` ban).
- §7A.2 — the aggregate `listagg` ON OVERFLOW mapping.
- [resource 23 § anti-patterns table — `STRING_AGG`](23-sql-best-practices-olap.md) — the cross-dialect row that already covers `STRING_AGG`.
- [resource 09 § LEADING CANONICAL — `CAST(map / array / row AS JSON)`](09-lakehouse-schema-design.md) — the right way to build JSON from MAP/ARRAY/ROW (do NOT hand-roll via `string_agg`-style concatenation).
- [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) — full Trino aggregate-function list; `string_agg` and `group_concat` are absent.
- [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) — `array_join(x, delimiter) -> varchar`.

---

### 7A.3 Oracle PL/SQL packages and stored functions → dbt macros + Jinja

**Oracle PL/SQL packages bundle related procedures and functions.** A typical package looks like:

```plsql
CREATE OR REPLACE PACKAGE fx_utils AS
    FUNCTION to_usd(amount NUMBER, from_currency VARCHAR2, on_date DATE) RETURN NUMBER;
    FUNCTION business_day_offset(start_date DATE, offset_days INTEGER) RETURN DATE;
END fx_utils;
```

**Trino has NO `CREATE PACKAGE` / `CREATE FUNCTION` for stored UDFs.** (Trino has a stored-function feature that's plugin-dependent and not widely used in OSS deployments — for the on-prem Trino 467 stack in production, treat stored functions as unavailable.)

**The dbt replacement: macros.** A dbt macro is a Jinja-templated SQL snippet that expands inline when the model compiles. Macros live in `macros/` and are reused via `{{ macro_name(args) }}`:

```jinja
-- macros/fx_utils.sql
{% macro to_usd(amount_col, from_currency_col, on_date_col) %}
    (
        {{ amount_col }} * (
            SELECT rate FROM {{ ref('stg_currency_fx') }} fx
            WHERE fx.currency_code = {{ from_currency_col }}
              AND fx.effective_date = {{ on_date_col }}
        )
    )
{% endmacro %}

{% macro business_day_offset(start_date_col, offset_days) %}
    -- Inline SQL that computes business-day offset using a calendar table.
    (
        SELECT cal.business_date
        FROM   {{ ref('dim_calendar') }} cal
        WHERE  cal.business_date_seq = (
            SELECT business_date_seq FROM {{ ref('dim_calendar') }}
            WHERE business_date = CAST({{ start_date_col }} AS DATE)
        ) + {{ offset_days }}
    )
{% endmacro %}
```

**Use site:**

```sql
-- models/fct_revenue_usd.sql
SELECT
    order_id,
    {{ to_usd('amount', 'currency_code', 'order_date') }} AS amount_usd,
    {{ business_day_offset('order_date', 3) }} AS settle_date
FROM {{ ref('stg_orders') }}
```

**Key differences from Oracle packages:**

| Oracle PL/SQL package | dbt macro |
|---|---|
| Compiled once, called at runtime; can have state | Expanded inline at compile time; **stateless** — each call is just SQL substitution |
| Can have `PRAGMA` directives, overloading, complex types | Plain text templating; no overloading, no types |
| Cross-schema reusable via grants | Cross-project reusable via `dbt deps` packages (e.g., `dbt_utils`) |
| Versioned via `ALTER PACKAGE` | Versioned via git on the dbt project |
| Can raise EXCEPTION | Cannot — failures bubble up as model SQL errors or compile errors |
| `EXECUTE IMMEDIATE 'dynamic SQL'` | `{% if %} {% endif %}` Jinja branching at compile time (the dynamic SQL is resolved BEFORE Trino sees it) |

**Important nuance — function call semantics differ.** In Oracle, `fx_utils.to_usd(amount, 'EUR', order_date)` is a function call evaluated row-by-row by the database engine. In dbt, `{{ to_usd('amount', "'EUR'", 'order_date') }}` is **textual SQL substitution at compile time** — the macro inlines its body into the SQL, and the resulting SQL runs as a normal correlated subquery (or JOIN) on Trino. This means macros can be MORE expensive than Oracle stored functions if they introduce correlated subqueries — always inspect the compiled SQL (`dbt compile` then read `target/compiled/...`) before assuming the macro is cheap.

#### 7A.3.1 Trino dialect landmine in macro examples — CONCAT and `||` require all-VARCHAR args (NO implicit numeric/date coercion)

**This is the single most common Trino dialect bug when porting Oracle PL/SQL string-building helpers** — and a typical place it crops up is a fiscal-quarter / period-label macro that concatenates a literal prefix with `EXTRACT(YEAR FROM ...)` or `EXTRACT(MONTH FROM ...)`. Oracle implicitly coerces numbers and dates to strings inside `||`; **Trino does not**. Per [trino.io/docs/current/functions/conversion.html](https://trino.io/docs/current/functions/conversion.html) verbatim: *"Trino will not convert between character and numeric types. For example, a query that expects a varchar will not automatically convert a bigint value to an equivalent varchar."* This applies to BOTH `concat(...)` and the `||` operator (the latter is sugar for the former per [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html)). And `EXTRACT(YEAR FROM date_col)` / `EXTRACT(MONTH FROM ...)` / `EXTRACT(QUARTER FROM ...)` all return **BIGINT** in Trino — so concatenating an EXTRACT result with a string literal requires an explicit CAST or use of `format()`.

**WRONG (Oracle-style, errors at runtime in strict Trino with "Unexpected parameters (varchar(N), bigint) for function concat")**:

```sql
-- macros/period_utils.sql  --  BROKEN on Trino, would compile but fail at execution
{% macro fiscal_quarter_label(date_col) %}
    CASE
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (1,2,3)  THEN CONCAT('FQ1-', EXTRACT(YEAR FROM {{ date_col }}))
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (4,5,6)  THEN CONCAT('FQ2-', EXTRACT(YEAR FROM {{ date_col }}))
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (7,8,9)  THEN CONCAT('FQ3-', EXTRACT(YEAR FROM {{ date_col }}))
        ELSE CONCAT('FQ4-', EXTRACT(YEAR FROM {{ date_col }}))
    END
{% endmacro %}
```

The literals `'FQ1-'`, `'FQ2-'`, ... are VARCHAR; `EXTRACT(YEAR FROM ...)` is BIGINT. `CONCAT(varchar, bigint)` has no match in Trino's function registry — runtime error.

**RIGHT — option A: explicit CAST AS VARCHAR**:

```sql
{% macro fiscal_quarter_label(date_col) %}
    CASE
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (1,2,3)  THEN CONCAT('FQ1-', CAST(EXTRACT(YEAR FROM {{ date_col }}) AS VARCHAR))
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (4,5,6)  THEN CONCAT('FQ2-', CAST(EXTRACT(YEAR FROM {{ date_col }}) AS VARCHAR))
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (7,8,9)  THEN CONCAT('FQ3-', CAST(EXTRACT(YEAR FROM {{ date_col }}) AS VARCHAR))
        ELSE CONCAT('FQ4-', CAST(EXTRACT(YEAR FROM {{ date_col }}) AS VARCHAR))
    END
{% endmacro %}
```

**RIGHT — option B: use `format()` (cleaner, printf-style, handles the type conversion via the `%d` placeholder)**:

```sql
{% macro fiscal_quarter_label(date_col) %}
    CASE
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (1,2,3)  THEN format('FQ1-%d', EXTRACT(YEAR FROM {{ date_col }}))
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (4,5,6)  THEN format('FQ2-%d', EXTRACT(YEAR FROM {{ date_col }}))
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (7,8,9)  THEN format('FQ3-%d', EXTRACT(YEAR FROM {{ date_col }}))
        ELSE format('FQ4-%d', EXTRACT(YEAR FROM {{ date_col }}))
    END
{% endmacro %}
```

`format()` returns VARCHAR and uses Java's `Formatter` syntax — `%d` for integer/bigint, `%s` for already-VARCHAR, `%.2f` for fixed-precision decimals.

**The general rule (memorize this when porting Oracle string-building code to Trino):**

> In Trino, **`CONCAT(...)` and `||` require ALL arguments to be character types (VARCHAR / CHAR)**. Cast every non-VARCHAR argument explicitly with `CAST(... AS VARCHAR)`, or use `format('...%d...%s...', a, b)` instead. Oracle implicitly coerces numerics/dates to strings inside `||`; Trino does not. This trips up almost every Oracle → Trino port that builds composite labels.

**Other common landmines from the same root cause:**

| Pattern | Wrong (Oracle-style) | Right (Trino) |
|---|---|---|
| Date → label | `'order-' \|\| order_date` | `'order-' \|\| CAST(order_date AS VARCHAR)` or `format('order-%s', CAST(order_date AS VARCHAR))` |
| Bigint id → key | `'cust:' \|\| customer_id` | `'cust:' \|\| CAST(customer_id AS VARCHAR)` or `format('cust:%d', customer_id)` |
| Decimal → display | `'$' \|\| amount` | `'$' \|\| CAST(amount AS VARCHAR)` or `format('$%.2f', amount)` |
| Timestamp → log key | `'evt-' \|\| event_ts` | `'evt-' \|\| CAST(event_ts AS VARCHAR)` or `format('evt-%s', CAST(event_ts AS VARCHAR))` |
| Boolean → flag | `'active-' \|\| is_active` | `'active-' \|\| CAST(is_active AS VARCHAR)` (returns `'true'`/`'false'`) |

**One subtle exception that's NOT a landmine**: `concat(varchar1, varchar2, varchar3, ...)` with all-VARCHAR args works fine, AND if a column is already typed `varchar(N)` you don't need to CAST it (different VARCHAR widths concat fine — the result type is the sum-widened VARCHAR). The landmine is ONLY when a non-character type (BIGINT, INTEGER, DATE, TIMESTAMP, DECIMAL, BOOLEAN) appears as an argument.

**Why this matters for macros specifically**: a dbt macro is **textual substitution at compile time** — the macro body is dropped verbatim into the model SQL. If the macro author wrote `CONCAT('FQ1-', EXTRACT(YEAR FROM x))`, that compiles fine in dbt (Jinja doesn't type-check), and `dbt parse` / `dbt compile` succeed. The error only surfaces when Trino tries to execute the model SQL — at which point dbt reports it as a generic model failure with the Trino error message buried in the stderr. Use `dbt compile` and read `target/compiled/<model>.sql` to inspect what Trino will actually see, and visually scan for any `CONCAT(...)` or `||` with non-VARCHAR arguments.

---

### 7A.4 Oracle EXCEPTION handling → dbt tests + WHERE guards + ROLLBACK semantics

**Oracle PL/SQL has a rich exception model**: `EXCEPTION WHEN NO_DATA_FOUND THEN ...`, `WHEN DUP_VAL_ON_INDEX THEN ...`, `WHEN OTHERS THEN ROLLBACK; RAISE_APPLICATION_ERROR(-20001, '...');`. Inside a transaction, the EXCEPTION block can ROLLBACK partial work and either suppress the error or re-raise it.

**Trino + dbt has NONE of this.** There is no `EXCEPTION` keyword, no try/catch, no programmatic ROLLBACK inside a query. The replacement is three-fold:

1. **dbt tests** for post-run data quality assertions. Tests run after the model materializes and fail the dbt run if violated. These are the dbt-shaped replacement for `RAISE_APPLICATION_ERROR(-20001, 'data quality violation')`.

   ```yaml
   # models/marts/schema.yml
   models:
     - name: fct_orders_daily
       columns:
         - name: order_id
           tests: [not_null, unique]
         - name: customer_id
           tests:
             - relationships:
                 to: ref('dim_customer')
                 field: id
         - name: amount_usd
           tests:
             - dbt_utils.accepted_range:
                 min_value: 0
                 max_value: 1000000
   ```

   And the custom singular test for "no orphan records":

   ```sql
   -- tests/no_orphan_orders.sql
   SELECT order_id
   FROM   {{ ref('fct_orders_daily') }}
   WHERE  customer_id IS NOT NULL
     AND  customer_id NOT IN (SELECT id FROM {{ ref('dim_customer') }})
   ```

   Any row returned by a singular test fails the run.

2. **In-query guards** for the "if X is missing, default to Y" pattern that an Oracle PL/SQL block would handle with `EXCEPTION WHEN NO_DATA_FOUND THEN x := 0;`. These guards are: `COALESCE(col, default)`, `LEFT JOIN` with a fallback NULL, `CASE WHEN col IS NULL THEN ... END`, `NULLIF(col, '')` for the empty-string-vs-NULL Oracle quirk.

   ```sql
   -- Oracle PL/SQL: BEGIN SELECT rate INTO v_rate FROM fx WHERE ...;
   --                EXCEPTION WHEN NO_DATA_FOUND THEN v_rate := 1.0; END;
   -- dbt + Trino:
   SELECT
       o.order_id,
       o.amount * COALESCE(fx.rate, 1.0) AS amount_usd
   FROM   {{ ref('stg_orders') }} o
   LEFT JOIN {{ ref('stg_currency_fx') }} fx
       ON fx.currency_code = o.currency
       AND fx.effective_date = o.order_date
   ```

3. **ROLLBACK semantics: Iceberg snapshots + dbt model atomicity.** Oracle's `ROLLBACK` aborts a transaction so partial writes are not visible. The Trino + Iceberg replacement uses two layers:
   - **dbt model atomicity.** Each dbt model materializes via `CREATE TABLE AS SELECT` (for `table`) or `MERGE INTO` (for `incremental`). If the SQL fails partway, dbt does NOT commit the result — the existing table stays at its previous snapshot. Effectively, dbt model runs are atomic per-model.
   - **Iceberg snapshot rollback** for "I committed bad data, restore the previous snapshot." **On Trino 467 (our production version), the ONLY valid rollback syntax is `CALL iceberg.system.rollback_to_snapshot('schema', 'table', <previous_snapshot_id>)`** — positional VARCHAR, VARCHAR, BIGINT three-arg form. Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (docs example: `CALL example.system.rollback_to_snapshot('testdb', 'customer_orders', 8954597067493422955)`). The `ALTER TABLE <table> EXECUTE rollback_to_snapshot(<id>)` table-procedure form was added in **Trino 469** (Jan 2025) and does **NOT** exist on Trino 467 — pasting it returns a procedure-not-found / parse error. This rolls the table back to a prior known-good state. See [resource 17 § Iceberg time travel and rollback](17-iceberg-table-maintenance.md) for the full canonical-forms card and the Trino-vs-Spark rollback syntax matrix.

**The GLOBAL TEMPORARY TABLE → dbt ephemeral / intermediate model mapping.** Oracle `CREATE GLOBAL TEMPORARY TABLE staging_orders ON COMMIT DELETE ROWS` becomes either:

- **dbt ephemeral model** (`materialized='ephemeral'`) — the model produces no table; it's inlined as a CTE in every downstream `ref()`. Best when the staging set is used once.
- **dbt intermediate model** (`materialized='table'`) — produces a real Iceberg table that downstream models JOIN against. Best when the staging set is reused across 3+ downstream models and is expensive to recompute.

The semantic difference: Oracle's GLOBAL TEMPORARY TABLE is session-scoped (gets cleaned up at session end). dbt-managed intermediate tables persist across runs but are recreated on each `dbt run`. The session-scoped semantic is rarely needed in a dbt DAG world — the DAG itself defines the "intermediate" scope.

**DO NOT WRITE:** `EXCEPTION WHEN ... THEN ROLLBACK; INSERT INTO error_log ...;` — there is no SQL-level EXCEPTION block in Trino. The dbt-shaped replacement is the **on-failure hook**: `on-run-end: ["{% if results | selectattr('status', 'eq', 'error') | list | length > 0 %}INSERT INTO error_log SELECT '{{ invocation_id }}', CURRENT_TIMESTAMP{% endif %}"]` — runs at the end of the dbt run, can detect model failures and emit an audit row.

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
- Trino datetime functions (current_timestamp / localtimestamp / AT TIME ZONE): https://trino.io/docs/current/functions/datetime.html
- Trino SET TIME ZONE command: https://trino.io/docs/current/sql/set-time-zone.html
- Trino properties reference (sql.forced-session-time-zone): https://trino.io/docs/current/admin/properties-general.html
- dbt-trino configurations: https://docs.getdbt.com/reference/resource-configs/trino-configs
- dbt materializations: https://docs.getdbt.com/docs/build/materializations
- dbt incremental strategies: https://docs.getdbt.com/docs/build/incremental-strategy
- dbt source freshness (resource property): https://docs.getdbt.com/reference/resource-properties/freshness
- dbt `source` command (CLI): https://docs.getdbt.com/reference/commands/source
- dbt source freshness (deploy guide): https://docs.getdbt.com/docs/deploy/source-freshness
- dbt sources overview: https://docs.getdbt.com/docs/build/sources
- Apache Iceberg docs: https://iceberg.apache.org/docs/latest/
- Oracle SQL Language Reference (NULLs): https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Nulls.html
