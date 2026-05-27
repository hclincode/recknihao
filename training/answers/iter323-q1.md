# Answer to Q1: OPA Policy Revocation Latency (Iter 323)

## The Quick Answer

**OPA policy changes take effect on the NEXT query submission, not retroactively.** The moment you push a policy update that denies the churned tenant, their next `SELECT` will be rejected at the coordinator during authorization — before it touches data or workers. Queries already running will finish unless you explicitly kill them.

## How It Works: The One-Line Rule

**OPA is consulted only during query analysis (planning), never during distributed execution. A query that has passed authorization and begun executing will run to completion regardless of subsequent OPA outages or policy updates.**

This breaks into two critical stages:

1. **Authorization happens once, at query startup, on the coordinator.** When a query arrives, Trino's coordinator asks OPA: "Can this principal read these tables/columns?" If the policy now denies them, OPA returns `allow: false`. Trino rejects the query immediately with `Access Denied` — no bytes read from MinIO, no workers involved.

2. **After authorization passes, OPA is out of the picture for that query.** Workers do not re-check authorization as they read data splits. If a policy changes one second after a query starts executing, that change applies to the **next** query only.

## No Caching, No Delays

One critical detail: **The Trino OPA plugin has no decision cache.** Every query's authorization is a fresh live HTTP call to OPA. There is no TTL, no stale-policy window. You push the policy, OPA picks it up on its next bundle poll cycle, and the very next query sees the new policy.

The only delay is OPA's bundle polling cycle (`services.<name>.polling.min_delay_seconds` to `max_delay_seconds` in OPA config — typically 30s to 60s, configurable faster).

## The Concrete Timeline

| Event | What Happens |
|---|---|
| Push new OPA Rego rule denying `churned-tenant` | Policy bundled and deployed to MinIO bundle server |
| OPA bundle poll completes | OPA (typically 30s–60s) picks up new bundle |
| Tenant submits new query | Coordinator asks OPA → `allow: false` → `Access Denied` ✓ |
| Tenant's in-flight 4-hour job | **Completes** — authorization already passed at submission time |

## Making Sure They Can't Run Even One More Query

**For immediate denial of new queries:** update OPA policy and push bundle. Sub-second after bundle is live.

**For queries already running:** use `KILL QUERY`:

```sql
-- Find in-flight queries from the revoked user
SELECT query_id, query, state
FROM system.runtime.queries
WHERE user = 'churned-tenant-principal'
  AND state = 'RUNNING';

-- Kill each one immediately
CALL system.runtime.kill_query(
  query_id => '<query_id>',
  message  => 'access revoked'
);
```

## The Complete Incident Playbook

1. **Push the policy update** denying the tenant's principal in OPA (seconds).
2. **Wait for OPA bundle poll** (~30–60s depending on your polling config) — or trigger an out-of-band bundle push if your CI/CD supports it.
3. **Check for in-flight queries**: `SELECT query_id FROM system.runtime.queries WHERE user = 'churned-tenant-principal'`
4. **Kill any running queries** using `CALL system.runtime.kill_query(...)` per query.
5. **Verify**: their next query attempt returns `Access Denied`.

## Debugging If Something Appears to Go Through

- **`system.runtime.queries` error log**: OPA denials show `error_code = 'PERMISSION_DENIED'`
- **Coordinator OPA plugin logs**: set `io.trino.plugin.opa.OpaHttpClient=DEBUG` in `etc/log.properties` — every OPA HTTP call logged with response (`allow: true/false`)

## Key Point for Your Incident

The only scenario where a query "goes through" after revocation is if it was submitted before your policy update. That's authorization-at-submission semantics, not a latency problem. Kill any in-flight queries with `kill_query` and new submissions will be denied immediately once the bundle propagates.
