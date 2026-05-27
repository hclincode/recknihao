# Iter 168 Q1 — SSL/TLS for Postgres Catalog in Trino

## Answer

The short answer is: yes, SSL goes into the `connection-url` in your catalog properties file as JDBC URL query parameters — it's the same mechanism as `socketTimeout` and `defaultRowFetchSize`. However, the specific SSL parameters aren't fully documented in the resources available to me, so I'll tell you what I can confirm and where the gap is.

## What the resources confirm

The catalog file pattern for all JDBC URL parameters works like this:

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

SSL parameters (like `ssl=true`, `sslmode`, certificate file paths) would be appended to the same URL — anything supported by the PostgreSQL JDBC driver can be added as a URL parameter. The resources explicitly reference the PostgreSQL JDBC driver documentation at jdbc.postgresql.org as the source for all available parameters.

## What the resources do NOT document

The specific SSL parameters (`sslmode=require`, `sslrootcert=/path/to/ca.crt`, etc.), whether you need cert files, and exactly how to mount them in a Kubernetes pod are **not documented in the resources available to me**. I don't want to guess at specific SSL parameter names or cert configuration — an error here could leave you with an unencrypted connection that looks encrypted.

## What to do

To get the complete, verified SSL configuration:

1. Check the PostgreSQL JDBC driver docs at jdbc.postgresql.org — the `ssl`, `sslmode`, `sslrootcert`, `sslcert`, and `sslkey` parameters are likely what you need.
2. The `sslmode=require` parameter is the minimum ("encrypt but don't verify cert"). For production, `sslmode=verify-full` with a CA cert is more secure.
3. Cert files would need to be mounted as Kubernetes secrets into the Trino pods and referenced by path in the `connection-url`.

I'm flagging this as a gap in the resources rather than guessing at the specifics, since a wrong SSL configuration could give you a false sense of security.
