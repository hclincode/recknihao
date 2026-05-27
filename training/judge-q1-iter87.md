# Judge Score — Iter 87 Q1

## Score: 4.50 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |

## Points covered
- **Diagnosis of the pain**: correctly identifies partition skew (enterprise tenants fanning out to many files per day) as the operational trap, not the partitioning scheme itself. Distinguishes "the engine prunes correctly" from "file open overhead stacks up" — that nuance is exactly what an engineer needs to understand why the system "feels slow."
- **The compaction-cadence trap**: explicit point that compacting the shared table to fix Acme also rewrites 75 small tenants' files (wasted CPU). This is a real operational pain point and the strongest justification for splitting.
- **Tiered model named clearly**: "small tenants on shared, large tenants on dedicated" framed as the standard pattern, with concrete table-naming (`analytics.acme_events`).
- **Operational overhead control via templated maintenance**: parameterized loop over tenant table names, single CronJob — this directly addresses the engineer's "6+ bespoke tables" worry and shows that 6 dedicated tables ≠ 6 bespoke jobs.
- **Schema-change strategy** via Python DDL generation — practical and runnable.
- **Break-even guidance**: 8–10 large tenants as ceiling, tier by contract/volume rather than per-tenant. Useful framing for "middle ground".
- **Concrete next steps**: numbered migration plan with INSERT INTO + view/OPA update + maintenance CronJob deployment.
- **Production-stack fit**: Spark `CALL iceberg.system.rewrite_data_files` (Spark, not Trino — correct per recent iter17 fix), Kubernetes CronJob, Trino views with OPA — all match the on-prem k8s + MinIO + Trino467 + Iceberg1.5.2 stack.

## Accuracy notes
- **Partition skew / file fan-out claim**: directionally correct and matches documented Iceberg behavior — uneven tenant volume → uneven file count per partition → query open-file overhead grows with the tenant's footprint. Verified against Starburst/lakeFS guidance on partition skew.
- **"Small tenant: 1 Parquet file, ~100M rows"**: numerically aggressive — 100M rows in a 128–256 MB Parquet file would require extremely narrow rows. Directionally fine for an illustration but a sharp reader might notice. Minor.
- **`current_timestamp()`**: should be `current_timestamp` (no parens) in Spark SQL / Iceberg procedure args, or use literal `TIMESTAMP '...'`. Procedure-arg syntax is mostly right but the parens are a small SQL-form nit.
- **Cross-table migration atomicity**: step 3 ("INSERT INTO ... then delete from shared table") is correct mechanically, but is **not atomic across the two tables** — between the INSERT and DELETE, the row exists in both tables. For a planned migration of an enterprise tenant this is usually fine (run in a maintenance window, or do INSERT first then atomically update the view to point at the new table, then delete). Not called out in the answer. Minor completeness gap.
- **OPA row-filter / view "carries over unchanged — just update the view's FROM clause"**: correct conceptually; in the production stack the OPA policy itself may also need to know about the new table identifier for action evaluation. Not a blocker but worth a one-liner.
- **8–10 large-tenant break-even**: reasonable rule of thumb, no contradicting source. Treat as judgment rather than canonical, which the answer implicitly does.

## Issues / gaps
- Migration cutover sequencing is glossed: a safer explicit order is (a) create dedicated table, (b) backfill via INSERT INTO ... SELECT, (c) verify row count, (d) atomically swap the Trino view's FROM clause, (e) delete from the shared table. The answer collapses this to "insert then delete then update views" which inverts the safe order.
- No mention of how to **detect** the skew quantitatively (e.g., querying `$files` / `$partitions` metadata tables to size each tenant's file count and bytes before committing to the split). An engineer reading this still has to guess which tenants are the 5–6.
- No mention of `write_distribution_mode` / fanout-writer tuning on the shared table as an interim fix before splitting — a lighter intervention that might buy time. Worth at least naming as the "even smaller middle ground."
- Maintenance bash loop uses `spark-submit maintenance.sql --args` — Spark doesn't take a `.sql` file with `--args` substitution natively; in practice this is either spark-sql + envsubst, or a parameterized PySpark job. Pseudocode is fine for direction but a sharp reader will trip on it.

## Resource fix needed?
Small additions recommended in `resources/05-multi-tenant-analytics.md` (or a tenant-scaling section):
1. **Tiered model section** — explicit "shared + dedicated for whales" pattern with break-even guidance (8–10 large tenants).
2. **Safe cross-table migration sequence** — INSERT → verify → swap view → delete, with note that cross-table writes are non-atomic in Iceberg.
3. **Skew detection recipe** — sample query against `$files` / `$partitions` metadata tables to identify large tenants before splitting.
4. **Interim mitigations** — `write_distribution_mode`, per-tenant compaction cadence on the shared table — as lighter alternatives before committing to split.

Overall: a strong, practically-useful answer. The diagnosis and operational-overhead framing are excellent; the gaps are around migration safety detail and detection tooling.
