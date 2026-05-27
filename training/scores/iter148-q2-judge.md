# Iter 148 Q2 Judge Report — OPA Column Masking with Trino

**Question scope**: Can OPA enforce per-user column masking in Trino? Does OPA intercept and rewrite SQL, or just block? Can Trino return different column values for the same query depending on principal?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter148-q2.md`

---

## Overall Score

| Dimension | Weight | Score | Weighted |
|---|---|---|---|
| Technical accuracy | 2x | 5.0 | 10.0 |
| Beginner clarity | 1x | 4.5 | 4.5 |
| Practical usefulness | 1x | 4.5 | 4.5 |
| Completeness | 1x | 4.5 | 4.5 |
| **Total** | **5x** | | **23.5** |
| **Weighted average** | | | **4.70 / 5** |

**Verdict**: **PASS** (>= 4.5 weighted average)

---

## Per-Dimension Scores

### Technical accuracy — 5.0
Every load-bearing technical claim verified against trino.io official docs:

- `access-control.name=opa` — correct.
- `opa.policy.uri`, `opa.policy.row-filters-uri`, `opa.policy.column-masking-uri` — all three property names verified verbatim against the Trino OPA access control documentation.
- Endpoint path conventions `/v1/data/trino/allow`, `/v1/data/trino/rowFilters`, `/v1/data/trino/columnMask` — match documented examples exactly.
- OPA response shape `{"expression": "<SQL expression>"}` — correct; docs explicitly show `{"expression": "NULL"}` and `{"expression": "'****' || substring(user_name, -3)"}` examples.
- Column masking as SQL-expression substitution (not allow/deny) — correct.
- Analyzer/analysis-phase application — supported by the PR #21997 description, which modifies `StatementAnalyzer` and `AccessControl` to fetch column masks. Answer's phrasing "at query analysis time — after Trino parses your SQL but before executing it" is accurate.
- OPA receives Trino's username (the `identity.user` field), not raw JWT claims — confirmed.
- Constant mask collapsing GROUP BY — correct standard SQL semantics; deterministic hash via `to_hex(sha256(to_utf8(email)))` is a valid Trino function chain that preserves cardinality.
- Row filtering as a separate but related OPA feature (WHERE-clause injection) — correct.
- "Same query text, different results per principal" — correct, this is exactly the design.

Minor nit (not docked): the answer omits the existence of `opa.policy.batch-column-masking-uri` (which, when set, overrides the single-column URI and is recommended for wide tables). Not technically wrong; just less complete on the operational surface.

### Beginner clarity — 4.5
- Three-step mechanism walkthrough (ask OPA -> OPA returns expression -> Trino rewrites) is concrete and accessible.
- Before/after SQL example makes the abstract "rewrite" concept tangible.
- Comparison table at the bottom (column masking vs row filtering vs allow/deny) is a clean mental model anchor.
- "Same query text, different results" framed in plain language.

Small clarity drag: terms like "JWT-authenticated principal", "Rego bundle", "Trino's analyzer phase" appear without inline glosses. The target reader (SaaS engineer with no OLAP background) may not know "Rego" is OPA's policy language. Half-point deduction.

### Practical usefulness — 4.5
- Drop-in `access-control.properties` config block.
- Three OPA JSON response examples for the engineer's exact columns (`email`, `billing_zip`, hashed phone).
- Runnable test queries with expected results for both principal types.
- "What you need to do next" 4-step checklist.
- Explicit deterministic-hash recipe to dodge the GROUP BY pitfall.
- Two username-encoding patterns (prefix-based, OPA data-bundle lookup) for the JWT-to-username mapping gotcha.

Small drag: the answer correctly defers Rego rule authoring to the external governance document (per `prod_info.md`), but doesn't show even a one-line Rego skeleton to anchor the engineer's mental model of what the security team will be writing. Half-point deduction.

### Completeness — 4.5
All five expected coverage areas hit:
1. How masking works mechanically — yes, with before/after SQL.
2. Config endpoints — yes, all three URIs named correctly.
3. Deterministic hash gotcha — yes, with the right reasoning and a concrete expression.
4. JWT vs username distinction — yes, explicit callout + two mitigation patterns.
5. Row filtering as related feature — yes, separate section with the right distinction.

Bonus: views-vs-masking comparison addresses the implicit "why not just use views?" follow-up.

Gaps (each minor):
- No mention of `batch-column-masking-uri` for wide-table performance.
- No Trino version floor stated (column-masking SPI requires Trino 453+; prod is 467 so fine, but a one-liner would future-proof).
- JOIN-on-masked-column gotcha (same family as GROUP BY: constant mask makes a self-join a cross-join) not mentioned.
- Iceberg/MinIO storage angle ("masking is engine-side, not stored differently") not made explicit — the engineer might wonder if masked data lives in separate files.

Half-point deduction across these four small completeness gaps.

---

## Verified-Correct Claims (with sources)

| Claim | Source |
|---|---|
| `access-control.name=opa`, `opa.policy.uri`, `opa.policy.row-filters-uri`, `opa.policy.column-masking-uri` are the correct property names | https://trino.io/docs/current/security/opa-access-control.html |
| OPA returns `{"expression": "<SQL>"}` for column masking, not allow/deny | https://trino.io/docs/current/security/opa-access-control.html |
| Endpoint conventions `/v1/data/trino/allow`, `/v1/data/trino/rowFilters`, `/v1/data/trino/columnMask` | https://trino.io/docs/current/security/opa-access-control.html |
| Trino sends `identity.user` (username) and `identity.groups` to OPA, not raw JWT claims | https://trino.io/docs/current/security/opa-access-control.html |
| Column masking touches `StatementAnalyzer` (i.e., analyzer phase) | https://github.com/trinodb/trino/pull/21997 |
| Column masking SPI was added in Trino 453 (prod runs 467 -> supported) | https://github.com/trinodb/trino/pull/21997 |
| `'****'` constant mask collapses GROUP BY; deterministic hash preserves cardinality | Standard SQL semantics; Trino `sha256`, `to_utf8`, `to_hex` are documented built-ins on https://trino.io/docs/current/functions/ |

---

## Errors and Gaps

### HIGH severity
None.

### MEDIUM severity
None.

### LOW severity
1. **`batch-column-masking-uri` not mentioned.** For wide tables, the single-column endpoint generates one OPA request per column per query — performance issue documented in trinodb/trino#21359. Production has Iceberg tables that may be wide; the engineer should at least know this option exists.
2. **Trino version floor not stated.** Column-masking SPI requires Trino 453+. Prod is 467 so it works today, but a one-liner ("requires Trino 453+") would future-proof and help readers on older clusters self-diagnose.
3. **JOIN-on-masked-column gotcha missing.** Same family as the GROUP BY pitfall; constant mask turns a self-join on `email` into a cross-join. Worth a sentence alongside the GROUP BY callout.
4. **No Iceberg/MinIO storage clarification.** Engineer's mental model from prod_info.md is Iceberg + MinIO; an explicit "masking is engine-side, the underlying Parquet files are identical for all principals" line would close a likely follow-up question.
5. **No Rego skeleton.** Answer correctly defers policy authoring to external governance doc, but a 3-line illustrative Rego stub (clearly labeled "illustrative — your security team owns the real rules") would help the engineer visualize what they're asking the security team for.

---

## Production-fit assessment

Fully aligned with on-prem Trino 467 + OPA + JWT stack from `prod_info.md`:
- Correctly identifies OPA as the production authz backend (not file-based rules).
- Correctly defers specific Rego policy authoring to "your governance policy repo."
- Correctly handles the JWT-to-username translation gotcha that is specific to this stack's custom JWT authenticator.
- Configuration block uses the production property file path conventions.
- Test queries are runnable against the prod stack as-is.

---

## Resource Fix Recommendations

For `resources/05-multi-tenant-analytics.md` (the OPA section, near the existing row-filter content):

1. **Add `opa.policy.batch-column-masking-uri` callout** — one paragraph explaining that wide tables should use the batch endpoint, and that setting batch overrides the single-column URI. Reference trinodb/trino#21359 for motivation.
2. **Add Trino version requirement note** — "Column masking SPI requires Trino 453+. Production runs 467, so this is supported. On older Trino, `getTableColumnMasks` is absent and only allow/deny is available."
3. **Extend the GROUP BY pitfall callout to cover JOINs** — same root cause (constant mask collapses distinctness); same fix (deterministic hash).
4. **Add an engine-vs-storage clarification line** — "OPA column masking is applied by Trino at query analysis time. The underlying Parquet files on MinIO are unchanged; every principal reads the same files but gets different per-column SQL expressions."
5. **Add a 3-line illustrative Rego stub** with a bright "owned by external governance doc; this is shape only" banner — gives the engineer something to point at when talking to the security team.

These are all LOW-severity polish items. The current answer is solidly above the pass bar without them.

---

## Sources Consulted

- [Open Policy Agent access control — Trino docs](https://trino.io/docs/current/security/opa-access-control.html)
- [Open Policy Agent for Trino arrived (Trino blog, Feb 2024)](https://trino.io/blog/2024/02/06/opa-arrived.html)
- [trinodb/trino PR #21997 — column mask SPI batching](https://github.com/trinodb/trino/pull/21997)
- [trinodb/trino issue #21359 — column-mask request fan-out motivation](https://github.com/trinodb/trino/issues/21359)
- [Trino built-in functions (sha256, to_utf8, to_hex)](https://trino.io/docs/current/functions/)
