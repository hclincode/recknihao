# Iter 330 — Q1 Score (Iceberg snapshots and `$snapshots` diagnostics)

**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup
**Topic running avg before this score**: 4.574 across 25 questions
**Resource consulted**: `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
**Answer evaluated**: `/Users/hclin/github/recknihao/training/answers/iter330-q1.md`

---

## Score table

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3.75 | Two real Trino-vs-Spark syntax errors (see below); core snapshot concepts and `$snapshots` columns correct. |
| Beginner clarity | 4.75 | Excellent photograph analogy; worked Day 1/2/3 example makes immutability click; column glossary plain-language. |
| Practical applicability | 4.25 | Correct decision criteria, runnable diagnostic SQL, ordered runbook — but one of the two SQL blocks (`SET TBLPROPERTIES`) fails on the production Trino 467 stack as written. |
| Completeness | 4.25 | Covers all five required areas (what a snapshot is, `$snapshots`, keep-vs-expire criteria, how `expire_snapshots` works, maintenance order). Omits `parent_id` and `manifest_list` columns; no mention of `$refs`/tags as the explicit pin mechanism. |
| **Average** | **4.25** | **PASS** (≥ 3.5 threshold) |

---

## What worked

- **Snapshot definition is excellent for a beginner.** The "photograph of the table's state at a moment in time" line is exactly right and immediately landed. The Day 1 / Day 2 / Day 3 walk-through with the 1M-row INSERTs concretely explains why storage grows even when no new data is ingested — that's the SaaS engineer's actual question.
- **The `$snapshots` query is copy-pasteable and correct** for Trino 467, including the important `"events$snapshots"` quoting note (the `$` is a reserved character in Trino and requires double-quoting the identifier). Many responders forget this and the query fails.
- **Column descriptions for `snapshot_id`, `committed_at`, `operation`, `summary` are accurate**, and the operation list (`APPEND`, `OVERWRITE`, `DELETE`, `REPLACE_PARTITIONS`) is consistent with the Iceberg spec.
- **Keep-vs-expire decision rules are correct**: time-travel queries in flight, audit-pinned snapshots, and a safety floor of "always keep the last N" map directly to what an operator actually needs to weigh.
- **Maintenance order is correct** — compaction → expire_snapshots → remove_orphan_files → rewrite_manifests matches the verified canonical sequence and the resource.
- **The 7-day Trino 467 minimum-retention floor is explicitly called out** in the comment next to the `expire_snapshots` example. That's the version-specific gotcha the previous iter323 failure was about; this answer got it right.

## What missed

### Technical errors (these are the real defects)

1. **`SET TBLPROPERTIES` is Spark syntax, NOT Trino.** The block at lines 69–74 reads:
   ```sql
   ALTER TABLE iceberg.analytics.events
   SET TBLPROPERTIES (
       'history.expire.min-snapshots-to-keep' = '5',
       'history.expire.max-snapshot-age-ms'   = '2592000000'
   );
   ```
   Trino 467 uses `ALTER TABLE ... SET PROPERTIES property_name = value` (no parentheses around the list, and `SET PROPERTIES` not `SET TBLPROPERTIES`). Pasting the above into a Trino client fails with a syntax error. This is a Spark-vs-Trino confusion the resource elsewhere explicitly warns about.

2. **Even with the correct keyword, Trino cannot set those Iceberg-native properties.** Trino 467's `SET PROPERTIES` only accepts connector-recognized properties (`partitioning`, `format`, `format_version`, `sorted_by`, etc.) — it does NOT pass through `history.expire.min-snapshots-to-keep` or `history.expire.max-snapshot-age-ms`. To set those, the engineer must run `ALTER TABLE ... SET TBLPROPERTIES (...)` **from Spark SQL**. The answer recommends the right defense-in-depth properties but tells the engineer to run them in the wrong engine with the wrong keyword — a double error in one block that will frustrate them.

3. **Minor — column list omits `parent_id` and `manifest_list`.** Per Trino docs, `$snapshots` has columns: `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary`. The four documented are correct; the two omitted are useful (parent_id for walking snapshot lineage, manifest_list for debugging metadata size).

### Completeness gaps

- **No mention of `$refs` or tags** as the way to pin audit-required snapshots. The "Dangerous to expire — Snapshots tagged for long-term retention" bullet correctly identifies the need, but doesn't tell the engineer how to discover what is currently pinned (`SELECT * FROM iceberg.analytics."events$refs" WHERE type = 'TAG'` is the pre-flight check before any retention-tightening expire run).
- **No mention of `$history`** as the better metadata table for "which snapshot was actually live at time T" reconstruction (relevant for audit-style "is this snapshot safe to expire" decisions).
- **No mention of the `retain_last` Trino 467 limitation.** The example uses `retention_threshold => '30d'`, which is fine, but a more complete answer would note that "keep the last N snapshots regardless of age" requires Spark on Trino 467 (the `retain_last` argument is Trino 479+).
- **`expire_snapshots` description is slightly imprecise.** Step 3 says "Iceberg issues deletion commands to remove those orphaned files from MinIO" — technically correct (expire_snapshots itself does delete unreferenced data files for files that fall out of all live snapshots), but the answer doesn't distinguish between (a) files that become unreferenced and are deleted by `expire_snapshots` itself vs (b) true orphans (failed-write fragments) that only `remove_orphan_files` can sweep. The maintenance-order section later implies the distinction but the procedure-description section conflates them.

---

## Technical accuracy verification

I verified each of the five required points via WebSearch against the Trino docs and Iceberg spec:

| Check | Verdict | Source |
|---|---|---|
| (a) `$snapshots` columns include `snapshot_id`, `committed_at`, `operation`, `summary` | CORRECT — also has `parent_id`, `manifest_list` (omitted in answer, not wrong) | [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) |
| (b) Maintenance order: compaction → expire_snapshots → remove_orphan_files → rewrite_manifests | CORRECT | Resource 17 + [Iceberg maintenance docs](https://iceberg.apache.org/docs/1.5.1/maintenance/) |
| (c) Trino 467 7-day minimum retention floor for `expire_snapshots` | CORRECT — confirmed `iceberg.expire-snapshots.min-retention` defaults to `7d` and Trino rejects shorter values | [Starburst forum on min-retention](https://www.starburst.io/community/forum/t/how-to-modify-iceberg-expire-snapshots-min-retention-configuration/518/), [Trino issue #27357](https://github.com/trinodb/trino/issues/27357) |
| (d) `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` are real Iceberg properties | CORRECT — but they are **Iceberg table properties** that on this stack must be set via Spark `SET TBLPROPERTIES`, NOT Trino `SET PROPERTIES` (which only accepts connector properties like format/partitioning) | [Tabular cookbook](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/), [Iceberg PR #11190](https://github.com/trinodb/trino/issues/11190) |
| (e) `FOR VERSION AS OF` is the correct Trino time-travel syntax | CORRECT — accepts a BIGINT snapshot_id | [Starburst time-travel blog](https://www.starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/) |

The bug found via verification: the answer's table-property example uses `SET TBLPROPERTIES (...)` against `iceberg.analytics.events` in a context the reader will assume is Trino (every other SQL block in the answer is Trino syntax). This statement fails on Trino 467 for two compounding reasons: (1) wrong keyword (`SET TBLPROPERTIES` is Spark), and (2) even with the right keyword, Trino's `SET PROPERTIES` doesn't accept Iceberg-native `history.expire.*` properties.

---

## Recommended resource fix (for the teacher)

Add an **engine label** to the table-property example in resources/17 around line 437–443 making explicit that:
- `SET TBLPROPERTIES` syntax is **Spark SQL only**.
- On Trino 467, attempting `SET PROPERTIES 'history.expire.min-snapshots-to-keep' = '5'` also fails because Trino does not pass through those properties — they must be set from a Spark session.
- Show the correct Spark form alongside the Trino form, and clarify that the **retention floor on the table** is set from Spark, not from a Trino client.

This is the same class of Spark/Trino confusion that has caused prior topic drops (iter317 dbt-trino `rollback_to_snapshot` Spark-vs-Trino mistake, iter323 `retain_last` version-constraint mistake). One more reinforcement in the table-properties section would close the recurring failure mode.

---

## Topic running average update

(4.574 × 25 + 4.25) / 26 = **4.561 / 26 questions** — PASSED (mild downward drift from 4.574; recoverable next iteration if the `SET TBLPROPERTIES` Spark-vs-Trino fix is added to resources/17).
