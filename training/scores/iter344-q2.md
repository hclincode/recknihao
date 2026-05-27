# Score: Iter 344 Q2 — Multi-tenant analytics (Trino resource group selector matching)

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every claim verified against trino.io docs. (1) First-match-wins top-to-bottom in JSON array — confirmed. (2) `user` and `source` are Java regex — confirmed (java.util.regex). (3) `group` field is literal string, not regex — confirmed. (4) All fields within one selector are AND-combined — confirmed. (5) `system.runtime.queries` exposes `query_id`, `user`, `resource_group_id` (array(varchar)) — confirmed (added in release 0.206). The if-elif-else mental model is accurate. The catch-all-above-specific failure mode is the canonical root cause for this symptom. No factual errors detected. |
| Beginner clarity | 5.0 | Opens with a one-line bottom-line answer ("strictly first-match-wins"). The if-elif-else pseudocode is the perfect analogy for an engineer with no OLAP background — they already understand control flow. JSON examples show wrong-order vs correct-order side by side. No unexplained jargon. The phrase "dead code" lands naturally for an engineer. Each operational rule is one sentence. |
| Practical applicability | 5.0 | Engineer knows exactly what to do next: (1) check JSON order, (2) run the provided `system.runtime.queries` SQL, (3) compare the actual `user` column to the regex. The SQL is copy-pasteable. The two intermittent-failure causes (regex mismatch vs source AND-combination) directly map to the "not always, just occasionally" symptom the engineer described — which is the exact signature of an AND-combined source field failing for some submission paths but not others. |
| Completeness | 5.0 | Addresses both halves of the question: (a) "first match or scored?" — answered definitively as first-match. (b) Diagnoses the actual symptom (intermittent catch-all landing) with two distinct root causes that explain intermittency. Includes the five operational rules, debugging SQL, and a 3-step debugging checklist. Nothing material missing. |
| **Average** | **5.00** | **STRONG PASS (PERFECT)** |

## What Worked
- **Direct answer first, then diagnosis.** Bottom-line "strictly first-match-wins" in sentence 1; no hedging.
- **Intermittency root-cause is on-point.** The engineer said "not always, just occasionally" — the answer correctly identifies the AND-combination on `source` as the prime suspect for intermittent (vs total) failures, since some submission paths set source differently. This is the kind of insight that requires actually understanding the symptom, not just reciting docs.
- **Wrong vs correct JSON side-by-side.** Engineer can pattern-match against their own file in seconds.
- **Literal-vs-regex callout on `group`.** Operational rule #5 explicitly says `group` in selectors is literal — directly addresses the iter343 resource fix and reinforces the corrected mental model.
- **EXPLAIN-style debugging via `system.runtime.queries`.** Gives the engineer a verification path, not just a theory. The SQL projects exactly the three columns needed (`query_id`, `user`, `resource_group_id`).
- **AND-combination of multiple fields** is explicitly called out as rule #3 and demonstrated with the `user` + `source` example.
- **Fits the production environment.** Mentions JWT principal (matches prod_info.md custom JWT authenticator) as the source of the `user` value. Does not invent OPA policies or stray into the external governance document territory.

## What Missed
Nothing material. Optional refinements (would not raise the score, just noted for resources):
- Could mention that the database-backed resource group config evaluates by priority field (descending), not by row order — but the question specifies JSON file usage implicitly, and adding this would dilute the focused answer.
- Could mention `userGroup`, `originalUser`, `authenticatedUser` as additional selector fields available in newer Trino versions (467 is the prod version, all three are available) — but the engineer is using `user`, so this would be tangential.

## Technical Accuracy Verification
- **First-match-wins (JSON, top-to-bottom)**: Confirmed via trino.io/docs/current/admin/resource-groups.html — "Selectors are processed sequentially and the first one that matches will be used."
- **`user` and `source` are Java regex**: Confirmed — "Java regex to match against username" / "Java regex to match against source string" (java.util.regex package).
- **`group` field is literal string**: Confirmed — `group` and `queryType` are literal string matching; `user`, `source`, `userGroup` are regex.
- **Multiple fields AND-combined within one selector**: Confirmed — "all rules within a single selector are combined using a logical AND."
- **`system.runtime.queries.resource_group_id`**: Confirmed — added in release 0.206 as `array(varchar)` type; `user` column also present. Sample query `SELECT query_id, resource_group_id, state, user FROM system.runtime.queries` is canonical.
- **Production fit (Trino 467, JWT auth)**: All selector fields and `system.runtime.queries` schema are present in Trino 467. JWT principal as source of the `user` selector value is consistent with the custom JWT authenticator described in prod_info.md.

Sources verified:
- https://trino.io/docs/current/admin/resource-groups.html
- https://trino.io/docs/current/release/release-0.206.html
- https://github.com/trinodb/trino/pull/24662 (originalUser/authenticatedUser additions)
