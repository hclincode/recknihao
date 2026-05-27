# Judge Report — iter160 Q2

## Question recap

> "Someone on our team ran an EXPLAIN on one of our Trino queries and the planner chose to do a full scan of a 400-million-row Iceberg table even though the result only touched about 2 million rows — and the partition column was right there in the WHERE clause. We suspected maybe the query planner just doesn't know how unevenly our data is distributed across partitions, like it has no idea that 90% of our rows are in the last 3 months. Is there a way to give Trino statistics about our data so it makes better join order and scan decisions? Do we have to run some kind of ANALYZE command, or does Iceberg track that automatically?"

The question has three distinct asks:
1. Is the planner missing data-distribution statistics?
2. Can the user give Trino statistics for **join order** AND **scan** decisions?
3. Does Iceberg auto-collect, or is ANALYZE required?

## Scores

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Technical accuracy | 2 | 2 | 4 |
| Beginner clarity | 4 | 1 | 4 |
| Practical applicability | 3 | 1 | 3 |
| Completeness | 2 | 1 | 2 |
| **Weighted average** | | | **2.6 / 5** |

**Verdict: FAIL** (below 3.5 pass threshold).

---

## Technical accuracy — 2/5

The answer mixes a correct insight with several incorrect or seriously misleading claims.

### What is correct
- Iceberg DOES automatically collect per-file column min/max (lower_bounds / upper_bounds) in manifest entries. Verified against iceberg.apache.org spec.
- The "data clustering / file-level skipping needs sorted data" framing is correct: with random data, every file's min..max spans the full date range and Trino cannot skip files using min/max alone. Verified against multiple Iceberg performance docs.
- `rewrite_data_files` with `strategy='sort'`, `sort_order`, and `options => map('rewrite-all','true')` is a valid Spark procedure with correct parameter syntax. Verified against iceberg.apache.org/docs/latest/spark-procedures/.
- Labeling the Spark `CALL iceberg.system.rewrite_data_files` as Spark-only (not Trino) is correct under current Trino docs — Trino's Iceberg connector does NOT expose `rewrite_data_files`; it uses `ALTER TABLE ... EXECUTE optimize` instead.

### What is wrong or misleading

1. **"You don't need to run an ANALYZE command"** — this is **factually incorrect** in context. The user explicitly asked about **join order**. Trino's Iceberg `ANALYZE TABLE` collects **NDV (number of distinct values)** statistics and writes them to a **Puffin file** (`.stats` file referenced from `metadata.json`). NDV is a key input the Trino CBO uses to pick join order and side (build vs probe). Min/max in manifests alone do NOT give the optimizer NDV. The answer flatly denies the need for ANALYZE, which would actively mislead the engineer to skip the one command that addresses half of their question.

2. **The reframe is incomplete.** The answer correctly identifies that scan-time file skipping needs sorted data, but it never tells the engineer that the **join-order** half of their question has a different answer: run `ANALYZE TABLE <iceberg_table>` (and optionally specify columns) to populate NDV in Puffin. This is the literal answer to "Do we have to run some kind of ANALYZE command?"

3. **No mention of the Trino-native compaction path.** Production is Trino 467 + Spark with Iceberg 1.5.2. Trino's Iceberg connector exposes `ALTER TABLE <t> EXECUTE optimize(file_size_threshold => '...')` and supports the `sorted_by` table property. Recommending only the Spark route ignores half the available tooling, when the engineer may already have a Trino-only workflow.

4. **"The planner is doing exactly what it should"** — partly true for scan files, but actively wrong for join order: if NDV is unknown, the planner is NOT making the best join decisions, and the user explicitly asked about this.

5. **"Your EXPLAIN would have shown Physical Input: 400 million rows"** — minor: `Physical Input` size in bytes appears in `EXPLAIN ANALYZE`, not plain `EXPLAIN`. Plain EXPLAIN shows estimated rows from statistics; `EXPLAIN ANALYZE` shows actuals.

The combination of (1)+(2) is the most damaging — the user's literal question was "do we need to ANALYZE?", and the answer said "no, you don't need to" when the correct answer is "yes, for the join-order half of your question, you do."

---

## Beginner clarity — 4/5

Strong on clarity overall:
- The "all files look identical" worked example with file_0001/file_0002 is excellent and concretely illustrates why min/max can't skip.
- The "300 files skipped, 400M → 2M" framing is intuitive.
- No unexplained jargon; `lower_bounds`/`upper_bounds` and "manifest entry" are introduced inline.
- Decent rhythm: Good News → Real Problem → Fix → Caveats → Why EXPLAIN missed it.

Docked one point because:
- "Cost-based optimizer", "NDV", and "Puffin" are entirely absent — a beginner would not know these terms exist, and these are exactly what their question was about.
- "Partition pruning works but file-level skipping doesn't without clustering" — this asymmetry is mentioned but the *names* (partition pruning vs file pruning vs row-group pruning) are not given, which makes it harder to look up later.

---

## Practical applicability — 3/5

The Spark snippet is concrete and runnable, and it correctly addresses the scan problem. The maintenance follow-up ("nightly compaction without `rewrite-all=true` maintains sort order") is real-world useful. The caveat about multi-hour runtime + off-hours scheduling matches our production stack reality.

But:
- No `ANALYZE TABLE <iceberg_table>` command shown, even though the user literally asked about ANALYZE.
- No mention of `ALTER TABLE <t> EXECUTE optimize` or `sorted_by` table property — these are the Trino-side levers that fit a Trino-first SaaS workflow.
- No mention of `optimize.join-reordering-strategy` / `join_reordering_strategy` session property, which controls whether the CBO uses the stats at all.
- No verification/diagnostic step: "After ANALYZE + sort-compact, re-run EXPLAIN and look for X" — the engineer is left without a feedback loop.

---

## Completeness — 2/5

The question explicitly asked three things; only one is meaningfully addressed.

| Sub-question | Addressed? |
|---|---|
| Why is the planner doing a full scan? | Yes (data clustering). |
| Can I give Trino stats for **join order**? | No. |
| Can I give Trino stats for **scan**? | Partially — via sort, not ANALYZE. |
| Does Iceberg auto-collect, or do I need ANALYZE? | Half-correct — covers manifest min/max auto-collection, denies need for ANALYZE entirely, omits Puffin/NDV. |

The answer also doesn't acknowledge what the partition column behavior is. The user said "the partition column was right there in the WHERE clause" — if true and partition pruning is in fact working, then the 400M scan is happening *within the matched partitions* and the real lever is file-level skipping inside those partitions (sort) OR fixing the partition transform if the partition predicate isn't being pushed (e.g., a `day` partition with a `cast(occurred_at as date)` predicate). The answer assumes the latter case without flagging the diagnostic.

---

## Production-environment fit

- The answer correctly avoids cloud-only tooling and stays on Spark + Trino + Iceberg, which matches the on-prem MinIO + Hive Metastore + Trino 467 + Iceberg 1.5.2 stack. Good.
- Misses an opportunity to lean on Trino 467's native `ALTER TABLE ... EXECUTE optimize` path, which is the friendlier route for a SaaS engineer who lives in Trino.

---

## Verification summary (against official docs)

1. Iceberg auto-collects min/max per file → **CONFIRMED** (iceberg.apache.org/spec/, default metrics mode is `truncate(16)`).
2. Trino ANALYZE on Iceberg is needed for NDV → **CONFIRMED** (trino.io/docs Iceberg connector — ANALYZE collects NDV and stores it in Puffin / metadata.json statistics).
3. Data-clustering / min-max skipping claim → **CONFIRMED** (multiple Iceberg performance docs).
4. `rewrite_data_files` with sort + `rewrite-all=true` is a Spark-only API → **CONFIRMED** (iceberg.apache.org/docs/latest/spark-procedures/). Trino's Iceberg connector does NOT expose `rewrite_data_files`; it offers `ALTER TABLE EXECUTE optimize` and the `sorted_by` table property.
5. "Partition pruning works but file-level skipping doesn't without clustering" → **CONFIRMED** as a general claim, but oversimplified — it ignores the case where the partition transform mismatches the predicate, which is also a very common cause of "full table scan despite WHERE on partition column."

---

## Topic & rubric update

This question touches:
- "Query performance basics: partitioning, indexing strategy for analytics" — already PASSED at 4.594 (4 questions).
- "Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup" — already PASSED at 4.602 (14 questions).
- "Query performance regression diagnosis: oncall workflow for slow queries" — already PASSED at 5.0 (2 questions).

A new latent topic the rubric does NOT currently track is **Trino CBO / table statistics / ANALYZE / Puffin / NDV / join ordering**. This question exposed that gap directly. Recommend adding this as a tracked topic — it's distinct from "partitioning" and "compaction" and the resources clearly under-cover it.

---

## Feedback for teacher

Priority gap: `resources/` does not have a clear, prominent section on:
1. What Trino `ANALYZE TABLE` does for Iceberg (NDV via Puffin), what it does NOT do (no min/max — Iceberg already has those), and when to run it.
2. The split between **scan-time stats** (min/max in manifests, automatic) vs **planning-time stats** (NDV in Puffin, requires ANALYZE) vs **data layout** (sort/cluster, requires compaction).
3. Trino-native compaction: `ALTER TABLE <t> EXECUTE optimize(...)` and the `sorted_by` table property — including the limitation that Trino's optimize does NOT itself sort, but `sorted_by` orders new writes.
4. Three pruning layers (partition pruning → manifest/file pruning via min-max → row-group pruning inside Parquet) by name, so beginners can map their EXPLAIN output to the right concept.
5. A diagnostic recipe for "full scan despite WHERE on partition column": (a) check partition transform vs predicate shape, (b) check whether partition predicate is being pushed (EXPLAIN), (c) check file count after partition pruning, (d) then move to sort-cluster.

The current answer is a strong "data clustering" mini-lesson but skips the literal ANALYZE question and the join-order half. Both are required for this to pass.
