# Iter 220 Q2 Judge Score

## Score: 4.80

## Topic: Trino federation cross-source connectors

## What the answer got right
- **`GetRowFilters` is the correct operation name.** Verified against trino.io docs and community examples — Rego policies match against `input.action.operation == "GetRowFilters"`.
- **`opa.policy.row-filters-uri` correctly described as separate from `opa.policy.uri`.** Matches official Trino OPA plugin configuration.
- **OPA fires at query analysis time, before any data reads.** Correct — this matches both the official Trino OPA docs ("authorization decisions are made during query analysis") and the responder's own resource (`22-trino-federation-postgresql.md` lines 522–527 "OPA is consulted only during query analysis").
- **Row-filter expression is injected as a WHERE clause and participates in predicate pushdown to Postgres.** Correct mechanism — the Trino analyzer rewrites the query, and the PostgreSQL connector then pushes equality/IN/!= predicates down on most column types.
- **Result shape `[{"expression": "tenant_id = 'acme'"}]`** matches the documented response format exactly: an array of `{"expression": "clause"}` objects.
- **Input shape with `action.resource.table` and `context.identity` is structurally correct** — Trino's OPA input does include the table resource (catalogName/schemaName/tableName) and a context block carrying identity (user, groups) and queryId.
- **`decision_logs.console: true` is the correct OPA config to enable console decision logs.** Verified against openpolicyagent.org docs.
- **EXPLAIN ANALYZE guidance is directionally correct** — a fully pushed-down predicate shows up inside the connector TableScan (not as a separate ScanFilterProject/Filter node above it). The official Trino pushdown doc says: "If predicate pushdown is successful, the EXPLAIN plan does not include a ScanFilterProject operation for that clause."
- **Three-step verification (OPA log → pg_stat_activity → EXPLAIN ANALYZE)** is exactly the right operator playbook and is highly actionable.
- **One `GetRowFilters` per table per query** — correct; the plugin invokes row-filter resolution per table reference.
- **Diagnosis table cleanly separates "OPA returned []" from "OPA returned filter but Postgres didn't get it"** — practically useful triage.
- **Ship decision logs to a durable sink** — correct production guidance; stdout is lost on pod restart.

## What the answer missed or got wrong
- **TableScan output formatting is slightly stylized/inaccurate.** The example shows `TableScan[table=app_pg:public.users]\n    constraint on [tenant_id]\n        tenant_id = 'acme'`. Real Trino EXPLAIN output uses a `predicate = (...)` field on the TableScan / `:: [predicate]` annotations or a `Layout` / `constraint` block formatted differently (TupleDomain rendering with column → domain). The user could be misled trying to grep for the literal phrase "constraint on [tenant_id]". Minor — directionally correct, but the formatting is invented.
- **Identity context field — minor uncertainty.** The answer puts `queryId` inside `context`, which matches Trino's documented input, but the explicit field name `queryId` (vs `queryID` or no top-level field at all in older versions) varies slightly across Trino releases. Not wrong, just one place where a literal copy could surprise the user on Trino 467.
- **No mention that the row-filter expression is parsed/validated by Trino as SQL** — if OPA returns malformed SQL like `tenant_id == 'acme'` (Rego-style), Trino will fail the query at analysis. Useful diagnostic signal the answer omits.
- **No mention of OPA batch endpoint** (`opa.policy.batch-row-filters-uri`) — exists in Trino's OPA plugin and is the production-recommended endpoint for high-QPS clusters. The responder's own resource mentions the batch column-masking endpoint but the answer doesn't note the row-filter batch analog.
- **The `identity` field on the result object (optional override)** is not mentioned — OPA can return a `{"expression": "...", "identity": "..."}` and Trino will evaluate the WHERE clause as that user. Niche, but a real feature with security implications worth a line.
- **Predicate pushdown caveat** says "complex expression or function call might not push" — true but vague. The answer could have called out the PostgreSQL connector specifics (range predicates on CHAR/VARCHAR don't push; UUID equality does; etc.) that are highly relevant to a `users` table where tenant_id might be a UUID column.

## WebSearch verification notes
- **trino.io docs (current/481 and Trino 467 behavior is consistent):** confirmed `opa.policy.row-filters-uri` exists as a distinct property; confirmed response format `[{"expression": "clause"}]` with optional `identity` field; confirmed pushdown semantics ("ScanFilterProject absence = pushed").
- **trino.io community/docs/examples:** confirmed `input.action.operation == "GetRowFilters"` is the operation string used in production Rego policies.
- **openpolicyagent.org Decision Logs doc:** confirmed `decision_logs.console: true` (or `--set decision_logs.console=true`) is the documented way to enable local stdout decision logging.
- **trino.io pushdown doc:** confirmed "If predicate pushdown for a specific clause is successful, the EXPLAIN plan for the query does not include a `ScanFilterProject` operation for that clause." The answer's claim (filter-in-TableScan-constraint = pushed; filter-above-TableScan = in-memory) is consistent with this, even though the literal output formatting example is stylized.

## Recommendation for teacher
- Add a **literal EXPLAIN ANALYZE snippet** to `22-trino-federation-postgresql.md` showing the actual Trino 467 output format for a pushed-down vs not-pushed-down predicate against the PostgreSQL connector. Right now responders are inventing plausible-looking but not-quite-real output strings (e.g., `constraint on [tenant_id]`). A captured real example would prevent these small inaccuracies.
- Add a short section on **`opa.policy.batch-row-filters-uri`** (the row-filter batch endpoint) alongside the existing batch column-masking treatment — keeps the row-filter and column-masking sections symmetric.
- Add a one-liner that **OPA must return a SQL-valid expression string** — malformed Rego-style operators (`==`) will fail the query at analysis with a recognizable error, which is itself a verification signal.
- Add a note on the **optional `identity` field** in the row-filter response object — small but the kind of detail that elevates an answer from 4.8 to 5.0.

The answer is strong overall: it correctly diagnoses the user's real fear (silent data leak from a misconfigured policy), gives a complete three-step verification playbook, names the right config keys and OPA operation, and provides a useful diagnosis table. The small deductions are for stylized (not literal) EXPLAIN output and a few missed production-grade nuances (batch endpoint, identity override). Comfortably above the topic's 4.5 raised threshold.
