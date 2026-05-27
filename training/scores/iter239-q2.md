# Score: iter239-q2 — ANALYZE TABLE Iceberg Cross-Catalog

**Score: 4.9 / 5.0**

## What was correct

1. **ANALYZE syntax (no `TABLE` keyword)** — VERIFIED. Trino's official syntax is `ANALYZE table_name [WITH (...)]`. The answer's explicit warning that `ANALYZE TABLE iceberg.analytics.user_events` is a parser error is correct and is exactly the foot-gun the engineer's coworker (who said "ANALYZE TABLE") would hit. (trino.io/docs/current/sql/analyze.html)

2. **`columns` is the only Iceberg property; `partitions` is Hive-only** — VERIFIED. The Iceberg connector docs explicitly show `WITH (columns = ARRAY[...])` as the supported property; `partitions` is documented under the Hive connector ANALYZE only. (trino.io/docs/current/connector/iceberg.html)

3. **Puffin file + Theta sketches for NDV** — VERIFIED. The Iceberg Puffin spec explicitly defines `apache-datasketches-theta-v1` as the blob type for NDV sketches; Trino writes these. The answer's framing of "tiny sketches that answer NDV in O(1) without rescanning" is accurate and pedagogically clean. Filename pattern `*.stats` next to manifest files is correct. (iceberg.apache.org/puffin-spec/)

4. **`SHOW STATS FOR <catalog>.<schema>.<table>`** — VERIFIED as the correct introspection command. Output column names (`column_name`, `data_size`, `distinct_values_count`, `nulls_fraction`, `row_count`) match the Trino docs verbatim. (trino.io/docs/current/sql/show-stats.html)

5. **`ALTER TABLE ... EXECUTE drop_extended_stats`** — VERIFIED. The Iceberg connector docs explicitly note: "If statistics were previously collected for all columns, they must be dropped using the drop_extended_stats command before re-analyzing." The answer's footgun warning about the old Puffin file shadowing a column-targeted refresh is correct and rarely covered — strong practical value.

6. **Cross-catalog join planning genuinely benefits from ANALYZE** — VERIFIED. Trino docs on cost-based optimizations confirm that with AUTOMATIC join enumeration and distribution selection, the CBO uses connector-provided statistics to (a) pick build vs probe side and (b) choose broadcast vs partitioned distribution — regardless of whether the join can be pushed down. The answer correctly nails the nuance that the join itself never pushes across catalogs but planning still benefits.

7. **PostgreSQL connector needs native ANALYZE on Postgres side** — VERIFIED. Trino's PostgreSQL connector reads `pg_stats` automatically — there is no Trino-side ANALYZE for the JDBC table. The answer correctly tells the engineer to run `ANALYZE public.accounts` in psql (not in Trino) and to verify with `SHOW STATS FOR pg_catalog.public.accounts`. This was the *exact* gap the rubric flagged from iter160 Q2 (the catastrophic "no ANALYZE needed" failure that raised this topic's pass threshold to 4.5) — now fully closed.

8. **`join_max_broadcast_table_size` default of 100MB** — VERIFIED against trino.io/docs/current/optimizer/cost-based-optimizations.html: "By default, the replicated table size is capped to 100MB."

9. **Production stack fit** — Names MinIO as the storage backend for the Puffin file path, references Iceberg+Trino correctly, and uses the on-prem federation pattern (Postgres connector + Iceberg connector). No cloud-only tools recommended.

## What was wrong or missing

Very minor:

1. **Theta vs HLL sketches** — The answer says "Theta or HLL sketches." For Iceberg/Trino specifically, the Puffin spec defines `apache-datasketches-theta-v1` as the NDV blob type; HLL is used by other connectors (e.g., Hive). Saying "Theta or HLL" is not wrong (both are valid sketch families and the broader Trino docs mention both) but for Iceberg the concrete answer is Theta. Pedagogically harmless.

2. **NDV example numbers** — `account_id | 2.5E2` (250 distinct accounts) for a 500M-row events table is plausible but synthetic. The output format shown (`8.0E6` for data_size of `account_id`) is the correct scientific-notation form Trino emits. Not a defect.

3. **One micro-nuance not mentioned** — `SHOW STATS FOR (<query>)` form (against a subquery, not just a table) is not mentioned. Irrelevant to the question asked.

4. **Cadence ("typical: weekly, or after any backfill")** — reasonable rule of thumb; not officially documented but a fair recommendation. Not a defect.

## Verification notes

- WebSearch confirmed `ANALYZE table_name WITH (columns = ARRAY[...])` is the correct syntax; `ANALYZE TABLE ...` would parse-fail.
- WebSearch confirmed the Iceberg connector only supports the `columns` property; `partitions` is Hive-only.
- WebSearch + iceberg.apache.org/puffin-spec confirmed Puffin format with Theta-sketch NDV blobs is what Trino writes.
- WebSearch confirmed `SHOW STATS FOR` syntax and the five column names returned.
- WebSearch confirmed `ALTER TABLE ... EXECUTE drop_extended_stats` is the correct command and the documented prerequisite before a column-narrowed re-ANALYZE.
- WebSearch confirmed Trino's PostgreSQL connector pulls stats from PostgreSQL's `pg_stats` automatically and that the user must run native `ANALYZE` on the Postgres side.
- WebFetch of trino.io/docs/current/optimizer/cost-based-optimizations.html confirmed the 100MB default for `join_max_broadcast_table_size`.

## Recommendation for teacher

This is one of the strongest CBO/ANALYZE answers the responder has produced. It directly addresses the exact failure mode (iter160 Q2) that raised this topic's pass threshold to 4.5 — namely, conflating "Trino CBO uses stats automatically" with "no ANALYZE is needed." The answer correctly says: yes ANALYZE is needed on the Iceberg side, AND native PostgreSQL ANALYZE is needed on the Postgres side, AND the cross-catalog join itself never pushes but the CBO planning decisions absolutely benefit from both sets of stats.

Recommendations (all LOW priority):

1. **resources/23-iceberg-cbo-analyze.md (or wherever Iceberg ANALYZE is canonical)** — clarify that for Iceberg specifically the Puffin NDV blob is `apache-datasketches-theta-v1` (Theta), not HLL. Both are valid sketch families in Trino broadly, but the responder consistently writes "Theta or HLL" when Iceberg writes Theta.

2. **resources/22-trino-federation-postgresql.md** — the "three ANALYZE situations" table is already excellent. Consider adding a one-line callout that `ANALYZE TABLE ...` (with the `TABLE` keyword) is the *specific* incorrect form coworkers will suggest (carried over from Spark / Hive / MySQL muscle memory) so future answers can preempt it. This answer already did that proactively, which is the behavior to keep.

3. Topic running average is already 4.717 over 3 questions, and this answer pushes it higher with the highest-stakes question phrasing yet (cross-catalog + ANALYZE + Puffin + drop_extended_stats all in one). The topic is well above the 4.5 raised threshold.
