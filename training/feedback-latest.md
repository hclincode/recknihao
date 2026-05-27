# Judge Feedback — Iter 330

Date: 2026-05-27
Phase: extended
Topics: Iceberg table maintenance / $snapshots diagnostics (Q1) + Multi-tenant analytics / HMS startup-latency tuning (Q2)

---

## Q1 — Iceberg $snapshots diagnostics

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.75 | Two Spark/Trino engine confusion errors: (1) `SET TBLPROPERTIES` is Spark SQL syntax, fails on Trino. (2) Trino's `SET PROPERTIES` does not accept `history.expire.*` properties — must use Spark. Core snapshot concepts, $snapshots query, maintenance order, and 7-day floor all verified correct. |
| Beginner clarity | 4.75 | "Photograph" analogy and Day 1/2/3 immutability walkthrough are excellent. Column glossary plain-language. `"events$snapshots"` quoting note included. |
| Practical applicability | 4.25 | Correct decision criteria, runnable diagnostic SQL, ordered runbook — but table-property SQL block fails on production Trino 467 as written. |
| Completeness | 4.25 | Covers: snapshot definition, $snapshots columns, keep-vs-expire criteria, expire_snapshots order, maintenance runbook. Omits parent_id/manifest_list columns; no $refs/tags as pin mechanism; no retain_last Trino 479+ caveat. |
| **Average** | **4.25** | **PASS** |

### What Worked
- Snapshot "photograph" analogy and the Day 1/2/3 concrete example make immutability click for beginners.
- `$snapshots` query is copy-pasteable and correct for Trino 467 including the `"events$snapshots"` double-quote requirement.
- Columns `snapshot_id`, `committed_at`, `operation`, `summary` all accurate.
- Keep-vs-expire decision rules are correct: time-travel queries in flight, audit-pinned snapshots, safety floor.
- Maintenance order (compaction → expire_snapshots → remove_orphan_files → rewrite_manifests) is correct.
- 7-day Trino 467 minimum-retention floor explicitly called out — the iter323 failure mode held this time.

### What Missed
1. **`SET TBLPROPERTIES` is Spark syntax** — the example block says "-- Trino 467" but uses Spark SQL syntax. Fails with a parse error on Trino.
2. **Trino's `SET PROPERTIES` doesn't accept `history.expire.*` properties** — even with the right keyword, these Iceberg-native table properties must be set from Spark. Double error in one block.
3. `$snapshots` column list omits `parent_id` and `manifest_list` (both real columns per Trino docs).
4. No mention of `$refs`/tags as the way to discover pinned snapshots before an aggressive expire run.
5. No mention that `retain_last` argument requires Trino 479+ (this stack is 467 — must use Spark for that parameter).

### Technical Accuracy (verified)
1. $snapshots columns (snapshot_id, committed_at, operation, summary) — CORRECT (also has parent_id, manifest_list — omitted, not wrong)
2. Maintenance order compaction → expire → orphan → manifests — CORRECT
3. 7-day Trino 467 minimum-retention floor — CORRECT
4. `history.expire.min-snapshots-to-keep` / `history.expire.max-snapshot-age-ms` are real Iceberg properties — CORRECT, but must be set from Spark
5. `FOR VERSION AS OF` time-travel syntax — CORRECT

### Resource Fix Applied
Fixed resources/17-iceberg-table-maintenance.md: added ENGINE CALLOUT block after the `SET TBLPROPERTIES` example clarifying it is Spark SQL only, that Trino's `SET PROPERTIES` does not accept `history.expire.*` properties, and how to verify via `"events$properties"` after setting from Spark.

### Rubric Update
- Iceberg table maintenance: prior avg 4.574 across 25 questions → (4.574 × 25 + 4.25) / 26 = 118.60 / 26 = **4.561 across 26 questions**. Status: **PASSED** (mild downward drift; resource fix applied).

---

## Q2 — HMS startup-latency tuning for multi-tenant Trino

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All five load-bearing claims verified correct: per-query HMS contact (no Iceberg connector caching), port 9083, system.runtime.queries column names, HMS stateless architecture, 3-pod k8s HA pattern. No fabricated config properties. |
| Beginner clarity | 4.5 | "Directory listing" mental model and 4-step query sequence are strong. SPOF acronym not expanded — minor gap for true beginners. |
| Practical applicability | 4.5 | Priority-ordered fix list, kubectl commands, pg_stat_activity, and system.runtime.queries triage SQL all actionable. Fits on-prem k8s + MinIO + HMS stack. |
| Completeness | 4.5 | Covers: what HMS is, why it's on the critical path, how to diagnose (kubectl + Trino system tables), Postgres backend tuning, HA pattern, REST catalog escape. Missing: `hive.metastore.uri` comma-separated failover form, concrete JVM heap number, Iceberg-vs-Hive caching contrast. |
| **Average** | **4.5** | **PASS** |

### What Worked
- "HMS is the directory; MinIO is the building" mental model maps cleanly to the rest.
- Per-query HMS contact / no caching framing is technically correct (verified against trinodb/trino#13115).
- Postgres-as-real-bottleneck callout is correct and highest-leverage.
- HA recipe (3 stateless HMS pods + HA Postgres) matches resource 21 and verified patterns.
- No fabricated config properties — clean run on a topic with prior fabrication history.
- Diagnosis SQL (system.runtime.queries phase timings) gives engineer an immediate triage path.

### What Missed
- "SPOF" not expanded on first use — beginner may not know "single point of failure."
- `hive.metastore.uri` comma-separated form not mentioned (Trino-side failover config knob).
- No concrete JVM heap number suggested (just "often too small").
- Iceberg-vs-Hive caching nuance implicit: Iceberg connector deliberately has no caching (to preserve snapshot correctness); Hive connector has `hive.metastore-cache-ttl`. Without this contrast, readers may try to apply Hive cache settings to an Iceberg catalog.
- No mention of HMS table-count scaling: with 80 tenants × many tables, HMS's backing Postgres `TBLS`/`SDS` tables can grow large enough to slow lookups without proper indexes.

### Technical Accuracy (verified)
1. Per-query HMS contact, no Iceberg connector caching — CONFIRMED (trinodb/trino#13115)
2. Port 9083 default Thrift port — CONFIRMED (Apache Hive docs, Starburst k8s docs)
3. system.runtime.queries columns (queued_time_ms, analysis_time_ms, planning_time_ms, execution_time_ms) — CONFIRMED
4. HMS is stateless; multiple instances = HA — CONFIRMED (Apache Hive admin guide)
5. 3-pod HA pattern for on-prem k8s — CONFIRMED (Starburst HMS-on-k8s docs)

### Rubric Update
- Multi-tenant analytics: prior avg 4.478 across 125 questions → (4.478 × 125 + 4.5) / 126 = 564.25 / 126 = **4.478 across 126 questions**. Status: **PASSED** (stable).

---

## Iter 330 Summary

**Iter 330 average: (4.25 + 4.50) / 2 = 4.375 — PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 4.25: $snapshots diagnostics — the recurring Spark/Trino engine confusion struck again (`SET TBLPROPERTIES` labeled as Trino). Resources/17 now has an ENGINE CALLOUT. The pattern: write-mode properties (iter317) → partition evolution (iter323) → now `history.expire.*` properties. All three are the same class of error.
- Q2 4.50: HMS startup tuning — solid and correct, no fabricated config properties. The no-caching-for-Iceberg-connector point was correctly identified and is the key technical fact.

### Resource fixes applied this iteration
- **resources/17-iceberg-table-maintenance.md**: Added ENGINE CALLOUT clarifying that `SET TBLPROPERTIES` for `history.expire.*` properties must be run from Spark SQL, NOT Trino 467. Trino's `SET PROPERTIES` does not accept these Iceberg-native table properties.

### Suggested focus for Iter 331
- **Iceberg table maintenance** (4.561/26, drifting): probe the fix — ask directly about setting `history.expire.min-snapshots-to-keep` and verify the responder now correctly routes to Spark. Or probe the `$refs` metadata table for discovering pinned snapshots before an expire run.
- **Multi-tenant analytics** (4.478/126): probe HMS-specific Iceberg connector caching — why the Iceberg connector has no metastore cache while the Hive connector does, and what this means for multi-tenant query planning latency.
- **Postgres-to-Iceberg ingestion** (4.496/117): probe `offset.flush.interval.ms` at-least-once delivery gap and how to absorb it, or probe the snapshot-rows null LSN case in CDC dedup (identified as a gap in iter329).
