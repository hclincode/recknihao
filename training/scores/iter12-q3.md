# Iter 12 Q3 — Trino Query Audit Trail

## Question summary
Security auditors want a log of who queried which customer's data and when. The engineer has no existing audit trail for Trino queries and needs to know whether there is a standard mechanism and where that log lives.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | What the responder said was not wrong: access control governs who can run queries but does not log them, and Trino does expose structured query events via an SPI. The statement that coordinator logs "already contain query events" is technically true at a coarse level (server.log captures some query lifecycle entries) but misleading — standard coordinator logs are not a structured, machine-readable audit trail. Nothing factually wrong, but one imprecise claim. |
| Beginner clarity | 3 | The honest "I can't fully answer this" framing is clear and the contrast between access control vs. audit logging is a useful conceptual distinction. However, the follow-up guidance ("check Trino's logging configuration") is vague and the "SPI" reference is unexplained jargon that a beginner cannot act on. The question asking the engineer to clarify application-layer vs. Trino-layer audit is reasonable but delays the answer unnecessarily — both layers have well-known answers. |
| Practical applicability | 1 | The engineer cannot take a single concrete next step from this response. The HTTP event listener (a built-in Trino plugin shipping since Trino 350+) was not named. Community plugins (trino-querylog) were not named. The fields captured per query event (user, principal, query text, query ID, session source, start time, end time, accessed tables) were not described. An engineer reading this response still has no idea what to deploy or configure. |
| Completeness | 1 | The core question — "is there a standard way to capture that kind of audit trail, and where does that log live?" — was not answered. Trino has two well-documented answers: (1) the built-in HTTP event listener (configured in etc/http-event-listener.properties, ships with Trino, POSTs QueryCreatedEvent and QueryCompletedEvent as JSON to any HTTP endpoint), and (2) the EventListener SPI for custom plugins. Neither was explained. The question also contained a concrete multi-tenant angle ("user X queried tenant Y's data at 3pm") that maps directly to the session principal + source + accessed tables fields in QueryCompletedEvent — that specificity was not addressed at all. |
| **Average** | **2.00** | |

## Topic updated

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

- Prior avg: 3.958 (6 questions, scores: 1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00)
- New score this question: 2.00
- New running avg: (1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00 + 2.00) / 7 = 25.75 / 7 = **3.679**
- Status: PASSED (3.679 >= 3.5 threshold) — but this answer reveals a coverage gap that will recur

## Key finding

Trino has a built-in audit mechanism — the HTTP event listener — that the resources do not cover at all. The responder correctly identified the resource gap and did not hallucinate, but the gap itself is a genuine hole: query audit logging is a security-adjacent, auditor-facing requirement that every production B2B SaaS will face, and the canonical Trino answer (HTTP event listener + JSON payload to a log aggregator) is well-documented and deployable on the on-prem k8s stack without any third-party software.

## Resource gap

Add a "Query audit logging" section to `resources/05-multi-tenant-analytics.md`. The section must cover:

1. **What Trino provides natively**: The HTTP event listener (`etc/http-event-listener.properties`) is a built-in plugin (no extra download required for Trino 467). Configure it with `http-event-listener.connect-ingest-uri = http://your-log-aggregator/trino-events` and reference it via `event-listener.config-files = etc/http-event-listener.properties` in `config.properties`. Enable `log-created=true` and `log-completed=true`.

2. **What fields each event captures**: `QueryCompletedEvent` JSON includes: `user` (the Trino principal — maps to your per-tenant role), `principal` (the authenticated identity), `query` (full SQL text), `queryId`, `createTime`, `endTime`, `queriedColumns` (list of catalog.schema.table.column touched), `remoteClientAddress`, and `source` (application name set by the client). This directly produces "user X queried tenant Y's data at timestamp T" log records.

3. **Where the log lives on the on-prem k8s stack**: The HTTP event listener POSTs JSON to any HTTP endpoint. On-prem options that require no cloud services: (a) POST to a local Loki instance (deployed as a k8s pod alongside Trino, queryable via Grafana); (b) write to a local file via a sidecar log aggregator (Filebeat or Fluentd); (c) POST to a simple FastAPI receiver that appends to an audit log table in Postgres or an Iceberg table in MinIO. Option (c) is particularly relevant for the production stack — audit events as an Iceberg table means the security auditor can run SQL against the audit trail.

4. **The EventListener SPI**: For custom behavior (e.g., writing to a specific database, filtering by tenant, adding application-layer context not in the session), the EventListener SPI allows a Java plugin that receives `QueryCreatedEvent` and `QueryCompletedEvent` objects. Community implementations include `trino-querylog` (writes one JSON line per query to a rotating log file) and `cloudandthings/trino-event-logger` (JDBC to any database). These require building and deploying a JAR to Trino's `plugin/` directory.

5. **Connecting to tenant isolation**: Because each tenant query runs under a dedicated Trino role (e.g., `role_tenant_acme`), the `user` field in the audit event already carries the tenant identity. No additional tagging is needed if the role-per-tenant setup from the earlier isolation section is in place.
