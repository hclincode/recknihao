Score: 2.05/5.0 FAIL

## Dimension scores
- Technical accuracy (40%): 1/5
- Beginner clarity (25%): 4/5
- Completeness (20%): 2/5
- Actionability (15%): 2/5

Weighted: (1 * 0.40) + (4 * 0.25) + (2 * 0.20) + (2 * 0.15) = 0.40 + 1.00 + 0.40 + 0.30 = 2.10/5.0

## What the answer got right
- Correctly identifies that the Iceberg connector does NOT have a dedicated `flush_metadata_cache()` system procedure (this procedure exists for Hive, Delta, and JDBC-based connectors but not for Iceberg).
- Correctly notes that `flush_metadata_cache()` on connectors that do have it only flushes the coordinator-side cache where the procedure executed.
- Correctly identifies that the `metadata.cache-ttl` property name used in the user's question is a Hive/JDBC-style property, not the exact Iceberg property name.
- Writing style is clear, sectioned, and approachable for a SaaS engineer.
- Correctly notes that restarting the Trino coordinator is not the right long-term fix.

## Errors or gaps
- **CRITICAL FALSE CLAIM**: The answer states "Trino's Iceberg connector does NOT maintain a metadata pointer cache" and "there is no Iceberg metadata pointer cache in the coordinator" and "there is no Trino-side cache to flush for Iceberg and no TTL to tune." This is factually wrong. Trino's Iceberg connector exposes the `iceberg.metadata-cache.enabled` configuration property (default: `true`) which controls in-memory caching of Iceberg metadata files on the coordinator. The cache TTL is governed by `fs.memory-cache.ttl` (when `fs.cache.enabled=false`) or by the file-system disk cache when `fs.cache.enabled=true`.
- **CRITICAL MISDIAGNOSIS**: The user described the exact symptom signature of a coordinator-side in-memory cache: stale results that go away after a coordinator restart, with a delay roughly matching a TTL. The answer redirects the user toward HMS latency, Spark commit timing, and MinIO erasure-coding replication as the "most likely causes" — none of these would be cured by restarting the Trino coordinator. The user explicitly said the coordinator restart fixes it; the answer ignores this clue.
- **MISSED THE QUESTION**: The user asked for (a) a command from within Trino to force refresh and (b) the config knob for cache TTL and a reasonable value. The answer effectively says "no such thing exists" for both, when both DO exist for Iceberg (`iceberg.metadata-cache.enabled`, `fs.memory-cache.ttl`, `fs.memory-cache.max-size`, and the JMX `MemoryFileSystemCache#flushCache` endpoint for ad-hoc invalidation).
- **MISSED MITIGATIONS**: Practical mitigations the answer should have surfaced: (1) lower `fs.memory-cache.ttl` to e.g. 60s if low-latency post-ingest visibility matters, (2) optionally set `iceberg.metadata-cache.enabled=false` to disable the cache entirely (with a small re-read cost per query that is usually negligible because Iceberg metadata files are typically <1MB), (3) restart impact comparison (cluster-wide via rolling restart vs. graceful TTL).
- **IRRELEVANT TANGENT**: Section 4 ("CREATE OR REPLACE VIEW Workaround" for Postgres-federated views) has nothing to do with the Iceberg stale-data question and adds noise.
- **MINOR**: The framing that the metadata.json pointer is fetched from HMS on every query is technically true at the catalog layer, but the answer fails to mention that the metadata.json file CONTENTS (and manifest lists, manifest files) ARE cached, which is precisely where the staleness window comes from when external writers like Spark advance the snapshot.
- **PERFORMANCE COST OF LOWERING TTL** (the user explicitly asked): not addressed. Should have explained that lowering TTL only forces a re-read of small metadata files (manifest list + manifests), typically tens to low hundreds of KB, so cost is small for low-QPS workloads but can add up on high-QPS dashboards where many queries hit the same table cold.

## Verification notes
WebSearch and direct fetch of https://trino.io/docs/current/connector/iceberg.html confirm:

1. **`iceberg.metadata-cache.enabled` EXISTS** and defaults to `true`. From the docs: "Set to `false` to disable in-memory caching of metadata files on the coordinator." This directly contradicts the answer's central claim.

2. **`fs.memory-cache.ttl`, `fs.memory-cache.max-size`, `fs.memory-cache.max-content-length`** are documented properties that govern the cache behavior when `iceberg.metadata-cache.enabled=true` and `fs.cache.enabled=false`.

3. **No `flush_metadata_cache()` procedure for the Iceberg connector** — the answer is correct here. Per the Trino discussions, the rationale is that Iceberg metadata files are immutable per the spec, so the cache should never serve "stale" data for a given pointer. However, the cache DOES delay visibility of NEW snapshots when external writers (Spark) advance the table — exactly the user's scenario. There is a JMX endpoint `io.trino.filesystem.memory.MemoryFileSystemCache#flushCache` for manual invalidation, but no SQL-level procedure.

4. **Coordinator-only scope description**: Where applicable to other connectors, the answer's scope description is roughly accurate, but it is moot for Iceberg since the SQL procedure does not exist.

5. **Hive Metastore cache (`hive.metastore-cache-ttl`)** is documented as DISABLED for the Iceberg connector per Trino issue #13115 — so HMS caching is not the culprit either. The culprit is the in-memory metadata file cache on the coordinator.

6. **Official guidance for stale Iceberg data after external writes**: The Trino docs and discussions indicate that lowering `fs.memory-cache.ttl` or disabling `iceberg.metadata-cache.enabled` is the standard knob. The answer should have surfaced these.

The answer's core technical assertion is wrong in a way that would actively mislead a production engineer into chasing the wrong root cause (HMS / Spark / MinIO) instead of the actual one (Trino coordinator metadata cache). This is a hard FAIL on technical accuracy and a meaningful FAIL on practical applicability/completeness, despite good prose clarity.

**Topic affected**: This question does not map cleanly to the existing rubric topics (it spans Iceberg operations, Trino cache configuration, and Spark+Trino interop). The closest existing topic is "Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup" but the question is really about Trino-side metadata caching for Iceberg, which is a resource gap worth flagging.
