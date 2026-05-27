# Feedback — Iter 212 Q2 (Extended phase)

Date: 2026-05-26
Topic: Trino federation / cross-source connectors (raised threshold ≥ 4.5)

## Question

When does the OPA decision log entry for a query get written — before or after workers start reading data? For a cross-catalog join (Iceberg + Postgres), do I get separate entries per table or one per query? How do I use the OPA log to determine if data was filtered by authorization vs. execution?

## Score

**5.0 / 5 — PASS** (Trino federation raised ≥ 4.5; PASS general ≥ 3.5)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All four technical claims verified against trino.io OPA docs and OPA decision-log docs. |
| Beginner clarity | 5 | Three-step structure with headings, decision table, plain-English interpretation rules. |
| Practical applicability | 5 | Engineer has exact field names to filter on (`input.context.queryId`), exact systems to consult (event listener, OPA decision log, `pg_stat_activity`), and an interpretation matrix. |
| Completeness | 5 | Answers all three sub-questions; covers row-filtering and batched-uri nuance; gives forensics matrix. |
| **Average** | **5.0** | |

## Verification (WebSearch against trino.io and openpolicyagent.org)

| Claim in answer | Verified? | Source |
|---|---|---|
| OPA decision log entry written at query analysis time, before workers start | YES | trino.io/docs/current/security/opa-access-control.html — access control invoked during analysis; coordinator authorizes before scheduling tasks to workers. Aligns with iter209 fix. |
| One SelectFromColumns call per base table in a multi-table query | YES | trino.io OPA docs — "Trino sends one request to OPA for each object" for non-batched ops. Cross-catalog Iceberg + Postgres join generates one SelectFromColumns per table. |
| Row-filter calls are separate per-table calls when `opa.policy.row-filters-uri` configured | YES | trino.io OPA docs — `opa.policy.row-filters-uri` is a separate endpoint that returns `[{"expression": "clause"}, ...]` per table. |
| Batched-uri collapses N filter-list calls into one for filter-list ops only (FilterCatalogs/Schemas/Tables/Columns/Views) | YES | trino.io OPA docs — VERIFIED in iter211 Q1; reinforced here. |
| `input.context.queryId` is the correlation field | YES | trino.io OPA docs — example shows `"queryId": "20250718_081710_03427_trino"` nested under `context`. PR #26851 added/formalized this. |
| OPA decision log survives Trino coordinator crash | YES | OPA decision logs are written by OPA itself (Styra/OpenPolicyAgent docs), independent of Trino's event listener — they persist even if the coordinator dies before emitting QueryCompletedEvent. |
| Row-filter expression behaves as additional WHERE clause | YES | trino.io OPA docs — "Each filter expression behaves like an additional WHERE clause." |
| pg_stat_activity reveals whether predicate was pushed to Postgres | YES | Standard Postgres monitoring; orthogonal to OPA but accurate. |

## What worked

### Direct hit on iter209/iter211 absorption angles

This answer directly tests two suggested angles from iter211's end-of-iteration feedback:

- **Angle (c)** — "OPA mid-query lifecycle re-test with different surface phrasing." The answer correctly states "OPA decision log entries are written at query analysis time, before workers start reading any data" as the very first sentence of section 1. This confirms the iter209 OPA-at-analysis-time fix is fully internalized and survives surface paraphrasing.
- **Angle (b/d) overlap** — batched-uri family awareness. The answer correctly distinguishes (i) per-object `SelectFromColumns` calls (always one per table, even when batched-uri configured, because batched-uri applies to filter-list ops only), (ii) per-table row-filter calls, (iii) batched filter-list ops as a separate category. This confirms the iter211 Q1 batched-uri framing absorbed.

### Three-way forensics workflow is genuinely useful

The Trino event listener → OPA decision log → `pg_stat_activity` cross-reference is exactly the workflow a SaaS support engineer needs when a customer reports "missing data." The decision table at the end maps each combination of OPA log state and Postgres log state to a definitive conclusion ("Authorization filtered the data" / "Policy worked, pushed to Postgres" / "Policy worked but predicate not pushed — Trino filtered locally" / "Authorization passed; data loss is elsewhere"). This is the actionable forensics output that has been missing from the resource set for 22 iterations (the recurring iter165→iter211 gap).

### Long-standing recurring gap addressed mid-answer

For 22 consecutive iterations (iter165-iter211), the rubric has flagged "OPA decision logs cross-referenced with Trino event listener for debugging denied filter operations" as a HIGH-priority recurring resource gap. This answer effectively delivers that content. The teacher should now extract the three-way forensics workflow into `resources/22-trino-federation-postgresql.md` §8.4 (or a dedicated forensics section) so it becomes part of the standing resource set rather than relying on the responder regenerating it each time.

### Cross-references the production stack accurately

Iceberg + Postgres + Trino + OPA is exactly the prod_info.md stack. The answer's mention of "iceberg.analytics.events" and "app_pg.public.tenants" matches the kind of catalog naming a production deployment would use. `pg_stat_activity` is the right Postgres monitoring source.

## Minor nits (not score-affecting)

1. **QueryCompletedEvent error code field path** — the answer says `errorCode.name = "PERMISSION_DENIED"`. The exact field path in the QueryCompletedEvent payload is closer to `failureInfo.errorCode.name`. The shorthand is understandable in context but slightly imprecise.
2. **OPA decision log enablement** — the answer doesn't explicitly note that OPA's decision log must be configured (via OPA's `decision_logs.console=true` or remote service endpoint) for any of this forensics workflow to actually have entries to consult. A one-line "to enable: set `decision_logs.console=true` in OPA config, or point `decision_logs.service` at a remote collector" would have closed this loop completely. Not score-affecting because the engineer's question presupposes the log already exists.
3. **opa.log-requests vs OPA decision log** — these are two different log surfaces (Trino-side request/response logging vs OPA-side decision logging). The answer treats "OPA decision log" as the canonical source, which is correct. Could optionally have noted the distinction.

## Topic status

Trino federation prior avg (after iter212 Q1 already added): 4.429 across 101 questions (total 447.375).

After Q2 (5.0): (447.375 + 5.0) / 102 = 452.375 / 102 = **4.435 across 102 questions**.

Gap to 4.5 threshold: **0.065** (was 0.074 after iter211; 0.071 after iter212 Q1). **Gap narrowed by 0.009 in iter212 Q2; combined iter212 net effect 0.009 narrowing.**

The topic still needs ~7-10 more answers averaging ≥4.7 to fully close the gap given the historical floor in the rolling average.

## Pattern flag — clean recovery iteration

Iter212 is a clean PASS-PASS iteration. Both Q1 (coordinator HA retest after the iter211 Q2 resource fix) and Q2 (OPA mid-query lifecycle + forensics retest) confirmed the teacher's resource updates landed correctly and the responder's mental model is internally consistent across surface paraphrasings.

This is the second consecutive iteration of clean recovery-pattern wins (iter211 Q1 OPA batched-uri after iter210; iter212 Q1+Q2 coordinator HA + OPA forensics after iter211).

## Resource fixes to apply before iter213

### HIGH (RECURRING — extract Q2's three-way forensics into resources)

The three-way forensics workflow generated in this Q2 answer (Trino event listener + OPA decision log + pg_stat_activity, joined by `input.context.queryId`) should be promoted from "responder regenerates each time" to a permanent section in `resources/22-trino-federation-postgresql.md` §8.4 (OPA decision logs) or §8.5 (forensics workflow). After 22 consecutive iterations of this gap being flagged, the teacher now has a concrete artifact (this Q2 answer) to lift into resources. Include:
- Decision table mapping (OPA state × Postgres state → conclusion).
- Field names: `input.context.queryId`, `errorCode.name`, `pg_stat_activity.query`.
- Sample log lines for each of the four interpretation cases.
- Note about enabling OPA's decision log (`decision_logs.console=true`).

### LOW (precision nits from Q2)

- Use `failureInfo.errorCode.name` (full path) in the event listener cross-reference example, not just `errorCode.name`.
- Add a sentence distinguishing `opa.log-requests` (Trino-side HTTP request/response logging) from OPA's `decision_logs` (OPA-side policy evaluation log) — they capture different surfaces.

### LOW (parallel family — still open from iter211)

- `opa.policy.batch-column-masking-uri` parallel-family coverage in the same `resources/22-trino-federation-postgresql.md` section. Tests whether the filterResources-in / shaped-array-out pattern generalizes to the column-masking sibling endpoint.

## Suggested iter213 angles (in priority order)

1. **Cross-three-source federation** — Iceberg + Postgres + a second JDBC source (MySQL or second Postgres). Plan complexity, broadcast vs partitioned join behavior when a third small dimension lives on a second JDBC catalog. Tests federation knowledge beyond two-source patterns.
2. **`opa.policy.batch-column-masking-uri` parallel family** — different surface phrasing for the iter211 Q1 batched-uri family. Question candidate: "We use column masking for PII. If I configure `opa.policy.column-masking-uri`, will OPA get one request per masked column or one per query?" Tests whether the responder generalizes the filterResources-in / shaped-array-out pattern.
3. **Iceberg time travel in cross-catalog context** — `FOR TIMESTAMP AS OF` on the Iceberg side while joining Postgres. What snapshot does the Postgres side see (current row state, no time-travel equivalent)? Engineer's debugging mental model.
4. **OPA decision-log retention / volume sizing** — practical operational question. How many OPA decision-log entries per query for a typical 3-table federated join with row filters? Storage sizing for a 30-day retention window. Tests the per-table multiplicity claim from this Q2 in a different surface form.

Aim for the next 1-2 federation answers to average ≥4.7 to close the 0.063 gap.

## Verification sources

- https://trino.io/docs/current/security/opa-access-control.html (OPA plugin operations list, batched-uri, row-filters-uri, queryId in context, per-object request behavior)
- https://github.com/trinodb/trino/pull/26851 (queryId added to OPA requests — confirms field availability)
- https://www.openpolicyagent.org/integrations/trino/ (Trino OPA integration overview)
- https://www.styra.com/blog/they-did-what-auditing-a-security-breach-using-enterprise-opa-decision-logs-and-aws-athena/ (OPA decision logs as forensic source independent of application)
- https://trino.io/docs/current/develop/event-listener.html (QueryCompletedEvent shape for cross-reference)
