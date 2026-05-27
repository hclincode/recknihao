# Iter248 Q2 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths
- Correctly identifies resource groups as the right tool and explains the admission-gate mental model in concrete, beginner-friendly terms.
- `rootGroups` key, `hardConcurrencyLimit`, `maxQueued`, `softMemoryLimit`, and `schedulingPolicy` are all valid (verified against https://trino.io/docs/current/admin/resource-groups.html).
- Selector fields `user`, `source`, and `queryType` are all valid (docs list user, originalUser, authenticatedUser, userGroup, source, queryText, queryType, clientTags).
- The properties file wiring (`resource-groups.configuration-manager=file` and `resource-groups.config-file=etc/resource-groups.json`) is exactly correct.
- The `resource_group_id` column does exist in `system.runtime.queries` (added in release 0.206) — verification step is valid.
- Maps cleanly to the on-prem k8s Trino 467 environment: ConfigMap mounting guidance, source-tagging in Spark/JDBC, and the worked Spark-ETL vs analytics split match the user's situation.
- Common pitfalls section is excellent for a beginner (notes the `groups` vs `rootGroups` mistake, missing source tagging, etc.).
- Selector evaluation order ("top-to-bottom, first match wins") is correct.
- Practical example covers config, client wiring, what happens at query time, and verification — fully end-to-end.

## Gaps / Errors
- **Minor inaccuracy on `resource_group_id` type**: The column is `array(varchar)` (hierarchical group path), not a plain string. The verification query would return something like `['federation_adhoc']` or `['global', 'federation_adhoc']`, not the bare string `federation_adhoc`. A beginner copying the query may be confused by the array output. Source: https://github.com/trinodb/trino/issues/5464
- **Scheduling policy claim is slightly off**: The answer describes `fifo` as a valid policy and contrasts it with `fair`. Per docs (https://trino.io/docs/current/admin/resource-groups.html), the valid policies are `fair` (default, FIFO processing), `weighted_fair`, `weighted`, and `query_priority`. There is no `fifo` policy name — `fair` already processes in FIFO order. Using `"schedulingPolicy": "fifo"` in the JSON would likely fail to parse or fall back to default. This is a concrete config bug a user would hit.
- **Hot-reload claim is correct but could be more nuanced**: The answer says file-based resource groups require restart, which matches what users report. Worth noting the DB-backed manager reloads every second if dynamic updates matter, but not a blocker.
- Selector regexes like `".*analytics.*"` and `".*federation.*"` are valid (selectors use Java regex on user/source), so this is fine.
- The answer doesn't mention `clientTags` as another selector option that some BI tools set automatically — small completeness nit, not a real gap given the source-based approach is the most practical.

Sources:
- [Resource groups — Trino current docs](https://trino.io/docs/current/admin/resource-groups.html)
- [system.runtime.queries timestamp issue (confirms resource_group_id type)](https://github.com/trinodb/trino/issues/5464)
- [Trino release 0.206 (added resource_group_id column)](https://trino.io/docs/current/release/release-0.206.html)
