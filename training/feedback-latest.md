# Iter 389 Feedback — 2026-05-30 (EXTENDED PHASE)

**Overall: 4.75 / 5.00 — STRONG PASS** (recovery from iter388 3.125 FAIL)

---

## Q1 — Iceberg tags for month-end audit bookmarks (2nd-angle test of iter388 gap)

**Responder answer summary**: Query `$snapshots` for snapshot_id; Spark `ALTER TABLE CREATE TAG name AS OF VERSION id RETAIN 3650 DAYS`; Trino read via `FOR VERSION AS OF 'tag-name'`; tags protect snapshots from `expire_snapshots`; create/drop Spark-only + read both engines; concrete billing-audit workflow.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | CREATE TAG syntax correct (Spark only); `RETAIN 3650 DAYS` per-tag retention correct; `FOR VERSION AS OF 'tag-name'` Trino read path correct; expire_snapshots protection correct (tagged snapshots pinned via SnapshotRef); Spark-write/Trino-read split correct |
| Beginner clarity | 4.0 | Workflow is concrete; `$snapshots` assumes some metadata-table familiarity — could inline-gloss "$snapshots = Iceberg metadata table listing all snapshot IDs with timestamps" |
| Practical applicability | 5.0 | Engineer knows exact path: query `$snapshots` -> CREATE TAG in Spark with RETAIN -> query FROM Trino with FOR VERSION AS OF — full billing-audit workflow |
| Completeness | 5.0 | Snapshot lookup, create syntax, retention clause, query syntax, protection from expiry, engine split, billing-audit use case all covered |
| **Average** | **4.75** | **STRONG PASS** |

**Verdict**: Direct fill of iter388 Q1 categorical-denial error. TA recovery 2.0 -> 5.0. The canonical SnapshotRef tag pattern is now taught with the Trino-write-DDL qualifier engineer needs.

---

## Q2 — Trino native file system cache (2nd-angle test of iter388 gap)

**Responder answer summary**: `fs.cache.enabled=true` + `fs.cache.directories` + `fs.cache.max-sizes` in iceberg.properties; mutual exclusivity with `iceberg.metadata-cache.enabled`; k8s emptyDir or local PVC; JMX verification; when cache helps (hot partitions, repeated reads) vs less helpful (ad-hoc wide scans).

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Property names verified against trino.io/docs/current/object-storage/file-system-cache.html — `fs.cache.enabled`, `fs.cache.directories`, `fs.cache.max-sizes` correct; mutual exclusivity with `iceberg.metadata-cache.enabled` correct |
| Beginner clarity | 4.0 | k8s emptyDir vs local PVC choice is concrete; JMX could use brief gloss ("JMX = Trino's built-in metrics endpoint, query `jmx.current` schema from Trino itself") |
| Practical applicability | 5.0 | Catalog file placement correct; production-fit excellent for on-prem MinIO + k8s; JMX gives feedback loop; applicability boundaries (hot partitions help; ad-hoc wide scans less helpful) prevent misuse |
| Completeness | 5.0 | Enable flag, directories, sizes, mutual exclusivity, k8s storage, verification, applicability all covered |
| **Average** | **4.75** | **STRONG PASS** |

**Verdict**: Direct fill of iter388 Q2 honest-punt. TA recovery 3.5 -> 5.0. File system cache configuration now sourced from official Trino docs with k8s storage path that matches the production stack.

---

## Patterns / next-iteration guidance

1. **Recovery confirmed**: Both critical iter388 resource gaps (Iceberg native tagging + fs.cache.enabled) are now filled with high-quality, production-fit answers. Categorical-denial regression fully reversed.
2. **Engine-split qualifiers preserved**: Q1 explicitly notes Spark-only CREATE TAG / both-engine read; Q2 explicitly notes mutual exclusivity with metadata-cache. Both prevent downstream misuse.
3. **Minor BC opportunity**: Both answers could add 1-sentence inline glosses for `$snapshots` (Q1) and JMX (Q2) to reach 5.0 on Beginner clarity. Not blocking — BC 4.0 is solid.
4. **Trajectory iter370-389**: 4.625 -> 4.375 -> 4.47 -> 3.98 FAIL -> 4.5625 -> 4.75 -> 4.1875 -> 4.4375 -> 4.40625 -> 4.5625 -> 3.25 FAIL -> 4.71875 -> 4.8125 -> 4.78125 -> 4.375 -> 4.094 -> 4.4375 -> 4.4375 -> 4.4375 -> 4.25 -> 3.125 FAIL -> **4.75 PASS**. Teacher successfully patched both targeted gaps in single iteration.
5. **Topic score updates**:
   - Iceberg table maintenance: 4.5050/50 -> 4.5098/51 (mild rise, still PASS)
   - Cost considerations: 4.063/14 -> 4.1088/15 (mild rise, still PASS)

## Probe targets for iter 390

1. **Iceberg tagging 3rd angle**: drop expired tag + audit ref retention via `$refs` metadata table; verify Trino sees only currently-valid tags after `max-ref-age-ms` expiry.
2. **fs.cache 3rd angle**: JMX cache-hit-rate metric name + tuning `fs.cache.max-sizes` when working set exceeds cache size; cache-warming strategy via `INSERT INTO SELECT` from hot partitions.
3. **Carry-forward iter387/388**: catalog migration HMS->Nessie no-downtime, SPILL_FAILED at 60GB with 200GB cap, Z-order 2nd angle, audit log 2nd angle, MERGE INTO rollback, Trino timeout OPA-override, schema registry forward/backward compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches concurrent fast_forward, bucket sizing 32/128/256, JWT+OPA concurrency, partition spec migration without downtime.
