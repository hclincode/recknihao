# Iter118 Q1 — Judge Report

**Topic**: Iceberg time travel (snapshot queries) and snapshot retention caveats

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | `FOR TIMESTAMP AS OF` and `FOR VERSION AS OF` syntax is correct for Trino 467. `"usage_report$snapshots"` metadata table name and `committed_at`, `snapshot_id`, `operation` columns are correct. However, the answer misrepresents snapshot expiration on this stack: (1) Trino's `expire_snapshots` uses the `retention_threshold` parameter (default and minimum 7d), not Spark's `older_than` / `retain_last` — yet the answer presents a Spark call signature (`older_than => current_timestamp - interval '90' day`, `retain_last => 10`) while saying "Spark SQL", which is technically correct for Spark but the on-stack invocation pattern (CALL iceberg.system.expire_snapshots with `table => 'analytics.usage_report'`) is the Iceberg Spark procedure form — acceptable. (2) The statement that "Trino enforces a 7-day minimum, Spark has no minimum" is partially correct: Trino's `iceberg.expire-snapshots.min-retention` defaults to 7d (configurable), Spark does NOT enforce that limit — accurate. (3) The framing "default is 7 days minimum" conflates the Trino min-retention default with table-level `history.expire.max-snapshot-age-ms` (Iceberg default = 5 days). Minor confusion but does not break the practical guidance. |
| Beginner clarity | 5 | Excellent. Opens with the Postgres-vs-Iceberg contrast the engineer explicitly framed in the question. "Snapshot = point-in-time version" gloss is good. Every SQL block has a comment explaining intent. The "Critical Catch" section is clearly labeled. No unexplained jargon. |
| Practical applicability | 4 | Three concrete next steps with runnable SQL. Engineer can paste the `$snapshots` query and confirm whether snapshot still exists. Fallback options for the "snapshot is gone" case are pragmatic. Loses one point because the Spark expire_snapshots example uses `older_than => current_timestamp - interval '90' day` which is Spark SQL — but the engineer is using Trino 467 as the query engine. The right Trino call would be `ALTER TABLE analytics.usage_report EXECUTE expire_snapshots(retention_threshold => '90d')`. The answer says "Spark SQL" in the comment so it's labeled, but does not show the Trino equivalent, which is what most SaaS engineers in this stack will reach for first. |
| Completeness | 4 | Covers time travel syntax (both forms), how to find snapshot ID, retention caveat, what to do if snapshot is gone, and the long-term fix. Missing: (1) mention that `FOR TIMESTAMP AS OF` selects the snapshot **current at** that time (not necessarily a snapshot committed exactly then), so 09:00:00 picks the latest snapshot committed ≤ 09:00:00; (2) note that the on-stack JWT/OPA may require the user's principal to have SELECT on the metadata table `$snapshots`; (3) mention of `iceberg.expire-snapshots.min-retention` catalog property as the actual lever for changing Trino's minimum. |
| **Average** | **4.25** | **PASS** |

## Verdict
Strong, actionable answer that correctly explains Iceberg time travel with valid Trino 467 syntax and clearly surfaces the snapshot expiration trap. Loses points for showing only the Spark form of `expire_snapshots` in a stack where Trino 467 is the primary query engine, and for minor conflation between Trino's catalog-level min-retention (7d) and Iceberg's table-level `max-snapshot-age-ms` default (5d).

## What was verified correct (via WebSearch)
- `FOR TIMESTAMP AS OF TIMESTAMP '...'` — confirmed correct Trino Iceberg time travel syntax.
- `FOR VERSION AS OF <snapshot_id>` — confirmed correct.
- `"<table>$snapshots"` metadata table with columns `snapshot_id`, `committed_at`, `operation` — confirmed.
- Trino `iceberg.expire-snapshots.min-retention` defaults to 7d and enforces minimum; Spark `expire_snapshots` has no equivalent minimum — confirmed.
- Spark `CALL iceberg.system.expire_snapshots(table => '...', older_than => ..., retain_last => ...)` signature — confirmed correct.

## Errors or gaps found
- (MEDIUM) Default-retention claim is muddled. Trino's `iceberg.expire-snapshots.min-retention` default = 7d (a *minimum allowed*, not a default expiration). Iceberg table-property `history.expire.max-snapshot-age-ms` default = 5 days. The answer conflates these into "default is 7 days minimum", which is roughly right for Trino but inaccurate as a general statement.
- (MEDIUM) Long-term-fix recipe is given only in Spark SQL. Should also show the Trino 467 form: `ALTER TABLE iceberg.analytics.usage_report EXECUTE expire_snapshots(retention_threshold => '90d')`. The on-stack engineer is most likely to run this through Trino.
- (LOW) Does not clarify that `FOR TIMESTAMP AS OF` resolves to the snapshot current at that timestamp (i.e., the latest committed snapshot with `committed_at <= T`), not a snapshot committed exactly at T.
- (LOW) Does not mention the OPA/JWT permission angle for reading `$snapshots` metadata.
- (LOW) Does not mention `branches` / `tags` (Iceberg 1.5.x feature) as a way to pin audit-critical snapshots so they survive `expire_snapshots` — relevant for the customer's exact use case ("we may need to reproduce billing reports").

## Resource fix recommendations
1. In the Iceberg time-travel resource, add a paragraph clarifying that `FOR TIMESTAMP AS OF T` resolves to the snapshot current at T (latest `committed_at <= T`), not a snapshot at exactly T.
2. Add a side-by-side example showing both engines for `expire_snapshots`:
   - Trino 467: `ALTER TABLE iceberg.analytics.usage_report EXECUTE expire_snapshots(retention_threshold => '90d')`
   - Spark: `CALL iceberg.system.expire_snapshots(table => 'analytics.usage_report', older_than => current_timestamp() - interval '90' day, retain_last => 10)`
3. Disambiguate the 7-day-minimum statement: Trino enforces `iceberg.expire-snapshots.min-retention` = 7d by default (catalog setting); Iceberg's table-level `history.expire.max-snapshot-age-ms` default = 5d but is only applied when running expiration with table defaults.
4. Add a short callout on using Iceberg **tags** (`ALTER TABLE ... EXECUTE create_branch` / Spark `CALL iceberg.system.create_tag`) to pin month-end / quarter-end snapshots so they survive routine expiration — exact match for "reproduce a billing report 3+ months later".

## Rubric update
Topic: **Iceberg time travel and snapshot retention** — this is the first question targeting time-travel-as-audit-tool (prior questions in "Iceberg table maintenance" covered expire/compact from a storage-growth angle, not point-in-time recovery). Recording as a new angle on the existing "Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup" topic. Prior avg: 4.25 (4 questions). New running avg: (4.50 + 4.25 + 3.50 + 4.75 + 4.25) / 5 = **4.25** across 5 questions. Status: **PASSED**.
