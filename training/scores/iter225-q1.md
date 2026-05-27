# Iter 225 Q1 Judge Score

## Score: 4.85

## Topic: Trino federation cross-source connectors (OPA row-filter + cross-catalog SECURITY DEFINER views)

## What the answer got right

1. **SECURITY DEFINER is the Trino default for views** — VERIFIED correct against
   https://trino.io/docs/current/sql/create-view.html. Docs explicitly say "In the
   default `DEFINER` security mode, tables referenced in the view are accessed
   using the permissions of the view owner."

2. **Two-check OPA model** — Correctly describes:
   - Check 1: view-level access uses the **caller's** identity.
   - Check 2: base-table access uses the **view owner's** identity (in DEFINER mode).
   This is the correct semantics confirmed by the CREATE VIEW docs and matches how
   the OPA plugin issues `GetRowFilters` per table accessed during planning.

3. **`GetRowFilters` is the correct OPA operation name** — VERIFIED against
   the Trino OPA plugin source (`OpaHighLevelClient.java`): the literal string
   passed is `.operation("GetRowFilters")`. The companion operation
   `GetColumnMask` was also verified. The Rego example pattern
   `input.action.operation == "GetRowFilters"` is exactly what real-world
   policies match on.

4. **OPA still fires `GetRowFilters` against billing_mysql even through an
   iceberg view** — Correct. Trino expands the view and runs access-control
   checks (including row filters) against every concrete base table touched,
   regardless of which catalog hosts the view.

5. **The "privilege escalation" framing** — Technically and pedagogically sound:
   the answer correctly reframes the engineer's "bypass" worry as an
   architectural property of DEFINER (not an OPA bug). This is the right
   mental model.

6. **SECURITY INVOKER explanation** — Correct: caller identity is used for
   both view-level and base-table checks; therefore caller must hold direct
   SELECT on base tables. INVOKER has been a Trino feature since Release 301
   (2019), so Trino 467 absolutely supports it.

7. **The decision-log JSON shape** — The `input.action.operation`,
   `input.context.identity.user`, `input.resource.table.{catalogName,
   schemaName, tableName}` shape, and the result array of
   `{"expression": "..."}` are all consistent with the Trino OPA docs and the
   verified Rego example. The empty-array `[]` for "no filter applied" is
   also the documented contract.

8. **Three remediation options** — All three are technically sound:
   - Option 1 (attach filter to the view object, keyed to caller identity) is
     the standard recommendation and works because the view-level check uses
     the caller's identity.
   - Option 2 (restricted view owner) is correctly flagged as harder to
     maintain but valid.
   - Option 3 (SECURITY INVOKER) is correctly called out as defeating the
     usual multi-catalog isolation pattern.

9. **Production fit** — The answer stays at the general/conceptual Trino+OPA
   level required by `prod_info.md` (Trino 467 + OPA) and does not invent
   specific policy rules or role hierarchies. Good discipline.

## What the answer missed or got wrong

1. **Minor: the OPA result-array structure can include an optional `identity`
   field** — The docs say each row-filter object may include an optional
   `identity` to evaluate the expression under a different user context. Not
   shown in the answer's example. Not a correctness issue — just a small
   completeness gap.

2. **Minor: no mention of `current_user`** — The CREATE VIEW docs note that
   `current_user` returns the *invoker* even in DEFINER mode, which is the
   classic Trino idiom for hand-rolling per-caller row filtering inside the
   view body itself (a fourth remediation option). Worth a sentence.

3. **Minor: no mention of column masking (`GetColumnMask`)** — The engineer
   asked about row-level access, so this is out of scope strictly speaking,
   but a one-line "the same two-identity model applies to column masks via
   `GetColumnMask`" would round out the answer.

4. **Very minor: phrasing "OPA still enforces row-level access control
   against the underlying tables"** — Strictly, OPA enforces what the policy
   tells it to enforce; the mechanism is that Trino issues `GetRowFilters`
   per accessed base table. The answer does correctly distinguish this later
   ("OPA is working correctly — you've architected a situation where the
   policy doesn't apply"). Phrasing is fine but could be tightened.

None of the above is a factual error.

## WebSearch verification notes

URLs consulted:
- https://trino.io/docs/current/sql/create-view.html — confirmed DEFINER is
  default, INVOKER supported, base-table access uses owner identity in
  DEFINER mode, `current_user` always returns invoker.
- https://trino.io/docs/current/security/opa-access-control.html — confirmed
  row-filter response format `{"expression": "clause"}`, optional `identity`
  field, batch vs single modes.
- Trino OPA plugin source `OpaHighLevelClient.java` (via GitHub WebFetch) —
  confirmed literal operation string `"GetRowFilters"` and `"GetColumnMask"`.
- Rego example via search — confirmed `input.action.operation ==
  "GetRowFilters"` pattern and the resource shape
  `input.action.resource.table.{catalogName, schemaName, tableName}`.
- Trino release-301 notes — confirmed SECURITY INVOKER has existed since 2019,
  so Trino 467 fully supports it.

All load-bearing claims in the answer line up with the official docs and
source.

## Recommendation for teacher

Resource is in very good shape on this topic. Optional small additions (not
required for passing):

1. Add a sentence about the optional `identity` field in row-filter
   responses (allows expression evaluation under a different identity).
2. Mention `current_user` always returning the invoker even in DEFINER mode,
   as an additional pattern for per-caller filtering written *inside* the
   view body.
3. One-line cross-reference to `GetColumnMask` so engineers know the same
   two-identity model applies to column masking.

These are polish; the answer as written is production-grade.
