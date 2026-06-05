# Judge Feedback — Iter 476 (end-of-iteration, extended phase)

## Verdict: PASS — 4.0156 overall (75th consecutive extended-phase PASS, softest margin in many iters)

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Oracle TRUNC(num,2) + TO_NUMBER → Trino | 2.50 | 4.00 | 4.00 | 2.50 | **3.25** | PASS (soft — FAB) |
| Q2 | Trino MERGE multiple WHEN MATCHED AND + conditional DELETE | 2.75 | 4.25 | 4.25 | 2.75 | **3.50** | PASS (soft — FAB) |
| Q3 | Parquet dictionary encoding + row-group min/max stats | 4.75 | 4.50 | 4.75 | 4.50 | **4.625** | STRONG PASS |
| Q4 | Hourly batch vs Debezium CDC for SaaS analytics | 4.75 | 4.50 | 4.75 | 4.75 | **4.6875** | STRONG PASS |

**Overall avg: 4.0156** — PASS by 0.52 above the 3.5 floor, but the softest margin since the 4.328 of iter474. Q1 + Q2 each PASS by a hair (≤ 0.50 above floor) because of two confirmed **cross-dialect-spillover fabrications on the SAME topic (Oracle migration)**.

---

## Fabrication audit — TWO load-bearing cross-dialect-spillover fabs

### Fab #1 (Q1) — `TRUNC` used as a Trino function name in the Oracle→Trino rewrite

**Responder wrote** (Trino rewrite block): `CAST(TRUNC(12.3456 * 100) / 100 AS DECIMAL(10,2))`

**Reality**: `TRUNC` is the **Oracle** function name. Trino has only the **lowercase** `truncate(x)` function, **1-argument form only** (returns x rounded to integer by dropping digits after decimal point). There is no `TRUNC` (uppercase or otherwise) in Trino's function registry. Running the responder's example produces:

```
Function 'trunc' not registered
```

**Correct Trino rewrite** (to truncate to 2 decimal places):
```sql
CAST(truncate(12.3456 * 100) / 100 AS DECIMAL(10,2))
-- or simpler if HALF_UP rounding is acceptable:
ROUND(12.3456, 2)
```

**Class**: cross-dialect-spillover (Oracle `TRUNC` keyword presented as Trino).

**Source**: https://trino.io/docs/current/functions/math.html — "truncate(x) → [same as input]: Returns x rounded to integer by dropping digits after decimal point." Single signature. No `TRUNC`. No 2-arg form.

**Partial mitigation**: The responder ALSO offered `ROUND(value, 2)` as an alternative, so an attentive engineer has a working escape hatch. But the lead-line example fails at parse time. The TO_NUMBER → CAST / TRY_CAST mapping in the same answer is **correct** (verified at https://trino.io/docs/current/functions/conversion.html).

### Fab #2 (Q2) — `UPDATE SET *` / `INSERT *` star shorthand used in Trino MERGE example

**Responder wrote** (production CDC example):
```sql
WHEN MATCHED AND s.op = 'd' THEN DELETE
WHEN MATCHED AND s.op IN ('u','c','r') THEN UPDATE SET *
WHEN NOT MATCHED AND s.op IN ('c','r','u') THEN INSERT *
```

**Reality**: `UPDATE SET *` and `INSERT *` are **Spark / Delta Lake / Databricks** MERGE shorthand. Trino MERGE syntax per docs requires **explicit column lists**:

```
WHEN MATCHED [ AND condition ] THEN UPDATE SET ( column = expression [, ...] )
WHEN NOT MATCHED [ AND condition ] THEN INSERT [ ( column [, ...] ) ] VALUES ( expression [, ...] )
```

An engineer copy-pasting the CDC pattern gets a parse error like `mismatched input '*'`.

**Class**: cross-dialect-spillover (Databricks / Delta Lake star MERGE shorthand presented as Trino).

**Source**: https://trino.io/docs/current/sql/merge.html — All examples use explicit column lists in both UPDATE SET and INSERT. No star shorthand documented or supported.

**Partial mitigation**: The **upstream clean example in the same answer** does show the correct explicit-column form, so an attentive engineer has a working template to compare against. But the "production CDC" example specifically marketed as production-ready is broken as written.

### Correct claims confirmed in Q2

- Trino MERGE supports multiple `WHEN MATCHED [AND condition]` branches: **CORRECT** ("an arbitrary number of WHEN clauses").
- First-match-wins ordering: **CORRECT** ("For each source row, the WHEN clauses are processed in order. Only the first matching WHEN clause is executed.").
- DELETE branch must come first when DELETE and UPDATE conditions could both match: **CORRECT** (logical consequence of first-match-wins).
- A WHEN MATCHED branch can be `THEN DELETE`: **CORRECT**.
- Boolean conditions on AND clauses: **CORRECT**.

### Q3 + Q4 — zero fabrications

- Q3 Parquet mechanisms (row-group min/max/null-count stats for row-group skipping; dictionary encoding for low-to-medium cardinality columns; combined skip + compressed scan effect): all directionally correct per Parquet spec and verified against the standard guidance. Illustrative numbers fine.
- Q4 batch-vs-CDC: hourly batch sufficient for most dashboards, CDC justified only for sub-5-min freshness / hard-delete accuracy / already-running-Debezium, complexity stack (Debezium + Kafka + streaming + replication-slot management + WAL monitoring) accurate, replication-slot disk-fill hazard real (well-documented Postgres failure mode), "full refresh → incremental batch → CDC last" progression sound, soft-deletes + updated_at watermark = standard incremental pattern. Excellent practical SaaS guidance.

---

## Topic average updates

| Topic | Before | After | Delta | Notes |
|---|---|---|---|---|
| Oracle PL/SQL → dbt/Trino migration | 4.5580 / 49 | **4.5116 / 51** | -0.0464 | Q1 (3.25) + Q2 (3.5) both well below topic avg; two fabs in one iter is a real signal; still PASSED, margin shrinking |
| Column-oriented storage | 4.4926 / 14 | **4.5014 / 15** | +0.0088 | Q3 (4.625) above topic avg |
| Real-time vs batch | 4.7501 / 8 | **4.7431 / 9** | -0.0070 | Q4 (4.6875) essentially at topic avg |
| Federation | 4.49944 / 310 | **4.49944 / 310** | unchanged | NOT probed this iter (per directive) |

No federation probe — federation 4.49944 / 310 row sits 0.0006 below 4.5 raised threshold. Held per iter472–475 judge directive.

---

## Teacher actions for iter477 — PRIMARY: fix both Oracle-migration cross-dialect fabs

### PRIMARY EDIT 1 — r27 (Oracle PL/SQL → dbt/Trino migration) function-mapping table — TRUNC fix

**Location**: r27 Oracle-to-Trino function mapping (the per-function rewrite table). Find the row for `TRUNC` (Oracle TRUNC for numbers, dates, both). RECONCILE in place — replace, do not append (per the reconcile-don't-append directive).

**Required content**:
1. Map Oracle `TRUNC(n, d)` (numeric, d decimal places) → Trino canonical forms:
   - Preferred: `ROUND(n, d)` — note this is HALF_UP rounding semantics, NOT truncation, so use only when HALF_UP is acceptable.
   - Exact truncation: `truncate(n * power(10, d)) / power(10, d)` — using **lowercase** `truncate`, 1-arg form.
2. Map Oracle `TRUNC(n)` (1-arg, integer truncation) → Trino `truncate(n)` (lowercase, 1-arg).
3. Map Oracle `TRUNC(date, 'fmt')` (date truncation, e.g., `TRUNC(d, 'MM')` → first day of month) → Trino `date_trunc('month', d)` — note this is a **different function name** (`date_trunc`, not `truncate`).

**NEW DO-NOT-WRITE block at the end of the TRUNC mapping row**:
- BAN `TRUNC(...)` in any Trino rewrite — Oracle name, not Trino. Trino function is **lowercase** `truncate`.
- BAN 2-arg `truncate(n, d)` — does not exist on Trino; only 1-arg `truncate(x)`.
- BAN `TRUNCATE` (uppercase) used as a function — Trino has lowercase `truncate(x)` math function; uppercase `TRUNCATE TABLE` is a different SQL statement (table-clear DDL).
- KEYWORD-TRAP phrase: "Anyone who writes `TRUNC(x, 2)` for Trino is using Oracle syntax — Trino has `truncate(x)` 1-arg only; to truncate to 2 decimals use `truncate(x*100)/100` or `ROUND(x, 2)`."

Source to cite verbatim in the resource: https://trino.io/docs/current/functions/math.html ("truncate(x) → [same as input]: Returns x rounded to integer by dropping digits after decimal point.").

### PRIMARY EDIT 2 — r27 (Oracle migration) MERGE-translation section — star-shorthand fix

**Location**: r27 Oracle MERGE → Trino MERGE translation section. RECONCILE in place — replace, do not append.

**Required content**:
1. Keep the existing correct explicit-column WHEN MATCHED / WHEN NOT MATCHED examples.
2. ADD a CDC-pattern worked example using **explicit column lists**:
   ```sql
   MERGE INTO target t
   USING source s
   ON t.id = s.id
   WHEN MATCHED AND s.op = 'd' THEN DELETE
   WHEN MATCHED AND s.op IN ('u', 'c', 'r') THEN UPDATE SET
       col1 = s.col1,
       col2 = s.col2,
       col3 = s.col3,
       updated_at = s.updated_at
   WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT (id, col1, col2, col3, updated_at)
       VALUES (s.id, s.col1, s.col2, s.col3, s.updated_at)
   ```
3. Add a one-line note: "For wide tables with many columns, generate the column list with a dbt macro or `INFORMATION_SCHEMA.COLUMNS` query — there is no star shorthand."

**NEW DO-NOT-WRITE block in the MERGE section**:
- BAN `UPDATE SET *` — Spark / Delta Lake / Databricks MERGE shorthand, NOT supported on Trino. Use explicit `UPDATE SET col1 = s.col1, col2 = s.col2, ...`.
- BAN `INSERT *` — Spark / Delta Lake / Databricks MERGE shorthand, NOT supported on Trino. Use explicit `INSERT (col1, col2, ...) VALUES (s.col1, s.col2, ...)`.
- BAN `INSERT VALUES *` — also Spark-ism, not Trino.
- BAN `WHEN MATCHED THEN UPDATE` with no SET clause — required.
- KEYWORD-TRAP phrase: "Anyone who writes `UPDATE SET *` or `INSERT *` is using Spark/Delta/Databricks MERGE syntax — Trino MERGE requires explicit column lists for every UPDATE SET assignment and every INSERT VALUES clause."

Confirm these correct claims are preserved (do not regress):
- Multiple WHEN MATCHED [AND condition] branches: SUPPORTED.
- First-match-wins ordering.
- DELETE branch first when DELETE + UPDATE conditions overlap.
- Any boolean condition on AND clauses.

Source to cite verbatim: https://trino.io/docs/current/sql/merge.html ("MERGE supports an arbitrary number of WHEN clauses ... For each source row, the WHEN clauses are processed in order. Only the first matching WHEN clause is executed.").

### SECONDARY — breadth design for iter477 4-question pack

Recommended angle distribution:
1. **Oracle-migration TRUNC re-probe** — different angle (e.g., TRUNC on dates: `TRUNC(d, 'MM')` → `date_trunc('month', d)`) to confirm EDIT 1 landed AND the date variant doesn't get conflated with the numeric variant.
2. **Oracle-migration MERGE re-probe** — different angle (e.g., conditional UPDATE with no DELETE branch, or MERGE with UPDATE-only path on Iceberg) to confirm EDIT 2 landed AND the star-shorthand ban holds.
3. **One non-Oracle-migration breadth probe** — pick from low-count topics (dbt model contracts 4.1146/3 — still thin; dbt sources/freshness 4.219/3 — thin; storage tiering 4.25/2 — thin) for distribution.
4. **One wildcard breadth probe** — Iceberg maintenance, query perf basics, or columnar storage from a fresh angle.

**No dedicated federation probe** — federation row stays at 4.49944/310 per directive.

### Fab-class watch for iter477

- **Cross-dialect-spillover (HEIGHTENED watch this iter)**: TWO confirmed in one iter on the same topic. Watch for any Oracle, Spark, Delta, Databricks, BigQuery, Snowflake, or Postgres function/syntax appearing in a Trino rewrite without an explicit dialect tag.
- **Version-pin**: hold Trino 467 + Iceberg 1.5.2 + dbt-trino; no 468+ or Iceberg-v3 features.
- **Trino-internal-clause conflation**: preserve EXECUTE-vs-CALL discipline (Trino EXECUTE vs Spark CALL).
- **Fabricated-capability-restriction**: don't invent new restrictions (the multiple-WHEN-MATCHED-AND and first-match-wins claims were CORRECT — don't over-correct in fix and accidentally remove them).
- **Fabricated session-property names**: N/A this iter (no session-property probes).

### Reconcile, don't append

EDITS 1 and 2 must **replace** the existing TRUNC and MERGE content in r27 — not append fresh sibling sections. The responder may still cite the older / wronger content if it remains. Per the established discipline: when two contradictory blocks exist in the same file, the responder may surface either; one FAIL > one PASS at 250+ datapoints.

### Citation-hygiene streak status

**BROKEN** at iter476 with two load-bearing fabs on Q1 and Q2. The pattern (both fabs are cross-dialect spillovers, both on Oracle migration topic, both reach for a SIBLING-dialect form) suggests the r27 Oracle-migration resource lacks explicit cross-dialect anti-spillover guardrails for these specific function/syntax forms. The fix is narrow (two edits to r27) but must include the keyword-trap phrasing so the next responder pass sees the canonical Trino form when scanning for `TRUNC` or `SET *`.
