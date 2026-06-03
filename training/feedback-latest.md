# Judge Feedback — Iter 407 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.0625 PASS (with critical Q2 inaccuracy)** (Q1 4.5 + Q2 2.75 + Q3 4.5 + Q4 4.5)

**Headline: Q2 IS A PARTIAL DODGE WITH A FACTUAL INACCURACY.** The responder steered away from the question the engineer actually asked (Iceberg branches + fast_forward for WAP), justified the steer with the incorrect blanket claim "branches are Spark-only," and substituted a staging-table + view-swap pattern that, while workable, is not the answer. The production stack HAS Spark with Iceberg 1.5.2 — meaning fast_forward IS available to them — so the steer-away reasoning collapses. Q1/Q3/Q4 are STRONG PASS; this score is pulled down entirely by Q2.

After five consecutive PASSes (iter402-406, four of which were STRONG), iter407 step-down to 4.0625 reintroduces the oscillation pattern. The Iceberg-branches probe was one of the long-standing carry-forward backlog items — when finally tested, the resource was either absent or wrong.

---

## Q1 — JOIN vs IN vs EXISTS rule of thumb

**Scores: 5.0 / 3.5 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **IN → SemiJoin one-row-per-left optimal**: correct (Decorrelate Subqueries rule + SemiJoinNode).
- **NOT IN NULL trap (zero rows)**: correctly flagged.
- **NOT EXISTS safe rewrite BUT correlated NOT EXISTS slower (Trino #21859 LeftJoin no short-circuit)**: verified accurate via prior iter406 re-probe + Trino issue #21859.
- **Non-correlated anti-join fix LEFT JOIN+DISTINCT+IS NULL → SemiJoin ANTI**: correct workaround pattern.
- **Plain JOIN only for multi-col match + DISTINCT on right if dups**: correct guidance.
- **Rule of thumb tier**: IN on non-nullable=optimal, NOT IN nullable=NOT EXISTS/anti-join, unsure=write semantic form + EXPLAIN, rewrite only if CorrelatedJoin/LeftJoin not SemiJoin. Exact actionable recipe.

### Minor gaps
- Dense / abbreviated; "SemiJoin ANTI", "CorrelatedJoin", "LeftJoin" jargon still unglossed for beginners (carry-forward from iter404/iter406).
- No explicit treatment of positive EXISTS (vs NOT EXISTS).
- No IN-list size threshold guidance (when does in-list become a problem).

### Verdict
STRONG PASS. The NOT EXISTS / NOT IN material is durable across four probe angles now (iter404, iter405, iter406, iter407).

---

## Q2 — Iceberg branches + fast_forward write-audit-publish

**Scores: 2.0 / 4.0 / 3.0 / 2.0 — avg 2.75 FAIL — INACCURATE DODGE**

### What's wrong
- **"Branches are Spark-only" is FACTUALLY INCORRECT.** Verified against Trino 481 docs and earlier versions: Trino supports reading from Iceberg branches via `FOR VERSION AS OF 'branch-name'` syntax (e.g., `SELECT * FROM tbl FOR VERSION AS OF 'audit-branch'`). It also exposes the $refs metadata table listing branches. What Trino does NOT support is **writing** to a branch (open issue #16570). Read support has been there since Trino added named references.
- **"You don't need branches" for WAP is misleading for this stack.** The canonical Iceberg WAP pattern IS branches + Spark fast_forward (per Apache Iceberg docs, AWS Prescriptive Guidance, Dremio, Expedia engineering). The production environment has **Spark with Iceberg 1.5.2**, which fully supports both branches and the fast_forward procedure. Steering the engineer to a view-swap workaround when their stack has the right tool is a partial non-answer.
- **fast_forward Spark-only IS correct** — verified in Iceberg Spark Procedures docs as `CALL catalog.system.fast_forward('tbl','main','audit-branch')`. Not exposed in Trino. That alone is not a reason to abandon the pattern given Spark is in the stack.
- **View-swap is a legitimate alternative** but should have been framed as "if you want a Trino-only solution without Spark-level branch ops" not "branches don't apply to you."

### What the right answer looks like
1. YES, Iceberg branches + fast_forward IS the canonical WAP pattern.
2. Your stack: Spark with Iceberg 1.5.2 supports both. Use Spark for the write/audit/publish lifecycle: `ALTER TABLE ... CREATE BRANCH audit`, write to `audit` branch from Spark, run validation queries, then `CALL system.fast_forward('tbl','main','audit')`.
3. Trino 467 can READ from a branch via `FOR VERSION AS OF 'audit-branch'` during validation queries. So your dashboards on `main` are isolated until publish.
4. Trino cannot WRITE to a branch (#16570) — so all branch writes must happen via Spark.
5. Alternative if you don't want branches: staging table + view swap (the responder's actual answer) — fine as a secondary option, but acknowledge it's a workaround, not the canonical pattern.

### Beginner clarity
The view-swap explanation was clear and well-structured. That dimension scores OK. The problem is the answer to a different question than the one asked.

### Practical applicability
View-swap works operationally. But the engineer who asked specifically about branches and fast_forward now believes those features don't apply to their stack — that's actively misleading.

### Completeness
Explicit dodge of the question asked. Did NOT explain: Trino reads branches via FOR VERSION AS OF; Trino can't write branches (#16570); Spark in their stack DOES support both branches and fast_forward; how to combine the two engines for end-to-end WAP.

### Verdict
**FAIL — inaccurate dodge.** This is the kind of error that would actively mislead a SaaS engineer into building view-swap infrastructure when their stack already supports the better pattern.

---

## Q3 — Trino result caching

**Scores: 4.5 / 4.0 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **Trino does NOT cache query results / plans / per-table metadata**: verified against Trino issue #13115 (long-standing feature request).
- **Trino DOES optionally cache Parquet blocks on worker SSD via `fs.cache.enabled`**: verified against Trino docs (file system caching). NVMe recommendation appropriate.
- **`iceberg.metadata-cache`**: correct property name and behavior (caches Iceberg metadata files in connector).
- **App-layer Redis cache (TTL 5min)**: correct architectural alternative for SaaS dashboards.
- **Pre-aggregated rollup table via dbt/Spark**: correct and stack-aligned (dbt supported in prod).
- **Verification via `EXPLAIN ANALYZE` Physical Input bytes drop on 2nd run**: correct diagnostic — fs.cache hits show reduced physical input bytes while the logical plan stays unchanged.

### Minor gaps
- Could mention Trino's experimental "Query results caching" plugin (still experimental as of Trino 481; not production-recommended).
- Could note the cache eviction policy and JMX metric names (carry-forward fs.cache JMX 3rd-angle gap).
- Doesn't explicitly tie caching strategy to the on-prem MinIO bandwidth pattern (fs.cache wins big on MinIO because object listing latency is the hot path).

### Verdict
STRONG PASS. Closes the long-standing "Trino result caching" carry-forward at the 2nd probe angle.

---

## Q4 — delete-file-threshold vs rewrite_position_delete_files

**Scores: 4.5 / 4.0 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **`delete-file-threshold` is an option on `rewrite_data_files`**: correct — when N+ delete files reference a data file, rewrite even if file size is fine. This is the iter395 read-amplification fix.
- **`rewrite_data_files` physically removes deleted rows + delete files**: correct semantics (rewrites data, drops delete-file references).
- **`rewrite_position_delete_files` compacts delete files themselves WITHOUT touching data files**: correct — deleted rows remain physically present, just consolidated delete files for faster MoR reads.
- **Spark-only for both, Trino #27371 (Iceberg roadmap umbrella)**: verified correct against Trino docs (no rewrite_position_delete_files procedure in Trino Iceberg connector).
- **Decision table**: many delete files + data well-sized → rewrite_position_delete_files (cheap); both small data + delete files → rewrite_data_files delete-file-threshold (heavy, physically removes). Sound operational mental model.
- **Gotcha: delete-file-threshold not valid on rewrite_position_delete_files**: correct.
- **Post-cleanup chain: expire_snapshots + remove_orphan_files**: correct ordering.

### Minor gaps
- Doesn't explicitly call out that BOTH procedures are Spark-only in their stack — the engineer should know they need a Spark job either way.
- No literal `CALL system.rewrite_data_files(table => 'tbl', options => map('delete-file-threshold','5'))` syntax sample.
- Could tie back to Iceberg v3 deletion vectors as the upstream fix that obsoletes both eventually (1.5.2 doesn't have it).

### Verdict
STRONG PASS. Natural follow-on from iter406 Q3 MoR cadence question closed cleanly with the rewrite_data_files delete-file-threshold variant.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.5 | STRONG PASS — IN/NOT IN/NOT EXISTS 4th angle durable |
| Q2 | 2.75 | **FAIL — inaccurate dodge on Iceberg branches** |
| Q3 | 4.5 | STRONG PASS — Trino result caching closes 2nd-angle |
| Q4 | 4.5 | STRONG PASS — delete-file-threshold variant closes Q3 follow-on |

**Average 4.0625 PASS** (above 3.5 threshold but pulled down by Q2 from what would otherwise have been a 4.5 STRONG PASS iteration).

**Trajectory iter394-407**: `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/**4.0625P**`. Sixth consecutive PASS (technically), but **the oscillation pattern is reasserting**. The Iceberg-branches probe — long on the carry-forward backlog — landed and exposed a real resource gap. This is the iter405 pattern (one Q with inaccuracy among three STRONG PASSes) recurring.

The dodge mechanism in Q2 ("X is Spark-only therefore X doesn't apply to you") is dangerous because it ignores that the production stack has Spark. The responder should be reasoning: "Does the engineer's stack have the tool? Yes → recommend it." Instead it treated "Spark-only" as a reason to abandon the pattern entirely.

---

## Teacher actions next (iter 408)

1. **MEDIUM — Iceberg branches + WAP resource needs major correction.** The current resource appears to either (a) miss this topic or (b) carry a misleading "Spark-only" framing. Write or rewrite the resource to cover:
   - The Spark+Trino split: Spark writes branches + runs fast_forward; Trino reads branches via `FOR VERSION AS OF 'branch-name'`.
   - Trino #16570 (no branch write support yet) as the boundary.
   - Worked end-to-end WAP example using Spark Iceberg 1.5.2 syntax: CREATE BRANCH → INSERT INTO `tbl.branch_audit` → audit query on audit branch (Spark or Trino read-only) → `CALL system.fast_forward('tbl','main','audit')` to publish.
   - View-swap pattern as a fallback option for teams that don't want branch operations, NOT as the recommended pattern.
   - Cite Apache Iceberg branching docs + AWS WAP blog + Dremio WAP blog as primary sources.

2. **LOW polish — anti-join / SemiJoin / CorrelatedJoin / LeftJoin jargon gloss block** at the top of the IN/NOT IN/NOT EXISTS resource (carry-forward from iter404/iter406, still flagged in iter407 Q1).

3. **LOW polish — Trino result caching resource**: add note that fs.cache.enabled wins biggest on MinIO (object-list latency hot path); add JMX metric names for hit-rate monitoring; mention experimental query-results-cache plugin status.

4. **LOW polish — delete-file-threshold resource**: add literal `CALL system.rewrite_data_files(table => 'tbl', options => map('delete-file-threshold','5'))` Spark syntax; add "both procedures are Spark-only in your stack" callout.

5. **LOW carry-forward backlog**: dbt-trino merge dups, predicate-pushdown JDBC rewrite, write.isolation-level, SHOW SESSION catalog-prefix, HMS->Nessie no-downtime, SPILL_FAILED 60GB cap, MERGE rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO/VALIDATE, JWT+OPA concurrency, Iceberg tagging 3rd, fs.cache 3rd JMX, PERCENT_RANK/NTILE 3rd, RANGE INTERVAL gap-day.

## Judge probe targets next (iter 408)

1. **CRITICAL RE-PROBE Iceberg branches + fast_forward** — different phrasing, e.g., "I need to validate ingested data before exposing it to Trino dashboards — what's the standard Iceberg pattern for this?" — durability check after teacher MEDIUM fix.
2. **Iceberg branch read from Trino via FOR VERSION AS OF** — confirm responder can correctly state that Trino READS branches even though it can't write.
3. **HMS-to-Nessie no-downtime migration** — long-standing carry-forward (also relevant if branches become a heavier focus, since Nessie is the catalog of choice for branch-heavy workflows).
4. **Trino #16570 boundary** — "Can I INSERT from Trino into an Iceberg branch?" — confirms responder correctly states Trino can't write to branches yet.
5. **rewrite_data_files Spark syntax literal** — natural follow-on from Q4 to confirm the engineer knows exactly what to type in spark-sql.
6. Carry-forward backlog rotation as needed.
