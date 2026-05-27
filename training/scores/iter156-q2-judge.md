# Iter 156 Q2 — Judge Report

**Question topic**: Iceberg time-travel and rollback after accidental DELETE — how to query a pre-DELETE snapshot in Trino, how long snapshots are kept, and how to recover.

---

## Scores

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Technical accuracy | 4 | 2x | 8 |
| Clarity | 5 | 1x | 5 |
| Practical usefulness | 5 | 1x | 5 |
| Completeness | 5 | 1x | 5 |
| **Weighted average** | | | **23/5 = 4.60** |

**Verdict**: PASS (>= 4.5 threshold)

---

## Per-dimension rationale

### Technical accuracy — 4/5

Most of the answer is verifiably correct against current Trino and Iceberg documentation, but it contains one factual error and a couple of small precision issues.

**Verified correct:**

1. **`FOR VERSION AS OF <snapshot_id>` syntax** — correct Trino Iceberg time-travel syntax. Confirmed against Trino docs and the Starburst time-travel article: `SELECT ... FROM table FOR VERSION AS OF <bigint snapshot_id>`. (`FOR TIMESTAMP AS OF` is the timestamp variant, also documented; the answer reasonably picks the snapshot-ID variant which is more deterministic for recovery.)
2. **`"events$snapshots"` metadata table with `snapshot_id`, `committed_at`, `operation`, `summary` columns** — correct. The Trino Iceberg `$snapshots` metadata table exposes exactly those columns (plus `parent_id` and `manifest_list`).
3. **`CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <snapshot_id>)`** — correct for **Trino 467**. The `CALL iceberg.system.*` system-procedure form was the primary supported syntax through Trino 468. It was deprecated in **Trino 469 (Jan 27, 2025)** via PR #24580 in favor of the table-procedure form `ALTER TABLE events EXECUTE rollback_to_snapshot(<snapshot_id>)`. Since prod runs Trino 467, the answer's `CALL` syntax is correct and runnable.
4. **Copy-on-write DELETE creating new files and a new snapshot, with old files still in MinIO and reachable via the prior snapshot** — correct description of Iceberg 1.5.2 default behavior (`write.delete.mode=copy-on-write` is the default for v2 tables in Iceberg 1.5.x).
5. **Property names `history.expire.max-snapshot-age-ms` and `history.expire.min-snapshots-to-keep`** — correct names per Apache Iceberg configuration docs.
6. **Querying `events$properties` for `history.expire%` keys** — `$properties` is a real Trino Iceberg metadata table and the `LIKE` filter works.

**Errors / imprecision:**

1. **Default snapshot retention is wrong.** The answer says "By default: 7 days. Iceberg keeps snapshots for a minimum of 7 days before expiry maintenance can clean them up." The actual Apache Iceberg default for `history.expire.max-snapshot-age-ms` is **432,000,000 ms = 5 days**, not 7 days. Confirmed against multiple Iceberg references (Tabular cookbook, Apache Iceberg issue #2821, multiple platform docs). Also, `history.expire.min-snapshots-to-keep` defaults to **1**, not a higher number — meaning out of the box, after expiry, only the most recent snapshot is guaranteed to remain. This is a non-trivial error because:
   - It tells the engineer they have ~2 extra days of recovery window they don't actually have.
   - It misstates the property's role: `max-snapshot-age-ms` is a *property used by* `expire_snapshots`, not a hard "retention floor" — Iceberg does not enforce a "minimum 7 days before expiry can run." A maintenance job can be told to expire snapshots older than 1 hour. The default just controls what `expire_snapshots` deletes when called with defaults.

2. **"`expire_snapshots` ... typically a weekly job"** is a stack-specific assumption presented as fact. The repo doesn't specify the prod maintenance cadence. This should be hedged ("if your team has scheduled `expire_snapshots`, ask them when it last ran" or "ask the data platform team for the schedule") rather than asserted.

3. **Minor: snapshot-history query uses `TIMESTAMP '... UTC'` literal** — Trino's standard `TIMESTAMP '2026-05-20 00:00:00'` literal does not accept a `UTC` suffix; for timezone-qualified literals use `TIMESTAMP '2026-05-20 00:00:00 UTC'` with the `TIMESTAMP WITH TIME ZONE` interpretation, or compare against `committed_at` (which is `timestamp(6) with time zone`) using `TIMESTAMP '... +00:00'`. As written this will work in many Trino setups via implicit coercion but is not the cleanest example. Small issue.

These three drop technical accuracy from 5 to 4. The default-retention error is the largest concern because it directly affects the engineer's mental model of "how long do I have to recover."

### Clarity — 5/5

Excellent narrative structure: starts with reassurance ("yes, you can"), explains what Iceberg actually did to the data, gives the two-step recovery query, then addresses retention, then escalates to rollback as the decisive recovery action. Zero unexplained jargon — "snapshot," "copy-on-write," "expire," and "rollback" are all introduced with context. The "critical window" warning communicates urgency well. SQL examples are concrete and use the engineer's actual schema (`tenant_id = 42`, `analytics.events`).

### Practical usefulness — 5/5

The engineer can act on this immediately:
- Knows the exact `$snapshots` query to find the right snapshot ID.
- Knows the exact `FOR VERSION AS OF` query to inspect the lost data without touching the table.
- Knows the exact `CREATE TABLE AS SELECT ... FOR VERSION AS OF` pattern to surgically recover just tenant 42's rows into a safe staging table — this is the right play in production rather than rolling back the entire table and losing other tenants' subsequent writes.
- Knows the `CALL iceberg.system.rollback_to_snapshot` syntax if a full rollback is the right move.
- Knows the urgency: every `expire_snapshots` run closes the window.

The progression from "look at it" → "extract just what you need" → "or roll back entirely" mirrors what an experienced operator would actually do. This is exactly the actionable guidance the dimension is asking for.

### Completeness — 5/5

Both halves of the question are answered:
- **"Can I write a query against the old data, and if so, how?"** — Yes, with the snapshot lookup + `FOR VERSION AS OF` recipe.
- **"Is there a time limit on how far back I can go, or does it keep every version forever?"** — No, not forever; default retention is given (incorrectly as 7 days but the conceptual answer is right); both controlling properties are named; the `expire_snapshots` mechanism is explained; the engineer is told how to check their actual retention via `$properties`.

The answer also goes beyond the literal question with the rollback procedure and the staging-table recovery pattern, both highly relevant. Nothing material is missing.

---

## Weighted average

(4 × 2 + 5 + 5 + 5) / 5 = 23 / 5 = **4.60**

**PASS** (>= 4.5)

---

## What was verified correct (with sources)

- `FOR VERSION AS OF <snapshot_id>` Trino Iceberg time-travel syntax — [Starburst: Apache Iceberg Time Travel & Rollbacks in Trino](https://www.starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/), [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- `$snapshots` metadata table columns (`snapshot_id`, `committed_at`, `operation`, `summary`, `parent_id`, `manifest_list`) — [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- `CALL iceberg.system.rollback_to_snapshot('schema','table',id)` valid in Trino 467 (deprecated in Trino 469 via PR #24580) — [Trino PR #24580](https://github.com/trinodb/trino/pull/24580), [Trino 469 release notes (27 Jan 2025)](https://trino.io/docs/current/release/release-469.html)
- `$properties` metadata table for inspecting Iceberg table properties — [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [Trino PR #10480](https://github.com/trinodb/trino/pull/10480)
- `history.expire.max-snapshot-age-ms` and `history.expire.min-snapshots-to-keep` property names — [Apache Iceberg 1.5.1 Maintenance docs](https://iceberg.apache.org/docs/1.5.1/maintenance/), [Tabular: Retain and expire snapshots](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/)

---

## Errors and gaps

1. **HIGH-impact factual error**: Default `history.expire.max-snapshot-age-ms` is **5 days** (432,000,000 ms), not 7 days. Default `history.expire.min-snapshots-to-keep` is **1**, not a higher number. Also, this is the default *used by* `expire_snapshots` when computing what to delete, not a hard floor preventing earlier expiry. Sources: [Tabular cookbook](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/), [Apache Iceberg issue #2821](https://github.com/apache/iceberg/issues/2821).
2. **MEDIUM**: "Weekly `expire_snapshots` job" is asserted as if it were known. Should be flagged as an assumption for the engineer to verify with the data platform team.
3. **LOW**: `TIMESTAMP '... UTC'` literal style is non-standard in Trino; cleaner to use `TIMESTAMP '... +00:00'` or compare without timezone suffix.
4. **LOW (optional)**: Could mention `FOR TIMESTAMP AS OF TIMESTAMP '...'` as an alternative when the engineer knows the wall-clock time of the DELETE but not a clean snapshot to land on. Not required, but a nice completeness touch.
5. **LOW**: Could note that after `rollback_to_snapshot`, *any* writes that happened to the table between the bad DELETE and the rollback are also reverted — important caveat if other ingestion is still landing into the table. The CTAS / staging-table recovery path the answer already recommends sidesteps this, but the caveat on rollback itself is worth a sentence.

---

## Resource fix recommendations

- **HIGH**: Correct the default snapshot retention claim in `resources/17-iceberg-table-maintenance.md` (and anywhere else snapshot retention defaults are stated). The Iceberg default is **5 days for `max-snapshot-age-ms`** and **1 for `min-snapshots-to-keep`**. Also clarify these are inputs to `expire_snapshots`, not enforced retention floors. This same error would affect any future question about snapshot retention or maintenance cadence.
- **MEDIUM**: In the time-travel / recovery resource, add a sentence noting that `rollback_to_snapshot` reverts *all* changes since the target snapshot, including any legitimate writes — and that CTAS-from-snapshot is the safer surgical recovery when only a subset of rows needs to come back.
- **LOW**: Add a note that `CALL iceberg.system.rollback_to_snapshot(...)` was deprecated in Trino 469 in favor of `ALTER TABLE ... EXECUTE rollback_to_snapshot(...)`. Prod is on 467 so `CALL` is currently correct, but if they upgrade past 469 the answer needs to change. Worth a one-line forward-compatibility note.
- **LOW**: Mention `FOR TIMESTAMP AS OF` as the timestamp-based time-travel alternative.

---

## Topic checklist update

The relevant topic is **"Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup"** (covers snapshot retention and `expire_snapshots`) and also touches Iceberg time-travel / recovery. The maintenance topic currently shows PASSED at avg 4.602 over 14 questions. New score 4.60 keeps it at PASSED status; running average essentially unchanged.
