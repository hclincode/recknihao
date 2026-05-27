# Iter 76 Q1 — Judge Score

**Topic**: Multi-tenant analytics
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.00** |

## Points covered

All 7 rubric points covered:

1. **Resource groups explained clearly** — Yes. "Traffic lanes for Trino queries" analogy, named groups with limits on memory/concurrency/queue depth, queries wait instead of fail. Zero OLAP background required.
2. **`hardConcurrencyLimit` and `softMemoryLimit` are the key knobs** — Yes. Concrete JSON example with both properties plus `maxQueued`, sized for a realistic SaaS tenant mix (3 enterprise + 77 small).
3. **Selectors route queries to groups by user/principal** — Yes. Selectors block in the example uses `user` regex, including a wildcard for the small-tenant pool.
4. **File-based config requires coordinator restart vs DB-backed hot-reloads (~1s)** — Yes. Both behaviors stated explicitly with tradeoff (one extra Postgres dependency).
5. **DB-backed config (`resource-groups.configuration-manager=db`)** — Yes. Exact `config.properties` snippet with all four required properties (manager, url, user, password) and the SQL-vs-JSON management implication called out.
6. **JWT principal matching (selector matches `sub`, not role name)** — Yes. Dedicated "Critical gotcha" section. Shows wrong vs right config side-by-side, explains "silently lands in default group" failure mode — directly applies the iter18/19 resource fix.
7. **Actionable advice for immediate relief (kill_query) and long-term fix** — Yes. `system.runtime.kill_query` CALL with both `query_id` and `message` parameters; companion `system.runtime.queries` lookup query. "No separate cluster needed" closing reinforces the long-term fix.

## Issues found

Minor nits only (none score-affecting):

- The `elapsed_time` column in `system.runtime.queries` is present in current Trino versions but historically the table exposed timestamp columns (`created`, `started`, `end`); some older docs derive elapsed from differences. In Trino 467 (production stack) `elapsed_time` is queryable, so this is fine.
- Strictly, JWT-authenticated selectors can also use the `authenticatedUser` field for stronger matching against the JWT principal regardless of session user override. The `user` field works correctly when no session user override happens (the SaaS dashboard flow), so the answer's recommendation is accurate for this production setup. A future resource enhancement could mention `authenticatedUser` as a defense-in-depth option, but this is not required for a passing answer.
- The `softMemoryLimit` at the root `global` group is set to 80% while the two subgroups sum to 50% — this leaves headroom, which is intentional, but a beginner might benefit from a one-line note that subgroup limits can be over-subscribed relative to parent. Not a correctness issue.

## Accuracy verification

WebSearch verification against official Trino docs (trino.io):

- **`resource-groups.configuration-manager=db`** — Verified as the correct config property for DB-backed resource groups. (trino.io/docs/current/admin/resource-groups.html)
- **Hot-reload interval ~1 second** — Verified. Trino docs state DB-backed config "is reloaded from the database every second, and the changes are reflected automatically for incoming queries." Answer's "~1 second" is exactly right.
- **`hardConcurrencyLimit` and `softMemoryLimit`** — Verified as valid resource group properties; `hardConcurrencyLimit` is required, `softMemoryLimit` accepts absolute (1GB) or percentage (10%) form. Answer uses percentage form correctly.
- **File-based config requires coordinator restart** — Verified. Trino docs and community discussions confirm file-based JSON requires coordinator restart; DB-backed is the dynamic alternative. Answer correctly distinguishes the two.
- **`system.runtime.kill_query` syntax** — Verified. The procedure accepts `query_id` (required) and `message` (optional) named parameters. Answer's CALL syntax is exactly correct.
- **JWT principal = `sub` claim** — Verified. Trino JWT auth uses `http-server.authentication.jwt.principal-field` with default value `sub`. Selector `user` field matches the resulting Trino principal name.

## Resource fix needed?

**No.** The answer is at ceiling quality across all four dimensions, and the iter18/19 JWT principal fix is being applied correctly (third consecutive answer to call this out without prompting). The iter21+ note that `softMemoryLimit`/`hardConcurrencyLimit` are the canonical field names is also reflected here.

Optional future enhancement (not blocking): `resources/05-multi-tenant-analytics.md` could mention the `authenticatedUser` selector field as a stronger alternative to `user` when defending against session-user override, but this is a nice-to-have and not needed for passing.

## Updated topic average

Prior: 4.406 across 73 questions (sum 321.638)
This answer: 5.00
New running avg: (321.638 + 5.00) / 74 = **4.414 across 74 questions**

Status: **PASSED** (above 3.5 threshold; lifts the weakest topic toward 4.5).

## Sources

- [Resource groups — Trino 480 Documentation](https://trino.io/docs/current/admin/resource-groups.html)
- [System connector — Trino 480 Documentation](https://trino.io/docs/current/connector/system.html)
- [JWT authentication — Trino 481 Documentation](https://trino.io/docs/current/security/jwt.html)
- [Updating resource groups without restarting Trino](https://posulliv.github.io/posts/dynamic-resource-groups/)
