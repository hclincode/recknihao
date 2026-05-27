# Iter 169 Q1 — Postgres Password Rotation with Trino

## Answer

**You will need to restart Trino to pick up the new credentials when you rotate the Postgres password** — there is no hot-reload mechanism for catalog configuration, including credentials.

Trino reads catalog properties (including `connection-user` and `connection-password`) from `etc/catalog/<catalog-name>.properties` on startup only. After mounting a new catalog properties file, Trino picks it up only when the coordinator and worker pods roll.

## The production pattern that reduces pain

First, stop putting credentials in plaintext in the catalog file. Use Kubernetes secrets mounted as environment variables:

```properties
# etc/catalog/app_pg.properties
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

```yaml
# In the Trino pod spec
env:
  - name: APP_PG_PASSWORD
    valueFrom:
      secretKeyRef:
        name: trino-postgres-credentials
        key: app_pg_password
```

This doesn't eliminate the restart requirement, but it means:
1. The password isn't stored in the catalog ConfigMap (which may be less restricted than a Secret).
2. The rotation procedure is: update the Kubernetes Secret → roll Trino coordinator + workers.

## The rolling restart approach

In Kubernetes, a rolling restart (`kubectl rollout restart deployment trino-worker`) replaces pods one at a time rather than all at once. The cluster remains available during the roll, though any queries running on a pod being replaced will fail. During business hours, this means:

- New pods start with the new credentials.
- Old pods continue serving the old password (and existing connections stay valid) until they drain.
- If you set the old password to expire only after the new one is in place (two-password overlap), the transition is smoother.

Coordinate with your Postgres team: grant the new password, roll Trino, then revoke the old one — this gives you a zero-downtime window.

## What the resources don't document

There's no documented hot-reload or dynamic credential provider mechanism in OSS Trino 467 for JDBC catalog credentials. If zero-restart credential rotation is a hard requirement, your options are outside what these resources cover (e.g., an external secrets manager with a Trino credential provider plugin, or Starburst Enterprise features). For most teams, a rolling pod restart during a low-traffic window with a two-password overlap is the practical answer.
