# Judge Feedback — Iter 388 (EXTENDED PHASE)

## Iter 388 overall: 3.125 — FAIL (<4.0 bar)

Q1 2.75 FAIL (Iceberg table tagging/organization) + Q2 3.5 BORDERLINE FAIL (Trino file system cache). Major drop from iter387 4.25. **Critical TA error in Q1**: responder claimed "no native tagging system" in Iceberg — Iceberg has had native SnapshotRef-based tags + branches since spec v1, with full create/manage support in Spark and READ support in Trino via `FOR VERSION AS OF 'tag-name'` and the `$refs` metadata table. Q2 was an honest "not enough info" punt, but missed that `fs.cache.enabled` IS Trino's documented file system data cache (Alluxio-based) — the feature DOES exist and is in official Trino docs at `/object-storage/file-system-cache.html`.

---

## Q1 — Iceberg table tagging and organization: 2.75 FAIL

Responder gave: "no native tagging system"; separate schemas (prod/staging/dev); TBLPROPERTIES for custom metadata (Spark sets, Trino reads via `$properties`); REST catalog future path; practical: use schemas now.

| Dimension | Score | Why |
|---|---|---|
| Technical accuracy | 2.0 | **CRITICAL FACTUAL ERROR**: "No native tagging system" is wrong. Iceberg spec defines SnapshotRef tags as first-class objects — immutable labels for snapshot IDs with independent retention policies. Spark supports `ALTER TABLE ... CREATE TAG`/`CREATE BRANCH`. Trino's Iceberg connector supports time-travel TO tags/branches via `FOR VERSION AS OF 'tag-name'` and exposes branches+tags through the `$refs` metadata table (Trino 467 confirmed). What Trino LACKS is the SQL DDL to *create* tags — that gap is the real nuance, but it is not "no tags exist". Responder collapsed a partial-tooling-gap into a false absolute claim. TBLPROPERTIES + $properties advice is technically correct. Schema separation advice is correct but tangential. |
| Beginner clarity | 3.5 | Schema separation explanation is clear; SaaS engineer can follow. Jargon "REST catalog", "$properties metadata table", "TBLPROPERTIES" not inline-glossed. |
| Practical applicability | 3.0 | Schema-based isolation (prod/staging/dev) IS actionable for the production stack. But engineer walks away NOT KNOWING the Iceberg-native feature they actually want (tag a snapshot as "v1.0-release", time-travel to it via `FOR VERSION AS OF`). Loses the most valuable production lever. |
| Completeness | 2.5 | Misses entirely: (a) Iceberg SnapshotRef tags exist natively in the spec; (b) Spark `ALTER TABLE t CREATE TAG 'v1' AS OF VERSION <snapshot_id>` syntax for tag management (production stack runs Spark for ingestion — engineer CAN create tags); (c) Trino `SELECT * FROM events FOR VERSION AS OF 'v1'` for reading tagged snapshots; (d) `$refs` metadata table for listing branches/tags; (e) Tag retention policy (`max-ref-age-ms`) for independent lifecycle from main branch. |
| **Average** | **2.75** | **FAIL** |

**Why this matters**: The production stack uses Spark for ingestion + Trino for queries with Iceberg 1.5.2 — exactly the combination where native Iceberg tagging works best (create in Spark, read in Trino). Answering "no native tagging" sends the engineer down the schema-namespace workaround when a one-line `ALTER TABLE ... CREATE TAG` would have served them.

---

## Q2 — Trino file system cache: 3.5 BORDERLINE FAIL

Responder gave: honest "not enough info"; found metadata caching (`iceberg.metadata-cache.enabled`); no data file cache content found in resources; recommends checking official Trino docs.

| Dimension | Score | Why |
|---|---|---|
| Technical accuracy | 3.5 | `iceberg.metadata-cache.enabled` correctly identified — verified valid (enabled by default, in-memory coordinator cache). "Not enough info" framing is technically defensible AS A RESOURCE LIMITATION, not as a Trino reality: `fs.cache.enabled` + `fs.cache.directories` ARE the documented data file cache properties (Alluxio-backed local-disk cache for object storage reads). Responder correctly refused to invent, but the gap in resources/ should be flagged for the teacher. |
| Beginner clarity | 4.0 | Clear, honest framing; minimal jargon; engineer understands the scope of the answer. |
| Practical applicability | 3.5 | "Check official docs" is actionable and safer than hallucinating. But a stronger answer would name `fs.cache.enabled` + point at `/object-storage/file-system-cache.html` as the canonical doc page. |
| Completeness | 3.0 | Misses: (a) `fs.cache.enabled` as the actual file system data cache property name; (b) `fs.cache.directories` for cache location (k8s PV mount detail relevant to on-prem); (c) the relationship "when fs.cache.enabled=true, iceberg.metadata-cache.enabled is deactivated" (mutual exclusivity); (d) cache invalidation behavior; (e) production-stack-fit: with MinIO on-prem + k8s, fs.cache.enabled on local NVMe PVs is the canonical pattern. |
| **Average** | **3.5** | **BORDERLINE FAIL** (≥4.0 bar) |

**Honest-punt credit**: Choosing "not enough info" over hallucination is the correct behavior when resources/ truly lacks coverage — this is graded positively in BC and slightly in TA. But the scoring still fails the 4.0 bar because the feature DOES exist publicly and the resource gap should be filled.

---

## Patterns

1. **TA collapse on Q1** (-2.5 from previous TA ceiling): "no X exists" framing on a feature that DOES exist is the worst failure mode — it actively misleads the engineer. Compare to iter387 where TA slip was a precision/framing issue (4.75→4.5); here it's a categorical error (4.75→2.0).
2. **BC unchanged at 3.5-4.0**: still the persistent cap — 11+ consecutive iterations of inline-gloss work pending.
3. **PA collapse on Q1** (-1.5): when the core feature is denied, even the workaround answer loses PA because the engineer doesn't know what they're missing.
4. **Comp slip on both Qs**: Q1 missing the entire native-tagging story; Q2 missing fs.cache.enabled.

## Teacher actions next (iter 389)

1. **CRITICAL TA Q1** — Add Iceberg native tagging coverage to resources:
   - Iceberg SnapshotRef objects: tags are immutable labels pointing to snapshot-id; branches are mutable refs.
   - Spark DDL: `ALTER TABLE events CREATE TAG 'v1.0-release' AS OF VERSION 1234567890123` and `ALTER TABLE events CREATE BRANCH 'audit'`.
   - Trino READ syntax: `SELECT * FROM events FOR VERSION AS OF 'v1.0-release'` (time-travel by tag name).
   - Trino `$refs` metadata table: `SELECT * FROM "events$refs"` lists all branches+tags with snapshot_id, type, retention.
   - Trino WRITE gap (production stack): Trino 467 cannot CREATE/DROP tags — that DDL must come from Spark in this stack.
   - Tag retention property: `history.expire.max-ref-age-ms` per-tag, independent from main branch retention.
   - Use cases: tag releases, freeze month-end snapshots for audit, mark "known-good" snapshots before risky writes.
2. **CRITICAL TA Q2** — Add fs.cache coverage:
   - `fs.cache.enabled=true` enables the Trino file system cache (Alluxio-backed local disk cache for object storage reads).
   - `fs.cache.directories=/cache/trino` sets cache location (k8s: mount local NVMe via PV/PVC).
   - `fs.cache.max-disk-usage-percentage=80` cache size cap.
   - Mutual exclusivity: when fs.cache.enabled=true, iceberg.metadata-cache.enabled is deactivated (metadata gets cached on local disk instead).
   - Production-stack-fit: on-prem MinIO + k8s + on-prem hardware = fs.cache.enabled on local NVMe is the canonical accelerator for repeated reads.
   - Reference: trino.io/docs/current/object-storage/file-system-cache.html
3. **HIGH BC** — Continue inline-gloss cascade for new vocab:
   - "SnapshotRef" → named pointer to a snapshot ID with its own retention policy
   - "tag" → immutable named reference to a specific snapshot (release marker)
   - "branch" → mutable named reference that can advance with new commits
   - "$refs metadata table" → built-in Trino query path showing all branches+tags for an Iceberg table
   - "Alluxio-backed cache" → local-disk cache for remote object storage reads
4. **MED Comp Q1** — Add concrete production examples: "tag v1.0-release in Spark before quarterly close; auditors query `FOR VERSION AS OF 'v1.0-release'` from Trino months later even if main snapshot was rewritten".

## Judge probe targets next (iter 389)

1. **Iceberg tagging 2nd angle** — "How do I freeze a snapshot for audit so analysts can query it 90 days later even after compaction?" tests SnapshotRef tag + max-ref-age-ms + FOR VERSION AS OF.
2. **Trino fs.cache 2nd angle** — "Repeated dashboard queries hit MinIO every time — how do I cache parquet files on the workers?" tests fs.cache.enabled + cache directory sizing.
3. Carry-forward (still unprobed): Catalog migration HMS→Nessie (iter387 deferred), SPILL_FAILED at 60GB (iter387 deferred), Z-order 2nd angle, audit log 2nd angle, MERGE INTO rollback, Trino timeout OPA-override, schema registry forward/backward compat.

---

**State update**: state.json bumped to iteration 388.
