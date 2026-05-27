# Answer to Q2: OPA Cache-TTL-Seconds and Revocation Latency (Iter 322)

Yes, OPA caching is real and creates exactly the revocation-latency window you're worried about.

## How the Cache Works

When you enable `opa.policy.cache-ttl-seconds`, Trino caches the OPA row-filter decision for a given `(user, table)` pair for the TTL window. If you revoke a tenant's access and they submit a query within the cache window, Trino skips the OPA HTTP call and returns the stale cached "allow" decision.

Configure it in `etc/access-control.properties` on your Trino coordinator:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.cache-ttl-seconds=30
```

**Scope of the cache:** Per-user, per-table. If user `alice` queries `events` once, the row-filter decision (`WHERE tenant_id = 'acme'`) is cached for 30 seconds. If she queries a different table (`users`), that's a separate cache entry — a separate OPA call.

## Revocation Latency Is Cumulative

When you revoke a tenant's access, the full propagation time is the sum of four stages:

1. **JWT revocation at your identity provider** — marks the old JWT invalid
2. **OPA bundle update** — new Rego policy pushed to MinIO bundle server
3. **OPA bundle poll** — OPA coordinator fetches the new bundle (your `min_delay_seconds` to `max_delay_seconds` polling window, typically 30s–60s)
4. **Trino decision cache expiry** — the cached `(user, table)` row-filter decision expires (`cache-ttl-seconds`)

**Total revocation window = sum of all four stages.** If OPA bundle polling already takes 2–5 minutes, adding 30 seconds of Trino cache adds minimal harm. The biggest lever is your OPA bundle polling interval, not the Trino cache TTL.

## Tuning Recommendations

**High churn (daily or weekly revocations, or security-critical):**
- `cache-ttl-seconds=0` — every query asks OPA, no revocation latency, but you pay OPA HTTP overhead on every row-filter decision
- `cache-ttl-seconds=5` to `10` — revocation takes effect within 10 seconds worst-case after bundle propagates

**Low churn (infrequent revocations, internal analytics):**
- `cache-ttl-seconds=30` to `60` — fewer OPA calls (better query analysis-phase latency), acceptable for cases where a few minutes of post-revocation access doesn't create business risk

**The right question:** How quickly does your identity provider revoke the JWT? If a revoked user can't re-authenticate, a 60-second cache TTL doesn't matter — they finish their current query and can't start a new session. The Trino cache only matters if users can start new queries after revocation.

## Immediate Revocation Escape Hatch

For urgent revocations (security incident, not just normal churn), use Trino's `KILL QUERY` command to terminate any in-flight queries from the revoked user immediately:

```sql
-- Find in-flight queries from the revoked user
SELECT query_id FROM system.runtime.queries
WHERE user = 'revoked_user@tenant' AND state = 'RUNNING';

-- Kill them
CALL system.runtime.kill_query(query_id => 'query-id-here', message => 'access revoked');
```

This is the escape hatch for "revoke NOW" scenarios — more effective than waiting for cache TTL expiry.

## Monitoring OPA Call Rate

If you lower `cache-ttl-seconds`, watch OPA call volume in your `io.trino.plugin.opa.OpaHttpClient` DEBUG logs. If OPA becomes the bottleneck (latency > 5–10ms per call at high concurrency), either:
1. Scale OPA horizontally (add replicas, same bundle endpoint)
2. Raise `cache-ttl-seconds` back to 30

**Bottom line:** Start with `cache-ttl-seconds=30`. For churn scenarios, focus first on shortening your OPA bundle polling interval (steps 2+3 above) — that's usually the bigger source of revocation latency. Lower Trino cache TTL only if you've already tightened bundle propagation and still need sub-minute revocation.
