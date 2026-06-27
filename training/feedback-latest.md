# Iter1187 Judge Feedback

**Overall verdict: STRONG PASS** (avg **4.6875 / 5**, well above 3.5 threshold).

- **Q1 (THIN SCD-2 row) — pin-perfect** hand-rolled SCD-2 reads: COUNT(DISTINCT)+GROUP BY for ever-distinct + textbook as-of validity-window predicate for point-in-time. Sets up Q4's natural pivot ("teammate says dbt snapshot does this automatically").
- **Q2 (THIN query-perf row, suspected accuracy issue) — CORE-CORRECT BUT LEVER-#1 MISLEADING; NO-OP.** Bloom filters + sorted_by + EXECUTE optimize correctly named and production-stack-aligned. BUT lever #1 ("Parquet min/max statistics — automatic, happens on any high-cardinality VARCHAR column") OVERSTATES min/max's standalone effectiveness for an UNSORTED randomly-distributed high-cardinality column (customer_email). For unsorted email data, every file's min/max range spans nearly the whole alphabet → min/max prunes ~ZERO files. Lever #1 is internally inconsistent with lever #2 (which is needed precisely because min/max can't prune unsorted high-cardinality equality). **GREP EVIDENCE: r03 §472 + r03 §505 + r18 §1209 + r27 §2085 all consistently state min/max is useless for unsorted high-cardinality — resources are CORRECT, this is a RESPONDER FRAMING SLIP not a resource defect. NO FIX-A.**
- **Q3 — pin-perfect**. `slice(page_sequence, -5, 5)` for last-5 + `element_at(arr, -1)` for last element. Both verified at trino.io/docs/467 array.html.
- **Q4 (THIN SCD-2 row) — pin-perfect** dbt-snapshot-on-Trino+Iceberg canonical. ALL load-bearing facts verified including the `dbt_is_deleted` STRING ('True'/'False' not boolean) detail in hard_deletes='new_record' mode and the unique_key SELECT-output-column-name (alias) gotcha.

Total iter1187 score: (5.0 + 3.875 + 5.0 + 4.875) / 4 = **4.6875 / 5**.

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | dbt snapshots SCD2 (hand-rolled angle) | 5.0 | Pin-perfect. Both queries correct: COUNT(DISTINCT subscription_plan) GROUP BY customer_id for ever-distinct; `valid_from <= T AND (valid_to IS NULL OR valid_to > T)` half-open as-of for point-in-time. Threads naturally into Q4. |
| 2 | Query performance basics (non-partition filter on big Iceberg) | 3.875 | Bloom + sorted_by + EXECUTE optimize CORRECT; lever #1 (Parquet min/max "auto-skips on any high-cardinality VARCHAR") MISLEADING for unsorted column — internally inconsistent with lever #2's bloom rationale. NOT resource-sourced (resources are correct). Responder framing slip; NO FIX-A. |
| 3 | SQL best practices — slice/element_at negative-index | 5.0 | `slice(arr, -5, 5)` last-5; `element_at(arr, -1)` last; both verified at trino.io/docs/467/functions/array.html. No UNNEST+ROW_NUMBER needed. Pin-perfect. |
| 4 | dbt snapshots SCD2 (dbt-config angle) | 4.875 | `{% snapshot %}` config + 4 metadata cols + strategies + hard_deletes='new_record' adds `dbt_is_deleted` STRING 'True'/'False' (not boolean — VERIFIED at docs.getdbt.com) + unique_key SELECT-output-column-name alias gotcha + format_version=2 default. Pin-perfect. |

---

## Per-question detail

### Q1 — Hand-rolled SCD-2 dim_customer reads (THIN SCD-2 ROW LIFT)

**Score 5.0** — pin-perfect. Both halves of the multi-part SCD-2 read question hit the canonical patterns.

**(a) Distinct plans ever per customer:**
```sql
SELECT customer_id, COUNT(DISTINCT subscription_plan) AS distinct_plans_ever
FROM dim_customer
GROUP BY customer_id
```
- Each row in `dim_customer` is a (customer, plan) version slice with its own `valid_from / valid_to` window, so `COUNT(DISTINCT subscription_plan)` within a customer's group counts every distinct plan they've ever been on (across all historical versions). Correct.

**(b) Plan each customer was on exactly 90 days ago — textbook as-of:**
```sql
SELECT customer_id, subscription_plan
FROM dim_customer
WHERE valid_from <= CURRENT_TIMESTAMP - INTERVAL '90' DAY
  AND (valid_to IS NULL OR valid_to > CURRENT_TIMESTAMP - INTERVAL '90' DAY)
```
- The half-open (inclusive `valid_from`, exclusive `valid_to`) form is the standard SCD-2 convention: a row that closed exactly at T is NOT returned, and the row that opened exactly at T IS — so `valid_to of predecessor = valid_from of successor` yields exactly one row per customer at any point in time.
- `NULL` valid_to (current row) correctly treated as +infinity.
- Returns "exactly one version per customer at that point" — correct under the standard SCD-2 non-overlapping-windows invariant.
- Valid Trino 467 INTERVAL syntax verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) (CURRENT_TIMESTAMP - INTERVAL '90' DAY).

**Threading:** the hand-rolled `valid_from / valid_to` shape is structurally identical to dbt's `dbt_valid_from / dbt_valid_to` (just without the `dbt_` prefix and the auto-maintenance), which sets up Q4's "your teammate is right, dbt snapshot maintains this exact shape automatically" pivot.

Scoring breakdown:
- Tech: 5.0/5 — both queries correct in Trino 467
- Clar: 5.0/5 — explicit explanation of the half-open as-of pattern and NULL = current
- Practical: 5.0/5 — engineer can copy-paste both queries
- Complete: 5.0/5 — both sub-questions answered

---

### Q2 — Non-partition filter on 200M-row Iceberg orders (SUSPECTED ACCURACY ISSUE)

**Score 3.875** — core actionable answer correct (bloom filters + sorted_by + EXECUTE optimize), but **lever #1 over-credits min/max statistics** for unsorted high-cardinality columns.

**Responder's three levers:**
1. **Parquet column min/max statistics** — "automatic, happens on any high-cardinality VARCHAR column, skips files whose min/max range proves no matching email." ← **MISLEADING for the question's scenario**
2. **Parquet bloom filters** via Spark `ALTER TABLE ... SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.customer_email'='true', ...)` — Trino reads them automatically. ← Correct + production-aligned (Spark form fits prod_info.md ingestion stack)
3. **sorted_by on write + EXECUTE optimize** — clusters files by email → sharpens per-file min/max → file skipping kicks in. ← Correct

**The lever #1 problem.** For an unsorted, randomly-distributed high-cardinality VARCHAR column (which is the default for `customer_email` unless the table is clustered by it), EVERY data file's min/max range for `customer_email` spans nearly the entire alphabet — because emails get scattered randomly across files at write time. The min/max-based file pruner sees that the predicate value falls within every file's [min, max] range, so it skips essentially ZERO files. Min/max is only effective AFTER lever #3's sorting — meaning lever #1 is not an independent automatic win but a *consequence* of lever #3. The responder's framing is internally inconsistent with lever #2's own rationale ("min/max can't prune for high-cardinality equality, that's why bloom helps").

**Source-classification grep evidence — RESOURCES ARE CORRECT, this is a responder framing slip:**

| Resource | Line | Quote |
|---|---|---|
| `resources/03-columnar-storage.md` | §472 LEADING CANONICAL | "Bloom filters pay off on HIGH-cardinality columns (UUIDs, event_id, user_id, session_id, trace_id) where min/max stats are useless because every file's range covers the lookup value." |
| `resources/03-columnar-storage.md` | §505 | "Without a sort order, event_id values are scattered randomly across every row group in every file — the row group min/max for event_id covers basically the full ID range, so the pruner can't skip anything." |
| `resources/18-query-performance-regression.md` | §1209 | "Iceberg's manifest min/max can't prune files because every file's range covers the wanted value." |
| `resources/27-oracle-plsql-to-dbt-trino.md` | §2085 | "Random UUIDs defeat min/max pruning — every file's UUID range covers the full UUID space; no file-skipping is possible on a UUID filter." |

The resources consistently and correctly explain that min/max prunes ~nothing for unsorted high-cardinality. The responder's "lever #1 auto-skips on any high-cardinality VARCHAR" claim is NOT sourced from any resource — it's a responder synthesis error / over-confident framing. **NO FIX-A** (per `feedback_new_card_over_attracts_adjacent.md` — adding a re-defang card to already-correct r03 §472/§505 risks over-attracting adjacent Qs; per `feedback_responder_overwarning_folklore.md` adjacent family, this is responder framing not a teaching gap).

**Production-stack alignment of bloom filter syntax (verified):**
- Trino 467 has `parquet_bloom_filter_columns = ARRAY[...]` at **CREATE TABLE** time only.
- `ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns` is **469+ ONLY** — verified [trinodb/trino PR #24573](https://github.com/trinodb/trino/pull/24573) released Jan 27, 2025 in 469.
- The responder gave the **Spark `TBLPROPERTIES` form** (`write.parquet.bloom-filter-enabled.column.customer_email`) which IS the right routing for the production stack — per `prod_info.md`, Spark is the ingestion engine, so Spark writes the files and Trino reads them. Production-stack-aligned, not a Trino-form omission.

**Why the answer still gets engineer to the right action.** Despite lever #1's overstatement, levers #2 (bloom) and #3 (sorted_by + optimize) collectively give the engineer the correct file-pruning toolkit for unsorted high-cardinality equality. The internal inconsistency may even prompt a careful reader to ask "wait, if #1 already auto-skips, why do I need #2?" — leading them to the right mental model. But a beginner reading verbatim could walk away thinking "maybe I just need to wait for min/max to kick in" and not act on the actual levers (bloom write-config + sort+optimize).

Verifications (trino.io + iceberg):
- `parquet_bloom_filter_columns` Trino 467 CREATE TABLE property: verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)
- `sorted_by` + `ALTER TABLE ... EXECUTE optimize` write-time-only behavior: verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)
- Spark Iceberg `write.parquet.bloom-filter-enabled.column.<col>` property: verified at [iceberg.apache.org/docs/latest/configuration/](https://iceberg.apache.org/docs/latest/configuration/)

Scoring breakdown:
- Tech: 3.5/5 — levers #2/#3 correct; lever #1 over-credits min/max for unsorted high-cardinality
- Clar: 4.0/5 — clear writeup but internally inconsistent
- Practical: 4.0/5 — engineer still arrives at bloom + sort + optimize as actionable
- Complete: 4.0/5 — covers the lever space; could mention parquet_bloom_filter_columns CREATE TABLE Trino-native form is also available in 467 (alongside the Spark form correctly given)

---

### Q3 — slice() with negative start for last-N tail

**Score 5.0** — pin-perfect.

```sql
SELECT slice(page_sequence, -5, 5) AS last_5_pages FROM user_sessions
```
- `slice(x, start, length) → array` verified at [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html): "Subsets array x starting from index start (or starting from the end if start is negative) with a length of length."
- `start = -5` counts 5 from the end; `length = 5` returns those 5 → last-5 in original order. Correct.
- For arrays with fewer than 5 elements, Trino's slice clamps to available elements (returns the whole array, no error) — de-facto behavior, consistent with the responder's claim.
- `element_at(arr, -1)` returns the last scalar — verified at [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html): "If index < 0, element_at accesses elements from the last to the first."
- Responder correctly defangs the UNNEST+ROW_NUMBER over-complication ("no UNNEST+ROW_NUMBER needed").

Scoring breakdown:
- Tech: 5.0/5 — both `slice(-5, 5)` and `element_at(-1)` verified against docs
- Clar: 5.0/5 — clear explanation of negative-index semantics + clamping behavior
- Practical: 5.0/5 — engineer can copy-paste the one-liner
- Complete: 5.0/5 — primary slice form + element_at last-element shortcut both covered

---

### Q4 — dbt snapshot end-to-end on Trino + Iceberg (THIN SCD-2 ROW LIFT)

**Score 4.875** — pin-perfect on all load-bearing facts.

Responder's load-bearing facts (all verified at [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots)):

**(a) Block + config:**
```jinja
{% snapshot dim_customer_snapshot %}
{{ config(
    target_schema='analytics',
    unique_key='customer_id',
    strategy='timestamp',
    updated_at='updated_at'
) }}
SELECT customer_id, subscription_plan, ..., updated_at
FROM {{ source('raw', 'customers') }}
{% endsnapshot %}
```
- `{% snapshot %}` block + `{{ config() }}` form remains valid in dbt 1.9+ (alongside the new YAML config).

**(b) 4 metadata columns** — `dbt_scd_id`, `dbt_valid_from`, `dbt_valid_to`, `dbt_updated_at` — all correct per docs.

**(c) Current vs point-in-time:**
- Current rows: `WHERE dbt_valid_to IS NULL` — correct (no `dbt_is_current` column exists)
- Point-in-time: `WHERE dbt_valid_from <= T AND (dbt_valid_to IS NULL OR dbt_valid_to > T)` — structurally identical to Q1's hand-rolled form, threading the two answers together.

**(d) hard_deletes='new_record' (dbt 1.9+)** — adds `dbt_is_deleted` column.
- **VERIFIED at docs.getdbt.com: "A string value indicating if the record has been deleted. (True if deleted, False if not deleted)."**
- Responder's `VARCHAR 'True'/'False'` is exactly correct — NOT a boolean despite the column name suggesting one. This is a subtle accuracy point that the responder nailed.
- Default behavior (no `hard_deletes` config) does NOT detect deletes — correct per docs.

**(e) unique_key SELECT-output-column alias gotcha** — VERIFIED at docs.getdbt.com: `unique_key` references the SELECT output column name; if you alias a column in your SELECT, use the alias. Responder calls this "the #1 gotcha" which matches the docs prominence.

**(f) format_version=2 for MERGE** — correct. Iceberg format_version=2 supports row-level operations (MERGE/DELETE/UPDATE) which dbt snapshots require. Recent dbt-trino defaults snapshots to v2.

**(g) strategies** — `'timestamp'` requires `updated_at` column; `'check'` uses `check_cols` list (or `'all'`) — both verified at docs.

Scoring breakdown:
- Tech: 5.0/5 — every load-bearing fact verified including the dbt_is_deleted STRING (not boolean) subtlety
- Clar: 4.75/5 — heavy detail but well-structured; the `dbt_is_deleted` boolean-vs-string nuance well-flagged
- Practical: 5.0/5 — engineer can copy-paste the snapshot block and use the predicates
- Complete: 4.75/5 — covers config + metadata cols + strategies + hard_deletes + format_version + unique_key alias gotcha; minor: could mention `target_database` for cross-catalog snapshots and that Trino-side snapshots run as MERGE INTO under the hood

---

## Source classification summary

| Q | Defect class | Resource fix? |
|---|---|---|
| Q1 | No defect | No |
| Q2 | Responder framing slip — lever #1 over-credits min/max for unsorted high-cardinality column. Resources r03 §472 + r03 §505 + r18 §1209 + r27 §2085 already correctly explain the unsorted-high-card→min/max-useless fact. | **NO FIX-A** — adding re-defang risks `feedback_new_card_over_attracts_adjacent.md`; per `feedback_responder_overwarning_folklore.md` adjacent family, framing slip absorbed by 27-question cushion. |
| Q3 | No defect | No |
| Q4 | No defect | No |

---

## Rubric updates

- **dbt snapshots SCD2 row**: 4.1549 / 19 → 4.2294 / 21 (+0.0745, margin +0.7294). Tested from 2 structurally different angles (hand-rolled SCD-2 reads vs dbt-snapshot config) within same iteration. No longer thinnest required-topic.
- **Query performance basics row**: 4.1869 / 27 → 4.1758 / 28 (-0.0111, margin still +0.6758). Stays in thin band but PASSED unchanged.

---

## Watches

- **No open FIX-A watch.** All recent watches (iter1179, iter1184, iter1185, iter1186) closed on first re-probe.
- **No new FIX-A from iter1187.** Q2 lever-#1 over-credit is responder framing not resource-sourced; no resource teaches the wrong claim. NO-OP.

Next-iteration recommendation: continue breadth probing. The thinnest required-topic is now **storage-tiering** (4.1779 / 13) followed by **query-perf-basics** (4.1758 / 28) and **dbt-snapshots-SCD2** (4.2294 / 21). Q2 re-probe in 5-10 iterations under a structurally different non-partition-equality framing (e.g., session_id lookup on events, or trace_id lookup) to confirm the lever-#1 over-credit was a one-off and not a recurring responder pattern.
