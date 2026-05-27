# Answer to Q1: OPA Action Name for Blocking Session Property Override (Iter 339)

**Yes, it is absolutely possible** — and you're right to be concerned. A customer can run `SET SESSION query_max_execution_time = '24h'` to override the 30-second limit set by your session property manager. **This is a known security gap**, and OPA is exactly the right tool to close it.

## The exact OPA action name to deny

The action name you need to block in your OPA policy is:

**`SetSystemSessionProperty`**

This action fires whenever a user runs `SET SESSION <property> = '...'` for a system-level session property — which includes `query_max_execution_time`, `query_max_run_time`, and `task_concurrency`. These are the properties that apply globally across all queries, not tied to a specific connector.

## How to use it in your OPA policy

In your OPA policy config, add a deny rule for non-admin users:

```
# Pseudocode — your actual policy syntax may vary
if input.action.operation == "SetSystemSessionProperty" && user.tier == "free" {
  deny["Cannot override system session properties"]
}
```

The resources note that **this is the specific action to deny to prevent bypassing per-tier time limits** — so your instinct was correct, and the security hole is well-documented.

## Important distinction: catalog-level properties

There's a separate action called `SetCatalogSessionProperty` for properties like `iceberg.split_size` or `hive.max_partitions_per_scan` (scoped to a specific connector). If you also want to block those, you'd use a separate deny rule, but for your free-tier time limits, `SetSystemSessionProperty` is what you need.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` (OPA decision-log action types section)
