# Iter 209 Q1 — OPA Mid-Query Deny / OPA Outage / JDBC Zombie Connections

**Topic:** Trino federation / cross-source connectors (auth interaction with in-flight federated queries; JDBC connection lifecycle on failure)

**Topic raised pass threshold:** ≥ 4.5

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Everything the answer asserts is correct (OPA at analysis time; Access Denied before storage touch; OSS Trino 467 no native PG pool; cancel propagation behavior). But it fails to assert the single most load-bearing fact for this question: Trino does NOT re-check OPA mid-execution. By staying silent, it leaves the engineer with the wrong mental model. |
| Beginner clarity | 4.0 | Clear structure, plain language, defines AST, analysis phase, kill_query. No unexplained jargon. |
| Practical applicability | 3.0 | The answer punts the actual on-call decision to "your platform team." For an on-call SaaS engineer at 2 AM, this is unsatisfying. The right answer would say: "for case (a) and (b) — your in-flight 2–3 minute query will keep running to completion; OPA is only consulted at analysis time." That single sentence resolves the entire scenario. |
| Completeness | 2.5 | Explicitly acknowledges the gap rather than answering (a) and (b). Does not address what happens to the JDBC connection on failure paths (the "zombie connection" sub-question). Does not address OPA bundle update semantics (next query only). Does not address what observability the engineer should add. |

**Weighted average (Tech×2):** (3.5×2 + 4.0 + 3.0 + 2.5) / 5 = (7.0 + 4.0 + 3.0 + 2.5) / 5 = 16.5 / 5 = **3.30**

**Unweighted average:** (3.5 + 4.0 + 3.0 + 2.5) / 4 = **3.25**

**Final score (unweighted, per rubric convention):** **3.25 / 5**

**Verdict:** **FAIL** (3.25 < 4.5 raised threshold for Trino federation)

---

## What was correct and verified

Cross-checked against trino.io/docs/current/security/opa-access-control.html and related issues:

1. **OPA evaluation at analysis (planning) time** — Verified. The Trino OPA plugin issues per-object authorization checks (`checkCanSelectFromColumns`, etc.) during the SystemAccessControl SPI calls fired in analysis. These are not repeated mid-task during distributed execution.
2. **Access Denied at coordinator before storage I/O** — Verified. The query never enters the distributed execution stage if any analysis-phase authorization check returns deny.
3. **kill_query() propagation** — Verified. Trino's coordinator does mark the query FAILED and sends abort signals to workers, and JDBC connector queries are now (since PR #7306 / #7819) cancelled on the remote PostgreSQL side via `Statement.cancel()` synchronously rather than in the background.
4. **OSS Trino 467 has no native PostgreSQL connection pool** — Verified. Pooling for the PostgreSQL connector is not exposed in OSS; only Oracle connector exposes `oracle.connection-pool.*` properties. This is the correct fact to remind the user of.

---

## What was missing or wrong

### CRITICAL omission #1: The actual answer to the user's question is left unsaid

The engineer asked: "Does Trino just keep running? Does it stop and throw an error? Do we get partial results?"

The correct answer that the resource must enable the responder to give:

> **For both scenarios (a) and (b), your in-flight 2–3 minute query will keep running to completion and return full results.** OPA is consulted by Trino only during the **analysis (planning) phase** at the coordinator, before any tasks are dispatched to workers. Once your query has passed analysis and is in the distributed execution phase (reading Iceberg splits, opening JDBC sessions to Postgres, shuffling join data), Trino does NOT re-call OPA. So:
>
> - (a) **OPA service goes down mid-execution** — your running query is unaffected. It will finish normally. The next *new* query to enter analysis will fail closed with an OPA HTTP error.
> - (b) **Policy change pushed mid-execution that would now deny the request** — your running query is unaffected. OPA bundle updates apply to the next query that enters analysis, not to queries already past it.

The current answer hedges where it should commit. That is the single biggest gap.

### CRITICAL omission #2: OPA fail-closed behavior for new queries

The user's case (a) implicitly asks "what about the next query?" too. The resource should say: when OPA HTTP requests fail (5xx, timeout, connection refused), the Trino OPA plugin returns an error to the coordinator and the new query fails with an authorization error — it does NOT fail open. The responder should be confident on this for on-call planning (e.g., OPA outage = all new queries die; in-flight queries finish).

### Important omission #3: JDBC "zombie connection" question is not answered

The user explicitly asked about the open Postgres connection. The answer mentions kill_query and socket timeouts but does not directly say:

- The JDBC connection is held inside the Trino worker's connector session for the lifetime of the query split (no app-level pooling on OSS 467).
- On normal completion: connection is returned (or closed, since no pool) cleanly.
- On query failure/cancel: since Trino 364+, the PostgreSQL connector sends a cancel to the remote PG server via `Statement.cancel()`, which kills the running PG backend and releases the connection. (See trinodb/trino PR #7306.)
- If the failure path is a TCP-level hang to Postgres (not OPA), the connection can hang until `connection-timeout` / TCP keepalives kill it — this is the only realistic "zombie connection" risk and it is unrelated to OPA.
- On Postgres side, `pg_stat_activity` is the right tool to spot orphans during/after an incident.

### Minor omission #4: OPA bundle update semantics

OPA bundles are pulled by OPA itself on its bundle poll interval. From Trino's perspective, each new query asks OPA fresh, so a new bundle takes effect on the next-evaluated query after OPA has finished applying the bundle. Worth one sentence so engineers can reason about deploy-vs-effect timing.

### Minor omission #5: Observability hooks

For an on-call answer, the responder should mention:
- Trino logger `io.trino.plugin.opa.OpaHttpClient` at DEBUG for OPA request tracing.
- Coordinator query-state metrics (FAILED with error type `PERMISSION_DENIED` vs `EXTERNAL`).
- `pg_stat_activity` on the Postgres side to confirm zombie connection theory.

---

## Specific resource fixes needed

Add a new section (or sharpen an existing one) in `resources/22` (or wherever the OPA / federation interaction is documented) titled approximately **"OPA authorization lifecycle and what happens during failures"** with these explicit, quotable statements:

1. **One-line summary box** the responder can lift verbatim:
   > "Trino consults OPA only during query analysis (planning) at the coordinator, NOT during distributed execution. An OPA outage or policy change that happens after a query has passed analysis does not affect the running query."

2. **Failure mode table:**

   | Scenario | New queries | In-flight queries |
   |---|---|---|
   | OPA service down | Fail closed: PERMISSION_DENIED / external error at analysis | Unaffected, run to completion |
   | OPA policy change pushed | Next query evaluated against new policy | Unaffected, run to completion |
   | OPA bundle refresh in progress | Brief window where old policy still applies | Unaffected |
   | Trino coordinator restart | New queries blocked until OPA reachable | Killed (coordinator restart kills queries regardless) |

3. **PostgreSQL JDBC lifecycle on cancel/fail** sub-section: state explicitly that OSS Trino 467 PostgreSQL connector calls `Statement.cancel()` on the remote PG server when a Trino task is cancelled (since PR #7306), so the PG backend is killed and the JDBC connection is released. Mention `pg_stat_activity` as the diagnostic tool.

4. **Operator observability:** logger names, query failure error codes, what to check on Postgres side.

5. **On-call decision tree:** "If your monitoring shows an OPA outage AND you have a slow federated query running: query will complete normally; let it finish; new queries will fail until OPA is restored."

---

## Pattern note for teacher

This is the third recent question in the Trino federation topic where the responder produced a polite "I can't fully answer this from the resources" reply instead of stating an actually-correct simple fact. The resource is treating OPA as a black box; it needs concrete, declarative statements about the OPA lifecycle (analysis-only, not execution-time) so the responder can give the engineer a direct yes/no answer.

Sources cross-checked:
- [Open Policy Agent access control — Trino docs](https://trino.io/docs/current/security/opa-access-control.html)
- [Trino OPA arrived (blog)](https://trino.io/blog/2024/02/06/opa-arrived.html)
- [trinodb/trino PR #17940 — initial OPA plugin](https://github.com/trinodb/trino/pull/17940)
- [trinodb/trino PR #7306 — Cancel PostgreSQL remote query on thread interruption](https://github.com/trinodb/trino/pull/7306)
- [trinodb/trino PR #7819 — Cancel query when JDBC connection or statement is closed](https://github.com/trinodb/trino/pull/7819)
- [PostgreSQL connector — Trino docs](https://trino.io/docs/current/connector/postgresql.html)
