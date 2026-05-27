# Judge — Iter 107 Q2

**Topic**: Postgres-to-Iceberg ingestion
**Score**: 4.7 / 5 (Tech 4.7, Clarity 4.8, Practical 4.8, Completeness 4.5)

## Verdict
Excellent, production-grade answer. Correctly diagnoses that the most likely root cause is a missing index on `updated_at` (Step 0) before touching Spark knobs — a senior-engineer framing. JDBC parallelism, fetchsize, replica routing, and pushdown verification are all technically accurate and presented with practical, copy-pasteable code plus a clear priority order. Loses minor points for not mentioning the pgjdbc autoCommit interaction with fetchsize and for a few small operational gaps.

## What was verified correct (via WebSearch)
- `partitionColumn` / `lowerBound` / `upperBound` / `numPartitions`: confirmed by spark.apache.org JDBC docs that bounds only control partition stride, not row filtering. The answer's explicit callout ("`lowerBound` and `upperBound` do NOT filter rows") is exactly right and addresses the classic beginner trap.
- pgjdbc `fetchsize` default is 0 (entire result set loaded at once) — confirmed via jdbc.postgresql.org issue/docs references.
- `CREATE INDEX CONCURRENTLY` — confirmed: takes SHARE UPDATE EXCLUSIVE rather than ACCESS EXCLUSIVE; does not block writes. Tradeoff (two table scans, slower overall) is accurate context the answer doesn't need but is correct.
- `hot_standby_feedback` / `max_standby_streaming_delay` default 30 s / "canceling statement due to conflict with recovery" — all confirmed via postgresql.org hot standby docs.
- `options=-c statement_timeout=...` syntax — confirmed valid via pgjdbc docs (`BaseDataSource` / `PGProperty` reference); units in milliseconds when unitless, matches the answer's 14400000 ms = 4 h.
- `df.explain(True)` showing `PushedFilters` — standard Spark JDBC pushdown diagnostic; supported in Spark 3.x.
- `pushDownPredicate` default is true in Spark JDBC (consistent with prior iter106/107 teacher fix to resources/13).

## Errors or gaps
- **pgjdbc fetchsize + autoCommit caveat omitted.** pgjdbc silently ignores `fetchSize` when the connection is in autoCommit mode, and pgjdbc's default is autoCommit=true. In practice Spark JDBC sets autoCommit=false during reads, so `fetchsize=10000` does work — but the answer presents the setting as universally applicable without explaining why it's safe here. An engineer copying the `fetchsize` snippet into a different (non-Spark) tool would be silently betrayed.
- **`max_standby_streaming_delay` framing is slightly loose.** The query cancellation can be triggered by any WAL-replay conflict (VACUUM is the canonical case but not the only one — exclusive locks, btree page deletions, etc. also trigger it). Calling out VACUUM as the cause is the right pedagogical choice but is presented as the only cause.
- **String interpolation in the SQL subquery** (`f"... WHERE updated_at > '{last_ts}'"`) is fine for a trusted watermark file but worth a one-line "treat the watermark as trusted; parameterize if sourced from elsewhere" note.
- **`df.agg({"updated_at": "max"}).collect()` at the end re-executes the JDBC read** (no `.cache()` shown). Minor — most teams would catch this — but on a 400M-row read it could double the cost. A `df.persist()` before `MERGE INTO` or computing max from the source-side bounds query would be cleaner.
- **No mention of on-prem k8s constraints from prod_info.md.** Iceberg 1.5.2 + Hive Metastore + MinIO context wasn't surfaced; the advice is environment-agnostic but doesn't tie back to the stack. Not a correctness issue.

## Resource fix recommendations
- **MEDIUM** — `resources/13-postgres-to-iceberg-ingestion.md`: add a one-paragraph callout on the pgjdbc `fetchSize` + `autoCommit` interaction. State that Spark's JDBC reader sets autoCommit=false so fetchSize works as expected, but warn that the same setting is silently ignored in autocommit clients (a common gotcha when porting query logic out of Spark).
- **LOW** — same file: add a parenthetical "(VACUUM is the typical cause; any conflicting WAL apply — exclusive lock, btree cleanup — can also trigger this)" to the `hot_standby_feedback` section.
- **LOW** — same file: add a one-liner on caching/persisting the JDBC DataFrame before MERGE + max-watermark calc to avoid re-reading the source table.

## Updated topic state
- Postgres-to-Iceberg ingestion: 92 questions / running avg **4.487** (prior 4.485 × 91 + 4.7) / 92 = 4.487
