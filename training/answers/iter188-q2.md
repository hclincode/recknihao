# Iter 188 Q2 — SSL/TLS for Trino-to-Postgres Connection in Kubernetes

## Answer

Your security team is right to flag unencrypted Postgres connections. The good news: Trino's PostgreSQL connector does support SSL/TLS encryption, but the configuration is **not** a separate `postgresql.ssl.*` catalog property like you might expect. Instead, you configure it through **JDBC URL parameters** on the `connection-url` line in your catalog properties file.

### The configuration approach: JDBC URL parameters, not separate properties

The PostgreSQL connector does **not** have dedicated catalog properties like `postgresql.ssl-enabled` or `postgresql.sslmode`. SSL is configured by appending parameters to your JDBC connection URL in `etc/catalog/app_pg.properties`.

### Two SSL modes to understand — and only one is production-ready

**1. Encryption only (NOT certificate verification) — `sslmode=require`**

```properties
connection-url=jdbc:postgresql://postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=require
```

This encrypts the wire but **does NOT verify the server certificate** against any CA. It's vulnerable to a MITM (man-in-the-middle) attack — an attacker presenting any certificate would succeed. Use this only for temporary unblocking or strictly-internal networks where you completely trust the network fabric. It won't pass a serious security review.

**2. Full certificate verification — `sslmode=verify-full` (production-correct)**

```properties
connection-url=jdbc:postgresql://postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt
```

This is what your security team actually wants. It does three things:
- Encrypts the connection (like `require`)
- Verifies the server's certificate chain against the CA that signed it (your internal CA)
- Checks that the certificate's CN or SAN matches the hostname in the JDBC URL

This is the production-correct posture — it defeats both passive eavesdropping and MITM attacks.

### Handling your internal CA certificate

Since your Postgres certificate was signed by an internal CA, you need to tell Trino where to find that CA's certificate. The `sslrootcert` parameter points to the filesystem path of your CA certificate **in PEM format**.

**Critical gotcha for Kubernetes:** The CA certificate file must be present and readable on **every Trino pod** — not just the coordinator, but all worker pods too. Workers are the ones that actually execute the JDBC reads; the coordinator only plans the queries.

The clean way to mount it:

```bash
# Step 1: Create a Kubernetes Secret from your CA cert file
kubectl create secret generic postgres-ca-cert \
  --from-file=ca.crt=/path/to/your/ca.crt \
  --namespace trino
```

```yaml
# Step 2: Mount it on BOTH coordinator and worker pod specs
spec:
  containers:
    - name: trino
      volumeMounts:
        - name: postgres-ca-cert
          mountPath: /etc/trino/certs
          readOnly: true
  volumes:
    - name: postgres-ca-cert
      secret:
        secretName: postgres-ca-cert
```

After this, `/etc/trino/certs/ca.crt` is readable from inside every Trino pod, and your `sslrootcert=/etc/trino/certs/ca.crt` parameter resolves correctly.

### Complete production example

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

The additional parameters (`defaultRowFetchSize`, `socketTimeout`, `connectTimeout`) are separate JDBC tuning levers — not related to SSL but commonly set together in production.

### Verifying encryption is actually working

After deploying and restarting your Trino pods, run a query against the Postgres catalog to force a connection, then check the Postgres replica:

```sql
-- Run this on your Postgres replica as a superuser:
SELECT a.usename, a.application_name, s.ssl, s.version, s.cipher
FROM pg_stat_activity a
JOIN pg_stat_ssl s ON a.pid = s.pid
WHERE a.usename = 'trino_reader';
```

If `ssl = t` (true) for `trino_reader` connections, encryption is active. If `ssl = f` (false), check: (1) the catalog file URL is correct, (2) the CA cert is mounted on the workers (not just the coordinator), (3) the file path in `sslrootcert` is readable from inside the pod.

### `sslmode=require` vs. `sslmode=verify-full` in one sentence

`require` encrypts but trusts any certificate; `verify-full` encrypts and **proves the certificate belongs to the server you're connecting to** by verifying it against your CA. The latter prevents an attacker from intercepting traffic by presenting a different certificate.
