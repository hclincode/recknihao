# Score: Iter 341 Q2 — Multi-tenant analytics (query_max_memory session property NOT a ceiling; resource group softMemoryLimit is the enforced cap)

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 4.5 | Core claim is correct and verified: `query_max_memory` is a session property that users can override via `SET SESSION` (capped only by cluster-wide `query.max-memory`). `softMemoryLimit` IS engine-enforced as an admission-control gate (verified at trino.io/docs/current/admin/resource-groups.html). `SetSystemSessionProperty` is the correct OPA action name (consistent with prior iter338/339/340 source verification of `OpaAccessControl.java`). One subtle imprecision: `softMemoryLimit` is described as a "cap" that "starts queuing or rejecting" — accurate, but the answer should note explicitly that it is *admission control* (does not kill or throttle queries already running). The "two-level" framing (resource group + cluster ceiling) is right; the "per-node" recommendation (`query.max-memory-per-node`) is also correct as defense-in-depth. |
| **Beginner clarity** | 4.5 | Three-knob comparison table is excellent for a beginner. Jargon ("admission controller", "principal") could trip a complete novice but each is contextualized. The "Why your customer's query wasn't killed" walkthrough names the exact failure mode in plain English. |
| **Practical applicability** | 5 | Engineer can act immediately: switch from session-property-manager default to `resource-groups.json` with `softMemoryLimit` for the free-tier group; optional OPA `SetSystemSessionProperty` deny rule if they want to keep using `query_max_memory`; `query.max-memory-per-node` as backstop. Concrete JSON snippet provided. File paths (`etc/resource-groups.json`, `etc/config.properties`) match production layout. |
| **Completeness** | 4.5 | Covers the why (override bypass), the right alternative (resource groups), the OPA backup option, and defense-in-depth. Minor gap: does not mention that resource group `softMemoryLimit` does NOT kill already-running queries either — it only blocks *new* queries from being scheduled. For a customer who already launched a runaway query, this matters: neither knob will kill the in-flight query unless it crosses `query.max-memory` (per-query hard ceiling). The answer steers toward `softMemoryLimit` without warning that the runaway query the engineer is asking about would also not have been killed by `softMemoryLimit` mid-flight — only future queries from the group would be queued. Per-query enforcement requires `query.max-memory` (cluster) or potentially `query.max-memory-per-node`. |
| **Average** | **4.625** | **STRONG PASS** |

## What Worked

- **Direct answer to the user's confusion in one sentence**: "`query_max_memory` is a default, not an enforced ceiling." This is the right mental model and fixes the misconception immediately.
- **Three-knob comparison table** with "Can SET SESSION bypass it?" column is exactly the right framing — it makes the security posture visible at a glance.
- **OPA `SetSystemSessionProperty` named correctly** (4th consecutive iteration — iter338 fix continues to hold).
- **Concrete resource-groups.json snippet** with `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued` — all valid Trino field names verified against trino.io docs.
- **Defense-in-depth framing**: resource group as primary, OPA deny rule as optional belt-and-suspenders, `query.max-memory-per-node` as cluster backstop. Realistic and idiomatic.
- **No bad SaaS-context fit issues**: stays in conceptual Trino territory, doesn't invent specific OPA policy or claim cloud-managed features the on-prem stack doesn't have.

## What Missed

- **The "killed mid-flight" question is dodged.** The user explicitly asked why the query "didn't get killed or throttled at all." The answer correctly explains the bypass mechanism but doesn't tell them that `softMemoryLimit` also won't kill an already-running query — it only queues *new* ones. The only Trino knob that will actually terminate a running query for exceeding memory is `query.max-memory` (per-query, cluster-wide). The answer mentions `query.max-memory` as "cluster-wide hard ceiling" but doesn't explicitly say "this is the one that would have killed your customer's query if it were set lower." That's the missing nuance.
- **`softMemoryLimit` semantics under-explained.** It's described as a "cap" — accurate but loose. The official docs are clear: "when a resource group runs out of a resource it does not cause running queries to fail; instead new queries become queued." Calling it an "admission controller" once is good; reiterating that semantics matters for runaway in-flight queries would be better.
- **Per-tier memory enforcement vs per-query enforcement not separated.** Resource group `softMemoryLimit` controls *aggregate* memory across all queries in the tier. The user may have wanted to limit *each individual free-tier query* to N GB — that requires the session-property + OPA-deny combination, not `softMemoryLimit` alone. The "If you need query_max_memory to act as a real ceiling" section addresses this but doesn't frame the choice explicitly: "Do you want to cap the tier in aggregate, or each query individually?"

## Technical Accuracy Verification

- **`query_max_memory` is a Trino session property overridable via SET SESSION**: CONFIRMED — trino.io docs (Memory management properties; SET SESSION). The override is capped by cluster-wide `query.max-memory`. The answer's claim "customers can override upward (up to the cluster ceiling)" is accurate.
- **`softMemoryLimit` engine-enforced, not bypassable via SET SESSION**: CONFIRMED — trino.io/docs/current/admin/resource-groups.html. It is an admission control mechanism evaluated by the coordinator at query submission time. SET SESSION cannot alter resource group assignment or memory limit.
- **`query.max-memory` is the cluster-wide hard ceiling in config.properties**: CONFIRMED — trino.io/docs/current/admin/properties-resource-management.html. "When the user memory allocation of a query across all workers hits this limit it is killed."
- **`SetSystemSessionProperty` OPA action name**: Could not re-verify from public docs (the OPA access-control docs page does not enumerate all operations), but rubric line 102 records prior judge verification against `OpaAccessControl.java` source, and the name has been confirmed across iter338, 339, 340. Treating as correct per consistent prior verification.
- **`query.max-memory-per-node`**: CONFIRMED as a valid Trino config property limiting per-query memory on each worker node. Answer's recommendation as defense-in-depth is sound.
- **Resource group JSON field names** (`softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued`, `name`): all CONFIRMED against trino.io docs (multiple prior rubric verifications + this iteration's search).

Sources:
- [SET SESSION — Trino 481 Documentation](https://trino.io/docs/current/sql/set-session.html)
- [Memory management properties — Trino Documentation](https://trino.io/docs/current/admin/properties-memory-management.html)
- [Resource groups — Trino 480 Documentation](https://trino.io/docs/current/admin/resource-groups.html)
- [Resource management properties — Trino 480 Documentation](https://trino.io/docs/current/admin/properties-resource-management.html)
- [Session property managers — Trino 481 Documentation](https://trino.io/docs/current/admin/session-property-managers.html)
- [Open Policy Agent access control — Trino 481 Documentation](https://trino.io/docs/current/security/opa-access-control.html)
