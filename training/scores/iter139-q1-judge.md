# Iter139 Q1 — Judge Verdict

**Question topic**: Iceberg time travel queries (FOR VERSION/TIMESTAMP AS OF), risks of cleanup jobs invalidating snapshots, snapshot isolation safety.

**Primary rubric topic touched**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup (prior avg 4.640 over 12 questions, PASSED). Secondary: Analytical query patterns on Iceberg+Trino.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5/5 | Core time-travel mechanics, `$snapshots` query, expire/orphan-files separation, 7-day floor all verified correct. **HIGH error**: the `CALL iceberg.system.create_tag(...)` procedure does not exist in Iceberg 1.5.x and is not supported in Trino 467. |
| Clarity | 4.5/5 | Excellent for a beginner. Explains "no reconstruction, no versioning magic, just old files." Snapshot-ID-vs-timestamp pitfall taught with a concrete clock example. Comparison table for retention policies is well-tuned to the audience. |
| Practical utility | 3.5/5 | Engineer can copy the `FOR VERSION AS OF`, `$snapshots` lookup, `expire_snapshots`, and `remove_orphan_files` snippets and run them in Trino 467 today. But the "pin a snapshot forever" recipe — the one that is most operationally important for billing close-outs — does not work as written. An engineer who runs the create_tag snippet in either Trino or Spark 1.5.2 will get a procedure-not-found error. |
| Completeness | 4.0/5 | Covers syntax, lookup, cleanup mechanics, the 7-day floor, retention sizing, the safety question, and the long-running query edge case. Missing: per-snapshot retention properties on the table itself (`history.expire.min-snapshots-to-keep`, `history.expire.max-snapshot-age-ms`), the production-environment Hive Metastore caveat for branch/tag refs, and the alternative `$history` metadata table. |

**Overall**: (3.5 + 4.5 + 3.5 + 4.0) / 4 = **3.875 / 5**

**Verdict**: **FAIL** (threshold 4.0). The HIGH-severity error on `create_tag` makes the most operationally consequential snippet in the answer non-runnable. The topic average remains a PASS in the rubric, so this is a one-off correction needed in the tagging guidance — not a topic-wide regression.

---

## What was verified correct (with sources)

- **`FOR TIMESTAMP AS OF` / `FOR VERSION AS OF` syntax in Trino** — confirmed against [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) and [Starburst Trino time travel blog](https://www.starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/). Both forms accept TIMESTAMP literals / snapshot IDs as shown.
- **`$snapshots` metadata table query syntax** — `iceberg.schema."table$snapshots"` with columns `snapshot_id`, `committed_at`, `operation` — confirmed against [Trino Iceberg docs](https://trino.io/docs/current/connector/iceberg.html) and [Trino on Ice III blog](https://trino.io/blog/2021/07/30/iceberg-concurrency-snapshots-spec).
- **`expire_snapshots` removes snapshot metadata; `remove_orphan_files` physically deletes orphan files** — confirmed against [Iceberg maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/). Two-step requirement is correctly explained.
- **Trino 467 7-day minimum retention floor** — `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` both default to `7d`, and `retention_threshold < min-retention` raises an error — confirmed against [Trino Iceberg docs](https://trino.io/docs/current/connector/iceberg.html).
- **Snapshot isolation makes time-travel reads safe concurrent with writes** — confirmed against [Iceberg spec](https://iceberg.apache.org/spec/) and [lakeFS Iceberg versioning post](https://lakefs.io/blog/iceberg-versioning/). The edge case the answer raises (long-running query whose files get deleted by mid-flight orphan cleanup) is a real concern.
- **Timestamp resolution returns the latest snapshot with `committed_at <= T`** — confirmed against [Conduktor Iceberg time-travel glossary](https://www.conduktor.io/glossary/time-travel-with-apache-iceberg). The pitfall framing is accurate and useful.

---

## Errors and gaps

### HIGH — `CALL iceberg.system.create_tag(...)` does not exist

The answer recommends:

```sql
CALL iceberg.system.create_tag(
    table       => 'analytics.usage_report',
    name        => '2026-03-billing-close',
    snapshot_id => 4823511203987654321
);
```

This procedure **does not exist** in either Iceberg 1.5.1/1.5.2 or Trino 467:
- [Iceberg 1.5.1 Spark procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) lists `rollback_to_snapshot`, `rollback_to_timestamp`, `set_current_snapshot`, `cherrypick_snapshot`, `publish_changes`, `fast_forward`, `expire_snapshots`, `remove_orphan_files`, `rewrite_data_files`, `rewrite_manifests`, `rewrite_position_delete_files`, `snapshot`, `migrate`, `add_files`, `register_table`, `ancestors_of`, `create_changelog_view`. No `create_tag`.
- Tags in Iceberg 1.5.x Spark are created via DDL: `ALTER TABLE prod.db.table CREATE TAG 'tag_name' AS OF VERSION <snapshot_id> RETAIN 365 DAYS`.
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) (current and 467 era) expose a read-only `$refs` metadata table but do **not** support `CREATE TAG` DDL or any tag-management CALL procedure. The open issues [trinodb/trino#16695](https://github.com/trinodb/trino/issues/16695) and [trinodb/trino#12844](https://github.com/trinodb/trino/issues/12844) confirm this gap.

In the production environment (Trino 467 + Iceberg 1.5.2 + Hive Metastore + Spark for ingestion), the only correct way to pin a snapshot from SQL is to run from **Spark**:

```sql
-- Spark only (Iceberg 1.5.2):
ALTER TABLE iceberg.analytics.usage_report
  CREATE TAG `2026-03-billing-close`
  AS OF VERSION 4823511203987654321
  RETAIN 3650 DAYS;
```

An engineer who copies the answer's snippet into either Trino or Spark gets a procedure-not-found error during a billing close-out — exactly the moment when failure is most costly.

### MEDIUM — No mention of table-level retention properties

The answer only covers per-invocation `retention_threshold` on the procedure. The production-grade approach for SaaS multi-tenant tables is to set table properties so that *every* expire_snapshots call honors a floor:

- `history.expire.min-snapshots-to-keep`
- `history.expire.max-snapshot-age-ms`
- `history.expire.max-ref-age-ms`

Without these, a misconfigured maintenance job can still purge the audit window. For an audit-focused use case, this belongs in the answer.

### MEDIUM — Hive Metastore + Iceberg branch/tag caveat not surfaced

The production environment uses **Hive Metastore** as the Iceberg catalog. Branch/tag commits in Iceberg 1.5.x with HMS work, but `$refs` exposure and tag-aware time travel (`FOR VERSION AS OF 'tag_name'`) have a different support matrix in Trino 467 vs. Spark. The answer would be more practically useful if it noted that the SQL `FOR VERSION AS OF <numeric snapshot_id>` works everywhere, but `FOR VERSION AS OF '<tag_name>'` is engine-version-dependent — and recommended sticking with numeric snapshot IDs for audits regardless.

### LOW — `$history` not mentioned as a complement to `$snapshots`

For audit purposes, `$history` shows the linear commit chain including rollbacks and ref reassignments, which is more accurate for "what did the table look like at time T" reconstructions than `$snapshots` alone. A one-line callout would be useful.

### LOW — Long-running-query edge case mitigation is incomplete

The answer correctly flags that `remove_orphan_files` could delete files under a long-running query but only suggests "schedule cleanup in a maintenance window." The cleaner mitigation — set `retention_threshold` on `remove_orphan_files` to comfortably exceed the longest expected query duration (e.g., `30d` for audit workloads) — is not mentioned.

---

## Resource fix recommendations

1. **`resources/17-iceberg-table-maintenance.md` (or wherever tagging is taught)** — Replace any `CALL iceberg.system.create_tag(...)` example with the correct Spark DDL: `ALTER TABLE <table> CREATE TAG '<name>' AS OF VERSION <snapshot_id> RETAIN <N> DAYS`. Explicitly label the snippet as **Spark only**. Add a note that Trino 467 cannot create tags from SQL — engineers must run this through Spark.
2. **Same resource** — Add a short table of table-level retention properties (`history.expire.min-snapshots-to-keep`, `history.expire.max-snapshot-age-ms`, `history.expire.max-ref-age-ms`) and explain that they provide a defense-in-depth floor that survives misconfigured procedure calls. Show the `ALTER TABLE ... SET TBLPROPERTIES` syntax (Spark) or Trino's equivalent `ALTER TABLE ... SET PROPERTIES`.
3. **Resource on time travel (if a dedicated one exists; otherwise add a section to `17-` or `16-` query patterns)** — Add a "stick with numeric snapshot IDs for audits" rule. Show `$history` alongside `$snapshots` for the lookup recipe. Add the mitigation for the long-running-query edge case (set `remove_orphan_files` retention well above max query duration).
4. **Cross-cutting** — Audit other resources for any `CALL ... create_tag` / `CALL ... create_branch` / `CALL ... drop_tag` / `CALL ... drop_branch` references; remove or replace with the correct ALTER TABLE DDL.

---

## Rubric impact

- **Iceberg table maintenance** topic: prior avg 4.640 over 12 questions; new running avg (4.640 × 12 + 3.875) / 13 = (55.68 + 3.875) / 13 = **4.581** over 13 questions. Status remains **PASSED**.
- No new topic needs to be added; this question is squarely within the existing maintenance topic.
