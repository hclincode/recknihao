# Judge Score — Iter 328 Q1

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five load-bearing claims verified: row filters + column masking compose independently during analysis, OPA is consulted only at planning (workers don't call OPA), the Rego `rowFilters` rule name and `{"rowFilters":[{"expression":...}]}` shape match the plugin contract, `batchColumnMasks` (plural) is the correct Rego rule name for the batch endpoint, and the coordinator must be restarted because `etc/access-control.properties` is read at startup only. The "row filter first injects WHERE, then column mask rewrites column references" framing is accurate: planner adds a filter predicate above the table scan and replaces the column reference with the mask expression — both end up in the same plan, no short-circuit. |
| Beginner clarity | 5 | Opens with the direct yes/no answer ("they compose independently, do not interfere"), then walks through analysis-phase mechanics in plain terms. The before/after SQL example showing exactly what plan Trino builds is concrete and unambiguous. The "Alice" scenario with row filter + email/SSN masking makes the composition tangible. No unexplained jargon — "analysis phase," "coordinator," "row filter," and "column mask" are all introduced with their effect. |
| Practical applicability | 5 | Engineer can act immediately: the `etc/access-control.properties` block shows exactly which three URI properties to set; the Rego code shows both `rowFilters` and `batchColumnMasks` patterns side by side; the restart warning explicitly names the silent-failure mode (column masking silently won't apply if you forget to restart and might be mistaken for "they conflict"). Fits the production stack (Trino 467 + OPA on k8s — coordinator restart maps to `kubectl rollout restart`, implicit from prod_info). |
| Completeness | 5 | Directly addresses every sub-question: (a) order — row filter first, mask second; (b) short-circuit concern — explicitly rejected with mechanism (OPA evaluates both independently, mask substitution is in the plan regardless of how many rows survive the filter); (c) "could a narrow row filter bypass masking" — addressed head-on. Adds the silent-failure config trap (forgetting the URI property or restart) which is the actual realistic way this would appear broken in production. Does not pad with unrelated material. |
| **Average** | **5.00** | **PASS** |

## What Worked
- Direct, structured answer that addresses the engineer's exact worry (short-circuiting / narrow row filter bypassing mask) head-on rather than reciting general OPA mechanics.
- The "before transformation / after transformation" SQL pair makes "both apply in the same plan" visually undeniable — far better than a prose explanation.
- Distinguishing the URI path (`batchColumnMask`) from the Rego rule name (`batchColumnMasks`, plural) — this is exactly the trap the resource file flagged as the most common silent failure, and surfacing it answers the unspoken "why might I think they're conflicting when they aren't?" question.
- The restart warning at the end reframes a real cause of perceived "interference" (config not loaded) without inventing nonexistent failure modes.
- All claims align with the Trino OPA plugin contract per official docs and the access-control PR (#2891) that introduced filters/masks application in the analysis phase.

## What Missed
- Nothing material. Minor: the answer could have noted that if multiple `rowFilters` are returned for one table, they are AND-combined (effectively additive WHERE clauses) — relevant only if the user later adds a second row filter. Not asked, and adding it would risk overwhelming the answer. Not a deduction.

## Technical Accuracy (verified)
WebSearch against trino.io/docs/current/security/opa-access-control.html, the Trino blog (trino.io/blog/2024/02/06/opa-arrived.html), and the access-control implementation PR (trinodb/trino #2891) confirms:

1. **Composition**: Row filter and column masking are independent decisions retrieved separately during the analysis phase. Both are applied to the query plan — there is no short-circuit. The plugin "supports retrieving filter definitions" via `opa.policy.row-filters-uri` AND "fetching column masks" via `opa.policy.column-masking-uri` / `opa.policy.batch-column-masking-uri`; these are separate endpoints called independently. Verified.
2. **Order in the plan**: per PR #2891, filters and masks are retrieved during analysis in `StatementAnalyzer.java`, then applied during plan rewrite in `RelationPlanner.java`. The row filter behaves "like an additional WHERE clause" (predicate above the scan); the column mask is a SQL expression that Trino wraps around the column reference (projection rewrite). Both land in the same plan; describing this as "row filter narrows rows, mask rewrites surviving values" is accurate. Verified.
3. **OPA at analysis only, not execution**: confirmed — Trino calls OPA during query planning on the coordinator; workers do not call OPA when reading splits or shuffling. There is no mid-query reauthorization hook. Verified.
4. **`rowFilters` Rego rule name**: confirmed — the plugin expects an OPA response of the form `{"rowFilters": [{"expression": "clause"}, ...]}`. Building this as `rowFilters contains {"expression": expr} if { ... }` with `import future.keywords.contains` is the standard idiomatic Rego pattern and matches what the plugin reads. Verified.
5. **Coordinator restart for new OPA URI**: confirmed — `etc/access-control.properties` is read at coordinator startup, not hot-reloaded. Adding `opa.policy.batch-column-masking-uri` without restarting means the property is ignored and column masking silently won't engage. Verified (consistent with general Trino access-control plugin lifecycle and the resource file's documented behavior).

Answer is fully consistent with official Trino 481 / 476 / 475 docs (current series) and the production stack's Trino 467 + OPA plugin baseline.

## Rubric Update
- Multi-tenant analytics: prior avg 4.473 across 123 questions → (4.473 × 123 + 5.00) / 124 = (550.179 + 5.00) / 124 = 555.179 / 124 = **4.477 across 124 questions**. Status: **PASSED**.
