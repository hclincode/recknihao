# Iter 8 Q3 — DuckDB as analytics layer vs Trino: scale ceiling and migration point

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims correct: DuckDB as embedded in-process library, MinIO/S3 support via httpfs, single-machine ceiling, no multi-user concurrency, no RBAC, ~100M-row performance advantage over small Trino cluster. No factual errors. |
| Beginner clarity | 5 | Inline definition of "embedded database," plain-English table of migration signals, no unexplained jargon. "Serializes" is slightly technical but recoverable from context. One of the cleaner beginner-facing answers in the run. |
| Practical applicability | 5 | Three-step "What to do right now" section grounded in the actual prod stack (MinIO + Iceberg + Trino). "No re-engineering cost when you switch" claim is accurate because both systems target Iceberg+Parquet. Correctly identifies DuckDB for prototyping and Trino for production concurrency. |
| Completeness | 4 | Answers both sub-questions (need Trino now? No; when to move? Four concrete signals). Minor gaps: (1) DuckDB MinIO connectivity requires httpfs extension config (endpoint, credentials) — not automatic; (2) SQL dialect divergence between DuckDB and Trino (read_parquet(), interval syntax, some window functions) glossed over with "same queries work on both"; (3) remote-vs-local latency nuance for on-prem MinIO not mentioned. None are blockers at this stage. |
| **Average** | **4.75** | |

## Topic updated

**Topic**: Popular tools overview: BigQuery, Snowflake, ClickHouse, DuckDB, Iceberg

- Prior avg: 4.75 (1 question, Iter 4 Q3)
- This question score: 4.75
- New running avg: (4.75 + 4.75) / 2 = **4.75** across 2 questions
- Status: **PASSED** (avg 4.75 >= 3.5 threshold, 2 questions from different angles)

## Key finding

The answer correctly positions DuckDB as a legitimate prototyping tool within the production stack (MinIO + Iceberg + Trino) and gives four concrete signals for when to graduate to Trino — without requiring the engineer to build anything new. The "no re-engineering cost" framing is accurate for the Iceberg+Parquet foundation.

## Resource gap

Minor: the resources should note that DuckDB requires the httpfs extension configured with MinIO endpoint and credentials before it can read from MinIO — "reads Parquet files directly from MinIO" is true but omits the one-time setup step that will block a first-time user. A single config snippet in the tools overview resource would prevent confusion.
