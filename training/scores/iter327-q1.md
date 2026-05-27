# Judge Score — Iter 327 Q1

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All key claims verified against official Trino OPA docs: config keys (`opa.policy.column-masking-uri` / `opa.policy.batch-column-masking-uri`), Rego rule names (`columnMask` singular / `batchColumnMasks` plural), batch response shape (`{"index": N, "viewExpression": {"expression": "..."}}` with the nested wrapper), one-call-per-column vs one-call-per-table semantics, and override behavior. Trino SQL functions (CONCAT, SUBSTR, STRPOS, to_hex, sha256, to_utf8) are all valid Trino built-ins. Silent-failure trap is plausible engineering behavior (no error path documented for mismatched rule names) and is presented as a guardrail, not a doc citation. |
| Beginner clarity | 5 | Opens with plain-language framing ("OPA doesn't mask data in the database. Instead, it tells Trino to rewrite the column..."). Defines patterns A/B explicitly, contrasts single vs batch with a clear when-to-use threshold. The query-rewrite example near the end ("Trino internally rewrites to: SELECT CONCAT(...) AS card_number...") makes the mechanism concrete for an engineer with no prior OPA exposure. Identity context paragraph spells out `input.context.identity` shape. |
| Practical applicability | 5 | Fits the production stack (Trino 467 + OPA already in use, row-filter already wired). Closing "Next step for your production stack" section is directly actionable: use batch URI for wide `events` table, name the rule `batchColumnMasks`, wrap response in `viewExpression`, test in CI. Provides a concrete CI test pattern (assert returned value ends in `****`). Respects prod_info.md guidance — gives general Trino/OPA mechanics without inventing tenant-specific policy. |
| Completeness | 5 | Addresses both halves of the question: (a) "Is there a way?" — yes, with two endpoint choices; (b) "Does Trino or OPA do the masking?" — explicitly answered (OPA returns the SQL expression, Trino rewrites the plan). Covers admin-vs-non-admin distinction matching the user's exact scenario, gives concrete masking expressions for credit card and email (the exact two columns mentioned), notes interaction with existing row-filter setup, performance trade-offs, and the silent-failure trap. Nothing material missing. |
| **Average** | **5.00** | **PASS** |

## What Worked
- Direct answer to the "who does the masking" sub-question — clearly states OPA returns the SQL expression and Trino rewrites the plan. This is the conceptual hook the engineer asked for.
- Side-by-side comparison of single vs batch endpoints, including the critical `expression` vs `viewExpression` response-shape difference that is the most common implementation footgun.
- Working Rego snippets for both patterns with the correct rule names. Snippets use the engineer's actual scenario (credit card + email, admin vs non-admin group).
- Silent-failure table is high-value — explicitly enumerates the four URI/rule-name combinations and which fail. The CI assertion pattern is concrete enough to implement immediately.
- SQL masking recipes (CC first-4, email hash, email domain-preserved, phone, SSN) cover beyond the question and are all valid Trino SQL.
- Final "Next step" paragraph ties everything back to the engineer's stack (Trino 467, OPA, existing row-filter setup on `events`).

## What Missed
- Minor: could note that the `viewExpression.identity` field is optional and lets the masking expression evaluate under a different identity (useful when the mask references columns the caller can't see). Not required by the question.
- Minor: doesn't mention that batch URI overrides single URI if both are set in config — the answer says "use one or the other, not both" which is safe guidance but slightly less precise than the actual override behavior. Not a scoring deduction since the practical advice is correct.
- No mention of Trino version requirement for batch column masking (it landed in a specific release). Trino 467 supports it, so the engineer is fine, but a version note would be a nice belt-and-suspenders.

## Technical Accuracy (verified)
Verified against [Trino OPA access control docs](https://trino.io/docs/current/security/opa-access-control.html):

1. **Config keys**: `opa.policy.column-masking-uri` and `opa.policy.batch-column-masking-uri` — both confirmed verbatim. Confirmed that when batch URI is set, it overrides the single URI.
2. **Rego rule names**: `columnMask` (singular) for single-column endpoint, `batchColumnMasks` (plural) for batch endpoint — both confirmed.
3. **Response shape for batch**: Confirmed exactly as written — array of `{"index": N, "viewExpression": {"expression": "..."}}` with the nested `viewExpression` wrapper. Docs also show an optional `identity` field inside `viewExpression`.
4. **Response shape for single**: Confirmed — just `{"expression": "..."}` with no `viewExpression` wrapper.
5. **One-call-per-column vs one-call-per-table**: Confirmed by GitHub issue #21359 ("When utilizing column masking, unnecessary requests are generated for each column") which motivated the batch endpoint via PR #21997.
6. **Silent-failure behavior**: Not explicitly documented in Trino docs, but the OPA evaluation model returns no decision when no rule matches, and Trino's behavior of leaving the column unmasked when no mask is returned is consistent with how absent rules are handled. The answer presents this as an engineering guardrail rather than a doc citation, which is appropriate.
7. **Trino SQL functions**: CONCAT, SUBSTR (alias for substring), STRPOS, to_hex, sha256, to_utf8 — all verified valid built-ins in [Trino string functions](https://trino.io/docs/current/functions/string.html) and [binary functions](https://trino.io/docs/current/functions/binary.html).

No factual errors found.

## Rubric Update
- Multi-tenant analytics: prior avg 4.469 across 122 questions → (4.469 × 122 + 5.00) / 123 = 4.4729 → **4.473 across 123 questions**. Status: **PASSED**.
