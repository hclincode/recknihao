# Iter1130 Feedback — 4.5469 PASS NO-OP+WATCH (dedup-tied-tuple FIX-A REACHED + Q1 watch CLOSES; new Q2 `SELECT * EXCEPT` foreign-projection slip = responder one-off, NO-OP+watch)

## Per-question scores

### Q1 — Dedup tied-tuple FIX-A re-probe (webhook double-fired, (order_id, status, status_changed_at) tied, only row_uuid differs, delete extras keep exactly one) — 5.0000

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | Pattern B3 exact match: `DELETE FROM iceberg.orders WHERE row_uuid IN (SELECT row_uuid FROM (SELECT row_uuid, ROW_NUMBER() OVER (PARTITION BY order_id, status, status_changed_at ORDER BY row_uuid DESC) AS rn FROM iceberg.orders) WHERE rn > 1)`. Delete by UNIQUE row_uuid (not the tied tuple). row_uuid DESC tiebreaker = deterministic "keep one". Verified against r27 §1991-2003 Pattern B3 canonical. |
| Beginner clarity | 5.0 | Explicitly explains the data-loss trap: "deleting by the tuple would match keeper+dupes and wipe everything." Names the unique row_uuid as the safe key. |
| Practical applicability | 5.0 | Copy-paste ready DELETE + companion `HAVING COUNT(*)>1` verification query for the engineer to confirm dedup worked. |
| Completeness | 5.0 | Addresses primary DELETE form, tiebreaker reasoning, AND verification — full lifecycle. |

**Q1 = 5.0000.**

### Q2 — Non-tied dedup regression check (customer_profiles, distinct updated_at, keep latest per customer, in-place or rebuild) — 3.3750

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 2.5 | ROW_NUMBER + WHERE rn=1 shape is correct (Pattern B1). BUT `SELECT * EXCEPT (rn)` is **NOT valid Trino 467** — `EXCEPT` in Trino is a SET operator between queries (per `trino.io/docs/current/sql/select.html`), NOT a column-exclusion projection. `SELECT * EXCEPT (col)` is BigQuery/Databricks/Snowflake/DuckDB syntax (verified `trinodb/trino #26402` + `#26969` — open feature requests, NOT implemented). Both Option A CTAS and Option B dbt model would PARSE-ERROR on `SELECT * EXCEPT (rn)`. Trino's actual workaround is the `exclude_columns` table function (`SELECT * FROM TABLE(exclude_columns(input => TABLE(t), columns => DESCRIPTOR(rn)))`) — but the canonical r27 Pattern B1 guidance is "**EXPLICIT column list — Iceberg has no SELECT * rename safety**." The responder slipped against existing canonical guidance. |
| Beginner clarity | 4.5 | Explains the two paths (in-place CTAS rebuild vs dbt model) clearly with rn=1 reasoning. The SELECT * EXCEPT defect is silent / unflagged. |
| Practical applicability | 2.5 | The exact SQL pasted into a Trino client would parse-fail on both options. Engineer would need to debug + look up "Trino column exclusion" before proceeding. CTAS scaffolding + RENAME swap + dbt config are otherwise sound. |
| Completeness | 4.0 | Covers in-place (CTAS) + dbt model + RENAME swap + Iceberg semantics. Does NOT cover the explicit column list discipline that r27 Pattern B1 explicitly prescribes. |

**Q2 = 3.3750.**

### Q3 — `COUNT(*) FILTER (WHERE ...)` for 4 side-by-side counts per region — 5.0000

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | `aggregate_function(...) FILTER (WHERE condition)` is valid Trino 467 syntax (verified `trino.io/docs/current/functions/aggregate.html` — "FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause... supported for all aggregate functions"). `COUNT(*) FILTER (WHERE amount>500)` is exactly the canonical form. CASE alternative correctly noted as still valid. |
| Beginner clarity | 5.0 | Clean side-by-side form, explicit aliases, GROUP BY region. |
| Practical applicability | 5.0 | Copy-paste ready, cleaner than 4x COUNT(CASE WHEN) as the engineer asked. |
| Completeness | 5.0 | Addresses the cleaner-form question + notes CASE works too + works on any aggregate (not just COUNT). |

**Q3 = 5.0000.**

### Q4 — Per-team Trino cost attribution / chargeback (4 teams, one cluster, bill creeping) — 4.8125

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | JOIN `system.runtime.queries q` to `system.runtime.tasks t` on `query_id`, GROUP BY `q.source`, SUM `t.split_cpu_time_ms` + `t.physical_input_bytes`, `pct_cluster_cpu` via `SUM(SUM(...)) OVER ()`. All column names verified against r16 §229-§248 canonical (which itself is verified against trino.io). `q.source` set via dbt `profiles.yml` `source: team_x` or JDBC `?source=` correctly identified (also CLI `--source=` / HTTP `X-Trino-Source:`). LIMITATION framing accurate: `query.max-history` default 100 + `query.min-expire-age` default 15min (verified `trino.io/docs/current/admin/properties-query-management.html`) — responder's "~last 100 / ~15 min" matches. Event listener for persistent retention is the correct durable answer. |
| Beginner clarity | 4.5 | Reasonably clear but dense (single-paragraph dump rather than numbered steps). |
| Practical applicability | 5.0 | Three concrete actions: paste the JOIN query, set `source` client-side (two specific mechanisms), wire up event listener for monthly windows. |
| Completeness | 4.75 | Covers identity, attribution query, retention limitation, persistent-store path. Minor: doesn't surface the dollar-conversion path (`cpu_seconds x $/vCPU-sec`) that r16 Step 3 also offers — per-instance only, not a resource gap. |

**Q4 = 4.8125.**

## Iteration summary

| Q | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q2 | 2.5 | 4.5 | 2.5 | 4.0 | **3.3750** |
| Q3 | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q4 | 5.0 | 4.5 | 5.0 | 4.75 | **4.8125** |

**Overall iter average = (5.0 + 3.375 + 5.0 + 4.8125) / 4 = 4.5469 PASS** (margin +1.0469 above the 3.5 pass threshold; NO per-Q veto invoked).

## Q1 dedup-tied-tuple FIX-A verdict — watch CLOSES

iter1129's r27 Pattern B3 LIGHT FIX-A **REACHED** on the exact re-probe of the iter1129 question family. Specifically the responder:
1. Picked the **unique row_uuid as the DELETE key** (NOT the business tuple `(order_id, status, status_changed_at)`).
2. Used `PARTITION BY` on the **tied business tuple** + `ORDER BY row_uuid DESC` as the deterministic tiebreaker — exactly the Pattern B3 canonical at r27 §1994-2003.
3. Explicitly **named the data-loss trap** ("deleting by the tuple would match keeper+dupes and wipe everything") — which is the very warning iter1129 added at r27 §1986-1988.
4. Added a verification query (`HAVING COUNT(*)>1`) — operational discipline beyond the canonical, no slip.

This is a clean FIX-A reach, no inheritance of the iter1129 Pattern B2 trap, no Pattern B2 mis-translation. **Watch CLOSES on the first re-probe opportunity.** Matches the iter1121 ADD-COLUMN / iter1125 partition-column-COUNT / iter1127 population-vs-per-group-percentile pattern of NO-OP-then-re-probe-CLOSES (now a 4th successful watch closure in 12 iters).

## Q2 `SELECT * EXCEPT (rn)` defect — classification + recommendation

**Defect: REAL Trino-dialect violation.** `SELECT * EXCEPT (col)` is BigQuery/Databricks/Snowflake/DuckDB column-exclusion projection — **NOT valid Trino 467 syntax.** Trino's `EXCEPT` is a set operator between two queries (e.g. `SELECT a FROM t1 EXCEPT SELECT a FROM t2`); putting `EXCEPT (rn)` after `SELECT *` is a parse error. Both Q2 Option A (CTAS) and Option B (dbt model) would parse-fail as written.

**Source-verification grep:** searched `resources/` for `SELECT * EXCEPT` and `EXCEPT (`:
- `resources/23-sql-best-practices-olap.md:3286` already has the **correct defang**: "`SELECT * EXCEPT (col1, col2)` (column-exclusion projection) | BigQuery, Databricks, ClickHouse | **NOT supported.** Parse error. Open feature request trinodb/trino #26969. | Spell out the columns you want."
- `resources/27-oracle-plsql-to-dbt-trino.md:1964` Pattern B1 explicitly carries the comment "EXPLICIT column list — Iceberg has no SELECT * rename safety" and uses an explicit `customer_id, created_at, amount` projection.

**Classification: RESPONDER ONE-OFF, NOT resource-sourced.** The resource canonical correctly prescribes explicit column lists; the responder synthesized a foreign-projection construct (BigQuery-flavored `SELECT * EXCEPT (rn)`) to strip the helper rn column instead of following the explicit-column-list discipline. Matches the `imported-prior` family signature (treating a BigQuery/Snowflake construct as if it were generic ANSI SQL), specifically the foreign-projection sub-family. First instance of this specific construct slipping; r23 §3286 defang exists but is in a faraway dialect-anti-patterns table, NOT inlined at r27 Pattern B1 where the CTAS-rebuild keyword route lands.

**Recommendation: NO-OP + WATCH STREAM (NOT a FIX-A yet).** Reasoning: (1) r23 §3286 already has the explicit defang; this is responder-side keyword routing failure, not a resource silence; (2) first instance of this exact slip — per the established NO-OP-then-re-probe discipline (iter1116 ts-minus-ts / iter1120 multi-clause ADD-COLUMN / iter1123 partition-column-COUNT / iter1126 population-percentile), don't preemptively touch the resource on the first instance; (3) Q1 just demonstrated the responder CAN follow r27 Pattern B3 perfectly on the re-probe, so the routing is recoverable.

**Re-probe queue (PRIORITY 1):** within 2-3 iters, ask another CTAS-rebuild question that requires stripping a helper column (e.g. "dedup using ROW_NUMBER then drop the rn column on the rebuilt table" or "dbt model that adds a hash key then strips an intermediate column" — the question must FORCE the column-exclusion choice). Confirm responder reaches the explicit-column-list path. If RECURS → **LIGHT FIX-A at r27 §1962-1972 Pattern B1**: add an inline INLINE-WRONG defang above the explicit-column-list example with `SELECT * EXCEPT (rn) -- WRONG, parse error on Trino 467; spell columns out` per `feedback_defang_donotwrite_snippets`. Cross-link to r23 §3286 from r27 Pattern B1. Reconcile-in-place per `feedback_reconcile_dont_append`.

## Critical verification results

| Claim | Source-verified | Notes |
|---|---|---|
| Q1: row_uuid-as-DELETE-key + (tied-tuple)PARTITION BY + (id)ORDER BY tiebreaker | YES (r27 §1991-2003 Pattern B3) | Exact Pattern B3 match. |
| Q1: data-loss trap if delete by the tuple | YES (r27 §1986-1988 critical warning + §2015 DO-NOT-WRITE row) | Responder explicitly names the trap. |
| Q2: ROW_NUMBER + WHERE rn=1 keep-latest per customer | YES (r27 §1962-1972 Pattern B1 / §1950-1957 Pattern A) | Correct shape. |
| Q2: `SELECT * EXCEPT (rn)` valid Trino 467 | NO — foreign projection (BigQuery/DuckDB/Snowflake), open feature request trinodb/trino #26402/#26969 | r23 §3286 already defangs this in the dialect-anti-patterns table. |
| Q2: `CREATE TABLE __new AS ... RENAME TO` atomic swap | YES (r27 §1970-1972 Pattern B1 + r17 Iceberg RENAME canonical) | Iceberg supports `ALTER TABLE ... RENAME TO`. |
| Q2: dbt `materialized='table', unique_key='customer_id'` | YES (general dbt-trino correct, but `unique_key` is for incremental not table materializations — minor framing; for `materialized='table'` it's not enforced, just metadata) | Minor — primary Q2 issue is the SELECT * EXCEPT defect. |
| Q3: `COUNT(*) FILTER (WHERE ...)` valid + works on any aggregate | YES (verified `trino.io/docs/current/functions/aggregate.html` — "supported for all aggregate functions") | Clean. |
| Q4: `system.runtime.queries.source` column exists | YES (verified via search; r16 §220 lists explicitly) | Clean. |
| Q4: `system.runtime.tasks.split_cpu_time_ms` + `physical_input_bytes` | YES (verified r18 §433-§440: "CPU time is `split_cpu_time_ms` (NOT `cpu_time_ms`)"; r16 §233 same; release 330 added `physical_input_bytes`) | Clean. Tables joinable on `query_id`. |
| Q4: ~last 100 queries / ~15 min retention | YES (`query.max-history` default 100, `query.min-expire-age` default 15 min — verified Trino query-management properties docs) | Clean. |
| Q4: event listener for durable history | YES (r18 + r16 §268) | Clean. |

No other Trino-dialect violations in any answer.

## Topic checklist updates

| Topic | Iter1129 baseline | Iter1130 contributions | Iter1130 new |
|---|---|---|---|
| Oracle PL/SQL -> dbt+Trino migration (r27 §4.5C Pattern A/B1/B2/B3 dedup canonical exercised by Q1+Q2) | 4.4615 / 110 = 490.7650 | Q1 5.0000 + Q2 3.3750 = 8.3750 added; n+=2 | (490.7650 + 5.0 + 3.375) / 112 = **4.4566 / 112 PASSED** (-0.0049, margin to 3.5 = +0.9566 preserved) |
| SQL best practices for OLAP (Q3 `COUNT(*) FILTER` is a Trino dialect feature) | 4.5471 / 189 = 859.5019 | Q3 5.0000 added; n+=1 | (859.5019 + 5.0) / 190 = **4.5500 / 190 PASSED** (+0.0029) |
| Cost considerations for analytical workloads at SaaS scale (Q4 per-team chargeback via system.runtime.queries.source + tasks join) | 4.2504 / 21 = 89.2584 | Q4 4.8125 added; n+=1 | (89.2584 + 4.8125) / 22 = **4.2759 / 22 PASSED** (+0.0255, the thinnest-margin row lifted modestly) |

All other required topics untouched. ALL required topics REMAIN PASSED.

## Watch streams

| Stream | Status |
|---|---|
| dedup-tied-tuple DELETE-IN trap (opened iter1129) | **CLOSED iter1130** — Pattern B3 reach confirmed on direct re-probe. |
| population-vs-per-group percentile entity-GROUP-BY (opened iter1126) | CLOSED iter1127. |
| partition-column-COUNT data-file folklore (opened iter1123, LIGHT-FIX iter1124) | CLOSED iter1125. |
| multi-clause ADD COLUMN (opened iter1120) | CLOSED iter1121. |
| ts-minus-ts type (opened iter1116) | CLOSED. |
| **NEW iter1130: `SELECT * EXCEPT (rn)` foreign-projection slip on CTAS-rebuild** | **OPENED** — first instance. Re-probe in 2-3 iters with another CTAS-rebuild-strip-helper-column question. NO-OP this iter per first-instance discipline. |

No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover/GREATEST-NULL-Postgres/array_sum/`->`-JSON/DATEDIFF-dialect-import/multi-arg-COUNT-DISTINCT/ts-minus-ts/over-warning/multi-clause-ADD-COLUMN/contains_sequence-array_position-arithmetic/partition-column-COUNT-data-file-folklore/population-vs-per-group-percentile recurrence.

## Thinnest-margin order after iter1130

| Topic | Avg | n | Margin to 3.5 |
|---|---|---|---|
| storage-tiering | 4.0278 | 9 | +0.5278 |
| dbt-snapshots SCD2 | 4.1526 | 16 | +0.6526 |
| query-perf-basics | 4.1771 | 23 | +0.6771 |
| cost-considerations | **4.2759** | 22 | +0.7759 (lifted +0.0255 by iter1130 Q4) |
| query-perf-regression-diagnosis | 4.3108 | 20 | +0.8108 |
| Oracle-migration | **4.4566** | 112 | +0.9566 (dipped -0.0049 by Q2 drag, still well clear) |
| federation | 4.5024 | 312 | +1.0024 (untouched, fragile-PASS preserved) |
| SQL-best-practices-OLAP | **4.5500** | 190 | +1.0500 (+0.0029 by Q3) |
| CBO/ANALYZE | 4.5920 | 21 | +1.0920 (untouched) |

Storage-tiering remains the thinnest required-topic row.

## Recommendation = NO-OP + WATCH STREAM

Commit rubric+feedback only. No resource edits this iter. Both because:
1. Q1 watch CLOSURE confirms iter1129's LIGHT FIX-A landed correctly.
2. Q2 SELECT-*-EXCEPT slip is responder-side keyword-routing failure (first instance) against existing r23 §3286 defang — first-instance discipline says re-probe before touching the resource.

**Re-probe queue (priority order):**
1. **NEW: CTAS-rebuild-strip-helper-column question** (force the column-exclusion choice; PRIORITY 1).
2. Storage-tiering 10th angle (still thinnest required-topic row; carry from iter1129).
3. dbt-snapshots SCD2 17th angle.
4. Cost-considerations 23rd angle (Q4 was a hit, keep building).
5. Trino-side `EXECUTE optimize` after partition evolution (carry from iter1128).

## Teacher guidance (priority)

1. **NO-OP this iter.** Do NOT preemptively edit r27 Pattern B1 yet. First-instance discipline.
2. **IF the iter1131+ re-probe RECURS** (`SELECT * EXCEPT (rn)` slip on a new CTAS-rebuild question): LIGHT FIX-A at r27 §1962-1972 Pattern B1 — insert an INLINE-WRONG defang above the explicit-column-list example. Specifically:
   ```sql
   -- INLINE WRONG (parse error on Trino 467 — SELECT * EXCEPT is BigQuery/DuckDB/Snowflake, NOT Trino):
   --   CREATE TABLE iceberg.analytics.t_dedup AS SELECT * EXCEPT (rn) FROM (... rn ...) WHERE rn = 1;
   -- See r23 §"dialect-anti-patterns" — SELECT * EXCEPT is open feature request trinodb/trino #26969.
   -- The Trino way: spell the kept columns out explicitly (no SELECT *).
   ```
   Cross-link to r23 §3286 from r27 Pattern B1. Reconcile-in-place per `feedback_reconcile_dont_append`; don't append a new section.
3. Q1 reaffirmed Pattern B3 lineage durable — no edits needed there.
4. Q3 COUNT(*) FILTER lineage durable.
5. Q4 r16 §220-§248 per-tenant chargeback recipe lineage durable.

## Pattern observation

13-iter sustainment band shape: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128 + LIGHT FIX-A iters 1091/1116/1124/1129 + NO-OP+WATCH iters 1120/1123/1126/**1130** with all watches closing on first or second re-probe. iter1130 4.5469 PASS+NO-OP+WATCH matches the iter1126 4.5000 PASS+NO-OP+WATCH profile — single Q with a real defect surfaced via question structure, responder-one-off classification (not resource-sourced), first-instance NO-OP discipline preserved. Q1 watch CLOSURE (4th successful in 12 iters) validates the iter1129 LIGHT FIX-A surgical reconcile-in-place + defang approach. Q2 SELECT-*-EXCEPT defect is the imported-prior family's foreign-projection sub-class (BigQuery/Databricks/Snowflake syntax -> Trino) — first instance of this construct slipping, watch opened for re-probe. Q3 + Q4 reaffirm `COUNT(*) FILTER` and per-tenant chargeback canonicals durable.
