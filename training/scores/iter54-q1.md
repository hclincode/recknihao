# Score: iter54-q1

**Topic**: Multi-tenant analytics
**Score**: 4.8 / 5.0

## Dimension scores
- Completeness: 5/5
- Accuracy: 5/5
- Clarity: 4/5
- No hallucination: 5/5

## What the answer got right
- Correctly affirms that OPA in Trino routes every table access — including system catalog reads — through the OPA authorization plugin before execution; there is no bypass for system catalogs. Verified against trino.io OPA access control docs.
- Identifies `system.runtime.queries` as a confirmed cross-tenant leak with the correct column inventory (full SQL text, user, query_id, resource_group_id, elapsed time). Verified against Trino's system connector docs and GitHub issue 5464.
- Correctly explains the OPA authorization request shape: action type (e.g., SelectColumns), catalog/schema/table, and principal identity (username, groups, JWT claims) returning allow/deny.
- Distinguishes admin principals from tenant principals via role / group / JWT claim, and correctly recommends deny-by-default on the `system` catalog with an admin carve-out.
- Correctly defers specific Rego policy code to the external governance document — does not fabricate policy syntax.
- Adds operationally valuable depth the question did not strictly require: scope deny to the whole `system` catalog rather than table-by-table (and lists `system.runtime.tasks`, `system.runtime.nodes`, `system.runtime.transactions` as additional leak paths).
- Correctly extends the answer to Iceberg `$`-suffix metadata tables (`$snapshots`, `$history`, `$partitions`, `$files`, `$manifests`) — directly addresses the expected coverage point on Iceberg metadata table denial.
- Surfaces the OPA hot-reload vs file-based-rules restart distinction — directly relevant given the security team's "fix this now" framing.
- Provides a concrete verification recipe (connect as tenant principal, run `SELECT COUNT(*) FROM system.runtime.queries`, expect Access Denied; then confirm admin can still query). Matches the resource's CI test pattern.
- Answer is tightly scoped, no fabricated config keys, no invented Rego syntax, no engine-confusion.

## What the answer missed or got wrong
- Beginner-clarity gloss gap: "principal", "deny-by-default", "carve-out", "hot-reload", "JWT claim", "Rego" used without inline one-line plain-English definitions. A SaaS engineer with no OLAP background would benefit from a single-sentence gloss at first use of each. This is a persistent pattern across multi-tenant answers and is the only reason this answer is not a clean 5.0.

## Recommendation for teacher
No new resource fixes required. `resources/05-multi-tenant-analytics.md` already contains the canonical content (system catalog leak section + Iceberg metadata table section + OPA hot-reload note + verification recipe) and the responder pulled all of it correctly. The only outstanding feedback is the persistent beginner-clarity issue: consider adding a short "Glossary callout" at the top of the system-catalog-leak and metadata-table sections that inlines plain-English definitions for principal / Rego / carve-out / hot-reload, so responses naturally surface those glosses.
