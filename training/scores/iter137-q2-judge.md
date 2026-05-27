# Iter137 Q2 — Judge Evaluation

## Score Summary

| Dimension | Score |
|---|---|
| Technical accuracy | 5/5 |
| Beginner clarity | 4/5 |
| Practical applicability | 5/5 |
| Completeness | 5/5 |
| **Overall** | **4.75/5** |

## Verdict: **PASS** (>= 4.0)

---

## What Was Verified Correct

### 1. `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')`
**VERIFIED CORRECT.** The official Trino Iceberg connector docs confirm this exact syntax: `ALTER TABLE table EXECUTE expire_snapshots(retention_threshold => '7d')`. Note: there is a `iceberg.expire-snapshots.min-retention` catalog property that defaults to 7d — the answer's `30d` is safely above that floor.
Source: [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)

### 2. `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')`
**VERIFIED CORRECT.** Trino docs confirm this exact syntax. The answer's explanation that the 7-day window "protects in-flight writes from being deleted" is exactly right — `iceberg.remove-orphan-files.min-retention` defaults to 7d for the same reason.
Source: [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)

### 3. `CALL iceberg.system.rewrite_data_files(...)`
**VERIFIED CORRECT.** This is the documented Trino procedure for Iceberg compaction. The answer correctly identifies its role as bin-packing small files. (Trino exposes it via `CALL <catalog>.system.rewrite_data_files(table => 'schema.table')` — the answer's shorthand `CALL iceberg.system.rewrite_data_files(...)` is consistent with that, where `iceberg` is the catalog name.)
Source: [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)

### 4. `CALL system.runtime.kill_query(query_id => '...')`
**VERIFIED CORRECT.** Trino's System connector documents exactly this: `CALL system.runtime.kill_query(query_id => '...', message => '...')`. The answer omits the optional `message` parameter, which is fine.
Source: [System connector — Trino docs](https://trino.io/docs/current/connector/system.html)

### 5. `system.runtime.queries` columns: `query`, `state`, `created`, `end`
**VERIFIED CORRECT.** The columns the answer's SQL references (`query`, `state`, `created`, `end`) are all valid columns on `system.runtime.queries`. Using `end - created` as a query duration is reasonable. The `state = 'FINISHED'` filter is correct (Trino terminal states include FINISHED, FAILED, CANCELED).
Source: [System connector — Trino docs](https://trino.io/docs/current/connector/system.html)

### 6. Small-file accumulation and manifest-read overhead
**VERIFIED CORRECT.** Multiple sources confirm Iceberg query planning degrades sharply with small files because each manifest must be downloaded and evaluated, and metadata reads per file are a fixed object-storage cost. The answer's "500,000 files = 30+ seconds of manifest reads" and "10× to 100× speedup after compaction" claims are consistent with published industry observations (Dremio, IOMETE, Firebolt).
Sources: [Dremio — Compaction in Iceberg](https://www.dremio.com/blog/compaction-in-apache-iceberg-fine-tuning-your-iceberg-tables-data-files/), [IOMETE — Iceberg Production Anti-Patterns](https://iomete.com/resources/blog/apache-iceberg-production-antipatterns-2026)

### 7. `iceberg.analytics."events$files"` query with `file_size_in_bytes`
**VERIFIED CORRECT.** The `$files` metadata table exists in Trino's Iceberg connector and exposes `file_size_in_bytes` as documented.
Source: [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)

### 8. Production stack fit
**VERIFIED CORRECT.** Answer stays inside the prod_info.md constraints throughout: on-prem only, Trino 467 + Iceberg 1.5.2, MinIO as object storage, Hive Metastore for catalog, Spark for ingestion, Kubernetes for orchestration. No cloud-only services recommended. CronJob/Airflow on Kubernetes for compaction is consistent with the deployment model.

---

## Errors or Gaps Found

### LOW — `CALL iceberg.system.rollback_to_snapshot(...)` syntax
The on-call incident response section names `iceberg.system.rollback_to_snapshot(...)` as a recovery action. In Trino, the equivalent is `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)`, not a `CALL system` procedure. The `CALL` form with `system.rollback_to_snapshot` is the **Spark** procedure spelling. Minor — the intent is correct (rollback to last good snapshot), and a SaaS engineer reading the runbook would find the right thing quickly, but the syntax mixes Spark and Trino spellings.
Impact: LOW — incident response context, easily corrected at runbook time.

### LOW — Postgres FTE math precision
The body text says "Compaction Jobs — 0.1–0.2 FTE/year" in the section header, but the summary table at the bottom shows "0.06–0.1 FTE." The same compression happens for several other categories. The total band of 0.3–0.5 FTE is internally consistent with the table values, but the per-section header ranges are higher than the table values, which could confuse a reader doing arithmetic.
Impact: LOW — total estimate is still reasonable and well-justified.

### LOW — Beginner clarity on a few terms
Some jargon is used without inline plain-English glosses: "manifest reads", "broadcast-replicated", "partition pruning regression", "resource groups", "OPA". A SaaS engineer with no OLAP background would need to look up at least 2–3 of these. Most other terms are well-explained inline (e.g., "Iceberg never modifies files in place" before introducing compaction).
Impact: LOW — overall the answer is accessible; this is why clarity scores 4/5 instead of 5/5.

### MEDIUM — Hive Metastore HA claim
Answer says "On-prem deployments typically run two Metastore instances behind a load balancer." This is correct in spirit, but in practice running Hive Metastore HA is more nuanced — both instances point at the same backing RDBMS, which itself becomes the SPOF unless the RDBMS is HA too. The answer hints at this ("the Metastore DB corrupts, table pointers are gone") but does not connect the two HA stories cleanly. A reader could come away thinking "2 Metastore pods = solved HA," which is incomplete.
Impact: MEDIUM — slightly misleading on a critical operational decision.

---

## Resource Fix Recommendations

1. **`resources/17-iceberg-table-maintenance.md`** — add a brief note distinguishing Trino's `ALTER TABLE ... EXECUTE rollback_to_snapshot(...)` from Spark's `CALL system.rollback_to_snapshot(...)`. This same Trino-vs-Spark syntax distinction has come up in earlier iterations' LOW-fix queue.

2. **`resources/06-when-to-add-olap.md`** or a new operations resource — add a paragraph on Hive Metastore HA that makes clear: (a) Metastore service HA requires multiple Metastore pods, AND (b) the backing RDBMS must independently be HA (managed Postgres, replicated, or with PITR backups). Currently the answer implies pod-level HA is sufficient.

3. **General glossary pass** — terms like "broadcast join", "partition pruning regression", "resource group", and "OPA" appear in answers without inline definitions. A short glossary file or inline "(in plain English: ...)" pattern at first use would lift beginner clarity from 4 to 5 across many topics.

---

## Topic Coverage Update

Question 2 of iter137 touches these required topics:
- **When to add an OLAP layer vs staying on the transactional DB** — strongly covered (decision framework, when-Postgres-wins vs when-Iceberg-wins tables)
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — strongly covered (all three procedures with verified syntax)
- **Cost considerations for analytical workloads at SaaS scale** — strongly covered (FTE breakdown, $ comparison with read-replica scaling)
- **Query performance basics: partitioning, indexing strategy for analytics** — covered (Postgres-vs-Iceberg patterns with speedup estimates)
- **Iceberg partition design for SaaS: strategies, small-files, compaction** — covered (small-file accumulation cost section)

All topics are already PASSED; this answer reinforces them.
