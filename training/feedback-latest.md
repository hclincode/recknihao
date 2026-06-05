# Judge Feedback — Iter 484

**Overall: 4.3125 avg / 4 questions — PASS (thin, identical headline to iter483 but different cause)**
**Phase: extended — end-of-iteration feedback**
**Federation: NOT probed this iter (4.49944/310 row held per directive)**

---

## Per-question scores

| Q | Topic | Acc | Compl | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Iceberg SET PROPERTIES re-probe (native-property fix) | 5.0 | 4.75 | 4.5 | 5.0 | **4.8125** | STRONG PASS — fix CONFIRMED LANDED |
| Q2 | running-total cumulative SUM by month (window function) | 2.5 | 3.5 | 3.75 | 2.25 | **3.0** | FAIL — load-bearing SQL-syntax bug |
| Q3 | Parquet column projection / 3-layer skipping | 4.75 | 4.75 | 4.75 | 4.75 | **4.75** | STRONG PASS |
| Q4 | dbt incremental late-arriving lookback | 4.75 | 4.75 | 4.5 | 4.75 | **4.6875** | STRONG PASS |

**Overall: (4.8125 + 3.0 + 4.75 + 4.6875) / 4 = 4.3125 PASS**

---

## Q1 — Iceberg SET PROPERTIES re-probe (native-property-fix CONFIRMED LANDED)

The responder correctly emitted:
- `ALTER TABLE iceberg.analytics.orders SET PROPERTIES max_commit_retry = 8` (bare identifier, integer literal — exactly the Trino-native form per trino.io/docs/current/connector/iceberg.html)
- Option A: `extra_properties = MAP(ARRAY['write.merge.isolation-level',...], ARRAY['snapshot',...])` with explicit caveat "Trino persists but 'not used by Trino' — available in `$properties`; runtime effect not guaranteed" — matches the doc's verbatim caveat
- Option B: Spark `ALTER TABLE ... SET TBLPROPERTIES (...)` as the recommended path for guaranteed runtime effect on Trino MERGE
- Verification via `SELECT key,value FROM "orders$properties" WHERE key LIKE 'write.%.isolation-level' OR key LIKE 'commit.retry%'` — correct `$properties` metadata-table pattern

**KEY CHECK PASSED**: NO bare-quoted `"commit.retry.num-retries"`. NO bare `"write.merge.isolation-level"` as a Trino SET PROPERTIES key. The iter483 teacher fix (r26 §4 canonical card + r17 cross-reference + DO-NOT-WRITE matrix) **LANDED CLEANLY**. This is fix-confirmation #1 — recommend a 2nd-angle re-probe at iter486-487 to lock at 2+ confirmations.

ZERO fabs. WebSearch-verified all 3 claims against trino.io docs + GitHub PR #24031.

## Q2 — running-total cumulative SUM (LOAD-BEARING SQL-SYNTAX BUG)

The window-over-aggregate pattern `SUM(COUNT(*)) OVER (PARTITION BY tenant_id ORDER BY event_month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is conceptually correct per trino.io/docs/current/functions/window.html ("All Aggregate functions can be used as window functions by adding the `OVER` clause").

**BUT the query as written has TWO compounding SQL bugs**:

1. **`GROUP BY tenant_id, DATE_TRUNC('month', event_date) AS event_month`** — defining a column alias inside GROUP BY is a parse error in every SQL dialect. Per trino.io/docs/current/sql/select.html: "A simple GROUP BY clause may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position (starting at one)." Alias-AS-definition is not part of the GROUP BY grammar.

2. **`event_month` referenced in SELECT / ORDER BY / window ORDER BY but never defined in SELECT** — the SELECT lists bare `event_month` with no `DATE_TRUNC('month', event_date) AS event_month` defining it. Compile-time fail.

Additionally, even if the AS-definition were fixed, Trino does NOT support referencing the SELECT alias by name in GROUP BY per trinodb/trino issue #16533 — you must use the original expression or an ordinal.

**Correct form**:
```sql
SELECT
  tenant_id,
  DATE_TRUNC('month', event_date) AS event_month,
  COUNT(*) AS monthly_events,
  SUM(COUNT(*)) OVER (
    PARTITION BY tenant_id
    ORDER BY DATE_TRUNC('month', event_date)
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_events
FROM events
GROUP BY tenant_id, DATE_TRUNC('month', event_date)
-- or: GROUP BY 1, 2
```

This is a **SQL-syntax-malformed-query / undefined-SELECT-column** fab class — distinct from iter483's capability-grant class but equally load-bearing (paste-and-fail). Suggests the running-total example was either (a) authored in a different SQL dialect (MySQL/PostgreSQL allow GROUP BY alias-reference, though NOT alias-AS-definition) and copy-edited to Trino without grammar-checking, OR (b) authored fresh without compile-time validation.

## Q3 — Parquet column projection (STRONG PASS, confirmed)

Column projection real (Trino's Parquet reader skips columns not in projection list per trino.io). 3-layer skipping (Iceberg manifest pruning -> Parquet row-group min/max -> column-chunk projection) ARCHITECTURALLY CORRECT per Iceberg spec + Parquet spec. 80-col -> 2-col approximately 40x I/O reduction (2/80 = 1/40) realistic for balanced column sizes. Row-oriented-vs-columnar framing pedagogically sound. ZERO fabs.

## Q4 — dbt incremental late-arriving lookback (STRONG PASS, confirmed)

`date_add('day', -3, timestamp)` CONFIRMED valid Trino per trino.io/docs/current/functions/datetime.html (signature `date_add(unit, value, timestamp) -> same as input`, doc explicitly states "Subtraction can be performed by using a negative value"). is_incremental lookback CTE + `COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01')` cold-start handling canonical. `incremental_strategy='merge'` + `unique_key='event_id'` provides idempotent matched-update / unmatched-insert semantics (eliminates duplicates append+lookback would create). Partition-on-same-column alignment makes Iceberg partition pruning kick in on the lookback predicate. ZERO fabs.

---

## Fab + SQL-error inventory (load-bearing only)

| Item | Class | Question | Status | Correct fact / source |
|---|---|---|---|---|
| `GROUP BY tenant_id, DATE_TRUNC('month', event_date) AS event_month` | SQL-syntax-malformed | Q2 | LOAD-BEARING | GROUP BY accepts expressions or ordinals only; no AS-alias-definition syntax. https://trino.io/docs/current/sql/select.html |
| `event_month` referenced in SELECT/ORDER BY/window but never defined in SELECT | undefined-SELECT-column | Q2 | LOAD-BEARING | Must add `DATE_TRUNC('month', event_date) AS event_month` to SELECT for the bare reference to resolve. |
| `GROUP BY event_month` (referencing alias by name) | Trino-grammar-gap | Q2 | adjacent concern | Trino does not support GROUP BY alias-reference per trinodb/trino #16533. Use original expression or ordinal `GROUP BY 1, 2`. |

ZERO fabs on Q1, Q3, Q4.

---

## Topic average updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Iceberg table maintenance (Q1) | 4.4890 / 139 | **4.4928 / 140** | +0.0038 (fix-confirm recovery from iter483's -0.0108 drag) |
| SQL query best practices (Q2) | 4.5915 / 46 | **4.5576 / 47** | -0.0339 (significant drag from Q2 SQL-syntax bug) |
| Column-oriented storage (Q3) | 4.5014 / 15 | **4.5169 / 16** | +0.0155 |
| Postgres-to-Iceberg ingestion (Q4) | 4.5034 / 162 | **4.5046 / 163** | +0.0012 |
| Trino federation | 4.49944 / 310 | **UNCHANGED** | not probed |

---

## Teacher actions for iter 485

### PRIMARY — grep + repair GROUP BY / running-total examples

The Q2 bug is the kind of error that suggests a stale resource example with `GROUP BY ... AS alias` syntax. Run these greps:

```bash
grep -rEn 'GROUP BY [^,)]+ AS [a-z_]' resources/
grep -rEn 'GROUP BY .*\bAS\b' resources/
grep -rEn 'SUM\(COUNT\(\*\)\) OVER' resources/
grep -rEn 'DATE_TRUNC.*GROUP BY' resources/
```

For every match in a working-example position (not inside a DO-NOT-WRITE block):
- Reconcile in-place to the canonical form: alias defined in SELECT, original expression repeated in GROUP BY (or use `GROUP BY 1, 2` ordinals)
- Do NOT just append a correction; fix the offending line

### PRIMARY — install GROUP BY rules anchor block

Add to `resources/19-sql-query-best-practices.md` (or wherever window/running-total examples live) a 3-rule anchor block:

> **Trino GROUP BY rules** (per trino.io/docs/current/sql/select.html + trinodb/trino #16533):
> 1. GROUP BY accepts **expressions** or **ordinal numbers** only. NO `AS alias` definition syntax inside GROUP BY — alias definitions belong in SELECT.
> 2. Trino does **NOT** support referencing a SELECT alias by name in GROUP BY (issue #16533). Use the original expression or an ordinal `GROUP BY 1, 2`.
> 3. A SELECT alias may be used in **ORDER BY** but NOT in **GROUP BY / WHERE / HAVING** in Trino.

### PRIMARY — install canonical running-total card

Add to the same resource (and cross-reference from any window-functions resource):

```sql
-- CORRECT cumulative SUM by month per tenant
SELECT
  tenant_id,
  DATE_TRUNC('month', event_date) AS event_month,
  COUNT(*) AS monthly_events,
  SUM(COUNT(*)) OVER (
    PARTITION BY tenant_id
    ORDER BY DATE_TRUNC('month', event_date)
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_events
FROM events
GROUP BY tenant_id, DATE_TRUNC('month', event_date)
-- or: GROUP BY 1, 2
```

with a DO-NOT-WRITE matrix banning:
- `GROUP BY tenant_id, DATE_TRUNC('month', event_date) AS event_month` — alias in GROUP BY = parse error
- Bare `event_month` in SELECT without a defining `DATE_TRUNC(...) AS event_month`
- `GROUP BY event_month` (alias reference) — Trino-grammar-gap per #16533

### SECONDARY — breadth design

4-Q breadth, NO dedicated federation probe. Federation 4.49944/310 row held per iter472-484+ directive.

### SECONDARY — confirm iter483 fix at 2+ angles

iter484 Q1 was confirmation #1 for the iter483 native-property fix. Schedule a 2nd-angle re-probe at iter486-487 from yet a different keyword angle (e.g., "user got Trino error 'Catalog iceberg table property write.merge.isolation-level does not exist' — how to fix?" or "what's the right way to switch a Trino Iceberg table to snapshot isolation for MERGE?"). Two iters in a row hitting Q1 may saturate the probe — wait 1-2 iters.

### Low-count topics worth datapoints

- dbt sources / source freshness (3 questions, 4.219)
- dbt model contracts (3 questions, 4.1146)
- storage tiering (2 questions, 4.25)
- dbt snapshots SCD2 (2 questions, 4.5625)
- Popular tools overview (3 questions, 4.75)
- What a data lakehouse is (3 questions, 4.6667)

### Fab-class watch (for iter485 teacher pre-flight)

This iter added a NEW class to the fab-watch list:
1. **SQL-syntax-malformed-query** (new this iter) — GROUP BY-inline-alias, undefined-SELECT-column referenced elsewhere. Grep mitigation above.
2. **fabricated-capability-GRANT** (iter481/483) — sibling-name extrapolation / native-dialect-property-as-Trino-property. iter484 Q1 confirms iter483 fix landed; keep DO-NOT-WRITE matrix in place.
3. **citation-hygiene** — restored at Q1 with trino.io + PR #24031 citations; Q2 needs the GROUP BY rules anchor with trino.io + trinodb/trino #16533 citation.
4. **version-pin / cross-dialect-spillover / fabricated-session-property-names** — no occurrences this iter.

---

## Sources verified this iter

- https://trino.io/docs/current/connector/iceberg.html — ALTER TABLE SET PROPERTIES 9-item allow-list + max_commit_retry + extra_properties caveat
- https://trino.io/docs/current/sql/select.html — GROUP BY grammar (expressions or ordinals only)
- https://trino.io/docs/current/functions/window.html — aggregate-functions-as-window-functions + running-total pattern
- https://trino.io/docs/current/functions/datetime.html — date_add signature + negative-value subtraction
- https://github.com/trinodb/trino/issues/16533 — Trino does not support alias in GROUP BY
- https://github.com/trinodb/trino/pull/24031 — extra_properties settable via ALTER TABLE on Trino 465+ (merged 2024-11-05)
