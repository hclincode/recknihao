# Judge Score — Iter 86 Q1

## Score: 4.50 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 4.5 |

## Points covered

Multi-tenant analytics topic coverage in this answer:
- OPA + Trino column masking as a sibling capability to row-level filtering (correct framing).
- Three-decision OPA SPI taxonomy (allow/deny, row filter, column mask).
- Mask injection at the Trino analyzer phase (correct mechanism).
- Before/after SQL rewrite example showing `'****' AS email` and `regexp_replace(phone, '.*', '****') AS phone`.
- Hot-reload of OPA bundles (correctly contrasted vs view DDL changes).
- Composition with row filtering — masks and row filters stack independently in the same query.
- OPA masking vs separate views — comparison table on setup, maintenance, flexibility.
- 1–3 vs 10+ cohort heuristic for when OPA masking beats views.
- GROUP BY pitfall on constant-masked columns + deterministic-hash workaround.
- Production-fit deferral of specific Rego policy to external governance document per prod_info.md.
- CI testing posture (mask assertion as analyst, real value as data-team role).

## Accuracy notes

Verified via WebSearch against trino.io/docs/current/security/opa-access-control.html and github.com/trinodb/trino/pull/21997:
- Column masking via the Trino OPA plugin is real and was added in **Trino 453** (PR #21997, merged July 2024). Production stack is Trino 467, so this works.
- Configuration property: `opa.policy.column-masking-uri` (single column) or `opa.policy.batch-column-masking-uri` (batch, for wide tables).
- Rego response wire format: `{"expression": "<SQL expression>"}` for single-column; batch is array of `{"index": N, "viewExpression": {"expression": "...", "identity": "..."}}`.
- Mask is applied as a SQL expression rewrite in the analyzer phase — exactly as the answer's before/after SQL example shows.
- GROUP BY on a constant-masked column collapsing to one group is standard SQL semantics (correct). Deterministic hash preserving cardinality is correct workaround.
- `regexp_replace(phone, '.*', '****')` is valid Trino syntax.
- The answer's composition story (row filter + column mask in the same query) is correct per Trino's analyzer pipeline.

No factual errors. Two soft omissions: the answer does not name the `opa.policy.column-masking-uri` config property, and does not show the Rego response JSON shape. Both are arguably appropriate given the prod_info.md "defer specifics to external governance doc" posture, but a one-liner pointer would have made the answer more actionable without crossing the line.

## Issues / gaps

1. **Rego response shape not shown** — answer describes WHAT OPA returns but not the wire format. An engineer cross-referencing the official docs will see a JSON shape they cannot map back to the answer's prose.
2. **Config property not named** — `opa.policy.column-masking-uri` is the key the security team needs to set; a pointer would be more actionable than "ask security team."
3. **Trino version requirement (≥453) not stated** — production is 467 so fine, but answer doesn't future-proof for engineers on older clusters.
4. **"Rego" not glossed** — used several times without a one-line definition. Beginners who have heard of OPA but not Rego will lose context.
5. **No example of a deterministic-hash mask** — answer recommends "hash instead of constant" to fix the GROUP BY collapse, but doesn't show `to_hex(sha256(cast(email as varbinary)))` or similar. Two-line snippet would make the workaround copy-pasteable.
6. **Iceberg-side framing missing** — column masking is engine-level (Trino), so masked-vs-real values are NOT stored differently in Parquet/MinIO. A one-line "happens at query time; same files on disk, different per-principal SQL rewrite" would directly answer the engineer's "no separate copies" sub-question.
7. **JOIN-on-masked-column gotcha not mentioned** — same family as GROUP BY: a self-join on a constant-masked column becomes a cross-join. Worth surfacing alongside aggregation.

## Resource fix needed?

Yes — minor, non-blocking. Add to `resources/05-multi-tenant-analytics.md`:
- A "Column masking" subsection alongside the existing OPA row-filter section, showing the Rego response shape (`{"expression": "..."}`) and the `opa.policy.column-masking-uri` / `opa.policy.batch-column-masking-uri` config properties.
- A "GROUP BY / JOIN gotcha on masked columns" callout with the deterministic-hash workaround example using Trino's `to_hex(sha256(cast(col as varbinary)))`.
- Note the Trino 453+ requirement for the column-masking SPI; production 467 is supported.
- Cross-reference: column masking is engine-side — no Iceberg/MinIO storage divergence; same files on disk, different per-principal SQL rewrites at query time.

Multi-tenant topic running average: 4.430 across 82 questions → **4.431** across 83 questions. PASSED (well above 3.5 threshold).
