# Score: iter266-q2

**Score**: 3.95 / 5.0
**Pass**: NO (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Two notable errors: (1) Claims inequalities (`>`, `<`, `BETWEEN`) don't trigger dynamic filtering — Trino docs explicitly state DF supports `=`, `<`, `<=`, `>`, `>=`, and `IS NOT DISTINCT FROM` for inner/right joins. (2) Recommends LEFT JOIN with small table on left side — Trino docs explicitly state DF does NOT work for LEFT OUTER or FULL OUTER joins (regardless of side ordering). The wait-timeout default (1s), build/probe terminology, equality-CAST behavior, and "join runs on Trino workers" claims are all correct. |
| Beginner clarity | 5 | Excellent for a beginner. Clear mental model with numbered steps, concrete row counts (5,000 IDs), "wrong vs right" code examples, and a summary table. No assumed OLAP knowledge. |
| Practical applicability | 4 | Very actionable: shows EXPLAIN ANALYZE workflow, gives `Input:` row count interpretation, suggests Postgres index, raises the wait-timeout to a concrete value (20s). The LEFT JOIN advice is misleading though — engineer following it would still see full Iceberg scans. No mention of partition pruning interaction beyond the checklist item. |
| Completeness | 4 | Covers core (what DF is, why it fails, how to verify, how to fix). Good summary table at end. Missing: (a) explicit note that LEFT/FULL OUTER joins can't use DF at all, (b) `enable_dynamic_filtering` session property as a quick diagnostic toggle, (c) note that broadcast vs partitioned join choice affects DF effectiveness, (d) mention that the Postgres connector itself supports DF for the probe side (relevant if join direction is reversed). |
| **Average** | **3.95** | |

## What the answer got right
- Correct that dynamic filtering is a real Trino feature usable across catalogs (Postgres build to Iceberg probe).
- Correct terminology: build side = smaller (filter-source), probe side = larger (filter-recipient).
- Correct default for `iceberg.dynamic-filtering.wait-timeout` is `1s` (verified against trino.io/docs/current/connector/iceberg.html).
- Correct that the join itself always executes on Trino workers — Postgres and Iceberg cannot push joins to each other.
- Correct that wrapping the probe-side column in `CAST(...)` (function on probe side) generally prevents DF, and bare column equality is required for reliable pushdown.
- Good EXPLAIN ANALYZE workflow: looking at `Input:` row count and `DynamicFilter` reference in the TableScan node is the right diagnostic.
- Partition pruning callout (date filter on `event_date`) is a valuable complementary tip.

## Gaps or errors
- **Wrong about inequalities**: Answer states "Inequalities (`>`, `<`, `BETWEEN`) also don't trigger dynamic filtering — it only works on equality joins (`=`)." Trino docs explicitly list `<`, `<=`, `>`, `>=`, and `IS NOT DISTINCT FROM` as supported for inner and right joins. (BETWEEN is not directly listed, but range inequalities are.)
- **Wrong LEFT JOIN guidance**: Answer says "For LEFT JOIN: the small table typically goes on the left (it becomes the build side)" and gives a code example. Per Trino docs, LEFT OUTER and FULL OUTER joins do NOT support dynamic filtering at all — because all left-side rows must be returned, filtering would change semantics. The correct advice is: rewrite LEFT JOIN as INNER JOIN where semantics allow, or accept that DF won't fire.
- **Missing session-level diagnostic**: No mention of `SET SESSION enable_dynamic_filtering = true/false` to quickly toggle DF and compare runtimes — a standard troubleshooting move.
- **Missing CAST nuance**: Answer treats all CASTs as DF-blocking. Trino actually supports DF when the cast goes from build key type to probe key type, and supports limited implicit casts in the reverse direction. The example shown (`CAST(e.customer_id AS VARCHAR) = c.id`, where `e` is the probe/Iceberg side) is indeed a problem case, so the practical advice is OK, but the absolute statement is not.
- **Missing broadcast vs partitioned join interaction**: For DF to be most effective, the smaller side typically needs to be broadcast. With very small Postgres dimension tables Trino usually broadcasts, but worth flagging.

## Verified sources
- [Dynamic filtering — Trino docs](https://trino.io/docs/current/admin/dynamic-filtering.html) — confirms supported operators (=, <, <=, >, >=, IS NOT DISTINCT FROM for inner/right joins; IN for semi-joins), LEFT/FULL OUTER not supported, and CAST behavior (build to probe supported).
- [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html) — confirms `iceberg.dynamic-filtering.wait-timeout` is a real property with default `1s`.
- [Trino blog: Dynamic filtering for highly-selective join optimization](https://trino.io/blog/2019/06/30/dynamic-filtering.html) — confirms build = smaller dimension, probe = larger fact terminology.
