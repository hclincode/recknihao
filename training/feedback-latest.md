# Judge Feedback — iter781

**DEFAULT NO-OP / durability-breadth sweep** (teacher made ZERO resource edits). 4 fresh adjacent probes: median / date-spine-sequence / top-category-per-group / Iceberg time-travel. All dialect claims verified vs trino.io/docs/467 (array.html, aggregate.html) + Iceberg connector docs on 2026-06-09. resources/ NOT treated as ground truth.

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | median (approx_percentile 0.5) | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | date series / fill missing dates | 3 | 2 | 4 | 2 | **2.75** |
| Q3 | top category per customer | 5 | 5 | 5 | 5 | **5.00** |
| Q4 | Iceberg time-travel | 5 | 5 | 5 | 5 | **5.00** |

**Overall avg = (5.00 + 2.75 + 5.00 + 5.00) / 4 = 4.4375 → PASS** (threshold 3.5; overall average governs, no single-Q veto).

---

## Q1 — median via approx_percentile — 5.00 CLEAN

`approx_percentile(order_value, 0.5) AS median_order_value` — VERIFIED vs trino.io/docs/467/functions/aggregate.html: `approx_percentile(x, percentage)` returns the approximate percentile; `approx_percentile(x, percentages)` accepts an ARRAY and returns an array (so `ARRAY[0.5,0.95,0.99]` is valid). Responder correctly stated:
- single-pass t-digest;
- the array form for multiple percentiles in one pass;
- Trino 467 has **NO** `MEDIAN()` and **NO** `PERCENTILE_CONT(...) WITHIN GROUP` (those are Postgres/Snowflake) — CONFIRMED absent in the docs.
For an EXACT median Trino has no direct function; `approx_percentile` is the standard idiom and the right answer to "typical/median, half above half below." Standing p95/approx_percentile pin held. No defect.

## Q2 — date series / fill missing calendar days — 2.75 — PRIMARY FINDING: FINDABILITY MISS

The responder **HONESTLY DECLINED**: "I don't have a dedicated resource showing how to generate a date sequence in Trino (like Postgres generate_series)… I cannot give you the exact Trino function… check trino.io/docs/467." It advised a calendar table + LEFT JOIN + COALESCE-to-zero conceptually, but did **NOT** surface `sequence()` + `UNNEST`.

**This is a real miss of a common, fully-answerable need. The CORRECT answer EXISTS in Trino AND in the resources.**

VERIFIED vs trino.io/docs/467/functions/array.html: `sequence(start, stop, step)` supports DATE bounds with an `INTERVAL DAY TO SECOND` step (e.g. `INTERVAL '1' DAY`), both bounds inclusive; there is NO `generate_series` in Trino. So the canonical date-spine is:

```sql
SELECT d
FROM UNNEST(sequence(DATE '2026-01-01', current_date, INTERVAL '1' DAY)) AS t(d)
```

then `LEFT JOIN daily_signups s ON s.day = c.d` and `COALESCE(s.cnt, 0)`. No manual placeholder rows.

### VERDICT: FINDABILITY MISS (content exists, responder couldn't reach it) — NOT a gap

GREP evidence — the content is present in `resources/07-analytical-query-patterns.md`:
- **§4 "Time-series rollups (with gap-filling)"** — `resources/07-analytical-query-patterns.md:1206`.
- The point-event zero-fill canonical — `07:1239-1256`: "Fix: generate a calendar and LEFT JOIN" using a `calendar` CTE `date_add('day', n, current_date - INTERVAL '30' DAY) FROM UNNEST(sequence(0, 29)) AS t(n)`, then `LEFT JOIN signups … COALESCE(s.cnt, 0)` — this is exactly the zero-fill pattern Q2 asked for, but built on an INTEGER sequence + `date_add`.
- The `sequence()` signature pin — `07:1258`: documents `sequence(start, stop[, step])` for dates with `INTERVAL` step, both bounds inclusive, and "There is NO `generate_series` function in Trino." Keyword anchors there: "Trino generate_series, Trino date spine, Trino generate range of dates, Trino row spine, Trino generate calendar, Trino date range UNNEST."
- The DIRECT date-form spine `SELECT d AS day FROM UNNEST(sequence(DATE '2026-05-01', DATE '2026-05-31', INTERVAL '1' DAY)) AS t(d)` — `07:1445` — but it is buried inside the **interval-overlap / reservations-per-room-per-day** variant, NOT at the primary point-event landing point.

So `sequence(DATE, DATE, INTERVAL '1' DAY) + UNNEST` DOES appear (07:1445), AND the zero-fill LEFT JOIN + COALESCE recipe DOES appear (07:1239-1256). The responder still declined. Root cause: the primary date-spine landing point (07:1239-1258) leads with the integer-sequence/`date_add` form and a "last 30 days" framing; the copy-attractive direct date-form spine is hidden in the interval-overlap variant; and the signature-pin keyword anchors emphasize "generate_series / date spine / generate range of dates" but NOT the phrasings this question used: **"generate every calendar date between two dates," "fill missing dates," "zero-fill gap days," "continuous date range," "calendar table," "without manual placeholder rows."**

### iter782 = FIX-A (findability, date-series) — near-certain

Add a **copy-attractive direct date-form canonical at the §4 primary landing point** (07:~1239, alongside or as the first-shown form ahead of the integer-sequence lead), featuring:

```sql
-- Date spine: one row per calendar day from a start date to today, then LEFT JOIN + zero-fill
WITH calendar AS (
  SELECT d AS day
  FROM UNNEST(sequence(DATE '2026-01-01', current_date, INTERVAL '1' DAY)) AS t(d)
),
daily AS (
  SELECT date_trunc('day', event_time) AS day, COUNT(*) AS cnt
  FROM iceberg.analytics.daily_signups
  WHERE event_time >= DATE '2026-01-01'
  GROUP BY 1
)
SELECT c.day, COALESCE(s.cnt, 0) AS signups
FROM calendar c
LEFT JOIN daily s ON s.day = c.day
ORDER BY c.day;
```

Add these landing-point keyword anchors at 07:1239/1258: **"generate a date series, every calendar day between two dates, fill missing dates, fill gap days with zero, zero-fill missing days, date spine, continuous date range, calendar table, every date from X to today, generate_series equivalent Trino, no manual placeholder rows / no VALUES list."** Keep the integer-sequence + `date_add` form as an alternative below the date-form canonical. Reconcile-in-place — do NOT just append; the direct date-form must be the FIRST and most copy-attractive form at the point-event landing point so the responder reaches it from "fill missing dates / continuous date range" keywords.

## Q3 — top category per customer — 5.00 CLEAN

`ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY COUNT(*) DESC) AS category_rank` over an inner `GROUP BY customer_id, category` query, outer `WHERE category_rank = 1` → exactly one row per customer = their #1 category by purchase count. VERIFIED valid Trino 467 (the window function runs AFTER GROUP BY and may ORDER BY the aggregate `COUNT(*)`). Responder correctly noted `RANK() … <= 1` to include ties. (`max_by(category, cnt)` after the group is a valid alternative, not required.) No defect. r07 top-per-group pattern held.

## Q4 — Iceberg time-travel (read as of yesterday) — 5.00 CLEAN (one minor quoting nuance, NOT docked)

VERIFIED vs trino.io/docs/467 Iceberg connector:
- `… FOR TIMESTAMP AS OF TIMESTAMP '2026-06-08 00:00:00'` — VALID Trino 467 Iceberg syntax (a DATE/timestamp point-in-time also works). CORRECT.
- `… FOR VERSION AS OF <snapshot_id>` — VALID. **Nuance:** the snapshot id is a BIGINT, so the unquoted numeric form `FOR VERSION AS OF 8954597067493422955` is correct; the QUOTED form `FOR VERSION AS OF 'name'` is for a NAMED reference/tag, not a numeric id. The responder wrote `FOR VERSION AS OF '<snapshot_id>'` with quotes around a snapshot-id placeholder — technically a numeric id should be unquoted. Treated as a placeholder, not misleading → noted, **not docked**. (If a future answer quotes a literal numeric id, dock Accuracy.)
- Rollback: `CALL iceberg.system.rollback_to_snapshot('schema','table',<snapshot_id>)` — CONFIRMED the correct Trino 467 form (the `ALTER TABLE … EXECUTE rollback_to_snapshot` form is 469+; standing rollback-CALL pin held). The responder correctly framed this as an admin/mutating operation.
- Snapshots immutable; `expire_snapshots` cleanup with ~7-day default retention — CONFIRMED reasonable: `iceberg.expire-snapshots.min-retention` default is 7 days, configurable (`ALTER TABLE … EXECUTE expire_snapshots(retention_threshold => '7d')`). Not wrong.

Core FOR TIMESTAMP / FOR VERSION AS OF is right; the rollback CALL form is right; the retention note is right. Right answer to "read the table as it was yesterday before a bad update." No defect.

---

## Summary / teacher actions

- **iter781 = PASS (4.4375).** Q1/Q3/Q4 all 5.00 CLEAN — median (approx_percentile), top-per-group (ROW_NUMBER over grouped aggregate), Iceberg time-travel (FOR TIMESTAMP/VERSION AS OF + rollback CALL) all verified bulletproof.
- **PRIMARY FINDING — Q2 date-series FINDABILITY MISS** (responder declined an answerable, common need that EXISTS at `07:1239-1258` + `07:1445`). **iter782 = FIX-A**: surface a copy-attractive direct `sequence(DATE d1, DATE d2, INTERVAL '1' DAY) + UNNEST` zero-fill canonical at the §4 primary point-event landing point (07:~1239) with the missing keyword anchors ("fill missing dates / continuous date range / every calendar day between two dates / calendar table / no manual placeholder rows"). Reconcile-in-place; make the date-form the first-shown form.
- **PRESERVE** (verified clean, churn risk): r05/r23 approx_percentile-median card; r07 top-per-group ROW_NUMBER/RANK pattern; r13 Iceberg time-travel FOR TIMESTAMP/VERSION AS OF + rollback_to_snapshot CALL + expire_snapshots cards.
- Q4 watch-item: VERSION-AS-OF numeric-id quoting (unquoted BIGINT vs quoted named ref) — optional one-line clarification in r13 if churning that card anyway; not a standalone fix.
