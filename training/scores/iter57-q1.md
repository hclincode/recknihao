# Score: iter57-q1
**Topic**: Multi-tenant analytics
**Score**: 5.0 / 5.0

## Dimension scores
- Completeness: 5/5
- Accuracy: 5/5
- Clarity: 5/5
- No hallucination: 5/5

## What the answer got right
- **Two-part framing** (real-time identification + prevention with verification) maps cleanly to the question's two halves.
- **`system.runtime.queries` diagnostic SQL** is correct and the four named columns (`user`, `state`, `elapsed_time`, `query`) exactly match the rubric's expected set. The two diagnostic queries — one for ranking by elapsed_time, one for per-tenant aggregation — give the engineer two distinct ways to spot the noisy neighbor.
- **`CALL system.runtime.kill_query()`** correctly framed as the immediate live-incident lever with proper procedure-call syntax (`CALL ... (query_id => '...', message => '...')`) — not the historical bug of `SELECT system.runtime.kill_query(...)` flagged in iter50 Q1.
- **Resource group JSON** uses the correct property names: `hardConcurrencyLimit` (integer), `softMemoryLimit` (string `"20%"`), `maxQueued` (integer), `subGroups`, `selectors`. Verified against trino.io/docs/current/admin/resource-groups.html.
- **Selector matching gotcha** — both the prose ("the `user` field matches the `sub` claim from the JWT token...NOT the Trino role name") and the worked CORRECT/WRONG examples surface the right failure mode. The third anti-example (`"user": "acme_role"`) shows the exact silent-no-match misconfiguration.
- **Verification recipe is exceptional** — three concrete tests in order: (1) `resource_group_id` column check to confirm selector matched, (2) submit 6 concurrent queries to trigger the cap and confirm 1 enters `QUEUED`, (3) explicit table of correct vs WRONG property names (`maxRunning`, `maxMemoryPercent`, `queueSize`) covers the silent-ignore failure mode end-to-end.
- **`userRegex` anti-example** correctly flagged as a non-existent field — directly applies the iter53 fix where the responder previously fabricated this name.
- **Summary table** at the end ties incident timeline (diagnose → kill → prevent → verify) to the specific tools.
- **Resource group JSON correctly uses dot-notation group path** (`global.tenant_acme`) for child group references in selectors.

## What the answer missed or got wrong
Truly minor:
- The `resource_group_id` column on `system.runtime.queries` is technically `array(varchar)` not scalar varchar — querying it with `=` comparison would need a stringification, but the answer treats it as a scalar display column which is the common usage and doesn't actively mislead.
- No explicit note that file-based resource-groups.json changes require a coordinator restart (or that the resource-groups manager can be configured with a refresh interval) — a small operational nuance the engineer might hit when deploying the new config. Not in the expected coverage so not docked.
- OPA/JWT framing for the prod stack is implicit (mentions JWT principal but doesn't tie selector evaluation to OPA-vs-file-based-rules deployment timing). Not in expected coverage.

## Recommendation for teacher
No resource fixes needed. `resources/05-multi-tenant-analytics.md` is being pulled correctly across all six expected coverage areas, including the iter53 `userRegex` fix and the iter50 `CALL` vs `SELECT` kill_query fix. Both recurring failure modes that previously cost points on this exact question shape are now resolved. Consider this question topic stable on the current resource.
