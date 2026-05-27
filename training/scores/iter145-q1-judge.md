# Iter145 Q1 — Judge Score

**Question topic**: Trino query audit history (compliance) + identifying expensive queries.

---

## Score breakdown

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | System table names and columns are correct, but multiple event listener property names are wrong (will not load). |
| Clarity for SaaS engineer | 5 | Well structured, jargon is explained, distinguishes "live in-memory" vs "persisted" cleanly. |
| Practical usefulness | 3 | The compute-killer recipes are good; however, the HTTP/Kafka/MySQL config blocks contain incorrect property names — a copy-paste user would hit "Configuration property ... is not valid" errors on coordinator startup. |
| Completeness | 5 | Covers built-in vs persistent, three listener options, JWT identity flow, expensive-query queries, and persistent-store queries. Excellent scope. |

**Average = (3 + 5 + 3 + 5) / 4 = 4.0**

PASS threshold = 4.5. **Verdict: FAIL**.

---

## Verified correct (via WebSearch + Trino source)

1. **`system.runtime.queries` and `system.runtime.tasks` exist and are ephemeral on the coordinator** — CONFIRMED. Defaults `query.max-history=100` and `query.min-expire-age=15m` match Trino docs.
2. **`system.runtime.queries` columns** (`query_id`, `state`, `user`, `source`, `query`, `resource_group_id`, `queued_time_ms`, `planning_time_ms`, `created`, `end`) — CONFIRMED against trino.io/docs/current/connector/system.html and prior iteration verification (rubric line 4574).
3. **`system.runtime.tasks` columns** `physical_input_bytes` and `split_cpu_time_ms` — CONFIRMED via TaskSystemTable.java source. Full schema includes both columns at the documented names.
4. **`event-listener.name=http` / `kafka` / `mysql`** — CONFIRMED as the three built-in open-source event listeners.
5. **No built-in file event listener** — CONFIRMED. Only HTTP, Kafka, MySQL, and OpenLineage ship out of the box.
6. **`event-listener.config-files` in `config.properties`** — CONFIRMED as the correct property name.
7. **JWT `sub` claim → Trino `user` identity flow** — Conceptually correct. Trino's JWT authenticator maps the subject claim to the principal/user, which is what flows into `system.runtime.queries.user` and `QueryCompletedEvent`. Matches prod_info.md auth section.

---

## Errors and gaps

### CRITICAL — HTTP event listener property name is wrong (will not load)

Answer (line 27):
```properties
http.event-listener.connect-ingest-uri=http://your-audit-api:8080/trino-events
```

Verified (trino.io/docs/current/admin/event-listeners-http.html):
```properties
http-event-listener.connect-ingest-uri=http://your-audit-api:8080/trino-events
```

Hyphen, not dot. With the wrong property the coordinator will fail to start with "Configuration property 'http.event-listener.connect-ingest-uri' was not used".

### CRITICAL — Kafka event listener property names are wrong

Answer (lines 41-44):
```properties
event-listener.name=kafka
kafka.bootstrap.servers=kafka1:9092,kafka2:9092,kafka3:9092
kafka.event-listener.topic=trino-query-events
```

Verified (trino.io/docs/current/admin/event-listeners-kafka.html):
```properties
event-listener.name=kafka
kafka-event-listener.broker-endpoints=kafka1:9092,kafka2:9092,kafka3:9092
kafka-event-listener.completed-event.topic=trino-query-events
kafka-event-listener.created-event.topic=trino-query-created   # if you want started events
```

Bootstrap servers does not exist; the property is `kafka-event-listener.broker-endpoints`. There is no single `topic` property — created and completed events have separate topic properties.

### CRITICAL — MySQL event listener property names are wrong

Answer (lines 62-67):
```properties
mysql.event-listener.connection-url=jdbc:mysql://mysql-host:3306/trino_audit
mysql.event-listener.connection-user=trino_audit_user
mysql.event-listener.connection-password=${MYSQL_PASSWORD}
mysql.event-listener.table=query_log
```

Verified (trino.io/docs/current/admin/event-listeners-mysql.html):
```properties
mysql-event-listener.db.url=jdbc:mysql://mysql-host:3306/trino_audit?user=trino_audit_user&password=${MYSQL_PASSWORD}
```

Hyphen prefix `mysql-event-listener.` not dot. The single property is `db.url`. Credentials are embedded inside the JDBC URL — there are NO separate user/password properties. The table name is hard-coded as `trino_queries` and is NOT configurable. The answer's claim that the table is auto-created with all event fields is correct in spirit, but the engineer cannot rename it.

### MEDIUM — Missing `etc/event-listener.properties` vs per-listener filename guidance

Trino's standard pattern is one properties file per listener (e.g. `etc/http-event-listener.properties`, `etc/kafka-event-listener.properties`, `etc/mysql-event-listener.properties`) all listed in `event-listener.config-files`. The answer puts everything in a single `etc/event-listener.properties` — Trino supports this for a single listener, but the example of registering multiple at once is missing.

### LOW — `query.max-history=100` is the default but worth noting it's queries not minutes

The answer says "old entries expire after `query.max-history` (default 100 queries) and `query.min-expire-age` (default 15 minutes)" — phrasing is accurate but the engineer should know that both must be exceeded for eviction (whichever is more restrictive). Minor clarity point.

### LOW — Persistent store column names are speculative

The "Persistent Query History" section uses columns like `bytes_scanned`, `query_text`, `completed_at`, `created_at`. These are reasonable names but they are NOT what the MySQL event listener actually produces (its auto-created `trino_queries` table has its own fixed schema). The answer should either (a) note the example assumes an Iceberg landing table you control, or (b) reference the actual MySQL listener schema. Currently the persistent-store queries look like they would run as-is against the MySQL listener output, but they won't.

---

## Resource fix recommendations

**Resource fix queued (HIGH priority)** for the Trino observability resource (likely `resources/14-trino-observability.md` or wherever event-listener config is documented):

1. Replace all instances of `http.event-listener.*` with `http-event-listener.*` (hyphen prefix).
2. Replace `kafka.bootstrap.servers` with `kafka-event-listener.broker-endpoints`. Replace `kafka.event-listener.topic` with the split `kafka-event-listener.completed-event.topic` and `created-event.topic`.
3. Replace `mysql.event-listener.connection-url` and related with single property `mysql-event-listener.db.url` (with user/password embedded in JDBC URL). Note that the MySQL listener table name is hard-coded to `trino_queries`.
4. Add the standard one-file-per-listener convention with `event-listener.config-files=etc/http-event-listener.properties,etc/mysql-event-listener.properties`.
5. Add an explicit "the MySQL event listener writes to a fixed table named `trino_queries` — schema is auto-managed and not customizable" callout.
6. Either correct the persistent-store query example schemas or label them as "assumes you control the Iceberg landing table schema, not the raw MySQL listener output".

---

## Verdict: **FAIL** (avg 4.0 < 4.5)

The answer is structurally excellent and correct about *what* Trino offers (system tables, three built-in event listeners, JWT identity flow), but every single `etc/*.properties` config snippet has wrong property names that will not load. For a question explicitly about setting up compliance audit logging, broken config syntax is a primary failure mode. An engineer copy-pasting this would lose the better part of a day debugging "configuration property not used" errors against three different listeners.
