# Judge Feedback — Iter 381 (EXTENDED PHASE)

**Date**: 2026-05-30
**Overall**: **4.78125 STRONG PASS** (combined Q1 + Q2 average; both questions cleared 4.0 pass bar)

---

## Per-question scores

### Q1 — Trino result caching for 30s dashboard refresh

**Score: 4.75 / 5.0 — STRONG PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.5 |

**What the responder got right**:
- **Led with the critical correction**: "Trino doesn't cache results by default." This is the #1 misconception engineers carry over from Snowflake / BigQuery (both of which have automatic query result cache). Setting this correctly is the foundation of the rest of the answer. Verified vs [Support query result caching · Issue #20854 · trinodb/trino](https://github.com/trinodb/trino/issues/20854) — result caching is an open feature request, NOT a built-in capability of Trino 467.
- **Three concrete patterns with trade-off positioning**:
  - **Redis app cache (60-300s TTL)** — standard cache-aside pattern for dashboard freshness vs latency tradeoff.
  - **Pre-aggregated rollup table** — pay aggregation cost once at write time, query thousands of rows instead of billions; canonical OLAP rollup pattern.
  - **Materialized view with REFRESH** — Trino's `CREATE MATERIALIZED VIEW` + `REFRESH MATERIALIZED VIEW` for Iceberg connector (supported since Trino 401+).
- **Comparison table for picking each** — structural clarity that gives the engineer a decision aid.
- **30s refresh window context**: each pattern's TTL/refresh interval is sized for that window.

**Gaps (minor, BC and Comp)**:
- **BC (−0.5)**: "TTL", "pre-aggregated rollup", "materialized view" used without one-line inline gloss for an OLTP engineer. Comparison table provides structural clarity but vocab is unexplained.
- **Comp (−0.5)**: Missed: (a) Trino's metadata cache (different from result cache — still helps planning latency), (b) Redis stampede / thundering-herd protection on cache miss for high-concurrency dashboards, (c) materialized view REFRESH in Trino is a full rebuild not incremental (production-relevant cost consideration), (d) staleness window analysis — for a 30s refresh, a 60s Redis TTL means up to 90s of staleness which may not match the engineer's spec.

---

### Q2 — Iceberg branches WAP (write-audit-publish) pattern

**Score: 4.8125 / 5.0 — STRONG PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |

**What the responder got right**:
- **Canonical WAP flow with correct procedure names**: CREATE BRANCH in Spark, set `spark.wap.branch` so writes land on the branch, audit, `CALL ... fast_forward` to atomically advance main, DROP BRANCH cleanup. Verified vs [Spark Procedures — Apache Iceberg 1.5.1](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) (production-stack-fit for Iceberg 1.5.2) and [Streamlining Data Quality in Apache Iceberg with WAP & branching (Dremio)](https://www.dremio.com/blog/streamlining-data-quality-in-apache-iceberg-with-write-audit-publish-branching/).
- **fast_forward is metadata-only and atomic**: verified vs [Try Iceberg FastForward Procedure (tomtan.dev)](https://tomtan.dev/blog/2024-01-30-try-iceberg-fastforward/) and [AWS — Build WAP pattern with Apache Iceberg branching + Glue Data Quality](https://aws.amazon.com/blogs/big-data/build-write-audit-publish-pattern-with-apache-iceberg-branching-and-aws-glue-data-quality/) — fast_forward updates main's ref to the audit branch's snapshot, no Parquet movement, all-or-nothing semantics.
- **Production main unaffected** during write/audit — correct branch isolation framing.
- **Trino audit from FOR VERSION AS OF** — correct snapshot read mechanism.
- **Capability split between Spark and Trino called out explicitly**: branch create/write/publish are Spark-only; audit reads are Trino-compatible. This is the most important production constraint for the Iceberg 1.5.2 + Trino 467 + HMS stack and the responder named it directly.

**Gaps (minor, BC and Comp)**:
- **BC (−0.5)**: "WAP", "branch", "snapshot", "fast_forward", "FOR VERSION AS OF" used; "atomic metadata-only publish" could use a one-line gloss ("only the pointer to the latest snapshot moves; no Parquet files are rewritten — this is why fast_forward is instantaneous regardless of data size").
- **Comp (−0.25)**: Missed: (a) Trino 467 `FOR VERSION AS OF` requires a snapshot ID, not a branch name — to audit the branch from Trino, resolve the branch's snapshot ID first via Spark or via the `<table>$refs` metadata table, (b) what happens if main advances during audit (fast_forward fails — need rebase or cherrypick), (c) snapshot expiry maintenance interaction: don't expire snapshots that branches reference; branches pin their snapshots from expiry, but stale audit branches can accumulate snapshots and inflate metadata size, (d) branch retention policy.

---

## Cross-question patterns

- **TA at ceiling both questions (5.0 + 5.0 = 10.0/10)**: Zero factual errors detected by WebSearch verification against authoritative sources ([Trino issue #20854](https://github.com/trinodb/trino/issues/20854) for Q1, [Apache Iceberg Spark Procedures 1.5.1 docs](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) and [Dremio WAP blog](https://www.dremio.com/blog/streamlining-data-quality-in-apache-iceberg-with-write-audit-publish-branching/) for Q2). Both led with the correct framing (Trino has no result cache; WAP via branches is Spark-only writes + Trino-compatible audit reads).
- **PA at ceiling both questions (5.0 + 5.0 = 10.0/10)**: Engineer has actionable next steps — Q1 gives three concrete patterns with a comparison table; Q2 gives end-to-end CREATE BRANCH -> spark.wap.branch -> audit -> fast_forward -> DROP flow with the Spark-vs-Trino capability split called out.
- **BC drag (−0.5 both)**: recurring inline-gloss gap on vocabulary. Q1: TTL, pre-aggregated rollup, materialized view. Q2: WAP, snapshot, fast_forward, FOR VERSION AS OF, atomic metadata-only. Both questions used the terms in context but newcomers without OLAP background would benefit from one-line glosses inline at first use.
- **Comp drag (Q1 −0.5, Q2 −0.25)**: Q1 missed metadata cache distinction + Redis stampede + materialized view REFRESH being full-rebuild + staleness window analysis; Q2 missed Trino 467 branch-name vs snapshot-ID limitation + main-advances-during-audit conflict + snapshot-expiry-vs-branch interaction. All edge cases; core answer fully covered both questions.
- **Production-stack-fit excellent both**: Q1 correctly scoped to Trino 467 (mentions REFRESH which is supported since 401+); Q2 correctly scoped to Iceberg 1.5.2 (CREATE BRANCH and fast_forward are 1.4+ features) + Spark + Trino + HMS + MinIO + k8s stack.
- **Iter trajectory restored at high water mark**: iter378 4.71875 -> iter379 4.8125 -> iter380 (not in record) -> iter381 4.78125. Three consecutive STRONG PASS results; teacher base is stable for the topics being probed.

---

## ITER381 TEACHER ACTIONS (PRIORITY-ORDERED)

1. **LOW (BC inline gloss cascade — recurring)**: Add inline glosses on first use for:
   - Q1 vocabulary: TTL (Time To Live — how long a cached entry stays valid), pre-aggregated rollup (a smaller table you build once that has the summed/counted result already computed), materialized view (a saved query whose results are stored on disk and refreshed on a schedule).
   - Q2 vocabulary: WAP (Write-Audit-Publish — pattern where you write data to a sandbox, validate it, then publish it to production), atomic metadata-only publish (only the pointer changes; no Parquet files move — the publish is instantaneous regardless of data size).
   - Carry-forward from prior iterations still open: Puffin (sidecar stats file), NDV (Number of Distinct Values), CBO (Cost-Based Optimizer), cardinality (number of distinct values), dictionary encoding (Parquet repeats stored once + integer ID), frame clause (window function row-window definition), data residency (data must physically live in specific geographic region), compliance tier (data category with different regulatory requirements), HyperLogLog (since iter372), MinIO TCO (since iter374), Trino UI vocab Queued/Scheduled/Physical Input/Blocked/Spilled (since iter376), lakehouse tx vocab atomic/idempotent/destructive/partial commit (since iter376), federation vocab BROADCAST/PARTITIONED/build-vs-probe/left-deep (since iter370+).

2. **LOW (Comp depth Q1)**: Add to result-caching resource:
   - Trino's **metadata cache** is distinct from result cache and DOES exist by default — helps planning latency, not query execution. Calling this out prevents the engineer from thinking Trino has zero caching.
   - **Cache stampede / thundering-herd**: on cache miss with high concurrent dashboards, ensure single-flight or lock-based protection so only one request rebuilds the cache.
   - **Materialized view REFRESH in Trino is a full rebuild** (not incremental as of Trino 467) — this is a real production cost consideration vs Snowflake's incremental MVs.
   - **Staleness window math**: 30s refresh + 60s Redis TTL = up to 90s staleness; size TTL to the engineer's actual freshness SLA.

3. **LOW (Comp depth Q2)**: Add to Iceberg branches / WAP resource:
   - **Trino 467 FOR VERSION AS OF takes snapshot ID, not branch name** — to read the branch from Trino, resolve the branch's snapshot ID first via Spark (`SELECT * FROM <table>.refs WHERE name = 'audit_branch'`) or via the `<table>$refs` metadata table.
   - **fast_forward fails if main advanced during audit**: needs rebase, cherrypick_snapshot, or a fresh audit branch from current main.
   - **Snapshot expiry interaction**: branches pin their snapshots from expiry — stale audit branches that are never dropped accumulate snapshots and inflate metadata size; include "DROP BRANCH after publish" as a hard step in any WAP runbook.

4. **LOW (carry-forward unprobed open items)**:
   - 7-day rolling average per tenant in Trino — sliding RANGE BETWEEN INTERVAL '6' DAY PRECEDING vs cumulative UNBOUNDED PRECEDING (iter379 probe target, not yet asked).
   - bloom filter low-cardinality side — country_code 200 distinct values correct answer NO (iter379 probe target, not yet asked).
   - `write.target-file-size-bytes` Spark DDL vs Trino session property `target_max_file_size` split (iter378 carry-forward).
   - `write.distribution-mode='hash'` Spark vs Trino split + skew caveat (iter378 carry-forward).
   - EXPLAIN ANALYZE warning that it actually executes the query (iter376 carry-forward).
   - Theta Sketch probabilistic NDV accuracy + `ANALYZE WITH (columns = ARRAY[...])` syntax + Puffin snapshot-ID interaction (iter379 Q1 follow-up).
   - Cross-catalog join GDPR Chapter V data transfer warning + maintenance job residency + Right to Be Forgotten DELETE per-catalog (iter379 Q2 follow-up).

---

## ITER381 JUDGE PROBE TARGETS

1. **Trino result caching 2nd angle**: "If I want sub-second dashboard load times on a billion-row Iceberg fact table, where exactly should the cache live — Trino itself, the BI tool, the application layer, or in a rollup table?" — probes the layering decision more explicitly and tests whether the responder can name Trino's metadata cache + result cache distinction.
2. **Iceberg branches 2nd angle**: "If two ETL jobs both try to fast_forward main from different audit branches at the same time, what happens?" — tests the concurrent-publish / lost-update semantics of branch publishing.
3. **Window function 3rd angle**: 7-day rolling average (carry-forward, still open).
4. **Bloom filter 3rd angle**: low-cardinality side country_code 200 distinct (carry-forward, still open).
5. **Trino-vs-Spark write property split**: `write.target-file-size-bytes` vs `target_max_file_size` (carry-forward).
6. **EXPLAIN ANALYZE warning** (carry-forward iter376).
7. **Federation glossary** (carry-forward iter370+).

---

## Sources verified via WebSearch

- [Support query result caching · Issue #20854 · trinodb/trino](https://github.com/trinodb/trino/issues/20854) — confirms Trino has no built-in query result cache; this is an open feature request, not a shipped capability.
- [File system cache — Trino 481 Documentation](https://trino.io/docs/current/object-storage/file-system-cache.html) — Trino has file system / storage caching, distinct from query result caching.
- [Spark Procedures — Apache Iceberg 1.5.1](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) — CREATE BRANCH, fast_forward, DROP BRANCH all documented as Spark procedures (not Trino).
- [Streamlining Data Quality in Apache Iceberg with WAP & branching (Dremio)](https://www.dremio.com/blog/streamlining-data-quality-in-apache-iceberg-with-write-audit-publish-branching/) — canonical WAP flow documentation with branch creation, spark.wap.branch, audit, fast_forward publish.
- [Try Iceberg FastForward Procedure (tomtan.dev)](https://tomtan.dev/blog/2024-01-30-try-iceberg-fastforward/) — fast_forward atomicity and metadata-only semantics confirmed.
- [Build WAP pattern with Apache Iceberg branching + AWS Glue Data Quality](https://aws.amazon.com/blogs/big-data/build-write-audit-publish-pattern-with-apache-iceberg-branching-and-aws-glue-data-quality/) — end-to-end WAP pattern.
- [Write-Audit-Publish Pattern with Apache Iceberg on AWS using Branches (guptaakashdeep.com)](https://www.guptaakashdeep.com/wap-via-apache-iceberg-on-aws/) — branch + WAP reference implementation.
