# Judge Feedback — iter1105 (2026-06-26)

**Phase**: extended (passed:true). FIX-A re-probe (Q1+Q2 GROUPING SETS first-STOP-slot hoist from iter1104), Q3+Q4 breadth.
**Iter average**: (5.0 + 5.0 + 3.25 + 5.0) / 4 = **4.5625 PASS** (margin +1.0625)
**Verdict**: PASS on average. **FIX-A REACHED** for both Q1 and Q2 — responder now LEADS with `GROUPING SETS ((x),(y),())` for "totals by X AND by Y AND grand total" on two completely different domains. ONE source-verified Q3 partial defect (`AT TIME ZONE` on tz-naive column is session-dependent; canonical r07 form not retrieved).

---

## FIX-A reach verdict (the main item this iter)

| Q | Domain | Asked construct | Responder LED with | FIX-A status |
|---|---|---|---|---|
| Q1 | revenue by region + by product line + grand total | one query, no cross-grid | `GROUP BY GROUPING SETS ((region), (product_line), ())` + `ORDER BY GROUPING(...)` | **REACHED** — matches r28 §`COPY THIS for "totals by X AND by Y AND grand total"` exactly |
| Q2 | tickets by priority + by team + total | one query, no priority×team grid | `GROUP BY GROUPING SETS ((priority_level), (assigned_team), ())` + `GROUPING() ORDER BY` | **REACHED** — same canonical form |

Both Qs correctly:
- Rejected ROLLUP (which would silently drop the by-`y`-only row)
- Rejected the per-`(X,Y)` cross-detail framing
- Explained the "replaces N UNION ALL queries" framing the r28 router uses
- Used `GROUPING(col)=1` semantics to label/order subtotal rows

The iter1104 first-STOP-slot hoist (GROUPING SETS COPY-THIS block now precedes the ROLLUP COPY-THIS block at r28 L426 vs L437, with a "⭐ MOST-MISROUTED CASE" pre-router callout at L424) is doing its job on two different domains. **Closed.**

---

## Verification — RAW sources / official docs

| Claim | Source verified | Verdict |
|---|---|---|
| `GROUP BY GROUPING SETS ((a),(b),())` emits per-A + per-B + grand total, NO (a,b) detail | trino.io/docs/467/sql/select.html GROUPING SETS grammar | CORRECT (Q1+Q2 LEAD) |
| `GROUPING(col)` returns 1 for a column rolled away in that row, 0 otherwise | trino.io/docs/467/functions/aggregate.html | CORRECT (Q1+Q2 ORDER BY pattern) |
| `naive_ts AT TIME ZONE 'X'` for a TIMESTAMP without time zone uses the SESSION time zone to interpret the value, then converts to X | trino.io/docs/467/functions/datetime.html (datetime ops); cross-checked vs r07 §timezone-bucketing canonical | RESPONDER Q3 IS SESSION-DEPENDENT for tz-naive UTC-stored columns — partial defect |
| For a tz-NAIVE UTC-intent column the robust form is `with_timezone(occurred_at, 'UTC') AT TIME ZONE 'Asia/Tokyo'` OR two-step `occurred_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Tokyo'` | r07 L2422-L2448 canonical block (verified at trino.io/docs/467/functions/datetime.html `with_timezone(timestamp(p), zone)`) | The canonical answer Q3 should have produced |
| For a tz-AWARE column (`timestamp(p) with time zone` — typical Iceberg UTC-normalized storage), bare `event_ts AT TIME ZONE 'X'` IS correct (session-independent) | trino.io/docs/467 type semantics; r07 L2407 example uses this | CORRECT but the responder did NOT disambiguate which case |
| `DATE(timestamp with time zone)` buckets on the LOCAL wall-clock date implied by the value's attached zone | Trino CAST semantics — date extracted in the value's own attached zone, not session zone | CORRECT |
| dbt incremental `merge` strategy + `unique_key` makes a re-processed lookback window idempotent | docs.getdbt.com/docs/build/incremental-models + dbt-trino merge docs | CORRECT (Q4) |
| `{% if is_incremental() %}` guard runs only on subsequent runs (first run is CTAS, no `WHERE`) | docs.getdbt.com/docs/build/incremental-models#understand-the-is_incremental-macro | CORRECT (Q4) |
| `partitioning: ['day(occurred_at)']` Iceberg partition transform | iceberg.apache.org/docs/latest/iceberg-trino/ + Trino Iceberg connector docs | CORRECT (Q4) |

---

## Per-Question scoring

### Q1 — revenue by region AND by product line AND grand total, ONE query (NOT a region×product grid)

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | `GROUP BY GROUPING SETS ((region), (product_line), ())` is exactly the canonical Trino 467 form. `ORDER BY GROUPING(region) + GROUPING(product_line)` ordering pattern correct. |
| Clarity | 5 | Explicitly explained "replaces three UNION ALL queries"; called out NULL semantics for rolled-up columns; explained NO cross-detail row. |
| Applicability | 5 | Copy-paste runnable on the prod stack; matches the r28 leading canonical block verbatim. |
| Completeness | 5 | Covered the operator choice, the row shape, the NULL labels, the ORDER BY, and the "why not ROLLUP" warning. |
| **Q1 avg** | **5.00** | |

### Q2 — ticket counts by priority AND by team AND total, ONE result (NOT a priority×team grid)

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | Identical canonical shape to Q1, different domain. `GROUPING SETS ((priority_level), (assigned_team), ())` is right. |
| Clarity | 5 | Same explanation pattern; engineer can map column-by-column. |
| Applicability | 5 | Direct copy with team/priority placeholders. |
| Completeness | 5 | Covered subtotal NULLs, GROUPING() labelling, ordering. |
| **Q2 avg** | **5.00** | |

### Q3 — UTC-stored event timestamps; bucket by CUSTOMER LOCAL calendar date (e.g. Tokyo 11PM UTC → next day); no hardcoded offsets

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 3 | **PARTIAL DEFECT** — bare `event_ts AT TIME ZONE 'Asia/Tokyo'` is the CORRECT form ONLY when `event_ts` is `timestamp(p) with time zone` (the Iceberg UTC-normalized form). If `event_ts` is bare `TIMESTAMP` (no tz) storing UTC, Trino's `AT TIME ZONE` interprets the value using the **SESSION timezone** first — if the session is not UTC, the result is hours-off. The robust session-independent form is `with_timezone(event_ts, 'UTC') AT TIME ZONE 'Asia/Tokyo'` (or two-step `event_ts AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Tokyo'`). r07 L2422-L2448 has the canonical block + an inline-marked WRONG form ("session-dependent — only correct when current_timezone() = 'UTC', off by hours otherwise"). The responder did NOT disambiguate the two column-type cases. Additional secondary concern: the WHERE-clause form `WHERE event_ts AT TIME ZONE 'X' >= CURRENT_DATE - INTERVAL '30' DAY` wraps the partition column in an expression on the LEFT, which may forfeit partition pruning; r07 L2412 canonical predicate form uses bare `created_at` on the LEFT (`WHERE created_at >= date_trunc('day', current_timestamp AT TIME ZONE 'X') - INTERVAL '30' DAY`) to keep the column sargable. |
| Clarity | 4 | IANA zone-name framing clear; the "shift before bucketing" rationale is right. Missing: explicit type disambiguation paragraph. |
| Applicability | 3 | Works in the easy case (Iceberg timestamptz storage), silently wrong in the harder one (Spark-ingested bare TIMESTAMP storing UTC, session zone ≠ UTC). The user's "Tokyo 11PM UTC → next day" framing suggests they're aware of UTC storage but didn't say which type — responder should have asked or covered both. Predicate non-sargable form may also hurt prod perf. |
| Completeness | 3 | Missed: (a) tz-naive vs tz-aware column branch, (b) `with_timezone()` / two-step alternative for tz-naive, (c) keeping the partition column bare on the left of WHERE for pruning, (d) `at_timezone(ts, user_tz_column)` for per-customer-zone bucketing (the question's "CUSTOMER LOCAL" framing implied the customer's zone is a per-row attribute, not a literal). |
| **Q3 avg** | **3.25** | |

### Q4 — dbt incremental missing late-arriving (2-3 day) records, avoid full reprocessing

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | `incremental_strategy='merge'` + `unique_key='event_id'` + 3-day lookback `WHERE occurred_at >= (SELECT date_add('day', -3, COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01')) FROM {{ this }})` guarded by `{% if is_incremental() %}` is the canonical r28 §139 / r28 §144 block. `day(occurred_at)` Iceberg partitioning is right. The COALESCE bootstrap handles the empty-table first run after backfill. The idempotency explanation (matched rows update in place, unmatched insert) is right. |
| Clarity | 5 | Clean, walked through each config line; clear on why each is needed. |
| Applicability | 5 | Copy-paste into a dbt-trino project. Matches resource exactly. |
| Completeness | 5 | Covered config, lookback predicate, is_incremental guard, partitioning, merge idempotency. |
| **Q4 avg** | **5.00** | |

---

## Score table

| Q | Acc | Clar | Appl | Comp | Avg |
|---|---|---|---|---|---|
| Q1 GROUPING SETS revenue/region/product | 5 | 5 | 5 | 5 | 5.00 |
| Q2 GROUPING SETS tickets/priority/team | 5 | 5 | 5 | 5 | 5.00 |
| Q3 AT TIME ZONE local-day bucketing | 3 | 4 | 3 | 3 | 3.25 |
| Q4 dbt incremental late-arriving lookback | 5 | 5 | 5 | 5 | 5.00 |
| **Iter avg** | **4.50** | **4.75** | **4.50** | **4.50** | **4.5625 PASS** |

Margin to 3.5 threshold: **+1.0625**.

---

## Source-verified defects this iter

1. **Q3 — `AT TIME ZONE` session-dependence on tz-naive columns NOT disambiguated.** The bare `event_ts AT TIME ZONE 'Asia/Tokyo'` form silently breaks when `event_ts` is `TIMESTAMP` (no tz) storing UTC AND the Trino session zone is not UTC. The canonical r07 block (L2422-L2448) explicitly inline-marks this WRONG and shows the session-independent forms. The responder did not retrieve the with_timezone / two-step alternative, and did not branch on column type.

Secondary (not score-impacting beyond Q3 Applicability): the predicate-side `WHERE event_ts AT TIME ZONE 'X' >= CURRENT_DATE - INTERVAL '30' DAY` wraps the column in an expression on the LEFT, which may lose partition pruning. r07 L2412 shows the canonical sargable form (`WHERE created_at >= date_trunc('day', current_timestamp AT TIME ZONE 'X') - INTERVAL '30' DAY` — column bare on the left).

---

## Teacher guidance

### Verdict on Q3: **MIXED — resource gap is borderline; primarily a responder retrieval gap.**

The canonical r07 block IS in place at L2422-L2448 with the correct two forms and an explicit WRONG block. The responder did not retrieve it. Possible reasons:

- The r07 timezone-bucketing block may not be findable from the specific question phrasing "UTC-stored event timestamps ... bucket by CUSTOMER LOCAL calendar date ... Tokyo 11PM UTC → next day ... without hardcoding offsets". Check whether the keyword anchors in that section catch on phrases like "customer local", "per-customer zone", "11PM UTC next day", "tz-naive UTC-stored column", "session-independent".
- The current "WRONG (session-dependent)" example at L2446-L2447 uses `CAST(occurred_at AS TIMESTAMP WITH TIME ZONE)` as the wrong-shape, NOT bare `occurred_at AT TIME ZONE 'Asia/Tokyo'` — the responder's specific wrong shape (bare AT TIME ZONE with NO disambiguation of column type) is not directly inline-marked.

### Recommended FIX-A for next iter (LIGHT, additive — do NOT churn):

1. **Add a keyword-magnetic findability sentence at the TOP of the r07 timezone-bucketing block.** Something like: "READ FIRST when asked: bucket UTC timestamps by customer local date, per-customer zone, IANA zone, 11PM UTC → next day, no hardcoded offsets, customer-local calendar day." (mirror the GROUPING SETS L415 keyword-anchor pattern that successfully closed iter1104).

2. **Add a column-type router sentence:** "**FIRST check the column type**: `DESCRIBE` the table. If `timestamp(p) with time zone` → bare `event_ts AT TIME ZONE 'zone'` is correct. If `timestamp(p)` (no tz, Spark-ingested UTC) → MUST use `with_timezone(event_ts, 'UTC') AT TIME ZONE 'zone'` to be session-independent."

3. **Add bare `event_ts AT TIME ZONE 'Asia/Tokyo'` (no `with_timezone`/no two-step) as an explicit defang/WRONG line in the inline-marked WRONG block,** since the responder's specific footgun shape is not currently captured there.

4. **For the "CUSTOMER LOCAL" framing**, ensure the `at_timezone(with_timezone(ts, 'UTC'), customer_zone_column)` worked example (already at r07 L2459+) is cross-referenced from the keyword block at the top of the section — the responder did not surface this even though the question implied per-row customer zone.

### Do NOT touch r28 GROUPING SETS (FIX-A REACHED twice this iter — locked).

### Do NOT touch Q4 (clean canonical retrieval).

### Don't churn / scope guard

The Q3 ask is a real footgun, but it's also borderline: if the engineer's Iceberg column is `timestamp with time zone` (the recommended UTC-normalized form), the responder's answer is correct. Don't escalate to a major rewrite — the LIGHT FIX-A above (4 small additions) should close findability and the responder's specific wrong-shape gap without restructuring the section.

---

## Topic touch map (rubric updates)

- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** — Q1+Q2 (GROUPING SETS subtotal-pivot pattern) + Q3 (time-series bucketing by local zone). Mixed: two strong + one partial.
- **Improving complex SQL performance on Trino with dbt** — Q4 (dbt incremental late-arriving + lookback) + Q1+Q2 (single-query-replaces-N-UNION-ALL is a complex-SQL-perf pattern).
- **Oracle PL/SQL → dbt/Trino migration** — Q4 (dbt incremental config pattern).
