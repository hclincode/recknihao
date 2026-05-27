# Iter 190 Q1 — Credential Rotation for PostgreSQL Connector Without Downtime

## Answer

## Trino Password Rotation Without Downtime

Based on your production environment (Trino 467, on-prem Kubernetes, Hive Metastore), here's how to handle 90-day password rotation safely:

### 1. What happens to in-flight queries when Trino workers restart

**Short answer: They fail.** When you restart a Trino worker pod (rolling or full restart), any query actively executing on that worker gets terminated. The coordinator will attempt to re-schedule work from failed tasks, but the end user sees the query as failed.

**Rolling restart impact:**
- During a rolling restart, only N workers are down at once (depends on your pod disruption budget).
- Queries touching only unaffected workers continue normally.
- Queries with splits assigned to a restarting worker will have those splits re-scheduled to healthy workers (with latency overhead). Some may eventually succeed; some may timeout if the overall query window is tight.
- Dashboard users with long-running queries (>2 minutes) will experience intermittent failures.

**This is why you want to avoid restarts for password rotation.** Fortunately, Trino 467 gives you a zero-restart alternative.

---

### 2. The recommended approach: Dynamic catalog management (DROP + CREATE)

**This is the modern, production-safe answer.** Instead of restarting workers, you rotate credentials by **dropping and recreating the PostgreSQL catalog at runtime** using SQL. No pod restart. In-flight queries on the old catalog continue to completion; new queries use the new password.

**Prerequisites:**
Enable dynamic catalog management in the **Trino coordinator's** `config.properties`:

```properties
catalog.management=dynamic
```

**Kubernetes gotcha:** This setting requires a **writable** `etc/catalog/` directory. By default, it's mounted as read-only ConfigMap. Switch to an `emptyDir` or PersistentVolumeClaim:

```yaml
volumes:
  - name: catalog-data
    emptyDir: {}  # survives pod lifetime, lost on restart
    # OR use a PVC for durability across restarts:
    # persistentVolumeClaim:
    #   claimName: trino-catalogs-pvc
volumeMounts:
  - name: catalog-data
    mountPath: /etc/trino/catalog
```

**The rotation workflow (zero downtime, no restarts):**

```sql
-- Step 1: Create a new catalog with the rotated password
CREATE CATALOG postgres_new USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10',
  "connection-user" = 'trino_reader',
  "connection-password" = '<new_rotated_password>',
  "metadata.cache-ttl" = '60s'
);

-- Step 2: Test the new catalog (optional but recommended)
SELECT 1 FROM postgres_new.public.my_test_table LIMIT 1;

-- Step 3: Drop the old catalog
-- Important: in-flight queries using the old catalog will NOT be interrupted.
-- They continue to completion. Only NEW queries referencing the old name will fail.
DROP CATALOG postgres;

-- Step 4: Recreate with the original name
CREATE CATALOG postgres USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10',
  "connection-user" = 'trino_reader',
  "connection-password" = '<new_rotated_password>',
  "metadata.cache-ttl" = '60s'
);

-- Step 5: Drop the temporary catalog
DROP CATALOG postgres_new;
```

**Why this works:**
- Steps 1–2 allow new queries to start using the new catalog while old queries finish with the old catalog still registered.
- Steps 3–4 create a tight window (seconds) where new queries referencing `postgres` will fail with "catalog not found," but in-flight queries continue.
- The tightness of this window depends on how fast you can type/execute the SQL. In production, automate this via a script or operator to minimize it.

**Key guarantees:**
- `DROP CATALOG` does NOT interrupt queries already using it.
- Existing connections holding a reference to the old catalog keep that reference until the query completes.
- New connections requesting the catalog between DROP and CREATE get "catalog not found," which is visible (not silent).

---

### 3. Safer approach: Dual-role pattern for truly zero downtime

If you need **zero window** with no "catalog not found" errors at all, coordinate with your Postgres team:

1. Create a second Postgres role `trino_reader_v2` with identical grants (CONNECT, USAGE, SELECT on relevant schemas).
2. While the old `trino_reader` role is still valid, run:
   ```sql
   CREATE CATALOG postgres_v2 USING postgresql
   WITH (
     "connection-user" = 'trino_reader_v2',
     "connection-password" = '<new_v2_password>',
     -- ... other properties
   );
   ```
3. Let both catalogs live for a bake period (e.g., 24 hours). New queries use `postgres_v2`; old queries use `postgres` with `trino_reader`.
4. Once everything is stable on `trino_reader_v2`, revoke or change the password of `trino_reader` on Postgres.
5. Drop the old catalog: `DROP CATALOG postgres;` (in-flight queries continue).
6. On the next rotation, reverse the roles.

**Why NOT dual-password:** Standard PostgreSQL doesn't support multiple passwords per role. `ALTER ROLE trino_reader PASSWORD '...'` is atomic and replaces the old password — no overlap window. The dual-role approach is the actual zero-downtime pattern.

---

### 4. Credential management best practices (static file vs. dynamic)

**For the properties file approach (if you're not using dynamic catalogs yet):**

Reference credentials from environment variables, not hardcoded values:

```properties
# etc/catalog/postgres.properties
connector.name=postgresql
connection-url=jdbc:postgresql://replica:5432/appdb
connection-user=${ENV:POSTGRES_USER}
connection-password=${ENV:POSTGRES_PASSWORD}
```

Mount the actual values from a Kubernetes Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: trino-postgres-creds
type: Opaque
stringData:
  username: trino_reader
  password: <strong-random>
---
# In the coordinator/worker pod spec:
containers:
  - name: trino
    env:
      - name: POSTGRES_USER
        valueFrom:
          secretKeyRef:
            name: trino-postgres-creds
            key: username
      - name: POSTGRES_PASSWORD
        valueFrom:
          secretKeyRef:
            name: trino-postgres-creds
            key: password
```

Rotating the password then requires:
1. Update the Secret: `kubectl patch secret trino-postgres-creds --type merge -p '{"stringData":{"password":"<new>"}}'`
2. Roll all Trino pods (coordinators + workers) to pick up the new env var.

This is the **static file approach** and it *does* cause brief unavailability during the rolling restart.

---

### 5. HashiCorp Vault integration — current limitations

**Trino 467 itself does NOT have native Vault agent integration.** There is no built-in Trino property that pulls secrets from Vault at runtime.

The standard pattern is **Kubernetes Secrets + pod lifecycle injection**, not Vault direct integration. Vault-on-Kubernetes integrations typically work at the pod level:

- Use the **Vault Agent sidecar** (a pod that injects secrets into the pod's filesystem or env vars at startup).
- Or use **Vault auth methods** (Kubernetes auth to obtain a token, then the app reads from Vault) — but Trino 467 doesn't expose Vault client APIs.

**Practical path forward for Vault:**
1. If your platform team already runs Vault, ask them to handle secret injection **at the pod level** — either via Vault Agent sidecar or a Kubernetes operator.
2. The injected value lands in an env var or file (same as the Kubernetes Secret approach above).
3. Trino's catalog properties reference it via `${ENV:VAR}` (the same mechanism as Kubernetes Secrets).
4. For automated rotation, your Vault team can push new values to the Secret, and you use the `DROP + CREATE` pattern above to pick up the new password without restarting.

**Better long-term option: Vault PostgreSQL dynamic credentials.**
If your Vault cluster has the PostgreSQL secret engine enabled, Vault can generate short-lived credentials dynamically (e.g., valid for 24 hours, auto-rotated). This changes the operational model — instead of rotating a static password every 90 days, Vault auto-generates a new one every day (or hour). OSS Trino 467 doesn't have built-in Vault client support for this — it requires external tooling or a custom operator.

---

### 6. Best practice workflow for your 90-day rotation (on-prem Kubernetes, Trino 467)

**Assume you're using dynamic catalog management (recommended):**

1. **Schedule:** Every 90 days, trigger a rotation job.
2. **Job steps:**
   - Fetch the new password from your credential store (Vault, AWS Secrets Manager, or manual generation).
   - Run the `DROP + CREATE` SQL pattern above (or the dual-role pattern for zero window).
   - Log the successful rotation in your audit system.
   - **No pod restart needed.**
3. **Monitoring:**
   - Alert if the rotation SQL fails.
   - Track the catalog drop-to-create window duration (should be <10 seconds).
   - Monitor for "catalog not found" errors in Trino query logs during the window (expected, not a failure).

---

### Summary table: Your options

| Approach | Restart needed? | In-flight queries | Rotation time | Setup complexity |
|---|---|---|---|---|
| **Static catalog + Secrets** (baseline) | YES — full cluster roll | Failed on affected pods | 10–30 min (incl. rollout) | Low |
| **Dynamic catalogs (DROP+CREATE)** (recommended) | NO | Continue to completion | <10 seconds | Medium — need writable catalog dir |
| **Dynamic catalogs + dual-role** (zero-downtime) | NO | Continue to completion | ~0 seconds | Medium — requires Postgres coordination |
| **Vault dynamic credentials** (future) | NO | Continue to completion | Automatic (hourly/daily) | High — requires Vault client integration |

**For your production stack right now: Enable `catalog.management=dynamic` and use the DROP + CREATE pattern. It's the safe middle ground — no restarts, no visible downtime, and it works with Trino 467 as-is. Rotation becomes a SQL script you run on-demand, not a Kubernetes maintenance event.**
