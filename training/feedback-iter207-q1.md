# Iter 207 Q1 — Judge Feedback

**Topic**: Trino federation / cross-source connectors (PostgreSQL connector, predicate pushdown through views)
**Pass threshold for this topic**: 4.5

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.7 | Verified against trino.io. All claims correct; minor stylization in EXPLAIN output |
| Beginner clarity | 4.5 | Concrete examples; clean GROUP-BY-vs-aggregate framing |
| Practical applicability | 4.8 | EXPLAIN + Postgres slow-query log verification; OPA fit for prod env |
| Completeness | 4.5 | Answers both questions; covers gotcha, verification, security |
| **Average** | **4.625** | |

**Verdict**: PASS (4.625 ≥ 4.5)

---

## What was correct and verified

1. **Postgres views are queryable through the Trino Postgres connector.** Verified against trino.io — `SHOW TABLES` lists both tables and views; the connector treats views as relations. The answer's claim "Trino does not know (or care) that the underlying object is a view" is accurate — over JDBC the relation name is just included in SQL sent to Postgres.

2. **Predicate pushdown through views works as described.** Verified against trino.io pushdown documentation. The Trino JDBC connector wraps the view name in a generated SQL statement with the WHERE clause; Postgres then expands the view definition and (when the optimizer permits) pushes the filter into the underlying joins. The answer's distinction "Postgres-side optimization, not Trino-side" is exactly the right mental model.

3. **The GROUP BY column vs computed aggregate gotcha is accurate.**
   - Filter on a GROUP BY key (like `tenant_id`): Postgres can push the filter through the aggregation into the underlying tables — correct.
   - Filter on a computed aggregate (like `SUM() AS total_api_calls > 10000`): this becomes HAVING semantics and Postgres must compute the aggregate before filtering — correct.
   This is one of the most useful pieces of guidance a beginner could get on this topic.

4. **The `system.query()` OPA bypass warning is accurate.** Verified against trino.io OPA access control docs and the system connector security guidance. Trino's own docs warn explicitly that `system.query` table functions can access underlying catalog data and that permission to the system schema must be granted carefully. Because Trino does not parse the raw passthrough SQL into named columns/tables, column-mask and row-filter policies that target named columns cannot be applied — this is a real concern and especially relevant to this production environment, where OPA is the authorization backend.

5. **Verification approach is excellent.** Combining Trino `EXPLAIN` with the Postgres slow-query log gives the engineer a way to confirm pushdown empirically — this is the kind of "what do I do next" guidance the rubric values.

---

## Minor nits (not score-blocking)

1. The shown EXPLAIN output (`constraint on [tenant_id]`) is stylized. Real Trino `EXPLAIN (TYPE DISTRIBUTED)` output for a JDBC connector typically shows the predicate inside the `TableHandle` constraint or as `predicate = ...` on the scan. The conceptual guidance ("if you see ScanFilterProject above TableScan, pushdown failed") is right.

2. The answer does not explicitly distinguish **Trino-side aggregate pushdown** (when Trino itself rewrites `SELECT SUM(x) FROM tbl GROUP BY y` to push to Postgres) from **the view's internal aggregation** (which Postgres always evaluates when the view is referenced). For this question the distinction did not matter, but for adjacent questions it might.

3. Did not mention the "federate vs ingest" decision — i.e., if the view is hot and large, the engineer might want to materialize it into Iceberg rather than federate every query. The rubric for this topic includes "when to federate vs ingest" as a sub-area, and a short pointer at the end would have been valuable. Not strong enough to drop the score below the threshold but worth noting for future similar questions.

---

## Resource fixes needed

Minor only — no blocking gaps for this topic.

- **LOW** — In whichever resource covers the Postgres connector (likely `resources/` Trino federation file), add a short callout that EXPLAIN output for JDBC pushdown typically appears as predicate on the `TableHandle`/`TableScan` rather than a separate filter node. Engineers reading EXPLAIN need to know what success looks like.
- **LOW** — Add a paragraph on the "federate vs ingest" tradeoff for hot Postgres views: when query latency or read-replica load becomes a problem, materialize into Iceberg via Spark/dbt rather than federating.
- **OPTIONAL** — A small note that Trino-side aggregate pushdown (over base tables) is separate from view-internal aggregation (always done in Postgres when the view is referenced).

---

## Pattern observation

This answer is well above the topic's 4.5 threshold and reflects strong recent resource quality on this topic. The running average for this topic is now at the pass bar; one more strong answer on a different angle (e.g., cross-catalog joins, when to federate vs ingest, complex pushdown like LIKE/range predicates) should consolidate the PASS.
