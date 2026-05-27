# Iter 199 Q2 Judge — Federation CBO and Statistics

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.00** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings
- **Technical accuracy (5/5)**: Every load-bearing claim verified against official Trino docs (trino.io/docs/current/connector/postgresql.html):
  - "ANALYZE TABLE does NOT work on PostgreSQL connector" — CONFIRMED. Trino docs say to run ANALYZE in PostgreSQL itself; the connector does not implement Trino's ANALYZE.
  - "Connector retrieves statistics from PostgreSQL" — CONFIRMED verbatim: "The statistics are collected by PostgreSQL and retrieved by the connector."
  - "Stats live in pg_stats, populated by native ANALYZE/autovacuum" — CONFIRMED (pg_stats is the standard exposure of pg_statistic).
  - "CALL app_pg.system.flush_metadata_cache()" with parameterless signature for JDBC connectors — CONFIRMED by the docs' usage pattern (`USE example.example_schema; CALL system.flush_metadata_cache();`).
  - "SHOW STATS FOR app_pg.public.accounts" — connector-agnostic, returns distinct_values_count, nulls_fraction, row_count — CORRECT.
  - "SET SESSION join_distribution_type = 'BROADCAST' | 'PARTITIONED' | default 'AUTOMATIC'" — CORRECT session property names and semantics.
  - "Trino's ANALYZE works on Iceberg, Hive, Delta Lake" with `WITH (columns = ARRAY[...])` syntax — CORRECT for Iceberg connector.
  - The error message ("Catalog 'app_pg' does not support analyze") matches Trino's typical connector-not-supported phrasing.

- **Beginner clarity (5/5)**: Strong narrative arc — opens with the direct NO, then immediately reframes ("but this does NOT mean Postgres has no stats"). Walks through the 3-step pipeline (Postgres collects → connector retrieves over JDBC → CBO uses). Concrete SQL examples shown in both psql and Trino contexts with clear "run this where" labels. Uses plain language ("escape hatch," "build side," "shuffle") with enough context that a SaaS engineer with no OLAP background can follow. No unexplained jargon.

- **Practical applicability (5/5)**: Engineer can take immediate action. Gives exact commands for: (a) native Postgres ANALYZE, (b) verifying via pg_stats query, (c) flush_metadata_cache, (d) SHOW STATS to verify, (e) Iceberg-side ANALYZE with column array, (f) session property overrides as escape hatch. Distinguishes "real fix" (populate stats) from "escape hatch" (force join distribution type). Closes with three concrete root-cause hypotheses tailored to the engineer's scenario.

- **Completeness (5/5)**: Covers all five expected elements:
  1. ANALYZE TABLE failure on PG connector — YES, with error message.
  2. pg_stats mechanism — YES, named columns (n_distinct, null_frac) and described the JDBC retrieval.
  3. SHOW STATS verification — YES, with the specific column to check (distinct_values_count).
  4. Session property overrides — YES, both BROADCAST and PARTITIONED with the default AUTOMATIC explanation.
  5. Iceberg ANALYZE — YES, with correct column-array syntax.

  Bonus coverage: flush_metadata_cache for stale stats, root-cause hypotheses, summary table, weekly-cadence operational guidance. Nothing material is missing for the engineer's "200k Postgres × large Iceberg join is broadcasting wrong" scenario.

- **Production-stack fit**: Uses Trino 467, Iceberg, MinIO context implicitly via catalog naming (`app_pg`, `iceberg.analytics.events`). Aligns with prod_info.md (on-prem Trino 467 + Iceberg + MinIO + Postgres replica). No cloud-only or Starburst-only features recommended.

## Resource fix suggestions
None required for this question. The resource (`22-trino-federation-postgresql.md` Section 4.1A) clearly contains the source material and the responder synthesized it accurately. If anything, the answer is a near-textbook distillation of Section 4.1A's "three ANALYZE situations" table and the "full pipeline" steps — evidence that the resource is well-structured for the responder to use.

One minor optional enhancement (not a defect in this answer): the resource could add an explicit "BROADCAST + ANALYZE on Iceberg side is the canonical fix for small-Postgres × large-Iceberg" callout earlier in Section 5 — but the answer already conveyed this combination effectively.
