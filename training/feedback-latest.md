# Judge Feedback — Iter 404 (EXTENDED PHASE)

**Overall: 4.6875 STRONG PASS** (Q1 4.75 + Q2 4.75 + Q3 4.5 + Q4 4.75)

This iteration probed exactly the four gaps iter403 flagged. **All four landed cleanly.** Highest score since iter400 (4.59375). Teacher's iter404 resource additions closed the gaps the judge called out.

---

## Q1 — NOT IN returns zero rows (3VL + NOT EXISTS)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What went well
- **3VL framing crisp**: TRUE/FALSE/UNKNOWN named explicitly. A single NULL in `blocked_tenants` makes every NOT IN comparison evaluate to UNKNOWN, WHERE filters out UNKNOWN → zero rows. This is the canonical mental model and the responder nailed it.
- **Two fixes ranked**: Fix A `NOT EXISTS` recommended because it decorrelates to an anti-join (Trino's optimizer handles this) and NULLs in the right side are ignored. Fix B `IS NOT NULL` filter in subquery labeled "fragile" — accurate, because one missed NULL re-breaks the query.
- **Bottom-line rule**: "Never use NOT IN with a nullable column" is the actionable rule the engineer needs.

### Minor gaps
- Could mention `EXCEPT` as a third option (set-difference semantics, also NULL-safe).
- Did not contrast NOT IN with non-nullable column (which IS safe).

### Verdict
Closes the iter403 NOT IN NULL gap completely. Strong PASS.

---

## Q2 — $partitions on bucket-transformed table (pivot to GROUP BY)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What went well
- **Bucket integer vs UUID**: Correctly explained that bucket transform stores the bucket integer (0 to N-1) in manifests, NOT the original tenant UUID. $partitions reflects manifests, so it shows integers.
- **Hash collision irreversibility**: Multiple tenants share a bucket (by design). UUID cannot be recovered from the bucket integer. This is the key insight that closes the gap.
- **Two-option pivot**: (1) identity partition → metadata-only direct answer (no scan); (2) bucket-partitioned → must scan via `GROUP BY tenant_id` (Trino uses min/max stats to prune files but count requires reading the tenant_id column). The pivot to GROUP BY is exactly what iter403 flagged as missing.
- **Trade-off framing**: "bucket = even write distribution but loses metadata-only per-tenant queries" is the right ops mental model.

### Minor gaps
- Could mention `$files` as an inspection alternative (per-file partition + column stats) when $partitions aggregation isn't sufficient.
- Did not contextualize the broader metadata-tables ecosystem (cheat sheet still missing).

### Verdict
Closes the iter403 bucket-pivot gap completely. Strong PASS.

---

## Q3 — EXPLAIN shows CorrelatedJoin not SemiJoin (failed-decorrelation remediation)

**Scores: 4.5 / 4.0 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What went well
- **Named the rule**: Decorrelate Subqueries failed (correct — this is the rule sibling of Semi-Join Decorrelation).
- **Why it's expensive**: Subquery executes once per outer row (O(n*m)). Beginner needs to understand WHY CorrelatedJoin is bad, not just that it is.
- **First diagnostic step**: Run ANALYZE / SHOW STATS first. CBO bails conservatively without row-count stats — this is verified Trino behavior and exactly the right first move before manual rewrite.
- **Manual rewrite pattern**: `LEFT JOIN (SELECT DISTINCT...) ... WHERE IS NULL` is the canonical anti-join pattern. The **DISTINCT critical to avoid duplicate rows** callout is the gotcha most beginners miss (right-side duplicates cause JOIN row inflation; SemiJoin dedupes implicitly, manual LEFT JOIN does not).
- **EXPLAIN lookup**: SemiJoin = optimal, InnerJoin = check for dups, CorrelatedJoin = ANALYZE then rewrite. Three-row decision matrix is exactly the runbook.

### Minor gaps
- "Anti-join" terminology not glossed for the zero-OLAP-background beginner. A one-line "anti-join = rows from left that have NO match in right" would tighten clarity.
- No worked example showing input SQL → CorrelatedJoin plan → rewritten LEFT JOIN SQL → SemiJoin-equivalent plan. The pattern is described but not demonstrated end-to-end.

### Verdict
Closes the iter403 CorrelatedJoin remediation gap. Strong PASS with room to add a worked example.

---

## Q4 — DROP COLUMN 3 weeks ago, MinIO usage didn't drop

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What went well
- **Root cause**: Iceberg files are immutable. DROP COLUMN creates a new snapshot without the column in the schema, but old Parquet files (still referenced by prior snapshots) keep the column bytes. Verified against Iceberg docs.
- **Three-step sequence**: (1) optimize compaction (optional), (2) `expire_snapshots(7d)` — labeled as the critical step that actually reclaims, (3) `remove_orphan_files(7d)` sweep. Order matches Iceberg maintenance docs (expire → orphan cleanup).
- **The subtle correct framing**: "Old files are NOT orphans yet — they are referenced by snapshots kept for time-travel." This is the precise distinction that prevents beginners from incorrectly reaching for `remove_orphan_files` alone (which would do nothing because the files aren't yet orphans).
- **Common-mistake callout**: "Assuming compaction alone drops storage" names the failure mode iter402 left open. This is the operational gotcha.

### Minor gaps
- Did not show literal Trino 467 syntax: `ALTER TABLE catalog.schema.table EXECUTE expire_snapshots(retention_threshold => '7d')`. Engineer has to look up syntax.
- Did not mention the partition-column DROP edge case (cannot drop a partition column without spec migration).
- Did not mention column-name reuse risk (field IDs are immutable; reusing the dropped name with a different field ID is the schema-evolution footgun).

### Verdict
Closes the iter402 + iter403 DROP COLUMN reclaim carry-forward completely. Strong PASS.

---

## Pattern across all four answers

| Q | Score | Gap closed |
|---|---|---|
| Q1 | 4.75 | NOT IN NULL gotcha (iter403 flag) |
| Q2 | 4.75 | $partitions bucket-pivot (iter403 flag) |
| Q3 | 4.5 | CorrelatedJoin remediation (iter403 flag) |
| Q4 | 4.75 | DROP COLUMN reclaim (iter402 carry-forward) |

**Average 4.6875** — highest since iter400. All four iter403 probe targets landed. The pattern of "judge flags gap → teacher adds resource → next iteration scores well" is working this round.

Trajectory iter394-404: `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/**4.6875P**`. The oscillation between mid-4 PASS and mid-3 FAIL every 4-6 iterations may finally be breaking — but we need 2-3 more iterations to confirm durability.

---

## Teacher actions next (iter 405)

1. **LOW polish** — Add literal Trino 467 syntax snippets to the DROP COLUMN reclaim resource:
   - `ALTER TABLE catalog.schema.table EXECUTE optimize`
   - `ALTER TABLE catalog.schema.table EXECUTE expire_snapshots(retention_threshold => '7d')`
   - `ALTER TABLE catalog.schema.table EXECUTE remove_orphan_files(retention_threshold => '7d')`
2. **LOW polish** — Gloss "anti-join" in the correlated-subquery / NOT IN resource for beginner clarity: "anti-join = return rows from the left side that have NO matching row on the right side."
3. **LOW** — Add a worked correlated EXISTS rewrite example to the CorrelatedJoin remediation resource: input SQL → CorrelatedJoin EXPLAIN snippet → manual LEFT JOIN + IS NULL rewrite → SemiJoin-equivalent EXPLAIN snippet. End-to-end before/after.
4. **LOW** — Iceberg metadata tables cheat sheet ($snapshots / $manifests / $partitions / $files / $history / $refs / $properties — one-line "use for X" per table). Still missing from resources after iter403 flagged it.
5. **LOW carry-forward backlog** unchanged: dbt-trino merge dups, predicate-pushdown JDBC rewrite, CoW vs MoR write.merge.mode, write.isolation-level, SHOW SESSION catalog-prefix, HMS->Nessie no-downtime, SPILL_FAILED 60GB cap, MERGE rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO/VALIDATE, result caching 2nd, Iceberg branches fast_forward, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd, fs.cache 3rd JMX, bucket(tenant_id) 3rd-angle, PERCENT_RANK/NTILE 3rd, RANGE INTERVAL gap-day.

## Judge probe targets next (iter 405)

1. **Iceberg metadata tables cheat sheet 2nd-angle** — "what's the difference between $snapshots, $manifests, $files — when do I use each?" — probes the cheat-sheet gap iter403 flagged that the teacher has not yet landed.
2. **NOT EXISTS performance follow-up** — "I switched NOT IN to NOT EXISTS but my query got slower — what gives?" — probes anti-join executor cost + when NOT IN with a non-nullable column is actually fine. Natural second-angle on the iter404 Q1 win.
3. **Partition spec migration** — "I want to change PARTITIONED BY day(ts) to PARTITIONED BY day(ts), tenant_id without rebuilding the table" — probes Iceberg partition spec evolution + how `rewrite_data_files` handles the new spec. Carry-forward from backlog.
4. **CoW vs MoR `write.merge.mode` 3rd-angle** — "MERGE INTO is rewriting 80GB per run on a 200GB table — how do I switch to row-level deletes?" — carry from iter400-402.
5. Carry-forward backlog rotation as needed.
