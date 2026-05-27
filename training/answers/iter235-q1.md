# Iter 235 Q1 — MySQL SSL/TLS Configuration for Trino

## Answer

For your security audit, here's the exact production setup for encrypting Trino's MySQL read replica connection with full certificate verification.

### 1. Exact Catalog Properties File Properties

Add these to your MySQL catalog properties file (e.g., `etc/catalog/billing_mysql.properties`):

```properties
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=file:///etc/trino/certs/truststore.jks&trustCertificateKeyStorePassword=changeit
```

Breaking this down — the key difference from PostgreSQL is that MySQL Connector/J uses **single `sslMode` parameter** (camelCase, not two separate `ssl` and `sslmode` properties):

| Parameter | What to set | Why |
|---|---|---|
| `sslMode=VERIFY_IDENTITY` | **Always this for production** | Encrypts the connection AND verifies the MySQL server's certificate chain against your truststore AND verifies the certificate's CN/SAN matches the hostname in the JDBC URL. This is what your audit wants. |
| `trustCertificateKeyStoreUrl` | `file:///etc/trino/certs/truststore.jks` | Path to the JKS truststore file containing your MySQL CA certificate. The `file://` scheme is required. |
| `trustCertificateKeyStorePassword` | Password you chose (default is `changeit`) | Password for the truststore (not a private key password — the truststore contains only the public CA cert). |

**Do NOT use deprecated MySQL 5.x properties** like `useSSL=true&requireSSL=true&verifyServerCertificate=true` alongside `sslMode` — they are silently ignored in modern MySQL Connector/J and clutter your URL.

### 2. Truststore Format: JKS Conversion and Creation

MySQL Connector/J **cannot load PEM directly** — you must convert your MySQL CA certificate to JKS format using `keytool`:

```bash
# Step 1: Import your PEM CA certificate into a JKS truststore
keytool -importcert \
  -alias MySQLCACert \
  -file /path/to/ca.pem \
  -keystore truststore.jks \
  -storepass changeit \
  -noprompt

# Step 2: Verify the truststore contains your CA cert
keytool -list -keystore truststore.jks -storepass changeit
# Output should show one entry: "MySQLCACert" of type "trustedCertEntry"
```

The resulting `truststore.jks` is a binary file that contains your CA's public certificate. You can use any password — `changeit` is conventional — but the password is required by the JKS format.

In Kubernetes (if that's your deployment environment), create a Secret and mount it on **every Trino pod (coordinator AND workers)**:

```bash
kubectl create secret generic mysql-tls-truststore \
  --from-file=truststore.jks=./truststore.jks \
  --namespace trino
```

Then in your pod spec:
```yaml
spec:
  containers:
    - name: trino
      volumeMounts:
        - name: mysql-tls-truststore
          mountPath: /etc/trino/certs
          readOnly: true
  volumes:
    - name: mysql-tls-truststore
      secret:
        secretName: mysql-tls-truststore
```

**Critical:** Mount on workers, not just the coordinator. The coordinator plans the query, but workers execute the actual JDBC reads to MySQL — if workers can't find the truststore, they'll fall back to plaintext silently.

### 3. Verifying the Connection is Actually Using TLS

After deploying, run any Trino query against your MySQL catalog to force a connection attempt, then **on the MySQL server itself**, check the connection status:

```sql
-- Show SSL cipher for the current session
SHOW STATUS LIKE 'Ssl_cipher';
-- Output: Ssl_cipher | value (should be non-empty, e.g., "TLS_AES_256_GCM_SHA384")

-- For all active connections (to see Trino's connection specifically)
SELECT * FROM performance_schema.threads WHERE CONNECTION_TYPE = 'TCP/IP';
-- Verify that the thread(s) from your Trino IP have a non-null CONNECTION_TYPE (meaning they negotiated TLS)
```

If `Ssl_cipher` is empty or the CONNECTION_TYPE shows 'TCP/IP' but the cipher is blank, the connection is **plaintext despite your config** — troubleshoot:

1. **Catalog file syntax**: Re-check that `sslMode=VERIFY_IDENTITY` and `trustCertificateKeyStoreUrl=` are spelled exactly as shown, with camelCase.
2. **Truststore path**: Verify `/etc/trino/certs/truststore.jks` exists on every worker node (run `ls /etc/trino/certs/truststore.jks` on a worker pod).
3. **Truststore password**: Ensure `trustCertificateKeyStorePassword` matches the password you used in the `keytool` import command.
4. **Restart Trino**: After catalog changes, restart Trino to reload the catalog file.
5. **Certificate CN/SAN mismatch**: If `sslMode=VERIFY_IDENTITY`, the certificate's CN or SAN must match the hostname in your JDBC URL exactly (case-sensitive). If they don't match, TLS negotiation will fail. Check the MySQL server's certificate with `openssl s_client -connect billing-replica.internal:3306` and verify the CN/SAN in the output.

**Never use `sslMode=PREFERRED`** (it silently falls back to plaintext if the server doesn't support TLS) or `sslMode=REQUIRED` (it encrypts but doesn't verify the cert, leaving you open to MITM attacks). Production audits require `VERIFY_IDENTITY`.
