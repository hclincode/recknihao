# Judge Report — Iter 152 Q2 (Iceberg Partition Evolution: Month -> Day on Live Table)

## Overall

| Metric | Value |
|---|---|
| Weighted average | **4.80 / 5** |
| Pass threshold | 4.5 |
| **Result** | **PASS** |

Weighted average formula: `(TechAccuracy * 2 + Clarity + Practical + Completeness) / 5`
= `(5*2 + 5 + 5 + 4) / 5` = **4.80**

---

## Per-dimension scores

### Technical accuracy — 5 / 5 (weight 2x)

Every load-bearing technical claim verified against official sources.

- **`ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]`** — CONFIRMED valid Trino syntax. The official Iceberg connector doc explicitly shows `ALTER TABLE table_name SET PROPERTIES partitioning = ARRAY[<existing partition columns>, 'my_new_partition_column'];`. ([Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html))
- **Partition evolution is write-forward only** — CONFIRMED. Iceberg docs: "When you evolve a partition spec, the old data written with an earlier spec remains unchanged. New data is written using the new spec in a new layout." ([Iceberg Evolution](https://iceberg.apache.org/docs/1.5.1/evolution/))
- **Iceberg tracks data files with `spec_id`** — CONFIRMED. spec_id is part of the Iceberg table spec and is exposed in metadata tables. ([Iceberg Spec](https://iceberg.apache.org/spec/))
- **`$files` metadata table has `spec_id` column queryable in Trino** — CONFIRMED. PR [trinodb/trino#24102](https://github.com/trinodb/trino/pull/24102) explicitly added `spec_id`, `partition`, `sort_order_id`, `readable_metrics` to the Trino `$files` table to reach parity with Spark.
- **`rewrite-all=true` option in `rewrite_data_files`** — CONFIRMED to exist in Iceberg 1.5.x. Bypasses the default file-size and delete-count filters and forces all files in scope to be rewritten. The answer's claim that the default strategy "skips well-sized files" matches the documented bin-pack filter behavior. ([Iceberg #14667 references the option in 1.5.x context](https://github.com/apache/iceberg/issues/14667))
- **Use Spark for the rewrite, not Trino** — CONFIRMED to be currently sound advice. All three referenced Trino issues are real and partition-evolution-related:
  - [trinodb/trino #26109](https://github.com/trinodb/trino/issues/26109) — `$files` invalid schema error after partition spec update (closed via PR #27380)
  - [trinodb/trino #26503](https://github.com/trinodb/trino/issues/26503) — ALTER partition truncate transform produces NULL partition values after optimize/compaction
  - [trinodb/trino #25279](https://github.com/trinodb/trino/issues/25279) — optimize cannot use newly added partition columns as predicate (FilterNode rejection)
- **`day(event_date)` transform** — Valid Iceberg partition transform; valid Trino syntax.
- **`expire_snapshots(retention_threshold => '7d')`** — CONFIRMED. Direct match to the Trino docs example.
- **Hidden partitioning explanation** — Accurate: Iceberg's pruning is automatic and queries use normal columns; the predicate must reference the same source column the transform was built on.

Minor nit (not deducted): the Iter 152 question is about month→day. With a `day(event_date)` transform replacing `month(event_date)`, both specs derive from the same `event_date` column, so the predicate `WHERE event_date >= DATE '2026-05-22'` correctly prunes against both old (month) and new (day) files. The answer's example handles this correctly.

### Beginner clarity — 5 / 5

- Opens with a one-sentence direct answer (yes, no downtime, but old files stay slow if not rewritten).
- Three numbered steps with the third (`expire_snapshots`) clearly labeled as cleanup.
- "The step teams skip and regret" framing for step 2 is exactly the kind of operational warning a SaaS engineer needs.
- Inline gloss for `spec_id` ("an integer identifying which partition spec was active").
- Closing timeline table converts abstract steps into concrete time budgets.
- Hidden partitioning subtlety (must use source column, not derived) is called out without OLAP jargon.

### Practical applicability — 5 / 5

- Runnable Trino SQL for the ALTER.
- Runnable Spark SQL for the rewrite with both required options (`rewrite-all`, `target-file-size-bytes` = 256 MB).
- Runnable Trino AND Spark variants of expire_snapshots.
- Runnable verification query against `$files`.
- Concrete timing: "5 minutes / 2-8 hours / 30 minutes."
- Concrete storage warning: "~2x table size during rewrite."
- Explicit "use Spark, not Trino" steer for the rewrite, with cited bug IDs — engineer can decide whether to verify on their own version.
- Fits the production stack: Trino 467 syntax, Spark/Iceberg 1.5.2 for the rewrite, MinIO storage spike called out, hidden partitioning maps to the existing partition design.

### Completeness — 4 / 5

Covers the explicit asks:
- "Can we change partitioning on a live table without rewriting?" — yes, with the ALTER mechanic explained.
- "What happens to old files, do queries break?" — old files remain readable under the old spec; queries do not break; engines plan each spec separately.

Covers the implicit critical follow-ups:
- ALTER syntax, write-forward-only caveat, Spark rewrite with rewrite-all, storage spike, spec_id verification, Trino compaction bug caveat, hidden partitioning subtlety, snapshot expiry — ALL present.

Missed nuances (one point deducted):
- **No mention of split planning at the read side.** The Iceberg docs explicitly note that during partition-evolution reads, each spec plans files separately and the results are unioned ("split planning"). The answer says "Checks the spec_id for each file" and "Merges the result sets" which is close, but does not name the concept or warn that scan planning latency may rise modestly while two specs coexist.
- **No mention of the `format-version` requirement or catalog support.** Hive Metastore + Iceberg 1.5.2 supports partition evolution, but a one-line "your Hive Metastore + Iceberg 1.5.2 setup supports this natively" assurance would close the loop for a nervous engineer.
- **`rewrite_manifests` is not mentioned.** After a large rewrite that produces many new manifests, running `rewrite_manifests` is a standard follow-on. The answer's step 3 jumps straight to expire_snapshots. Not strictly required (the rewrite procedure does write a new manifest), but a passing reference would be ideal.
- **No rollback / safety net.** The engineer asked "we're nervous." A sentence on "if step 2 misbehaves, the snapshot history lets you `ROLLBACK TO SNAPSHOT`" would directly address the stated anxiety.

---

## Verified-correct claims with sources

| Claim | Source |
|---|---|
| ALTER TABLE SET PROPERTIES partitioning = ARRAY[...] is valid Trino syntax | [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) |
| Partition evolution leaves old files unchanged (write-forward) | [iceberg.apache.org/docs/1.5.1/evolution/](https://iceberg.apache.org/docs/1.5.1/evolution/) |
| spec_id is tracked per data file and exposed in $files | [trinodb/trino PR #24102](https://github.com/trinodb/trino/pull/24102), [Iceberg Spec](https://iceberg.apache.org/spec/) |
| rewrite-all=true forces rewrite of all files | [apache/iceberg #14667 context](https://github.com/apache/iceberg/issues/14667), [Iceberg spark-procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) |
| Trino compaction-after-partition-evolution has known bugs | [trinodb/trino #26109](https://github.com/trinodb/trino/issues/26109), [#26503](https://github.com/trinodb/trino/issues/26503), [#25279](https://github.com/trinodb/trino/issues/25279) |
| EXECUTE expire_snapshots(retention_threshold => '7d') is valid Trino | [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) |
| Queries succeed across both old and new partition specs (split planning) | [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/) |

---

## Errors or gaps

**HIGH severity**: none.

**MEDIUM severity**: none.

**LOW severity**:
- Missing the term "split planning" when explaining how the engine handles two specs (concept is conveyed, terminology is missing).
- No `rewrite_manifests` follow-on mention after a large rewrite.
- No rollback-via-snapshot safety-net sentence (the engineer literally said "we're nervous").
- No "your Hive Metastore + Iceberg 1.5.2 supports this natively, no catalog upgrade needed" reassurance.

---

## Resource fix recommendations

Add the following to `resources/13-iceberg-maintenance.md` (or wherever partition evolution lives — possibly `resources/10-lakehouse-partitioning.md`):

1. **"Split planning" callout box** — one paragraph explaining that during partition-evolution coexistence, the query planner runs file pruning once per spec and unions the file lists. This makes plan time slightly higher but query correctness perfect.
2. **Rollback safety-net section** — show `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => <id>)` (Trino) and the Spark equivalent, framed as "if the rewrite produces something unexpected, snapshots let you revert in seconds."
3. **`rewrite_manifests` follow-on** — note when to run it (after schema changes, after very large rewrites that create many small manifest files) and when it is redundant (after `rewrite_data_files` for a moderate-size table).
4. **Hive Metastore + Iceberg 1.5.2 compatibility line** — explicit statement that partition evolution is a v1+ format-version feature and works on the production stack without catalog changes.
5. **Trino bug list with version pins** — for the compaction-after-partition-evolution bugs, note the Trino version each was reported in and which (if any) are fixed in current Trino. The current answer cites the bug IDs but does not say "still open as of Trino 467" — adding this would help future answers age well.

---

## Topic updates for rubric.md

Affected topics:
- **Iceberg partition design for SaaS** — partition evolution is a sub-area; this answer should add to that topic's running average. Prior avg 4.589 (15 questions). New: (4.589*15 + 4.80) / 16 = **4.602** across 16 questions. Status: still PASSED.
- **Iceberg table maintenance** — rewrite_data_files with rewrite-all and expire_snapshots are core maintenance ops. Prior avg 4.602 (14 questions). New: (4.602*14 + 4.80) / 15 = **4.615** across 15 questions. Status: still PASSED.

Both topics already PASSED and this answer reinforces that status.
