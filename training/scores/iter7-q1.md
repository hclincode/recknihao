# Iter 7 Q1 — Self-hosted Iceberg+Trino vs Snowflake: hidden costs beyond storage

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All three cost layers (idle compute, maintenance complexity, engineering FTE) match `resources/16-cost-considerations.md` exactly. The ~20–30%/year orphaned-file storage growth, 0.2–0.5 FTE per 10 TB, $200k fully-loaded FTE, and Snowflake crossover numbers (~$550 storage, ~$4,800 credits, ~$60k FTE) all match the resource. Minor: the FTE range is quoted for a "10 TB" baseline but the implied scale is 500 GB — the resource would suggest a lower FTE fraction at that scale — but this is not egregiously wrong. The Snowflake-is-theoretical anchoring to prod_info.md is correct. |
| Beginner clarity | 4 | Well-structured with numbered sections and concrete dollar figures. However, "executor pods," "Hive Metastore," "k8s node budget," "compaction," "FTE," and "orphaned files" appear without inline plain-English glosses (FTE defined only implicitly via the "1 day per week" restatement). The resource's Key Terms section defines FTE and several other terms that the answer does not surface inline. Persistent jargon-without-gloss pattern throughout the training run. |
| Practical applicability | 5 | Engineer walks away with a three-category framework, concrete dollar ranges ($60k–$140k FTE), and a Snowflake-vs-self-hosted comparison table with the on-prem caveat correctly stated. CTO-ready framing. The "you're already running this stack, so the marginal compute cost is sunk" nuance is preserved. |
| Completeness | 5 | Directly addresses all parts of the question: why compute (not storage) dominates, what maintenance complexity hides in the bill, why engineering FTE is the largest true cost, and a structured cost comparison. Anchors to the on-prem prod requirement. No critical omissions. |
| **Average** | **4.75** | |

## Topic updated

**Topic**: Cost considerations for analytical workloads at SaaS scale

- Prior avg: 4.25 (1 question, Iter 6 Q2)
- This question's score: 4.75
- New running avg: (4.25 + 4.75) / 2 = **4.50** across 2 questions
- Status: **PASSED** — avg 4.50 >= 3.5 threshold, 2 distinct question angles tested

## Key finding

The answer correctly surfaces all three hidden cost layers from the resource and grounds the crossover analysis in the production stack, delivering a CTO-ready cost breakdown. The only persistent weakness is inline jargon definitions — "compaction," "executor pods," "Hive Metastore," and "FTE" appear without the plain-English glosses the resource provides in its Key Terms section, leaving a beginner reader to infer meaning from context.

## Resource gap

The answer pulls FTE guidance verbatim from `resources/16-cost-considerations.md` line 46 ("0.2 to 0.5 FTE per 10 TB") but applies it to a 500 GB lakehouse without scaling down the estimate. The resource should add a brief callout in the Engineering FTE section noting that the 0.2–0.5 FTE figure is calibrated to ~10 TB and should be prorated for smaller stacks (e.g., 0.05–0.15 FTE at <1 TB), so the answer does not inadvertently overstate the FTE burden for small-scale deployments.
