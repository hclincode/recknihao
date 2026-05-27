# Answer to Q2: OPA Blocking Session Property Overrides (Iter 338)

Based on the resources available, I can answer part of your question, but I need to be honest about what's missing.

## What the resources confirm

The production environment uses **OPA as the authorization backend for Trino** and the session property manager enforces per-tier limits.

The mechanism is: the session property manager applies limits server-side at query submission time. When a query exceeds the configured execution time limit, Trino kills it with `EXCEEDED_TIME_LIMIT` error code — regardless of what `SET SESSION` the client issued.

## What's missing from the resources

The resources **do not document the specific OPA action names** that Trino sends when a user runs `SET SESSION query_max_execution_time = '24h'`. The resource file lists several OPA operations (`SelectFromColumns`, `ExecuteQuery`, `ImpersonateUser`), but there is no documented entry for the session property change action, or details distinguishing system-level vs. catalog-level session property actions in OPA.

To find the exact action name, you would need to:
1. Check the Trino source code (`OpaAccessControl.java`) for the exact operation name used for session property changes, or
2. Run a test `SET SESSION` with OPA decision logging enabled and inspect the `input.action.operation` field in the OPA log

## The practical protection that's already in place

Your concern is valid, but the current protection model is "enforcement at execution time" rather than "prevention at SET time":

- A tenant *can* run `SET SESSION query_max_execution_time = '24h'`
- But their queries will still be killed at execution time when they exceed the group's configured limit
- The session property manager's server-side limit acts as a ceiling — the client's `SET SESSION` override is accepted, but the actual enforced value is capped by the per-group configuration

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`, `/Users/hclin/github/recknihao/prod_info.md`
