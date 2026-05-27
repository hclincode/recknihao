# Iter 207 Q2 — Judge Feedback

**Topic**: Trino federation / cross-source connectors (with overlap into Multi-tenant analytics — JWT identity flow into OPA Rego)
**Pass threshold for federation topic**: 4.5
**Pass threshold (general)**: 3.5

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | All four key claims verified against trino.io and openpolicyagent.org official docs |
| Beginner clarity | 5.0 | Concrete JWT payload example, before/after diagram of claim discard, summary table |
| Practical applicability | 5.0 | Two workarounds with runnable Rego, `opa eval` testing recipe, fits the JWT+OPA production stack exactly |
| Completeness | 4.8 | Addresses every facet of the question; minor nit on not mentioning custom JWT authenticator SPI as a third option |
| **Average** | **4.95** | |

**Verdict**: PASS (4.95 ≥ 4.5 federation topic threshold; ≥ 3.5 general)

---

## What was correct and verified

1. **`sub` is the default JWT principal field; only one field becomes the username.** Verified against trino.io/docs/current/security/jwt.html — `http-server.authentication.jwt.principal-field` defaults to `sub` and identifies *the* field that becomes the Trino principal. The answer's claim that "everything else is discarded" is correct: Trino's JWT authenticator does not propagate other claims into the request context.

2. **`input.context.identity` contains exactly `user` and `groups`.** Verified against trino.io/docs/current/security/opa-access-control.html — the documented shape is `{"user": "foo", "groups": ["some-group"]}`. No `extraData`, no `tenant_id`, no propagated JWT claims. The answer's table at the end is accurate.

3. **`http-server.authentication.jwt.groups-field` does NOT exist in OSS Trino.** Verified — current trino.io JWT auth docs list only `key-file`, `required-issuer`, `required-audience`, `principal-field`, and `user-mapping.pattern`. GitHub issue trinodb/trino#28571 (March 2026) is an *open* request to add JWT-claim group extraction, confirming the feature is not yet present. A deprecated `oauth2.groups-field` exists for OAuth2 only — the answer correctly distinguishes this.

4. **Workaround Pattern 1 (encode tenant in username) is legitimate.** Operationally feasible: change the JWT issuer's `sub` format (or change `principal-field`), then `split(input.context.identity.user, "--")[0]` in Rego. The answer correctly flags the operational cost (every issuer must enforce the convention).

5. **Workaround Pattern 2 (OPA data bundle tenant_map) is the recommended pattern.** Verified against openpolicyagent.org/docs/management-bundles — bundles can carry JSON data accessible via `data.<package>.<key>`. The user→tenant indirection keeps JWT issuance and policy concerns separate. The answer's trade-off note (bundle must stay in sync with user directory) is exactly the right caveat.

6. **`opa eval --input ... --data ... 'data.trino.allow'` syntax is correct.** Verified against openpolicyagent.org/docs/cli — this is the documented CLI form for testing policies offline before wiring into Trino.

7. **Fit with production environment is strong.** The answer addresses the exact stack in prod_info.md (custom JWT authenticator + OPA), explains the conceptual flow without inventing specific permission rules (correctly deferred to "the external governance document" implicitly by giving generic patterns), and gives the engineer a concrete unblock path.

---

## Minor nits (not score-blocking)

1. **Did not mention the "build a custom JWT authenticator SPI" escape hatch.** A more advanced engineer might want to know that they *could* write a Trino plugin that reads custom JWT claims and propagates them — for example by populating groups from a `roles` claim before the OPA call. This is a real third option (used in some prod deployments) but it requires Java + Trino SPI knowledge, so deferring to the two simpler patterns is defensible.

2. **Did not reference the prod_info.md governance document explicitly.** A small pointer "specific tenant→user mappings and rules are governed by the external governance document; the workarounds above are mechanical/structural patterns, not policy content" would have aligned even more tightly with the prod-env guidance. Not a real gap because the answer's content is in the right scope.

3. **No mention of caching/TTL on the data bundle approach.** OPA bundles refresh on a poll cadence — if tenant assignment changes (user moves tenants), there is a window where the bundle is stale. A short note ("bundle polls every N seconds; user→tenant changes propagate on the next poll cycle") would be useful but not score-blocking.

---

## Resource fixes needed

**No new resource gaps surfaced.** The teacher's prior work on `resources/05-multi-tenant-analytics.md` already contains the exact content this answer reproduces:
- `input.context.identity` shape (user + groups only) — already documented
- JWT claims being discarded before OPA — already documented
- Pattern 1 (username encoding) and Pattern 2 (OPA data bundle) — already documented
- Note about `groups-field` not existing for JWT — already documented

The weak-ai-responder correctly retrieved and synthesized this content. This is evidence the resource is in good shape on this topic.

**Optional enhancements** (low priority):
- **LOW** — Add a short paragraph on bundle TTL / polling cadence so engineers know the propagation delay for user→tenant mapping changes via Pattern 2.
- **LOW** — Briefly mention the custom JWT authenticator SPI as a third option (with the caveat that it requires building a Trino plugin).

---

## Pattern observation

This is one of the strongest answers on the JWT-into-OPA flow yet. The answer:
- Names the exact failure mode (undefined → false → silent deny)
- Gives two workarounds with runnable code
- Provides a testing recipe with `opa eval`
- Ends with a summary table that doubles as a quick reference

Combined with Q1's 4.625, iter207 averages 4.7875 — well above the federation topic's raised 4.5 threshold. This is the kind of sustained quality needed to lift the topic average above threshold.
