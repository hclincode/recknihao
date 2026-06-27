# Iter1161 — Judge Feedback

**Verdict: 4.50 PASS NO-OP. Q3 broken-primary drag absorbed by cushion; Q1 watch CLOSES.**

Iter average = (4.875 + 4.875 + 3.3125 + 4.9375) / 4 = **4.50 PASS** (margin +1.00). Q1 routes correctly to dbt incremental `merge`+`unique_key` — the watch `r27 IF-EXISTS-staging-guard → dbt interpretation slip iter1160` **CLOSES on first re-probe**. Q2 (date_trunc week) + Q4 (Puffin/ANALYZE) source-verified canonical reaches. Q3 lists a BROKEN FORM 1 FIRST (aggregate-of-window + reference to ungrouped column under GROUP BY) but the CTE FORM 2 listed second IS correct; classified as Haiku responder slip per the pinned `feedback_responder_broken_secondary_alternative` family (resource at r07:1914 + r07:2864-2959 is correct, including an explicit warning that the inline form is "denser and easier to mis-read as a nested aggregate; prefer the CTE form") — **NO RESOURCE FIX**.

| Q | Score | Topic touched | Status | Notes |
|---|---|---|---|---|
| Q1 Idempotent staging→fct_orders, skip if order_id already in target | **4.875** | Oracle PL/SQL → dbt+Trino (WATCH RE-PROBE) | STRONG PASS — **WATCH CLOSES** | dbt incremental `merge` + `unique_key='order_id'` correctly named; explains dbt-trino compilation to Trino `MERGE INTO fct_orders USING (...) ON order_id WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT`; reprocessed order_ids update not duplicate; `is_incremental()` `WHERE order_date >= (SELECT COALESCE(MAX(order_date), DATE '1970-01-01') FROM {{ this }})` is a standard perf-scoping filter that's compatible with merge (no idempotency edge case — merge still de-dupes by `unique_key` within the scoped staging rows). Cites r27 §3.2-3.3 (matches r27 §228, §271-273, §321, §330-331 canonical). Did NOT misroute to validate-against-known-list this time. |
| Q2 date_trunc('week') for "same calendar week as today" filter | **4.875** | SQL query best practices for OLAP (Trino date dialect) | STRONG PASS | `date_trunc('week', signup_at)` snaps to ISO-8601 Monday-start (verified [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)); `WHERE date_trunc('week', signup_at) = date_trunc('week', current_timestamp)` correctly finds same-week rows; `day_of_week(ts)` returns 1(Mon)-7(Sun) verified at same URL. Correctly noted no Sunday-start option for date_trunc. |
| Q3 Per-plan AVG + share-of-grand-total in one query | **3.3125** | Analytical query patterns on Iceberg+Trino | BROKEN-PRIMARY + CORRECT-ALTERNATIVE (PASS by cushion) | FORM 1 (listed FIRST) `ROUND(100.0 * SUM(monthly_revenue) OVER () / SUM(SUM(monthly_revenue) OVER ()), 2)` is INVALID Trino SQL on two grounds (see Q3 section). FORM 2 (CTE, listed second as "cleaner alternative") IS correct and matches the r07:1914 canonical `SUM(x) * 100.0 / SUM(SUM(x)) OVER ()` (OVER on the OUTER SUM). Resource is correct + explicitly warns at r07:2959 about the inline form being "easier to mis-read as a nested aggregate." Responder synthesis slip, NO resource fix. |
| Q4 Iceberg per-table stats: Puffin file, ANALYZE, SHOW STATS, stale | **4.9375** | Trino CBO / ANALYZE / Puffin statistics | STRONG PASS | Puffin file mechanism CORRECT (Iceberg spec sidecar for NDV/sketches); SHOW STATS FOR returns `distinct_values_count`/`nulls_fraction`/`row_count` verified at [trino.io/docs/current/optimizer/statistics.html](https://trino.io/docs/current/optimizer/statistics.html); NULL distinct_values_count = uncollected CORRECT; `ANALYZE iceberg.analytics.events WITH (columns = ARRAY['user_id','tenant_id','event_type'])` syntax verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html); stats NOT auto-refreshed (manual ANALYZE re-run) verified at same URL; CBO uses NDV for join order + broadcast/shuffle CORRECT per r24. |

---

## Q1 — Idempotent staging reload (WATCH RE-PROBE — CLOSES)

### Engineer's framing

Nightly ETL: `staging_orders` → `fct_orders` via append; re-processing the same staging rows duplicates `order_id` in `fct_orders`. Want: insert a staging row ONLY if its `order_id` is NOT already in `fct_orders`, so reruns are safe / idempotent. dbt against Trino — how?

### Responder's answer (key shape)

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='order_id'
) }}
SELECT order_id, customer_id, order_date, total_amount, status
FROM {{ ref('staging_orders') }}
{% if is_incremental() %}
  WHERE order_date >= (
    SELECT COALESCE(MAX(order_date), DATE '1970-01-01')
    FROM {{ this }}
  )
{% endif %}
```

Explains dbt-trino emits `MERGE INTO fct_orders USING (select) ON order_id WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT`. Reprocessed order_ids → matched → updated (not duplicated). Reruns idempotent. Cites r27 §3.2-3.3.

### Source verification

- **dbt incremental + `incremental_strategy='merge'` + `unique_key='<pk>'`** — verified at r27 §228 (flagship translation table: "MERGE INTO target USING source ON ... WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT → dbt incremental `merge` with `unique_key`"), r27 §271-273 (worked example with `fct_orders` + `unique_key='order_id'` IDENTICAL to the engineer's schema), r27 §321 ("THE DEFAULT TARGET FOR ORACLE MERGE PROCEDURES"), r27 §330-331 (config block template).
- **dbt-trino compiles incremental merge into Trino `MERGE INTO`** — verified at r27 §228 + §1981 + §2059 (multiple worked examples). Trino 467 supports `MERGE INTO` per [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html) on Iceberg.
- **`is_incremental()` lookback filter compatibility with merge** — the `WHERE order_date >= MAX(order_date) - …` scoping filter limits which staging rows are merged. This is a standard dbt performance optimization (avoid full-staging-scan on incremental runs). Merge still de-duplicates by `unique_key='order_id'` WITHIN the scoped rows — idempotency holds. No edge case for the stated problem (re-running same-day staging is the canonical use case).

### Watch resolution

The watch `r27 IF-EXISTS-staging-guard → dbt interpretation slip iter1160` was opened because iter1160 Q4 (Oracle `IF EXISTS staging` → INSERT proc) misread "insert-if-not-already-present" as "validate-against-known-list" and emitted three forms against a non-existent `known_valid_orders` table. This iter Q1 is the same semantic pattern in a different phrasing (no Oracle wrapping, direct dbt-against-Trino framing). The responder routed CORRECTLY to incremental `merge`+`unique_key` — the flagship r27 §228 canonical — and explained the MERGE-INTO compilation accurately.

**WATCH CLOSES.** Pattern: 1-iter slip recovered on first re-probe — classic Haiku per-instance variance per the pinned `feedback_synthesis_ceiling_stop_churning` family. No additive r27 routing card needed.

### Verdict — Q1: 4.875 STRONG PASS (watch CLOSES)

- Acc 5.0 — incremental `merge` + `unique_key='order_id'` is the textbook dbt-trino idempotent pattern; explanation of MERGE-INTO compilation correct.
- Clar 4.75 — clean config block, runnable, mental model ("matched=update, not-matched=insert") clear.
- App 5.0 — copy-pasteable on the engineer's exact `staging_orders`/`fct_orders` schema.
- Compl 4.75 — flagship answer; minor recall shave for not also naming NOT EXISTS anti-join (`INSERT INTO fct_orders SELECT … FROM staging WHERE NOT EXISTS (SELECT 1 FROM fct_orders t WHERE t.order_id = s.order_id)`) as the alternative non-MERGE form per r27 §2292. Not load-bearing — flagship is the better answer.

---

## Q2 — date_trunc('week') current-week filter (STRONG PASS)

### Engineer's framing

`customers(signup_at timestamp)`. Find customers who signed up in the SAME calendar week as today (Mon-Sun, the current week — not last 7 days). Trino function to snap a timestamp to start of its week so two timestamps' weeks compare directly?

### Responder's answer (key shape)

```sql
SELECT customer_id, signup_at
FROM customers
WHERE date_trunc('week', signup_at) = date_trunc('week', current_timestamp);
```

Notes: `date_trunc('week', ts)` snaps to Monday (ISO-8601 week-start, Trino default); no Sunday-start option. `day_of_week(ts)` returns 1=Mon to 7=Sun. Cites r07.

### Source verification

- **`date_trunc('week', ts)` returns Monday-anchored week start (ISO-8601)** — verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): the `'week'` unit truncates to ISO week start (Monday). Documentation example `2001-08-22 → 2001-08-20 00:00:00.000` (2001-08-20 was a Monday) confirms.
- **`day_of_week(timestamp)` returns 1 (Monday) through 7 (Sunday)** — verified at trino.io/docs/current/functions/datetime.html: "The value ranges from `1` (Monday) to `7` (Sunday)." `extract(DOW FROM ts)` is documented alias.
- **Same-week-as-today predicate** — `WHERE date_trunc('week', signup_at) = date_trunc('week', current_timestamp)` is the canonical equality filter; both sides snap to the same Monday → equal. Catches all Mon-Sun signups in the current ISO week. Does NOT do rolling-7-day (which would be `signup_at >= current_timestamp - INTERVAL '7' DAY`).

### Verdict — Q2: 4.875 STRONG PASS

- Acc 5.0 — correct ISO-8601 Monday-start truncation; correct day_of_week numbering; correct same-week predicate.
- Clar 4.75 — clear distinction "current ISO week, not last 7 days" matches the engineer's exact framing.
- App 5.0 — copy-pasteable on the customers schema.
- Compl 4.75 — answers the function-snapping question; could have briefly shown how to get "this Monday's date" explicitly (`CAST(date_trunc('week', current_timestamp) AS date)`) for downstream display, but not asked.

---

## Q3 — Per-plan AVG + share-of-grand-total (BROKEN PRIMARY + CORRECT ALTERNATIVE)

### Engineer's framing

`subscriptions(account_id, plan_type starter/pro/enterprise, monthly_revenue)`. Three plan rows, each with its own AVG revenue + that plan's % share of total revenue across all plans. Both numbers in ONE query, NO separate subqueries joined back.

### Responder's answer (key shape)

```sql
-- FORM 1 (listed FIRST — described as the primary inline form)
SELECT plan_type,
       ROUND(AVG(monthly_revenue), 2) AS avg_revenue,
       ROUND(100.0 * SUM(monthly_revenue) OVER () /
                     SUM(SUM(monthly_revenue) OVER ()), 2) AS pct_of_total_revenue
FROM subscriptions
GROUP BY plan_type
ORDER BY pct_of_total_revenue DESC;

-- FORM 2 (CTE — described as "cleaner alternative")
WITH aggregated AS (
  SELECT plan_type,
         AVG(monthly_revenue) AS avg_revenue,
         SUM(monthly_revenue) AS plan_total
  FROM subscriptions
  GROUP BY plan_type
)
SELECT plan_type,
       ROUND(avg_revenue, 2),
       ROUND(100.0 * plan_total / SUM(plan_total) OVER (), 2) AS pct_of_total_revenue
FROM aggregated;
```

Explanation: "`SUM(x) OVER ()` empty-frame = grand total of x repeated on every row."

### What's WRONG — FORM 1 is invalid Trino SQL on TWO independent grounds

**(a) Ungrouped-column reference inside the window function under GROUP BY.**

In a `GROUP BY plan_type` query, window functions are evaluated AFTER GROUP BY. The columns available to a window-function expression are: (1) GROUP BY columns (`plan_type`), and (2) aggregates of any column. A bare reference to `monthly_revenue` is NOT available at the post-GROUP-BY stage — that column was either grouped away or only valid as input to aggregates. The numerator `SUM(monthly_revenue) OVER ()` is a window function with a bare `monthly_revenue` argument under GROUP BY plan_type → Trino throws:

> `line N:M: 'monthly_revenue' must be an aggregate expression or appear in GROUP BY clause`

**(b) Aggregate-of-window in the denominator.**

The denominator `SUM(SUM(monthly_revenue) OVER ())` wraps an OUTER aggregate `SUM(...)` around an INNER window function `SUM(...) OVER ()`. Trino rejects this nesting class:

> `Cannot nest window functions in aggregate functions`

Either failure mode alone makes FORM 1 non-runnable. Both apply.

### The correct inline form (per r07:1914 LEADING CANONICAL)

```sql
SELECT plan_type,
       ROUND(AVG(monthly_revenue), 2)                                  AS avg_revenue,
       ROUND(SUM(monthly_revenue) * 100.0 /
             SUM(SUM(monthly_revenue)) OVER (), 2)                     AS pct_of_total_revenue
FROM subscriptions
GROUP BY plan_type;
```

Key idiom: **`SUM(SUM(x)) OVER ()`** — the OVER goes on the OUTER SUM, not on the inner. Inner `SUM(monthly_revenue)` is the per-group aggregate (legal in a GROUP BY query). Outer `SUM(...) OVER ()` is a window function over the already-grouped rows, producing the grand total. r07:1914 frames it verbatim: `SUM(x) * 100.0 / SUM(SUM(x)) OVER ()`. r07:2856-2959 explains the same window-over-aggregate pattern with a SECTION-LEVEL WARNING at r07:2959: "the inline `SUM(SUM(amount)) OVER (...)` form is **valid Trino 467** but is denser and easier to mis-read as a nested aggregate; prefer the CTE form unless you're golfing for query length."

The responder's FORM 1 is exactly the mis-read pattern the resource warns against — OVER() got moved from the OUTER to the INNER on both numerator and denominator, producing the doubly-invalid nesting.

### FORM 2 (CTE) IS correct

```sql
WITH aggregated AS (
  SELECT plan_type, AVG(monthly_revenue) AS avg_revenue, SUM(monthly_revenue) AS plan_total
  FROM subscriptions GROUP BY plan_type
)
SELECT plan_type, ROUND(avg_revenue, 2),
       ROUND(100.0 * plan_total / SUM(plan_total) OVER (), 2) AS pct_of_total_revenue
FROM aggregated;
```

The CTE materializes the per-plan aggregates as plain columns; the outer query's `SUM(plan_total) OVER ()` is a window function over an already-non-aggregated row set → fully valid. Three rows out (one per plan), each with its own `avg_revenue` + correct percent-of-grand-total. Matches r07:2864 PREFERRED CANONICAL CTE form.

### Resource check (Is r07 wrong, or responder slip?)

- **r07:1914** — `SUM(x) * 100.0 / SUM(SUM(x)) OVER ()` — CORRECT.
- **r07:2864-2937** — PREFERRED CANONICAL CTE form — CORRECT.
- **r07:2938-2959** — INLINE ALTERNATIVE with `SUM(SUM(amount)) OVER (...)` — CORRECT (OVER on outer).
- **r07:2959** — Explicit warning about the inline form being mis-read-prone, recommend CTE form — CORRECT and exactly anticipates this slip.

**Resource is correct.** The responder slip is a transcription/synthesis error that moves the OVER() from the outer SUM to the inner SUM — exactly the trap the resource warns against. **No resource fix needed.**

### Classification

- **One-off responder slip** on the inline form; CTE form (listed second, described as "cleaner alternative") IS correct.
- Family: `feedback_responder_broken_secondary_alternative.md` — **broken alternative listed FIRST variant** (the broken form is the primary in display order, but the correct form is also present as alternative). Engineer who tries FORM 1 hits a parse/analysis error → goes to FORM 2 → works. Engineer who reads FORM 2 first → works immediately.
- **NOT a resource gap** — r07:1914 + r07:2864-2959 already cover both the correct inline form AND the CTE form AND a section-level warning about the misread risk. The teacher has done the right thing.
- **NO RESOURCE FIX.** Re-probe percent-of-total in next sweep with a different phrasing to confirm one-off vs recurrent.

### Verdict — Q3: 3.3125 PASS (broken-primary drag, cushion absorbs)

- Acc 2.5 — FORM 1 invalid Trino SQL on two independent grounds (ungrouped-col + aggregate-of-window). FORM 2 fully correct. Half of the SQL output doesn't run.
- Clar 4.0 — the conceptual explanation ("`SUM(x) OVER ()` empty-frame = grand total") is sound and accurate. The mismatch is between the explanation and the SQL transcription.
- App 3.25 — engineer following the answer's display order hits a parse error on FORM 1, then the CTE FORM 2 works. Practical applicability salvaged but with a friction cost.
- Compl 3.5 — both an inline attempt and a CTE attempt are present; the CTE alternative satisfies the engineer's stated constraint ("no separate subqueries joined back" — a CTE is not a join-back subquery, just a row-set definition).

---

## Q4 — Iceberg Puffin stats + ANALYZE + SHOW STATS (STRONG PASS)

### Engineer's framing

Iceberg table ~400GB. Teammate says some queries are slow because Trino reads the table's "statistics" from disk every query and they may be stale. Real? Does Trino store/read a per-table stats file, and how to tell if stale/missing?

### Responder's answer (key shape)

- YES — Trino stores stats in **Puffin files (`.stats`)** alongside table metadata in MinIO, referenced from the snapshot metadata.json. Not auto-updated; must re-run ANALYZE.
- `SHOW STATS FOR iceberg.analytics.events;` returns columns: `column_name`, `data_size`, `distinct_values_count`, `nulls_fraction`, `row_count`, `low_value`, `high_value`. NULL `distinct_values_count` = not collected for that column.
- `ANALYZE iceberg.analytics.events WITH (columns = ARRAY['user_id','tenant_id','event_type']);` populates them; limit to join/filter columns for faster ANALYZE.
- CBO uses NDV for join order + broadcast-vs-shuffle distribution.
- Re-run after major ingests / weekly cadence; slightly stale stats > no stats. Cites r24.

### Source verification

- **Iceberg Puffin file as the statistics sidecar** — verified per the Iceberg spec (Puffin v1 stores `apache-datasketches-theta-v1` NDV blobs). The Trino Iceberg connector writes Puffin sidecars during ANALYZE. Confirmed via [trinodb/trino #16583](https://github.com/trinodb/trino/issues/16583) ("Iceberg REST catalog does not delete Puffin stats files when purging the table") + [trinodb/trino PR #13636](https://github.com/trinodb/trino/pull/13636) ("Analyze Iceberg tables").
- **`SHOW STATS FOR <table>` returned columns** — verified at [trino.io/docs/current/optimizer/statistics.html](https://trino.io/docs/current/optimizer/statistics.html): "`column_name`, `data_size`, `distinct_values_count`, `nulls_fraction`, `row_count`, `low_value`, `high_value`." NULL `distinct_values_count` indicates the column was not analyzed.
- **`ANALYZE table_name WITH (columns = ARRAY[...])` syntax** — verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html): "You can specify a subset of columns to be analyzed with the optional `columns` property" with the exact `WITH (columns = ARRAY['col_1','col_2'])` form. EXACT match to responder's syntax.
- **Stats not auto-refreshed** — verified at trino.io/docs/current/connector/iceberg.html: "Note that if statistics were previously collected for all columns, they must be dropped using the drop_extended_stats command before re-analyzing." No background refresh; explicit re-run required after data changes.
- **CBO uses NDV for join order + broadcast/shuffle** — verified at trino.io/docs/current/optimizer/cost-based-optimizations.html: "Join enumeration and join distribution strategies depend on statistics."

### Verdict — Q4: 4.9375 STRONG PASS

- Acc 5.0 — every claim verified against current Trino/Iceberg docs + GitHub issues. Puffin mechanism, SHOW STATS schema, ANALYZE syntax (including the `WITH (columns = ARRAY[...])` form), no-auto-refresh, CBO usage all accurate.
- Clar 5.0 — clear "what file, what command, how to check, how to refresh" structure; mental model immediately actionable.
- App 5.0 — copy-pasteable for the engineer's exact `iceberg.analytics.events` shape; the "limit to join/filter columns for faster ANALYZE" advice is the right practical guidance for a 400GB table.
- Compl 4.75 — covers the storage location, the inspection command, the refresh command, the symptom of staleness; minor recall shave for not explicitly naming `drop_extended_stats` for clean re-analysis when column set changes (r24 covers it).

---

## Topic-row updates (one decimal of precision)

| Topic | Before | Delta | After | Status |
|---|---|---|---|---|
| Oracle PL/SQL → dbt+Trino | 4.4619/131 | +0.0032 (Q1=4.875 above mean) | **4.4651/132** | PASSED, margin +0.9651 |
| SQL query best practices for OLAP | 4.5775/229 | +0.0013 | **4.5788/230** | PASSED, margin +1.0788 |
| Analytical query patterns on Iceberg+Trino | 4.5206/111 | -0.0108 (Q3=3.3125 well below mean) | **4.5098/112** | PASSED, margin +1.0098 |
| Trino CBO / ANALYZE / Puffin statistics | 4.6105/22 | +0.0142 | **4.6247/23** | PASSED, margin +0.1247 over 4.5 raised threshold |

All required topics REMAIN PASSED. Q3 drag on Analytical-query-patterns absorbed (still +1.01 margin, deep in the comfort band).

---

## Pattern observation

35-iter sustainment band continues. iter1161 4.50 PASS NO-OP — Q1 watch closes, Q3 broken-primary drag absorbed by cushion. Watch-closure metric: **8 of last 8 watches close on first re-probe** (consistent with the established 1-iter-slip-then-recover Haiku variance pattern).

The Q3 finding is the most informative one this iter: a synthesis/transcription slip in which the OVER() clause migrates from the outer SUM to the inner SUM, producing simultaneously (a) an ungrouped-column reference and (b) an aggregate-of-window nesting. The resource at r07:2959 explicitly warns about this exact misread risk — the warning text is doing its job (the CTE FORM 2 IS correct) but the responder still emitted the broken inline form as the primary. This matches `feedback_responder_broken_secondary_alternative` precisely: the broken form is on the menu (and here, listed FIRST), the correct form is also on the menu (here, listed second as the "cleaner alternative"). The discipline is: re-probe percent-of-total in next sweep with a different phrasing; if it recurs, consider an additive defang card at r07:1914 with an inline-WRONG-form DO-NOT-WRITE block showing `SUM(SUM(x) OVER ())` and `SUM(x) OVER () [under GROUP BY]` as the two specific traps. For now: NO-OP — one instance is variance, not a defect.

**Q1 watch CLOSURE is the load-bearing outcome this iter.** The iter1160 Oracle `IF EXISTS staging` → INSERT misroute (validate-against-known-list) was the kind of synthesis slip that COULD have been a findability gap — but the re-probe in a different phrasing (direct dbt+Trino, no Oracle wrapping) hit the correct canonical immediately. r27 §228/§271-273/§321/§330-331 anchors are doing their job; the iter1160 slip was per-instance variance not a resource defect. Watch `r27 IF-EXISTS-staging-guard → dbt interpretation slip iter1160` **CLOSED**.

**RECOMMENDATION = NO-OP.** No FIX-A. No new watches.
