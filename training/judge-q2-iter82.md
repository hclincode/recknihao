# Judge Score — Iter 82 Q2

## Score: 4.875 / 5.0
| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4.75 |

## Points covered
Watermark-based incremental ingestion checklist points hit:
1. **Watermark mechanics (updated_at as cutoff)** — covered with `WHERE updated_at > last_watermark` example and explicit explanation of what gets pulled.
2. **Append vs MERGE INTO duplicate behavior** — covered explicitly: `.append()` creates duplicate copies on `user_id`; MERGE INTO updates-in-place via primary-key join. Stale-row problem named directly.
3. **MERGE INTO Spark SQL syntax for upserts** — full runnable example with `WHEN MATCHED THEN UPDATE SET *` / `WHEN NOT MATCHED THEN INSERT *`. Idempotency on retry called out.
4. **updated_at vs created_at decision** — clear rule: `updated_at` is the default for mutable tables (catches updates), `created_at` is acceptable only for append-only tables (page_views, webhook_events, audit_log). Trap of `created_at` on mutable tables described concretely (stale soft-deletes after 3 months).
5. **Trigger fallback to enforce updated_at = now()** — concrete Postgres trigger function and BEFORE INSERT OR UPDATE trigger included.
6. **Lag buffer pattern (subtract safety margin from saved watermark)** — full rationale (read replica lag, in-flight rows at boundary), runnable Python pattern with `timedelta(minutes=15)`, P99 sizing guidance.
7. **Why re-reading the boundary is safe with MERGE INTO** — explicitly stated: matched rows get UPDATE in place, no duplicate accumulation.
8. **Late-arriving rows trap** — concrete 4-step timeline (May 20 events arriving May 23) showing MERGE INTO handles it correctly while `overwritePartitions()` would silently drop existing rows.
9. **Postgres index check on watermark column** — pg_indexes query included as preflight.
10. **End-to-end runnable example** — final code block ties JDBC read + MERGE INTO + watermark write with lag buffer.

## Accuracy notes
WebSearch verification against iceberg.apache.org/docs/latest/spark-writes/ and the Iceberg cookbook:
- **MERGE INTO with `WHEN MATCHED THEN UPDATE SET *` and `WHEN NOT MATCHED THEN INSERT *`** — confirmed as supported Iceberg/Spark 3 syntax. Schema mismatch resolved at runtime.
- **`.append()` does not deduplicate** — confirmed via apache/iceberg issue #7554 and #1637: Iceberg appends do not check primary keys; identical rows produce duplicates that queries will double-count.
- **updated_at preferred over created_at for incremental loads** — confirmed: standard pattern across the Iceberg cookbook, Snowflake-on-Iceberg view patterns, and Netflix Maestro write-up. The created_at trap on mutable tables is a real and frequently cited pitfall.
- **Lag-buffer pattern (subtract safety window before saving watermark)** — this is a widely documented "safety overlap" pattern in incremental ETL (Azure Data Factory docs, Iceberg/Spark incremental processing blogs). The Iceberg-specific snapshot-watermark approach (storing event-time watermark in snapshot summary) is an alternative but more advanced pattern; the answer's lag-buffer + MERGE INTO pattern is the right introductory recommendation for an engineer just starting incremental loads from Postgres.
- **MERGE INTO idempotency on retry** — confirmed; the join-on-key + UPDATE SET * means re-running the same delta produces the same end state.

## Issues / gaps
Minor deductions only — this is a strong answer.

**Technical accuracy (−0.25)**:
1. **`df.agg({"updated_at": "max"}).collect()[0][0]` after MERGE** — `df` is the JDBC-read DataFrame; calling `.collect()` on it after the MERGE re-executes the JDBC read (Spark lazy evaluation) and could double-pull from Postgres or hit an inconsistent snapshot. The robust pattern is to `cache()` or `persist()` the delta DataFrame before the MERGE, or compute `max_ts` before the MERGE and reuse it. A short caveat about caching would tighten this.
2. **MERGE INTO subtle behavior on identical rows** — Iceberg's MERGE rewrites data files for matched rows even when the source and target values are identical, which can produce write amplification on every re-merge of the lag-buffer window. For the engineer this is fine in practice (compaction handles it), but the answer's "remerges the same rows with the same result — no additional duplicates" is true at the logical level but glosses over the metadata/file-rewrite cost. Not a wrong claim, just understated.

**Completeness (−0.25)**:
1. **Hard deletes**: the question is focused on updates/inserts and the answer correctly stays on that, but a one-line callout that "DELETE in Postgres is invisible to an `updated_at` watermark" would round out the safety story. The engineer will hit this within a month.
2. **Watermark storage location**: `read_watermark()` / `write_watermark()` are referenced as if they exist; a one-liner about where the watermark file actually lives (a tiny JSON object on MinIO via the S3 API in the on-prem env, or a row in a small Iceberg metadata table) would close the loop. The throwaway "from a JSON file in MinIO" is in a comment but not shown in code.
3. **Production-environment fit**: the answer assumes Spark + Iceberg + MinIO via JDBC and is correctly aligned with `prod_info.md`. No cloud-only services referenced. Trino is not mentioned, which is correct — ingestion is Spark in this stack.

**Beginner clarity**: no deductions. The "stale email" scenario, the "users churn numbers are wrong three months later" trap, and the May 20/May 23 late-arrival timeline are all concrete and grounded.

**Practical applicability**: no deductions. End-to-end runnable code; the pg_indexes preflight check is exactly the kind of "next thing the engineer should actually do" that earns a 5.

## Resource fix needed?
**No** — minor polish only. Topic remains well above pass threshold (~4.45 across 77 questions after this entry). Optional polish for `resources/13-postgres-to-iceberg-ingestion.md` if the teacher revisits:
- Add a one-line note about `.cache()` / `.persist()` on the delta DataFrame before MERGE INTO so the post-merge `agg().collect()` for max watermark doesn't trigger a re-read.
- Add a one-line callout that hard deletes are invisible to `updated_at` watermarks (the answer is consistent with the question, but the resource should cover it for completeness).
- Optionally show the watermark JSON read/write helper code (S3 object on MinIO) so engineers don't reinvent it.

## Sources verified
- https://iceberg.apache.org/docs/latest/spark-writes/ — Spark MERGE INTO with UPDATE SET * / INSERT * confirmed.
- https://github.com/apache/iceberg/issues/7554 — append does not dedupe; primary-key duplicates are the user's responsibility.
- https://github.com/apache/iceberg/issues/7005 — MERGE write-amplification on no-op matches.
- https://netflixtechblog.com/incremental-processing-using-netflix-maestro-and-apache-iceberg-b8ba072ddeeb — snapshot-based watermark approach (the more advanced alternative the answer correctly does not introduce here).
- https://medium.com/datamindedbe/upserting-data-using-spark-and-iceberg-9e7b957494cf — confirms MERGE INTO upsert pattern for Iceberg.
