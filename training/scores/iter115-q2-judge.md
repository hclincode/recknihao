# Iter 115 Q2 — Judge Report

**Question topic**: Iceberg partition design for SaaS at 140 tenants — manifest-list / planning-time bloat from identity-`tenant_id` × `day` partitioning; whether partition evolution can fix it without rewriting all data; Trino 467 + Iceberg 1.5.2 on-prem.

**Primary topics touched**:
- Iceberg partition design for SaaS: strategies, small-files, compaction (PRIMARY)
- Iceberg table maintenance: compaction (CTAS rewrite path, follow-on `rewrite_data_files` decision)
- Multi-tenant analytics (per-tenant metadata access tradeoff via `$partitions`)

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Most of the answer is correct: partition evolution is genuinely metadata-only; `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` is the documented Trino 467 syntax; mixed-spec query handling, bucket-pruning semantics, the `tenant_id_bucket` column name, and the manifest-list-traversal cost framing are all accurate. **The one material technical error**: the answer flatly states `rewrite_data_files does NOT re-layout under a new spec. Use CTAS to actually re-layout historical data.` This is wrong — per Apache Iceberg docs and GitHub discussion, `rewrite_data_files` uses the **current** table partition spec when rewriting, which after a `SET PROPERTIES` change IS the new spec. The simpler, lower-risk Phase 2 is `ALTER TABLE iceberg.analytics.events EXECUTE optimize` (Trino) or `CALL system.rewrite_data_files('analytics.events')` (Spark) — no CTAS, no DROP/RENAME, no doubled MinIO storage, no view-swap. This isn't a tiny nit: the recommended CTAS path doubles storage during the rewrite and demands view-redirect coordination across every consumer, which is exactly the kind of operational complexity the user said they wanted to avoid. |
| Beginner clarity | 4.5 | Strong. Opens with the diagnostic verdict ("known problem, partition evolution is metadata-only"), gives the actual planning-time mechanism in plain language ("planner must traverse all 12,600 partition entries"), uses a tradeoff table for the bucket vs identity decision, defines the `tenant_id_bucket` rename hazard concretely, and closes with a clear recommendation. One small clarity ding: terms like "manifest list" and "partition spec version" appear without one-line glosses for a reader who hasn't seen the resource. |
| Practical applicability | 3.5 | Phase 1 (metadata-only `ALTER TABLE SET PROPERTIES`) is immediately actionable and correct. The verification, hybrid-migration, and storage-reporting tradeoff sections are all production-grade. The Phase 2 CTAS recipe is **runnable but unnecessarily heavy** and carries real production risks the answer doesn't flag: (a) doubles MinIO storage during the rewrite (a real concern on on-prem bare-metal MinIO); (b) breaks any external view, dbt model, or query that references `iceberg.analytics.events` by name until the rename completes; (c) loses snapshot history (the new table starts at snapshot 0 — no time-travel back to pre-migration state); (d) the `CREATE OR REPLACE VIEW tenant_acme.events` example assumes the view exists per tenant and that the engineer will iterate across all 140 — not stated. An engineer following the answer literally would do significantly more work and assume more risk than the topic actually requires. |
| Completeness | 4 | Covers the question's three explicit asks (is this known? can partition spec evolve? how to do it without rewriting). Adds correct material on hybrid tenant migration, per-tenant metadata-reporting tradeoff, and post-migration verification. Missing: (1) `rewrite_manifests` as a lower-cost intervention that can reduce planning latency without a partition-spec change at all — worth mentioning before recommending a full spec switch; (2) the `spec_id` filter pattern for incrementally re-compacting historical data under the new spec (`SELECT spec_id, COUNT(*) FROM events$files GROUP BY spec_id`, then run `optimize` per spec); (3) no caveat that during the mixed-spec window, queries against the table can produce slightly larger query plans because the planner must reason about both specs; (4) `expire_snapshots` not mentioned post-rewrite to actually free the old per-tenant Parquet files from MinIO. |
| **Average** | **3.875** | **PASS** (above the 3.5 threshold, but with one material technical correction needed) |

---

## Verdict

**PASS** with a flagged correction on the rewrite path. The answer correctly identifies the root cause (manifest-list traversal cost at ~12,600 partitions), correctly applies the recommended remedy from `resources/05` (switch to `bucket(tenant_id, 32)`), and correctly explains the metadata-only nature of partition evolution. The one material technical error — claiming `rewrite_data_files` cannot rewrite under the new spec — sends the engineer down a heavier-than-necessary CTAS path that doubles storage and adds view-redirect coordination overhead. This is the kind of mistake that survives copy-paste into production and creates a long-running incident; it pulls the answer below a 4-star evaluation but does not push it below the pass threshold because Phase 1 (the immediate fix) and the conceptual framing are sound.

---

## What was verified correct (via WebSearch against trino.io + iceberg.apache.org)

1. **`ALTER TABLE table_name SET PROPERTIES partitioning = ARRAY['col1', 'col2']`** is the documented Trino syntax to change Iceberg partition spec; verified against trino.io/docs/current/connector/iceberg.html. Existing data files are preserved.

2. **Partition evolution is a metadata-only operation; existing files retain their original partition spec; new files are written under the new spec; queries reconcile both transparently.** Verified against iceberg.apache.org/docs/latest/evolution/ and the Trino Iceberg connector docs ("partitioning can also be changed and the connector can still query data created before the partitioning change").

3. **`bucket(tenant_id, 32)` partition transform with equality predicate `WHERE tenant_id = 'acme'` prunes to a single bucket** — verified against Iceberg spec (Murmur3 hash, mod N). The engine evaluates the bucket transform on the literal once and prunes manifests by partition stats. (Note: the failure mode the engineer should be warned about is using `system.bucket()` directly in the WHERE clause, which can defeat pruning — but the answer's `WHERE tenant_id = 'acme'` form is correct.)

4. **Manifest-list traversal cost dominates planning at ~10,000+ partitions** — verified against iceberg.apache.org/docs/latest/performance/ and IOMETE's 2026 anti-patterns article; the "200–500ms planning overhead at 12,600 partitions" estimate is in the right order of magnitude.

5. **After bucket-partitioning, `$partitions.partition.tenant_id_bucket` is an INT 0..N-1 and the original `tenant_id` string is NOT recoverable from metadata-only queries** — verified against the resource and matches Iceberg transform-column naming convention. The `DESCRIBE iceberg.analytics."events$partitions"` recommendation is correct Trino syntax.

6. **`CREATE OR REPLACE VIEW` is atomic in Trino's Iceberg connector** — verified against trino.io/docs/current/sql/create-view.html. The view-swap cutover Step 3 is operationally sound IF every consumer goes through the view (a big "if" — see gaps).

---

## Errors or gaps found

### MATERIAL (technical accuracy)

1. **`rewrite_data_files` DOES rewrite old files under the new partition spec by default.** The answer's claim "Partition evolution is metadata-only; rewrite_data_files does NOT re-layout under a new spec. Use CTAS to actually re-layout historical data" is wrong. Per Apache Iceberg GitHub issue #7557 and the Spark procedures docs: `rewrite_data_files` always uses the **current** table partition spec when rewriting. After `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(event_ts)', 'bucket(tenant_id, 32)']`, the new spec IS the current spec, so running `CALL system.rewrite_data_files('analytics.events')` (Spark) or `ALTER TABLE iceberg.analytics.events EXECUTE optimize` (Trino) re-layouts historical files under the new bucket spec — without CTAS, without DROP/RENAME, without view swaps, without doubled storage. This is the standard documented migration path for partition evolution. CTAS is a valid fallback if `rewrite_data_files` runs into issues (e.g., very large partitions, memory constraints), but it should not be presented as the only option.

2. **Risks of the CTAS path are not flagged.** Even if CTAS were necessary, the answer doesn't warn the engineer that: (a) it doubles MinIO storage for the duration of Phase 2 (potentially terabytes on a 140-tenant production table); (b) it loses snapshot history (the new table starts fresh — no time-travel back to pre-migration state for incident recovery); (c) any external dbt model, BI tool, or scheduled job that references `iceberg.analytics.events` by base-table name (not through a view) will break after the DROP/RENAME until those consumers are repointed; (d) the example only shows redirecting `tenant_acme.events` — there are 139 other tenant views to update.

### MEDIUM (completeness)

3. **`rewrite_manifests` not mentioned as a cheaper intervention.** At 12,600 partitions across many ingestion-time-created small manifests, simply rewriting manifests (which consolidates manifest entries and reduces planning-time traversal cost) may recover most of the lost latency without any partition-spec change. The standard guidance is "if you have more than 1,000 manifests, run rewrite_manifests" — at 12,600 partitions there are almost certainly >1,000 manifests. The engineer should try this first as a no-risk diagnostic.

4. **Mixed-spec query planning overhead during the migration window not flagged.** While the answer correctly says Trino "handles the mixed layout transparently," it doesn't mention that during the period when both old (identity) and new (bucket) spec files coexist, query planning must reason about both specs, which can produce slightly larger plans and somewhat higher planning latency than either pure-spec state. Phase 2 should be completed in a reasonable window to avoid leaving the table permanently in a mixed-spec state.

5. **`expire_snapshots` not mentioned to reclaim MinIO storage after the rewrite.** Whether via CTAS or `rewrite_data_files`, the old per-tenant Parquet files remain pinned by older snapshots until `expire_snapshots` runs. For the on-prem MinIO context (no managed-storage cleanup), the engineer needs to explicitly schedule `expire_snapshots` to actually free the bytes.

6. **`spec_id`-filtered incremental compaction not mentioned.** For very large tables, rewriting all historical data in one shot may exceed Spark cluster memory. The idiomatic pattern is `SELECT spec_id, COUNT(*) FROM iceberg.analytics."events$files" GROUP BY spec_id`, then run `rewrite_data_files` per spec_id range to chunk the rewrite. Worth mentioning for a 140-tenant production table that may hold significant historical volume.

### MINOR (clarity)

7. **`SECURITY DEFINER` semantics on the view-swap step.** The `CREATE OR REPLACE VIEW tenant_acme.events` example assumes per-tenant views exist and are SECURITY DEFINER (owner reads `events_v2`, tenant has SELECT only on the view). The answer doesn't restate this, which is fine for a partition question but worth a one-line note since the cutover hinges on it.

8. **The Step 4 `DROP TABLE` instruction is dangerous if any consumer is still on `iceberg.analytics.events`.** The view-swap Step 3 only updates the tenant views; it does not catch direct consumers (dbt, BI tools, scheduled queries). A safer cutover is RENAME first (`RENAME ... TO events_old`), verify no errors in audit logs for 24-48 hours, then DROP. The current sequence is irreversible after Step 4.

---

## Resource fix recommendations

### HIGH priority

1. **Add a "Migrating historical data after partition evolution: `rewrite_data_files` vs CTAS" subsection to `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` (in the partition strategy section, near the bucket-tenant case study around lines 760-810).**

   Required content:
   - Lead with: "After `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]`, the simplest way to re-layout historical files under the new spec is `ALTER TABLE iceberg.analytics.events EXECUTE optimize` (Trino) or `CALL system.rewrite_data_files('analytics.events')` (Spark) — `rewrite_data_files` uses the current (new) partition spec by default."
   - Then: "Use CTAS only when `rewrite_data_files` is not feasible — e.g., when you also need to drop columns, change the table format version, or when the rewrite must be staged behind a dual-write window."
   - Add explicit cost warnings for the CTAS path: doubles MinIO storage during the rewrite; loses snapshot history; requires repointing every consumer (not just per-tenant views); not reversible after `DROP TABLE`.
   - Cite Iceberg GitHub issue #7557 for the current-spec-only behavior of `rewrite_data_files`.

### MEDIUM priority

2. **Add `rewrite_manifests` as the first-line diagnostic to the same partition section.**

   At >1,000 manifests, `rewrite_manifests` can recover much of the lost planning latency without any partition-spec change. The current resource jumps straight from "identify the problem" to "change the partition spec" — a no-risk diagnostic step belongs between them.

3. **Add a `spec_id`-filtered incremental rewrite recipe.**

   Three-line SQL: `SELECT spec_id, COUNT(*) FROM iceberg.analytics."events$files" GROUP BY spec_id` to see how many files are still on the old spec, then `CALL system.rewrite_data_files(table => 'analytics.events', where => 'spec_id = <old_spec_id>')` to rewrite incrementally. Important for tables where one-shot rewrite would exceed Spark cluster memory.

4. **Add `expire_snapshots` as the explicit "actually free the MinIO bytes" step.**

   Currently the resource talks about partition evolution being metadata-only but doesn't connect the dots that historical bytes remain on MinIO until `expire_snapshots` runs. Add a one-paragraph "freeing the old bytes" note pointing to the existing `expire_snapshots` coverage in `resources/17-iceberg-table-maintenance.md`.

### LOW priority

5. **Inline glosses for "manifest list" and "partition spec version" in `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` partition section.**

   The two terms appear repeatedly in any partition-evolution discussion; a one-line plain-English gloss at first use would improve the answer's beginner clarity by ~0.5.

6. **Add a CTAS-cutover safety note.**

   If the resource keeps any CTAS migration example, add: "RENAME the old table to `_old` instead of DROP, leave it for 24-48 hours, then DROP after verifying no audit-log errors. DROP is irreversible."

---

## Production-stack fit (per `/Users/hclin/github/recknihao/prod_info.md`)

The answer is correctly scoped to Trino 467 + Iceberg 1.5.2 + on-prem MinIO + Hive Metastore + Spark. No cloud-only constructs invoked. JWT/OPA is not directly relevant to this partition question and is correctly omitted. The CTAS path's MinIO storage doubling is a real concern on bare-metal MinIO (no elastic cloud capacity to absorb the spike), which makes the missing storage warning more important than it would be on a cloud-managed object store.

---

## Sources

- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) — verified `ALTER TABLE ... SET PROPERTIES partitioning` syntax and partition-evolution mixed-spec query handling
- [Apache Iceberg Evolution docs](https://iceberg.apache.org/docs/latest/evolution/) — verified metadata-only partition evolution semantics
- [Apache Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/) — `rewrite_data_files` semantics
- [Apache Iceberg GitHub Issue #7557 — Support Rewrite Datafiles into a custom Partition Spec](https://github.com/apache/iceberg/issues/7557) — confirms `rewrite_data_files` uses the current table partition spec (not a custom one), which means after partition evolution it rewrites old files under the new spec
- [Apache Iceberg Performance docs](https://iceberg.apache.org/docs/latest/performance/) — manifest-list traversal cost and `rewrite_manifests` guidance
- [Apache Iceberg Table Optimization #8: Hidden Pitfalls — Compaction and Partition Evolution](https://dev.to/alexmercedcoder/apache-iceberg-table-optimization-8-hidden-pitfalls-compaction-and-partition-evolution-in-13f1) — `spec_id` filtering pattern for incremental rewrite
- [Trino GitHub Issue #12323 — Iceberg `$partitions` metadata table only uses the current Spec](https://github.com/trinodb/trino/issues/12323) — context on `$partitions` behavior after partition evolution
