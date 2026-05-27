# Score: iter237-q1 — Iceberg-Only Dynamic Filtering

**Score: 3.85 / 5.0**

## What was correct
- Yes/no answer is correct: dynamic filtering applies to Iceberg-to-Iceberg joins and is enabled by default in the Iceberg connector.
- The file-level pruning mechanism description is accurate — Trino uses build-side join key values to derive filters, then prunes Iceberg files via manifest min/max (`lower_bounds`/`upper_bounds`) statistics. This matches the official docs.
- IN-list vs BETWEEN range compaction concept is correct (Trino does switch to min/max when distinct values exceed thresholds).
- `dynamicFilterSplitsProcessed` is a real OperatorStats field added in Trino (PR #3217) and is visible in EXPLAIN ANALYZE VERBOSE. The description of what it measures (splits processed after the DF was pushed down) is accurate.
- Iceberg connector default `dynamic-filtering.wait-timeout = 1s` is confirmed correct against the official Trino 481 docs.
- Catalog-prefix session property syntax (`SET SESSION <catalog>.dynamic_filtering_wait_timeout = '20s'`) is correct. The example uses `iceberg_catalog` as a placeholder catalog name, which is fine.
- Suggestion to check the Trino UI "Dynamic filters" panel for a post-mortem view is accurate and practically useful.
- Plan-time annotation `dynamicFilters = {...}` on the probe-side TableScan is accurate — this is how DF wiring is verified at plan time.
- Practical guidance (probe-side catalog timeout matters, raise timeout if build side is large) is sound.

## What was wrong or missing
- **Significant fabrication / overreach (Section 1)**: The claim that "Trino's CBO can plan an efficient broadcast join across workers. Dynamic filtering is still available as part of Trino's join strategies" is technically not wrong, but the framing implies a fundamental difference between same-catalog and cross-catalog DF behavior that does not exist. DF works the same way mechanically — it always runs on workers; the "intra-catalog vs cross-catalog" distinction the answer draws is misleading. The Iceberg connector simply supports DF push-down; the catalog co-location is not architecturally relevant to DF itself.
- **Missing context on `domain-compaction-threshold`**: The answer claims the default is 256. The official Trino dynamic-filtering admin docs do not list this exact default, and the per-connector default may differ. Verification could not confirm 256 specifically from the official docs page. This is plausibly correct (it has historically been 256 for Hive/Iceberg) but the answer states it as a hard fact without caveat.
- **Missing**: No mention of `dynamic_row_filtering` (dynamic row filtering is enabled by default in the Iceberg connector per the latest docs) — this is the row-level companion to file-level pruning and is relevant to a complete answer.
- **Missing**: No mention of the alternative `Dynamic filters` field shown in EXPLAIN ANALYZE (the human-readable form showing `df_370, [ SortedRangeSet[...] ], collection time=2.34s`). The answer focuses only on `dynamicFilterSplitsProcessed`, which is more buried in VERBOSE OperatorStats JSON output.
- **Missing**: No mention of broadcast vs partitioned join strategy as a precondition (DF works best with broadcast joins, which is the default when the build side is small enough — relevant since the engineer's plans table is the small build side).
- **Minor**: "intra-catalog join" is non-standard terminology; "same-catalog" is fine but the architectural distinction the answer draws is overstated.
- **Minor**: The claim that Iceberg doesn't filter rows with a WHERE clause is partially misleading — Trino does apply dynamic row filtering (DRF) when scanning Parquet within selected files, not just file pruning.

## Verification notes
- Confirmed via Trino 481 official docs that `iceberg.dynamic-filtering.wait-timeout` default is **1s**. Answer is correct.
- Confirmed via Trino docs that file-level pruning uses manifest min/max statistics on remaining files after partition pruning. Answer correctly describes the mechanism.
- Confirmed via Trino PR #3217 that `dynamicFilterSplitsProcessed` is a real OperatorStats field. Answer is correct.
- Could NOT confirm that `domain-compaction-threshold` default is 256 — the dynamic-filtering admin docs do not list this property's default explicitly. The Iceberg connector docs also do not list it. This is asserted as fact in the answer without verification.
- Catalog session property syntax `<catalog>.dynamic_filtering_wait_timeout` is correct per Trino SET SESSION docs.
- Join pushdown is NOT explicitly documented as supported by the Iceberg connector — the answer wisely did not claim join pushdown happens (good — avoided a fabrication that was a risk).
- Dynamic row filtering is enabled by default in the Iceberg connector and is missing from the answer.

## Recommendation for teacher
- Add a clear note in resources/ that **`domain-compaction-threshold` default is connector-specific** and verify the exact Iceberg default (or remove the hard-coded "256" claim and say "typically 32 or 256 depending on connector — check current docs").
- Add coverage of **dynamic row filtering** (DRF) for the Iceberg connector — it complements file-level pruning by filtering rows within selected files. This is a real, documented feature that the answer omits.
- Clarify that the "intra-catalog vs cross-catalog" framing for DF is misleading — DF mechanism is the same; the only difference is whether the probe-side connector supports DF push-down (Iceberg does, JDBC connectors mostly do via newer versions).
- Add the more accessible `Dynamic filters: - df_XXX, [ SortedRangeSet[...] ], collection time=...` EXPLAIN ANALYZE field as a verification path alongside `dynamicFilterSplitsProcessed`.
- Mention broadcast join precondition / join strategy briefly — DF is most effective with broadcast joins.

## Per-dimension breakdown
- Technical accuracy: 3.5 (correct on the core mechanism and timeouts; overreach on intra/cross-catalog framing; unverified `domain-compaction-threshold` default)
- Beginner clarity: 4.5 (well-structured, explains jargon, good step-by-step verification workflow)
- Practical applicability: 4.5 (concrete config snippets, both file-property and session-property forms, three-step verification workflow, ties back to the engineer's billing/plans use case)
- Completeness: 3.0 (missing dynamic row filtering, missing broadcast-join context, missing the simpler `Dynamic filters` EXPLAIN ANALYZE field)

Average: (3.5 + 4.5 + 4.5 + 3.0) / 4 = **3.875 ≈ 3.85**

Passes 3.5 threshold but with notable gaps around dynamic row filtering and the overstated intra/cross-catalog distinction.
