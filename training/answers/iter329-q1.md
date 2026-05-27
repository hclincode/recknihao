# Answer to Q1: OPA Bundle Management for Trino (Iter 329)

Based on the resources in `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`:

## What an OPA Bundle Actually Is

A bundle is a **packaged unit of OPA policy (Rego rules) plus data** that gets downloaded and cached by OPA instances. Instead of pointing OPA at individual `.rego` policy files, you package everything together, push it to a central location (S3, an HTTP endpoint, etc.), and OPA polls that location on a regular schedule to pull the latest version. The big win: you can update policy data (like your tenant-to-username mappings) **without restarting anything** — OPA reloads the bundle, and the next query sees the new policy.

## The Critical Naming Rule for Data Files

This is the most important thing to get right. **OPA only recognizes data files named exactly `data.json` or `data.yaml` — any other filename gets silently ignored.** The specific mistake your team might make: calling your tenant mappings file `tenants.json` instead of `data.json`. When you do this, OPA loads the bundle successfully, but the tenant data simply isn't there — you won't get a warning, you'll just see undefined lookups, and every tenant request gets denied (or hits a fallback rule). The way to verify: after pushing the bundle, run `curl http://opa:8181/v1/data/tenants` — if it returns `{}` instead of your tenant map, the filename is wrong.

## Bundle Directory Structure

The correct layout is:

```
bundle/
  trino_policy/
    row_filter.rego
    column_mask.rego
  tenants/
    data.json        # NOT tenants.json
```

The directory structure becomes your data namespace in Rego. So the file at `bundle/tenants/data.json` becomes accessible in Rego as `data.tenants`. If that file contains:

```json
{
  "tenant_map": {
    "acme-svc": "acme",
    "beta-svc": "beta"
  }
}
```

Then in your Rego policy you reference it as `data.tenants.tenant_map[input.context.identity.user]`.

## Serving the Bundle as an Endpoint

The resources mention that bundles are stored on a **bundle server** — this can be S3, an HTTP endpoint, or similar. OPA is configured to poll that server on a fixed interval. The specific configuration details (the OPA properties file format, how to set the bundle URL in `services.<name>.polling.min_delay_seconds` / `max_delay_seconds`, and the exact HTTP endpoint format) **are not documented in the available resources**.

What I can tell you from the resources:
- OPA pulls bundles from the configured location at a **regular poll interval (typically 30 seconds to 5 minutes)** in production
- Once OPA downloads and activates the new bundle, the **very next query** from Trino sees the new policy — there's no decision cache on Trino's side
- Changes to your tenant mappings (`data.json`) take effect on the next poll cycle, which creates a small propagation window you need to account for during tenant reassignments

## Why This Beats Individual Policy Files

Moving from individual files to a bundle helps because:
1. **Data updates don't require restarts** — add a new tenant to `data.json`, push the bundle, OPA picks it up on the next poll
2. **Cleaner separation** — Rego policy (which rarely changes) is separate from data (which changes every time you onboard a tenant)
3. **Versioning and deployment** — you can package and deploy the whole thing atomically

For a complete answer on the exact OPA configuration format (how to set the bundle URL, authentication if needed, and the HTTP endpoint path structure), you'll need to consult OPA's official documentation, as those specific configuration details aren't in the available resources.

The key action for your team right now: confirm your data file is named `data.json` (not `tenants.json`), and test it with `curl http://opa:8181/v1/data/tenants` to verify OPA is actually seeing your tenant mappings.
