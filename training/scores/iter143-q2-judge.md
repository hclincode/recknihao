# Iter143 Q2 — Judge Score

**Question**: 30-customer SaaS platform; one customer's morning exports slow shared dashboards. Can Trino give per-customer resource limits or separate lanes for heavy queries?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter143-q2.md`

---

## Score breakdown

| Dimension | Score | Reasoning |
|---|---:|---|
| Technical accuracy | 5 | All property names, scheduling policy, selector semantics, config file split, restart requirement, and kill_query syntax verified against trino.io docs. |
| Clarity for SaaS engineer with no OLAP background | 5 | Concrete scenario named upfront ("morning export starves dashboards"); each property explained inline; minimal-fix shown before scale-up; "isolation, not fairness" framing in the close. No undefined jargon. |
| Practical usefulness | 5 | Three concrete JSON configs (minimal, per-tenant, weighted), exact kubectl restart command, runnable kill_query syntax with the production date format `20260526_…`, and a `system.runtime.queries` SELECT to verify routing. Engineer can copy/paste. |
| Completeness | 5 | Covers: what resource groups do, minimal vs scaled config, weighted_fair for query-type isolation, selector matching against JWT principal, queue/maxQueued behavior, separate properties file gotcha, restart caveat, immediate-relief kill_query, and verification query. |

**Average**: (5 + 5 + 5 + 5) / 4 = **5.0**

---

## What was verified correct (via WebSearch against trino.io docs)

1. **`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`, `schedulingPolicy`, `schedulingWeight`** — all correct JSON property names per https://trino.io/docs/current/admin/resource-groups.html.
2. **`softMemoryLimit` accepts absolute (`"10GB"`) or percent (`"20%"`) values** — correct.
3. **`weighted_fair` is a valid `schedulingPolicy`** — correct; sub-groups selected by `schedulingWeight` and current concurrency relative to share.
4. **Separate `etc/resource-groups.properties` file is required** — correct. Putting these keys in `config.properties` is silently ignored. `resource-groups.configuration-manager=file` + `resource-groups.config-file=etc/resource-groups.json` are the canonical keys.
5. **Selector `user` field is Java regex matched against the connection principal**; under JWT auth with default `principal-field=sub`, that's the JWT `sub` claim — correct (verified against trino.io resource-groups + JWT auth docs).
6. **File-based manager has no file watcher; coordinator restart required to apply changes** — correct (DB-backed manager hot-reloads every ~1s, file-based does not).
7. **`CALL system.runtime.kill_query(query_id => '...', message => '...')`** — correct named-parameter syntax per trino.io system connector docs.
8. **`resource_group_id` column on `system.runtime.queries`** exposes the full dotted group path as an array — correct.
9. **First-match-wins selector evaluation top-down** — correct.
10. **`QUERY_QUEUE_FULL` returned when `maxQueued` exceeded** — correct behavior.

## Errors or gaps found

- None of substance. Minor nuances (non-blocking):
  - "A restart kills all in-flight queries" is the default `kubectl rollout restart` behavior on a single-coordinator deployment; Trino supports graceful coordinator shutdown via `SHUTDOWN` admin call, which the answer does not mention. Acceptable for a beginner-level answer; not an error.
  - The answer could have mentioned DB-backed resource group manager as a hot-reloadable alternative for teams that change tenant configs frequently (per posulliv.github.io/posts/dynamic-resource-groups and trinodb/trino#14514). Not required by the question but is a known follow-up.
  - The example sums for `softMemoryLimit` in the scale-up config (15% + 15% + 25% = 55%) are well under the parent's 80% — internally consistent, no issue.

## Resource fix recommendations

None required for this answer. The answer reflects the iter 17 / 18 / 19 / 31 / 61 / 62 / 67 / 72 cumulative fixes already landed in `resources/05-multi-tenant-analytics.md`:
- Correct property names ([hardConcurrencyLimit, softMemoryLimit, maxQueued, schedulingPolicy, schedulingWeight])
- JWT-principal-vs-Trino-role selector gotcha
- Separate `resource-groups.properties` file requirement
- Coordinator restart caveat for file-based manager
- `kill_query` as the immediate-relief lever before config rollout
- `system.runtime.queries.resource_group_id` for verification

Optional enrichment (not blocking): add a brief paragraph to `resources/05-multi-tenant-analytics.md` on DB-backed resource group manager as a hot-reload alternative for fast-changing tenant inventories (already partially covered per iter 72 notes — verify it's present).

---

## Verdict: **PASS**

Average 5.0 / 4.5 threshold. Answer is production-ready for the on-prem k8s + Trino 467 + JWT-auth + OPA stack described in `prod_info.md`. Every technical claim was verified against current trino.io documentation.

Sources verified:
- https://trino.io/docs/current/admin/resource-groups.html
- https://trino.io/docs/current/connector/system.html
- https://trino.io/docs/current/security/jwt.html
- https://github.com/trinodb/trino/issues/14514 (DB-backed reload interval)
