# Judge Feedback — Iter 321

Date: 2026-05-27
Phase: extended
Topics: Column rename detection in CDC pipeline (Q1) + Time-travel snapshot storage cost (Q2)

---

## Q1 — Column rename detection in CDC pipeline

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core mechanism correct: Postgres pgoutput emits no DDL rename event; Debezium learns the new column layout via the WAL relation message piggybacked on the next DML; rename is effectively seen as "old column gone, new column appears." Iceberg `ADD COLUMN` / `DROP COLUMN` mechanics correct. One imprecision: the "Default: Silent column drop. The old column name disappears from events. The new column name never appears" framing is slightly off — per Debezium PG connector behavior, once the relation message arrives the connector emits events that include the **new** column name; what is "silently broken" is the downstream consumer (Spark MERGE) whose column list still references the old name, and/or an Iceberg table that has never had `ADD COLUMN` for the new name. The answer partially course-corrects in step 4 ("With auto-evolution enabled... your Spark job's hardcoded column list probably still references the old name"), but the lead-in implies Debezium itself drops the new column, which overstates it. Also missing: that Iceberg has a native `ALTER TABLE ... RENAME COLUMN` (metadata-only, preserves column ID) which would be the cleanest alternative repair if the schema-match path were chosen; the answer instead always recommends ADD + backfill + DROP. Postgres RENAME being catalog-only (no rewrite, brief AccessExclusiveLock) not mentioned — minor since the question is CDC-side. |
| Beginner clarity | 4.5 | Walks through what Debezium "sees" step by step, names the WAL relation message concept, contrasts with MySQL/SQL Server schema-history topic. Phrases like "data silently vanishes" and "Don't Rename in Postgres. Migrate Instead." make the takeaway memorable. No unexplained jargon — "WAL relation message" and "logical replication protocol" are both introduced with their function. Could have briefly defined "expand/contract" by name since that is the canonical industry term for the 5-step migration, but the steps themselves are clear. |
| Practical applicability | 4.75 | Two complete runnable paths: (a) prevention via expand/contract migration in 5 numbered steps, (b) repair pattern for the user's already-broken state in 4 steps with SQL/PySpark snippets. The MERGE INTO sample uses explicit column lists, which directly answers the prevention sub-question. Preflight schema-diff and "alert on DROP+ADD pair on same table" is a concrete detection rule the engineer can put into their CI/cron today. Spark MERGE example fits the prod stack (Spark + Iceberg). Missing: a note that step 3's `UPDATE iceberg... SET new_name = old_name` only recovers values written **before** the Postgres rename — anything Debezium attempted to write to the new column name during the broken window (if Iceberg auto-evolved) may live in a different column or be missing entirely; the engineer should reconcile against Postgres after the fix. Also missing: any mention of the Trino-side equivalent of these ALTERs (the prod stack uses Trino 467 as the query engine), though Spark-side ALTER works fine. |
| Completeness | 4.5 | All three sub-questions answered: (1) how Debezium handles the rename — yes, with the relation-message mechanism; (2) what happened on the user's pipeline — yes, framed as old-gone/new-appears with the consumer-side break; (3) safe process going forward — yes, the expand/contract pattern plus a repair recipe and a detection/prevention rule. Nuance gaps: doesn't mention that Iceberg's native `RENAME COLUMN` preserves column ID and is metadata-only (would let engineer keep one column instead of ADD+DROP if they choose to align Iceberg to the new Postgres name); doesn't mention that the WAL relation message arrives only on the **next DML**, so a read-heavy/write-light table can defer the propagation for hours and that's not a separate failure (this is in resources/13 already and would have improved the diagnostic framing); doesn't mention checking connector schema-cache or restarting the Debezium task if a stale cached schema is suspected. |
| **Average** | **4.56** | **PASS** |

### What Worked
- Correctly framed the root cause as Postgres pgoutput emitting no DDL rename event, with Debezium learning new column layout via the WAL relation message tied to the next DML.
- Correctly contrasted Postgres (no schema-history topic) vs MySQL/SQL Server (separate schema-history Kafka topic) — useful mental model.
- Expand/contract migration pattern (add new column → dual-write → switch readers → drop old) is the textbook-correct prevention and is laid out as 5 actionable steps.
- Concrete repair recipe with runnable SQL and a Spark MERGE skeleton that uses explicit column lists.
- Preflight schema-diff with "DROP+ADD pair on the same table = likely rename" is a real, deployable detection rule.
- Explicit MERGE column list recommendation directly attacks the silent-failure mode.

### What Missed
- Lead-in overstates "the new column name never appears" as if Debezium itself drops new-column events. More accurate: once the WAL relation message arrives, Debezium **does** emit events with the new column name; the silence is downstream — either the Iceberg table has no such column, or the Spark MERGE column list still references the old name, or both. The answer self-corrects in step 4 but the misframe sits at the top of the technical explanation.
- Does not mention Iceberg's native `ALTER TABLE ... RENAME COLUMN` (metadata-only, preserves column ID) as an alternative to ADD-then-DROP when the engineer wants the Iceberg schema to match the new Postgres name and is willing to update consumers in lockstep.
- Postgres `RENAME COLUMN` being catalog-only with a brief `ACCESS EXCLUSIVE` lock not mentioned — would have reassured the engineer that the Postgres side wasn't the bottleneck.
- The repair's `UPDATE iceberg... SET new_name = old_name` only recovers values written **before** the rename; anything Debezium tried to land during the silent window (if auto-evolution was on) needs a separate reconciliation against the Postgres source-of-truth. Should be called out.
- No mention of restarting the Debezium task or refreshing connector schema cache if the relation message is suspected stale.
- Prod-stack-fit: example uses Spark SQL only; a one-liner showing the Trino 467 equivalent (`ALTER TABLE iceberg.analytics.your_table RENAME COLUMN ...` from Trino against the Hive Metastore catalog) would have closed the loop for the user's actual query engine.

### Technical Accuracy (verified)
- **Debezium PG connector treats RENAME COLUMN as drop-old + add-new (no rename event)**: Confirmed via Debezium PG connector docs / Red Hat Integration docs — Debezium for Postgres does **not** maintain a schema-history topic and learns table shape from WAL relation messages; the connector "appends a column with the new name" rather than recognizing a rename. Answer correct on the mechanism; slightly imprecise on whether new-column events ever flow (they do).
- **Postgres pgoutput sends no standalone DDL rename event, only WAL relation message on next DML**: Confirmed — pgoutput attaches relation messages inline with the next change event for the table; this matches resources/13 line 4073 and the Debezium PG connector documentation. Answer correct.
- **`ALTER TABLE ... RENAME COLUMN` is metadata-only in Postgres**: Confirmed via Crunchy Data and PostgreSQL docs — rename is a catalog-only change (system catalog entry update), no data file rewrite, brief `ACCESS EXCLUSIVE` lock. Answer doesn't state this explicitly but doesn't contradict it.
- **Iceberg supports `ALTER TABLE ... RENAME COLUMN` as metadata-only via column ID**: Confirmed via Apache Iceberg docs — Iceberg tracks columns by unique IDs; rename updates only the name in metadata, no file rewrite. Answer doesn't mention this native rename path (gap noted above) but the ADD+DROP path the answer recommends is also valid.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.491 across 112 questions → (4.491 × 112 + 4.56) / 113 = **4.492 across 113 questions**. Status: **PASSED**.

---

## Q2 — Time-travel snapshot storage cost

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Core mechanics correct and verified: snapshots hold data files alive even after they're "replaced"; compaction without expiry doubles disk because old + new files coexist; canonical 2-step sequence expire_snapshots → remove_orphan_files reclaims space; Trino's 7-day min-retention floor named correctly (`iceberg.expire-snapshots.min-retention`); Spark `CALL iceberg.system.expire_snapshots(table=>..., older_than=>..., retain_last=>...)` syntax VERIFIED correct; Trino `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold=>'30d')` syntax VERIFIED correct; `$snapshots` and `$files` metadata tables are real and the diagnostic queries are valid. Material weaknesses: (1) the "rough formula" `base_data_size × (1 + retention_days/100)` is a fabricated heuristic with no grounding — actual snapshot overhead is driven by UPDATE/DELETE/MERGE *frequency* and compaction activity, not by calendar days; for a "heavily updated table" the user described, 7 days could easily be 100%+ overhead, not 2%. The percentage table (7d: +2%, 30d: +30%, 90d: +90%) reads as quantitative guidance but is unsupported. (2) "Iceberg's default behavior is to keep every snapshot forever" — operationally true (no auto-expiry runs), but the Iceberg library default `history.expire.max-snapshot-age-ms` is 5 days as the eligibility threshold; phrasing is imprecise. (3) "Trino's 7-day minimum retention floor means you can't delete anything younger than 7 days, but there's no upper bound by default" conflates the floor with an "upper bound" concept that doesn't apply to this API. |
| Beginner clarity | 4.5 | Strong narrative: opens with the right anchor ("snapshots hold data files hostage"), explains compaction interaction in 4 numbered steps that map cleanly to MinIO usage growing → finally dropping. Tables digestible. Jargon (snapshot, manifest, orphan file) introduced with minimal assumption. The "Why Storage Grows After Compaction" subsection is the pedagogical highlight — a clear beginner-friendly causal chain. |
| Practical applicability | 3.5 | Diagnostic queries copy-pasteable; Spark + Trino syntax both shown; weekly schedule concrete. Gaps for the production stack (Trino 467 + Spark + MinIO): (1) does NOT mention that Trino 467's `ALTER TABLE ... EXECUTE remove_orphan_files` has NO `dry_run` parameter — only Spark supports `dry_run => true`; an engineer who copies the Trino command expecting a preview will not get one. Resources/17 explicitly calls this out. (2) does NOT mention that the 7-day floor applies to `remove_orphan_files` from Trino too, not just `expire_snapshots`. (3) "Recommended Schedule" uses Spark CALL syntax without specifying which engine the cron should run from — engineer must infer engine choice. (4) No mention of `iceberg.system.rollback_to_snapshot` as the safety net before running aggressive expiry. (5) No warning about the FIRST-run cost when a multi-month snapshot backlog gets expired — that initial `remove_orphan_files` sweep can be slow and IO-heavy on MinIO. |
| Completeness | 4.0 | All three sub-questions addressed: what's stored (snapshots + held-alive data files), how to estimate (diagnostic queries + formula), tradeoff of shortening retention (table). Missing nuance: (1) cost estimation should teach reasoning from *operation rate* (commits/day × avg file size × retention days), not calendar-day percentages; (2) snapshot-level metadata growth (manifest list files, manifest files) is conflated with data-file growth — manifest growth is small but for heavily-updated tables compounds; (3) no mention of `clean_expired_metadata => true` option (cleans unreferenced schemas/partition-specs alongside snapshots); (4) doesn't explain WHY heavy updates inflate storage faster (UPDATE in CoW mode rewrites files → old files held alive by snapshots → effective storage = files-per-day × retention-days). |
| **Average** | **4.00** | **PASS** |

### What Worked

- Anchors on the correct mechanism: "snapshots hold data files hostage" — accurate mental model
- Compaction causal chain laid out in the right order: compaction writes new files → snapshots still point to old files → expire_snapshots makes old files eligible → remove_orphan_files actually deletes them → MinIO drops. This is the clearest section.
- Both Spark CALL and Trino ALTER TABLE EXECUTE syntaxes shown; both verified correct against current docs
- Diagnostic queries against `$snapshots` and `$files` metadata tables are real and copy-pasteable
- "Verify Expiry Is Running" closing diagnostic (count snapshots; thousands → expiry isn't running) is concrete and actionable
- Correctly names the Trino config key `iceberg.expire-snapshots.min-retention` and the 7-day floor
- Production-fit framing: "On bare-metal MinIO: there's no per-GB cost beyond hardware, so the question is disk capacity" — matches `prod_info.md`
- Order of operations (compaction → expire → remove orphans) stated and reinforced

### What Missed

- **Fabricated cost formula.** `base_data_size × (1 + retention_days/100)` is not grounded in Iceberg mechanics. Real overhead scales with commit rate × avg file size × retention window. The percentage table (7d: +2%, 30d: +30%, 90d: +90%) reads as authoritative quantitative guidance but is unsupported. For a CoW table where 10% of rows update daily, every day's snapshot pins ~10% of the table; 30 days of retention easily exceeds 200% overhead, not 30%. The user explicitly said "heavily updated every day" — this is exactly the scenario where the formula understates the problem.
- **Trino `remove_orphan_files` has NO `dry_run` on Trino 467.** Only the Spark form supports dry_run. The "Always run `dry_run => true` first" advice is correct for the Spark example but an engineer who copies the Trino-equivalent will not get preview behavior. Resources/17 explicitly calls this out (line 79–80, 95–101); the answer should have surfaced it for the prod stack.
- **Trino 7-day floor applies to `remove_orphan_files` too**, not just `expire_snapshots`. The answer only mentions the floor for expire_snapshots.
- **"No upper bound by default" is misleading.** Iceberg's library `history.expire.max-snapshot-age-ms` defaults to 5 days as the *eligibility* threshold for expire_snapshots when it runs — the operational issue is that nothing auto-runs the procedure, not that there's no default age.
- **First-run cost not warned.** A team that's accumulated months of snapshots and runs `expire_snapshots` for the first time will trigger a large orphan-file sweep that can be slow and IO-heavy on MinIO. Worth a one-line operational warning.
- **No mention of `rollback_to_snapshot` as safety net** before aggressive expiry. If you expire to 7 days and discover a bug from day 10, you've lost the ability to recover via Iceberg time-travel.
- **Engine choice for scheduled job not specified.** The "WEEKLY maintenance job" code block uses Spark CALL syntax — should be explicit that on this stack the weekly job typically runs from Spark via Airflow / k8s CronJob, with Trino as the ad-hoc alternative.
- **Manifest-file vs data-file overhead not separated.** All overhead is attributed to data files; manifest list / manifest growth (small but non-trivial for heavily-updated tables) is invisible in the formula.

### Technical Accuracy (verified)

WebSearch verification against trino.io connector docs and Iceberg maintenance docs:

1. **Iceberg keeps all data files referenced by any live snapshot, even "replaced" files**: VERIFIED. Per Iceberg maintenance docs and Tabular cookbook, data files are reachable through any live snapshot; expire_snapshots removes metadata pointers and only then are orphaned data files eligible for cleanup.
2. **`expire_snapshots` + `remove_orphan_files` as canonical two-step**: VERIFIED. Standard pattern in Iceberg maintenance documentation. The answer's ordering (expire first, then remove orphans) is correct.
3. **Trino `iceberg.expire-snapshots.min-retention` default 7d**: VERIFIED against Trino 481 connector docs and Starburst Galaxy forum. The retention_threshold must be ≥ min-retention or the procedure fails with "Retention specified (X) is shorter than the minimum retention configured in the system (7.00d)". The answer's claim is accurate.
4. **Spark `CALL iceberg.system.expire_snapshots(table => '...', older_than => ..., retain_last => ...)`**: VERIFIED. Named-argument form with `table`, `older_than`, `retain_last` matches the Iceberg Spark procedures spec.
5. **Trino `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')`**: VERIFIED against trino.io/docs/current/connector/iceberg.html. The extended form `expire_snapshots(retention_threshold => '30d', retain_last => 10, clean_expired_metadata => true)` is also supported.

Unverified / partially incorrect:
- The percentage overhead table (7d: +2%, 30d: +30%, 90d: +90%) — not from any documentation; heuristics that vastly underestimate overhead for heavily-updated tables (exactly the user's scenario).
- "Iceberg's default behavior is to keep every snapshot forever" — operationally correct (no auto-expiry); technically there is a 5-day default `max-snapshot-age-ms` eligibility threshold when expire_snapshots is invoked.

### Rubric Update

- Storage sizing: prior avg 4.521 across 6 questions → (4.521 × 6 + 4.00) / 7 = (27.126 + 4.00) / 7 = 31.126 / 7 = **4.447 across 7 questions**. Status: **PASSED** (mild downward drift of 0.074 — formula fabrication and Trino-467 prod-fit gaps pulled the score down).

---

## Iter 321 Summary

**Iter 321 average: (4.56 + 4.00) / 2 = 4.28 — PASS** ✓

### Notable
- Q1 4.56: Column rename detection in CDC — correctly framed pgoutput sending no DDL rename event and Debezium learning via WAL relation message; expand/contract pattern + repair recipe both runnable; minor lead-in overstates "new column name never appears" and misses Iceberg native `RENAME COLUMN` alternative
- Q2 4.00: Time-travel snapshot storage cost — correct anchor (snapshots hold data files hostage), correct Spark+Trino syntax, correct expire→remove-orphans ordering; cost estimation formula is a fabricated calendar-day-percentage heuristic that understates overhead for the user's heavily-updated scenario; Trino 467 prod-fit gaps (no `dry_run` in Trino's `remove_orphan_files`, floor applies to BOTH procedures, engine choice for scheduled job unstated); missing `rollback_to_snapshot` safety-net mention and first-run cost warning

### Resource fixes applied this iteration
1. **resources/11-lakehouse-storage-sizing.md** — Replaced fabricated calendar-day-percentage formula with commit-rate-based estimator (`snapshot_overhead ≈ daily_rewritten_volume × retention_days`); worked example: 500 GB CoW table with 10% daily UPDATE rate → 50 GB/day rewritten → 1.5 TB overhead at 30-day retention (300%, not 30%); Trino `remove_orphan_files` has NO `dry_run` parameter (Spark-only); `rollback_to_snapshot` safety net before aggressive expiry; first-run cost warning for multi-month backlogs; 7-day floor applies to BOTH `expire_snapshots` AND `remove_orphan_files`
2. **resources/13-postgres-to-iceberg-ingestion.md** — Corrected "new column name never appears" framing: Debezium DOES emit events with new column name once WAL RELATION message arrives on next DML; silence is downstream (Iceberg table missing column or Spark consumer referencing old name); added Iceberg native `ALTER TABLE ... RENAME COLUMN` as metadata-only preferred repair (preserves column ID, works in Spark and Trino); added three downstream failure mode diagnostic ladder

### Suggested focus for Iter 322
- **Storage sizing** (4.447/7 after Q2 — slight downward drift): probe the *quantitative* cost-estimation angle — commit-rate × file-size × retention-window framing instead of calendar-day percentages. Resources/11 should add a worked example showing how a heavily-updated CoW table accumulates per-day snapshot overhead from UPDATE/MERGE activity, and explicitly call out that "heavily updated" can mean 100–300% overhead at 30-day retention, not 30%.
- **Iceberg table maintenance** (4.655/20): probe Trino 467-specific gaps surfaced by Q2 — no `dry_run` in Trino's `remove_orphan_files`, 7-day floor enforcement on BOTH procedures, `clean_expired_metadata` parameter, first-run cost on a multi-month backlog, `rollback_to_snapshot` as pre-expiry safety net. Resources/17 covers these but the responder didn't surface them from /11.
- **Postgres-to-Iceberg ingestion** (4.492/113): continue probing CDC edge cases — column rename was Q1; next angle could be JSONB column type evolution, composite primary key handling in Debezium, or `replica identity` impact on UPDATE/DELETE event completeness.
- **Multi-tenant analytics** (4.480/119): probe `opa.policy.cache-ttl-seconds` revocation latency tradeoff (cache hit rate vs how long a revoked tenant retains access).
