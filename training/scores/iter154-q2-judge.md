# Judge Report — Iter 154 Q2

**Question**: Trino cluster with 20-30 concurrent dashboard queries slowing to a crawl; can certain queries (scheduled reports) be given lower priority than interactive dashboard queries, and how does it work under the hood?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter154-q2.md`

---

## Scores per dimension

### Technical accuracy: 5/5
Every load-bearing technical claim was verified against the official Trino 480 docs (trino.io/docs/current/admin/resource-groups.html). Specifically:

- **Two-file pattern (`resource-groups.properties` + `resource-groups.json`)** — confirmed correct. `resource-groups.configuration-manager=file` and `resource-groups.config-file=etc/resource-groups.json` are the documented properties.
- **Property names** (`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`, `schedulingWeight`, `schedulingPolicy`) — all are exact-match documented field names.
- **`schedulingPolicy: "weighted_fair"`** — confirmed valid. Docs list four values: `fair` (default), `weighted_fair`, `weighted`, `query_priority`.
- **`weighted_fair` semantics** — answer's explanation that scheduling weight controls relative admission across sibling sub-groups matches the official docs ("selects sub-groups based on their schedulingWeight and the number of queries they are already running concurrently").
- **`system.runtime.queries` with `resource_group_id` column** — confirmed; column type is `array(varchar)`, matching the answer's `ARRAY['global', 'dashboards']` example.
- **`CALL system.runtime.kill_query(query_id => '...', message => '...')`** — exact syntax match with Trino docs.
- **Database-backed resource group manager (`configuration-manager=db`)** — confirmed; docs explicitly say "reloaded from the database every second."
- **Restart requirement for file manager** — correct. Docs note the file manager is static; the db manager is the hot-reload path.
- **Gotcha about silent property-name typos** — correct and a well-known operational hazard.
- **"queued query consumes no resources" framing** — accurate; admission control is at the coordinator before any worker scheduling.

No incorrect or misleading technical claims found.

### Beginner clarity: 5/5
The answer opens by naming the mechanism (resource groups), then gives a plain-English root-cause explanation of why N concurrent queries fight each other. The terms `selector`, `sub-group`, `concurrency`, and `queue` are introduced in context with an explicit four-step lifecycle ("Query arrives → Selector matches → Group limits checked → Queries scheduled"). The 10:1 admission ratio for `schedulingWeight: 10` vs `1` makes the abstract weight number concrete. The "What Each Limit Does" table is a clean reference. No unexplained jargon assumed.

### Practical applicability: 5/5
Engineer can act on this immediately:
- Two complete config files with the exact production paths.
- `kubectl rollout restart deployment/trino-coordinator -n trino` matches the k8s on-prem stack from `prod_info.md`.
- Incident-response section with a runnable `kill_query` call.
- Monitoring SQL to verify selectors are matching.
- Explicit warning that the restart kills in-flight queries (operationally critical).
- Hot-reload alternative (db manager) named for when restart windows become painful.
- Selector regex (`.*dashboard.*`, `.*scheduled.*|.*export.*|.*batch.*`) is realistic for BI tool source strings.

### Completeness: 5/5
The question had three parts: (1) is there a way to prioritize, (2) how does it work under the hood, (3) implicit: how do I actually deploy this. All three answered. Bonus coverage: gotchas (silent property typos, inert weights without policy on parent, restart requirement), incident-response kill_query, observability via `system.runtime.queries`, and a forward pointer to db-backed hot-reload. Nothing material missing.

---

## Weighted average

(Tech × 2 + Clarity + Practical + Completeness) / 5 = (5×2 + 5 + 5 + 5) / 5 = **25/5 = 5.00**

## Verdict: PASS (≥ 4.5)

---

## What was verified correct (sources)

- [Trino 480 Resource groups](https://trino.io/docs/current/admin/resource-groups.html) — file manager two-file pattern, all property names, schedulingPolicy enum values, db manager hot-reload, selector source field.
- [Trino 480 System connector](https://trino.io/docs/current/connector/system.html) — `system.runtime.queries` with `resource_group_id` of type `array(varchar)`.
- [Trino kill_query procedure](https://trino.io/docs/current/admin/resource-groups.html) — `CALL system.runtime.kill_query(query_id => ..., message => ...)` syntax confirmed.

## Errors or gaps found

None of material consequence. Two extremely minor observations (not score-affecting):

1. The example `source` regex `.*dashboard.*` will match any client whose source string contains "dashboard". In practice the SaaS engineer will need to confirm what their BI tool actually puts in the X-Trino-Source header. The answer already flags this in the monitoring section ("check that the `source` regex matches what your BI tool actually reports"), so this is self-mitigated.

2. The answer says `schedulingPolicy: "weighted_fair"` on the **parent** group governs how sub-groups are picked. This is correct, but a stronger framing would clarify that `schedulingPolicy` applies to selection *of* child sub-groups, not within a flat group. The answer's wording is technically right and the gotcha section ("schedulingWeight is inert unless the parent has schedulingPolicy") gets the operational point across. Not a deduction.

## Resource fix recommendations

**LOW** — Resources already cover this material well enough that the responder produced a 5.0 answer. Optional reinforcement only:

- Consider adding the `query_priority` scheduling policy as an alternative to `weighted_fair` in the existing resource group resource — useful when the engineer wants per-query priority (set at submit time) rather than per-group weights.
- Consider adding a short note that the production stack's JWT-authenticated user identity can be used as a selector field (`"user": "..."`) in addition to `source`, since JWT auth is the prod auth mechanism per `prod_info.md`.

Neither is required; current resources are sufficient for this question class.

---

## Topic checklist update

- **Query performance regression diagnosis: oncall workflow for slow queries — concurrency, partition skew, data model, file layout**: prior avg 5.0 over 2 questions; new running avg with this 5.0 = **5.0 over 3 questions**. Already PASSED; this question reinforces from a third angle (concurrency contention specifically, asked from the priority/admission-control direction rather than the diagnosis direction).
