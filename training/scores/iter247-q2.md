# Iter247 Q2 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths

- **Correct primary mechanism**: SSL is configured via JDBC URL parameters on `connection-url` in the catalog properties file — matches official Trino PostgreSQL connector docs (https://trino.io/docs/current/connector/postgresql.html). The example `?ssl=true&sslmode=verify-full&sslrootcert=...` is exactly the documented pattern.
- **Correct CA cert format**: PEM is accepted directly for `sslrootcert` (verified against pgJDBC docs — only the client private key has special format requirements). The answer correctly distinguishes this from the client-cert/key case.
- **Production-fit deployment guidance**: Kubernetes Secret + volumeMount example matches the on-prem k8s environment in `prod_info.md`. Explicitly calling out that the CA must be mounted on **both coordinator AND every worker** is a high-value, easy-to-miss operational detail — workers do the actual JDBC connection.
- **Verification step**: The `pg_stat_ssl JOIN pg_stat_activity` query is correct and the most direct way to confirm encryption is actually active on the Postgres side.
- **SSL mode comparison table**: Accurate descriptions of `require` vs `verify-ca` vs `verify-full`, and correctly recommends `verify-full` for production.
- **Sensible scope**: mTLS section is appropriately framed as "if required" rather than mandatory — avoids overwhelming the engineer.
- **Production example** at the end stacks SSL options with the previously-recommended JDBC params (`defaultRowFetchSize`, `prepareThreshold=0` for PgBouncer compatibility), tying back to prior iteration's resource fixes.

## Gaps / Errors

- **Minor inaccuracy on mTLS example**: Per pgJDBC docs (https://jdbc.postgresql.org/documentation/ssl/), when using a PKCS-12 keyfile the `sslcert` parameter is **ignored** — the cert is read from the same .p12 file. The answer's example sets both `sslcert=...p12&sslkey=...p12`, which works but is redundant. Also worth noting: PKCS-12 file extension must be `.p12` (since 42.2.9) or `.pfx` (since 42.2.16) for the driver to recognize it; the answer's `.p12` example is correct on that front but doesn't mention the extension requirement.
- **PKCS-12 isn't the only option**: PKCS-8 DER format is also supported for the client key per pgJDBC docs. Saying "the PostgreSQL JDBC driver requires client certificates in PKCS-12 format, not PEM" is slightly overstated — PKCS-12 is the recommended modern format, but DER PKCS-8 is also accepted.
- **No mention of Trino restart**: The verification section says "after restart" but doesn't explicitly call out that catalog properties changes require a Trino coordinator+worker restart (or the catalog reload mechanism if available). Minor — most ops engineers know this, but the resource could be more explicit.
- **No JVM truststore alternative**: For shops that already manage CAs via the JVM truststore (`cacerts`), there's an alternative pattern (don't need to mount per-cert; trust the CA system-wide). Not a blocker, but a sophisticated reader might wonder.

## Topic impact

Topic prior: 4.449 avg across 167 questions. New running avg: (4.449 × 167 + 4.75) / 168 = (742.983 + 4.75) / 168 = 747.733 / 168 = **4.451 across 168 questions**. Status remains NEEDS WORK (4.451 < 4.5 raised threshold), but the gap continues to narrow (0.051 → 0.049).
