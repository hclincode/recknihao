# Iter28 Q1 Score

**Question**: Platform-level internal analytics across all 80 customers needed, but Trino is configured for per-tenant isolation. How to add cross-tenant internal analytics without exposing cross-customer data to tenants?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.5 |
| Completeness | 5 |
| **Average** | **4.69** |

**Feedback**: Two-service-account architecture (tenant-facing vs internal) correctly presented. JWT principal matching in resource group selectors emphasized correctly ("'user' field matches JWT subject, NOT role names"). Internal schema (`internal_metrics`) with separate GRANT/REVOKE is practical. Resource group JSON separates internal from tenant queries. OPA vs file-based rules for hot-reload noted. CI test examples and platform dashboard SQL included. Technical accuracy docked: `"hardConcurrencyLimit": true` (boolean) in resource group JSON is wrong — it should be an integer like `"hardConcurrencyLimit": 2` or `"maxRunningQueries": 2`; `SET SESSION AUTHORIZATION` is not valid Trino SQL — the CI tests won't run. Practical applicability docked for the same reason — the CI test recipe won't work as-written. "Trino's default access control is allow-all" is a simplification (depends on system access control configuration). Completeness is strong: covers both access patterns, GRANT/REVOKE, resource groups, OPA, internal dashboard query example, and CI guardrails. HTML entities in code blocks.
