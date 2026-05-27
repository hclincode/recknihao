# Feedback — Iter 211 Q1 (Extended phase)

## Question
We're enabling `opa.policy.batched-uri` to reduce OPA HTTP calls with 200 catalogs. My understanding is batched-uri takes over from the regular uri and handles all checks in one big request. Is that right? What Rego changes are needed? What does the batch endpoint cover?

## Context
This is a **direct retest** of the angle that caused the iter210 Q2 FAIL (2.80). The teacher rewrote the OPA batched-uri section to teach the "complement not override" framing, the `action.filterResources` input shape, the indices-return output shape, and the minimal Rego `batch contains i if { some i; ... }` handler. This question tests whether the resource fix landed.

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5 | Every claim verified against trino.io OPA docs. |
| Beginner clarity | 5 | 200-catalog scenario tied to engineer's exact situation; minimal jargon; reassuring "your existing Rego stays as-is" framing. |
| Practical applicability | 5 | Full properties config block, concrete Rego skeleton, quantified benefit. Production-fit for the on-prem Trino 467 + OPA stack. |
| Completeness | 5 | Hits all three sub-questions (correctness of mental model, Rego changes, batch endpoint coverage) plus fallback behavior. |
| **Average** | **5.0** | PASS (Trino federation raised threshold ≥ 4.5; general ≥ 3.5). |

## What worked — strong recovery from iter210 Q2

The answer's **headline framing** is now docs-accurate and directly corrects the engineer's wrong assumption in the question:
- Opens with "Your understanding is incorrect on the core point" and immediately states "`opa.policy.batched-uri` does NOT take over from `opa.policy.uri`. It COMPLEMENTS it."
- States both URIs must be configured and serve different categories of operations — this is the exact correction that was missing in iter210 Q2.

Verification against trino.io/docs/current/security/opa-access-control.html:

1. **Complement not replace** — VERIFIED. Docs: "If `opa.policy.batched-uri` is not configured, Trino sends one request to OPA for each object, and then creates a filtered list of permitted objects."
2. **Filter-list operations list** (`FilterCatalogs`, `FilterSchemas`, `FilterTables`, `FilterColumns`, `FilterViews`) — VERIFIED. Docs mention catalogs, schemas, tables, columns, queries, views as filtered resource categories.
3. **Input shape** `action.filterResources` as an array of resource objects — VERIFIED. Docs: "Configuring `opa.policy.batched-uri` allows Trino to send a request to the batch endpoint, with a list of resources in one request using the under `action.filterResources` node."
4. **Output shape** zero-based indices array — VERIFIED. Docs: "must return a list containing the _indices_ of the items for which authorization is granted."
5. **Rego pattern** `batch contains i if { some i; resource := input.action.filterResources[i]; ... }` — VERIFIED. Matches the canonical docs pattern.
6. **Graceful fallback** when batched-uri not configured (per-object calls, no error) — VERIFIED.
7. **Single-resource ops** (`CreateTable`, `DeleteFromTable`, `AccessCatalog`, `RenameTable`) always use the single uri because they have no filterResources array — correct interpretation of the plugin's resource model.

The concrete tenant-prefix Rego example (`tenant := split(input.context.identity.user, "--")[0]`) is practical and fits the production setup. The endpoint-coverage table is unambiguous about what batched-uri does and does not handle. The 200-catalog quantification ("200 separate HTTP calls → 1 call") correctly describes the within-filter-op collapsing, not the across-op collapsing that was misrepresented in iter210 Q2.

## Minor nits (not score-affecting)

- Could explicitly cite issue #25748 (batch chunking work in flight, not yet in Trino 467) for engineers planning very large filterResources arrays, but this is optional.
- Could mention `import future.keywords.contains` declaration needed for the `batch contains i if { ... }` syntax — minor Rego setup detail.
- The example claims "Index 0 = events allowed, index 2 = tenants allowed" which is correct but small typo risk in cross-referencing array positions; the engineer will need to test in their own deployment regardless.

## Resource fix landing — confirmed

The iter210 Q2 critical errors are all corrected:
- **"Overrides not complements"** — FIXED. Answer's headline now says "COMPLEMENTS it" and "Both URIs must be configured."
- **Wrong list of batched ops** (CreateTable, DeleteFromTable, single-table SelectFromColumns) — FIXED. Answer correctly lists only Filter* operations as batched.
- **"No automatic fallback / queries fail"** — FIXED. Answer explicitly says "If you don't configure `batched-uri`, Trino falls back gracefully to one per-candidate call... There is no error."
- **"18 round-trips → 1 round-trip per query"** misrepresentation — FIXED. Answer correctly describes "200 separate HTTP calls" collapsing into "1 call" for a single filter operation (e.g., FilterCatalogs), not for the whole query.
- **Rego section hand-wavy** — FIXED. Answer names `action.filterResources` explicitly and the indices-return contract, and gives a complete minimal handler.

## Topic trend

- Trino federation topic moves from 4.431 across 98 → **4.435 across 99** after this 5.0.
- Gap to 4.5 threshold narrows from 0.069 → 0.065. First narrowing iteration after three consecutive widening iterations (iter208-210).
- The single highest-priority recurring gap (OPA decision logs cross-referenced with Trino event listener) is still untested — recommended for a future iteration.

## Recommended next question angles for Trino federation

- (a) OPA decision logs + Trino event listener cross-reference workflow for debugging a denied filter — this is the **20+ iteration recurring gap** that has been flagged in every recent feedback file.
- (b) `opa.policy.batch-column-masking-uri` parallel family (filterResources-in, mask-objects-out) — tests whether the responder generalizes the batched family pattern.
- (c) Trino coordinator HA on k8s and federation query routing/failover.
- (d) Cross-three-source federation (Iceberg + Postgres + second catalog) plan complexity.

## Verification sources

- https://trino.io/docs/current/security/opa-access-control.html (complement framing, filterResources input, indices output, Rego pattern, graceful fallback all verified)
- https://www.openpolicyagent.org/integrations/trino (batch policy examples)
- https://github.com/trinodb/trino/issues/25748 (batch chunking work in flight)
- https://github.com/trinodb/trino/pull/21997 (column masking SPI + OPA implementation)
