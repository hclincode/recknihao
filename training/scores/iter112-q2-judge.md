# Iter 112 Q2 — Judge Report

**Question topic**: Debezium → Iceberg CDC duplicates after connector restart (pod crash / k8s deploy); `updated_at` differs by a millisecond so `DISTINCT` does not clean them.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter112-q2.md`

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3 | Correct on snapshot.mode value list, MERGE pattern, and slot monitoring. Misframes the **root cause** — duplicates on Debezium restart come overwhelmingly from at-least-once redelivery within the offset-flush window, not from re-snapshots. Also makes a misleading claim that "snapshot rows carry no LSN-based CDC metadata." |
| Clarity | 4 | Reads cleanly for an app engineer. Some jargon (`source.lsn`, `op='r'/'c'/'u'/'d'`, `replication slot`, `LSN`, `Strimzi KafkaConnector CRD`, `pgoutput`) is dropped without a one-line gloss. Otherwise good structure (root cause → fixes → cleanup → summary table). |
| Practical completeness | 4 | Concrete runnable Spark/PySpark snippet, concrete YAML, concrete `pg_replication_slots` query, concrete cleanup procedure. Engineer can copy-paste. Loses points for the cleanup recipe and for omitting the canonical idempotency tool the resource emphasizes (deduplicate **on `source.lsn`/source.ts_ms` and the PK**, plus rolling back the bad snapshot via `CALL system.rollback_to_snapshot`). |
| Coverage | 3 | Misses or under-weights several root causes the rubric and `resources/13` call out as the **primary** suspects when this symptom appears: (1) at-least-once redelivery during the offset-flush window (Debezium's documented behavior on any restart, not just re-snapshots); (2) Kafka Connect `group.id` / connector `name` change causing offset key miss; (3) `offset.flush.interval.ms` tuning; (4) the canonical "Why did Debezium re-snapshot on restart?" diagnostic checklist (5 items in the resource, answer covers ~1.5). The `connect-offsets` topic name is also wrong for Debezium 2.x defaults. |

**Average: 3.5 / 5 — borderline PASS** (3.5 is the threshold; rounding does not save it from being a weak pass).

**Verdict: PASS (marginal).** Useful and not actively harmful, but root-cause framing is off and several technical details are imprecise. Not strong enough to ship as a confident production answer if the engineer is going to act on the "it must be re-snapshots" diagnosis.

---

## What was verified correct (via WebSearch against debezium.io, postgresql.org, iceberg.apache.org)

1. **Debezium 2.x snapshot.mode value list and deprecation status.** Answer correctly says `no_data` is the current preferred value, `never` is deprecated (alias), and `always` re-snapshots on every restart. Matches the Debezium 2.x docs and the Conduktor snapshot-modes reference. (sources: debezium.io PostgreSQL connector docs, Conduktor snapshot-modes explainer.)
2. **Three-branch MERGE INTO shape** (`WHEN MATCHED AND op='d' THEN DELETE / WHEN MATCHED AND op IN ('u','c','r') THEN UPDATE / WHEN NOT MATCHED AND op IN ('c','r','u') THEN INSERT`) is the canonical Iceberg CDC pattern. Verified against `iceberg.apache.org/docs/1.5.0/spark-writes` and multiple third-party CDC-to-Iceberg writeups (Streamkap, Cazpian).
3. **Reason to keep `op='d'` in its own branch** — Debezium delete envelopes have a null `after` field; collapsing into UPDATE would null all columns. Correct.
4. **Window-function dedup before MERGE** using `Window.partitionBy(PK).orderBy(source_lsn.desc())` + `row_number()==1` is the standard pattern for handling the "Iceberg MERGE INTO multi-source-match raises error" gotcha. Verified.
5. **`pg_replication_slots` lag query** (`pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)`) and the `active=false` orphaned-slot semantics are correct.
6. **`max_slot_wal_keep_size`** as a backstop to prevent WAL filling Postgres disk. Correct, matches `postgresql.org/docs/current/runtime-config-replication.html` and Gunnar Morling's "Mastering Postgres Replication Slots" writeup.

---

## Errors and gaps found

### E1 — Misframed root cause (HIGH severity)
Answer leads with: *"the core problem is at-least-once delivery combined with connector restarts triggering re-snapshotting."* This conflates two different failure modes:
- **At-least-once redelivery** happens on **every** Debezium connector restart, regardless of `snapshot.mode`, because Kafka Connect commits source offsets on a flush interval (default 60s for the offset.flush.interval.ms). Any events between the last offset flush and the crash are re-delivered on restart. This is the documented Debezium behavior (per the Debezium FAQ: *"Because there is a chance that some events may be duplicated during a recovery from failure, consumers should always anticipate some events may be duplicated."*) and it is the **most likely cause** of the small-batch duplicates the engineer describes (3-4 copies of recent rows, with tiny `updated_at` differences explained by Postgres-level retries in the app, not by Debezium snapshots).
- **Re-snapshot on restart** is a much rarer event that only happens when the Connect offset topic is lost / the connector name or group.id changed / `snapshot.mode=always`. It would produce a **flood** of duplicates (every row in the table) — not "the same event showing up two or three times."

The symptom described (a few duplicate copies of recent rows) is the **at-least-once redelivery** pattern, not the re-snapshot pattern. The answer's primary fix recommendation (`snapshot.mode: no_data`) addresses the wrong root cause for this symptom. The MERGE INTO idempotency fix (Fix 1) does correctly absorb both — that part is fine — but the framing tells the engineer the wrong story about what is happening.

### E2 — "Snapshot rows carry no LSN-based CDC metadata" is misleading (MEDIUM)
Answer says: *"Snapshot rows carry no LSN-based CDC metadata — they arrive from a point-in-time Postgres read, slightly different from the WAL stream."* Per Debezium's Postgres connector source code and docs, snapshot (`op='r'`) events **do** include `source.lsn` — it is set to the LSN of the snapshot's consistent point (or null in some sub-modes). It is not categorically absent. More importantly, the "millisecond `updated_at` differences" the engineer sees cannot be explained by snapshot vs WAL mode — Postgres returns the same `updated_at` value either way (it is just a column read from the row). The likely explanation for the millisecond drift is **application-level retry**: the app wrote the same logical event twice with two `updated_at` values one millisecond apart, and Debezium faithfully captured both. The answer never raises this possibility.

### E3 — `connect-offsets` is not the correct topic name for Debezium 2.x (LOW-MEDIUM)
Answer says: *"the connector's Kafka offset topic (`__consumer_offsets` or the Connect internal `connect-offsets`)."* Two issues:
- `__consumer_offsets` is the Kafka **broker's** consumer-group offset topic — it has nothing to do with Kafka Connect source connector offsets. Mentioning it here is just wrong.
- The Connect source offset topic is configured via `offset.storage.topic` and defaults to `connect-offsets` only in vanilla Apache Kafka Connect. In Strimzi (which is what `resources/13` documents as the production stack) the default is `_debezium_connect_offsets` per the resource's own diagnostic checklist (line 1647). The answer's `grep debezium-connector-name` example will not find anything against the Strimzi default name.

### E4 — Missed canonical diagnostic checklist (MEDIUM)
`resources/13` lines 1641-1662 has a 5-item "Why did Debezium re-snapshot on restart?" checklist that is exactly the resource the engineer needs: (1) offset topic deleted, (2) Connect cluster `group.id` changed, (3) `offset.storage.topic` misconfigured, (4) connector `name` changed, (5) diagnose root cause before flipping `snapshot.mode`. The answer mentions only #1 (offset topic) and skips the four other items that the resource flags as common operational causes — including the `group.id` and connector-name issues that are by far the most common after a Kubernetes redeploy (the exact scenario the engineer describes).

### E5 — Cleanup recipe is incomplete and assumes Trino Postgres connector access (MEDIUM)
The cleanup recipe assumes Trino has a `postgres.public.events` catalog mapping and that the engineer can do `CREATE TABLE iceberg.analytics.events_backfill AS SELECT * FROM postgres.public.events`. That requires (a) a Postgres connector wired into Trino, (b) Trino having direct network access to the Postgres primary, (c) the table fitting through Trino's JDBC scan. None of those are mentioned. `resources/13` documents two cleaner cleanup paths the answer should have used:
- **`CALL system.rollback_to_snapshot('iceberg.analytics.events', <snapshot_id_before_bad_run>)`** — the canonical fast-path if the bad snapshot is still alive (line 3179+).
- **Per-partition `INSERT OVERWRITE` from a deduplicated source** (line 3237+).

Neither is mentioned. The answer's approach (create a backfill table from the Postgres catalog, MERGE, drop) works but is the more expensive and operationally riskier option, and it doesn't address what to do if the engineer doesn't have the Postgres catalog mounted in Trino.

### E6 — `cleanup.policy=compact` is correct but `replication.factor>=2` understates the prod-grade default (LOW)
Recommending `replication.factor >= 2` for `connect-offsets` is too low. The Strimzi production default and the Debezium docs both recommend `replication.factor=3` for the Connect internal topics in any non-toy cluster. `>= 2` would survive a single broker loss but is below the conventional production baseline.

### E7 — `DELETE branch` discussion is correct but the answer never mentions REPLICA IDENTITY FULL (LOW)
The DELETE branch only works correctly if the Debezium delete envelope contains enough identifying columns. With Postgres default `REPLICA IDENTITY DEFAULT`, the before-image only contains the PK. That works for the PK-keyed MERGE the answer shows — fine — but the answer should at least note that if the engineer wants to filter the DELETE branch on a non-PK column (e.g., `WHEN MATCHED AND s.tenant_id = '...'`), they need `ALTER TABLE ... REPLICA IDENTITY FULL`. `resources/13` covers this (line 1152) and the answer omits it.

### E8 — Bootstrap row `op='r'` semantics under-explained (LOW)
The answer says snapshot rows "must be handled in both MATCHED (idempotent overwrite) and NOT MATCHED (initial insert)." That is correct but glosses over **why**: it's because on a re-snapshot, every row the engineer already has in Iceberg arrives again as `op='r'`. Without an explicit example, a beginner reading this won't understand why `op='r'` is in **both** branches of the MERGE.

---

## Resource fix recommendations

### HIGH priority

**Fix 1 — Add a "Symptoms vs root causes" decision table for CDC duplicates** in `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`. New subsection between the "Why did Debezium re-snapshot on restart?" checklist (line 1641) and the slot-monitoring section (line 1664). Table columns: *Symptom* | *Most likely root cause* | *How to confirm* | *Fix*. Rows:
- **A few duplicate copies of recent rows, small `updated_at` drift** → at-least-once redelivery during the offset-flush window (or app-level retry) → check `offset.flush.interval.ms` and confirm pre-flush events are duplicated, OR check app logs for retries → idempotent MERGE INTO with dedup-on-`source_lsn`.
- **Every row in the table duplicated, all carrying `op='r'`** → re-snapshot on restart → check `kafka-topics --describe _debezium_connect_offsets` (recreated recently?) AND connector `name`/`group.id` against git history → fix the underlying offset-loss cause from the existing checklist; do NOT mask with `snapshot.mode=no_data`.
- **A few duplicates AND every row in a single table re-emitted** → incremental snapshot was triggered via the signal table → check `debezium_signal` table for recent `execute-snapshot` rows → expected behavior; the MERGE INTO absorbs them.

This is the single most important missing piece — the iter 112 Q2 answer misdiagnosed the symptom because the resource doesn't explicitly teach the symptom → root-cause mapping. Without this table the weak-ai-responder keeps reaching for re-snapshots as the explanation whenever an engineer says "duplicates after restart."

**Fix 2 — Add a "Where do the `updated_at` millisecond drifts come from?" callout.** Path: same file, in the new section above. Three causes to list explicitly: (1) Postgres-level application retry committing the same logical event twice with two slightly different `now()` values; (2) the app uses `now()` in a trigger that re-fires on each UPDATE; (3) the engineer is comparing Debezium's `source.ts_ms` (millisecond) to Postgres `updated_at` (microsecond) and seeing rounding. None of these are "Debezium's fault" and the resource should disabuse engineers of the idea that snapshot vs WAL is responsible for the drift.

### MEDIUM priority

**Fix 3 — Add an `at-least-once and offset.flush.interval.ms` subsection** to the same file, near the existing "Why did Debezium re-snapshot on restart?" checklist. Cover: (a) Kafka Connect commits source offsets every `offset.flush.interval.ms` (default 60000); (b) any event committed between the last flush and a crash will be re-delivered on restart; (c) lowering `offset.flush.interval.ms` reduces the duplicate window but increases overhead; (d) the only structural fix is consumer-side idempotency (MERGE INTO + per-key LSN dedup). Cross-reference the Debezium FAQ "events may be duplicated" statement so the engineer understands this is documented behavior, not a bug.

**Fix 4 — Clarify the Connect offset topic naming.** Right now `resources/13` correctly names `_debezium_connect_offsets` in one place (line 1647) but the weak-ai-responder is producing `__consumer_offsets` and plain `connect-offsets`. Add a single explicit callout near the diagnostic checklist: *"The Connect source-offset topic is `_debezium_connect_offsets` in Strimzi (this prod stack) and `connect-offsets` in vanilla Apache Kafka Connect. It is NOT `__consumer_offsets` — that is the broker's consumer-group offset topic and is unrelated to Kafka Connect source-connector offsets."*

**Fix 5 — Add a "Cleanup recipe selection" table to the duplicate-cleanup section** (already exists around line 3179). Add a decision matrix at the top:
- Bad snapshot still alive (within `history.expire.max-snapshot-age-ms`)? → `CALL system.rollback_to_snapshot` is the fastest path.
- Bad snapshot already expired AND the partition is small? → `INSERT OVERWRITE` from deduplicated source.
- Bad snapshot expired AND the partition is huge? → Spark MERGE INTO with `ROW_NUMBER` dedup and explicit ON clause.
- No clean source to backfill from in Trino? → Spark JDBC from Postgres primary into a staging Iceberg table, then MERGE.

The current section has all four paths but doesn't have a top-level "which one for which situation" choice — the weak-ai-responder picks one arbitrarily.

### LOW priority

**Fix 6 — Add a one-line REPLICA IDENTITY FULL reminder** to the MERGE-INTO three-branch documentation (around line 1543). Already documented at line 1152, but linking the two would help the responder remember to mention it when the DELETE branch comes up.

**Fix 7 — Update `replication.factor` recommendations from `>= 2` to `= 3`** wherever the resource discusses Strimzi internal topic config. Production baseline.

---

## Summary for the teacher

The answer's mechanics (three-branch MERGE, `row_number` dedup, `snapshot.mode` value list, slot lag query) are accurate and copyable. The **diagnosis** is wrong for the symptom described: the engineer is almost certainly seeing at-least-once redelivery (or app retries), not a re-snapshot. The fix the weak-ai-responder reaches for first (`snapshot.mode: no_data`) is correct in isolation but wrong as the lead recommendation for this specific symptom — and it can actively cause data loss if applied without the `confirmed_flush_lsn` gap check the resource already documents at line 1622-1624.

The root cause is a resource gap, not a model gap: `resources/13` doesn't have an explicit "symptom → root cause → fix" decision table for CDC duplicates. The weak-ai-responder defaulted to the most-detailed material in the resource (the re-snapshot procedure) and pattern-matched the engineer's "after a restart" phrasing to "re-snapshot on restart." Adding Fix 1 and Fix 2 above (HIGH priority) should correct this for the next iteration.

---

## Sources verified

- [Debezium PostgreSQL connector documentation (stable)](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Debezium FAQ — duplicate events on restart and at-least-once semantics](https://debezium.io/documentation/faq/)
- [Towards Debezium exactly-once delivery (Debezium blog 2023)](https://debezium.io/blog/2023/06/22/towards-exactly-once-delivery/)
- [Debezium snapshot modes explained — Conduktor](https://kafka-options-explorer.conduktor.io/debezium/snapshot-modes/)
- [Apache Iceberg Spark writes — MERGE INTO semantics](https://iceberg.apache.org/docs/1.5.0/spark-writes/)
- [PostgreSQL replication runtime config including `max_slot_wal_keep_size`](https://www.postgresql.org/docs/current/runtime-config-replication.html)
- [Mastering Postgres Replication Slots — Gunnar Morling](https://www.morling.dev/blog/mastering-postgres-replication-slots/)
- [CDC to Apache Iceberg three-branch MERGE pattern — Streamkap](https://streamkap.com/resources-and-guides/cdc-to-apache-iceberg)
