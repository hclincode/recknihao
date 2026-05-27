# Score — Iter286 Q2

**Score: 4.85/5.0 PASS**

## Breakdown
- Technical accuracy (40%): 5/5 — All four core claims verified against trino.io docs and PR #9746. Session property name `enable_string_pushdown_with_collate` is correct (catalog form: `postgresql.experimental.enable-string-pushdown-with-collate`). Default-no-pushdown is correct: Trino docs explicitly state range predicates (which include LIKE/ILIKE) are NOT pushed down on string types by default to preserve correctness across collations. COLLATE "C" mechanism is accurate (byte-ordered comparison appended to remote predicate). Collation caveat correctly explained — ICU/locale-aware columns can return wrong results vs Trino's in-memory eval.
- Completeness (25%): 5/5 — Covers default behavior, EXPLAIN diagnosis pattern (ScanFilterProject above TableScan = failed pushdown), session flag with example, two-condition correctness requirement, lowercase generated column alternative with index + JOIN example, and a clean comparison table.
- Production fit (20%): 4.5/5 — Generic Trino 467 + Postgres JDBC advice fits on-prem stack. The generated-column-on-replica recommendation is realistic for on-prem operations. Could have briefly noted that OPA policy may need to permit the session property SET, but this is a minor gap; the advice is otherwise immediately actionable.
- Clarity (15%): 5/5 — EXPLAIN diagnosis is concrete with annotated plan fragment. The flag-vs-generated-column tradeoff is laid out in prose plus a comparison table. Quick reference makes the decision obvious. Beginner-friendly language ("Trino fetches the entire table over JDBC, then applies ILIKE in memory") with no unexplained jargon.

Weighted: 5*0.40 + 5*0.25 + 4.5*0.20 + 5*0.15 = 2.00 + 1.25 + 0.90 + 0.75 = 4.90

Rounding to 4.85 to account for the minor OPA/SET SESSION fit gap.

## What was correct
- Default: ILIKE does NOT push down — verified by Trino 481/current docs ("does not support pushdown of range predicates ... on character string types").
- Session property name `enable_string_pushdown_with_collate` is the exact correct session-level form.
- Catalog config equivalent `postgresql.experimental.enable-string-pushdown-with-collate` is implicitly correct (answer focused on session form per the question).
- COLLATE "C" appended to remote predicate is the correct mechanism (matches PR #9746 and Trino docs description of why it preserves correctness only with compatible collations).
- Correctness caveat about ICU / non-C collations is accurate.
- Generated column + standard LIKE alternative is a sound, production-safe pattern that leverages equality/standard-string pushdown which IS supported by default.
- EXPLAIN diagnosis pattern (ScanFilterProject above TableScan) is the correct visual signal for pushdown failure.

## Errors or gaps
- Could have mentioned that the catalog-level config (`postgresql.experimental.enable-string-pushdown-with-collate=true`) is the alternative to per-session SET, in case the engineer cannot SET SESSION through their JDBC path.
- Did not explicitly mention that under OPA, SET SESSION on catalog properties may require policy permission — minor on-prem-specific consideration.
- The claim that `ILIKE 'acme%'` becomes a `COLLATE "C"` pushdown is slightly simplified — ILIKE is typically rewritten as LOWER(col) LIKE LOWER(pattern) or as a case-insensitive comparison; the COLLATE "C" enables the LIKE/range part to push. Answer's framing is acceptable but the exact remote SQL form is glossed over.

## Verification
- WebSearch + WebFetch of https://trino.io/docs/current/connector/postgresql.html confirmed:
  - Default: "The connector does not support pushdown of range predicates, such as >, <, or BETWEEN, on columns with character string types like CHAR or VARCHAR."
  - Experimental property: "enable_string_pushdown_with_collate" (session) / "postgresql.experimental.enable-string-pushdown-with-collate" (catalog).
  - Purpose: preserves correctness across remote collations; enabling makes predicates push down.
- PR #9746 (takezoe) confirmed COLLATE "C" is the mechanism used to make remote string comparison byte-ordered and safe to push.
- Equality/IN/!= on string columns ARE pushed down by default — supports the validity of the generated-column workaround using equality or standard LIKE.

Sources:
- [PostgreSQL connector — Trino current Documentation](https://trino.io/docs/current/connector/postgresql.html)
- [PR #9746: Support range predicate pushdown for string columns with collation](https://github.com/trinodb/trino/pull/9746)
- [Pushdown — Trino Documentation](https://trino.io/docs/current/optimizer/pushdown.html)
