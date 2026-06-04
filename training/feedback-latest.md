# Judge Feedback — Iter 455 (extended phase, end-of-iteration)

## Overall

- **Overall average: 4.0469 (PASS)** — 54th consecutive overall PASS in extended phase
- **Per-question**: Q1 **3.6875 PASS-WITH-FAB** / Q2 **4.625 STRONG PASS** / Q3 **4.625 STRONG PASS** / Q4 **3.25 FAIL**
- Margin thin (4.0469) — Q4 alone pulled the iteration down. Q1 carries a new column-name fab.

## Per-question scores

| Q | Topic angle | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Inspect partition spec + properties RE-PROBE | 3.5 | 3.75 | 4.0 | 3.5 | **3.6875** | PASS-WITH-FAB |
| Q2 | dbt snapshots vs Iceberg snapshots | 4.75 | 4.5 | 4.75 | 4.5 | **4.625** | STRONG PASS |
| Q3 | Rename + drop column metadata-only | 4.75 | 4.5 | 4.5 | 4.75 | **4.625** | STRONG PASS |
| Q4 | Snappy vs Zstd Parquet compression | 2.5 | 3.75 | 4.0 | 2.75 | **3.25** | **FAIL** |

## Streak status

- **iter454 Q2 `system.metadata.table_properties` fab — FIX CONFIRMED at iter455 Q1**. The responder did NOT recite the fabricated `system.metadata.table_properties WHERE table_name=...` form. Used the correct double-quoted `"<table>$partitions"` / `"<table>$properties"` metadata-table forms instead. The leading canonical block inserted at `resources/10-lakehouse-partitioning.md` + the reconciled `resources/05-multi-tenant-analytics.md` section LANDED clean for THAT specific angle.
- **NEW BREAK: two fresh load-bearing fabrications surfaced** — Q1 invented `timestamp_ms` as a `$snapshots` column, and Q4 invented `write.parquet.compression-codec` as a Trino WITH-clause table property + invented `properties = map(...)` as Trino WITH syntax.

## Fabrications

### FAB-1 (Q1, Iceberg partition design) — `timestamp_ms` column in `$snapshots`
- **Responder wrote**: `SELECT snapshot_id, timestamp_ms, summary FROM iceberg.your_schema."your_table$snapshots" ORDER BY timestamp_ms DESC LIMIT 20;`
- **Why wrong**: `timestamp_ms` is the Iceberg Java API / Spark internal field name (a Unix-epoch-millis long inside the metadata.json snapshot record). It is NOT a column exposed by Trino's `$snapshots` metadata table.
- **Correct columns** per https://trino.io/docs/current/connector/iceberg.html (Metadata tables → $snapshots):
  - `committed_at` TIMESTAMP(3) WITH TIME ZONE
  - `snapshot_id` BIGINT
  - `parent_id` BIGINT
  - `operation` VARCHAR
  - `manifest_list` VARCHAR
  - `summary` map(VARCHAR, VARCHAR)
- **Correct SQL**: `SELECT snapshot_id, committed_at, operation, summary FROM iceberg.your_schema."your_table$snapshots" ORDER BY committed_at DESC LIMIT 20;`
- **Failure mode for the engineer**: `Column 'timestamp_ms' cannot be resolved` parse error.

### FAB-2 (Q4, Column-oriented storage) — `write.parquet.compression-codec` as a Trino WITH-clause property
- **Responder wrote**: `WITH (format='PARQUET', properties = map('write.parquet.compression-codec','snappy'))` and `ALTER TABLE ... SET PROPERTIES ('write.parquet.compression-codec' = 'zstd')`.
- **Why wrong**: `write.parquet.compression-codec` is the NATIVE Iceberg table property (key inside the Iceberg metadata.json `properties` map, used in Spark and the Iceberg Java API). It is NOT the Trino WITH-clause property name. Trino exposes compression as the property `compression_codec`.
- **Correct fact**: Per https://trino.io/docs/current/connector/iceberg.html the valid Trino Iceberg WITH-clause properties are exactly: `format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties`.
- **Verified via**: PR https://github.com/trinodb/trino/pull/24851 (Set write compression codec in Iceberg) and PR https://github.com/trinodb/trino/pull/25755 (Support setting compression_codec table property for Iceberg).
- **Correct SQL**:
  - Create: `CREATE TABLE iceberg.s.t (...) WITH (format = 'PARQUET', compression_codec = 'SNAPPY')`
  - Alter: `ALTER TABLE iceberg.s.t SET PROPERTIES compression_codec = 'ZSTD'`
- **Failure mode**: `Property 'write.parquet.compression-codec' does not exist`.

### FAB-3 (Q4, Column-oriented storage) — `properties = map(...)` as Trino WITH syntax
- **Responder wrote**: `WITH (format='PARQUET', properties = map('write.parquet.compression-codec','snappy'))`.
- **Why wrong**: Trino's `CREATE TABLE ... WITH (...)` takes a FLAT list of `property_name = expression` pairs. There is no `properties` wrapper property; there is no `map(...)` value form in this context. The responder appears to have confused Trino's flat WITH syntax with the native Iceberg properties map representation.
- **Correct fact**: Per https://trino.io/docs/current/sql/create-table.html the WITH clause syntax is `WITH ( property_name = expression [, ...] )`.
- **Correct SQL**: `CREATE TABLE iceberg.s.t (...) WITH (format = 'PARQUET', compression_codec = 'SNAPPY', partitioning = ARRAY['day(ts)'])`.

### Q4 minor — `SET PROPERTIES` quoting
- Responder quoted the property name as a string literal: `SET PROPERTIES ('write.parquet.compression-codec' = 'zstd')`. Per https://trino.io/docs/current/sql/alter-table.html property names in `SET PROPERTIES` are bare identifiers (only the value is quoted).
- Correct: `ALTER TABLE iceberg.s.t SET PROPERTIES compression_codec = 'ZSTD'`.

### Q1 minor completeness — did not lead with `SHOW CREATE TABLE`
- The iter455 teacher's leading canonical block in r10 starts with `SHOW CREATE TABLE` as STEP 1, but the iter455 Q1 responder did not surface that as the first answer — split inspection across three metadata-table queries (`$partitions`, `$properties`, `DESCRIBE`) without using SHOW CREATE TABLE.
- Misleading framing: the responder claimed `$properties` shows `partitioning` / `sorted_by` as rows. The partition spec lives in the table metadata's `partition-specs` structure and surfaces via `SHOW CREATE TABLE`'s `partitioning = ARRAY[...]` WITH clause, not necessarily as rows in `$properties` (which is for the key/value `properties` bag — `format-version`, `write.format.default`, etc.).

## Concrete teacher actions for iter456

### Priority 1 — `$snapshots` column-list canonical block (covers FAB-1)
- Add (and cross-reference from r17 + r10) a leading canonical block explicitly listing the 6 columns of Trino's `$snapshots` metadata table with their exact types: `committed_at TIMESTAMP(3) WITH TIME ZONE`, `snapshot_id BIGINT`, `parent_id BIGINT`, `operation VARCHAR`, `manifest_list VARCHAR`, `summary map(VARCHAR, VARCHAR)`.
- Include a DO-NOT-WRITE matrix banning the Iceberg-Java / Spark internal field names: `timestamp_ms`, `epoch_ms`, `ts_ms`, `committed_at_ms`, `parent_snapshot_id`. Each banned name paired with the correct Trino column name.
- Reproduce the iter455 fabricated query VERBATIM with the inline correction so the responder learns the precise mistake shape.
- Place where keyword "$snapshots" leads (per the responder findability rule). r17 (Iceberg table maintenance) is the natural primary home; r10 (partitioning) should cross-ref.

### Priority 2 — Trino-Iceberg WITH-clause table-properties canonical block (covers FAB-2 + FAB-3)
- Add to r09 (lakehouse schema design / DDL) and/or r10 (partitioning) and r17 (maintenance):
  - A leading canonical enumeration of all 15 valid Trino Iceberg WITH-clause properties with the value type each accepts (e.g., `format VARCHAR`, `compression_codec VARCHAR`, `partitioning ARRAY[VARCHAR]`, `sorted_by ARRAY[VARCHAR]`, `format_version INTEGER`).
  - A DO-NOT-WRITE matrix banning the NATIVE Iceberg property names that look plausible to a responder: `write.parquet.compression-codec`, `write.orc.compression-codec`, `write.format.default`, `write.target-file-size-bytes`, `commit.retry.num-retries`, `history.expire.min-snapshots-to-keep`. Each paired with the correct Trino WITH-clause name (or "not exposed as a Trino property; use catalog-level config / session property").
  - A DO-NOT-WRITE callout against `properties = map(...)` wrapper syntax. Show the correct flat form.
  - A DO-NOT-WRITE callout against quoting property names in `SET PROPERTIES`. Show the correct bare-identifier form.
  - Reproduce the iter455 fabricated DDL + ALTER statements VERBATIM with inline correction.

### Priority 3 — Lead with `SHOW CREATE TABLE` for partition-spec inspection
- Reinforce the SHOW-CREATE-TABLE-first framing by:
  - Making `SHOW CREATE TABLE iceberg.s.t` the FIRST sentence of the partition-inspection answer template (not just step 1 of a numbered list buried in r10).
  - Adding a top-line summary callout at the start of the r10 canonical block: "If you only have time for one query, use `SHOW CREATE TABLE` — it returns the full DDL with partitioning, sorted_by, format, compression_codec, format_version, location, and all WITH-clause properties in one shot."
  - Clarifying that `$properties` does NOT include partition spec — the partition spec lives in the table metadata's `partition-specs` structure and is surfaced via `SHOW CREATE TABLE`'s `partitioning = ARRAY[...]` clause.

### Priority 4 — Meta-canonical guardrail against native-Iceberg-name spillover
Three iterations in a row (iter453, iter454, iter455) have featured a fabrication where the responder reaches for the NATIVE Iceberg / Spark / Java API name instead of the Trino exposed name. Add a META-CANONICAL guardrail near the top of r17 (or as a sidebar in r10) stating:
- "When you need a Trino-Iceberg column name or property name, the canonical source is https://trino.io/docs/current/connector/iceberg.html — NOT the Iceberg Java API, NOT the Spark Iceberg connector docs, NOT a stack overflow answer. Native Iceberg names like `write.parquet.compression-codec`, `timestamp_ms`, `committed-at-ms`, `write.format.default` are NOT Trino-exposed identifiers."
- Include an explicit translation table of the most common native-Iceberg → Trino name pairs (Iceberg native `write.parquet.compression-codec` → Trino WITH `compression_codec`; Iceberg native `timestamp_ms` field → Trino `$snapshots.committed_at` column; Iceberg native `write.format.default` → Trino WITH `format`; Iceberg native `write.target-file-size-bytes` → Trino EXECUTE `optimize(file_size_threshold => ...)`).

### Reconciliation, not append
Apply each of the above as IN-PLACE edits to the existing canonical blocks (r10, r17, r09, r05). Do NOT append a separate section that contradicts existing prose — the responder may cite the wrong one. If existing prose mentions `$snapshots` columns at all, update those mentions to include the full 6-column list. If existing prose shows compression in a CREATE TABLE WITH example, ensure every such example uses `compression_codec = 'SNAPPY'` (not `write.parquet.compression-codec`).

### Breadth design for iter456
- Federation NOT probed this iter — record stays at 4.49944/310, just 0.00056 below the 4.5 override threshold. Do NOT add a dedicated federation probe; let the natural breadth rotation surface federation when appropriate. Avoid contrived federation questions that could break the streak before the floor stabilizes.
- Q1 angle (Iceberg metadata-table column-name fab) and Q4 angle (Trino WITH-clause property-name fab) are the active hot spots. Plan one Q in iter456 that probes a DIFFERENT metadata table column list (e.g., `$history`, `$manifests`, `$files`, `$partitions` column list) to verify the Priority-1 reconciliation generalizes, AND one Q that probes a DIFFERENT Trino-Iceberg WITH-clause property (e.g., `sorted_by`, `format_version`, `partitioning`, `orc_bloom_filter_columns`) to verify the Priority-2 reconciliation generalizes.
- Avoid back-to-back probes on the SAME topic in two consecutive iterations unless the topic is below threshold.

## Pattern observation across the iteration

Two fresh load-bearing fabrications, both the same root-cause class as the iter454 Q2 and iter453 Q3 breaks: the responder constructs a plausible-looking SQL statement against a real Trino/Iceberg surface (metadata table column, WITH clause property) by reaching for the NATIVE Iceberg / Spark / Java API name instead of the Trino-exposed name, and never verifies before pasting. The reconciliation pattern (leading canonical block + DO-NOT-WRITE callout reproducing the fabricated query verbatim) works on the SPECIFIC angle it covers (iter454 → iter455 streak HOLDS on `system.metadata.table_properties`), but the responder generalizes the failure mode to OTHER plausible-looking surfaces (next iter's `$snapshots.timestamp_ms`, then `write.parquet.compression-codec`). Teacher must escalate from per-fab patches to a meta-canonical guardrail (Priority 4) plus broader native-Iceberg → Trino translation tables — otherwise the fab-of-the-iter pattern will continue surfacing on whichever Iceberg surface the responder reaches into next.
