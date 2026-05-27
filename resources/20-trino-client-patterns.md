# Trino Client Patterns for SaaS Embedded Analytics APIs

A practical guide for SaaS engineers building multi-tenant embedded analytics APIs on top of **Trino 467** (on-prem Kubernetes, MinIO, JWT auth). Focused on the three things that bite you first: JDBC connection pooling, the "too many open connections" error, and prepared statements.

> **Production stack assumed**: Trino 467 with Iceberg connector, on-prem k8s, MinIO via S3, JWT auth. Your API service is a JVM app (Spring Boot, Micronaut, Quarkus, Ktor, etc.) running in the same k8s cluster as Trino. No cloud-managed Trino, no Snowflake, no BigQuery.

---

## 1. Quick mental model

When your API service talks to Trino:

- Each Trino client connection is just an **HTTP session** with the coordinator. There's no persistent TCP socket like Postgres — it's HTTP request/response with long polling.
- A connection can run **only one query at a time**. To run N queries concurrently, you need N connections (or N HTTP clients).
- The coordinator has **two separate "concurrency" limits**:
  1. **HTTP connection limit** (`http-server.max-concurrency`) — how many open HTTP connections the Jetty server will accept.
  2. **Query admission limit** (resource groups `hardConcurrencyLimit`) — how many queries are allowed to actively run after the HTTP request lands.
- These are different layers. Mixing them up is the #1 cause of wrong-fix incidents in production.

Keep this picture in mind for the rest of this doc.

---

## 2. JDBC connection pooling with HikariCP

Trino has a first-class JDBC driver. You pool it with **HikariCP** like any other JDBC datasource. There is nothing exotic here — the failure mode "you can't pool Trino" is a myth.

### 2.1 Driver and URL

- **Driver class**: `io.trino.jdbc.TrinoDriver`
- **Maven coordinates**: `io.trino:trino-jdbc:467`
- **JDBC URL shape**:

  ```
  jdbc:trino://<coordinator-host>:8080/<catalog>/<schema>?<params>
  ```

  Production example (TLS + JWT):

  ```
  jdbc:trino://trino-coordinator.trino.svc.cluster.local:8443/iceberg/analytics?SSL=true&SSLVerification=FULL&SSLTrustStorePath=/etc/ssl/trino-truststore.jks&SSLTrustStorePassword=changeit
  ```

  JWT is provided per-request via the `accessToken` property on the connection, or by setting `user` plus calling `setProperty("accessToken", jwt)` from your code. The token represents the end user (or service principal) and is what OPA evaluates for authorization.

### 2.2 HikariCP configuration (typical SaaS API service)

```properties
# Datasource basics
dataSourceClassName=io.trino.jdbc.TrinoDriver
jdbcUrl=jdbc:trino://trino-coordinator.trino.svc.cluster.local:8443/iceberg/analytics?SSL=true&SSLVerification=FULL&SSLTrustStorePath=/etc/ssl/trino-truststore.jks

# Pool sizing — see Section 2.3 for sizing logic
maximumPoolSize=20
minimumIdle=5

# Timeouts
connectionTimeout=30000      # 30s — time to acquire from pool
validationTimeout=3000       # 3s — time to validate connection
idleTimeout=600000           # 10min — kill idle connections
maxLifetime=1800000          # 30min — recycle connections before coordinator drops them

# Validation (Trino has no native driver-level isValid that round-trips)
connectionTestQuery=SELECT 1
```

### 2.3 Pool sizing rules of thumb

Trino connections are **lightweight** (HTTP long-poll). You do not need huge pools:

| API service instance count | Pool per instance | Total connections to coordinator |
|---|---|---|
| 5 instances | 10 | 50 |
| 20 instances | 20 | 400 |
| 50 instances | 20 | 1000 |

- **Typical sweet spot**: `maximumPoolSize=10–20` per API service replica.
- **Bad pattern**: `maximumPoolSize=100+` per replica. You waste coordinator memory tracking idle HTTP sessions and you will hit `http-server.max-concurrency` faster.
- **Concurrency rule**: each connection runs one query at a time. If your p99 query latency is 2 seconds and you need to serve 100 QPS per replica, you need ~200 in-flight query capacity → multiple replicas, not one giant pool.

### 2.4 Why `SELECT 1` for validation

Trino's JDBC driver implements `Connection.isValid()` but it issues an HTTP round-trip anyway. Using `connectionTestQuery=SELECT 1` is explicit and predictable. The query is metadata-only on the coordinator (no worker involvement, no MinIO reads).

---

## 3. The "Too many open connections" error

This is the trap that caused the original wrong answer in iter149. **Read this section carefully.**

### 3.1 What the error looks like

In your API service logs you see something like:

```
io.trino.jdbc.TrinoConnection: failed to obtain HTTP connection: ...
java.io.IOException: Server returned HTTP response code: 503
or
org.eclipse.jetty.io.EofException
```

In Trino coordinator logs (`/var/log/trino/server.log`):

```
HTTP server rejected connection: max concurrent connections exceeded
```

### 3.2 Root cause

The coordinator's Jetty HTTP server has a hard cap on concurrent HTTP connections, controlled by:

```properties
# etc/config.properties on the coordinator
http-server.max-concurrency=1000
```

The default is low (a few hundred in older versions, sometimes 1024). When the total number of open HTTP connections **from all clients to all endpoints** (UI, JDBC pools, CLI, REST) exceeds this number, Jetty rejects new connections at the TCP/HTTP layer — **before any Trino query logic runs**.

### 3.3 This is NOT a resource group problem

This is the misconception to drill into your head:

- **Resource groups** (`resource-groups.json`, `hardConcurrencyLimit`) control **how many queries are admitted to run** after the HTTP request lands on the coordinator. They control query queueing, not socket acceptance.
- **`http-server.max-concurrency`** controls **how many HTTP connections Jetty will accept at all**. It runs at a lower layer than resource groups.

If you get "too many open connections" and you raise `hardConcurrencyLimit` in resource groups, **nothing will change**. The connection was rejected before resource groups ever saw it.

### 3.4 The fix

On the **coordinator** node, in `etc/config.properties`:

```properties
http-server.max-concurrency=1000
http-server.http.port=8080
http-server.https.port=8443
```

Pick the value based on your total expected concurrent client connections (see sizing table in Section 2.3). Common production values: **1000–4000**.

In a Kubernetes deployment, this goes into the ConfigMap that mounts `config.properties` into the coordinator pod. **Restart the coordinator** for changes to take effect.

### 3.5 Sizing `http-server.max-concurrency` for your pool

Worked example, multi-tenant API:

- 50 API service replicas
- HikariCP `maximumPoolSize=20` per replica
- 5 dbt Cloud jobs that each open ~10 connections
- Trino Web UI ~5 concurrent users (~20 connections of overhead)
- CLI / ad-hoc → reserve 50

Total estimated worst case:
```
50 * 20  = 1000  (API services)
+ 5 * 10 =   50  (dbt)
+ 20     =   20  (UI overhead)
+ 50     =   50  (CLI / ad-hoc)
-----------------
~ 1120 connections
```

Set `http-server.max-concurrency=1500` to leave headroom. Don't set it to infinity — a runaway client should still get rejected eventually.

---

## 4. PREPARE / EXECUTE and JDBC PreparedStatement

Trino 467 fully supports SQL `PREPARE`, `EXECUTE`, and `EXECUTE IMMEDIATE` (the latter was added server-side in **Trino 418**). The JDBC `PreparedStatement` interface works normally with `?` placeholders, but **does NOT use `EXECUTE IMMEDIATE` by default** — see Section 4.4 for the `explicitPrepare=false` JDBC URL parameter required to opt in.

### 4.1 SQL-level PREPARE / EXECUTE

```sql
PREPARE get_events FROM
  SELECT event_id, event_type, ts
  FROM iceberg.analytics.events
  WHERE tenant_id = ?
    AND event_date BETWEEN ? AND ?;

EXECUTE get_events USING 'tenant-abc', DATE '2026-05-01', DATE '2026-05-31';
```

Prepared statements are **session-scoped**: they live on the connection. If your HikariCP pool recycles the connection, the prepared statement is gone. This is fine — see "no plan cache" caveat below.

### 4.2 JDBC PreparedStatement

```java
String sql =
    "SELECT event_id, event_type, ts " +
    "FROM iceberg.analytics.events " +
    "WHERE tenant_id = ? AND event_date BETWEEN ? AND ?";

try (Connection conn = dataSource.getConnection();
     PreparedStatement ps = conn.prepareStatement(sql)) {

    ps.setString(1, tenantId);
    ps.setDate(2, java.sql.Date.valueOf(startDate));
    ps.setDate(3, java.sql.Date.valueOf(endDate));

    try (ResultSet rs = ps.executeQuery()) {
        while (rs.next()) {
            // ...
        }
    }
}
```

This works out of the box with `io.trino.jdbc.TrinoDriver`. By default, the driver translates `?` bindings into a two-step `PREPARE` + `EXECUTE` pair on the wire. To collapse this into a single `EXECUTE IMMEDIATE` round-trip, you must explicitly opt in via the `explicitPrepare=false` JDBC URL parameter — see Section 4.4 for the exact URL form and caveats.

### 4.3 CRITICAL caveat: Trino does NOT cache query plans

This is the most-missed fact about Trino prepared statements. **Read carefully:**

| What Postgres / Oracle gives you | What Trino gives you |
|---|---|
| Server-side query plan cached per prepared statement | **No plan cache.** Every `EXECUTE` re-plans from scratch. |
| Bind variables can avoid plan-cache-pollution | No cache to pollute — but no reuse either. |
| Major latency win on repeated execution | Minor parse-time win only. |

What `PreparedStatement` in Trino **does** give you:

1. **SQL injection safety** — bind parameters are properly escaped/typed. Don't string-concatenate user input into queries.
2. **SQL text parsed once per connection** — small CPU win on the coordinator for the parse phase.
3. **Cleaner client code** — type-safe parameter binding instead of string templating.

What it **does NOT** give you:

- **Plan reuse across requests.** If your API serves 1000 requests/second all running the same query template, the coordinator re-plans 1000 times per second. This is by design in Trino.
- **A reason to use long-lived prepared statements across pool checkouts** — the plan isn't saved, so `PREPARE` once and `EXECUTE` many is no faster end-to-end than `PREPARE` + `EXECUTE` every time.

**Implication for your API design**: if you have a query template where planning time dominates (complex joins, many partitions, dynamic filter pushdown), the lever is **query simplification or materialization**, not prepared statements. Consider:

- Pre-aggregate via Iceberg materialized data (a dbt model that compacts to a smaller table).
- Add explicit filters that prune partitions before planning gets expensive.
- Use `EXPLAIN` to confirm planning vs. execution time split.

### 4.4 EXECUTE IMMEDIATE — server-side in Trino 418, JDBC opt-in in Trino 431+

`EXECUTE IMMEDIATE` collapses `PREPARE` + `EXECUTE` into a single statement, which means **one HTTP round-trip instead of two**:

```sql
EXECUTE IMMEDIATE
  'SELECT event_id FROM iceberg.analytics.events
   WHERE tenant_id = ? AND event_date = ?'
  USING 'tenant-abc', DATE '2026-05-26';
```

**Version history (get these straight — they are commonly misquoted):**
- **Trino 418** — added `EXECUTE IMMEDIATE` as a server-side SQL statement. From this version onward you can run the SQL form above by hand.
- **Trino 431** — added the JDBC driver optimization that lets `PreparedStatement` use `EXECUTE IMMEDIATE` on the wire (one round-trip) instead of the two-step `PREPARE` + `EXECUTE`. **This optimization is opt-in, not on by default.**

**CRITICAL — the JDBC driver does NOT automatically use `EXECUTE IMMEDIATE`.** The driver's `explicitPrepare` JDBC parameter defaults to `true`, which means by default `PreparedStatement.executeQuery()` still does the two-step `PREPARE` + `EXECUTE` (two HTTP round-trips). To make the driver use `EXECUTE IMMEDIATE` (one round-trip), you must explicitly add `explicitPrepare=false` to the JDBC URL:

```
jdbc:trino://coordinator:8080/iceberg?SSL=true&SSLVerification=FULL&SSLTrustStorePath=/etc/trino/truststore.jks&explicitPrepare=false
```

Without `explicitPrepare=false`, no amount of driver upgrade or server upgrade will change the wire behavior — the default is two round-trips. This is a frequent source of "I upgraded to Trino 467 / driver 467 and didn't see the latency drop" surprises: the driver upgrade is necessary but not sufficient — you must also flip the URL parameter.

**Even with `explicitPrepare=false`, there is STILL no plan cache.** This bears repeating because it is the biggest misconception about `EXECUTE IMMEDIATE`. The optimization saves **one HTTP round-trip per query** (network latency only); it does NOT cache the query plan. Trino still re-plans the query from scratch on every `EXECUTE` (whether the call arrives as two-step PREPARE+EXECUTE or as one-step EXECUTE IMMEDIATE). The savings are bounded by your network RTT (typically 10–30ms on-prem), not by your planning cost. If planning dominates your latency, `explicitPrepare=false` will not help — re-read Section 4.3 and consider materialization instead.

When to flip `explicitPrepare=false`:
- Per-request API patterns where p50 latency is in the 50–200ms range and one extra round-trip is a measurable fraction of total time.
- Trino driver 431 or newer (the optimization didn't exist before).
- You've confirmed network RTT (not planning time) is the bottleneck via `EXPLAIN ANALYZE` and HTTP wire traces.

When `explicitPrepare=false` does NOT help:
- Planning-dominated workloads (complex joins, many partitions, dynamic filters).
- Drivers older than 431 (the parameter exists but the optimization doesn't).
- Workloads that don't use `PreparedStatement` (raw `Statement` already does one round-trip).

---

## 5. Symptom-to-lever mapping table

Bookmark this. It is the most useful piece of this document during an incident.

| Symptom | Common wrong guess | Correct fix |
|---|---|---|
| `Too many open connections` / Jetty rejecting HTTP | Resource group limit too low | `http-server.max-concurrency` in coordinator `config.properties` |
| Queries sitting in QUEUED state, slow admission | HTTP connection limit | Resource group `hardConcurrencyLimit` in `resource-groups.json` |
| Same query re-plans every request, planning dominates latency | "JDBC isn't using PreparedStatement properly" | Trino has **no plan cache by design** — `PREPARE`/`EXECUTE` work but don't reuse plans. Simplify query or materialize. |
| High per-request connection setup latency | "Can't pool Trino connections" | Use **HikariCP** with `io.trino.jdbc.TrinoDriver` — standard pooling works fine |
| One tenant's heavy queries starve others | Add a per-tenant connection limit in HikariCP | Resource group `hardConcurrencyLimit` on a per-tenant sub-group — apply at Trino layer, not pool layer |
| `SSLHandshakeException` after switching to HTTPS port | Wrong port | URL needs `SSL=true&SSLTrustStorePath=...` and you must connect to the HTTPS port (8443), not 8080 |
| JWT expired mid-request | "Refresh token from pool" | JWT goes per-connection-acquire, not per-pool-init. Set `accessToken` property when checking out a connection, or use a `HikariDataSource` wrapper that injects a fresh token per `getConnection()` call. |

---

## 6. Complete example: Spring Boot + HikariCP + Trino 467

### 6.1 `pom.xml`

```xml
<dependency>
    <groupId>io.trino</groupId>
    <artifactId>trino-jdbc</artifactId>
    <version>467</version>
</dependency>
<dependency>
    <groupId>com.zaxxer</groupId>
    <artifactId>HikariCP</artifactId>
    <version>5.1.0</version>
</dependency>
```

### 6.2 `application.yml`

```yaml
spring:
  datasource:
    hikari:
      driver-class-name: io.trino.jdbc.TrinoDriver
      jdbc-url: >-
        jdbc:trino://trino-coordinator.trino.svc.cluster.local:8443/iceberg/analytics
        ?SSL=true
        &SSLVerification=FULL
        &SSLTrustStorePath=/etc/ssl/trino-truststore.jks
        &SSLTrustStorePassword=${TRINO_TRUSTSTORE_PASSWORD}
      maximum-pool-size: 20
      minimum-idle: 5
      connection-timeout: 30000
      validation-timeout: 3000
      idle-timeout: 600000
      max-lifetime: 1800000
      connection-test-query: SELECT 1
      pool-name: trino-analytics-pool
```

### 6.3 Per-request JWT injection (Kotlin example)

Because JWTs are per-end-user and short-lived, you typically inject the token when checking out a connection — not at pool initialization.

```kotlin
@Service
class TrinoQueryService(private val baseDataSource: HikariDataSource) {

    fun runForUser(jwt: String, sql: String, params: List<Any>): List<Row> {
        baseDataSource.connection.use { conn ->
            // Set per-user JWT on this checkout
            val trinoConn = conn.unwrap(io.trino.jdbc.TrinoConnection::class.java)
            trinoConn.setSessionProperty("query_max_run_time", "60s")
            // For JWT: pass via connection property at URL or via a custom DataSource wrapper.
            // Typical pattern: use a delegating DataSource that appends ?accessToken=<jwt> per checkout,
            // or use TrinoConnection.setClientInfo for headers handled by your auth plugin.

            conn.prepareStatement(sql).use { ps ->
                params.forEachIndexed { i, p -> ps.setObject(i + 1, p) }
                ps.executeQuery().use { rs ->
                    return rs.toRows()
                }
            }
        }
    }
}
```

> **Note**: JWT-per-connection requires a custom `DataSource` wrapper because HikariCP itself caches connections built from a fixed URL. The common production pattern is a thin wrapper that pulls a fresh JWT from the auth service and either rebuilds the connection properties or uses a custom HTTP header injection in the Trino client. Specific implementation depends on your auth service contract — defer to your platform team's standard wrapper.

### 6.4 Coordinator-side ConfigMap snippet (k8s)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-coordinator-config
data:
  config.properties: |
    coordinator=true
    node-scheduler.include-coordinator=false
    http-server.http.port=8080
    http-server.https.enabled=true
    http-server.https.port=8443
    http-server.max-concurrency=1500
    discovery.uri=http://trino-coordinator:8080
    query.max-memory=200GB
    query.max-memory-per-node=8GB
```

---

## 7. Anti-patterns to avoid

1. **One giant pool of 200+ connections** — wastes coordinator memory, hits `http-server.max-concurrency` first.
2. **Opening a new JDBC connection per HTTP request** — connection setup includes a JWT auth round-trip plus session init. Pool it.
3. **Assuming `PreparedStatement` will fix slow planning** — it won't; Trino has no plan cache. Fix the data shape.
4. **Raising `hardConcurrencyLimit` to fix "too many open connections"** — wrong layer; will not help. Fix `http-server.max-concurrency`.
5. **String-concatenating tenant IDs into SQL** — use `?` placeholders. Even though Trino re-plans, you still want SQL injection protection.
6. **Skipping TLS or JWT in non-prod** — production is JWT + TLS only. Test environments should match or you'll discover auth bugs in prod.

---

## 8. Key terms

- **JDBC driver**: Java library that lets a JVM app speak the database wire protocol. For Trino: `io.trino:trino-jdbc:467`.
- **Connection pool**: cache of pre-opened database connections, reused across requests. HikariCP is the JVM standard.
- **`http-server.max-concurrency`**: coordinator Jetty's cap on concurrent HTTP connections. Connection-layer admission control.
- **Resource group `hardConcurrencyLimit`**: cap on actively running queries per group. Query-layer admission control.
- **`PREPARE` / `EXECUTE`**: Trino SQL for parameterized statements. Parameter binding only — no plan reuse.
- **`EXECUTE IMMEDIATE`**: collapses PREPARE+EXECUTE into one round-trip. Server-side SQL form added in **Trino 418**; JDBC driver optimization added in **Trino 431**. The JDBC optimization is **opt-in** — you must add `explicitPrepare=false` to the JDBC URL to use it. Default JDBC behavior is still two-step PREPARE+EXECUTE. No plan cache either way.
- **`explicitPrepare`**: Trino JDBC URL parameter (default `true`). Set to `false` to make `PreparedStatement` use single-round-trip `EXECUTE IMMEDIATE` on Trino 431+ drivers. Has no effect on plan caching — only on wire round-trip count.
- **Plan cache**: server-side cache of compiled query plans. Postgres has one; **Trino does not**.
- **JWT (JSON Web Token)**: signed token your auth service issues to a user. Production Trino authenticates with this; OPA authorizes the query.
