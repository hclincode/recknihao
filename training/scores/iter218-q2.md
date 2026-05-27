# Iter 218 Q2 Judge Score

## Score: 4.80

## Topic: Trino federation cross-source connectors

## What the answer got right

- **`constraint on [columns]` notation is correct.** Verified against official Trino docs and `resources/22-trino-federation-postgresql.md` lines 1390–1397: in real Trino 467 `EXPLAIN (TYPE DISTRIBUTED)` output, predicate pushdown shows as `constraint on [columns]` on separate indented lines underneath the `TableScan` node. The answer correctly distinguishes this real format from the simplified inline `constraint = ...` teaching notation.
- **`ScanFilterProject` (or standalone `Filter`) ABOVE the `TableScan` is the correct failed-pushdown signal.** Verified at https://trino.io/docs/current/connector/postgresql.html — pushdown success is indicated by the absence of `ScanFilterProject` for that clause. The vertical-position rule (predicate under TableScan = pushed, above = not pushed) is the right mental model.
- **Pushdown-supported predicate categories are accurate**: equality on UUID/numeric/string columns, range on numeric/temporal/DATE, `IN` lists on numeric/UUID, `IS NULL` / `IS NOT NULL`, and equality on strings all push down. Verified — equality (`=`, `IN`) and inequality (`!=`) on textual types push down by default per the official PostgreSQL connector docs.
- **String range predicates (`>`, `<`, `BETWEEN`, `LIKE`) do NOT push down by default.** Correct. Official docs explicitly state this is due to collation differences between Postgres and Trino — answer's explanation matches the docs verbatim.
- **`postgresql.experimental.enable-string-pushdown-with-collate=true` is a real Trino config property** introduced in Trino 365 (Dec 2021), and the session-property form `app_pg.enable_string_pushdown_with_collate = true` is also real. Verified.
- **CAST trap is correctly explained.** `WHERE CAST(id AS VARCHAR) = '12345'` does pull the whole table because Trino cannot push function-wrapped column predicates to JDBC. The fix (use correctly-typed literals: `WHERE id = 12345`) is the right guidance.
- **Function-on-column predicates (LOWER, SUBSTRING) do not push down**, and the suggested workaround (generated column on Postgres + index, then push equality on that column) is standard practice.
- **`EXPLAIN ANALYZE` `Filtered:` field interpretation is correct** — non-zero `Filtered:` percentage on the JDBC scan = pushdown happened; `Filtered: 0%` or absent + large `Input:` row count = pushdown failed.
- **`Input: N rows (size)` format is the verbatim Trino EXPLAIN ANALYZE output**, matching real format and the resource at line 1416.
- **Postgres slow query log approach (`log_min_duration_statement = 0`) is valid** and gives the strongest ground-truth evidence. The `ALTER DATABASE ... SET log_min_duration_statement = 0` command is the correct dynamic syntax.
- **The three-tier verification stack (EXPLAIN → EXPLAIN ANALYZE → Postgres slow log)** maps to weakest-to-strongest evidence and is exactly the right diagnostic ordering for a SaaS engineer.
- **Actionable workarounds when pushdown fails** are sensible: rewrite predicate, lead with selective predicate, enable experimental flag carefully, or ingest into Iceberg long-term.
- **The "your specific use case" recap** at the end ties the general guidance back to the engineer's exact WHERE clause, making the answer practically actionable.

## What the answer missed or got wrong

- **Minor — the `Filtered:` calculation example is slightly suspect.** The answer says "Postgres scanned ~1.9M rows internally (52K / (1 - 0.9725) ≈ 1.89M)". Per the docs, `Filtered:` describes the fraction of rows filtered by the operator's predicate relative to input. When pushdown succeeded and the predicate is server-side in Postgres, the `Filtered:` percentage on the Trino TableScan node is a less direct signal of Postgres-internal scan size — it more directly reflects what was filtered at the Trino-side projection layer. The simpler claim "non-zero `Filtered:` = pushdown succeeded" is fine; the back-calculated 1.9M number could mislead. (Minor; doesn't change the verdict.)
- **`ILIKE` is treated as "not documented as supported in OSS Trino 467"** — this is a safe statement but slightly more pessimistic than reality. PR #11045 added JDBC function predicate pushdown with PostgreSQL LIKE pushdown back in Trino 376+, and `LIKE` (and by extension `ILIKE`) has had increasing support across releases. The conservative "verify with EXPLAIN before relying on it" advice is correct.
- **No mention of dynamic filtering** as a related mechanism — when a federated join uses dynamic filtering, the inner side's matching values can be injected into the Postgres-side WHERE clause as an IN-list at runtime, which is essentially "runtime pushdown" on top of the WHERE clause discussed. A one-line note would have made completeness even better, but the question was specifically about static WHERE clause pushdown so this is not a deduction.
- **No mention of the `unsupported-type-handling` or `IGNORE` mode** that can silently disable pushdown for some column types (e.g., array types, custom types). Edge case, minor.
- **Production fit could be tighter**: the answer correctly cites Trino 467 throughout. It does not call out OPA, Hive Metastore, MinIO, or other production-stack specifics, but the question is about pushdown semantics which are stack-agnostic, so this is not a deduction.

## WebSearch verification notes

- **Verified `constraint on [columns]` notation** against https://trino.io/docs/current/connector/postgresql.html and https://trino.io/docs/current/optimizer/pushdown.html — both confirm the format and that pushdown success is indicated by absence of `ScanFilterProject` for that predicate.
- **Verified `postgresql.experimental.enable-string-pushdown-with-collate`** — real config property, introduced in Trino 365 (Dec 2021) via PR #9746, still experimental in current docs. Both catalog property and `enable_string_pushdown_with_collate` session property forms exist.
- **Verified string range / LIKE non-pushdown by default**: official docs state "The connector does not support pushdown of range predicates ... on columns with character string types like CHAR or VARCHAR. Equality predicates such as IN or = and inequality predicates such as != on columns with textual types are pushed down." Answer matches.
- **Verified `Filtered:` and `Input:` format** via WebFetch on https://trino.io/docs/current/sql/explain-analyze.html — `Input: 1500000 rows (18.17MB), Filtered: 45.46%` is the exact verbatim format used by Trino.
- **Verified `log_min_duration_statement = 0`** as valid PostgreSQL syntax for capturing all query durations via official Postgres docs and Crunchy Data references.

## Recommendation for teacher

The resource at `resources/22-trino-federation-postgresql.md` is already strong for this question — sections 3.2–3.4 cover all the key signals (constraint on, ScanFilterProject above TableScan, Filtered:, Input:) accurately and the answer reused them well. Two small polish items:

1. **Clarify the `Filtered:` percentage semantics on a pushed-down JDBC scan.** When pushdown succeeded, the Postgres server applied the predicate and only matching rows arrive at Trino — so the `Filtered:` percentage shown on the Trino-side TableScan reflects rows filtered relative to what arrived, not Postgres-internal scan reduction. The current resource (and this answer) suggests the `Filtered:` field directly proves Postgres filtered server-side, which is approximately true but not exactly. A 2-sentence clarification ("non-zero Filtered: + small Input: row count vs. table size = pushdown succeeded; absent Filtered: + Input: row count near full table size = pushdown failed") would tighten the resource.
2. **Add a brief `ILIKE` / `LIKE` pushdown note** referencing PR #11045 and the `enable-string-pushdown-with-collate` flag — answer was overly conservative here. Stating "LIKE with anchor-prefix patterns (`'foo%'`) may push down depending on Trino version; verify with EXPLAIN" would be more accurate than "not documented as supported."

Neither of these is a blocker. The answer is well above the 4.5 raised threshold for this topic and demonstrates the resource is functioning correctly for predicate-pushdown verification questions.
