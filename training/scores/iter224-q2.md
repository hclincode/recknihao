# Iter 224 Q2 Judge Score

## Score: 4.20

## Topic: Trino federation cross-source connectors (cross-catalog CTAS MySQL -> Iceberg)

## What the answer got right

- **Cross-catalog CTAS validity**: Correctly confirms that `CREATE TABLE iceberg.lakehouse.invoices_snapshot WITH (...) AS SELECT * FROM billing_mysql.billing.invoices` is valid Trino syntax. Verified against Trino docs.
- **High-level execution model**: Correctly describes that the coordinator distributes the SELECT across workers; each worker opens a JDBC connection to MySQL; rows stream through Trino (not direct MySQL->MinIO).
- **Parquet write to MinIO**: Correct — workers serialize rows to Parquet and upload data files to MinIO at the table's data location.
- **Atomic metadata commit (final step)**: Correctly explains that the final atomic act is writing the metadata.json and updating the HMS pointer; before that moment, readers see nothing; after it, readers see the complete snapshot. This is the central correct intuition about Iceberg CTAS atomicity.
- **Orphan files on failure**: Correctly notes that a mid-flight crash can leave orphaned Parquet files in MinIO. This matches the known behavior documented in trinodb/trino issue #14798 — Trino does not automatically clean up data/metadata files written by a failed CTAS.
- **Partitioning syntax**: `WITH (partitioning = ARRAY['day(invoice_date)'], format = 'PARQUET')` is correct Trino Iceberg WITH-clause syntax. The two-level partition example (`['day(invoice_date)', 'bucket(tenant_id, 16)']`) is also valid and well-suited to multi-tenant invoicing.
- **`$partitions` metadata table syntax**: `iceberg.lakehouse."invoices_snapshot$partitions"` is correctly quoted and valid.
- **JDBC connection held for full CTAS duration**: Accurate. The MySQL connector keeps the connection open for the duration of the scan; there is no internal checkpointing for federated CTAS.
- **Use read replica advice**: Correct and practically valuable for the SaaS production setup.
- **Non-idempotent CTAS**: Correct — re-running CTAS against the same target name fails (or duplicates if a different name is used).
- **Cross-catalog INSERT INTO for incremental load**: Syntactically correct.
- **Watermark INSERT pattern**: Both the simple `CURRENT_DATE - INTERVAL '1' DAY` form and the `MAX(invoice_date)`-based CTE form are valid Trino SQL. The CTE form is a sound pattern.

## What the answer missed or got wrong

### MODERATE — `remove_orphan_files` procedure signature is wrong

The answer writes:
```
CALL iceberg.system.remove_orphan_files(
  schema_name => 'lakehouse',
  table_name => 'invoices_snapshot',
  older_than => TIMESTAMP '2026-05-26 00:00:00'
)
```

Verified against the Trino 481 Iceberg connector docs, the actual Trino procedure signature is:
```
CALL iceberg.system.remove_orphan_files(
  table => 'lakehouse.invoices_snapshot',
  retention_threshold => '7d'
)
```

Differences:
- Trino takes a single `table` argument as `'schema.table'`, not separate `schema_name`/`table_name`.
- Trino uses `retention_threshold` (an interval string like `'7d'`), not `older_than` with a TIMESTAMP literal.
- `retention_threshold` must be >= `iceberg.remove-orphan-files.min-retention` (default 7d) or the procedure errors out — the answer does not mention this guardrail at all.

The names the answer used (`schema_name`/`table_name`/`older_than`) are closer to the **Spark** Iceberg procedure signature, not Trino's. This is a fabricated/confused signature and an engineer who runs it verbatim will get a "procedure not found" or "unknown argument" error.

### MODERATE — "HMS registers the new table at query start" is misleading

The answer states that HMS creates a table row before any data flows and the table entry exists in HMS but points to an in-progress location. For Iceberg in Trino, the HMS pointer to a valid metadata.json is the *commit*. The atomic step that publishes the table is exactly that HMS pointer write — there is no "pre-create empty pointer, then update it" two-step. If the CTAS fails before commit, HMS typically has no entry for the table (or has a dangling entry only in some commit-failure edge cases per trinodb/trino #14798). The answer's later statement that "HMS table entry is broken" after a coordinator crash is overstated as the default outcome.

This matters because the cleanup guidance (`DROP TABLE iceberg.lakehouse.invoices_snapshot`) often will fail with "table does not exist" when the CTAS died before the metadata commit — the engineer should know to check `SHOW TABLES` first and not be surprised.

### LOW — Failure mode coverage could be more precise

- For "MySQL connection drop: Kills the query mid-SELECT. No data reaches MinIO." — this is wrong if the drop happens after workers have already written Parquet splits to MinIO. Files may already be partially written and will be orphaned in MinIO, exactly the scenario the orphan-cleanup section addresses. The "no data reaches MinIO" claim contradicts the orphan-files cleanup section.
- The answer does not mention the Trino-specific `iceberg.remove-orphan-files.min-retention` floor (7d default) or that running `remove_orphan_files` with a recent `older_than`/`retention_threshold` will be rejected unless the catalog property is lowered. An engineer cleaning up a 5-minute-old failed CTAS will hit this immediately.

### LOW — Production environment fit

The prod_info.md production environment uses Trino 467 + Iceberg connector + HMS on MinIO — the answer fits the stack. However, the answer does not call out that the JWT-authenticated Trino session is what runs this and that OPA will authorize the CREATE TABLE on the iceberg catalog and the SELECT on billing_mysql. Not required, but a nice fit-to-environment touch.

## WebSearch verification notes

- https://trino.io/docs/current/connector/iceberg.html — Confirmed: Iceberg connector supports atomic CTAS; supports `partitioning` WITH-clause property with transforms `day()`, `month()`, `bucket(col, N)`, identity; `$partitions` metadata table accessed via `"table$partitions"` quoting.
- https://trino.io/docs/current/connector/iceberg.html (remove_orphan_files) — Confirmed: Trino procedure signature is `CALL catalog.system.remove_orphan_files(table => 'schema.table', retention_threshold => 'duration', dry_run => bool, location => '...')`. The answer's `schema_name`/`table_name`/`older_than` parameters are NOT the Trino signature; they resemble older Spark Iceberg parameters.
- https://github.com/trinodb/trino/issues/14798 — Confirmed: failed Iceberg CREATE TABLE / CTAS operations leave orphaned metadata and data files; no automatic cleanup. Supports the answer's orphan-files claim but undermines the "no data reaches MinIO on connection drop" line.
- https://trino.io/docs/current/connector/mysql.html — Confirmed: MySQL connector uses one JDBC connection per table scan; the connection is held for the duration of that scan. Aligns with the answer's "CTAS holds JDBC connection open for full duration."
- https://iceberg.apache.org/docs/latest/maintenance/ — Confirmed: Iceberg atomicity is achieved by writing a new metadata.json and atomically swapping the catalog pointer; intermediate data files are not visible until the swap.

## Recommendation for teacher

**HIGH priority fixes**:
1. Correct the `remove_orphan_files` invocation in any cross-catalog CTAS / Iceberg-maintenance resource to the actual Trino signature: `CALL iceberg.system.remove_orphan_files(table => 'schema.table', retention_threshold => '7d')`. Explicitly call out that the parameter names differ from Spark Iceberg.
2. Add a note about `iceberg.remove-orphan-files.min-retention` (default 7d) — engineers cleaning up a fresh failed CTAS will need to either wait, lower this catalog property, or use the `dry_run => true` flag first.

**MEDIUM priority fixes**:
3. Clarify the Iceberg CTAS commit model: there is no pre-registered HMS row; the HMS pointer write IS the commit. After a pre-commit failure, the table typically does not exist in HMS — `DROP TABLE` may fail with "table does not exist". Tell engineers to check `SHOW TABLES IN iceberg.lakehouse LIKE 'invoices_snapshot'` first and to use `CALL iceberg.system.remove_orphan_files(...)` against the *parent schema location* or to manually delete the staging directory in MinIO when no table entry exists.

**LOW priority fixes**:
4. Make the failure-mode descriptions internally consistent: a MySQL connection drop mid-CTAS leaves orphan Parquet files in MinIO (workers may have already flushed splits), so the "no data reaches MinIO" claim should be removed.
5. Optional: mention that under the prod OPA + JWT setup, the executing JWT subject needs both SELECT on `billing_mysql.billing.invoices` and CREATE TABLE on `iceberg.lakehouse` per the centralized OPA policy.
