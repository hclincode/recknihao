# Score: iter270-q1

**Score**: 4.38 / 5.0
**Pass**: NO (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | MERGE INTO syntax, semantics, and the "Iceberg-only target / Postgres only as source" claim are all correct and align with Trino official docs. INSERT INTO append-only behavior is correct. **However**, the performance note states: "Every MERGE rewrites the Parquet files it touches (Iceberg's Copy-on-Write default)." This is wrong for Trino. Trino's Iceberg connector writes use **merge-on-read** (positional delete files), NOT copy-on-write. CoW is Iceberg's spec-level default for some engines, but Trino specifically implements MoR for DML. This is a meaningful technical error because it misrepresents the on-disk behavior and the kinds of maintenance the engineer will need (compaction of delete files vs. rewriting data files). |
| Beginner clarity | 5 | Excellent for a non-OLAP engineer. The "why plain INSERT creates duplicates" framing maps directly to the engineer's intuition. Each clause of MERGE is explained line-by-line. The summary table at the end crisply compares INSERT vs DELETE+INSERT vs MERGE. No undefined jargon. |
| Practical applicability | 4 | Concrete, runnable SQL with realistic schema (tenant_id, plan, updated_at). The watermark window and "safe to re-run" pattern match the engineer's nightly-sync scenario. Fits the on-prem Trino 467 + Iceberg + Hive Metastore stack from prod_info.md. Loses some points because: (a) the CoW claim could mislead the engineer about file-layout consequences and the maintenance commands they'd need (e.g., they'd actually need to compact position delete files via `optimize` / `remove_orphan_files` / `expire_snapshots` rather than worry about data-file rewrites), and (b) it suggests `overwritePartitions()` via Spark for large batches but doesn't mention the more directly available Trino approach (DELETE + INSERT in a single transaction or `optimize` after MERGE). |
| Completeness | 4.5 | Covers the core question fully: MERGE syntax, Iceberg-only-target constraint, idempotency, INSERT-INTO pitfall, batch-size performance, retry safety. Includes a summary comparison table. Missing nuance: no mention of merge-on-read delete-file accumulation and the need for periodic `ALTER TABLE ... EXECUTE optimize` to compact delete files, which is the actual maintenance burden under Trino's MoR write mode. Also doesn't mention handling deletes-at-source (rows removed from Postgres won't be removed from Iceberg by this MERGE — only soft-handled by `WHEN MATCHED` if the source row still appears). |
| **Average** | **4.375** | |

## What the answer got right
- MERGE INTO is supported for Iceberg targets in Trino — verified against trino.io/docs/current/sql/merge.html and the Iceberg connector docs.
- Correct that PostgreSQL connector cannot be a MERGE **target** (only Hive, Kudu, Raptor, Iceberg, and Delta Lake connectors support MERGE as target). Postgres-as-source in the USING clause is valid.
- Correct MERGE syntax: `WHEN MATCHED THEN UPDATE SET ...` and `WHEN NOT MATCHED THEN INSERT (...) VALUES (...)`.
- Correct that Trino's `INSERT INTO` always appends for Iceberg — there is no INSERT OVERWRITE in Trino SQL (open issue #11602, #26178).
- Correct idempotency reasoning: re-running MERGE with the same source produces the same final state.
- Good practical SaaS-shaped example (tenant_id, plan, watermarked updated_at window).
- Fits the prod_info.md environment (Trino 467 + Iceberg connector + Hive Metastore).

## Gaps or errors
- **Factual error**: "Every MERGE rewrites the Parquet files it touches (Iceberg's Copy-on-Write default)." Trino's Iceberg connector writes use **merge-on-read** (positional delete files), not copy-on-write. CoW for Iceberg writes in Trino is an open feature request (trinodb/trino#17272), not the current default. This changes the engineer's mental model of what files are produced and what maintenance is required.
- Missing: under merge-on-read, repeated MERGEs accumulate position delete files that must be compacted via `ALTER TABLE ... EXECUTE optimize` and `expire_snapshots` — this is the real maintenance story for nightly MERGE jobs on Trino, and it was not mentioned.
- Missing: source-side deletes (rows removed from Postgres) will not be reflected in Iceberg by this MERGE pattern. For a true mirror, the engineer would need `WHEN NOT MATCHED BY SOURCE THEN DELETE` semantics (which Trino MERGE does not currently support without a full snapshot of source) or a separate strategy.
- The Spark `overwritePartitions()` suggestion is technically valid but feels like a non-sequitur for a Trino-centric answer; a Trino-native alternative (DELETE by partition predicate then INSERT, in a transaction) would be more immediately useful to this engineer.

## Verified sources
- https://trino.io/docs/current/sql/merge.html — MERGE syntax and semantics
- https://trino.io/docs/current/connector/iceberg.html — Iceberg connector supports INSERT, UPDATE, DELETE, TRUNCATE, MERGE; writes use merge-on-read
- https://github.com/trinodb/trino/issues/17272 — "Support copy-on-write mode for Iceberg write" (still open, confirming MoR is the only Trino mode)
- https://github.com/trinodb/trino/issues/11602 — "Add INSERT OVERWRITE to Trino SQL" (confirms INSERT always appends)
- https://github.com/trinodb/trino/issues/26178 — "Can Trino support Iceberg's overwrite feature?" (further confirmation)
- https://www.starburst.io/blog/apache-iceberg-dml-update-delete-merge-maintenance-in-trino/ — Trino Iceberg DML behavior
