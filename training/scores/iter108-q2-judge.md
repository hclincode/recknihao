# Iter 108 Q2 — Judge Verdict

**Topic**: Postgres-to-Iceberg ingestion
**Question summary**: New nullable column added in Postgres broke incremental Spark→Iceberg job. How to make Iceberg auto-evolve, and does incremental Spark vs Debezium CDC change the answer?

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Core direction is right (mergeSchema for Spark, allow-field-addition for debezium-server-iceberg) but omits the **required** `write.spark.accept-any-schema=true` table property. Without it, `mergeSchema` alone does NOT trigger automatic ADD COLUMNS — Spark fails the write before Iceberg can evolve. This is a load-bearing omission for the recommended fix. |
| Beginner clarity | 4.5 | Strong structure (numbered solutions, comparison table, prevention checklist). Jargon is explained. The "why Iceberg didn't auto-evolve" framing is excellent for a newcomer. |
| Practical applicability | 3.5 | Fits the on-prem stack (Spark 3 + Iceberg 1.5.2 + Hive Metastore). However, the recommended snippet **will not work as written** in production because of the missing ALTER TABLE step. Engineer would copy-paste, retry, still fail. Penalty applied. |
| Completeness | 4.0 | Covers JDBC append, MERGE INTO, debezium-server-iceberg sink, and Spark Structured Streaming consumer. Comparison table covers freshness, deletes, ops complexity. Missing: (a) the `accept-any-schema` prerequisite, (b) caveat that schema evolution only handles ADDS — type changes, renames, drops still break, (c) NOT NULL columns without defaults still break even with mergeSchema. |
| **Weighted average** | **3.875** | Just above pass threshold; failure on accuracy is significant. |

---

## Verdict

The answer reaches a passing score but has a **critical accuracy gap**: it presents `df.writeTo("...").mergeSchema(True).append()` as a complete fix, omitting the mandatory `ALTER TABLE ... SET TBLPROPERTIES('write.spark.accept-any-schema'='true')` step that Iceberg requires for `mergeSchema` to actually trigger column addition. Per the official Iceberg docs (https://iceberg.apache.org/docs/1.5.0/spark-writes/) and the rdblue PR that added the feature, both the table property AND the writer option are required — neither is sufficient on its own. An engineer following this answer literally will get the same schema-mismatch error and stay paged.

The framework (three patterns, comparison table, prevention checklist) is genuinely useful. The CDC half (debezium-server-iceberg with `allow-field-addition=true`) is correctly described and verified. The distinction between the debezium-server sink (auto-evolves) and a Spark Structured Streaming consumer of Debezium events (does not, fall back to mergeSchema) is technically sharp and correct. JDBC re-reads picking up new columns via `SELECT *` is correct — Spark introspects the JDBC ResultSetMetaData per read, no schema cache issue.

The syntax `.mergeSchema(True)` as a chained method is also non-idiomatic — the documented API is `.option("mergeSchema", "true")`. This may work as a Pythonic alias in some Iceberg/Spark bindings but the official, portable form is `.option(...)`. Minor.

---

## What was verified correct (via WebSearch)

1. **Iceberg auto-evolves on ALTER TABLE ADD COLUMNS, returning NULL for old Parquet files** — confirmed via iceberg.apache.org spark-writes docs. Old files are not rewritten; reads project NULL.
2. **`debezium.sink.iceberg.allow-field-addition=true` is a real property** in the memiiso/debezium-server-iceberg sink — confirmed via the project's docs/iceberg.md on GitHub. When true, new source columns are auto-added to the Iceberg destination.
3. **Spark JDBC re-reads pick up new columns via `SELECT *`** — Spark introspects via `ResultSetMetaData` on each `spark.read.jdbc(...)` call. No persistent schema cache across job runs. Confirmed via Spark JDBC docs.
4. **Spark Structured Streaming Debezium consumer does NOT inherit `allow-field-addition`** — that property is sink-specific. A Spark consumer must use `mergeSchema` (plus `accept-any-schema`) on its own writes. Correctly distinguished in the answer.
5. **`MERGE INTO` in Spark+Iceberg supports schema evolution** — partially confirmed, though Iceberg issue #5556 notes mergeSchema on MERGE INTO has historically been a feature request. Behavior in 1.5.2 generally works for the documented case in the answer.

---

## Errors and gaps

### HIGH priority
- **Missing required table property `write.spark.accept-any-schema=true`**. The answer presents `mergeSchema(True)` as sufficient; it is not. The fix the engineer will paste from this answer will fail the same way. Must include:
  ```sql
  ALTER TABLE iceberg.analytics.subscriptions
  SET TBLPROPERTIES ('write.spark.accept-any-schema'='true');
  ```
  And ideally note that this should be set at table creation time for all incrementally-loaded tables, not reactively after a paging incident.

### MEDIUM priority
- **Schema evolution only covers ADD COLUMN**. The answer implies broad schema-evolution coverage. In reality: column renames in Postgres = breakage (Iceberg sees it as drop+add and loses column identity); type widening is limited; column drops can break downstream queries. A nuance paragraph would prevent the next paging incident.
- **NOT NULL columns without defaults still break.** The question specifies a nullable column, so the answer is correct for that case, but the engineer will eventually face the non-nullable case and the answer offers no warning.
- **Syntax `.mergeSchema(True)` vs `.option("mergeSchema", "true")`**: the official documented API is the `.option()` form. The chained method form is not in the Iceberg Spark API surface. Engineer may get `AttributeError`.

### LOW priority
- **MERGE INTO schema evolution behavior is more fragile than `.append()`** in some Iceberg versions (issue #5556 history). Worth a footnote.
- **No mention of detection/alerting** for upstream Postgres schema changes (e.g., subscribing to migration PRs, schema-diff CI check). Listed as bullet 4 in prevention but very briefly.
- **No mention of Iceberg snapshot rollback** as the emergency recovery if a schema evolution attempt corrupts the table — and that 7-day default retention may have expired by the time the on-call notices.

---

## Resource fix recommendations

| File | Change | Priority |
|---|---|---|
| `resources/13-postgres-to-iceberg-ingestion.md` | Add a clearly-labeled subsection titled "Required table property for mergeSchema to work" with the `ALTER TABLE ... SET TBLPROPERTIES('write.spark.accept-any-schema'='true')` step. Emphasize that mergeSchema alone is insufficient. Recommend setting at table-create time as a default. | HIGH |
| `resources/13-postgres-to-iceberg-ingestion.md` | Add a "What schema evolution does NOT auto-handle" subsection: renames, type changes beyond Iceberg's widening rules, drops, NOT NULL without default. | MEDIUM |
| `resources/13-postgres-to-iceberg-ingestion.md` | Correct any `.mergeSchema(True)` chained-method examples to use `.option("mergeSchema", "true")`. Grep for the literal `mergeSchema(True)` and replace. | MEDIUM |
| `resources/13-postgres-to-iceberg-ingestion.md` | Add a one-paragraph note on `MERGE INTO` + mergeSchema interaction caveats (Iceberg issue #5556 history). | LOW |

---

## Updated topic state

- Prior topic running avg: **4.487 across 92 questions**
- This question score: **3.875**
- New running avg: (4.487 × 92 + 3.875) / 93 = (412.804 + 3.875) / 93 = 416.679 / 93 ≈ **4.480 across 93 questions**
- Status: **PASSED** (>= 3.5 threshold), but the accuracy gap on the `accept-any-schema` prerequisite is a recurring risk worth a resource fix before more iterations cement the incomplete pattern.

---

## Sources verified

- [Apache Iceberg Spark Writes (1.5.0)](https://iceberg.apache.org/docs/1.5.0/spark-writes/)
- [Apache Iceberg Writes (latest)](https://iceberg.apache.org/docs/latest/spark-writes/)
- [Iceberg PR #4154 — Spark 3.2 Support mergeSchema option on write](https://github.com/apache/iceberg/pull/4154)
- [Iceberg Issue #8005 — Document MergeSchema, AcceptAnySchema and Schema Evolution Code](https://github.com/apache/iceberg/issues/8005)
- [debezium-server-iceberg docs/iceberg.md](https://github.com/memiiso/debezium-server-iceberg/blob/master/docs/iceberg.md)
- [Spark 3.5.6 JDBC To Other Databases](https://spark.apache.org/docs/3.5.6/sql-data-sources-jdbc.html)
- [Iceberg Issue #5556 — Support mergeSchema option when using Spark MERGE INTO](https://github.com/apache/iceberg/issues/5556)
