# Score: iter227-q1
Score: 3.40
Topic: Trino federation / cross-source connectors

## What was correct
- Core architectural framing is right: Trino MySQL connector does NOT have catalog-level `mysql.ssl.*` properties — TLS is configured via JDBC URL parameters in `connection-url`. Verified against trino.io/docs/current/connector/mysql.html.
- `sslMode=VERIFY_IDENTITY` is a valid and correct value for full chain + hostname verification. Verified against dev.mysql.com Connector/J docs: "VERIFY_IDENTITY - Like VERIFY_CA, but additionally verify that the server certificate matches the host to which the connection is attempted."
- Two-tier framing (encrypt-only vs. encrypt+verify) is conceptually correct and matches MySQL Connector/J's `REQUIRED` vs `VERIFY_CA`/`VERIFY_IDENTITY` distinction.
- CA cert must be mounted on ALL workers, not just coordinator — correct, because JDBC reads execute on workers. This is a practical/production-aware point.
- The PostgreSQL vs MySQL parameter-name divergence framing is conceptually correct (driver-specific) and the warning against copy-pasting Postgres config is valuable.
- Kubernetes Secret/volumeMount example is concrete, on-prem appropriate (matches prod_info.md which describes on-prem k8s deployment), and runnable.
- Verification step idea (querying server-side for active connections' SSL state) is the right diagnostic instinct.
- `connection-password=${ENV:MYSQL_PASSWORD}` pattern is the correct Trino secret-substitution syntax.

## What was wrong or missing

### Critical technical errors

1. **`serverSslCertificate` is NOT a real MySQL Connector/J parameter.** This appears to be fabricated or confused with another driver (MariaDB Connector/J has `serverSslCert`, not MySQL Connector/J). MySQL Connector/J uses **`trustCertificateKeyStoreUrl`** and **`trustCertificateKeyStorePassword`** (JKS or PKCS12 only — NOT a PEM file path). To use a PEM CA cert with MySQL Connector/J, you must first import it into a Java keystore with `keytool -importcert -alias MySQLCACert -file ca.pem -keystore truststore -storepass <pwd>`, then point the JDBC URL at the keystore file. The answer's complete production examples will FAIL with an "unknown connection property" or be silently ignored — engineer would get a working connection that is NOT actually verifying the cert. This is the most dangerous error in the answer because it silently degrades the security posture the security team is asking for.

2. **`useSSL=true&requireSSL=true` is DEPRECATED in MySQL Connector/J 8.x.** Per Oracle docs: "The sslMode property replaced the deprecated legacy properties 'useSSL', 'requireSSL', and 'verifyServerCertificate'." When `sslMode` is set explicitly, the legacy properties are IGNORED. Trino's own MySQL connector documentation says explicitly: "with version 8.0 of MySQL Connector/J, use the sslMode parameter." The answer should recommend just `sslMode=REQUIRED` (or `VERIFY_IDENTITY`) and NOT include the deprecated useSSL/requireSSL alongside it. Including both is misleading and propagates legacy-driver folklore.

3. **`INFORMATION_SCHEMA.PROCESSLIST` does NOT have an `SSL_TYPE` column.** This column does not exist in any MySQL version. The verification query as written will fail with `ERROR 1054 (42S22): Unknown column 'SSL_TYPE' in 'field list'`. The correct verification approaches are: (a) `SHOW STATUS LIKE 'Ssl_cipher';` in a session, (b) `performance_schema.session_status` joined to `performance_schema.threads`, or (c) the `CONNECTION_TYPE` column in `performance_schema.threads` (added in MySQL 5.7.8) which shows `SSL/TLS` for encrypted connections. This is a concrete reproducibility failure — the engineer will copy-paste the query and immediately see an error.

### Less critical gaps

4. PostgreSQL comparison row uses `sslrootcert=/path/to/ca.crt` — that IS correct for Postgres (PEM-direct), but reinforces the (wrong) symmetry implied for MySQL where the answer claims a PEM path can be used directly. PEM vs. JKS asymmetry between the two drivers is the actual key teaching point and is missed.
5. No mention that JKS keystore creation requires JDK `keytool` access at image-build time or via init container — operationally relevant on k8s.
6. `serverTimezone=UTC` is unnecessary noise in a TLS-focused answer (it's a MySQL Connector/J 5.x-era requirement, mostly redundant in 8.x with correct server tz config); padding the URL with unrelated parameters dilutes the security message.
7. No mention of mTLS (client-cert auth via `clientCertificateKeyStoreUrl`), which a compliance-driven security team may also require beyond server-cert verification.
8. No mention of Trino 467 (the prod version per prod_info.md) bundling a specific MySQL Connector/J version — engineer can't tell which property set actually applies.

## Verdict
**FAIL.** Average ≈ 3.4, below 3.5 pass threshold, and well below the 4.5 raised threshold for this topic.

The answer reads professionally and gets the high-level architecture right (JDBC-URL-based config, two-tier framing, worker-side mounting), but three concrete, copy-pasted-into-production technical claims are wrong in dangerous ways:
- A fabricated parameter name (`serverSslCertificate`) that silently fails to enforce verification
- Use of deprecated `useSSL/requireSSL` alongside `sslMode` (legacy properties are ignored when sslMode is set)
- A verification query referencing a column that does not exist

Any engineer following this answer literally will either (a) get errors from the verification query and lose trust, or worse (b) believe their connection is being CA-verified when in fact the unknown `serverSslCertificate` property is being ignored and only the `sslMode=VERIFY_IDENTITY` is doing work — at which point verification depends entirely on the JVM's default truststore containing the right CA, which for an internal/private CA it almost certainly does NOT. The security team's actual requirement would be silently unmet.

Resource fix priorities for next iter:
- HIGH: Document MySQL Connector/J truststore properties correctly (`trustCertificateKeyStoreUrl`, `trustCertificateKeyStorePassword`) and the `keytool -importcert` step to convert PEM → JKS.
- HIGH: Mark `useSSL`/`requireSSL` as deprecated; recommend `sslMode=REQUIRED` / `VERIFY_CA` / `VERIFY_IDENTITY` only.
- HIGH: Correct the verification query — use `SHOW STATUS LIKE 'Ssl_cipher'` or `performance_schema.threads.CONNECTION_TYPE`, not `INFORMATION_SCHEMA.PROCESSLIST.SSL_TYPE`.
- MEDIUM: PEM-vs-JKS asymmetry between Postgres JDBC and MySQL Connector/J as the headline teaching point in the comparison table.
- LOW: Mention mTLS / client-cert variant for security teams that require it.

Verified against:
- trino.io/docs/current/connector/mysql.html (sslMode is the documented approach; no catalog-level ssl props)
- dev.mysql.com/doc/connector-j/en/connector-j-connp-props-security.html (sslMode values DISABLED/PREFERRED/REQUIRED/VERIFY_CA/VERIFY_IDENTITY; useSSL/requireSSL deprecated)
- dev.mysql.com/doc/connector-j/en/connector-j-server-authentication.html (trustCertificateKeyStoreUrl + keytool PEM→JKS workflow)
- dev.mysql.com/blog-archive/identifying-insecure-connections/ (Ssl_cipher status variable, performance_schema.threads.CONNECTION_TYPE; no SSL_TYPE in PROCESSLIST)
