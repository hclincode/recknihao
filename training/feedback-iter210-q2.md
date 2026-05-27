# Iter 210 Q2 — Judge Feedback (2026-05-26, EXTENDED PHASE)

**Question**: What does `opa.policy.batched-uri` do differently from the regular endpoint? How does it differ from `opa.policy.row-filters-uri`? Which query types benefit most? What changes in Rego policies to support it?

**Topic**: Trino federation / cross-source connectors (OPA-internals angle)
**Pass thresholds**: general ≥3.5; federation raised ≥4.5

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy (×2) | 2.0 | Multiple factual errors at the core of the answer |
| Beginner clarity | 4.5 | Well-structured, plain English, concrete config and Rego examples |
| Practical applicability | 2.0 | An engineer following this answer would misconfigure OPA |
| Completeness | 3.5 | Touches all sub-questions but misses the actual mechanism (filterResources/indices) |
| **Weighted average (Tech×2)** | **2.80** | **FAIL** topic (≥4.5) and **FAIL** general (≥3.5) |

---

## Verified against official docs

WebFetch + WebSearch against trino.io/docs/current/security/opa-access-control.html, Stackable Trino docs, openpolicyagent.org/integrations/trino, and trinodb/trino issues #25748 (chunking) and #21997 (column masks).

### What the docs actually say

> "If `opa.policy.batched-uri` is not configured, Trino sends one request to OPA for each object, and then creates a filtered list of permitted objects. Configuring `opa.policy.batched-uri` allows Trino to send a request to the batch endpoint, with a list of resources in one request using the under `action.filterResources` node. All other fields in the request are identical to the non-batch endpoint."

> "An OPA policy supporting batch operations must return a list containing the **indices** of the items for which authorization is granted. Returning a null value or an empty list is equivalent and denies any access."

> "Many features in Trino require **filtering** to determine to which resources a user is granted access. These resources are catalogs, schema, queries, views, and others objects."

The batched endpoint is for **filter-list operations only** — operations where Trino starts with a candidate list (catalogs, schemas, tables, columns, queries, views) and asks OPA "which of these is the user allowed to see?" The response is a list of indices into the input array.

---

## What is materially wrong in the answer

### 1. CRITICAL — "Overrides (not complements)" is wrong

The answer's headline framing is:

> "`batched-uri` completely overrides (not complements) the single-call `uri` for the operations it covers. If you configure `opa.policy.batched-uri` but your OPA bundle doesn't implement the batch handler, those authorization checks fail rather than silently falling back to the single-call endpoint."

This is the inverse of how the OPA plugin actually works. The single-call `opa.policy.uri` is **always required** and handles every per-resource authorization check (CreateTable, DropTable, SelectFromColumns on a single table, etc.). The batched URI is an **optional optimization** added on top, used only for the specific filter-list operations where Trino has multiple candidate resources to evaluate in one shot. There is no "no automatic fallback — queries fail" scenario when you simply forget to add a batch handler; the plugin only routes filter-list ops to the batched URI when it's configured, and continues per-object calls otherwise.

This single misframing infects the rest of the answer's recommendations: the "Migration required / queries fail at analysis with authorization errors" caveat is wrong; the "Once enabled, Trino will: Send all non-masking authorization checks to batchAllow" claim is wrong; the "Use the single-call uri only for operations without a batch variant" framing is wrong.

### 2. CRITICAL — The list of batched operations is wrong

The answer states:

> "The operations batched include `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `SelectFromColumns` (allow/deny), `CreateTable`, `DeleteFromTable`, and others."

Per the docs, batched-uri covers **filter-style operations only** — those that operate on a list of resources via `action.filterResources` and return indices. The docs explicitly list "catalogs, schema, queries, views, and others objects" in the filtering context, and provide a Rego example for `FilterColumns`. Single-resource operations like `CreateTable`, `DeleteFromTable`, and individual `SelectFromColumns` checks on one specific table are **not** batched because they have no candidate list to batch over — they are single-resource decisions and stay on the per-object path through `opa.policy.uri`.

### 3. HIGH — The "18 round-trips → 1 round-trip per query" example misrepresents the mechanism

The answer's headline example says:

> "if a single query checks access to 3 catalogs, 5 schemas, and 10 tables, that's 18 separate HTTP round-trips. With the batch endpoint, all 18 go into one request — 1 HTTP call instead of 18."

This is wrong about the mechanism. Batched-uri batches *within a single filter operation* — i.e., one `FilterCatalogs` call carries all 3 catalogs in `filterResources` (1 request instead of 3), one `FilterSchemas` call carries all 5 schemas (1 request instead of 5), and so on. The 18 calls collapse to roughly 3 calls (one per filter operation type), not 1. This is still a meaningful optimization but it is not "all 18 in one request."

### 4. HIGH — The Rego change section misses the actual format

The answer describes the Rego change as "iterate over the batch of access-check inputs and return decisions for all of them at once" and "decisions in the format OPA and Trino expect for batched responses (plural, not singular)." That is hand-wavy. The actual contract per the docs is:

- Input: same payload as the per-object call, but with `input.action.filterResources` populated as an array of resource objects (instead of a single `input.action.resource`).
- Output: a Rego rule that returns `batch contains i if { some i input.action.filterResources[i]; <decision> }` — a list of integer indices into the input array.
- Returning `null` or `[]` denies all items in the batch.

Without naming `action.filterResources`, the indices-return shape, and a minimal `batch contains i if ...` rule, a Rego author cannot actually implement the handler. The answer leaves them stuck.

### 5. MEDIUM — `opa.policy.batch-column-masking-uri` is mentioned but not differentiated

The answer lists `opa.policy.batch-column-masking-uri` as "separately batches column-masking decisions" but does not explain that it uses the same `filterResources` pattern (list of columns in, list of mask expressions out keyed by index). The mechanism parallelism would help a reader understand both endpoints uniformly.

---

## What is correct

- Property names: `opa.policy.batched-uri`, `opa.policy.row-filters-uri`, `opa.policy.column-masking-uri`, `opa.policy.batch-column-masking-uri` — all verified.
- High-level row-filters-uri vs batched-uri distinction (RLS WHERE clause vs general authorization decisions) is directionally right.
- "Dashboard queries listing metadata (SHOW CATALOGS, SHOW SCHEMAS, SHOW TABLES) — trigger FilterCatalogs, FilterSchemas, FilterTables for every visible resource" is correct and is exactly the right benefit case for batching.
- "Cross-catalog federated queries" benefiting from batching is plausible because they exercise FilterTables across more candidates.
- Config block locations (`etc/access-control.properties`) and property syntax are correct.
- Recommendation to test the batch handler in CI/staging before flipping the flag is sound advice (even though the underlying claim that queries will fail without it is wrong — staging testing is still good practice).

---

## What was missing

- **`action.filterResources` input shape** — the single most important thing a Rego author needs to know to implement a batch handler.
- **Indices-return output shape** — the actual contract of what the batch handler must produce.
- **Minimal Rego batch rule example** — `batch contains i if { some i; resource := input.action.filterResources[i]; <decision> }`.
- **Issue #25748 (batch chunking)** — large batches are sent as a single request; for very wide-table cases consider whether your OPA deployment can handle the payload size. The chunking work is in flight but not shipped in 467.
- **Production-fit observability**: OPA decision log entries for batch calls show `filterResources` arrays — the recurring OPA decision logs gap, now flagged for the **19th consecutive iteration** on the federation topic (iter165 through iter210). The answer does not mention how to verify batch calls in OPA logs.
- **Coordinator latency profile**: batching helps coordinator analysis-phase wall time more than it helps query execution. Worth saying explicitly so the engineer doesn't expect end-to-end query speedup.
- **JWT + on-prem k8s production fit**: how the OPA service should be deployed alongside Trino on k8s (sidecar vs separate service) is not discussed; the latency math (`~10ms per call`) is invented without grounding in the actual OPA deployment pattern.

---

## Production-fit assessment

The answer is generally consistent with the on-prem k8s + JWT + OPA + Trino 467 stack described in `prod_info.md`. The framing of "your federated cross-catalog workload" and the SHOW CATALOGS / SHOW SCHEMAS examples fit the production scenario. But the technical errors above mean an engineer following this advice would push a broken or misconfigured OPA policy bundle into production and observe broken authorization behavior — which is worse than not changing anything.

---

## Pattern observation across recent OPA-internals questions

This is consistent with the iter209 Q1 failure mode and the iter163/164/169/171 connection-pool / ALTER CATALOG / flush_metadata_cache failures: the responder confidently asserts a feature behavior that is the opposite of what the docs actually say. The pattern is "confident wrong" rather than "honestly hedging" — but it produces the same on-call outcome (the engineer follows the advice and is broken).

The iter210 Q2 case is worse than iter171 (parameterless flush_metadata_cache invented as named-parameter form) because the headline framing of the answer — "overrides not complements" — is what an engineer would commit to memory and propagate to their team. The next OPA question this responder gets will likely repeat the misframing.

---

## Recommended resource fixes (HIGH PRIORITY before iter211)

### Fix 1 — `resources/22-trino-federation-postgresql.md` or `resources/05-multi-tenant-analytics.md`: rewrite the OPA batched-uri section

The section must teach:

1. **Complementary, not replacement**: `opa.policy.uri` is always required and handles every per-resource decision (CreateTable, DropTable, single-table SelectFromColumns, etc.). `opa.policy.batched-uri` is an opt-in optimization that *only* applies to filter-list operations (FilterCatalogs, FilterSchemas, FilterTables, FilterColumns, queries, views).

2. **The exact mechanism**: when batched-uri is configured, Trino takes operations that would have made N per-object calls (one per candidate resource in a list) and instead makes 1 call with `action.filterResources` carrying the full candidate list. The OPA handler returns indices into the list for permitted items.

3. **What batching does NOT do**: it does NOT take separate filter operations and combine them. FilterCatalogs and FilterSchemas remain separate HTTP calls; each one carries its own resource list internally.

4. **Minimal Rego batch handler example**:

   ```rego
   package trino
   import future.keywords.contains
   import future.keywords.if

   batch contains i if {
     some i
     resource := input.action.filterResources[i]
     # ... your authorization logic against resource ...
     allowed
   }
   ```

5. **No-fallback claim deletion**: the answer should NOT say "queries fail if you forget the batch handler." Without `opa.policy.batched-uri` configured at all, Trino uses the per-object path. With `batched-uri` configured but no batch rule in the bundle, the behavior is the batch endpoint returning empty (deny-all for the filter), which means SHOW CATALOGS etc. return empty — not a query failure. Either way, the dramatic "queries fail" claim is wrong.

6. **GitHub issue #25748**: the chunking work for very large batches is in flight but not shipped in 467 — call this out for engineers planning large multi-tenant deployments.

### Fix 2 — Same resource: parallel structure for `opa.policy.batch-column-masking-uri`

The column-masking batch endpoint uses the same `filterResources`-array-in, indices-or-mask-objects-out pattern as `batched-uri`. Teach them as a uniform family ("filterResources-based batch endpoints") so engineers understand them once.

### Fix 3 — Same resource: OPA decision log entries for batch calls (RECURRING 19 ITERATIONS)

OPA decision log entries for batch endpoints include the full `filterResources` array and the returned indices. The audit-and-debug workflow ("which call did I get from Trino, what did I return, why did the user see this catalog list?") is the missing observability story that has been flagged on every federation answer from iter165 through iter210. This iteration's answer is yet another miss on this front. **Teacher must prioritize.**

### Fix 4 — Same resource: latency framing

Batching helps **coordinator analysis-phase wall time** for queries that need to filter long lists (SHOW CATALOGS in a many-catalog deployment, SHOW TABLES on a many-table schema, column-mask-heavy wide tables). It does not speed up the data-fetch or join phases of a query. Be specific so engineers don't expect end-to-end query speedup.

---

## Verdict

**FAIL** — both the topic-specific 4.5 threshold and the general 3.5 threshold are missed.

Score: **2.80 / 5**

Single biggest fix to apply before iter211: rewrite the OPA batched-uri section in resources to teach the "complement not override" framing and the `filterResources`/indices contract. The teacher should also propagate the same correction to the OPA-internals section of `resources/05-multi-tenant-analytics.md`.
