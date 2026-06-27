# Iter1172 — Judge Feedback

## Verdict: FIX-A — Average 3.625 / 5.0 — TWO LOAD-BEARING DEFECTS (Q2 + Q3)

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 `map_filter((k,v)->predicate)` returns smaller MAP without UNNEST | SQL query best practices for OLAP | 5.0 | pin-perfect; one-line canonical |
| Q2 HAVING ratio `reopened/total > 0.5` — INTEGER DIVISION BUG | SQL query best practices for OLAP | 2.5 | **DEFECT — answer SQL silently returns wrong rows; classification = ONE-OFF RESPONDER SLIP** |
| Q3 GDPR purge `DELETE WHERE event_date < cutoff` — WRONG PREMISE + WRONG `expire_snapshots` PARAM | Iceberg table maintenance | 2.625 | **DEFECT — falsely agreed delete files pile up; over-engineered Spark step; wrong param syntax; classification = LIGHT FIX-A (findability gap)** |
| Q4 `UPPER(email)` sargability + Iceberg/Trino equivalents | SQL query best practices for OLAP / Query performance basics | 4.375 | mostly correct; normalize-at-write canonical reached; minor framing shave on partition-pruning phrasing |

Iter average = (5.0 + 2.5 + 2.625 + 4.375) / 4 = **3.625** — just above the 3.5 pass threshold but with two load-bearing technical-accuracy fails. Recommending **LIGHT FIX-A on r17 partition-aligned-DELETE findability**; Q2 stays NO-OP+WATCH per the `feedback_responder_broken_secondary_alternative` pattern.

---

## Q1 — map_filter (STRONG PASS 5.0)

Responder answer: `map_filter(feature_scores, (k, v) -> v > threshold)`.

Verified against [trino.io/docs/467/functions/map.html](https://trino.io/docs/467/functions/map.html): `map_filter(map(K, V), function(K, V, boolean)) -> map(K, V)` — *"Constructs a map from those entries of map for which function returns true"*. Signature, return type, lambda form all match. The "one row in, one row out, no UNNEST + MAP_AGG rebuild" framing is the correct mental model. r09 citation aligned.

No issues. Pass.

---

## Q2 — HAVING ratio with INTEGER-DIVISION BUG (FAIL 2.5)

### The defect (verified)

Responder's HAVING clause as written:
```sql
HAVING COUNT(CASE WHEN was_reopened THEN 1 END) / COUNT(*) > 0.5
```

`COUNT(...)` returns `BIGINT` in Trino 467. Per [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) operator table: *"Division (integer division performs truncation)"*. So `BIGINT / BIGINT` truncates toward zero — `3 / 5 = 0`, NOT `0.6`. The HAVING expression is `0 > 0.5` (FALSE) for any account that is NOT 100% reopened, and `1 > 0.5` (TRUE) only when ALL tickets are reopened (ratio exactly 1).

**Effect**: the responder's SQL silently returns ONLY accounts with `reopened_count == total_tickets`, not accounts with majority (> half) reopens. This is a silent-wrong correctness bug — engineer gets a result set that looks plausible but is filtered far too aggressively.

### Correct forms (any one is fine)
```sql
-- decimal coercion
HAVING COUNT(CASE WHEN was_reopened THEN 1 END) * 1.0 / COUNT(*) > 0.5
-- explicit CAST
HAVING CAST(COUNT(CASE WHEN was_reopened THEN 1 END) AS DOUBLE) / COUNT(*) > 0.5
-- integer-safe rearrangement (preferred for exact arithmetic)
HAVING COUNT(CASE WHEN was_reopened THEN 1 END) * 2 > COUNT(*)
```

### What the responder got RIGHT
- HAVING accepts aggregate expressions combined arithmetically — correct, no need for an outer query.
- Must repeat the aggregate expression in HAVING (not the SELECT alias) — correct per Trino's logical evaluation order.

### Resource coverage check (NOT a resource defect)

The integer-division trap is **already extensively documented** in resources:
- `resources/07-analytical-query-patterns.md:1824` — *"`revenue / SUM(...)` on two integers does integer division (truncates to 0). Multiply by the DECIMAL literal `100.0` (or `CAST` the numerator) so the division is done in floating/decimal — see resource 23 §3 integer-division trap"*
- `resources/07-analytical-query-patterns.md:3510` — *"**`* 1.0`** forces decimal division. Without it, `SUM(amount) / NULLIF(SUM(amount), 0)` on two integer/bigint values does integer division and the ratio truncates to 0..."*
- `resources/07-analytical-query-patterns.md:3585` — DO-NOT-WRITE row explicitly flagging the omission as SILENT-WRONG with worked example
- `resources/23-sql-best-practices-olap.md:988` — *"Weighted average — `SUM(value * weight) / SUM(weight)` — FORCE non-integer division or the mean TRUNCATES"*

The canonical IS findable, IS load-bearing, and the responder applies it correctly in the percent-of-total / YoY-ratio / cohort-retention canonicals across many prior iterations. This is a one-off recall slip on a HAVING-specific phrasing where the integer-division trap didn't fire as a recall keyword.

### Classification: ONE-OFF RESPONDER SLIP — NO-OP + WATCH

Matches the `feedback_responder_broken_secondary_alternative.md` pattern (responder occasionally drops a load-bearing safety even when the resource warns) and the `feedback_responder_overwarning_folklore.md` ceiling. No single resource fix would catch this without churning a row that already says it correctly multiple times. Add to next-sweep watch: re-probe HAVING ratio-style aggregation on a different scenario (e.g., conversion-rate, attach-rate, refund-rate); expect the responder to land `*1.0` consistently. If misses on the re-probe, then consider a HAVING-anchored cross-ref card in r07/r23.

---

## Q3 — Partition-aligned DELETE on Iceberg (FAIL 2.625) — LIGHT FIX-A

### Defect 1: WRONG PREMISE — agreed with coworker that "delete files pile up"

Responder said: *"On format-v2 each DELETE produces position-delete files that pile up"* and *"DELETE FROM events WHERE event_date < DATE '2026-03-27' creates position-delete files"*. **Both claims are FALSE** for the engineer's exact query — `event_date` is the day-partition identity column.

Verified against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): *"For partitioned tables, the Iceberg connector supports the deletion of entire partitions if the WHERE clause specifies filters only on the identity-transformed partitioning columns."* This is a **metadata-only operation** — drops whole partitions' data-file references from the new snapshot's manifest list, writes **ZERO position-delete files**.

Position-delete files are written ONLY for row-level deletes whose WHERE clause filters on non-partition columns (e.g., `DELETE FROM events WHERE user_id = 42`), where Iceberg can't drop whole data files because surviving rows in the same file must be preserved.

So:
- `DELETE FROM events WHERE event_date < DATE '2026-03-27'` (partition column only) — **metadata-only**, fast, no delete files
- `DELETE FROM events WHERE user_id = 42` (non-partition column) — **row-level**, writes position-delete files on v2 MoR tables

The coworker's premise was wrong; the responder reinforced it.

### Defect 2: Unnecessary Spark step

Responder recommended `CALL iceberg.system.rewrite_position_delete_files(table=>'analytics.events')` as Step 1. **This is unnecessary** because the partition-aligned DELETE never wrote any position-delete files to compact. The procedure is a no-op (or skip) on this table. Responder is solving a problem the engineer doesn't have.

### Defect 3: WRONG `expire_snapshots` parameter syntax

Responder wrote:
```sql
ALTER TABLE events EXECUTE expire_snapshots(retention_duration => INTERVAL '7' DAY)
```

The **correct Trino 467 form** per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) and verified at `resources/17-iceberg-table-maintenance.md:59, 164, 188, 190, 210` (cited at least 5 times in r17):
```sql
ALTER TABLE iceberg.<schema>.events EXECUTE expire_snapshots(retention_threshold => '7d')
```

Parameter name is `retention_threshold` (NOT `retention_duration`), and value is a **VARCHAR duration literal** like `'7d'` (NOT `INTERVAL '7' DAY`). Running the responder's form on Trino 467 fails with an unknown-procedure-argument error.

### Defect 4: "No single partition drop command" is misleading

Responder said *"There is NO single partition drop command in Trino 467."* Technically true — Trino 467 has no `ALTER TABLE ... DROP PARTITION` DDL — but the framing buries the operational reality: **the partition-aligned `DELETE` IS the bulk partition drop on Iceberg**. It's metadata-only, atomic, and drops whole partitions in one snapshot commit. Telling an engineer "no single command exists" implies they're stuck cleaning up small pieces, when actually the DELETE they're already running IS the canonical solution.

### Correct minimal answer

```sql
-- Step 1 — Drop the partition data (metadata-only, atomic, no delete files written).
DELETE FROM iceberg.analytics.events WHERE event_date < DATE '2026-03-27';

-- Step 2 — Reclaim physical storage on MinIO by expiring old snapshots
-- that still reference the dropped data files.
ALTER TABLE iceberg.analytics.events
  EXECUTE expire_snapshots(retention_threshold => '7d');
```

That's it. Two statements, both Trino-native, no Spark hop, no position-delete-file compaction needed. (If GDPR sub-7-day urgency, drop to Spark or lower `iceberg.expire-snapshots.min-retention` per r17 §59 / §187.)

### Resource coverage check — FINDABILITY GAP

The canonical IS in `resources/17-iceberg-table-maintenance.md:162` (4th bullet of the "clear / empty an Iceberg table" leading canonical):

> *"Position-delete files are written ONLY for PARTIAL row-level deletes... NOT for whole-table or whole-partition deletes. Partition-only deletes (WHERE filters only on identity-transformed partition columns) are also metadata-only per Trino docs."*

But the **section header** is keyword-magnet for "clear / empty whole table" — NOT for the engineer's actual framing of *"GDPR purge of activity older than 90 days"*, *"DELETE WHERE event_date < cutoff"*, *"delete files pile up"*. The partition-aligned case is a parenthetical inside a whole-table-DELETE canonical.

### Classification: LIGHT FIX-A — findability card in r17

**Recommend** the teacher add a keyword-magnet card in `resources/17-iceberg-table-maintenance.md` (probably as a new LEADING CANONICAL near the existing whole-table card or in the myth-buster matrix) with these keyword anchors so the next "GDPR purge old partitions / delete files pile up / partition-aligned DELETE" question routes correctly:

**Keyword anchors to add:** GDPR purge old partitions, data retention purge, delete activity older than N days, DELETE WHERE event_date < cutoff, drop old day partitions in bulk, delete files pile up, position delete files accumulating, partition-aligned DELETE metadata-only, no DROP PARTITION on Trino Iceberg, bulk partition drop equivalent, retention-based partition deletion.

**Load-bearing facts to surface:**
1. `DELETE FROM tbl WHERE <identity_partition_column> < cutoff` is **metadata-only** on Iceberg — no position-delete files written, drops data-file references atomically in one snapshot.
2. Data bytes on MinIO persist until `expire_snapshots` drops the older snapshots that still reference them.
3. **Correct syntax:** `ALTER TABLE iceberg.<schema>.<table> EXECUTE expire_snapshots(retention_threshold => '7d')` (VARCHAR `'7d'`, NOT `INTERVAL '7' DAY`; param name is `retention_threshold`, NOT `retention_duration`).
4. `rewrite_position_delete_files` is NOT needed here — no position-delete files exist to compact.

**Defang (DO-NOT-WRITE):** "DELETE on partitioned Iceberg always writes position-delete files" (FALSE for identity-partition-aligned WHERE); "`expire_snapshots(retention_duration => INTERVAL '7' DAY)`" (FALSE — param name and type both wrong); "must run Spark `rewrite_position_delete_files` after every DELETE" (FALSE for partition-aligned DELETE).

The wrong-parameter-syntax slip (Defect 3) is partly responder hallucination — the canonical syntax IS in r17 in 5+ places. But pairing it with the partition-aligned-DELETE findability gap into ONE keyword-magnet card serves both defects: a single anchor block titled around "delete old partitions for GDPR" naturally co-locates the correct DELETE + correct expire_snapshots syntax.

**Watch label:** `r17 partition-aligned-DELETE GDPR-purge keyword card iter1172`, re-probe next sweep with a "delete activity older than N days" / "drop old monthly partitions" framing; expect responder to land on `retention_threshold => '7d'` + no-spark-step + no-position-delete-files framing.

---

## Q4 — UPPER(email) sargability (PASS 4.375)

Responder reached the load-bearing canonical: **normalize email at WRITE time** (dbt/Spark/app), then query the bare column. Matches `resources/23-sql-best-practices-olap.md:2562` directly: *"`WHERE LOWER(email) = 'me@x.com'` → Store email lowercased at ingest, then `WHERE email = 'me@x.com'`"*.

Three supplementary mitigations also reasonable:
1. Partition layout — generally not relevant if email isn't a partition column; framing as "DOES defeat partition pruning" overstates this. UPPER on a non-partition column doesn't affect partition pruning; it breaks **file-level min/max stat pruning** on the email column.
2. `sorted_by` + `EXECUTE optimize` for Parquet min/max file-skip — correct mechanism, but only helps if the normalized form is queried.
3. **Parquet bloom filters** framing: *"Iceberg writes them, Trino checks at scan time"* — accurate framing. Doesn't repeat the iter1160 pin-imprecision because the responder didn't claim Trino-side DDL syntax. Verified that Trino 467 docs DO list `parquet_bloom_filter_columns` as a valid CREATE TABLE property at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (the iter1160 pin's "469+" was about the `SET PROPERTIES` ALTER form per PR #24573, not CREATE TABLE — pin is slightly over-broad but not load-bearing for this Q4).

Minor shave (-0.5 on Technical): "does NOT auto-scan the whole table but DOES defeat partition pruning" conflates partition pruning with file-level min/max pruning. For a non-partition column like `email`, `UPPER(email)` breaks file-level min/max pruning on email's Parquet stats, but doesn't affect partition pruning at all. The correct framing is *"breaks file-level min/max pruning on email's column stats; pruning on other (partition) columns still works"*. Engineer still arrives at right action (normalize at write time), so the shave is small.

No FIX-A. r23 §2562 canonical and r28 sargability canonical both routed correctly.

---

## Summary — what's open after iter1172

| Item | Type | Owner | Next step |
|---|---|---|---|
| Q2 HAVING `*1.0` recall slip | One-off responder slip | Watch only | Re-probe HAVING-ratio on a different scenario next sweep (conversion / attach / refund). NO resource fix. |
| Q3 r17 partition-aligned-DELETE GDPR-purge findability card | LIGHT FIX-A | Teacher | Add keyword-magnet card in r17 covering: partition-aligned DELETE = metadata-only, `retention_threshold => '7d'` (not `retention_duration => INTERVAL '7' DAY`), no `rewrite_position_delete_files` needed for partition-aligned DELETE. Watch label `r17 partition-aligned-DELETE GDPR-purge keyword card iter1172`. |
| Q4 partition-pruning vs file-level-pruning framing | Recall ceiling | — | NO-OP. Engineer reaches right answer; rephrasing nuance is recall noise, not a resource defect. |

No new pins to add; no existing pin invalidated.
