# Iter 182 Q1 — Resource Groups for Capping Concurrent Federation Queries

## Answer

**What resource groups are and how they work**

Resource groups are Trino's native mechanism for limiting the concurrency of queries in a workload. Think of them as a gate controlling how many queries can run simultaneously against a specific catalog or user pattern. When you set a `hardConcurrencyLimit` on a resource group, Trino enforces it strictly: queries beyond that limit don't fail immediately — they queue and wait for a slot to open up (up to a `maxQueued` limit, after which subsequent queries are rejected). This is exactly what you need for federation, where too many concurrent queries to Postgres means too many JDBC connections and replica meltdown.

The three critical properties you'll tune:

- **`hardConcurrencyLimit`**: the absolute ceiling on concurrent queries in the group. Set this to `2` to match your requirement.
- **`maxQueued`**: how many queries can wait in queue before new arrivals are rejected. Set this higher (e.g., `20`) to be forgiving; people waiting in queue won't see immediate failure.
- **`softMemoryLimit`**: a memory-based eviction trigger (as a percentage of the coordinator's heap). Not strictly necessary for connection bounding, but useful for preventing memory runaway from federation queries.

---

### How to identify federation queries to target with a resource group

You identify queries using the **`source` label** — a client-supplied identifier passed when opening a Trino connection. The resource group selector matches this source against a regex pattern.

**Critical gotcha**: the source must be explicitly set by the client, or the selector doesn't match and your limit is bypassed entirely.

Set the source via:
1. JDBC URL: `jdbc:trino://coordinator:8080/iceberg?source=federation-queries`
2. CLI: `trino --server coordinator:8080 --source federation-queries`
3. HTTP header: `X-Trino-Source: federation-queries`

Without this setup step, federation queries fall through to a catch-all rule and ignore your limits.

---

### Concrete resource-groups.json configuration

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "softMemoryLimit": "30%",
      "hardConcurrencyLimit": 2,
      "maxQueued": 20,
      "schedulingPolicy": "fair"
    },
    {
      "name": "default",
      "softMemoryLimit": "70%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 1000,
      "schedulingPolicy": "fair"
    }
  ],
  "selectors": [
    {
      "user": ".*",
      "source": ".*federation.*",
      "group": "federation"
    },
    {
      "user": ".*",
      "group": "default"
    }
  ]
}
```

The `selectors` array is evaluated top-to-bottom. Queries with a source containing `federation` land in the federation group (max 2 concurrent); everything else lands in the default group.

---

### How to wire it to the coordinator

Place the JSON file at `etc/resource-groups.json` in your Trino coordinator pod, then enable it in `etc/config.properties`:

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

Deploy via a Kubernetes ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-resource-groups
  namespace: trino
data:
  resource-groups.json: |
    { ... }
---
# In the Trino coordinator pod spec:
volumeMounts:
  - name: resource-groups
    mountPath: /etc/trino/resource-groups.json
    subPath: resource-groups.json
volumes:
  - name: resource-groups
    configMap:
      name: trino-resource-groups
```

Restart the coordinator after mounting. The resource group configuration is live.

---

### What happens when the limit is hit — queries queue, not reject

When the third federation query arrives (you've set `hardConcurrencyLimit: 2`), it enters the queue and waits. If the queue hits `maxQueued: 20`, the 21st query is rejected. Queued queries are not failed; they just wait for a slot. This is gentler than rejection and lets your users' tools (dashboards, notebooks, ETL) handle the delay gracefully. Adjust `hardConcurrencyLimit` based on your replica's appetite — 2 concurrent federation queries is conservative; some teams run 5–10 safely with proper pooling.

---

### Additional defenses: PostgreSQL-side guardrails

Resource groups cap **Trino queries**, not JDBC connections directly. Layer these defenses outside Trino:

**1. PgBouncer in transaction-pooling mode**

OSS Trino 467's PostgreSQL connector has no built-in JDBC connection pool. Each query opens a raw JDBC connection held open for the full query duration. PgBouncer multiplexes many Trino connections onto fewer real Postgres backends.

```properties
# In etc/catalog/app_pg.properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
```

`prepareThreshold=0` is required for PgBouncer transaction-pooling mode — without it you'll get intermittent `ERROR: prepared statement "S_1" does not exist` errors.

**2. Postgres role CONNECTION LIMIT**

Defense in depth — even if PgBouncer is misconfigured, Postgres itself will reject connections beyond the limit:

```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

**3. Postgres statement_timeout on the replica**

Kill runaway federation queries server-side:

```sql
ALTER ROLE trino_reader SET statement_timeout = '300000';  -- 5 minutes in milliseconds
```

Together these three layers mean: at most 2 concurrent federation queries (Trino resource group), each opening 1 JDBC connection per table scan, pooled through PgBouncer (capped at 50 real Postgres connections), with any statement running over 5 minutes killed by Postgres itself.

---

### How to verify it's working

**Check resource group assignment**:

```sql
SELECT query_id, "user", source, resource_group_id, state
FROM system.runtime.queries
WHERE source LIKE '%federation%'
ORDER BY created DESC
LIMIT 10;
```

The `resource_group_id` column should show `federation` for your capped queries.

**Monitor Postgres connection count on the replica**:

```sql
SELECT count(*), state, wait_event_type
FROM pg_stat_activity
WHERE usename = 'trino_reader'
GROUP BY state, wait_event_type;
```

With `hardConcurrencyLimit: 2`, you should see at most 2 active statements.

**Trino Web UI**: Visit `http://coordinator:8080/ui/queries` and look at the resource groups view. With all 2 slots full, new queries will show queued with their wait time.

**Observe queuing in action**: Submit 5 federation queries in quick succession. The first 2 will be `RUNNING`; queries 3–5 will be `QUEUED` until earlier ones finish.

---

The combination of resource groups (capping concurrent queries), PgBouncer (pooling connections), Postgres role `CONNECTION LIMIT` (hard stop at the database), and `statement_timeout` (killing runaway statements) is the production-standard pattern for protecting a Postgres replica from Trino federation load.
