# Iter 156 Q1 — Judge Report

**Question topic**: OPA column masking in Trino — does OPA gate queries or transform data; where does masking happen (Trino vs MinIO)?

---

## Scores

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Technical accuracy | 4 | 2x | 8 |
| Clarity | 5 | 1x | 5 |
| Practical usefulness | 4 | 1x | 4 |
| Completeness | 4 | 1x | 4 |
| **Weighted average** | | | **21/5 = 4.20** |

**Verdict**: FAIL (< 4.5 threshold)

---

## Per-dimension rationale

### Technical accuracy — 4/5
The answer's core architecture is correct and matches the official Trino OPA docs: OPA does both allow/deny gating AND can return masking expressions; masking happens inside the Trino engine (not MinIO); `access-control.name=opa`, `opa.policy.uri`, and `opa.policy.column-masking-uri` are real, correctly-named properties; OPA returns a SQL expression that Trino substitutes for the column. All verified against trino.io/docs/current/security/opa-access-control.html.

However, there are precision gaps:

1. **Response format is slightly under-specified.** The single-column-mask response is `{"expression":"..."}` but the official format actually requires the response to come back as `{"result": {"expression": "..."}}` from an OPA query (OPA wraps policy decisions under a `result` field), and crucially the answer omits the **batch column masking** endpoint (`opa.policy.batch-column-masking-uri`) which returns an array of `{"index": N, "viewExpression": {"expression": "..."}}` objects. For a wide events table with PII, the batch endpoint is the recommended one — the per-column endpoint triggers a request per column even for non-queried columns (known performance issue trinodb/trino#21359). This is a meaningful gap for a production answer.

2. **"Substituted before fetching from MinIO"** is technically imprecise. The mask SQL expression is injected during query analysis/planning, but if the underlying column is referenced by the mask (e.g., `to_hex(sha256(to_utf8(email)))`), Trino DOES fetch the raw email bytes from MinIO and then applies the masking expression in-engine before returning results. The answer's phrasing "Trino substitutes the masked expression *before* fetching from MinIO, so the raw email never travels from MinIO to the caller" can mislead the engineer into thinking the bytes never leave object storage. The correct claim is: raw bytes are read by Trino workers but never returned to the client.

3. **JWT vs identity payload not addressed.** The question is in a JWT-auth environment (per prod_info.md). Trino's OPA plugin sends only `{user, groups}` in the `identity` object — not the full JWT claims. An engineer building OPA policies needs to know they cannot inspect arbitrary JWT claims (e.g., team, tenant_id) unless those are mapped into Trino groups via the authenticator. The answer says "support team" / "analytics team" as if these are first-class to OPA, but the mapping from JWT → group is non-trivial and not mentioned.

4. **prod_info.md deferral missing.** The answer writes a concrete worked policy (mask expression for email). prod_info.md is explicit: "Do NOT attempt to write specific OPA policies, role hierarchies, or permission rules — defer those to the external governance document." The answer crosses that line by giving the actual mask expression and Rego-language reference without the external-doc deferral.

### Clarity — 5/5
Excellent structure. Opens with the direct answer ("OPA does both, in this order"). The before/after SQL example makes the masking concept concrete instantly. Clear separation between allow/deny vs column-masking modes. "Defense in Depth" and "MinIO bypass" sections preempt natural follow-up questions. Zero unexplained jargon.

### Practical usefulness — 4/5
The engineer can take this answer and immediately understand what `access-control.properties` needs and what an OPA endpoint must return. The before/after SQL is gold. Two gaps prevent a 5: (a) no mention of batch endpoint which is what they'd actually want in production for a wide events table; (b) no pointer to the JWT-claim → group mapping problem they'll hit when writing the policy. The "what NOT to do" angle (network controls to prevent direct MinIO bypass) is well-placed.

### Completeness — 4/5
Answers both halves of the question (gates queries vs transforms data; Trino-side vs MinIO-side). Missing: batch column masking endpoint, the `result` wrapper in OPA responses, the `{user, groups}` identity payload limitation, row-filter sibling feature (relevant since the engineer may want row-level controls on PII tables too), and the prod_info.md deferral.

---

## Verified correct (with sources)

- `access-control.name=opa` and `opa.policy.uri` — verified at [Trino OPA access control docs](https://trino.io/docs/current/security/opa-access-control.html).
- `opa.policy.column-masking-uri` is a real, correctly-named optional property — verified at same source.
- Allow/deny response has a boolean `allow` field — verified.
- Column mask response contains an `expression` field with a SQL expression — verified.
- Masking happens inside the Trino engine (StatementAnalyzer + AccessControl), not at MinIO — verified via [PR #21997](https://github.com/trinodb/trino/pull/21997) and SystemAccessControl SPI docs.
- OPA integration shipped in Trino 438 — verified via [Trino OPA arrived blog](https://trino.io/blog/2024/02/06/opa-arrived.html). Production is on Trino 467, so feature is available.

## Errors / gaps

| Severity | Issue |
|---|---|
| MEDIUM | "Before fetching from MinIO" is imprecise — Trino does read raw bytes from MinIO; masking is applied in the engine before results return to client. |
| MEDIUM | Batch column masking endpoint (`opa.policy.batch-column-masking-uri`) omitted — recommended for wide tables, single-column mode hits known perf issue #21359. |
| MEDIUM | Identity payload to OPA is only `{user, groups}` — JWT claims are not passed through. Engineer needs to know group mapping is the integration seam. |
| MEDIUM | prod_info.md deferral missing — answer provides concrete mask expressions; should note specific policies live in external governance doc. |
| LOW | OPA response wrapper `{"result": {...}}` not shown — minor since the inner shape is what matters for policy authors. |
| LOW | Row filters (`opa.policy.row-filters-uri`) not mentioned as a sibling feature for tenant or PII row-level controls. |

---

## Resource fix recommendations

**MEDIUM** — `resources/` OPA/authorization content should add:
1. The batch column masking endpoint and the per-column performance issue (trinodb/trino#21359), with the corrected response array shape.
2. A one-paragraph note on what Trino actually sends to OPA (`{identity: {user, groups}}` — not JWT claims), and how to map JWT claims to Trino groups via the authenticator.
3. The "raw bytes are read by workers but never returned to client" precision for the masking-vs-MinIO question.
4. Reinforce the prod_info.md deferral pattern: present mask expression shapes as conceptual examples and explicitly say specific policies live in the external governance doc.

**LOW** — Add a short cross-reference between column masking and row filters so an answer to a PII question naturally surfaces both controls.

---

## Sources

- [Trino OPA access control documentation](https://trino.io/docs/current/security/opa-access-control.html)
- [Trino OPA blog announcement](https://trino.io/blog/2024/02/06/opa-arrived.html)
- [PR #21997 — Add SystemAccessControl.getTableColumnMasks SPI and OPA implementation](https://github.com/trinodb/trino/pull/21997)
- [Issue #21359 — Unnecessary requests per column with column masking](https://github.com/trinodb/trino/issues/21359)
- [PR #2891 — Add support for row filtering and column masking](https://github.com/trinodb/trino/pull/2891)
