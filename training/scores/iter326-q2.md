# Judge Score — Iter 326 Q2

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every key claim verified against official Trino OPA docs: (1) `batched-uri` only applies to filter-list ops (FilterTables/Schemas/Columns/Catalogs/Views) and NOT row-filter evaluation — confirmed; (2) No decision cache / `cache-ttl-seconds` exists in the plugin — confirmed; (3) Row-filter evaluation is a separate `opa.policy.row-filters-uri` endpoint — confirmed; (4) `batch-column-masking-uri` overrides `column-masking-uri` precedence rule is correctly stated implicitly; (5) The endpoint mapping table matches the 10-property list from the docs. The sidecar latency claim (<1ms loopback vs 10–20ms cross-pod) is industry-accurate. The HTTP client pool tuning suggestion is correct. The `opa.http-client.max-connections` default of 32 is reasonable as a documented baseline. No fabricated properties detected. |
| Beginner clarity | 5 | Opens with a direct "short answer" up front, then explains the distinction with concrete examples (50 tables example, `SELECT * FROM events` example). Every jargon term (FilterTables, sidecar, Rego, HTTP client pool) is explained in-context. The "Fundamental Distinction" section uses parallel headings ("Which resources can this user see?" vs "Which rows can this user see?") that walk a beginner through the architectural reasoning. The summary table at the end maps problem → solution which is exactly what a confused engineer needs. |
| Practical applicability | 5 | The engineer asked "did I configure something wrong, or does batched-uri not apply to row filtering?" — answer explicitly says config is correct but solving a different problem, then gives 4 actionable levers (sidecar, HTTP pool tuning with concrete property names and values, Rego optimization with `opa eval --profile`, OPA replicas). The diagnostic section with the actual log line format (`OpaHttpClient - POST /v1/data/trino/rowFilters Status: 200 Response time: 42ms`) and the `io.trino.plugin.opa.OpaHttpClient=DEBUG` log property let the engineer immediately identify which endpoint is being hit. The recommended config block is drop-in ready and fits the on-prem K8s + Trino 467 + OPA stack from prod_info.md. |
| Completeness | 5 | Addresses all three parts of the question: (a) what `batched-uri` actually batches (filter-list ops, with 5 specific operations enumerated); (b) why it doesn't apply to row-filter evaluation (separate endpoint, per-query architecture, no candidates to batch); (c) what actually reduces row-filter overhead (sidecar, HTTP pool, Rego optimization, horizontal scaling). Bonus content: diagnostic logging, complete endpoint map table, fit-for-stack recommended config. The "no decision cache" caveat explicitly closes off the common wrong path (engineers often ask "can't we just cache?"). Nothing material missing. |
| **Average** | **5.00** | **PASS** |

## What Worked
- Crystal-clear lead with the answer up top, before any explanation.
- Concrete numeric example (50 tables: 50 calls → 1 call) makes batching intuitive.
- Architectural distinction between "schema visibility" and "row visibility" gives the engineer a mental model, not just a config fix.
- Diagnostic log snippet (`OpaHttpClient - POST /v1/data/trino/rowFilters ...`) lets the engineer verify which endpoint is being hit in their own environment.
- Recommended config block uses `localhost` with explicit sidecar callout — fits the on-prem K8s deployment in prod_info.md.
- Explicit "no decision cache" callout heads off the natural follow-up question.
- HTTP client pool tuning (`opa.http-client.max-connections=64`) is a real, often-overlooked lever and the explanation of pool exhaustion when concurrent queries exceed pool size is correct.

## What Missed
- Could have mentioned that `opa.log-requests` / `opa.log-responses` properties also exist as alternative debug knobs (the answer uses the `OpaHttpClient` logger only).
- The recommended config does not explicitly tag that it works with the JWT auth setup from prod_info.md, but this is a minor framing issue, not a correctness issue.
- Minor: the answer says "Trino's query planner blocks until OPA responds" — strictly true, but the planner phase vs analysis phase distinction is glossed (still correct enough for the audience).

None of these missed items materially affect the answer quality.

## Technical Accuracy (verified)
WebSearch against trino.io official docs confirmed:
1. **`opa.policy.batched-uri` scope**: The docs state it sends "a list of resources" for filtering ops only — confirmed that it applies to FilterTables/FilterSchemas/FilterColumns/FilterCatalogs/FilterViews and NOT to row-filter expression evaluation. Answer is correct.
2. **No decision cache**: WebFetch of the official Trino OPA docs page confirmed "no mention of decision caching, cache-TTL properties, or similar mechanisms." There is no `opa.policy.cache-ttl-seconds`. Answer is correct.
3. **`opa.policy.row-filters-uri` as separate endpoint**: Confirmed by the docs — row filtering uses its own dedicated URI distinct from the main authorization URI. Answer is correct.
4. **Sidecar deployment recommendation**: Industry-standard practice for low-latency OPA integration; documented in Trino OPA plugin guides and the upstream OPA project. Answer is correct.
5. **10 OPA plugin config properties**: Verified list matches — `opa.policy.uri`, `opa.policy.row-filters-uri`, `opa.policy.column-masking-uri`, `opa.policy.batch-column-masking-uri`, `opa.policy.batched-uri`, `opa.log-requests`, `opa.log-responses`, `opa.allow-permission-management-operations`, `opa.http-client.*`, `opa.context-file`. The answer's endpoint mapping table correctly identifies the 5 policy-URI properties and their roles.

Additionally verified: `opa.policy.batch-column-masking-uri` overrides `opa.policy.column-masking-uri` precedence rule (matches the docs). The answer correctly does not claim a fabricated cache property — a fabrication that has appeared in prior iterations.

Sources:
- [Open Policy Agent access control — Trino Documentation](https://trino.io/docs/current/security/opa-access-control.html)
- [Open Policy Agent for Trino arrived (Trino blog)](https://trino.io/blog/2024/02/06/opa-arrived.html)

## Rubric Update
- Multi-tenant analytics: prior avg 4.465 across 121 questions → (4.465 × 121 + 5.00) / 122 = (540.265 + 5.00) / 122 = 545.265 / 122 = **4.469 across 122 questions**. Status: **PASSED**.
