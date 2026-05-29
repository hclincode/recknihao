# Judge Feedback — Iter 403 (EXTENDED PHASE)

**Overall: 4.25 PASS** (Q1 4.25 PASS + Q2 4.25 PASS, average 4.25)

---

## Q1 — Trino IN subquery vs JOIN (re-probe after iter402 punt)

**Scores: 4.5 / 4.0 / 4.5 / 4.0 — avg 4.25 PASS**

### What went well
- Correctly stated that "IN is slow" advice is **wrong** for Trino — no false equivalence with other engines.
- Named the actual optimizer rule: **Semi-Join (IN) Decorrelation** producing a **SemiJoinNode**.
- Mentioned **optimize-hash-generation** session/config property and that it's **default=true** (this is the property that backs efficient SemiJoin execution).
- Warned that **manual rewrite IN -> JOIN can introduce duplicates** when the right-side subquery has duplicate keys — SemiJoin deduplicates implicitly, JOIN does not. This is the single most important gotcha and the responder nailed it.
- Provided an **EXPLAIN lookup table** mapping SemiJoin / InnerJoin / CorrelatedJoin operators to what each means, which gives the engineer the diagnostic vocabulary they need.

### Gaps
- **NOT IN with NULL gotcha** not explicit. NOT IN with a nullable right side returns zero rows when any NULL is present; rewrite to NOT EXISTS or LEFT JOIN ... WHERE right.key IS NULL. This is a recurring real-world failure mode and the canonical companion to the IN/SemiJoin discussion. Add it.
- **CorrelatedJoin diagnosis path** not explored — if EXPLAIN shows CorrelatedJoin instead of SemiJoin, decorrelation **failed** and manual rewrite may be warranted. The lookup table mentions CorrelatedJoin but doesn't tell the engineer what to **do** about it.
- No mention of the **Decorrelate Subqueries** rule for correlated subqueries (sibling of Semi-Join Decorrelation).

### Verdict
Recovery from iter402 punt confirmed. Solid PASS but not strong — the NOT IN NULL and CorrelatedJoin remediation angles remain gaps.

---

## Q2 — Iceberg $partitions metadata table for row counts

**Scores: 4.5 / 4.0 / 4.5 / 4.0 — avg 4.25 PASS**

### What went well
- Correctly framed **$partitions** as **pre-aggregated metadata** — no data scan, reads only manifest files. This is the right mental model.
- Named real columns: **record_count**, **file_count**, **total_size**. All three are present on Iceberg $partitions output.
- Made the critical distinction: **identity partition on tenant_id works** (partition value IS tenant_id, GROUP BY trivially gives per-tenant counts); **bucket(tenant_id, N) does NOT work** because the partition value is the **bucket integer**, not the original tenant_id. Engineer cannot recover tenant_id from $partitions on a bucket-transformed column.
- Recommended **DESCRIBE "tbl$partitions"** for column discovery — practical and correct (column names depend on the partition spec).
- Mentioned **$files** as an alternative when $partitions is insufficient.

### Gaps
- No mention of what to do **instead** when the table is bucket-partitioned — the engineer is left without a path (the answer should pivot them to `SELECT tenant_id, count(*) FROM tbl GROUP BY tenant_id` with metadata-only optimization caveats, or to maintaining a separate rollup).
- **$snapshots / $manifests / $history** ecosystem not contextualized — engineer would benefit from a one-line cheat sheet of Iceberg metadata tables.
- Did not mention that **stats freshness on $partitions depends on recent commits** — if a write is in progress or compaction just ran, counts reflect committed manifests only.

### Verdict
Solid PASS. The bucket-vs-identity distinction is the right insight and it was delivered correctly.

---

## Pattern across Q1 + Q2

Both answers landed at 4.25 — the **same** score on both. That's a moderate PASS, not a strong one. The pattern through iter392-403 shows oscillation between mid-4 PASS and mid-3 FAIL roughly every 4-6 iterations:

`4.75P / 4.125P / 3.9375F / 4.625P / 4.75P / 3.125F / 4.3125P / 4.375P / 4.34375P / 4.09375P / 4.0625P / 3.8125F / 4.59375P / 3.875F / **4.25P**`

Recovery from iter402 fail is real but not strongly stabilized. The responder is on a knife edge; one second-angle probe that hits an uncovered gap (e.g., NOT IN NULL, CorrelatedJoin diagnosis, bucket-partition row count pivot) could swing the next iteration back to FAIL.

---

## Teacher actions next (iter 404)

1. **MEDIUM** — Add explicit **NOT IN NULL** gotcha section to the Trino subquery optimization resource: example query that returns zero rows when right-side has one NULL, then NOT EXISTS / LEFT JOIN-IS-NULL rewrites.
2. **MEDIUM** — Add an **Iceberg metadata tables cheat sheet**: $snapshots, $manifests, $partitions, $files, $history, $refs, $properties — one-line "use for X" per table. The cheat sheet would have given Q2 an extra half-point.
3. **MEDIUM** — Add a **CorrelatedJoin remediation** snippet: if EXPLAIN shows CorrelatedJoin, decorrelation failed; show one common pattern (correlated EXISTS in WHERE) that can be manually rewritten as LEFT JOIN + IS NOT NULL.
4. **LOW** — Carry-forward backlog unchanged (dbt-trino merge duplicates, predicate-pushdown JDBC rewrite, CoW vs MoR write.merge.mode, write.isolation-level, SHOW SESSION catalog-prefix, HMS->Nessie no-downtime, SPILL_FAILED 60GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching 2nd-angle, Iceberg branches fast_forward, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd-angle, fs.cache 3rd-angle JMX, bucket(tenant_id) 2nd-angle, PERCENT_RANK/NTILE 3rd-angle, RANGE INTERVAL gap-day semantics).

## Judge probe targets next (iter 404)

1. **NOT IN NULL gotcha** — "My NOT IN query returns zero rows but I know matching data exists, what gives?" — probes NULL semantics directly.
2. **$partitions on bucket-transformed table** — "I have bucket(tenant_id, 128) and $partitions shows bucket integer not tenant_id — how do I get per-tenant counts?" — probes responder's ability to pivot to GROUP BY when metadata can't help.
3. **2nd-angle CorrelatedJoin diagnosis** — "My EXPLAIN shows CorrelatedJoin not SemiJoin — what does that mean and how do I fix it?" — probes failed-decorrelation remediation, the gap iter403 left open.
4. **Iceberg DROP COLUMN reclaim path** — "I dropped a column 3 weeks ago but MinIO usage didn't drop — what's wrong?" — probes rewrite_data_files + expire_snapshots ordering (carry-forward from iter402).
