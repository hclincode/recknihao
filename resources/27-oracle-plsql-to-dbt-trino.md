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
| "Oracle's `CONNECT BY PRIOR ... START WITH ...` hierarchical syntax works in Trino — it's a common SQL extension." | **FALSE — Trino has NO `CONNECT BY`.** The replacement is **`WITH RECURSIVE`** (ANSI SQL standard, supported in Trino since release 343). A recursive CTE must be shaped as `WITH RECURSIVE t(cols) AS (base_query UNION ALL recursive_step) SELECT ...`. **Caveats:** (1) The Trino docs flag `WITH RECURSIVE` as **experimental**: "This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload." (2) Default `max_recursion_depth = 10` (session-tunable via `SET SESSION max_recursion_depth = N`). (3) The query-plan growth is **quadratic with recursion depth** — for very deep org charts or BOMs, materialize a closure table as a pre-computed dbt model instead of computing recursively at read time. **DO NOT WRITE `CONNECT BY PRIOR` in a dbt model — parse error.** | [Trino SELECT - WITH RECURSIVE](https://trino.io/docs/current/sql/select.html); [PR #4250](https://github.com/trinodb/trino/pull/4250) |
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
      'partitioned_by': "ARRAY['order_date']",
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
- `properties` is the dbt-trino-specific block. **Inside this dict the documented partitioning key is `partitioned_by` (snake_case)** — NOT `partitioning`. The bare-Trino raw-DDL form `CREATE TABLE ... WITH (partitioning = ARRAY[...])` DOES use `partitioning` without an underscore, but that's the raw-SQL surface, not the dbt-trino properties dict. See [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) and [resource 28 § LEADING CANONICAL WORKED EXAMPLE](28-complex-sql-performance-trino-dbt.md) for the canonical block + DO-NOT-WRITE list. **Partition the migrated table by the same column the Oracle table was partitioned on (or whatever the dominant filter is — see [resource 10](10-lakehouse-partitioning.md)).**
- `{% if is_incremental() %}` is the CANONICAL incremental delta-filter guard. It is True ONLY when (a) the target table already exists, (b) the run is NOT `--full-refresh`, and (c) the model is configured as incremental. On first run it's FALSE (no WHERE filter, full CTAS); on subsequent runs it's TRUE (filter applied, MERGE on the delta). **NOTE: do NOT use `{% if execute %}` here — `execute` is True during both `dbt compile` and `dbt run` and does NOT gate first-build / `--full-refresh` vs incremental.** See [docs.getdbt.com/reference/dbt-jinja-functions/execute](https://docs.getdbt.com/reference/dbt-jinja-functions/execute) and [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models).
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
| `DECODE(col, 'A', 1, 'B', 2, 0)` | `CASE col WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END` (or chained `CASE WHEN`s) | Trino has NO `DECODE`. CASE is more readable anyway. **CRITICAL NULL-MATCHING NUANCE: see §4.1A below — DECODE treats NULL=NULL as a match; simple CASE does NOT, so NULL-bearing columns silently change result on migration.** |
| `'' IS NULL` -> TRUE (Oracle quirk) | `'' IS NULL` -> **FALSE** in Trino | The single most dangerous silent-result-change in the migration. See myths box. |
| `nvl(col, '')` (sentinel "no value" Oracle idiom) | `COALESCE(col, '')` BUT this now produces a row where `col` is `''` (not null) — downstream `WHERE col IS NULL` checks BREAK. Audit and rewrite. | Oracle's quirk made this idiom round-trip cleanly; Trino's strictness breaks it. |

### 4.1A Oracle DECODE → Trino CASE — the silent NULL-matching nuance

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

| Oracle | Trino | Notes |
|---|---|---|
| `SYSDATE` (current date + time, server time zone) | `current_timestamp` (timestamp with time zone, session TZ) OR `localtimestamp` (no TZ) | Beware: `SYSDATE` returns DATE-with-time in Oracle; `CURRENT_DATE` in Trino is just DATE (no time). Use `current_timestamp` for "now()" semantics. **NOTE: `current_date` drops the time component — do NOT use it as a SYSDATE replacement when you need hours/minutes/seconds.** See §4.2A for how to change the session time zone (it is NOT a `SET SESSION` property — it is a dedicated `SET TIME ZONE` command). |
| `SYSTIMESTAMP` | `current_timestamp` | Identical semantics (both TZ-aware). Oracle `SYSTIMESTAMP` is `TIMESTAMP WITH TIME ZONE`; Trino `current_timestamp` is `timestamp with time zone` keyed on the session time zone. |
| `TRUNC(dt)` (truncate to day) | `date_trunc('day', dt)` | Also `'week'`, `'month'`, `'quarter'`, `'year'`, `'hour'`, `'minute'`, `'second'`. |
| `TO_DATE('2026-05-30', 'YYYY-MM-DD')` | `date_parse('2026-05-30', '%Y-%m-%d')` returning timestamp, OR `CAST('2026-05-30' AS DATE)` for ISO-8601 dates. | Trino's format strings use `%Y %m %d %H %i %s` (MySQL-style), NOT Oracle's `YYYY MM DD HH24 MI SS`. |
| `TO_CHAR(dt, 'YYYY-MM-DD')` | `date_format(dt, '%Y-%m-%d')` (MySQL-style, FIRST-CHOICE) OR `format_datetime(dt, 'yyyy-MM-dd')` (Joda) OR `CAST(dt AS VARCHAR)` for ISO of a DATE column only. | See the LEADING CANONICAL block at the top of this section for the full Oracle TO_CHAR ↔ Trino format-string mapping table and DO-NOT-WRITE matrix. `TO_CHAR` itself is NOT a Trino function. |
| `TO_NUMBER('123')` | `CAST('123' AS bigint)` or `CAST('1.5' AS double)` | Trino has no `TO_NUMBER`; use `CAST`. |
| `EXTRACT(YEAR FROM dt)` | `EXTRACT(YEAR FROM dt)` OR `year(dt)` | Identical syntax + convenience functions. |
| `dt + 1` (add one day) | `dt + INTERVAL '1' DAY` | Trino requires explicit INTERVAL — no implicit day-arithmetic on dates. |
| `dt - SYSDATE` (interval) | `date_diff('day', current_timestamp, dt)` returns bigint | Trino doesn't subtract timestamps to get a bare number; use `date_diff`. |
| `ADD_MONTHS(dt, 3)` | `dt + INTERVAL '3' MONTH` OR `date_add('month', 3, dt)` | Both work. |
| `MONTHS_BETWEEN(d1, d2)` | `date_diff('month', d2, d1)` | Trino's date_diff returns bigint, not the Oracle-style fractional. |
| `LAST_DAY(dt)` | `last_day_of_month(dt)` | Trino has it; just renamed. |

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

### 4.3 String functions

| Oracle | Trino | Notes |
|---|---|---|
| `SUBSTR(s, start, len)` | `substr(s, start, len)` OR `substring(s FROM start FOR len)` | Both 1-indexed; same as Oracle. |
| `INSTR(s, sub)` | `strpos(s, sub)` | Returns position (1-indexed); `0` if not found, same as Oracle. |
| `INSTR(s, sub, start, n)` (find n-th occurrence) | No single-call equivalent; chain `strpos` + `substr` or use `regexp_extract_all`. | The 4-argument INSTR form is Oracle-only. |
| `LENGTH(s)` | `length(s)` | Identical. |
| `LPAD(s, n, pad)` / `RPAD(s, n, pad)` | `lpad(s, n, pad)` / `rpad(s, n, pad)` | Identical. |
| `LTRIM(s)` / `RTRIM(s)` / `TRIM(s)` | `ltrim(s)` / `rtrim(s)` / `trim(s)` | Identical. |
| ``a || b`` (concatenation) | `a \|\| b` OR `concat(a, b)` | Same operator. **BUT two big differences**: (1) Oracle treats `NULL \|\| 'x'` as `'x'` (quirk); Trino returns `NULL` (standard) — wrap in `COALESCE`. (2) **Oracle implicitly coerces numbers/dates to strings inside `\|\|`; Trino does NOT** — `CONCAT` and `\|\|` both require all-VARCHAR args, so `CAST(year_int AS VARCHAR)` or use `format('FQ-%d', year_int)`. See §7A.3.1 for the canonical fix. |
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
> | String → date | `STR_TO_DATE('2026-05-30', '%Y-%m-%d')` | MySQL | `Function 'str_to_date' not registered` | `date_parse('2026-05-30', '%Y-%m-%d')` (MySQL-style) or `parse_datetime('2026-05-30', 'yyyy-MM-dd')` (Joda) |
> | Conditional null | `NVL(a, b)` | Oracle | Parse / resolution error | `COALESCE(a, b)` |
> | Conditional zero | `NVL2(a, b, c)` | Oracle | `Function 'nvl2' not registered` | `CASE WHEN a IS NOT NULL THEN b ELSE c END` |
> | Decode-with-NULL semantics | `DECODE(col, NULL, 'x', ...)` | Oracle | Parse / resolution error | Searched `CASE WHEN col IS NULL THEN 'x' WHEN col = ... END` (see §4.1A) |
> | Row limit | `WHERE ROWNUM <= 100` | Oracle 11g | Parse error (no `ROWNUM` pseudocolumn) | `LIMIT 100` (with `ORDER BY` for determinism) |
> | Iceberg table property: compression | `WITH (..., "write.parquet.compression-codec" = 'zstd')` | native Iceberg property key | Parse error — that key is the native Iceberg name, not a Trino WITH property | `WITH (..., compression_codec = 'ZSTD')` — flat name=value, Trino name |
> | Iceberg WITH-clause shape | `WITH (..., properties = map('k','v'))` | native Iceberg / Spark API style | Parse / property error | `WITH (key1 = 'v1', key2 = 'v2')` — flat name=value pairs |
> | Spark TBLPROPERTIES | `ALTER TABLE t SET TBLPROPERTIES ('k' = 'v')` | Spark SQL | Parse error | `ALTER TABLE t SET PROPERTIES key = 'v'` — bare identifier LHS, string-literal RHS |
> | Iceberg snapshot timestamp | `WHERE timestamp_ms = ...` on `$snapshots` | Iceberg Java API field name | Column does not exist | `WHERE committed_at = TIMESTAMP '...'` — the Trino metadata-table column |
> | NULLS-default ordering in `ORDER BY ... DESC` | Assuming `ORDER BY ts DESC` puts NULLs at the top (Oracle's default) | Oracle's documented default | **SILENT-WRONG row ordering** — Trino puts NULLs at the BOTTOM on `DESC` (default `NULLS LAST` regardless of direction); no error, just different row order than Oracle | Always write `ORDER BY ts DESC NULLS FIRST` (preserve Oracle behavior) or `ORDER BY ts DESC NULLS LAST` (explicit Trino default). See **§ LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY** at the top of this resource. |
>
> **Meta-rule (memorize)**: when unsure, **prefer ANSI / standard SQL forms (`CAST(... AS ...)`, `COALESCE`, `CASE WHEN`) and SESSION properties (`SET SESSION ...`)**; do **not** paste PostgreSQL / Oracle / Snowflake / Spark / native-Iceberg idioms into Trino. If the form parses-and-runs without error but the optimizer behavior didn't change, suspect a silent-no-op hint or wrong session property — Trino has no hint mechanism, so the answer is always a SESSION property.
>
> **Cross-reference chain.**
> - Resource 23 anti-patterns table — extends this with QUALIFY, DISTINCT ON, LIMIT N BY, TOP N, EXTRACT(EPOCH FROM ...), TIMESTAMPDIFF, STRING_AGG, RETURNING.
> - Resource 24 § LEADING CANONICAL — How do I influence Trino's join distribution — the canonical replacement for any `/*+ hint */` form.
> - Resource 11 § Trino dialect ↔ native-Iceberg name translation — the canonical replacement for any `write.*-codec` / `TBLPROPERTIES` / `properties = map(...)` form.
> - Resource 17 § LEADING CANONICAL — `$snapshots` column list — the canonical column names (`committed_at`, NOT `timestamp_ms`).
> - **§ LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY (top of this resource) — the canonical Oracle-to-Trino NULLS-default migration pattern.**

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

### 4.5A ICEBERG-IDENTITY-COLUMN-NEGATION GUARDRAIL — Iceberg has NO user-facing identity / auto-increment columns; use `dbt_utils.generate_surrogate_key` instead

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
| `MERGE ... WHEN NOT MATCHED BY SOURCE THEN DELETE` (hard delete instead of soft) | **TWO models**: Model 1 = upsert as above. Model 2 = standalone `DELETE FROM fct_customers WHERE NOT EXISTS (SELECT 1 FROM stg_customers s WHERE s.customer_id = fct_customers.customer_id)` (Trino DELETE on Iceberg). | Hard-delete via DELETE is simpler than soft-delete via MERGE because there's no `deleted_at` column to fill. |

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
      'partitioned_by': "ARRAY['order_date']",
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

## 7. Cutover checklist (the non-obvious gotchas)

Once your models compile and run, before you turn off Oracle:

1. **Empty-string vs NULL audit.** Search every Oracle source SQL for `IS NULL` / `IS NOT NULL` / `NVL(x, '...')` and decide per-occurrence whether the Oracle quirk was load-bearing. Common fixes: `COALESCE(NULLIF(col, ''), default)`.
2. **Date precision.** Oracle `DATE` = date+time; Trino `DATE` = date only. If you migrated a time-bearing Oracle DATE column to a Trino `DATE`, you silently lost the time component. Audit and rewrite to `TIMESTAMP` where needed.
3. **Implicit coercion audit.** Search WHERE clauses for `<integer_col> = '<string>'`-style comparisons. Trino will fail to parse these. Add explicit `CAST(...)`.
4. **Number precision.** Oracle `NUMBER` is variable-precision; Trino requires you to pick `decimal(p,s)` / `bigint` / `double`. Picking `double` for money introduces rounding errors. **Always `decimal(p,s)` for currency.**
5. **Surrogate key stability.** If your Oracle pipeline relied on `seq.NEXTVAL` for surrogate keys, downstream foreign keys reference those values. The hash-based replacement (`md5(natural_keys)`) is stable across re-runs but will NOT match the Oracle-generated values. You need either a one-time migration table mapping old-key -> new-key OR a re-keying pass on all dependent tables.
6. **Row diff against Oracle.** Pick 3-5 representative rollup rows, compute them in Oracle and in Trino on the same source data, and diff. Don't trust column-level aggregate sums alone — they can match even when row-level results differ.
7. **EXPLAIN the migrated SELECTs.** Look for `CorrelatedJoin` in the EXPLAIN — it's a sign decorrelation failed (your cursor-loop translated naively). See [resource 28 §3](28-complex-sql-performance-trino-dbt.md) for rewrites.
8. **Partition the migrated table to match the dominant filter.** Oracle table partitioning hints don't carry over — set `partitioned_by=ARRAY['<column>']` inside the dbt `properties` block for an incremental Iceberg model (snake_case, dbt-trino documented key; the bare-Trino raw-DDL form `WITH (partitioning = ARRAY[...])` uses `partitioning` without an underscore, but inside the dbt `properties` dict use `partitioned_by`). See [resource 10](10-lakehouse-partitioning.md) and [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs).
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
2. **`max_recursion_depth` default = 10.** Any hierarchy deeper than 10 levels truncates. Tune via `SET SESSION max_recursion_depth = 100;` (or whatever bound your tree has). In a dbt model, set the session property via a pre-hook: `pre_hook="SET SESSION max_recursion_depth = 100"`. **Do not set this unboundedly high** — runaway recursion will OOM a worker.
3. **Quadratic plan-growth** with recursion depth. Each iteration of the recursive CTE is planned as a separate logical operator; for a tree 50 levels deep, the planner builds a 50-stage UnionAll. For deep org charts or BOMs (bill-of-materials), the canonical Trino-friendly pattern is a **closure table**: precompute every (ancestor, descendant, distance) triple in a dbt incremental model, then JOIN against it at read time. The dbt model can use a loop in Jinja (`{% for i in range(max_depth) %}...{% endfor %}`) to build the closure deterministically without depending on `WITH RECURSIVE`.

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
| `LISTAGG(col, ',') WITHIN GROUP (ORDER BY col)` | `array_join(array_agg(col ORDER BY col), ',')` or `listagg(col, ',') WITHIN GROUP (ORDER BY col)` (Trino 396+) | LISTAGG was added to Trino in PR #6418 (release 396). For older Trino, use `array_join(array_agg(...))`. See the ON OVERFLOW mapping callout immediately below — Trino supports `ON OVERFLOW ERROR | TRUNCATE` natively and direct 1:1 to Oracle. |
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
   - **Iceberg snapshot rollback** for "I committed bad data, restore the previous snapshot." Trino: `ALTER TABLE my_table EXECUTE rollback_to_snapshot(<previous_snapshot_id>)`. This rolls the table back to a prior known-good state. See [resource 17 § Iceberg time travel and rollback](17-iceberg-table-maintenance.md).

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
- Apache Iceberg docs: https://iceberg.apache.org/docs/latest/
- Oracle SQL Language Reference (NULLs): https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Nulls.html
