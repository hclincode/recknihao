# Judge Feedback — Iter 477 (extended phase, end-of-iteration)

## Overall verdict

**4.75 STRONG PASS** (avg of 4 questions). 76th consecutive overall PASS in extended phase. +0.73 above iter476's 4.0156 thin pass; matches/exceeds iter475's 4.6953. CITATION-HYGIENE STREAK FULLY RESTORED — zero load-bearing fabrications across all four answers.

## Re-probe statuses (both CONFIRMED FIXED)

- **Q1 truncate-fix — CONFIRMED HELD.** Responder used lowercase `truncate(amount * 100) / 100`, explicitly stated 1-arg only, gave general form `truncate(amount * power(10, d)) / power(10, d)`, flagged uppercase `TRUNC` as Oracle (not Trino), flagged 2-arg `truncate(x, 2)` as fabricated, distinguished truncate-toward-zero vs round-HALF_UP semantics for billing. r27 §4.4 numeric-table row + §4.4C TRUNC-truncate guardrail + §4.4B consolidated DO-NOT-WRITE entries (iter476 EDITS A+B+C) all FOUND AND APPLIED.
- **Q2 star-shorthand-fix — CONFIRMED HELD.** Responder gave full 3-branch MERGE with EXPLICIT column lists in both UPDATE SET (`customer_id=s.customer_id, amount=s.amount, status=s.status, updated_at=s.updated_at`) AND INSERT (`INSERT (id, customer_id, amount, status, updated_at) VALUES (s.id, ...)`); DELETE-first ordering for first-match-wins; explicit call-out that `UPDATE SET *` / `INSERT *` is Spark/Snowflake/Databricks-only and NOT Trino. r27 §4.6B MERGE star-shorthand guardrail + §4.4B consolidated DO-NOT-WRITE entries (iter476 EDITS C+D) + r13 line-5214 + line-5239 reconciliations (EDITS E+F) all flowed through to the answer.

## Per-question breakdown

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Oracle TRUNC(amount,2) → Trino (re-probe) | 4.75 | 4.75 | 4.75 | 4.75 | **4.75** | STRONG PASS |
| Q2 | Trino MERGE upsert+conditional-DELETE (re-probe) | 5.0 | 4.75 | 4.75 | 5.0 | **4.875** | STRONG PASS |
| Q3 | OPA row-level filtering | 4.75 | 4.5 | 4.5 | 4.75 | **4.625** | STRONG PASS |
| Q4 | Iceberg snapshot rollback | 4.5 | 4.75 | 4.75 | 5.0 | **4.75** | STRONG PASS |

**Overall: (4.75 + 4.875 + 4.625 + 4.75) / 4 = 4.75 STRONG PASS.**

### Q1 — Oracle `TRUNC(amount, 2)` decimal truncation → Trino (re-probe)
- Accuracy 4.75: core claims (`truncate` 1-arg only, lowercase, no `TRUNC`, no 2-arg `truncate(x, 2)`) all docs-anchored at trino.io/docs/current/functions/math.html. Minor: responder attributed `Function 'trunc' not registered` error wording to a 2-arg `truncate(x, 2)` call — that exact error text is what uppercase `TRUNC` produces; a 2-arg lowercase `truncate(...)` would fail with wrong-arity / function-resolution, not the not-registered text. Conceptual claim correct; error-message attribution slightly imprecise.
- Completeness 4.75: general form + worked example + 2-arg ban + Oracle-side `TRUNC` ban + truncate-vs-round HALF_UP billing distinction.
- Clarity 4.75: jargon-free, billing example concrete.
- Actionability 4.75: copy-pasteable; HALF_UP vs toward-zero call-out gives the criterion for engineer choice.

### Q2 — Trino MERGE upsert + conditional DELETE full pattern (re-probe)
- Accuracy 5.0: every claim docs-anchored at trino.io/docs/current/sql/merge.html. DELETE-first ordering correctly grounded in the docs quote `For each source row, the WHEN clauses are processed in order. Only the first matching WHEN clause is executed.`
- Completeness 4.75: 3-branch CDC pattern (DELETE/UPDATE/INSERT) + DELETE-first ordering + star-shorthand ban call-out + explicit column lists in both branches.
- Clarity 4.75: op-code CDC framing (`'d'` / `'u'` / `'c'` / `'r'`) makes the structure concrete.
- Actionability 5.0: full copy-paste runnable MERGE.

### Q3 — OPA row-level filtering in Trino
- Accuracy 4.75: model matches docs at trino.io/docs/current/security/opa-access-control.html. Minor: responder did not name the specific `opa.policy.row-filters-uri` / `opa.policy.column-masking-uri` config keys, but the conceptual model (Trino sends user/action/table/columns JSON over HTTP per query; OPA returns row filters + column masks; Trino applies the WHERE at query time) is right. No fabricated `SET ROW FILTER` DDL or fabricated OPA endpoint paths.
- Completeness 4.5: good coverage; specific Rego correctly deferred to external governance doc per prod_info.md. Could be stronger by naming the row-filters-uri / column-masking-uri config keys.
- Clarity 4.5: Rego/OPA jargon used but defined inline; SECURITY DEFINER fallback gives a concrete escape hatch.
- Actionability 4.75: engineer knows the production flow + fallback path (per-tenant view + REVOKE/GRANT).

### Q4 — Iceberg snapshot rollback for bad load
- Accuracy 4.5: `$snapshots` columns (snapshot_id, committed_at, operation, summary) match trino.io/docs/current/connector/iceberg.html; double-quoting `"events$snapshots"` correct; `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <id>)` positional 3-arg form is the legacy 467-era syntax; `ALTER TABLE ... EXECUTE rollback_to_snapshot(<id>)` table-procedure form was introduced in Release 469 (Jan 2025) per PR #24580 trinodb/trino — responder correctly version-gated this to post-467; 7-day retention caveat correct. Minor: responder showed the 469+ EXECUTE form as `EXECUTE rollback_to_snapshot(snapshot_id => <id>)` with named-arg syntax — the Trino doc example for the 469+ EXECUTE form shows positional `EXECUTE rollback_to_snapshot(<id>)`. Whether the named-arg form is also accepted is plausible but not explicitly demonstrated in the connector-doc example — treat as unverified-but-plausible, not a hard fab.
- Completeness 4.75: lookup query + rollback call + atomic / metadata-only claim + 7d retention warning.
- Clarity 4.75: DESC ORDER + LIMIT 10 + numeric example all jargon-free.
- Actionability 5.0: full copy-pasteable lookup + rollback + retention warning.

## Fabrications

None substantive. Two minor non-load-bearing imprecisions (engineer copy-pasting any answer still gets working SQL):

1. **Q1 error-message attribution slip**: Responder said the 2-arg `truncate(x, 2)` form fails with `Function 'trunc' not registered`. That exact error text is what uppercase `TRUNC` produces. A 2-arg lowercase `truncate(...)` would fail with a wrong-arity / function-resolution error. Both fail, so the conceptual claim is correct; the error-message attribution is slightly imprecise. Source: trino.io/docs/current/functions/math.html (1-arg only).
2. **Q4 `snapshot_id =>` named-arg over-spec**: Responder showed the 469+ EXECUTE form as `EXECUTE rollback_to_snapshot(snapshot_id => <id>)` with named-arg syntax — the Trino doc example shows positional `EXECUTE rollback_to_snapshot(<id>)`. The named-arg form is plausible (Trino EXECUTE generally supports both positional and named for procedure parameters) but not explicitly demonstrated. Unverified-but-plausible, not a hard fab. Source: trino.io/docs/current/connector/iceberg.html.

## Topic-row impact

| Topic | Before | After | Delta |
|---|---|---|---|
| Oracle PL/SQL → dbt/Trino migration | 4.5116/51 | **4.5230/53** | +0.0114 (Q1 4.75 + Q2 4.875, both above topic avg; recovers iter476's -0.0464 drag, ground back above iter474's 4.5539 baseline) |
| Multi-tenant analytics | 4.4582/153 | **4.4593/154** | +0.0011 (Q3 4.625 above topic avg) |
| Iceberg table maintenance | 4.4917/134 | **4.4936/135** | +0.0019 (Q4 4.75 above topic avg) |
| Trino federation | 4.49944/310 | **4.49944/310** | unchanged (NOT probed per directive) |

## Teacher actions for iter478

### PRIMARY — breadth design with NO dedicated federation probe

Federation row (4.49944/310) sits 0.0006 below the raised 4.5 threshold; held per iter472-477 judge directive. Let the count grow naturally with non-federation breadth probes. **DO NOT design a dedicated federation question for iter478.**

### Possible breadth angles for iter478 (pick 4, one each — keep diversity)

1. **3rd-angle re-probe on dbt-snapshots-SCD2 micro-topic** (still locked at only 2 datapoints at 4.5625/2). Angles not yet probed:
   - Hard-deletes config (`invalidate_hard_deletes: true` for timestamp strategy)
   - `target_schema` / `target_database` overrides
   - `snapshot_meta_column_names` config (renaming `dbt_valid_from` etc. to custom names)
   - dbt 1.9+ `dbt_is_deleted` metadata column semantics

2. **Oracle-migration cross-dialect-spillover 4th-angle probe from a phrasing the responder hasn't seen yet.** The iter476 fabs (`TRUNC` + `UPDATE SET *`) closed via 6 r27/r13 edits, and iter477 re-probes both held; harden the win by probing cousin patterns the DO-NOT-WRITE matrix in r27 §4.4B doesn't yet cover:
   - Oracle `LISTAGG(col, ',') WITHIN GROUP (ORDER BY ...)` → Trino `array_join(array_agg(col ORDER BY ...), ',')` (DO-NOT-WRITE LISTAGG as Trino function name)
   - Oracle `NVL2(expr, val_if_not_null, val_if_null)` → Trino `CASE WHEN expr IS NOT NULL THEN ... ELSE ... END`
   - Oracle `REGEXP_LIKE(str, pattern)` → Trino `regexp_like(str, pattern)` (case-sensitivity check)
   - Oracle `SUBSTR(str, start, len)` → Trino `substr(str, start, len)` (verify Trino 1-based start index matches Oracle)

3. **OPA row-filter/column-mask 2nd-angle re-probe**:
   - "How does Trino call OPA per query and how often does the OPA decision get cached / batched?" probes the batch endpoint (`opa.policy.batch-column-masking-uri`) and cache TTL semantics
   - "Show me an OPA decision response shape that returns BOTH a row filter AND a column mask in the same query" probes the response-format JSON shape

4. **Iceberg-rollback adjacent angle**:
   - `iceberg.system.set_current_snapshot(table, snapshot_id)` vs `rollback_to_snapshot` — distinct procedure for branch-aware reset
   - Tag-based rollback: rollback to a TAG name vs a numeric snapshot_id, using `FOR VERSION AS OF '<tag>'` read pattern as the audit step
   - `expire_snapshots` retention threshold interaction: how to GUARANTEE a snapshot can still be rolled back to over a 30-day window despite the production default 7d expire

### SECONDARY — citation hygiene around the two iter477 minor imprecisions

These two are non-load-bearing (engineer gets working SQL either way) but worth surfacing in r27 + r17 with a one-line clarifier each:

- **r27 §4.4C TRUNC-truncate guardrail**: add a one-line "expected error message" note distinguishing (a) `TRUNC(x, 2)` → `Function 'trunc' not registered` from (b) `truncate(x, 2)` 2-arg lowercase → wrong-arity / function-resolution error. Pre-empts the iter477 Q1 minor slip from recurring.
- **r17 (or wherever the rollback section lives) Iceberg rollback 469+ EXECUTE form**: clarify that the documented form is positional `EXECUTE rollback_to_snapshot(<id>)`; if the named-arg `snapshot_id => <id>` form is also accepted (which Trino EXECUTE generally supports for procedure parameters), note that the positional form is the doc-canonical one to prefer in production examples.

### Federation hygiene held

Do NOT touch §13.x federation guardrails in resources/22 or any federation-adjacent content (TopN pushdown, predicate pushdown, JOIN pushdown). Federation row near-miss is being walked toward 4.5 via natural count growth from non-federation iterations; injecting fresh content risks an unforced regression.
