## Score: 4.81 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4.5 |

## Points covered
- What resource groups are and why they solve the noisy-neighbor problem — covered (highway-lane analogy, explicit "noisy neighbor" section)
- Concrete resource-groups.json configuration with key parameters — covered (softMemoryLimit, hardConcurrencyLimit, maxQueued all present with valid values and per-parameter explanation)
- How selectors route queries to groups (user/JWT principal matching) — covered (explicit JWT principal section, calls out exact-match selector gotcha)
- Restart requirement for file-based config changes — covered (explicit deploy step + outage warning)
- Emergency kill_query option for immediate relief — covered (correct named-argument syntax with query_id and message)
- Database-backed resource group manager for hot-reloading — covered (mentions 1-second reload, Postgres/MySQL)

## Technical accuracy gaps
- Minor: the answer uses `"user"` as the selector key, which is technically a valid Trino selector field but matches the session user. With JWT auth, this is usually fine because the JWT principal becomes the session user, but Trino also supports `authenticatedUser` and `originalUser` selectors (added in PR #24662) which are more robust against `X-Trino-User` overrides or `SET SESSION AUTHORIZATION`. The answer's framing that "the `user` field must match the JWT `sub` claim exactly" is correct in practice for this stack but a one-line nod to `authenticatedUser` for stronger isolation would be ideal.
- Minor: claim that file-based config "requires a restart for each change" is correct per Trino docs (file manager has no reload interval; only DB manager hot-reloads at `resource-groups.refresh-interval`, default 1s). Verified.
- Minor: claim that softMemoryLimit "pauses (queues) new queries" when hit is correct — verified against Trino 480 docs.
- The 10–30 second restart outage estimate is reasonable but environment-dependent; not technically wrong.

## Completeness gaps
- No mention of `schedulingPolicy` (fair / weighted / weighted_fair / query_priority) which is useful when many tenants share a parent group and you want bounded fairness rather than first-come-first-served.
- No mention of `softCpuLimit` / `hardCpuLimit` which complement memory caps when CPU is the bottleneck (12-month aggregation reports are often CPU-bound during aggregation, not just memory-bound).
- No mention of per-query memory caps (`query.max-memory-per-node`, `query.max-memory`) as a complementary lever — resource groups cap aggregate per-group memory but a single runaway query can still consume the group's entire allocation. A one-line note would round out the defense.
- 80 tenants in two static groups (enterprise/standard) is workable but the answer doesn't discuss the scaling problem of one-selector-per-tenant when tenants are added/removed frequently. A note on using a regex selector on tenant name pattern (e.g., `"user": "tenant-.*"` routed to a parent group with sub-groups created via DB manager) would be more production-realistic for a fleet that changes.
- Does not mention OPA's role in this stack — not strictly required since the question is about resource limits not authorization, but in production OPA may also need to allow the kill_query call.

## Verified (WebSearch)
- Trino docs (480/current) confirm `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued` parameter names and semantics — all correct in the answer.
- Trino docs confirm file-based resource group config requires coordinator restart; database-based config reloads every 1 second by default — answer's framing is accurate.
- `CALL system.runtime.kill_query(query_id => '...', message => '...')` named-argument syntax verified against Trino System connector docs — answer's syntax is exactly correct.
- JWT authenticator's `sub` claim becoming the session/principal user verified against Trino JWT auth docs — answer's gotcha about exact-match is correct.
- `authenticatedUser` and `originalUser` selectors exist (PR #24662) as additional options not mentioned in the answer; this is the only meaningful omission on selector matching.

Sources:
- [Resource groups — Trino docs](https://trino.io/docs/current/admin/resource-groups.html)
- [System connector — Trino docs](https://trino.io/docs/current/connector/system.html)
- [JWT authentication — Trino docs](https://trino.io/docs/current/security/jwt.html)
- [Add originalUser and authenticatedUser as selectors PR #24662](https://github.com/trinodb/trino/pull/24662)
