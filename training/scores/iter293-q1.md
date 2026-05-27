# Iter293 Q1 Score

**Question**: Does Trino support window functions? Performance comparison between window functions and GROUP BY self-join for cumulative SUM (running total) use case on Iceberg.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims verified against trino.io docs. `SUM(...) OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` syntax is exactly correct (Trino 480 docs confirm this is the canonical running-total form). Window operator spilling is real and requires `spill-enabled=true` plus optional `spill_window_operator` session override. Self-join O(n²) characterization is reasonable (each row joins all preceding rows in its tenant partition). `ANALYZE TABLE iceberg.analytics.revenue_events` is the correct Iceberg/Trino syntax — collects NDV stats for CBO. `EXCEEDED_LOCAL_MEMORY_LIMIT` is the actual Trino error code. |
| Beginner clarity | 5 | Clear explanation of *why* GROUP BY can't express running totals ("GROUP BY collapses multiple rows into one row per group"). The bad/good code comparison with explicit "DO NOT DO THIS" labels and concrete row-count math (1M events → 1 trillion comparisons) makes the trade-off visceral. Frame clause is shown but not unpacked in prose — minor gap, but the SQL is self-evident enough for a SaaS engineer with basic SQL. |
| Practical applicability | 5 | Engineer can copy the query directly. Production guidance is concrete: spill config, pre-aggregation pattern with a dbt model example, ANALYZE TABLE for stats. Addresses the realistic operational failure mode (OOM on large tenants) and gives the escape hatch (nightly rollup). Fits production stack: Trino 467 + Iceberg + dbt are all explicitly supported in prod_info.md. |
| Completeness | 5 | Covers: (1) yes-supports answer, (2) correct syntax with frame clause, (3) why GROUP BY can't do this, (4) self-join alternative cost analysis, (5) memory/spill behavior, (6) pre-aggregation alternative for dashboards, (7) ANALYZE follow-up. Nothing material missing for the question as posed. |
| **Average** | **5.0** | **PASS** |

## Verification notes

- **Window function syntax** — confirmed via [Window functions — Trino 480 Documentation](https://trino.io/docs/current/functions/window.html). Example in docs: `SELECT avg(totalprice) OVER (PARTITION BY custkey ORDER BY orderdate ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM orders`. Matches answer exactly.
- **Spilling** — confirmed via [Spill to disk — Trino 481 Documentation](https://trino.io/docs/current/admin/spill.html). Window functions are explicitly listed as a spillable operator; `spill-enabled=true` is the base requirement, with `spill_window_operator` session property override.
- **Self-join cost** — reasonable claim. A SaaS engineer would correctly understand "do not do this." Strictly speaking the cost is O(n²/k) where k is per-tenant partition count, but the order-of-magnitude framing is right.
- **ANALYZE TABLE for Iceberg** — confirmed via [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) and [Table statistics — Trino 480 Documentation](https://trino.io/docs/current/optimizer/statistics.html). ANALYZE collects NDV and feeds the CBO.

## Topic mapping

This question primarily exercises:
- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** (currently 4.550, 5 questions, PASSED) — running totals are a core time-series pattern
- **SQL query best practices for OLAP** (currently 4.517, 8 questions, PASSED) — window function vs self-join is a classic OLAP best-practice question
- Minor touch: **Trino CBO / ANALYZE TABLE** (currently 4.763, 4 questions, PASSED) — the ANALYZE follow-up

## Verdict

PASS (5.0 / 5.0). Strong, comprehensive answer. No resource gaps surfaced.
