# Iteration 47, Q2 — Score

**Question**: Our Postgres events table is managed by pg_partman, partitioned by month on `occurred_at`, so we have child tables like `events_2026_03`, `events_2026_04`, `events_2026_05`. Our Spark ingestion job was hanging 45-60 seconds at startup when reading from the parent `events` table, so we switched to targeting child partitions directly using `dbtable='(SELECT * FROM events_2026_04) t'` for April's nightly job. The startup hang went away. But now our analytics team says April's event counts in Iceberg are 12,000 rows lower than in Postgres. Our mobile app sometimes batches events offline and uploads them a few days late — could that be the cause, and how do we fix the Spark job to catch those late-arriving rows without going back to reading the slow parent table?

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Technical verification (via WebSearch against official docs)

1. **Does pg_partman route rows by partition key value (not by insertion time)?**
   YES — confirmed via pg_partman documentation and community posts. pg_partman implements range partitioning on a partition key column; for a `occurred_at`-based monthly scheme, rows are routed to the child whose range covers the value of `occurred_at`, not the value of "now()" at insert. A row inserted on May 3 with `occurred_at = '2026-04-29 23:50'` lands in `events_2026_04`. This is exactly the late-arriving-mobile-events scenario the engineer describes.

2. **Does Iceberg `overwritePartitions()` / dynamic overwrite replace only matching partitions?**
   YES — confirmed via iceberg.apache.org (Spark Writes docs). `df.writeTo("table").overwritePartitions()` (DataFrameWriterV2) is equivalent to dynamic `INSERT OVERWRITE`: only partitions that the source DataFrame produces rows for are replaced; all other partitions are left untouched. The Spark v1 DataFrame API equivalent is `.mode("overwrite").option("overwrite-mode", "dynamic")` on Iceberg sources, which restores the Spark 2.4 dynamic-partition behavior. Both forms work on Iceberg 1.5.2 (the production stack version).

3. **Is `overwritePartitions()` idempotent and safe for re-runs?**
   YES — confirmed via the Iceberg `ReplacePartitions` Javadoc. The default validation mode for ReplacePartitions is idempotent: re-running the operation with the same source data produces the same final table state, regardless of concurrent activity on other partitions. This is exactly what makes the responder's "run April for 5–7 days after month close" recipe safe.

4. **Diagnostic SQL correctness**: The responder's `SELECT COUNT(*) FROM events_2026_04 WHERE occurred_at >= '2026-04-01' AND occurred_at < '2026-05-01'` is correct. The WHERE clause is technically redundant since pg_partman's child partition by definition only contains April rows, but adding it is defensive and harmless.

5. **Production-stack fit**: All recommended APIs work on Spark 3.x + Iceberg 1.5.2 + Hive Metastore + MinIO (the production stack per prod_info.md). The answer correctly avoids returning to the slow parent table while still solving the late-arrival problem.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every technical claim verified against iceberg.apache.org and pg_partman docs. Correctly identifies the late-arriving-events cause, correctly explains pg_partman's value-based routing, correctly uses `overwritePartitions()` semantics, correctly states idempotency. The Spark code shows `.mode("overwrite").option("overwrite-mode", "dynamic")` which is the valid v1 DataFrame API form for Iceberg dynamic partition overwrite on Iceberg 1.5.2. The phrase "atomically replace April's Iceberg partition" is accurate — each Iceberg commit is atomic and snapshot-isolated. Only nit: `dbtable="(SELECT * FROM events_2026_04) t"` does not benefit from `column`/`lowerBound`/`upperBound` JDBC partitioning unless the partition column is exposed in the subquery — minor since the example uses `column="id"` and `id` IS in `SELECT *`. |
| **Beginner clarity** | 4 | Strong narrative structure: "Your Problem Explained" front, diagnostic before fix, "Why this works" recap, scheduling table, and recovery steps. The mental model "pg_partman routes by `occurred_at` value, not by when they arrived" is named explicitly — exactly the insight a beginner needs. Beginner-clarity weak spots: "dynamic overwrite", "partition key", "overwritePartitions()", "idempotent", "atomic" appear without inline one-line plain-English glosses. A reader who has never used Iceberg will not learn from this answer what "dynamic" means in this context versus "static". |
| **Practical applicability** | 5 | Engineer leaves with: (a) confirmed root cause (late arrivals routed by `occurred_at` to April child); (b) diagnostic SQL to run on Postgres to verify; (c) runnable Spark Python code with the exact mode/option settings; (d) explicit scheduling recipe (May 1, May 3, May 7 re-runs); (e) one-time recovery plan for the existing 12,000-row gap; (f) explanation of why this avoids the parent-table hang. This is exactly the "what do I do Monday morning" output that the rubric rewards. |
| **Completeness** | 4 | Hits the core: cause confirmed, diagnostic, fix code, idempotency claim, scheduling, recovery. Two completeness gaps relative to the expected-answer outline: (1) does NOT mention the "UNION two consecutive months' child partitions" pattern as an alternative for catching cross-boundary late arrivals (an event with `occurred_at = '2026-04-30 23:50'` that arrives in May still routes to `events_2026_04`, but the engineer might want to read both `events_2026_04` and `events_2026_05` together to also catch any May rows pushed back into late April by clock skew); (2) does not discuss what happens after May 7 — i.e., a quarterly or month-end "catch-up" job for events arriving > 7 days late, or accepting that gap as a stated SLO. Minor: no mention of using a watermark on `received_at` / `inserted_at` as a more efficient incremental alternative to full re-reading the child partition. |

**Average**: (5 + 4 + 5 + 4) / 4 = **4.50**

---

## Rubric update

Topic: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
- Prior: avg 4.242 across 48 questions (per state.json notes)
- This score: 4.50
- New running avg (49 questions): ((4.242 × 48) + 4.50) / 49 ≈ 4.247
- Status: PASSED (unchanged)

---

## Notes for teacher

This answer is strong overall and validates that `resources/13-postgres-to-iceberg-ingestion.md` (or wherever the `overwritePartitions()` guidance lives) is working — the responder pulled the right API, the right semantics, and the right operational recipe. Two specific resource enhancements would lift future answers on this question class from 4.5 to ~4.75:

1. **Add a "late-arriving data on pg_partman child partitions" mini-pattern** to the ingestion resource. The pattern is:
   - pg_partman routes by partition-key VALUE, not by INSERT time (state this explicitly — it is the single most important insight for any team using time-partitioned source tables)
   - The standard fix: re-read the most recent N child partitions (typically current month + previous month) with `overwritePartitions()` on a dynamic-overwrite Iceberg target
   - The UNION-of-two-months pattern as the alternative when you also want to catch boundary late arrivals into the NEW partition: `dbtable="(SELECT * FROM events_2026_04 UNION ALL SELECT * FROM events_2026_05) t"`
   - A decision rule: 5–7 day re-run window is typical; teams with very long mobile offline tails may need a monthly or quarterly catch-up sweep

2. **Add inline plain-English glosses** for "dynamic overwrite" (= replace only the partitions present in your new data, leave all other partitions alone — contrast with static overwrite which replaces the entire table) and "idempotent" (= running it twice produces the same result as running it once; safe to retry). These two terms recur across many ingestion answers and consistently cost the responder a beginner-clarity point.

No factual bugs detected — this is a clean answer ready for production use by a SaaS engineer.
