# Iter 209 Q2 — Cross-Catalog View Permissions in OPA: SECURITY DEFINER vs INVOKER, Backdoor Risk

**Topic:** Trino federation / cross-source connectors (cross-catalog views over Iceberg + Postgres; OPA row-level security through views; SECURITY DEFINER vs INVOKER semantics)

**Topic raised pass threshold:** ≥ 4.5

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core claims verified against trino.io: DEFINER is Trino's default; DEFINER causes base-table access to be evaluated against the view owner's identity, not the caller's; INVOKER causes evaluation against the caller. The answer correctly identifies the real "backdoor" mechanism — row-filter policies that target the caller will be bypassed when OPA checks base tables under the view owner's identity. Small imprecision: the answer doesn't cleanly separate the two distinct authorization checks Trino performs (view-level check against caller + base-table checks against owner under DEFINER), but no outright factual errors. |
| Beginner clarity | 4.5 | DEFINER vs INVOKER explained in plain language with a concrete SQL example. The "what actually happens" summary table at the end is an excellent orientation artifact. Jargon ("expansion," "analysis phase," "principal") is used but the surrounding sentences carry the meaning. |
| Practical applicability | 5.0 | Engineer asked "could the view become a backdoor?" — they get a direct yes/no with conditions: NO if you use DEFINER + explicit OPA deny on base tables + explicit column list. Concrete CREATE VIEW SQL is provided. Belt-and-suspenders pattern (view mode + OPA deny) reflects production-grade thinking. The CI test recipe ("as each tenant principal, `SELECT DISTINCT tenant_id FROM <view>` must return exactly one value") is exactly the kind of automated verification an on-call SaaS team should adopt. Fits prod_info.md (JWT + OPA + Trino 467 + Iceberg + Postgres) without drift. |
| Completeness | 4.5 | Covers: (a) view expansion and per-table OPA checks; (b) both DEFINER and INVOKER modes; (c) the row-filter bypass risk that motivates the engineer's question; (d) explicit-column-list trap; (e) operational verification. Missing: a note that OPA can also attach row-filter policies to view objects themselves (so you can keep DEFINER and still get per-caller row filtering by writing a filter against the view name); and a slightly clearer separation of the view-level check vs base-table checks. |

**Average: (4.5 + 4.5 + 5.0 + 4.5) / 4 = 18.5 / 4 = 4.625**

**Verdict:** **PASS** (4.625 ≥ 4.5 raised threshold for Trino federation topic; also PASS general threshold)

---

## What was correct and verified

Cross-checked against trino.io/docs/current/sql/create-view.html, trino.io/docs/current/security/opa-access-control.html, and trinodb/trino discussion #14790:

1. **DEFINER is the default SECURITY mode for CREATE VIEW** — VERIFIED. Trino docs: "tables referenced in the view are accessed using the permissions of the view owner (the creator or definer of the view) rather than the user executing the query." The answer correctly states "SECURITY DEFINER (Trino's default)."

2. **DEFINER causes base-table access checks to use the view owner's identity** — VERIFIED. The access controls of the underlying tables are still evaluated, but against the view creator's identity.

3. **INVOKER causes base-table access checks to use the calling user's identity** — VERIFIED. "tables referenced in the view are accessed using the permissions of the user executing the query."

4. **View expansion happens during analysis** — VERIFIED. Trino resolves view SQL to the underlying tables during query analysis, and the SystemAccessControl SPI (OPA plugin) is invoked for each resolved resource.

5. **Each table referenced generates its own OPA check** — VERIFIED. The OPA plugin issues per-resource authorization calls (`checkCanSelectFromColumns` etc.) for each table in the view's expanded SQL.

6. **Row-filter policies targeting the caller are effectively bypassed for base tables under DEFINER** — VERIFIED. Because OPA evaluates base-table access against the view owner's identity, any per-caller row-filter rule keyed on the tenant's principal won't fire on the base-table reads. This is the precise "backdoor" mechanism the engineer was worried about, and the answer captures it correctly.

7. **Caller only needs SELECT on the view itself under DEFINER** — VERIFIED.

8. **Under INVOKER, the caller must have SELECT on every base table** — VERIFIED.

9. **`current_user` still returns the actual invoker even under DEFINER** — implicitly consistent with the answer's recommendation (not directly stated, but doesn't contradict).

---

## What was missing or wrong

### Minor imprecision #1: Two distinct OPA checks not cleanly separated

When a caller queries a DEFINER view, Trino performs (at least) two kinds of authorization checks during analysis:

- **View-level check** — `checkCanSelectFromColumns` on the view object, evaluated against the **caller's** identity. The caller must be allowed to SELECT from the view itself.
- **Base-table checks** — `checkCanSelectFromColumns` on each underlying table, evaluated against the **view owner's** identity (under DEFINER) or the **caller's** identity (under INVOKER).

The answer collapses these into "OPA checks the underlying tables against the view owner's identity," which is true for DEFINER's base-table phase but glosses over the view-level check against the caller. An engineer trying to write the OPA policy needs to know: yes, your policy will still receive a `SelectFromColumns` call for the view object with the caller's identity, AND a `SelectFromColumns` call for each base table with the view owner's identity. The policy can deny either.

### Minor omission #2: OPA can attach row-filter policies to view objects themselves

The answer correctly notes that per-caller row filters keyed on the caller's identity won't apply to base tables under DEFINER. But it doesn't mention the workaround: you can attach a row-filter policy to the **view** object via OPA's `opa.policy.row-filters-uri`. The filter is evaluated against the caller's identity when they SELECT from the view, and Trino injects the filter expression as an additional WHERE clause on the view's resolved query. This lets you keep DEFINER mode (so the caller doesn't need base-table grants) and still get per-caller row filtering through the view.

Without this, the engineer might conclude DEFINER mode and row-level security are incompatible. They aren't — you just attach the filter at the view layer instead of the base-table layer.

### Minor omission #3: Cross-catalog identity propagation note

The view joins Iceberg (HMS-backed in this stack) and Postgres. Under DEFINER, the **same view owner identity** is used to authorize both base-table reads. The answer doesn't call out that the view owner needs to be a valid principal both for Trino's OPA policy and for any catalog-level grants (Postgres GRANTs on the JDBC role, Iceberg/HMS access). For the prod stack (JWT-authenticated users + service principal for the view owner), this means the view owner is typically a fixed service principal, not a human user — worth one sentence so the engineer doesn't try to make a per-tenant user own the view.

### Minor omission #4: `SHOW CREATE VIEW` shows the SECURITY clause

Engineer auditing existing views needs to know which mode each view is in. `SHOW CREATE VIEW <name>` displays the SECURITY clause (DEFINER or INVOKER) explicitly. A one-line operational tip would close the loop on "how do I audit what we already have?"

### Nit #5: "OPA receives these resolved table names in the SelectFromColumns operation"

Correct in spirit, but the actual operation name in the OPA plugin's request payload is `SelectFromColumns` — the answer renders it as a free-form English phrase rather than the actual operation identifier the engineer will see in OPA decision logs. If they grep their logs after reading this answer, the actual JSON field will be `"operation": "SelectFromColumns"`. Not a hard error, but lossy.

---

## Specific resource fixes needed

These edits target the `resources/22-trino-federation-postgresql.md` (or the cross-catalog views resource) and `resources/05-multi-tenant-analytics.md`:

### Fix 1: Add a "Two-check model for DEFINER views" sub-section
Spell out the two distinct OPA calls that fire when a caller queries a DEFINER view:
1. `SelectFromColumns` on the view object, identity = caller.
2. `SelectFromColumns` on each underlying base table, identity = view owner.

Include a small JSON example of each OPA request payload so engineers know what to write Rego against.

### Fix 2: Add OPA row-filter-on-view as the DEFINER-compatible RLS pattern
Document that `opa.policy.row-filters-uri` can attach a filter to a view object, evaluated against the caller's identity. This is the canonical way to get per-caller row-level security while keeping DEFINER's "caller doesn't need base-table grants" benefit. Without this, engineers may conclude RLS and DEFINER are incompatible and overcorrect into INVOKER mode (which then requires giving callers direct base-table grants — exactly the opposite of multi-tenant isolation).

### Fix 3: Add a "view owner = service principal" note for cross-catalog views
Brief paragraph: in the on-prem JWT+OPA setup, cross-catalog views (Iceberg + Postgres) should be owned by a fixed service principal that has SELECT on both catalogs. Don't make per-tenant users own the view.

### Fix 4: Add a `SHOW CREATE VIEW` audit recipe
One sentence: "To audit which security mode an existing view uses, run `SHOW CREATE VIEW <catalog>.<schema>.<view>` and look for the `SECURITY DEFINER` or `SECURITY INVOKER` clause near the top of the output."

### Fix 5: Cite the actual OPA operation name (`SelectFromColumns`)
When resources describe what OPA receives, use the literal operation name (`SelectFromColumns`, `FilterColumns`, etc.) so grepping decision logs works.

### Fix 6 (from Q1 — same iter, recurring): Add OPA lifecycle section
This is the highest-leverage edit from Q1 of the same iteration: a clearly-labeled subsection stating "Trino consults OPA only during query analysis (planning) at the coordinator, NOT during distributed execution. An OPA outage or policy change that happens after a query has passed analysis does not affect the running query." See feedback-iter209-q1.md for full detail. This edit benefits both Q1 and Q2 because both questions sit at the OPA-view-federation intersection.

---

## Pattern note for teacher

Q2 is the strongest answer the federation topic has produced on the OPA-views-row-security angle so far. The DEFINER-vs-INVOKER framing landed, the "row-filter target identity" insight landed, and the CI verification pattern is the kind of operationally-actionable advice that drives high practical scores.

Two patterns to reinforce in resources:
1. **Always pair a view-permissions discussion with the explicit OPA row-filter-on-view pattern.** Otherwise readers conclude DEFINER and RLS are incompatible.
2. **Always name the actual SPI operation name** (`SelectFromColumns` etc.) so OPA decision-log grep is one step away.

---

## Sources cross-checked

- [CREATE VIEW — Trino 481 Documentation](https://trino.io/docs/current/sql/create-view.html) — confirms DEFINER is default, explains DEFINER vs INVOKER semantics for base-table access.
- [Open Policy Agent access control — Trino 481 Documentation](https://trino.io/docs/current/security/opa-access-control.html) — confirms `opa.policy.row-filters-uri` mechanism and operation names.
- [trinodb/trino Discussion #14790 — Authorization on query views](https://github.com/trinodb/trino/discussions/14790) — confirms code-level handling of INVOKER setting `owner = Optional.empty()`.
- [trinodb/trino Issue #6792 — SHOW CREATE VIEW SECURITY INVOKER](https://github.com/trinodb/trino/issues/6792) — confirms SHOW CREATE VIEW exposes the SECURITY clause.
