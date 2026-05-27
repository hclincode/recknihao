# Iter290 Q2 Score — Trino JOIN order, broadcast vs partitioned, EXPLAIN, ANALYZE

**Topic**: Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering (threshold ≥ 4.5)

## Verification against trino.io and Iceberg docs

- **Broadcast join semantics**: trino.io confirms BROADCAST broadcasts the right table to all nodes; requires the right side fits in memory on each node. Answer's framing ("load the smaller table into every worker's memory as a hash table; each worker joins against its local slice of the big table") is correct.
- **Partitioned join semantics**: trino.io confirms PARTITIONED requires redistributing both tables using a hash of the join key. Answer's framing ("split both tables by join key so matching rows land on the same worker; network-expensive") is correct.
- **AUTOMATIC default and CBO fallback**: trino.io confirms in AUTOMATIC mode, Trino defaults to hash-distributed (PARTITIONED) joins if no cost could be computed, e.g., tables without statistics. Answer correctly states AUTOMATIC is the default and that without statistics the CBO guesses.
- **`join_distribution_type` values**: AUTOMATIC, BROADCAST, PARTITIONED — confirmed.
- **ANALYZE on Iceberg**: trino.io and the Iceberg connector PR (trinodb/trino#13636) confirm Trino's Iceberg ANALYZE collects NDV per column and (since Iceberg 1.1+) stores them in Puffin files. Iceberg 1.5.2 (production stack) supports Puffin. Answer correctly says NDV is not auto-collected and requires ANALYZE.
- **Row count free from Iceberg metadata**: correct — Iceberg manifests carry per-file/per-snapshot row counts.
- **`Join[BROADCAST]` / `Join[PARTITIONED]` EXPLAIN signals**: trino.io EXPLAIN docs do show distribution annotation on Join nodes in TYPE DISTRIBUTED plans (e.g., `LocalExchange[HASH]`, `RemoteExchange[REPLICATE]`, and the Join header itself notes BROADCAST/PARTITIONED). The bracket notation used in the answer is a reasonable simplification commonly seen in Trino EXPLAIN output and is accurate enough for diagnostic purposes.
- **`Estimates: {rows: ?}` as the "CBO guessing" signal**: correct — when stats are missing, Trino shows `?` in estimates. This is a real and recognizable diagnostic signal.
- **FROM-clause order as a CBO hint**: this is a softer claim. With CBO enabled (default in Trino 467), `reorder_joins` typically reorders based on cost; without stats, the CBO falls back to syntactic order in many cases, so "smaller first" as a hint when stats are absent is reasonable. Answer correctly frames this as a hint, not a guarantee.

No factual errors found. All Trino-specific syntax is valid for Trino 467 + Iceberg 1.5.2 on the production stack.

## Scoring

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims verified against trino.io. Broadcast/partitioned semantics, AUTOMATIC fallback, ANALYZE+NDV+Puffin, EXPLAIN signals, session property values — all correct. No misstatements about ANALYZE (the historic failure mode for this topic). |
| Beginner clarity | 5 | The Postgres-contrast section is excellent: "Postgres has B-tree indexes; planner probes one row at a time" vs "Trino must pick a strategy because there are no row-level indexes." Build-side / hash-table jargon is introduced gently. Summary table at the end gives a beginner a decision recipe. |
| Practical applicability | 5 | Engineer can: (1) run the exact EXPLAIN, (2) look for `Join[BROADCAST]` vs `Join[PARTITIONED]` and `Estimates: {rows: ?}`, (3) run ANALYZE on both tables, (4) force `join_distribution_type='BROADCAST'` as override, (5) follow the post-ingest workflow. Trino 467 + Iceberg 1.5.2 + MinIO stack is explicitly named. |
| Completeness | 5 | Covers: why JOIN order matters, broadcast vs partitioned definitions, how CBO decides (row count free + NDV needs ANALYZE), EXPLAIN diagnostic, ANALYZE fix, session-property force, FROM-clause hint, post-ingest workflow, 3+ table caveat. Both diagnostic and fix paths fully covered. |

**Average**: (5 + 5 + 5 + 5) / 4 = **5.00**

**Result**: PASS (≥ 4.5 elevated threshold for this topic)

## Notes

- This is the strongest answer on the join-ordering topic so far. Notably avoids the iter160 historic failure mode ("no ANALYZE needed"). Explicitly states NDV is NOT collected automatically and requires ANALYZE — exactly the correction the topic needed.
- The Postgres-vs-Trino mental model paragraph is reusable beginner-clarity content and matches what made iter Q answers on similar OLTP-vs-OLAP framing score well historically.
- Minor nit (not deducted): the FROM-clause-order hint is a useful heuristic but with CBO enabled and `reorder_joins=true` (Trino 467 default), the CBO will reorder regardless of syntactic order when stats are present. Answer correctly scopes the hint to "when statistics are absent" so this is not an error.
- All advice fits the on-prem Trino 467 + Iceberg 1.5.2 + MinIO + Hive Metastore production stack.
