# Iter 396 Feedback — 2026-05-30 (EXTENDED PHASE)

**Overall: 4.375 — PASS**

## Q1 — Trino UNNEST for array columns — 4.375 PASS

### Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 4.0 |

### What landed
- `CROSS JOIN UNNEST(tags) AS t(tag)` syntax exact per Trino 467/479 Iceberg connector docs.
- COUNT(DISTINCT order_id) example over exploded rows is the canonical "tag co-occurrence" pattern; engineer can drop their column name in directly.
- ARRAY<VARCHAR> vs JSON column distinction is precisely right and operationally important — a SaaS engineer coming from Postgres JSONB will hit the type mismatch immediately if not warned. The note that JSON columns require `CAST(... AS ARRAY<VARCHAR>)` or `json_parse` before UNNEST works is exactly the right framing.
- Calibrated honesty: the responder acknowledging that resources don't explicitly document this pattern while still giving the correct answer is the behavior we want — beats fabricating a citation.

### Minor gaps
- No mention of `WITH ORDINALITY` for tracking element position (useful for "first tag" / "tag rank" queries).
- No mention of `LEFT JOIN UNNEST` for rows where array is NULL or empty — without this, `CROSS JOIN UNNEST` silently drops rows with empty arrays, which is a real SaaS analytics footgun (you lose orders with no tags from counts).

## Q2 — Column-targeted ANALYZE for 500GB table — 4.375 PASS

### Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.5 |
| Completeness | 4.5 |

### What landed
- `ANALYZE table_name WITH (columns = ARRAY['col1','col2'])` syntax exact per Trino Iceberg connector ANALYZE documentation.
- ~80% speedup is a plausible heuristic for column-targeted vs full ANALYZE on a wide 500GB table (Puffin sketch generation is the dominant cost and scales with column count).
- `drop_extended_stats` footgun is a real and underdocumented gotcha — running ANALYZE with a column subset retains older Puffin sketches for unspecified columns; if the engineer assumes they get fresh stats only on the named columns and stale stats elsewhere are discarded, that assumption is wrong. Calling this out is high-value.
- Target selection guidance (join keys + high-selectivity filter columns) matches CBO best practice — these are the columns whose NDV/distribution most affects join ordering and filter cardinality estimation.
- "Safe — doesn't affect file skipping" is technically correct: partition/file-level skipping uses Iceberg manifest min/max statistics, which are produced by Spark writes, not by Trino ANALYZE. Critical reassurance for an engineer worried about regressions.

### Minor gaps
- "Puffin" is mentioned implicitly (via drop_extended_stats) but not explained for beginners.
- No mention of re-ANALYZE cadence (post-compaction trigger, weekly maintenance window, etc.) — engineer might run targeted ANALYZE once and not realize it needs refresh.
- Could suggest EXPLAIN cost-output verification step after ANALYZE completes ("look for non-zero NDV on the analyzed columns in EXPLAIN (TYPE DISTRIBUTED)").

## Pattern observations

Both answers production-stack-fit (Trino 467 + Iceberg 1.5.2 per prod_info.md). Both correctly identify the engineer-actionable next step. Both show calibrated honesty (Q1) or appropriate caveats (Q2 footgun). This is the iter390+ pattern of consistent ~4.3-4.4 PASS performance — exactly the "consistent correctness across phrasings" the rubric asks for.

## Teacher actions next (iter397)

1. **LOW priority** — Add `WITH ORDINALITY` and `LEFT JOIN UNNEST` for NULL/empty arrays to the UNNEST resource. These are the most common follow-up questions after an engineer adopts the basic pattern.
2. **LOW priority** — Add a one-line "Puffin = Trino's per-column statistics sidecar files" definition to the ANALYZE resource for beginner clarity.
3. **LOW priority** — Document ANALYZE re-run cadence guidance: "re-ANALYZE after large compaction, or weekly, whichever comes first."

## Judge probe targets next (iter397)

1. Carry forward backlog: HMS→Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches fast_forward, bucket sizing, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd angle, fs.cache 3rd angle JMX.
2. Hive→Iceberg migration: 3rd angle probe — explicit Trino-from-migrate angle to test whether teacher's between-iter resource update on dual-engine migrate() landed.
3. Equality-delete 2nd angle: MERGE INTO slowness after 6mo CDC accumulation as a different symptom for the same underlying read-amplification problem.
