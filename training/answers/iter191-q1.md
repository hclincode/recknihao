# Iter 191 Q1 — Debugging CREATE CATALOG Access Denied with OPA

## Answer

## Complete Debugging Runbook for CREATE CATALOG Access Denied

You're hitting a **two-gate permission check** that's tripping up your service account. Here's how to debug step-by-step and which layer is actually broken.

### The Two-Gate System (This Is Key)

Before OPA is ever consulted, Trino verifies **one prerequisite**: that `catalog.management=dynamic` is set in the coordinator's `etc/config.properties`. If it's not set (or set to `static`, the default), Trino rejects `CREATE CATALOG` at SQL parse time with `Catalog management type must be 'dynamic'` — and **OPA never sees the request**. Only if that config gate passes does OPA get to evaluate authorization.

| Gate | Location | What blocks it |
|---|---|---|
| **Gate #1: Feature Enable** | `etc/config.properties` → `catalog.management=dynamic` | Missing or `static` → SQL rejected before OPA; OPA never consulted |
| **Gate #2: Authorization** | OPA Rego policy → rule matching `operation: "CreateCatalog"` + group membership | OPA policy denies → `Access Denied: Cannot create catalog ...` |

Your "Access Denied immediately" is likely Gate #2 (OPA rejecting), but confirm Gate #1 first.

---

### Step-by-Step Debugging

#### Step 1: Verify the config gate is enabled

On the Trino coordinator pod, check `etc/config.properties`:

```bash
kubectl exec -it <trino-coordinator-pod> -- grep catalog.management /etc/trino/config.properties
```

You must see:
```properties
catalog.management=dynamic
```

**If you see `catalog.management=static` or nothing at all**, that's your problem. Add the line, restart the coordinator, and retry. OPA never gets a chance to evaluate when the config gate is off.

#### Step 2: Verify group membership is being sent to OPA

The OPA plugin receives the user's JWT and extracts the `groups` claim. Check:

1. **Does your service account's JWT include a `groups` claim?** Decode the JWT to inspect it:
   ```bash
   echo "$SERVICE_ACCOUNT_JWT" | cut -d. -f2 | base64 -d | jq .
   ```
   Look for a `groups` field:
   ```json
   {
     "sub": "platform-svc@internal",
     "groups": ["platform-admin"],
     ...
   }
   ```

2. **What group name is the OPA policy checking for?** Your group membership must match what the policy's Rego rule expects (e.g., `"platform-admin"`, `"admin"`). This is in your external governance document.

#### Step 3: See what OPA is actually evaluating

Enable **OPA decision logging** on your OPA server. You'll see the exact input document OPA received from Trino:

```json
{
  "input": {
    "context": {
      "identity": {
        "user": "platform-svc",
        "groups": ["platform-admin"]
      },
      "queryId": "20260526_120000_00001_xxxxx",
      "softwareStack": { "trinoVersion": "467" }
    },
    "action": {
      "operation": "CreateCatalog",
      "resource": { "catalog": { "name": "my_catalog" } }
    }
  }
}
```

**The crucial field is `input.action.operation`**: it must be **`"CreateCatalog"`** (not `"CREATE CATALOG"` — it's the SPI method name in PascalCase). If you see `operation: "CreateCatalog"` and your group shows up in the `groups` array, and OPA still returned `allow: false`, then **your Rego policy rule is missing or has the wrong condition.**

Check OPA decision logs via:
```bash
kubectl logs <opa-pod>
# or query OPA's decision endpoint: curl http://opa-server:8181/api/v1/decisions
```

#### Step 4: Enable Trino access-control logging

In the Trino coordinator's `etc/config.properties`, add:

```properties
access-control.log=true
```

Restart the coordinator, then watch:

```bash
kubectl exec -it <trino-coordinator-pod> -- tail -f /var/log/trino/access-control.log
```

When your service account runs `CREATE CATALOG`, you'll see:

```
2026-05-26T12:00:00.000Z user=platform-svc action=CreateCatalog resource=<catalog: my_catalog> result=DENIED
```

**If the log says DENIED but OPA decision log shows `allow: true`**: mismatch between Trino and OPA — check OPA endpoint URL config.
**If user shows up but `groups` is empty**: JWT parsing issue on the Trino side.

#### Step 5: Check for the common mistake: `opa.allow-permission-management-operations`

In `etc/access-control.properties`, you might see:

```properties
opa.allow-permission-management-operations=false
```

**This flag does NOT gate catalog DDL.** It only controls `GRANT` / `REVOKE` / role operations. `CreateCatalog` and `DropCatalog` always go to OPA regardless of this flag. Do not rely on toggling it to permit catalog creation — you must write an explicit Rego allow rule.

---

### Common Mistakes

| Mistake | How to detect | Fix |
|---|---|---|
| `catalog.management` not set to `dynamic` | Step 1: grep shows nothing or `static` | Add `catalog.management=dynamic` and restart coordinator |
| Service account JWT doesn't include `groups` | Step 2: decode JWT, no `groups` field | Contact auth service team; JWT must include group membership claim |
| Service account in wrong group | Step 3: OPA log shows different group name or empty array | Add service account to the correct group in the auth system |
| Rego rule uses wrong operation name (e.g., `"CREATE CATALOG"` not `"CreateCatalog"`) | Step 3: OPA log shows operation accepted but Trino still denies | Change Rego rule to `input.action.operation == "CreateCatalog"` (exact PascalCase) |
| Rego bundle not deployed / typo in file name | Step 3: OPA decision log is empty or shows default deny with no rule match | Verify bundle deployed, syntax valid (`opa fmt` + `opa test`) |
| Assuming `opa.allow-permission-management-operations=true` enables catalog DDL | Step 4: access-control.log shows DENIED | Add explicit `allow` rule for `"CreateCatalog"` / `"DropCatalog"` in Rego |

---

### Quick Sanity Check: Run CREATE CATALOG as a Known-Good Admin

Get a JWT for a user you know is in the admin group and run:

```sql
CREATE CATALOG test_temp USING tpch WITH ("tpch.splits-per-node" = '4');
SHOW CATALOGS;
DROP CATALOG test_temp;
```

- **All three succeed?** Your Trino + OPA stack is working. The service account either isn't in the right group, or its JWT isn't carrying the group claim.
- **First command fails with "Access Denied"?** Even a known-good admin can't run it. Either Gate #1 (config) is off, or the Rego rule is denying everyone.
- **CREATE succeeds but subsequent queries fail with "catalog not found"?** Timing or persistence issue — check if `etc/catalog/` is writable in the pod.

---

### Summary

You have two gates. **Start with Gate #1**: grep for `catalog.management=dynamic` in the coordinator config. If missing or `static`, OPA never sees the request — fix that first and retry. If Gate #1 is correct, move to **Gate #2**: use OPA decision logs and Trino access-control logs to confirm the group membership in the JWT matches what your Rego policy expects, and that the operation name is exactly `"CreateCatalog"` (PascalCase).
