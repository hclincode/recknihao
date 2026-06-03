# Judge Feedback — Iter 409 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.5625 STRONG PASS** (Q1 4.625 + Q2 4.625 + Q3 4.5 + Q4 4.5)

**Headline: ITER408 Q2 PUNT IS DURABLY RESOLVED — TRINO MV GAP CLOSED.** The iter408 honest "I don't have enough information" punt on Trino materialized views was replaced this iteration with a precise, end-to-end correct answer covering the full read-time and refresh-time semantics. Every load-bearing technical claim was verified against Trino 481 official docs (`create-materialized-view.html`, `refresh-materialized-view.html`, `connector/iceberg.html`) and matches. The teacher's new resource `25-trino-materialized-views-iceberg.md` (~430 lines) is the right shape: TL;DR sentences, full syntax with worked example, REFRESH semantics, freshness/grace-period/WHEN STALE matrix, MV-vs-dbt-vs-Redis decision guide, on-prem k8s ops.

**Pattern note:** Eighth consecutive PASS, and the highest score since iter404 (4.6875). The behavioral arc iter407→iter408→iter409 is clean: confident inaccuracy → honest punt → correct answer with citations. Both failure modes (fabricate-wrong / refuse-to-answer) get fixed inside two iterations once the teacher targets the gap.

---

## Q1 — Trino MV on Iceberg (iter408 Q2 RE-PROBE)

**Scores: 5.0 / 4.5 / 5.0 / 4.0 — avg 4.625 STRONG PASS**

### What landed
- **Yes, Trino supports MV on Iceberg** — correctly stated upfront, contrast with iter408 punt.
- **Two-thing model**: view definition in HMS + hidden Iceberg storage table — correct architecture.
- **Reads hit the cached storage table, NOT re-running the SELECT** — correct (this is the whole point of an MV).
- **NO auto-refresh** — must trigger manually via cron / dbt / Airflow / k8s CronJob. Verified against `refresh-materialized-view.html` (no auto-refresh capability documented).
- **INCREMENTAL refresh claim VERIFIED CORRECT**: Trino does diff source snapshot-ids and append deltas to the storage table when all sources are Iceberg and query shape supports it. Trino Iceberg connector docs explicitly state: *"For incremental refresh, the existing data is not deleted from the storage table and only the delta records are processed from the source tables and appended into the storage table as needed."* Controlled by `iceberg.incremental-refresh-enabled` (default `true`). The responder's specific claim was a precise technical assertion and it is accurate.
- **Full refresh for non-Iceberg/federated** — correct.
- **Snapshot-id-based freshness (NOT time-based)** — correct. Source snapshot_ids recorded at refresh, compared against current on read.
- **GRACE PERIOD default = infinity** — VERIFIED against `create-materialized-view.html`: *"If not specified, the grace period defaults to infinity, and therefore all queries are within the grace period."* Responder's "default infinity = serve stale until manual refresh" is correct.
- **WHEN STALE INLINE (default) = falls through to underlying query** — VERIFIED: *"When the materialized view becomes stale, the view will be expanded like a logical view, and queries accessing the materialized view will use the underlying query definition to retrieve up-to-date data."* Responder's claim is correct.
- **WHEN STALE FAIL = errors out** — correct.
- **All-Iceberg smart shortcut past grace period** — correct. Trino can keep serving cache past grace if snapshot-id diff proves no source change.
- **Recommends explicit `GRACE PERIOD INTERVAL '90' MINUTE` + hourly refresh** — sensible production default; matches resource 25.
- **MV vs dbt vs Redis decision** — correct framing (fixed-shape Iceberg-only → MV; MERGE / lineage → dbt; sub-minute / KB-MB / high QPS → Redis).
- **CREATE MATERIALIZED VIEW example** with GRACE PERIOD + WHEN STALE INLINE + partitioning — matches Trino syntax.
- **Storage table needs `optimize` + `expire_snapshots` maintenance** — correct; the storage table is a real Iceberg table and has the same lifecycle.

### Minor gaps
- Dense style — beginner clarity at 4.0. The 7-sentence TL;DR in the resource is more accessible than the responder's compressed version; responder could have leaned on plain-English framing more.
- No explicit `iceberg.incremental-refresh-enabled` catalog property mention (the kill-switch).
- No mention of "first refresh is always full" (no prior snapshot-ids to diff against) — a small operational nuance.

### Verdict
**STRONG PASS — ITER408 Q2 PUNT DURABLY RESOLVED.** Every load-bearing technical claim verified. The teacher's new resource 25 landed and the responder lifted from it accurately. **No inaccuracy in the responder's answer; no inaccuracy in the new resource as written.** The previously-feared "incremental refresh actually does what?" precision claim holds up — it really is delta-append per snapshot-id diffing.

---

## Q2 — Column rename + field-ID schema evolution

**Scores: 5.0 / 4.5 / 4.5 / 4.5 — avg 4.625 STRONG PASS**

### What landed
- **Iceberg tracks columns by internal field ID, not name** — verified against Iceberg docs ("Iceberg assigns a unique ID to every column when it is first created. That ID is stored in both the table metadata and the Parquet file metadata").
- **RENAME COLUMN is metadata-only, no file rewrites** — verified ("renaming a column updates the metadata mapping without touching data files").
- **Historical Parquet readable under the new name** — verified (field ID 7 maps to new column name regardless of rename).
- **Time-travel projects historical files through current schema via field IDs** — correct semantic (FOR VERSION AS OF on a pre-rename snapshot still shows the new column name because the projection happens through current schema mapping, not the snapshot's recorded name).
- **The breakage is downstream, not the table** — correctly diagnoses why the engineer's pipeline broke: hardcoded SQL / dbt models / dashboards referencing the old name need manual updates; the table itself is fine.
- **Transition pattern: ADD new col + MERGE backfill + DROP old col** — sound alternative for cases where downstream can't be coordinated atomically.

### Minor gaps
- Doesn't mention that field IDs are assigned at first-CREATE and preserved through evolution (a key clarifier for someone who's never thought about why rename can be metadata-only).
- No call-out of the column-mapping / name-mapping file (`schema.name-mapping.default`) that legacy Parquet files written without embedded field IDs require — edge case but a real foot-gun for tables ingested via add_files.

### Verdict
STRONG PASS. Schema evolution mental model is correct.

---

## Q3 — Small files diagnosis + compaction thresholds

**Scores: 4.5 / 4.0 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **`$files` metadata table query** with `content=0` (data) vs `content=1` (delete) — correct.
- **Healthy 128-256MB band**: reasonable practical heuristic. Iceberg's `write.target-file-size-bytes` default is technically 512MB-1GB depending on version, but the 128-256MB band is the widely-recommended practical target for Trino-friendly read performance and matches Dremio/Tabular/Trino-summit guidance.
- **<10MB compact, 10-100MB gray zone** — reasonable.
- **Per-file fixed overhead 10-50ms** — sound order-of-magnitude for MinIO + small Parquet footer read.
- **`$partitions` per-partition file_count thresholds** (>100 files/partition compact, 5-10 fine) — sensible heuristic.
- **`EXECUTE optimize` nightly after ingestion** with 256MB target — correct.
- **`$manifests` count >30 OR >100MB → optimize_manifests** — `optimize_manifests` correctly flagged as Spark-only (Trino #25281).

### Minor gaps
- Doesn't show the literal Trino syntax for `optimize` with `file_size_threshold` (`ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')`).
- Doesn't mention `write.distribution-mode=hash` to prevent small-file proliferation at write time (treating only the symptom not the cause).
- "Per-file fixed overhead 10-50ms" lacks a citation; while order-of-magnitude correct, the actual number varies with MinIO config and erasure-coding.

### Verdict
STRONG PASS. Thresholds are practical and the diagnostic workflow ($files → $partitions → $manifests → optimize) is exactly the right sequence.

---

## Q4 — Time travel + rollback_to_snapshot

**Scores: 4.5 / 4.5 / 4.5 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **`FOR TIMESTAMP AS OF` / `FOR VERSION AS OF snapshot_id`** — correct Trino time-travel syntax.
- **`$snapshots` to find pre-batch snapshot** — correct diagnostic table.
- **`rollback_to_snapshot` instant metadata-only restore** — correct (just updates the current snapshot pointer in metadata; no data files touched).
- **Bad snapshot lingers until expire_snapshots (~7d) — forensics window** — accurate and a useful operational framing.
- **Surgical DELETE + EXECUTE optimize WHERE partition** when too late to rollback — sound alternative.
- **Delete files = markers until compaction** — correct MoR semantics.

### Minor gaps — SYNTAX NIT
- The responder wrote `rollback_to_snapshot('analytics','events',snap_id)` (three positional args, separating schema and table). The canonical Iceberg Spark Procedure syntax is `CALL catalog.system.rollback_to_snapshot('analytics.events', snap_id)` (two args, single qualified table name as `schema.table`), or by-name `CALL catalog.system.rollback_to_snapshot(table => 'analytics.events', snapshot_id => <id>)`. The responder's three-arg form would error in Spark. **Small but real syntax inaccuracy that an engineer copy-pasting would hit.**
- Doesn't mention `rollback_to_timestamp` as a sibling procedure for the case where the engineer knows the timestamp but not the snapshot_id.
- Doesn't explicitly state rollback is Spark-only (Trino doesn't expose this procedure — verified).

### Verdict
STRONG PASS with a copy-paste-trap nit. Mental model and operational sequence are correct; the syntax line will fail if pasted into Spark. Teacher should fix the syntax in the rollback resource.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.625 | STRONG PASS — Trino MV on Iceberg iter408 PUNT DURABLY RESOLVED |
| Q2 | 4.625 | STRONG PASS — Column rename field-ID schema evolution |
| Q3 | 4.5 | STRONG PASS — Small files + compaction thresholds |
| Q4 | 4.5 | STRONG PASS — Time travel + rollback_to_snapshot (minor syntax nit) |

**Average 4.5625 STRONG PASS** — highest score since iter404 (4.6875). All four answers above the per-iteration STRONG PASS floor (4.5 avg). No critical inaccuracies. The teacher's MEDIUM iter409 action (Trino MV gap fill) landed cleanly and the responder lifted from it precisely.

**Trajectory iter394-409:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/**4.5625P**`. Eighth consecutive PASS, jumping from 4.125 to 4.5625 (+0.4375). The oscillation pattern (iter401/iter403/iter405/iter407 mid-3 FAILs) remains broken — 8-iteration PASS streak is the longest of the extended phase.

**ITER408 Q2 PUNT RESOLUTION: CONFIRMED.** The "I don't have enough information" output is replaced with a full, doc-verified MV answer. The teacher's new resource 25 is accurate as written — the precise incremental-refresh and GRACE PERIOD claims hold up against Trino 481 official docs. **No inaccuracy flagged in the new MV resource.**

---

## Teacher actions next (iter 410)

1. **LOW polish — Q4 `rollback_to_snapshot` Spark syntax fix.** Wherever the resource shows the procedure call, ensure the canonical form `CALL catalog.system.rollback_to_snapshot('schema.table', snapshot_id)` (two args, qualified table name as one string) — NOT the three-arg `('schema','table',id)` form which doesn't exist. Add by-name form `(table => 'analytics.events', snapshot_id => <id>)` as recommended. Cite Iceberg Spark Procedures docs. Same fix for `rollback_to_timestamp`.

2. **LOW polish — Q1 MV resource: add "first refresh is always full"** callout (no prior snapshot-ids to diff against) + mention the `iceberg.incremental-refresh-enabled` kill-switch property. Both are small precision adds, not corrections.

3. **LOW polish — Q3 small-files resource: add the literal Trino `optimize(file_size_threshold => '128MB')` syntax** + a callout that `write.distribution-mode=hash` at write time prevents the small-file problem at the root (rather than only treating it via nightly optimize).

4. **LOW polish — Q2 schema-evolution resource: add `schema.name-mapping.default` callout** for legacy Parquet ingested without embedded field IDs (the add_files / external-write footgun).

5. **LOW carry-forward backlog:** dbt-trino merge dups, predicate-pushdown JDBC rewrite, write.isolation-level, SHOW SESSION catalog-prefix, HMS->Nessie no-downtime, SPILL_FAILED 60GB cap, MERGE rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO/VALIDATE, JWT+OPA concurrency, Iceberg tagging 3rd, fs.cache 3rd JMX, PERCENT_RANK/NTILE 3rd, RANGE INTERVAL gap-day, equality delete 1.5.2 bug context, Iceberg v3 deletion vectors timeline.

---

## Judge probe targets next (iter 410)

1. **Trino MV durability 2nd-angle** — probe a different facet: "my MV says it refreshed 5 minutes ago but the dashboard still shows yesterday's numbers — why?" This probes (a) snapshot-id-based freshness vs time-based mental model, (b) GRACE PERIOD interaction, (c) the all-Iceberg-shortcut behavior. Confirms the MV understanding sticks across a different question phrasing.

2. **`rollback_to_snapshot` Spark syntax verification** — natural follow-on from Q4. Probe "exact CALL syntax to roll back to a specific snapshot" — confirms the responder uses the correct two-arg `'schema.table'` form after iter410 teacher fix.

3. **Field-ID column mapping 2nd-angle** — "what happens to existing Parquet files that don't have Iceberg field IDs in their footer (e.g., from add_files)?" Probes the `schema.name-mapping.default` foot-gun.

4. **HMS-to-Nessie no-downtime migration** — long-standing carry-forward, now even more relevant with Trino MV + branch patterns both confirmed working (Nessie is canonical for both branch-heavy + MV-heavy workflows).

5. **Iceberg v3 deletion vectors timeline** — "when does this stack get deletion vectors and what changes for MoR compaction?" — probes upstream-fix horizon.

6. **`write.distribution-mode=hash` for hot-partition write distribution** — natural follow-on from Q3 (preventing small files at write time rather than only treating with optimize).

7. Carry-forward backlog rotation as needed.
