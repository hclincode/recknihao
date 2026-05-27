# Judge Feedback — Iter 67 Q1

**Topic**: Multi-tenant analytics — Trino resource groups for noisy-neighbor isolation
**Answer file**: /Users/hclin/github/recknihao/training/answers/iter67-q1.md
**Resource consulted**: /Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md (resource groups section, lines 471–608)

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Completeness | 5.0 | All 6 expected coverage points present: what RGs are, correct field names with wrong-name warning, JWT-principal selector matching, concrete JSON config, `resource_group_id` verification, file-based vs DB-backed restart/hot-reload behavior. Bonus: live-incident `kill_query`, deployment checklist. |
| Accuracy | 5.0 | All field names match trino.io/docs. `CALL system.runtime.kill_query(query_id => '...', message => '...')` matches the documented procedure signature. Selector field is `"user"` (Java regex) — correct. File-based requires restart, DB-backed reloads every 1s via `resource-groups.refresh-interval=1s` — correct. Nested group reference `global.heavy_tenants.large_cust_acme` is the correct dotted-path form. |
| Clarity | 5.0 | Strong structure: opening confirmation, what resource groups are, field-name table with "what goes wrong" framing, full working JSON, critical-gotcha callout on selector matching, two verification queries with expected outputs, file vs DB tradeoff with deployment context, plus immediate-relief tool for the live incident. |
| No hallucination | 5.0 | No invented properties or syntax. All configuration is verifiable in Trino 467 docs. Internal consistency: memory percentages sum correctly (heavy_tenants 35% + standard_tenants 50% + internal_admin 5% = 90%, matching the global parent's 90%); nested subgroup caps respect parent caps. |
| **Average** | **5.00** | **PASS** |

---

## Verification (WebSearch against official Trino docs)

| Claim in answer | Verified? | Source |
|---|---|---|
| `hardConcurrencyLimit` is the property name (not `maxRunning`) | YES | https://trino.io/docs/current/admin/resource-groups.html |
| `softMemoryLimit` accepts `"20%"` or `"10GB"` | YES | trino.io docs (same page) |
| `maxQueued` is the property name | YES | trino.io docs |
| `subGroups` is the property name (not `queues`) | YES | trino.io docs |
| Selector `"user"` field is a Java regex matched against the connection's principal | YES | trino.io docs + https://trino.io/docs/current/security/jwt.html (JWT principalField defaults to `sub`) |
| `CALL system.runtime.kill_query(query_id => '...', message => '...')` | YES | https://trino.io/docs/current/connector/system.html |
| File-based requires coordinator restart (no file-watcher) | YES | trino.io docs + GitHub trinodb/trino#14514 |
| DB-backed reloads every 1 second | YES | trino.io docs (`resource-groups.refresh-interval` default 1s) |
| `resource_group_id` column on `system.runtime.queries` | YES | trino.io docs + resource file |

No factual errors. No hallucinated property names or syntax.

---

## What the answer does especially well

1. **Leads with the wrong-name warning before showing the config.** Tells the engineer "using `maxRunning` or `maxMemoryPercent` causes limits to be silently ignored — no error" *before* they see the JSON. This is the most common bug in resource-groups deployments and the answer surfaces it where it will land.

2. **JWT principal selector matching is called out explicitly.** Distinguishes "the `user` field is matched against the JWT subject, not the Trino role name." This is a separate failure mode from the field-name issue and the answer handles both. Concrete failure scenario provided: "If you write a selector matching `acme_role` but the JWT subject is `acme-service-account`, the selector silently never fires."

3. **Production-stack alignment.** ConfigMap mount on coordinator pod (matches on-prem k8s deployment per prod_info.md). JWT framing aligns with the custom JWT authenticator in production. Database-backed manager recommendation is operationally compatible (small Postgres dependency).

4. **Two verification queries with expected outputs.** Engineer can paste the per-query lookup (`SELECT query_id, user, state, resource_group_id...`) and the per-group queue depth query directly. Both reference real `system.runtime.queries` columns.

5. **Live-incident path is separate from the prevention path.** Distinguishes "kill the runaway query right now with `kill_query`" from "deploy the config to prevent the next occurrence." This is the correct operational sequence and matches the resource's emphasis.

6. **Deployment checklist as the closer.** Six concrete steps the engineer can execute in order. The step "Run a deliberately heavy query as Acme and confirm other tenants' queries remain unaffected" is exactly the right validation gate.

---

## Issues found

None. This is a model answer for the noisy-neighbor question pattern.

---

## Topic status

Multi-tenant analytics: isolating customer data in SaaS — running avg **4.367** across 67 questions. **PASSED** (above 3.5 threshold, tested from many angles including: physical isolation models, security INVOKER/DEFINER, OPA system catalog deny, GDPR purge, automated provisioning, resource groups for noisy neighbors, and more).

No teacher action required for this answer. The resource file's resource-groups section (lines 471–608) is well-structured and the responder pulled all the right pieces from it.
