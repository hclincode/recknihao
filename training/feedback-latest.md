# Judge Feedback — Iter 492

**Phase**: extended (end-of-iteration feedback only)
**Overall**: 4.156 PASS (+0.656 above 3.5 floor)
**Federation**: NOT probed this iter — 4.49944/310 row HELD per iter472-492+ directive

---

## Headline

**Q1 TIMEZONE FIX CONFIRMED LANDED.** Responder correctly produced zone-aware boundary-literal half-open range (`TIMESTAMP '2026-06-01 00:00:00 America/New_York'`) AND `CAST(created_at AT TIME ZONE 'America/New_York' AS date)` for GROUP BY. Bare-string BETWEEN correctly flagged as type error. Iter491 teacher §4.2B canonical block in r27 CONFIRMED WORKING.

**Q2 LOAD-BEARING SEMANTIC MISMATCH.** Responder computed `LAG(COUNT(*)) OVER (PARTITION BY customer_id ORDER BY date_trunc('month', occurred_at))` with default offset 1 and labeled the result `usage_last_month`, then used it in `yoy_growth_pct`. This is month-over-month (previous month), NOT year-over-year (same month last year). YoY requires `LAG(metric, 12)` over a complete gap-filled monthly series, OR a self-join matching `(customer_id, month) = (customer_id, month - INTERVAL '1' YEAR)`. The answer is internally inconsistent (column name says "last month"; downstream metric says "YoY") and answers the wrong question. This is a resource gap — no resource currently covers LAG(N, 12) vs LAG(N, 1) for YoY vs MoM.

**Q3 Iceberg ADD COLUMN CLEAN.** Correct on all counts: metadata-only, NULL for old rows, no rewrite, backward-compatible.

**Q4 Oracle MERGE→dbt CLEAN.** Correct on all counts: merge strategy, composite unique_key, is_incremental (NOT execute), format_version=2. Iter489/490 execute-guard regression did NOT recur.

---

## Per-question breakdown

### Q1 — Timezone filter re-probe (4.75 STRONG PASS)

**CONFIRMED FIXED — iter491 teacher canonical §4.2B block in r27 LANDED.**

Responder produced:
```sql
WHERE created_at >= TIMESTAMP '2026-06-01 00:00:00 America/New_York'
  AND created_at < TIMESTAMP '2026-07-01 00:00:00 America/New_York'
```
And for GROUP BY:
```sql
CAST(created_at AT TIME ZONE 'America/New_York' AS date)
```

Both forms match r27 §4.2B exactly:
- Zone-aware boundary-literal half-open range = PREFERRED form (sargable, partition-prunes)
- CAST-AT-TIME-ZONE-AS-date = ALSO CORRECT form for GROUP BY / ad-hoc
- Bare-string BETWEEN correctly identified as type error (no VARCHAR→TIMESTAMP WITH TIME ZONE coercion in Trino)

Verified against trino.io/docs/current/language/types.html (TIMESTAMP WITH TIME ZONE literal with IANA zone name is valid) and trino.io/docs/current/functions/datetime.html (AT TIME ZONE semantics: re-renders the same instant in the given zone, does NOT change the underlying instant).

- Accuracy 5.0 | Clarity 4.5 | Actionability 5.0 | Completeness 4.5
- **Q1 avg: 4.75**
- Fab status: ZERO fabrications. TIMEZONE FIX CONFIRMED.

### Q2 — YoY usage per customer (2.375 FAIL)

**LOAD-BEARING SEMANTIC MISMATCH — computes MoM, labels/uses it as YoY.**

Responder gave:
```sql
LAG(COUNT(*)) OVER (PARTITION BY customer_id ORDER BY date_trunc('month', occurred_at))
  AS usage_last_month
```
Then computed `yoy_growth_pct = (current_month_usage - usage_last_month) / usage_last_month * 100`.

**ERROR 1 — Wrong offset for YoY.** `LAG(x)` with default offset 1 returns the value from 1 row back — the PREVIOUS MONTH. Confirmed: trino.io/docs/current/functions/window.html states "lag(x[, offset[, default_value]]) → Returns the value at offset rows before the current row in the window partition. The default offset is 1." For same-month-last-year (YoY), the correct forms are:
- `LAG(metric, 12) OVER (PARTITION BY customer_id ORDER BY month)` — requires the monthly series to be gap-filled (every customer must have a row for every month in the window; missing months silently shift the offset);
- Self-join: `JOIN monthly_counts prev ON prev.customer_id = cur.customer_id AND prev.month = cur.month - INTERVAL '1' YEAR` — handles gaps naturally.

**ERROR 2 — Internal inconsistency.** The column is named `usage_last_month` (suggesting month-over-month) but the downstream metric is named `yoy_growth_pct` (suggesting year-over-year). These are contradictory labels for the same value.

**ERROR 3 — Silent gap corruption.** Even for MoM, LAG(offset 1) only returns "previous month" when every customer has a contiguous monthly row. The WHERE clause filters the last 12 months but does not gap-fill. A customer with data in January and March but not February would have `LAG(March) = January` — a 2-month-back comparison, not 1-month-back.

The WHERE filter covers 12 months, which is necessary for YoY but insufficient — it does not create missing month rows.

The correct YoY answer:
```sql
-- Option A: LAG(12) over gap-filled series
WITH monthly AS (
  SELECT
    customer_id,
    date_trunc('month', occurred_at) AS month,
    COUNT(*) AS usage_count
  FROM iceberg.analytics.events
  WHERE occurred_at >= date_add('month', -24, date_trunc('month', current_date))
  GROUP BY 1, 2
),
gap_filled AS (
  -- Generate all (customer, month) pairs for the window to avoid shift
  SELECT DISTINCT customer_id, m.month
  FROM monthly
  CROSS JOIN (SELECT sequence(
    date_add('month', -24, date_trunc('month', current_date)),
    date_trunc('month', current_date),
    INTERVAL '1' MONTH
  ) AS months) t(ms)
  CROSS JOIN UNNEST(ms) AS m(month)
),
joined AS (
  SELECT gf.customer_id, gf.month,
    COALESCE(m.usage_count, 0) AS usage_count
  FROM gap_filled gf LEFT JOIN monthly m USING (customer_id, month)
)
SELECT
  customer_id,
  month,
  usage_count AS current_month,
  LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month) AS same_month_last_year,
  CASE WHEN LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month) > 0
       THEN (usage_count - LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month))
            * 1.0 / LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month) * 100
  END AS yoy_growth_pct
FROM joined
WHERE month = date_trunc('month', current_date);

-- Option B: self-join (gap-safe)
SELECT cur.customer_id, cur.month AS current_month,
  cur.usage_count AS current_usage,
  prev.usage_count AS last_year_usage,
  (cur.usage_count - prev.usage_count) * 1.0
    / NULLIF(prev.usage_count, 0) * 100 AS yoy_growth_pct
FROM monthly_counts cur
LEFT JOIN monthly_counts prev
  ON prev.customer_id = cur.customer_id
 AND prev.month = date_add('month', -12, cur.month)
WHERE cur.month = date_trunc('month', current_date);
```

- Accuracy 1.5 | Clarity 3.5 | Actionability 2.0 | Completeness 2.5
- **Q2 avg: 2.375**
- Fab status: ONE load-bearing semantic error (LAG offset 1 = MoM, not YoY); ONE internal inconsistency (mislabeled column `usage_last_month` used in `yoy_growth_pct`); ONE silent-failure trap (gap corruption).

### Q3 — Iceberg ADD COLUMN (4.75 STRONG PASS)

**ALL CLAIMS CORRECT.**

- `ALTER TABLE iceberg.analytics.events ADD COLUMN device_type VARCHAR` — correct Trino Iceberg syntax
- Metadata-only, no file rewrite — CONFIRMED at iceberg.apache.org/docs/latest/evolution: "schema updates are metadata-only changes" and "no data files are changed when you perform a schema update"
- Existing rows read NULL for the new column — CONFIRMED: Iceberg uses column-ID-based read path; new columns added after a file was written simply return NULL when old files are read (the column-ID is not present in the file, so the reader fills NULL)
- Queries that don't mention the column are unaffected — CORRECT: Iceberg metadata change only
- Backward-compatible — CORRECT: no migration required for consumers that add the column to their SELECT

- Accuracy 5.0 | Clarity 4.5 | Actionability 5.0 | Completeness 4.5
- **Q3 avg: 4.75**
- Fab status: ZERO fabrications.

### Q4 — Oracle MERGE upsert summary table → dbt/Trino (4.75 STRONG PASS)

**ALL CLAIMS CORRECT. Execute-guard regression NOT recurred.**

- Trino supports MERGE INTO — CORRECT for Iceberg connector (Trino 467 Iceberg connector supports row-level MERGE)
- `incremental_strategy='merge'` — CORRECT per dbt-trino docs + r27 §3.2
- `unique_key=['tenant_id','summary_date']` composite list — CORRECT (dbt-trino supports composite unique_key as a list)
- `format_version=2` in properties — CORRECT (Iceberg v2 enables row-level deletes and updates required for MERGE)
- `partitioned_by` key in dbt properties — CORRECT (snake_case key per dbt-trino docs; NOT `partitioning` which is raw Trino DDL surface)
- `{% if is_incremental() %}` delta guard — CORRECT; responder explicitly noted NOT `{% if execute %}`
- First run CTAS (full build), subsequent MERGE upsert idempotent — CORRECT

Execute-guard regression from iter489/490 (`{% if execute %}`) did NOT recur.

- Accuracy 5.0 | Clarity 4.5 | Actionability 5.0 | Completeness 4.5
- **Q4 avg: 4.75**
- Fab status: ZERO fabrications. Execute-guard regression HELD CLOSED.

---

## Overall score

| Q | Topic | Acc | Clarity | Action | Complete | Avg |
|---|---|---|---|---|---|---|
| Q1 | Timezone filter re-probe (zone-aware boundary literals) | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 |
| Q2 | YoY usage per customer (LAG offset 1 vs 12) | 1.5 | 3.5 | 2.0 | 2.5 | 2.375 |
| Q3 | Iceberg ADD COLUMN | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 |
| Q4 | Oracle MERGE upsert → dbt/Trino | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 |
| **Overall** | | **4.125** | **4.25** | **4.25** | **4.0** | **4.156** |

**PASS** (4.156 > 3.5, margin +0.656)

---

## Regression / fabrication inventory (iter492)

| # | Q | Class | Severity | Correct fact | Source |
|---|---|---|---|---|---|
| 1 | Q2 | SEMANTIC MISMATCH — `LAG(COUNT(*))` with default offset 1 returns PREVIOUS MONTH (MoM), NOT same month last year (YoY); labeled `usage_last_month` then used in `yoy_growth_pct` | LOAD-BEARING — computes wrong metric for stated requirement | For YoY: `LAG(metric, 12)` over gap-filled monthly series OR self-join on `month = month - INTERVAL '1' YEAR` | trino.io/docs/current/functions/window.html: "lag(x[, offset]) → Returns the value at offset rows before the current row. Default offset is 1." |
| 2 | Q2 | INTERNAL INCONSISTENCY — column named `usage_last_month` (MoM label) used in `yoy_growth_pct` (YoY label) | LOAD-BEARING — engineer cannot tell which metric they are actually computing | Pick one: MoM = LAG(1) + label `prev_month_usage`; YoY = LAG(12) or self-join + label `same_month_last_year` | — |
| 3 | Q2 | SILENT GAP CORRUPTION — LAG(offset 1) silently shifts when monthly rows are not contiguous per customer | NON-LOAD-BEARING as a separate issue but compounds the semantic error | Gap-fill required before LAG(N) for any fixed-offset comparison; OR use self-join which is gap-safe | trino.io/docs/current/functions/window.html |

Q1: ZERO fabrications — timezone fix CONFIRMED.
Q3: ZERO fabrications.
Q4: ZERO fabrications — execute-guard regression held closed.

---

## Fix status (iter491 primary action)

| Action | Status |
|---|---|
| Timezone filter canonical (§4.2B in r27): zone-aware boundary literals + CAST-AS-date + DO-NOT-WRITE for bare-string BETWEEN | CONFIRMED FIXED — Q1 responder produced correct forms verbatim. CLOSED. |
| Execute-guard regression (`{% if execute %}` vs `{% if is_incremental() %}`) | HELD CLOSED — Q4 correctly used `{% if is_incremental() %}` and explicitly warned against `{% if execute %}`. |

---

## Topic average updates (iter492)

| Topic | Before | After | Delta | Probed |
|---|---|---|---|---|
| Oracle PL/SQL→dbt/Trino migration | 4.4875/61 | **4.4958/63** | +0.0083 | Q1 (timezone re-probe, 4.75) + Q4 (MERGE upsert, 4.75) |
| Analytical query patterns on Iceberg+Trino | 4.5144/18 | **4.4018/19** | -0.1126 | Q2 (YoY window mismatch, 2.375) |
| Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling | 4.4985/164 | **4.4970/165** | -0.0015 | Q3 (ADD COLUMN, 4.75) |
| Trino federation / cross-source connectors | 4.49944/310 | **4.49944/310 UNCHANGED** | NOT PROBED | — |

---

## Teacher actions for iter493

### PRIMARY — Add YoY / period-over-period canonical to resources

No resource currently covers LAG(metric, 12) for same-month-last-year vs LAG(metric, 1) for previous-month. This is a complete resource gap. The responder defaulted to LAG(1) without any guidance on the correct offset for YoY, and no existing resource corrects this.

Add a **canonical YoY / period-over-period window function block** to the most appropriate resource (r07 analytical query patterns is the best fit, or r27 if a dbt-incremental YoY model is the use case). The block must cover:

1. **LAG offset mapping table** (the core missing fact):
   | Comparison type | LAG offset | Requirement |
   |---|---|---|
   | Previous row (day-over-day if rows are daily) | `LAG(metric, 1)` | Contiguous rows, no gaps |
   | Previous month (MoM — month-over-month) | `LAG(metric, 1)` over monthly partition | One row per month per partition key, no gaps |
   | Same month last year (YoY) | `LAG(metric, 12)` over monthly partition | 13+ months of contiguous monthly rows per partition key, no gaps |
   | Previous quarter (QoQ) | `LAG(metric, 4)` over quarterly partition | Contiguous quarterly rows, no gaps |

2. **Gap-fill requirement** — LAG(N) over a sparse series silently shifts. If customer A has data in Jan and Mar but not Feb, LAG(1) on the March row returns January — a 2-month lookback not a 1-month. Solutions:
   - Generate a complete date spine (all months in window) and LEFT JOIN actual data to it
   - Alternatively, use a self-join on the date math: `JOIN ... ON prev.month = date_add('month', -12, cur.month)` — self-join is gap-safe because an unmatched row simply produces NULL (not a shifted offset)

3. **The two canonical YoY forms** (both verified Trino 467):

   ```sql
   -- FORM A: LAG(12) over gap-filled series
   -- Requires generating a spine of all months then left-joining actual counts
   WITH monthly AS (
     SELECT customer_id,
            date_trunc('month', occurred_at) AS month,
            COUNT(*) AS usage_count
     FROM iceberg.analytics.events
     WHERE occurred_at >= date_add('month', -25, date_trunc('month', current_date))
     GROUP BY 1, 2
   )
   SELECT customer_id, month, usage_count,
     LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month)
       AS same_month_last_year,
     (usage_count - LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month))
       * 1.0 / NULLIF(LAG(usage_count, 12) OVER (PARTITION BY customer_id ORDER BY month), 0)
       * 100 AS yoy_growth_pct
   FROM monthly
   -- NOTE: this form only gives correct results if every (customer_id, month) pair
   -- is present in `monthly` for all 25 months. Missing months shift the offset.
   -- If gaps are expected, prefer FORM B (self-join) or add a gap-fill step.

   -- FORM B: self-join on date math (gap-safe, preferred)
   WITH monthly AS (
     SELECT customer_id,
            date_trunc('month', occurred_at) AS month,
            COUNT(*) AS usage_count
     FROM iceberg.analytics.events
     WHERE occurred_at >= date_add('month', -25, date_trunc('month', current_date))
     GROUP BY 1, 2
   )
   SELECT cur.customer_id,
          cur.month,
          cur.usage_count AS current_month,
          prev.usage_count AS same_month_last_year,
          (cur.usage_count - prev.usage_count) * 1.0
            / NULLIF(prev.usage_count, 0) * 100 AS yoy_growth_pct
   FROM monthly cur
   LEFT JOIN monthly prev
     ON prev.customer_id = cur.customer_id
    AND prev.month = date_add('month', -12, cur.month);
   ```

4. **DO-NOT-WRITE block**:
   ```sql
   -- WRONG for YoY — LAG(1) = previous month (MoM), NOT same-month-last-year
   LAG(usage_count) OVER (PARTITION BY customer_id ORDER BY month) AS usage_last_month
   -- Then labeling this as yoy_growth_pct is internally inconsistent.
   -- This computes month-over-month change, not year-over-year.
   ```

5. **Keyword anchors**: "year over year", "YoY", "same month last year", "year-over-year growth", "compare to last year", "monthly trend year ago", "period over period", "LAG window function", "LAG 12 months".

Place this block in r07 (analytical query patterns), adjacent to the existing LAG/LEAD section (currently around line 614-625). This is where a keyword-based search on "LAG" + "window function" + "year over year" will land.

### SECONDARY — breadth for iter493

- Federation 4.49944/310 row HELD per directive. DO NOT probe.
- Q2 YoY mismatch is the only new gap. The three clean topics (timezone, ADD COLUMN, MERGE dbt) need no additional probing this round.
- After installing the YoY resource, a single re-probe of the Q2 question angle (same-month-last-year in one row) will confirm it lands.
- Window function topic (Analytical query patterns) dropped from 4.5144/18 to 4.4018/19 from Q2 fail — one strong pass on a YoY question would recover to ~4.45.

### Schedule note

5-min cadence — `delaySeconds=300`.

---

## Streak / margin status

- **91st consecutive overall PASS in extended phase.**
- Margin at 4.156 — +0.656 above 3.5 floor. Q2 2.375 FAIL is the drag.
- **Timezone filter FIX CONFIRMED** — iter491 teacher §4.2B block in r27 LANDED. CLOSED.
- **Execute-guard regression HELD CLOSED** — Q4 used `{% if is_incremental() %}` correctly.
- **OPEN NEW ISSUE: YoY window function gap** — no resource covers LAG(N, 12) for same-month-last-year. Teacher must add canonical YoY block to r07 with LAG offset table + gap-fill warning + self-join form.
- Citation hygiene: Q1/Q3/Q4 ZERO fabrications. Q2 has 1 load-bearing semantic error + 1 internal inconsistency + 1 gap-corruption trap.
