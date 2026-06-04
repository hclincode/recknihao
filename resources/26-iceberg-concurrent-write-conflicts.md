# 26 — Iceberg Concurrent Write Conflicts: serializable vs snapshot, retries, false positives

> **One-sentence summary:** Iceberg uses **optimistic concurrency** for writes — each writer plans against a snapshot, then atomically swaps the table's current-snapshot pointer; concurrent writers race and the losers either auto-retry or fail with `CommitFailedException`. The `write.delete.isolation-level` / `write.update.isolation-level` / `write.merge.isolation-level` properties (Iceberg 1.5.2) control how aggressively the loser is told "your write conflicts." This resource is the discovery-friendly entry point for *concurrent MERGE/UPDATE/DELETE conflicts on disjoint partitions* — the most common false-positive scenario engineers hit on the production stack (Spark 3.5 + Iceberg 1.5.2 + HMS + Trino 467). **Verified against [Iceberg IsolationLevel javadoc](https://iceberg.apache.org/javadoc/1.7.1/org/apache/iceberg/IsolationLevel.html), [Iceberg Reliability docs](https://iceberg.apache.org/docs/latest/reliability/), and [Iceberg table configuration docs](https://iceberg.apache.org/docs/latest/configuration/).**

> **Cross-reference index** (so this content is findable from every natural starting point):
> - From `resources/13-postgres-to-iceberg-ingestion.md` § overwritePartitions/MERGE INTO → see this resource for conflict semantics.
> - From `resources/17-iceberg-table-maintenance.md` § write.isolation-level → see this resource for the dedicated treatment.
> - From `resources/10-lakehouse-partitioning.md` (snapshot isolation mentions) → see this resource for the writer-side conflict model.
> - From `resources/22-trino-federation-postgresql.md`, `resources/05-multi-tenant-analytics.md` (concurrency mentions) → see this resource.

---

## 1. The optimistic concurrency model in one paragraph

Iceberg writes work like Git commits:

1. The writer reads the current table snapshot pointer (e.g., `snap-abc123`).
2. The writer plans its work against `snap-abc123` — figures out which data files to add, which to delete, which to update.
3. The writer writes new Parquet data files and new metadata files to MinIO.
4. The writer **attempts to atomically swap** the table's current-snapshot pointer from `snap-abc123` to a new snapshot `snap-def456`. This is the **commit**.
5. **If the table's current pointer is still `snap-abc123`, the swap succeeds.** Writer wins.
6. **If the table's current pointer has moved on to `snap-xyz789` (another writer committed first), the swap fails.** Writer either retries (re-plan against `snap-xyz789`) or fails with `CommitFailedException`.

This is **optimistic** because writers don't take locks up front — they assume nothing else is happening and only check at the commit step. When two writers race, the first wins and the second has to either redo its work or fail.

The question `write.*.isolation-level` answers: **for `UPDATE` / `DELETE` / `MERGE INTO`, how strict is "another writer committed first" defined?**

---

## 2. Serializable vs snapshot — the two isolation levels

Iceberg defines exactly **two** isolation levels for `UPDATE` / `DELETE` / `MERGE INTO`:

| Level | When the second writer FAILS | Default? |
|---|---|---|
| **`serializable`** | If another concurrent commit added a new data file that **MIGHT contain rows matching your UPDATE/DELETE/MERGE WHERE clause** — even if you can't prove the rows actually matched. The check is at the **manifest level**, not the row level. | Yes (Iceberg default) |
| **`snapshot`** | Only if your UPDATE/DELETE/MERGE actually touches a row that was also modified or deleted by a concurrent commit. **New rows added by other writers don't conflict, even if they match your WHERE clause.** | No (opt-in) |

> **Verbatim from the [Iceberg 1.5.2 IsolationLevel javadoc](https://iceberg.apache.org/javadoc/1.5.2/org/apache/iceberg/IsolationLevel.html):** *"The serializable isolation level guarantees that an ongoing UPDATE/DELETE/MERGE operation fails if a concurrent transaction commits a new file that might contain rows matching the condition used in UPDATE/DELETE/MERGE. For example, if there is an ongoing update on a subset of rows and a concurrent transaction adds a new file with records that potentially match the update condition, the update operation must fail under the serializable isolation but can still commit under the snapshot isolation."* The javadoc class-level description also confirms: *"Both of them provide a read consistent view of the table to all operations and allow readers to see only already committed data"* — i.e., readers are snapshot-isolated under both levels; the writer-side knob is what differs.

The serializable check is conservative: Iceberg uses the partition spec + the column min/max stats stored in manifest files to decide if a newly-added file *could* contain rows matching your predicate. If it can't prove the answer is no, it conservatively says yes, conflict, fail. This is where false positives come from.

**`snapshot` isolation is weaker but practically useful**: it accepts a phantom-row anomaly (a row inserted by writer A may not be visible to writer B's WHERE filter even though B logically should have updated it) in exchange for much higher concurrent-write throughput. For most append-mostly fact tables in SaaS analytics, the phantom-row risk is acceptable because the next ingestion cycle will catch any drift.

**Plain reader-side guarantee is unchanged.** Both isolation levels give readers full snapshot isolation: a query started at snapshot S sees the table exactly as it was at S, regardless of how many writers committed after S. The isolation level here is a **writer-side conflict detection knob**, not a reader consistency knob.

---

## 3. The disjoint-partition MERGE false-positive scenario (the most common pain point)

This is the scenario behind 80% of "my MERGE keeps failing with `ValidationException: Found conflicting files`" production tickets.

**Setup.** Two jobs run at the same time against `iceberg.analytics.orders` (partitioned by `order_date`):

- **Job A** (nightly Spark backfill): `INSERT INTO orders` appending 5M new rows for `order_date = '2026-05-29'`. **Append-only — modifies one partition.**
- **Job B** (analyst correction running via Trino): `UPDATE orders SET amount = amount * 1.10 WHERE tenant_id = 'acme' AND order_date < '2026-05-29'`. **Modifies rows in older partitions, never touches May 29.**

**The two jobs target disjoint partitions.** No row is touched by both jobs.

Under **`serializable`** (the default):
- Job B reads the table at snapshot S1.
- Job A commits a new snapshot S2 between Job B's read and Job B's commit attempt.
- Job B tries to commit. Iceberg walks the manifest changes between S1 and S2, sees a new data file added by Job A, and asks: *"could this new file contain rows matching `tenant_id = 'acme' AND order_date < '2026-05-29'`?"*
- The partition spec says the new file is in `order_date = '2026-05-29'`, which is NOT in `< '2026-05-29'`. **A well-implemented serializable check should be able to prove this is disjoint and let Job B commit.** But in practice the check is conservative — if `tenant_id` is not the partition column, Iceberg falls back to manifest-level min/max stats for `tenant_id`, which may overlap with `'acme'`, and the check fails.
- **Result: Job B fails with `ValidationException: Found conflicting files`.** Even though no row was actually touched by both jobs.

Under **`snapshot`**:
- Same setup. Job B's commit attempt succeeds because Iceberg only checks whether Job A's commit *modified or deleted* any of the rows Job B is touching. Job A appended new rows; Job B is updating old rows; no row-level overlap; commit succeeds.

**This is the canonical false-positive scenario.** The conflict isn't real — no row is touched by both writers — but `serializable` conservatively rejects it.

---

## 4. The three properties — there is NO global `write.isolation-level`

A common documentation footgun: some older blog posts reference a global `write.isolation-level` property. **It does not exist.** Iceberg exposes the isolation level **per operation**:

| Property | Controls | Default |
|---|---|---|
| `write.delete.isolation-level` | `DELETE` statements | `serializable` |
| `write.update.isolation-level` | `UPDATE` statements | `serializable` |
| `write.merge.isolation-level` | `MERGE INTO` statements | `serializable` |

**Set all three to the same value** if you want consistent behavior. A common mistake is setting only `write.merge.isolation-level` to `snapshot` and being surprised when a concurrent `DELETE` still fails.

### How to set them

**Trino 467 (ALTER TABLE):**
```sql
ALTER TABLE iceberg.analytics.orders
SET PROPERTIES "write.delete.isolation-level" = 'snapshot',
               "write.update.isolation-level" = 'snapshot',
               "write.merge.isolation-level" = 'snapshot';
```

**Spark (TBLPROPERTIES):**
```sql
ALTER TABLE iceberg.analytics.orders
SET TBLPROPERTIES (
  'write.delete.isolation-level' = 'snapshot',
  'write.update.isolation-level' = 'snapshot',
  'write.merge.isolation-level' = 'snapshot'
);
```

**Verify the effective value** with the Iceberg `$properties` metadata table (Trino 467):
```sql
SELECT key, value
FROM iceberg.analytics."orders$properties"
WHERE key LIKE 'write.%.isolation-level';
-- Expect three rows: write.delete.isolation-level, write.update.isolation-level, write.merge.isolation-level
```

If a row is absent from `$properties`, the table is using the Iceberg default (`serializable`).

---

## 5. Retry behavior — `commit.retry.num-retries` is the second knob

Even under `serializable`, Iceberg can **transparently retry** a write that hits a conflict, as long as the retry produces the same logical result (re-plan against the new snapshot, re-attempt the commit). Three properties control this:

| Property | Default (Iceberg 1.5.2) | What it does |
|---|---|---|
| `commit.retry.num-retries` | `4` | Number of times Iceberg retries a write after a conflict before raising `CommitFailedException`. |
| `commit.retry.min-wait-ms` | `100` | Initial backoff between retries (exponential — doubles each attempt). |
| `commit.retry.max-wait-ms` | `60000` (1 minute) | Cap on the per-retry backoff. |
| `commit.retry.total-timeout-ms` | `1800000` (30 minutes) | Total time budget across all retries. After this, fail regardless of how many retries are left. |

**Interpreting failures:**
- `org.apache.iceberg.exceptions.ValidationException: Found conflicting files that can contain records matching <expression>` during the operation → the planner detected a conflict before commit; retried automatically up to `commit.retry.num-retries` times; final attempt also conflicted. The `<expression>` placeholder is the actual WHERE-clause expression Iceberg validated against the concurrent file's manifest min/max stats — useful for spotting which predicate caused the false positive. Verified against [apache/iceberg issue #11687](https://github.com/apache/iceberg/issues/11687) where the canonical error reads `Found conflicting files that can contain records matching true` (literal `true` when the validation expression is unspecified — typically a row-level DELETE/UPDATE without a tight predicate).
- `org.apache.iceberg.exceptions.CommitFailedException` after a few seconds of work → the table is genuinely contended; either lower contention (stagger jobs, partition the work better) or relax to `snapshot` isolation.

**Raising `commit.retry.num-retries` is a Band-Aid, not a fix.** If a write needs 20 retries to succeed, the table is so contended that throughput is suffering. The real fixes are below.

---

## 6. Diagnostic recipe — "my MERGE keeps failing during ingestion window"

The symptom: a dbt MERGE that always succeeded suddenly starts failing with `ValidationException: Found conflicting files` or `CommitFailedException` after a new ingestion stream was added.

```sql
-- Step 1: confirm the current isolation level for the table.
SELECT key, value
FROM iceberg.analytics."orders$properties"
WHERE key LIKE 'write.%.isolation-level'
   OR key LIKE 'commit.retry.%';
-- Expected if not customized: nothing (Iceberg defaults: serializable + 4 retries).

-- Step 2: look at recent commit operations — is something else writing in your MERGE window?
SELECT snapshot_id,
       committed_at,
       operation,
       summary['total-records'] AS total_rows,
       summary['added-data-files'] AS added_files
FROM iceberg.analytics."orders$snapshots"
ORDER BY committed_at DESC
LIMIT 20;
-- Look for interleaved 'append' (from ingestion) and 'overwrite' / 'delete' (from MERGE).
-- If the timestamps interleave, you have concurrent writers.

-- Step 3: confirm the MERGE's partition predicate excludes the ingestion's partitions.
-- If both touch the same partition, the conflict is real (not a false positive).
EXPLAIN
MERGE INTO iceberg.analytics.orders t
USING (...) s
ON t.order_id = s.order_id
WHEN MATCHED ...;
-- Look at the partition pruning in the plan. If the predicate prunes to disjoint
-- partitions from the ingestion job, the conflict at serializable is a false positive.
```

**Two viable fixes** depending on what you find:

- **The MERGE and the ingestion target disjoint partitions** → relax to `snapshot` isolation. The conflict is a false positive at `serializable`. Apply via `ALTER TABLE ... SET PROPERTIES` (Section 4).
- **The MERGE and the ingestion really do touch the same rows** → serialize them in your scheduler (run them sequentially via Airflow / k8s CronJob dependencies). **No isolation level can paper over genuinely-conflicting writes; you have a workflow design issue, not a config issue.**

---

## 7. Four fix paths (when to use which)

When you've confirmed via Section 6 that the conflict is the disjoint-partition false-positive, you have four levers, in increasing-cost order:

| Fix | When to use | Trade-off |
|---|---|---|
| **(a) Make partition pruning explicit in the WHERE clause** | The MERGE's WHERE clause references the partition column with literal partition values that Iceberg can statically prove disjoint from the concurrent writer's partition. | Lowest cost; sometimes enough on its own — but only if the partition spec actually proves disjointness. |
| **(b) Relax to `snapshot` isolation** | The table is append-mostly, and updates target rows from earlier partitions. The phantom-row risk is acceptable. | Loses the "no phantom rows" guarantee. Most SaaS analytics tables tolerate this. |
| **(c) Raise `commit.retry.num-retries`** | Conflicts are real and short-lived — eventually the table will be quiescent and the retry will succeed. | Higher latency on contended writes. Doesn't fix the root cause; treats the symptom. |
| **(d) Serialize writers in the scheduler** | Conflicts are real (writers do touch the same rows). | Loses concurrent-write throughput entirely. The only honest fix when writes genuinely overlap. |

The right answer for **disjoint-partition false positives** is almost always (b). The right answer for **genuinely conflicting writes** is (d). (a) is a refinement that sometimes makes (b) unnecessary. (c) is rarely the right answer on its own.

---

## 8. When to choose each isolation level (decision table)

| You should pick `serializable` (the default) if... | You should pick `snapshot` if... |
|---|---|
| Your team has a small number of writers (one ingest job, occasional ad-hoc fixes); commit conflicts are rare; correctness matters more than throughput. | You have many concurrent writers (multiple dbt models, multiple ingestion streams, multiple analysts running corrections) and you keep hitting `ValidationException` retries that slow the pipeline. |
| The table is the source of truth for billing / compliance and you cannot tolerate a phantom-read where a concurrent insert went unseen by a concurrent UPDATE/MERGE. | The table is an append-mostly fact table where updates and inserts target disjoint partitions (most multi-tenant SaaS analytics tables fit this shape). |
| You are running a one-off MERGE that synchronizes a table from an external source and the source has the full ground truth (any phantom-read would corrupt the merge). | Your UPDATE/DELETE/MERGE operations are partition-scoped and idempotent — the worst case of a missed concurrent insert is "we'll catch it next run." |

### 8.1 The phantom-row risk under `snapshot` — a worked example

The price of `snapshot` is precisely defined: a concurrent **INSERT** of a row that **logically should have been included** in your `UPDATE`/`DELETE`/`MERGE`'s WHERE filter goes **un-seen**. Walk through this to internalize it:

**Setup.** `iceberg.analytics.orders` is configured with `write.update.isolation-level = 'snapshot'`. Two writers run in parallel:

- **Writer A (Spark batch)** at time T: `INSERT INTO orders VALUES (order_id=42, tenant_id='acme', amount=100, status='pending')`. Commits at T+50ms with new snapshot S2.
- **Writer B (Trino UPDATE)** at time T+10ms: `UPDATE orders SET status = 'cancelled' WHERE tenant_id = 'acme' AND status = 'pending'`. Reads at snapshot S1 (BEFORE Writer A's insert). Commits at T+80ms with new snapshot S3 derived from S1.

**What `snapshot` isolation does:**
1. Writer B plans its UPDATE against snapshot S1. At S1, the order_id=42 row does not yet exist.
2. Writer B's plan rewrites the files that contain matching rows AS OF S1. No file from S2 (the one containing order_id=42) is in B's plan.
3. Writer B commits. Iceberg's `snapshot` check asks: *"did writer A modify or delete any of the row positions writer B is about to overwrite?"* Answer: no — A only appended a new file. Commit succeeds.
4. Final state at snapshot S3: order_id=42 has `status='pending'` (Writer A's insert), NOT `'cancelled'`. **Writer B's UPDATE silently missed it** — the row logically matches the WHERE filter but was invisible to B at plan time.

Under **`serializable`**, Iceberg's manifest-level overlap check would have detected that A's new file's `tenant_id` min/max range overlaps `'acme'` and the `status` min/max range overlaps `'pending'`, and **rejected Writer B's commit** with `ValidationException: Found conflicting files`. Writer B would retry, re-plan at S2, include order_id=42 in the plan, and produce a correct final state with `status='cancelled'`.

**The trade-off is exactly:** `snapshot` skips the manifest-level overlap check, so writers commit more often without retries, but ACCEPTS that a concurrent INSERT can land "in the WHERE-filter blind spot" of a concurrent UPDATE/DELETE/MERGE. The phantom row exists in the final table with its pre-UPDATE value.

**When this is OK in SaaS analytics:**
- **Idempotent re-runs catch the drift.** If Writer B is part of a nightly dbt model that re-evaluates the WHERE filter every run, the NEXT run will see order_id=42 at status='pending' and set it to 'cancelled'. The phantom-row is fixed within one cycle of the pipeline.
- **The application is the source of truth, not the warehouse.** If order_id=42's "cancelled" state is recorded in Postgres and the warehouse is a downstream mirror, the next ingestion sync re-pulls the row's correct status from Postgres.
- **The table is append-mostly with rare cross-partition updates.** The window for phantom-row anomalies is small — only writes whose plan time overlaps with another writer's commit time.

**When this is NOT OK:**
- **The warehouse is the source of truth for billing/compliance.** Missing a status flip on an in-flight order can mean a customer is billed for a cancelled order. Stay on `serializable` and pay the retry cost.
- **The UPDATE is a one-shot reconciliation against an external source.** You synchronize from external data once, and you need the final state to reflect the full set as of plan time. Stay on `serializable`.
- **You cannot tolerate ANY drift between concurrent commits.** Either use `serializable` or serialize the writers (only one runs at a time) — `snapshot` is fundamentally a "accept some drift" knob.

### 8.2 Defenses to layer on top of `snapshot`

If you choose `snapshot` for throughput but want to bound the phantom-row exposure:

1. **Partition-prune the UPDATE/MERGE explicitly.** If your `UPDATE` says `WHERE order_date = DATE '2026-05-29'` and the concurrent INSERT writes to a different partition, the partition predicate AT THE QUERY LEVEL (not the isolation check) already excludes the new file. The phantom risk is only on UPDATEs that span the same partitions as concurrent INSERTs.
2. **Schedule re-runs.** Make the UPDATE/MERGE idempotent and run it on a cadence (every N minutes / hourly / nightly). Phantom-row drift gets caught on the next run. This is the canonical pattern for dbt incremental models.
3. **Verify drift periodically.** Run a Trino sanity query (`SELECT COUNT(*) FROM orders WHERE status = 'pending' AND tenant_id = 'acme' AND order_date < CURRENT_DATE - INTERVAL '1' DAY`) on a schedule. A non-zero count after the daily reconciliation means you have drift; alert and re-run the UPDATE.
4. **Use `snapshot` per-operation, not per-table.** If only the high-contention MERGE needs `snapshot`, set only `write.merge.isolation-level = 'snapshot'` and leave `write.delete` / `write.update` at `serializable`. The trade-off becomes targeted.

---

## 9. Pitfalls and footguns

- **There is NO global `write.isolation-level` property.** Use the three operation-specific properties. The shortcut form `write.isolation-level` that some older docs reference was deprecated.
- **Changing `write.*.isolation-level` does NOT affect already-running writes.** The level is read at write-plan time. If you flip the property mid-incident, in-flight writes continue under the old level. The new level applies only to writes that *start* after the property change commits.
- **`snapshot` isolation does NOT mean "no isolation."** Readers still see snapshot-isolated reads (a query started before a commit doesn't see that commit's data). The property only changes the WRITER conflict-detection strictness, not the READER consistency model.
- **`serializable` is necessary, not sufficient, for serializable history.** Even under `serializable`, two concurrent writers that both succeed don't have a totally-ordered history — they have a serializable one (some valid ordering exists). If your application requires a specific ordering, serialize the writers in the scheduler, not just at the isolation level.
- **The check is at the manifest level, not the row level.** This is why `serializable` can false-positive — manifests carry column min/max stats, not exact row values. A predicate on a non-partition column with overlapping min/max ranges across files will fail conservatively.
- **`commit.retry.num-retries=4` is a *commit*-level retry, not an application-level retry.** Your Spark or Trino client may also retry the entire statement on failure; those are two layers of retry stacked. If you see "the same dbt model retried 12 times," that's probably 4 Iceberg-level retries × 3 dbt-level retries.
- **Iceberg 1.5.2 still uses the legacy positional-delete + equality-delete model.** The Iceberg v3 spec's deletion vectors aren't in 1.5.2; the isolation level behavior described here is for the v2 row-level operations.

---

## 10. Quick reference cheat sheet

```sql
-- The three properties to set (Trino 467 or Spark):
ALTER TABLE iceberg.analytics.orders SET PROPERTIES
  "write.delete.isolation-level" = 'snapshot',
  "write.update.isolation-level" = 'snapshot',
  "write.merge.isolation-level" = 'snapshot';

-- The three commit-retry properties (rarely change from default):
ALTER TABLE iceberg.analytics.orders SET PROPERTIES
  "commit.retry.num-retries" = '8',           -- default 4
  "commit.retry.min-wait-ms" = '200',         -- default 100
  "commit.retry.max-wait-ms" = '60000';       -- default 60000

-- Verify in Trino 467:
SELECT key, value FROM iceberg.analytics."orders$properties"
WHERE key LIKE 'write.%' OR key LIKE 'commit.retry.%';

-- Inspect concurrent writers via snapshot history:
SELECT snapshot_id, committed_at, operation, summary['total-records'] AS rows
FROM iceberg.analytics."orders$snapshots"
ORDER BY committed_at DESC LIMIT 20;
```

| Symptom | Likely cause | First fix |
|---|---|---|
| `ValidationException: Found conflicting files` on a MERGE that touches disjoint partitions from concurrent ingestion | `serializable` false positive on non-partition column predicate | Relax to `snapshot` (Section 4) |
| `CommitFailedException` after several seconds of work | Genuinely contended table — retries exhausted | Serialize writers in scheduler OR raise retries if contention is short |
| MERGE that "used to work" suddenly fails after a new ingestion job was added | New writer increased contention; check `$snapshots` for interleaving | Confirm via Section 6 diagnostic; then Section 7 fix paths |
| Property change had no effect on in-flight writes | Level is read at write-plan time | Wait for in-flight writes to finish; new writes pick up the new level |

---

## 11. Key terms

| Term | Plain meaning |
|---|---|
| **Optimistic concurrency** | Writers don't lock the table up front; they plan, write, then attempt an atomic commit. If two writers race, only one wins the commit. |
| **Snapshot** | A point-in-time version of an Iceberg table. Every successful write creates a new snapshot. |
| **Snapshot isolation (reader-side)** | A reader sees the snapshot that was current when the query started — never a partial mid-write state. Unchanged by `write.*.isolation-level`. |
| **Serializable isolation (writer-side)** | The strictest conflict check: any new data file in a concurrent commit that *might* match your WHERE clause aborts your write. |
| **Snapshot isolation (writer-side)** | The relaxed conflict check: only abort if your write actually touches a row that was modified or deleted by a concurrent commit. New rows added by others don't conflict. |
| **CommitFailedException** | Iceberg's "I gave up retrying" exception. Thrown after `commit.retry.num-retries` failed attempts. |
| **ValidationException: Found conflicting files** | The conflict-detection error raised during the validation phase (before the commit attempt). May or may not lead to `CommitFailedException` depending on retry budget. |
| **Phantom row** | A row that was inserted by a concurrent writer and would have matched your UPDATE/DELETE/MERGE WHERE clause if you'd seen it. Under `snapshot` isolation, your write may miss it; under `serializable`, your write aborts to prevent missing it. |
| **Manifest-level check** | The conflict detection looks at manifest file metadata (partition values, column min/max stats), not actual row content. This is why it can false-positive. |

---

## 12. Branch-and-tag protection vs. `expire_snapshots` — common myths

Engineers asking concurrent-write questions often surface a parallel question: *"my nightly `expire_snapshots` job runs with `retention_threshold=7d`, but I want to keep a 30-day-old snapshot for audit — can a branch protect it, or will the cleanup delete the data files anyway?"* This is the same factual question that comes up in maintenance context (resource 17). The answer is the same; this section restates it here so the responder finds the right framing whichever doorway the engineer enters from.

> **TRUTH (Iceberg default, verified against [iceberg.apache.org/docs/latest/branching/](https://iceberg.apache.org/docs/latest/branching/), [maintenance/](https://iceberg.apache.org/docs/latest/maintenance/), [spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/)):** while a named ref (branch or tag) points at a snapshot, that snapshot AND its exclusively-owned data files are **protected from `expire_snapshots`**, regardless of age, regardless of `retention_threshold` / `older_than` / `retain_last` arguments. The official wording: *"snapshots that are still referenced by branches or tags won't be removed"* and *"the expire_snapshots procedure will never remove files which are still required by a non-expired snapshot."*

**Myth-buster table (mirrors resource 17's leading callout for findability):**

| MYTH (wrong) | TRUTH (right) |
|---|---|
| "`expire_snapshots` can orphan files an active branch points at." | **No, not in normal operation.** While the ref is alive, the snapshot and its exclusively-owned files are protected. The only ways files behind a branch get deleted are: (a) the branch's own snapshot-retention ages snapshots OUT OF the branch's ancestor chain (the tip is always retained); (b) the branch ref itself is dropped (`ALTER TABLE ... DROP BRANCH` or `max-ref-age-ms` fires); (c) the [Iceberg #13568 multi-ref bug](https://github.com/apache/iceberg/issues/13568) — affects **1.6.1+**, NOT this stack on **1.5.2**. |
| "Branch retention (`max_snapshot_age_in_ms` / `min_snapshots_to_keep`) controls only snapshots inside the branch; it does NOT protect data files of currently-referenced snapshots from being deleted on `main`'s expiry." | **There is no separate `main`-only expiry pass.** `expire_snapshots` looks at ALL live refs across the table — branches, tags, and `main`. While any ref points at a snapshot, that snapshot is protected globally. Branch retention controls which ancestors are dropped from the branch's history; it does NOT cause the tip's data files to be deleted while the ref is alive. |
| "To keep a snapshot safe for audit, you must create a tag — an active branch alone is not enough." | **A live branch IS the protection.** Both branches and tags are refs in `$refs`; both protect snapshots from `expire_snapshots`. Use **tag** for immutable labels (billing close, compliance cutoff); use **branch** for refs that advance with new commits (WAP staging). Either keeps the snapshot safe. |

**The operational answer to the canonical question:** *"Can a branch protect a 30-day-old snapshot from my nightly `expire_snapshots(retention_threshold => '7d')` job?"* → **YES.** Create the branch (Spark: `ALTER TABLE ... CREATE BRANCH \`audit-2026-05-01\` AS OF VERSION <snapshot_id>`) and run the cleanup unchanged. The branch's existence is the entire mechanism — no need to tighten retention, skip the cleanup, or pass special arguments.

**What can actually delete branch-referenced data (the narrow legitimate exceptions):**

1. **Forgotten refs hold old data indefinitely** — the OPPOSITE problem from the myth. Monitor `$refs` and drop unused refs to reclaim storage.
2. **Explicit `DROP BRANCH`** — removes the ref intentionally; the snapshot becomes eligible if no other ref still points at it.
3. **`max-ref-age-ms` firing on the ref** — if you set `RETAIN N DAYS` on the branch/tag, the ref auto-expires after N days, and the snapshot becomes eligible at that point. This is by design (auto-cleanup of forgotten refs); the ref is no longer "active" when this happens.
4. **Iceberg #13568 bug** — multi-ref edge case affecting Iceberg 1.6.1+. **NOT prod-relevant on 1.5.2.** Flag as a known item for future upgrades only.

**Cross-references:**
- The leading callout in [`resources/17-iceberg-table-maintenance.md` § 2. `expire_snapshots`](17-iceberg-table-maintenance.md#2-expire_snapshots--run-weekly) — the primary authoritative location with the full property semantics table (`min-snapshots-to-keep`, `max-snapshot-age-ms`, `max-ref-age-ms`, `history.expire.max-snapshot-age-ms` and what each one controls).
- The WAP / branches section in [`resources/17` § Write-Audit-Publish (WAP) with Iceberg branches](17-iceberg-table-maintenance.md#write-audit-publish-wap-with-iceberg-branches) — the canonical use case for protective branches AND the canonical Spark branch-DDL & write-syntax reference card.

> **POINTER — if asked about exact Spark SQL for writing to / promoting a branch, use the canonical reference card in [`resources/17` § ENGINE CALLOUT / Branch-DDL reference card](17-iceberg-table-maintenance.md#write-audit-publish-wap-with-iceberg-branches), NOT invented forms.** Verified against [iceberg.apache.org/docs/latest/spark-writes/](https://iceberg.apache.org/docs/latest/spark-writes/) + [spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/):
> - **CREATE / DROP branch (Spark DDL):** `ALTER TABLE <cat>.<db>.<table> CREATE BRANCH \`<name>\` [AS OF VERSION <snapshot_id>] [RETAIN <n> DAYS]` / `ALTER TABLE ... DROP BRANCH \`<name>\``.
> - **WRITE to branch (Spark — TWO forms):** (i) suffix on identifier: `INSERT INTO <cat>.<db>.<table>.branch_<name> VALUES (...)` (the `branch_` prefix is required, also works for UPDATE/DELETE/MERGE); (ii) WAP session conf: `SET spark.wap.branch=<name>;` then plain `INSERT INTO <cat>.<db>.<table> VALUES (...)`.
> - **PUBLISH branch to main (Spark):** `CALL <cat>.system.fast_forward('<db>.<table>', 'main', '<branch>')` — a PROCEDURE call, NOT a DDL statement.
> - **Trino 467 (READ-ONLY):** `SELECT ... FROM <table> FOR VERSION AS OF '<branch_name>'`. Cannot create / write / publish / drop branches.
>
> **DO-NOT-WRITE (FABRICATED — these fail to parse):**
> - `INSERT INTO <table> (BRANCH '<name>') VALUES (...)` — there is NO `(BRANCH '...')` parenthesized clause.
> - `MERGE BRANCH <name> INTO main` / `ALTER TABLE ... MERGE BRANCH ... INTO main` — no `MERGE BRANCH` DDL; use the `fast_forward` procedure.
> - Any Trino-side `CALL iceberg.system.create_branch / fast_forward / drop_branch` — Spark-only on this stack.

---

## See also

- **[resource 13](13-postgres-to-iceberg-ingestion.md)** — the ingestion stack uses `overwritePartitions()` (append) and `MERGE INTO` (upsert); see those sections for the write patterns that this resource covers the concurrency semantics for.
- **[resource 17](17-iceberg-table-maintenance.md)** — table maintenance procedures (compaction, snapshot expiry) ALSO create snapshots and can conflict with writes; the maintenance procedures in resource 17 are typically scheduled to avoid this overlap.
- **[resource 10](10-lakehouse-partitioning.md)** — partition design directly affects whether `serializable` can prove disjointness; a good partition spec makes `serializable` false positives rare.
- **[resource 22](22-trino-federation-postgresql.md)** — Trino-side `MERGE INTO` semantics and how Trino routes through the Iceberg connector.

