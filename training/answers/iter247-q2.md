# Iter247 Q2 — SSL/TLS for Trino PostgreSQL Connector

## Answer: SSL/TLS Configuration for Trino PostgreSQL Connector

SSL/TLS is configured via **JDBC URL parameters** on the `connection-url` line in your catalog properties file — not via separate `postgresql.ssl.*` properties.

### The Quick Fix

Update `etc/catalog/app_pg.properties` on your coordinator (and ensure workers get the same config):

```properties
connection-url=jdbc:postgresql://replica-hostname:5432/dbname?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt
```

### Step 1: Mount the CA Certificate on Every Trino Pod

Yes — **you need to trust your internal CA**. The `sslmode=verify-full` parameter:
- Encrypts the connection
- Verifies the Postgres server's certificate was signed by your CA
- Verifies the certificate hostname (CN or SAN) matches the hostname in your JDBC URL

The path `/etc/trino/certs/ca.crt` must be readable on **every Trino pod — coordinator AND all workers**. Workers do the actual JDBC queries; forgetting workers is a common mistake.

On Kubernetes, create a Secret and mount it:

```bash
kubectl create secret generic postgres-ca-cert \
  --from-file=ca.crt=/path/to/your/ca.crt \
  --namespace trino
```

Add to both coordinator and worker pod specs:

```yaml
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

The CA cert file can be in **PEM format** — the PostgreSQL JDBC driver accepts it directly.

### Step 2: Restart Trino to Pick Up the New Catalog Config

After updating the catalog properties file and mounting the cert, roll your coordinator and worker pods.

### Verifying SSL is Actually Active

Force a connection, then check on the Postgres replica:

```sql
SELECT a.usename, a.application_name, s.ssl, s.version, s.cipher
FROM pg_stat_activity a
JOIN pg_stat_ssl s ON a.pid = s.pid
WHERE a.usename = 'trino_reader';
```

If `ssl = t` (true), you're encrypted. If `ssl = f` despite your config:
- Double-check the catalog file syntax (common typo: `sslrootcert` vs `sslrootcer`)
- Verify the cert file is actually mounted on the workers (`kubectl exec` into a worker pod and `ls /etc/trino/certs/ca.crt`)
- Ensure the hostname in your JDBC URL matches the Postgres certificate's CN or SAN

### Three SSL Modes — Pick the Right One

| Mode | Encryption? | CA verification? | When to use |
|---|---|---|---|
| `sslmode=require` | Yes | No | Stopgap only; vulnerable to MITM attacks |
| `sslmode=verify-full` | Yes | Yes (full chain + hostname check) | **Production. Use this.** |
| `sslmode=verify-ca` | Yes | Yes (chain only, no hostname check) | Rarely needed; vulnerable to certs for different hosts |

### Mutual TLS (If Required)

If Postgres also needs to verify a client certificate from Trino (mTLS), add `sslcert` and `sslkey` parameters. The PostgreSQL JDBC driver requires client certificates in **PKCS-12 format**, not PEM. Convert once:

```bash
openssl pkcs12 -export \
  -out client.p12 \
  -inkey client.key \
  -in client.crt \
  -CAfile ca.crt
```

Then add `&sslcert=/etc/trino/certs/client.p12&sslkey=/etc/trino/certs/client.p12` to the JDBC URL. Most setups use server-side TLS only, not mTLS.

### Complete Production Example

```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10&prepareThreshold=0
```
