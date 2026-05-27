# Score: iter241-q1 — PostgreSQL Predicate Pushdown

**Score: 4.7 / 5.0**

## What was correct

1. **VARCHAR equality / IN unconditionally push** — Correct. The answer states `status = 'active'` and `status IN ('active', 'trial')` push to PostgreSQL unconditionally. Verified against trino.io/docs/current/connector/postgresql.html: "Equality predicates, such as `IN` or `=`, and inequality predicates, such as `!=` on columns with textual types are pushed down."

2. **`!=` and IS NULL / IS NOT NULL push on VARCHAR** — Correct. Trino's PostgreSQL docs explicitly confirm `!=` and NULL checks on text columns push down.

3. **Timestamp/date range filters unconditionally push** — Correct. `created_at > '2025-01-01'` does push. Trino docs confirm temporal range pushdown is supported. The answer's list (`>`, `<`, `>=`, `<=`, `BETWEEN`) is accurate.

4. **Anchored `LIKE 'foo%'` is collation-dependent / "MAYBE"** — Correctly hedged. The Trino docs do not promise unconditional LIKE pushdown, and the experimental `enable-string-pushdown-with-collate` flag exists precisely because string-comparison correctness depends on collation. Matching the resource file's defensive "verify with EXPLAIN" framing is appropriate.

5. **Leading-wildcard LIKE (`%text%`) does not push** — The answer's framing is operationally correct for the engineer's purposes. (Technically, even if it "pushes" syntactically, the engineer's real concern — does Postgres get a usable predicate — is "no useful pushdown effect," which is what the answer conveys.)

6. **EXPLAIN (TYPE DISTRIBUTED) verification approach** — Correct. The `TableScan` constraint vs. `ScanFilterProject`/`Filter` node distinction is the canonical pattern per trino.io/docs/current/optimizer/pushdown.html: "If predicate pushdown for a specific clause is successful, the EXPLAIN plan for the query does not include a ScanFilterProject operation for that clause."

7. **PostgreSQL slow-log verification as ground-truth fallback** — Practical, accurate, and useful guidance for an engineer who needs to be certain. Mentioning the read-replica caveat is a nice touch.

8. **Production-fit** — Answer matches the on-prem Trino 467 + PostgreSQL connector environment in `prod_info.md`. No invented features, no Starburst-only properties surfaced.

## What was wrong or missing

1. **Minor inaccuracy on leading-wildcard LIKE** — The answer says `LIKE '%text%'` "does not push down by default; Trino pulls rows to its workers and applies the filter in-memory." Per Trino source behavior, an unanchored LIKE may push down syntactically as a remote LIKE expression — it just can't use a Postgres btree index. The resource file (line 2150) gets this distinction right ("push down syntactically when they push at all, but rarely help performance because Postgres cannot use a btree index"). The answer collapses both effects into "doesn't push," which is operationally correct for the engineer but technically imprecise. Minor deduction.

2. **Experimental string-range flag not mentioned** — When discussing LIKE / string-range edge cases, the resource has a clear escape hatch (`postgresql.experimental.enable-string-pushdown-with-collate`). The answer omits it. This is appropriate for an answer focused on the engineer's three operators (equality, timestamp range, LIKE prefix), but a one-line "if anchored LIKE refuses to push and you need it to, there's an experimental flag" would have strengthened the LIKE section. Not a scoring deduction — the engineer asked about behavior, not workarounds — but noted for completeness.

3. **String-range pushdown caveat not surfaced** — The answer doesn't mention that VARCHAR range filters (e.g., `WHERE status > 'a'`) do NOT push by default. The engineer didn't ask about that exact case, so the omission is acceptable, but a "this rule is operator-specific — equality pushes, range does not" callout would have generalized the lesson cleanly.

4. **Bottom line on `status IN ('active', 'trial')` — IN-list pushdown is correctly stated but not separately verified.** The answer treats IN as equivalent to equality, which Trino docs confirm. No deduction.

## Verification notes

- **Claim 1 (VARCHAR equality/IN/!= push)**: VERIFIED against trino.io/docs/current/connector/postgresql.html. Direct quote: "Equality predicates, such as `IN` or `=`, and inequality predicates, such as `!=` on columns with textual types are pushed down."

- **Claim 2 (timestamp/date range pushes unconditionally)**: VERIFIED. Trino PostgreSQL docs list temporal range pushdown as supported without flags.

- **Claim 3 (anchored LIKE — collation-dependent)**: VERIFIED. Trino docs don't promise unconditional LIKE pushdown; the experimental `enable-string-pushdown-with-collate` flag exists precisely because string comparisons (including pattern-anchored LIKE) are collation-sensitive. The "MAYBE — verify with EXPLAIN" framing is the defensible answer.

- **Claim 4 (leading-wildcard LIKE doesn't push)**: PARTIALLY VERIFIED. Operationally correct (no useful index-eligible pushdown), but technically the predicate may still be sent to Postgres as a LIKE expression — Postgres just sequential-scans. The resource file states this nuance correctly; the answer simplifies it.

- **Claim 5 (IS NULL/IS NOT NULL on VARCHAR pushes)**: VERIFIED. Confirmed by Trino PostgreSQL connector docs.

- **Claim 6 (EXPLAIN TYPE DISTRIBUTED verification)**: VERIFIED against trino.io/docs/current/optimizer/pushdown.html. The `constraint on [columns]` vs `ScanFilterProject` distinction is the canonical interpretation pattern.

## Dimension scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All major claims verified. Minor simplification on unanchored LIKE pushdown mechanics. |
| Beginner clarity | 5.0 | Plain-English framing ("Trino translates this into a JDBC SQL WHERE clause..."), no unexplained jargon, BLUF summary up front, concrete EXPLAIN output snippets shown. |
| Practical applicability | 5.0 | Engineer can verify on their own cluster: exact EXPLAIN command given, output patterns shown for both pass and fail cases, PostgreSQL slow-log fallback for ambiguous EXPLAIN output. Tailored to the engineer's exact DBA conversation. |
| Completeness | 4.3 | Covers the three asked filter types thoroughly, plus IS NULL bonus and DBA talking points. Could have mentioned the experimental string-range flag and the "operator-specific" generalization briefly. |

**Average: (4.5 + 5.0 + 5.0 + 4.3) / 4 = 4.7**

## Recommendation for teacher

No urgent fixes required — this answer is a model example of how to communicate the operator-specific PostgreSQL pushdown rule clearly to a beginner. The resource file (`resources/22-trino-federation-postgresql.md`) Section 3.2 is what enabled this answer's quality; keep that section prominent.

**Minor polish (optional, LOW priority):**
1. In `resources/22-trino-federation-postgresql.md` around the unanchored-LIKE discussion (line 2150), consider adding a one-line BLUF: "Unanchored LIKE (`%text%`) — for the engineer's purposes, treat as 'no useful pushdown' even if the LIKE expression is sent to Postgres, because Postgres cannot use a btree index and will sequential-scan." This would let future answers be both technically precise and operationally clear without choosing between them.

2. Consider adding a "what your DBA actually wants to hear" snippet to Section 3 — the iter241-q1 answer's "Key Takeaway for Your DBA Conversation" closing is exactly the kind of frame an application engineer needs, and codifying it in the resource would help future answers reproduce it.
