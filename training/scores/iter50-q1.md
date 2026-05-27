# Iteration 50, Q1 — Score

**Question**: 30 tenants on one Trino cluster. Large customer's batch reports starve smaller tenants (60s queues). Memory limit on the Trino role didn't help. How to properly cap one tenant's resource consumption, and how to see who's using the most CPU/memory right now?

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

---

## Technical verification (via WebSearch against trino.io)

1. **Is `resource-groups.json` the correct Trino mechanism for capping per-user resource consumption?**
   YES — confirmed by trino.io/docs/current/admin/resource-groups.html. Resource groups define query queues with `softMemoryLimit` (when exceeded, new queries queue), `hardConcurrencyLimit` (max concurrent running queries, required), and `maxQueued` (max queued queries, required). The responder's example JSON is structurally correct (rootGroups with nested subGroups under a parent group, selectors block at the same top level).

2. **Do resource group selectors match on JWT principals/username, not Trino role names?**
   CONFIRMED — Trino docs list `user`, `originalUser`, `authenticatedUser`, and `userGroup` as the selector fields. There is NO `role` selector field. With JWT auth, the username is extracted from the JWT `sub` claim by default — exactly as the responder states. The responder's "gotcha" call-out is correct and load-bearing: a selector keyed on a role name would silently never match.

3. **Does `system.runtime.queries` expose all users' queries by default?**
   CONFIRMED — Trino's system access control documentation states: "If no system access control is installed, then all users are able to view and kill any query." The responder's leak-path warning is accurate and aligned with prod_info.md's OPA-as-authorization model. The instruction "tenant principals must be blocked by OPA or a catalog-level deny rule" matches the production stack correctly.

4. **`system.runtime.kill_query()` syntax — BUG**: The Trino docs and multiple sources confirm the correct syntax is `CALL system.runtime.kill_query(query_id => '...', message => '...')` — it is a **procedure**, invoked with `CALL`, not a function called via `SELECT`. The responder's answer writes `SELECT system.runtime.kill_query(query_id => '...', message => '...')`, which will fail with a syntax error in Trino 467. This is a real, copy-paste-into-production-and-it-breaks bug at exactly the moment (active incident) when the engineer needs the SQL to work the first time.

5. **Production-stack fit**: Answer correctly references JWT principal matching for the prod auth stack (JWT + OPA per prod_info.md). Correctly defers OPA policy specifics ("blocked by OPA or a catalog-level deny rule") rather than inventing policy. Resource group config is on-prem-stack neutral (works on the prod Trino 467). Anchored well.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 4 | Resource-group mechanism, JSON structure, selector-matches-principal-not-role gotcha, `system.runtime.queries` leak path, and the role-vs-resource-consumption distinction are all verified accurate. The `kill_query` syntax bug (SELECT instead of CALL) is the one factual error. It is a copy-paste-and-it-fails error during an incident, which is the worst possible context for a syntax bug. One soft technical nuance missed: `softMemoryLimit` triggers queuing when the *group's* aggregate memory exceeds the threshold, but a single very large query can still consume more memory than the soft limit before queuing kicks in — for true per-query memory caps the engineer also needs `query.max-memory-per-node` / `query.max-memory` server properties. Not naming this means the resource-group config alone may not stop a single 80%-of-cluster query from the big tenant. |
| **Beginner clarity** | 4 | Strong opening reframe (role = data access, not resource consumption) — defuses the engineer's confusion about why the memory limit didn't work. Inline plain-English glosses on `softMemoryLimit` ("when queries exceed 20% of cluster memory, new queries queue instead of running immediately"), `hardConcurrencyLimit` ("at most 3 of the large tenant's queries run simultaneously"). The JSON example is annotated. Beginner-clarity weakness: "JWT principal", "JWT subject", "JWT sub claim", "OPA", "catalog-level deny rule", "snapshot isolation" appear without inline one-line definitions. A reader who has never set up JWT auth will not learn from this answer what "sub claim" actually is or where to find it. |
| **Practical applicability** | 4 | Engineer leaves with: (a) clear diagnosis (role doesn't gate resource consumption); (b) runnable resource-groups.json with exact JSON structure and selector for the large tenant; (c) the gotcha that would silently break the fix (selector keyed on role name does not match); (d) a runnable SQL to see current per-user usage; (e) the leak-path warning that this SQL must not be exposed to tenant principals; (f) immediate-incident relief via kill_query; (g) tuning guidance (15-25% softMemoryLimit, 2-5 hardConcurrencyLimit). The kill_query syntax bug costs one point — the engineer needs that SQL to *work* at incident time and the answer hands them invalid syntax. Also missing: how to reload resource-groups.json (does it require coordinator restart, or hot reload via the file-based resource group manager?) — operationally relevant for "I edited the file, now what?" |
| **Completeness** | 5 | Both halves of the two-part question are addressed: (1) how to cap one tenant's resource consumption — resource groups with concrete JSON, the role-vs-resource-group distinction, the selector-principal-not-role gotcha, tuning ranges; (2) how to see who's using the most right now — runnable SQL on `system.runtime.queries` with ORDER BY execution_time_ms, plus the leak-path warning, plus the during-incident kill_query escape hatch. Tuning guidance and a "your existing isolation still handles data access separately" closing reconciliation are bonus. |

**Average**: (4 + 4 + 4 + 5) / 4 = **4.25**

---

## Rubric update

Topic: Multi-tenant analytics: isolating customer data in SaaS
- Prior: avg 4.270 across 51 questions
- New running avg with iter50 Q1 = (4.270 × 51 + 4.25) / 52 = (217.77 + 4.25) / 52 = 222.02 / 52 ≈ **4.270** across 52 questions
- Status: **PASSED** (unchanged, well above 3.5 threshold)

## Notes for teacher

Primary resource gap (NEW): `resources/05-multi-tenant-analytics.md` should have a "Resource groups for noisy-neighbor isolation" subsection. The responder's overall framing was strong but introduced a `kill_query` syntax bug (`SELECT` instead of `CALL`). The resource should explicitly show the correct invocation:

```sql
CALL system.runtime.kill_query(
  query_id => '20260524_134522_00123_abcde',
  message  => 'Throttling: exceeding allocated resource group'
);
```

with a one-line note that `kill_query` is a **procedure** (invoked with `CALL`), not a function (invoked with `SELECT`). The same resource should also mention `query.max-memory-per-node` and `query.max-memory` as the per-query memory cap server properties that complement resource groups — resource groups gate *new* queries by group-aggregate memory, but a single query can still spike before queuing kicks in, so the per-query caps are needed as the second guardrail.

Secondary resource gap (recurring): beginner clarity — `JWT sub claim`, `principal`, `OPA`, `catalog-level deny rule`, `snapshot isolation` continue to appear without inline plain-English glosses across multi-tenant answers. This has been flagged repeatedly (Iter 3 Q3, Iter 4 Q5, Iter 5 Q5, Iter 6 Q1). A single "Key terms used in this section" gloss block at the top of `resources/05-multi-tenant-analytics.md` would close this gap across many answers.

Operational gap: the responder should know whether editing `resource-groups.json` requires a coordinator restart or hot-reloads via the file-based resource group manager. The Trino docs say file-based resource groups support refresh on a configurable interval (`resource-groups.config-refresh-period`). Adding this one-line note to the resource (and to any "deploy and verify" section) would prevent the next "I edited the file and nothing happened" follow-up question.
