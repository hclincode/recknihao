# Iter 108 Q1 — Judge Verdict

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Question summary**: Internal product-analytics team needs cross-tenant queries while customer dashboards remain tenant-scoped on the same Trino + Iceberg + OPA cluster. Same-cluster pattern vs. separate cluster/tables?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | Core architectural pattern (separate principal + OPA carve-out + resource group) is correct. OPA row-filter carve-out point is accurate. Resource-groups.json structure is correct (matches verified Trino 467 docs). Selector matching JWT principal name is correct. **One factual error**: `PERCENTILE_CONT(...) WITHIN GROUP (ORDER BY ...)` is NOT supported in Trino — the correct function is `approx_percentile(x, 0.5)`. A SaaS engineer copy-pasting that SQL will hit a parser error. |
| Beginner clarity | 4.5 | Strong structure: principle → 3 steps → why it's safe → gotchas → bottom line. Concrete principal names (`acme-service-account`, `data-team`, `spark-ingest`) make the abstraction tangible. Defense-in-depth explanation is digestible. Minor: assumes the reader already understands "principal", "row-filter mode", and "service account" without definition. |
| Practical applicability | 4.75 | Engineer knows exactly what to do: add OPA rule for `data-team`, mint a JWT with `sub: "data-team"`, configure a resource group entry, deny metadata tables. Resource-groups JSON example is directly usable. Production stack fit is excellent — JWT auth, OPA, Trino 467 resource groups, Iceberg base tables all named correctly. Correctly defers specific OPA Rego to "your external governance document" per prod_info.md guidance. Recommendation against separate cluster/tables answers the question directly. |
| Completeness | 4.75 | Covers: principal separation, OPA carve-out, JWT minting, resource group isolation, metadata-table leak prevention (`$partitions`, `$files`, `system.runtime.queries`), row-filter carve-out, and explicit list of anti-patterns. Could add: (a) audit logging note (internal queries should still be auditable for compliance), (b) brief mention that scanning all 80 tenants will benefit from existing partition pruning if `tenant_id` is a partition column. Both are nice-to-haves, not gaps. |

**Weighted average**: (4.25 + 4.5 + 4.75 + 4.75) / 4 = **4.5625** ≈ **4.56 / 5**

## Verdict

Strong, production-shaped answer that gives an internal-team-vs-customer separation pattern the engineer can ship. The three-step structure (OPA principal carve-out → separate JWT identity → resource group cap) directly maps to the production stack (Trino 467 + OPA + JWT + Iceberg + on-prem k8s). The single material defect is the use of `PERCENTILE_CONT ... WITHIN GROUP` which is not valid Trino syntax — Trino requires `approx_percentile(session_length_ms, 0.5)`. Because both SQL examples are presented as ready-to-paste-and-run, this error has a real chance of biting a junior engineer. Everything else (resource-groups.json shape, OPA carve-out for row-filter mode, deny-list on `$partitions`/`$files`/`system.runtime.queries`, JWT sub claim, defense-in-depth framing) is accurate.

## Verified correct via WebSearch

- **Trino OPA plugin** supports per-principal allow/deny on tables and per-principal row filters (`opa.policy.row-filters-uri`). The carve-out pattern described (data-team principal gets no row filter; tenant principals get an injected `tenant_id = '...'` filter) is the documented OPA row-filter contract. (trino.io/docs/current/security/opa-access-control.html)
- **Resource group selector `"user"` field** matches against the Trino authenticated principal name. With JWT auth, the principal is derived from the JWT `sub` claim by default (configurable via `http-server.authentication.jwt.principal-field`). So `{"user": "data-team", ...}` correctly matches a JWT with `sub: "data-team"`. (trino.io/docs/current/admin/resource-groups.html, trino.io/docs/current/security/jwt.html)
- **`etc/resource-groups.json` vs `.properties`** distinction is correct — the properties file points to the JSON config file via `resource-groups.config-file`. (trino.io 467 docs)
- **Iceberg metadata tables** (`$partitions`, `$files`, `$snapshots`, etc.) are real and would expose per-tenant volumes if not explicitly denied via OPA. The Lakekeeper OPA bridge specifically notes metadata-table handling is a separate access-control concern. (trino.io/docs/current/connector/iceberg.html)
- **JWT `sub` claim → Trino principal** mapping is the production-stack-correct mechanism. (trino.io/docs/current/security/jwt.html)
- **One Trino cluster, per-request principal switching** (via X-Trino-User impersonation OR per-request JWT) is the documented integration pattern — engineers do not maintain 80 connection pools. (trino.io JWT and impersonation docs)

## Errors / Gaps

| Priority | Issue |
|---|---|
| **HIGH** | `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY session_length_ms)` is NOT valid Trino SQL. Trino's aggregate functions list does not include `PERCENTILE_CONT`. The correct expression is `approx_percentile(session_length_ms, 0.5) AS median_session_ms`. The `WITHIN GROUP (ORDER BY ...)` clause in Trino is only supported for `listagg`, not percentile functions. A copy-paste of the example will throw a parser error. |
| LOW | Audit logging not mentioned. Internal cross-tenant queries are higher-privilege and arguably need their own audit lane (event listener captures `data-team` queries separately) for SOC2/compliance. |
| LOW | Partition pruning callout missing — if `tenant_id` is already a partition column, the "scanning all 80 tenants" concern is partly mitigated by partition stats; only a `WHERE tenant_id IN (...)` filter or a `GROUP BY tenant_id` scan-all is needed. Worth a sentence. |
| LOW | `X-Trino-User` impersonation is mentioned in passing but not explained as an alternative to per-request JWT — engineers reading this may not know they can choose between the two. |

## Resource fix recommendations

| Priority | File | Fix |
|---|---|---|
| **HIGH** | `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` (and any other resource that shows percentile SQL) | Audit all SQL examples for `PERCENTILE_CONT ... WITHIN GROUP` and replace with `approx_percentile(col, 0.5)`. Add a one-line callout: "Trino does NOT support `PERCENTILE_CONT WITHIN GROUP`; use `approx_percentile(x, p)`." This is a recurring footgun for engineers coming from Postgres/SQL Server/Snowflake. |
| LOW | `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` | Add a short "Internal analytics audit lane" subsection: when adding an internal `data-team` principal with broader access, route its events through a separate audit-log query tag or partition so compliance reviewers can distinguish internal cross-tenant scans from customer queries. |
| LOW | `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` | Add a sentence noting that `tenant_id` as a partition column means cross-tenant aggregates still benefit from partition pruning per-tenant (one file group per tenant), so a `GROUP BY tenant_id` over all tenants is parallelizable rather than a full unstructured scan. |

## Updated topic state

- **Multi-tenant analytics: isolating customer data in SaaS**
  - Prior: 4.455 avg across 102 questions
  - This question: **4.5625**
  - New running avg: (4.455 × 102 + 4.5625) / 103 = (454.41 + 4.5625) / 103 = 458.9725 / 103 ≈ **4.456 across 103 questions**
  - Status: **PASSED** (above 3.5 threshold, well-tested across many angles)

## Sources (WebSearch verification)

- [Trino OPA access control](https://trino.io/docs/current/security/opa-access-control.html)
- [Trino resource groups](https://trino.io/docs/current/admin/resource-groups.html)
- [Trino JWT authentication](https://trino.io/docs/current/security/jwt.html)
- [Trino aggregate functions](https://trino.io/docs/current/functions/aggregate.html)
- [Trino Iceberg connector (metadata tables)](https://trino.io/docs/current/connector/iceberg.html)
- [Trino file-based access control](https://trino.io/docs/current/security/file-system-access-control.html)
