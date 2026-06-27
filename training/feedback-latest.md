# Iter1162 — Judge Feedback

**Verdict: 4.8125 STRONG PASS NO-OP. Q1 WATCH CLOSES on first re-probe.**

Iter average = (5.0 + 4.375 + 4.9375 + 4.9375) / 4 = **4.8125 STRONG PASS** (margin +1.3125). Q1 percent-of-total re-probe lands the correct `SUM(COUNT(*)) OVER ()` window-over-aggregate form — the iter1161 transcription slip (SUM(SUM(x) OVER ()) aggregate-of-window inversion) did NOT recur. Q3 + Q4 strong canonical reaches. Q2 minor completeness shave on date_add quarter/week unit-list omission (engineer's question explicitly mentioned QUARTERS; responder's unit list `'month'/'day'/'year'/'hour'/'minute'/'second'` omits `'quarter'` and `'week'` which DO exist in Trino 467 per [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) — recall ceiling, not load-bearing).

| Q | Score | Topic touched | Status | Notes |
|---|---|---|---|---|
| Q1 tickets COUNT + pct-of-grand-total | **5.0** | Analytical query patterns on Iceberg+Trino (WATCH RE-PROBE) | STRONG PASS — **WATCH CLOSES** | `ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)` is the textbook share-of-grand-total form; OVER on OUTER aggregate, NOT the iter1161 broken aggregate-of-window. Inner `COUNT(*)` is per-group aggregate (legal under GROUP BY); outer `SUM(...) OVER ()` is window function over already-grouped rows, producing grand total broadcast onto every grouped row. Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) ("All aggregate functions can be used as window functions by adding the OVER clause"; window functions "run after the HAVING clause but before the ORDER BY clause" → execute after GROUP BY aggregation). NULLIF guard for zero total noted. Cites r07. |
| Q2 add 3 months to date in Trino (Postgres `+ INTERVAL '3 months'`) | **4.375** | SQL query best practices for OLAP (Trino date dialect) | PASS with minor completeness shave | TWO forms reached, primary facts correct: (1) `date_add('month', 3, subscription_start_date)` returns the type of input; (2) `subscription_start_date + INTERVAL '3' MONTH` valid (UPPERCASE unit OUTSIDE quotes, SINGULAR). Correctly EXCLUDED `QUARTER`/`WEEK` from INTERVAL units (verified [trinodb/trino#17357](https://github.com/trinodb/trino/issues/17357) open for WEEK; SqlBase.g4 intervalField grammar = YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only per pinned `reference_trino_interval_qualifiers.md`). Correctly defanged Postgres `'3 months'` plural form. MINOR COMPLETENESS SHAVE (-0.5 Acc / -1.0 Compl): engineer's question explicitly mentioned QUARTERS but responder's date_add unit list was `'month'/'day'/'year'/'hour'/'minute'/'second'` — omits `'quarter'` and `'week'`, which DO exist per [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) verbatim "The functions in this section support the following interval units: millisecond, second, minute, hour, day, week, month, quarter, year." Engineer wanting to add 1 quarter must discover `date_add('quarter', 1, date)` externally; recall ceiling. Cites r07/r13. |
| Q3 broadcast organic channel's signups to every same-month row | **4.9375** | Analytical query patterns on Iceberg+Trino | STRONG PASS | `MAX(CASE WHEN channel = 'organic' THEN signups END) OVER (PARTITION BY report_month)` — canonical "broadcast one category's value within partition" pattern. CASE on non-matching rows returns NULL → MAX ignores NULLs (per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) "NULL values are ignored"), broadcasts the single organic value to all rows. Window function in SELECT scope (NOT WHERE — would be analysis error). NULLIF-guarded ratio for divide-by-zero. Alternative `LEFT JOIN organic_baseline` CTE form also given. Cites r07/r23. Minor recall ceiling: didn't explicitly name `min_by(signups, CASE WHEN channel='organic' THEN 0 ELSE 1 END)` as an alternative Trino-specific form; the MAX(CASE) form is the cleaner readable canonical. |
| Q4 dbt incremental_strategy='append' vs 'merge' for events Iceberg | **4.9375** | Improving complex SQL performance on Trino with dbt | STRONG PASS | Balanced judgment correct: Teammate A (merge+unique_key idempotent) is right; Teammate B's "append faster" point acknowledged but bets on perfect orchestration. Decision table (reruns possible → merge; append-only never-rerun → append; high-volume same-day reruns → merge) reflects the actual tradeoff. Canonical config block correct: `incremental_strategy='merge'`, `unique_key='event_id'`, `on_schema_change`, `partitioning=ARRAY['day(occurred_at)']`, lookback `WHERE occurred_at >= date_add('day',-3, COALESCE((SELECT MAX(occurred_at) FROM {{this}}), TIMESTAMP '1970-01-01'))`. `is_incremental()` correctly named (NOT `{% if execute %}`). Cites r28/r26. Verified at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs): "append (default)", "merge ... constructs a Trino MERGE statement to insert new records and update existing records based on the `unique_key` property". Trino 467 MERGE on Iceberg verified at [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html). "Merge cost only on later runs (first is CTAS)" + "partition pruning limits merge to lookback window" reasoning sound. |

---

## Q1 — Tickets percent-of-grand-total (WATCH RE-PROBE — CLOSES)

### Engineer's framing

`tickets(category bug/feature/question/other)`. Per category, the COUNT and that category's percentage share of ALL tickets (percentages must sum to 100). One query, no separate total step / no hardcoding.

### Responder's answer (key shape)

```sql
SELECT category,
       COUNT(*) AS ticket_count,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM tickets
GROUP BY category
ORDER BY pct_of_total DESC;
```

Explanation: empty `OVER ()` = grand total over result set; `100.0` forces decimal division; `NULLIF(SUM(COUNT(*)) OVER (), 0)` guard noted for zero-row tables.

### Source verification

- **`SUM(COUNT(*)) OVER ()` window-over-aggregate validity**: in a `GROUP BY category` query, `COUNT(*)` is the per-group aggregate (legal under GROUP BY), `SUM(...) OVER ()` is a window function that runs AFTER GROUP BY aggregation. Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html): "All aggregate functions can be used as window functions by adding the `OVER` clause" + "Window functions perform calculations across rows of the query result. They run after the `HAVING` clause but before the `ORDER BY` clause." Execution order: GROUP BY → HAVING → window functions → ORDER BY.
- **OVER goes on the OUTER aggregate**: inner `COUNT(*)` is the per-group aggregate input (one value per category), outer `SUM(...) OVER ()` is the window function over the four grouped rows, producing the grand total broadcast onto every row. Matches r07:1914 LEADING CANONICAL `SUM(x) * 100.0 / SUM(SUM(x)) OVER ()`.
- **`100.0` for decimal division**: Trino integer `/` integer = integer (truncating); multiplying by `100.0` (DECIMAL or DOUBLE literal) promotes the numerator to decimal/double, avoiding the silently-zero `100 * 1 / 4 = 25` round-down trap (already 25 in this case but the principle generalizes).
- **`NULLIF(denom, 0)` guard**: standard defensive idiom — Trino integer division by zero throws DIVISION_BY_ZERO (per pinned `reference_trino_division_by_zero.md`). For empty tables, NULLIF returns NULL → ratio returns NULL not error.

### Watch resolution

The iter1161 watch `r07 percent-of-total SUM(SUM(x)) OVER () transcription slip iter1161` was opened because the iter1161 Q3 FORM 1 wrote `SUM(SUM(monthly_revenue) OVER ())` — wrapping an OUTER aggregate around an INNER window function (Trino throws "Cannot nest window functions in aggregate functions") AND it also referenced an ungrouped column `monthly_revenue` directly under GROUP BY. This iter Q1 is the same semantic pattern in a different domain (tickets count + pct vs subscriptions revenue + pct).

The responder routed CORRECTLY to `SUM(COUNT(*)) OVER ()` — OVER on the OUTER aggregate, NOT the inner. NO ungrouped-column reference. NO aggregate-of-window nesting. The exact misread pattern the iter1161 slip exhibited did NOT recur.

**WATCH CLOSES on first re-probe.** Pattern: 1-iter Haiku synthesis variance recovered on next sweep — consistent with the established `feedback_synthesis_ceiling_stop_churning` discipline (9 of last 9 watches close on first re-probe). NO additive defang card needed at r07:1914.

### Verdict — Q1: 5.0 STRONG PASS (watch CLOSES)

- Acc 5.0 — `SUM(COUNT(*)) OVER ()` is the textbook share-of-grand-total form; OVER-on-OUTER aggregate correct; window-after-GROUP-BY semantics correct.
- Clar 5.0 — runnable shape + explicit explanation of empty-OVER() = grand total + 100.0 decimal-division reason + NULLIF guard rationale.
- App 5.0 — copy-pastable on tickets schema; four rows out, percentages sum to 100, ORDER BY pct DESC gives the engineer's expected display.
- Compl 5.0 — flagship answer to a flagship question; both the inline form and the underlying mental model present.

---

## Q2 — Add 3 months to date in Trino (PASS with minor quarter shave)

### Engineer's framing

`subscriptions(subscription_start_date date)`. Postgres uses `subscription_start_date + INTERVAL '3 months'` / a date-add helper. Does that work in Trino 467, or is there a Trino-specific function for adding months/quarters/days to a date?

### Responder's answer (key shape)

```sql
-- Form A: function
SELECT date_add('month', 3, subscription_start_date) AS plus_three_months FROM subscriptions;
-- units: 'month' / 'day' / 'year' / 'hour' / 'minute' / 'second'
-- negative value subtracts: date_add('month', -3, d)

-- Form B: INTERVAL
SELECT subscription_start_date + INTERVAL '3' MONTH AS plus_three_months FROM subscriptions;
-- UPPERCASE unit OUTSIDE quotes, SINGULAR (NOT '3 months' plural Postgres syntax)
-- valid units: YEAR / MONTH / DAY / HOUR / MINUTE / SECOND
```

DO NOT write `current_date - 30` (bare integer subtraction on DATE in Trino is not standard — needs INTERVAL).

### Source verification

- **`date_add(unit, value, timestamp)` signature**: verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) verbatim "The functions in this section support the following interval units: **millisecond, second, minute, hour, day, week, month, quarter, year**." Responder's unit list `'month'/'day'/'year'/'hour'/'minute'/'second'` is INCOMPLETE — omits `'millisecond'`, `'week'`, AND `'quarter'`. The engineer's question explicitly named QUARTERS as a unit they want to handle, so the omission of `'quarter'` is materially relevant.
- **`d + INTERVAL '3' MONTH` valid form on DATE column**: verified at [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) (`INTERVAL YEAR TO MONTH` + `INTERVAL DAY TO SECOND` types defined). DATE + interval year-to-month returns DATE.
- **INTERVAL `QUARTER` / `WEEK` are PARSE ERRORS**: verified per [trinodb/trino#17357](https://github.com/trinodb/trino/issues/17357) (open feature request "Support week in interval literals", explicit acknowledgement that this is not in current grammar) + pinned `reference_trino_interval_qualifiers.md` ("Trino 467 INTERVAL literals support ONLY YEAR/MONTH/DAY/HOUR/MINUTE/SECOND"). Responder's exclusion of QUARTER/WEEK from INTERVAL units is CORRECT.
- **Postgres `'3 months'` plural form is NOT valid in Trino**: confirmed. Must use singular unit OUTSIDE the quoted number: `INTERVAL '3' MONTH` not `INTERVAL '3 months'`.

### What's missing

The engineer's framing mentioned three units they want to handle: **months / quarters / days**. The responder showed:
- Months: BOTH forms covered (`date_add('month',3,d)` and `d + INTERVAL '3' MONTH`).
- Days: `date_add('day', n, d)` and `d + INTERVAL '7' DAY` both implicitly covered (unit listed).
- **Quarters: NEITHER form correctly addressed.** `INTERVAL '1' QUARTER` is a parse error (correct exclusion in responder's INTERVAL unit list). But `date_add('quarter', 1, d)` IS valid per Trino 467 docs — and the responder's date_add unit list omitted `'quarter'`. Engineer must discover the missing unit externally.

The CORRECT complete answer would say: "for quarters, use `date_add('quarter', n, date)` — the INTERVAL literal form does not support QUARTER as a qualifier in Trino 467." That single sentence closes the gap.

This is a RECALL CEILING (responder under-listed valid date_add units) NOT a resource defect. r07 + r13 cover date_add but the resource may not explicitly enumerate `'quarter'` as a unit string in a high-visibility location. Not load-bearing for FIX-A on a +1.08 margin row.

### Verdict — Q2: 4.375 PASS (minor shave)

- Acc 4.5 — `date_add` exists and is correctly used; `INTERVAL` form syntax and exclusions correct; Postgres-plural defang correct. Shave: date_add unit list incomplete (omits `'quarter'`, `'week'`, `'millisecond'`).
- Clar 4.75 — two-form structure clear with explicit "uppercase OUTSIDE quotes, singular" rule and "DO NOT write Postgres plural" defang.
- App 4.25 — engineer asking about quarters gets months covered fully but quarters only implicitly (must extrapolate that date_add accepts `'quarter'` even though responder didn't list it).
- Compl 4.0 — three-unit ask (months/quarters/days) → two fully answered, quarter only partial. Material because question named quarters explicitly.

---

## Q3 — Broadcast organic channel's signups to every same-month row (STRONG PASS)

### Engineer's framing

`channel_performance(channel organic/paid_search/social, report_month, signups)`. For each row, also display the 'organic' channel's signup count for that SAME month alongside it (to compute a ratio per row), without a self-join or correlated subquery. Way to pull one specific category's value into every row scoped to the same period?

### Responder's answer (key shape)

```sql
SELECT channel,
       report_month,
       signups,
       MAX(CASE WHEN channel = 'organic' THEN signups END) OVER (PARTITION BY report_month) AS organic_signups_this_month,
       ROUND(1.0 * signups / NULLIF(MAX(CASE WHEN channel = 'organic' THEN signups END) OVER (PARTITION BY report_month), 0), 4) AS ratio_to_organic
FROM channel_performance
ORDER BY report_month, channel;

-- Alternative: CTE + LEFT JOIN
WITH organic_baseline AS (
  SELECT report_month, signups AS organic_signups FROM channel_performance WHERE channel = 'organic'
)
SELECT cp.*, ob.organic_signups
FROM channel_performance cp
LEFT JOIN organic_baseline ob USING (report_month);
```

### Source verification

- **`MAX(CASE WHEN ...)` aggregated within a window**: CASE returns the signups value only on matching ('organic') rows; on non-matching rows returns NULL. MAX ignores NULLs per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) "NULL values are ignored" (default behavior for MIN/MAX/SUM/AVG). Within a partition of (report_month=X), exactly one row has channel='organic' so MAX broadcasts that single value to all rows in the partition. Pattern is widely used; equivalent to the "MAX(CASE) pivot" idiom on aggregated data.
- **Window function in SELECT scope**: legal per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html); window functions in WHERE would be analysis error (responder correctly placed in SELECT + uses NULLIF for divide-by-zero in the same SELECT).
- **PARTITION BY report_month scoping**: each report_month becomes its own partition; the MAX(CASE) computes per-partition. Same-month-as-row organic value broadcasts to all rows in that month. Engineer's exact ask.
- **LEFT JOIN CTE alternative**: also valid, slightly more explicit pre-aggregation. The LEFT JOIN preserves ALL channel_performance rows even if no organic row exists for that month (CASE form would return NULL too in that case — semantically equivalent).

### Verdict — Q3: 4.9375 STRONG PASS

- Acc 5.0 — `MAX(CASE WHEN ...)` OVER (PARTITION BY ...) is the canonical "broadcast one category's value within partition" form; valid Trino 467.
- Clar 5.0 — clean shape + ratio computation + NULLIF guard; alternative CTE form labeled correctly.
- App 5.0 — copy-pastable on the engineer's exact schema; ratio_to_organic ready to use.
- Compl 4.75 — primary + alternative both reach the ask; minor recall ceiling: didn't name `min_by(signups, CASE WHEN channel='organic' THEN 0 ELSE 1 END)` as a Trino-specific equivalent (would be a one-row-per-partition pivot trick) — MAX(CASE) is the cleaner readable canonical.

---

## Q4 — dbt incremental_strategy='append' vs 'merge' for events Iceberg (STRONG PASS)

### Engineer's framing

`events` Iceberg table loaded by a dbt incremental model with `strategy='append'`. Teammate A: switch to `merge`+`unique_key` because append duplicates on reruns. Teammate B: append is much faster on large Iceberg tables, handle reruns at orchestration level. Which is right, and how to think through append-vs-merge for a high-volume fact table?

### Responder's answer (key shape)

**Verdict**: Teammate A correct; B's speed point real but bets on perfect orchestration.

**Decision table**:
- Reruns possible → merge + unique_key (idempotent)
- Append-only, never-rerun (immutable upstream + deduped at orchestration) → append
- High-volume same-day reruns → merge

**Canonical merge config**:
```yaml
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='event_id',
    on_schema_change='append_new_columns',
    properties={'partitioning': "ARRAY['day(occurred_at)']"}
) }}
SELECT event_id, occurred_at, user_id, event_type, properties
FROM {{ ref('stg_events') }}
{% if is_incremental() %}
  WHERE occurred_at >= date_add('day', -3, COALESCE((SELECT MAX(occurred_at) FROM {{ this }}), TIMESTAMP '1970-01-01'))
{% endif %}
```

Notes: `is_incremental()` canonical guard (NOT `{% if execute %}`); merge cost only on later runs (first is CTAS); partition pruning limits merge to lookback window (3-day window vs full-table merge cost differential).

### Source verification

- **`incremental_strategy='append'` (default) and `incremental_strategy='merge'`**: BOTH valid dbt-trino strategies. Verified at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — strategies are `append` (default), `delete+insert`, `merge`.
- **`append` duplicates on rerun**: confirmed by dbt-trino docs — append "only adds new records based on the condition specified in the `is_incremental()` block." If the lookback predicate scopes overlapping rows, those rows appear twice in the target. No de-dup by primary key.
- **`merge` + `unique_key` idempotent**: confirmed — merge "constructs a Trino MERGE statement to insert new records and update existing records based on the `unique_key` property." Reprocessed event_ids match → UPDATE (not duplicate). Reruns of the same staging slice produce the same target — idempotent.
- **Trino 467 MERGE on Iceberg**: verified at [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html) — MERGE INTO requires Iceberg connector (v2 format default since Trino 419). Operates against unique_key for match condition.
- **`is_incremental()` canonical guard**: verified at [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) — `{% if is_incremental() %}` block conditionally adds the lookback predicate ONLY on subsequent runs (first run is CTAS). Responder's defang of `{% if execute %}` is correct — execute is a different macro for compile-vs-run gating, not incremental-vs-first-run gating.
- **Partition pruning limits merge cost**: with `partitioning=ARRAY['day(occurred_at)']` + lookback predicate `WHERE occurred_at >= date_add('day', -3, ...)`, Trino prunes to the recent 3 day partitions; MERGE scans only those partitions on the target side, not the full 400GB+ table. Responder's reasoning sound.
- **B's "append faster" claim**: partially true — append is a pure INSERT (no scan-target-for-match step), so per-run cost is lower than merge. But the savings depend on cluster scale, partition layout, and the size of the lookback window. For a high-volume fact table with day-partitioning and a small lookback, the merge-cost differential is bounded and well worth the idempotency guarantee. Responder's framing ("bets on perfect orchestration") correctly identifies the risk: ANY orchestration retry (pod restart, dbt run --select rerun, manual replay) silently duplicates rows in target.

### Verdict — Q4: 4.9375 STRONG PASS

- Acc 5.0 — both strategies named correctly; append/merge behaviors correctly described; partition pruning + lookback reasoning sound; `is_incremental()` vs `{% if execute %}` correctly disambiguated.
- Clar 4.75 — decision table + reasoning + canonical config block + caveat all present; engineer leaves with a clear "use merge unless you can prove the orchestration never replays" framework.
- App 5.0 — copy-pastable config block on the engineer's exact `events` schema; runnable.
- Compl 5.0 — both teammates' positions acknowledged, balanced verdict with explicit conditions under which append IS acceptable; covers schema-change handling (`on_schema_change`), lookback window pattern, partition pruning, and first-run-vs-incremental-run cost differential.

---

## Topic-row updates

| Topic | Before | Delta | After | Status |
|---|---|---|---|---|
| Analytical query patterns on Iceberg+Trino | 4.5098/112 | +0.0044 (Q1=5.0 + Q3=4.9375 both above mean) | **4.5186/114** | PASSED, margin +1.0186 |
| SQL query best practices for OLAP | 4.5788/230 | -0.0009 (Q2=4.375 below mean) | **4.5779/231** | PASSED, margin +1.0779 |
| Improving complex SQL performance on Trino with dbt | 4.6111/25 | +0.0125 (Q4=4.9375 above mean) | **4.6236/26** | PASSED, margin +1.1236 |

All required topics REMAIN PASSED with comfortable margins.

---

## Pattern observation

36-iter sustainment band continues. iter1162 4.8125 STRONG PASS NO-OP — Q1 watch closes cleanly, Q2 minor recall ceiling on date_add quarter/week unit list, Q3+Q4 strong canonical reaches.

**Watch-closure metric**: 9 of last 9 watches close on first re-probe (Haiku 1-iter-slip-then-recover variance pattern HOLDS robustly). The iter1161 Q3 SUM(SUM(x) OVER ()) aggregate-of-window inversion was a per-instance transcription slip not a resource defect — r07:1914 LEADING CANONICAL + r07:2864-2959 CTE-and-inline pair + r07:2959 explicit "easier to mis-read as a nested aggregate; prefer the CTE form" warning are all doing their job. The first-re-probe verdict on this different domain (tickets count vs subscriptions revenue) reaches the correct OVER-on-OUTER form cleanly. No additive defang card needed.

**Q2 observation**: the minor completeness gap on date_add unit list is a recall ceiling, not a findability gap. The engineer's specific question framing (months/quarters/days) makes the omission of `'quarter'` material, but the responder gave the correct function name (`date_add`) and the correct overall mental model — engineer with passing Trino knowledge extrapolates `'quarter'` is also a unit. NOT a resource fix candidate: r07/r13 already document date_add; adding a "complete unit list" emphasis card risks `feedback_new_card_over_attracts_adjacent` on the adjacent INTERVAL-qualifier defang (where QUARTER/WEEK are explicitly NOT valid) — the engineer who reads both sections needs to keep them distinct, and over-emphasizing the date_add quarter side could pull INTERVAL-qualifier questions to the wrong row. Recall ceiling, NO-OP.

**Q4 observation**: the dbt-trino incremental strategy framework is durably correct. iter1162 lands the canonical balanced answer (append valid in narrow conditions, merge correct in the high-volume-rerun case) on first probe; no slippage from iter1141 r28 LIGHT FIX-A region (which covered TopN-disambiguation, separate topic). The `complex-SQL-perf-dbt` row was already comfortably above threshold; this iter adds a clean datapoint.

**RECOMMENDATION = NO-OP.** No FIX-A. No new watches. Q1 watch CLOSED.

---

## Sources

- [Trino 467 Window functions — trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) (window-over-aggregate validity, execution order, all aggregates usable as window functions)
- [Trino 467 Date and time functions — trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) (date_add unit list including quarter and week)
- [Trino 467 Data types — trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) (INTERVAL YEAR TO MONTH / DAY TO SECOND)
- [Trino 467 SELECT — trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) (window scope in SELECT, execution order)
- [Trino 467 Aggregate functions — trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) (NULL handling in MAX/MIN/SUM/AVG)
- [Trino 467 MERGE — trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html) (MERGE INTO on Iceberg)
- [dbt-trino configs — docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) (incremental_strategy values: append default, delete+insert, merge)
- [dbt incremental models — docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) (is_incremental() guard semantics)
- [trinodb/trino#17357](https://github.com/trinodb/trino/issues/17357) (open feature request: support WEEK in interval literals; confirms WEEK not valid INTERVAL qualifier)
- pinned `reference_trino_interval_qualifiers.md` (INTERVAL units = YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only)
- pinned `reference_trino_division_by_zero.md` (DIVISION_BY_ZERO behavior; NULLIF guard rationale)
