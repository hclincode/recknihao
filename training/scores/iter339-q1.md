# Score: Iter 339 Q1 — OPA SetSystemSessionProperty for Session Property Override

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Confirms the bypass is real (correct — SET SESSION does override session-property-manager defaults), names the exact OPA operation `SetSystemSessionProperty` (verified against Trino OPA plugin source — passed as the operation string in `checkCanSetSystemSessionProperty`), and correctly distinguishes `SetCatalogSessionProperty` for `<catalog>.<property>` forms. Examples of system-level properties (`query_max_execution_time`, `query_max_run_time`, `task_concurrency`) are all genuine system session properties. No factual errors detected. |
| Beginner clarity | 4.5 | Opens with a direct yes/no, bolds the operation name so it is impossible to miss, and the system vs catalog distinction is explained with concrete property examples a SaaS engineer will recognize. The pseudo-Rego snippet is labeled as pseudocode, which avoids misleading anyone unfamiliar with Rego syntax. Could earn a perfect 5 only by briefly mentioning *why* the session property manager defaults can be overridden (they are defaults, not ceilings) — but that is a nuance, not a clarity gap. |
| Practical applicability | 4.5 | Engineer has the exact operation string to drop into their OPA policy and a clear hint about where to add the deny rule (gated on tier). For the on-prem JWT + OPA stack in `prod_info.md`, this is the correct production lever — the answer correctly defers to OPA rather than file-based access control. Slightly short of a 5 because it does not explicitly say to test the rule with a non-admin JWT identity, nor mention that admins still need to be allowed to set the property for tuning. |
| Completeness | 4.0 | Hits the core ask: (a) confirms the bypass, (b) names `SetSystemSessionProperty`, (c) calls out `SetCatalogSessionProperty` as the sibling action. Missing: no mention that the OPA decision log will record the denied attempt (useful for audit and detecting probing), no mention that resource group `query_max_execution_time` settings in `resource-groups.json` are a separate ceiling that *is* enforceable from the engine side, and no caveat that this also blocks legitimate per-session tuning for power users (so the deny should be conditional on tier/role, which the snippet hints at but doesn't elaborate). Solid coverage of the question as asked. |
| **Average** | **4.50** | **STRONG PASS** |

## What Worked
- Direct, unambiguous answer to "is this possible" — yes, with no hedging.
- Exact operation name (`SetSystemSessionProperty`) given verbatim, bolded, and verified against Trino source.
- Correctly distinguishes system-level vs catalog-level session properties and names the matching second action (`SetCatalogSessionProperty`).
- Examples of system-level properties are accurate and match what the engineer is trying to lock down.
- Pseudo-policy snippet labeled as pseudocode — does not pretend to be production Rego.
- Fits the on-prem OPA-backed authz model in `prod_info.md` — recommends the right layer (OPA), not file-based ACLs.

## What Missed
- Does not explain the deeper "why": session-property-manager values are *defaults*, not enforced ceilings, which is why the override works. The user's mental model would be improved by stating this.
- No mention that the OPA decision log captures denied `SetSystemSessionProperty` attempts — useful for detecting probing behavior and a natural fit with the multi-tenant audit setup.
- No callout that resource-group `softMemoryLimit`/`hardConcurrencyLimit` *are* engine-enforced and so behave differently from session-property defaults; the engineer might still confuse the two enforcement models.
- The deny snippet conditions on `user.tier == "free"` but does not remind the engineer to whitelist admin/internal service identities, which would lock out their own ops tooling on first deploy.
- No reference to where in the OPA bundle this rule typically lives (batch query endpoint vs single-decision endpoint) — minor but practical.

## Technical Accuracy Verification
- **Claim**: "A customer can run `SET SESSION query_max_execution_time = '24h'` to override the 30-second limit set by your session property manager." → **CORRECT.** Session property manager values are applied as defaults at session creation; `SET SESSION` mutates the session value at runtime and is not bounded by the manager unless an access control plugin denies the set. Confirmed via Trino issue #25474 and the session-property-managers admin doc. Source: https://trino.io/docs/current/admin/session-property-managers.html and https://github.com/trinodb/trino/issues/25474
- **Claim**: The OPA operation name is `SetSystemSessionProperty`. → **CORRECT.** Verified in the Trino OPA plugin source (`OpaAccessControl.java`, `checkCanSetSystemSessionProperty` passes the literal string `"SetSystemSessionProperty"` to `queryAndEnforce`). Source: https://github.com/trinodb/trino/blob/master/plugin/trino-opa/src/main/java/io/trino/plugin/opa/OpaAccessControl.java
- **Claim**: `query_max_execution_time`, `query_max_run_time`, and `task_concurrency` are system-level session properties. → **CORRECT.** All three appear in `SHOW SESSION` without a catalog prefix and are documented as system session properties. Source: https://trino.io/docs/current/admin/properties-session.html (referenced in resources/22 with verified `SHOW SESSION` output)
- **Claim**: `SetCatalogSessionProperty` is the matching action for `<catalog>.<property>` forms like `iceberg.split_size` or `hive.max_partitions_per_scan`. → **CORRECT.** Verified in the same OPA plugin source — `checkCanSetCatalogSessionProperty` uses the literal `"SetCatalogSessionProperty"`. The example properties (`iceberg.split_size`, `hive.max_partitions_per_scan`) are real catalog session properties for those connectors. Source: https://github.com/trinodb/trino/blob/master/plugin/trino-opa/src/main/java/io/trino/plugin/opa/OpaAccessControl.java
- **Claim**: OPA is the right tool to close this gap. → **CORRECT** and consistent with `prod_info.md` (OPA is the production authorizer for Trino on this stack).
