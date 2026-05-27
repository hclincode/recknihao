# Score: iter267-q2

**Score**: 4.75 / 5.0
**Pass**: YES (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All key claims verified against Trino docs: (1) LEFT OUTER and FULL OUTER joins do NOT support dynamic filtering — confirmed by official docs ("Dynamic filtering cannot be used for LEFT OUTER and FULL OUTER joins because all records from the left side must be returned at least once"). (2) INNER and RIGHT joins DO support dynamic filtering — confirmed. (3) `iceberg.dynamic-filtering.wait-timeout` is the correct property name, default 1s, configured in the Iceberg catalog properties file — confirmed. (4) `dynamicFilters` annotation on the TableScan is correct EXPLAIN output. (5) The INNER JOIN + UNION ALL rewrite is semantically equivalent to LEFT JOIN. The answer correctly fixes the iter266 error (which had wrongly claimed LEFT JOIN was a fix). |
| Beginner clarity | 4.5 | Excellent narrative flow: opens with a plain-English explanation of WHY LEFT JOIN blocks the optimization (must return every left row, so can't prune). Tables and step-by-step list make INNER JOIN behavior easy to follow. Inline comments in the SQL examples ("slow — no dynamic filtering" vs "fast — dynamic filtering active") help orient newcomers. Minor: terms like "build side", "probe side", "split", and "Parquet min/max stats" appear without inline glossing — a true beginner could stumble briefly. |
| Practical applicability | 5 | Engineer can act immediately: drop-in INNER JOIN + UNION ALL rewrite uses the exact catalog names from the question (`app_pg.public.customer_accounts`, `iceberg.analytics.events`), preserves the same account_id join key, gives identical semantics. CTE alternative for the case where NOT EXISTS is slow. Verification path via EXPLAIN ANALYZE with concrete row-count expectations (800M vs ~50M). Catalog-config snippet for `iceberg.dynamic-filtering.wait-timeout=20s` is correct for production (Trino 467 + Iceberg catalog). |
| Completeness | 4.5 | Addresses the explicit questions fully: (1) why LEFT JOIN doesn't get the optimization, (2) how to rewrite. Adds verification via EXPLAIN ANALYZE and a useful timeout-tuning aside. Missing nuances: (a) no mention that dynamic filtering also supports inequality conditions (<, <=, >, >=) and IS NOT DISTINCT FROM, not just equality — the answer focuses entirely on equality IN-lists; (b) doesn't mention semi-joins (IN subqueries) as another DF-supported pattern, which could be an even simpler rewrite for this specific query (replace LEFT JOIN with WHERE EXISTS / IN — semi-join semantics differ but worth noting); (c) no mention of `domain-compaction-threshold` (256 default) which would matter if the 1,800 distinct account IDs ever grew larger and the IN-list got compacted into a BETWEEN range. |
| **Average** | **4.75** | |

## What the answer got right
- Correctly identifies that LEFT OUTER JOIN does NOT support dynamic filtering — directly fixes the iter266 regression where this was stated incorrectly.
- Accurate join-type support table (INNER YES, RIGHT YES, LEFT OUTER NO, FULL OUTER NO).
- Mechanically correct walkthrough of how dynamic filtering works: build-side scan → collect distinct keys → push IN-list to probe side → file/split pruning via Iceberg min/max stats.
- INNER JOIN + UNION ALL rewrite is semantically equivalent to the original LEFT JOIN and recovers the DF optimization on the expensive Iceberg side.
- Bonus CTE pattern is a valid alternative when NOT EXISTS performs poorly.
- `iceberg.dynamic-filtering.wait-timeout` property name, default behavior, and catalog placement all verified correct.
- EXPLAIN ANALYZE guidance and `dynamicFilters` plan annotation are accurately described.
- Uses production-relevant catalog and schema names from the question (no fabrication of unrelated examples).

## Gaps or errors
- Implies dynamic filtering only produces IN-lists from equality joins. Trino docs explicitly support `=`, `<`, `<=`, `>`, `>=`, and `IS NOT DISTINCT FROM` for INNER/RIGHT joins, plus `IN` for semi-joins. The narrow framing as "IN-list pushdown" is not wrong but underspecifies what DF can do.
- Does not mention the simpler rewrite alternative: a semi-join via `WHERE account_id IN (SELECT account_id FROM customer_accounts)` on the Iceberg side followed by a LEFT JOIN back to Postgres. For this specific 2K-vs-800M case it would be the most natural pattern.
- The "CAST blocks dynamic filtering" claim from the verification checklist is NOT addressed in the answer (the answer does not mention CAST at all). According to Trino docs, CAST from build key type to probe key type does NOT block DF; only some probe-to-build casts have limited support. Omission is acceptable since the engineer didn't ask, but a one-line note would have been useful.
- "Build side" / "probe side" terminology not glossed for beginners.
- No mention of `domain-compaction-threshold` (256) which controls IN-list vs BETWEEN-range compaction once distinct-value counts get large.

## Verified sources
- https://trino.io/docs/current/admin/dynamic-filtering.html — confirmed LEFT/FULL OUTER joins not supported; INNER/RIGHT joins supported with =, <, <=, >, >=, IS NOT DISTINCT FROM; semi-joins supported with IN; CAST behavior; `dynamicFilters` in EXPLAIN.
- https://trino.io/docs/current/connector/iceberg.html — confirmed `iceberg.dynamic-filtering.wait-timeout` property name, default `1s`, configured in catalog properties file.
