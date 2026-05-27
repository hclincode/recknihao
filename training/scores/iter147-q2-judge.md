# Iter 147 Q2 — Judge Report

**Question topic**: Iceberg ALTER TABLE ADD COLUMN on a live production table read by Trino and a Spark batch job. Concerns: do old Parquet files break, will Spark fail on schema mismatch, what is the safe procedure.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter147-q2.md`

---

## Overall verdict

**Weighted average score: 4.80 / 5 — PASS** (threshold 4.5)

Calculation: (Tech 4.8 × 2 + Clarity 4.9 + Practical 4.8 + Completeness 4.7) / 5 = (9.6 + 4.9 + 4.8 + 4.7) / 5 = 24.0 / 5 = **4.80**

---

## Per-dimension scores

### Technical accuracy — 4.8 / 5 (weighted 2x)

Every load-bearing claim is verified against the Apache Iceberg spec / evolution docs.

**Verified correct claims**:

| Claim in answer | Verification | Source |
|---|---|---|
| Iceberg tracks columns by numeric field ID, not name/position | Confirmed: "Iceberg uses unique IDs to track each column in a table" | [Iceberg Evolution docs](https://iceberg.apache.org/docs/1.5.1/evolution/) |
| ADD COLUMN is metadata-only, no Parquet rewrite, completes in milliseconds | Confirmed: "Iceberg schema updates are metadata changes, so no data files need to be rewritten" | [Iceberg Evolution docs](https://iceberg.apache.org/docs/latest/evolution/) |
| Old files return NULL for columns added later | Confirmed: "Added columns never read existing values from another column" — the field ID is absent from old files, so reads return NULL | [Iceberg Evolution docs](https://iceberg.apache.org/docs/1.5.1/evolution/) |
| Added columns are always nullable/optional in Iceberg | Confirmed: "When an optional field is added, the defaults may be null and should be explicitly set." Iceberg cannot enforce NOT NULL on added columns because old rows genuinely lack the value. | [Iceberg spec](https://iceberg.apache.org/spec/), [Presto Issue #20618](https://github.com/prestodb/presto/issues/20618) |
| Spark uses snapshot isolation; in-flight jobs keep reading their original snapshot | Confirmed: "Readers use the snapshot that was current when they load the table metadata and are not affected by changes until they refresh" | [Iceberg spec](https://iceberg.apache.org/spec/) |
| No schema-mismatch Spark errors when reading mixed-schema files | Confirmed by field-ID design: "Although you can change the schema of your table over time, you can still read old data files because Iceberg uniquely identifies schema elements" | [Iceberg Evolution docs](https://iceberg.apache.org/docs/1.5.1/evolution/) |
| Same `ALTER TABLE ADD COLUMN` syntax works in Trino and Spark SQL | Confirmed by Trino Iceberg connector and Iceberg Spark DDL docs | [Starburst Iceberg/Trino schema evolution](https://www.starburst.io/blog/apache-iceberg-schema-evolution-in-trino/), [Iceberg Spark DDL](https://iceberg.apache.org/docs/1.5.1/spark-ddl/) |

**Minor issues (LOW severity)**:

1. **The NOT NULL claim is slightly imprecise.** The answer says: "New columns added to Iceberg are always nullable, regardless of what you declare in the ALTER statement" — implying Iceberg silently downgrades a `NOT NULL` declaration. In practice, several engines (Trino, Presto, Spark) reject `ADD COLUMN ... NOT NULL` outright with an error, rather than silently accepting and downgrading. The result is similar (you cannot end up with a NOT NULL added column), but the wording "regardless of what you declare" overstates Iceberg's silent permissiveness. Could mislead an engineer who tries the syntax and is surprised by an error instead of a silent acceptance.

2. **Backfill example is functionally correct but a bit heavy.** Using `overwritePartitions()` to backfill a default value works, but for a one-time default value, an `UPDATE` (Spark 3.x with Iceberg) or `MERGE` would be lower-risk than a partition overwrite. Not wrong — just not the simplest path.

3. **"Spark's Iceberg integration reads the current table schema at the start of each job"** — Strictly, Spark+Iceberg snapshot isolation pins to the snapshot at job-plan time, and that snapshot has a specific schema. Wording in the answer is correct enough but slightly conflates "current table schema" with "snapshot's schema". Not a real error.

No HIGH or MEDIUM severity errors. Production stack fit (Iceberg 1.5.2, Trino 467, MinIO, Hive Metastore) is appropriate — answer mentions Iceberg 1.5.2 explicitly and references Hive Metastore.

### Clarity — 4.9 / 5

- Strong organizational structure: how-it-works section, what-happens-in-your-setup section, safe procedure with numbered steps, caveats, summary table.
- Summary table at the end directly addresses every fear the engineer raised in the question ("Old Parquet files break?", "Spark job fails with schema mismatch?", "Need downtime?"). This is exactly the format a nervous on-call engineer needs.
- SQL and PySpark snippets are short and runnable.
- Zero unexplained jargon — "field ID", "snapshot isolation", and "metadata-only" are each defined in context.
- One small nit: the term "snapshot isolation" is used without a one-sentence definition, but the surrounding sentence makes the meaning clear from context.

### Practical usefulness — 4.8 / 5

- Tells the engineer exactly what to run, in what order, and explicitly states no downtime / no coordination is required.
- The "optional backfill" step is correctly positioned as optional — answer makes clear NULL in historical rows is normal and expected.
- Caveat about NOT NULL is actionable: gives two concrete mitigations (backfill default; document cutover date and filter dashboards).
- Mentions that DROP/RENAME COLUMN are different and have implications for CDC (Debezium) — good forward pointer without going off-topic.
- Trino + Spark dual-engine context from the question is addressed for both engines explicitly.

Minor: could mention that the backfill itself produces a new snapshot and may briefly inflate small-file count; not required for an answer scored on this question.

### Completeness — 4.7 / 5

Covers every part of the asked question:
- Old file behavior — yes (returns NULL).
- Spark job impact — yes (snapshot isolation, no restart, next run includes new column).
- Trino dashboard impact — yes.
- Nullability caveat — yes.
- Backfill option — yes, with code.
- Safe procedure — yes, numbered steps.

Gaps (LOW severity):
1. Does not mention that the `ALTER TABLE` itself creates a new metadata.json and commits via the Hive Metastore — irrelevant to the safety question but worth a sentence for production confidence.
2. Does not mention concurrent-writer behavior: if Spark is mid-write when ALTER fires, the writer's commit may need to rebase on the new schema. In practice Iceberg handles this, but the engineer specifically said "Spark batch job that runs every hour" so a single sentence on "what if ALTER lands while a Spark write is in flight" would be valuable.
3. No mention of needing to update downstream dbt models / view definitions that might `SELECT *` and break BI layer schemas — relevant to a SaaS engineer with dashboards.

None of these gaps are required to answer the asked question; all are bonus depth.

---

## Production-stack fit

Production environment: on-prem MinIO + Iceberg 1.5.2 + Hive Metastore + Trino 467 + Spark.

- Answer explicitly references Iceberg 1.5.2 and Hive Metastore — good.
- ALTER syntax shown (`ALTER TABLE iceberg.analytics.your_table ADD COLUMN ...`) works in both Trino 467 and Spark SQL with Iceberg 1.5.2 — verified.
- No cloud-only assumptions; no reference to AWS Glue, Snowflake, BigQuery, or any tool incompatible with the stack.
- No auth/authz claims that would conflict with the JWT/OPA model.

Production fit: clean.

---

## Errors and gaps (consolidated)

| Severity | Issue |
|---|---|
| LOW | "Always nullable regardless of declaration" wording understates that some engines reject `ADD COLUMN ... NOT NULL` with an error rather than silently accepting it. |
| LOW | Backfill uses `overwritePartitions()`; `UPDATE`/`MERGE` would be lower risk for setting a default. |
| LOW | Missing mention of concurrent-writer rebase behavior when ALTER lands during an in-flight Spark write. |
| LOW | No mention that downstream `SELECT *` consumers (dbt models, BI views) may need refresh. |
| LOW | Could briefly note ALTER creates a new metadata.json commit visible in `$history` / `$snapshots` (writer audit trail). |

No HIGH or MEDIUM severity items.

---

## Resource fix recommendations

The answer is already strong. Suggested incremental improvements to underlying resources (not required for pass):

1. In whichever schema-evolution resource feeds this answer, clarify the engine-by-engine behavior on `ADD COLUMN ... NOT NULL`:
   - Trino: rejects with error.
   - Spark + Iceberg: rejects with `AnalysisException`.
   - The spec disallows NOT NULL on added columns because historical rows have no value.

2. Add a short paragraph on "concurrent writers during ADD COLUMN" — Iceberg's optimistic concurrency rebase model means in-flight writes succeed and pick up the new schema on commit; this is reassurance the SaaS engineer will want when the question is asked in production.

3. Add a one-liner pointing out that consumers using `SELECT *` (dbt model materializations, BI tools caching column lists) may need a refresh after ADD COLUMN — purely additive, low cost.

---

## Rubric topic coverage

Question primarily exercises **schema evolution / Iceberg DDL safety** (a sub-area of "Iceberg partition design / table operations" and "Postgres-to-Iceberg ingestion" topics that already have PASSED status). No new topic to mark.

---

## Sources

- [Apache Iceberg Evolution docs (latest)](https://iceberg.apache.org/docs/latest/evolution/)
- [Apache Iceberg Evolution docs (1.5.1, closest to prod 1.5.2)](https://iceberg.apache.org/docs/1.5.1/evolution/)
- [Apache Iceberg Spec](https://iceberg.apache.org/spec/)
- [Apache Iceberg Spark DDL](https://iceberg.apache.org/docs/1.5.1/spark-ddl/)
- [Starburst — Apache Iceberg Schema Evolution in Trino](https://www.starburst.io/blog/apache-iceberg-schema-evolution-in-trino/)
- [Presto Issue #20618 — ADD COLUMN NOT NULL constraint behavior](https://github.com/prestodb/presto/issues/20618)
