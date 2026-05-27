# Iter 187 Q1 — Dynamic Catalog Management: Adding Data Sources Without Trino Restart

## Answer

Yes, it's actually possible, and it's the right answer for your situation. Trino 467 has a feature called **dynamic catalog management** that lets you add, remove, or update data sources at runtime via SQL — without restarting anything. No downtime for analytics.

### The Short Version

Enable this in your Trino coordinator's `etc/config.properties`:

```properties
catalog.management=dynamic
```

Then instead of editing config files and restarting, you run SQL to create a new customer database connection:

```sql
CREATE CATALOG customer_acme_db USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/customer_acme_db?ssl=true&sslmode=require&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10',
  "connection-user" = 'trino_reader',
  "connection-password" = '<secret>',
  "metadata.cache-ttl" = '60s'
);
```

Once you run that SQL, `SHOW CATALOGS` immediately shows the new connection and your analysts can start querying `customer_acme_db.public.orders` — all without restarting Trino. The catalog is registered cluster-wide immediately.

### What's the catch?

#### 1. Kubernetes requires a writable volume

By default, your Trino `etc/catalog/` directory is probably mounted as a read-only ConfigMap. Dynamic catalog management needs to write state to disk, so you must mount a **writable volume** at `etc/catalog/` instead:

```yaml
volumes:
  - name: catalog-data
    emptyDir: {}  # or a PersistentVolumeClaim for persistence across pod restarts
volumeMounts:
  - name: catalog-data
    mountPath: /etc/trino/catalog
```

With `emptyDir`, catalogs you create via SQL are lost if the pod restarts — you'd need an init container to re-create them on startup. With a `PersistentVolumeClaim`, they persist automatically.

#### 2. Passwords appear in query history

When you run `CREATE CATALOG`, the SQL statement — including the plain-text password — is logged in Trino's Web UI query history. **Never run `CREATE CATALOG` with a literal password in a shared or audited cluster.** Instead:
- Reference Kubernetes secrets as environment variables: `${ENV:APP_ACME_PASSWORD}` in your CREATE CATALOG statement
- Or use HashiCorp Vault / a secrets manager to inject at runtime
- Or ensure only admins can see query history in your Trino UI

#### 3. No `ALTER CATALOG` — use DROP + CREATE instead

There's no `ALTER CATALOG` command in Trino 467. If you need to change credentials (e.g., password rotation), you must:

```sql
-- Step 1: Create new catalog with new password under a different name
CREATE CATALOG customer_acme_db_new USING postgresql
WITH ("connection-url" = '...', "connection-password" = 'new_secret', ...);

-- Step 2: Drop the old catalog
DROP CATALOG customer_acme_db;

-- Step 3: Recreate with the original name
CREATE CATALOG customer_acme_db USING postgresql
WITH ("connection-url" = '...', "connection-password" = 'new_secret', ...);

-- Step 4: Clean up
DROP CATALOG customer_acme_db_new;
```

There is a brief window between DROP and CREATE where new queries referencing `customer_acme_db` will fail with "catalog not found" — run the commands back-to-back in the same client session to minimize it.

**For zero-downtime rotation**: create a second Postgres role (`trino_reader_v2` with same grants). New catalog uses the new role — existing queries keep using old catalog, new queries pick up the new one. After a bake period, revoke the old role.

#### 4. It's marked experimental in Trino 467

Dynamic catalog management is **experimental** in Trino 467. The SQL syntax and properties might change in future releases. Test with your Trino upgrade roadmap before fully depending on it.

### The Bottom Line

For onboarding new enterprise customers:

1. Enable `catalog.management=dynamic` on your coordinator
2. Mount a writable volume at `etc/catalog/` (PVC for persistence)
3. Create a secure credential-injection mechanism (env vars, secrets manager)
4. When a new customer onboards, run `CREATE CATALOG` via SQL — done in seconds, no downtime
