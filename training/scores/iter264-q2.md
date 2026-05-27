# Iter264 Q2 Score

Score: 4.75

## Verdict
PASS (PASS = 4.5+)

## Dimension scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Strengths
- Correctly diagnoses the failure mode of application-only WHERE filtering and motivates Trino-side enforcement.
- Recommends a defense-in-depth pattern (tenant-scoped view + OPA deny on base table + OPA deny on Iceberg metadata tables) — all three layers are valid, supported by Trino, and a recognized multi-tenant SaaS pattern.
- Accurately states Trino's default view security mode is `SECURITY DEFINER`, with the view executing as the creator's identity — verified against the Trino CREATE VIEW docs.
- Correctly calls out that on the production stack (Trino 467 + OPA), SQL `GRANT`/`REVOKE` are effectively out-of-band: per the Trino OPA docs, `opa.allow-permission-management-operations` defaults to false so GRANT/REVOKE are denied without OPA evaluation. The answer's framing ("GRANT/REVOKE are ignored — update OPA bundle instead") is practically correct for the stack.
- Specifically warns to deny `$snapshots` / `$files` system tables, which is a real leak vector and frequently missed — strong signal of operator-level understanding.
- Concrete, copy-pasteable view DDL covering both the Iceberg and Postgres sides of the federated join, plus an integration-test checklist (positive view path, negative base-table path, negative metadata path).
- Fits production environment: defers specific OPA Rego rules to the platform team / external governance doc, consistent with prod_info.md guidance.

## Gaps / Errors
- Does not mention OPA's native row-filter and column-masking endpoints (`opa.policy.row-filters-uri`, `opa.policy.column-masking-uri`) as an alternative or complement to per-tenant views. For a large tenant fleet, per-tenant CREATE VIEW does not scale well (one view per tenant per table); an OPA row-filter rule keyed on the JWT claim is the more idiomatic pattern at scale. The answer would be stronger if it acknowledged this trade-off.
- "Beginner clarity" docked one point: terms like "principal," "Rego," "SECURITY DEFINER," "OPA policy bundle" appear without a one-line gloss. A SaaS engineer with no OLAP background would likely need to look these up.
- Minor: phrasing "SQL GRANT/REVOKE statements are ignored" is slightly imprecise — they are denied by default (not silently ignored); the configuration flag `opa.allow-permission-management-operations` controls this. The practical guidance is right, but the mechanism wording could be tighter.
- Could briefly mention that the JWT subject/claims (production auth mechanism) are what the OPA policy keys off — this would close the loop between auth and authz for the reader.

## Technical accuracy notes
Verified via WebSearch against official Trino docs:
- `SECURITY DEFINER` is the default view security mode in Trino — confirmed (https://trino.io/docs/current/sql/create-view.html).
- OPA integrates with Trino as an access-control plugin since Trino 438; supports row-level filters and column masking — confirmed (https://trino.io/docs/current/security/opa-access-control.html, https://trino.io/blog/2024/02/06/opa-arrived.html).
- GRANT/REVOKE behavior with OPA: gated by `opa.allow-permission-management-operations` (default false), denied without OPA evaluation — confirmed. Answer's "ignored" wording is loose but conclusion (don't rely on SQL GRANT with OPA) is correct.
- Iceberg `$snapshots`, `$files`, `$history`, `$manifests` system tables exist and do leak metadata — confirmed (https://trino.io/docs/current/connector/iceberg.html). The recommendation to explicitly deny them in OPA policy is sound.
- Three-layer defense (view + OPA deny base + OPA deny metadata) is a valid, recommended pattern — corroborated by Cerbos/Permit.io/Stackable security writeups.
