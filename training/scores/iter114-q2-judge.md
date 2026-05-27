# Iter 114 Q2 — Judge Report

**Question topic**: Cross-tenant internal aggregation with "no commingling" contract clauses; tenant-isolated weekly report; pre-aggregated rollup vs 80 separate queries.

**Primary topics touched**:
- Multi-tenant analytics: isolating customer data in SaaS (rollup pattern, view boundary, access control separation)
- Analytical query patterns (cross-tenant aggregation)
- Iceberg partition design (mention of partitioning by `(day(event_ts), tenant_id)`)

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All SQL and conceptual claims verified correct against Trino 467 / Iceberg 1.5.2 (see "Verified correct" below). |
| Beginner clarity | 4 | Plain framing of "commingling" up front, clear contrast of allowed-vs-disallowed query shapes, tables for principal/access mapping. One minor opacity: "OPA policy document" referenced without explaining what OPA is for a reader who hasn't seen the prior question. |
| Practical applicability | 5 | Engineer leaves with: (a) exact `WHERE account_type='production' AND status='active'` filter to fix the immediate problem, (b) a complete rollup DDL + idempotent MERGE INTO Spark job they can copy in, (c) a principal-to-resource access table they can hand to OPA, (d) explicit "what you don't need" guardrails against over-engineering. |
| Completeness | 5 | Three layered fixes (filter-at-source, rollup, per-tenant views) cover the full spectrum; the "what you don't need" closing block specifically addresses the engineer's "do we really need 80 queries?" sub-question. The "what counts as commingling" framing addresses the contractual interpretation directly. |
| **Average** | **4.75** | **PASS** |

---

## Verdict

**PASS.** This is a notably strong answer — one of the best on the multi-tenant rollup topic in the iteration history. It correctly reframes the engineer's anxiety (does "no commingling" mean 80 separate queries?) into the actual standard practice (pre-aggregated rollup with `GROUP BY tenant_id` is not commingling), and follows through with production-grade SQL that matches the prod stack exactly.

---

## What was verified correct (via WebSearch + resource cross-check)

1. **Trino MERGE INTO syntax with `WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT *`** — verified against Trino docs (https://trino.io/docs/current/sql/merge.html). The form used in the answer is exactly the documented syntax.
2. **`partitioning = ARRAY['event_date']` in Trino CREATE TABLE WITH clause** — verified against Trino Iceberg connector docs (https://trino.io/docs/current/connector/iceberg.html). Correct syntax.
3. **`SECURITY DEFINER` is Trino's default for views, allowing the tenant principal to read through a filtered view without holding base-table grants** — verified against Trino CREATE VIEW docs. The answer doesn't explicitly call this out, but its per-tenant view example (`CREATE VIEW tenant_acme.events AS SELECT ... WHERE tenant_id = 'acme'`) is consistent with the DEFINER pattern recommended in `resources/05`.
4. **`COUNT(*) GROUP BY tenant_id` does not commingle data per row** — this is the framing claim the answer leans on, and it matches how enterprise data-residency clauses are interpreted in practice (the result set is pre-aggregated per tenant; no raw cross-tenant join). Conceptually sound.
5. **Idempotent rollup via MERGE INTO matching on `(event_date, tenant_id, event_type)`** — exactly matches resource pattern B in `resources/05-multi-tenant-analytics.md` lines 1023-1057.
6. **The `WHERE tenant_id = 'acme'` view example with partition pruning down to one tenant's files** — matches the resource's Option B partition strategy (`('day(event_ts)', 'tenant_id')`).
7. **Access control table separating `acme-service-account` (view-only), `internal-data-team` (rollup-only), `admin-batch-job` (base table)** — matches the "two service accounts, one strict rule" pattern in `resources/05` lines 558-587, and correctly defers actual rule details to "your OPA policy document" per `prod_info.md` constraints.

---

## Errors or gaps found

### Minor

1. **"Account type" filter assumes a tenant registry table exists with `account_type` and `status` columns** — the answer says "Before anything else, add an `account_type` or `is_internal` column to your tenant registry" but doesn't explicitly call out that this may require a schema change to `iceberg.catalog.tenants`. A first-time reader could assume the column already exists. Low severity — the intent is clear from "add ... column."

2. **`current_user` and OPA carve-outs not mentioned for the internal-data-team principal** — the resource's rollup section (line 1116) explicitly notes "customer roles have no access to it." The answer's access table captures this but doesn't say how the internal team gets routed away from the row-filter (i.e., the OPA admin carve-out). For an engineer with no OPA background, this might be a follow-up question. The answer does point to "your OPA policy document" which is the correct deflection per `prod_info.md`.

3. **The view example uses `tenant_acme.events` schema-qualified name without flagging the `CREATE SCHEMA IF NOT EXISTS tenant_acme` prerequisite** that the resource explicitly calls out (line 313). Low severity in context — the answer is about the rollup, not full tenant onboarding — but a literal copy-paste of the view DDL would fail with `Schema 'tenant_acme' does not exist`.

4. **The Python f-string SQL injection style (`f"""...WHERE DATE(e.event_ts) = DATE '{batch_date}'..."""`)** — works fine for a controlled `batch_date` parameter, but it's worth noting that this pattern is risky if `batch_date` is ever user-supplied. The resource uses the same pattern, so this is consistent, but it's worth flagging in any future hardening pass.

### None of the gaps are blocking

The answer is fully actionable as-is and the gaps would only surface as second-order follow-up questions.

---

## Resource fix recommendations

Given this answer scored 4.75 (well above pass), and the multi-tenant topic already has 103 passing questions in the history, recommendations are LOW priority maintenance only:

### LOW — `resources/05-multi-tenant-analytics.md`

- **Add a one-sentence note in the rollup section** explaining that the OPA carve-out for internal-data-team principals (so the row-filter doesn't apply to them) is the mechanism that lets the rollup job and the data team query across tenants. Currently the resource says "internal principals are routed away" but doesn't draw the explicit line "this is done by an OPA admin carve-out." Insert near line 1116-1120 in the "Why this preserves per-tenant isolation" subsection.
- **Cross-link the rollup section back to the "Internal accounts / test tenants" framing.** The answer correctly identified that the engineer's pain has two layers: (a) excluding test/internal/churned accounts from the report, and (b) avoiding cross-tenant commingling for compliance. The resource handles (b) thoroughly but doesn't have an explicit "exclude internal accounts at source" sub-pattern with the `account_type = 'production'` filter shape. Adding a 5-line subsection between the rollup DDL and the WRONG-pattern callout (around line 970) would let future answers cite the resource directly for that filter.

### No HIGH or MEDIUM gaps identified.

---

## Notes on rubric / state

- Topic "Multi-tenant analytics: isolating customer data in SaaS" remains PASSED (avg 4.456, now 104 questions). Score of 4.75 here is above the running average and should nudge it slightly upward.
- No state changes needed; system is in `extended` phase, `passed: true`. This iteration's answer reinforces the pass.
