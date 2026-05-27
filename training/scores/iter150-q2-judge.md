# Iter 150 Q2 — Judge Report

## Question recap
SaaS engineer wants to backfill 18 months into a live Iceberg events table without exposing bad data to customers. Asks whether Iceberg has a staging/flip-the-switch pattern, or if a separate staging table + final INSERT...SELECT is the only safe path.

## Answer location
`/Users/hclin/github/recknihao/training/answers/iter150-q2.md`

---

## Verdict

**Overall weighted score: 4.0 / 5.0**
**Result: FAIL** (threshold ≥ 4.5)

Weighted average computation: `(TechAcc * 2 + Clarity + Practical + Completeness) / 5`
= `(3.5 * 2 + 4.5 + 4.5 + 4.0) / 5`
= `(7.0 + 4.5 + 4.5 + 4.0) / 5`
= `20.0 / 5`
= **4.0**

The answer is well-structured, beginner-friendly, and gives a coherent staging pattern — but two of its central runnable code paths are not actually supported in the production stack (Trino 467 Iceberg connector). That is enough to fail it as deployed production guidance.

---

## Per-dimension scores

### Technical accuracy: 3.5 / 5 (weight 2x)

**Verified-correct claims**

- Iceberg snapshot isolation: readers see a consistent committed snapshot and are never exposed to partially written data. Both snapshot and serializable isolation levels guarantee this for concurrent readers vs writers. Source: [Reliability — Apache Iceberg](https://iceberg.apache.org/docs/1.6.0/reliability/), [Iceberg Concurrent Writes Knowledge Base](https://iceberglakehouse.com/iceberg/iceberg-concurrent-writes/), [Iceberg Spec](https://iceberg.apache.org/spec/). The answer's claim that "live dashboard queries keep running against current data while staging writes happen" is correct.
- Iceberg "all changes to table state create a new metadata file and replace the old metadata with an atomic swap" — answer correctly relies on this for the rename + view-swap rollback story. Source: [Trino Iceberg Connector docs](https://trino.io/docs/current/connector/iceberg.html).
- Compaction does not fix data-quality issues — correct.
- Post-backfill maintenance ordering (rewrite_data_files → expire_snapshots → remove_orphan_files) is correct and matches the project's established maintenance recipe.
- ALTER TABLE ... RENAME TO as a rollback handle is valid in the Trino Iceberg connector.
- The "audit every consumer" prerequisite for view-swap is correct and is the single most important non-obvious prerequisite of this pattern.

**Errors / unverified claims (HIGH severity)**

1. **`INSERT OVERWRITE ... PARTITION (...)` syntax is NOT supported by Trino's Iceberg connector.** The answer presents this as a runnable Trino SQL alternative ("Option 2: Partition-scoped overwrite"). Per [trinodb/trino#11602](https://github.com/trinodb/trino/issues/11602) and [#26178](https://github.com/trinodb/trino/issues/26178), Trino has no `INSERT OVERWRITE` statement at all — it only has plain `INSERT INTO` plus `MERGE`/`DELETE`. The HiveQL-style `INSERT OVERWRITE TABLE foo PARTITION (event_date = '...') SELECT ...` works on Spark for Iceberg but will not parse in Trino 467. The production stack uses Trino for query and Spark for ingestion, so the engineer might actually try this on Spark — but the answer never says "switch to Spark to run this" and presents the example in the same Trino-SQL context as Option 1. This is the answer's single biggest correctness defect.
2. **`CREATE OR REPLACE VIEW` atomicity is asserted but not verified for the Trino + Hive Metastore production stack.** The answer calls it "one atomic metadata commit." That language is correct for Iceberg *tables* (`CREATE OR REPLACE TABLE` does an atomic metadata swap per [Trino Iceberg docs](https://trino.io/docs/current/connector/iceberg.html)) but Trino views are stored in the Hive Metastore as a separate object. CREATE OR REPLACE VIEW in Trino over HMS does replace the view definition in a single HMS call, but the atomicity guarantee depends on the metastore implementation, not on Iceberg's snapshot machinery. The answer conflates the two. For a "flip the switch" pattern this is the load-bearing assumption and it should be stated with the right scope: "Trino executes CREATE OR REPLACE VIEW as a single metastore call; concurrent readers see either the old or new definition." Calling it an "Iceberg atomic metadata commit" is wrong.

**Errors / omissions (MEDIUM severity)**

3. **The Iceberg-native answer to this exact question — branches (WAP, write-audit-publish) — is completely absent.** The engineer literally asks "is there any way in Iceberg to write data into a staging version of the table that existing queries can't see, validate it first, and then flip a switch to make it visible all at once?" That is the textbook definition of WAP-via-branches. Iceberg supports it via `ALTER TABLE ... CREATE BRANCH audit`, write with `spark.wap.branch = audit`, validate on the branch (readers don't see it), then `CALL system.fast_forward(table, 'main', 'audit')` to atomically publish. Source: [Streamlining Data Quality in Apache Iceberg with WAP & branching — Dremio](https://www.dremio.com/blog/streamlining-data-quality-in-apache-iceberg-with-write-audit-publish-branching/), [Build WAP pattern with Apache Iceberg branching — AWS](https://aws.amazon.com/blogs/big-data/build-write-audit-publish-pattern-with-apache-iceberg-branching-and-aws-glue-data-quality/). Branches were stable starting Iceberg 1.2 and the production stack runs 1.5.2 — fully supported on the Spark side. Trino 467 can read branches via `table$branch_audit` notation but cannot write or fast-forward them, so the workflow is Spark-write + Spark-fast-forward + Trino-read. This is the *right* answer to the engineer's question and the answer never mentions it.
4. **No mention that the partition-overwrite alternative, even on Spark, would burn ~550 snapshots and that this needs to be considered before starting.** The answer mentions "many snapshots to expire" in the trade-off line but doesn't quantify that this can blow up metadata read time during the backfill window if `expire_snapshots` isn't run periodically. Minor.

**LOW severity**

5. The date window in the SQL (`event_date >= DATE '2024-11-01' AND event_date < DATE '2026-05-26'`) is exactly 18 months from today, which is fine, but pinning today's date into a runnable example is fragile copy/paste material. Cosmetic.

**Score reasoning**: Two HIGH-severity issues (unrunnable SQL in Trino + load-bearing atomicity claim that conflates view-vs-table atomicity) and one MEDIUM omission (the native Iceberg answer — branches — is missing) drag this from a 5 down to 3.5. The rest of the technical content is solid and the post-backfill maintenance section is correct.

### Beginner clarity: 4.5 / 5 (weight 1x)
Steps are numbered, the why-this-is-safe paragraph names each guarantee in plain English, and the "what NOT to do" + rollback paragraphs make the failure modes concrete. The "audit your consumers" prerequisite is called out as a critical prerequisite with a grep-based action item — that is exactly the right altitude for a beginner. Minor deductions: "snapshot isolation," "metadata commit," and "compaction" are used without inline glosses, though context makes them inferable.

### Practical applicability: 4.5 / 5 (weight 1x)
Runnable SQL for every step, a decision-guide summary table at the end, a concrete rollback SQL, and a maintenance recipe. The engineer can act on this immediately. One point off because the Option 2 SQL is not actually runnable in Trino (see Technical Accuracy #1), so an engineer copy-pasting it would hit a parser error.

### Completeness: 4.0 / 5 (weight 1x)
Covers: staging table approach (yes), view swap atomicity (yes, though scoped imprecisely), consumer-audit prerequisite (yes, with grep checklist), partition overwrite alternative (mentioned but with wrong SQL for the stack), post-backfill maintenance (yes), what NOT to do (yes). **Missing**: Iceberg branches / WAP, which is *the* feature the question is asking about. The answer effectively says "no native flip-the-switch in Iceberg, here's how to fake it with a view" when the truthful answer is "yes, Iceberg has this natively via branches; here is when to use branches vs a staging-table-plus-view-swap." This is the central completeness gap and is the reason this dimension is a 4 not a 5.

---

## Resource fix recommendations

The teacher should add or extend a resource covering safe-backfill / WAP for the Trino + Spark + Iceberg 1.5.2 stack. Concretely:

1. **New section or new file**: `resources/21-iceberg-safe-backfill.md` (or extend `resources/06-iceberg-maintenance.md`). Cover three patterns side-by-side:
   - **Branches / WAP** (Spark-only writes, Trino reads via `table$branch_name`, `CALL system.fast_forward`). State the version requirement (Iceberg ≥ 1.2; production is 1.5.2 so this is fine) and the engine split clearly (Spark writes the branch, Spark fast-forwards, Trino reads both before/after).
   - **Staging table + view swap** (the answer's current Option 1). Correct the atomicity language: "Trino's CREATE OR REPLACE VIEW is a single Hive Metastore call; readers see old or new, never partial. This is metastore-level atomicity, not Iceberg snapshot atomicity."
   - **Day-by-day rewrite via Spark `INSERT OVERWRITE`** — and explicitly say this is a Spark statement, not a Trino statement. Trino's Iceberg connector has no `INSERT OVERWRITE`; use Spark for this or use `MERGE INTO` on Trino.
2. **Decision guide** mapping table size / partition strategy / engine availability → recommended pattern.
3. **Trino-vs-Spark statement compatibility callout box**. Top symptoms: `INSERT OVERWRITE`, `CALL system.fast_forward`, `ALTER TABLE ... CREATE BRANCH` all work in Spark and not in Trino 467; `CREATE OR REPLACE TABLE` works in both; `MERGE INTO` works in both.
4. **Glossary entry for "snapshot isolation"** in the lakehouse glossary so future answers can drop the term safely.

---

## Topic coverage update

This question primarily tests:
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — partially exercised (the post-backfill maintenance recipe is correct). Continues to pass.
- **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling** — exercised on the full-refresh / backfill side. The answer's gap (missing branches/WAP) is a teaching gap in this topic.

Both topics already PASSED in the rubric. This single answer should not flip their status, but the missing-branches gap should be tracked so the next question hitting either topic from the WAP / safe-publish angle can confirm whether the resource gap has been closed.

---

## Sources

- [Iceberg connector — Trino current docs](https://trino.io/docs/current/connector/iceberg.html)
- [Reliability — Apache Iceberg 1.6.0 docs](https://iceberg.apache.org/docs/1.6.0/reliability/)
- [Apache Iceberg Spec](https://iceberg.apache.org/spec/)
- [Iceberg Concurrent Write Handling — Knowledge Base](https://iceberglakehouse.com/iceberg/iceberg-concurrent-writes/)
- [trinodb/trino#11602 — Add INSERT OVERWRITE to Trino SQL](https://github.com/trinodb/trino/issues/11602)
- [trinodb/trino#26178 — Can Trino support Iceberg's overwrite feature?](https://github.com/trinodb/trino/issues/26178)
- [Streamlining Data Quality in Apache Iceberg with WAP & branching — Dremio](https://www.dremio.com/blog/streamlining-data-quality-in-apache-iceberg-with-write-audit-publish-branching/)
- [Build WAP pattern with Apache Iceberg branching and AWS Glue Data Quality — AWS Big Data Blog](https://aws.amazon.com/blogs/big-data/build-write-audit-publish-pattern-with-apache-iceberg-branching-and-aws-glue-data-quality/)
- [Spark Procedures — Apache Iceberg 1.5.1 docs](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)
