# Judge Feedback — Iter 410 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.0 PASS** (Q1 2.625 FAIL + Q2 4.5 STRONG + Q3 4.5 STRONG + Q4 4.375 STRONG) — average crosses the 3.5 PASS threshold, but Q1 is an individual FAIL with a novel root cause.

**Headline: NEW FAILURE MODE — FINDABILITY / CROSS-REFERENCE GAP.** Q1 punted "I don't have enough information" on write.isolation-level. BUT the teacher ADDED a 120-line `write.isolation-level` section to resource 17 THIS ITERATION (lines 2108–2229 of `resources/17-iceberg-table-maintenance.md`) covering exactly the partition-disjoint MERGE false-positive scenario, the three-property namespace, commit.retry.num-retries, and a diagnostic recipe. The responder did not find it. The content is correct and complete; the discovery path is broken. This is structurally different from iter405/iter407 (confident inaccuracy) and from iter408 Q2 (genuine resource gap) — same observable behavior as iter408, different root cause, different fix.

**Pattern note:** ninth consecutive PASS technically (4.0 >= 3.5), but the lowest score since iter408 (4.125). Q2/Q3/Q4 all STRONG PASS — the four teacher iter410 BACKLOG SHORE-UPS landed correctly for SPILL_FAILED + EXPLAIN TYPE IO/VALIDATE + PERCENT_RANK/NTILE. Only write.isolation-level failed to land, and not because the content is wrong but because it's buried in resource 17 where the reader didn't look.

---

## Q1 — write.isolation-level serializable vs snapshot, partition-disjoint MERGE (PUNTED)

**Scores: 3.5 / 3.5 / 2.0 / 1.5 — avg 2.625 FAIL**

### What landed
- Honest "I don't have enough information" — better than fabricating.
- Cited resource 13 overwritePartitions atomicity + MERGE — correct as far as it went.
- Told the user to check Iceberg 1.5.2 docs for `iceberg.write-isolation-level` — workable but burdens the engineer.

### What missed
- **The answer IS in resources/.** Resource 17 lines 2108–2229 contain a 120-line `write.isolation-level` section covering: the three-property namespace (`write.delete.isolation-level` / `write.update.isolation-level` / `write.merge.isolation-level`); the partition-disjoint MERGE false-positive scenario; `commit.retry.num-retries=4` and `commit.retry.min-wait-ms=100` defaults; a diagnostic recipe via `$properties` + `$snapshots`. Every detail the engineer's question wanted was there.
- The responder appears to have searched `resources/13-postgres-to-iceberg-ingestion.md` (ingestion) and possibly concurrency keywords elsewhere, but didn't traverse into resource 17 (maintenance) where the section lives.

### Correct answer for the record (verified against `iceberg.apache.org/javadoc/1.7.1/org/apache/iceberg/IsolationLevel.html` and Iceberg Apache mail-archives)
- Iceberg supports two isolation levels for `UPDATE` / `DELETE` / `MERGE INTO`: **serializable** (default, strictest) and **snapshot**.
- Under **serializable**, an ongoing UPDATE/DELETE/MERGE FAILS if a concurrent transaction commits new data files that MIGHT contain rows matching the operation's WHERE predicate. The conflict check uses the partition spec + column min/max stats and is **conservative** — so disjoint-partition MERGEs CAN false-positive when (a) the predicate is on a non-partition column, or (b) the partition spec can't prove disjointness from newly-added files' partition values.
- Under **snapshot**, the check is relaxed: concurrent adds in disjoint partitions don't conflict, at the cost of potentially missing a phantom row that would have matched the operation's WHERE clause if seen.
- Properties are **namespaced per operation**: `write.delete.isolation-level` / `write.update.isolation-level` / `write.merge.isolation-level`. There is NO global `write.isolation-level` property — the older shortcut form is deprecated.
- `commit.retry.num-retries` (default `4` in Iceberg 1.5.2) controls how many times a write retries on conflict before raising `CommitFailedException`. `commit.retry.min-wait-ms` (default `100`) is the initial exponential backoff.
- **Fix path for chronic false-conflicts**: (a) make partition pruning explicit so the partition spec can prove disjointness; (b) relax to snapshot isolation if the workload tolerates the phantom-row risk; (c) raise `commit.retry.num-retries`; (d) serialize the writers in scheduling.

### Verdict
**FAIL on a FINDABILITY / DISCOVERABILITY axis, NOT a content-accuracy or content-completeness axis.** The fix is not "write more content" — it's "make existing content discoverable from where the question naturally arises."

---

## Q2 — SPILL_FAILED on k8s ephemeral disk

**Scores: 4.5 / 4.0 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **Spilling defined correctly**: Trino runs out of worker memory mid-query and writes intermediate state (hash tables for window / GROUP BY) to local disk to continue executing.
- **Window functions + GROUP BY identified as the memory-hungry shapes** — accurate.
- **K8s root cause correctly diagnosed**: pod ephemeral disk has no PVC mounted, so the spill path either fills up or is read-only / non-existent — exactly the on-prem k8s failure mode.
- **Four fix paths enumerated**:
  - Mount PVC at spill path + configure `spill-enabled` / `spiller-spill-path` — correct (verified against `trino.io/docs/current/admin/properties-spilling.html`).
  - Tighten WHERE partition pruning to reduce hash table size — correct treatment-at-root.
  - Pre-aggregate via rollup table — correct architectural alternative.
  - Raise per-node memory or lower concurrency via resource groups — correct.

### Minor gaps
- No mention that spill-to-disk is **legacy/unmaintained as of Trino 454** — Trino now recommends Fault-Tolerant Execution (FTE) as the modern alternative (Trino #22845). Production is on Trino 467, so the legacy spill mechanism is still supported but a forward-looking note would help.
- Doesn't mention `max-spill-per-node` / `query-max-spill-per-node` properties as a guardrail.
- No `kubectl describe pod` diagnostic for confirming ephemeral-storage cap.

### Verdict
STRONG PASS. On-prem k8s spill diagnosis is sound; engineer can act on it immediately.

---

## Q3 — EXPLAIN TYPE IO + TYPE VALIDATE

**Scores: 5.0 / 4.5 / 4.5 / 4.0 — avg 4.5 STRONG PASS**

### What landed
- **`EXPLAIN (TYPE IO, FORMAT JSON)` does NOT execute** — verified against `trino.io/docs/current/sql/explain.html`.
- **Returns `inputTableColumnInfos`** with catalog/schema/table/columnConstraints (pushed predicates) + `estimate.outputRowCount` from CBO — verified exactly correct JSON shape.
- **Cheap, no scan** — correct (CBO uses stats, no data read).
- **`EXPLAIN (TYPE VALIDATE)` parses + resolves names + type-checks WITHOUT executing**, returns single `'Valid'` boolean column — verified.
- **Even cheaper than TYPE IO** — correct (no CBO pass needed).

### Minor gaps
- No literal worked example showing the JSON output structure for `inputTableColumnInfos` (would help an engineer who's never used it).
- Doesn't explicitly position TYPE IO as **the canonical predicate-pushdown verification tool** at plan time (versus EXPLAIN ANALYZE which actually scans).

### Verdict
STRONG PASS. Both EXPLAIN variants correctly distinguished; cost framing is accurate.

---

## Q4 — NTILE uneven buckets + NULL handling

**Scores: 4.5 / 4.5 / 4.5 / 4.0 — avg 4.375 STRONG PASS**

### What landed
- **NTILE remainder rule correctly stated**: 9997 rows / 10 buckets = 999 quotient + 7 remainder, so first 7 buckets get 1000 rows each, last 3 get 999. **Verified against Oracle/SQL Server/BigQuery NTILE docs**: "remainder values are distributed one for each bucket, starting with bucket 1" — universal SQL standard behavior.
- **No two tiles differ by more than 1 row** — correctly implied.
- **For exact-equal use PERCENT_RANK threshold or fixed boundary split** — correct alternative when exact equality matters.
- **NULL hypothesis correctly framed**: either NULL in the ORDER BY column (NULLs sort first in Trino default), or PERCENT_RANK single-row partition `(rank-1)/(n-1)` divides by zero. (NTILE itself doesn't have the divide-by-zero edge — it returns 1 for a single-row partition.)
- **Check for NULL/zero usage rows** is the correct diagnostic.

### Minor gaps
- Dense style, beginner clarity could be improved.
- Doesn't show the literal SQL pattern to filter NULLs (`WHERE usage IS NOT NULL` before the NTILE).
- Doesn't mention Trino's default NULLS FIRST ordering (NULLS sort first in ASC, last in DESC unless overridden).

### Verdict
STRONG PASS. Remainder distribution rule is correct and the NULL diagnostic is the right place to look.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 2.625 | FAIL — write.isolation-level PUNTED (FINDABILITY/CROSS-REF gap, content exists in resource 17) |
| Q2 | 4.5 | STRONG PASS — SPILL_FAILED k8s ephemeral disk |
| Q3 | 4.5 | STRONG PASS — EXPLAIN TYPE IO + TYPE VALIDATE |
| Q4 | 4.375 | STRONG PASS — NTILE remainder distribution + NULL diagnostic |

**Average 4.0 PASS** — clears the 3.5 PASS threshold, but Q1 is an individual FAIL. **New failure mode**: not content inaccuracy (iter405/iter407), not content gap (iter408 Q2), but cross-reference / discoverability. The teacher correctly identified `write.isolation-level` as a backlog item and shored it up THIS ITERATION, but placed the content in resource 17 (maintenance) where a reader with a "concurrent MERGE conflict / partition-disjoint" question wouldn't naturally look.

**Trajectory iter394-410:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/**4.0P**`. Ninth consecutive PASS, but the lowest score since iter408. The Q2/Q3/Q4 wins confirm three of four teacher backlog shore-ups landed correctly; the Q1 outcome confirms the fourth (write.isolation-level) is a discovery problem, not a content problem.

---

## Teacher actions next (iter 411)

1. **MEDIUM — CROSS-REFERENCE / DISCOVERABILITY fix for `write.isolation-level`.** The content is correct and complete in resource 17 lines 2108–2229. The problem is that a reader with a "concurrent MERGE conflict on disjoint partitions" question naturally searches:
   - `resources/13-postgres-to-iceberg-ingestion.md` (ingestion, overwritePartitions, MERGE)
   - any concurrency-conflict resource
   - NOT `resources/17-iceberg-table-maintenance.md` (table maintenance — feels like compaction/snapshots/orphan-files territory).

   **Required cross-references**:
   - (a) Add a forward-pointer in `resources/13-postgres-to-iceberg-ingestion.md` under the overwritePartitions / MERGE INTO section: *"For concurrent-write conflict semantics (serializable vs snapshot isolation, partition-disjoint MERGE false-positives, `commit.retry.num-retries` retry behavior), see `resources/17-iceberg-table-maintenance.md` § `write.isolation-level`."*
   - (b) Add a similar forward-pointer in any concurrency-conflict resource section (currently scattered across resources 10, 13, 17, 22, 05 per `grep -l 'isolation\|serializable\|snapshot isolation'`).
   - (c) **Strongly consider** promoting `write.isolation-level` to a top-level section header in resource 17 (or breaking it into a dedicated `resources/26-iceberg-concurrent-write-conflicts.md` resource). It's a 120-line section answering a specific operational question; burying it mid-document in "table maintenance" loses discoverability.

2. **LOW polish — Q2 spill resource**: add **FTE migration callout** (spill-to-disk is legacy/unmaintained as of Trino 454; FTE is the modern alternative — Trino #22845) + `max-spill-per-node` / `query-max-spill-per-node` properties + `kubectl describe pod` diagnostic for confirming ephemeral-storage cap on the pod.

3. **LOW polish — Q3 EXPLAIN resource**: add literal `EXPLAIN (TYPE IO, FORMAT JSON)` worked example showing the `inputTableColumnInfos` JSON output structure + callout that TYPE IO is the canonical predicate-pushdown verification tool at plan time (vs EXPLAIN ANALYZE which actually scans).

4. **LOW polish — Q4 NTILE resource**: add the literal `WHERE usage IS NOT NULL` SQL pattern to filter NULLs before windowing + a note on Trino's default NULLS FIRST (ASC) / NULLS LAST (DESC) ordering, since this matters for which bucket NULL-bearing rows land in if not filtered.

5. **LOW carry-forward backlog**: dbt-trino merge dups, predicate-pushdown JDBC rewrite, SHOW SESSION catalog-prefix, HMS->Nessie no-downtime, MERGE rollback, OPA-override timeout, schema registry compat, JWT+OPA concurrency, Iceberg tagging 3rd-angle, fs.cache JMX 3rd-angle, RANGE INTERVAL gap-day, equality delete 1.5.2 bug context, Iceberg v3 deletion vectors timeline.

---

## Judge probe targets next (iter 411)

1. **CRITICAL RE-PROBE write.isolation-level** AFTER teacher cross-reference fix lands — same question phrasing ("concurrent MERGE conflict on disjoint partitions — why?") — confirms the responder NOW finds the content via the cross-reference pointer or the promoted section header.

2. **write.isolation-level 2nd-angle** — different facet: *"what's the difference between serializable and snapshot isolation in Iceberg, and when should I switch to snapshot?"* — probes the technical content directly, less reliant on which resource the reader lands in first.

3. **SPILL_FAILED 2nd-angle** — different facet: *"should I migrate from spill-to-disk to FTE in Trino 467 / on-prem k8s?"* — probes the FTE-vs-spill decision and confirms the responder knows spill is legacy.

4. **EXPLAIN TYPE IO 2nd-angle** — *"how do I verify a predicate is being pushed down to Iceberg without actually running the query?"* — natural follow-on, confirms TYPE IO as predicate-pushdown verification tool.

5. **NTILE 2nd-angle** — *"why is my decile bucket #1 always larger than #10 when I expected equal-sized deciles?"* — confirms remainder distribution understanding from a different angle.

6. **HMS->Nessie no-downtime migration** carry-forward.

7. **Iceberg v3 deletion vectors timeline** carry-forward.
