## Score: 3.50 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 2.5 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3.5 |

## Points covered
- system.runtime.queries for live insight (with ephemeral caveat) — partially (covered concept and caveat, but query uses non-existent columns)
- HTTP event listener for durable audit logging — covered (config properties are valid)
- Iceberg audit log table structure — covered
- Weekly per-tenant usage report query — covered
- $files / $partitions metadata as alternative for storage sizing — partial ($files covered; $partitions not mentioned by name)
- Security: admin-only access to system.runtime.queries and query_audit_log — covered (strong P0 framing)

## Technical accuracy gaps

1. **`system.runtime.queries` does NOT have a `query_type` column.** The answer's first SQL query filters `WHERE query_type = 'SELECT'`, which will fail at parse time. Per Trino source (`QuerySystemTable.java`), the actual columns are: query_id, state, user, source, query, resource_group_id, queued_time_ms, analysis_time_ms, planning_time_ms, created, started, last_heartbeat, end, error_type, error_code. To filter for SELECTs, the answer would need to inspect the `query` text (e.g., `regexp_like(upper(query), '^\s*SELECT')`) or remove the filter.

2. **`system.runtime.queries` does NOT have a JSON `statistics` column.** The answer's `JSON_EXTRACT_SCALAR(statistics, '$.totalBytes')` and `JSON_EXTRACT_SCALAR(statistics, '$.elapsedTime')` will both fail — there is no `statistics` column at all in the runtime table. Bytes-scanned per query is simply not available from `system.runtime.queries`; only timing fields (queued_time_ms, analysis_time_ms, planning_time_ms) and identity fields are exposed. This is a fundamental error — the "Quick win" query is non-runnable as written, which directly undermines the practical applicability of that section.

3. **`statistics.totalBytes` is NOT a field on the HTTP event listener payload.** Per `io.trino.spi.eventlistener.QueryStatistics` source, there is no `totalBytes` field — it was removed (see PR #26524 and related). The correct field for bytes scanned from object storage is `statistics.physicalInputBytes`. Similarly there is no `statistics.elapsedTime`; the correct field name is `wallTime` (with `executionTime`, `queuedTime` etc. also available). The answer's documented field names will not match the actual JSON payload, so the column extraction code a SaaS engineer writes from this guide will silently produce nulls.

4. **`metadata.queryState`** — the QueryCompletedEvent metadata structure does include `queryState`, so this is correct.

5. HTTP event listener config (`event-listener.name=http`, `http-event-listener.connect-ingest-uri`, `http-event-listener.log-completed`) — verified correct against trino.io docs.

6. The Iceberg `$files` query with `partition.tenant_id` and `file_size_in_bytes` is syntactically valid Trino+Iceberg.

7. Minor: file path `/etc/http-event-listener.properties` would typically be `etc/http-event-listener.properties` relative to Trino home (the answer is inconsistent with the `etc/config.properties` reference style on the next line).

## Completeness gaps

- `$partitions` is not mentioned explicitly (only `$files`). The rubric calls out "$files/$partitions metadata as an alternative." A complete answer would show both, since `$partitions` gives a direct per-tenant aggregate (record_count, file_count, total_size) without manual `GROUP BY` if the table is partitioned by tenant.
- The answer does not mention that the principal in `user` column will be the JWT subject (which is how tenant identity is mapped in the prod environment), nor confirm that the production Trino 467 + OPA setup requires the OPA policy (not file-based access control) to enforce the security restriction. This was the prior rubric note on this topic.
- No mention that the audit collector service (the HTTP receiver) is something the engineer must build/operate — the answer skips over the operational lift of running the `audit-collector:8080` endpoint, batching writes, schema migration, retries on collector outage, etc.
- The Iceberg audit log table uses `create_time` (DATE) as a partition column but `completed_time` (TIMESTAMP) is what the report query filters on. This works but is not explained; a beginner could be confused why one is used for partitioning and another for filtering.
- `bytes_scanned` is described as "compressed bytes read from MinIO" — accurate framing for physicalInputBytes — but the answer should explicitly say "this maps to QueryStatistics.physicalInputBytes in the event payload."

## Verified (WebSearch)

- **system.runtime.queries schema** — verified via Trino source `QuerySystemTable.java`. No `query_type`, no `statistics` JSON column. Answer's first SQL is non-runnable.
- **HTTP event listener config properties** — verified at https://trino.io/docs/current/admin/event-listeners-http.html. `connect-ingest-uri`, `log-completed`, `log-created` are correct property names.
- **QueryStatistics SPI fields** — verified via Trino master source `QueryStatistics.java`. Field is `physicalInputBytes` (not `totalBytes`); time field is `wallTime` (not `elapsedTime`). `totalBytes` was removed from QueryStatistics.
- **Iceberg `$files` table and `file_size_in_bytes`** — verified per Trino Iceberg connector docs. Valid syntax.
- **Prod fit check** — the answer aligns with prod stack (Trino 467, Iceberg on MinIO via S3). Security warning correctly invokes OPA. JWT principal mapping should have been called out explicitly.

## Summary

The answer's structure, narrative framing, security warning, and Iceberg audit table design are excellent — beginner-friendly, practical, and well-organized. However, the two flagship SQL examples in the "Quick win" section reference columns that do not exist in `system.runtime.queries`, and the documented HTTP event listener payload field names (`statistics.totalBytes`, `statistics.elapsedTime`) are wrong. A SaaS engineer who copies the first query verbatim will get a parse error; one who builds an audit collector against the documented field names will get NULL columns. These are not minor typos — they break the runnable promise of the answer. Score reflects strong pedagogy and structure undermined by core factual errors on column/field names.

Sources verified:
- [System connector — Trino docs](https://trino.io/docs/current/connector/system.html)
- [HTTP event listener — Trino docs](https://trino.io/docs/current/admin/event-listeners-http.html)
- [QuerySystemTable.java (Trino source)](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/connector/system/QuerySystemTable.java)
- [QueryStatistics.java (Trino SPI source)](https://github.com/trinodb/trino/blob/master/core/trino-spi/src/main/java/io/trino/spi/eventlistener/QueryStatistics.java)
- [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)
