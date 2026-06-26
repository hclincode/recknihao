# Iter1122 Judge Feedback — 4.9844 STRONG PASS NO-OP

## Verdict: STRONG PASS, NO-OP

Iter average **4.9844** (margin +1.4844 above 3.5 threshold). All four answers source-verified clean against trino.io 467 RAW docs (string.html, iceberg.html). Breadth durability sweep across four less-recently-probed angles in already-passed topics; no resource defects, no watch streams opened.

---

## Per-question scoring

### Q1 — First-touch attribution: earliest event's channel per user, sum purchase revenue per channel
**Score: 5.0000** (Acc 5 / Clar 5 / App 5 / Compl 5)

Responder: CTE `first_event` with `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time ASC) AS rn`; JOIN `purchases ON user_id`; `WHERE rn=1`; `SUM(p.revenue)`, `COUNT(DISTINCT user_id)`, `GROUP BY channel`.

- Canonical first-touch attribution shape: PARTITION BY user, ORDER BY event_time ASC, rn=1 = earliest.
- Correctly separates attribution dimension (channel from first event) from the dollar source (revenue from purchases).
- `GROUP BY channel` aggregates per channel; added `COUNT(DISTINCT user_id)` for converting-user funnel context.
- ROW_NUMBER (not RANK/DENSE_RANK) is correct for first-touch — ties at exact event_time bucket randomly within a user, acceptable for first-touch and explicitly addressed by ORDER BY event_time ASC.
- ORDER BY ASC explicit (no folklore default ordering).

Verified: standard Trino 467 window function pattern. No fabrications, no folklore.

### Q2 — Extract subdomain (everything before first dot); does Trino have strpos?
**Score: 5.0000** (Acc 5 / Clar 5 / App 5 / Compl 5)

Responder: Trino HAS `strpos()` but `split_part(host, '.', 1)` is the clean idiom -> `'analytics'`; 1-indexed; out-of-range index returns NULL; cleaner than `substr(host, 1, strpos(host, '.') - 1)`.

**Source-verified against trino.io/docs/current/functions/string.html:**
- `strpos(string, substring) → bigint` — "Returns the starting position of the first instance of `substring` in `string`. Positions start with `1`. If not found, `0` is returned." **strpos exists in Trino 467 — responder CORRECT.**
- `split_part(string, delimiter, index) → varchar` — "Splits `string` on `delimiter` and returns the field `index`. Field indexes start with `1`. **If the index is larger than the number of fields, then null is returned.**" **Responder CORRECT on NULL (not empty string) out-of-range behavior.**
- `split_part(host, '.', 1)` on `'analytics.acmecorp.com'` correctly returns `'analytics'`.
- Engineer-useful: strpos+substr is the verbose two-call form; split_part is the one-call clean form. Responder answered BOTH the literal existence question AND chose the cleaner idiom — desirable behavior, no over-warning.

No imported-prior trap (strpos handling clean; no false claim it doesn't exist).

### Q3 — Iceberg $partitions metadata: file/row counts per partition without scanning 500M rows
**Score: 5.0000** (Acc 5 / Clar 5 / App 5 / Compl 5)

Responder: `SELECT partition, record_count, file_count, total_size FROM iceberg.analytics."events$partitions"`; warns `events."$partitions"` (split-quote form) is WRONG / parse-fail; added a `pct_of_total` skew window; metadata-only access.

**Source-verified against trino.io/docs/current/connector/iceberg.html `$partitions` metadata table:**
- Quoting: docs use `"test_table$partitions"` in ONE double-quote pair — **responder CORRECT, split-quote defang is right** (split form IS a parse error per Trino SQL parser — `$` is not a valid identifier start without quoting).
- Columns confirmed: `partition ROW(...)`, `record_count BIGINT`, `file_count BIGINT`, `total_size BIGINT` (plus `data ROW(... min/max/null_count/nan_count)`) — responder's four-column projection exactly matches.
- $partitions is a metadata table sourced from Iceberg manifests — no data file scan, returns at planning/metadata speed even on 500M-row tables. Directly addresses "without scanning 500M rows" constraint.
- `pct_of_total` window (`100.0 * record_count / SUM(record_count) OVER ()`) is a strong value-add for "evenly spread across monthly partitions" framing — engineer can act on skew immediately.

Matches production stack (Trino 467 + Iceberg connector + Hive Metastore + MinIO from prod_info.md).

### Q4 — Added nullable boolean `is_churned`; `WHERE is_churned = false` returns 800 not 1200; 400 NULL excluded — is Trino dropping NULLs?
**Score: 4.9375** (Acc 5 / Clar 5 / App 5 / Compl 4.75)

Responder: Three-valued logic — `NULL = false` evaluates to UNKNOWN (not TRUE), so NULL rows are filtered; fixes are `WHERE is_churned = false OR is_churned IS NULL` or `WHERE COALESCE(is_churned, false) = false`. Framed as standard ANSI SQL behavior, not a Trino bug.

- SQL three-valued logic explanation precise and engineer-recognizable: `NULL = anything → UNKNOWN`, WHERE keeps only TRUE rows.
- Both fix forms are correct Trino 467 syntax and semantically equivalent for boolean column: explicit `OR ... IS NULL` and null-replacement `COALESCE(..., false) = false`.
- "Standard ANSI SQL, not a bug" framing directly addresses the engineer's framing question.

**Minor completeness shave (-0.25):** `WHERE is_churned IS NOT TRUE` is the most compact equivalent (`IS NOT TRUE` returns TRUE for both `FALSE` and `UNKNOWN/NULL` per SQL standard) and would also fix the issue in a single token. Responder gave two valid fixes but missed the cleanest one-call form. Per-instance enumeration ellipsis, NOT a content gap — no resource defect. Per `feedback_responder_broken_secondary_alternative`, missing-an-alternative shading scopes as per-instance not structural when the primary fixes already work.

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---:|---:|---:|---:|---:|
| Q1 | Analytical query patterns (first-touch attribution) | 5 | 5 | 5 | 5 | 5.0000 |
| Q2 | SQL best practices (strpos exists + split_part idiom) | 5 | 5 | 5 | 5 | 5.0000 |
| Q3 | Iceberg table maintenance ($partitions metadata) | 5 | 5 | 5 | 5 | 5.0000 |
| Q4 | SQL best practices (three-valued logic NULL=false) | 5 | 5 | 5 | 4.75 | 4.9375 |

**Iteration average: (5.0000 + 5.0000 + 5.0000 + 4.9375) / 4 = 4.9844 STRONG PASS** (margin +1.4844 over 3.5 threshold).

---

## Source-verified clean (no defects)

- **Q1**: ROW_NUMBER + rn=1 + JOIN + GROUP BY channel is canonical first-touch attribution. No fabrications.
- **Q2**: strpos signature, split_part signature, out-of-range = NULL all match trino.io/docs/current/functions/string.html verbatim.
- **Q3**: `$partitions` quoting (`"events$partitions"` single token), column names (partition/record_count/file_count/total_size), metadata-only behavior all match trino.io/docs/current/connector/iceberg.html.
- **Q4**: Three-valued logic `NULL = false → UNKNOWN` is standard ANSI SQL Trino implements per spec; both fix forms produce correct results.

No recurrence of: `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover/imported-prior/GREATEST-NULL-Postgres/array_sum/`->`/`->>`-JSON/DATEDIFF-dialect-import/multi-arg-COUNT-DISTINCT/ts-minus-ts/over-warning/multi-clause-ADD-COLUMN/contains_sequence-array_position-arithmetic.

---

## Topics updated

- **Analytical-query-patterns-Iceberg+Trino** (Q1, first-touch attribution): 4.4603/76 → (339.0828 + 5.0000)/77 = **4.4686/77 PASSED** (+0.0083; margin to 3.5 widens to +0.9686).
- **SQL-query-best-practices-OLAP** (Q2 split_part + Q4 three-valued logic): 4.5175/177 → (799.5975 + 5.0000 + 4.9375)/179 = **4.5225/179 PASSED** (+0.0050; margin to 3.5 widens to +1.0225).
- **Iceberg-table-maintenance** (Q3 $partitions metadata table): 4.4724/175 → (782.6700 + 5.0000)/176 = **4.4754/176 PASSED** (+0.0030; margin to 3.5 widens to +0.9754).

ALL required topics REMAIN PASSED.

---

## Teacher guidance

**RECOMMENDATION = NO-OP.** No resource edits. Commit rubric + feedback only.

Rationale:
1. All four answers source-verified against trino.io 467 RAW docs (string.html for strpos/split_part NULL-on-overflow; iceberg.html for $partitions schema & single-quote-token form).
2. Q4 missing `IS NOT TRUE` is a one-instance per-instance enumeration ellipsis — per `feedback_responder_broken_secondary_alternative` and `feedback_synthesis_ceiling_stop_churning`, no churn on first-instance shade when two valid fixes already given.
3. No watch streams open from prior iters (iter1116 ts-minus-ts CLOSED iter1118; iter1120 multi-clause ADD COLUMN CLOSED iter1121).
4. 8-iter STRONG PASS streak continues: 1090/1092/1093/1117/1118/1119/1121/1122 all ≥4.75 with 1091/1116 LIGHT FIX-A iters confirmed reaching between — content lineage durable, no structural drift.

### Re-probe queue (thinnest margins first; not requested this iter)

1. **storage-tiering 9th angle** (3.9219/8, +0.4219 margin — still thinnest, lifted off floor iter1119/1121) — multi-bucket lifecycle or tier-vs-orphan interaction.
2. **dbt-snapshots SCD2 16th angle** (4.0961/15, +0.5961) — `dbt_is_deleted` hard-delete CDC, check_cols edge cases.
3. **cost-considerations 22nd angle** (4.2504/21, +0.7504) — `$manifests` partition-level cost attribution / per-tenant split.
4. **query-perf-regression-diagnosis 21st angle** (4.3108/20, +0.8108) — concurrent ETL-vs-dashboard contention oncall.
5. **query-perf-basics 21st angle** (4.3629/20, +0.8629) — EXPLAIN dynamic-filtering verification.

Federation untouched (4.50244/312 fragile-PASS preserved). CBO/ANALYZE 4.5920/21 untouched.

### Optional Q4 micro-completeness probe (NOT recommended now)

If `IS NOT TRUE` becomes a recurring shave across 2+ iters, a one-line addendum to the existing three-valued-logic resource could enumerate the trio `= false OR IS NULL` / `IS NOT TRUE` / `COALESCE(...,false) = false`. Single-instance shade per-instance ellipsis; **NO FIX-A this iter**.

---

## Pattern observation

This iter's four targets were deliberately less-recently-probed angles in already-passed topics:
- Q1 first-touch attribution (variant of cohort/funnel attribution in analytical-query-patterns row).
- Q2 strpos-existence + split_part-cleaner (function-existence + idiom-choice in SQL-best-practices row).
- Q3 $partitions metadata-only counts (Iceberg metadata-table operational use in table-maintenance row).
- Q4 boolean NULL three-valued logic (NULL-handling completeness in SQL-best-practices row).

All four scored clean (Q4's 4.9375 is per-instance enumeration shade, not a content gap). The "imported-prior" family did NOT trigger (strpos/split_part existence handled correctly without Postgres-vs-Trino confusion). The "fabricated-fn-trap" family did NOT trigger (no false-positive defanging of strpos as "not in Trino" — `reference_trino_starts_with_ends_with`-class self-error did not recur). The "over-warning" family did NOT trigger (responder answered the existence question AND chose the cleaner idiom, didn't collapse to a defensive single-answer).

8-iter STRONG PASS streak (1090/1092/1093/1117/1118/1119/1121/1122) with two intervening LIGHT FIX-A iters (1091 contains_sequence findability; 1116 ts-minus-ts watch open) and one watch-stream iter (1120 closed iter1121) — content lineage durable, no structural drift, no new watch streams opened.
