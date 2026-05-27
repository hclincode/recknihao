# Judge Report — Iteration 155, Q2

**Question topic**: Schema design (denormalization of `plan_type`/`country` into events fact table) AND tenant skew/file-layout for an 800M-row, 200-tenant events table on Iceberg.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter155-q2.md`

---

## Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Technical accuracy** (2x) | 5 | Every load-bearing technical claim verifies against official Iceberg/Parquet docs and standard lakehouse practice. See verification below. |
| **Clarity** (1x) | 5 | Structure is excellent: starts with "your call was correct," then walks through 4 numbered reasons, then directly addresses the user's exact follow-up ("what if a user changes their plan?"), then pivots cleanly to the skew problem with a clear "this is orthogonal to denormalization" framing. Postgres-vs-OLAP framing meets the reader where they are. SQL is short and labeled. |
| **Practical usefulness** (1x) | 5 | Engineer can act immediately: (a) keep current schema, (b) run the provided `CALL iceberg.system.rewrite_data_files(... strategy => 'sort' ...)` to address the file-layout asymmetry, (c) use the provided `users_dim` JOIN pattern when they truly need current-plan reporting. Spark-only label on the CALL is present, which matches production stack constraints (Trino 467 cannot execute Iceberg CALL procedures). |
| **Completeness** (1x) | 5 | Answers all three asks in the question: (1) why denormalize — 4 reasons; (2) when to regret it — 3 named cases; (3) the "user changed plan" scenario — explicitly addressed with the correct "historical truth" framing AND the JOIN-to-dim escape hatch for current-plan queries. The tenant skew sub-question is also addressed with a concrete fix. |

**Weighted average** = (5×2 + 5 + 5 + 5) / 5 = **5.00 / 5**

**Verdict**: **PASS** (≥ 4.5 threshold)

---

## What was verified correct (via WebSearch)

1. **`CALL iceberg.system.rewrite_data_files(table => ..., strategy => 'sort', sort_order => '<col> ASC NULLS LAST, ...')` syntax** — matches the official Iceberg 1.5 Spark procedures documentation exactly. Named-argument style is the recommended convention. Source: [Apache Iceberg 1.5.1 Spark Procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/).
2. **Parquet dictionary encoding for low-cardinality columns compresses to near-nothing** — verified. For categorical columns with low cardinality, the column is reduced to a small dictionary plus a stream of small integer IDs; in the extreme single-value case the output is essentially two values. The answer's "almost nothing" framing is accurate for `plan_type` (~5–10 values) and `country` (~200 values), both well under the 1 MiB row-group dictionary limit. Source: [SAI Notes: Encoding in Parquet](https://www.newsletter.swirlai.com/p/sai-notes-02-encoding-in-parquet), [Parquet Dictionary + Snappy](https://redmonk.com/rstephens/2025/06/02/parquet-dictionary-snappy/).
3. **Sort-strategy compaction narrows per-file min/max ranges and enables file pruning** — mechanically correct. Files written in sorted order have non-overlapping min/max ranges on the sort column, which is exactly what Iceberg's file pruner uses to skip files at planning time. The answer's "this file has only 'pro' and 'enterprise'" framing is the right intuition. Source: [Dremio: Compaction in Apache Iceberg](https://www.dremio.com/blog/compaction-in-apache-iceberg-fine-tuning-your-iceberg-tables-data-files/), [Cazpian: Iceberg Query Performance Tuning](https://www.cazpian.ai/blog/iceberg-query-performance-tuning-partition-pruning-bloom-filters-and-spark-configs).
4. **Denormalizing slowly-changing attributes into analytical fact tables is a recognized lakehouse best practice** — confirmed. Kimball-style dimensional modeling is explicitly endorsed for lakehouses; SCD Type 2 in a dim table + denormalized snapshot in the fact row is the standard pattern. Source: [Databricks Lakehouse Data Modeling Best Practices](https://www.databricks.com/blog/databricks-lakehouse-data-modeling-myths-truths-and-best-practices).
5. **Historical events should reflect the plan at the time of the event, not the current plan** — this is the standard analytical pattern. Point-in-time correctness is the explicit reason SCD Type 2 exists; using the value as of event-time is exactly what you want for "enterprise signups last month." The answer's framing that this is a *feature, not a bug* is correct. Source: [DataDriven: Slowly Changing Dimensions Explained](https://datadriven.io/data-modeling/slowly-changing-dimensions).

---

## Production environment fit

- `CALL iceberg.system.rewrite_data_files(...)` is explicitly labeled "Spark SQL only" — important because Trino 467 with the Iceberg connector cannot execute this CALL. Persistent gap from prior iterations (responder forgetting this label) was avoided here.
- 256 MB target file size is a reasonable default for the on-prem MinIO + Iceberg 1.5.2 stack.
- The `JOIN users_dim` pattern for current-plan queries is single-JOIN and broadcastable — fits Trino's query planner well. No incompatible tooling recommended.

---

## Errors or gaps found

None of consequence. Two very minor observations (NOT scored against):

- The answer says "4-way JOIN ... becomes a multi-stage shuffle" in motivating denormalization. For a small dim table joined to a large fact, Trino would normally broadcast the dim, not shuffle. The follow-up `users_dim` example actually relies on broadcasting. The first claim slightly overstates the JOIN cost for the specific `plan_type`/`country` case; it would be more accurate to say "JOINs against multiple dimension tables compose unpredictable plans and add latency at dashboard interactive scale." Not factually wrong (large-table JOINs do shuffle), but slightly inconsistent with the later broadcast example. Does not warrant a point deduction.
- The answer mentions "bloom filters" in passing but doesn't note that bloom filters in Iceberg are write-side and require `write.parquet.bloom-filter-enabled.column.<col>=true` table property. Out of scope for this question; no deduction.

---

## Topics touched and rubric updates

- **Schema design for analytics: denormalization, star schema basics** — PASSED 4.50 (2 qs). New question adds a 3rd angle (denormalization + SCD-style "what if a value changes later"). Running avg → (4.75 + 4.25 + 5.00) / 3 = **4.667** across 3 questions. Status: PASSED.
- **Iceberg partition design for SaaS: strategies, small-files, compaction** — PASSED 4.589 (15 qs). New question adds another angle (sort-strategy rewrite as fix for tenant skew without changing partition spec). Running avg → (4.589×15 + 5.00) / 16 = **4.615** across 16 questions. Status: PASSED.
- **Multi-tenant analytics: isolating customer data in SaaS** — PASSED 4.458 (104 qs). New question lightly touches tenant skew. Running avg → (4.458×104 + 5.00) / 105 ≈ **4.463**. Status: PASSED.
- **Lakehouse schema design: fact tables, dimension tables, denormalization** — PASSED 4.583 (3 qs). New question is on-topic (fact vs dim, denormalization tradeoffs). Running avg → (4.583×3 + 5.00) / 4 = **4.687** across 4 questions. Status: PASSED.
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — PASSED 4.602 (14 qs). New question touches `rewrite_data_files` with sort strategy. Running avg → (4.602×14 + 5.00) / 15 ≈ **4.629** across 15 questions. Status: PASSED.

---

## Resource fix recommendations

**LOW** — the JOIN cost motivation in the resource could be tightened to distinguish "broadcastable small dim JOIN (cheap)" from "multi-large-fact JOIN (expensive shuffle)." Current resource leads the responder to slightly overstate the cost of a small `plan_type`/`country` lookup JOIN. Not a correctness issue; would improve precision.

No HIGH or MEDIUM fixes warranted. This is a model-quality answer for the topic.
