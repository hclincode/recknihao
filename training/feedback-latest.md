# Judge Feedback — Iter 490

**Phase**: extended (end-of-iteration feedback only)
**Overall**: 4.156 PASS (~0.656 above 3.5 floor)
**Federation**: NOT probed this iter — 4.49944/310 row HELD per iter472-490+ directive

---

## Headline

**$snapshots SPLIT-QUOTE RECURRED FOR THE THIRD TIME (iter454 fixed, iter489 recurred, iter490 teacher re-fixed via LEADING CANONICAL diff section at line 2390 of r17, iter490 responder STILL produced split-quote form).** This is a CRITICAL REPEAT REGRESSION. The resource now has four separate blocks banning the split-quote form, but the responder is not routing to them.

**Q2 execute-guard fix CONFIRMED LANDED** — responder correctly used `{% if is_incremental() %}`.

**Q3 new TYPE ERROR** — `cardinality(element_at(map, key))` on MAP(VARCHAR,VARCHAR) is a SQL type error: `element_at` returns a scalar VARCHAR, and `cardinality()` accepts only arrays/maps, not scalars. Not load-bearing on the answer (the core element_at vs bracket advice is correct), but is a concrete SQL error that would fail if the engineer ran it.

**Q4 CLEAN** — partition evolution metadata-only, SET PROPERTIES partitioning, bucket(col,N) arg order, and Spark rewrite_data_files-vs-Trino-optimize framing all correct.

---

## Per-question breakdown

### Q1 — Iceberg snapshot history + DIFF for audit (3.375 FAIL)

**CONFIRMED REGRESSION — $snapshots SPLIT-QUOTE RECURRED.**

Responder produced: `FROM iceberg.analytics.your_table_name."$snapshots"`

This is the split-quote form. Trino parses `catalog.schema.table.column` and resolves `"$snapshots"` as a column named `$snapshots` on the table `your_table_name`. This fails with an unresolvable-identifier error.

Correct form per trino.io/docs/current/connector/iceberg.html:
```sql
SELECT * FROM iceberg.analytics."your_table_name$snapshots"
```
The WHOLE `<tablename>$snapshots` token must be inside ONE pair of double quotes.

**Resource status**: The iter490 teacher ADDED a LEADING CANONICAL diff section to r17 at line 2390, which includes:
- Step 1 showing `FROM iceberg.analytics."events$snapshots"` (correct one-quote form)
- An explicit DO-NOT-WRITE table row at line 2518 banning `iceberg.analytics.events."$snapshots"` (split-quote)
- The ban notice at line 2396: "DO NOT write the split-quote form `iceberg.<schema>.<table>."$snapshots"`"

Despite these resources being present, the responder STILL produced the wrong form. This is the THIRD RECURRENCE of this specific regression.

**Regression history**: iter454 (first fix) → iter489 (first recurrence) → iter490 teacher fixed → iter490 responder STILL WRONG.

The `FOR VERSION AS OF <bigint>` + `EXCEPT` diff pattern IS correct.
`ORDER BY committed_at DESC` column name IS correct.

- Accuracy 2.5 | Clarity 4.5 | Actionability 2.5 | Completeness 4.0
- **Q1 avg: 3.375 FAIL**
- Fab status: ONE CONFIRMED REPEAT REGRESSION — split-quote `table."$snapshots"` (load-bearing SQL error on Trino 467)

### Q2 — dbt incremental hourly only-new-rows (4.75 STRONG PASS)

**CONFIRMED FIXED — `{% if is_incremental() %}` guard correctly used.**

- `{% if is_incremental() %}` — CORRECT (NOT `{% if execute %}`)
- `WHERE occurred_at >= (SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01') FROM {{ this }})` — CORRECT pattern: subquery-wrapped MAX, COALESCE sentinel, correct watermark field
- `partitioned_by` in dbt model properties — CORRECT per dbt-trino docs (dbt-trino uses `partitioned_by` inside the `properties` config dict for incremental models)
- merge strategy + unique_key — CORRECT

The iter489 Q4 execute-guard regression (iter452/iter489 double recurrence) is CONFIRMED FIXED as of iter490. Resource r27 LEADING CANONICAL surrogate-key + incremental section (line 999) with the `{% if is_incremental() %}` pattern and the DO-NOT-WRITE banning `{% if execute %}` LANDED.

- Accuracy 5.0 | Clarity 4.5 | Actionability 5.0 | Completeness 4.5
- **Q2 avg: 4.75 STRONG PASS**
- Fab status: ZERO fabrications.

### Q3 — Trino MAP(VARCHAR,VARCHAR) key access (4.0 PASS)

**CORE ADVICE CORRECT — ONE TYPE ERROR in secondary check.**

CORRECT:
- `element_at(properties, 'key')` returns NULL for missing key (NULL-safe) — CORRECT
- `properties['key']` bracket form raises "Key not present in map" if key absent (strict) — CORRECT
- `element_at(properties, 'key') IS NOT NULL` for existence check — CORRECT
- Both forms confirmed against trino.io/docs/current/functions/map.html

TYPE ERROR (confirmed):
- Responder offered `WHERE cardinality(element_at(properties, 'some_key')) > 0` as an existence check
- `element_at` on `MAP(VARCHAR,VARCHAR)` returns `VARCHAR` (the value type, a scalar)
- `cardinality()` accepts only maps or arrays, NOT scalar types per trino.io/docs/current/functions/map.html and trino.io/docs/current/functions/array.html
- `cardinality(VARCHAR_scalar)` is a SQL type error — Trino analyzer would reject this query
- Source: trino.io/docs/current/functions/map.html confirms `element_at(map(K,V), key) -> V`; trino.io/docs/current/functions/array.html + map.html confirm `cardinality(x)` accepts array or map, not scalar

This error is secondary (presented alongside the correct `IS NOT NULL` check) but it IS a concrete SQL parse error if an engineer uses the cardinality form.

- Accuracy 3.5 | Clarity 4.5 | Actionability 3.5 | Completeness 4.5
- **Q3 avg: 4.0 PASS**
- Fab status: ONE type error — `cardinality(element_at(map, key))` on MAP(VARCHAR,VARCHAR) (SQL type error; element_at returns scalar VARCHAR, cardinality requires array/map).

### Q4 — Add partition column to existing Iceberg table (4.5 STRONG PASS)

**ALL CLAIMS CORRECT.**

- Partition evolution is metadata-only — CORRECT per trino.io/docs/current/connector/iceberg.html: "Partitioning can also be changed and the connector can still query data created before the partitioning change"
- Trino reads old+new partition specs transparently — CORRECT (dual-spec read-compat confirmed)
- `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(occurred_at)','bucket(tenant_id, 64)']` — CORRECT: `partitioning` is the Trino Iceberg SET PROPERTIES key per trino.io/docs/current/connector/iceberg.html; `bucket(col, N)` arg order confirmed correct per doc example `bucket(account_number, 10)` (column first, N second)
- spec_id 0 (old) vs 1 (new) conceptually CORRECT
- Old files don't get new pruning benefit until rewritten — CORRECT (files written under the old spec remain under the old spec until explicitly rewritten)
- Spark `rewrite_data_files` for forcing files into new partition layout — DIRECTIONALLY CORRECT: Spark's `rewrite_data_files` is the established procedure for this (iceberg.apache.org/docs/latest/spark-procedures/); Trino `EXECUTE optimize` is a bin-packing compaction that does not explicitly restructure files to a new partition spec per the documentation; evidence from trino.io search results indicates optimize "acts separately on each partition selected for optimization" (bin-pack within existing spec boundaries)

- Accuracy 4.5 | Clarity 4.5 | Actionability 4.5 | Completeness 4.5
- **Q4 avg: 4.5 STRONG PASS**
- Fab status: ZERO fabrications.

---

## Overall score

| Q | Topic | Acc | Clarity | Action | Complete | Avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg snapshot diff + $snapshots quoting | 2.5 | 4.5 | 2.5 | 4.0 | 3.375 |
| Q2 | dbt incremental guard (is_incremental re-probe) | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 |
| Q3 | Trino MAP element_at vs bracket | 3.5 | 4.5 | 3.5 | 4.5 | 4.0 |
| Q4 | Iceberg partition evolution | 4.5 | 4.5 | 4.5 | 4.5 | 4.5 |
| **Overall** | | **3.875** | **4.5** | **3.875** | **4.375** | **4.156** |

**PASS** (4.156 > 3.5, margin +0.656)

---

## Regression / fabrication inventory (iter490)

| # | Q | Class | Severity | Correct fact | Source |
|---|---|---|---|---|---|
| 1 | Q1 | REPEAT REGRESSION — $snapshots split-quote (3rd recurrence: iter454 fixed, iter489 recurred, iter490 teacher re-fixed, iter490 responder STILL wrong) | LOAD-BEARING — SQL error in Trino 467 (column-not-found) | Correct form: `iceberg.schema."tablename$snapshots"` (WHOLE token in ONE pair of double quotes) | trino.io/docs/current/connector/iceberg.html ("Metadata tables" section: `iceberg.test_db."customer_orders$snapshots"`) |
| 2 | Q3 | TYPE ERROR — `cardinality(element_at(map, key))` on MAP(VARCHAR,VARCHAR) | NON-LOAD-BEARING on core advice but is a concrete SQL type error | `element_at` on MAP(K,V) returns V (scalar); `cardinality()` accepts array/map NOT scalar; correct existence check is `element_at(map, key) IS NOT NULL` | trino.io/docs/current/functions/map.html + trino.io/docs/current/functions/array.html |

Q2: ZERO fabrications — execute-guard FIXED.
Q4: ZERO fabrications.

---

## Fix status (iter489 regressions)

| Regression | Status |
|---|---|
| $snapshots split-quote (Q3 iter489, iter454 original fix) | STILL BROKEN — iter490 teacher added LEADING CANONICAL diff section (r17 line 2390) but responder STILL produced split-quote form. Resource fix did not take at the keyword path the responder routes through. |
| {% if execute %} incremental guard (Q4 iter489, iter452 original fix) | CONFIRMED FIXED — iter490 Q2 re-probe used `{% if is_incremental() %}`. Resource r27 LEADING CANONICAL surrogate-key + incremental block (line 999) LANDED. |

---

## Topic average updates (iter490)

| Topic | Before | After | Delta | Probed |
|---|---|---|---|---|
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.4912/143 | **4.4835/144** | -0.0077 | Q1 (snapshot diff + $snapshots quoting) |
| Oracle PL/SQL→dbt/Trino migration | 4.4831/60 | **4.4875/61** | +0.0044 | Q2 (dbt incremental guard) |
| Analytical query patterns on Iceberg+Trino | 4.5318/16 | **4.5005/17** | -0.0313 | Q3 (MAP element_at type error) |
| Iceberg partition design for SaaS | 4.4946/35 | **4.4947/36** | +0.0001 | Q4 (partition evolution) |
| Trino federation / cross-source connectors | 4.49944/310 | **4.49944/310 UNCHANGED** | NOT PROBED | — |

---

## Teacher actions for iter491

### PRIMARY — ESCALATE the $snapshots split-quote recurring regression (THIRD recurrence)

This is an ESCALATION from the iter490 actions. The regression has now recurred THREE TIMES. The current resource (r17) has FOUR separate places banning the split-quote form:
1. Line 712-736: Metadata-table quoting LEADING CANONICAL section (general)
2. Line 2390: LEADING CANONICAL Snapshot DIFF section (added iter490)
3. Line 2396: Explicit "DO NOT write" inline note
4. Line 2518: DO-NOT-WRITE table row

Yet the responder STILL routes to the wrong form. This means the keyword path for "snapshot history query" / "list snapshots" is NOT routing through any of these blocks.

**The required escalation step**: make the `$snapshots` canonical form THE VERY FIRST CONTENT in r17 — ahead of any other section. The responder's keyword path for "snapshot history" / "audit trail" / "snapshot list" must hit the correct quoting form BEFORE anything else. Consider:

1. Adding a ZERO-th section at the absolute top of r17 (before §1/§2/§3 maintenance procedures) titled "CRITICAL QUOTING RULE — read this FIRST before any `$snapshots` query" with the correct form and a two-line DO-NOT-WRITE for the split-quote.

2. Also place a standalone "snapshot history query" mini-block (3-4 lines) at the TOP of the file with the correct `"tablename$snapshots"` form, so it is the FIRST match when the responder scans for "snapshot" / "history" / "list snapshots" keywords.

3. VERIFY that the keyword path "snapshot history" → r17 → finds the correct quoting before finding any old example. The existing anchors are buried mid-file; the responder may be generating the split-quote form from its base training data before reaching any DO-NOT-WRITE block.

The failing pattern is consistent: the responder writes `table_name."$snapshots"` which appears to come from a templated mental model where the `$suffix` is a quoted suffix added AFTER the table name. The cure is to make the first thing the responder reads for ANY snapshot-related query be the correct one-quote-pair form, not just a mid-file note.

### SECONDARY — Fix `cardinality(element_at(map, key))` type error

In the resource covering Trino MAP functions (likely r07 analytical-query-patterns or r23 sql-best-practices), add to the MAP access section:

```
CORRECT existence check:
  element_at(properties, 'key') IS NOT NULL

DO NOT WRITE:
  cardinality(element_at(properties, 'key')) > 0
  -- TYPE ERROR: element_at on MAP(VARCHAR,VARCHAR) returns a VARCHAR scalar.
  -- cardinality() accepts only arrays or maps, not scalars. Trino analyzer rejects this.
```

Source: trino.io/docs/current/functions/map.html (`element_at(map(K,V), key) -> V`) + trino.io/docs/current/functions/array.html (`cardinality(x) -> bigint` where x is array or map).

### SECONDARY — breadth design for iter491

- Federation 4.49944/310 row HELD per iter472-490+ directive. DO NOT probe.
- Low-count topics worth additional probes:
  - dbt sources / source freshness (4.219/3) — re-probe from a "stale source blocking downstream model" angle
  - dbt model contracts (4.1146/3) — re-probe contract.enforced runtime behavior
  - Storage tiering (4.25/2) — re-probe MinIO lifecycle approach
- Q1 $snapshots fix needs a THIRD-ANGLE re-probe at iter492 (after the escalated fix) to confirm the fix actually landed this time. Do NOT consider the iter490 re-probe sufficient evidence.

### Schedule note

5-min cadence — `delaySeconds=300`.

---

## Streak / margin status

- **89th consecutive overall PASS in extended phase.**
- Margin at 4.156 — +0.656 above 3.5 floor; Q1 3.375 dragging; Q2/Q3/Q4 all above 4.0.
- **$snapshots split-quote RECURRING REGRESSION is the primary open issue.** The iter490 teacher fix landed the LEADING CANONICAL diff section in the right place (line 2390) but the responder's keyword path is not routing through it. Need TOP-OF-FILE escalation.
- **Execute-guard (`{% if execute %}`) CONFIRMED FIXED** — iter490 Q2 is clean. No longer a concern.
- **Q3 cardinality type error** is a secondary inaccuracy — non-load-bearing on the core MAP advice but produces a SQL type error if the engineer copies the existence-check variant.
- **Citation-hygiene**: Q2 ZERO fabs (execute-guard fixed). Q4 ZERO fabs. Q1 one recurring regression. Q3 one type error (secondary).
