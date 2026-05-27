# Iter 201 Q2 Judge — Federate vs Ingest Decision Framework

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

- **JDBC throughput claim (100K-200K rows/sec) is in a plausible range.** Public benchmarks reference about 37 MB/sec for a 32 GB Postgres-over-JDBC extraction (Starburst blog). Depending on row width (~200-500 bytes), 37 MB/sec maps to roughly 75K-200K rows/sec, so the answer's 100K-200K rows/sec citation for a non-selective Postgres JDBC scan is realistic and well-calibrated. The numeric examples (2M rows in 20-40s; 500M rows in 40+ minutes) line up with that math.
- **"1 JDBC connection per non-selective table scan" claim is correct.** Confirmed by Trino issue #389 and the PostgreSQL connector design: the OSS Trino PostgreSQL connector reads non-partitioned tables via a single split / single JDBC connection. The answer captures this implicitly (single-threaded JDBC scan timings) and the underlying resource file's Section 4.4 explicitly documents the single-split model. No technical regression introduced.
- **Hybrid pattern (UNION ALL: old Iceberg + live Postgres tail) is a recognized lakehouse pattern.** Lambda-style "historical from data lake + live tail from source" patterns are well-documented in the Trino ecosystem (e.g., Starburst, Redpanda blog on federated queries). The specific implementation given — splitting on `created_at` boundary at `current_timestamp - INTERVAL '1 HOUR'` — is sound, although it only covers append/insert-time freshness for `customers`. A purist would note the pattern works cleanly only for the events-style append case; for `customers` UPDATE traffic, the live tail filtered by `created_at` misses updates to old rows (would need `updated_at` filter instead, or the pattern should be applied to events, not customers). This is a minor caveat, not an outright error — the answer presents it as a freshness-bridging pattern with the right caveats and tradeoffs.
- **MERGE INTO guidance for the customers table is technically sound.** Trino 467's Iceberg connector supports MERGE INTO on v2-format tables (verified against trino.io docs). The "incremental MERGE on `updated_at` watermark with a 15-30 min lag buffer" is the standard CDC-lite idempotent ingestion pattern. Good production guidance.
- **Two-table guidance is well-reasoned and concrete.** The decision (ingest both) matches what an experienced data engineer would do: 500M append-only events is the textbook ingestion case, and 2M customers with frequent updates is large enough that JDBC scans hurt and MERGE INTO is the right tool. The "what breaks first" enumeration (dashboard latency → replica lag → connection saturation) is operationally accurate and ordered the way it actually happens in production.
- **Coverage of the four decision criteria is complete.** Freshness SLO, change pattern, query complexity (broadcast vs shuffle, dynamic filtering), Postgres load on replica — all addressed with specifics, not hand-waving. Decision matrix at the end gives concrete cutoffs.
- **Production-stack fit (per prod_info.md):** All recommendations align — Trino 467 + Iceberg + Hive Metastore + Spark for ingestion. No cloud-only services, no incompatible tooling. The hybrid view example uses standard Trino SQL.
- **Beginner clarity:** Jargon ("broadcast join", "dynamic filtering", "MERGE INTO", "watermark") is used but each appears in a context that makes its purpose clear, and the bottom-line answer ("ingest both") is stated explicitly without requiring the reader to derive it.

## Resource fix suggestions

- Minor: the hybrid UNION ALL example uses `created_at` as the boundary column for `customers`. For an UPDATE-heavy dimension like customers, this misses updates to old rows. The resource (or a future answer) could note that the live-tail pattern is most natural for append-only / insert-time-stamped tables; for UPDATE-heavy tables, the boundary should use `updated_at`, and the ingested side must dedupe the most recent record per key (e.g., via a window function or by treating the Iceberg side as a snapshot frozen at `now() - 1h`).
- Optional: cite the specific Trino issue (#389) or the single-split documentation when explaining the JDBC throughput ceiling, so engineers can read the upstream rationale themselves.
- Optional: add a quick note that `defaultRowFetchSize=1000` on the JDBC URL avoids the "load entire result set into memory" default behavior — directly relevant when the engineer experiments with federation before committing to ingestion.

No required topic regressions; resource 22 is in good shape. This answer is production-ready for a SaaS engineer making the federate-vs-ingest call.
