# Iter 162 Q1 — Judge Report

## Question
"I ran ANALYZE on our main events table last night and it has been going for over four hours now on what I think is about 2TB of data. Is that normal, or did something go wrong? Our dashboard queries are still timing out and I need to get the stats updated, but I also cannot leave this running forever. Is there a way to speed it up, maybe by only updating the columns we actually filter on instead of the whole table?"

## Answer location
/Users/hclin/github/recknihao/training/answers/iter162-q1.md

---

## Fact-check (via WebSearch against trino.io)

| # | Claim in answer | Verdict | Source |
|---|---|---|---|
| 1 | `ANALYZE iceberg.analytics.events WITH (columns = ARRAY[...])` — no TABLE keyword | CORRECT | trino.io/docs/current/sql/analyze.html and iceberg.html |
| 2 | `WITH (partitions = ARRAY[ARRAY['2026-05']], columns = ARRAY[...])` for partition-scoped ANALYZE on Iceberg | **INCORRECT — CRITICAL BUG** | trino.io Iceberg connector docs. The `partitions` property is a **Hive connector** ANALYZE property; the Iceberg connector ANALYZE only supports the `columns` property. Running this on Iceberg will fail with an "invalid analyze property" error. |
| 3 | Puffin file stores NDV sketches (Theta sketch) alongside Iceberg metadata | CORRECT | iceberg.apache.org/puffin-spec; confirmed Trino writes NDV to Puffin |
| 4 | "ANALYZE does not block other queries — it's just another query in the queue" | MOSTLY CORRECT | Trino ANALYZE does not take Iceberg table locks that would prevent reads; it competes for cluster resources (CPU/memory/IO) but does not block SELECT queries. Phrasing is acceptable. |
| 5 | Killing ANALYZE mid-run is safe; Iceberg transactions are atomic — either Puffin written or not | CORRECT | Iceberg's atomic commit semantics apply; killing produces no half-written stats file. |
| 6 | `SHOW STATS FOR table` returns `distinct_values_count` column | CORRECT | trino.io/docs/current/sql/show-stats.html |
| 7 | "4 hours for 2TB is normal" | REASONABLE | Full-table NDV scan over 2TB Parquet at typical Trino throughput per worker can easily take hours; phrasing is appropriately hedged ("within normal range"). |
| 8 | **MISSING** — `drop_extended_stats` before re-running ANALYZE on a column subset | **CRITICAL OMISSION** | trino.io Iceberg docs explicitly state: "if statistics were previously collected for all columns, they must be dropped using the drop_extended_stats command before re-analyzing." The user is asking to switch from full-table ANALYZE to column-subset ANALYZE — this is exactly the scenario where `drop_extended_stats` is required. Without it, the new column-subset ANALYZE may be a no-op or produce stale combined stats. |
| 9 | "Reduce concurrency — Trino respects resource groups; you can throttle ANALYZE to use fewer worker threads" | PARTIALLY MISLEADING | Resource groups throttle query concurrency / memory at the coordinator level, not "worker threads per query." Phrasing implies per-query thread tuning, which is a different mechanism (task.concurrency, etc.). Not catastrophically wrong but loose. |
| 10 | "ANALYZE walks through every row of your table" | CORRECT for first run on Iceberg; for column-subset it scans only needed columns from Parquet (columnar projection pushdown). The answer's framing is fine since it's discussing full-table runs. |

---

## Scoring

### Technical accuracy: 3/5
- Two material errors:
  1. **`partitions` parameter does not exist on Iceberg ANALYZE.** This is a critical SQL syntax bug — the user will paste the example and get an error.
  2. **`drop_extended_stats` is not mentioned**, even though the user's exact scenario (re-running ANALYZE on a column subset after a full-table run was already started/finished) is the canonical case requiring it. This was already called out as a known gap in the iter161 notes; it remains unfixed.
- Resource group framing is loose.
- Other facts (Puffin, atomicity of cancellation, SHOW STATS column name, no-TABLE-keyword syntax, NDV scan rationale) are accurate.

### Beginner clarity: 5/5
- No unexplained jargon. "Sketches," "Puffin file," "CBO," and "NDV" are either defined inline or used in context that makes meaning clear.
- Structure is clean: why it's slow → impact on dashboards → solution → cleanup → re-run scheduling → verification.
- Code blocks are commented and concrete.

### Practical applicability: 3/5
- The column-targeted ANALYZE recommendation is excellent and directly answers the user's question.
- However, the broken `partitions = ARRAY[...]` example will cost the engineer real time to debug — they will paste it, get a syntax error, and lose trust in the answer.
- The missing `drop_extended_stats` step means the engineer who follows the answer literally may end up confused about why the new column-subset ANALYZE doesn't seem to update stats as expected.
- The MinIO/Kubernetes production stack is implicitly fit (mentions MinIO once), but on-prem-specific concerns (no autoscaling to absorb ANALYZE load, resource group config under k8s) are not addressed.

### Completeness: 4/5
- Addresses all three of the user's sub-questions: (a) is 4h normal, (b) what's wrong, (c) can I speed it up via column-targeted analysis.
- Adds useful next steps: kill safety, scheduling, partition-by-partition iteration, verification via SHOW STATS.
- Missing the `drop_extended_stats` precondition is a completeness gap (in addition to being an accuracy gap).
- Does not mention that an EXPLAIN ANALYZE on a dashboard query (after stats land) is the way to confirm CBO is now using the new stats.

### Weighted average: (3×2 + 5 + 3 + 4) / 5 = **3.6/5**

This is technically above the global 3.5 pass threshold, but this topic ("Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering") has a **raised threshold of 4.5** because of the iter160 critical-error history. **3.6 is well below 4.5 — this answer FAILS the topic threshold.**

---

## Key findings to feed back to the teacher

### CRITICAL (must fix in resources/)
1. **Iceberg ANALYZE does not support `partitions`.** The teacher must remove any example of `ANALYZE iceberg.x.y WITH (partitions = ARRAY[ARRAY[...]])` from resources/. This is a Hive-connector-only property. If partition-scoped analysis is needed on Iceberg, the workaround is to filter via a temporary view or simply re-run column-subset ANALYZE periodically — there is no native per-partition ANALYZE on Iceberg. Resource must state this explicitly so the weak responder does not invent the syntax.
2. **`drop_extended_stats` must be documented** as a required step when transitioning from full-table ANALYZE to column-subset ANALYZE, or re-analyzing the same table with a different column set. This was flagged as a gap in iter161 and is still unfixed. The exact procedure call: `ALTER TABLE iceberg.x.y EXECUTE drop_extended_stats`.

### MEDIUM
3. **Resource group phrasing** should not equate resource groups with "fewer worker threads per query." Resource groups control concurrent query slots and memory limits; per-query parallelism is `task.concurrency` / `task.writer-count`. Recommend the teacher use precise language like "lower the concurrency cap for the ad-hoc resource group so ANALYZE does not compete with dashboards."

### LOW
4. Add a one-liner: after ANALYZE finishes, run `EXPLAIN` (not `EXPLAIN ANALYZE`) on a representative dashboard query and confirm the join order changed / row estimates look sane. This closes the loop from "stats exist" to "CBO actually used them."

---

## Rubric update

Topic: **Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering**
- Previous: NEEDS WORK, avg 4.400, 1 question
- New question score: 3.6
- New running avg: (4.400 + 3.6) / 2 = **4.000**, 2 questions
- Status: **NEEDS WORK** (threshold 4.5)
