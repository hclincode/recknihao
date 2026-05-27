# Score: iter238-q1 — DF Wait-Timeout Catalog Placement

**Score: 4.85 / 5.0**

## What was correct

- **Probe-side rule is correct**: `dynamic-filtering.wait-timeout` lives on the catalog *receiving* the DF (probe side). For Iceberg-probe × PostgreSQL-build, it belongs in `etc/catalog/iceberg.properties`. This is the exact fix called out in iter237 feedback and the answer nails it.
- **Iceberg default of 1 second** is verified correct against trino.io/docs/current/connector/iceberg.html.
- **PostgreSQL/JDBC default of 20 seconds** is verified correct (PR #13334 and Trino PostgreSQL connector docs).
- **`dynamicFilterSplitsProcessed`** is the correct EXPLAIN ANALYZE field name, per Trino's admin/dynamic-filtering.html.
- **Per-session syntax `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s'`** uses the correct pattern: catalog-name prefix + underscored property name. Matches Trino SET SESSION docs for catalog session properties.
- **Correctly flags that setting wait-timeout on the PostgreSQL catalog "has no effect"** for this build-side direction — verified true: PostgreSQL here produces the DF, doesn't wait for one.
- Build/probe identification is correct: 50K PostgreSQL = build, 800M Iceberg = probe.
- The diagnostic narrative ("1s default fires before PostgreSQL publishes the IN-list") is technically sound and matches the engineer's "zero splits pruned" symptom.
- EXPLAIN ANALYZE VERBOSE is recommended (correct — runtime stats need ANALYZE; VERBOSE gives the dynamic filter domain detail).
- Mentions restart vs. session as the workaround, which is immediately actionable.
- Property key in the file is also correct: in `iceberg.properties` you write `dynamic-filtering.wait-timeout=20s` (no `iceberg.` prefix in the catalog file itself — the catalog filename provides the namespace). The answer shows this correctly.
- Wait, double-check: the answer writes `iceberg.dynamic-filtering.wait-timeout=20s` in `etc/catalog/iceberg.properties`. This is a minor inconsistency — see "What was wrong" below.

## What was wrong or missing

- **Minor property-prefix nit (only real issue)**: in `etc/catalog/iceberg.properties` the catalog properties are written **without** the `iceberg.` prefix (the filename provides the namespace). The line should be `dynamic-filtering.wait-timeout=20s`, not `iceberg.dynamic-filtering.wait-timeout=20s`. The answer's snippet writes `iceberg.dynamic-filtering.wait-timeout=20s` which is incorrect for a catalog properties file. Per-session form correctly uses the `iceberg.` prefix; the catalog file should not.
- **Minor**: The "PostgreSQL rarely finishes scanning 50K rows in 1 second" claim is reasonable as intuition, but PostgreSQL is usually fast on 50K rows — the more accurate culprit is often **JDBC round-trip + Trino DF aggregation overhead** rather than the Postgres scan itself. Not factually wrong, but slightly oversimplified.
- Does not mention that **dynamic filtering on Iceberg is also row-level (DRF)** within Parquet files, not only file-level pruning. For this question that nuance isn't strictly required, so this is a small completeness gap, not a critical one.
- No mention of production environment constraints (Trino 467, MinIO, Hive Metastore). Not load-bearing for this question but the answer is environment-agnostic.

## Verification notes

Verified via WebSearch against official trino.io docs:
1. **Probe-side property placement**: Confirmed — Trino dynamic filtering admin docs and connector docs both treat `dynamic-filtering.wait-timeout` as a property on the catalog that *receives* the DF (the probe scan delays until it arrives).
2. **Iceberg default 1s**: Confirmed via trino.io/docs/current/connector/iceberg.html — "Maximum duration to wait for completion of dynamic filters during split generation. Default: 1s".
3. **JDBC default 20s**: Confirmed via PR #13334 and PostgreSQL connector docs — "table scans on the connector are delayed up to 20 seconds until dynamic filters are collected from the build side of joins".
4. **`dynamicFilterSplitsProcessed`**: Confirmed via trino.io/docs/current/admin/dynamic-filtering.html — "records the number of splits processed after a dynamic filter is pushed down to the table scan".
5. **Per-session syntax**: Confirmed pattern `<catalog>.dynamic_filtering_wait_timeout = '<duration>'` via Trino SET SESSION docs (catalog session properties use the `catalogname.property_name` form with underscores).
6. **Catalog properties file: no `iceberg.` prefix**: Trino convention — catalog filename provides the namespace, so the property key inside the file is `dynamic-filtering.wait-timeout`, not `iceberg.dynamic-filtering.wait-timeout`. The answer's code snippet has this prefix incorrectly added.

## Recommendation for teacher

- **Small fix in resources/22-trino-federation-postgresql.md**: when showing the catalog properties file snippet, ensure the example reads `dynamic-filtering.wait-timeout=20s` (NOT `iceberg.dynamic-filtering.wait-timeout=...`) since the catalog name is implicit in the filename. The per-session form correctly keeps the `iceberg.` prefix.
- Consider adding one explicit table that contrasts:
  - **In `etc/catalog/iceberg.properties`**: `dynamic-filtering.wait-timeout=20s` (no prefix)
  - **In SQL session**: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';` (prefix + underscores)
  Many SaaS engineers confuse these.
- The current resource coverage (sections 2914–2978) is solid; the answer faithfully reflects it. Just fix the file-snippet prefix issue so the weak-ai-responder copies it correctly next time.
