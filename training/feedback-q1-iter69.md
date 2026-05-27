# Feedback — Iter 69 Q1

**Topic**: Iceberg partition design for SaaS: strategies, small-files, compaction
**Question**: Why doesn't `WHERE event_ts >= '2026-05-01'` prune partitions on a day-partitioned Iceberg table?
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter69-q1.md`

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Completeness | 5.0 | All five expected coverage points present (hidden partitioning, function wrapping, ALTER spec for future writes only + rewrite_data_files fix, small-files via EXPLAIN ANALYZE, diagnostic checklist). Adds a useful "step zero" `SHOW CREATE TABLE` verification. |
| Accuracy | 4.0 | Core claims correct (ALTER affects future writes only, rewrite_data_files migrates old data, Trino reports file counts in EXPLAIN ANALYZE). Two imprecisions on Cause 2 (DATE-literal type mismatch framing) and the blanket "CAST/DATE always break pruning" rule. |
| Clarity | 5.0 | Excellent BAD/GOOD code snippets, named causes, summary checklist at the end. A beginner can act on this. |
| No hallucination | 4.0 | Mild speculation on "Cause 2: type mismatch may confuse the planner." Otherwise grounded. |
| **Average** | **4.5** | Pass |

---

## What worked well

1. **Hidden partitioning framing** — opens with "Iceberg's partition pruning is automatic — you don't reference the partition column directly" — exactly the right mental model.
2. **Function-wrapping section is the right diagnosis first** — most engineers hit this before they hit anything else. BAD/GOOD code blocks make it copy-pasteable.
3. **Partition-spec-added-after-data section is complete** — explains the symptom ("new data fast, old slow"), the metadata cause, and gives the exact `rewrite_data_files` call to migrate. Notes it's a one-time Spark op, not Trino. This matches resources/10-lakehouse-partitioning.md verbatim.
4. **Distinguishes the two "slow query" failure modes**: "scans everything" (causes 1–3) vs "scans the right partitions but is still slow" (cause 4 — small files). This is a sharp framing.
5. **EXPLAIN ANALYZE recommendation with concrete `Files:` numbers** — gives the engineer a number to react to ("if it's 25,000 instead of 25, compact").

---

## What to fix

### 1. Cause 2 framing is imprecise (minor)

The answer says `WHERE event_ts >= DATE '2026-05-01'` (TIMESTAMP column, DATE literal) is "potentially broken" because of type mismatch. Per the Trino date-predicates blog (https://trino.io/blog/2023/04/11/date-predicates.html), Trino actively **unwraps** this comparison into a TIMESTAMP range and partition pruning works fine. The actual sharp edge is comparisons that don't fall on a day boundary (e.g., `ts >= TIMESTAMP '2026-05-01 10:00:00'` on a `day(ts)` partition — Trino can't safely prune the partition that contains midnight–10am).

Recommend either dropping Cause 2 entirely or reframing it as "non-day-aligned timestamps."

### 2. "Function wrapping always breaks pruning" is overstated (minor)

The answer marks CAST and DATE() as universal pruning-breakers. Per the same Trino blog, Trino unwraps `CAST(event_ts AS DATE) = DATE '...'` and `date_trunc('day', event_ts) = DATE '...'` to enable pruning. For a beginner-safety answer this oversimplification is defensible — "use the raw column" is still the right advice — but the absolute framing ("hides event_ts from the planner") is not strictly true for the common date-truncation cases.

### 3. Both fixes are non-blocking

The answer is fundamentally correct and useful. These are precision refinements, not corrections. The teacher could add a short note to resources/10-lakehouse-partitioning.md:

- "Trino does unwrap some `CAST(ts AS DATE)` and `date_trunc('day', ts)` patterns, but prefer the raw column for safety."
- "Non-day-aligned timestamp comparisons (e.g., `ts >= TIMESTAMP '... 10:00:00'`) are the trickiest pruning corner case, not type-mismatched literals."

---

## Verification (WebSearch)

- **Function wrapping defeats pruning**: Mostly true — but Trino unwraps `CAST(ts AS DATE)` and `date_trunc('day', ts)`. Source: https://trino.io/blog/2023/04/11/date-predicates.html
- **ALTER TABLE changes spec for new writes only, old files unpartitioned until rewrite**: Confirmed. Source: https://www.dremio.com/blog/future-proof-partitioning-and-fewer-table-rewrites-with-apache-iceberg/
- **EXPLAIN ANALYZE shows file counts (scanned_files_count, active_files_count)**: Confirmed. Source: https://trino.io/docs/current/connector/iceberg.html

---

## Rubric update

- Topic: Iceberg partition design for SaaS: strategies, small-files, compaction
- Prior avg: 4.429 across 7 questions
- New score this Q: 4.5
- New avg: (4.429 × 7 + 4.5) / 8 = 35.503 / 8 = **4.438** across 8 questions
- Status: **PASSED**
