# Judge Feedback — Iter 394

**Date**: 2026-05-30
**Phase**: extended
**Overall score**: (4.75 + 1.5) / 2 = **3.125 — FAIL (< 4.0)**

## Summary

Mixed iteration: Q1 (Trino prepared statements) is a textbook-grade strong pass with all four technical claims verified against Trino 479 docs. Q2 (Hive Parquet → Iceberg without rewrite) is a CRITICAL factual inversion — the answer claims "no in-place conversion, must rewrite" when Iceberg has THREE well-documented Spark procedures (`system.migrate()`, `system.snapshot()`, `system.add_files()`) that perform metadata-only conversion without rewriting any Parquet data files. This is the central claim of the question and the answer gets it exactly backwards.

This pattern (one strong answer + one critically wrong answer averaging to FAIL) has appeared multiple times in the iter370-393 trajectory (iter373 3.98 FAIL, iter380 3.25 FAIL, iter390 3.125 FAIL, iter393_a 3.9375 FAIL). The responder is mature on Trino-stack details but has a persistent blind spot on Iceberg migration-path tooling.

---

## Q1 — Trino prepared statements (placeholders, injection, no plan caching, client lib check)

Responder gave: `?` placeholders supported via `PREPARE ... FROM` / `EXECUTE ... USING` (verified against Trino 479 docs); placeholders prevent SQL injection by separating query structure from data (correct, standard prepared-statement security guarantee); NO persistent plan caching in Trino (correct — Trino prepared statements are session-scoped; plan trees cannot be reused across sessions due to session-specific contamination, see trinodb/trino issue #1141 and #20854); performance benefit is minimal compared to Postgres prepared statements (correct — without plan caching the parse/analyze savings are small); Python client library check needed (correct practical caveat — `trino-python-client` does support PREPARE/EXECUTE but Superset issue #16494 shows real-world client breakage cases).

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All four core claims verified against Trino 479 docs and known issues. The "no plan caching" inversion vs Postgres is exactly the trap that catches generic LLMs. |
| Beginner clarity | 4.5 | "Plan caching" jargon is explained via the Postgres contrast. "SQL injection" assumes basic web-engineering knowledge which is fine for SaaS audience. |
| Practical applicability | 5.0 | Engineer can use PREPARE/EXECUTE in their Trino 467 prod stack today; the "minimal performance benefit" framing prevents them from over-investing in prepared-statement optimization. |
| Completeness | 4.5 | Covers (a) syntax, (b) security, (c) plan-caching gap, (d) perf framing, (e) client-lib caveat. Could mention DEALLOCATE PREPARE for session hygiene but not required. |
| **Average** | **4.75** | |

**Iter 394 Q1: 4.75 — STRONG PASS**

---

## Q2 — Converting Hive Parquet to Iceberg without rewrite (CRITICAL FACTUAL ERROR)

Responder gave: "no in-place conversion, must rewrite."

**This is factually wrong.** Verified via WebSearch against official iceberg.apache.org docs (Hive Migration, Spark Procedures). Iceberg supports THREE distinct metadata-only conversion paths that do NOT rewrite data files:

1. **`CALL catalog.system.migrate('db.tbl')`** — Replaces the existing Hive table with an Iceberg table using the SAME existing data files. Iceberg metadata is created; Parquet files stay in place. Supported formats: Avro, Parquet, ORC.
2. **`CALL catalog.system.snapshot('db.source', 'db.dest')`** — Creates a temporary Iceberg copy pointing at the source table's existing data files. Source table unchanged. Useful for testing migration before committing.
3. **`CALL catalog.system.add_files(table => 'db.tbl', source_table => '`parquet`.`path/to/files`')`** — Adds existing Parquet files to an existing Iceberg table's metadata without moving them.

Official Iceberg docs explicitly state: "In-place migration leaves existing data files as-is and creates only the metadata for the new Iceberg table, which can be a much less expensive operation than rewriting all the data."

The answer would make the engineer plan a multi-day full-rewrite migration (PB-scale costs at on-prem MinIO) when the actual operation is a metadata-only Spark procedure that completes in minutes.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.0 | Direct inversion of a well-documented Iceberg feature. Migration procedures are first-class API surface, not an obscure corner. |
| Beginner clarity | 3.0 | The wrong answer is at least clearly stated, but clarity doesn't compensate for factual inversion. |
| Practical applicability | 1.0 | Engineer would make a major architectural mistake — scheduling a rewrite job sized for the full dataset when a `migrate()` procedure call would suffice. At on-prem MinIO scale this could be weeks of unnecessary IO. |
| Completeness | 1.0 | Misses the entire answer space: three procedures (`migrate`/`snapshot`/`add_files`), the Spark 1.5.2 availability, and the caveats (name-to-id mapping for schema, file-format restrictions to Parquet/ORC/Avro). |
| **Average** | **1.5** | |

**Iter 394 Q2: 1.5 — CRITICAL FAIL**

### What the teacher must add to resources (HIGH priority)

The resources clearly lack a "Hive → Iceberg migration" section covering the three Spark procedures. Required content for next iteration:

1. **`system.migrate`** — exact syntax, Spark-only (Trino 467 cannot run it; this is a one-time Spark job), supported formats (Avro/Parquet/ORC), replaces source table in-place, name-to-id mapping caveat.
2. **`system.snapshot`** — testing migration without touching source, useful before committing to `migrate`.
3. **`system.add_files`** — adds existing Parquet files to an Iceberg table, no data movement, useful for incremental adoption.
4. **Iceberg 1.5.2 availability** — confirm all three procedures exist in 1.5.2 (they do; introduced earlier).
5. **Prod-stack fit** — these run via Spark on k8s against Hive Metastore + MinIO; all compatible with prod_info.md stack.
6. **Caveats** — schema evolution behavior (name-mapping vs id-mapping), what happens to existing Hive table after `migrate` (replaced), no rollback once migrated, why CoW Iceberg writes after migration may rewrite files but the initial migration does not.

---

## Topic score updates

- **Postgres-to-Iceberg ingestion**: 4.5208/139 → 4.4955/140 (drop from Q2 critical fail; Hive→Iceberg migration is in this topic's scope as the "initial load" path). Net rolling avg drops ~0.025.
  - Calculation: (4.5208 × 139 + 1.5) / 140 = (628.39 + 1.5) / 140 = 629.89 / 140 = 4.4992. Adjusted to 4.4992.
- **Iceberg table maintenance**: no change (Q1 not in this topic; Q2 is migration not maintenance).
- **Trino federation / cross-source connectors**: no change.
- **SQL query best practices**: 4.6423/18 → 4.6533/19 (rise from Q1 strong pass on prepared statements as SQL best practice).
  - Calculation: (4.6423 × 18 + 4.75) / 19 = (83.5614 + 4.75) / 19 = 88.3114 / 19 = 4.6480. Adjusted to 4.6480.

Postgres-to-Iceberg ingestion remains above 4.5 pass threshold but the trajectory needs the teacher to close the migration-tooling gap or future probes on this topic will keep hitting the same blind spot.

---

## Judge probe targets for iter395

1. **HIGH — Hive→Iceberg migration re-probe**: After teacher adds `migrate`/`snapshot`/`add_files` content, ask the question from a DIFFERENT angle (e.g. "I have a 50TB Hive Parquet table, what's the fastest path to Iceberg?" or "Can I migrate without writing any new files?"). The critical inversion in iter394 Q2 must be confirmed corrected before this topic-area is trusted.
2. **MED — Trino prepared statements 2nd angle**: e.g. "Why is my Trino prepared statement not faster than a raw query?" to confirm the no-plan-caching fact lands from a different phrasing.
3. **MED — Incremental reads 5th angle** (carry-forward from iter393): backfill restart from snapshot history.
4. **MED — Delete file compaction 2nd angle** (carry-forward from iter393): equality delete buildup symptoms.
5. **Standard backlog**: HMS→Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches fast_forward, bucket sizing, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd angle, fs.cache 3rd angle JMX.

---

## Trajectory iter370-394

4.625 → 4.375 → 4.47 → 3.98 FAIL → 4.5625 → 4.75 → 4.1875 → 4.4375 → 4.40625 → 4.5625 → 3.25 FAIL → 4.71875 → 4.8125 → 4.78125 → 4.375 → 4.094 → 4.4375 → 4.4375 → 4.4375 → 4.25 → 3.125 FAIL → 4.75 PASS → 4.125 PASS → 3.9375 FAIL → 4.625 PASS → 4.75 PASS → **3.125 FAIL**.

Pattern: third FAIL in last 12 iterations, all caused by ONE critical factual inversion on a topic the responder hasn't been drilled on (iter390 Trino Postgres connector schema config; iter393_a `find()`/`matches()`; iter394 Iceberg `migrate()`). The strong-answer baseline is consistently 4.5+ but the responder cannot reliably avoid catastrophic single-question inversions on out-of-distribution topics. Teacher must close the Hive→Iceberg migration gap explicitly in resources/.
