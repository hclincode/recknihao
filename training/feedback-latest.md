# Iter 375 Judge Feedback — 2026-05-30 (EXTENDED PHASE)

## Iteration Summary

| Question | Topic | Average | Verdict |
|---|---|---|---|
| Q1 | Trino memory config / OOM on aggregations (query perf regression diagnosis) | 4.375 | PASS |
| Q2 | Iceberg small files / 5-min batch writes (Iceberg maintenance) | 4.4375 | PASS |
| **Iter avg** | | **4.40625** | **PASS** |

Iter convergence: std-dev 0.03125 — tightest convergence of recent iterations, suggests stable resource quality across both general-Trino and Iceberg-maintenance tracks.

---

## Q1 — Trino memory config, OOM on aggregations

### Scoring

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.5 | All three memory property names CONFIRMED real; spill prereqs CONFIRMED; 25% per-node sizing is conservative vs. community consensus 30% but defensible as safe starting point |
| Beginner clarity | 4.0 | Property names cascade without inline gloss; "rolling restart", "JVM heap", "spill" used assuming background |
| Practical applicability | 4.5 | Priority order (restructure → join_distribution_type → spill) is actionable; concrete config values; Trino UI verification step; kubectl rolling restart fits on-prem k8s prod environment |
| Completeness | 4.5 | Three knobs + spill prereqs + verify + priority order is comprehensive; missing `memory.heap-headroom-per-node` constraint that sum of per-node + headroom must be < JVM heap |
| **Average** | **4.375** | **PASS** |

### Judge WebSearch verification

1. **`query.max-memory-per-node` is real** — CONFIRMED per [Resource management properties — Trino 480 Documentation](https://trino.io/docs/current/admin/properties-resource-management.html): "limits the amount of memory a query may use on any one node." Constraint: sum of `query.max-memory-per-node` + `memory.heap-headroom-per-node` must be less than max JVM heap size on the node.
2. **`query.max-memory` (cluster) is real** — CONFIRMED at same docs page.
3. **`query_max_memory` (session) is real** — CONFIRMED at [Memory management properties — Trino 370+ docs](https://trino.io/docs/current/admin/properties-memory-management.html). Session form maps to the config-level cluster limit.
4. **25% of JVM heap sizing** — DEFENSIBLE BUT CONSERVATIVE. Per [Right-Sizing Trino: A Data-Driven Guide to Cluster Memory Tuning (Vivek Jain, Medium)](https://medium.com/@vjain143/right-sizing-trino-a-data-driven-guide-to-cluster-memory-tuning-a31b6a80c2f6) and [Trino Memory Config Calculator](https://vjain143.github.io/Trino_Memory_Sizing_Guidelines.html), the more common recommendation is ~30% of JVM heap for `query.max-memory-per-node` (e.g., 14GB on a 48GB heap). 25% is within safe bounds and avoids under-allocating headroom, but slightly under-utilizes resources. Responder's 25% is correct as a STARTING POINT but should be flagged as such, with 30% as the upper-conservative ceiling. NOT a factual error.
5. **Spill properties** — All CONFIRMED per [Spilling properties — Trino 479 docs](https://trino.io/docs/current/admin/properties-spilling.html) and [Spill to disk — Trino 481 docs](https://trino.io/docs/current/admin/spill.html):
   - `spill-enabled` (cluster) / `spill_enabled` (session) — both exist
   - `spiller-spill-path` — exists, supports comma-separated paths for JBOD
   - `max-spill-per-node` — exists, total node spill budget
   - `query-max-spill-per-node` — exists, per-query node spill budget
   - LZ4 compression (`spill-compression-codec`) — supported codec
   - Local SSD recommendation matches docs warning against system drives and NFS

### Gaps (deductions from 5)

- **Beginner clarity (-1.0)**: Properties cascade by name without inline one-line glosses. A SaaS engineer with no OLAP background hits 6+ unfamiliar Trino property names and may not know which lever to pull first. Glosses needed for: "JVM heap" = the Java memory pool the Trino worker JVM allocates at startup, "rolling restart" = restart workers one at a time so the cluster stays serving, "spill" = streaming intermediate hash-join/aggregation state to local disk when worker memory pressure exceeds budget.
- **Technical accuracy (-0.5)**: 25% sizing should be paired with the upper bound 30% (or stated as "start at 25%, can raise to 30% if heap-headroom calculation allows"). Sole 25% recommendation slightly under-utilizes available worker memory.
- **Practical applicability (-0.5)**: No `memory.heap-headroom-per-node` callout — this is the constraint that bites engineers ("I set per-node to 40% of heap and now the worker crashes on startup" because per-node + heap-headroom must be < JVM heap). Engineer needs this constraint to make sizing decisions safely.
- **Completeness (-0.5)**: Missing (a) `memory.heap-headroom-per-node` constraint and recommended sizing (default 30% of heap, never below 2GB); (b) EXPLAIN ANALYZE VERBOSE diagnostic to confirm the OOM source is HashAggregation operator (not output buffer); (c) which aggregation pattern is the typical OOM driver (high-cardinality GROUP BY > many-window-function chains > distinct-count without HyperLogLog).

---

## Q2 — Iceberg small files problem, 5-min batch writes

### Scoring

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.5 | File count math correct (2,016 ~ 2,000); 10-50ms per-file metadata reasonable; 256MB target valid (default is 512MB but 256MB is sensible for 5-min cadence); rewrite_data_files signature correct; 4-step maintenance ordering matches official guidance after compact step |
| Beginner clarity | 4.0 | Concrete numbers help; "manifest explosion", "binpack", "snapshot" used without inline gloss; "metadata overhead" not unpacked |
| Practical applicability | 4.75 | Concrete numbers (2,000 files, 20-100s overhead, 30s+ query planning); exact Spark procedure call with parameters; Trino alternative (`ALTER TABLE EXECUTE optimize`); 4-step maintenance sequence — engineer knows exactly what command to run next |
| Completeness | 4.5 | Covers symptoms, math, fix, ordering, alternative; could add (a) write-side prevention via `write.target-file-size-bytes` table property; (b) explicit cadence guidance (hourly vs. daily compaction); (c) Trino `file_size_threshold` parameter |
| **Average** | **4.4375** | **PASS** |

### Judge WebSearch verification

1. **Small files problem accurately described** — CONFIRMED per [Compaction in Apache Iceberg (Dremio blog)](https://www.dremio.com/blog/compaction-in-apache-iceberg-fine-tuning-your-iceberg-tables-data-files/) and [Spark Iceberg and problem of Tiny files (Medium)](https://medium.com/@deepa.account/spark-iceberg-and-problem-of-tiny-files-9d5d369b77cb): small files inflate metadata overhead and runtime file open cost. Responder's 10-50ms per-file metadata estimate is in the documented range for object-store metadata latency. 2,016 file count for 5-min × 7-day cadence is arithmetically correct.
2. **`rewrite_data_files` parameters CONFIRMED** — per [Spark Procedures — Apache Iceberg latest docs](https://iceberg.apache.org/docs/latest/spark-procedures/):
   - `target-file-size-bytes` — exists, default 536870912 (512MB). Responder's 268435456 (256MB) is a valid override; sensible for 5-min cadence where 512MB targets are too aggressive.
   - `min-input-files` — exists, controls minimum file group size for rewrite.
   - Default strategy `binpack` correctly described.
3. **4-step maintenance sequence** — CONFIRMED per [The Iceberg Maintenance Runbook (IOMETE)](https://iomete.com/resources/blog/iceberg-maintenance-runbook) and [Maintenance — Apache Iceberg latest docs](https://iceberg.apache.org/docs/latest/maintenance/) and [GH issue #11804](https://github.com/apache/iceberg/issues/11804). The canonical safe order is: **expire_snapshots → remove_orphan_files → rewrite_manifests**. Compaction (`rewrite_data_files`) is a separate operation that typically goes FIRST because it creates new snapshots that the subsequent expire step then cleans up. Responder's compact → expire → orphan → manifests order is the correct full sequence. Running tasks out of this order risks data loss, broken time travel, or lingering orphan files.
4. **Trino `ALTER TABLE EXECUTE optimize` CONFIRMED** — per [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html): `ALTER TABLE test_table EXECUTE optimize(file_size_threshold => '128MB')`. Default threshold is 100MB. Files smaller than threshold are merged. This is the correct Trino ad-hoc alternative for users without direct Spark access.

### Gaps (deductions from 5)

- **Beginner clarity (-1.0)**: "manifest", "manifest explosion", "snapshot", "binpack" used without inline gloss. A SaaS engineer reading this for the first time needs: "manifest = Iceberg's per-snapshot index file listing which data files belong to the snapshot", "snapshot = an immutable commit of the table at a point in time", "manifest explosion = too many manifest files cause query planning to read megabytes of metadata before any data file is touched".
- **Technical accuracy (-0.5)**: `target-file-size-bytes` default is 512MB, not the answer's 256MB — should explicitly say "I'm overriding the default 512MB to 256MB because 5-min cadence does not produce enough per-batch data to fill 512MB economically". Without the framing, the engineer might think 256MB is the default.
- **Practical applicability (-0.25)**: No cadence guidance — should the engineer run this hourly, nightly, or weekly? For 5-min writes producing ~12 files/hour, hourly compaction is the typical recommendation. Missing this leaves the engineer unsure how often to schedule the job.
- **Completeness (-0.5)**: Missing (a) write-side prevention: `ALTER TABLE ... SET TBLPROPERTIES ('write.target-file-size-bytes'='268435456')` so new writes produce closer-to-target files, reducing how much compaction has to do; (b) Trino `file_size_threshold` parameter mention (`ALTER TABLE EXECUTE optimize(file_size_threshold => '256MB')`); (c) `write.distribution-mode = 'hash'` callout for partitioned tables to consolidate writes by partition key.

---

## Patterns across Q1 + Q2

1. **Property-name density without glosses** — Both answers list correct, verified property names but stack 4-7 of them without inline one-line definitions. This is the dominant beginner-clarity drag in both questions (BC = 4.0 on both). For an engineer with zero OLAP background, the property cascade is the single largest comprehension barrier even when each individual property is correctly named and used. This is the same pattern that has driven federation BC ceilings at 4.0 since iter360.
2. **Defaults vs. overrides not framed** — Q1's 25% sizing and Q2's 256MB target-file-size are both valid overrides of the documented defaults (30% / 512MB respectively) but the answers present them as the recommendation without framing them as overrides. This invites the engineer to think the answer's number IS the default, which it isn't.
3. **Both answers technically correct on substance** — All property names verified, all sequences verified, all syntax verified. The 4.4 iter average reflects clarity/framing gaps, not factual errors. This is a stable iteration in a mature topic band.
4. **Trino-on-k8s production fit landed cleanly on Q1** — `kubectl rolling restart`, Trino UI verification, all match the on-prem k8s production environment described in `prod_info.md`. No cloud-managed-service assumptions snuck in. This is durable evidence that the on-prem/k8s production-fit teacher actions from iter374 and earlier have stabilized.

---

## ITER376 TEACHER ACTIONS (PRIORITY-ORDERED)

### HIGH

1. **Inline-gloss the Trino memory property cascade in resources** — At first mention of each property name, add a one-line gloss: `query.max-memory` = total memory budget summed across all worker nodes for a single query; `query.max-memory-per-node` = max user memory a single query can use on ONE worker; `query_max_memory` = session-level override of the cluster `query.max-memory`. Also gloss "JVM heap" = the Java memory pool allocated to each Trino worker JVM at process startup; "rolling restart" = restart workers one at a time so the cluster stays serving queries; "spill" = streaming hash-table or sort state to local SSD when worker memory pressure exceeds the per-node budget. Tests directly against Q1 BC = 4.0 deduction.

2. **Inline-gloss the Iceberg metadata vocabulary in resources/maintenance section** — At first mention: "snapshot" = immutable commit of the table at a point in time; "manifest" = per-snapshot index file listing which data files belong to the snapshot, plus column-level min/max stats; "manifest list" = top-level pointer to the manifests of a single snapshot; "binpack" = the default rewrite strategy that combines small files into target-sized files without sort/zorder. Tests directly against Q2 BC = 4.0 deduction.

### MEDIUM

3. **Frame defaults vs. overrides explicitly** — In Trino memory section: "The default per-node sizing of 30% of JVM heap is the community consensus; 25% is a safer conservative starting point if you have a mix of analytics and embedded reporting workloads sharing the cluster." In Iceberg compaction section: "`target-file-size-bytes` defaults to 512MB (536870912). For 5-min batch cadences, override to 256MB (268435456) since per-batch volume rarely fills 512MB economically." Tests against Q1 TA -0.5 and Q2 TA -0.5.

4. **Add `memory.heap-headroom-per-node` constraint section** — Explicit callout: "The sum of `query.max-memory-per-node` + `memory.heap-headroom-per-node` MUST be less than max JVM heap. `memory.heap-headroom-per-node` defaults to 30% of heap, never below 2GB. If you raise per-node sizing without checking heap-headroom, the worker crashes on startup." Tests against Q1 PA -0.5.

5. **Add Iceberg compaction cadence guidance** — Concrete table: "5-min batch writes (12 files/hour): hourly compaction; hourly batch writes: 6-hourly compaction; daily batch writes: weekly compaction. Tune `min-input-files` higher (e.g., 10) for low-cadence to avoid rewriting near-target-size files." Tests against Q2 PA -0.25.

### LOW

6. **Carry-forward federation glossary expansion in resources/22** — CBO/BROADCAST/PARTITIONED/build-side/probe-side/left-deep-join-tree/`join_distribution_type`/`join_reordering_strategy`/dynamic-filtering — open since iter360. Not re-probed in iter375 but will re-emerge on next federation probe.

7. **Carry-forward HyperLogLog inline gloss** — `approx_distinct()` / `cardinality(approx_set())` open since iter372. Relevant to Q1 OOM-on-aggregation context: high-cardinality COUNT(DISTINCT) is a classic OOM driver and HyperLogLog approximation is the standard fix. Could be tied into the Q1 memory-OOM teaching path.

8. **Carry-forward iter374 actions** — (a) Trino S3 filesystem config deltas section (AWS-vs-MinIO side-by-side: `fs.native-s3.enabled` / `s3.endpoint` / `s3.path-style-access`); (b) Metadata caching property names (`iceberg.metadata-cache-enabled` / `iceberg.metadata-cache-max-size` / `iceberg.metadata-cache-ttl` / `hive.metastore-cache-ttl`); (c) MinIO TCO decomposition.

---

## ITER376 JUDGE PROBE TARGETS

1. **Trino memory glossary follow-up at fresh phrasing** — "What's the difference between `query.max-memory` and `query.max-memory-per-node` — and which one do I tune when a single query OOMs vs. when multiple concurrent queries OOM?" — tests iter376 action #1 inline glossaries and the cluster-vs-per-node distinction.

2. **Iceberg compaction cadence follow-up** — "How often should I run `rewrite_data_files` on a table that gets 5-min batch writes? Hourly? Nightly? Weekly?" — tests iter376 action #5.

3. **Write-side compaction prevention** — "Can I tune Spark/Iceberg so it writes larger files in the first place, instead of always playing catch-up with compaction?" — tests whether write-side table properties (`write.target-file-size-bytes`, `write.distribution-mode`) land as resources, not just compaction-side fixes.

4. **Carry-forward federation glossary** (CBO/BROADCAST/PARTITIONED) — open since iter360.

5. **Carry-forward iter374 action #3 metadata caching property names by name** — "Our Iceberg queries do tons of small reads against MinIO — what's the specific Trino config property to enable metadata caching?" — still not probed since iter374.

6. **Carry-forward iter374 action #4 Trino S3 filesystem config deltas** — "How do I point Trino at our MinIO vs AWS S3 — what properties change in the catalog file?" — still not probed since iter374.

---

## Topic running averages after iter375

- **Iceberg table maintenance** (Q2): (4.531 x 45 + 4.4375) / 46 = 208.332 / 46 = **4.533 across 46 questions** — PASSED top band hold.
- **Query performance regression diagnosis** (Q1): (5.0 x 2 + 4.375) / 3 = 14.375 / 3 = **4.792 across 3 questions** — PASSED but only 3 questions; iter376 should probe a 4th angle to durabilize.

## Sources verified via WebSearch

- [Resource management properties — Trino 480 Documentation](https://trino.io/docs/current/admin/properties-resource-management.html) — `query.max-memory-per-node` and `query.max-memory` confirmed; per-node + heap-headroom constraint confirmed.
- [Memory management properties — Trino 370 Documentation](https://trino.io/docs/current/admin/properties-memory-management.html) — session-form `query_max_memory` confirmed.
- [Right-Sizing Trino: A Data-Driven Guide to Cluster Memory Tuning (Vivek Jain, Medium)](https://medium.com/@vjain143/right-sizing-trino-a-data-driven-guide-to-cluster-memory-tuning-a31b6a80c2f6) — community 30%-of-heap recommendation for per-node sizing.
- [Trino Memory Config Calculator (Vivek Jain)](https://vjain143.github.io/Trino_Memory_Sizing_Guidelines.html) — heap headroom = 30% of heap, never below 2GB.
- [Spilling properties — Trino 479 Documentation](https://trino.io/docs/current/admin/properties-spilling.html) — `spill-enabled`, `spill_enabled`, `max-spill-per-node`, `query-max-spill-per-node` all confirmed.
- [Spill to disk — Trino 481 Documentation](https://trino.io/docs/current/admin/spill.html) — `spiller-spill-path` confirmed; do-not-spill-to-system-drives guidance.
- [Spark Procedures — Apache Iceberg latest docs](https://iceberg.apache.org/docs/latest/spark-procedures/) — `rewrite_data_files`, `target-file-size-bytes` default 536870912 (512MB), `min-input-files`, binpack strategy all confirmed.
- [The Iceberg Maintenance Runbook (IOMETE)](https://iomete.com/resources/blog/iceberg-maintenance-runbook) — maintenance ordering: expire_snapshots → remove_orphan_files → rewrite_manifests confirmed.
- [Maintenance — Apache Iceberg latest docs](https://iceberg.apache.org/docs/latest/maintenance/) — official maintenance operations and ordering guidance.
- [GH apache/iceberg #11804 — correct sequence for running maintenance steps](https://github.com/apache/iceberg/issues/11804) — community consensus on safe ordering.
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) — `ALTER TABLE EXECUTE optimize(file_size_threshold => '128MB')` confirmed; default 100MB.
- [Compaction in Apache Iceberg (Dremio blog)](https://www.dremio.com/blog/compaction-in-apache-iceberg-fine-tuning-your-iceberg-tables-data-files/) — small files problem and metadata overhead confirmed.
