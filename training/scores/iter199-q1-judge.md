# Iter 199 Q1 Judge — system.query() Security

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings

- **Core thesis is correct and verified against official Trino docs.** The PostgreSQL connector page explicitly states: "Only the data source performs validation or security checks for these queries using its own configuration. Trino does not perform these tasks" and "The query text is not parsed by Trino, only passed through." The answer's central claim — that OPA row filters, column masks, and base-table access checks do not apply to `system.query()` — is fully accurate.
- **The bypass mechanism explanation is correct.** OPA row-filter enforcement works via analyzer-time query rewriting; since `system.query()` skips the analyzer for the underlying tables, row-filter predicates are never injected. This matches the documented behavior of the Trino OPA plugin (row filters are injected at analysis time per the OPA access-control docs).
- **The three-layer bypass framing (views, base-table SELECT denial, row filters) is excellent SaaS-relevant analysis** and aligns with the resources/05 multi-tenant pattern.
- **Minor technical accuracy concern on OPA operation naming.** The answer names `ExecuteTableFunction` as the OPA action operation. The official Trino OPA documentation does not enumerate this specific operation by name in the public docs I could verify; the actual operation in the Trino OPA plugin source is typically `ExecuteFunction` (with a function-kind discriminator) or in some versions `ExecuteProcedure`. The `checkCanCallFunction()` SPI method name referenced in the prose is also slightly off — the modern Trino SPI method is `checkCanExecuteFunction` (and a separate `checkCanExecuteTableProcedure` for table procedures). The Rego policy snippet would likely need adjustment to match the exact operation string the OPA plugin emits for table-function invocations on a given Trino version. This is the only meaningful accuracy gap; it does not change the conclusion or the recommended mitigation, but the literal Rego snippet may not work as written without verifying the action operation name for the deployed Trino version.
- **Practical guidance is production-ready.** The three mitigations (deny via OPA, mandatory code-review checkpoint, prefer views) are concrete and correctly prioritized. The comparison table at the end is a strong artifact a SaaS engineer can hand to security review.
- **Beginner clarity is excellent.** The answer defines what "query rewriting" means, explains why bypassing it removes the row-filter injection, and walks through a concrete attack scenario with literal SQL the engineer could try. No undefined jargon.
- **Completeness covers all four required dimensions** (row filter bypass, column mask bypass, OPA function-call gating, practical mitigation).

## Resource fix suggestions

- In resources/22-trino-federation-postgresql.md, add a short subsection under the `system.query()` discussion that:
  1. Explicitly names this as a security-relevant escape hatch with the exact Trino doc quote ("query text is not parsed by Trino, only passed through"), so the weak responder cites the source directly.
  2. Clarifies the correct OPA operation string used by the modern Trino OPA plugin for table-function invocations — verify against the deployed Trino version (likely `ExecuteFunction` with function kind, not `ExecuteTableFunction`). Provide a Rego example whose `input.action.operation` value is known to match what Trino actually sends.
  3. Cross-references resources/05 multi-tenant for the three-layer bypass framing so the weak responder can compose the two cleanly.
- In resources/05-multi-tenant-analytics.md, add a "things that bypass OPA row filters" callout enumerating `system.query()`, raw connector passthrough, and direct catalog access from privileged service accounts, so this attack class is recognized in any tenant-isolation question, not just Trino-federation ones.
