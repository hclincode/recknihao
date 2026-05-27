# Iter 197 Q2 — Dynamic Catalog Management Without Restarts

## Answer

Trino 467 does have a way to manage catalogs without restarting pods. It's called **dynamic catalog management**, enabled via a configuration flag.

### How it works: `catalog.management=dynamic`

Enable dynamic mode on the **Trino coordinator** in `etc/config.properties`:

```properties
catalog.management=dynamic
```

Once enabled, you can create, drop, and rotate catalogs using SQL commands **without restarting any Trino pods**. The default is `catalog.management=static`, which requires the ConfigMap+restart pattern you're currently doing.

### Creating a catalog at runtime

```sql
CREATE CATALOG app_pg USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/appdb?ssl=true&sslmode=require',
  "connection-user" = 'trino_reader',
  "connection-password" = '${ENV:APP_PG_PASSWORD}',
  "metadata.cache-ttl" = '60s'
);
```

The catalog is registered **cluster-wide immediately**. Run `SHOW CATALOGS` and `app_pg` appears instantly.

### Password rotation: DROP + CREATE pattern

There is **no `ALTER CATALOG` command yet** in Trino 467 (tracked in trinodb/trino#25542). For credential rotation, use:

```sql
-- Step 1: Create new catalog under temporary name — existing queries keep using the old catalog
CREATE CATALOG app_pg_new USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/appdb',
  "connection-user" = 'trino_reader',
  "connection-password" = '${ENV:APP_PG_PASSWORD}'
);

-- Step 2: Drop the old catalog. In-flight queries continue; only NEW queries fail.
DROP CATALOG app_pg;

-- Step 3: Recreate with the original name so existing code keeps working.
CREATE CATALOG app_pg USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/appdb',
  "connection-user" = 'trino_reader',
  "connection-password" = '${ENV:APP_PG_PASSWORD}'
);

-- Step 4: Clean up the temporary catalog.
DROP CATALOG app_pg_new;
```

**Critical point**: `DROP CATALOG` does **not** interrupt queries currently running against it. Those queries finish normally. Only **new** queries arriving after the DROP but before the CREATE fail with "catalog not found." Keep the DROP→CREATE window as tight as possible.

### Persistence across pod restarts: The Kubernetes gotcha

**Dynamic catalogs do NOT persist automatically across pod restarts.**

When `catalog.management=dynamic`, Trino writes catalog state to `etc/catalog/`. In a standard Kubernetes deployment with a read-only ConfigMap mount, this fails. You have two options:

**Option 1: EmptyDir (lose catalogs on restart)**
```yaml
volumes:
  - name: catalog-data
    emptyDir: {}
volumeMounts:
  - name: catalog-data
    mountPath: /etc/trino/catalog
```
Catalogs created via `CREATE CATALOG` are lost when the pod terminates. Use an init container that runs the CREATE statements on startup.

**Option 2: PersistentVolumeClaim (persist across restarts — production-correct)**
```yaml
volumes:
  - name: catalog-data
    persistentVolumeClaim:
      claimName: trino-catalog-pvc
volumeMounts:
  - name: catalog-data
    mountPath: /etc/trino/catalog
```

### Handling credentials securely

**Never hardcode passwords in CREATE CATALOG SQL.** The full statement is logged verbatim in the Trino Web UI query history — anyone who can view it will see the plaintext password.

Use **environment-variable indirection**:
```sql
CREATE CATALOG app_pg USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/appdb',
  "connection-user" = 'trino_reader',
  "connection-password" = '${ENV:APP_PG_PASSWORD}'
);
```

The environment variable name appears in query history; the resolved value does not.

### Authorization: Who can run CREATE/DROP CATALOG

Enabling `catalog.management=dynamic` **only turns on the capability** — it doesn't restrict who uses it. In your production stack with OPA, you must write an OPA Rego rule:

```rego
allow if {
  input.action.operation == "CreateCatalog"
  "platform-admin" in input.context.identity.groups
}

allow if {
  input.action.operation == "DropCatalog"
  "platform-admin" in input.context.identity.groups
}
```

Without this rule, **any user with a valid JWT can CREATE or DROP catalogs**.

### Important production caveats

1. **Dynamic catalog management is marked experimental in Trino 467.** Verify your platform team approves experimental features before production use.
2. **No `ALTER CATALOG` command yet.** Any change requires DROP + CREATE.
3. **The rotation window matters.** If a pod crashes between DROP and CREATE, new queries fail until you re-CREATE. Automate this pattern carefully.

### Summary

| Aspect | Static (ConfigMap + restart) | Dynamic (SQL) |
|---|---|---|
| Adding a catalog | Edit ConfigMap, roll pods | `CREATE CATALOG` SQL, instant |
| Rotating credentials | Edit ConfigMap, roll pods, downtime | DROP + CREATE, no pod restart, brief "not found" window |
| Persistence | ConfigMap lasts forever | Need PVC or init container |
| Authorization | File-system access control | OPA policy controls who can DDL |
| Production maturity | Stable | Experimental in 467 |
