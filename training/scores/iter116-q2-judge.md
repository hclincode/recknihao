# Iter116 Q2 — Judge Report

**Question topic**: GDPR right-to-erasure — physically purging a tenant's data from Iceberg snapshots, history, and MinIO bytes, across ~12 tables.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter116-q2.md`

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | **5** | Every claim about the 4-step sequence, Trino's `iceberg.expire_snapshots.min-retention` 7d floor, the `history.expire.min-snapshots-to-keep` / `history.expire.max-snapshot-age-ms` properties, and the `$snapshots` / `$files` metadata tables verified against official Iceberg/Trino docs. SQL is syntactically correct for the engines it's labeled with. |
| Beginner clarity | **5** | MVCC, delete files, snapshots, and "logical vs physical deletion" all explained in plain English. Why-this-matters before how-to-do-it. Step-by-step structure with one task per step. |
| Practical applicability | **5** | A SaaS engineer can execute this verbatim — exact SQL, exact procedure names, exact CALL syntax. 30-day timeline guidance. Verification checklist using `$snapshots` and `$files` metadata tables for regulator audit. Specifically calls out the production stack (Trino 467 / Spark / MinIO). |
| Completeness | **5** | Covers: (a) why DELETE alone is insufficient, (b) the full 4-step sequence (DELETE → rewrite_data_files → expire_snapshots → remove_orphan_files), (c) why order matters, (d) Trino vs Spark for expiry with the 7-day floor explanation, (e) table-property pitfalls that silently block expiry, (f) per-table verification queries against `$snapshots` and `$files`, (g) the DROP PARTITION anti-pattern, (h) compliance timeline. |
| **Average** | **5.0** | |

**Verdict: PASS (5.0/5.0)**

---

## What was verified correct (via WebSearch + official docs)

1. **Trino's 7-day floor on `expire_snapshots`** — confirmed: `iceberg.expire_snapshots.min-retention` defaults to `7d`; passing a shorter retention fails with `Retention specified (1.00d) is shorter than the minimum retention configured in the system (7.00d)`. The answer's recommendation to "always run `expire_snapshots` from Spark for GDPR urgency" is accurate. [Trino Iceberg docs](https://trino.io/docs/current/connector/iceberg.html)
2. **`rewrite_data_files` with `where` filter** — confirmed: the Spark procedure accepts a `where` clause restricted to partition columns; `tenant_id = 'acme'` qualifies because the table is partitioned by `tenant_id`. The procedure applies position deletes and writes clean Parquet under the current spec. [Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
3. **`expire_snapshots(table, older_than, retain_last)`** — confirmed: Spark procedure signature matches; `retain_last => 1` keeps the current snapshot, `older_than => current_timestamp()` expires everything older. [Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
4. **`remove_orphan_files` with `older_than`** — confirmed: requires a time boundary because file creation and metadata commits are not atomic; the `INTERVAL '1' DAY` lookback is a reasonable safety margin. [Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
5. **Iceberg table properties that block expiry** — confirmed: `history.expire.min-snapshots-to-keep` (default 1, a count) and `history.expire.max-snapshot-age-ms` (default 432000000 = 5 days) DO override the procedure's `retain_last` semantics. The answer's recommendation to check `SHOW CREATE TABLE` and temporarily UNSET these is correct. [Tabular Cookbook](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/)
6. **Metadata table verification queries** — confirmed: `"events$snapshots"` and `"events$files"` are valid Trino syntax for inspecting Iceberg metadata. `partition.tenant_id` resolves correctly on an identity-partitioned table (matches what `resources/05` already documents at length).
7. **MVCC + delete files explanation** — accurate description of position/equality delete files marking rows in the current snapshot while original Parquet remains referenced by older snapshots.
8. **DROP PARTITION anti-pattern warning** — correct: on a shared multi-tenant table, partition-level drop ops on `tenant_id` only would target the right tenant, but the warning about not using partition-level operations for sub-partition (per-user) erasure is sound defensive guidance.

---

## Errors or gaps found

None of consequence. A few very minor nits below — none rise to the level of a deduction.

- **Nit (LOW)**: Step 3's `expire_snapshots(retain_last => 1, older_than => current_timestamp())` works in Spark but the answer could mention that `older_than` precisely at `current_timestamp()` is a boundary value; some Iceberg versions evaluate strictly-greater-than. In practice this works because the rewrite-data-files commit (Step 2) creates a brand-new snapshot whose timestamp is older than the subsequent `current_timestamp()` call. Not worth deducting on.
- **Nit (LOW)**: The answer says "Iceberg removes all old snapshot metadata entries, then issues S3 DELETE calls against every Parquet file no longer referenced by any surviving snapshot." Technically the unreferenced data files include both Parquet data files AND delete files (position/equality), plus old manifest files and manifest lists. The answer's phrasing is correct but slightly imprecise — a regulator-grade audit might want to confirm manifest cleanup too. Not deducting because the user's question was about data bytes, not metadata files.
- **Nit (LOW)**: `'history.expire.min-snapshots-to-keep' = '5'` example — clarifying that this is a COUNT (not a time) would be slightly clearer for a beginner. The answer's wording "silently keep 5 snapshots" implies that correctly, so this is borderline.

None of these are worth marking down.

---

## Topics touched (rubric updates)

- **Multi-tenant analytics: isolating customer data in SaaS** — primary topic. This is a tenant-data-isolation question wrapped around GDPR right-to-erasure.
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — secondary topic. Direct usage of `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files` in sequence.

Both topics are already PASSED with strong scores; this answer reinforces.

---

## Resource fix recommendations

**None required.** The answer is at or above the level of the existing `resources/05-multi-tenant-analytics.md` GDPR section. The teacher's prior iterations have built solid GDPR coverage and this answer demonstrates the responder is now reliably reproducing it correctly.

Optional (LOW priority) enhancement — if the teacher wants to harden against the one borderline nit:

- **LOW** — `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` — consider adding a sentence to the GDPR 4-step sequence explaining that `expire_snapshots` also deletes orphaned manifest files and manifest lists (not just Parquet data files), so a regulator-grade audit can be told "all metadata pointing to the deleted data is also gone, not just the data files themselves." This is a polish improvement, not a correctness fix.

---

## Final verdict

**5.0 / 5.0 — PASS.** This is a textbook-quality answer for the GDPR right-to-erasure use case on this stack. The responder correctly:
- Distinguished logical from physical deletion.
- Sequenced the 4 maintenance procedures in the only correct order.
- Labeled engine boundaries (Trino vs Spark) and explained the 7-day floor.
- Surfaced table properties that silently block expiry.
- Provided regulator-facing verification SQL using `$snapshots` and `$files`.
- Stayed within the production stack constraints (Trino 467, Iceberg 1.5.2, Spark, MinIO).
- Warned against a real foot-gun (DROP PARTITION for per-user erasure on shared tables).

Sources:
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- [Iceberg Spark Procedures (latest)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/)
- [Tabular — Retain and expire snapshots](https://www.tabular.io/apache-iceberg-cookbook/data-operations-snapshot-expiration/)
- [Starburst forum — modifying iceberg.expire_snapshots.min-retention](https://www.starburst.io/community/forum/t/how-to-modify-iceberg-expire-snapshots-min-retention-configuration/518/)
