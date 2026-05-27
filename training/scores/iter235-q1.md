# Score: iter235-q1 — MySQL SSL/TLS Configuration

**Score: 4.70 / 5.0**

## What was correct
- **Catalog property strategy** correctly puts SSL parameters in the JDBC `connection-url` (no catalog-level SSL props exist for Trino MySQL connector) — verified against trino.io MySQL connector docs.
- **`sslMode=VERIFY_IDENTITY`** is the correct camelCase parameter name for MySQL Connector/J (verified against dev.mysql.com Connector/J 8.x security docs). Distinction from PostgreSQL's `ssl=true&sslmode=verify-full` is accurate and useful.
- **`trustCertificateKeyStoreUrl`** is the correct property name (not `trustCertificateKeyStoreFile`). The `file://` URL scheme is correct.
- **`trustCertificateKeyStorePassword`** is the correct property name.
- **JKS truststore format** is correct — Connector/J defaults to JKS (PKCS12 also supported via `trustCertificateKeyStoreType`). The `keytool -importcert` workflow with `-alias MySQLCACert` matches the canonical MySQL docs example exactly.
- **Deprecation warning** about `useSSL=true&requireSSL=true&verifyServerCertificate=true` is accurate for Connector/J 8.x.
- **Mounting truststore on all workers, not just coordinator** is correct — workers execute the JDBC reads and need access to the truststore. Without it the JDBC driver would error (or fall back if sslMode allows). Production-critical detail.
- **`SHOW STATUS LIKE 'Ssl_cipher'`** is a valid verification command. An empty value means unencrypted; non-empty means TLS negotiated (verified against MySQL 8.0/8.4 reference manuals).
- **`sslMode=PREFERRED` silent fallback warning** is correct — PREFERRED is the default and will fall back to plaintext.
- **CN/SAN hostname match requirement** for VERIFY_IDENTITY is correct.
- **`openssl s_client -connect host:3306`** is a valid (and common) cert inspection command.
- **Kubernetes Secret + volumeMount example** fits the on-prem k8s production environment from `prod_info.md`.

## What was wrong or missing
- **Minor: `SHOW STATUS LIKE 'Ssl_cipher'` is session-scoped**, so it reflects the SQL client running it — not Trino's connection. The answer says "on the MySQL server itself, check the connection status" which is slightly misleading. To verify Trino's specific connection one must either (a) join `performance_schema.threads` / `performance_schema.status_by_thread` filtered by Trino's user/host, or (b) check from the Trino side. The answer hints at this with the `performance_schema.threads` query but the `CONNECTION_TYPE = 'TCP/IP'` predicate alone does not indicate TLS — `CONNECTION_TYPE` returns 'TCP/IP' for both plaintext and TLS TCP connections; TLS is indicated by a non-empty `Ssl_cipher` in `status_by_thread`, not by `CONNECTION_TYPE`. This is a slight technical inaccuracy.
- **Minor: `sslMode=REQUIRED` description is slightly imprecise.** The answer says REQUIRED "encrypts but doesn't verify the cert, leaving you open to MITM" — this is correct in effect, but worth noting that REQUIRED is appropriate when CA cert distribution is impractical; VERIFY_CA is the typical middle ground. Not a fabrication, just slightly absolute phrasing.
- **Not mentioned: PKCS12 alternative** — `trustCertificateKeyStoreType=PKCS12` is also supported and is the modern default for `keytool` in newer JDKs. Not required, but a completeness gap.
- **Not mentioned: SSL property file vs URL.** Properties can also be supplied via `connection-user` / `connection-password` style catalog properties, but JDBC URL embedding (as shown) is the standard documented approach. Not a flaw, just one path.

## Verification notes
WebSearch confirmed against authoritative sources:
1. `sslMode=VERIFY_IDENTITY` is the correct camelCase parameter for MySQL Connector/J 8.x — confirmed against dev.mysql.com Connector/J Security docs. Not PostgreSQL-style.
2. `trustCertificateKeyStoreUrl` is the exact correct property name — confirmed.
3. JKS is the default Connector/J truststore format; the `keytool -importcert -alias MySQLCACert -file ca.pem -keystore truststore` command in the answer matches the canonical MySQL docs example almost verbatim. PEM cannot be loaded directly via `trustCertificateKeyStoreUrl`.
4. `SHOW STATUS LIKE 'Ssl_cipher'` is valid (returns session-scoped value); empty = unencrypted, non-empty = TLS active. Confirmed in MySQL 8.0/8.4/9.x reference manuals.
5. Truststore on all workers is correct — Trino workers execute connector splits and open JDBC connections to MySQL themselves.

## Recommendation for teacher
Minor polish only — this was a retry of iter227 (3.40 FAIL) and the resources are now clearly correct. Suggestions:
1. Clarify in resources that `SHOW STATUS LIKE 'Ssl_cipher'` is **session-scoped to the client running it**; to verify Trino's specific connection, query `performance_schema.status_by_thread` joined with `performance_schema.threads` filtered by `PROCESSLIST_USER` = Trino's MySQL user.
2. Note that `CONNECTION_TYPE` in `performance_schema.threads` does **not** indicate TLS — it indicates transport (TCP/IP vs socket vs pipe). TLS state lives in `Ssl_cipher`.
3. Optionally add a PKCS12 alternative note for environments that prefer it (newer JDK keytool default).

Overall this is a strong, production-ready answer. The minor verification-command nuance is the only technical wrinkle.

Score: 4.70 — strong recovery from iter227; production-ready answer with one minor verification nuance.
