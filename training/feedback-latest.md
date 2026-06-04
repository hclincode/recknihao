# Judge Feedback — Iter 456 (extended phase, end-of-iteration)

## Overall

- **Overall average: 3.8594 (PASS, THIN MARGIN)** — 55th consecutive overall PASS in extended phase
- **Per-question**: Q1 **4.6875 STRONG PASS** / Q2 **3.1875 FAIL** / Q3 **4.6875 STRONG PASS** / Q4 **2.875 FAIL**
- Margin THIN (3.8594) — Q1+Q3 carry the iteration; Q2+Q4 BOTH below 3.5 floor with load-bearing fabs.

## Per-question scores

| Q | Topic angle | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Trino ZSTD compression DDL RE-PROBE | 4.75 | 4.75 | 4.5 | 4.75 | **4.6875** | STRONG PASS — iter455 Q4 fab fix CONFIRMED |
| Q2 | Broadcast join concern + how to influence + does ANALYZE help | 2.75 | 3.0 | 4.0 | 3.0 | **3.1875** | FAIL — fabricated `/*+ USE_HASH_JOIN */` hints + missing `join_distribution_type` |
| Q3 | dbt ref() vs source() | 4.75 | 4.5 | 4.75 | 4.75 | **4.6875** | STRONG PASS — clean dbt semantics |
| Q4 | Oracle TO_CHAR(date,'YYYY-MM-DD') → Trino | 2.5 | 2.5 | 3.75 | 2.75 | **2.875** | FAIL — `::VARCHAR` PostgreSQL fab + missing `date_format`/`format_datetime` |

## Streak status

**Compression-DDL fab class (iter455 Q4 FAB-2 + FAB-3): FULLY RESOLVED at Q1.** Responder used Trino `compression_codec` (NOT native `write.parquet.compression-codec`); flat `WITH` pairs (NOT `properties = map(...)`); bare-identifier LHS in SET PROPERTIES (NOT string-literal). Explicitly called out the native name as WRONG. iter456 teacher LEADING CANONICAL block in r03 + r11 + meta-canonical translation table LANDED CLEAN.

**Bare-ANALYZE-vs-ANALYZE-TABLE: HELD AT Q2.** Responder did not take the "ANALYZE TABLE" bait planted by the question; used the correct bare `ANALYZE iceberg.analytics.events` Trino syntax.

## Fabrications detected

### FAB-1 (Q2) — `/*+ USE_HASH_JOIN(a,b) */` and `/*+ USE_PARTITIONED_JOIN(a,b) */` query hints

- **Claim**: responder recommended Trino query hints `SELECT /*+ USE_HASH_JOIN(a,b) */ ...` and `/*+ USE_PARTITIONED_JOIN(a,b) */ ...` with hedge "if your Trino version supports hints, verify docs".
- **Reality**: Trino does NOT support `/*+ ... */` query hints AT ALL — neither these specific hint names nor any hint mechanism. Per [trinodb/trino issue #9498 "Support query hints"](https://github.com/trinodb/trino/issues/9498) (still open, not implemented as of Trino 467/481), Trino has no query-hint syntax. The names `USE_HASH_JOIN` / `USE_PARTITIONED_JOIN` are Oracle/Spark-specific.
- **Failure mode**: SILENT-WRONG. Trino 467 treats `/*+ ... */` as a regular block comment per Trino SQL grammar, silently ignores the hint, optimizer makes the default cost-based decision. Engineer thinks the hint applied; it didn't. Worse than a parse error because no immediate feedback.
- **Hedge does not save it**: the hedge "if your Trino version supports hints" implies hints might exist somewhere — they don't. Even if Trino added hints in a future release, the names `USE_HASH_JOIN`/`USE_PARTITIONED_JOIN` are not what Trino would use.
- **Correct fact**: per [Trino CBO docs](https://trino.io/docs/current/optimizer/cost-based-optimizations.html), the canonical Trino lever is `SET SESSION join_distribution_type = 'PARTITIONED'` (or `'BROADCAST'` or `'AUTOMATIC'`).
- **Source**: https://github.com/trinodb/trino/issues/9498

### FAB-2 (Q4) — `::VARCHAR` PostgreSQL cast operator

- **Claim**: responder recommended `CAST(order_ts AS DATE)::VARCHAR` as "more idiomatically" with `::VARCHAR` called "syntactic sugar for CAST".
- **Reality**: Trino does NOT support the PostgreSQL `x::type` cast operator syntax. Per [trinodb/trino issue #23795 "Cast operator `::`"](https://github.com/trinodb/trino/issues/23795) (still open as a feature request, not implemented as of Trino 467/481), `::` is not valid Trino syntax — only standard SQL `CAST(x AS type)` is supported.
- **Failure mode**: PARSE ERROR. Engineer copy-pastes the preferred form, hits `mismatched input '::'. Expecting: ...`.
- **Compounding factor**: this is in the PREFERRED-form position of the answer (responder explicitly says "more idiomatically"), so the engineer would try this form first.
- **Root-cause class**: PostgreSQL/Snowflake/DuckDB dialect spillover into Trino — same pattern as Q2 (recommending another dialect's syntax as Trino's). Calling `::` "syntactic sugar" implies it's just an alternative spelling; it's not — it's a different dialect's syntax.
- **Correct fact**: per [Trino datetime functions](https://trino.io/docs/current/functions/datetime.html), the canonical Trino equivalents of Oracle TO_CHAR are `date_format(ts, '%Y-%m-%d')` (MySQL-style) and `format_datetime(ts, 'yyyy-MM-dd')` (Joda) — both FIRST-CHOICE answers, both missing from the responder.
- **Source**: https://github.com/trinodb/trino/issues/23795

## Major completeness gaps

### MISS-1 (Q2) — `join_distribution_type` session property

- The canonical Trino lever for influencing per-query join distribution is `SET SESSION join_distribution_type = 'PARTITIONED'` (or `'BROADCAST'` / `'AUTOMATIC'`). Accepts three values, default AUTOMATIC. This is THE direct switch.
- The responder gave only the secondary cap (`join_max_broadcast_table_size`), which is the AUTOMATIC-mode broadcast-build-side cap, not the primary distribution switch.
- Engineer asking "how do I influence broadcast" needs the primary switch first; the cap is a secondary mechanism.
- **Source**: https://trino.io/docs/current/optimizer/cost-based-optimizations.html

### MISS-2 (Q4) — `date_format` and `format_datetime`

- Per [Trino datetime functions docs](https://trino.io/docs/current/functions/datetime.html), the canonical Trino equivalents of Oracle TO_CHAR for arbitrary date format strings are:
  - `date_format(timestamp, '%Y-%m-%d')` — MySQL-style format specifiers (capital `%Y` = 4-digit year, `%m` = 2-digit month, `%d` = 2-digit day, `%H` = hour, `%i` = minute, `%s` = second). **FIRST-CHOICE.**
  - `format_datetime(timestamp, 'yyyy-MM-dd')` — Joda DateTime pattern (lowercase `yyyy` = 4-digit year, `MM` = 2-digit month, `dd` = 2-digit day, `HH` = hour, `mm` = minute, `ss` = second).
- Both exist in Trino 467, both documented, both are the canonical Oracle TO_CHAR migration answers.
- Responder gave NEITHER. Instead recommended `format('%1$td/%1$tm/%1$tY', order_ts)` Java Formatter syntax — which IS a real Trino function but the NICHE choice, not the canonical TO_CHAR equivalent.
- Engineer migrating hundreds of Oracle TO_CHAR calls in legacy PL/SQL needs `date_format`/`format_datetime` first, `format()` as fallback for niche cases.
- **Source**: https://trino.io/docs/current/functions/datetime.html

## Concrete teacher actions for iter457

Both new fabrications are **dialect-spillover** fabs (Oracle/Spark in Q2, PostgreSQL/Snowflake/DuckDB in Q4). The pattern is the same as iter455 Q4 (native Iceberg name spillover): responder recommends another dialect's syntax as Trino's because the syntax is plausible-looking and widespread elsewhere. Teacher needs TWO new canonical blocks plus DO-NOT-WRITE matrices.

### Action 1 — Trino join-strategy canonical lever block (r25 / r26)

**Where to install**: resources/25-trino-cbo-analyze-stats.md (and/or resources/26-query-performance-regression-diagnosis.md) — the keyword path is "broadcast join" / "join strategy" / "how do I make Trino use a hash join". Use a LEADING CANONICAL `### LEADING CANONICAL — How do I influence Trino's join strategy?` subsection BEFORE any prose discussion of broadcast vs partitioned.

**Content to teach (verified syntax)**:
1. **Primary lever**: `SET SESSION join_distribution_type = 'PARTITIONED';` (accepted values: `PARTITIONED`, `BROADCAST`, `AUTOMATIC`; default `AUTOMATIC`). One line — this is the direct switch.
2. **Secondary cap (AUTOMATIC mode only)**: `SET SESSION join_max_broadcast_table_size = '50MB';` (default 100MB). Caps the broadcast build side when CBO is choosing.
3. **Tertiary (improve the optimizer's input)**: bare `ANALYZE iceberg.analytics.events;` (no TABLE keyword) → populates NDV stats in the Iceberg Puffin sketch file → CBO makes better join-distribution choices.
4. **EXPLAIN (TYPE DISTRIBUTED)** before/after to verify the chosen distribution.

**DO-NOT-WRITE matrix** (reproduce iter456 Q2 fab verbatim with inline correction):
- `SELECT /*+ USE_HASH_JOIN(a,b) */ ...` — **WRONG**: Trino has NO query hints per trinodb/trino issue #9498. `/*+ ... */` is silently treated as a regular block comment — the hint is IGNORED with no error. Use `SET SESSION join_distribution_type = 'PARTITIONED'` before the query instead.
- `SELECT /*+ USE_PARTITIONED_JOIN(a,b) */ ...` — **WRONG**: same as above. These are Oracle/Spark hint names; Trino has neither the syntax nor these names.
- Any `/*+ ANY_HINT_NAME(...) */` — **WRONG**: Trino has NO query hint mechanism at all. Use SET SESSION properties instead.

**Failure-mode callout**: emphasize the SILENT-WRONG nature. Unlike a parse error, the engineer gets no feedback that the hint was ignored — the query runs with default distribution and the engineer thinks the hint worked.

**Verification anchors**: trino.io/docs/current/optimizer/cost-based-optimizations.html + trinodb/trino issue #9498.

### Action 2 — Trino TO_CHAR canonical equivalents block (r27 — Oracle migration)

**Where to install**: resources/27-oracle-plsql-dbt-trino-migration.md — the keyword path is "TO_CHAR" / "date format" / "Oracle date string". Use a LEADING CANONICAL `### LEADING CANONICAL — Oracle TO_CHAR(date, format) → Trino` subsection.

**Content to teach (verified syntax)**:
1. **For ISO format (`'YYYY-MM-DD'`)** — three valid Trino forms in preference order:
   - `CAST(date_column AS VARCHAR)` (DATE column, implicit 'YYYY-MM-DD' format)
   - `date_format(ts, '%Y-%m-%d')` (TIMESTAMP column, MySQL-style — FIRST-CHOICE general answer)
   - `format_datetime(ts, 'yyyy-MM-dd')` (TIMESTAMP column, Joda pattern)
2. **For arbitrary formats** — `date_format` and `format_datetime` are THE canonical answers. Include a side-by-side Oracle TO_CHAR ↔ Trino format-string mapping table:

| Oracle TO_CHAR | Trino `date_format` (MySQL) | Trino `format_datetime` (Joda) |
|---|---|---|
| `'YYYY-MM-DD'` | `'%Y-%m-%d'` | `'yyyy-MM-dd'` |
| `'YYYY-MM-DD HH24:MI:SS'` | `'%Y-%m-%d %H:%i:%s'` | `'yyyy-MM-dd HH:mm:ss'` |
| `'DD/MM/YYYY'` | `'%d/%m/%Y'` | `'dd/MM/yyyy'` |
| `'Mon DD, YYYY'` | `'%b %d, %Y'` | `'MMM dd, yyyy'` |
| `'HH24:MI'` | `'%H:%i'` | `'HH:mm'` |

3. **For niche needs only**: `format('%1$td/%1$tm/%1$tY', ts)` Java Formatter syntax — but only when you need Formatter-specific features.

**DO-NOT-WRITE matrix** (reproduce iter456 Q4 fab verbatim with inline correction):
- `CAST(order_ts AS DATE)::VARCHAR` — **WRONG**: Trino does NOT support the PostgreSQL `::` cast operator per trinodb/trino issue #23795. Hits parse error `mismatched input '::'`. Use `CAST(CAST(order_ts AS DATE) AS VARCHAR)` instead.
- `order_ts::TIMESTAMP` / `col::INT` / any `expr::type` — **WRONG**: same reason. Always use `CAST(expr AS type)`.
- Calling `::` "syntactic sugar for CAST" — **WRONG**: it's another dialect's syntax (PostgreSQL/Snowflake/DuckDB), not a Trino spelling.
- `TO_CHAR(date, 'YYYY-MM-DD')` — **WRONG (Oracle, not Trino)**: TO_CHAR does not exist in Trino. Use `date_format(...)` or `format_datetime(...)`.

**Meta-canonical dialect-spillover guardrail** (extend the iter456 native-Iceberg translation table in r17 with a NEW table at the top of r27 for Oracle migration):

| Concept | Oracle / PG / Snowflake | Trino 467 |
|---|---|---|
| Cast operator | `expr::type` (PG/Snowflake/DuckDB) | `CAST(expr AS type)` ONLY |
| Date-to-string | `TO_CHAR(date, fmt)` (Oracle) | `date_format(ts, fmt)` (MySQL) / `format_datetime(ts, fmt)` (Joda) |
| String-to-date | `TO_DATE(str, fmt)` (Oracle) | `date_parse(str, fmt)` (MySQL) / `parse_datetime(str, fmt)` (Joda) |
| Conditional null | `NVL(a, b)` (Oracle) | `COALESCE(a, b)` |
| Pattern match | `DECODE(...)` (Oracle) | `CASE WHEN ...` (with `IS NULL` for NULL-bearing inputs) |
| Row limit | `ROWNUM <= 100` (Oracle 11g) | `LIMIT 100` |

Closing meta-rule (verbatim, mirror the iter456 native-Iceberg guardrail style): "in Trino, use Trino's dialect — Oracle/PostgreSQL/Snowflake/Spark function names and operators that look idiomatic in other engines parse-error or silently no-op against Trino 467."

**Verification anchors**: trino.io/docs/current/functions/datetime.html + trino.io/docs/current/functions/conversion.html + trinodb/trino issue #23795.

### Breadth design for iter457

- Do NOT add a dedicated federation probe — federation row 4.49944/310 unchanged per directive.
- Re-probe BOTH new fab classes from a different angle to confirm fix:
  - **Q2 hint fab re-probe**: ask a different join-strategy question (e.g., "how do I force a partitioned join when I know the right side is too big to broadcast?") — fix CONFIRMED only if responder leads with `SET SESSION join_distribution_type = 'PARTITIONED'` and explicitly calls out that Trino has no query hints.
  - **Q4 `::` cast operator re-probe**: ask a different cast question (e.g., "what's the Trino way to convert a string to a TIMESTAMP?") — fix CONFIRMED only if responder uses `CAST(... AS TIMESTAMP)` or `date_parse(...)` / `parse_datetime(...)` and does NOT use `::`.
- Use the other 2 questions for breadth coverage — recommend: (a) Iceberg partition design (one of the lower-margin near-threshold topics — 4.4854/31) or storage sizing (4.516/8), (b) something on dbt-Trino incrementals to keep the dbt-on-Trino topics warm.

### Reconcile-don't-append reminder

When adding the join-strategy and TO_CHAR canonical blocks, search for and **reconcile in place** any stale or contradictory content in r25/r26/r27 — do not just append. Specifically:
- Grep r25/r26 for any existing mention of `USE_HASH_JOIN` / `USE_PARTITIONED_JOIN` / `/*+` — if any exists, fix or remove it.
- Grep r27 for any existing mention of `::` as a cast operator or `TO_CHAR` without a Trino equivalent — fix in place.
- Verify no resource file uses `properties = map(...)` Trino-context wrapper or `write.parquet.compression-codec` as a Trino property name (these should already be reconciled per iter456 teacher work).

## Topic average changes this iter

| Topic | Before | After | Δ | Note |
|---|---|---|---|---|
| Column-oriented storage | 4.4664/12 | **4.4835/13** | +0.0171 | Q1 4.6875 above topic avg — compression-DDL fab class FULLY RESOLVED |
| Trino CBO/ANALYZE | 4.6707/13 | **4.5651/14** | -0.1056 | Q2 3.1875 well below topic avg — hint fab + missing `join_distribution_type`; still above override-threshold 4.5 but margin TIGHTER |
| Postgres-to-Iceberg ingestion | 4.4944/155 | **4.4957/156** | +0.0013 | Q3 4.6875 above topic avg marginal — dbt ref/source clean |
| Oracle PL/SQL→dbt/Trino migration | 4.6324/27 | **4.5697/28** | -0.0627 | Q4 2.875 well below topic avg — `::VARCHAR` PG fab + missing date_format/format_datetime |
| Federation (NOT probed) | 4.49944/310 | 4.49944/310 | 0 | unchanged per directive |
