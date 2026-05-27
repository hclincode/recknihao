# Judge Score — Iter 85 Q1

## Score: 5.00 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |

## Points covered

Multi-tenant analytics checklist items touched:
- Per-tenant row isolation patterns (views vs OPA row-filter injection)
- OPA integration with Trino (analyzer-phase rewriting, where the boundary lives)
- Operational trade-offs (blast radius, failure isolation, scaling, auditability)
- Verification / CI testing posture for tenant isolation
- Hybrid strategy (row filters for high-volume tables, per-tenant views for sensitive ones)
- Production-stack fit (Trino 467 + OPA + JWT, deferral to external governance document)

## Accuracy notes

WebSearch verification against trino.io official docs and Trino release notes:

- **Row filter injection is real**: confirmed in the Trino OPA access control documentation. Configured via `opa.policy.row-filters-uri` in `etc/access-control.properties`. Without that setting, no row filtering is applied.
- **Response format**: OPA must return an array of objects, each `{"expression": "<SQL clause>"}`. Each expression behaves as an additional WHERE clause. Multiple filters can be returned; optionally include an `identity` field to evaluate under a different identity (useful when the filter must reference a column the requesting user cannot see).
- **Version support**: OPA plugin first shipped in Trino 438 (Feb 2024). Production stack runs Trino 467 (Dec 2024), which fully supports row-filter mode.
- **Analyzer-phase rewriting**: confirmed — Trino calls OPA during query analysis and appends the returned expression as a WHERE predicate before execution reaches the connector.
- **The answer's outer JSON shape** `{"rowFilters": [{"expression": "tenant_id = 'acme'"}]}` corresponds to the Rego policy structure shown in the official examples. The bare wire response is the inner array. Either framing is fine at this audience's level.
- **50-tenant threshold**: not an official docs number, but a reasonable industry heuristic. DDL overhead for many per-tenant views does become painful around that point, and OPA Rego maintenance/test maturity tends to be where teams cross over.

## Issues / gaps

None material. Minor polish:
- Column masking is an adjacent OPA capability (same plugin, similar mechanic for column-level redaction) — would have been a natural one-line mention as a follow-up to row filters.
- The OPA response JSON in step 3 is the Rego policy shape rather than the raw HTTP response array. Both are correct at this abstraction level; pedantic readers checking docs might want the wire format called out separately.

## Resource fix needed?

No. `resources/05-multi-tenant-analytics.md` already has the OPA row-filter section (lines 274+, including the response-shape table and the verification recipe). The responder pulled from it cleanly and added the right operational framing (50-tenant heuristic, hybrid strategy, blast-radius caveat). The resource update flagged in iter84 feedback landed correctly.

**Optional follow-up**: add a short "column masking" sister section to `resources/05-multi-tenant-analytics.md` — same OPA plugin, same configuration shape (`opa.policy.column-masking-uri`), and a natural extension for engineers who just learned about row filters.

## Topic status after this answer

Multi-tenant analytics: 4.423 (81q) → **4.430 (82q)**. PASSED, comfortably above 3.5 threshold.
