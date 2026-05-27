# Score: iter58-q1
**Topic**: Multi-tenant analytics
**Score**: 4.8 / 5.0

## Dimension scores
- Completeness: 5/5
- Accuracy: 4/5
- Clarity: 5/5
- No hallucination: 5/5

## What the answer got right
- Correctly identifies Trino's built-in HTTP event listener as the right tool — no third-party plugin needed.
- Provides the exact properties file content (`etc/http-event-listener.properties`) with `event-listener.name=http`, `http-event-listener.connect-ingest-uri`, and `log-completed=true`. Matches Trino official docs.
- Correctly references it via `event-listener.config-files` in `etc/config.properties`.
- Calls out the Kubernetes ConfigMap mount pattern explicitly — practical for the on-prem k8s production stack.
- States plainly that the coordinator must be restarted for the event listener config to take effect (no hot-reload). This is the explicit gotcha called out in the question's expected-coverage list.
- All five nested JSON paths are correct: `context.user`, `metadata.query`, `metadata.queryId`, `metadata.queryState`, `ioMetadata.inputs[n].tableName`, `.columns[]`. Explicitly warns that the JSON is nested and that flat top-level keys return null.
- Provides a concrete JSON example matching the shape Trino actually emits.
- Covers all three on-prem storage destinations the resource calls out: Loki, Filebeat/ELK, Iceberg audit table in MinIO. Picks the Iceberg-in-MinIO option for the worked example, which is the most aligned with the production stack.
- Explains the role-per-tenant insight clearly: because each tenant authenticates with a JWT whose `sub` claim becomes `context.user`, the audit log already carries tenant identity with no extra tagging — directly maps to the production JWT auth setup.
- Answers both auditor questions with concrete SQL queries.
- Calls out `ioMetadata.inputs` as the second audit signal for detecting tenant principals touching base tables they shouldn't — matches the expected coverage.
- Closes with a 7-step deployment checklist that gives the engineer a clear sequence of next actions.

## What the answer missed or got wrong
- The audit table DDL uses `USING iceberg` syntax (Spark/Databricks SQL form). On Trino 467 the correct syntax is `WITH (format = 'PARQUET')` plus partitioning in the `WITH` clause. The resource file itself uses the same `USING iceberg` syntax, so the answer is faithful to the source — but in a Trino-only production stack this would not execute as written. Worth flagging because the question is specifically about Trino.
- The cross-tenant detection SQL relies on `query_text LIKE '%FROM analytics.events%'` and `trino_user LIKE '%-service-account'`. This is fragile: it depends on naming conventions and SQL formatting (whitespace, casing, comments, aliases all break the LIKE match). A more robust approach uses the `queried_tables` JSON column (which the audit schema includes) to check whether `analytics.events` appears in the parsed `ioMetadata.inputs` set. The answer correctly describes the right concept in prose ("match `context.user` against `ioMetadata.inputs.tableName`") but the example SQL doesn't actually implement that — it falls back to string matching on the raw query text.
- No mention that the production stack uses OPA for authz. Not strictly required for an audit-logging question, but a one-line note that the HTTP event listener is separate from the OPA authorization layer (and they should both be in place) would have rounded out the practical guidance.
- Minor: doesn't mention `createTime` / `endTime` as top-level event payload timestamps, though the table on line 39 alludes to it.

## Recommendation for teacher
The resource is solid and the answer faithfully reproduces it. Two small polish opportunities for the next revision:
1. In the audit table examples in `05-multi-tenant-analytics.md`, swap `USING iceberg` for the correct Trino `WITH (...)` syntax (or label the examples explicitly as Spark SQL). Right now the audit schema is shown in a context that implies it runs in Trino, but the syntax is Spark's.
2. Add a worked example of the cross-tenant detection query that parses `queried_tables` as JSON (e.g., using `json_extract` or a flattened column populated by the audit collector) rather than `LIKE` on the raw query text. That avoids the weak-ai-responder reaching for a fragile string-match pattern.

## Rubric update arithmetic
Previous: avg=4.298, q=57.
Score for this question = 4.75 (per the dimension table above; the 4.8 in the header is the rounded-to-one-decimal display)
new_avg = (4.298 * 57 + 4.75) / 58
       = (244.986 + 4.75) / 58
       = 249.736 / 58
       = 4.306
