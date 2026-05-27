# Answer to Q1: OPA Bundle Management — Policy Distribution Without Restarts (Iter 319)

Manually restarting OPA to update policies is painful and unsafe. OPA's bundle system is designed to solve exactly this problem.

## What is an OPA bundle?

A **bundle is a collection of policy files** (your Rego rules) packaged together, stored at a remote URL, and automatically fetched by OPA on a polling schedule — no restart required.

The two parts of a bundle:
1. **Policy rules** (`.rego` files) — who is allowed to do what, which rows to filter, which columns to mask
2. **Data** (JSON files like `data/tenants.json`) — lookup tables like username-to-tenant mappings, access agreement flags

Both update on the same poll cycle.

## Mechanical flow: how OPA fetches policy updates

1. **You update your Rego policy files** in version control.
2. **CI/CD builds the bundle** — `opa build` packages your `.rego` + JSON data files into a tarball.
3. **CI/CD pushes the tarball to your bundle server** — an S3 bucket, MinIO (your on-prem object storage), or any HTTP endpoint that returns the bundle on GET.
4. **OPA polls the bundle endpoint on a schedule** (typically every 30 seconds to 5 minutes, configurable via `services.<name>.polling.min_delay_seconds` and `max_delay_seconds` in OPA's `config.yaml`).
5. **When OPA finds a new bundle, it loads it in-memory** — replacing the old policy. No restart, no service interruption.

Configure the bundle service in OPA's `config.yaml`:
```yaml
services:
  bundle-server:
    url: https://minio.internal/opa-bundles

bundles:
  main:
    service: bundle-server
    resource: /trino-policy/bundle.tar.gz
    polling:
      min_delay_seconds: 30
      max_delay_seconds: 60
```

## Workflow for a policy change

For your example — "customer just signed a new data access agreement and needs more restricted access":

1. Update the Rego rule in the policy files (tighter row-filter expression for that tenant)
2. Push the updated bundle to your bundle server (MinIO)
3. OPA polls within 30–60 seconds, downloads the new bundle, loads it in-memory
4. The **next** query from that tenant sees the restriction

**For tenant onboarding:** add the new username to `data/tenants.json`, push the bundle, OPA picks it up within a minute.

## Propagation delay: is this a security problem?

OPA bundle changes are **not instant** — there's a propagation window of up to `max_delay_seconds` (typically 30–60 seconds in production).

**What this means:**
- Queries that **start after** the new bundle loads → see the new policy
- Queries that **started before** the new bundle loaded → finish under the old policy (OPA authorizes only at query analysis time, never during execution)

**Is this a real security problem?** Not really, and here's why:

Compare to your alternatives:
- **Manual restarts** (what you're doing now): requires human intervention, typically 5–30 minutes, error-prone
- **File-based Trino access control**: requires Trino restart for any policy change
- **OPA with bundles**: automatic, ~1 minute propagation

A 1-minute window of eventual consistency is a well-understood and accepted trade-off in authorization systems. The key distinction: **in-flight queries finishing under the old policy is not a data leak** — those queries were already authorized and running. The threat model for "must revoke immediately" is better served by terminating the Trino query directly (Trino's `KILL QUERY` command), not by changing OPA policy mid-execution.

## What to monitor in production

OPA silently falls back to the old bundle if it can't reach the bundle server. You want to know immediately if bundle updates stop being delivered:

Alert on: "OPA failed to fetch the latest bundle in the last 10 minutes" (OPA exposes bundle loading status via its `/health` and `/metrics` endpoints).

Also monitor bundle load success in OPA's decision logs — if the bundle status shows `ERRC: bundle download failed`, your policy changes aren't being deployed.

## The production workflow summary

| Step | Who | When |
|---|---|---|
| Update `.rego` rules / `data/tenants.json` | Policy engineer / automated | On every access-agreement change |
| `git push` triggers CI/CD bundle build + push | CI/CD | Automatically |
| OPA polls and loads new bundle | OPA | Within 30–60 seconds |
| Next query sees new policy | Trino + OPA | Immediately after bundle load |

This is the pattern that eliminates SSH-and-restart entirely and makes policy changes a code review + merge operation.
