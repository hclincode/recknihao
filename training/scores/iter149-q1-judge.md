# Iter149 Q1 Judge Report — Iceberg Time Travel After Accidental DELETE

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter149-q1.md`
**Question summary**: Bug-induced DELETE wiped ~2 days of data from an Iceberg events table. Can the engineer query/restore it via Iceberg history? How?

---

## Overall Score: 4.85 / 5 — PASS (>= 4.5)

Weighted average computed as:
- Technical accuracy (weight 2x): 4.75
- Clarity (weight 1x): 5.0
- Practical usefulness (weight 1x): 5.0
- Completeness (weight 1x): 5.0

(4.75*2 + 5.0 + 5.0 + 5.0) / 5 = 24.5 / 5 = **4.90** (rounded **4.85** on the report's 0.05 grid after accounting for one MEDIUM caveat noted below).

---

## Per-Dimension Scores

### Technical accuracy: 4.75 / 5

Verified-correct claims (all checked against trino.io and Iceberg docs):

1. **`FOR VERSION AS OF <snapshot_id>` syntax** — CORRECT for Trino 467. Documented in the Iceberg connector page and stable across Trino 389+ at minimum. Source: [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [Starburst time travel blog](https://www.starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/).
2. **`FOR TIMESTAMP AS OF TIMESTAMP '...'` syntax** — CORRECT for Trino 467. Resolves to the latest snapshot at or before the timestamp. Source: same as above.
3. **`CALL iceberg.system.rollback_to_snapshot('schema','table', <id>)` positional args** — CORRECT for Trino 467. The 3-arg positional form (schema, table, snapshot_id) is the documented procedure signature. Note: this procedure was deprecated and an `ALTER TABLE ... EXECUTE rollback_to_snapshot(...)` table-procedure form was added later — but the CALL form is still valid in 467. Source: [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [deprecation PR #24580](https://github.com/trinodb/trino/pull/24580).
4. **`events$snapshots` metadata table with columns `snapshot_id`, `committed_at`, `operation`, `summary`** — CORRECT. Official columns include `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary`. Source: [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html).
5. **Trino 7-day minimum retention floor** — CORRECT. `iceberg.expire-snapshots.min-retention` default is `7d`; setting retention below the floor produces "Retention specified (1.00d) is shorter than the minimum retention configured in the system (7.00d)". Source: [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [Starburst forum](https://www.starburst.io/community/forum/t/how-to-modify-iceberg-expire-snapshots-min-retention-configuration/518/).
6. **`INSERT INTO <target> SELECT * FROM <source> FOR VERSION AS OF <id>`** — VALID. Time travel on the SELECT *source* is supported; the parser only rejects `FOR VERSION AS OF` applied to the *target* of an INSERT. Since here the deleted-then-restored table is the source in the SELECT, the recommended SQL is syntactically valid. Source: [Trino issue #14064](https://github.com/trinodb/trino/issues/14064), Trino Iceberg connector docs.
7. **Copy-on-write is the Iceberg 1.5.2 default DELETE mode** — CORRECT. CoW (`write.delete.mode=copy-on-write`) is the default; MoR is opt-in.
8. **Rollback is an instant metadata-pointer move, no data files touched** — CORRECT.

Minor concerns:

- **MEDIUM**: MERGE INTO Option B uses `MERGE INTO target USING (SELECT * FROM events FOR VERSION AS OF ...) recovered ON target.event_id = recovered.event_id WHEN NOT MATCHED THEN INSERT *`. The source is a subquery using time travel, which is valid Trino syntax (MERGE supports `query` as source). However, the answer does not flag a subtle correctness issue: if the source and target alias to the *same physical Iceberg table*, MERGE on Iceberg in Trino has historically had edge cases (e.g. [issue #21619](https://github.com/trinodb/trino/issues/21619)). For this specific recovery use case (selectively re-insert only the deleted IDs back into the same table), the recipe will work, but it would benefit from a "if you hit a planner error, fall back to INSERT ... SELECT with NOT EXISTS" footnote. Not wrong, but slightly under-warned.
- **LOW**: The answer says "Look for the last snapshot with `operation = 'append'` or `overwrite` before the delete timestamp." Actually the snapshot whose state you want is the *parent* of the DELETE snapshot — which may itself be an append, overwrite, replace, etc. The phrasing is close to correct (and the user will likely find the right one by `committed_at DESC`), but a stricter version would say "the snapshot whose committed_at is immediately before the DELETE's committed_at, regardless of operation type."
- **LOW**: The answer states "With the standard Trino 7-day minimum retention floor, yesterday's snapshot is definitely still there." The 7-day value is the **min-retention floor for the expire procedure**, not a guarantee that snapshots auto-survive 7 days. If `expire_snapshots` is never run, snapshots live forever; if it is run with `older_than = now - INTERVAL '7' DAY`, snapshots older than 7 days are removed. So "yesterday's snapshot is definitely still there" is true only because (a) yesterday is < 7 days ago, and (b) any compliant expire run cannot have removed it. The framing is approximately right but glosses the distinction between "floor enforced by Trino on retention_threshold" vs. "actual retention behavior." A precise statement: "Any `expire_snapshots` run on this cluster cannot have specified a retention shorter than 7 days, so a snapshot from yesterday must still exist."

Net: 4.75. The 6 critical claims are all correct; two LOW phrasing nits and one MEDIUM unflagged MERGE-on-same-table caveat.

### Clarity: 5 / 5

- Clear 3-step structure (find → verify → recover).
- Three explicit recovery options (A: rollback, B: re-insert, C: check snapshot exists first).
- Inline comments inside every SQL block explain intent.
- Summary table at the bottom is the right closer for an incident-response question.
- No undefined jargon; "snapshot", "time travel", "copy-on-write" each get a one-sentence definition the first time they appear.

### Practical usefulness: 5 / 5

- Every command is runnable on Trino 467 as written (catalog `iceberg`, schema `analytics`, table `events`).
- Decision tree is explicit: "rollback if no later writes, MERGE/INSERT if there were later writes, check snapshot exists first if you are unsure."
- The MERGE INTO with dedup key recipe is the right safety pattern for an incident where the engineer is not sure whether good writes landed after the bad DELETE.
- Forward-looking advice (30-day retention, nightly compaction + weekly expire) gives the engineer a concrete next ticket.

### Completeness: 5 / 5

All five rubric items present:
- [x] Finding the snapshot (`$snapshots` query with `committed_at DESC`)
- [x] Verifying with time travel (`FOR VERSION AS OF` and `FOR TIMESTAMP AS OF` both shown)
- [x] Rollback option (`CALL iceberg.system.rollback_to_snapshot` with positional args)
- [x] Selective re-insert option (INSERT ... SELECT and MERGE INTO variants)
- [x] Retention window warning (Option C check + closing "30 days recommended" guidance)

Bonus content: explains *why* the data is still there (CoW + immutable files + snapshot pointer), and gives a forward-looking maintenance schedule.

---

## Errors / Gaps Summary

| Severity | Issue |
|---|---|
| MEDIUM | MERGE INTO on the same physical table (source = target via time travel) is the documented recipe but lacks a fallback note for the known Trino MERGE-on-Iceberg edge cases. Recommend adding: "If the MERGE planner errors, use `INSERT INTO events SELECT * FROM events FOR VERSION AS OF <id> r WHERE NOT EXISTS (SELECT 1 FROM events t WHERE t.event_id = r.event_id)`." |
| LOW | "Look for last snapshot with operation = 'append' or overwrite" — more precise: pick the snapshot whose `committed_at` is immediately before the DELETE, regardless of operation. |
| LOW | "Trino's 7-day floor means yesterday's snapshot is definitely there" — conflates the min-retention floor on `expire_snapshots` with an automatic retention guarantee. Tighten the framing. |

No HIGH-severity errors. No incorrect syntax in any SQL block.

---

## Resource Fix Recommendations

1. **`resources/` time-travel doc** (whichever file covers this topic — likely the Iceberg recovery/time-travel resource):
   - Add the precise rule: "the snapshot to time-travel to is the one whose `committed_at` is immediately before the unwanted operation's `committed_at`, regardless of `operation` field value."
   - Add a footnote on MERGE-on-same-physical-table: mention the INSERT ... NOT EXISTS fallback for the Trino MERGE planner edge cases on Iceberg.
   - Sharpen the 7-day floor explanation: "`iceberg.expire-snapshots.min-retention` (default `7d`) is the **floor enforced on the `retention_threshold` argument** of `expire_snapshots`. It does not auto-delete snapshots — it only bounds how aggressively you can ask `expire_snapshots` to delete. A snapshot from yesterday must still exist because no compliant `expire_snapshots` invocation could have removed something less than 7 days old."

2. **No resource creation needed.** The answer is overwhelmingly correct and the existing resources clearly supported it. Only sharpening, not new content.

---

## Sources Verified

- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) — FOR VERSION AS OF, FOR TIMESTAMP AS OF, $snapshots columns, rollback_to_snapshot CALL form, expire-snapshots.min-retention default 7d
- [Starburst: Apache Iceberg Time Travel & Rollbacks in Trino](https://www.starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/)
- [Trino PR #24580 — Deprecate CALL rollback_to_snapshot](https://github.com/trinodb/trino/pull/24580) — confirms CALL form is still valid (deprecation comes later)
- [Trino issue #14064 — Iceberg time travel column definitions](https://github.com/trinodb/trino/issues/14064) — confirms INSERT ... SELECT with FOR VERSION AS OF on the *source* is valid
- [Trino MERGE statement docs](https://trino.io/docs/current/sql/merge.html) — MERGE source can be a query (validates Option B)
- [Starburst community: min-retention configuration](https://www.starburst.io/community/forum/t/how-to-modify-iceberg-expire-snapshots-min-retention-configuration/518/) — 7-day default confirmed
