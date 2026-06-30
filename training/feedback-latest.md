# Judge Feedback — Iteration 1309

**Phase**: extended (pass-loop)
**Overall iteration score**: **4.609 STRONG PASS** (Q1 4.9375 / Q2 3.75 / Q3 4.875 / Q4 4.875)
**Pattern**: HARD watch closure on Q1 (iter1305-Q3 columnar-projection mis-attribution → CLOSES POSITIVELY on this re-probe — responder now identifies COLUMNAR PROJECTION as the cause rather than partition-pruning/delete-files). Q2 is the lone drag — one per-instance grain-miss on the LAG worked query (assumed monthly-grained data even though engineer's table shape `account_id, event_date, event_count` strongly suggests daily granularity); LAG mechanism + OVER + ORDER BY + NULL guard all correct, but `LAG(event_count, 1)` directly on `event_date` compares consecutive days/rows not consecutive months → the engineer pasting this against daily-grained data silently gets wrong results. Q3 (snapshot history + time-travel) and Q4 (Oracle DECODE-NULL → Trino CASE) both pin-perfect.

---

## Per-question scoring

### Q1 — Columnar projection RE-PROBE of iter1305-Q3 HARD watch — **4.9375 STRONG PASS — WATCH CLOSES POSITIVELY**

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 5.0.

**Setup**: wide 90-column Iceberg events table; `SELECT *` = 90s, 4-column query = 6s; same WHERE filter, same row count returned. Why so much slower with `SELECT *`?

**Responder**: Columnar storage (Parquet on Iceberg) physically stores each column separately within row groups; the engine reads ONLY the column chunks for columns named in `SELECT`. `SELECT *` reads all 90 column chunks per row group ≈ 100% of storage. `SELECT 4_columns` reads only those 4 chunks ≈ 4-5% of storage. Same WHERE + same returned row count = same row-filtering work, but `SELECT *` does ~22× more bytes-read I/O at the scan layer. Not a row-filtering problem; it's an I/O / bytes-scanned problem at the file-format layer. Practical guidance: never `SELECT *` in production analytics; list columns explicitly; for SaaS dashboards rewrite to column-specific projections (the engineer's instinct is correct). Cited r03 columnar storage.

**HARD WATCH CLOSURE — iter1305-Q3 columnar-projection mis-attribution**: at iter1305 the responder mis-attributed a `SELECT *`-vs-narrow-column scan-time difference to partition-pruning / position-delete files (wrong mechanism — neither partition pruning nor delete-files explain a same-WHERE different-projection difference; columnar projection is the canonical answer). At this re-probe, given an explicit same-WHERE + same-row-count + projection-only-differs framing, the responder NOW reaches the COLUMNAR PROJECTION canonical cleanly on first pass. Watch **CLOSES POSITIVELY**.

**VERIFIED** via WebSearch on Parquet columnar storage mechanism: column chunks (within row groups) are the unit of I/O — query engines read ONLY chunks for columns named in the projection and skip all others; "column pruning can reduce I/O by 80-95% for wide tables" matches the responder's ~95%-reduction framing for a 4-of-90-column projection. Iceberg uses Parquet underneath (default `format='PARQUET'` confirmed in the production stack), so the mechanism applies directly. Sources: [Parquet Format: A Complete Guide](https://www.velodb.io/glossary/par-1), [What is Apache Parquet? Columns, Encoding, and Performance](https://datalakehousehub.com/blog/2026-04-apache-parquet/).

No imported-prior, no broken-secondary, no over-warning, no fabrication. The mechanism is correctly framed at the right abstraction (column chunks, bytes-scanned not rows, I/O not filter), the practical "never SELECT * in production analytics" prescription matches industry consensus, and the engineer's "rewrite dashboards to be column-specific" instinct is endorsed without overclaim.

### Q2 — LAG MoM percent change in one pass — **3.75 PASS (per-instance grain miss; primary worked-query slip)**

Acc 3.5 / Clar 4.0 / Prac 3.5 / Compl 4.0.

**Setup**: per account, total events this month vs last month as % change. Table `account_id, event_date, event_count`. Two subqueries + join, or LAG in one pass?

**Responder lead (CORRECT)**: LAG in one pass is the better Trino 467 form; window function decoration `LAG(event_count, 1) OVER (PARTITION BY account_id ORDER BY event_date) AS prior_month_count`, then `(curr - prior) / NULLIF(prior, 0) * 100` for percent change with NULLIF divide-by-zero guard; `ORDER BY` REQUIRED inside `OVER` for LAG (Trino enforces); YoY = `LAG(..., 12)`; `WHERE event_date >= date_trunc('month', current_date - INTERVAL '13' MONTH)` to scope to the recent window.

**LOAD-BEARING SLIP — grain assumption**: the responder applied `LAG(event_count, 1) OVER (PARTITION BY account_id ORDER BY event_date)` DIRECTLY on the source table. This is CORRECT **ONLY IF** the data is already monthly-grained (one row per `account_id` per month). With the engineer's table shape (`event_date` + `event_count` per row), the more natural reading is DAILY-GRAINED — i.e. `event_count` is the count for one specific `event_date`. On daily-grained data, `LAG(event_count, 1) OVER (ORDER BY event_date)` compares consecutive DAYS / consecutive ROWS, not consecutive MONTHS. The engineer pasting this gets a percent-change-vs-yesterday signal, not a percent-change-vs-prior-month signal — silently wrong.

**The robust form (NOT given) — aggregate to monthly FIRST, then LAG**:

```sql
WITH monthly AS (
  SELECT account_id,
         date_trunc('month', event_date) AS mon,
         SUM(event_count)                 AS monthly_total
  FROM events
  WHERE event_date >= date_trunc('month', current_date - INTERVAL '13' MONTH)
  GROUP BY account_id, date_trunc('month', event_date)
)
SELECT account_id, mon, monthly_total,
       LAG(monthly_total, 1) OVER (PARTITION BY account_id ORDER BY mon) AS prior_month_total,
       (monthly_total - LAG(monthly_total, 1) OVER (PARTITION BY account_id ORDER BY mon))
         * 100.0 / NULLIF(LAG(monthly_total, 1) OVER (PARTITION BY account_id ORDER BY mon), 0) AS pct_change
FROM monthly;
```

**Classification — per-instance grain miss on the worked query**: the LAG mechanism itself (OVER, ORDER BY required, offset semantics, NULLIF guard, `LAG(..., 12)` for YoY) is correct; the architectural recommendation (LAG over two-subqueries-and-join) is correct; only the worked SQL assumes monthly-grained input without disclosing the assumption or aggregating first. NOT a resource defect — r07 / r28 LAG canonicals teach the mechanism correctly and the `date_trunc('month', ...) GROUP BY + LAG` pattern is documented elsewhere; the responder didn't compose the two pieces under "% change month over month" framing. Similar in shape to the iter1303-Q2 `SUM(SUM(x)) OVER ROWS-frame` broken-secondary family (worked query missing the inner aggregate level), but here it's the PRIMARY worked query, not a secondary.

**NEW SOFT WATCH `iter1309-Q2 LAG-without-aggregate-to-monthly-first grain-assumption`**: re-probe 4-8 iters under varied "MoM / YoY % change with LAG" framings where the source table is daily-grained (`event_date` column rather than `month` column); if responder again drops the `date_trunc + GROUP BY` step and writes LAG directly on the daily table, escalate to LIGHT FIX-A at r07 §LAG-canonical adding a "FIRST aggregate to the comparison grain, THEN LAG" worked card with the daily→monthly aggregation example above. NO FIX-A on first occurrence.

No imported-prior, no broken-secondary in the strict sense (the LEAD is correct; the worked query has the grain bug), no over-warning, no fabrication.

### Q3 — Iceberg snapshot history + time-travel after a bad dbt run — **4.875 STRONG PASS — pin-perfect**

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

**Setup**: bad dbt model overwrote the production table; list snapshots; query the table as it was before the bad run.

**Responder**: `SELECT snapshot_id, committed_at, operation, summary FROM iceberg.analytics."events$snapshots" ORDER BY committed_at DESC` to list snapshots and identify the pre-bad-run snapshot_id. Whole-token quoting rule called out — `"events$snapshots"` is one quoted identifier, NOT `events."$snapshots"`. Then read at that snapshot via `SELECT ... FROM iceberg.analytics.events FOR VERSION AS OF <snapshot_id>`. For permanent revert: `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <snapshot_id>)` (3-arg positional form, metadata-only — table-pointer rewrite, atomic, regardless of table size). Cleanup with `EXECUTE expire_snapshots(retention_threshold => '7d')` AFTER verification.

**VERIFIED**:
- `$snapshots` metadata table exposes `snapshot_id` / `committed_at` / `operation` / `summary` (+ `parent_id`, `manifest_list`) per [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — every column responder named matches docs verbatim.
- `FOR VERSION AS OF <snapshot_id>` is the documented Trino 467 time-travel syntax with snapshot_id (BIGINT) — verified via [trino.io Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) + [Apache Iceberg Time Travel & Rollbacks in Trino (Starburst)](https://www.starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/). `FOR TIMESTAMP AS OF` also valid for time-based travel (recall ceiling not load-bearing here — engineer wanted snapshot_id).
- 3-arg `CALL iceberg.system.rollback_to_snapshot('schema', 'table', snapshot_id)` is the canonical Trino 467 form per pin `reference_trino_rollback_snapshot_form` (ALTER TABLE EXECUTE rollback_to_snapshot form is 469+); reconfirmed at iter1297-Q2.
- Whole-token quoting rule matches the docs example `example.testdb."customer_orders$snapshots"` verbatim.

Minor Compl shave (-0.25): didn't explicitly contrast `FOR VERSION AS OF` (read at snapshot, table-pointer unchanged — safe for ad-hoc reads / data-recovery copy) vs `rollback_to_snapshot` (rewrites the current-snapshot pointer — DISCARDS any legitimate writes committed after the bad-run snapshot). For a single-bad-run + no-concurrent-good-writes scenario these are equivalent; on a busier table it matters. Not load-bearing for this engineer's narrative.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

### Q4 — Oracle DECODE NULL + ranges → Trino CASE — **4.875 STRONG PASS — pin-perfect, comprehensive**

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

**Setup**: Oracle DECODE with range logic (0-100 → 'low', etc.). Does Oracle DECODE treat NULLs same as CASE WHEN? Convert DECODE-with-ranges to Trino CASE — watch-outs?

**Responder**:
1. **Oracle DECODE NULL semantics**: DECODE treats `NULL = NULL` as a MATCH (Oracle's documented exception to the standard `NULL` propagation rule); Trino simple `CASE col WHEN NULL THEN ...` does NOT (per SQL standard `col = NULL` → UNKNOWN → never matches). Use `CASE WHEN col IS NULL THEN ... ELSE ... END` (searched form) for the NULL branch in Trino.
2. **Range-based DECODE → searched CASE**: DECODE only supports exact-equality matches; range-based "0-100 → 'low'" rewrites in Trino need searched CASE: `CASE WHEN value BETWEEN 0 AND 100 THEN 'low' WHEN value BETWEEN 101 AND 1000 THEN 'mid' ... END`. Do NOT use simple `CASE value WHEN ...` form for ranges (it only does equality).
3. **NULL gotcha re-emphasized**: `col = NULL` returns UNKNOWN in Trino; simple `CASE col WHEN NULL` therefore never matches. Use `WHEN col IS NULL`.
4. **Type coercion**: CAST if mixing types across CASE result branches (Trino is strict — all THEN branches must produce a common supertype; Oracle DECODE is more lenient).
5. **Audit steps**: scan Oracle DDL for DECODE expressions, identify NULL-comparison + range patterns, rewrite each.

**VERIFIED** via [databasestar.com Oracle DECODE Function](https://www.databasestar.com/oracle-decode-function/) + [oracletutorial.com Oracle DECODE Function](https://www.oracletutorial.com/oracle-comparison-functions/oracle-decode/) + [sqlines.com Oracle to SQL Server DECODE NULL Issue](https://www.sqlines.com/oracle-to-sql-server/decode):
- DECODE's documented NULL=NULL-as-MATCH exception: "Oracle considers two nulls to be equivalent while working with DECODE function. For example, if expression is null, then Oracle returns the result of the first search that is also null" — exactly matches responder framing.
- CASE simple-form `WHEN NULL` never matches: "when converting DECODE to CASE expression and there is a NULL condition, you have to use the searched CASE form with IS NULL condition, because WHEN NULL is never true in simple CASE expressions" — verbatim matches.
- DECODE is equality-only; ranges require CASE — well-established.

Minor Compl shave (-0.25): didn't explicitly mention that `NVL(col, sentinel)` wrapping is an alternative pattern to emulate Oracle DECODE's NULL=NULL match (responder went straight to `IS NULL` branch which is cleaner — equally valid choice, not load-bearing).

No imported-prior (DECODE-NULL-semantics correctly attributed to Oracle, not over-generalized), no broken-secondary, no over-warning, no fabrication. Pin-quality answer; engineer can paste-and-run on a real Oracle→Trino DECODE migration.

---

## Source-verified outcomes

- 0 fabrications
- 0 Trino dialect parse-errors
- 0 imported-prior assumed-absence
- 0 broken-secondary in the responder-padding family
- 0 over-warning folklore
- 0 false-premise endorsement
- 0 resource defects
- 1 LOAD-BEARING grain miss on Q2 worked query (LAG directly on daily-grained `event_date` without aggregate-to-monthly-first step) — per-instance worked-query slip, NOT a resource defect (r07/r28 LAG + `date_trunc + GROUP BY` canonicals are present and correct individually); engineer pasting on daily data silently gets wrong result. CLASSIFIED as new SOFT watch, NOT FIX-A on first occurrence per `feedback_synthesis_ceiling_stop_churning.md` discipline.

---

## Recommendation

**NO-OP** on resources. iter1305-Q3 columnar-projection HARD watch CLOSES positively (the re-probe target reached the right canonical cleanly). Q2 grain-miss is per-instance — new SOFT watch only (re-probe 4-8 iters under varied MoM/YoY framings against daily-grained sources). Q3 + Q4 are pin-perfect, reconfirming `reference_trino_rollback_snapshot_form` (3-arg CALL) and Oracle DECODE-NULL-vs-Trino-CASE-IS-NULL family knowledge.

## Watch updates

- **CLOSING (positive)**: iter1305-Q3 columnar-projection mis-attribution HARD watch — responder NOW correctly identifies columnar projection (column chunks per Parquet row group, only selected columns read, I/O not row-filtering) under explicit same-WHERE + same-row-count + projection-differs framing.
- **NEW LOW SOFT WATCH**: `iter1309-Q2 LAG-without-aggregate-to-monthly-first grain-assumption` — re-probe 4-8 iters under varied "MoM / YoY % change with LAG" framings where the source table is daily-grained (`event_date` column rather than `month` column); escalate to LIGHT FIX-A only at 2+ recurrences with the same grain-miss pattern.
- **CARRY (not exercised)**: iter1303-Q2 SUM(SUM)-OVER broken-secondary; iter1300-Q2 spill-causality; iter1299-Q3 this-guard; iter1298-Q2 metadata-tables-for-file-layout; iter1285-Q2 timestamp-tz; iter1281-Q1 system.runtime; iter1278-Q1 Scheduled-vs-CPU.
- **DOWNGRADED previously (carry)**: iter1307-Q4 Oracle-migration→r23 string-canonical routing miss (LOW).

## Topic score updates

| Topic | Before | After | Δ | Margin over 3.5 |
|---|---|---|---|---|
| Column-oriented storage — what it is and why it's faster for analytics | 4.5416 / 17 | **4.5636 / 18** | +0.0220 | +1.0636 |
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | 4.4828 / 216 | **4.4794 / 217** | −0.0034 | +0.9794 |
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.4597 / 250 | **4.4614 / 251** | +0.0017 | +0.9614 |
| Oracle PL/SQL → dbt + Trino migration | 4.4997 / 286 | **4.5010 / 287** | +0.0013 | +1.0010 |

All required topics REMAIN PASSED.

## Pattern observation

This is a notable iter for two reasons: (1) iter1305-Q3 was the longest-standing HARD watch in the recent carry-forward set (mis-attribution of a projection-driven scan-time difference to partition-pruning/delete-files — a fundamental columnar-storage gap); the explicit same-WHERE + same-row-count framing this iter unambiguously isolated projection as the only variable, and the responder reached COLUMNAR PROJECTION cleanly without prompting. Closes the watch positively. (2) Q2 is a fresh per-instance worked-query slip in a still-active sub-pattern (worked SQL assumes a grain not present in the engineer's stated table shape, similar to the iter1303-Q2 cumulative-spend SUM-of-SUM-OVER worked-query slip). The LAG architectural recommendation is correct + the LAG mechanism is correct + the resources have both the LAG canonical and the `date_trunc + GROUP BY` aggregation canonical — but composing the two under "MoM % change" framing failed on first probe. SOFT watch only, no FIX-A; re-probe to determine whether this is a recurring composition gap or a one-off.

Q3 + Q4 are pin-confirmation cleanups, joining the long streak of 1st-re-probe-clean-reach on `reference_trino_rollback_snapshot_form` (3-arg CALL) and Oracle-DECODE-NULL family.

ALL required topics REMAIN PASSED.
