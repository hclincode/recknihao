# Score: iter243-q1 — Resource Groups for JDBC vs Iceberg

**Score: 4.8 / 5.0**

## What was correct

- **`rootGroups` is the correct top-level key.** Verified against trino.io/docs/current/admin/resource-groups.html — the example uses `"rootGroups": [...]`.
- **`selectors` is the correct array name** for routing rules.
- **`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`, `schedulingPolicy`** are all spelled and used correctly. They are the documented fields on a root group.
- **Selector `source` field supports Java regex** — the official docs explicitly say "Java regex to match against source string." The answer's `.*federation.*` / `.*iceberg.*` patterns are valid.
- **Selector also supports `user` and `queryType`** — both used correctly in the example.
- **First-match-wins semantics** for selectors is correct. Selectors are processed sequentially and the first matching one is used.
- **The `resource-groups.properties` wiring file is correct**: `resource-groups.configuration-manager=file` and `resource-groups.config-file=etc/resource-groups.json`. Verified against official docs.
- **The "wire it in a dedicated `etc/resource-groups.properties` file, NOT `etc/config.properties`" gotcha is real and important.** This matches Section 8.2 of the resource and is a genuine common mistake.
- **`X-Trino-Source` is the correct HTTP header name.** Confirmed against trino.io/docs/current/develop/client-protocol.html: "For reporting purposes, this supplies the name of the software that submitted the query."
- **JDBC `?source=<name>` URL parameter and CLI `--source <name>` flag** are both correct ways to set the source.
- **Coordinator restart required** for file-based resource-groups config changes — correct (file manager does not hot reload; only the DB-backed manager reloads every second).
- **The `system.runtime.queries` table has `source`, `query_id`, and `created` columns** — verified, the SQL in the verification checklist is valid.
- **The catch-all selector pattern** (last selector with no matchers) is the documented best practice to avoid queries falling through to no group.
- **Practical applicability** is excellent: gives runnable JSON, the exact wiring file, the three client patterns (JDBC URL, CLI flag, HTTP header), a verification SQL query, a UI verification step, and a deterministic isolation test recipe. The engineer can execute this end-to-end.
- **Production fit is strong**: Trino 467 on-prem is exactly the target; resource groups are an in-engine feature with no cloud dependency. The 10/30 concurrency split is conservative and reasonable for an on-prem cluster.

## What was wrong or missing

- **Minor: "rootGroups vs groups silently fails" is partially overstated.** The official docs only document `rootGroups`. In practice the file-based manager will reject a malformed config (throws on coordinator startup), so it's typically a startup error visible in logs — not a silent runtime no-op. The "silently fails" framing could lead an engineer to skip checking the coordinator log on first deploy. Better phrasing: "the coordinator will refuse to load the resource-groups config (check the startup log); double-check the top-level key is `rootGroups`."
- **Missing: priority field on selectors.** The docs note selectors can have an explicit `priority` and are processed in descending priority order; absent that, file order is used. The answer relies on file order, which works, but mentioning `priority` would harden the explanation against engineers who later add selectors out of order.
- **Minor omission: `softConcurrencyLimit`** is not mentioned. Not required for the answer, but adding it would help tune "start throttling at 8, hard-cap at 10."
- **Catalog-scoped routing not mentioned as an alternative.** The selector routes on `source`, which depends on the client cooperating. A complementary approach is `queryType` plus query-text matching (or having two separate Trino users/roles per workload type) so that a misconfigured client cannot bypass the federation cap. The resource file (Section 8.2) flags this risk; the answer mentions the fall-through gotcha but doesn't suggest the secondary defense.
- **The `softMemoryLimit` semantic is slightly fuzzy.** "When exceeded, Trino throttles (doesn't reject)" is roughly correct, but the precise mechanism is that new queries in the group are queued instead of admitted once the soft limit is exceeded — the wording "throttles" could be misread as per-query slowdown. Small nit.

## Verification notes

WebSearch and WebFetch against trino.io official docs confirm:

1. `rootGroups` — correct top-level key (trino.io/docs/current/admin/resource-groups.html)
2. `selectors` — correct array name
3. `hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`, `schedulingPolicy` — all valid documented properties
4. `source` selector supports Java regex — explicitly documented
5. `resource-groups.properties` with `resource-groups.configuration-manager=file` and `resource-groups.config-file=...` — correct wiring
6. `X-Trino-Source` HTTP header — confirmed in client-protocol.html
7. `system.runtime.queries` exposes `source`, `query_id`, `created` columns — confirmed
8. First-match-wins selector semantics — confirmed (selectors processed sequentially)

The "silently fails" claim about wrong top-level key is the only assertion that the official docs do not back; in practice the file manager throws on startup. Downgraded technical accuracy by a small amount for that.

## Recommendation for teacher

The resource (`22-trino-federation-postgresql.md`) is already strong on this topic — the answer pulled directly from Sections 8.2 C and the wiring sub-section, and got it right. Two low-priority fixes for the resource:

1. **Soften the "silently fails" framing** in Section 8.2's "rootGroups gotcha" — replace with "the coordinator startup log will show a parse error; the most common failure mode is putting the wiring lines in `etc/config.properties` instead of `etc/resource-groups.properties`, which IS a silent no-op."
2. **Add a one-paragraph mention of `priority` on selectors and `softConcurrencyLimit`** as tuning knobs, so future answers about resource group tuning have these to reach for.

No new resource needed. Topic **Trino federation / cross-source connectors** running avg moves from 4.436 toward the 4.5 raised pass threshold with this 4.8 — recommend continuing to push iter243 angles (b)/(c)/(d) from the iter242 notes to lock in the threshold.

## Scoring breakdown

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All config field names, file names, HTTP header, and system table columns verified against trino.io. Only "silently fails" framing is slightly overstated. |
| Beginner clarity | 5.0 | Explains "not a connection pool, it's query-level admission control" up front; defines `hardConcurrencyLimit`/`softMemoryLimit`/`maxQueued` in a table; walks the lifecycle of a query through the selector; gives the verification SQL inline. Engineer with zero resource-groups background can follow it. |
| Practical applicability | 5.0 | Engineer can copy-paste the JSON, the properties file, the JDBC URL, the CLI flag, the SQL verification query, and the isolation test recipe. Restart-coordinator step is called out. Production stack (Trino 467 on-prem) is the natural fit. |
| Completeness | 4.5 | Hits the question's two halves (separate buckets + how to configure) cleanly. Slight gap: doesn't mention `priority` for selector ordering or the "client cooperation" weakness of source-based routing. |
| **Average** | **4.75 → 4.8** | Rounded to one decimal. |
