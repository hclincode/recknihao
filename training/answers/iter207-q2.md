# Iter 207 Q2 — JWT Claims and OPA Identity: What's Actually in input.context.identity

## Answer

The short answer: `input.context.identity.tenant_id` does **not exist**. Your Rego rule will fail silently — OPA evaluates it as undefined, which means the policy denies access. Here's why, and what to do instead.

---

### 1. What Trino extracts from a JWT

When a user presents a JWT to Trino, the JWT authenticator extracts exactly **one field**: the subject claim (`sub`). That becomes the Trino username.

```
JWT payload:
{
  "sub": "alice@acme.com",
  "tenant_id": "acme",
  "role": "analyst",
  "email": "alice@acme.com",
  "iat": 1716700000,
  "exp": 1716786400
}

→ Trino username: "alice@acme.com"
→ Everything else: DISCARDED
```

The `sub` claim is the default. You can configure which JWT field becomes the username with:

```properties
# etc/config.properties
http-server.authentication.jwt.principal-field=preferred_username
```

But that only changes which JWT field maps to the Trino username — it doesn't bring any other claims into OPA.

---

### 2. What input.context.identity actually contains

When OPA evaluates a policy for a Trino query, `input.context.identity` has this shape:

```json
{
  "user": "alice@acme.com",
  "groups": []
}
```

That's it. Two fields:
- `user` — the Trino username (from JWT `sub` or configured `principal-field`)
- `groups` — group memberships from Trino's group provider (file-based or LDAP). Empty array if no group provider is configured.

**`tenant_id` is not here. `role` is not here. `email` is not here.**

So this Rego rule:

```rego
allow {
  input.context.identity.tenant_id == input.resource.schema.schemaName
}
```

evaluates `input.context.identity.tenant_id` as `undefined`. OPA treats undefined in a boolean context as false. The rule never fires, access is always denied.

---

### 3. The groups-field property does not exist

You might find references to `http-server.authentication.jwt.groups-field` online (some blog posts, some older forks). This property **does not exist in OSS Trino 467**.

There is no built-in mechanism to take an array claim like `"roles": ["analyst", "admin"]` from a JWT and populate `input.context.identity.groups`. Groups come from an external group provider, not the JWT payload.

---

### 4. Two workarounds that actually work

#### Pattern 1: Encode tenant_id in the username

Restructure your JWT's `sub` claim to include the tenant identifier:

```
sub: "acme--alice"
```

Then in Rego, extract the tenant prefix:

```rego
# Split on "--", first segment is the tenant
tenant := split(input.context.identity.user, "--")[0]

allow {
  tenant == input.resource.schema.schemaName
}
```

This works because `input.context.identity.user` is always populated. The downside: every service account, human user, and machine identity needs this naming convention enforced at JWT issuance time.

For your case where the JWT already has a separate `tenant_id` claim and a human-readable `sub`, you'd need to change your auth server to issue a `sub` like `{tenant_id}--{actual_user_id}` and update `jwt.principal-field` accordingly.

#### Pattern 2: OPA data bundle tenant mapping

Keep the JWT `sub` as-is. Maintain a data bundle in OPA that maps usernames to tenants:

```json
// data/tenant_map.json (in your OPA bundle)
{
  "tenant_map": {
    "alice@acme.com": "acme",
    "bob@widgets.com": "widgets",
    "svc-acme-etl": "acme"
  }
}
```

Then in Rego:

```rego
tenant := data.tenant_map[input.context.identity.user]

allow {
  tenant == input.resource.schema.schemaName
}
```

This keeps JWT issuer concerns (what's in the JWT) separate from authorization policy (which tenant a user belongs to). The OPA bundle is your source of truth for user→tenant mapping and you update it via your bundle build/push pipeline without touching JWT issuance.

**Trade-off**: The bundle must stay in sync with your user directory. If a user moves to a different tenant, you update the bundle. For service accounts this is easy to manage; for large user directories, you may want to automate bundle generation from your identity provider.

---

### 5. Testing your Rego policy interactively

Before wiring this into production Trino, test the policy with `opa eval`:

```bash
# Test Pattern 1 (username encoding)
opa eval \
  --input '{"context":{"identity":{"user":"acme--alice","groups":[]}}, "resource":{"schema":{"schemaName":"acme"}}}' \
  --data policy.rego \
  'data.trino.allow'

# Expected: {"result": [{"expressions": [{"value": true, ...}]}]}
```

Or use OPA's REPL for interactive debugging:

```bash
opa run --data policy.rego
> data.trino.allow with input as {"context":{"identity":{"user":"acme--alice","groups":[]}},"resource":{"schema":{"schemaName":"acme"}}}
true
```

This lets you verify the field paths before Trino sends real queries.

---

### Summary

| What you expected | What actually exists |
|---|---|
| `input.context.identity.tenant_id` | Does NOT exist — undefined in OPA |
| `input.context.identity.role` | Does NOT exist |
| `input.context.identity.email` | Does NOT exist |
| `input.context.identity.user` | EXISTS — Trino username from JWT `sub` |
| `input.context.identity.groups` | EXISTS — from Trino group provider, not JWT |
| `http-server.authentication.jwt.groups-field` | Does NOT exist in OSS Trino 467 |

To enforce tenant isolation through OPA: either encode the tenant in the username (Pattern 1) or maintain a data bundle mapping users to tenants (Pattern 2). Pattern 2 is more maintainable for production systems with many users.
