# Iter261 Q2 Score

Score: 4.75

## Verdict
PASS (4.5+)

## Strengths
- Opens with the exact right answer to the engineer's core confusion: "a Trino view does NOT cache or store anything... pure SQL substitution." This is the single most important fact and it is stated correctly and prominently.
- Concrete, runnable SQL for both options using catalogs that match the engineer's mental model (`app_pg.public.customers` and `iceberg.analytics.event_counts`).
- Mentions what `EXPLAIN` would show (two TableScans and a HashJoin, view name "completely gone"), giving the engineer a way to verify the behavior themselves. This is high-value, actionable detail.
- Excellent comparison table with the right axes: result caching, Postgres load, join cost per query, freshness, maintenance, when right.
- Quantitative decision heuristics ("5-10 page loads per day keep the view; 50+ materialize") give the engineer a real threshold instead of vague "it depends" advice.
- Correctly identifies the federation cost amplification problem (5 widgets × N users = 5N federated joins).
- Concrete materialization SQL using INSERT INTO Iceberg matches the production stack (Iceberg 1.5.2, Trino 467, MinIO).
- Calls out the multi-dashboard-amplification case correctly (materializing once vs. re-federating per dashboard).
- Closing summary restates both the technical fact and the recommendation cleanly.

## Gaps / Errors
- **Materialized views not mentioned at all.** Trino has a first-class `CREATE MATERIALIZED VIEW` feature (with `REFRESH MATERIALIZED VIEW`) which is exactly the middle ground between a federated view and a manually-scheduled INSERT-INTO job. For a question that literally asks "view vs nightly job," omitting Trino's built-in materialized-view feature is a notable completeness gap. It is the third option the engineer should at least know exists, especially with the Iceberg connector which supports materialized views with storage tables.
- **MERGE / incremental refresh not mentioned.** The answer recommends a full `INSERT INTO` rebuild every night, which for large customers tables means re-writing all of them every cycle. A `MERGE` pattern (or INSERT OVERWRITE on a partition) would be more efficient for incremental refreshes and is the dbt-on-Trino-Iceberg standard. The answer says "Set up a nightly (or hourly) job that runs the INSERT" without addressing whether that INSERT appends, replaces, or merges — leaving the engineer with an ambiguous next step.
- **dbt not mentioned** even though `prod_info.md` explicitly lists dbt as the supported transformation tool. The materialization job is exactly a dbt incremental model use case in this stack.
- **View security mode not mentioned.** Trino views default to `SECURITY DEFINER`, which has real implications when the view federates Postgres+Iceberg (the dashboard user inherits the view-creator's read permissions on both catalogs). For an engineer asking about views in a production system using OPA + JWT, a brief mention would have been valuable but is not strictly required by the question.
- Minor: "a few seconds of replica lag" framing for federated freshness assumes the engineer is reading from a Postgres replica; the original question did not state this. Small assumption, doesn't affect the core advice.

## Technical accuracy notes
- Verified against https://trino.io/docs/current/sql/create-view.html: "Views do not contain any data. Instead, the query stored by the view is executed every time the view is referenced by another query." Answer's claim that a view does pure SQL substitution with no caching is **correct**.
- Verified that materialized views are the caching alternative per https://trino.io/docs/current/sql/create-materialized-view.html: "physical manifestation of the query results at time of refresh." Answer does not mention this option — a real gap.
- Verified INSERT INTO Iceberg as the standard materialization pattern: AWS Prescriptive Guidance and Starburst confirm CTAS / INSERT INTO Iceberg as the recommended materialization pattern when results are reused frequently (dashboards). For incremental updates, MERGE with partition pruning via the `$partition` hidden column is best practice — answer's INSERT-only example is correct but not the most efficient pattern for large refreshes.
- Verified DEFINER vs INVOKER view security modes exist (DEFINER is the default). Not directly required by this question, but worth noting in the context of a SaaS platform with OPA-based authorization.
- The EXPLAIN claim (TableScans + HashJoin, view name gone) is consistent with how Trino's analyzer expands views before planning. Correct.
- Quantitative thresholds ("5-10 vs 50+ page loads per day") are reasonable rules of thumb but are presented as the answer's heuristic, not an official Trino guideline. Acceptable.

Sources:
- [CREATE VIEW — Trino docs](https://trino.io/docs/current/sql/create-view.html)
- [CREATE MATERIALIZED VIEW — Trino docs](https://trino.io/docs/current/sql/create-materialized-view.html)
- [REFRESH MATERIALIZED VIEW — Trino docs](https://trino.io/docs/current/sql/refresh-materialized-view.html)
- [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)
- [Working with Iceberg tables by using Trino — AWS Prescriptive Guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/apache-iceberg-on-aws/iceberg-trino.html)

## Dimension scores
- Technical accuracy: 4.75 — Everything stated is correct; the one significant omission (materialized views as a built-in option) lowers this slightly but does not introduce errors.
- Beginner clarity: 5.0 — Opens with the key fact in bold, uses concrete catalog names, includes EXPLAIN explanation, no assumed OLAP knowledge.
- Practical applicability: 4.75 — Strong actionable thresholds and a clear "what to do now" section. Loses a fraction for not mentioning dbt (the production transformation tool) and for full-overwrite INSERT instead of MERGE for incremental refresh.
- Completeness: 4.5 — Answers the core view-vs-nightly-job question well, but misses Trino materialized views which is directly relevant to the question.

Average: (4.75 + 5.0 + 4.75 + 4.5) / 4 = 4.75
