# Score: Iter 337 Q2 — DELETE Orphaned Rows from Iceberg

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core claims verified: Trino 467 supports row-level `DELETE FROM ... WHERE`; `ALTER TABLE ... EXECUTE optimize` is correct compaction syntax; `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` is correct and the 7-day floor (iceberg.expire-snapshots.min-retention default 7d) is accurate; Spark CALL `iceberg.system.rewrite_data_files` and `iceberg.system.expire_snapshots` are canonical. Engine labels are clean (Spark vs Trino blocks). Minor: the claim "Only this step [expire_snapshots] physically removes the old bytes from MinIO" is essentially correct per Trino docs ("removes all snapshots and all related metadata and data files"), but it omits that `remove_orphan_files` is still required to catch any files outside the snapshot graph and that this is the recommended full maintenance order (expire -> orphan -> manifests). Slight overstatement that expire_snapshots is the single sufficient cleanup step. |
| Beginner clarity | 4.5 | Three numbered steps with clear "what happens / what doesn't happen" framing. The Postgres analogy ("In my regular Postgres world I'd just run DELETE...") is acknowledged directly. "Why all three steps are required" with skip-step consequences is a strong teaching device. "Between steps 1 and 2" explains the transient slow-query window. Minor: terms like "delete markers", "snapshot", "immutable file architecture" are used without inline glossing — a true beginner may need a sentence on what a snapshot/delete file is. |
| Practical applicability | 4.5 | Directly answers the engineer's stuck-point with runnable SQL for both Spark and Trino paths. The cross-catalog DELETE FROM ... WHERE id IN (SELECT ... EXCEPT SELECT ...) shows exactly how to wire the EXCEPT into the DELETE. Both engine variants are given, so the engineer can use Trino 467 directly. Missing: no warning that running the cross-catalog EXCEPT inside the DELETE subquery may be expensive (no predicate pushdown into postgres for the EXCEPT side at delete-time) — safer pattern is to materialize the ID list once and pass it as a literal `IN (...)` or stage it in a temp table. No mention that if the ID set is large (>10K rows), splitting into batches avoids a single huge transaction / huge rewrite. |
| Completeness | 4.0 | Covers the three-step lifecycle (DELETE -> compact -> expire) which is the heart of the question. Engine alternatives covered. Missing: (1) `remove_orphan_files` as the canonical fourth step in the documented maintenance order; (2) batching guidance for large ID lists; (3) the WHERE-clause anti-pattern in DELETE subqueries across catalogs (correctness/perf); (4) note that the EXCEPT-generated ID list is a moving target if new rows were ingested between the EXCEPT and the DELETE — should either pin via a CTE or stage the IDs first; (5) no mention that `optimize` with no WHERE clause rewrites the entire table, which on a large events table is wasteful — a partition-scoped optimize is dramatically cheaper. |
| **Average** | **4.375** | **PASS** |

## What Worked
- Correctly identified that DELETE alone does not free storage and that a multi-step sequence is required.
- Clean Spark-vs-Trino separation with engine labels on each code block (no engine-mixing bugs).
- 7-day retention floor for Trino's `expire_snapshots` explicitly called out — this is a real Trino 467 gotcha.
- "Skip step X consequences" framing turns the procedure into causal reasoning, not a checklist.
- Acknowledges transient query slowdown between DELETE and compaction (MoR position-delete cost) — that is a real and underexplained user-visible symptom.
- The DELETE SQL shows the cross-catalog EXCEPT inline, directly answering "how do I plug my EXCEPT result into a DELETE."

## What Missed
- `remove_orphan_files` is not mentioned. The documented maintenance order is expire_snapshots -> remove_orphan_files -> rewrite_manifests. The answer treats expire_snapshots as the single physical-cleanup step, which slightly overstates its scope. For a complete cleanup it's still good practice to follow with remove_orphan_files.
- No batching guidance for large reconciliation deletes. If the EXCEPT returns 1M IDs, a single DELETE will create huge position-delete files and a multi-hour optimize.
- No warning about the cross-catalog DELETE subquery: running EXCEPT against postgres_catalog from inside a DELETE WHERE IN means the engine re-evaluates the postgres side at delete-plan time. Safer: stage the ID list in a temp iceberg table or use a CTE materialized once.
- No mention that `ALTER TABLE ... EXECUTE optimize` without a WHERE clause rewrites the entire table — partition-scoped optimize (`WHERE event_date = ...`) is much cheaper and the typical production pattern.
- `interval '7' day` is shown in the Spark example as `current_timestamp() - interval '7' day` — this is correct Spark SQL, but for the reconciliation use case (where the user wants to free storage after a one-off delete), `older_than => current_timestamp()` with `retain_last => 1` is what the user actually wants. Defaulting to 7 days means the deleted rows stay queryable via time-travel for a week, which may not be what the engineer intends after a reconciliation cleanup.

## Technical Accuracy Verification
- **`DELETE FROM iceberg.<schema>.<table> WHERE col IN (subquery)` is valid Trino 467 syntax** — CONFIRMED. Trino's Iceberg connector supports row-level deletes via position delete files for v2 tables (trino.io/docs/current/connector/iceberg.html, trinodb/trino PR #11886).
- **DELETE in Iceberg does not immediately free storage** — CONFIRMED. "A Delete statement doesn't actually physically delete the data off the storage. In order to ensure the data has been removed, an expire_snapshots procedure needs to be executed" (Starburst, trinodb/trino issue #12843).
- **`ALTER TABLE ... EXECUTE optimize` is the Trino compaction syntax** — CONFIRMED (trino.io/docs/current/connector/iceberg.html).
- **`ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` is valid Trino syntax** — CONFIRMED.
- **Trino enforces a 7-day minimum retention floor by default** — CONFIRMED. `iceberg.expire-snapshots.min-retention` defaults to `7d`; shorter values fail with "Retention specified (X.XXd) is shorter than the minimum retention configured in the system (7.00d)".
- **`CALL iceberg.system.rewrite_data_files(table => ..., options => map(...))` is valid Spark syntax** — CONFIRMED (iceberg.apache.org/docs/latest/spark-procedures/).
- **`CALL iceberg.system.expire_snapshots(table, older_than, retain_last)` is valid Spark syntax** — CONFIRMED.
- **expire_snapshots physically deletes data files no longer referenced by any retained snapshot** — CONFIRMED for Trino's implementation per trino.io docs: "removes all snapshots and all related metadata and data files." However, this does not catch files orphaned outside the snapshot graph (failed writes, abandoned compactions), which is why `remove_orphan_files` is still recommended as a follow-up.
- **MoR position delete files cause slower queries until compaction** — CONFIRMED. "The query engine must read through potentially many small delete files and apply them during query time" (multiple Iceberg blog sources). Regular compaction rewrites the data files and removes the delete-file overhead.
- **Cross-catalog subqueries (iceberg + postgres_catalog) in a single DELETE statement** — supported by Trino's federated query model, but with the caveat that planning re-evaluates the postgres side at delete-plan time. The answer does not warn about this.

Sources:
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [DELETE — Trino Documentation](https://trino.io/docs/current/sql/delete.html)
- [Apache Iceberg DML & Maintenance in Trino — Starburst](https://www.starburst.io/blog/apache-iceberg-dml-update-delete-merge-maintenance-in-trino/)
- [Maintenance — Apache Iceberg](https://iceberg.apache.org/docs/latest/maintenance/)
- [Procedures — Apache Iceberg](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Iceberg: DELETE erases table history — trinodb/trino issue #12843](https://github.com/trinodb/trino/issues/12843)
- [How Table Maintenance Affects Iceberg Snapshots — Starburst](https://www.starburst.io/blog/how-table-maintenance-affects-iceberg-snapshots/)
- [Copy-on-Write vs Merge-on-Read — Dremio](https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/)
