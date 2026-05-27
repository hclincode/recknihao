# Score: Iter 343 Q2 — Multi-tenant: hardConcurrencyLimit queue vs reject behavior

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 4.5 | Core behavior correct: hardConcurrencyLimit queues, maxQueued caps queue, overflow rejects with QUERY_QUEUE_FULL. HTTP 200 with error in JSON body is correct per Trino client protocol. One minor error in the JSON example — the `selectors[].group` field uses literal dot notation (`"global.free_tier"`) per the official docs, not a regex-escaped dot (`"global\\.free_tier"`). The user/source fields are regex, but `group` is a plain reference to the configured group path. |
| **Beginner clarity** | 5.0 | Outstanding for a non-OLAP engineer. Frames the answer around the engineer's actual decision ("what UI message do I write?") and walks through both stages with concrete numbers ("3rd query queues, 8th query rejects"). The comparison table directly maps each stage to client behavior and HTTP/error semantics. No assumed OLAP jargon — "queue", "running", "reject" are used plainly. |
| **Practical applicability** | 5.0 | Exceptionally actionable. The engineer is handed: (1) a working resource-groups JSON snippet they can drop in, (2) the exact two code paths to branch on (`stats.state == "QUEUED"` vs `error.errorCode.name == "QUERY_QUEUE_FULL"`), (3) the precise UI copy for each case, and (4) a monitoring tip (`queued_time_ms` in `system.runtime.queries`) for tuning. The engineer knows exactly what to do next. |
| **Completeness** | 5.0 | Addresses every part of the three-part question: (a) do extras fail immediately — no, they queue; (b) do they eventually run — yes, when a slot frees up; (c) is there a point queries get rejected — yes, when `maxQueued` is exceeded, with the precise error code. Also covers the UI-copy decision that was the actual motivation for the question. Bonus content (system.runtime.queries monitoring) adds value without bloat. |
| **Average** | **4.875** | **STRONG PASS** |

## What Worked
- The two-stage framing ("Stage 1: Queued = waiting" vs "Stage 2: Queue full = failure") maps perfectly onto the engineer's UI-copy problem.
- Concrete numeric walkthrough (limit=2, maxQueued=5 → 8th query rejected) makes the boundary crystal clear.
- The comparison table tying HTTP status, error code, and client behavior together is exactly the reference an app engineer needs.
- The non-obvious "HTTP 200 even on query errors" note is correct and surprising — flagging it prevents real production bugs where engineers branch on HTTP status alone.
- Provides both branches the engineer needs in code (`stats.state == "QUEUED"` path vs `error.errorCode.name == "QUERY_QUEUE_FULL"` path).
- Recommends the right monitoring view (`queued_time_ms` in `system.runtime.queries`) for follow-up tuning.

## What Missed
- **Minor JSON syntax error in the selector**: shown as `"group": "global\\.free_tier"`, but the official Trino resource-groups docs show the `group` field uses literal dot notation (e.g., `"group": "global.data_definition"`). Only the `user` and `source` fields are Java regex. If the engineer copies this verbatim and the dot is interpreted literally, it will likely not match — could cost debugging time. Should be `"global.free_tier"`.
- No mention of how `softConcurrencyLimit` differs from `hardConcurrencyLimit` (when sub-groups compete, soft limits can be exceeded). Not strictly required for this question but related context the engineer may bump into next.
- No mention that selectors are evaluated top-down and the first match wins — relevant if the engineer later adds a paid-tier selector.
- Production-environment fit: the answer doesn't explicitly call out that JWT-authenticated users in this prod stack means the `user` regex must match whatever claim Trino maps to the session user. Minor — the answer is still actionable.

## Technical Accuracy Verification
Verified via WebSearch against the official Trino resource-groups documentation (trino.io/docs/current/admin/resource-groups.html) and client-protocol docs:

1. **hardConcurrencyLimit queues rather than rejects**: CONFIRMED. Trino docs: "Except for the limit on queued queries, when a resource group runs out of a resource it does not cause running queries to fail; instead new queries become queued."
2. **maxQueued caps queue depth, overflow rejects**: CONFIRMED. Trino docs: "maxQueued ... Once this limit is reached new queries are rejected."
3. **QUERY_QUEUE_FULL is the error code**: CONFIRMED as the correct/canonical error name for this condition in Trino's error taxonomy.
4. **HTTP 200 with error in JSON body**: CONFIRMED. Per Trino client protocol docs, the /v1/statement endpoint returns a QueryResults JSON document, and query failure is signaled inside that JSON (via the `error` field), not via a non-200 HTTP status. Non-200 codes (429, 502, 503, 504) have different protocol semantics (retry/transport).
5. **Resource-groups JSON syntax**: MOSTLY CORRECT. `rootGroups`, `subGroups`, `hardConcurrencyLimit`, `maxQueued`, `softMemoryLimit`, `selectors` all match the official docs. The one exception: `selectors[].group` should use literal dot notation (`"global.free_tier"`), not the regex-escaped form (`"global\\.free_tier"`) shown in the answer. The `user` field is correctly regex.
