# Score: Iter 342 Q1 — Multi-tenant analytics (softMemoryLimit admission control vs kill_query vs query.max-memory)

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every claim verified against trino.io docs: (1) softMemoryLimit is admission control only — does not affect already-running queries (trino.io/docs/current/admin/resource-groups.html); (2) CALL system.runtime.kill_query(query_id => '...') is the documented procedure signature (trino.io/docs/current/connector/system.html); (3) query.max-memory in config.properties is the per-query hard ceiling that kills queries mid-flight when distributed memory across all workers exceeds the limit (trino.io/docs/current/admin/properties-resource-management.html); (4) query.max-memory-per-node correctly named as per-worker ceiling. query_id format `20260527_120530_00042_abcde` matches Trino's standard timestamp_sequence_random format. No errors. |
| **Beginner clarity** | 5 | Opens with explicit "No." — directly answers the binary question first. "Bouncer at the door, not a power cord" analogy is excellent and memorable for non-OLAP engineers. Comparison table makes the three knobs distinguishable at a glance ("Kills in-flight query?" column with NO/YES is the perfect framing). Concrete CALL example with realistic query_id. Numbered "immediate next steps" section eliminates ambiguity for an engineer in incident mode. Zero unexplained jargon. |
| **Practical applicability** | 5 | Engineer can act immediately: (1) exact SQL command with placeholder for query ID from UI, (2) instruction to run from admin session, (3) follow-up config change spelled out with file location (etc/config.properties), (4) three-layer defense recommendation gives a clear next sprint of work. Incident-first framing matches the question's urgency ("right now, while it's running"). Fits prod_info.md on-prem Trino 467 + ConfigMap deployment (config.properties is the standard Trino config file mounted in coordinator pod). |
| **Completeness** | 5 | Addresses both halves of the question: (1) what softMemoryLimit does and does NOT do (admission control, not termination), (2) what to do instead right now (kill_query). Bonus: explains why softMemoryLimit alone is insufficient as a forward-looking control and introduces query.max-memory + query.max-memory-per-node as the actual mid-flight circuit breakers. Closes the loop by sequencing the incident response and the post-incident hardening. |
| **Average** | **5.00** | **STRONG PASS** |

## What Worked
- Direct binary answer ("**No.**") in the first sentence — perfect for an incident-mode engineer who needs to make a decision in seconds.
- "Bouncer at the door, not a power cord" analogy crisply encodes the admission-control vs runtime-enforcement distinction.
- The comparison table with the **"Kills in-flight query?"** column is the single clearest articulation of the softMemoryLimit vs query.max-memory distinction across the entire training run. This was the gap flagged in iter341 Q2 notes ("softMemoryLimit as admission control vs query.max-memory as per-query killer gap remains") and it is now fully closed.
- CALL system.runtime.kill_query syntax matches the trino.io documented signature exactly, including the `query_id =>` named parameter form.
- Three-layer defense (softMemoryLimit + query.max-memory + query.max-memory-per-node) gives the engineer the architectural picture, not just the immediate fix.
- Sequenced action plan ("Right now" → "After the incident") matches incident response best practice.

## What Missed
- Minor: the `message =>` optional parameter on kill_query is not shown. Adding `, message => 'OOM runaway, killed by ops'` would aid auditability and is documented in trino.io system connector docs. Not a scoring deduction at this score level, but worth noting for future iterations.
- Could have mentioned that the killer needs the appropriate permission (in this prod environment, governed by OPA) — the question doesn't ask, but a one-liner ("you'll need admin-level OPA grants to execute kill_query against another user's query") would close one possible follow-up question. Not a deduction.
- No explicit mention that query.max-memory changes require coordinator restart (unlike resource group DB-backed hot-reload). Minor nuance.

## Technical Accuracy Verification
Verified against official Trino docs (WebSearch 2026-05-27):

1. **softMemoryLimit is admission control only** — CONFIRMED. trino.io/docs/current/admin/resource-groups.html: "softMemoryLimit ... specifies the maximum amount of distributed memory a group may use, before new queries become queued." Multiple sources confirm "resource groups only perform admission control" and "limits only applying to next queries, not already executing ones." Answer's framing is exactly correct.

2. **query.max-memory kills in-flight queries** — CONFIRMED. trino.io/docs/current/admin/properties-resource-management.html: "When the memory allocated by a query across all workers hits this limit it is killed." Answer correctly identifies this as the per-query circuit breaker.

3. **CALL system.runtime.kill_query exists and signature is correct** — CONFIRMED. trino.io/docs/current/connector/system.html documents: `CALL system.runtime.kill_query(query_id => '20151207_215727_00146_tx3nr', message => 'Using too many resources');`. Answer's syntax matches exactly (minus the optional `message` parameter, which is fine to omit).

4. **query_id format `20260527_120530_00042_abcde`** — CONFIRMED matches Trino's standard format: `YYYYMMDD_HHMMSS_<sequence>_<random>`. Engineer can find this in the Trino Web UI directly.

5. **Production-stack fit (prod_info.md)** — Trino 467 on-prem in Kubernetes with ConfigMap-mounted etc/config.properties is the standard deployment pattern. Answer's reference to `etc/config.properties` is correct for this stack. No invented OPA policies (kill_query authorization is handled by Trino + OPA, not invented in the answer — correct scope per prod_info.md).

**Sources:**
- [Resource groups — Trino docs](https://trino.io/docs/current/admin/resource-groups.html)
- [System connector — Trino docs](https://trino.io/docs/current/connector/system.html)
- [Resource management properties — Trino docs](https://trino.io/docs/current/admin/properties-resource-management.html)
- [Query management properties — Trino docs](https://trino.io/docs/current/admin/properties-query-management.html)
