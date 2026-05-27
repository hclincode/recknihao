# Iter102 Q1 — Judge Score

**Topic**: Postgres-to-Iceberg ingestion (CDC recovery after Debezium outage)
**Question**: Debezium connector crashed for ~2 hours, restarted, verify gap and backfill without full resync.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Replication slot mechanics correct, `pg_replication_slots` columns and `wal_status` values verified correct, `rewrite_data_files` with `where` clause verified correct, MERGE INTO logic sound — **BUT** the `snapshot.mode: recovery` recommendation is wrong: that mode is NOT supported by the PostgreSQL connector (only MySQL/MariaDB/SQL Server). Also minor: `_debezium_connect_offsets` is not the literal default name; Kafka Connect uses whatever is set in `offset.storage.topic` (commonly `connect-offsets`). |
| Beginner clarity | 4.5 | Explains LSN, WAL, replication slots, and the two-tracking-mechanisms model very well. Gradual build-up. Some terms (LSN, `confirmed_flush_lsn`) appear with minimal definition but context makes them clear. |
| Practical applicability | 4 | Runnable SQL and PySpark snippets, correctly targets on-prem k8s setup with `kubectl exec`, uses MinIO/Iceberg conventions, includes prevention follow-up. The bad `recovery` mode recommendation would fail at runtime — engineer would get a config validation error and have to backtrack. |
| Completeness | 4.5 | Covers verification, detection, idempotent backfill, slot-lost recovery path, post-backfill compaction, and prevention. Misses: explicit mention of checking `wal_keep_size` / `max_slot_wal_keep_size` as the upstream cause of slot loss; doesn't mention checking Kafka Connect REST API (`/connectors/{name}/status`) which is the easiest first-look for whether the connector resumed cleanly. |
| **Average** | **4.125** | |

---

## Verdict

**PASS** (4.125 ≥ 3.5) — but with one significant technical bug the teacher must fix.

---

## Verified-correct claims

- Debezium tracks position both in the Kafka Connect offset topic and via the Postgres replication slot's `confirmed_flush_lsn` / `restart_lsn`.
- `pg_replication_slots` exposes `slot_name`, `active`, `confirmed_flush_lsn`, `restart_lsn`, `wal_status` (verified against postgresql.org).
- `wal_status` values `reserved`, `extended`, `unreserved`, `lost` are correct and their meanings as stated are accurate.
- Postgres retains WAL for an inactive slot until the slot is dropped or WAL retention limits (`max_slot_wal_keep_size`) are exceeded — correctly described.
- Iceberg `rewrite_data_files` with `where =>` parameter is valid syntax (verified — supported since Iceberg 1.x and present in current docs).
- MERGE INTO with `event_id` as join key correctly produces idempotent backfill when overlap exists between CDC stream and replay window.
- Reading from the Postgres PRIMARY (not replica) for ground truth is the right call.
- Recommendation to add a `source_lsn` column for exact future gap detection is excellent and goes beyond the minimum ask.

---

## Bugs / Errors

### HIGH — Wrong snapshot mode for PostgreSQL connector

In "Special case: replication slot invalidated", the answer says:

> 3. Set `snapshot.mode: recovery` on the connector (one-time) — this tells Debezium to re-read the slot position from the new slot's starting point and resume CDC without full snapshot. Change back to `no_data` after recovery completes.

**Verification (debezium.io / Conduktor snapshot-modes guide)**: `snapshot.mode: recovery` is NOT supported by the Debezium **PostgreSQL** connector. Recovery mode exists only for MySQL, MariaDB, and SQL Server (connectors that maintain a schema history topic). The PostgreSQL connector has no schema history topic and therefore no `recovery` mode.

What the answer should say for the PostgreSQL slot-lost scenario:
- After recreating the slot, the new slot starts at the current WAL position (no history to replay).
- The right snapshot mode choice depends on what you want:
  - `snapshot.mode: never` — skip snapshot entirely, start streaming from the new slot's WAL position. Use this if you'll handle the gap manually via the targeted backfill below.
  - `snapshot.mode: initial` — re-snapshot the table (probably what you want to avoid given the table is huge).
  - `snapshot.mode: no_data` — capture schema only, no row data, then stream. Good companion to a manual backfill.
- Then the manual time-scoped backfill from PRIMARY fills the gap between the last Iceberg row and the new slot's start point.

This is a configuration value the engineer would type into a Kafka Connect config and it would fail validation — material enough to dock technical accuracy.

### LOW — Offset topic name not literal

The answer references `_debezium_connect_offsets` as if it were the standard name. Kafka Connect's offset topic name is set by `offset.storage.topic` in the worker config and defaults to whatever the operator chose (commonly `connect-offsets` or `<cluster>-connect-offsets`). Not a runtime breaker since the engineer would substitute their actual topic name, but worth being more precise.

---

## Strengths

1. Excellent mental model: explicit "two things track your position" framing makes the recovery story easy to reason about.
2. Concrete diagnostic queries with interpretation guidance ("if 'lost' → data loss likely", "if from days ago → progress wasn't flushing").
3. The idempotent MERGE-on-event_id pattern is the correct production answer — the engineer can copy-paste this.
4. Goes beyond the question with the `source_lsn` prevention column — turns a fuzzy timestamp comparison into a precise LSN comparison.
5. Post-backfill compaction reminder is the right operational follow-up.

---

## Gaps

1. **Wrong `snapshot.mode: recovery` recommendation** for PostgreSQL — see HIGH bug above.
2. No mention of checking the Kafka Connect REST API (`GET /connectors/{name}/status`) — this is usually the first thing an SRE checks before digging into Postgres-side queries.
3. No mention of `wal_keep_size` / `max_slot_wal_keep_size` as the root-cause Postgres setting that determines whether a 2-hour outage is survivable. Engineer should know to check and tune this.
4. The Iceberg-vs-Postgres timestamp comparison logic depends on `event_ts` being a wall-clock column populated at insert time in Postgres. If `event_ts` is actually a write timestamp that lags behind real-time, the gap detection could miss events. A one-line caveat would help.
5. The `missed_end` is hardcoded — should mention pulling it from the connector restart time or using `now()` minus a safe lag buffer.

---

## Resource fix recommendations

**HIGH priority**: Update `resources/13-postgres-to-iceberg.md` (or wherever Debezium snapshot.mode is documented) to:
- Add an explicit table of `snapshot.mode` values **supported per connector** — clearly noting that `recovery` is NOT supported for PostgreSQL.
- Add a section "PostgreSQL connector: what to do when the replication slot is lost" with the correct workflow: drop slot → recreate slot → set `snapshot.mode: never` or `no_data` → manual targeted backfill from PRIMARY.

**LOW priority**:
- Add a note that Kafka Connect's offset topic name is configurable via `offset.storage.topic` and not literally `_debezium_connect_offsets`.
- Add `wal_keep_size` / `max_slot_wal_keep_size` to the Postgres-side preflight checklist for CDC.
- Add Kafka Connect REST API `/connectors/{name}/status` as the first diagnostic step after any connector restart.

---

## Topic state update

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
**Prior**: 4.479 avg over 86 questions
**This score**: 4.125
**New avg**: (4.479 × 86 + 4.125) / 87 = (385.194 + 4.125) / 87 = 389.319 / 87 = **4.475**
**Question count**: 87
**Status**: PASSED (still well above 3.5 threshold)
