# Iter 218 Q1 Judge Score

## Score: 4.70

## Topic: Trino federation cross-source connectors

## What the answer got right

- **Two-check OPA model for views correctly described.** Check 1 = view-level `SelectFromColumns` under the caller's identity; Check 2 = base-table `SelectFromColumns` under the view owner's identity. Matches the resources and Trino's OPA plugin behavior verified against trino.io docs and the OPA Rego ecosystem entries.
- **SECURITY DEFINER correctly identified as the Trino default.** Verified against the Trino CREATE VIEW docs (DEFINER is the default; INVOKER is the opt-in alternative). The DEFINER vs INVOKER tradeoff (caller's grants vs owner's grants for base tables) is captured accurately.
- **Identity used for row-filter checks under DEFINER is correctly described as the view owner's, not the caller's.** This is the engineer's actual concern, and the answer addresses it head-on (which is exactly why per-tenant filters configured on the Postgres base table can silently fail to enforce isolation when accessed through a DEFINER view).
- **Correct remediation guidance:** attach the row-filter policy to the view (fires under caller identity in Check 1, gets injected and pushed down), OR switch to SECURITY INVOKER and require analysts to hold direct base-table grants. Both options are technically valid and the tradeoff is articulated correctly.
- **WHERE pushdown through views is correctly described.** Trino expands the view body, combines outer WHERE with view-internal predicates and any OPA-injected row filters, then evaluates pushdown against the PostgreSQL connector. The example of the rewritten Postgres SQL (`SELECT ... FROM public.users WHERE user_id = 123`) is accurate.
- **Pushdown caveats are accurate and version-relevant for Trino 467:** LIKE/ILIKE generally do not push down by default to Postgres, and string range comparisons (>, <, BETWEEN) on VARCHAR have collation safety caveats (the connector explicitly disables range pushdown on character types unless `enable-string-pushdown-with-collate` is set). Verified against Trino PostgreSQL connector docs.
- **OPA decision log guidance is correct.** `SelectFromColumns` per object, identity stamped per call, `input.context.identity.user` field used to distinguish caller vs owner, expect at least 3 entries (view + 2 base tables). `GetRowFilters` is the correct operation name for row-filter checks (verified via Trino OPA docs and Rego policy examples).
- **Concrete verification steps:** `SHOW CREATE VIEW`, `EXPLAIN (TYPE DISTRIBUTED)`, OPA decision log filtering by queryId — all are practical and correct for the production stack (Trino 467 + OPA + Iceberg + Postgres connector).
- **Fits the production environment** (Trino 467, OPA, Iceberg, Postgres connector, on-prem). Does not invent specific OPA policy rules; defers to the engineer's own policy bundle, consistent with prod_info.md guidance.

## What the answer missed or got wrong

- **Minor wording quibble on the row-filter operation name:** the answer hedges with "`GetRowFilters` (or similar, depending on your Trino version)" — `GetRowFilters` is in fact the canonical operation name for the row-filter check (confirmed via the Trino OPA docs and Rego policy examples). The hedge is slightly under-confident but not wrong.
- **Could have mentioned `run-as-owner` / the OWNER recorded in the view metadata more concretely** — the answer says "verify the view's SECURITY mode" but doesn't remind the engineer that under DEFINER, the OWNER row in `SHOW CREATE VIEW` output is the principal that base-table checks run as. This is implied but not crisp.
- **Missing nuance on the recommendation to "attach row filters to the view, not the base table."** This is correct, but the answer doesn't explicitly note that an OPA row-filter rule scoped to the view's `catalogName/schemaName/tableName` triple is what fires in Check 1 — it's slightly hand-wavy on how the engineer actually writes the Rego rule. (Not a deduction since the engineer's external governance doc owns the actual rule text, per prod_info.md.)
- **WHERE pushdown explanation skips one nuance:** the OPA-injected filter from the view-level check is added at the view's *output* boundary, not at the base table boundary directly. The combined predicate is then planned and only the parts the Postgres connector can push down get pushed. The answer's flow is close to correct but slightly elides this planning step.
- **No mention of the AccessCatalog pre-check** that fires before `SelectFromColumns` per catalog — minor, but the engineer who greps decision logs for "what does OPA see for one query" will be confused if they expect exactly 3 entries and see more.
- **The pushdown caveat on LIKE/ILIKE is correct directionally** but slightly understated: with the Trino PR landed for JDBC function pushdown, certain `LIKE` patterns ARE pushed down to Postgres in modern Trino, with caveats around collation. The blanket "do not push down by default" is mostly true for ILIKE but oversimplifies LIKE.

## WebSearch verification notes

- **trino.io CREATE VIEW docs** — confirmed SECURITY DEFINER is the default; SECURITY INVOKER is the named alternative. Confirmed semantics: DEFINER uses view-owner's grants for base-table access, INVOKER uses caller's grants.
- **trino.io OPA access control docs + Trino blog "OPA Arrived"** — confirmed `SelectFromColumns` as the per-table/per-view operation; confirmed two-check model (view object + base table) where Trino does not distinguish table from view at the operation level but generates separate checks per resource. Confirmed the identity field is per-request and reflects whoever the engine evaluates as.
- **GetRowFilters** — confirmed as the canonical operation name in OPA Rego policy examples; the row-filter expression is returned in the OPA response and Trino injects it as a WHERE predicate.
- **Trino PostgreSQL connector docs** — confirmed predicate pushdown limits: range predicates (>, <, BETWEEN) on CHAR/VARCHAR not pushed by default (collation safety); equality / inequality (IN, =, !=) on strings push down; `enable-string-pushdown-with-collate` is the experimental opt-in. Confirms the answer's claim about pushdown caveats.
- **Trino PR #11045** — LIKE pushdown for PostgreSQL exists as JDBC function pushdown; the answer's blanket "no LIKE pushdown" is slightly outdated but not catastrophically wrong for Trino 467 default config.

## Recommendation for teacher

The resource (22-trino-federation-postgresql.md) already covers the two-check OPA model and SECURITY DEFINER/INVOKER tradeoffs in depth — that work is paying off (this answer pulled the right facts cleanly). Two small refinements would close the remaining gap:

1. **Add a one-sentence "expected decision-log entry count for a federated view query" line** so engineers don't get confused by `AccessCatalog` / `FilterColumns` / etc. when they grep by queryId expecting exactly 3 entries.
2. **Tighten the LIKE/ILIKE pushdown guidance** to acknowledge that LIKE pushdown for Postgres exists via JDBC function pushdown (Trino PR #11045 lineage) and that the historic "no LIKE pushdown" is outdated for current versions. ILIKE is the more reliably-not-pushed case.

Neither is a correctness blocker. The Trino federation topic continues to perform well on view + OPA angles; this question (cross-catalog VIEW + OPA, the (a) suggestion from iter217 notes) was handled solidly.
