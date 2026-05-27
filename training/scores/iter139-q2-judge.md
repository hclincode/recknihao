# Iter139 Q2 — Judge Evaluation

**Question**: Spark CDC + Trino dashboards on same Iceberg table — what is a "commit conflict", does Iceberg have locking, what happens at storage level?

## Score Summary

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 4.5/5 | Core mental model is correct; one MEDIUM imprecision around retry default + one LOW around "weekly" maintenance cadence |
| **Beginner clarity** | 5/5 | Concrete timeline, explicit numbered snapshot IDs, "no locks" stated up front, jargon explained inline |
| **Practical applicability** | 5/5 | Real scheduling fix, partition-scoped `where` example, `partial-progress.enabled`, micro-batch interval, retry diagnostic log line — engineer can act immediately |
| **Completeness** | 5/5 | Addresses all three sub-questions (locking? interference? storage-level?), plus prevention + retry behavior |
| **Overall** | **4.875/5** | |

**Verdict**: **PASS** (>= 4.0)

---

## What Was Verified Correct

1. **Optimistic concurrency, no table-level locks** — CONFIRMED. Iceberg spec and concurrent-write docs explicitly state writers proceed in parallel and conflicts are detected at commit time, not via locking.
   - Source: https://iceberg.apache.org/spec/ ; https://iceberglakehouse.com/iceberg/iceberg-concurrent-writes/

2. **Atomic commit = metadata pointer swap in catalog (Hive Metastore in this prod env)** — CONFIRMED. HMS provides the compare-and-swap primitive; the swap is of the `metadata_location` pointer from `vN.metadata.json` to `vN+1.metadata.json`.
   - Source: https://iceberg.apache.org/spec/ ; https://iceberglakehouse.com/iceberg/iceberg-hive-metastore/

3. **CommitFailedException when base snapshot changed mid-flight** — CONFIRMED. "Cannot commit changes based on stale table metadata" is the canonical message; the failing writer's data files become unreferenced.
   - Source: https://www.ryft.io/blog/handling-commit-conflicts-in-apache-iceberg-patterns-and-fixes

4. **Snapshot isolation — Trino readers pinned, never blocked** — CONFIRMED. Each query reads the current snapshot ID once and reads consistently from it; concurrent writer failures do not affect query results.
   - Source: https://iceberg.apache.org/spec/ (serializable isolation section); https://trino.io/docs/current/connector/iceberg.html

5. **Failed-commit files become orphans, cleaned by `remove_orphan_files`** — CONFIRMED. This is one of the documented sources of orphan files (the others being failed jobs / abandoned writes).
   - Source: https://iceberg.apache.org/docs/1.5.1/maintenance/

6. **`rewrite_data_files` with `where` and `partial-progress.enabled` options** — CONFIRMED. Both are valid procedure options in Iceberg 1.5.2; `where` filters which files are rewritten; `partial-progress.enabled` allows per-group commits so a single group's conflict does not fail the whole job. Defaults to false. Syntax in the answer (`map('partial-progress.enabled', 'true')`) is correct.
   - Source: https://iceberg.apache.org/docs/latest/spark-procedures/

7. **Spark auto-retries on CommitFailedException** — CONFIRMED. Iceberg retries the metadata commit (not the data write) with exponential backoff.
   - Source: https://iceberglakehouse.com/iceberg/iceberg-concurrent-writes/

8. **Recommended trigger interval 60+ seconds for streaming** — CONFIRMED. Iceberg's Spark Structured Streaming docs explicitly recommend a minimum 1-minute trigger interval.
   - Source: https://iceberg.apache.org/docs/1.7.2/spark-structured-streaming/

---

## Errors and Gaps

### MEDIUM

- **Retry-count description is imprecise.** The answer says "If it fails 3+ times (the retry limit), the micro-batch fails." The default for `commit.retry.num-retries` in Iceberg is **4**, not 3, and it is a per-commit table property (catalog/table level), not "per-query". The answer's comment block does acknowledge it is configured at the catalog level, but the prose statement "3+ times" undercounts the default and may mislead an oncall engineer tuning the value. The unrelated `spark.sql.iceberg.handle-timestamp-without-timezone` config example is also a distraction — it has nothing to do with commit retry.
  - Source: https://iceberg.apache.org/docs/1.5.2/configuration/

### LOW

- **"`remove_orphan_files` cleans them up weekly"** — orphan-file cleanup is *not* automatic; it must be scheduled by the operator. Saying "weekly" implies it just happens. Also, the default retention interval is **3 days** (older-than threshold), and in Trino 467 there is a 7-day floor enforced for the analogous Trino procedure. The answer should clarify "weekly *if* you have a scheduled maintenance job, with retention >= 3 days to avoid deleting in-flight writes."
  - Source: https://iceberg.apache.org/docs/1.5.1/maintenance/

- **Production-env fit**: The answer correctly names MinIO and Hive Metastore (matches `prod_info.md`). Good. Could have explicitly noted "HMS commit atomicity relies on the underlying RDBMS row-level transaction" for the on-prem operator who runs HMS — minor missed nuance.

- **Trino as writer**: The question framing mentions Trino "serving dashboard queries" (read-only here), and the answer correctly treats Trino as a reader. However, since this team uses Trino with the Iceberg connector, it would have been a small bonus to note that **if** they ever did `INSERT` from Trino (which `prod_info.md` says they do for temp tables), the same commit-conflict model applies to Trino writers too. Not a deduction, just an opportunity.

### Not Errors (verified)

- The made-up snapshot IDs in the timeline are pedagogical, not claims of fact. Good use.
- "Data corruption is impossible" — correct given immutable files + atomic pointer swap; this is the right framing for a beginner.
- The compaction-vs-CDC overlap as the most likely root cause is accurate and well-targeted for the production stack.

---

## Resource Fix Recommendations

1. **resources/ on Iceberg concurrency** — correct the default retry count to **4** and remove the unrelated `handle-timestamp-without-timezone` distractor from the retry section. Add the precise table property name: `commit.retry.num-retries` (default 4), `commit.retry.min-wait-ms` (default 100ms), `commit.retry.max-wait-ms` (default 60s), `commit.retry.total-timeout-ms` (default 30 min).

2. **resources/17 (maintenance)** — already queued from iter138: ensure `remove_orphan_files` examples use a retention threshold consistent with both Iceberg's 3-day default and Trino 467's 7-day floor. Add an explicit sentence: "orphan-file cleanup is not automatic; you must schedule it."

3. **Add a small note** that for the on-prem Hive Metastore catalog, the atomic compare-and-swap relies on the RDBMS backing HMS (typically MariaDB/MySQL/Postgres) — so HMS DB availability is part of the commit critical path. Useful for an oncall engineer debugging "why did all my commits start failing at once."

---

## Rubric impact

Topics touched:
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — already PASSED (avg 4.640, 12 questions). Add this score: 4.875.
- **Iceberg partition design / small-files / compaction** — touched via `rewrite_data_files` discussion. Already PASSED (avg 4.554, 13 questions). Add this score: 4.875.
- **Postgres-to-Iceberg ingestion: CDC** — touched via Spark+Debezium streaming context. Already PASSED (avg 4.468, 96 questions). Add this score: 4.875.

All required topics remain PASSED.
