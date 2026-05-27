# Iter 227 Q1 — MySQL SSL/TLS Configuration for Trino JDBC Connector

## Answer

Trino's MySQL connector uses the exact same TLS approach as the PostgreSQL connector. It doesn't have separate `mysql.ssl.*` catalog properties — you configure encryption entirely via JDBC URL parameters in your catalog's `connection-url`, just like you do for other connection tuning parameters.

### The Two Tiers: Encryption-Only vs. Full Certificate Verification

**Tier 1: Minimal encryption (not recommended for production)**

If you just want to encrypt the wire without verifying the server's certificate, add these parameters to your MySQL JDBC URL:

```properties
# etc/catalog/billing_mysql.properties
connector.name=mysql
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?useSSL=true&requireSSL=true
connection-user=trino_reader
connection-password=${ENV:MYSQL_PASSWORD}
```

What this does: encrypts the TCP connection but does NOT verify the server's certificate. This protects against passive eavesdropping but is vulnerable to man-in-the-middle (MITM) attacks — an attacker with a self-signed cert could impersonate your database server and Trino would accept it. Use this only as a temporary workaround or on strictly-trusted internal networks.

**Tier 2: Full certificate verification (production-correct)**

For compliance-grade security, verify the server's certificate against a trusted CA:

```properties
# etc/catalog/billing_mysql.properties
connector.name=mysql
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?useSSL=true&requireSSL=true&serverTimezone=UTC&sslMode=VERIFY_IDENTITY&serverSslCertificate=/etc/trino/certs/ca.crt
connection-user=trino_reader
connection-password=${ENV:MYSQL_PASSWORD}
```

What this does:
- `useSSL=true&requireSSL=true`: encrypt the connection
- `sslMode=VERIFY_IDENTITY`: verify the server's certificate chain against the CA AND verify that the certificate's CN (Common Name) or SAN (Subject Alternative Name) matches the hostname in your JDBC URL (`billing-replica.internal`)
- `serverSslCertificate=/etc/trino/certs/ca.crt`: path to the CA certificate (PEM format) that signed your MySQL server's certificate

This is the production-correct posture. It protects against both passive eavesdropping and MITM attacks.

### Critical: The CA cert must be mounted on ALL Trino pods

Unlike the coordinator (which plans queries), the **workers execute the actual JDBC reads**. If you only mount the CA cert on the coordinator, workers will fail to verify the certificate when they try to connect. You must mount it on every pod in your cluster.

In Kubernetes:

```bash
# Create a Secret from your CA certificate
kubectl create secret generic mysql-ca-cert \
  --from-file=ca.crt=/path/to/your/ca.crt \
  --namespace trino
```

Then in both your coordinator AND worker pod specs:

```yaml
spec:
  containers:
    - name: trino
      volumeMounts:
        - name: mysql-ca-cert
          mountPath: /etc/trino/certs
          readOnly: true
  volumes:
    - name: mysql-ca-cert
      secret:
        secretName: mysql-ca-cert
```

### Important differences from PostgreSQL — MySQL JDBC parameters are different

The MySQL JDBC driver uses **different parameter names** than PostgreSQL's JDBC driver:

| Requirement | PostgreSQL JDBC parameter | MySQL JDBC parameter |
|---|---|---|
| Require SSL | `ssl=true&sslmode=require` | `useSSL=true&requireSSL=true` |
| Require TLS + verify server cert | `ssl=true&sslmode=verify-full` | `useSSL=true&requireSSL=true&sslMode=VERIFY_IDENTITY` |
| Path to CA certificate | `sslrootcert=/path/to/ca.crt` | `serverSslCertificate=/path/to/ca.crt` |

A common mistake is copy-pasting PostgreSQL configuration directly into MySQL catalogs — the parameter names won't work.

### Complete production example for MySQL

```properties
# etc/catalog/billing_mysql.properties
connector.name=mysql
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?useSSL=true&requireSSL=true&sslMode=VERIFY_IDENTITY&serverSslCertificate=/etc/trino/certs/ca.crt&serverTimezone=UTC&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=trino_reader
connection-password=${ENV:MYSQL_PASSWORD}

# Also recommended:
metadata.cache-ttl=60s
metadata.cache-missing=true
```

This combines TLS parameters with throughput-tuning parameters (`defaultRowFetchSize`, `socketTimeout`, `connectTimeout`) that Trino federation generally expects.

### To verify TLS is actually active

After deploying, run any query against `billing_mysql` to force a connection. Then on your MySQL server, query your current connections:

```sql
SELECT ID, HOST, DB, COMMAND, TIME, SSL_TYPE
FROM INFORMATION_SCHEMA.PROCESSLIST
WHERE USER = 'trino_reader';
-- SSL_TYPE should show 'TLSv1.2' or similar, not empty
```

If `SSL_TYPE` is empty for your Trino connections, the connection is plaintext — re-check that the CA cert is actually mounted on the workers and the path in the JDBC URL is correct.

### Summary

| What you want | MySQL JDBC parameter(s) |
|---|---|
| Encrypt only (minimal) | `useSSL=true&requireSSL=true` |
| Encrypt + verify server cert against CA + verify hostname (production) | `useSSL=true&requireSSL=true&sslMode=VERIFY_IDENTITY&serverSslCertificate=/path/to/ca.crt` |

The second option is what your security team almost certainly wants. Mount the CA cert on every pod, use `VERIFY_IDENTITY`, and test with a real query before declaring the setup production-ready.
