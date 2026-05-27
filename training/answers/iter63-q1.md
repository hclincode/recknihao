# Iter63 Q1 — Answer

**Question**: We've got per-tenant schemas and roles set up in Trino — each customer can only query their own schema. But I'm worried we've accumulated misconfigurations over time as we've onboarded new customers, rotated engineers, and run one-off scripts. Is there a way to actually query what access each tenant role currently has? Like, can I run something against Trino's system tables or catalog to list out exactly which schemas or tables each role can see? I want to be able to run an audit and catch if, say, tenant A's role accidentally has read access to tenant B's schema — before a customer discovers it themselves.

---

## Answer

Trino does not have a single SQL query that lists all grants for all roles — it has `SHOW GRANTS` for specific objects and `SHOW ROLES`, but your authorization source of truth is OPA (your production stack), not Trino's internal tables. The practical audit strategy combines checking the config source, testing actual permissions, and monitoring query audit logs.

### What Trino gives you directly

`SHOW ROLES` lists all roles defined in the catalog:

```sql
SHOW ROLES;
```

`SHOW ROLE GRANTS` shows role-to-user and role-to-role assignments:

```sql
SHOW ROLE GRANTS;
```

`SHOW GRANTS ON TABLE ...` and `SHOW GRANTS ON SCHEMA ...` show explicit grants on specific objects:

```sql
SHOW GRANTS ON TABLE iceberg.tenant_acme.events;
SHOW GRANTS ON SCHEMA iceberg.tenant_acme;
```

The limitation: these show only grants applied via SQL `GRANT` statements in Trino's own access control. Your production stack uses OPA as the authorization backend — OPA policies are the real source of truth and are not reflected in Trino's SHOW GRANTS output. If a grant exists in OPA but not in Trino's internal system, SHOW GRANTS won't show it (and vice versa).

### The authoritative audit: test actual permissions

The most reliable way to audit isolation is behavioral testing — connect as each tenant service account and assert what it can and cannot access:

```python
# Run this for every tenant service account
def audit_tenant_isolation(cursor, tenant_user, tenant_schema, all_schemas, base_table):
    # Should SUCCEED — own view
    cursor.execute(f"SELECT COUNT(*) FROM {tenant_schema}.events")

    # Should FAIL — base table (any success is a breach)
    try:
        cursor.execute(f"SELECT COUNT(*) FROM {base_table} LIMIT 1")
        print(f"BREACH: {tenant_user} can read base table {base_table}")
    except TrinoQueryError as e:
        assert "Access Denied" in str(e)

    # Should FAIL — other tenants' schemas
    for other_schema in all_schemas:
        if other_schema == tenant_schema:
            continue
        try:
            cursor.execute(f"SELECT COUNT(*) FROM {other_schema}.events LIMIT 1")
            print(f"BREACH: {tenant_user} can read {other_schema}")
        except TrinoQueryError as e:
            assert "Access Denied" in str(e)

    # Should FAIL — system catalog (exposes other tenants' query history)
    try:
        cursor.execute("SELECT query FROM system.runtime.queries LIMIT 1")
        print(f"BREACH: {tenant_user} can read system.runtime.queries")
    except TrinoQueryError as e:
        assert "Access Denied" in str(e)
```

Run this in CI against your staging Trino cluster using each tenant's real JWT credentials. A passed CI run is auditable evidence.

### The high-risk misconfigurations to catch

| Misconfiguration | Symptom | Test |
|---|---|---|
| Base-table access leaked to tenant role | Tenant queries `analytics.events` and gets rows | CI: SELECT on base table succeeds (should fail) |
| Missing USER-level revoke | Tenant bypasses the role and queries base table via user principal | Same test — role REVOKE alone is insufficient |
| Cross-schema read access | Tenant queries another tenant's schema | CI: SELECT on another tenant's view succeeds |
| system.runtime.queries not denied | Tenant can see other tenants' SQL text | CI: SELECT on system catalog succeeds |
| Iceberg metadata tables exposed | Tenant reads `events$partitions`, sees all tenant_id values | CI: SELECT on `$partitions` metadata table succeeds |

### Monitoring: detect anomalies via query audit logs

Enable Trino's HTTP event listener (configured in `etc/http-event-listener.properties` on the coordinator). Every completed query posts a JSON event to your audit collector containing:
- `context.user` — the JWT principal (tenant service account)
- `ioMetadata.inputs[n].tableName` — the resolved tables actually read (not what the user typed)
- `metadata.queryState` — FINISHED or FAILED

With an audit table populated from these events, detect misconfigurations retroactively:

```sql
-- Detect any tenant role reading the base table (should never happen)
SELECT query_id, trino_user, query_text, create_time
FROM iceberg.analytics.query_audit_log
WHERE queried_tables LIKE '%analytics.events%'
  AND trino_user LIKE '%-service-account'
  AND query_state = 'FINISHED'
ORDER BY create_time DESC;

-- Detect cross-tenant access: Acme reading Beta's schema
SELECT query_id, trino_user, queried_tables, create_time
FROM iceberg.analytics.query_audit_log
WHERE trino_user = 'acme-service-account'
  AND (queried_tables LIKE '%tenant_beta%' OR queried_tables LIKE '%tenant_gamma%')
ORDER BY create_time DESC;
```

Run these queries weekly to catch misconfigurations that slipped through.

### Operational practice to prevent drift

**Version-control access control config.** Whether you use file-based rules (`etc/rules.json`) or OPA policies, store them in Git. Every change goes through code review — this eliminates the "one-off script" class of accidental grants.

**Automate onboarding.** When a new tenant is added, the onboarding script should run exactly: `CREATE ROLE`, `GRANT ROLE TO USER`, `GRANT SELECT ON VIEW TO ROLE`, `REVOKE ALL ON BASE TABLE FROM USER`. No manual steps means no manual errors.

**Run CI isolation tests on every deploy.** Each deployment of updated access control config triggers the behavioral test suite. If a misconfiguration was introduced, CI catches it before it reaches staging or production.

### What SHOW GRANTS doesn't cover

If your OPA policies contain a rule that grants tenant A access to tenant B's schema, no Trino SQL query will surface that — OPA is an external policy engine that Trino consults per-request. The only way to find this is to (a) audit the OPA Rego rules in your governance repo, or (b) run the behavioral tests above and observe an unexpected Access Granted where you expected Denied.
